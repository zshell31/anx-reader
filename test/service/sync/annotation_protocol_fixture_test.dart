import 'dart:convert';
import 'dart:io';

import 'package:anx_reader/service/sync/annotation_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

const _fixturePath = 'protocol/fixtures/annotation_book_document_v2.json';

void main() {
  final corpus =
      jsonDecode(File(_fixturePath).readAsStringSync()) as Map<String, dynamic>;
  final documents = (corpus['documents'] as Map).cast<String, dynamic>();
  final values = (corpus['values'] as Map).cast<String, dynamic>();
  final cases = (corpus['cases'] as List).cast<Map<String, dynamic>>();
  final report = <Map<String, dynamic>>[];

  for (final fixture in cases) {
    test('M4A corpus: ${fixture['name']}', () {
      final outcome = _evaluate(fixture, documents, values);
      report.add({'name': fixture['name'], 'outcome': outcome});
    });
  }

  tearDownAll(() {
    final outputPath = Platform.environment['ANNOTATION_PROTOCOL_REPORT'];
    if (outputPath == null || outputPath.isEmpty) return;
    File(outputPath).writeAsStringSync(canonicalJson({
      'protocol': corpus['protocol'],
      'schemaVersion': corpus['schemaVersion'],
      'corpusVersion': corpus['corpusVersion'],
      'caseCount': cases.length,
      'results': report,
    }));
  });
}

String _evaluate(
  Map<String, dynamic> fixture,
  Map<String, dynamic> documents,
  Map<String, dynamic> values,
) {
  try {
    late final String outcome;
    switch (fixture['operation']) {
      case 'canonical-json':
        outcome = canonicalJson(values[fixture['value']]);
      case 'md5':
        outcome = canonicalMd5Fingerprint(fixture['input']);
      case 'decode':
        outcome = canonicalAnnotationDocumentJson(
            _document(documents, fixture['input'] as String));
      case 'merge':
        outcome = canonicalJson(mergeAnnotationDocuments(
          _document(documents, fixture['left'] as String),
          _document(documents, fixture['right'] as String),
        ));
      case 'algebra':
        outcome = _evaluateAlgebra(fixture, documents);
      default:
        throw StateError('unknown fixture operation ${fixture['operation']}');
    }
    final expectedError = fixture['expectedError'];
    if (expectedError != null) {
      fail('expected protocol error $expectedError, got $outcome');
    }
    final expected = fixture['expectedCanonical'] != null
        ? fixture['expectedCanonical'] as String
        : fixture['operation'] == 'md5'
            ? fixture['expected'] as String
            : canonicalAnnotationDocumentJson(
                _document(documents, fixture['expected'] as String));
    expect(outcome, expected);
    return outcome;
  } on AnnotationProtocolException catch (error) {
    expect(error.code, fixture['expectedError']);
    return 'error:${error.code}';
  }
}

String _evaluateAlgebra(
    Map<String, dynamic> fixture, Map<String, dynamic> documents) {
  final names = (fixture['inputs'] as List).cast<String>();
  final a = _document(documents, names[0]);
  final b = _document(documents, names[1]);
  final c = _document(documents, names[2]);
  final canonicalA = canonicalAnnotationDocumentJson(a);
  expect(canonicalJson(mergeAnnotationDocuments(a, a)), canonicalA);

  final ab = mergeAnnotationDocuments(a, b);
  final ba = mergeAnnotationDocuments(b, a);
  expect(canonicalJson(ab), canonicalJson(ba));

  final leftAssociated = mergeAnnotationDocuments(ab, c);
  final rightAssociated =
      mergeAnnotationDocuments(a, mergeAnnotationDocuments(b, c));
  expect(canonicalJson(leftAssociated), canonicalJson(rightAssociated));
  return canonicalJson(leftAssociated);
}

Map<String, dynamic> _document(Map<String, dynamic> documents, String name) {
  return (jsonDecode(jsonEncode(documents[name])) as Map)
      .cast<String, dynamic>();
}
