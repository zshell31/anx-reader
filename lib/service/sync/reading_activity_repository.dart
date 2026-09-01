import 'dart:convert';

import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/dao/reading_time.dart';
import 'package:anx_reader/models/reading_time.dart';
import 'package:anx_reader/service/sync/annotation_protocol.dart';
import 'package:anx_reader/service/sync/domain_stamp.dart';
import 'package:anx_reader/service/sync/library_protocol.dart';
import 'package:anx_reader/service/sync/reading_activity_protocol.dart';
import 'package:anx_reader/service/sync/shared_state_database.dart';
import 'package:uuid/uuid.dart';

abstract interface class ReadingActivityProjection {
  Future<List<ReadingTime>> legacyAggregates();
  Future<String?> fingerprintForBookId(int bookId);
  Future<void> replaceAggregate(
      String fingerprint, String day, int durationSeconds);
}

class SqliteReadingActivityProjection implements ReadingActivityProjection {
  final ReadingTimeDao readingTimes;
  final BookDao books;
  SqliteReadingActivityProjection({
    ReadingTimeDao? readingTimes,
    BookDao? books,
  })  : readingTimes = readingTimes ?? readingTimeDao,
        books = books ?? bookDao;

  @override
  Future<List<ReadingTime>> legacyAggregates() =>
      readingTimes.selectAllReadingTime();

  @override
  Future<String?> fingerprintForBookId(int bookId) async {
    try {
      return canonicalMd5Fingerprint((await books.selectBookById(bookId)).md5);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> replaceAggregate(
      String fingerprint, String day, int durationSeconds) async {
    final matches = await books.selectBooksByFingerprint(fingerprint);
    final book = matches.firstOrNull ?? await books.getBookByMd5(fingerprint);
    if (book == null) return;
    await readingTimes.replaceDailyAggregate(
      bookId: book.id,
      day: day,
      readingTime: durationSeconds,
    );
  }
}

class ReadingActivityRepository {
  static const bootstrapSource = 'reading-activity-v1';
  final SharedStateDatabase sharedState;
  final ReadingActivityProjection projection;
  final String deviceId;
  final Uuid uuid;
  final DateTime Function() now;

  ReadingActivityRepository({
    required this.sharedState,
    required this.projection,
    required this.deviceId,
    this.uuid = const Uuid(),
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;

  Future<String> recordSession({
    required String fingerprint,
    required DateTime startedAt,
    required int durationSeconds,
    String? eventId,
  }) async {
    if (durationSeconds < 0) throw ArgumentError.value(durationSeconds);
    final normalized = canonicalMd5Fingerprint(fingerprint);
    final day = startedAt.toLocal().toIso8601String().substring(0, 10);
    final id = readingActivityDocumentId(normalized, day);
    final current = await _read(id) ?? _empty(normalized, day);
    final event = <String, dynamic>{
      'eventId': eventId ?? uuid.v4(),
      'startedAt': startedAt.toUtc().toIso8601String(),
      'durationSeconds': durationSeconds,
      'deviceId': deviceId,
      'deleted': false,
      'stamp':
          DomainStamp(modifiedAt: now().toUtc(), deviceId: deviceId).toJson(),
    };
    final next = mergeReadingActivityDocuments(current, {
      ..._empty(normalized, day),
      'events': [event],
    });
    await sharedState.putCanonicalDocument(
        readingActivityDomain, id, encodeDomainDocument(next));
    await _project(next);
    return event['eventId'] as String;
  }

  Future<void> projectCanonical(String id) async {
    final document = await _read(id);
    if (document != null) await _project(document);
  }

  Future<Set<String>> deleteHistoryForFingerprints(
      Iterable<String> fingerprints) async {
    final changed = <String>{};
    final deletionStamp =
        DomainStamp(modifiedAt: now().toUtc(), deviceId: deviceId).toJson();
    for (final fingerprint in fingerprints.map(canonicalMd5Fingerprint)) {
      final prefix = '$fingerprint@';
      for (final id in await sharedState.documentIds(readingActivityDomain)) {
        if (!id.startsWith(prefix)) continue;
        final current = await _read(id);
        if (current == null) continue;
        final events = (current['events'] as List)
            .cast<Map<String, dynamic>>()
            .map((event) => {
                  ...event,
                  'deleted': true,
                  'stamp': deletionStamp,
                })
            .toList();
        final next =
            decodeReadingActivityDocument({...current, 'events': events});
        await sharedState.putCanonicalDocument(
            readingActivityDomain, id, encodeDomainDocument(next));
        await _project(next);
        changed.add(id);
      }
    }
    return changed;
  }

  Future<int> bootstrap() async {
    var imported = 0;
    for (final row in await projection.legacyAggregates()) {
      final fingerprint = await projection.fingerprintForBookId(row.bookId);
      final day = row.dateOnly;
      if (fingerprint == null || day == null || row.readingTime < 0) continue;
      final sourceKey = '$fingerprint:$day:${row.readingTime}';
      if (await sharedState.importReceipt(bootstrapSource, sourceKey) != null) {
        continue;
      }
      final eventId =
          uuid.v5(Namespace.url.value, 'anx:legacy-reading:v1:$sourceKey');
      await recordSession(
        fingerprint: fingerprint,
        startedAt: DateTime.parse('${day}T00:00:00'),
        durationSeconds: row.readingTime,
        eventId: eventId,
      );
      await sharedState.recordImport(
        source: bootstrapSource,
        sourceKey: sourceKey,
        sharedId: eventId,
        status: 'complete',
      );
      imported++;
    }
    return imported;
  }

  Future<Map<String, dynamic>?> _read(String id) async {
    final bytes =
        await sharedState.canonicalDocument(readingActivityDomain, id);
    return bytes == null
        ? null
        : decodeReadingActivityDocument(jsonDecode(utf8.decode(bytes)));
  }

  Map<String, dynamic> _empty(String fingerprint, String day) => {
        'schemaVersion': readingActivitySchemaVersion,
        'fingerprint': fingerprint,
        'day': day,
        'events': <Map<String, dynamic>>[],
      };

  Future<void> _project(Map<String, dynamic> document) async {
    final total = (document['events'] as List)
        .cast<Map<String, dynamic>>()
        .where((event) => event['deleted'] != true)
        .fold<int>(0, (sum, event) => sum + event['durationSeconds'] as int);
    await projection.replaceAggregate(
        document['fingerprint'] as String, document['day'] as String, total);
  }
}
