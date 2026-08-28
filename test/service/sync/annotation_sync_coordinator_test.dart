import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anx_reader/service/sync/annotation_projection_reconciler.dart';
import 'package:anx_reader/service/sync/annotation_protocol.dart';
import 'package:anx_reader/service/sync/annotation_sync_coordinator.dart';
import 'package:anx_reader/service/sync/conditional_webdav_transport.dart';
import 'package:anx_reader/service/sync/shared_state_database.dart';
import 'package:flutter_test/flutter_test.dart';
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
  Uint8List? body;
  String? etag;
  int version = 0;
  int gets = 0;
  int puts = 0;
  int activeGets = 0;
  int maxActiveGets = 0;
  Object? getFailure;
  Object? putFailure;
  Future<void> Function()? onGet;
  Future<void> Function()? onPut;

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
    expect(path, ['annotations', '$fingerprint.json']);
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

  WebDavWriteResult _write(List<int> value) {
    body = Uint8List.fromList(value);
    etag = '"v${++version}"';
    return WebDavWriteResult(etag);
  }
}

void main() {
  sqfliteFfiInit();

  late Directory directory;
  late String databasePath;
  late SharedStateDatabase store;
  late MemoryWebDav remote;
  late List<String> projections;
  late AnnotationSyncCoordinator coordinator;

  AnnotationSyncCoordinator createCoordinator({
    int retries = 2,
    Future<AnnotationReconciliationResult> Function(String)? reconcile,
    List<Duration> networkBackoff = const [],
    AnnotationRetryScheduler? scheduleRetry,
  }) =>
      AnnotationSyncCoordinator(
        sharedState: store,
        transport: remote,
        maxPreconditionRetries: retries,
        networkBackoff: networkBackoff,
        scheduleRetry: scheduleRetry,
        reconcileProjection: reconcile ??
            (id) async {
              projections.add(id);
              return AnnotationReconciliationResult();
            },
      );

  Future<int> putLocal(Iterable<Map<String, dynamic>> values) =>
      store.putAnnotationDocument(document(values));

  Future<void> makeClean() async {
    final entry = (await store.pendingOutbox()).single;
    await store.markConverged(
        annotationSyncDomain, fingerprint, entry.localRevision,
        strongEtag: '"clean"');
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('anx_m4d2_test_');
    databasePath = p.join(directory.path, 'shared_state.db');
    store =
        SharedStateDatabase(path: databasePath, factory: databaseFactoryFfi);
    remote = MemoryWebDav();
    projections = [];
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
    expect(projections, [fingerprint]);
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

  test('remote tombstone is sticky and reaches projection', () async {
    await putLocal([entity('A')]);
    await makeClean();
    remote.seed(document([
      entity('A',
          updatedAt: '2026-08-27T11:00:00.000Z',
          deletedAt: '2026-08-27T11:00:00.000Z')
    ]));
    Map<String, dynamic>? projected;
    await coordinator.close();
    coordinator = createCoordinator(reconcile: (id) async {
      projected = await store.annotationDocument(id);
      return AnnotationReconciliationResult()..deleted = 1;
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

  test('remote bookmark is materialized through projection reconciliation',
      () async {
    remote.seed(document([bookmarkEntity('bookmark')]));
    String? motivation;
    await coordinator.close();
    coordinator = createCoordinator(reconcile: (id) async {
      final local = await store.annotationDocument(id);
      motivation = ((local!['annotations'] as List).single as Map)['motivation']
          as String;
      return AnnotationReconciliationResult()..inserted = 1;
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

  test('412 retries are bounded and leave revision dirty', () async {
    await putLocal([entity('A')]);
    remote.seed(document([entity('B')]));
    remote.onPut = () async {
      final next = remote.version + 1;
      remote.seed(document([entity('B')]), tag: '"v$next"');
    };
    await coordinator.close();
    coordinator = createCoordinator(retries: 1);

    await expectLater(coordinator.syncBook(fingerprint),
        throwsA(isA<AnnotationSyncConflictException>()));

    expect(remote.puts, 2);
    expect((await store.pendingOutbox()).single.attempts, 1);
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
    coordinator = createCoordinator(reconcile: (_) async {
      if (!mutated) {
        mutated = true;
        final current = (await store.annotationDocument(fingerprint))!;
        final annotations = (current['annotations'] as List)
            .cast<Map<String, dynamic>>()
            .toList()
          ..add(entity('C'));
        expect(await putLocal(annotations), revision + 1);
      }
      return AnnotationReconciliationResult();
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

  test('projection failure does not roll back canonical or network convergence',
      () async {
    await putLocal([entity('A')]);
    remote.seed(document([entity('B')]));
    await coordinator.close();
    coordinator = createCoordinator(
        reconcile: (_) async => throw StateError('native unavailable'));

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
}
