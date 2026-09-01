import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String source(String path) => File(path).readAsStringSync();

  test('startup, resume, connectivity, background, and book-open are wired',
      () {
    final main = source('lib/main.dart');
    final runtime = source('lib/service/sync/annotation_sync_runtime.dart');
    final reader = source('lib/page/reading_page.dart');

    expect(main, contains('annotationSyncRuntime.start()'));
    expect(main, contains('annotationSyncRuntime.onResume()'));
    expect(main, contains('annotationSyncRuntime.bestEffortFlush()'));
    expect(runtime, contains('onConnectivityRegained()'));
    expect(runtime, contains('Connectivity().onConnectivityChanged'));
    expect(reader, contains('annotationSyncRuntime.openBook('));
    expect(reader, contains('annotationSyncRuntime.closeBook('));
  });

  test('repository scheduling is immediate and contains no debounce timer', () {
    final repository = source('lib/service/sync/annotation_repository.dart');
    final runtime = source('lib/service/sync/annotation_sync_runtime.dart');

    expect(repository, contains('onCanonicalMutation?.call(fingerprint)'));
    expect(repository.indexOf('putAnnotationDocument(document)'),
        lessThan(repository.indexOf('onCanonicalMutation?.call(fingerprint)')));
    expect(runtime, isNot(contains('Timer(')));
  });

  test('annotation runtime is independent of legacy direction selection', () {
    final runtime = source('lib/service/sync/annotation_sync_runtime.dart');
    expect(runtime, contains("defaultAnnotationRemoteRoot = 'Lingua Reader'"));
    expect(runtime, isNot(contains('SyncDirection')));
    expect(runtime, isNot(contains('determineSyncDirection')));
    expect(runtime, isNot(contains('app_database.db')));
  });

  test('shared state configures result-returning pragmas as queries', () {
    final sharedState = source('lib/service/sync/shared_state_database.dart');

    expect(sharedState, contains("rawQuery('PRAGMA journal_mode = WAL')"));
    expect(
        sharedState, isNot(contains("execute('PRAGMA journal_mode = WAL')")));
  });

  test('open reader refresh drives the canonical Foliate renderer', () {
    final reader = source('lib/page/reading_page.dart');
    final player = source('lib/page/book_player/epub_player.dart');

    expect(reader, contains('refreshAnnotations()'));
    expect(reader, contains('ref.invalidate(bookmarkProvider'));
    expect(reader, contains('ref.invalidate(bookNotesControllerProvider'));
    expect(
        player,
        contains(
            'refreshAnnotations() => renderAnnotations(webViewController)'));
  });

  test('legacy migration remains for startup and explicit backup import', () {
    final main = source('lib/main.dart');
    final provider = source('lib/providers/sync.dart');
    final settings = source('lib/page/settings_page/sync.dart');

    expect(main, contains('Future<void> migrateLegacyAnnotations()'));
    expect(settings, contains('await migrateLegacyAnnotations()'));
    expect(provider, isNot(contains('migrateLegacyAnnotations')));
    expect(
        File('lib/service/database_sync_manager.dart').existsSync(), isFalse);
    expect(main, isNot(contains('AnnotationProjectionReconciler')));
  });
}
