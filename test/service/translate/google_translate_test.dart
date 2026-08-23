import 'package:anx_reader/enums/lang_list.dart';
import 'package:anx_reader/service/translate/google_translate.dart';
import 'package:anx_reader/service/translate/index.dart';
import 'package:anx_reader/service/translate/web_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';

void main() {
  group('Google ML Kit selection translation', () {
    late _FakeGoogleMlKitClient client;
    late GoogleTranslateProvider provider;

    setUp(() {
      client = _FakeGoogleMlKitClient();
      provider = GoogleTranslateProvider(client: client);
    });

    test('requires no API key and has no saved configuration', () {
      expect(provider.getConfig(), isEmpty);
      expect(
        provider.getConfigItems(_FakeBuildContext()).map((item) => item.key),
        isNot(contains('api_key')),
      );
    });

    test('maps explicit source and target languages', () async {
      client.installedModels.addAll(<String>{'en', 'zh'});

      final results = await provider
          .translateStream(
            'Hello',
            LangListEnum.english,
            LangListEnum.simplifiedChinese,
          )
          .toList();

      expect(results, <String>['...', 'translated']);
      expect(client.translatedSource, TranslateLanguage.english);
      expect(client.translatedTarget, TranslateLanguage.chinese);
      expect(client.identifyCalls, 0);
    });

    test('Auto uses a reliable concrete source when available', () async {
      provider = GoogleTranslateProvider(
        client: client,
        reliableSourceLanguage: LangListEnum.french,
      );
      client.installedModels.addAll(<String>{'fr', 'de'});

      await provider
          .translateStream(
            'bonjour',
            LangListEnum.auto,
            LangListEnum.german,
          )
          .drain<void>();

      expect(client.identifyCalls, 0);
      expect(client.translatedSource, TranslateLanguage.french);
    });

    test('Auto falls back to local language identification', () async {
      client.identifiedLanguage = 'es';
      client.installedModels.addAll(<String>{'es', 'en'});

      await provider
          .translateStream(
            'Hola',
            LangListEnum.auto,
            LangListEnum.english,
          )
          .drain<void>();

      expect(client.identifyCalls, 1);
      expect(client.translatedSource, TranslateLanguage.spanish);
    });

    test('undetermined Auto source returns a controlled error', () async {
      client.identifiedLanguage = 'und';

      await expectLater(
        provider.translateStream(
          'x',
          LangListEnum.auto,
          LangListEnum.english,
        ),
        emitsInOrder(<dynamic>[
          '...',
          emitsError(
            isA<GoogleTranslateException>().having(
              (error) => error.message,
              'message',
              contains('Choose it explicitly'),
            ),
          ),
        ]),
      );
      expect(client.checkedModels, isEmpty);
    });

    test('unsupported language returns a controlled error', () async {
      await expectLater(
        provider.translateStream(
          'Qırım',
          LangListEnum.crimeanTatarLatin,
          LangListEnum.english,
        ),
        emitsInOrder(<dynamic>[
          '...',
          emitsError(
            isA<GoogleTranslateException>().having(
              (error) => error.message,
              'message',
              contains('not supported'),
            ),
          ),
        ]),
      );
      expect(client.checkedModels, isEmpty);
    });

    test('already-downloaded models are not downloaded again', () async {
      client.installedModels.addAll(<String>{'en', 'fr'});

      await provider
          .translateStream(
            'Hello',
            LangListEnum.english,
            LangListEnum.french,
          )
          .drain<void>();

      expect(client.checkedModels, <String>['en', 'fr']);
      expect(client.downloadedModels, isEmpty);
      expect(client.events.last, 'translate');
    });

    test('missing models download before translation', () async {
      final results = await provider
          .translateStream(
            'Hello',
            LangListEnum.english,
            LangListEnum.french,
          )
          .toList();

      expect(results, <String>[
        '...',
        googleTranslateDownloadingModelStatus,
        'translated',
      ]);
      expect(client.downloadedModels, <String>['en', 'fr']);
      expect(client.events, <String>[
        'check:en',
        'download:en',
        'check:fr',
        'download:fr',
        'translate',
      ]);
    });

    test('model-download failure produces a controlled error', () async {
      client.downloadSucceeds = false;

      await expectLater(
        provider.translateStream(
          'Hello',
          LangListEnum.english,
          LangListEnum.french,
        ),
        emitsInOrder(<dynamic>[
          '...',
          googleTranslateDownloadingModelStatus,
          emitsError(
            isA<GoogleTranslateException>().having(
              (error) => error.message,
              'message',
              contains('download'),
            ),
          ),
        ]),
      );
      expect(client.events, <String>['check:en', 'download:en']);
    });

    test('translation failure produces a controlled error', () async {
      client.installedModels.addAll(<String>{'en', 'fr'});
      client.translationError = StateError('native detail');

      await expectLater(
        provider.translateStream(
          'Hello',
          LangListEnum.english,
          LangListEnum.french,
        ),
        emitsInOrder(<dynamic>[
          '...',
          emitsError(
            isA<GoogleTranslateException>()
                .having(
                  (error) => error.message,
                  'message',
                  contains('Unable to translate'),
                )
                .having(
                  (error) => error.message,
                  'message',
                  isNot(contains('native detail')),
                ),
          ),
        ]),
      );
    });

    test('unsupported platform produces a controlled result', () async {
      client.supported = false;

      await expectLater(
        provider.translateStream(
          'Hello',
          LangListEnum.english,
          LangListEnum.french,
        ),
        emitsError(
          isA<GoogleTranslateException>().having(
            (error) => error.message,
            'message',
            contains('not supported on this platform'),
          ),
        ),
      );
      expect(client.events, isEmpty);
    });

    test('googleWeb resolves to ML Kit rather than a WebView', () {
      expect(
        TranslateService.googleWeb.provider,
        isA<GoogleTranslateProvider>(),
      );
      expect(
        TranslateService.googleWeb.provider,
        isNot(isA<WebViewTranslateProvider>()),
      );
      expect(TranslateService.googleWeb.provider.getConfig(), isEmpty);
    });

    test('full-text provider choices remain unchanged', () {
      expect(
        TranslateService.fullTextValues,
        isNot(contains(TranslateService.googleWeb)),
      );
      expect(
        TranslateService.fullTextValues,
        isNot(contains(TranslateService.bingWeb)),
      );
      expect(
        TranslateService.fullTextValues,
        contains(TranslateService.googleApi),
      );
    });
  });
}

class _FakeBuildContext extends Fake implements BuildContext {}

class _FakeGoogleMlKitClient implements GoogleMlKitClient {
  bool supported = true;
  bool downloadSucceeds = true;
  String identifiedLanguage = 'en';
  String translatedText = 'translated';
  Object? translationError;
  int identifyCalls = 0;
  TranslateLanguage? translatedSource;
  TranslateLanguage? translatedTarget;
  final Set<String> installedModels = <String>{};
  final List<String> checkedModels = <String>[];
  final List<String> downloadedModels = <String>[];
  final List<String> events = <String>[];

  @override
  bool get isSupported => supported;

  @override
  Future<String> identifyLanguage(String text) async {
    identifyCalls++;
    return identifiedLanguage;
  }

  @override
  Future<bool> isModelDownloaded(String languageCode) async {
    checkedModels.add(languageCode);
    events.add('check:$languageCode');
    return installedModels.contains(languageCode);
  }

  @override
  Future<bool> downloadModel(String languageCode) async {
    downloadedModels.add(languageCode);
    events.add('download:$languageCode');
    if (downloadSucceeds) installedModels.add(languageCode);
    return downloadSucceeds;
  }

  @override
  Future<String> translate(
    String text,
    TranslateLanguage source,
    TranslateLanguage target,
  ) async {
    events.add('translate');
    translatedSource = source;
    translatedTarget = target;
    if (translationError != null) throw translationError!;
    return translatedText;
  }
}
