import 'dart:io';

import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/service/sync/annotation_read_model.dart';
import 'package:anx_reader/service/sync/legacy_annotation_bootstrap.dart';
import 'package:anx_reader/service/sync/legacy_annotation_store.dart';
import 'package:anx_reader/service/sync/shared_state_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const fingerprint = '0123456789abcdef0123456789abcdef';
const cfi = 'epubcfi(/6/4!/4/2:3)';
final created = DateTime.parse('2026-01-02T03:04:05.000Z');
final updated = DateTime.parse('2026-02-03T04:05:06.000Z');

Book book({int id = 7, String path = 'book.epub', String? md5 = fingerprint}) =>
    Book(
      id: id,
      title: 'Book',
      coverPath: '',
      filePath: path,
      lastReadPosition: '',
      readingPercentage: 0,
      author: 'Author',
      isDeleted: false,
      rating: 0,
      md5: md5,
      createTime: created,
      updateTime: updated,
    );

LegacyAnnotationRow row({
  int id = 41,
  int bookId = 7,
  String text = 'selected text',
  String value = cfi,
  String chapter = 'Chapter 1',
  String type = 'highlight',
  String color = 'yellow',
  String? personalNote,
  String? canonicalIdHint,
  DateTime? createTime,
  DateTime? updateTime,
}) =>
    LegacyAnnotationRow(
      rowId: id,
      localBookId: bookId,
      selectedText: text,
      cfi: value,
      chapter: chapter,
      type: type,
      color: color,
      personalNote: personalNote,
      canonicalIdHint: canonicalIdHint,
      createTime: createTime ?? created,
      updateTime: updateTime ?? updated,
    );

class FakeLegacyAnnotationStore implements LegacyAnnotationStore {
  final Map<int, Book> books;
  List<LegacyAnnotationRow> rows;
  int reads = 0;

  FakeLegacyAnnotationStore({
    required Iterable<Book> books,
    required Iterable<LegacyAnnotationRow> rows,
  })  : books = {for (final value in books) value.id: value},
        rows = List.of(rows);

  @override
  Future<List<LegacyAnnotationRow>> readAnnotations() async {
    reads++;
    return List.unmodifiable(rows);
  }

  @override
  Future<Book?> readBook(int localBookId) async => books[localBookId];
}

Map<String, dynamic> onlyAnnotation(Map<String, dynamic> document) =>
    (document['annotations'] as List).single as Map<String, dynamic>;

void main() {
  sqfliteFfiInit();

  late Directory directory;
  late String databasePath;
  late SharedStateDatabase shared;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('anx_legacy_import_');
    databasePath = p.join(directory.path, 'shared_state.db');
    shared = SharedStateDatabase(
      path: databasePath,
      factory: databaseFactoryFfi,
      now: () => updated.add(const Duration(days: 1)),
    );
  });

  tearDown(() async {
    await shared.close();
    await directory.delete(recursive: true);
  });

  test('legacy row imports semantics, personal note, and Anx presentation',
      () async {
    final legacy = FakeLegacyAnnotationStore(
      books: [book()],
      rows: [
        row(
          type: 'underline',
          color: '00ff00',
          personalNote: 'remember this',
        )
      ],
    );

    final result =
        await LegacyAnnotationBootstrap(shared, legacy: legacy).run();

    expect(result.imported, 1);
    expect(result.alreadyImported, 0);
    final annotation =
        onlyAnnotation((await shared.annotationDocument(fingerprint))!);
    expect(annotation['motivation'], 'selection');
    expect(annotation['target']['selectors'].single['cfi'], cfi);
    expect(annotation['enrichments'].single['kind'], 'personal-note');
    expect(annotation['enrichments'].single['content'], 'remember this');
    final presentation =
        await shared.annotationPresentation(annotation['id'] as String);
    expect(presentation?.style, AnnotationPresentationStyle.underline);
    expect(presentation?.color, '00ff00');
  });

  test('migration is idempotent across restart and missing receipt', () async {
    final legacy = FakeLegacyAnnotationStore(
      books: [book()],
      rows: [row(personalNote: 'remember')],
    );
    final bootstrap = LegacyAnnotationBootstrap(shared, legacy: legacy);
    await bootstrap.run();
    final firstBytes =
        await shared.canonicalDocument('annotations', fingerprint);
    await (await shared.database).delete('legacy_import_receipts');
    await shared.close();

    shared = SharedStateDatabase(
      path: databasePath,
      factory: databaseFactoryFfi,
      now: () => updated.add(const Duration(days: 2)),
    );
    final second =
        await LegacyAnnotationBootstrap(shared, legacy: legacy).run();

    expect(second.imported, 0);
    expect(second.alreadyImported, 1);
    expect((await shared.annotationDocument(fingerprint))!['annotations'],
        hasLength(1));
    expect(await shared.canonicalDocument('annotations', fingerprint),
        orderedEquals(firstBytes!));
  });

  test('existing canonical state is neither duplicated nor overwritten',
      () async {
    final legacy = FakeLegacyAnnotationStore(
        books: [book()], rows: [row(personalNote: 'old')]);
    await LegacyAnnotationBootstrap(shared, legacy: legacy).run();
    var document = (await shared.annotationDocument(fingerprint))!;
    final annotation = onlyAnnotation(document);
    annotation['updatedAt'] = '2026-08-30T12:00:00.000Z';
    annotation['futureField'] = {'preserve': true};
    (annotation['enrichments'] as List).single['content'] = 'newer canonical';
    await shared.putAnnotationDocument(document);

    final result =
        await LegacyAnnotationBootstrap(shared, legacy: legacy).run();

    document = (await shared.annotationDocument(fingerprint))!;
    expect(result.alreadyImported, 1);
    expect(document['annotations'], hasLength(1));
    expect(onlyAnnotation(document)['futureField'], {'preserve': true});
    expect(onlyAnnotation(document)['enrichments'].single['content'],
        'newer canonical');
  });

  test('canonical tombstone cannot be resurrected by a legacy row', () async {
    final legacy = FakeLegacyAnnotationStore(books: [book()], rows: [row()]);
    await LegacyAnnotationBootstrap(shared, legacy: legacy).run();
    final document = (await shared.annotationDocument(fingerprint))!;
    final annotation = onlyAnnotation(document);
    annotation['updatedAt'] = '2026-08-30T12:00:00.000Z';
    annotation['deletedAt'] = '2026-08-30T12:00:00.000Z';
    await shared.putAnnotationDocument(document);
    await shared.deleteAnnotationPresentation(annotation['id'] as String);

    await LegacyAnnotationBootstrap(shared, legacy: legacy).run();

    final after =
        onlyAnnotation((await shared.annotationDocument(fingerprint))!);
    expect(after['deletedAt'], '2026-08-30T12:00:00.000Z');
    expect(await shared.annotationPresentation(after['id'] as String), isNull);
  });

  test('tombstone receipt remains sticky when canonical snapshot is absent',
      () async {
    final legacy = FakeLegacyAnnotationStore(books: [book()], rows: [row()]);
    await LegacyAnnotationBootstrap(shared, legacy: legacy).run();
    final document = (await shared.annotationDocument(fingerprint))!;
    final annotation = onlyAnnotation(document);
    final anchor =
        LegacyAnnotationAnchor.forRow(fingerprint, legacy.rows.single);
    await shared.recordImport(
      source: LegacyAnnotationAnchor.receiptSource,
      sourceKey: anchor,
      sharedId: annotation['id'] as String,
      status: 'tombstoned',
    );
    document['annotations'] = <Object>[];
    await shared.putAnnotationDocument(document);

    final result =
        await LegacyAnnotationBootstrap(shared, legacy: legacy).run();

    expect(result.alreadyImported, 1);
    expect((await shared.annotationDocument(fingerprint))!['annotations'],
        isEmpty);
  });

  test('presentation reset is not overwritten by later legacy input', () async {
    final legacy =
        FakeLegacyAnnotationStore(books: [book()], rows: [row(color: 'red')]);
    await LegacyAnnotationBootstrap(shared, legacy: legacy).run();
    final annotation =
        onlyAnnotation((await shared.annotationDocument(fingerprint))!);
    final id = annotation['id'] as String;
    await shared.deleteAnnotationPresentation(id);
    legacy.rows = [row(color: 'blue')];

    await LegacyAnnotationBootstrap(shared, legacy: legacy).run();

    expect(await shared.annotationPresentation(id), isNull);
    expect(await shared.hasAnnotationPresentationOperation(id), isTrue);
  });

  test('stable canonical identity hint is preserved without CFI inference',
      () async {
    final legacy = FakeLegacyAnnotationStore(
      books: [book()],
      rows: [row(canonicalIdHint: 'established-canonical-id')],
    );

    await LegacyAnnotationBootstrap(shared, legacy: legacy).run();

    expect(
        onlyAnnotation((await shared.annotationDocument(fingerprint))!)['id'],
        'established-canonical-id');
  });

  test('same-CFI rows with distinct identity evidence stay distinct', () async {
    final legacy = FakeLegacyAnnotationStore(
      books: [book()],
      rows: [
        row(id: 1, text: 'first'),
        row(id: 2, text: 'second'),
      ],
    );

    await LegacyAnnotationBootstrap(shared, legacy: legacy).run();

    final annotations =
        (await shared.annotationDocument(fingerprint))!['annotations'] as List;
    expect(annotations, hasLength(2));
    expect(annotations.map((value) => value['id']).toSet(), hasLength(2));
    expect(
        annotations.map((value) => value['target']['selectors'].single['cfi']),
        everyElement(cfi));
  });

  test('unsupported legacy rows are recognized without canonical creation',
      () async {
    final legacy = FakeLegacyAnnotationStore(
      books: [book(path: 'book.pdf')],
      rows: [row()],
    );

    final first = await LegacyAnnotationBootstrap(shared, legacy: legacy).run();
    final second =
        await LegacyAnnotationBootstrap(shared, legacy: legacy).run();

    expect(first.unsupported, 1);
    expect(second.unsupported, 1);
    expect(await shared.annotationDocument(fingerprint), isNull);
  });

  test('legacy adapter is read-only and isolated from modern repository code',
      () {
    final adapter = File('lib/service/sync/legacy_annotation_store.dart')
        .readAsStringSync();
    final repository =
        File('lib/service/sync/annotation_repository.dart').readAsStringSync();
    expect(adapter, contains("'tb_notes'"));
    expect(adapter, isNot(contains('Future<int> insert')));
    expect(adapter, isNot(contains('Future<int> update')));
    expect(adapter, isNot(contains('Future<int> delete')));
    expect(repository, isNot(contains('legacy_annotation_store.dart')));
    expect(repository, isNot(contains('tb_notes')));
  });
}
