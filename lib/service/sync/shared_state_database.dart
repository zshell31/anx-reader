import 'dart:convert';

import 'package:anx_reader/service/sync/annotation_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

enum SharedSyncStatus { synced, pending, syncing, error }

class SharedOutboxEntry {
  final String domain;
  final String documentId;
  final int attempts;
  final String? lastError;
  const SharedOutboxEntry(
      this.domain, this.documentId, this.attempts, this.lastError);
}

class SharedStateDatabase {
  final String? path;
  final DatabaseFactory? factory;
  Database? _database;

  SharedStateDatabase({this.path, this.factory});

  Future<Database> get database async => _database ??= await _open();

  Future<Database> _open() async {
    final resolvedPath = path ?? p.join(await getDatabasesPath(), 'shared_state.db');
    return (factory ?? databaseFactory).openDatabase(
      resolvedPath,
      options: OpenDatabaseOptions(
        version: 1,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
          await db.execute('PRAGMA journal_mode = WAL');
        },
        onCreate: (db, _) async {
          await db.execute('''CREATE TABLE shared_documents (
            domain TEXT NOT NULL,
            document_id TEXT NOT NULL,
            canonical_json TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            PRIMARY KEY(domain, document_id)
          )''');
          await db.execute('''CREATE TABLE sync_outbox (
            domain TEXT NOT NULL,
            document_id TEXT NOT NULL,
            dirty_since TEXT NOT NULL,
            attempts INTEGER NOT NULL DEFAULT 0,
            last_error TEXT,
            PRIMARY KEY(domain, document_id),
            FOREIGN KEY(domain, document_id) REFERENCES shared_documents(domain, document_id)
              ON DELETE CASCADE
          )''');
          await db.execute('''CREATE TABLE sync_metadata (
            domain TEXT NOT NULL,
            document_id TEXT NOT NULL,
            strong_etag TEXT,
            last_synced_at TEXT,
            status TEXT NOT NULL DEFAULT 'pending',
            PRIMARY KEY(domain, document_id)
          )''');
          await db.execute('''CREATE TABLE legacy_import_receipts (
            source TEXT NOT NULL,
            source_key TEXT NOT NULL,
            shared_id TEXT,
            status TEXT NOT NULL,
            detail TEXT,
            imported_at TEXT NOT NULL,
            PRIMARY KEY(source, source_key)
          )''');
          await db.execute('''CREATE TABLE annotation_projections (
            annotation_id TEXT PRIMARY KEY,
            book_fingerprint TEXT NOT NULL,
            native_note_id INTEGER,
            status TEXT NOT NULL,
            canonical_hash TEXT,
            last_error TEXT
          )''');
        },
      ),
    );
  }

  Future<void> putAnnotationDocument(Map<String, dynamic> input,
      {bool dirty = true}) async {
    final document = decodeAnnotationDocument(input);
    final book = document['book'] as Map<String, dynamic>;
    final id = canonicalMd5Fingerprint(book['fingerprint']);
    final now = canonicalWireTimestamp(DateTime.now());
    final db = await database;
    await db.transaction((txn) async {
      await txn.insert(
          'shared_documents',
          {
            'domain': 'annotations',
            'document_id': id,
            'canonical_json': canonicalJson(document),
            'updated_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      if (dirty) {
        await txn.insert(
            'sync_outbox',
            {
              'domain': 'annotations',
              'document_id': id,
              'dirty_since': now,
            },
            conflictAlgorithm: ConflictAlgorithm.ignore);
        await txn.insert(
            'sync_metadata',
            {
              'domain': 'annotations',
              'document_id': id,
              'status': SharedSyncStatus.pending.name,
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  Future<Map<String, dynamic>?> annotationDocument(String fingerprint) async {
    final rows = await (await database).query('shared_documents',
        columns: ['canonical_json'],
        where: 'domain = ? AND document_id = ?',
        whereArgs: ['annotations', canonicalMd5Fingerprint(fingerprint)],
        limit: 1);
    return rows.isEmpty
        ? null
        : decodeAnnotationDocument(
            jsonDecode(rows.single['canonical_json'] as String));
  }

  Future<List<SharedOutboxEntry>> pendingOutbox() async {
    final rows = await (await database)
        .query('sync_outbox', orderBy: 'dirty_since, domain, document_id');
    return rows
        .map((row) => SharedOutboxEntry(
            row['domain'] as String,
            row['document_id'] as String,
            row['attempts'] as int,
            row['last_error'] as String?))
        .toList();
  }

  Future<void> recordFailure(String domain, String id, Object error) async {
    await (await database).rawUpdate('''UPDATE sync_outbox
      SET attempts = attempts + 1, last_error = ? WHERE domain = ? AND document_id = ?''',
        [error.toString(), domain, id]);
  }

  Future<void> markConverged(String domain, String id,
      {String? strongEtag}) async {
    final now = canonicalWireTimestamp(DateTime.now());
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('sync_outbox',
          where: 'domain = ? AND document_id = ?', whereArgs: [domain, id]);
      await txn.insert(
          'sync_metadata',
          {
            'domain': domain,
            'document_id': id,
            'strong_etag': strongEtag,
            'last_synced_at': now,
            'status': SharedSyncStatus.synced.name,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  Future<String?> importedSharedId(String source, String sourceKey) async {
    final rows = await (await database).query('legacy_import_receipts',
        columns: ['shared_id'],
        where: 'source = ? AND source_key = ?',
        whereArgs: [source, sourceKey],
        limit: 1);
    return rows.isEmpty ? null : rows.single['shared_id'] as String?;
  }

  Future<void> recordImport(
      {required String source,
      required String sourceKey,
      String? sharedId,
      required String status,
      String? detail}) async {
    await (await database).insert(
        'legacy_import_receipts',
        {
          'source': source,
          'source_key': sourceKey,
          'shared_id': sharedId,
          'status': status,
          'detail': detail,
          'imported_at': canonicalWireTimestamp(DateTime.now()),
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> close() async {
    await _database?.close();
    _database = null;
  }
}
