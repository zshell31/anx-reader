import 'package:anx_reader/service/annotation_enrichment/google_annotation_translate.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('normalizes whitespace and URL-encodes the configured target', () {
    final uri = googleAnnotationTranslateUri(
      '  one\n two\tthree  ',
      targetLanguage: 'zh-CN',
    );
    expect(normalizeAnnotationTranslationText('  one\n two  '), 'one two');
    expect(uri.queryParameters, {
      'client': 'gtx',
      'sl': 'auto',
      'tl': 'zh-CN',
      'dt': 't',
      'q': 'one two three',
    });
  });

  test('parses one segment and detected language', () {
    final result = parseGoogleAnnotationTranslation([
      [
        ['Привет', 'Hello', null, null, 1],
      ],
      null,
      'en',
    ]);
    expect(result.text, 'Привет');
    expect(result.detectedLanguage, 'en');
  });

  test('joins multiple translation segments', () {
    final result = parseGoogleAnnotationTranslation([
      [
        ['Первое. ', 'First. ', null, null, 1],
        ['Второе.', 'Second.', null, null, 1],
      ],
      null,
      'en',
    ]);
    expect(result.text, 'Первое. Второе.');
  });

  test('rejects empty and malformed payloads', () {
    expect(
      () => parseGoogleAnnotationTranslation([]),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => parseGoogleAnnotationTranslation([
        [
          [null],
        ],
      ]),
      throwsA(isA<FormatException>()),
    );
  });

  test('HTTP failure is explicit without using live Google', () async {
    final service = GoogleAnnotationTranslateService(
      client: MockClient((_) async => http.Response('down', 503)),
    );
    await expectLater(
      service.translate('hello', targetLanguage: 'ru'),
      throwsA(predicate((error) => error.toString().contains('HTTP 503'))),
    );
  });
}
