import 'dart:convert';

import 'package:anx_reader/service/sync/annotation_protocol.dart';

const anxPresentationSyncDomain = 'anx-annotation-presentations';
const anxPresentationDocumentId = 'presentations';
const anxPresentationFormat = 'anx-reader-annotation-presentations';
const anxPresentationVersion = 1;

List<String> anxPresentationRemotePath(String _) =>
    const ['anx', 'annotation-presentations.json'];

Map<String, dynamic> emptyAnxPresentationDocument() => <String, dynamic>{
      'format': anxPresentationFormat,
      'version': anxPresentationVersion,
      'presentations': <Object>[],
    };

Map<String, dynamic> decodeAnxPresentationDocument(Object? input) {
  if (input is! Map) {
    throw const FormatException('presentation document must be an object');
  }
  final document = Map<String, dynamic>.from(input);
  if (document['format'] != anxPresentationFormat ||
      document['version'] != anxPresentationVersion) {
    throw const FormatException('unsupported presentation document');
  }
  final rawEntries = document['presentations'];
  if (rawEntries is! List) {
    throw const FormatException('presentations must be an array');
  }
  final byId = <String, Map<String, dynamic>>{};
  for (final raw in rawEntries) {
    if (raw is! Map) {
      throw const FormatException('presentation entry must be an object');
    }
    final entry = Map<String, dynamic>.from(raw);
    final id = entry['annotationId'];
    final updatedAt = entry['updatedAt'];
    if (id is! String || id.isEmpty || updatedAt is! String) {
      throw const FormatException('presentation identity/time is required');
    }
    DateTime.parse(updatedAt).toUtc();
    final resetAt = entry['resetAt'];
    if (resetAt != null) {
      if (resetAt is! String || resetAt != updatedAt) {
        throw const FormatException('resetAt must equal updatedAt');
      }
      entry.remove('style');
      entry.remove('color');
    } else {
      if (entry['style'] != 'highlight' && entry['style'] != 'underline') {
        throw const FormatException('unsupported presentation style');
      }
      if (entry['color'] is! String ||
          (entry['color'] as String).trim().isEmpty) {
        throw const FormatException('presentation color is required');
      }
    }
    final previous = byId[id];
    byId[id] = previous == null ? entry : _winner(previous, entry);
  }
  document['presentations'] = [
    for (final id in byId.keys.toList()..sort()) byId[id]!,
  ];
  return document;
}

Map<String, dynamic> mergeAnxPresentationDocuments(
    Object? left, Object? right) {
  final a = decodeAnxPresentationDocument(left);
  final b = decodeAnxPresentationDocument(right);
  final merged = <String, Map<String, dynamic>>{};
  for (final raw in [
    ...a['presentations'] as List,
    ...b['presentations'] as List
  ]) {
    final entry = Map<String, dynamic>.from(raw as Map);
    final id = entry['annotationId'] as String;
    final previous = merged[id];
    merged[id] = previous == null ? entry : _winner(previous, entry);
  }
  return decodeAnxPresentationDocument(<String, dynamic>{
    ...a,
    ...b,
    'format': anxPresentationFormat,
    'version': anxPresentationVersion,
    'presentations': merged.values.toList(),
  });
}

Map<String, dynamic> _winner(
    Map<String, dynamic> left, Map<String, dynamic> right) {
  final leftTime = DateTime.parse(left['updatedAt'] as String).toUtc();
  final rightTime = DateTime.parse(right['updatedAt'] as String).toUtc();
  if (leftTime.isBefore(rightTime)) return right;
  if (rightTime.isBefore(leftTime)) return left;
  final leftReset = left.containsKey('resetAt');
  final rightReset = right.containsKey('resetAt');
  if (leftReset != rightReset) return leftReset ? left : right;
  return canonicalJson(left).compareTo(canonicalJson(right)) >= 0
      ? left
      : right;
}

List<int> encodeAnxPresentationDocument(Map<String, dynamic> document) =>
    utf8.encode(canonicalJson(decodeAnxPresentationDocument(document)));
