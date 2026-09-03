import 'dart:convert';

import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/dao/reading_time.dart';
import 'package:anx_reader/models/reading_time.dart';
import 'package:anx_reader/service/sync/annotation_protocol.dart';
import 'package:anx_reader/service/sync/domain_stamp.dart';
import 'package:anx_reader/service/sync/library_protocol.dart';
import 'package:anx_reader/service/sync/reading_activity_protocol.dart';
import 'package:anx_reader/service/sync/shared_state_database.dart';
import 'package:anx_reader/service/sync/sync_diagnostics.dart';
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
  static const bootstrapReceiptSource = 'reading-activity-v2';
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
    var recognized = 0;
    var deferred = 0;
    for (final row in await projection.legacyAggregates()) {
      final fingerprint = await projection.fingerprintForBookId(row.bookId);
      final day = row.dateOnly;
      if (fingerprint == null || day == null || row.readingTime < 0) {
        deferred++;
        continue;
      }
      final daySourceKey = '$fingerprint:$day';
      if (await sharedState.importReceipt(
            bootstrapReceiptSource,
            daySourceKey,
          ) !=
          null) {
        continue;
      }
      final sourceKey = '$fingerprint:$day:${row.readingTime}';
      if (await sharedState.importReceipt(bootstrapSource, sourceKey) != null) {
        await _recordBootstrapDayReceipt(daySourceKey);
        continue;
      }
      final eventId =
          uuid.v5(Namespace.url.value, 'anx:legacy-reading:v1:$sourceKey');
      final documentId = readingActivityDocumentId(fingerprint, day);
      final current = await _read(documentId);
      final existing = current == null
          ? null
          : (current['events'] as List)
              .cast<Map<String, dynamic>>()
              .where((event) => event['eventId'] == eventId)
              .firstOrNull;
      if (existing != null) {
        if (existing['durationSeconds'] != row.readingTime) {
          throw const FormatException('legacy reading event ID collision');
        }
        await sharedState.recordImport(
          source: bootstrapSource,
          sourceKey: sourceKey,
          sharedId: eventId,
          status: 'complete',
          detail: 'already-present',
        );
        await _recordBootstrapDayReceipt(daySourceKey);
        recognized++;
        continue;
      }
      if (current != null && _liveDuration(current) == row.readingTime) {
        await sharedState.recordImport(
          source: bootstrapSource,
          sourceKey: sourceKey,
          sharedId: documentId,
          status: 'complete',
          detail: 'already-projected',
        );
        await _recordBootstrapDayReceipt(daySourceKey);
        recognized++;
        continue;
      }
      await _recordLegacyAggregate(
        fingerprint: fingerprint,
        day: day,
        durationSeconds: row.readingTime,
        eventId: eventId,
        current: current,
      );
      await sharedState.recordImport(
        source: bootstrapSource,
        sourceKey: sourceKey,
        sharedId: eventId,
        status: 'complete',
      );
      await _recordBootstrapDayReceipt(daySourceKey);
      imported++;
    }
    syncDebug('bootstrap reading-activity imported=$imported '
        'recognized=$recognized deferred=$deferred');
    if (deferred > 0) {
      syncWarning('bootstrap reading-activity deferred '
          'reason=unsupported-local-state count=$deferred');
    }
    return imported;
  }

  Future<void> _recordBootstrapDayReceipt(String sourceKey) =>
      sharedState.recordImport(
        source: bootstrapReceiptSource,
        sourceKey: sourceKey,
        status: 'complete',
      );

  int _liveDuration(Map<String, dynamic> document) =>
      (document['events'] as List)
          .cast<Map<String, dynamic>>()
          .where((event) => event['deleted'] != true)
          .fold<int>(
            0,
            (sum, event) => sum + event['durationSeconds'] as int,
          );

  Future<void> _recordLegacyAggregate({
    required String fingerprint,
    required String day,
    required int durationSeconds,
    required String eventId,
    required Map<String, dynamic>? current,
  }) async {
    final startedAt = DateTime.parse('${day}T00:00:00Z');
    final event = <String, dynamic>{
      'eventId': eventId,
      'startedAt': startedAt.toIso8601String(),
      'durationSeconds': durationSeconds,
      'deviceId': bootstrapSource,
      'deleted': false,
      'stamp': DomainStamp(
        modifiedAt: startedAt,
        deviceId: bootstrapSource,
      ).toJson(),
    };
    final next = mergeReadingActivityDocuments(
      current ?? _empty(fingerprint, day),
      {
        ..._empty(fingerprint, day),
        'events': [event],
      },
    );
    await sharedState.putCanonicalDocument(
      readingActivityDomain,
      readingActivityDocumentId(fingerprint, day),
      encodeDomainDocument(next),
    );
    await _project(next);
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
    final total = _liveDuration(document);
    await projection.replaceAggregate(
        document['fingerprint'] as String, document['day'] as String, total);
  }
}
