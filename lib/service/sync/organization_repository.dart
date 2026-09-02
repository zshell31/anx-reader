import 'dart:convert';
import 'dart:typed_data';

import 'package:anx_reader/dao/database.dart';
import 'package:anx_reader/service/sync/annotation_protocol.dart';
import 'package:anx_reader/service/sync/domain_stamp.dart';
import 'package:anx_reader/service/sync/library_protocol.dart';
import 'package:anx_reader/service/sync/organization_protocol.dart';
import 'package:anx_reader/service/sync/shared_state_database.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

class OrganizationRepository {
  static const bootstrapSource = 'organization-v1';
  final SharedStateDatabase sharedState;
  final String deviceId;
  final DateTime Function() now;
  final Uuid uuid;
  final Future<Database> Function() _database;
  Future<void> _serial = Future<void>.value();

  OrganizationRepository({
    required this.sharedState,
    required this.deviceId,
    DateTime Function()? now,
    Future<Database> Function()? database,
    this.uuid = const Uuid(),
  })  : now = now ?? DateTime.now,
        _database = database ?? (() => DBHelper().database);

  DomainStamp get _stamp =>
      DomainStamp(modifiedAt: now().toUtc(), deviceId: deviceId);

  Future<T> _enqueue<T>(Future<T> Function() operation) {
    final next = _serial.then((_) => operation());
    _serial = next.then<void>((_) {}, onError: (_, __) {});
    return next;
  }

  Future<int> bootstrap() => _enqueue(_bootstrap);

  Future<int> _bootstrap() async {
    final db = await _database();
    var imported = 0;
    final groups = await db.query('tb_groups', orderBy: 'id');
    final groupIds = <int, String>{};
    for (final row in groups.where((row) => row['id'] != 0)) {
      final localId = row['id'] as int;
      groupIds[localId] = (await _ensureGroupSharedId(localId, row: row))!;
    }
    for (final row in groups.where((row) => row['id'] != 0)) {
      final localId = row['id'] as int;
      final id = groupIds[localId]!;
      final sourceKey = 'group:$id';
      final first =
          await sharedState.importReceipt(bootstrapSource, sourceKey) == null;
      final parent = row['parent_id'] as int?;
      await _putBootstrapIfChanged(
          groupDomain,
          id,
          decodeGroupDocument({
            'schemaVersion': 1,
            'domain': groupDomain,
            'id': id,
            'deleted':
                stampedValue((row['is_deleted'] as int? ?? 0) != 0, _stamp),
            'fields': {
              'name': stampedValue(row['name'] as String? ?? 'Group', _stamp),
              'parentId': stampedValue(
                  parent == null || parent == 0 ? null : groupIds[parent],
                  _stamp),
            },
          }));
      if (first) {
        await _receipt(sourceKey, id);
        imported++;
      }
    }
    final groupedBooks = await db.query('tb_books',
        columns: ['file_md5', 'group_id'],
        where: 'group_id IS NOT NULL AND group_id != 0');
    for (final row in groupedBooks) {
      final groupId = groupIds[row['group_id'] as int?];
      if (groupId == null) continue;
      String fingerprint;
      try {
        fingerprint = canonicalMd5Fingerprint(row['file_md5']);
      } catch (_) {
        continue;
      }
      final bytes = await sharedState.canonicalDocument(
          libraryCatalogDomain, fingerprint);
      if (bytes == null) continue;
      final catalog =
          decodeLibraryCatalogDocument(jsonDecode(utf8.decode(bytes)));
      final currentGroup = catalog['groupId'] as Map<String, dynamic>?;
      if (currentGroup?['value'] == groupId) continue;
      catalog['groupId'] = stampedValue(groupId, _stamp);
      await sharedState.putCanonicalDocument(libraryCatalogDomain, fingerprint,
          encodeDomainDocument(decodeLibraryCatalogDocument(catalog)));
    }

    final tags = await db.query('tb_styles',
        where: 'ABS(font_size - 1.0) < 0.0001 AND font_family IS NOT NULL',
        orderBy: 'id');
    final tagIds = <int, String>{};
    for (final row in tags) {
      final localId = row['id'] as int;
      final id = (await _ensureTagSharedId(localId, row: row))!;
      tagIds[localId] = id;
      final sourceKey = 'tag:$id';
      final first =
          await sharedState.importReceipt(bootstrapSource, sourceKey) == null;
      await _putBootstrapIfChanged(
          tagDomain,
          id,
          decodeTagDocument({
            'schemaVersion': 1,
            'domain': tagDomain,
            'id': id,
            'deleted': stampedValue(false, _stamp),
            'fields': {
              'name': stampedValue(row['font_family'], _stamp),
              'color':
                  stampedValue((row['line_height'] as num?)?.toInt(), _stamp),
            },
          }));
      if (first) {
        await _receipt(sourceKey, id);
        imported++;
      }
    }
    final relations = await db.query('tb_styles',
        where: 'ABS(font_size - 2.0) < 0.0001', orderBy: 'id');
    for (final row in relations) {
      final bookId = (row['line_height'] as num).toInt();
      final tagLocalId = (row['letter_spacing'] as num).toInt();
      final tagId = tagIds[tagLocalId];
      final books = await db.query('tb_books',
          columns: ['file_md5'],
          where: 'id = ?',
          whereArgs: [bookId],
          limit: 1);
      if (tagId == null || books.isEmpty) continue;
      String fingerprint;
      try {
        fingerprint = canonicalMd5Fingerprint(books.single['file_md5']);
      } catch (_) {
        continue;
      }
      final id = bookTagDocumentId(fingerprint, tagId);
      final sourceKey = 'book-tag:$id';
      final first =
          await sharedState.importReceipt(bootstrapSource, sourceKey) == null;
      await _putBootstrapIfChanged(
          bookTagDomain,
          id,
          decodeBookTagDocument({
            'schemaVersion': 1,
            'bookFingerprint': fingerprint,
            'tagId': tagId,
            'membership': stampedValue(true, _stamp),
          }));
      if (first) {
        await _receipt(sourceKey, id);
        imported++;
      }
    }

    final themes = await db.query('tb_themes', where: 'id > 2', orderBy: 'id');
    for (final row in themes) {
      final localId = row['id'] as int;
      final id = (await _ensureThemeSharedId(localId, row: row))!;
      final sourceKey = 'theme:$id';
      final first =
          await sharedState.importReceipt(bootstrapSource, sourceKey) == null;
      await _putBootstrapIfChanged(
          themeDomain,
          id,
          decodeThemeDocument({
            'schemaVersion': 1,
            'domain': themeDomain,
            'id': id,
            'deleted': stampedValue(false, _stamp),
            'fields': {
              'backgroundColor': stampedValue(row['background_color'], _stamp),
              'textColor': stampedValue(row['text_color'], _stamp),
            },
          }));
      if (first) {
        await _receipt(sourceKey, id);
        imported++;
      }
    }
    return imported;
  }

  Future<void> projectCanonical(String domain, String id) async {
    final bytes = await sharedState.canonicalDocument(domain, id);
    if (bytes == null) return;
    final raw = jsonDecode(utf8.decode(bytes));
    switch (domain) {
      case groupDomain:
        return _projectGroup(decodeGroupDocument(raw));
      case tagDomain:
        return _projectTag(decodeTagDocument(raw));
      case themeDomain:
        return _projectTheme(decodeThemeDocument(raw));
      case bookTagDomain:
        return _projectBookTag(decodeBookTagDocument(raw));
    }
  }

  /// Reconciles group projections in two passes so shared parent UUIDs never
  /// depend on the order in which remote documents completed.
  Future<void> projectAllCanonicalGroups() async {
    final documents = <Map<String, dynamic>>[];
    final ids = (await sharedState.documentIds(groupDomain)).toList()..sort();
    for (final id in ids) {
      final bytes = await sharedState.canonicalDocument(groupDomain, id);
      if (bytes != null) {
        documents.add(decodeGroupDocument(jsonDecode(utf8.decode(bytes))));
      }
    }
    for (final document in documents) {
      await _ensureGroupProjectionIdentity(document);
    }
    for (final document in documents) {
      await _projectGroup(document);
    }
  }

  /// Persists the distributed deletion before callers remove the local row.
  Future<void> tombstoneTag(int localId) =>
      _enqueue(() => _tombstoneTag(localId));

  Future<void> _tombstoneTag(int localId) async {
    final db = await _database();
    final rows = await db.query('tb_styles',
        where: 'id = ? AND ABS(font_size - 1.0) < 0.0001',
        whereArgs: [localId],
        limit: 1);
    final row = rows.isEmpty ? null : rows.single;
    final id = await _ensureTagSharedId(localId, row: row);
    if (id == null) return;
    final bytes = await sharedState.canonicalDocument(tagDomain, id);
    Map<String, dynamic> document;
    if (bytes != null) {
      document = decodeTagDocument(jsonDecode(utf8.decode(bytes)));
    } else {
      if (row == null) return;
      document = decodeTagDocument({
        'schemaVersion': 1,
        'domain': tagDomain,
        'id': id,
        'deleted': stampedValue(false, _stamp),
        'fields': {
          'name': stampedValue(row['font_family'], _stamp),
          'color': stampedValue((row['line_height'] as num?)?.toInt(), _stamp),
        },
      });
    }
    document['deleted'] = stampedValue(true, _stamp);
    await _putIfChanged(tagDomain, id, decodeTagDocument(document));
  }

  /// Built-in themes are local application defaults and are never tombstoned.
  Future<void> tombstoneTheme(int localId) =>
      _enqueue(() => _tombstoneTheme(localId));

  Future<void> _tombstoneTheme(int localId) async {
    if (localId <= 2) return;
    final db = await _database();
    final rows = await db.query('tb_themes',
        where: 'id = ? AND id > 2', whereArgs: [localId], limit: 1);
    final row = rows.isEmpty ? null : rows.single;
    final id = await _ensureThemeSharedId(localId, row: row);
    if (id == null) return;
    final bytes = await sharedState.canonicalDocument(themeDomain, id);
    Map<String, dynamic> document;
    if (bytes != null) {
      document = decodeThemeDocument(jsonDecode(utf8.decode(bytes)));
    } else {
      if (row == null) return;
      document = decodeThemeDocument({
        'schemaVersion': 1,
        'domain': themeDomain,
        'id': id,
        'deleted': stampedValue(false, _stamp),
        'fields': {
          'backgroundColor': stampedValue(row['background_color'], _stamp),
          'textColor': stampedValue(row['text_color'], _stamp),
        },
      });
    }
    document['deleted'] = stampedValue(true, _stamp);
    await _putIfChanged(themeDomain, id, decodeThemeDocument(document));
  }

  /// Persists the distributed deletion before callers remove the local row.
  Future<void> tombstoneGroup(int localId) =>
      _enqueue(() => _tombstoneGroup(localId));

  Future<void> _tombstoneGroup(int localId) async {
    final db = await _database();
    final rows = await db.query('tb_groups',
        where: 'id = ?', whereArgs: [localId], limit: 1);
    var mappings = await db.query('sync_group_ids',
        columns: ['shared_id'],
        where: 'local_id = ?',
        whereArgs: [localId],
        limit: 1);
    if (mappings.isEmpty) {
      if (rows.isEmpty) return;
      final row = rows.single;
      await _ensureGroupSharedId(localId, row: row);
      mappings = await db.query('sync_group_ids',
          columns: ['shared_id'],
          where: 'local_id = ?',
          whereArgs: [localId],
          limit: 1);
    }
    final id = mappings.single['shared_id'] as String;
    final bytes = await sharedState.canonicalDocument(groupDomain, id);
    Map<String, dynamic> document;
    if (bytes != null) {
      document = decodeGroupDocument(jsonDecode(utf8.decode(bytes)));
    } else {
      if (rows.isEmpty) return;
      final row = rows.single;
      final parentLocalId = row['parent_id'] as int?;
      String? parentId;
      if (parentLocalId != null && parentLocalId != 0) {
        parentId = await _sharedId('sync_group_ids', parentLocalId);
      }
      document = decodeGroupDocument({
        'schemaVersion': 1,
        'domain': groupDomain,
        'id': id,
        'deleted': stampedValue(false, _stamp),
        'fields': {
          'name': stampedValue(row['name'] as String? ?? 'Group', _stamp),
          'parentId': stampedValue(parentId, _stamp),
        },
      });
    }
    document['deleted'] = stampedValue(true, _stamp);
    await _putIfChanged(groupDomain, id, decodeGroupDocument(document));
  }

  Future<void> publishBookTagByLocalIds(
          int bookId, int tagLocalId, bool present) =>
      _enqueue(() => _publishBookTagByLocalIds(bookId, tagLocalId, present));

  Future<void> _publishBookTagByLocalIds(
      int bookId, int tagLocalId, bool present) async {
    final db = await _database();
    final books = await db.query('tb_books',
        columns: ['file_md5'], where: 'id = ?', whereArgs: [bookId], limit: 1);
    if (books.isEmpty) return;
    String fingerprint;
    try {
      fingerprint = canonicalMd5Fingerprint(books.single['file_md5']);
    } catch (_) {
      // Relations for books without a portable fingerprint stay device-local.
      return;
    }
    final tagId = await _ensureTagSharedId(tagLocalId);
    if (tagId == null) return;
    final id = bookTagDocumentId(fingerprint, tagId);
    await _putIfChanged(
        bookTagDomain,
        id,
        decodeBookTagDocument({
          'schemaVersion': 1,
          'bookFingerprint': fingerprint,
          'tagId': tagId,
          'membership': stampedValue(present, _stamp),
        }));
  }

  Future<void> publishBookGroupByLocalIds(int bookId, int groupLocalId) async {
    final db = await _database();
    final books = await db.query('tb_books',
        columns: ['file_md5'], where: 'id = ?', whereArgs: [bookId], limit: 1);
    if (books.isEmpty) return;
    final fingerprint = canonicalMd5Fingerprint(books.single['file_md5']);
    String? groupId;
    if (groupLocalId != 0) {
      final mappings = await db.query('sync_group_ids',
          columns: ['shared_id'],
          where: 'local_id = ?',
          whereArgs: [groupLocalId],
          limit: 1);
      if (mappings.isEmpty) return;
      groupId = mappings.single['shared_id'] as String;
    }
    final bytes =
        await sharedState.canonicalDocument(libraryCatalogDomain, fingerprint);
    if (bytes == null) return;
    final catalog =
        decodeLibraryCatalogDocument(jsonDecode(utf8.decode(bytes)));
    final current = catalog['groupId'] as Map<String, dynamic>?;
    if (current?['value'] == groupId) return;
    catalog['groupId'] = stampedValue(groupId, _stamp);
    await sharedState.putCanonicalDocument(libraryCatalogDomain, fingerprint,
        encodeDomainDocument(decodeLibraryCatalogDocument(catalog)));
  }

  Future<void> _projectGroup(Map<String, dynamic> doc) async {
    final db = await _database();
    final localId = await _ensureGroupProjectionIdentity(doc);
    if (localId == null) return;
    final fields = doc['fields'] as Map<String, dynamic>;
    final parentId = (fields['parentId'] as Map)['value'] as String?;
    final parentLocalId =
        parentId == null ? null : await _localId('sync_group_ids', parentId);
    final values = <String, Object?>{
      'name': (fields['name'] as Map)['value'],
      'is_deleted': (doc['deleted'] as Map)['value'] == true ? 1 : 0,
      'update_time': now().toIso8601String(),
    };
    if (parentId == null) {
      values['parent_id'] = 0;
    } else if (parentLocalId != null) {
      values['parent_id'] = parentLocalId;
    }
    await db.update('tb_groups', values, where: 'id = ?', whereArgs: [localId]);
  }

  Future<int?> _ensureGroupProjectionIdentity(Map<String, dynamic> doc) async {
    final id = doc['id'] as String;
    final mapped = await _localId('sync_group_ids', id);
    if (mapped != null) return mapped;
    if ((doc['deleted'] as Map)['value'] == true) return null;
    final timestamp = now().toIso8601String();
    final localId = await (await _database()).insert('tb_groups', {
      'name': 'Group',
      // Null means unresolved during projection. Only a canonical null parent
      // is projected to the application's local root sentinel (0).
      'parent_id': null,
      'is_deleted': 0,
      'create_time': timestamp,
      'update_time': timestamp,
    });
    await _map('sync_group_ids', id, localId);
    return localId;
  }

  Future<void> _projectTag(Map<String, dynamic> doc) async {
    final db = await _database();
    final id = doc['id'] as String;
    var localId = await _localId('sync_tag_ids', id);
    final deleted = (doc['deleted'] as Map)['value'] == true;
    if (localId == null && !deleted) {
      localId = await db
          .insert('tb_styles', {'font_size': 1.0, 'font_family': 'Tag'});
      await _map('sync_tag_ids', id, localId);
    }
    if (localId == null) return;
    if (deleted) {
      await db.delete('tb_styles', where: 'id = ?', whereArgs: [localId]);
      await db.delete('tb_styles',
          where:
              'ABS(font_size - 2.0) < 0.0001 AND CAST(letter_spacing AS INTEGER) = ?',
          whereArgs: [localId]);
      return;
    }
    final fields = doc['fields'] as Map<String, dynamic>;
    await db.update(
        'tb_styles',
        {
          'font_family': (fields['name'] as Map)['value'],
          'line_height': (fields['color'] as Map)['value'],
        },
        where: 'id = ?',
        whereArgs: [localId]);
  }

  Future<void> _projectTheme(Map<String, dynamic> doc) async {
    final db = await _database();
    final id = doc['id'] as String;
    var localId = await _localId('sync_theme_ids', id);
    final deleted = (doc['deleted'] as Map)['value'] == true;
    if (localId == null && !deleted) {
      localId = await db.insert('tb_themes', {
        'background_color': 'fffbfbf3',
        'text_color': 'ff343434',
        'background_image_path': '',
      });
      await _map('sync_theme_ids', id, localId);
    }
    if (localId == null) return;
    if (deleted) {
      await db.delete('tb_themes',
          where: 'id = ? AND id > 2', whereArgs: [localId]);
      return;
    }
    final fields = doc['fields'] as Map<String, dynamic>;
    await db.update(
        'tb_themes',
        {
          'background_color': (fields['backgroundColor'] as Map)['value'],
          'text_color': (fields['textColor'] as Map)['value'],
        },
        where: 'id = ?',
        whereArgs: [localId]);
  }

  Future<void> _projectBookTag(Map<String, dynamic> doc) async {
    final db = await _database();
    final tagLocalId = await _localId('sync_tag_ids', doc['tagId'] as String);
    final books = await db.query('tb_books',
        columns: ['id'],
        where: 'LOWER(file_md5) = ?',
        whereArgs: [doc['bookFingerprint']],
        limit: 1);
    if (tagLocalId == null || books.isEmpty) return;
    final bookId = books.single['id'] as int;
    await db.delete('tb_styles',
        where:
            'ABS(font_size - 2.0) < 0.0001 AND CAST(line_height AS INTEGER) = ? AND CAST(letter_spacing AS INTEGER) = ?',
        whereArgs: [bookId, tagLocalId]);
    if ((doc['membership'] as Map)['value'] == true) {
      await db.insert('tb_styles', {
        'font_size': 2.0,
        'line_height': bookId.toDouble(),
        'letter_spacing': tagLocalId.toDouble(),
      });
    }
  }

  /// Bootstrap reflects legacy projection fields, but it is not a user
  /// recreation/addition and therefore cannot defeat an explicit mutation
  /// while the destructive DAO is still removing that projection.
  Future<bool> _putBootstrapIfChanged(
      String domain, String id, Map<String, dynamic> document) async {
    final bytes = await sharedState.canonicalDocument(domain, id);
    if (bytes != null) {
      final current = jsonDecode(utf8.decode(bytes));
      if (domain == bookTagDomain) {
        final canonical = decodeBookTagDocument(current);
        if ((canonical['membership'] as Map)['value'] == false) {
          document['membership'] = canonical['membership'];
        }
      } else {
        final canonical = switch (domain) {
          groupDomain => decodeGroupDocument(current),
          tagDomain => decodeTagDocument(current),
          themeDomain => decodeThemeDocument(current),
          _ => throw ArgumentError.value(domain),
        };
        if ((canonical['deleted'] as Map)['value'] == true) {
          document['deleted'] = canonical['deleted'];
        }
      }
    }
    return _putIfChanged(domain, id, document);
  }

  Future<bool> _putIfChanged(
      String domain, String id, Map<String, dynamic> doc) async {
    final current = await sharedState.canonicalDocument(domain, id);
    if (current != null) {
      final existing = jsonDecode(utf8.decode(current));
      if (canonicalJson(_semantic(existing)) == canonicalJson(_semantic(doc))) {
        return false;
      }
    }
    await sharedState.putCanonicalDocument(
        domain, id, Uint8List.fromList(encodeDomainDocument(doc)));
    return true;
  }

  Object? _semantic(Object? value) {
    if (value is List) return value.map(_semantic).toList();
    if (value is Map) {
      return {
        for (final entry in value.entries)
          if (entry.key != 'stamp') entry.key: _semantic(entry.value),
      };
    }
    return value;
  }

  Future<void> _receipt(String key, String id) => sharedState.recordImport(
      source: bootstrapSource,
      sourceKey: key,
      sharedId: id,
      status: 'complete');

  Future<String> _ensureMapping(
      String table, int localId, String namespace) async {
    final db = await _database();
    final rows = await db.query(table,
        columns: ['shared_id'],
        where: 'local_id = ?',
        whereArgs: [localId],
        limit: 1);
    if (rows.isNotEmpty) return rows.single['shared_id'] as String;
    final id = uuid.v5(Namespace.url.value, namespace);
    await _map(table, id, localId);
    return id;
  }

  Future<String?> _ensureGroupSharedId(int localId,
      {Map<String, Object?>? row}) async {
    final existing = await _sharedId('sync_group_ids', localId);
    if (existing != null) return existing;
    if (row == null) {
      final rows = await (await _database())
          .query('tb_groups', where: 'id = ?', whereArgs: [localId], limit: 1);
      if (rows.isEmpty) return null;
      row = rows.single;
    }
    return _ensureMapping('sync_group_ids', localId,
        'anx:legacy-group:v1:$localId:${row['create_time']}:${row['name']}');
  }

  Future<String?> _ensureTagSharedId(int localId,
      {Map<String, Object?>? row}) async {
    final existing = await _sharedId('sync_tag_ids', localId);
    if (existing != null) return existing;
    if (row == null) {
      final rows = await (await _database()).query('tb_styles',
          where: 'id = ? AND ABS(font_size - 1.0) < 0.0001',
          whereArgs: [localId],
          limit: 1);
      if (rows.isEmpty) return null;
      row = rows.single;
    }
    return _ensureMapping('sync_tag_ids', localId,
        'anx:legacy-tag:v1:$localId:${row['font_family']}');
  }

  Future<String?> _ensureThemeSharedId(int localId,
      {Map<String, Object?>? row}) async {
    final existing = await _sharedId('sync_theme_ids', localId);
    if (existing != null) return existing;
    if (row == null) {
      final rows = await (await _database()).query('tb_themes',
          where: 'id = ? AND id > 2', whereArgs: [localId], limit: 1);
      if (rows.isEmpty) return null;
      row = rows.single;
    }
    return _ensureMapping('sync_theme_ids', localId,
        'anx:legacy-theme:v1:$localId:${row['background_color']}:${row['text_color']}');
  }

  Future<int?> _localId(String table, String sharedId) async {
    final rows = await (await _database()).query(table,
        columns: ['local_id'],
        where: 'shared_id = ?',
        whereArgs: [sharedId],
        limit: 1);
    return rows.isEmpty ? null : rows.single['local_id'] as int;
  }

  Future<String?> _sharedId(String table, int localId) async {
    final rows = await (await _database()).query(table,
        columns: ['shared_id'],
        where: 'local_id = ?',
        whereArgs: [localId],
        limit: 1);
    return rows.isEmpty ? null : rows.single['shared_id'] as String;
  }

  Future<void> _map(String table, String sharedId, int localId) async {
    await (await _database()).rawInsert(
        'INSERT OR REPLACE INTO $table (shared_id, local_id) VALUES (?, ?)',
        [sharedId, localId]);
  }
}
