import 'dart:convert';
import 'dart:async';
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

  test('lookup sends browser headers', () async {
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

  test('retries a timeout once using a fresh client and closes both', () async {
    final fixture = await File('test/fixtures/ldoce_entry.html').readAsString();
    final clients = <_TrackedClient>[];
    final service = LdoceAnnotationDictionaryService(
      timeout: const Duration(milliseconds: 10),
      retryDelay: Duration.zero,
      clientFactory: () {
        final first = clients.isEmpty;
        final client = _TrackedClient((_) async => first
            ? await Completer<http.Response>().future
            : http.Response(fixture, 200,
                headers: {'content-type': 'text/html; charset=utf-8'}));
        clients.add(client);
        return client;
      },
    );
    expect((await service.lookup('take')).entries, isNotEmpty);
    expect(clients, hasLength(2));
    expect(clients.every((client) => client.closed), isTrue);
  });

  test('persistent timeout stops after two attempts', () async {
    var attempts = 0;
    final service = LdoceAnnotationDictionaryService(
      timeout: const Duration(milliseconds: 10),
      retryDelay: Duration.zero,
      client: MockClient((_) {
        attempts++;
        return Completer<http.Response>().future;
      }),
    );
    await expectLater(service.lookup('take'), throwsA(isA<TimeoutException>()));
    expect(attempts, 2);
  });

  test('access denied is reported without retrying or parsing it as an entry',
      () async {
    var attempts = 0;
    final service = LdoceAnnotationDictionaryService(
      client: MockClient((_) async {
        attempts++;
        return http.Response('<h1>Forbidden</h1>', 403);
      }),
    );
    await expectLater(
        service.lookup('take'),
        throwsA(predicate(
          (error) => error.toString().contains('denied the request (HTTP 403)'),
        )));
    expect(attempts, 1);
  });

  test('not-found HTML returns a useful error', () {
    expect(
      () => parseLdoceArticle('<html><body>not found</body></html>', 'missing'),
      throwsA(predicate((error) => error.toString().contains('missing'))),
    );
  });
}

class _TrackedClient extends MockClient {
  _TrackedClient(super.fn);
  bool closed = false;
  @override
  void close() {
    closed = true;
    super.close();
  }
}
