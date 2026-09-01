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
import 'package:anx_reader/service/sync/translation_cache_sync_service.dart';
import 'package:anx_reader/utils/get_path/get_base_path.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:anx_reader/utils/toast/common.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'sync.g.dart';

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
    if (!Prefs().webdavStatus) return false;
    if (Prefs().onlySyncWhenWifi &&
        !(await Connectivity().checkConnectivity())
            .contains(ConnectivityResult.wifi)) {
      if (Prefs().syncCompletedToast) {
        AnxToast.show(L10n.of(navigatorKey.currentContext!).webdavOnlyWifi);
      }
      return false;
    }
    return true;
  }

  Future<void> syncData(
    WidgetRef? ref, {
    SyncTrigger trigger = SyncTrigger.auto,
  }) async {
    if (trigger == SyncTrigger.auto && !Prefs().autoSync) return;
    if (state.isSyncing || !await shouldSync()) return;
    final client = _syncClient;
    if (client == null) {
      AnxLog.info('No sync client configured');
      return;
    }
    state = state.copyWith(isSyncing: true, count: 0, total: 0, fileName: '');
    if (Prefs().syncCompletedToast) {
      AnxToast.show(L10n.of(navigatorKey.currentContext!).webdavSyncing);
    }
    try {
      await client.ping();
      await annotationSyncRuntime.syncNow();
      await _syncSharedLibraryAssets(client);
      try {
        await TranslationCacheSyncService(client: client).sync();
      } catch (error, stackTrace) {
        AnxLog.warning(
            'Translation cache sync failed; shared domains remain safe: '
            '$error\n$stackTrace');
      }
      ref?.read(bookListProvider.notifier).refresh();
      ref?.read(groupDaoProvider.notifier).refresh();
      ref?.read(syncStatusProvider.notifier).refresh();
      if (Prefs().syncCompletedToast) {
        AnxToast.show(L10n.of(navigatorKey.currentContext!).webdavSyncComplete);
      }
    } catch (error, stackTrace) {
      AnxLog.severe('Automatic shared-state sync failed: $error\n$stackTrace');
    } finally {
      state = state.copyWith(isSyncing: false);
    }
  }

  Future<void> _syncSharedLibraryAssets(SyncClientBase client) async {
    final service = LibraryAssetSyncService(
      transport: SyncClientLibraryAssetTransport(client),
      projection: SqliteLibraryProjection(),
    );
    for (final id in await annotationSyncRuntime.sharedState
        .documentIds(libraryCatalogDomain)) {
      final document = await _catalog(id);
      if (document != null) await service.syncBook(document);
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

  Future<List<String>> listRemoteBookFiles() async {
    final client = _syncClient;
    if (client == null) return const [];
    final remote = await client.safeReadDir('/anx/assets/books/md5');
    return remote.map((file) => file.name).whereType<String>().toList();
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
    await LibraryAssetSyncService(
      transport: SyncClientLibraryAssetTransport(client),
      projection: SqliteLibraryProjection(),
    ).syncBook(document);
    ref.read(syncStatusProvider.notifier).refresh();
  }

  Future<void> releaseBook(Book book) async {
    final fingerprint = book.md5?.toLowerCase();
    final client = _syncClient;
    if (fingerprint == null || client == null) return;
    final document = await _catalog(fingerprint);
    if (document == null) return;
    final transport = SyncClientLibraryAssetTransport(client);
    await LibraryAssetSyncService(
      transport: transport,
      projection: SqliteLibraryProjection(),
    ).syncBook(document);
    if (await transport.exists(libraryBookAssetSegments(fingerprint))) {
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
        AnxLog.warning('Book asset download failed localBook=$id: $error');
      }
    }
  }
}
