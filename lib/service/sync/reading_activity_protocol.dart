import 'package:anx_reader/service/sync/annotation_protocol.dart';
import 'package:anx_reader/service/sync/domain_stamp.dart';

const readingActivityDomain = 'reading-activity';
const readingActivitySchemaVersion = 1;
const readingActivityLegacySource = 'reading-activity-v1';

String legacyReadingActivityEventId(
        String fingerprint, String day, int durationSeconds) =>
    deterministicMigrationUuid(
      'anx:legacy-reading:v1:'
      '${canonicalMd5Fingerprint(fingerprint)}:$day:$durationSeconds',
    );

String readingActivityDocumentId(String fingerprint, String day) =>
    '${canonicalMd5Fingerprint(fingerprint)}@$day';

List<String> readingActivityRemotePath(String documentId) {
  final parts = documentId.split('@');
  if (parts.length != 2 || !_validDay(parts[1])) {
    throw const FormatException('invalid reading-activity document id');
  }
  return ['shared', 'v1', 'reading-activity', parts[0], '${parts[1]}.json'];
}

Map<String, dynamic> decodeReadingActivityDocument(Object? input) {
  if (input is! Map) {
    throw const FormatException('reading activity must be an object');
  }
  final doc = Map<String, dynamic>.from(input);
  if (doc['schemaVersion'] != readingActivitySchemaVersion) {
    throw const FormatException('unsupported reading-activity schema');
  }
  doc['fingerprint'] = canonicalMd5Fingerprint(doc['fingerprint']);
  final day = doc['day'];
  if (day is! String || !_validDay(day)) {
    throw const FormatException('reading activity day is invalid');
  }
  final events = doc['events'];
  if (events is! List) throw const FormatException('events must be a list');
  final byId = <String, Map<String, dynamic>>{};
  for (final raw in events) {
    if (raw is! Map) throw const FormatException('event must be an object');
    final event = Map<String, dynamic>.from(raw);
    final id = event['eventId'];
    final startedAt = event['startedAt'];
    final duration = event['durationSeconds'];
    final deviceId = event['deviceId'];
    final deleted = event['deleted'] ?? false;
    if (id is! String ||
        !_uuid.hasMatch(id) ||
        startedAt is! String ||
        DateTime.tryParse(startedAt) == null ||
        duration is! int ||
        duration < 0 ||
        deviceId is! String ||
        deviceId.isEmpty ||
        deleted is! bool) {
      throw const FormatException('reading event is invalid');
    }
    final isLegacyAggregate = id ==
        legacyReadingActivityEventId(
          doc['fingerprint'] as String,
          day,
          duration,
        );
    event['startedAt'] = isLegacyAggregate
        ? DateTime.parse('${day}T00:00:00Z').toIso8601String()
        : DateTime.parse(startedAt).toUtc().toIso8601String();
    if (isLegacyAggregate) event['deviceId'] = readingActivityLegacySource;
    event['deleted'] = deleted;
    event['stamp'] = isLegacyAggregate && !deleted
        ? DomainStamp(
            modifiedAt: DateTime.parse('${day}T00:00:00Z'),
            deviceId: readingActivityLegacySource,
          ).toJson()
        : event['stamp'] == null
            ? DomainStamp(
                    modifiedAt: DateTime.parse(startedAt).toUtc(),
                    deviceId: deviceId)
                .toJson()
            : DomainStamp.fromJson(event['stamp']).toJson();
    final previous = byId[id];
    if (previous != null) {
      for (final field in const [
        'eventId',
        'startedAt',
        'durationSeconds',
        'deviceId'
      ]) {
        if (previous[field] != event[field]) {
          throw const FormatException('event ID collision');
        }
      }
      final previousStamp = DomainStamp.fromJson(previous['stamp']);
      final eventStamp = DomainStamp.fromJson(event['stamp']);
      if (eventStamp.compareTo(previousStamp) < 0) continue;
      if (eventStamp.compareTo(previousStamp) == 0 &&
          canonicalJson(previous) != canonicalJson(event)) {
        throw const FormatException('event mutation collision');
      }
    }
    byId[id] = event;
  }
  doc['events'] = byId.values.toList()
    ..sort(
        (a, b) => (a['eventId'] as String).compareTo(b['eventId'] as String));
  return doc;
}

/// Produces a content-free diagnostic label for a rejected remote document.
String readingActivityDecodeFailureLabel(Object error) {
  if (error is AnnotationProtocolException) return 'invalid-fingerprint';
  if (error is! FormatException) return 'unexpected-format';
  return switch (error.message) {
    'reading activity must be an object' => 'not-an-object',
    'unsupported reading-activity schema' => 'unsupported-schema',
    'reading activity day is invalid' => 'invalid-day',
    'events must be a list' => 'invalid-events-list',
    'event must be an object' => 'invalid-event-object',
    'reading event is invalid' => 'invalid-event-fields',
    'stamp must be an object' => 'invalid-stamp-object',
    'stamp fields are invalid' => 'invalid-stamp-fields',
    'stamp time is invalid' => 'invalid-stamp-time',
    'event ID collision' => 'event-id-collision',
    'event mutation collision' => 'event-mutation-collision',
    _ => 'invalid-document',
  };
}

Map<String, dynamic> mergeReadingActivityDocuments(
    Map<String, dynamic> left, Map<String, dynamic> right) {
  final a = decodeReadingActivityDocument(left);
  final b = decodeReadingActivityDocument(right);
  if (a['fingerprint'] != b['fingerprint'] || a['day'] != b['day']) {
    throw const FormatException('reading activity identities differ');
  }
  return decodeReadingActivityDocument({
    'schemaVersion': readingActivitySchemaVersion,
    'fingerprint': a['fingerprint'],
    'day': a['day'],
    'events': [...a['events'] as List, ...b['events'] as List],
  });
}

bool readingActivityMatchesId(Map<String, dynamic> document, String id) =>
    readingActivityDocumentId(
        document['fingerprint'] as String, document['day'] as String) ==
    id;

bool _validDay(String value) {
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return false;
  return DateTime.tryParse(value) != null;
}

final _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    caseSensitive: false);
