import 'dart:convert';

import 'package:anx_reader/models/reading_time.dart';
import 'package:anx_reader/service/sync/reading_activity_protocol.dart';
import 'package:anx_reader/service/sync/reading_activity_repository.dart';
import 'package:anx_reader/service/sync/shared_state_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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
    expect(projection.aggregates[id], 90);
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
}
