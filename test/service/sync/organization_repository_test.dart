import 'dart:convert';

import 'package:anx_reader/service/sync/domain_stamp.dart';
import 'package:anx_reader/service/sync/organization_protocol.dart';
import 'package:anx_reader/service/sync/organization_repository.dart';
import 'package:anx_reader/service/sync/shared_state_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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
  late SharedStateDatabase sharedState;
  late OrganizationRepository repository;

  setUp(() async {
    appDatabase = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
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
    sharedState = SharedStateDatabase(
        path: inMemoryDatabasePath, factory: databaseFactoryFfi);
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
    expect(
        (await sharedState.canonicalDocument(groupDomain, childId)), isNotNull);
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
}
