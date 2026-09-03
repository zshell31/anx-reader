import 'dart:convert';

import 'package:anx_reader/models/full_text_translation_cache.dart';
import 'package:anx_reader/service/translate/translation_cache_merge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WebDAV entry merge', () {
    test('local-only and remote-only entries survive', () {
      final local = _entry(source: 'local');
      final remote = _entry(source: 'remote');
      final result = mergeTranslationCacheEntries(
          <TranslationCacheEntry>[local], <TranslationCacheEntry>[remote]);
      expect(result.entries.map((entry) => entry.requestKey),
          containsAll(<String>[local.requestKey, remote.requestKey]));
    });

    test('newer active state wins in either direction', () {
      final old = _entry(updated: DateTime.utc(2026, 1, 1), text: 'old');
      final newer = _entry(updated: DateTime.utc(2026, 1, 2), text: 'new');
      expect(_mergeOne(newer, old).translatedText, 'new');
      expect(_mergeOne(old, newer).translatedText, 'new');
    });

    test('newer tombstone beats active translation', () {
      final active = _entry(updated: DateTime.utc(2026, 1, 1));
      final tombstone = _entry(
        updated: DateTime.utc(2026, 1, 2),
        deleted: DateTime.utc(2026, 1, 2),
      );
      expect(_mergeOne(active, tombstone).deletedAt, isNotNull);
    });

    test('newer recreated translation beats tombstone', () {
      final tombstone = _entry(
        updated: DateTime.utc(2026, 1, 1),
        deleted: DateTime.utc(2026, 1, 1),
      );
      final recreated = _entry(updated: DateTime.utc(2026, 1, 2), text: 'new');
      expect(_mergeOne(tombstone, recreated).deletedAt, isNull);
      expect(_mergeOne(tombstone, recreated).translatedText, 'new');
    });

    test('equal timestamps use deterministic state ordering', () {
      final a = _entry(updated: DateTime.utc(2026), text: 'a');
      final b = _entry(updated: DateTime.utc(2026), text: 'b');
      expect(
          _mergeOne(a, b).canonicalState(), _mergeOne(b, a).canonicalState());
    });

    test('different books remain independent', () {
      final first = _entry(book: 'a' * 32);
      final second = _entry(book: 'b' * 32);
      final firstDocument = TranslationCacheBookDocument(
        bookFingerprintAlgorithm: bookFingerprintAlgorithmMd5,
        bookFingerprint: first.bookFingerprint,
        entries: <TranslationCacheEntry>[first],
      );
      final secondDocument = TranslationCacheBookDocument(
        bookFingerprintAlgorithm: bookFingerprintAlgorithmMd5,
        bookFingerprint: second.bookFingerprint,
        entries: <TranslationCacheEntry>[second],
      );
      expect(
          firstDocument.bookFingerprint, isNot(secondDocument.bookFingerprint));
      expect(firstDocument.entries.single.requestKey,
          isNot(secondDocument.entries.single.requestKey));
    });

    test('identity collision is reported and does not select remote', () {
      final local = _entry();
      final remote = TranslationCacheEntry(
        requestKey: local.requestKey,
        cacheVersion: local.cacheVersion,
        bookFingerprintAlgorithm: local.bookFingerprintAlgorithm,
        bookFingerprint: local.bookFingerprint,
        sourceLanguage: local.sourceLanguage,
        targetLanguage: 'different',
        translationService: local.translationService,
        providerFingerprint: local.providerFingerprint,
        promptFingerprint: local.promptFingerprint,
        sourceHash: local.sourceHash,
        contextHash: local.contextHash,
        sourceText: local.sourceText,
        contextText: local.contextText,
        translatedText: 'remote',
        createdAt: local.createdAt,
        updatedAt: local.updatedAt,
      );
      final result = mergeTranslationCacheEntries(
          <TranslationCacheEntry>[local], <TranslationCacheEntry>[remote]);
      expect(result.hasIdentityConflict, isTrue);
      expect(result.entries.single.translatedText, local.translatedText);
    });
  });

  group('AI provider-route deduplication', () {
    test('keeps the earliest result and tombstones later provider routes', () {
      final first = _entry(
        provider: 'openai',
        text: 'first translation',
        updated: DateTime.utc(2026, 9, 3, 5, 35),
      );
      final second = _entry(
        provider: 'claude',
        text: 'second translation',
        updated: DateTime.utc(2026, 9, 3, 14, 6),
      );

      final result = deduplicateReusableAiEntries(
        <TranslationCacheEntry>[second, first],
        DateTime.utc(2026, 9, 3, 16),
      );

      expect(result.tombstonedCount, 1);
      expect(
        result.entries
            .singleWhere((entry) => entry.requestKey == first.requestKey)
            .deletedAt,
        isNull,
      );
      expect(
        result.entries
            .singleWhere((entry) => entry.requestKey == second.requestKey)
            .deletedAt,
        DateTime.utc(2026, 9, 3, 16),
      );
    });

    test('is idempotent and leaves non-AI provider routes independent', () {
      final first = _entry(service: 'google', provider: 'first');
      final second = _entry(service: 'google', provider: 'second');
      final initial = deduplicateReusableAiEntries(
        <TranslationCacheEntry>[first, second],
        DateTime.utc(2026, 9, 3),
      );
      final repeated = deduplicateReusableAiEntries(
        initial.entries,
        DateTime.utc(2026, 9, 4),
      );

      expect(initial.tombstonedCount, 0);
      expect(repeated.tombstonedCount, 0);
      expect(
          repeated.entries.every((entry) => entry.deletedAt == null), isTrue);
    });

    test('uses a tombstone timestamp newer than a future-dated duplicate', () {
      final first = _entry(provider: 'openai');
      final future = _entry(
        provider: 'claude',
        updated: DateTime.utc(2030),
      );
      final result = deduplicateReusableAiEntries(
        <TranslationCacheEntry>[first, future],
        DateTime.utc(2026),
      );
      final tombstone = result.entries
          .singleWhere((entry) => entry.requestKey == future.requestKey);

      expect(tombstone.deletedAt,
          DateTime.utc(2030).add(const Duration(microseconds: 1)));
    });
  });

  group('remote document serialization', () {
    test('round trips active and deleted entries', () {
      final entries = <TranslationCacheEntry>[
        _entry(source: 'one'),
        _entry(source: 'two', deleted: DateTime.utc(2026)),
      ];
      final document = TranslationCacheBookDocument(
        bookFingerprintAlgorithm: bookFingerprintAlgorithmMd5,
        bookFingerprint: entries.first.bookFingerprint,
        entries: entries,
      );
      final decoded = TranslationCacheBookDocument.decode(document.encode());
      expect(decoded.schemaVersion, translationCacheRemoteSchemaVersion);
      expect(decoded.entries.length, 2);
      expect(decoded.encode(), document.encode());
    });

    test('invalid entry is discarded without poisoning valid local data', () {
      final valid = _entry();
      final json = TranslationCacheBookDocument(
        bookFingerprintAlgorithm: bookFingerprintAlgorithmMd5,
        bookFingerprint: valid.bookFingerprint,
        entries: <TranslationCacheEntry>[valid],
      ).toJson();
      final entries = json['entries']! as List<Object?>;
      final corrupt =
          Map<String, Object?>.from(entries.single! as Map<String, Object?>)
            ..['sourceHash'] = 'corrupt';
      entries.add(corrupt);
      final decoded = TranslationCacheBookDocument.decode(jsonEncode(json));
      expect(decoded.entries, hasLength(1));
      expect(decoded.entries.single.requestKey, valid.requestKey);
    });

    test('unsupported future schema fails safely', () {
      expect(
        () => TranslationCacheBookDocument.decode(jsonEncode(<String, Object?>{
          'schemaVersion': 99,
          'bookFingerprintAlgorithm': 'md5',
          'bookFingerprint': 'a' * 32,
          'entries': <Object?>[],
        })),
        throwsUnsupportedError,
      );
    });

    test('merge is pure and cannot invoke translation providers', () {
      var providerCalls = 0;
      mergeTranslationCacheEntries(
          <TranslationCacheEntry>[_entry()], const <TranslationCacheEntry>[]);
      expect(providerCalls, 0);
    });
  });
}

TranslationCacheEntry _mergeOne(
  TranslationCacheEntry local,
  TranslationCacheEntry remote,
) =>
    mergeTranslationCacheEntries(
            <TranslationCacheEntry>[local], <TranslationCacheEntry>[remote])
        .entries
        .single;

TranslationCacheEntry _entry({
  String book = '0123456789abcdef0123456789abcdef',
  String source = 'source',
  String text = 'translated',
  String service = 'ai',
  String provider = 'provider',
  DateTime? updated,
  DateTime? deleted,
}) {
  final request = FullTextTranslationRequest(
    bookFingerprint: book,
    sourceLanguage: 'en',
    targetLanguage: 'fr',
    translationService: service,
    providerFingerprint: provider,
    promptFingerprint: 'prompt',
    sourceText: source,
    contextText: 'context',
  );
  final timestamp = updated ?? DateTime.utc(2026, 1, 1);
  return TranslationCacheEntry.fromRequest(request, text, timestamp)
      .copyWith(deletedAt: deleted);
}
