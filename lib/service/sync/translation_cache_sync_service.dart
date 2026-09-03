import 'dart:io';

import 'package:anx_reader/models/full_text_translation_cache.dart';
import 'package:anx_reader/models/remote_file.dart';
import 'package:anx_reader/service/sync/sync_client_base.dart';
import 'package:anx_reader/service/sync/sync_diagnostics.dart';
import 'package:anx_reader/service/translate/full_text_translation_cache_service.dart';
import 'package:anx_reader/service/translate/translation_cache_database.dart';
import 'package:anx_reader/service/translate/translation_cache_merge.dart';
import 'package:anx_reader/utils/get_path/get_temp_dir.dart';
import 'package:path/path.dart';

const String translationCacheRemoteDirectory = 'anx/data/translation-cache/v1';

class TranslationCacheSyncService {
  TranslationCacheSyncService({
    required this.client,
    TranslationCacheDatabase? database,
    FullTextTranslationCacheService? cacheService,
    DateTime Function()? clock,
    Future<Directory> Function()? tempDirectory,
  })  : cacheService = cacheService ?? fullTextTranslationCacheService,
        database = database ??
            (cacheService ?? fullTextTranslationCacheService).database,
        _clock = clock ?? DateTime.now,
        _tempDirectory = tempDirectory ?? getAnxTempDir;

  final SyncClientBase client;
  final TranslationCacheDatabase database;
  final FullTextTranslationCacheService cacheService;
  final DateTime Function() _clock;
  final Future<Directory> Function() _tempDirectory;
  final Map<String, _TranslationSyncCheckpoint> _checkpoints = {};

  Future<void> sync() async {
    final remoteFiles =
        await client.safeReadDir('/$translationCacheRemoteDirectory');
    final remoteByFingerprint = <String, RemoteFile>{};
    for (final file in remoteFiles) {
      final name = file.name ?? '';
      if (!RegExp(r'^[0-9a-fA-F]{32}\.json$').hasMatch(name)) continue;
      remoteByFingerprint[name.substring(0, name.length - 5).toLowerCase()] =
          file;
    }
    final fingerprints = <String>{
      ...await database.bookFingerprints(),
      ...remoteByFingerprint.keys,
    }.toList()
      ..sort();

    var completed = 0;
    var failed = 0;
    var unchanged = 0;
    syncDebug('translation-cache documents=${fingerprints.length}');
    for (final fingerprint in fingerprints) {
      try {
        final remoteFile = remoteByFingerprint[fingerprint];
        final remoteToken = _remoteToken(remoteFile);
        final localToken = await database.bookSyncToken(fingerprint);
        final checkpoint = _checkpoints[fingerprint];
        if (remoteToken != null &&
            checkpoint?.remoteToken == remoteToken &&
            checkpoint?.localToken == localToken) {
          unchanged++;
          completed++;
          continue;
        }
        await cacheService.synchronizeSemanticMutation(
          () => _syncBook(fingerprint, remoteFile != null),
        );
        if (remoteToken != null) {
          _checkpoints[fingerprint] = _TranslationSyncCheckpoint(
            remoteToken,
            await database.bookSyncToken(fingerprint),
          );
        } else {
          _checkpoints.remove(fingerprint);
        }
        completed++;
      } catch (error) {
        failed++;
        syncWarning('translation-cache doc=${shortSyncId(fingerprint)} '
            'failed error=${safeSyncError(error)}');
      }
    }
    syncDebug('translation-cache completed=$completed unchanged=$unchanged '
        'failed=$failed');
  }

  String? _remoteToken(RemoteFile? file) {
    if (file == null) return null;
    final etag = file.eTag?.trim();
    if (etag?.isNotEmpty == true) return 'etag:$etag';
    final modified = file.mTime?.toUtc().toIso8601String();
    if (modified == null && file.size == null) return null;
    return 'metadata:${file.size ?? -1}:${modified ?? ''}';
  }

  Future<void> _syncBook(String fingerprint, bool remoteExists) async {
    final localEntries = await database.entriesForBook(fingerprint);
    TranslationCacheBookDocument? remoteDocument;
    if (remoteExists) {
      try {
        remoteDocument = await _downloadDocument(fingerprint);
        if (remoteDocument.bookFingerprintAlgorithm !=
                bookFingerprintAlgorithmMd5 ||
            remoteDocument.bookFingerprint != fingerprint) {
          syncWarning('translation-cache doc=${shortSyncId(fingerprint)} '
              'reason=identity-mismatch');
          return;
        }
      } on UnsupportedError {
        syncWarning('translation-cache doc=${shortSyncId(fingerprint)} '
            'reason=unsupported-remote');
        return;
      } catch (error) {
        syncWarning('translation-cache doc=${shortSyncId(fingerprint)} '
            'reason=malformed-remote error=${safeSyncError(error)}');
        return;
      }
    }

    final merged = mergeTranslationCacheEntries(
      localEntries,
      remoteDocument?.entries ?? const <TranslationCacheEntry>[],
    );
    if (merged.hasIdentityConflict) {
      syncWarning('translation-cache doc=${shortSyncId(fingerprint)} '
          'reason=identity-conflict');
      return;
    }
    final result = deduplicateReusableAiEntries(
      merged.entries,
      _clock().toUtc(),
    );
    if (result.tombstonedCount > 0) {
      syncInfo('translation-cache doc=${shortSyncId(fingerprint)} '
          'deduplicated=${result.tombstonedCount}');
    }
    final localState = <String, String>{
      for (final entry in localEntries)
        entry.requestKey: entry.canonicalState(),
    };
    final changesLocalState = result.entries.any(
      (entry) => localState[entry.requestKey] != entry.canonicalState(),
    );
    if (changesLocalState) {
      cacheService.invalidateBookInFlightWrites(fingerprint);
    }
    await database.upsertAll(result.entries);
    if (result.entries.isEmpty) return;

    final mergedDocument = TranslationCacheBookDocument(
      bookFingerprintAlgorithm: bookFingerprintAlgorithmMd5,
      bookFingerprint: fingerprint,
      entries: result.entries,
    );
    final mergedSource = mergedDocument.encode();
    final remoteSource = remoteDocument?.encode();
    if (mergedSource == remoteSource) return;

    // The bundled WebDAV API exposes ETags on PROPFIND results but has no
    // conditional PUT/If-Match operation. This isolated per-book merge is the
    // safest available fallback: it re-reads immediately before replacing and
    // never performs paragraph-level requests. A simultaneous writer can still
    // race between this read and PUT; conditional writes can be added here when
    // the client exposes them.
    if (remoteExists) {
      final latest = await _downloadDocument(fingerprint);
      final retryMerge = mergeTranslationCacheEntries(
        result.entries,
        latest.entries,
      );
      if (retryMerge.hasIdentityConflict) return;
      final retryResult = deduplicateReusableAiEntries(
        retryMerge.entries,
        _clock().toUtc(),
      );
      if (retryResult.tombstonedCount > 0) {
        cacheService.invalidateBookInFlightWrites(fingerprint);
        syncInfo('translation-cache doc=${shortSyncId(fingerprint)} '
            'retry-deduplicated=${retryResult.tombstonedCount}');
      }
      await database.upsertAll(retryResult.entries);
      await _uploadDocument(TranslationCacheBookDocument(
        bookFingerprintAlgorithm: bookFingerprintAlgorithmMd5,
        bookFingerprint: fingerprint,
        entries: retryResult.entries,
      ));
    } else {
      await _uploadDocument(mergedDocument);
    }
  }

  Future<TranslationCacheBookDocument> _downloadDocument(
    String fingerprint,
  ) async {
    final tempDir = await _tempDirectory();
    final file = File(join(
      tempDir.path,
      'translation-cache-download-$fingerprint-${DateTime.now().microsecondsSinceEpoch}.json',
    ));
    try {
      await client.downloadFile(
        '$translationCacheRemoteDirectory/$fingerprint.json',
        file.path,
      );
      return TranslationCacheBookDocument.decode(await file.readAsString());
    } finally {
      if (await file.exists()) await file.delete();
    }
  }

  Future<void> _uploadDocument(TranslationCacheBookDocument document) async {
    final tempDir = await _tempDirectory();
    final file = File(join(
      tempDir.path,
      'translation-cache-upload-${document.bookFingerprint}-${DateTime.now().microsecondsSinceEpoch}.json',
    ));
    try {
      await file.writeAsString(document.encode(), flush: true);
      await client.uploadFile(
        file.path,
        '$translationCacheRemoteDirectory/${document.bookFingerprint}.json',
        replace: true,
      );
    } finally {
      if (await file.exists()) await file.delete();
    }
  }
}

class _TranslationSyncCheckpoint {
  const _TranslationSyncCheckpoint(this.remoteToken, this.localToken);

  final String remoteToken;
  final String localToken;
}
