import 'dart:convert';
import 'dart:io';

import 'package:anx_reader/service/sync/domain_stamp.dart';
import 'package:anx_reader/service/sync/organization_protocol.dart';
import 'package:anx_reader/service/sync/organization_repository.dart';
import 'package:anx_reader/service/sync/shared_state_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

const parentId = '00000000-0000-4000-8000-000000000001';
const childId = '00000000-0000-4000-8000-000000000002';
const grandchildId = '00000000-0000-4000-8000-000000000003';

Map<String, dynamic> groupDocument(String id, String name,
    {String? parentId, bool deleted = false}) {
  final stamp =
      DomainStamp(modifiedAt: DateTime.utc(2026), deviceId: 'device-a');
  return decodeGroupDocument({
    'schemaVersion': 1,
    'domain': groupDomain,
    'id': id,
    'deleted': stampedValue(deleted, stamp),
    'fields': {
      'name': stampedValue(name, stamp),
      'parentId': stampedValue(parentId, stamp),
    },
  });
}

void main() {
  sqfliteFfiInit();

  late Database appDatabase;
  late Directory directory;
  late SharedStateDatabase sharedState;
  late OrganizationRepository repository;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('anx-org-sync-test-');
    appDatabase =
        await databaseFactoryFfi.openDatabase('${directory.path}/app.db');
    await appDatabase.execute('''CREATE TABLE tb_groups (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT,
      parent_id INTEGER,
      is_deleted INTEGER DEFAULT 0,
      create_time TEXT,
      update_time TEXT
    )''');
    await appDatabase.execute('''CREATE TABLE sync_group_ids (
      shared_id TEXT PRIMARY KEY,
      local_id INTEGER NOT NULL UNIQUE
    )''');
    await appDatabase.execute('''CREATE TABLE tb_styles (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      font_size REAL,
      font_family TEXT,
      line_height REAL,
      letter_spacing REAL
    )''');
    await appDatabase.execute('''CREATE TABLE tb_themes (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      background_color TEXT,
      text_color TEXT,
      background_image_path TEXT
    )''');
    await appDatabase.execute('''CREATE TABLE tb_books (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      file_md5 TEXT,
      group_id INTEGER
    )''');
    for (final table in ['sync_tag_ids', 'sync_theme_ids']) {
      await appDatabase.execute('''CREATE TABLE $table (
        shared_id TEXT PRIMARY KEY,
        local_id INTEGER NOT NULL UNIQUE
      )''');
    }
    sharedState = SharedStateDatabase(
        path: '${directory.path}/shared.db', factory: databaseFactoryFfi);
    repository = OrganizationRepository(
      sharedState: sharedState,
      deviceId: 'device-a',
      database: () async => appDatabase,
      now: () => DateTime.utc(2026, 1, 2),
    );
  });

  tearDown(() async {
    await sharedState.close();
    await appDatabase.close();
    await directory.delete(recursive: true);
  });

  Future<void> storeGroup(Map<String, dynamic> document) async {
    await sharedState.applyRemoteMerge(groupDomain, document['id'] as String,
        null, utf8.encode(jsonEncode(document)));
  }

  Future<int> localId(String sharedId) async {
    final rows = await appDatabase.query('sync_group_ids',
        columns: ['local_id'], where: 'shared_id = ?', whereArgs: [sharedId]);
    return rows.single['local_id'] as int;
  }

  test('child projected before parent resolves hierarchy in one final pass',
      () async {
    await storeGroup(groupDocument(childId, 'Child', parentId: parentId));
    final canonicalChildBefore =
        await sharedState.canonicalDocument(groupDomain, childId);
    await repository.projectCanonical(groupDomain, childId);
    expect((await appDatabase.query('tb_groups')).single['parent_id'], isNot(0),
        reason: 'an unresolved shared parent is not semantic root');

    await storeGroup(groupDocument(parentId, 'Parent'));
    await repository.projectCanonical(groupDomain, parentId);
    await repository.projectAllCanonicalGroups();

    final parentLocalId = await localId(parentId);
    final childLocalId = await localId(childId);
    final child = (await appDatabase
            .query('tb_groups', where: 'id = ?', whereArgs: [childLocalId]))
        .single;
    expect(child['parent_id'], parentLocalId);
    expect(await sharedState.canonicalDocument(groupDomain, childId),
        canonicalChildBefore,
        reason: 'projection order must not mutate canonical shared state');
  });

  test('parent projected before child resolves the same hierarchy', () async {
    await storeGroup(groupDocument(parentId, 'Parent'));
    await repository.projectCanonical(groupDomain, parentId);
    await storeGroup(groupDocument(childId, 'Child', parentId: parentId));
    await repository.projectCanonical(groupDomain, childId);
    await repository.projectAllCanonicalGroups();

    final childLocalId = await localId(childId);
    expect(
        (await appDatabase
                .query('tb_groups', where: 'id = ?', whereArgs: [childLocalId]))
            .single['parent_id'],
        await localId(parentId));
  });

  test('group hierarchy projection is idempotent at depth greater than one',
      () async {
    await storeGroup(
        groupDocument(grandchildId, 'Grandchild', parentId: childId));
    await storeGroup(groupDocument(childId, 'Child', parentId: parentId));
    await storeGroup(groupDocument(parentId, 'Parent'));

    await repository.projectAllCanonicalGroups();
    await repository.projectAllCanonicalGroups();

    expect(await appDatabase.query('tb_groups'), hasLength(3));
    expect((await appDatabase.query('sync_group_ids')), hasLength(3));
    final parentLocalId = await localId(parentId);
    final childLocalId = await localId(childId);
    final grandchildLocalId = await localId(grandchildId);
    expect(
        (await appDatabase.query('tb_groups',
                where: 'id = ?', whereArgs: [parentLocalId]))
            .single['parent_id'],
        0);
    expect(
        (await appDatabase
                .query('tb_groups', where: 'id = ?', whereArgs: [childLocalId]))
            .single['parent_id'],
        parentLocalId);
    expect(
        (await appDatabase.query('tb_groups',
                where: 'id = ?', whereArgs: [grandchildLocalId]))
            .single['parent_id'],
        childLocalId);
  });

  test('group tombstone survives physical removal and prevents resurrection',
      () async {
    await storeGroup(groupDocument(parentId, 'Published group'));
    await repository.projectAllCanonicalGroups();
    final groupLocalId = await localId(parentId);

    await repository.tombstoneGroup(groupLocalId);
    await appDatabase
        .delete('tb_groups', where: 'id = ?', whereArgs: [groupLocalId]);
    await repository.projectAllCanonicalGroups();

    final canonical = jsonDecode(utf8
        .decode((await sharedState.canonicalDocument(groupDomain, parentId))!));
    expect(canonical['deleted']['value'], isTrue);
    expect(await sharedState.outboxEntry(groupDomain, parentId), isNotNull);
    expect(await appDatabase.query('tb_groups'), isEmpty);
    expect((await appDatabase.query('sync_group_ids')).single['shared_id'],
        parentId,
        reason: 'the tombstone retains the stable shared identity');

    await repository.projectAllCanonicalGroups();
    expect(await appDatabase.query('tb_groups'), isEmpty);
  });

  test('semantic delete reconstructs a missing canonical group before cleanup',
      () async {
    const stableId = '00000000-0000-4000-8000-000000000004';
    final localId = await appDatabase.insert('tb_groups', {
      'name': 'Local group',
      'parent_id': 0,
      'is_deleted': 0,
      'create_time': '2025-01-01T00:00:00Z',
      'update_time': '2025-01-01T00:00:00Z',
    });
    await appDatabase
        .insert('sync_group_ids', {'shared_id': stableId, 'local_id': localId});
    expect(await sharedState.canonicalDocument(groupDomain, stableId), isNull);

    await repository.tombstoneGroup(localId);
    await appDatabase
        .delete('tb_groups', where: 'id = ?', whereArgs: [localId]);
    await repository.projectAllCanonicalGroups();

    final bytes = await sharedState.canonicalDocument(groupDomain, stableId);
    final canonical = jsonDecode(utf8.decode(bytes!));
    expect(canonical['id'], stableId);
    expect(canonical['deleted']['value'], isTrue);
    expect(canonical['fields']['name']['value'], 'Local group');
    expect(jsonEncode(canonical), isNot(contains('local_id')));
    expect(await sharedState.outboxEntry(groupDomain, stableId), isNotNull);
    expect(await appDatabase.query('tb_groups'), isEmpty);
    expect((await appDatabase.query('sync_group_ids')).single['shared_id'],
        stableId);
  });

  test('tag deletion before bootstrap establishes a durable tombstone',
      () async {
    final localId = await appDatabase.insert('tb_styles', {
      'font_size': 1.0,
      'font_family': 'Early tag',
      'line_height': 0x123456.toDouble(),
    });
    final expectedId = const Uuid()
        .v5(Namespace.url.value, 'anx:legacy-tag:v1:$localId:Early tag');

    await repository.tombstoneLocalRecord(tagDomain, 'sync_tag_ids', localId);

    final mappings = await appDatabase.query('sync_tag_ids');
    expect(mappings.single['shared_id'], expectedId);
    final bytes = await sharedState.canonicalDocument(tagDomain, expectedId);
    final canonical = jsonDecode(utf8.decode(bytes!));
    expect(canonical['deleted']['value'], isTrue);
    expect(canonical['fields']['name']['value'], 'Early tag');
    expect(await sharedState.outboxEntry(tagDomain, expectedId), isNotNull);

    await appDatabase
        .delete('tb_styles', where: 'id = ?', whereArgs: [localId]);
    await repository.projectCanonical(tagDomain, expectedId);
    expect(await appDatabase.query('tb_styles'), isEmpty,
        reason: 'a later projection must not resurrect the deleted tag');
  });

  test('theme deletion before bootstrap excludes local image state', () async {
    await appDatabase.insert('tb_themes', {
      'background_color': 'light',
      'text_color': 'dark',
      'background_image_path': '',
    });
    await appDatabase.insert('tb_themes', {
      'background_color': 'dark',
      'text_color': 'light',
      'background_image_path': '',
    });
    final localId = await appDatabase.insert('tb_themes', {
      'background_color': 'ff112233',
      'text_color': 'ffddeeff',
      'background_image_path': '/device/private/theme.png',
    });
    final expectedId = const Uuid().v5(
        Namespace.url.value, 'anx:legacy-theme:v1:$localId:ff112233:ffddeeff');

    await repository.tombstoneLocalRecord(
        themeDomain, 'sync_theme_ids', localId);

    expect((await appDatabase.query('sync_theme_ids')).single['shared_id'],
        expectedId);
    final bytes = await sharedState.canonicalDocument(themeDomain, expectedId);
    final encoded = utf8.decode(bytes!);
    final canonical = jsonDecode(encoded);
    expect(canonical['deleted']['value'], isTrue);
    expect(canonical['fields']['backgroundColor']['value'], 'ff112233');
    expect(canonical['fields']['textColor']['value'], 'ffddeeff');
    expect(encoded, isNot(contains('background_image_path')));
    expect(encoded, isNot(contains('/device/private/theme.png')));
    expect(await sharedState.outboxEntry(themeDomain, expectedId), isNotNull);

    await appDatabase
        .delete('tb_themes', where: 'id = ?', whereArgs: [localId]);
    await repository.projectCanonical(themeDomain, expectedId);
    expect(await appDatabase.query('tb_themes'), hasLength(2),
        reason: 'built-in themes remain and the custom theme stays deleted');
  });

  test('book-tag removal before bootstrap records explicit non-membership',
      () async {
    const fingerprint = '0123456789abcdef0123456789abcdef';
    final bookId = await appDatabase
        .insert('tb_books', {'file_md5': fingerprint, 'group_id': 0});
    final tagLocalId = await appDatabase.insert('tb_styles', {
      'font_size': 1.0,
      'font_family': 'Early relation tag',
      'line_height': 0xabcdef.toDouble(),
    });
    await appDatabase.insert('tb_styles', {
      'font_size': 2.0,
      'line_height': bookId.toDouble(),
      'letter_spacing': tagLocalId.toDouble(),
    });
    final tagId = const Uuid().v5(Namespace.url.value,
        'anx:legacy-tag:v1:$tagLocalId:Early relation tag');
    final documentId = bookTagDocumentId(fingerprint, tagId);

    await repository.publishBookTagByLocalIds(bookId, tagLocalId, false);

    expect(
        (await appDatabase.query('sync_tag_ids')).single['shared_id'], tagId);
    final bytes =
        await sharedState.canonicalDocument(bookTagDomain, documentId);
    final canonical = jsonDecode(utf8.decode(bytes!));
    expect(canonical['bookFingerprint'], fingerprint);
    expect(canonical['tagId'], tagId);
    expect(canonical['membership']['value'], isFalse);
    expect(await sharedState.outboxEntry(bookTagDomain, documentId), isNotNull);

    await appDatabase.delete('tb_styles',
        where:
            'ABS(font_size - 2.0) < 0.0001 AND CAST(line_height AS INTEGER) = ? AND CAST(letter_spacing AS INTEGER) = ?',
        whereArgs: [bookId, tagLocalId]);
    await repository.projectCanonical(bookTagDomain, documentId);
    expect(
        await appDatabase.query('tb_styles',
            where: 'ABS(font_size - 2.0) < 0.0001'),
        isEmpty,
        reason: 'a later projection must not restore the relation');
  });
}
