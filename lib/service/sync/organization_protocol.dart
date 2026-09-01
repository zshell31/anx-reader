import 'package:anx_reader/service/sync/annotation_protocol.dart';
import 'package:anx_reader/service/sync/domain_stamp.dart';

const groupDomain = 'groups';
const tagDomain = 'tags';
const bookTagDomain = 'book-tags';
const themeDomain = 'themes';
const organizationSchemaVersion = 1;

List<String> groupRemotePath(String id) =>
    ['shared', 'v1', 'groups', '$id.json'];
List<String> tagRemotePath(String id) => ['shared', 'v1', 'tags', '$id.json'];
List<String> themeRemotePath(String id) =>
    ['shared', 'v1', 'themes', '$id.json'];
List<String> bookTagRemotePath(String id) {
  final parts = id.split('@');
  if (parts.length != 2) throw const FormatException('invalid book-tag ID');
  canonicalMd5Fingerprint(parts[0]);
  _sharedUuid(parts[1]);
  return ['shared', 'v1', 'book-tags', parts[0], '${parts[1]}.json'];
}

Map<String, dynamic> decodeGroupDocument(Object? input) =>
    _decodeRecord(input, groupDomain, const {'name', 'parentId'},
        (field, value) {
      if (field == 'name' && value is String && value.trim().isNotEmpty) return;
      if (field == 'parentId' && (value == null || _isUuid(value))) return;
      throw FormatException('invalid group $field');
    });

Map<String, dynamic> decodeTagDocument(Object? input) =>
    _decodeRecord(input, tagDomain, const {'name', 'color'}, (field, value) {
      if (field == 'name' && value is String && value.trim().isNotEmpty) return;
      if (field == 'color' && (value == null || value is int)) return;
      throw FormatException('invalid tag $field');
    });

Map<String, dynamic> decodeThemeDocument(Object? input) =>
    _decodeRecord(input, themeDomain, const {'backgroundColor', 'textColor'},
        (field, value) {
      if (value is String && RegExp(r'^[0-9a-fA-F]{8}$').hasMatch(value)) {
        return;
      }
      throw FormatException('invalid theme $field');
    });

Map<String, dynamic> decodeBookTagDocument(Object? input) {
  if (input is! Map) throw const FormatException('book-tag must be an object');
  final doc = Map<String, dynamic>.from(input);
  if (doc['schemaVersion'] != organizationSchemaVersion) {
    throw const FormatException('unsupported book-tag schema');
  }
  doc['bookFingerprint'] = canonicalMd5Fingerprint(doc['bookFingerprint']);
  doc['tagId'] = _sharedUuid(doc['tagId']);
  final membership = _stamped(doc['membership']);
  if (membership['value'] is! bool) {
    throw const FormatException('book-tag membership must be boolean');
  }
  doc['membership'] = membership;
  return doc;
}

Map<String, dynamic> mergeGroupDocuments(
        Map<String, dynamic> a, Map<String, dynamic> b) =>
    _mergeRecords(
        decodeGroupDocument(a), decodeGroupDocument(b), decodeGroupDocument);
Map<String, dynamic> mergeTagDocuments(
        Map<String, dynamic> a, Map<String, dynamic> b) =>
    _mergeRecords(
        decodeTagDocument(a), decodeTagDocument(b), decodeTagDocument);
Map<String, dynamic> mergeThemeDocuments(
        Map<String, dynamic> a, Map<String, dynamic> b) =>
    _mergeRecords(
        decodeThemeDocument(a), decodeThemeDocument(b), decodeThemeDocument);

Map<String, dynamic> mergeBookTagDocuments(
    Map<String, dynamic> left, Map<String, dynamic> right) {
  final a = decodeBookTagDocument(left);
  final b = decodeBookTagDocument(right);
  if (a['bookFingerprint'] != b['bookFingerprint'] ||
      a['tagId'] != b['tagId']) {
    throw const FormatException('book-tag identities differ');
  }
  return decodeBookTagDocument({
    'schemaVersion': organizationSchemaVersion,
    'bookFingerprint': a['bookFingerprint'],
    'tagId': a['tagId'],
    'membership': winningStampedValue(a['membership'], b['membership']),
  });
}

String bookTagDocumentId(String fingerprint, String tagId) =>
    '${canonicalMd5Fingerprint(fingerprint)}@${_sharedUuid(tagId)}';

bool recordMatchesId(Map<String, dynamic> document, String id) =>
    document['id'] == id;
bool bookTagMatchesId(Map<String, dynamic> document, String id) =>
    bookTagDocumentId(
        document['bookFingerprint'] as String, document['tagId'] as String) ==
    id;

Map<String, dynamic> _decodeRecord(Object? input, String domain,
    Set<String> allowed, void Function(String, Object?) validate) {
  if (input is! Map) throw FormatException('$domain record must be an object');
  final doc = Map<String, dynamic>.from(input);
  if (doc['schemaVersion'] != organizationSchemaVersion ||
      doc['domain'] != domain) {
    throw FormatException('unsupported $domain schema');
  }
  doc['id'] = _sharedUuid(doc['id']);
  final tombstone = _stamped(doc['deleted']);
  if (tombstone['value'] is! bool) {
    throw FormatException('$domain deleted flag is invalid');
  }
  final fields = doc['fields'];
  if (fields is! Map || fields.keys.toSet().difference(allowed).isNotEmpty) {
    throw FormatException('$domain fields are invalid');
  }
  final normalized = <String, dynamic>{};
  for (final name in allowed) {
    final field = _stamped(fields[name]);
    validate(name, field['value']);
    normalized[name] = field;
  }
  doc['deleted'] = tombstone;
  doc['fields'] = normalized;
  return doc;
}

Map<String, dynamic> _mergeRecords(Map<String, dynamic> a,
    Map<String, dynamic> b, Map<String, dynamic> Function(Object?) decode) {
  if (a['domain'] != b['domain'] || a['id'] != b['id']) {
    throw const FormatException('record identities differ');
  }
  final af = a['fields'] as Map<String, dynamic>;
  final bf = b['fields'] as Map<String, dynamic>;
  return decode({
    'schemaVersion': organizationSchemaVersion,
    'domain': a['domain'],
    'id': a['id'],
    'deleted': winningStampedValue(a['deleted'], b['deleted']),
    'fields': {
      for (final name in af.keys) name: winningStampedValue(af[name], bf[name]),
    },
  });
}

Map<String, dynamic> _stamped(Object? value) {
  if (value is! Map || !value.containsKey('value')) {
    throw const FormatException('stamped value is invalid');
  }
  DomainStamp.fromJson(value['stamp']);
  return Map<String, dynamic>.from(value);
}

bool _isUuid(Object? value) {
  if (value is! String) return false;
  return _uuid.hasMatch(value);
}

String _sharedUuid(Object? value) {
  if (!_isUuid(value)) throw const FormatException('invalid shared UUID');
  return (value as String).toLowerCase();
}

final _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    caseSensitive: false);
