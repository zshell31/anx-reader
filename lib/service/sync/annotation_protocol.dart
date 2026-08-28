import 'dart:convert';

const _timestampPattern = r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$';
final RegExp _md5Pattern = RegExp(r'^[0-9a-f]{32}$');
final RegExp _wireTimestampPattern = RegExp(_timestampPattern);

class AnnotationProtocolException implements Exception {
  final String message;
  const AnnotationProtocolException(this.message);
  @override
  String toString() => 'AnnotationProtocolException: $message';
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
    throw AnnotationProtocolException(
        '$field is not a canonical UTC timestamp');
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null || canonicalWireTimestamp(parsed) != value) {
    throw AnnotationProtocolException('$field is not a valid UTC timestamp');
  }
  return value;
}

String canonicalMd5Fingerprint(Object? value) {
  if (value is! String) {
    throw const AnnotationProtocolException('fingerprint must be a string');
  }
  final result = value.toLowerCase();
  if (!_md5Pattern.hasMatch(result)) {
    throw const AnnotationProtocolException(
        'fingerprint must be 32 hexadecimal MD5 characters');
  }
  return result;
}

String canonicalJson(Object? value) => jsonEncode(_canonicalValue(value));

Object? _canonicalValue(Object? value) {
  if (value is List) return value.map(_canonicalValue).toList();
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return <String, Object?>{
      for (final key in keys) key: _canonicalValue(value[key]),
    };
  }
  return value;
}

Map<String, dynamic> decodeAnnotationDocument(Object? input) {
  final source = input is String ? jsonDecode(input) : input;
  if (source is! Map) {
    throw const AnnotationProtocolException('document must be an object');
  }
  final document = _copyMap(source);
  final version = document['schemaVersion'];
  if (version != 1 && version != 2) {
    throw AnnotationProtocolException('unsupported schema version $version');
  }
  final migrated =
      version == 1 ? migrateAnnotationDocumentV1(document) : document;
  _validateDocument(migrated);
  return migrated;
}

Map<String, dynamic> migrateAnnotationDocumentV1(Map<String, dynamic> source) {
  final result = _copyMap(source)..['schemaVersion'] = 2;
  final annotations = _mapList(result['annotations'], 'annotations');
  result['annotations'] = annotations.map((annotation) {
    final migrated = _copyMap(annotation);
    // V1 presentation was renderer-local. It must not acquire semantic meaning.
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
  if (leftBook['fingerprintAlgorithm'] != 'md5' ||
      rightBook['fingerprintAlgorithm'] != 'md5' ||
      canonicalMd5Fingerprint(leftBook['fingerprint']) !=
          canonicalMd5Fingerprint(rightBook['fingerprint'])) {
    throw const AnnotationProtocolException('book document identity collision');
  }
  final winner =
      canonicalJson(left).compareTo(canonicalJson(right)) >= 0 ? left : right;
  final result = _copyMap(winner);
  result['schemaVersion'] = 2;
  result['book'] = {
    ..._copyMap(_map(winner['book'], 'book')),
    'fingerprintAlgorithm': 'md5',
    'fingerprint': canonicalMd5Fingerprint(leftBook['fingerprint']),
  };
  result['annotations'] = _mergeById(
    _mapList(left['annotations'], 'annotations'),
    _mapList(right['annotations'], 'annotations'),
    _mergeAnnotation,
  );
  return decodeAnnotationDocument(result);
}

Map<String, dynamic> _mergeAnnotation(
    Map<String, dynamic> a, Map<String, dynamic> b) {
  _sameIdentity('annotation', a, b, const ['createdAt']);
  final result = _copyMap(_winner(a, b, const {'enrichments', 'deletedAt'}));
  result.remove('presentation');
  result['enrichments'] = _mergeById(
    _mapList(a['enrichments'], 'enrichments'),
    _mapList(b['enrichments'], 'enrichments'),
    _mergeEnrichment,
  );
  _stickyTombstone(result, a['deletedAt'], b['deletedAt']);
  return result;
}

Map<String, dynamic> _mergeEnrichment(
    Map<String, dynamic> a, Map<String, dynamic> b) {
  _sameIdentity('enrichment', a, b, const ['createdAt', 'kind']);
  final isThread = a['kind'] == 'ai-thread';
  final result =
      _copyMap(_winner(a, b, {if (isThread) 'messages', 'deletedAt'}));
  if (isThread) {
    result['messages'] = _mergeById(
      _mapList(a['messages'], 'messages'),
      _mapList(b['messages'], 'messages'),
      _mergeMessage,
    )..sort((x, y) {
        final sequence = (x['sequence'] as num).compareTo(y['sequence'] as num);
        return sequence != 0
            ? sequence
            : (x['id'] as String).compareTo(y['id'] as String);
      });
  }
  _stickyTombstone(result, a['deletedAt'], b['deletedAt']);
  return result;
}

Map<String, dynamic> _mergeMessage(
    Map<String, dynamic> a, Map<String, dynamic> b) {
  _sameIdentity('AI message', a, b, const ['createdAt', 'role', 'sequence']);
  final result = _copyMap(_winner(a, b, const {'deletedAt'}));
  _stickyTombstone(result, a['deletedAt'], b['deletedAt']);
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
    final id = item['id'];
    if (id is! String || id.isEmpty) {
      throw const AnnotationProtocolException('entity id is required');
    }
    values[id] = values[id] == null ? _copyMap(item) : merge(values[id]!, item);
  }
  final result = values.values.toList();
  result.sort((x, y) => (x['id'] as String).compareTo(y['id'] as String));
  return result;
}

Map<String, dynamic> _winner(
    Map<String, dynamic> a, Map<String, dynamic> b, Set<String> ignored) {
  final leftTime = validateWireTimestamp(a['updatedAt'], 'updatedAt');
  final rightTime = validateWireTimestamp(b['updatedAt'], 'updatedAt');
  if (leftTime != rightTime) return leftTime.compareTo(rightTime) > 0 ? a : b;
  Map<String, dynamic> comparable(Map<String, dynamic> value) =>
      _copyMap(value)..removeWhere((key, _) => ignored.contains(key));
  return canonicalJson(comparable(a)).compareTo(canonicalJson(comparable(b))) >=
          0
      ? a
      : b;
}

void _sameIdentity(String entity, Map<String, dynamic> a,
    Map<String, dynamic> b, List<String> keys) {
  if (a['id'] != b['id'] ||
      keys.any((key) => canonicalJson(a[key]) != canonicalJson(b[key]))) {
    throw AnnotationProtocolException(
        '$entity identity collision for ${a['id']}');
  }
}

void _stickyTombstone(Map<String, dynamic> result, Object? a, Object? b) {
  final values = [a, b].whereType<String>().toList();
  if (values.isEmpty) {
    result.remove('deletedAt');
  } else {
    for (final value in values) {
      validateWireTimestamp(value, 'deletedAt');
    }
    values.sort();
    result['deletedAt'] = values.last;
  }
}

void _validateDocument(Map<String, dynamic> document) {
  final book = _map(document['book'], 'book');
  if (book['fingerprintAlgorithm'] != 'md5') {
    throw const AnnotationProtocolException(
        'fingerprint algorithm must be md5');
  }
  book['fingerprint'] = canonicalMd5Fingerprint(book['fingerprint']);
  document['book'] = book;
  for (final annotation in _mapList(document['annotations'], 'annotations')) {
    if (annotation.containsKey('presentation')) {
      throw const AnnotationProtocolException('v2 presentation is local-only');
    }
    if (annotation['motivation'] != 'selection' &&
        annotation['motivation'] != 'bookmark') {
      throw const AnnotationProtocolException('invalid annotation motivation');
    }
    validateWireTimestamp(annotation['createdAt'], 'createdAt');
    validateWireTimestamp(annotation['updatedAt'], 'updatedAt');
    if (annotation['deletedAt'] != null) {
      validateWireTimestamp(annotation['deletedAt'], 'deletedAt');
    }
    _map(annotation['target'], 'target');
    for (final enrichment
        in _mapList(annotation['enrichments'], 'enrichments')) {
      validateWireTimestamp(enrichment['createdAt'], 'createdAt');
      validateWireTimestamp(enrichment['updatedAt'], 'updatedAt');
      if (enrichment['deletedAt'] != null) {
        validateWireTimestamp(enrichment['deletedAt'], 'deletedAt');
      }
      if (enrichment['kind'] == 'ai-thread') {
        for (final message in _mapList(enrichment['messages'], 'messages')) {
          validateWireTimestamp(message['createdAt'], 'createdAt');
          validateWireTimestamp(message['updatedAt'], 'updatedAt');
          if (message['deletedAt'] != null) {
            validateWireTimestamp(message['deletedAt'], 'deletedAt');
          }
        }
      }
    }
  }
}

Map<String, dynamic> _map(Object? value, String field) {
  if (value is! Map) {
    throw AnnotationProtocolException('$field must be an object');
  }
  return _copyMap(value);
}

List<Map<String, dynamic>> _mapList(Object? value, String field) {
  if (value is! List) {
    throw AnnotationProtocolException('$field must be an array');
  }
  return value.map((item) => _map(item, field)).toList();
}

Map<String, dynamic> _copyMap(Map value) =>
    value.map((key, value) => MapEntry(key.toString(), value));
