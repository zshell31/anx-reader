import 'package:anx_reader/models/full_text_translation_cache.dart';
import 'package:anx_reader/utils/get_path/databases_path.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

const String translationCacheDatabaseName = 'translation_cache.db';
const int translationCacheDatabaseVersion = 1;

typedef TranslationCacheDatabaseOpener = Future<Database> Function();

class TranslationCacheDatabase {
  TranslationCacheDatabase({TranslationCacheDatabaseOpener? opener})
      : _opener = opener;

  final TranslationCacheDatabaseOpener? _opener;
  Future<Database>? _database;

  Future<Database> get database async =>
      _database ??= _opener?.call() ?? _openDefault();

  Future<Database> _openDefault() async {
    final directory = await getAnxDataBasesPath();
    return openDatabase(
      join(directory, translationCacheDatabaseName),
      version: translationCacheDatabaseVersion,
      onCreate: createSchema,
    );
  }

  static Future<void> createSchema(Database db, int version) async {
    await db.execute('''
CREATE TABLE translation_cache (
  request_key TEXT NOT NULL PRIMARY KEY,
  cache_version INTEGER NOT NULL,
  book_fingerprint_algorithm TEXT NOT NULL,
  book_fingerprint TEXT NOT NULL,
  source_language TEXT NOT NULL,
  target_language TEXT NOT NULL,
  translation_service TEXT NOT NULL,
  provider_fingerprint TEXT NOT NULL,
  prompt_fingerprint TEXT NOT NULL,
  source_hash TEXT NOT NULL,
  context_hash TEXT NOT NULL,
  source_text TEXT NOT NULL,
  context_text TEXT NOT NULL,
  translated_text TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  deleted_at TEXT
)
''');
    await db.execute('''
CREATE UNIQUE INDEX idx_translation_cache_request_key
ON translation_cache(request_key)
''');
    await db.execute('''
CREATE INDEX idx_translation_cache_book
ON translation_cache(book_fingerprint_algorithm, book_fingerprint)
''');
    await db.execute('''
CREATE INDEX idx_translation_cache_updated_at
ON translation_cache(updated_at)
''');
  }

  Future<TranslationCacheEntry?> find(String requestKey) async {
    final db = await database;
    final rows = await db.query(
      'translation_cache',
      where: 'request_key = ? AND deleted_at IS NULL',
      whereArgs: <Object?>[requestKey],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    try {
      return TranslationCacheEntry.fromDatabaseMap(rows.first);
    } catch (_) {
      return null;
    }
  }

  /// Finds the canonical cross-device result for a semantic request.
  ///
  /// Different devices may use different OpenAI endpoints or models. Those
  /// details are provenance rather than part of the translated paragraph's
  /// portable identity. The earliest valid result wins deterministically, so
  /// a later device reuses the text already uploaded through WebDAV.
  Future<TranslationCacheEntry?> findReusable(
    FullTextTranslationRequest request,
  ) async {
    final db = await database;
    final rows = await db.query(
      'translation_cache',
      where: '''cache_version = ?
AND book_fingerprint_algorithm = ?
AND book_fingerprint = ?
AND source_language = ?
AND target_language = ?
AND translation_service = ?
AND prompt_fingerprint = ?
AND source_hash = ?
AND context_hash = ?
AND deleted_at IS NULL''',
      whereArgs: <Object?>[
        request.cacheVersion,
        request.bookFingerprintAlgorithm,
        request.bookFingerprint,
        request.sourceLanguage,
        request.targetLanguage,
        request.translationService,
        request.promptFingerprint,
        request.sourceHash,
        request.contextHash,
      ],
      orderBy: 'created_at ASC, request_key ASC',
    );
    for (final row in rows) {
      try {
        final entry = TranslationCacheEntry.fromDatabaseMap(row);
        if (entry.matchesReusableRequest(request)) return entry;
      } catch (_) {
        // Ignore a malformed candidate without hiding later valid entries.
      }
    }
    return null;
  }

  Future<TranslationCacheEntry?> findIncludingDeleted(String requestKey) async {
    final db = await database;
    final rows = await db.query(
      'translation_cache',
      where: 'request_key = ?',
      whereArgs: <Object?>[requestKey],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    try {
      return TranslationCacheEntry.fromDatabaseMap(rows.first);
    } catch (_) {
      return null;
    }
  }

  Future<void> upsert(TranslationCacheEntry entry) async {
    final db = await database;
    await db.insert(
      'translation_cache',
      entry.toDatabaseMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> upsertAll(Iterable<TranslationCacheEntry> entries) async {
    if (entries.isEmpty) return;
    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final entry in entries) {
        batch.insert(
          'translation_cache',
          entry.toDatabaseMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<List<TranslationCacheEntry>> entriesForBook(
    String bookFingerprint,
  ) async {
    final db = await database;
    final rows = await db.query(
      'translation_cache',
      where: 'book_fingerprint_algorithm = ? AND book_fingerprint = ?',
      whereArgs: <Object?>[
        bookFingerprintAlgorithmMd5,
        bookFingerprint.toLowerCase(),
      ],
    );
    return rows
        .map((row) => TranslationCacheEntry.fromDatabaseMap(row))
        .toList(growable: false);
  }

  Future<Set<String>> bookFingerprints() async {
    final db = await database;
    final rows = await db.query(
      'translation_cache',
      columns: <String>['book_fingerprint'],
      distinct: true,
      where: 'book_fingerprint_algorithm = ?',
      whereArgs: <Object?>[bookFingerprintAlgorithmMd5],
    );
    return rows.map((row) => row['book_fingerprint']! as String).toSet();
  }

  Future<int> activeCountForBook(String bookFingerprint) async {
    final db = await database;
    final result = await db.rawQuery('''
SELECT COUNT(*) AS count FROM translation_cache
WHERE book_fingerprint_algorithm = ?
  AND book_fingerprint = ?
  AND deleted_at IS NULL
''', <Object?>[bookFingerprintAlgorithmMd5, bookFingerprint.toLowerCase()]);
    return (result.first['count'] as int?) ?? 0;
  }

  Future<int> tombstoneBook(String bookFingerprint, DateTime now) async {
    final db = await database;
    final timestamp = now.toUtc().toIso8601String();
    return db.update(
      'translation_cache',
      <String, Object?>{
        'deleted_at': timestamp,
        'updated_at': timestamp,
      },
      where: '''book_fingerprint_algorithm = ?
AND book_fingerprint = ?
AND deleted_at IS NULL''',
      whereArgs: <Object?>[
        bookFingerprintAlgorithmMd5,
        bookFingerprint.toLowerCase(),
      ],
    );
  }

  Future<void> close() async {
    final database = _database;
    _database = null;
    if (database != null) await (await database).close();
  }
}

final translationCacheDatabase = TranslationCacheDatabase();
