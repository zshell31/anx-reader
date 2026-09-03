import 'dart:convert';

import 'package:anx_reader/models/reading_time.dart';
import 'package:anx_reader/service/sync/reading_activity_protocol.dart';
import 'package:anx_reader/service/sync/reading_activity_repository.dart';
import 'package:anx_reader/service/sync/shared_state_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

const fingerprint = 'abcdef0123456789abcdef0123456789';
const eventA = '00000000-0000-4000-8000-000000000001';
const eventB = '00000000-0000-4000-8000-000000000002';

class MemoryActivityProjection implements ReadingActivityProjection {
  final List<ReadingTime> legacy;
  final Map<int, String> fingerprints;
  final Map<String, int> aggregates = {};
  MemoryActivityProjection(
      {this.legacy = const [], this.fingerprints = const {}});

  @override
  Future<String?> fingerprintForBookId(int bookId) async =>
      fingerprints[bookId];

  @override
  Future<List<ReadingTime>> legacyAggregates() async => legacy;

  @override
  Future<void> replaceAggregate(
      String fingerprint, String day, int durationSeconds) async {
    aggregates['$fingerprint@$day'] = durationSeconds;
  }
}

void main() {
  test('decode failure diagnostics never include document content', () {
    expect(
      readingActivityDecodeFailureLabel(
        const FormatException('reading event is invalid'),
      ),
      'invalid-event-fields',
    );
    expect(
      readingActivityDecodeFailureLabel(
        const FormatException('secret remote payload'),
      ),
      'invalid-document',
    );
  });

  sqfliteFfiInit();
  late SharedStateDatabase store;
  late MemoryActivityProjection projection;
  late ReadingActivityRepository repository;

  setUp(() {
    store = SharedStateDatabase(
        path: inMemoryDatabasePath, factory: databaseFactoryFfi);
    projection = MemoryActivityProjection();
    repository = ReadingActivityRepository(
      sharedState: store,
      projection: projection,
      deviceId: 'device-a',
    );
  });

  tearDown(() => store.close());

  test('two independent same-day events are unioned and projected', () async {
    final start = DateTime.parse('2025-03-04T10:00:00Z');
    await repository.recordSession(
        fingerprint: fingerprint,
        startedAt: start,
        durationSeconds: 30,
        eventId: eventA);
    await repository.recordSession(
        fingerprint: fingerprint,
        startedAt: start.add(const Duration(hours: 2)),
        durationSeconds: 45,
        eventId: eventB);
    final id = readingActivityDocumentId(fingerprint, '2025-03-04');
    final decoded = jsonDecode(utf8
        .decode((await store.canonicalDocument(readingActivityDomain, id))!));
    expect(decoded['events'], hasLength(2));
    expect(projection.aggregates[id], 75);
  });

  test('duplicate event ID does not double-count', () async {
    final start = DateTime.parse('2025-03-04T10:00:00Z');
    for (var i = 0; i < 2; i++) {
      await repository.recordSession(
          fingerprint: fingerprint,
          startedAt: start,
          durationSeconds: 30,
          eventId: eventA);
    }
    expect(projection.aggregates['$fingerprint@2025-03-04'], 30);
  });

  test('merge rejects an event ID collision with different payload', () {
    Map<String, dynamic> document(int duration) => {
          'schemaVersion': 1,
          'fingerprint': fingerprint,
          'day': '2025-03-04',
          'events': [
            {
              'eventId': eventA,
              'startedAt': '2025-03-04T10:00:00Z',
              'durationSeconds': duration,
              'deviceId': 'device-a',
            }
          ],
        };
    expect(() => mergeReadingActivityDocuments(document(10), document(20)),
        throwsFormatException);
  });

  test('old and stable legacy event shapes converge without an ID collision',
      () {
    const day = '2025-03-04';
    const duration = 90;
    final eventId = legacyReadingActivityEventId(fingerprint, day, duration);
    Map<String, dynamic> document(Map<String, dynamic> event) => {
          'schemaVersion': 1,
          'fingerprint': fingerprint,
          'day': day,
          'events': [event],
        };
    final oldShape = document({
      'eventId': eventId,
      'startedAt': '2025-03-03T21:00:00.000Z',
      'durationSeconds': duration,
      'deviceId': 'old-device',
      'deleted': false,
      'stamp': {
        'modifiedAt': '2025-03-04T08:00:00.000Z',
        'deviceId': 'old-device',
      },
    });
    final stableShape = document({
      'eventId': eventId,
      'startedAt': '2025-03-04T00:00:00.000Z',
      'durationSeconds': duration,
      'deviceId': readingActivityLegacySource,
      'deleted': false,
      'stamp': {
        'modifiedAt': '2025-03-04T00:00:00.000Z',
        'deviceId': readingActivityLegacySource,
      },
    });

    final merged = mergeReadingActivityDocuments(oldShape, stableShape);

    expect(merged['events'], hasLength(1));
    expect(merged['events'].single, stableShape['events'].single);
  });

  test('legacy normalization preserves a newer deletion stamp', () {
    const day = '2025-03-04';
    const duration = 90;
    final eventId = legacyReadingActivityEventId(fingerprint, day, duration);
    final decoded = decodeReadingActivityDocument({
      'schemaVersion': 1,
      'fingerprint': fingerprint,
      'day': day,
      'events': [
        {
          'eventId': eventId,
          'startedAt': '2025-03-03T21:00:00.000Z',
          'durationSeconds': duration,
          'deviceId': 'old-device',
          'deleted': true,
          'stamp': {
            'modifiedAt': '2025-03-05T10:00:00.000Z',
            'deviceId': 'deleting-device',
          },
        }
      ],
    });
    final event = decoded['events'].single as Map<String, dynamic>;

    expect(event['startedAt'], '2025-03-04T00:00:00.000Z');
    expect(event['deviceId'], readingActivityLegacySource);
    expect(event['deleted'], isTrue);
    expect(event['stamp'], {
      'modifiedAt': '2025-03-05T10:00:00.000Z',
      'deviceId': 'deleting-device',
    });
  });

  test('single legacy-only aggregate remains as the day history', () {
    const day = '2025-03-04';
    const duration = 90;
    final eventId = legacyReadingActivityEventId(fingerprint, day, duration);

    final decoded = decodeReadingActivityDocument({
      'schemaVersion': 1,
      'fingerprint': fingerprint,
      'day': day,
      'events': [
        {
          'eventId': eventId,
          'startedAt': '2025-03-03T21:00:00.000Z',
          'durationSeconds': duration,
          'deviceId': 'old-device',
          'stamp': {
            'modifiedAt': '2025-03-04T08:00:00.000Z',
            'deviceId': 'old-device',
          },
        }
      ],
    });

    expect(decoded['events'], hasLength(1));
    expect(decoded['events'].single['durationSeconds'], duration);
  });

  test('legacy feedback cascade collapses to its original baseline', () {
    const day = '2025-03-04';
    Map<String, dynamic> legacy(int duration, String importedAt) => {
          'eventId': legacyReadingActivityEventId(fingerprint, day, duration),
          'startedAt': '2025-03-03T21:00:00.000Z',
          'durationSeconds': duration,
          'deviceId': 'old-device',
          'stamp': {
            'modifiedAt': importedAt,
            'deviceId': 'old-device',
          },
        };
    final decoded = decodeReadingActivityDocument({
      'schemaVersion': 1,
      'fingerprint': fingerprint,
      'day': day,
      'events': [
        legacy(2758, '2025-03-04T09:00:00Z'),
        {
          'eventId': eventA,
          'startedAt': '2025-03-04T09:30:00Z',
          'durationSeconds': 27,
          'deviceId': 'device-a',
          'stamp': {
            'modifiedAt': '2025-03-04T09:31:00Z',
            'deviceId': 'device-a',
          },
        },
        legacy(2785, '2025-03-04T10:00:00Z'),
        legacy(5570, '2025-03-04T11:00:00Z'),
      ],
    });
    final events = (decoded['events'] as List).cast<Map<String, dynamic>>();

    expect(events, hasLength(2));
    expect(
      events
          .where((event) => event['eventId'] == eventA)
          .single['durationSeconds'],
      27,
    );
    expect(
      events
          .where((event) => event['eventId'] != eventA)
          .single['durationSeconds'],
      2758,
    );
  });

  test('legacy cascade already covered by real sessions is removed', () {
    const day = '2025-03-04';
    Map<String, dynamic> real(String id, int duration, String completedAt) => {
          'eventId': id,
          'startedAt': completedAt,
          'durationSeconds': duration,
          'deviceId': 'device-a',
          'stamp': {'modifiedAt': completedAt, 'deviceId': 'device-a'},
        };
    Map<String, dynamic> legacy(int duration, String importedAt) => {
          'eventId': legacyReadingActivityEventId(fingerprint, day, duration),
          'startedAt': '2025-03-03T21:00:00.000Z',
          'durationSeconds': duration,
          'deviceId': 'old-device',
          'stamp': {
            'modifiedAt': importedAt,
            'deviceId': 'old-device',
          },
        };
    final decoded = decodeReadingActivityDocument({
      'schemaVersion': 1,
      'fingerprint': fingerprint,
      'day': day,
      'events': [
        real(eventA, 100, '2025-03-04T09:00:00Z'),
        legacy(100, '2025-03-04T09:01:00Z'),
        real(eventB, 200, '2025-03-04T10:00:00Z'),
        legacy(300, '2025-03-04T10:01:00Z'),
        legacy(600, '2025-03-04T11:00:00Z'),
      ],
    });
    final events = (decoded['events'] as List).cast<Map<String, dynamic>>();

    expect(events.map((event) => event['eventId']), {eventA, eventB});
    expect(
      events.fold<int>(
          0, (sum, event) => sum + event['durationSeconds'] as int),
      300,
    );
    expect(
      decodeReadingActivityDocument(decoded),
      decoded,
      reason: 'cleanup must be canonical and idempotent',
    );
  });

  test('bootstrap persists cascade cleanup once and queues WebDAV repair',
      () async {
    const day = '2025-03-04';
    final id = readingActivityDocumentId(fingerprint, day);
    Map<String, dynamic> legacy(int duration) => {
          'eventId': legacyReadingActivityEventId(fingerprint, day, duration),
          'startedAt': '2025-03-04T00:00:00.000Z',
          'durationSeconds': duration,
          'deviceId': readingActivityLegacySource,
          'deleted': false,
          'stamp': {
            'modifiedAt': '2025-03-04T00:00:00.000Z',
            'deviceId': readingActivityLegacySource,
          },
        };
    final stale = {
      'schemaVersion': 1,
      'fingerprint': fingerprint,
      'day': day,
      'events': [
        {
          'eventId': eventA,
          'startedAt': '2025-03-04T09:00:00Z',
          'durationSeconds': 30,
          'deviceId': 'device-a',
          'deleted': false,
          'stamp': {
            'modifiedAt': '2025-03-04T09:00:30Z',
            'deviceId': 'device-a',
          },
        },
        legacy(30),
        legacy(60),
        legacy(120),
      ],
    };
    await store.putCanonicalDocument(
      readingActivityDomain,
      id,
      utf8.encode(jsonEncode(stale)),
    );
    await store.markConverged(readingActivityDomain, id, 1,
        strongEtag: '"before-cleanup"');

    expect(await repository.bootstrap(), 0);
    final first = await store.documentSnapshot(readingActivityDomain, id);
    final cleaned = jsonDecode(utf8.decode(first!.canonicalState));
    expect(cleaned['events'], hasLength(1));
    expect(cleaned['events'].single['eventId'], eventA);
    expect(first.localRevision, 2);
    expect(first.dirty, isTrue);
    expect(projection.aggregates[id], 30);

    expect(await repository.bootstrap(), 0);
    final second = await store.documentSnapshot(readingActivityDomain, id);
    expect(second!.localRevision, first.localRevision);
    expect((await store.pendingOutbox()), hasLength(1));
  });

  test('legacy aggregate import has deterministic identity and is idempotent',
      () async {
    projection = MemoryActivityProjection(
      legacy: [
        ReadingTime(id: 9, bookId: 7, date: '2025-05-06', readingTime: 90)
      ],
      fingerprints: const {7: fingerprint},
    );
    repository = ReadingActivityRepository(
      sharedState: store,
      projection: projection,
      deviceId: 'device-a',
    );
    expect(await repository.bootstrap(), 1);
    expect(await repository.bootstrap(), 0);
    final id = readingActivityDocumentId(fingerprint, '2025-05-06');
    final decoded = jsonDecode(utf8
        .decode((await store.canonicalDocument(readingActivityDomain, id))!));
    expect(decoded['events'], hasLength(1));
    expect(decoded['events'].single['deviceId'],
        ReadingActivityRepository.bootstrapSource);
    expect(decoded['events'].single['startedAt'], '2025-05-06T00:00:00.000Z');
    expect(projection.aggregates[id], 90);
  });

  test('projected daily total is not reimported as another legacy event',
      () async {
    final legacyRow =
        ReadingTime(id: 9, bookId: 7, date: '2025-05-06', readingTime: 90);
    projection = MemoryActivityProjection(
      legacy: [legacyRow],
      fingerprints: const {7: fingerprint},
    );
    repository = ReadingActivityRepository(
      sharedState: store,
      projection: projection,
      deviceId: 'device-a',
    );

    expect(await repository.bootstrap(), 1);
    await repository.recordSession(
      fingerprint: fingerprint,
      startedAt: DateTime.parse('2025-05-06T10:00:00Z'),
      durationSeconds: 30,
      eventId: eventA,
    );
    legacyRow.readingTime = 120;

    // Simulate a restart after the canonical projection updated the mutable
    // aggregate in the legacy database.
    repository = ReadingActivityRepository(
      sharedState: store,
      projection: projection,
      deviceId: 'device-a',
    );
    expect(await repository.bootstrap(), 0);
    expect(await repository.bootstrap(), 0);

    final id = readingActivityDocumentId(fingerprint, '2025-05-06');
    final decoded = jsonDecode(utf8
        .decode((await store.canonicalDocument(readingActivityDomain, id))!));
    expect(decoded['events'], hasLength(2));
    expect(projection.aggregates[id], 120);
    expect(
      await store.importReceipt(
        ReadingActivityRepository.bootstrapReceiptSource,
        '$fingerprint:2025-05-06',
      ),
      isNotNull,
    );
  });

  test('legacy import recognizes an event created by another device', () async {
    final legacy = [
      ReadingTime(id: 9, bookId: 7, date: '2025-05-06', readingTime: 90)
    ];
    const sourceKey = '$fingerprint:2025-05-06:90';
    final legacyEventId = const Uuid().v5(
      Namespace.url.value,
      'anx:legacy-reading:v1:$sourceKey',
    );
    repository = ReadingActivityRepository(
      sharedState: store,
      projection: MemoryActivityProjection(),
      deviceId: 'device-a',
    );
    await repository.recordSession(
      fingerprint: fingerprint,
      startedAt: DateTime.parse('2025-05-06T00:00:00Z'),
      durationSeconds: 90,
      eventId: legacyEventId,
    );

    repository = ReadingActivityRepository(
      sharedState: store,
      projection: MemoryActivityProjection(
        legacy: legacy,
        fingerprints: const {7: fingerprint},
      ),
      deviceId: 'device-b',
    );

    expect(await repository.bootstrap(), 0);
    final receipt = await store.importReceipt(
      ReadingActivityRepository.bootstrapSource,
      sourceKey,
    );
    expect(receipt?.status, 'complete');
    expect(receipt?.detail, 'already-present');
    final id = readingActivityDocumentId(fingerprint, '2025-05-06');
    final decoded = jsonDecode(utf8
        .decode((await store.canonicalDocument(readingActivityDomain, id))!));
    expect(decoded['events'], hasLength(1));
    expect(decoded['events'].single['deviceId'],
        ReadingActivityRepository.bootstrapSource);
  });

  test('legacy import does not resurrect an event deleted on another device',
      () async {
    final legacy = [
      ReadingTime(id: 9, bookId: 7, date: '2025-05-06', readingTime: 90)
    ];
    projection = MemoryActivityProjection(
      legacy: legacy,
      fingerprints: const {7: fingerprint},
    );
    repository = ReadingActivityRepository(
      sharedState: store,
      projection: projection,
      deviceId: 'device-a',
    );
    expect(await repository.bootstrap(), 1);
    expect(await repository.deleteHistoryForFingerprints([fingerprint]),
        {'$fingerprint@2025-05-06'});

    await (await store.database).delete('legacy_import_receipts');
    repository = ReadingActivityRepository(
      sharedState: store,
      projection: MemoryActivityProjection(
        legacy: legacy,
        fingerprints: const {7: fingerprint},
      ),
      deviceId: 'device-b',
    );

    expect(await repository.bootstrap(), 0);
    final id = readingActivityDocumentId(fingerprint, '2025-05-06');
    final decoded = jsonDecode(utf8
        .decode((await store.canonicalDocument(readingActivityDomain, id))!));
    expect(decoded['events'], hasLength(1));
    expect(decoded['events'].single['deleted'], isTrue);
  });

  test('remote union projection recomputes statistics rather than LWW',
      () async {
    final id = readingActivityDocumentId(fingerprint, '2025-06-07');
    final document = decodeReadingActivityDocument({
      'schemaVersion': 1,
      'fingerprint': fingerprint,
      'day': '2025-06-07',
      'events': [
        {
          'eventId': eventA,
          'startedAt': '2025-06-07T10:00:00Z',
          'durationSeconds': 12,
          'deviceId': 'a',
        },
        {
          'eventId': eventB,
          'startedAt': '2025-06-07T11:00:00Z',
          'durationSeconds': 18,
          'deviceId': 'b',
        },
      ],
    });
    await store.applyRemoteMerge(
        readingActivityDomain, id, null, utf8.encode(jsonEncode(document)));
    await repository.projectCanonical(id);
    expect(projection.aggregates[id], 30);
  });

  test('history deletion tombstones events and defeats a stale live replica',
      () async {
    final startedAt = DateTime.parse('2025-07-08T10:00:00Z');
    await repository.recordSession(
      fingerprint: fingerprint,
      startedAt: startedAt,
      durationSeconds: 40,
      eventId: eventA,
    );
    final id = readingActivityDocumentId(fingerprint, '2025-07-08');
    final stale = decodeReadingActivityDocument(jsonDecode(utf8
        .decode((await store.canonicalDocument(readingActivityDomain, id))!)));
    expect(await repository.deleteHistoryForFingerprints([fingerprint]), {id});
    final deleted = decodeReadingActivityDocument(jsonDecode(utf8
        .decode((await store.canonicalDocument(readingActivityDomain, id))!)));
    final merged = mergeReadingActivityDocuments(deleted, stale);
    expect((merged['events'] as List).single['deleted'], isTrue);
    expect(projection.aggregates[id], 0);
    expect(await store.outboxEntry(readingActivityDomain, id), isNotNull);
  });
}
