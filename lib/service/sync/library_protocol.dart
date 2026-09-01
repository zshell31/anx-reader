import 'dart:convert';

import 'package:anx_reader/service/sync/annotation_protocol.dart';
import 'package:anx_reader/service/sync/domain_stamp.dart';

const libraryCatalogDomain = 'library-catalog';
const readingStateDomain = 'reading-state';
const libraryCatalogSchemaVersion = 1;
const readingStateSchemaVersion = 1;

List<String> libraryCatalogRemotePath(String id) =>
    ['shared', 'v1', 'catalog', 'books', '$id.json'];
List<String> readingStateRemotePath(String id) =>
    ['shared', 'v1', 'reading-state', '$id.json'];

Map<String, dynamic> decodeLibraryCatalogDocument(Object? input) {
  if (input is! Map) throw const FormatException('catalog must be an object');
  final doc = Map<String, dynamic>.from(input);
  if (doc['schemaVersion'] != libraryCatalogSchemaVersion) {
    throw const FormatException('unsupported catalog schema');
  }
  doc['fingerprint'] = canonicalMd5Fingerprint(doc['fingerprint']);
  final membership = _stamped(doc['membership']);
  if (membership['value'] is! bool) {
    throw const FormatException('membership must be boolean');
  }
  final metadata = doc['metadata'];
  if (metadata is! Map) throw const FormatException('metadata is invalid');
  final normalizedMetadata = <String, dynamic>{};
  for (final field in const ['title', 'author', 'description', 'rating']) {
    final value = _stamped(metadata[field]);
    final raw = value['value'];
    if (field == 'rating') {
      if (raw is! num) throw const FormatException('rating must be numeric');
      value['value'] = raw.toDouble();
    } else if (raw != null && raw is! String) {
      throw FormatException('$field must be text or null');
    }
    normalizedMetadata[field] = value;
  }
  doc['membership'] = membership;
  doc['metadata'] = normalizedMetadata;
  final asset = doc['bookAsset'];
  final extension = asset is Map ? asset['extension'] : null;
  if (asset is! Map ||
      asset['algorithm'] != 'md5' ||
      canonicalMd5Fingerprint(asset['digest']) != doc['fingerprint'] ||
      extension is! String ||
      !RegExp(r'^\.[a-z0-9]{1,8}$').hasMatch(extension)) {
    throw const FormatException('book asset identity is invalid');
  }
  doc['bookAsset'] = {
    'algorithm': 'md5',
    'digest': doc['fingerprint'],
    'extension': extension,
  };
  if (doc.containsKey('groupId') && doc['groupId'] != null) {
    doc['groupId'] = _stamped(doc['groupId']);
    if (doc['groupId']['value'] is! String) {
      throw const FormatException('groupId must be a shared UUID');
    }
  }
  return doc;
}

Map<String, dynamic> mergeLibraryCatalogDocuments(
    Map<String, dynamic> left, Map<String, dynamic> right) {
  final a = decodeLibraryCatalogDocument(left);
  final b = decodeLibraryCatalogDocument(right);
  if (a['fingerprint'] != b['fingerprint']) {
    throw const FormatException('catalog identities differ');
  }
  final am = a['metadata'] as Map<String, dynamic>;
  final bm = b['metadata'] as Map<String, dynamic>;
  return decodeLibraryCatalogDocument({
    'schemaVersion': libraryCatalogSchemaVersion,
    'fingerprint': a['fingerprint'],
    'membership': winningStampedValue(a['membership'], b['membership']),
    'metadata': {
      for (final field in const ['title', 'author', 'description', 'rating'])
        field: winningStampedValue(am[field], bm[field]),
    },
    if (a['groupId'] != null || b['groupId'] != null)
      'groupId': a['groupId'] == null
          ? b['groupId']
          : b['groupId'] == null
              ? a['groupId']
              : winningStampedValue(a['groupId'], b['groupId']),
    'bookAsset': a['bookAsset'],
  });
}

Map<String, dynamic> decodeReadingStateDocument(Object? input) {
  if (input is! Map) {
    throw const FormatException('reading state must be an object');
  }
  final doc = Map<String, dynamic>.from(input);
  if (doc['schemaVersion'] != readingStateSchemaVersion) {
    throw const FormatException('unsupported reading-state schema');
  }
  doc['fingerprint'] = canonicalMd5Fingerprint(doc['fingerprint']);
  if (doc['position'] is! String || doc['percentage'] is! num) {
    throw const FormatException('reading-state payload is invalid');
  }
  final percentage = (doc['percentage'] as num).toDouble();
  if (!percentage.isFinite || percentage < 0 || percentage > 1) {
    throw const FormatException('reading percentage is out of range');
  }
  doc['percentage'] = percentage;
  doc['stamp'] = DomainStamp.fromJson(doc['stamp']).toJson();
  return doc;
}

Map<String, dynamic> mergeReadingStateDocuments(
    Map<String, dynamic> left, Map<String, dynamic> right) {
  final a = decodeReadingStateDocument(left);
  final b = decodeReadingStateDocument(right);
  if (a['fingerprint'] != b['fingerprint']) {
    throw const FormatException('reading-state identities differ');
  }
  return DomainStamp.fromJson(a['stamp'])
              .compareTo(DomainStamp.fromJson(b['stamp'])) >=
          0
      ? a
      : b;
}

List<int> encodeDomainDocument(Map<String, dynamic> document) =>
    utf8.encode(canonicalJson(document));

Map<String, dynamic> _stamped(Object? value) {
  if (value is! Map || !value.containsKey('value')) {
    throw const FormatException('stamped field is invalid');
  }
  DomainStamp.fromJson(value['stamp']);
  return Map<String, dynamic>.from(value);
}
