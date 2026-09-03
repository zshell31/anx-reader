import 'dart:io';

import 'package:anx_reader/models/full_text_translation_cache.dart';
import 'package:anx_reader/models/remote_file.dart';
import 'package:anx_reader/service/sync/sync_client_base.dart';
import 'package:anx_reader/service/sync/translation_cache_sync_service.dart';
import 'package:anx_reader/service/translate/full_text_translation_cache_service.dart';
import 'package:anx_reader/service/translate/translation_cache_database.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const fingerprint = 'abcdef0123456789abcdef0123456789';

class MemorySyncClient extends SyncClientBase {
  MemorySyncClient(this.document);

  String document;
  String etag = '"v1"';
  int downloads = 0;

  @override
  Future<List<RemoteFile>> safeReadDir(String path) async => [
        RemoteFile(
          name: '$fingerprint.json',
          size: document.length,
          eTag: etag,
        ),
      ];

  @override
  Future<void> downloadFile(String remotePath, String localPath,
      {void Function(int received, int total)? onProgress}) async {
    downloads++;
    await File(localPath).writeAsString(document);
  }

  @override
  Future<void> uploadFile(String localPath, String remotePath,
      {bool replace = true,
      void Function(int sent, int total)? onProgress,
      CancelToken? cancelToken}) async {
    document = await File(localPath).readAsString();
    etag = '"v2"';
  }

  @override
  Future<void> mkdirAll(String path) async {}
  @override
  Future<void> ping() async {}
  @override
  Future<List<RemoteFile>> readDir(String path) => safeReadDir(path);
  @override
  Future<RemoteFile?> readProps(String path) async => null;
  @override
  Future<void> remove(String path) async {}
  @override
  Future<void> testFullCapabilities() async {}
  @override
  Future<bool> isExist(String path) async => true;
  @override
  String get protocolName => 'memory';
  @override
  Map<String, dynamic> get config => const {};
  @override
  bool get isConfigured => true;
  @override
  void updateConfig(Map<String, dynamic> newConfig) {}
}

void main() {
  sqfliteFfiInit();

  test('unchanged ETag and local token skip the second document download',
      () async {
    final directory = await Directory.systemTemp.createTemp('anx-cache-sync-');
    final database = TranslationCacheDatabase(
      opener: () => databaseFactoryFfi.openDatabase(
        '${directory.path}/translation.db',
        options: OpenDatabaseOptions(
          version: translationCacheDatabaseVersion,
          singleInstance: false,
          onCreate: TranslationCacheDatabase.createSchema,
        ),
      ),
    );
    addTearDown(() async {
      await database.close();
      await directory.delete(recursive: true);
    });
    final request = FullTextTranslationRequest(
      bookFingerprint: fingerprint,
      sourceLanguage: 'en',
      targetLanguage: 'ru',
      translationService: 'ai',
      providerFingerprint: 'provider',
      promptFingerprint: 'prompt',
      sourceText: 'Source',
      contextText: '',
    );
    final entry = TranslationCacheEntry.fromRequest(
      request,
      'Translation',
      DateTime.utc(2026),
    );
    final document = TranslationCacheBookDocument(
      bookFingerprintAlgorithm: bookFingerprintAlgorithmMd5,
      bookFingerprint: fingerprint,
      entries: [entry],
    ).encode();
    final client = MemorySyncClient(document);
    final cache = FullTextTranslationCacheService(database: database);
    final service = TranslationCacheSyncService(
      client: client,
      database: database,
      cacheService: cache,
      tempDirectory: () async => directory,
    );

    await service.sync();
    await service.sync();

    expect(client.downloads, 1);
    expect(await database.activeCountForBook(fingerprint), 1);
  });

  test('local cache mutation invalidates the ETag checkpoint', () async {
    final directory = await Directory.systemTemp.createTemp('anx-cache-sync-');
    final database = TranslationCacheDatabase(
      opener: () => databaseFactoryFfi.openDatabase(
        '${directory.path}/translation.db',
        options: OpenDatabaseOptions(
          version: translationCacheDatabaseVersion,
          singleInstance: false,
          onCreate: TranslationCacheDatabase.createSchema,
        ),
      ),
    );
    addTearDown(() async {
      await database.close();
      await directory.delete(recursive: true);
    });
    FullTextTranslationRequest request(String source) =>
        FullTextTranslationRequest(
          bookFingerprint: fingerprint,
          sourceLanguage: 'en',
          targetLanguage: 'ru',
          translationService: 'ai',
          providerFingerprint: 'provider',
          promptFingerprint: 'prompt',
          sourceText: source,
          contextText: '',
        );
    final first = TranslationCacheEntry.fromRequest(
      request('First'),
      'Первый',
      DateTime.utc(2026),
    );
    final client = MemorySyncClient(TranslationCacheBookDocument(
      bookFingerprintAlgorithm: bookFingerprintAlgorithmMd5,
      bookFingerprint: fingerprint,
      entries: [first],
    ).encode());
    final cache = FullTextTranslationCacheService(database: database);
    final service = TranslationCacheSyncService(
      client: client,
      database: database,
      cacheService: cache,
      tempDirectory: () async => directory,
    );
    await service.sync();
    await database.upsert(TranslationCacheEntry.fromRequest(
      request('Second'),
      'Второй',
      DateTime.utc(2026, 1, 2),
    ));

    await service.sync();

    expect(client.downloads, 3,
        reason: 'a changed local document is read and re-read before PUT');
  });
}
