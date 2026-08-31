import 'dart:convert';
import 'dart:io';

import 'package:anx_reader/service/annotation_enrichment/ldoce_annotation_dictionary.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('builds a normalized LDOCE URL', () {
    expect(
      ldoceAnnotationDictionaryUri(" Take it for granted ").toString(),
      'https://www.ldoceonline.com/dictionary/take-it-for-granted',
    );
  });

  test('parses headword, POS, pronunciation, senses, labels, and examples',
      () async {
    final fixture = await File('test/fixtures/ldoce_entry.html').readAsString();
    final article = parseLdoceArticle(fixture, 'take');

    expect(article.title, 'take');
    expect(article.entries, hasLength(1));
    final entry = article.entries.single;
    expect(entry.headword, 'take');
    expect(entry.partOfSpeech, 'verb');
    expect(entry.pronunciation, '/teɪk/');
    expect(entry.senses, hasLength(2));
    expect(entry.senses.first.labels, ['transitive']);
    expect(entry.senses.first.examples, hasLength(2));
    expect(entry.senses.last.phrase, 'take it for granted');
    expect(article.shortDefinition, 'to move something from one place');
  });

  test('formats the complete article as markdown', () async {
    final fixture = await File('test/fixtures/ldoce_entry.html').readAsString();
    final markdown = ldoceArticleToMarkdown(parseLdoceArticle(fixture, 'take'));

    expect(markdown, contains('**LDOCE · take · verb**'));
    expect(markdown, contains('Pronunciation: /teɪk/'));
    expect(markdown, contains('_transitive_'));
    expect(markdown, contains('Take the book with you.'));
    expect(markdown, contains('**take it for granted**'));
  });

  test('lookup identifies as a browser accepted by LDOCE', () async {
    final fixture = await File('test/fixtures/ldoce_entry.html').readAsString();
    late Map<String, String> headers;
    final service = LdoceAnnotationDictionaryService(
      client: MockClient((request) async {
        headers = request.headers;
        return http.Response.bytes(
          utf8.encode(fixture),
          200,
          headers: const {'content-type': 'text/html; charset=utf-8'},
        );
      }),
    );

    final article = await service.lookup('take');

    expect(headers['user-agent'], contains('Mozilla/5.0'));
    expect(article.entries, isNotEmpty);
  });

  test('not-found HTML returns a useful error', () {
    expect(
      () => parseLdoceArticle('<html><body>not found</body></html>', 'missing'),
      throwsA(predicate((error) => error.toString().contains('missing'))),
    );
  });
}
