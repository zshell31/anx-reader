import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anx_reader/service/sync/annotation_protocol.dart';
import 'package:anx_reader/service/sync/annotation_presentation_protocol.dart';
import 'package:anx_reader/service/sync/annotation_read_model.dart';
import 'package:anx_reader/service/sync/annotation_sync_coordinator.dart';
import 'package:anx_reader/service/sync/conditional_webdav_transport.dart';
import 'package:anx_reader/service/sync/shared_state_database.dart';
import 'package:anx_reader/service/sync/sync_diagnostics.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const fingerprint = '0123456789abcdef0123456789abcdef';
const timestamp = '2026-08-27T10:00:00.000Z';

Map<String, dynamic> entity(String id,
        {String updatedAt = timestamp,
        String? deletedAt,
        List<Map<String, dynamic>> enrichments = const []}) =>
    {
      'id': id,
      'motivation': 'selection',
      'createdAt': timestamp,
      'updatedAt': updatedAt,
      if (deletedAt != null) 'deletedAt': deletedAt,
      'target': {
        'selectedText': '$id-$updatedAt',
        'chapter': 'Chapter',
        'selectors': [
          {'type': 'epub-cfi', 'cfi': 'epubcfi(/6/2[$id])'}
        ],
      },
      'enrichments': enrichments,
    };

Map<String, dynamic> document(Iterable<Map<String, dynamic>> annotations) => {
      'schemaVersion': 2,
      'book': {
        'fingerprintAlgorithm': 'md5',
        'fingerprint': fingerprint,
      },
      'annotations': annotations.toList(),
    };

Map<String, dynamic> bookmarkEntity(String id) => {
      ...entity(id),
      'motivation': 'bookmark',
    };

Uint8List bytes(Map<String, dynamic> value) =>
    Uint8List.fromList(utf8.encode(canonicalJson(value)));

class MemoryWebDav implements AnnotationWebDavTransport {
  List<String> expectedPath = const ['annotations', '$fingerprint.json'];
  Uint8List? body;
  String? etag;
  int version = 0;
  int gets = 0;
  int puts = 0;
  int activeGets = 0;
  int maxActiveGets = 0;
  Object? getFailure;
  Object? putFailure;
  Object? lockFailure;
  Object? lockedPutFailure;
  Object? unlockFailure;
  bool conditionalCreateUnsupported = false;
  bool materializeLockPlaceholder = false;
  bool isLocked = false;
  int locks = 0;
  int unlocks = 0;
  int lockedPuts = 0;
  Future<void> Function()? onGet;
  Future<void> Function()? onPut;
  Future<void> Function()? onLock;

  void seed(Map<String, dynamic> value, {String tag = '"v1"'}) {
    body = bytes(value);
    etag = tag;
    version = int.tryParse(tag.replaceAll(RegExp('[^0-9]'), '')) ?? 1;
  }

  Map<String, dynamic>? get decoded => body == null
      ? null
      : decodeAnnotationDocument(jsonDecode(utf8.decode(body!)));

  @override
  Future<WebDavObject?> get(List<String> path) async {
    expect(path, expectedPath);
    gets++;
    activeGets++;
    if (activeGets > maxActiveGets) maxActiveGets = activeGets;
    try {
      await onGet?.call();
      if (getFailure case final failure?) throw failure;
      return body == null
          ? null
          : WebDavObject(Uint8List.fromList(body!), etag!);
    } finally {
      activeGets--;
    }
  }

  @override
  Future<WebDavWriteResult> create(List<String> path, List<int> value) async {
    puts++;
    await onPut?.call();
    if (putFailure case final failure?) throw failure;
    if (conditionalCreateUnsupported) {
      throw const WebDavPreconditionFailed();
    }
    if (body != null) throw const WebDavPreconditionFailed();
    return _write(value);
  }

  @override
  Future<WebDavWriteResult> replace(
      List<String> path, List<int> value, String strongEtag) async {
    puts++;
    await onPut?.call();
    if (putFailure case final failure?) throw failure;
    if (etag != strongEtag) throw const WebDavPreconditionFailed();
    return _write(value);
  }

  @override
  Future<WebDavLock> lock(List<String> path,
      {Duration timeout = const Duration(seconds: 45)}) async {
    locks++;
    if (lockFailure case final failure?) throw failure;
    if (isLocked) throw const WebDavLocked();
    await onLock?.call();
    final created = body == null;
    isLocked = true;
    if (created && materializeLockPlaceholder) {
      body = Uint8List(0);
      etag = '"lock-null"';
    }
    return WebDavLock('<opaquelocktoken:test>', const Duration(seconds: 45),
        created: created);
  }

  @override
  Future<WebDavWriteResult> putLocked(
      List<String> path, List<int> value, WebDavLock lock) async {
    lockedPuts++;
    if (lockedPutFailure case final failure?) throw failure;
    if (!isLocked) throw const WebDavLockPutFailed(412);
    return _write(value);
  }

  @override
  Future<void> unlock(List<String> path, WebDavLock lock) async {
    unlocks++;
    if (unlockFailure case final failure?) throw failure;
    isLocked = false;
  }

  WebDavWriteResult _write(List<int> value) {
    body = Uint8List.fromList(value);
    etag = '"v${++version}"';
    return WebDavWriteResult(etag);
  }
}

class RaceWebDavServer {
  Uint8List? body;
  String? etag;
  String? owner = 'Anx';
  int createArrivals = 0;
  int lockedCreates = 0;
  int lockConflicts = 0;
  int conditionalReplaces = 0;
  final Completer<void> createBarrier = Completer<void>();
  final Completer<void> anxMayProceed = Completer<void>();
  final Completer<void> anxUnlocked = Completer<void>();

  Future<WebDavObject?> read() async =>
      body == null ? null : WebDavObject(Uint8List.fromList(body!), etag!);

  Future<WebDavWriteResult> create() async {
    createArrivals++;
    if (createArrivals == 2) createBarrier.complete();
    await createBarrier.future;
    throw const WebDavPreconditionFailed();
  }

  Future<WebDavLock> acquire(String client) async {
    if (owner != client) {
      lockConflicts++;
      throw const WebDavLocked();
    }
    if (client == 'Anx') await anxMayProceed.future;
    return WebDavLock('<opaquelocktoken:${client.toLowerCase()}>',
        const Duration(seconds: 45),
        created: body == null);
  }

  WebDavWriteResult writeLocked(String client, List<int> value) {
    if (owner != client) throw const WebDavLockPutFailed(423);
    lockedCreates++;
    body = Uint8List.fromList(value);
    etag = '"v1"';
    return WebDavWriteResult(etag);
  }

  WebDavWriteResult replace(List<int> value, String strongEtag) {
    if (etag != strongEtag) throw const WebDavPreconditionFailed();
    conditionalReplaces++;
    body = Uint8List.fromList(value);
    etag = '"v2"';
    return WebDavWriteResult(etag);
  }

  void release(String client) {
    if (owner != client) throw const WebDavUnlockFailed(409);
    owner = null;
    if (client == 'Anx' && !anxUnlocked.isCompleted) anxUnlocked.complete();
  }
}

class RaceWebDavClient implements AnnotationWebDavTransport {
  final String name;
  final RaceWebDavServer server;
  RaceWebDavClient(this.name, this.server);

  @override
  Future<WebDavObject?> get(List<String> path) => server.read();

  @override
  Future<WebDavWriteResult> create(List<String> path, List<int> body) =>
      server.create();

  @override
  Future<WebDavWriteResult> replace(
          List<String> path, List<int> body, String strongEtag) async =>
      server.replace(body, strongEtag);

  @override
  Future<WebDavLock> lock(List<String> path,
          {Duration timeout = const Duration(seconds: 45)}) =>
      server.acquire(name);

  @override
  Future<WebDavWriteResult> putLocked(
          List<String> path, List<int> body, WebDavLock lock) async =>
      server.writeLocked(name, body);

  @override
  Future<void> unlock(List<String> path, WebDavLock lock) async =>
      server.release(name);
}

void main() {
  sqfliteFfiInit();

  late Directory directory;
  late String databasePath;
  late SharedStateDatabase store;
  late MemoryWebDav remote;
  late List<String> notifications;
  late AnnotationSyncCoordinator coordinator;

  AnnotationSyncCoordinator createCoordinator({
    int retries = 2,
    int lockRetries = 3,
    List<Duration> lockBackoff = const [],
    AnnotationLockRetryDelay? waitForLockRetry,
    SharedDocumentChanged? onDocumentChanged,
    SharedDocumentRemotePlaceholder? isRecoverableRemotePlaceholder,
    List<Duration> networkBackoff = const [],
    AnnotationRetryScheduler? scheduleRetry,
  }) =>
      AnnotationSyncCoordinator(
        sharedState: store,
        transport: remote,
        maxPreconditionRetries: retries,
        maxLockContentionRetries: lockRetries,
        lockContentionBackoff: lockBackoff,
        waitForLockRetry: waitForLockRetry,
        networkBackoff: networkBackoff,
        scheduleRetry: scheduleRetry,
        isRecoverableRemotePlaceholder: isRecoverableRemotePlaceholder,
        onDocumentChanged: onDocumentChanged ?? notifications.add,
      );

  Future<int> putLocal(Iterable<Map<String, dynamic>> values) =>
      store.putAnnotationDocument(document(values));

  Future<void> makeClean() async {
    final entry = (await store.pendingOutbox()).single;
    await store.markConverged(
        annotationSyncDomain, fingerprint, entry.localRevision,
        strongEtag: '"clean"');
  }

  Future<List<LogRecord>> captureLogs(Future<void> Function() operation) async {
    Logger.root.level = Level.ALL;
    final records = <LogRecord>[];
    final subscription = AnxLog.log.onRecord.listen(records.add);
    try {
      await runWithSyncDiagnostics('manual', (_) => operation());
      await Future<void>.delayed(Duration.zero);
      return records;
    } finally {
      await subscription.cancel();
    }
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('anx_m4d2_test_');
    databasePath = p.join(directory.path, 'shared_state.db');
    store =
        SharedStateDatabase(path: databasePath, factory: databaseFactoryFfi);
    remote = MemoryWebDav();
    notifications = [];
    coordinator = createCoordinator();
  });

  tearDown(() async {
    await coordinator.close();
    await store.close();
    await directory.delete(recursive: true);
  });

  test('dirty local and independent remote additions converge', () async {
    await putLocal([entity('A')]);
    remote.seed(document([entity('B')]));

    await coordinator.syncDirtyAnnotations();

    expect((await store.annotationDocument(fingerprint))!['annotations'],
        hasLength(2));
    expect(remote.decoded!['annotations'], hasLength(2));
    expect(await store.pendingOutbox(), isEmpty);
    expect(notifications, [fingerprint]);
  });

  test('dirty local already present remotely converges without a PUT',
      () async {
    await putLocal([entity('A')]);
    remote.seed(document([entity('A')]));

    await coordinator.syncBook(fingerprint);

    expect(remote.puts, 0);
    expect(remote.locks, 0);
    expect(await store.pendingOutbox(), isEmpty);
  });

  test('known sync does not schedule a dirty document as a second pull',
      () async {
    await putLocal([entity('A')]);
    remote.seed(document([entity('B')]));

    await coordinator.syncKnown([fingerprint]);

    expect(remote.gets, 1);
    expect(remote.decoded!['annotations'], hasLength(2));
    expect(await store.pendingOutbox(), isEmpty);
  });

  test('protocol winner resolves the same annotation edit', () async {
    await putLocal([entity('same', updatedAt: '2026-08-27T11:00:00.000Z')]);
    remote.seed(
        document([entity('same', updatedAt: '2026-08-27T12:00:00.000Z')]));

    await coordinator.syncBook(fingerprint);

    final annotation = (remote.decoded!['annotations'] as List).single as Map;
    expect(annotation['updatedAt'], '2026-08-27T12:00:00.000Z');
  });

  test('personal note and remote translation enrichment both survive',
      () async {
    Map<String, dynamic> enrichment(String id, String kind, String content) => {
          'id': id,
          'kind': kind,
          'content': content,
          'createdAt': timestamp,
          'updatedAt': timestamp,
        };
    await putLocal([
      entity('same',
          enrichments: [enrichment('personal', 'personal-note', 'mine')])
    ]);
    remote.seed(document([
      entity('same',
          enrichments: [enrichment('translation', 'translation', 'remote')])
    ]));

    await coordinator.syncBook(fingerprint);

    final annotation = (remote.decoded!['annotations'] as List).single as Map;
    expect((annotation['enrichments'] as List).map((item) => item['kind']),
        containsAll(['personal-note', 'translation']));
  });

  test('remote tombstone is sticky when document listeners run', () async {
    await putLocal([entity('A')]);
    await makeClean();
    remote.seed(document([
      entity('A',
          updatedAt: '2026-08-27T11:00:00.000Z',
          deletedAt: '2026-08-27T11:00:00.000Z')
    ]));
    Map<String, dynamic>? projected;
    await coordinator.close();
    coordinator = createCoordinator(onDocumentChanged: (id) async {
      projected = await store.annotationDocument(id);
    });

    await coordinator.pullBook(fingerprint);

    expect(((projected!['annotations'] as List).single as Map)['deletedAt'],
        isNotNull);
  });

  test('local tombstone defeats stale remote live annotation', () async {
    await putLocal([
      entity('A',
          updatedAt: '2026-08-27T11:00:00.000Z',
          deletedAt: '2026-08-27T11:00:00.000Z')
    ]);
    remote.seed(document([entity('A')]));

    await coordinator.syncBook(fingerprint);

    expect(
        ((remote.decoded!['annotations'] as List).single as Map)['deletedAt'],
        isNotNull);
  });

  test('clean pull applies remote-only update without false dirty work',
      () async {
    await putLocal([entity('A')]);
    await makeClean();
    final before =
        (await store.documentSnapshot(annotationSyncDomain, fingerprint))!
            .localRevision;
    remote.seed(document([entity('A'), entity('B')]));

    await coordinator.pullBook(fingerprint);

    final after =
        await store.documentSnapshot(annotationSyncDomain, fingerprint);
    expect(after!.localRevision, before);
    expect(after.dirty, isFalse);
    expect(remote.puts, 0, reason: 'remote-only pulls must not upload-loop');
  });

  test('clean pull skips GET when discovered strong ETag is unchanged',
      () async {
    await putLocal([entity('A')]);
    await makeClean();
    remote.seed(document([entity('A')]), tag: '"clean"');

    await coordinator.pullBook(
      fingerprint,
      discoveredStrongEtag: '"clean"',
    );

    expect(remote.gets, 0);
    expect(remote.puts, 0);
    expect(notifications, isEmpty);
  });

  test('clean pull falls back to GET when discovered ETag changed', () async {
    await putLocal([entity('A')]);
    await makeClean();
    remote.seed(document([entity('A'), entity('B')]), tag: '"changed"');

    await coordinator.pullBook(
      fingerprint,
      discoveredStrongEtag: '"changed"',
    );

    expect(remote.gets, 1);
    expect((await store.annotationDocument(fingerprint))!['annotations'],
        hasLength(2));
  });

  test('discovered matching ETag never skips dirty local work', () async {
    await putLocal([entity('A')]);
    remote.seed(document([entity('A')]), tag: '"v1"');

    await coordinator.pullBook(
      fingerprint,
      discoveredStrongEtag: '"v1"',
    );

    expect(remote.gets, 1);
    expect(await store.pendingOutbox(), isEmpty);
  });

  test('clean pull preserves remote note edits and unknown target data',
      () async {
    await putLocal([entity('A')]);
    await makeClean();
    final before =
        (await store.documentSnapshot(annotationSyncDomain, fingerprint))!
            .localRevision;
    final remoteAnnotation = entity(
      'A',
      updatedAt: '2026-08-27T12:00:00.000Z',
      enrichments: [
        {
          'id': 'personal-note:A',
          'kind': 'personal-note',
          'content': 'remote note',
          'createdAt': timestamp,
          'updatedAt': '2026-08-27T12:00:00.000Z',
        }
      ],
    );
    remoteAnnotation['futureAnnotation'] = {'preserved': true};
    final target = remoteAnnotation['target'] as Map<String, dynamic>;
    target['selectors'] = <Object?>[
      ...(target['selectors'] as List),
      {
        'type': 'future-selector',
        'payload': {'preserved': true},
      }
    ];
    remote.seed(document([remoteAnnotation]));

    await coordinator.pullBook(fingerprint);

    final snapshot =
        await store.documentSnapshot(annotationSyncDomain, fingerprint);
    final canonical = (await store.annotationDocument(fingerprint))!;
    final pulled = canonical['annotations'].single as Map<String, dynamic>;
    expect(snapshot!.localRevision, before);
    expect(snapshot.dirty, isFalse);
    expect(remote.puts, 0);
    expect(pulled['enrichments'].single['content'], 'remote note');
    expect(pulled['futureAnnotation'], {'preserved': true});
    expect(pulled['target']['selectors'], hasLength(2));
  });

  test('remote-only first discovery creates clean revision zero', () async {
    remote.seed(document([entity('remote')]));

    await coordinator.pullBook(fingerprint);

    final snapshot =
        await store.documentSnapshot(annotationSyncDomain, fingerprint);
    expect(snapshot!.localRevision, 0);
    expect(snapshot.dirty, isFalse);
    expect(remote.puts, 0);
  });

  test('remote bookmark reaches canonical document listeners', () async {
    remote.seed(document([bookmarkEntity('bookmark')]));
    String? motivation;
    await coordinator.close();
    coordinator = createCoordinator(onDocumentChanged: (id) async {
      final local = await store.annotationDocument(id);
      motivation = ((local!['annotations'] as List).single as Map)['motivation']
          as String;
    });

    await coordinator.pullBook(fingerprint);

    expect(motivation, 'bookmark');
  });

  test('missing remote is absence and clean canonical state recreates it',
      () async {
    await putLocal([entity('local')]);
    await makeClean();

    await coordinator.pullBook(fingerprint);

    expect(remote.decoded!['annotations'], hasLength(1));
    expect(remote.puts, 1);
    expect(await store.pendingOutbox(), isEmpty);
  });

  test('native If-None-Match create remains preferred and does not LOCK',
      () async {
    await putLocal([entity('A')]);

    await coordinator.syncBook(fingerprint);

    expect(remote.puts, 1);
    expect(remote.locks, 0);
    expect(remote.lockedPuts, 0);
    expect(remote.decoded!['annotations'], hasLength(1));
  });

  test('successful sync logs safe domain action and convergence result',
      () async {
    await putLocal([entity('private-annotation-content')]);

    final logs = await captureLogs(() => coordinator.syncBook(fingerprint));
    final output = logs.map((record) => record.message).join('\n');

    expect(output, contains('sync run='));
    expect(output, contains('domain=annotations'));
    expect(output, contains('action=create'));
    expect(output, contains('result=converged'));
    expect(output, contains('doc=01234567…'));
    expect(output, isNot(contains(fingerprint)));
    expect(output, isNot(contains('private-annotation-content')));
  });

  test('create 412 then re-GET finds writer and merges without LOCK', () async {
    await putLocal([entity('A')]);
    var raced = false;
    remote.onPut = () async {
      if (raced) return;
      raced = true;
      remote.seed(document([entity('B')]));
    };

    await coordinator.syncBook(fingerprint);

    expect(remote.locks, 0);
    expect(remote.puts, 2);
    expect(remote.decoded!['annotations'], hasLength(2));
  });

  test('create 412 while still absent uses LOCK, locked PUT, and UNLOCK',
      () async {
    await putLocal([entity('A')]);
    remote.conditionalCreateUnsupported = true;
    remote.materializeLockPlaceholder = true;

    await coordinator.syncBook(fingerprint);

    expect(remote.puts, 1, reason: 'only the preferred conditional PUT runs');
    expect(remote.locks, 1);
    expect(remote.lockedPuts, 1);
    expect(remote.unlocks, 1);
    expect(remote.decoded!['annotations'], hasLength(1));
    expect(await store.pendingOutbox(), isEmpty);
  });

  test('LOCK 200 reads, decodes, and merges a representation won in the race',
      () async {
    await putLocal([entity('A')]);
    remote.conditionalCreateUnsupported = true;
    remote.onLock = () async {
      remote.seed(document([entity('B')]));
    };

    await coordinator.syncBook(fingerprint);

    expect(remote.locks, 1);
    expect(remote.gets, 3,
        reason: 'the 200 LOCK path must GET while holding the lock');
    expect(remote.lockedPuts, 1);
    expect(remote.unlocks, 1);
    expect((remote.decoded!['annotations'] as List).map((item) => item['id']),
        ['A', 'B']);
  });

  test('LOCK recheck merges a representation created before lock acquisition',
      () async {
    await putLocal([entity('A')]);
    remote.conditionalCreateUnsupported = true;
    remote.lockFailure = const WebDavLocked();
    await coordinator.close();
    coordinator = createCoordinator(waitForLockRetry: (_) async {
      remote.seed(document([entity('B')]));
      remote.lockFailure = null;
    });

    await coordinator.syncBook(fingerprint);

    expect(remote.locks, 1);
    expect(remote.lockedPuts, 0);
    expect(remote.puts, 2);
    expect(remote.decoded!['annotations'], hasLength(2));
  });

  test('423 contention retries are bounded without aggressive spinning',
      () async {
    await putLocal([entity('A')]);
    remote.conditionalCreateUnsupported = true;
    remote.lockFailure = const WebDavLocked();
    final delays = <Duration>[];
    await coordinator.close();
    coordinator = createCoordinator(
        lockRetries: 2,
        lockBackoff: const [
          Duration(milliseconds: 10),
          Duration(milliseconds: 20)
        ],
        waitForLockRetry: (delay) async => delays.add(delay));

    await expectLater(
        coordinator.syncBook(fingerprint), throwsA(isA<WebDavLocked>()));

    expect(remote.locks, 3);
    expect(
        delays, const [Duration(milliseconds: 10), Duration(milliseconds: 20)]);
    expect(remote.lockedPuts, 0);
    expect((await store.pendingOutbox()).single.documentId, fingerprint);
  });

  test('locked PUT failure still attempts UNLOCK and leaves work dirty',
      () async {
    await putLocal([entity('A')]);
    remote.conditionalCreateUnsupported = true;
    remote.lockedPutFailure = const WebDavLockPutFailed(500);

    await expectLater(
        coordinator.syncBook(fingerprint), throwsA(isA<WebDavLockPutFailed>()));

    expect(remote.unlocks, 1);
    expect((await store.pendingOutbox()).single.documentId, fingerprint);
  });

  test('UNLOCK failure after successful locked PUT does not lose success',
      () async {
    await putLocal([entity('A')]);
    remote.conditionalCreateUnsupported = true;
    remote.unlockFailure = const WebDavUnlockFailed(500);

    await coordinator.syncBook(fingerprint);

    expect(remote.lockedPuts, 1);
    expect(remote.unlocks, 1);
    expect(await store.pendingOutbox(), isEmpty);
  });

  test('unsupported LOCK fails safely without unconditional PUT', () async {
    await putLocal([entity('A')]);
    remote.conditionalCreateUnsupported = true;
    remote.lockFailure = const WebDavLockUnsupported(405);

    await expectLater(coordinator.syncBook(fingerprint),
        throwsA(isA<WebDavLockUnsupported>()));

    expect(remote.puts, 1);
    expect(remote.lockedPuts, 0);
    expect((await store.pendingOutbox()).single.documentId, fingerprint);
  });

  test('Anx/Lingua first-create race converges through LOCK and 423', () async {
    await coordinator.close();
    final raceServer = RaceWebDavServer();
    coordinator = AnnotationSyncCoordinator(
      sharedState: store,
      transport: RaceWebDavClient('Anx', raceServer),
      lockContentionBackoff: const [],
    );
    final linguaPath = p.join(directory.path, 'lingua_shared_state.db');
    final linguaStore =
        SharedStateDatabase(path: linguaPath, factory: databaseFactoryFfi);
    final linguaCoordinator = AnnotationSyncCoordinator(
      sharedState: linguaStore,
      transport: RaceWebDavClient('Lingua', raceServer),
      lockContentionBackoff: const [Duration(milliseconds: 1)],
      waitForLockRetry: (_) async {
        if (!raceServer.anxMayProceed.isCompleted) {
          raceServer.anxMayProceed.complete();
        }
        await raceServer.anxUnlocked.future;
      },
    );
    try {
      await putLocal([entity('A')]);
      await linguaStore.putAnnotationDocument(document([entity('B')]));

      await Future.wait([
        coordinator.syncBook(fingerprint),
        linguaCoordinator.syncBook(fingerprint),
      ]);

      final finalDocument =
          decodeAnnotationDocument(jsonDecode(utf8.decode(raceServer.body!)));
      expect((finalDocument['annotations'] as List).map((item) => item['id']),
          ['A', 'B']);
      expect(raceServer.lockedCreates, 1);
      expect(raceServer.lockConflicts, 1);
      expect(raceServer.conditionalReplaces, 1);
      expect(await store.pendingOutbox(), isEmpty);
      expect(await linguaStore.pendingOutbox(), isEmpty);
    } finally {
      await linguaCoordinator.close();
      await linguaStore.close();
    }
  });

  test('412 rereads, merges newest representation, and retries strongly',
      () async {
    await putLocal([entity('A')]);
    remote.seed(document([entity('B')]));
    var raced = false;
    remote.onPut = () async {
      if (raced) return;
      raced = true;
      remote.seed(document([entity('B'), entity('C')]), tag: '"v2"');
    };

    await coordinator.syncBook(fingerprint);

    expect(remote.puts, 2);
    expect(remote.gets, 2);
    expect(remote.decoded!['annotations'], hasLength(3));
  });

  test('conditional conflict logs 412 retry without payload or ETag', () async {
    await putLocal([entity('local-private')]);
    remote.seed(document([entity('remote-private')]));
    var raced = false;
    remote.onPut = () async {
      if (raced) return;
      raced = true;
      remote.seed(document([entity('remote-private')]),
          tag: '"private-etag-value"');
    };

    final logs = await captureLogs(() => coordinator.syncBook(fingerprint));
    final output = logs.map((record) => record.message).join('\n');

    expect(output, contains('action=replace conflict=412 retry=1'));
    expect(output, isNot(contains('private-etag-value')));
    expect(output, isNot(contains('local-private')));
    expect(output, isNot(contains('remote-private')));
  });

  test('bounded 412 retries fall back to an exclusive LOCK', () async {
    await putLocal([entity('A')]);
    remote.seed(document([entity('B')]));
    remote.onPut = () async {
      final next = remote.version + 1;
      remote.seed(document([entity('B')]), tag: '"v$next"');
    };
    await coordinator.close();
    coordinator = createCoordinator(retries: 1);

    await coordinator.syncBook(fingerprint);

    expect(remote.puts, 2);
    expect(remote.locks, 1);
    expect(remote.lockedPuts, 1);
    expect(remote.decoded!['annotations'], hasLength(2));
    expect(await store.pendingOutbox(), isEmpty);
  });

  test('local mutation during GET is merged with current revision', () async {
    final revision = await putLocal([entity('A')]);
    remote.seed(document([entity('B')]));
    var mutated = false;
    remote.onGet = () async {
      if (mutated) return;
      mutated = true;
      expect(await putLocal([entity('A'), entity('C')]), revision + 1);
    };

    await coordinator.syncBook(fingerprint);

    expect(remote.decoded!['annotations'], hasLength(3));
    expect(await store.pendingOutbox(), isEmpty);
  });

  test('local mutation after merged persistence prevents a stale PUT',
      () async {
    final revision = await putLocal([entity('A')]);
    remote.seed(document([entity('B')]));
    var mutated = false;
    await coordinator.close();
    coordinator = createCoordinator(onDocumentChanged: (_) async {
      if (!mutated) {
        mutated = true;
        final current = (await store.annotationDocument(fingerprint))!;
        final annotations = (current['annotations'] as List)
            .cast<Map<String, dynamic>>()
            .toList()
          ..add(entity('C'));
        expect(await putLocal(annotations), revision + 1);
      }
    });

    await coordinator.syncBook(fingerprint);

    expect(remote.puts, 1,
        reason: 'the stale revision must stop before its conditional PUT');
    expect(remote.decoded!['annotations'], hasLength(3));
    expect(await store.pendingOutbox(), isEmpty);
  });

  test('local mutation during PUT leaves newer work dirty then runs it',
      () async {
    final revision = await putLocal([entity('A')]);
    remote.seed(document([entity('B')]));
    var mutated = false;
    remote.onPut = () async {
      if (mutated) return;
      mutated = true;
      expect(await putLocal([entity('A'), entity('C')]), revision + 1);
    };

    await coordinator.syncBook(fingerprint);

    expect(remote.puts, 2);
    expect(remote.decoded!['annotations'], hasLength(3));
    expect(await store.pendingOutbox(), isEmpty);
  });

  test('412 plus a concurrent local mutation rereads and merges current state',
      () async {
    final revision = await putLocal([entity('A')]);
    remote.seed(document([entity('B')]));
    var raced = false;
    remote.onPut = () async {
      if (raced) return;
      raced = true;
      expect(await putLocal([entity('A'), entity('C')]), revision + 1);
      remote.seed(document([entity('B'), entity('D')]), tag: '"v2"');
    };

    await coordinator.syncBook(fingerprint);

    expect(remote.puts, 2);
    expect(remote.gets, greaterThanOrEqualTo(2));
    expect(remote.decoded!['annotations'], hasLength(4));
    expect(await store.pendingOutbox(), isEmpty);
  });

  test('notifyDirty coalesces calls and carries the newest revision', () async {
    final revision = await putLocal([entity('A')]);
    final gate = Completer<void>();
    remote.onGet = () => gate.future;

    final first = coordinator.notifyDirty(fingerprint);
    while (remote.gets == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(await putLocal([entity('A'), entity('B')]), revision + 1);
    final notifications =
        List.generate(12, (_) => coordinator.notifyDirty(fingerprint));
    gate.complete();
    await Future.wait([first, ...notifications]);

    expect(remote.maxActiveGets, 1);
    expect(remote.decoded!['annotations'], hasLength(2));
    expect(await store.pendingOutbox(), isEmpty);
  });

  test('new notification during a failed request bypasses obsolete retry state',
      () async {
    final revision = await putLocal([entity('A')]);
    var first = true;
    remote.onGet = () async {
      if (!first) return;
      first = false;
      expect(await putLocal([entity('A'), entity('B')]), revision + 1);
      unawaited(coordinator.notifyDirty(fingerprint).catchError((_) {}));
      throw const WebDavTransportException('first request failed');
    };

    await coordinator.syncBook(fingerprint);

    expect(remote.gets, 2);
    expect(remote.decoded!['annotations'], hasLength(2));
    expect(await store.pendingOutbox(), isEmpty);
  });

  test('network failure preserves local state and a later retry converges',
      () async {
    await putLocal([entity('offline')]);
    remote.getFailure = const WebDavTransportException('offline');

    await expectLater(coordinator.syncBook(fingerprint),
        throwsA(isA<WebDavTransportException>()));
    expect((await store.pendingOutbox()).single.lastError, contains('offline'));
    expect(await coordinator.status(fingerprint),
        AnnotationSyncStatus.pendingOffline);
    expect((await store.annotationDocument(fingerprint))!['annotations'],
        hasLength(1));

    remote.getFailure = null;
    await coordinator.syncDirtyAnnotations();
    expect(remote.decoded!['annotations'], hasLength(1));
    expect(await store.pendingOutbox(), isEmpty);
  });

  test('network retry uses injectable bounded backoff', () async {
    await putLocal([entity('offline')]);
    remote.getFailure = const WebDavTransportException('offline');
    Duration? scheduledDelay;
    void Function()? retry;
    Timer? timer;
    await coordinator.close();
    coordinator = createCoordinator(
      networkBackoff: const [Duration(seconds: 3), Duration(seconds: 9)],
      scheduleRetry: (delay, callback) {
        scheduledDelay = delay;
        retry = callback;
        return timer = Timer(const Duration(days: 1), callback);
      },
    );

    await expectLater(coordinator.syncBook(fingerprint), throwsException);
    expect(scheduledDelay, const Duration(seconds: 3));

    remote.getFailure = null;
    timer!.cancel();
    retry!();
    while ((await store.pendingOutbox()).isNotEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(remote.decoded!['annotations'], hasLength(1));
  });

  test('retryable network failure logs safe scheduled retry diagnostic',
      () async {
    await putLocal([entity('secret-offline-content')]);
    remote.getFailure = const WebDavTransportException(
        'password=secret Authorization Basic credential',
        status: 503);
    Timer? timer;
    await coordinator.close();
    coordinator = createCoordinator(
      networkBackoff: const [Duration(seconds: 10)],
      scheduleRetry: (delay, callback) =>
          timer = Timer(const Duration(days: 1), callback),
    );

    final logs = await captureLogs(() async {
      await expectLater(coordinator.syncBook(fingerprint), throwsException);
    });
    timer?.cancel();
    final output = logs.map((record) => record.message).join('\n');

    expect(output, contains('retryScheduled=10s'));
    expect(output, contains('error=WebDavTransportException/http-503'));
    expect(output, isNot(contains('password')));
    expect(output, isNot(contains('Authorization')));
    expect(output, isNot(contains('Basic credential')));
    expect(output, isNot(contains('secret-offline-content')));
  });

  test('exclusive-lock diagnostics never expose lock token or local path',
      () async {
    await putLocal([entity('/private/library/book.epub')]);
    remote.conditionalCreateUnsupported = true;
    remote.materializeLockPlaceholder = true;

    final logs = await captureLogs(() => coordinator.syncBook(fingerprint));
    final output = logs.map((record) => record.message).join('\n');

    expect(output, contains('action=lock-fallback'));
    expect(output, isNot(contains('<opaquelocktoken:test>')));
    expect(output, isNot(contains('/private/library/book.epub')));
    expect(output, isNot(contains('canonicalState')));
  });

  test('authentication failure stays durable and is not aggressively retried',
      () async {
    await putLocal([entity('auth')]);
    remote.getFailure =
        const WebDavTransportException('authentication failed', status: 401);
    var scheduled = false;
    await coordinator.close();
    coordinator = createCoordinator(
      networkBackoff: const [Duration(seconds: 1)],
      scheduleRetry: (delay, callback) {
        scheduled = true;
        return Timer(delay, callback);
      },
    );

    await expectLater(coordinator.syncBook(fingerprint), throwsException);

    expect(scheduled, isFalse);
    expect(await coordinator.status(fingerprint), AnnotationSyncStatus.error);
    expect(await store.pendingOutbox(), isNotEmpty);
  });

  test('pending work survives process restart and resumes', () async {
    await putLocal([entity('restart')]);
    remote.getFailure = const WebDavTransportException('offline');
    await expectLater(coordinator.syncBook(fingerprint), throwsException);
    await coordinator.close();
    await store.close();

    store =
        SharedStateDatabase(path: databasePath, factory: databaseFactoryFfi);
    remote.getFailure = null;
    coordinator = createCoordinator();
    await coordinator.syncDirtyAnnotations();

    expect(remote.decoded!['annotations'], hasLength(1));
    expect(await store.pendingOutbox(), isEmpty);
  });

  test('malformed remote fails closed and is never overwritten', () async {
    await putLocal([entity('valid')]);
    remote.body = Uint8List.fromList(utf8.encode('{not-json'));
    remote.etag = '"bad"';

    await expectLater(coordinator.syncBook(fingerprint),
        throwsA(isA<MalformedRemoteAnnotationException>()));

    expect(utf8.decode(remote.body!), '{not-json');
    expect((await store.annotationDocument(fingerprint))!['annotations'],
        hasLength(1));
    expect(await store.pendingOutbox(), isNotEmpty);
  });

  test('explicitly recoverable empty placeholder is replaced conditionally',
      () async {
    await putLocal([entity('valid')]);
    remote.body = Uint8List(0);
    remote.etag = '"placeholder"';
    await coordinator.close();
    coordinator = createCoordinator(
      isRecoverableRemotePlaceholder: (body) => body.isEmpty,
    );

    await coordinator.syncBook(fingerprint);

    expect(remote.decoded!['annotations'], hasLength(1));
    expect(remote.puts, 1);
    expect(remote.locks, 0);
    expect(await store.pendingOutbox(), isEmpty);
  });

  test('placeholder recovery never accepts non-empty malformed content',
      () async {
    await putLocal([entity('valid')]);
    remote.body = Uint8List.fromList(utf8.encode('{not-json'));
    remote.etag = '"bad"';
    await coordinator.close();
    coordinator = createCoordinator(
      isRecoverableRemotePlaceholder: (body) => body.isEmpty,
    );

    await expectLater(coordinator.syncBook(fingerprint),
        throwsA(isA<MalformedRemoteAnnotationException>()));

    expect(utf8.decode(remote.body!), '{not-json');
    expect(remote.puts, 0);
    expect(await store.pendingOutbox(), isNotEmpty);
  });

  test('listener failure does not roll back canonical or network convergence',
      () async {
    await putLocal([entity('A')]);
    remote.seed(document([entity('B')]));
    await coordinator.close();
    coordinator = createCoordinator(
        onDocumentChanged: (_) async => throw StateError('listener failed'));

    await coordinator.syncBook(fingerprint);

    expect(remote.decoded!['annotations'], hasLength(2));
    expect((await store.annotationDocument(fingerprint))!['annotations'],
        hasLength(2));
    expect(await store.pendingOutbox(), isEmpty);
  });

  test('same-document requests are single-flight and coalesced', () async {
    await putLocal([entity('A')]);
    final gate = Completer<void>();
    remote.onGet = () => gate.future;

    final requests =
        List.generate(20, (_) => coordinator.syncBook(fingerprint));
    while (remote.gets == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(remote.gets, 1);
    expect(await coordinator.status(fingerprint), AnnotationSyncStatus.syncing);
    gate.complete();
    await Future.wait(requests);

    expect(remote.maxActiveGets, 1);
    expect(remote.puts, 1);
    expect(await coordinator.status(fingerprint), AnnotationSyncStatus.synced);
  });

  test('two Anx devices converge presentation update and reset independently',
      () async {
    await coordinator.close();
    remote.expectedPath = anxPresentationRemotePath(anxPresentationDocumentId);
    final deviceA = AnnotationSyncCoordinator(
      sharedState: store,
      transport: remote,
      syncDomain: anxPresentationSyncDomain,
      normalizeDocumentId: (_) => anxPresentationDocumentId,
      remotePathFor: anxPresentationRemotePath,
      decodeDocument: decodeAnxPresentationDocument,
      mergeDocuments: mergeAnxPresentationDocuments,
      validateDocumentId: (_, id) => id == anxPresentationDocumentId,
      networkBackoff: const [],
    );
    coordinator = deviceA;
    final deviceBPath = p.join(directory.path, 'device-b.db');
    final deviceBStore =
        SharedStateDatabase(path: deviceBPath, factory: databaseFactoryFfi);
    final deviceB = AnnotationSyncCoordinator(
      sharedState: deviceBStore,
      transport: remote,
      syncDomain: anxPresentationSyncDomain,
      normalizeDocumentId: (_) => anxPresentationDocumentId,
      remotePathFor: anxPresentationRemotePath,
      decodeDocument: decodeAnxPresentationDocument,
      mergeDocuments: mergeAnxPresentationDocuments,
      validateDocumentId: (_, id) => id == anxPresentationDocumentId,
      networkBackoff: const [],
    );
    try {
      await store.putAnnotationDocument(document([entity('semantic')]));
      final canonicalBefore =
          await store.canonicalDocument(annotationSyncDomain, fingerprint);
      await store.putAnnotationPresentation(const AnnotationPresentation(
        annotationId: 'annotation-a',
        style: AnnotationPresentationStyle.underline,
        color: 'blue',
      ));
      await deviceA.syncDirtyAnnotations();

      await deviceB.pullBook(anxPresentationDocumentId);
      expect((await deviceBStore.annotationPresentation('annotation-a'))?.color,
          'blue');
      await deviceBStore.deleteAnnotationPresentation('annotation-a');
      await deviceB.syncDirtyAnnotations();
      await deviceA.pullBook(anxPresentationDocumentId);

      expect(await store.annotationPresentation('annotation-a'), isNull);
      expect(await deviceBStore.annotationPresentation('annotation-a'), isNull);
      expect(await store.canonicalDocument(annotationSyncDomain, fingerprint),
          orderedEquals(canonicalBefore!));
      final pending = await store.pendingOutbox();
      expect(
          pending
              .singleWhere((entry) => entry.domain == annotationSyncDomain)
              .documentId,
          fingerprint);
      expect(pending.any((entry) => entry.domain == anxPresentationSyncDomain),
          isFalse);
    } finally {
      await deviceB.close();
      await deviceBStore.close();
    }
  });

  test('offline presentation failure remains in its own durable outbox',
      () async {
    await coordinator.close();
    remote.expectedPath = anxPresentationRemotePath(anxPresentationDocumentId);
    coordinator = AnnotationSyncCoordinator(
      sharedState: store,
      transport: remote,
      syncDomain: anxPresentationSyncDomain,
      normalizeDocumentId: (_) => anxPresentationDocumentId,
      remotePathFor: anxPresentationRemotePath,
      decodeDocument: decodeAnxPresentationDocument,
      mergeDocuments: mergeAnxPresentationDocuments,
      validateDocumentId: (_, id) => id == anxPresentationDocumentId,
      networkBackoff: const [],
    );
    await store.putAnnotationPresentation(const AnnotationPresentation(
      annotationId: 'annotation-a',
      style: AnnotationPresentationStyle.highlight,
      color: 'red',
    ));
    remote.getFailure = const WebDavTransportException('offline');

    final logs = await captureLogs(() async {
      await expectLater(coordinator.syncDirtyAnnotations(), completes,
          reason: 'batch sync records individual durable failures');
    });
    final output = logs.map((record) => record.message).join('\n');
    final entry = (await store.pendingOutbox()).single;
    expect(entry.domain, anxPresentationSyncDomain);
    expect(entry.attempts, 1);
    expect(await coordinator.domainStatus, AnnotationSyncStatus.pendingOffline);
    expect(output, contains('action=sync-failed'));
    expect(output, contains('error=WebDavTransportException'));
    expect(output, isNot(contains('offline')));
  });
}
