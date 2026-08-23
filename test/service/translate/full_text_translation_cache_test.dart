import 'dart:async';
import 'dart:io';

import 'package:anx_reader/models/ai_provider.dart';
import 'package:anx_reader/models/full_text_translation_cache.dart';
import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/service/translate/full_text_translation_cache_service.dart';
import 'package:anx_reader/service/translate/index.dart';
import 'package:anx_reader/service/translate/translation_cache_database.dart';
import 'package:anx_reader/service/translate/translation_fingerprint.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await Prefs().initPrefs();
  });

  group('request identity', () {
    test('same complete request has the same key', () {
      expect(_request().requestKey, _request().requestKey);
    });

    test('identity changes with source, context, language, route, and prompt',
        () {
      final base = _request();
      expect(_request(source: 'other').requestKey, isNot(base.requestKey));
      expect(
          _request(source: ' source text').requestKey, isNot(base.requestKey));
      expect(_request(context: 'other').requestKey, isNot(base.requestKey));
      expect(_request(context: 'previous text ').requestKey,
          isNot(base.requestKey));
      expect(_request(target: 'de').requestKey, isNot(base.requestKey));
      expect(_request(provider: 'other').requestKey, isNot(base.requestKey));
      expect(_request(prompt: 'other').requestKey, isNot(base.requestKey));
    });

    test('AI fingerprint ignores keys and local provider ids', () {
      final first = _provider(id: 'local-a', key: 'secret-a');
      Prefs().saveAiProviders(<AiProvider>[first]);
      Prefs().selectedAiService = first.id;
      final firstFingerprint = buildProviderFingerprint(TranslateService.ai);

      final second = _provider(id: 'local-b', key: 'secret-b');
      Prefs().saveAiProviders(<AiProvider>[second]);
      Prefs().selectedAiService = second.id;
      final secondFingerprint = buildProviderFingerprint(TranslateService.ai);
      expect(secondFingerprint, firstFingerprint);
    });

    test('independently constructed effective configs fingerprint equally', () {
      Prefs().saveAiProviders(<AiProvider>[
        _provider(id: 'one', key: 'one'),
      ]);
      Prefs().selectedAiService = 'one';
      final first = buildProviderFingerprint(TranslateService.ai);
      Prefs().saveAiProviders(<AiProvider>[
        _provider(id: 'two', key: 'two'),
      ]);
      Prefs().selectedAiService = 'two';
      expect(buildProviderFingerprint(TranslateService.ai), first);
    });

    test('effective model change changes provider fingerprint', () {
      final first = _provider(id: 'one', key: 'one');
      Prefs().saveAiProviders(<AiProvider>[first]);
      Prefs().selectedAiService = first.id;
      final fingerprint = buildProviderFingerprint(TranslateService.ai);
      Prefs().saveAiProviders(<AiProvider>[
        first.copyWith(model: 'different-model'),
      ]);
      expect(buildProviderFingerprint(TranslateService.ai), isNot(fingerprint));
    });
  });

  group('persistent local cache', () {
    late Directory tempDir;
    late String databasePath;
    late TranslationCacheDatabase database;
    late FullTextTranslationCacheService cache;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('anx-translation-test-');
      databasePath = '${tempDir.path}/translation_cache.db';
      database = _databaseAt(databasePath);
      cache = FullTextTranslationCacheService(database: database);
    });

    tearDown(() async {
      await database.close();
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    test('miss invokes once, then memory-service and recreated-service hit',
        () async {
      var calls = 0;
      Future<String> provider() async {
        calls++;
        return 'translated';
      }

      expect(await cache.translate(_request(), provider), 'translated');
      expect(await cache.translate(_request(), provider), 'translated');
      expect(calls, 1);

      await database.close();
      database = _databaseAt(databasePath);
      cache = FullTextTranslationCacheService(database: database);
      expect(await cache.translate(_request(), provider), 'translated');
      expect(calls, 1);
    });

    test('provider failure and dirty output are not persisted', () async {
      expect(
        () => cache.translate(_request(), () => throw Exception('failure')),
        throwsException,
      );
      expect(
          await database.findIncludingDeleted(_request().requestKey), isNull);
      expect(
        await cache.translate(_request(), () async => 'Error: auth failed'),
        'Error: auth failed',
      );
      expect(
          await database.findIncludingDeleted(_request().requestKey), isNull);
    });

    test('corrupt historical output is a miss', () async {
      final request = _request();
      await database.upsert(TranslationCacheEntry.fromRequest(
        request,
        '<think>secret reasoning</think>',
        DateTime.utc(2026),
      ));
      var calls = 0;
      expect(
        await cache.translate(request, () async {
          calls++;
          return 'clean';
        }),
        'clean',
      );
      expect(calls, 1);
    });

    test('simultaneous identical requests invoke provider once', () async {
      final completer = Completer<String>();
      final started = Completer<void>();
      var calls = 0;
      Future<String> provider() {
        calls++;
        started.complete();
        return completer.future;
      }

      final first = cache.translate(_request(), provider);
      final second = cache.translate(_request(), provider);
      await started.future;
      expect(calls, 1);
      completer.complete('shared');
      expect(await Future.wait(<Future<String>>[first, second]),
          <String>['shared', 'shared']);
    });

    test('book clear tombstones only that book', () async {
      final first = _request(book: 'a' * 32);
      final second = _request(book: 'b' * 32);
      await cache.translate(first, () async => 'first');
      await cache.translate(second, () async => 'second');
      expect(await cache.clearBook(first.bookFingerprint), 1);
      expect(await database.find(first.requestKey), isNull);
      expect((await database.findIncludingDeleted(first.requestKey))?.deletedAt,
          isNotNull);
      expect(
          (await database.find(second.requestKey))?.translatedText, 'second');
    });

    test('pre-clear in-flight request cannot write, later request resurrects',
        () async {
      final request = _request();
      final completer = Completer<String>();
      final pending = cache.translate(request, () => completer.future);
      await Future<void>.delayed(Duration.zero);
      await cache.clearBook(request.bookFingerprint);
      completer.complete('stale result');
      expect(await pending, 'stale result');
      expect(await database.findIncludingDeleted(request.requestKey), isNull);

      await database.upsert(TranslationCacheEntry.fromRequest(
        request,
        'old',
        DateTime.utc(2025),
      ));
      await cache.clearBook(request.bookFingerprint);
      expect(await cache.translate(request, () async => 'new result'),
          'new result');
      final recreated = await database.find(request.requestKey);
      expect(recreated?.translatedText, 'new result');
      expect(recreated?.deletedAt, isNull);
    });
  });
}

FullTextTranslationRequest _request({
  String book = '0123456789abcdef0123456789abcdef',
  String source = 'source text',
  String context = 'previous text',
  String target = 'fr',
  String provider = 'provider',
  String prompt = 'prompt',
}) =>
    FullTextTranslationRequest(
      bookFingerprint: book,
      sourceLanguage: 'en',
      targetLanguage: target,
      translationService: 'ai',
      providerFingerprint: provider,
      promptFingerprint: prompt,
      sourceText: source,
      contextText: context,
    );

AiProvider _provider({required String id, required String key}) => AiProvider(
      id: id,
      title: 'Local display name',
      url: 'https://example.com/v1/chat/completions?secret=value',
      protocol: AiProtocol.openai,
      apiKeys: <AiApiKey>[AiApiKey(id: 'key-$id', key: key)],
      model: 'same-model',
    );

TranslationCacheDatabase _databaseAt(String path) => TranslationCacheDatabase(
      opener: () => databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: translationCacheDatabaseVersion,
          singleInstance: false,
          onCreate: TranslationCacheDatabase.createSchema,
        ),
      ),
    );
