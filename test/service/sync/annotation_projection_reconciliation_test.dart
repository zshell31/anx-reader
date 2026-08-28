import 'dart:io';

import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/models/book_note.dart';
import 'package:anx_reader/service/sync/annotation_projection_reconciler.dart';
import 'package:anx_reader/service/sync/legacy_annotation_bootstrap.dart';
import 'package:anx_reader/service/sync/native_annotation_projection.dart';
import 'package:anx_reader/service/sync/shared_state_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const fingerprint = '0123456789abcdef0123456789abcdef';
const created = '2026-01-02T03:04:05.000Z';
const updated = '2026-02-03T04:05:06.000Z';
const cfi = 'epubcfi(/6/4!/4/2:3)';

Book book(int id, {String path = 'book.epub', String? md5 = fingerprint}) =>
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
      createTime: DateTime.parse(created),
      updateTime: DateTime.parse(updated),
    );

BookNote note(
  int id,
  int bookId, {
  String value = cfi,
  String text = 'selected text',
  String chapter = 'Chapter 1',
  String type = 'highlight',
  String color = 'yellow',
  String? readerNote,
  String? sharedId,
  String createdAt = created,
  String updatedAt = updated,
}) =>
    BookNote(
      id: id,
      bookId: bookId,
      content: text,
      cfi: value,
      chapter: chapter,
      type: type,
      color: color,
      readerNote: readerNote,
      sharedAnnotationId: sharedId,
      createTime: DateTime.parse(createdAt),
      updateTime: DateTime.parse(updatedAt),
    );

Map<String, dynamic> annotation(
  String id, {
  String value = cfi,
  String text = 'selected text',
  String chapter = 'Chapter 1',
  String motivation = 'selection',
  String createdAt = created,
  String updatedAt = updated,
  String? deletedAt,
  List<Map<String, dynamic>> enrichments = const [],
  String selectorType = 'epub-cfi',
}) =>
    {
      'id': id,
      'motivation': motivation,
      'createdAt': createdAt,
      'updatedAt': updatedAt,
      if (deletedAt != null) 'deletedAt': deletedAt,
      'target': {
        'selectedText': text,
        'chapter': chapter,
        'selectors': [
          {
            'type': selectorType,
            selectorType == 'epub-cfi' ? 'cfi' : 'value': value
          }
        ],
      },
      'enrichments': enrichments,
    };

Map<String, dynamic> document(List<Map<String, dynamic>> annotations) => {
      'schemaVersion': 2,
      'book': {
        'fingerprintAlgorithm': 'md5',
        'fingerprint': fingerprint,
      },
      'annotations': annotations,
    };

class FakeNativeStore implements NativeAnnotationProjectionStore {
  Map<int, Book> books;
  List<BookNote> notes;
  int nextNativeId;
  int binds = 0;
  int inserts = 0;
  int updates = 0;
  int deletes = 0;

  FakeNativeStore({
    required Iterable<Book> books,
    required Iterable<BookNote> notes,
    this.nextNativeId = 1,
  })  : books = {for (final value in books) value.id: value},
        notes = List.of(notes);

  void replaceSnapshot({
    required Iterable<Book> books,
    required Iterable<BookNote> notes,
    required int nextNativeId,
  }) {
    this.books = {for (final value in books) value.id: value};
    this.notes = List.of(notes);
    this.nextNativeId = nextNativeId;
  }

  @override
  Future<List<BookNote>> enumerateLegacyUnboundNotes() async => notes
      .where((value) =>
          value.sharedAnnotationId == null &&
          const ['highlight', 'underline', 'bookmark'].contains(value.type))
      .toList();

  @override
  Future<Book?> readBook(int localBookId) async => books[localBookId];

  @override
  Future<List<Book>> findBooksByFingerprint(String value) async => books.values
      .where((book) =>
          !book.isDeleted && book.md5?.toLowerCase() == value.toLowerCase())
      .toList();

  @override
  Future<void> bindSharedAnnotation(
      int nativeNoteId, String annotationId) async {
    notes.singleWhere((value) => value.id == nativeNoteId).sharedAnnotationId =
        annotationId;
    binds++;
  }

  @override
  Future<BookNote?> findBySharedAnnotationId(String annotationId) async {
    final matches =
        notes.where((value) => value.sharedAnnotationId == annotationId);
    return matches.isEmpty ? null : matches.single;
  }

  @override
  Future<BookNote> readProjection(int nativeNoteId) async =>
      notes.singleWhere((value) => value.id == nativeNoteId);

  @override
  Future<int> insertProjection(BookNote value) async {
    value.id = nextNativeId++;
    notes.add(value);
    inserts++;
    return value.id!;
  }

  @override
  Future<void> updateProjection(BookNote value) async {
    final index = notes.indexWhere((item) => item.id == value.id);
    notes[index] = value;
    updates++;
  }

  @override
  Future<void> deleteProjection(int nativeNoteId) async {
    notes.removeWhere((value) => value.id == nativeNoteId);
    deletes++;
  }
}

void main() {
  sqfliteFfiInit();

  late Directory directory;
  late String sharedPath;
  late SharedStateDatabase shared;

  setUp(() async {
    directory =
        await Directory.systemTemp.createTemp('anx_projection_m4c_test_');
    sharedPath = p.join(directory.path, 'shared_state.db');
    shared = SharedStateDatabase(path: sharedPath, factory: databaseFactoryFfi);
  });

  tearDown(() async {
    await shared.close();
    await directory.delete(recursive: true);
  });

  NativeAnnotationDefaults defaults() => const NativeAnnotationDefaults(
      selectionType: 'highlight', color: '66CCFF');

  group('portable legacy anchor and bootstrap', () {
    test('anchor ignores native IDs but distinguishes portable evidence', () {
      final original = note(17, 4);
      final replacement = note(91, 23);
      expect(
        LegacyAnnotationAnchor.forNote(fingerprint, original),
        LegacyAnnotationAnchor.forNote(fingerprint, replacement),
      );
      expect(
        LegacyAnnotationAnchor.forNote(fingerprint, original),
        isNot(LegacyAnnotationAnchor.forNote(
            fingerprint, note(18, 4, value: 'epubcfi(/6/8!/4/2:3)'))),
        reason: 'same text at distinct locators must stay distinct',
      );
      expect(
        LegacyAnnotationAnchor.forNote(fingerprint, original),
        isNot(LegacyAnnotationAnchor.forNote(
            fingerprint, note(19, 4, text: 'a second selection'))),
        reason: 'same-CFI annotations must not collapse by locator alone',
      );
      expect(
        LegacyAnnotationAnchor.forNote(fingerprint, original),
        isNot(LegacyAnnotationAnchor.forNote(
            fingerprint, note(20, 4, createdAt: updated))),
      );
    });

    test('safe EPUB import is idempotent and preserves personal note',
        () async {
      final native = FakeNativeStore(
          books: [book(4)], notes: [note(17, 4, readerNote: 'remember')]);
      final bootstrap = LegacyAnnotationBootstrap(shared, native: native);

      expect((await bootstrap.run()).imported, 1);
      expect((await bootstrap.run()).imported, 0);
      final canonical = await shared.annotationDocument(fingerprint);
      final annotations = canonical!['annotations'] as List;
      expect(annotations, hasLength(1));
      expect(annotations.single['target'].containsKey('context'), isFalse);
      expect(annotations.single['enrichments'].single['content'], 'remember');
      expect(native.notes.single.sharedAnnotationId,
          annotations.single['id'] as String);
    });

    test('changed Book and BookNote IDs retain one shared identity', () async {
      final native = FakeNativeStore(books: [book(4)], notes: [note(17, 4)]);
      final bootstrap = LegacyAnnotationBootstrap(shared, native: native);
      await bootstrap.run();
      final firstId = ((await shared
              .annotationDocument(fingerprint))!['annotations'] as List)
          .single['id'];

      native.replaceSnapshot(
          books: [book(23)], notes: [note(91, 23)], nextNativeId: 100);
      final result = await bootstrap.run();
      final annotations = (await shared
          .annotationDocument(fingerprint))!['annotations'] as List;
      expect(result.alreadyImported, 1);
      expect(annotations, hasLength(1));
      expect(annotations.single['id'], firstId);
      expect(native.notes.single.sharedAnnotationId, firstId);
    });

    test('earlier local-ID-derived tombstone is recognized by anchor',
        () async {
      await shared.putAnnotationDocument(document(
          [annotation('earlier-local-id-derived', deletedAt: updated)]));
      final native = FakeNativeStore(books: [book(23)], notes: [note(91, 23)]);

      final result =
          await LegacyAnnotationBootstrap(shared, native: native).run();
      final annotations = (await shared
          .annotationDocument(fingerprint))!['annotations'] as List;
      expect(result.alreadyImported, 1);
      expect(annotations, hasLength(1));
      expect(annotations.single['id'], 'earlier-local-id-derived');
      expect(
          native.notes.single.sharedAnnotationId, 'earlier-local-id-derived');
      await AnnotationProjectionReconciler(shared,
              native: native, defaults: defaults)
          .run();
      expect(native.notes, isEmpty);
      expect(
          (await shared.annotationDocument(fingerprint))!['annotations']
              .single['deletedAt'],
          updated);
    });

    test(
        'distinct annotations at same CFI and same text at distinct CFIs survive',
        () async {
      final native = FakeNativeStore(books: [
        book(4)
      ], notes: [
        note(1, 4),
        note(2, 4, text: 'other text'),
        note(3, 4, value: 'epubcfi(/6/8!/4/2:3)'),
      ]);
      await LegacyAnnotationBootstrap(shared, native: native).run();
      expect((await shared.annotationDocument(fingerprint))!['annotations'],
          hasLength(3));
    });

    test('unsupported format gets a durable receipt and remains untouched',
        () async {
      final legacy = note(17, 4, value: 'page:1');
      final native =
          FakeNativeStore(books: [book(4, path: 'book.pdf')], notes: [legacy]);
      final bootstrap = LegacyAnnotationBootstrap(shared, native: native);
      expect((await bootstrap.run()).unsupported, 1);
      expect((await bootstrap.run()).unsupported, 1);
      expect(await shared.annotationDocuments(), isEmpty);
      expect(legacy.sharedAnnotationId, isNull);
      final receipts = await (await shared.database)
          .query('legacy_import_receipts', where: "status = 'unsupported'");
      expect(receipts, hasLength(1));
      expect(receipts.single['shared_id'], isNull);
    });
  });

  group('canonical projection reconciliation', () {
    test('duplicate canonical CFIs materialize as independent native rows',
        () async {
      await shared
          .putAnnotationDocument(document([annotation('a'), annotation('b')]));
      final native =
          FakeNativeStore(books: [book(7)], notes: const [], nextNativeId: 40);
      final reconciler = AnnotationProjectionReconciler(shared,
          native: native, defaults: defaults);
      final first = await reconciler.run();
      final second = await reconciler.run();

      expect(first.inserted, 2);
      expect(native.notes, hasLength(2));
      expect(native.notes.map((value) => value.cfi).toSet(), {cfi});
      expect(native.notes.map((value) => value.sharedAnnotationId).toSet(),
          {'a', 'b'});
      expect(second.nativeWrites, 0);
      expect(second.metadataWrites, 0);
    });

    test('missing projection is recreated with a new native ID', () async {
      await shared.putAnnotationDocument(document([annotation('a')]));
      final native =
          FakeNativeStore(books: [book(7)], notes: const [], nextNativeId: 10);
      final reconciler = AnnotationProjectionReconciler(shared,
          native: native, defaults: defaults);
      await reconciler.run();
      expect(native.notes.single.id, 10);

      native.notes.clear();
      native.nextNativeId = 57;
      await reconciler.run();
      expect(native.notes.single.id, 57);
      expect(native.notes.single.sharedAnnotationId, 'a');
      expect((await shared.annotationProjection('a'))!.nativeNoteId, 57);
    });

    test('bookmark uses native bookmark semantics and local default color',
        () async {
      await shared.putAnnotationDocument(
          document([annotation('bookmark', motivation: 'bookmark', text: '')]));
      final native = FakeNativeStore(books: [book(7)], notes: const []);
      await AnnotationProjectionReconciler(shared,
              native: native, defaults: defaults)
          .run();
      expect(native.notes.single.type, 'bookmark');
      expect(native.notes.single.color, '66CCFF');
      expect(native.notes.single.sharedAnnotationId, 'bookmark');
    });

    test('stale projection updates representable fields and keeps presentation',
        () async {
      final enrichments = [
        {
          'id': 'personal-old',
          'kind': 'personal-note',
          'content': 'older',
          'createdAt': created,
          'updatedAt': created,
        },
        {
          'id': 'translation',
          'kind': 'translation',
          'content': 'must stay canonical',
          'createdAt': created,
          'updatedAt': updated,
        },
        {
          'id': 'personal-new',
          'kind': 'personal-note',
          'content': 'newer',
          'createdAt': created,
          'updatedAt': updated,
        },
      ];
      await shared.putAnnotationDocument(document(
          [annotation('a', text: 'canonical', enrichments: enrichments)]));
      final existing = note(9, 7,
          text: 'stale',
          type: 'underline',
          color: 'local-red',
          readerNote: 'stale note',
          sharedId: 'a');
      final native = FakeNativeStore(books: [book(7)], notes: [existing]);
      final reconciler = AnnotationProjectionReconciler(shared,
          native: native, defaults: defaults);

      expect((await reconciler.run()).updated, 1);
      expect(native.notes.single.content, 'canonical');
      expect(native.notes.single.readerNote, 'newer');
      expect(native.notes.single.type, 'underline');
      expect(native.notes.single.color, 'local-red');
      expect((await reconciler.run()).nativeWrites, 0);
      final canonical = await shared.annotationDocument(fingerprint);
      expect(canonical!['annotations'].single['enrichments'], hasLength(3));
    });

    test('tombstoned personal note clears readerNote without canonical loss',
        () async {
      final enrichments = [
        {
          'id': 'personal-note:a',
          'kind': 'personal-note',
          'content': 'deleted note',
          'createdAt': created,
          'updatedAt': updated,
          'deletedAt': updated,
        },
        {
          'id': 'dictionary',
          'kind': 'dictionary',
          'content': 'preserved',
          'createdAt': created,
          'updatedAt': updated,
        },
      ];
      await shared.putAnnotationDocument(
          document([annotation('a', enrichments: enrichments)]));
      final native = FakeNativeStore(
          books: [book(7)],
          notes: [note(9, 7, readerNote: 'deleted note', sharedId: 'a')]);
      await AnnotationProjectionReconciler(shared,
              native: native, defaults: defaults)
          .run();
      expect(native.notes.single.readerNote, isNull);
      expect(
          (await shared.annotationDocument(fingerprint))!['annotations']
              .single['enrichments'],
          hasLength(2));
    });

    test('canonical tombstone hard-deletes native projection idempotently',
        () async {
      await shared.putAnnotationDocument(
          document([annotation('a', deletedAt: updated)]));
      final native = FakeNativeStore(
          books: [book(7)], notes: [note(10, 7, sharedId: 'a')]);
      final reconciler = AnnotationProjectionReconciler(shared,
          native: native, defaults: defaults);
      expect((await reconciler.run()).deleted, 1);
      expect(native.notes, isEmpty);
      expect((await reconciler.run()).nativeWrites, 0);
      expect(
          (await shared.annotationDocument(fingerprint))!['annotations']
              .single['deletedAt'],
          updated);
      expect((await shared.annotationProjection('a'))!.status,
          AnnotationProjectionStatus.tombstoned);
    });

    test('unsupported and unbound canonical records are preserved safely',
        () async {
      await shared.putAnnotationDocument(document([
        annotation('unsupported', selectorType: 'pdf-page'),
        annotation('unbound'),
      ]));
      final native = FakeNativeStore(books: const [], notes: [
        note(1, 7, sharedId: 'unsupported'),
        note(2, 7, sharedId: 'unbound'),
      ]);
      final before = await shared.annotationDocument(fingerprint);
      final result = await AnnotationProjectionReconciler(shared,
              native: native, defaults: defaults)
          .run();
      expect(result.unsupported, 1);
      expect(result.unbound, 1);
      expect(native.notes, isEmpty);
      expect(await shared.annotationDocument(fingerprint), before);
      expect((await shared.annotationProjection('unsupported'))!.status,
          AnnotationProjectionStatus.unsupported);
      expect((await shared.annotationProjection('unbound'))!.status,
          AnnotationProjectionStatus.unbound);
    });
  });

  test('old replacement snapshot cannot resurrect a canonical tombstone',
      () async {
    final native = FakeNativeStore(
        books: [book(4)], notes: [note(17, 4)], nextNativeId: 30);
    final bootstrap = LegacyAnnotationBootstrap(shared, native: native);
    await bootstrap.run();
    var canonical = await shared.annotationDocument(fingerprint);
    final sharedId = canonical!['annotations'].single['id'] as String;
    canonical['annotations'].single['deletedAt'] = updated;
    await shared.putAnnotationDocument(canonical);

    native.replaceSnapshot(
        books: [book(23)], notes: [note(91, 23)], nextNativeId: 100);
    expect((await bootstrap.run()).alreadyImported, 1);
    canonical = await shared.annotationDocument(fingerprint);
    expect(canonical!['annotations'], hasLength(1));
    expect(canonical['annotations'].single['id'], sharedId);
    expect(canonical['annotations'].single['deletedAt'], updated);

    await AnnotationProjectionReconciler(shared,
            native: native, defaults: defaults)
        .run();
    expect(native.notes, isEmpty);
    expect(
        (await shared.importReceipt(LegacyAnnotationAnchor.receiptSource,
                LegacyAnnotationAnchor.forNote(fingerprint, note(91, 23))))!
            .status,
        'tombstoned');
  });

  test('database replacement plus restart remains stable and imports only new',
      () async {
    final native = FakeNativeStore(books: [
      book(4)
    ], notes: [
      note(17, 4, text: 'existing'),
      note(18, 4, text: 'will be deleted', createdAt: updated),
    ]);
    var bootstrap = LegacyAnnotationBootstrap(shared, native: native);
    var reconciler = AnnotationProjectionReconciler(shared,
        native: native, defaults: defaults);
    await bootstrap.run();
    await reconciler.run();

    var canonical = await shared.annotationDocument(fingerprint);
    final deleted = (canonical!['annotations'] as List).singleWhere(
        (item) => item['target']['selectedText'] == 'will be deleted');
    deleted['deletedAt'] = updated;
    await shared.putAnnotationDocument(canonical);

    native.replaceSnapshot(books: [
      book(23)
    ], notes: [
      note(91, 23, text: 'existing'),
      note(92, 23, text: 'will be deleted', createdAt: updated),
      note(93, 23, text: 'genuinely new', value: 'epubcfi(/6/10!/4/2:3)'),
    ], nextNativeId: 100);
    final replacementImport = await bootstrap.run();
    await reconciler.run();
    expect(replacementImport.imported, 1);
    expect(replacementImport.alreadyImported, 2);
    expect(native.notes.map((value) => value.content).toSet(),
        {'existing', 'genuinely new'});
    expect((await shared.annotationDocument(fingerprint))!['annotations'],
        hasLength(3));

    await shared.close();
    shared = SharedStateDatabase(path: sharedPath, factory: databaseFactoryFfi);
    bootstrap = LegacyAnnotationBootstrap(shared, native: native);
    reconciler = AnnotationProjectionReconciler(shared,
        native: native, defaults: defaults);
    expect((await bootstrap.run()).imported, 0);
    final stable = await reconciler.run();
    expect(stable.nativeWrites, 0);
    expect(stable.metadataWrites, 0);
    expect((await shared.annotationDocument(fingerprint))!['annotations'],
        hasLength(3));
  });
}
