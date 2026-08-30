import 'dart:convert';
import 'dart:io';

import 'package:anx_reader/service/sync/annotation_read_model.dart';
import 'package:anx_reader/service/sync/annotation_presentation_protocol.dart';
import 'package:anx_reader/service/sync/shared_state_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const fingerprint = '0123456789abcdef0123456789abcdef';

Map<String, dynamic> annotationDocument() => {
      'schemaVersion': 2,
      'book': {
        'fingerprintAlgorithm': 'md5',
        'fingerprint': fingerprint,
      },
      'annotations': <Object>[],
    };

Future<Directory> temporaryDirectory() =>
    Directory.systemTemp.createTemp('anx_shared_state_test_');

void main() {
  sqfliteFfiInit();

  group('revision-safe outbox', () {
    late Directory directory;
    late SharedStateDatabase store;

    setUp(() async {
      directory = await temporaryDirectory();
      store = SharedStateDatabase(
          path: p.join(directory.path, 'shared_state.db'),
          factory: databaseFactoryFfi);
    });

    tearDown(() async {
      await store.close();
      await directory.delete(recursive: true);
    });

    test('an older successful sync cannot clear a newer local revision',
        () async {
      final revisionA = await store.putCanonicalDocument(
          'test', 'document', utf8.encode('A'));
      final workA = await store.beginSync('test', 'document', revisionA);

      // The claim transaction has ended, so an offline write can commit while
      // revision A is conceptually in network I/O.
      final revisionB = await store.putCanonicalDocument(
          'test', 'document', utf8.encode('B'));
      expect(revisionB, revisionA + 1);
      expect(utf8.decode(workA!.canonicalState), 'A');

      expect(
          await store.markConverged('test', 'document', revisionA,
              strongEtag: '"remote-a"'),
          isFalse);
      final pending = await store.pendingOutbox();
      expect(pending, hasLength(1));
      expect(pending.single.localRevision, revisionB);
      expect((await store.syncMetadata('test', 'document'))!.status,
          SharedSyncStatus.pending);

      final workB = await store.beginSync('test', 'document', revisionB);
      expect(utf8.decode(workB!.canonicalState), 'B');
      expect(workB.strongEtag, '"remote-a"');
      expect(
          await store.markConverged('test', 'document', revisionB,
              strongEtag: '"remote-b"'),
          isTrue);
      expect(await store.pendingOutbox(), isEmpty);
      final metadata = await store.syncMetadata('test', 'document');
      expect(metadata!.status, SharedSyncStatus.synced);
      expect(metadata.strongEtag, '"remote-b"');
      expect(metadata.remoteRevision, revisionB);
    });

    test('multiple mutations and stale failure target exact revisions',
        () async {
      final revisionA =
          await store.putCanonicalDocument('test', 'document', [1]);
      await store.beginSync('test', 'document', revisionA);
      final revisionB =
          await store.putCanonicalDocument('test', 'document', [2]);
      final revisionC =
          await store.putCanonicalDocument('test', 'document', [3]);

      expect(
          await store.recordFailure(
              'test', 'document', revisionA, StateError('old failure')),
          isFalse);
      expect(await store.markConverged('test', 'document', revisionB), isFalse);
      final pending = (await store.pendingOutbox()).single;
      expect(pending.localRevision, revisionC);
      expect(pending.attempts, 0);
      expect(pending.lastError, isNull);
    });

    test('retry metadata applies only to the current revision', () async {
      final revision =
          await store.putCanonicalDocument('test', 'document', [1]);
      await store.beginSync('test', 'document', revision);
      expect(
          await store.recordFailure(
              'test', 'document', revision, StateError('offline')),
          isTrue);
      var pending = (await store.pendingOutbox()).single;
      expect(pending.attempts, 1);
      expect(pending.lastError, contains('offline'));
      expect((await store.syncMetadata('test', 'document'))!.status,
          SharedSyncStatus.error);

      final retry = await store.beginSync('test', 'document', revision);
      expect(retry!.attempts, 1);
      final nextRevision =
          await store.putCanonicalDocument('test', 'document', [2]);
      expect(
          await store.recordFailure(
              'test', 'document', revision, StateError('stale')),
          isFalse);
      pending = (await store.pendingOutbox()).single;
      expect(pending.localRevision, nextRevision);
      expect(pending.attempts, 0);
      expect(pending.lastError, isNull);
    });

    test('canonical mutation and dirty revision roll back atomically',
        () async {
      final revision = await store.putCanonicalDocument(
          'test', 'document', utf8.encode('original'));
      await (await store.database)
          .execute('''CREATE TRIGGER reject_outbox_update
        BEFORE UPDATE ON sync_outbox
        BEGIN
          SELECT RAISE(ABORT, 'outbox write rejected');
        END''');

      await expectLater(
          store.putCanonicalDocument(
              'test', 'document', utf8.encode('must roll back')),
          throwsA(isA<DatabaseException>()));
      expect(utf8.decode((await store.canonicalDocument('test', 'document'))!),
          'original');
      expect((await store.pendingOutbox()).single.localRevision, revision);
    });

    test('remote merge preserves revision and existing dirty work', () async {
      final revision = await store.putAnnotationDocument(annotationDocument());
      final changed = await store.applyRemoteMerge(
        'annotations',
        fingerprint,
        revision,
        utf8.encode('{"remote":"merged"}'),
        strongEtag: '"v1"',
      );

      expect(changed, isTrue);
      final snapshot = await store.documentSnapshot('annotations', fingerprint);
      expect(snapshot!.localRevision, revision);
      expect(snapshot.dirty, isTrue);
      expect((await store.pendingOutbox()).single.localRevision, revision);
    });

    test('stale remote compare-and-set cannot overwrite newer mutation',
        () async {
      final revision = await store.putAnnotationDocument(annotationDocument());
      final next = await store.putAnnotationDocument(annotationDocument());

      expect(
          await store.applyRemoteMerge('annotations', fingerprint, revision,
              utf8.encode('{"stale":true}')),
          isFalse);
      final snapshot = await store.documentSnapshot('annotations', fingerprint);
      expect(snapshot!.localRevision, next);
      expect(utf8.decode(snapshot.canonicalState), isNot(contains('stale')));
    });
  });

  group('physical restart persistence', () {
    late Directory directory;
    late String path;
    SharedStateDatabase? openStore;

    setUp(() async {
      directory = await temporaryDirectory();
      path = p.join(directory.path, 'shared_state.db');
    });

    tearDown(() async {
      await openStore?.close();
      await directory.delete(recursive: true);
    });

    SharedStateDatabase reopen() => openStore =
        SharedStateDatabase(path: path, factory: databaseFactoryFfi);

    test('canonical state, dirty revision, and failure survive restart',
        () async {
      var store = reopen();
      final revision = await store.putAnnotationDocument(annotationDocument());
      await store.beginSync('annotations', fingerprint, revision);
      await store.recordFailure(
          'annotations', fingerprint, revision, StateError('network down'));
      await store.close();
      openStore = null;

      store = reopen();
      expect(
          (await store.annotationDocument(fingerprint))!['schemaVersion'], 2);
      final pending = (await store.pendingOutbox()).single;
      expect(pending.localRevision, revision);
      expect(pending.attempts, 1);
      expect(pending.lastError, contains('network down'));
      expect((await store.syncMetadata('annotations', fingerprint))!.status,
          SharedSyncStatus.error);
    });

    test('successful convergence survives restart', () async {
      var store = reopen();
      final revision = await store.putAnnotationDocument(annotationDocument());
      await store.beginSync('annotations', fingerprint, revision);
      await store.markConverged('annotations', fingerprint, revision,
          strongEtag: '"v1"');
      await store.close();
      openStore = null;

      store = reopen();
      expect(await store.pendingOutbox(), isEmpty);
      final metadata = await store.syncMetadata('annotations', fingerprint);
      expect(metadata!.status, SharedSyncStatus.synced);
      expect(metadata.strongEtag, '"v1"');
      expect(metadata.lastSyncedAt, isNotNull);
    });

    test('an interrupted syncing state recovers to pending', () async {
      var store = reopen();
      final revision = await store.putAnnotationDocument(annotationDocument());
      expect(
          (await store.beginSync('annotations', fingerprint, revision))!
              .localRevision,
          revision);
      expect((await store.syncMetadata('annotations', fingerprint))!.status,
          SharedSyncStatus.syncing);
      await store.close();
      openStore = null;

      store = reopen();
      expect((await store.syncMetadata('annotations', fingerprint))!.status,
          SharedSyncStatus.pending);
      expect(await store.beginSync('annotations', fingerprint, revision),
          isNotNull);
    });

    test('shared state is physically independent from the app database',
        () async {
      final appPath = p.join(directory.path, 'app_database.db');
      final appDatabase = await databaseFactoryFfi.openDatabase(appPath);
      await appDatabase.execute(
          'CREATE TABLE app_sentinel (id INTEGER PRIMARY KEY, value TEXT)');
      await appDatabase.insert('app_sentinel', {'id': 1, 'value': 'app'});
      await appDatabase.close();

      final store = reopen();
      await store.putCanonicalDocument('test', 'document', [1, 2, 3]);
      expect(File(path).existsSync(), isTrue);
      expect(File(appPath).existsSync(), isTrue);
      expect(path, isNot(appPath));

      final reopenedApp = await databaseFactoryFfi.openDatabase(appPath);
      expect((await reopenedApp.query('app_sentinel')).single['value'], 'app');
      expect(
          (await reopenedApp.rawQuery(
                  "SELECT name FROM sqlite_master WHERE name = 'shared_documents'"))
              .isEmpty,
          isTrue);
      await reopenedApp.close();
    });
  });

  group('shared-state schema', () {
    late Directory directory;

    setUp(() async => directory = await temporaryDirectory());
    tearDown(() async => directory.delete(recursive: true));

    test('fresh creation and reopening retain explicit schema v3', () async {
      final path = p.join(directory.path, 'shared_state.db');
      var store = SharedStateDatabase(path: path, factory: databaseFactoryFfi);
      expect(await store.schemaVersion, 3);
      final tables = await (await store.database).rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name");
      expect(
          tables.map((row) => row['name']),
          containsAll([
            'shared_documents',
            'sync_outbox',
            'sync_metadata',
            'legacy_import_receipts',
            'annotation_projections',
            'annotation_presentations',
          ]));
      await store.close();

      store = SharedStateDatabase(path: path, factory: databaseFactoryFfi);
      expect(await store.schemaVersion, 3);
      await store.close();
    });

    test('ordered migration callbacks are executable and testable', () async {
      final path = p.join(directory.path, 'migration.db');
      var store = SharedStateDatabase(
          path: path,
          factory: databaseFactoryFfi,
          schema: const SharedStateSchema());
      await store.database;
      await store.close();

      var callbackRan = false;
      store = SharedStateDatabase(
          path: path,
          factory: databaseFactoryFfi,
          schema: SharedStateSchema(version: 2, migrations: {
            2: (db) async {
              callbackRan = true;
            },
          }));
      expect(await store.schemaVersion, 2);
      expect(callbackRan, isTrue);
      await store.close();
    });

    test('a newer unsupported schema fails safely', () async {
      final path = p.join(directory.path, 'newer.db');
      const schema = SharedStateSchema();
      final newer = await databaseFactoryFfi.openDatabase(path,
          options: OpenDatabaseOptions(
              version: 4, onCreate: (db, _) => schema.create(db)));
      await newer.close();

      final store =
          SharedStateDatabase(path: path, factory: databaseFactoryFfi);
      await expectLater(store.database, throwsA(isA<UnsupportedError>()));
    });
  });

  group('annotation presentation sidecar', () {
    late Directory directory;
    late SharedStateDatabase store;

    setUp(() async {
      directory = await temporaryDirectory();
      store = SharedStateDatabase(
          path: p.join(directory.path, 'shared_state.db'),
          factory: databaseFactoryFfi);
    });

    tearDown(() async {
      await store.close();
      await directory.delete(recursive: true);
    });

    test('persists UUID-keyed presentation across reopen', () async {
      const presentation = AnnotationPresentation(
        annotationId: 'annotation-a',
        style: AnnotationPresentationStyle.underline,
        color: '00ff00',
      );
      expect(await store.annotationPresentation('annotation-a'), isNull);
      expect(await store.putAnnotationPresentation(presentation), isTrue);
      expect(await store.putAnnotationPresentation(presentation), isFalse);
      await store.close();

      store = SharedStateDatabase(
          path: p.join(directory.path, 'shared_state.db'),
          factory: databaseFactoryFfi);
      final restored = await store.annotationPresentation('annotation-a');
      expect(restored?.style, AnnotationPresentationStyle.underline);
      expect(restored?.color, '00ff00');
      expect((await store.annotationPresentations()).keys, ['annotation-a']);
    });

    test('presentation writes never change canonical bytes or dirty revision',
        () async {
      await store.putAnnotationDocument(annotationDocument());
      final before = await store.canonicalDocument('annotations', fingerprint);
      final outbox = (await store.pendingOutbox())
          .singleWhere((entry) => entry.domain == 'annotations');

      await store.putAnnotationPresentation(const AnnotationPresentation(
        annotationId: 'annotation-a',
        style: AnnotationPresentationStyle.highlight,
        color: '66CCFF',
      ));

      expect(await store.canonicalDocument('annotations', fingerprint),
          orderedEquals(before!));
      final entries = await store.pendingOutbox();
      final after =
          entries.singleWhere((entry) => entry.domain == 'annotations');
      expect(after.localRevision, outbox.localRevision);
      expect(after.attempts, outbox.attempts);
      expect(
          entries.singleWhere(
              (entry) => entry.domain == anxPresentationSyncDomain),
          isNotNull);
    });

    test('v1 migration adds the sidecar without changing canonical state',
        () async {
      final path = p.join(directory.path, 'migration.db');
      var legacy = SharedStateDatabase(
          path: path,
          factory: databaseFactoryFfi,
          schema: const SharedStateSchema());
      await legacy.putAnnotationDocument(annotationDocument());
      final before = await legacy.canonicalDocument('annotations', fingerprint);
      await legacy.close();

      legacy = SharedStateDatabase(path: path, factory: databaseFactoryFfi);
      expect(await legacy.schemaVersion, 3);
      expect(await legacy.annotationPresentations(), isEmpty);
      expect(await legacy.canonicalDocument('annotations', fingerprint),
          orderedEquals(before!));
      await legacy.close();
    });

    test('v2 sidecar migrates to dirty synchronized presentation document',
        () async {
      final path = p.join(directory.path, 'v2-presentation.db');
      var legacy = SharedStateDatabase(
        path: path,
        factory: databaseFactoryFfi,
        schema: SharedStateSchema(
          version: 2,
          migrations: {2: currentSharedStateSchema.migrations[2]!},
        ),
      );
      final database = await legacy.database;
      await database.insert('annotation_presentations', {
        'annotation_id': 'annotation-a',
        'style': 'underline',
        'color': '00ff00',
      });
      await legacy.close();

      legacy = SharedStateDatabase(path: path, factory: databaseFactoryFfi);
      expect(await legacy.schemaVersion, 3);
      final migrated = await legacy.annotationPresentation('annotation-a');
      expect(migrated?.style, AnnotationPresentationStyle.underline);
      expect(migrated?.color, '00ff00');
      final outbox = (await legacy.pendingOutbox()).single;
      expect(outbox.domain, anxPresentationSyncDomain);
      expect(outbox.documentId, anxPresentationDocumentId);
      await legacy.close();
    });

    test('reset is durable, independently dirty, and restores defaults',
        () async {
      await store.putAnnotationPresentation(const AnnotationPresentation(
        annotationId: 'annotation-a',
        style: AnnotationPresentationStyle.highlight,
        color: 'red',
      ));
      expect(await store.deleteAnnotationPresentation('annotation-a'), isTrue);
      expect(await store.deleteAnnotationPresentation('annotation-a'), isFalse);
      expect(await store.deleteAnnotationPresentation('remote-unknown'), isTrue,
          reason: 'reset must suppress an explicit value not yet pulled');
      expect(await store.annotationPresentation('annotation-a'), isNull);
      await store.close();

      store = SharedStateDatabase(
          path: p.join(directory.path, 'shared_state.db'),
          factory: databaseFactoryFfi);
      expect(await store.annotationPresentation('annotation-a'), isNull);
      final bytes = await store.canonicalDocument(
          anxPresentationSyncDomain, anxPresentationDocumentId);
      final document =
          decodeAnxPresentationDocument(jsonDecode(utf8.decode(bytes!)));
      expect((document['presentations'] as List),
          everyElement(contains('resetAt')));
      expect((await store.pendingOutbox()).single.domain,
          anxPresentationSyncDomain);
    });
  });
}
