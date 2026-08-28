import 'dart:io';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/dao/database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Directory directory;
  late String path;

  setUp(() async {
    SharedPreferences.setMockInitialValues({'webdavStatus': false});
    await Prefs().initPrefs();
    directory = await Directory.systemTemp.createTemp('anx_app_db_test_');
    path = p.join(directory.path, 'app_database.db');
  });

  tearDown(() async {
    await DBHelper.close();
    await directory.delete(recursive: true);
  });

  test('production migration preserves v7 data and enforces v8 shared IDs',
      () async {
    final version7 = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(
            version: 7,
            onCreate: (db, _) async {
              await db.execute('''CREATE TABLE tb_notes (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                book_id INTEGER,
                content TEXT,
                cfi TEXT,
                chapter TEXT,
                type TEXT,
                color TEXT,
                create_time TEXT,
                update_time TEXT,
                reader_note TEXT
              )''');
              await db.execute('''CREATE TABLE migration_sentinel (
                id INTEGER PRIMARY KEY,
                value TEXT NOT NULL
              )''');
              await db.insert('tb_notes', {
                'id': 41,
                'book_id': 7,
                'content': 'selected text',
                'cfi': 'epubcfi(/6/4!/4/2:3)',
                'chapter': 'Chapter 2',
                'type': 'highlight',
                'color': 'fff4c542',
                'reader_note': 'remember this',
                'create_time': '2025-01-02T03:04:05.000Z',
                'update_time': '2025-06-07T08:09:10.000Z',
              });
              await db
                  .insert('migration_sentinel', {'id': 1, 'value': 'survives'});
            }));
    final before = (await version7.query('tb_notes')).single;
    expect(await version7.getVersion(), 7);
    await version7.close();

    var version8 = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(
            version: currentDbVersion,
            onUpgrade: DBHelper().onUpgradeDatabase));
    expect(await version8.getVersion(), 8);

    final after = (await version8.query('tb_notes', where: 'id = 41')).single;
    for (final column in [
      'id',
      'book_id',
      'content',
      'cfi',
      'chapter',
      'type',
      'color',
      'reader_note',
      'create_time',
      'update_time',
    ]) {
      expect(after[column], before[column], reason: '$column must survive');
    }
    expect(after['shared_annotation_id'], isNull);
    expect(
        (await version8.rawQuery('PRAGMA table_info(tb_notes)'))
            .map((row) => row['name']),
        contains('shared_annotation_id'));
    expect(await version8.query('migration_sentinel'), [
      {'id': 1, 'value': 'survives'}
    ]);

    Future<int> insertNote(int id, String? sharedId) =>
        version8.insert('tb_notes', {
          'id': id,
          'book_id': 7,
          'content': 'note $id',
          'shared_annotation_id': sharedId,
        });

    await insertNote(42, null);
    await insertNote(43, null);
    await insertNote(44, 'shared-a');
    await insertNote(45, 'shared-b');
    await expectLater(
        insertNote(46, 'shared-a'), throwsA(isA<DatabaseException>()));

    final indexes = await version8.rawQuery(
        "SELECT sql FROM sqlite_master WHERE type = 'index' AND name = ?",
        ['idx_tb_notes_shared_annotation_id']);
    expect(indexes, hasLength(1));
    expect(indexes.single['sql'],
        contains('WHERE shared_annotation_id IS NOT NULL'));
    await version8.close();

    version8 = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(
            version: currentDbVersion,
            onUpgrade: DBHelper().onUpgradeDatabase));
    expect(await version8.getVersion(), 8);
    expect(await version8.query('tb_notes'), hasLength(5));
    expect((await version8.query('migration_sentinel')).single['value'],
        'survives');
    await version8.close();
  });
}
