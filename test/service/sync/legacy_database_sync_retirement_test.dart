import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('normal sync has no whole-database transfer or direction selection', () {
    final source = File('lib/providers/sync.dart').readAsStringSync();
    expect(source, isNot(contains('app_database.db')));
    expect(source, isNot(contains('determineSyncDirection')));
    expect(source, isNot(contains('syncDatabase')));
    expect(source, isNot(contains('syncFiles')));
    expect(source, isNot(contains('DatabaseSyncManager')));
    expect(source, isNot(contains('SyncDirection')));
    expect(source, isNot(contains('syncData(')));
    expect(source, contains('annotationSyncRuntime.syncNow()'));
  });

  test('shared runtime integrates assets and translation cache', () {
    final source = File('lib/service/sync/annotation_sync_runtime.dart')
        .readAsStringSync();
    expect(source, contains('LibraryAssetSyncService'));
    expect(source, contains('TranslationCacheSyncService'));
    expect(source.indexOf('syncCatalog('),
        lessThan(source.indexOf('coordinator.pullBooks(')));
  });

  test('sync transport cannot transfer either local SQLite database', () {
    final files = [
      File('lib/providers/sync.dart'),
      ...Directory('lib/service/sync').listSync().whereType<File>().where(
          (file) =>
              file.path.endsWith('.dart') &&
              !file.path.endsWith('shared_state_database.dart')),
    ];
    final source = files.map((file) => file.readAsStringSync()).join('\n');
    expect(source, isNot(contains('app_database.db')));
    expect(source, isNot(contains('shared_state.db')));
    expect(source, isNot(contains('VACUUM INTO')));
    expect(source, isNot(contains('database8.db')));
    expect(source, isNot(contains('prepareUploadSnapshot')));
  });

  test('legacy database replacement implementation is removed', () {
    expect(
        File('lib/service/database_sync_manager.dart').existsSync(), isFalse);
    expect(File('lib/enums/sync_direction.dart').existsSync(), isFalse);
  });

  test('ordinary sync diagnostics do not interpolate private identities', () {
    for (final path in [
      'lib/providers/sync.dart',
      'lib/service/sync/annotation_sync_runtime.dart',
      'lib/service/sync/translation_cache_sync_service.dart',
      'lib/service/sync/sync_connection_tester.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(source, isNot(contains(r'for $fingerprint')),
          reason: '$path must not log book fingerprints');
      expect(source, isNot(contains(r'$error\n$stack')),
          reason: '$path must not log raw errors or stack traces');
      expect(source, isNot(contains(r'localBook=$id')),
          reason: '$path must not log device-local book IDs');
    }
  });
}
