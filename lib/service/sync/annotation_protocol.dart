import 'dart:convert';

const _timestampPattern = r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$';
final RegExp _md5Pattern = RegExp(r'^[0-9a-f]{32}$');
final RegExp _wireTimestampPattern = RegExp(_timestampPattern);
const _materialKinds = {
  'translation',
  'dictionary',
  'ai-analysis',
  'personal-note',
};
const _messageRoles = {'system', 'user', 'assistant'};

abstract final class AnnotationProtocolErrorCode {
  static const invalidDocument = 'invalid-document';
  static const unsupportedSchema = 'unsupported-schema-version';
  static const invalidMd5 = 'invalid-md5';
  static const invalidTimestamp = 'invalid-timestamp';
  static const invalidMotivation = 'invalid-motivation';
  static const presentationNotShared = 'presentation-not-shared';
  static const invalidEntityId = 'invalid-entity-id';
  static const duplicateEntityId = 'duplicate-entity-id';
  static const invalidEnrichmentKind = 'invalid-enrichment-kind';
  static const invalidAiThread = 'invalid-ai-thread';
  static const invalidAiMessage = 'invalid-ai-message';
  static const bookIdentityCollision = 'identity-collision/book';
  static const annotationIdentityCollision = 'identity-collision/annotation';
  static const materialIdentityCollision =
      'identity-collision/material-enrichment';
  static const aiThreadIdentityCollision = 'identity-collision/ai-thread';
  static const aiMessageIdentityCollision = 'identity-collision/ai-message';
}

class AnnotationProtocolException implements Exception {
  final String code;
  final String message;
  const AnnotationProtocolException(this.code, this.message);

  @override
  String toString() => 'AnnotationProtocolException($code): $message';
}

Never _fail(String code, String message) {
  throw AnnotationProtocolException(code, message);
}

String canonicalWireTimestamp(DateTime value) {
  final utc = value.toUtc();
  String two(int value) => value.toString().padLeft(2, '0');
  String three(int value) => value.toString().padLeft(3, '0');
  return '${utc.year.toString().padLeft(4, '0')}-${two(utc.month)}-'
      '${two(utc.day)}T${two(utc.hour)}:${two(utc.minute)}:'
      '${two(utc.second)}.${three(utc.millisecond)}Z';
}

String validateWireTimestamp(Object? value, String field) {
  if (value is! String || !_wireTimestampPattern.hasMatch(value)) {
    _fail(AnnotationProtocolErrorCode.invalidTimestamp,
        '$field is not a canonical UTC timestamp');
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null || canonicalWireTimestamp(parsed) != value) {
    _fail(AnnotationProtocolErrorCode.invalidTimestamp,
        '$field is not a valid UTC timestamp');
  }
  return value;
}

String canonicalMd5Fingerprint(Object? value) {
  if (value is! String) {
    _fail(
        AnnotationProtocolErrorCode.invalidMd5, 'fingerprint must be a string');
  }
  final result = value.toLowerCase();
  if (!_md5Pattern.hasMatch(result)) {
    _fail(AnnotationProtocolErrorCode.invalidMd5,
        'fingerprint must be 32 hexadecimal MD5 characters');
  }
  return result;
}

/// Canonical JSON recursively orders object keys by UTF-16 code unit.
/// Protocol-owned arrays are normalized by [decodeAnnotationDocument].
String canonicalJson(Object? value) => jsonEncode(_canonicalValue(value));

Object? _canonicalValue(Object? value) {
  if (value is List) return value.map(_canonicalValue).toList();
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort(_ordinalCompare);
    return <String, Object?>{
      for (final key in keys) key: _canonicalValue(value[key]),
    };
  }
  return value;
}

String canonicalAnnotationDocumentJson(Object? input) =>
    canonicalJson(decodeAnnotationDocument(input));

Map<String, dynamic> decodeAnnotationDocument(Object? input) {
  Object? source;
  try {
    source = input is String ? jsonDecode(input) : input;
  } on FormatException {
    _fail(AnnotationProtocolErrorCode.invalidDocument,
        'document is not valid JSON');
  }
  if (source is! Map) {
    _fail(AnnotationProtocolErrorCode.invalidDocument,
        'document must be an object');
  }
  final document = _deepMap(source, 'document');
  final version = document['schemaVersion'];
  if (version != 1 && version != 2) {
    _fail(AnnotationProtocolErrorCode.unsupportedSchema,
        'unsupported schema version $version');
  }
  final migrated =
      version == 1 ? migrateAnnotationDocumentV1(document) : document;
  return _normalizeAndValidateDocument(migrated);
}

Map<String, dynamic> migrateAnnotationDocumentV1(Map<String, dynamic> source) {
  final result = _deepMap(source, 'document')..['schemaVersion'] = 2;
  final annotations = _mapList(result['annotations'], 'annotations');
  result['annotations'] = annotations.map((annotation) {
    final migrated = _deepMap(annotation, 'annotation');
    migrated.remove('presentation');
    migrated.putIfAbsent('motivation', () => 'selection');
    return migrated;
  }).toList();
  return result;
}

Map<String, dynamic> mergeAnnotationDocuments(
  Map<String, dynamic> leftInput,
  Map<String, dynamic> rightInput,
) {
  final left = decodeAnnotationDocument(leftInput);
  final right = decodeAnnotationDocument(rightInput);
  final leftBook = _map(left['book'], 'book');
  final rightBook = _map(right['book'], 'book');
  if (leftBook['fingerprint'] != rightBook['fingerprint']) {
    _fail(AnnotationProtocolErrorCode.bookIdentityCollision,
        'book document identity collision');
  }
  final leftEnvelope = _deepMap(left, 'document')..remove('annotations');
  final rightEnvelope = _deepMap(right, 'document')..remove('annotations');
  final result = _deepMap(
      canonicalJson(leftEnvelope).compareTo(canonicalJson(rightEnvelope)) >= 0
          ? leftEnvelope
          : rightEnvelope,
      'document');
  result['schemaVersion'] = 2;
  result['annotations'] = _mergeById(
    _mapList(left['annotations'], 'annotations'),
    _mapList(right['annotations'], 'annotations'),
    _mergeAnnotation,
  );
  return _normalizeAndValidateDocument(result);
}

Map<String, dynamic> _mergeAnnotation(
    Map<String, dynamic> a, Map<String, dynamic> b) {
  _sameIdentity(AnnotationProtocolErrorCode.annotationIdentityCollision,
      'annotation', a, b, const ['createdAt']);
  final result =
      _deepMap(_winner(a, b, const {'enrichments', 'deletedAt'}), 'annotation');
  result['enrichments'] = _mergeById(
    _mapList(a['enrichments'], 'enrichments'),
    _mapList(b['enrichments'], 'enrichments'),
    _mergeEnrichment,
  );
  _stickyTombstone(result, a, b);
  return result;
}

Map<String, dynamic> _mergeEnrichment(
    Map<String, dynamic> a, Map<String, dynamic> b) {
  final aIsThread = a['kind'] == 'ai-thread';
  final bIsThread = b['kind'] == 'ai-thread';
  if (aIsThread || bIsThread) {
    _sameIdentity(AnnotationProtocolErrorCode.aiThreadIdentityCollision,
        'AI thread', a, b, const ['createdAt', 'kind', 'contextSnapshot']);
  } else {
    _sameIdentity(AnnotationProtocolErrorCode.materialIdentityCollision,
        'material enrichment', a, b, const ['createdAt', 'kind']);
  }
  final result = _deepMap(
      _winner(a, b, {if (aIsThread && bIsThread) 'messages', 'deletedAt'}),
      'enrichment');
  if (aIsThread && bIsThread) {
    result['messages'] = _mergeById(
      _mapList(a['messages'], 'messages'),
      _mapList(b['messages'], 'messages'),
      _mergeMessage,
    )..sort(_compareMessages);
  }
  _stickyTombstone(result, a, b);
  return result;
}

Map<String, dynamic> _mergeMessage(
    Map<String, dynamic> a, Map<String, dynamic> b) {
  _sameIdentity(AnnotationProtocolErrorCode.aiMessageIdentityCollision,
      'AI message', a, b, const ['createdAt', 'role', 'sequence']);
  final result = _deepMap(_winner(a, b, const {'deletedAt'}), 'AI message');
  _stickyTombstone(result, a, b);
  return result;
}

List<Map<String, dynamic>> _mergeById(
  List<Map<String, dynamic>> a,
  List<Map<String, dynamic>> b,
  Map<String, dynamic> Function(Map<String, dynamic>, Map<String, dynamic>)
      merge,
) {
  final values = <String, Map<String, dynamic>>{};
  for (final item in [...a, ...b]) {
    final id = _entityId(item);
    values[id] =
        values[id] == null ? merge(item, item) : merge(values[id]!, item);
  }
  final result = values.values.toList()..sort(_compareIds);
  return result;
}

Map<String, dynamic> _winner(
    Map<String, dynamic> a, Map<String, dynamic> b, Set<String> ignored) {
  final leftTime = validateWireTimestamp(a['updatedAt'], 'updatedAt');
  final rightTime = validateWireTimestamp(b['updatedAt'], 'updatedAt');
  if (leftTime != rightTime) {
    return _ordinalCompare(leftTime, rightTime) > 0 ? a : b;
  }
  Map<String, dynamic> comparable(Map<String, dynamic> value) =>
      _deepMap(value, 'entity')..removeWhere((key, _) => ignored.contains(key));
  return canonicalJson(comparable(a)).compareTo(canonicalJson(comparable(b))) >=
          0
      ? a
      : b;
}

void _sameIdentity(String code, String entity, Map<String, dynamic> a,
    Map<String, dynamic> b, List<String> keys) {
  if (a['id'] != b['id'] ||
      keys.any((key) => canonicalJson(a[key]) != canonicalJson(b[key]))) {
    _fail(code, '$entity identity collision for ${a['id']}');
  }
}

void _stickyTombstone(Map<String, dynamic> result, Map<String, dynamic> a,
    Map<String, dynamic> b) {
  final values = <String>[
    if (a.containsKey('deletedAt')) a['deletedAt'] as String,
    if (b.containsKey('deletedAt')) b['deletedAt'] as String,
  ]..sort(_ordinalCompare);
  if (values.isEmpty) {
    result.remove('deletedAt');
  } else {
    result['deletedAt'] = values.last;
  }
}

Map<String, dynamic> _normalizeAndValidateDocument(Map<String, dynamic> input) {
  final document = _deepMap(input, 'document');
  if (document['schemaVersion'] != 2) {
    _fail(AnnotationProtocolErrorCode.unsupportedSchema,
        'schemaVersion must be 2');
  }
  final book = _map(document['book'], 'book');
  if (book['fingerprintAlgorithm'] != 'md5') {
    _fail(AnnotationProtocolErrorCode.invalidMd5,
        'fingerprint algorithm must be md5');
  }
  book['fingerprint'] = canonicalMd5Fingerprint(book['fingerprint']);
  document['book'] = book;
  final annotations = _mapList(document['annotations'], 'annotations');
  _requireUniqueIds(annotations);
  document['annotations'] = annotations.map(_normalizeAnnotation).toList()
    ..sort(_compareIds);
  return document;
}

Map<String, dynamic> _normalizeAnnotation(Map<String, dynamic> input) {
  final annotation = _deepMap(input, 'annotation');
  _entityId(annotation);
  if (annotation.containsKey('presentation')) {
    _fail(AnnotationProtocolErrorCode.presentationNotShared,
        'v2 presentation is local-only');
  }
  if (annotation['motivation'] != 'selection' &&
      annotation['motivation'] != 'bookmark') {
    _fail(AnnotationProtocolErrorCode.invalidMotivation,
        'invalid annotation motivation');
  }
  _validateTimestamps(annotation);
  final target = _map(annotation['target'], 'target');
  final selectors = target['selectors'];
  if (selectors is! List) {
    _fail(AnnotationProtocolErrorCode.invalidDocument,
        'selectors must be an array');
  }
  target['selectors'] =
      selectors.map((value) => _deepMap(value, 'selector')).toList();
  annotation['target'] = target;
  final enrichments = _mapList(annotation['enrichments'], 'enrichments');
  _requireUniqueIds(enrichments);
  annotation['enrichments'] = enrichments.map(_normalizeEnrichment).toList()
    ..sort(_compareIds);
  return annotation;
}

Map<String, dynamic> _normalizeEnrichment(Map<String, dynamic> input) {
  final enrichment = _deepMap(input, 'enrichment');
  _entityId(enrichment);
  _validateTimestamps(enrichment);
  final kind = enrichment['kind'];
  if (kind == 'ai-thread') {
    final snapshot = _map(enrichment['contextSnapshot'], 'contextSnapshot');
    final enrichmentIds = snapshot['enrichmentIds'];
    if (enrichmentIds is! List ||
        enrichmentIds.any((value) => value is! String)) {
      _fail(AnnotationProtocolErrorCode.invalidAiThread,
          'AI thread enrichmentIds must be an array of strings');
    }
    snapshot['enrichmentIds'] = List<Object?>.from(enrichmentIds);
    enrichment['contextSnapshot'] = snapshot;
    final messages = _mapList(enrichment['messages'], 'messages');
    _requireUniqueIds(messages);
    enrichment['messages'] = messages.map(_normalizeMessage).toList()
      ..sort(_compareMessages);
  } else if (!_materialKinds.contains(kind)) {
    _fail(AnnotationProtocolErrorCode.invalidEnrichmentKind,
        'invalid annotation enrichment kind');
  }
  return enrichment;
}

Map<String, dynamic> _normalizeMessage(Map<String, dynamic> input) {
  final message = _deepMap(input, 'AI message');
  _entityId(message);
  _validateTimestamps(message);
  if (!_messageRoles.contains(message['role']) || message['sequence'] is! int) {
    _fail(AnnotationProtocolErrorCode.invalidAiMessage,
        'invalid AI message identity');
  }
  return message;
}

void _validateTimestamps(Map<String, dynamic> value) {
  validateWireTimestamp(value['createdAt'], 'createdAt');
  validateWireTimestamp(value['updatedAt'], 'updatedAt');
  if (value.containsKey('deletedAt')) {
    validateWireTimestamp(value['deletedAt'], 'deletedAt');
  }
}

void _requireUniqueIds(List<Map<String, dynamic>> values) {
  final ids = <String>{};
  for (final value in values) {
    final id = _entityId(value);
    if (!ids.add(id)) {
      _fail(AnnotationProtocolErrorCode.duplicateEntityId,
          'duplicate entity id $id');
    }
  }
}

String _entityId(Map<String, dynamic> item) {
  final id = item['id'];
  if (id is! String || id.isEmpty) {
    _fail(AnnotationProtocolErrorCode.invalidEntityId, 'entity id is required');
  }
  return id;
}

int _compareIds(Map<String, dynamic> a, Map<String, dynamic> b) =>
    _ordinalCompare(a['id'] as String, b['id'] as String);

int _compareMessages(Map<String, dynamic> a, Map<String, dynamic> b) {
  final sequence = (a['sequence'] as int).compareTo(b['sequence'] as int);
  return sequence != 0 ? sequence : _compareIds(a, b);
}

int _ordinalCompare(String left, String right) => left.compareTo(right);

Map<String, dynamic> _map(Object? value, String field) {
  if (value is! Map) {
    _fail(AnnotationProtocolErrorCode.invalidDocument,
        '$field must be an object');
  }
  return _deepMap(value, field);
}

List<Map<String, dynamic>> _mapList(Object? value, String field) {
  if (value is! List) {
    _fail(
        AnnotationProtocolErrorCode.invalidDocument, '$field must be an array');
  }
  return value.map((item) => _map(item, field)).toList();
}

Map<String, dynamic> _deepMap(Object? value, String field) {
  if (value is! Map) {
    _fail(AnnotationProtocolErrorCode.invalidDocument,
        '$field must be an object');
  }
  return value.map<String, dynamic>((key, item) {
    if (key is! String) {
      _fail(AnnotationProtocolErrorCode.invalidDocument,
          '$field object keys must be strings');
    }
    return MapEntry(key, _deepCopy(item));
  });
}

Object? _deepCopy(Object? value) {
  if (value is Map) return _deepMap(value, 'JSON value');
  if (value is List) return value.map(_deepCopy).toList();
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  _fail(AnnotationProtocolErrorCode.invalidDocument,
      'protocol values must be JSON-compatible');
}
