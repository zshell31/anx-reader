import 'dart:async';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/enums/ai_prompts.dart';
import 'package:anx_reader/enums/lang_list.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/models/full_text_translation_cache.dart';
import 'package:anx_reader/service/md5_service.dart';
import 'package:anx_reader/service/ai/prompt_generate.dart';
import 'package:anx_reader/service/translate/index.dart';
import 'package:anx_reader/service/translate/translation_cache_database.dart';
import 'package:anx_reader/service/translate/translation_fingerprint.dart';
import 'package:anx_reader/utils/log/common.dart';

typedef TranslationProviderCall = Future<String> Function();
typedef TranslationClock = DateTime Function();

class FullTextTranslationCacheService {
  FullTextTranslationCacheService({
    TranslationCacheDatabase? database,
    TranslationClock? clock,
  })  : database = database ?? translationCacheDatabase,
        _clock = clock ?? DateTime.now;

  final TranslationCacheDatabase database;
  final TranslationClock _clock;
  final Map<FullTextTranslationRequest, Future<String>> _inFlight =
      <FullTextTranslationRequest, Future<String>>{};
  final Map<String, int> _bookGenerations = <String, int>{};
  int _globalGeneration = 0;
  Future<void> _mutationTail = Future<void>.value();

  Future<String> translate(
    FullTextTranslationRequest request,
    TranslationProviderCall providerCall, {
    bool persistent = true,
  }) async {
    final existing = _inFlight[request];
    if (existing != null) return existing;

    final bookGeneration = _generationFor(request.bookFingerprint);
    final globalGeneration = _globalGeneration;
    late final Future<String> future;
    future = _translateShared(
      request,
      providerCall,
      persistent: persistent,
      bookGeneration: bookGeneration,
      globalGeneration: globalGeneration,
    );
    _inFlight[request] = future;
    try {
      return await future;
    } finally {
      if (identical(_inFlight[request], future)) {
        _inFlight.remove(request);
      }
    }
  }

  Future<String> _translateShared(
    FullTextTranslationRequest request,
    TranslationProviderCall providerCall, {
    required bool persistent,
    required int bookGeneration,
    required int globalGeneration,
  }) async {
    if (persistent) {
      final cached = await database.find(request.requestKey);
      if (cached != null &&
          cached.matchesRequest(request) &&
          isCacheableFullTextTranslation(cached.translatedText)) {
        return cached.translatedText;
      }
      if (cached != null) {
        AnxLog.warning(
            'Ignoring inconsistent full-text translation cache entry');
      }
    }

    final translatedText = await providerCall();
    if (!isCacheableFullTextTranslation(translatedText)) {
      return translatedText;
    }

    if (!persistent ||
        globalGeneration != _globalGeneration ||
        bookGeneration != _generationFor(request.bookFingerprint)) {
      return translatedText;
    }

    await _mutate(() async {
      if (globalGeneration != _globalGeneration ||
          bookGeneration != _generationFor(request.bookFingerprint)) {
        return;
      }
      final previous = await database.findIncludingDeleted(request.requestKey);
      if (previous != null && !previous.matchesRequest(request)) {
        AnxLog.severe(
            'Translation cache request-key collision; result was not persisted');
        return;
      }
      final now = _clock().toUtc();
      await database.upsert(TranslationCacheEntry.fromRequest(
        request,
        translatedText,
        now,
        createdAt: previous?.createdAt,
      ));
    });
    return translatedText;
  }

  Future<int> clearBook(String bookFingerprint) async {
    final normalized = bookFingerprint.toLowerCase();
    _bookGenerations[normalized] = _generationFor(normalized) + 1;
    var count = 0;
    await _mutate(() async {
      count = await database.tombstoneBook(normalized, _clock().toUtc());
    });
    return count;
  }

  Future<int> activeCountForBook(String bookFingerprint) =>
      database.activeCountForBook(bookFingerprint.toLowerCase());

  void invalidateBookInFlightWrites(String bookFingerprint) {
    final normalized = bookFingerprint.toLowerCase();
    _bookGenerations[normalized] = _generationFor(normalized) + 1;
  }

  void invalidateAllInFlightWrites() {
    _globalGeneration++;
  }

  Future<void> synchronizeSemanticMutation(
    Future<void> Function() action,
  ) =>
      _mutate(action);

  int _generationFor(String fingerprint) =>
      _bookGenerations[fingerprint.toLowerCase()] ?? 0;

  Future<void> _mutate(Future<void> Function() action) {
    final completer = Completer<void>();
    final previous = _mutationTail;
    _mutationTail = completer.future;
    return previous.then((_) => action()).whenComplete(completer.complete);
  }
}

bool isCacheableFullTextTranslation(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty || trimmed == '...') return false;
  final lower = trimmed.toLowerCase();
  if (lower.startsWith('error:') ||
      lower.startsWith('translation error:') ||
      lower.startsWith('translate error:') ||
      lower.contains('translation failed after') ||
      lower.contains('authentication failed') ||
      lower.contains('invalid api key') ||
      lower.contains('api key in settings') ||
      lower.contains('service not configured') ||
      lower.contains('<think>') ||
      lower.contains('</think>')) {
    return false;
  }
  const promptLeaks = <String>[
    'you are a professional translator',
    'current source text to translate:',
    'translate only the current source text',
    'output only the translation of the current source text',
  ];
  return !promptLeaks.any(lower.contains);
}

class FullTextTranslationCoordinator {
  FullTextTranslationCoordinator({FullTextTranslationCacheService? cache})
      : cache = cache ?? fullTextTranslationCacheService;

  final FullTextTranslationCacheService cache;

  Future<String> translate({
    required String text,
    required String contextText,
    required Book book,
    required TranslateService service,
    required LangListEnum from,
    required LangListEnum to,
  }) async {
    final provider = service.provider;
    final routeSnapshot = provider.captureRouteSnapshot();
    final effectivePrompt = service == TranslateService.ai
        ? Prefs().getAiPrompt(AiPrompts.fullTextTranslate)
        : '';
    final fingerprint = await resolveBookFingerprint(book);
    final persistent = fingerprint != null && !service.isWebView;
    final request = FullTextTranslationRequest(
      bookFingerprint: fingerprint ?? '',
      sourceLanguage: from.code,
      targetLanguage: to.code,
      translationService: service.name,
      providerFingerprint: buildProviderFingerprint(
        service,
        routeSnapshot: routeSnapshot,
      ),
      promptFingerprint:
          sha256Text(normalizePromptForFingerprint(effectivePrompt)),
      sourceText: text,
      contextText: contextText,
    );
    return cache.translate(
      request,
      () => provider.translateTextOnly(
        text,
        from,
        to,
        contextText: contextText,
        isFullText: true,
        routeSnapshot: routeSnapshot,
      ),
      persistent: persistent,
    );
  }

  Future<String?> resolveBookFingerprint(Book book) async {
    final existing = book.md5?.trim().toLowerCase();
    if (existing != null && RegExp(r'^[0-9a-f]{32}$').hasMatch(existing)) {
      return existing;
    }
    final calculated =
        (await MD5Service.calculateFileMd5(book.fileFullPath))?.toLowerCase();
    if (calculated == null || calculated.isEmpty) return null;
    await bookDao.updateBookMd5(book.id, calculated);
    book.md5 = calculated;
    return calculated;
  }
}

final fullTextTranslationCacheService = FullTextTranslationCacheService();
final fullTextTranslationCoordinator = FullTextTranslationCoordinator();
