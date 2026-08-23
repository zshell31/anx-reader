import 'dart:io';

import 'package:anx_reader/models/full_text_translation_cache.dart';
import 'package:anx_reader/service/sync/sync_client_base.dart';
import 'package:anx_reader/service/translate/full_text_translation_cache_service.dart';
import 'package:anx_reader/service/translate/translation_cache_database.dart';
import 'package:anx_reader/service/translate/translation_cache_merge.dart';
import 'package:anx_reader/utils/get_path/get_temp_dir.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:path/path.dart';

const String translationCacheRemoteDirectory = 'anx/data/translation-cache/v1';

class TranslationCacheSyncService {
  TranslationCacheSyncService({
    required this.client,
    TranslationCacheDatabase? database,
    FullTextTranslationCacheService? cacheService,
  })  : cacheService = cacheService ?? fullTextTranslationCacheService,
        database = database ??
            (cacheService ?? fullTextTranslationCacheService).database;

  final SyncClientBase client;
  final TranslationCacheDatabase database;
  final FullTextTranslationCacheService cacheService;

  Future<void> sync() async {
    final remoteFiles =
        await client.safeReadDir('/$translationCacheRemoteDirectory');
    final remoteFingerprints = remoteFiles
        .map((file) => file.name ?? '')
        .where((name) => RegExp(r'^[0-9a-fA-F]{32}\.json$').hasMatch(name))
        .map((name) => name.substring(0, name.length - 5).toLowerCase())
        .toSet();
    final fingerprints = <String>{
      ...await database.bookFingerprints(),
      ...remoteFingerprints,
    }.toList()
      ..sort();

    for (final fingerprint in fingerprints) {
      try {
        await cacheService.synchronizeSemanticMutation(
          () =>
              _syncBook(fingerprint, remoteFingerprints.contains(fingerprint)),
        );
      } catch (error, stack) {
        AnxLog.warning(
            'Translation cache sync failed for $fingerprint: $error\n$stack');
      }
    }
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
          AnxLog.severe(
              'Translation cache remote book identity mismatch; skipping');
          return;
        }
      } on UnsupportedError catch (error) {
        AnxLog.warning('$error; translation cache document was not merged');
        return;
      } catch (error) {
        AnxLog.warning(
            'Invalid remote translation cache for $fingerprint: $error');
        return;
      }
    }

    final result = mergeTranslationCacheEntries(
      localEntries,
      remoteDocument?.entries ?? const <TranslationCacheEntry>[],
    );
    if (result.hasIdentityConflict) {
      AnxLog.severe(
          'Translation cache request-key collision for book $fingerprint; both documents were left in place');
      return;
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
      await database.upsertAll(retryMerge.entries);
      await _uploadDocument(TranslationCacheBookDocument(
        bookFingerprintAlgorithm: bookFingerprintAlgorithmMd5,
        bookFingerprint: fingerprint,
        entries: retryMerge.entries,
      ));
    } else {
      await _uploadDocument(mergedDocument);
    }
  }

  Future<TranslationCacheBookDocument> _downloadDocument(
    String fingerprint,
  ) async {
    final tempDir = await getAnxTempDir();
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
    final tempDir = await getAnxTempDir();
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
