import 'dart:convert';
import 'dart:io';

import 'package:anx_reader/service/sync/annotation_protocol.dart';
import 'package:anx_reader/service/sync/annotation_read_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = jsonDecode(
    File('test/fixtures/lingua_annotation_book_v2.json').readAsStringSync(),
  ) as Map<String, dynamic>;

  test('Lingua material fixture is readable through semantic Anx fields', () {
    final decoded = decodeAnnotationDocument(source);
    final model = const CanonicalAnnotationReadAdapter().read(decoded).single;
    final byKind = {
      for (final item in model.activeEnrichments) item.kind: item
    };

    expect(decoded['schemaVersion'], 2);
    expect(byKind['translation']?.translation, 'случайно встретил');
    expect(byKind['translation']?.providerId, 'google-translate');
    expect(byKind['dictionary']?.markdown, contains('come across somebody'));
    expect(byKind['dictionary']?.providerName, 'LDOCE');
    expect(byKind['ai-analysis']?.commentaryValue('translationNotes'),
        'Фразовый глагол.');
    expect(byKind['ai-analysis']?.commentaryValue('grammar'), 'Past simple.');
    expect(byKind['ai-analysis']?.commentaryValue('usage'), 'Neutral.');
  });

  test('known semantic fields are searchable without flattening unknown JSON',
      () {
    final model = const CanonicalAnnotationReadAdapter().read(source).single;
    final searchable = model.activeEnrichments
        .expand((item) => item.searchableText)
        .join('\n');

    expect(searchable, contains('случайно встретил'));
    expect(searchable, contains('come across somebody'));
    expect(searchable, contains('Фразовый глагол.'));
    expect(searchable, contains('Past simple.'));
    expect(searchable, contains('Neutral.'));
    expect(searchable, isNot(contains('preserve')));
  });

  test('Lingua fixture preserves unknown fields and deterministic merge', () {
    final before = canonicalAnnotationDocumentJson(source);
    final decoded = decodeAnnotationDocument(source);

    expect(canonicalAnnotationDocumentJson(decoded), before);
    expect(decoded['futureDocumentField'], {'preserve': true});
    final annotation = (decoded['annotations'] as List).single as Map;
    expect(annotation['futureAnnotationField'], ['preserve']);
    final translation = (annotation['enrichments'] as List)
        .cast<Map>()
        .singleWhere((item) => item['kind'] == 'translation');
    expect(translation['futureMaterialField'], {'preserve': true});
    expect(canonicalJson(mergeAnnotationDocuments(decoded, source)), before);
  });
}
