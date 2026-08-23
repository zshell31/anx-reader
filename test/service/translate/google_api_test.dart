import 'dart:convert';
import 'dart:typed_data';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/enums/lang_list.dart';
import 'package:anx_reader/service/translate/google_api.dart';
import 'package:anx_reader/service/translate/index.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('Google Cloud Translation API', () {
    late _RecordingAdapter adapter;
    late GoogleApiTranslateProvider provider;

    setUp(() {
      adapter = _RecordingAdapter();
      provider = GoogleApiTranslateProvider(
        dio: Dio()..httpClientAdapter = adapter,
      );
    });

    test('posts mapped languages and API key outside the URL', () async {
      final results = await provider.translateStreamForRoute(
        'Hello',
        LangListEnum.english,
        LangListEnum.simplifiedChinese,
        routeSnapshot: <String, dynamic>{'api_key': 'test-api-key'},
      ).toList();

      expect(results, <String>['...', '你好']);
      expect(adapter.request?.method, 'POST');
      expect(adapter.request?.uri.toString(), googleTranslationApiEndpoint);
      expect(adapter.request?.uri.queryParameters, isEmpty);
      expect(adapter.request?.headers['X-Goog-Api-Key'], 'test-api-key');
      expect(adapter.request?.data, <String, dynamic>{
        'q': 'Hello',
        'target': 'zh-CN',
        'format': 'text',
        'source': 'en',
      });
    });

    test('omits source when language detection is automatic', () async {
      await provider.translateStreamForRoute(
        'Hello',
        LangListEnum.auto,
        LangListEnum.japanese,
        routeSnapshot: <String, dynamic>{'api_key': 'test-api-key'},
      ).drain<void>();

      expect(adapter.request?.data, <String, dynamic>{
        'q': 'Hello',
        'target': 'ja',
        'format': 'text',
      });
    });

    test('extracts translatedText from the documented response shape', () {
      expect(
        parseGoogleTranslationResponse(<String, dynamic>{
          'data': <String, dynamic>{
            'translations': <Map<String, String>>[
              <String, String>{'translatedText': 'Bonjour'},
            ],
          },
        }),
        'Bonjour',
      );
    });

    test('missing API key returns a controlled error without a request', () {
      final stream = provider.translateStreamForRoute(
        'Hello',
        LangListEnum.auto,
        LangListEnum.french,
        routeSnapshot: <String, dynamic>{'api_key': ''},
      );

      expect(
        stream,
        emitsError(
          isA<GoogleApiTranslationException>().having(
            (error) => error.message,
            'message',
            contains('Configure'),
          ),
        ),
      );
      expect(adapter.request, isNull);
    });

    test('403 returns a native configuration and quota error', () async {
      adapter.statusCode = 403;

      final stream = provider.translateStreamForRoute(
        'Hello',
        LangListEnum.auto,
        LangListEnum.french,
        routeSnapshot: <String, dynamic>{'api_key': 'test-api-key'},
      );

      await expectLater(
        stream,
        emitsInOrder(<dynamic>[
          '...',
          emitsError(
            isA<GoogleApiTranslationException>()
                .having(
                  (error) => error.message,
                  'message',
                  allOf(contains('API key'), contains('quota')),
                )
                .having(
                  (error) => error.message,
                  'message',
                  isNot(contains('test-api-key')),
                ),
          ),
        ]),
      );
    });

    test('malformed response returns a controlled error', () async {
      adapter.responseData = <String, dynamic>{'data': <String, dynamic>{}};

      final stream = provider.translateStreamForRoute(
        'Hello',
        LangListEnum.auto,
        LangListEnum.french,
        routeSnapshot: <String, dynamic>{'api_key': 'test-api-key'},
      );

      await expectLater(
        stream,
        emitsInOrder(<dynamic>[
          '...',
          emitsError(isA<GoogleApiTranslationException>()),
        ]),
      );
    });
  });

  group('selected-text translation service migration', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await Prefs().initPrefs();
    });

    test('persisted googleWeb selection migrates to googleApi', () async {
      await Prefs().prefs.setString('translateService', 'googleWeb');

      expect(Prefs().translateService, TranslateService.googleApi);
      expect(Prefs().prefs.getString('translateService'), 'googleApi');
      expect(TranslateService.selectionValues,
          isNot(contains(TranslateService.googleWeb)));
      expect(TranslateService.selectionValues,
          contains(TranslateService.googleApi));
    });

    test('setting googleWeb selection stores googleApi', () {
      Prefs().translateService = TranslateService.googleWeb;

      expect(Prefs().translateService, TranslateService.googleApi);
      expect(Prefs().prefs.getString('translateService'), 'googleApi');
    });

    test('unrelated providers are unchanged', () {
      const services = <TranslateService>[
        TranslateService.microsoftApi,
        TranslateService.deepl,
        TranslateService.ai,
        TranslateService.bingWeb,
      ];

      for (final service in services) {
        expect(service.forSelection, service);
        Prefs().translateService = service;
        expect(Prefs().translateService, service);
        expect(Prefs().prefs.getString('translateService'), service.name);
      }
    });
  });
}

class _RecordingAdapter implements HttpClientAdapter {
  RequestOptions? request;
  int statusCode = 200;
  dynamic responseData = <String, dynamic>{
    'data': <String, dynamic>{
      'translations': <Map<String, String>>[
        <String, String>{'translatedText': '你好'},
      ],
    },
  };

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
