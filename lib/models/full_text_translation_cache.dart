import 'dart:convert';

import 'package:crypto/crypto.dart';

const int fullTextTranslationCacheVersion = 1;
const int translationCacheRemoteSchemaVersion = 1;
const String translationCacheNamespace = 'anx.full_text_translation';
const String bookFingerprintAlgorithmMd5 = 'md5';

String sha256Text(String value) =>
    sha256.convert(utf8.encode(value)).toString();

class FullTextTranslationRequest {
  FullTextTranslationRequest({
    required String bookFingerprint,
    required this.sourceLanguage,
    required this.targetLanguage,
    required this.translationService,
    required this.providerFingerprint,
    required this.promptFingerprint,
    required this.sourceText,
    required this.contextText,
    this.cacheVersion = fullTextTranslationCacheVersion,
    this.bookFingerprintAlgorithm = bookFingerprintAlgorithmMd5,
  })  : bookFingerprint = bookFingerprint.toLowerCase(),
        sourceHash = sha256Text(sourceText),
        contextHash = sha256Text(contextText) {
    requestKey = sha256Text(jsonEncode(<Object?>[
      translationCacheNamespace,
      cacheVersion,
      bookFingerprintAlgorithm,
      this.bookFingerprint,
      sourceLanguage,
      targetLanguage,
      translationService,
      providerFingerprint,
      promptFingerprint,
      sourceText,
      contextText,
    ]));
  }

  final int cacheVersion;
  final String bookFingerprintAlgorithm;
  final String bookFingerprint;
  final String sourceLanguage;
  final String targetLanguage;
  final String translationService;
  final String providerFingerprint;
  final String promptFingerprint;
  final String sourceHash;
  final String contextHash;
  final String sourceText;
  final String contextText;
  late final String requestKey;

  List<Object?> get exactIdentity => <Object?>[
        cacheVersion,
        bookFingerprintAlgorithm,
        bookFingerprint,
        sourceLanguage,
        targetLanguage,
        translationService,
        providerFingerprint,
        promptFingerprint,
        sourceHash,
        contextHash,
        sourceText,
        contextText,
      ];

  @override
  bool operator ==(Object other) =>
      other is FullTextTranslationRequest &&
      _listEquals(exactIdentity, other.exactIdentity);

  @override
  int get hashCode => Object.hashAll(exactIdentity);
}

class TranslationCacheEntry {
  const TranslationCacheEntry({
    required this.requestKey,
    required this.cacheVersion,
    required this.bookFingerprintAlgorithm,
    required this.bookFingerprint,
    required this.sourceLanguage,
    required this.targetLanguage,
    required this.translationService,
    required this.providerFingerprint,
    required this.promptFingerprint,
    required this.sourceHash,
    required this.contextHash,
    required this.sourceText,
    required this.contextText,
    required this.translatedText,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
  });

  factory TranslationCacheEntry.fromRequest(
    FullTextTranslationRequest request,
    String translatedText,
    DateTime now, {
    DateTime? createdAt,
  }) =>
      TranslationCacheEntry(
        requestKey: request.requestKey,
        cacheVersion: request.cacheVersion,
        bookFingerprintAlgorithm: request.bookFingerprintAlgorithm,
        bookFingerprint: request.bookFingerprint,
        sourceLanguage: request.sourceLanguage,
        targetLanguage: request.targetLanguage,
        translationService: request.translationService,
        providerFingerprint: request.providerFingerprint,
        promptFingerprint: request.promptFingerprint,
        sourceHash: request.sourceHash,
        contextHash: request.contextHash,
        sourceText: request.sourceText,
        contextText: request.contextText,
        translatedText: translatedText,
        createdAt: createdAt ?? now,
        updatedAt: now,
      );

  final String requestKey;
  final int cacheVersion;
  final String bookFingerprintAlgorithm;
  final String bookFingerprint;
  final String sourceLanguage;
  final String targetLanguage;
  final String translationService;
  final String providerFingerprint;
  final String promptFingerprint;
  final String sourceHash;
  final String contextHash;
  final String sourceText;
  final String contextText;
  final String translatedText;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  List<Object?> get exactIdentity => <Object?>[
        cacheVersion,
        bookFingerprintAlgorithm,
        bookFingerprint,
        sourceLanguage,
        targetLanguage,
        translationService,
        providerFingerprint,
        promptFingerprint,
        sourceHash,
        contextHash,
        sourceText,
        contextText,
      ];

  bool matchesRequest(FullTextTranslationRequest request) =>
      requestKey == request.requestKey &&
      _listEquals(exactIdentity, request.exactIdentity) &&
      sourceHash == sha256Text(sourceText) &&
      contextHash == sha256Text(contextText);

  bool hasSameIdentity(TranslationCacheEntry other) =>
      requestKey == other.requestKey &&
      _listEquals(exactIdentity, other.exactIdentity);

  TranslationCacheEntry tombstone(DateTime now) => copyWith(
        updatedAt: now,
        deletedAt: now,
      );

  TranslationCacheEntry copyWith({
    String? translatedText,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? deletedAt,
    bool clearDeletedAt = false,
  }) =>
      TranslationCacheEntry(
        requestKey: requestKey,
        cacheVersion: cacheVersion,
        bookFingerprintAlgorithm: bookFingerprintAlgorithm,
        bookFingerprint: bookFingerprint,
        sourceLanguage: sourceLanguage,
        targetLanguage: targetLanguage,
        translationService: translationService,
        providerFingerprint: providerFingerprint,
        promptFingerprint: promptFingerprint,
        sourceHash: sourceHash,
        contextHash: contextHash,
        sourceText: sourceText,
        contextText: contextText,
        translatedText: translatedText ?? this.translatedText,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        deletedAt: clearDeletedAt ? null : (deletedAt ?? this.deletedAt),
      );

  Map<String, Object?> toDatabaseMap() => <String, Object?>{
        'request_key': requestKey,
        'cache_version': cacheVersion,
        'book_fingerprint_algorithm': bookFingerprintAlgorithm,
        'book_fingerprint': bookFingerprint,
        'source_language': sourceLanguage,
        'target_language': targetLanguage,
        'translation_service': translationService,
        'provider_fingerprint': providerFingerprint,
        'prompt_fingerprint': promptFingerprint,
        'source_hash': sourceHash,
        'context_hash': contextHash,
        'source_text': sourceText,
        'context_text': contextText,
        'translated_text': translatedText,
        'created_at': createdAt.toUtc().toIso8601String(),
        'updated_at': updatedAt.toUtc().toIso8601String(),
        'deleted_at': deletedAt?.toUtc().toIso8601String(),
      };

  factory TranslationCacheEntry.fromDatabaseMap(Map<String, Object?> map) =>
      TranslationCacheEntry(
        requestKey: map['request_key']! as String,
        cacheVersion: map['cache_version']! as int,
        bookFingerprintAlgorithm: map['book_fingerprint_algorithm']! as String,
        bookFingerprint: (map['book_fingerprint']! as String).toLowerCase(),
        sourceLanguage: map['source_language']! as String,
        targetLanguage: map['target_language']! as String,
        translationService: map['translation_service']! as String,
        providerFingerprint: map['provider_fingerprint']! as String,
        promptFingerprint: map['prompt_fingerprint']! as String,
        sourceHash: map['source_hash']! as String,
        contextHash: map['context_hash']! as String,
        sourceText: map['source_text']! as String,
        contextText: map['context_text']! as String,
        translatedText: map['translated_text']! as String,
        createdAt: DateTime.parse(map['created_at']! as String).toUtc(),
        updatedAt: DateTime.parse(map['updated_at']! as String).toUtc(),
        deletedAt: map['deleted_at'] == null
            ? null
            : DateTime.parse(map['deleted_at']! as String).toUtc(),
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'requestKey': requestKey,
        'cacheVersion': cacheVersion,
        'sourceLanguage': sourceLanguage,
        'targetLanguage': targetLanguage,
        'translationService': translationService,
        'providerFingerprint': providerFingerprint,
        'promptFingerprint': promptFingerprint,
        'sourceHash': sourceHash,
        'contextHash': contextHash,
        'sourceText': sourceText,
        'contextText': contextText,
        'translatedText': translatedText,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'updatedAt': updatedAt.toUtc().toIso8601String(),
        'deletedAt': deletedAt?.toUtc().toIso8601String(),
      };

  factory TranslationCacheEntry.fromJson(
    Map<String, dynamic> json, {
    required String bookFingerprintAlgorithm,
    required String bookFingerprint,
  }) =>
      TranslationCacheEntry(
        requestKey: json['requestKey'] as String,
        cacheVersion: json['cacheVersion'] as int,
        bookFingerprintAlgorithm: bookFingerprintAlgorithm,
        bookFingerprint: bookFingerprint.toLowerCase(),
        sourceLanguage: json['sourceLanguage'] as String,
        targetLanguage: json['targetLanguage'] as String,
        translationService: json['translationService'] as String,
        providerFingerprint: json['providerFingerprint'] as String,
        promptFingerprint: json['promptFingerprint'] as String,
        sourceHash: json['sourceHash'] as String,
        contextHash: json['contextHash'] as String,
        sourceText: json['sourceText'] as String,
        contextText: json['contextText'] as String,
        translatedText: json['translatedText'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String).toUtc(),
        updatedAt: DateTime.parse(json['updatedAt'] as String).toUtc(),
        deletedAt: json['deletedAt'] == null
            ? null
            : DateTime.parse(json['deletedAt'] as String).toUtc(),
      );

  String canonicalState() => jsonEncode(<Object?>[
        ...exactIdentity,
        translatedText,
        createdAt.toUtc().toIso8601String(),
        updatedAt.toUtc().toIso8601String(),
        deletedAt?.toUtc().toIso8601String(),
      ]);
}

class TranslationCacheBookDocument {
  const TranslationCacheBookDocument({
    required this.bookFingerprintAlgorithm,
    required this.bookFingerprint,
    required this.entries,
    this.schemaVersion = translationCacheRemoteSchemaVersion,
  });

  final int schemaVersion;
  final String bookFingerprintAlgorithm;
  final String bookFingerprint;
  final List<TranslationCacheEntry> entries;

  Map<String, Object?> toJson() => <String, Object?>{
        'schemaVersion': schemaVersion,
        'bookFingerprintAlgorithm': bookFingerprintAlgorithm,
        'bookFingerprint': bookFingerprint.toLowerCase(),
        'entries': entries.map((entry) => entry.toJson()).toList(),
      };

  String encode() => jsonEncode(toJson());

  factory TranslationCacheBookDocument.decode(String source) {
    final value = jsonDecode(source);
    if (value is! Map<String, dynamic>) {
      throw const FormatException(
          'Translation cache document is not an object');
    }
    final schemaVersion = value['schemaVersion'];
    if (schemaVersion != translationCacheRemoteSchemaVersion) {
      throw UnsupportedError(
          'Unsupported translation cache schema: $schemaVersion');
    }
    final algorithm = value['bookFingerprintAlgorithm'] as String;
    final fingerprint = (value['bookFingerprint'] as String).toLowerCase();
    final rawEntries = value['entries'];
    if (rawEntries is! List) {
      throw const FormatException('Translation cache entries are not a list');
    }
    final entries = <TranslationCacheEntry>[];
    for (final raw in rawEntries) {
      if (raw is! Map<String, dynamic>) continue;
      try {
        final entry = TranslationCacheEntry.fromJson(
          raw,
          bookFingerprintAlgorithm: algorithm,
          bookFingerprint: fingerprint,
        );
        if (entry.cacheVersion == fullTextTranslationCacheVersion &&
            entry.requestKey ==
                FullTextTranslationRequest(
                  bookFingerprint: fingerprint,
                  sourceLanguage: entry.sourceLanguage,
                  targetLanguage: entry.targetLanguage,
                  translationService: entry.translationService,
                  providerFingerprint: entry.providerFingerprint,
                  promptFingerprint: entry.promptFingerprint,
                  sourceText: entry.sourceText,
                  contextText: entry.contextText,
                ).requestKey &&
            entry.sourceHash == sha256Text(entry.sourceText) &&
            entry.contextHash == sha256Text(entry.contextText)) {
          entries.add(entry);
        }
      } catch (_) {
        // A malformed entry must not poison other entries in the document.
      }
    }
    return TranslationCacheBookDocument(
      schemaVersion: schemaVersion as int,
      bookFingerprintAlgorithm: algorithm,
      bookFingerprint: fingerprint,
      entries: entries,
    );
  }
}

bool _listEquals(List<Object?> a, List<Object?> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
