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
    expect(source, contains('annotationSyncRuntime.syncNow()'));
  });

  test('legacy database replacement implementation is removed', () {
    expect(
        File('lib/service/database_sync_manager.dart').existsSync(), isFalse);
    expect(File('lib/enums/sync_direction.dart').existsSync(), isFalse);
  });
}
