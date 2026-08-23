import 'dart:convert';
import 'dart:typed_data';

import 'package:anx_reader/enums/lang_list.dart';
import 'package:anx_reader/service/translate/google_translate.dart';
import 'package:anx_reader/service/translate/index.dart';
import 'package:anx_reader/service/translate/web_view.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Google Translate', () {
    late _RecordingAdapter adapter;
    late GoogleTranslateProvider provider;

    setUp(() {
      adapter = _RecordingAdapter();
      provider = GoogleTranslateProvider(
        dio: Dio()..httpClientAdapter = adapter,
      );
    });

    test('requires no API key and has no configuration', () async {
      final results = await provider
          .translateStream(
            'Hello',
            LangListEnum.auto,
            LangListEnum.french,
          )
          .toList();

      expect(results, <String>['...', 'Bonjour']);
      expect(provider.getConfig(), isEmpty);
    });

    test('uses the keyless endpoint with automatic source detection', () async {
      await provider
          .translateStream(
            'Hello',
            LangListEnum.auto,
            LangListEnum.french,
          )
          .drain<void>();

      expect(adapter.request?.method, 'GET');
      expect(
        adapter.request?.uri,
        isA<Uri>()
            .having((uri) => uri.scheme, 'scheme', 'https')
            .having((uri) => uri.host, 'host', 'translate.googleapis.com')
            .having((uri) => uri.path, 'path', '/translate_a/single'),
      );
      expect(adapter.request?.uri.queryParameters, <String, String>{
        'client': 'gtx',
        'sl': 'auto',
        'tl': 'fr',
        'dt': 't',
        'q': 'Hello',
      });
      expect(adapter.request?.uri.queryParameters, isNot(contains('key')));
    });

    test('maps explicit source and target languages', () async {
      await provider
          .translateStream(
            'Hello',
            LangListEnum.english,
            LangListEnum.simplifiedChinese,
          )
          .drain<void>();

      expect(adapter.request?.uri.queryParameters['sl'], 'en');
      expect(adapter.request?.uri.queryParameters['tl'], 'zh-CN');
    });

    test('parses one translated segment', () {
      expect(
        parseGoogleTranslateResponse(<dynamic>[
          <dynamic>[
            <dynamic>['Bonjour', 'Hello', null, null],
          ],
        ]),
        'Bonjour',
      );
    });

    test('concatenates every valid translated segment', () {
      expect(
        parseGoogleTranslateResponse(<dynamic>[
          <dynamic>[
            <dynamic>['Bon', 'Good', null, null],
            <dynamic>[null, null, null, null],
            <dynamic>['jour', 'morning', null, null],
            <dynamic>[],
          ],
        ]),
        'Bonjour',
      );
    });

    test('malformed response produces a controlled error', () async {
      adapter.responseData = <String, dynamic>{'unexpected': true};

      await expectLater(
        provider.translateStream(
          'Hello',
          LangListEnum.auto,
          LangListEnum.french,
        ),
        emitsInOrder(<dynamic>[
          '...',
          emitsError(isA<GoogleTranslateException>()),
        ]),
      );
    });

    test('HTTP error produces a controlled native error', () async {
      adapter.statusCode = 429;

      await expectLater(
        provider.translateStream(
          'Hello',
          LangListEnum.auto,
          LangListEnum.french,
        ),
        emitsInOrder(<dynamic>[
          '...',
          emitsError(
            isA<GoogleTranslateException>().having(
              (error) => error.message,
              'message',
              contains('429'),
            ),
          ),
        ]),
      );
    });

    test('googleWeb uses the native keyless provider', () {
      expect(
          TranslateService.googleWeb.provider, isA<GoogleTranslateProvider>());
      expect(TranslateService.googleWeb.provider,
          isNot(isA<WebViewTranslateProvider>()));
      expect(TranslateService.googleWeb.provider.getConfig(), isEmpty);
    });

    test('full-text provider choices remain unchanged', () {
      expect(TranslateService.fullTextValues,
          isNot(contains(TranslateService.googleWeb)));
      expect(TranslateService.fullTextValues,
          isNot(contains(TranslateService.bingWeb)));
      expect(TranslateService.fullTextValues,
          contains(TranslateService.googleApi));
    });
  });
}

class _RecordingAdapter implements HttpClientAdapter {
  RequestOptions? request;
  int statusCode = 200;
  dynamic responseData = <dynamic>[
    <dynamic>[
      <dynamic>['Bonjour', 'Hello', null, null],
    ],
  ];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    request = options;
    return ResponseBody.fromString(
      jsonEncode(responseData),
      statusCode,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
