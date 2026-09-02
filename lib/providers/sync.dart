import 'dart:convert';
import 'dart:io' as io;

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/enums/sync_trigger.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/main.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/models/sync_state_model.dart';
import 'package:anx_reader/providers/book_list.dart';
import 'package:anx_reader/providers/sync_status.dart';
import 'package:anx_reader/providers/tb_groups.dart';
import 'package:anx_reader/service/sync/annotation_sync_runtime.dart';
import 'package:anx_reader/service/sync/library_asset_sync.dart';
import 'package:anx_reader/service/sync/library_protocol.dart';
import 'package:anx_reader/service/sync/library_sync_repository.dart';
import 'package:anx_reader/service/sync/sync_client_base.dart';
import 'package:anx_reader/service/sync/sync_client_factory.dart';
import 'package:anx_reader/utils/get_path/get_base_path.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:anx_reader/utils/toast/common.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'sync.g.dart';

class BookAssetAvailability {
  final bool localVerified;
  final bool remote;
  final bool released;

  const BookAssetAvailability({
    required this.localVerified,
    required this.remote,
    required this.released,
  });
}

/// Directionless automatic synchronization entry point.
///
/// Neither application SQLite database is transferred. Shared documents
/// converge first, followed by catalog-referenced immutable assets and the
/// independent translation cache.
@Riverpod(keepAlive: true)
class Sync extends _$Sync {
  static final Sync _instance = Sync._internal();
  factory Sync() => _instance;
  Sync._internal();
  String? _lastSkipReason;

  @override
  SyncStateModel build() => const SyncStateModel(
        isSyncing: false,
        total: 0,
        count: 0,
        fileName: '',
      );

  SyncClientBase? get _syncClient {
    if (SyncClientFactory.currentClient == null) {
      SyncClientFactory.initializeCurrentClient();
    }
    return SyncClientFactory.currentClient;
  }

  Future<void> init() async {
    final client = _syncClient;
    if (client != null) AnxLog.info('${client.protocolName}: init');
  }

  Future<bool> shouldSync() async {
    if (!Prefs().webdavStatus) {
      _logSkip('not-configured');
      return false;
    }
    if (Prefs().onlySyncWhenWifi) {
      final connectivity = await Connectivity().checkConnectivity();
      if (connectivity.contains(ConnectivityResult.wifi)) return true;
      _logSkip(connectivity.contains(ConnectivityResult.none)
          ? 'no-network'
          : 'wifi-policy');
      if (Prefs().syncCompletedToast) {
        AnxToast.show(L10n.of(navigatorKey.currentContext!).webdavOnlyWifi);
      }
      return false;
    }
    return true;
  }

  Future<void> synchronize(
    WidgetRef? ref, {
    SyncTrigger trigger = SyncTrigger.auto,
  }) async {
    if (trigger != SyncTrigger.manual && !Prefs().autoSync) {
      _logSkip('auto-disabled');
      return;
    }
    if (state.isSyncing || !await shouldSync()) return;
    final client = _syncClient;
    if (client == null) {
      _logSkip('not-configured');
      return;
    }
    _lastSkipReason = null;
    state = state.copyWith(isSyncing: true, count: 0, total: 0, fileName: '');
    try {
      _showSyncToast((l10n) => l10n.webdavSyncing);
      await client.ping();
      if (trigger == SyncTrigger.manual) {
        await annotationSyncRuntime.syncNow();
      } else {
        await annotationSyncRuntime.syncAutomatic(
          trigger: trigger == SyncTrigger.startup ? 'startup' : 'mutation',
        );
      }
      ref?.read(bookListProvider.notifier).refresh();
      ref?.read(groupDaoProvider.notifier).refresh();
      ref?.read(syncStatusProvider.notifier).refresh();
      _showSyncToast((l10n) => l10n.webdavSyncComplete);
    } catch (error) {
      AnxLog.severe('Automatic shared-state sync failed: ${error.runtimeType}');
    } finally {
      state = state.copyWith(isSyncing: false);
    }
  }

  void _showSyncToast(String Function(L10n) message) {
    if (!Prefs().syncCompletedToast) return;
    try {
      final context = navigatorKey.currentContext;
      if (context == null) return;
      AnxToast.tryShow(message(L10n.of(context)));
    } catch (error) {
      AnxLog.warning('Sync notification failed: ${error.runtimeType}');
    }
  }

  Future<Map<String, dynamic>?> _catalog(String fingerprint) async {
    final bytes = await annotationSyncRuntime.sharedState
        .canonicalDocument(libraryCatalogDomain, fingerprint.toLowerCase());
    return bytes == null
        ? null
        : decodeLibraryCatalogDocument(jsonDecode(utf8.decode(bytes)));
  }

  Future<void> uploadFile(
    String localPath,
    String remotePath, [
    bool replace = true,
  ]) async {
    final client = _syncClient;
    if (client == null) return;
    state = state.copyWith(fileName: localPath.split('/').last);
    await client.uploadFile(localPath, remotePath,
        replace: replace,
        onProgress: (sent, total) =>
            state = state.copyWith(count: sent, total: total));
  }

  Future<void> downloadFile(String remotePath, String localPath) async {
    final client = _syncClient;
    if (client == null) return;
    state = state.copyWith(fileName: remotePath.split('/').last);
    await client.downloadFile(remotePath, localPath,
        onProgress: (received, total) =>
            state = state.copyWith(count: received, total: total));
  }

  Future<BookAssetAvailability> bookAssetAvailability(Book book) async {
    final fingerprint = book.md5?.toLowerCase();
    final client = _syncClient;
    if (fingerprint == null || client == null) {
      return const BookAssetAvailability(
          localVerified: false, remote: false, released: false);
    }
    final document = await _catalog(fingerprint);
    if (document == null) {
      return const BookAssetAvailability(
          localVerified: false, remote: false, released: false);
    }
    final asset = (document['bookAsset'] as Map<String, dynamic>)['value']
        as Map<String, dynamic>;
    final digest = asset['digest'] as String;
    final local = io.File(getBasePath(book.filePath));
    final localVerified = await local.exists() &&
        (await sha256.bind(local.openRead()).first).toString() == digest;
    final remote = await SyncClientLibraryAssetTransport(client)
        .exists(libraryBookAssetSegments(digest));
    final receipt = await annotationSyncRuntime.sharedState
        .importReceipt(libraryAssetReleaseSource, fingerprint);
    return BookAssetAvailability(
      localVerified: localVerified,
      remote: remote,
      released: !localVerified &&
          remote &&
          receipt?.status == 'released' &&
          receipt?.sharedId == digest,
    );
  }

  Future<void> downloadBook(Book book) async {
    final fingerprint = book.md5?.toLowerCase();
    final client = _syncClient;
    if (fingerprint == null || client == null) return;
    final document = await _catalog(fingerprint);
    if (document == null) {
      AnxToast.show(L10n.of(navigatorKey.currentContext!)
          .bookSyncStatusBookNotFoundRemote);
      return;
    }
    final result = await LibraryAssetSyncService(
      transport: SyncClientLibraryAssetTransport(client),
      projection: SqliteLibraryProjection(),
    ).syncBook(document);
    if (result.downloaded || result.bound) {
      final asset = (document['bookAsset'] as Map<String, dynamic>)['value']
          as Map<String, dynamic>;
      await annotationSyncRuntime.sharedState.recordImport(
        source: libraryAssetReleaseSource,
        sourceKey: fingerprint,
        sharedId: asset['digest'] as String,
        status: 'acquired',
      );
    }
    ref.read(syncStatusProvider.notifier).refresh();
  }

  Future<void> releaseBook(Book book) async {
    final fingerprint = book.md5?.toLowerCase();
    final client = _syncClient;
    if (fingerprint == null || client == null) return;
    final document = await _catalog(fingerprint);
    if (document == null) return;
    final asset = (document['bookAsset'] as Map<String, dynamic>)['value']
        as Map<String, dynamic>;
    final digest = asset['digest'] as String;
    final transport = SyncClientLibraryAssetTransport(client);
    if (await transport.exists(libraryBookAssetSegments(digest))) {
      await annotationSyncRuntime.sharedState.recordImport(
        source: libraryAssetReleaseSource,
        sourceKey: fingerprint,
        sharedId: digest,
        status: 'released',
      );
      final local = io.File(getBasePath(book.filePath));
      if (local.existsSync()) await local.delete();
      ref.read(syncStatusProvider.notifier).refresh();
    }
  }

  Future<void> downloadMultipleBooks(List<int> bookIds) async {
    for (final id in bookIds) {
      try {
        await downloadBook(await bookDao.selectBookById(id));
      } catch (error) {
        AnxLog.warning('Book asset download failed: ${error.runtimeType}');
      }
    }
  }

  void _logSkip(String reason) {
    if (_lastSkipReason == reason) return;
    _lastSkipReason = reason;
    AnxLog.info('sync skipped reason=$reason');
  }
}
