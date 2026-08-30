import 'dart:convert';
import 'dart:typed_data';

import 'package:anx_reader/service/sync/annotation_protocol.dart';
import 'package:anx_reader/service/sync/annotation_read_model.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Durable lifecycle of the current local document revision.
///
/// [synced] has no dirty revision, [pending] is retryable dirty work,
/// [syncing] is a process-local claim, and [error] is dirty work whose latest
/// attempt failed. On open, [syncing] is recovered to [pending].
enum SharedSyncStatus { synced, pending, syncing, error }

typedef SharedStateMigration = Future<void> Function(DatabaseExecutor db);

Future<void> _createAnnotationPresentations(DatabaseExecutor db) =>
    db.execute('''CREATE TABLE annotation_presentations (
      annotation_id TEXT PRIMARY KEY,
      style TEXT NOT NULL CHECK(style IN ('highlight', 'underline')),
      color TEXT NOT NULL CHECK(length(color) > 0)
    )''');

const currentSharedStateSchema = SharedStateSchema(
  version: 2,
  migrations: {2: _createAnnotationPresentations},
);

/// Versioning policy for the physically independent shared-state database.
///
/// Migration keys are destination versions. A future v1 -> v2 migration is
/// registered under key 2. Missing steps fail instead of opening a partially
/// understood schema.
class SharedStateSchema {
  final int version;
  final Map<int, SharedStateMigration> migrations;

  const SharedStateSchema({this.version = 1, this.migrations = const {}});

  Future<void> create(DatabaseExecutor db) async {
    await db.execute('''CREATE TABLE shared_documents (
      domain TEXT NOT NULL,
      document_id TEXT NOT NULL,
      canonical_state BLOB NOT NULL,
      local_revision INTEGER NOT NULL,
      updated_at TEXT NOT NULL,
      PRIMARY KEY(domain, document_id)
    )''');
    await db.execute('''CREATE TABLE sync_outbox (
      domain TEXT NOT NULL,
      document_id TEXT NOT NULL,
      local_revision INTEGER NOT NULL,
      dirty_since TEXT NOT NULL,
      attempts INTEGER NOT NULL DEFAULT 0,
      last_error TEXT,
      PRIMARY KEY(domain, document_id),
      FOREIGN KEY(domain, document_id)
        REFERENCES shared_documents(domain, document_id) ON DELETE CASCADE
    )''');
    await db.execute('''CREATE TABLE sync_metadata (
      domain TEXT NOT NULL,
      document_id TEXT NOT NULL,
      strong_etag TEXT,
      remote_revision INTEGER NOT NULL DEFAULT 0,
      last_synced_at TEXT,
      status TEXT NOT NULL DEFAULT 'pending'
        CHECK(status IN ('synced', 'pending', 'syncing', 'error')),
      PRIMARY KEY(domain, document_id),
      FOREIGN KEY(domain, document_id)
        REFERENCES shared_documents(domain, document_id) ON DELETE CASCADE
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
    if (version >= 2) await _createAnnotationPresentations(db);
  }

  Future<void> upgrade(
      DatabaseExecutor db, int oldVersion, int newVersion) async {
    for (var destination = oldVersion + 1;
        destination <= newVersion;
        destination++) {
      final migration = migrations[destination];
      if (migration == null) {
        throw UnsupportedError(
            'No shared-state migration to schema v$destination');
      }
      await migration(db);
    }
  }

  Future<void> downgrade(Database db, int oldVersion, int newVersion) async =>
      throw UnsupportedError(
          'Shared-state schema v$oldVersion is newer than supported v$newVersion');
}

class SharedOutboxEntry {
  final String domain;
  final String documentId;
  final int localRevision;
  final int attempts;
  final String? lastError;

  const SharedOutboxEntry(this.domain, this.documentId, this.localRevision,
      this.attempts, this.lastError);
}

/// A canonical document snapshot used for compare-and-set remote merges.
///
/// [localRevision] advances only for local user mutations. Remote
/// reconciliation may change [canonicalState] while preserving that revision.
class SharedDocumentSnapshot {
  final String domain;
  final String documentId;
  final Uint8List canonicalState;
  final int localRevision;
  final bool dirty;

  const SharedDocumentSnapshot({
    required this.domain,
    required this.documentId,
    required this.canonicalState,
    required this.localRevision,
    required this.dirty,
  });
}

/// An immutable local revision to synchronize after its claim transaction has
/// completed. Network I/O must happen after this is returned.
class SharedSyncWork {
  final String domain;
  final String documentId;
  final int localRevision;
  final Uint8List canonicalState;
  final int attempts;
  final String? strongEtag;

  const SharedSyncWork(
      {required this.domain,
      required this.documentId,
      required this.localRevision,
      required this.canonicalState,
      required this.attempts,
      required this.strongEtag});
}

class SharedSyncMetadata {
  final String domain;
  final String documentId;
  final String? strongEtag;
  final int remoteRevision;
  final String? lastSyncedAt;
  final SharedSyncStatus status;

  const SharedSyncMetadata(
      {required this.domain,
      required this.documentId,
      required this.strongEtag,
      required this.remoteRevision,
      required this.lastSyncedAt,
      required this.status});
}

class LegacyImportReceipt {
  final String source;
  final String sourceKey;
  final String? sharedId;
  final String status;
  final String? detail;

  const LegacyImportReceipt({
    required this.source,
    required this.sourceKey,
    required this.sharedId,
    required this.status,
    required this.detail,
  });
}

class AnnotationProjectionMetadata {
  final String annotationId;
  final String bookFingerprint;
  final int? nativeNoteId;
  final String status;
  final String? canonicalHash;
  final String? lastError;

  const AnnotationProjectionMetadata({
    required this.annotationId,
    required this.bookFingerprint,
    required this.nativeNoteId,
    required this.status,
    required this.canonicalHash,
    required this.lastError,
  });
}

class SharedStateDatabase {
  final String? path;
  final DatabaseFactory? factory;
  final SharedStateSchema schema;
  Database? _database;

  SharedStateDatabase(
      {this.path, this.factory, this.schema = currentSharedStateSchema});

  Future<Database> get database async => _database ??= await _open();

  Future<Database> _open() async {
    final resolvedPath =
        path ?? p.join(await getDatabasesPath(), 'shared_state.db');
    return (factory ?? databaseFactory).openDatabase(
      resolvedPath,
      options: OpenDatabaseOptions(
        version: schema.version,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
          // journal_mode returns a result row. Android's sqflite driver rejects
          // it through execute(), even though SQLite reports SQLITE_OK.
          await db.rawQuery('PRAGMA journal_mode = WAL');
        },
        onCreate: (db, _) => schema.create(db),
        onUpgrade: schema.upgrade,
        onDowngrade: schema.downgrade,
        onOpen: _recoverInterruptedSyncs,
      ),
    );
  }

  Future<void> _recoverInterruptedSyncs(Database db) async {
    // A process-local in-flight claim cannot survive process death. Dirty work
    // becomes retryable; an impossible in-flight row without an outbox is
    // normalized to converged.
    await db.rawUpdate('''UPDATE sync_metadata
      SET status = CASE
        WHEN EXISTS (
          SELECT 1 FROM sync_outbox o
          WHERE o.domain = sync_metadata.domain
            AND o.document_id = sync_metadata.document_id
        ) THEN 'pending'
        ELSE 'synced'
      END
      WHERE status = 'syncing' ''');
  }

  Future<int> get schemaVersion async {
    final rows = await (await database).rawQuery('PRAGMA user_version');
    return rows.single['user_version'] as int;
  }

  /// Stores canonical bytes and advances the document revision in the same
  /// transaction that makes that exact revision dirty.
  Future<int> putCanonicalDocument(
      String domain, String documentId, List<int> canonicalState) async {
    if (domain.isEmpty || documentId.isEmpty) {
      throw ArgumentError('domain and documentId must not be empty');
    }
    final now = canonicalWireTimestamp(DateTime.now());
    return (await database).transaction((txn) async {
      final previous = await txn.query('shared_documents',
          columns: ['local_revision'],
          where: 'domain = ? AND document_id = ?',
          whereArgs: [domain, documentId],
          limit: 1);
      final revision =
          previous.isEmpty ? 1 : (previous.single['local_revision'] as int) + 1;
      await txn.rawInsert('''INSERT INTO shared_documents
          (domain, document_id, canonical_state, local_revision, updated_at)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(domain, document_id) DO UPDATE SET
          canonical_state = excluded.canonical_state,
          local_revision = excluded.local_revision,
          updated_at = excluded.updated_at''', [
        domain,
        documentId,
        Uint8List.fromList(canonicalState),
        revision,
        now
      ]);
      await txn.rawInsert('''INSERT INTO sync_outbox
          (domain, document_id, local_revision, dirty_since, attempts, last_error)
        VALUES (?, ?, ?, ?, 0, NULL)
        ON CONFLICT(domain, document_id) DO UPDATE SET
          local_revision = excluded.local_revision,
          dirty_since = excluded.dirty_since,
          attempts = 0,
          last_error = NULL''', [domain, documentId, revision, now]);
      await txn.rawInsert('''INSERT INTO sync_metadata
          (domain, document_id, status)
        VALUES (?, ?, 'pending')
        ON CONFLICT(domain, document_id) DO UPDATE SET status = 'pending' ''',
          [domain, documentId]);
      return revision;
    });
  }

  Future<int> putAnnotationDocument(Map<String, dynamic> input) async {
    final document = decodeAnnotationDocument(input);
    final book = document['book'] as Map<String, dynamic>;
    final id = canonicalMd5Fingerprint(book['fingerprint']);
    return putCanonicalDocument(
        'annotations', id, utf8.encode(canonicalJson(document)));
  }

  Future<Uint8List?> canonicalDocument(String domain, String documentId) async {
    final rows = await (await database).query('shared_documents',
        columns: ['canonical_state'],
        where: 'domain = ? AND document_id = ?',
        whereArgs: [domain, documentId],
        limit: 1);
    return rows.isEmpty
        ? null
        : Uint8List.fromList(rows.single['canonical_state'] as List<int>);
  }

  Future<SharedDocumentSnapshot?> documentSnapshot(
      String domain, String documentId) async {
    final rows = await (await database).rawQuery('''SELECT
        d.canonical_state, d.local_revision,
        CASE WHEN o.document_id IS NULL THEN 0 ELSE 1 END AS dirty
      FROM shared_documents d
      LEFT JOIN sync_outbox o
        ON o.domain = d.domain AND o.document_id = d.document_id
      WHERE d.domain = ? AND d.document_id = ?
      LIMIT 1''', [domain, documentId]);
    if (rows.isEmpty) return null;
    final row = rows.single;
    return SharedDocumentSnapshot(
      domain: domain,
      documentId: documentId,
      canonicalState: Uint8List.fromList(row['canonical_state'] as List<int>),
      localRevision: row['local_revision'] as int,
      dirty: (row['dirty'] as int) == 1,
    );
  }

  Future<SharedOutboxEntry?> outboxEntry(
      String domain, String documentId) async {
    final rows = await (await database).query('sync_outbox',
        where: 'domain = ? AND document_id = ?',
        whereArgs: [domain, documentId],
        limit: 1);
    if (rows.isEmpty) return null;
    final row = rows.single;
    return SharedOutboxEntry(
      row['domain'] as String,
      row['document_id'] as String,
      row['local_revision'] as int,
      row['attempts'] as int,
      row['last_error'] as String?,
    );
  }

  /// Applies network-derived canonical bytes without manufacturing local work.
  ///
  /// The update is compare-and-set against [expectedLocalRevision], so a merge
  /// computed from an older snapshot can never overwrite a concurrent local
  /// mutation. Existing dirty state is preserved. A document first discovered
  /// remotely starts at revision zero and is clean.
  Future<bool> applyRemoteMerge(
    String domain,
    String documentId,
    int? expectedLocalRevision,
    List<int> canonicalState, {
    String? strongEtag,
  }) async {
    if (strongEtag != null && !RegExp(r'^"[^"\r\n]+"$').hasMatch(strongEtag)) {
      throw ArgumentError.value(strongEtag, 'strongEtag', 'must be strong');
    }
    final now = canonicalWireTimestamp(DateTime.now());
    return (await database).transaction((txn) async {
      final current = await txn.query('shared_documents',
          columns: ['local_revision'],
          where: 'domain = ? AND document_id = ?',
          whereArgs: [domain, documentId],
          limit: 1);
      if (current.isEmpty) {
        if (expectedLocalRevision != null) return false;
        await txn.insert('shared_documents', {
          'domain': domain,
          'document_id': documentId,
          'canonical_state': Uint8List.fromList(canonicalState),
          'local_revision': 0,
          'updated_at': now,
        });
        await txn.insert('sync_metadata', {
          'domain': domain,
          'document_id': documentId,
          'strong_etag': strongEtag,
          'last_synced_at': now,
          'status': 'synced',
        });
        return true;
      }
      final revision = current.single['local_revision'] as int;
      if (revision != expectedLocalRevision) return false;
      await txn.update(
        'shared_documents',
        {
          'canonical_state': Uint8List.fromList(canonicalState),
          'updated_at': now,
        },
        where: 'domain = ? AND document_id = ? AND local_revision = ?',
        whereArgs: [domain, documentId, revision],
      );
      final dirtyRows = await txn.rawQuery('''SELECT COUNT(*) AS count
        FROM sync_outbox WHERE domain = ? AND document_id = ?''',
          [domain, documentId]);
      final dirty = (dirtyRows.single['count'] as int) > 0;
      await txn.rawInsert('''INSERT INTO sync_metadata
          (domain, document_id, strong_etag, last_synced_at, status)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(domain, document_id) DO UPDATE SET
          strong_etag = COALESCE(excluded.strong_etag, strong_etag),
          last_synced_at = CASE
            WHEN excluded.strong_etag IS NOT NULL THEN excluded.last_synced_at
            ELSE last_synced_at END,
          status = CASE WHEN ? THEN status ELSE 'synced' END''', [
        domain,
        documentId,
        strongEtag,
        now,
        dirty ? 'pending' : 'synced',
        dirty ? 1 : 0
      ]);
      return true;
    });
  }

  /// Records a successful clean pull/write only if no local mutation raced it.
  Future<bool> markRemoteConverged(
      String domain, String documentId, int expectedLocalRevision,
      {String? strongEtag}) async {
    if (strongEtag != null && !RegExp(r'^"[^"\r\n]+"$').hasMatch(strongEtag)) {
      throw ArgumentError.value(strongEtag, 'strongEtag', 'must be strong');
    }
    final now = canonicalWireTimestamp(DateTime.now());
    return (await database).transaction((txn) async {
      final current = await txn.rawQuery('''SELECT d.local_revision
        FROM shared_documents d
        WHERE d.domain = ? AND d.document_id = ?
          AND d.local_revision = ?
          AND NOT EXISTS (SELECT 1 FROM sync_outbox o
            WHERE o.domain = d.domain AND o.document_id = d.document_id)
        LIMIT 1''', [domain, documentId, expectedLocalRevision]);
      if (current.isEmpty) return false;
      await txn.rawInsert('''INSERT INTO sync_metadata
          (domain, document_id, strong_etag, last_synced_at, status)
        VALUES (?, ?, ?, ?, 'synced')
        ON CONFLICT(domain, document_id) DO UPDATE SET
          strong_etag = COALESCE(excluded.strong_etag, strong_etag),
          last_synced_at = excluded.last_synced_at,
          status = 'synced' ''', [domain, documentId, strongEtag, now]);
      return true;
    });
  }

  Future<Map<String, dynamic>?> annotationDocument(String fingerprint) async {
    final bytes = await canonicalDocument(
        'annotations', canonicalMd5Fingerprint(fingerprint));
    return bytes == null
        ? null
        : decodeAnnotationDocument(jsonDecode(utf8.decode(bytes)));
  }

  Future<List<Map<String, dynamic>>> annotationDocuments() async {
    final rows = await (await database).query('shared_documents',
        columns: ['canonical_state'],
        where: 'domain = ?',
        whereArgs: ['annotations'],
        orderBy: 'document_id');
    return rows
        .map((row) => decodeAnnotationDocument(jsonDecode(utf8
            .decode(Uint8List.fromList(row['canonical_state'] as List<int>)))))
        .toList(growable: false);
  }

  Future<List<SharedOutboxEntry>> pendingOutbox() async {
    final rows = await (await database)
        .query('sync_outbox', orderBy: 'dirty_since, domain, document_id');
    return rows
        .map((row) => SharedOutboxEntry(
            row['domain'] as String,
            row['document_id'] as String,
            row['local_revision'] as int,
            row['attempts'] as int,
            row['last_error'] as String?))
        .toList();
  }

  /// Atomically claims and snapshots one exact revision. The returned bytes can
  /// be used over the network without retaining a SQLite transaction or lock.
  Future<SharedSyncWork?> beginSync(
      String domain, String id, int expectedRevision) async {
    return (await database).transaction((txn) async {
      final rows = await txn.rawQuery('''SELECT
          d.canonical_state, o.attempts, m.strong_etag, m.status
        FROM sync_outbox o
        JOIN shared_documents d
          ON d.domain = o.domain AND d.document_id = o.document_id
          AND d.local_revision = o.local_revision
        LEFT JOIN sync_metadata m
          ON m.domain = o.domain AND m.document_id = o.document_id
        WHERE o.domain = ? AND o.document_id = ? AND o.local_revision = ?
        LIMIT 1''', [domain, id, expectedRevision]);
      if (rows.isEmpty ||
          rows.single['status'] == SharedSyncStatus.syncing.name) {
        return null;
      }
      await txn.rawInsert('''INSERT INTO sync_metadata
          (domain, document_id, status)
        VALUES (?, ?, 'syncing')
        ON CONFLICT(domain, document_id) DO UPDATE SET status = 'syncing' ''',
          [domain, id]);
      final row = rows.single;
      return SharedSyncWork(
          domain: domain,
          documentId: id,
          localRevision: expectedRevision,
          canonicalState:
              Uint8List.fromList(row['canonical_state'] as List<int>),
          attempts: row['attempts'] as int,
          strongEtag: row['strong_etag'] as String?);
    });
  }

  /// Records a failure only if it belongs to the still-current dirty revision.
  Future<bool> recordFailure(
      String domain, String id, int expectedRevision, Object error) async {
    return (await database).transaction((txn) async {
      final changed = await txn.rawUpdate('''UPDATE sync_outbox
        SET attempts = attempts + 1, last_error = ?
        WHERE domain = ? AND document_id = ? AND local_revision = ?''',
          [error.toString(), domain, id, expectedRevision]);
      if (changed == 0) return false;
      await txn.rawUpdate('''UPDATE sync_metadata SET status = 'error'
        WHERE domain = ? AND document_id = ?''', [domain, id]);
      return true;
    });
  }

  /// Completes only the expected revision. A newer local mutation keeps its
  /// outbox row and status. Its next replace may still use the ETag produced by
  /// this older successful upload, unless an even newer upload already won.
  Future<bool> markConverged(String domain, String id, int expectedRevision,
      {String? strongEtag}) async {
    if (strongEtag != null && !RegExp(r'^"[^"\r\n]+"$').hasMatch(strongEtag)) {
      throw ArgumentError.value(strongEtag, 'strongEtag', 'must be strong');
    }
    final now = canonicalWireTimestamp(DateTime.now());
    return (await database).transaction((txn) async {
      final deleted = await txn.delete('sync_outbox',
          where: 'domain = ? AND document_id = ? AND local_revision = ?',
          whereArgs: [domain, id, expectedRevision]);
      if (deleted == 1) {
        await txn.rawUpdate('''UPDATE sync_metadata SET
            strong_etag = COALESCE(?, strong_etag),
            remote_revision = CASE
              WHEN ? >= remote_revision THEN ? ELSE remote_revision END,
            last_synced_at = ?, status = 'synced'
          WHERE domain = ? AND document_id = ?''',
            [strongEtag, expectedRevision, expectedRevision, now, domain, id]);
        return true;
      }
      // A completed older upload is useful as the precondition for the pending
      // revision, but must never change that newer revision's status.
      await txn.rawUpdate('''UPDATE sync_metadata SET
          strong_etag = CASE
            WHEN ? IS NOT NULL AND ? >= remote_revision THEN ?
            ELSE strong_etag END,
          remote_revision = CASE
            WHEN ? >= remote_revision THEN ? ELSE remote_revision END,
          last_synced_at = CASE
            WHEN ? >= remote_revision THEN ? ELSE last_synced_at END
        WHERE domain = ? AND document_id = ?''', [
        strongEtag,
        expectedRevision,
        strongEtag,
        expectedRevision,
        expectedRevision,
        expectedRevision,
        now,
        domain,
        id
      ]);
      return false;
    });
  }

  Future<SharedSyncMetadata?> syncMetadata(String domain, String id) async {
    final rows = await (await database).query('sync_metadata',
        where: 'domain = ? AND document_id = ?',
        whereArgs: [domain, id],
        limit: 1);
    if (rows.isEmpty) return null;
    final row = rows.single;
    return SharedSyncMetadata(
        domain: domain,
        documentId: id,
        strongEtag: row['strong_etag'] as String?,
        remoteRevision: row['remote_revision'] as int,
        lastSyncedAt: row['last_synced_at'] as String?,
        status: SharedSyncStatus.values.byName(row['status'] as String));
  }

  Future<String?> importedSharedId(String source, String sourceKey) async {
    return (await importReceipt(source, sourceKey))?.sharedId;
  }

  Future<LegacyImportReceipt?> importReceipt(
      String source, String sourceKey) async {
    final rows = await (await database).query('legacy_import_receipts',
        where: 'source = ? AND source_key = ?',
        whereArgs: [source, sourceKey],
        limit: 1);
    if (rows.isEmpty) return null;
    final row = rows.single;
    return LegacyImportReceipt(
      source: row['source'] as String,
      sourceKey: row['source_key'] as String,
      sharedId: row['shared_id'] as String?,
      status: row['status'] as String,
      detail: row['detail'] as String?,
    );
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

  Future<AnnotationPresentation?> annotationPresentation(
      String annotationId) async {
    if (annotationId.isEmpty) {
      throw ArgumentError.value(
          annotationId, 'annotationId', 'must not be empty');
    }
    final rows = await (await database).query('annotation_presentations',
        where: 'annotation_id = ?', whereArgs: [annotationId], limit: 1);
    if (rows.isEmpty) return null;
    final row = rows.single;
    return AnnotationPresentation(
      annotationId: row['annotation_id'] as String,
      style: AnnotationPresentationStyle.values.byName(row['style'] as String),
      color: row['color'] as String,
    );
  }

  Future<Map<String, AnnotationPresentation>> annotationPresentations() async {
    final rows = await (await database)
        .query('annotation_presentations', orderBy: 'annotation_id');
    return Map.unmodifiable({
      for (final row in rows)
        row['annotation_id'] as String: AnnotationPresentation(
          annotationId: row['annotation_id'] as String,
          style:
              AnnotationPresentationStyle.values.byName(row['style'] as String),
          color: row['color'] as String,
        ),
    });
  }

  /// Writes only client-local style/color state. This table has no trigger or
  /// foreign key into canonical documents and never touches the sync outbox.
  Future<bool> putAnnotationPresentation(
      AnnotationPresentation presentation) async {
    if (presentation.annotationId.isEmpty ||
        presentation.color.trim().isEmpty) {
      throw ArgumentError('Annotation presentation identity/color is required');
    }
    final previous = await annotationPresentation(presentation.annotationId);
    if (previous != null &&
        previous.style == presentation.style &&
        previous.color == presentation.color) {
      return false;
    }
    await (await database).insert(
      'annotation_presentations',
      {
        'annotation_id': presentation.annotationId,
        'style': presentation.style.name,
        'color': presentation.color,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return true;
  }

  Future<void> deleteAnnotationPresentation(String annotationId) async {
    await (await database).delete('annotation_presentations',
        where: 'annotation_id = ?', whereArgs: [annotationId]);
  }

  Future<AnnotationProjectionMetadata?> annotationProjection(
      String annotationId) async {
    final rows = await (await database).query('annotation_projections',
        where: 'annotation_id = ?', whereArgs: [annotationId], limit: 1);
    if (rows.isEmpty) return null;
    final row = rows.single;
    return AnnotationProjectionMetadata(
      annotationId: row['annotation_id'] as String,
      bookFingerprint: row['book_fingerprint'] as String,
      nativeNoteId: row['native_note_id'] as int?,
      status: row['status'] as String,
      canonicalHash: row['canonical_hash'] as String?,
      lastError: row['last_error'] as String?,
    );
  }

  /// Stores local materialization metadata only when it actually changed.
  /// The native note id is a cache; callers must recover identity through the
  /// canonical annotation id / `shared_annotation_id` binding.
  Future<bool> putAnnotationProjection({
    required String annotationId,
    required String bookFingerprint,
    required int? nativeNoteId,
    required String status,
    String? canonicalHash,
    String? lastError,
  }) async {
    final previous = await annotationProjection(annotationId);
    if (previous != null &&
        previous.bookFingerprint == bookFingerprint &&
        previous.nativeNoteId == nativeNoteId &&
        previous.status == status &&
        previous.canonicalHash == canonicalHash &&
        previous.lastError == lastError) {
      return false;
    }
    await (await database).insert(
      'annotation_projections',
      {
        'annotation_id': annotationId,
        'book_fingerprint': bookFingerprint,
        'native_note_id': nativeNoteId,
        'status': status,
        'canonical_hash': canonicalHash,
        'last_error': lastError,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return true;
  }

  Future<void> close() async {
    await _database?.close();
    _database = null;
  }
}
