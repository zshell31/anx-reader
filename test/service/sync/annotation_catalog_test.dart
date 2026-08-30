import 'dart:io';

import 'package:anx_reader/service/sync/annotation_catalog.dart';
import 'package:anx_reader/service/notes/export_notes.dart';
import 'package:anx_reader/service/sync/annotation_read_model.dart';
import 'package:anx_reader/service/sync/shared_state_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const fingerprint = '0123456789abcdef0123456789abcdef';
const timestamp = '2026-08-30T10:00:00.000Z';

Map<String, dynamic> annotation(
  String id, {
  List<Map<String, dynamic>>? selectors,
  bool deleted = false,
}) =>
    {
      'id': id,
      'motivation': 'selection',
      'createdAt': timestamp,
      'updatedAt': timestamp,
      if (deleted) 'deletedAt': timestamp,
      'target': {
        'selectedText': 'Text $id',
        'chapter': 'Remote chapter',
        'context': 'Context for $id.',
        'selectors': selectors ??
            [
              {'type': 'epub-cfi', 'cfi': 'epubcfi(/6/2!/4/2)'}
            ],
      },
      'enrichments': [
        {
          'id': 'note-$id',
          'kind': 'personal-note',
          'content': 'Personal $id',
          'createdAt': timestamp,
          'updatedAt': timestamp,
        },
      ],
    };

void main() {
  sqfliteFfiInit();

  late Directory directory;
  late SharedStateDatabase store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('anx_catalog_test_');
    store = SharedStateDatabase(
      path: p.join(directory.path, 'shared_state.db'),
      factory: databaseFactoryFfi,
    );
  });

  tearDown(() async {
    await store.close();
    await directory.delete(recursive: true);
  });

  test('remote unbound annotations stay visible without native rows', () async {
    await store.putAnnotationDocument({
      'schemaVersion': 2,
      'book': {
        'fingerprintAlgorithm': 'md5',
        'fingerprint': fingerprint,
        'title': 'Remote Book',
        'author': 'Remote Author',
      },
      'annotations': [
        annotation('same-cfi-a'),
        annotation('same-cfi-b'),
        annotation('unsupported', selectors: [
          {'type': 'future-selector', 'value': 'kept'}
        ]),
        annotation('deleted', deleted: true),
      ],
    });
    await store.putAnnotationPresentation(const AnnotationPresentation(
      annotationId: 'same-cfi-a',
      style: AnnotationPresentationStyle.underline,
      color: 'FF00AA',
    ));

    final catalog = CanonicalAnnotationCatalog(
      store,
      loadLocalBooks: () async => const [],
    );
    final books = await catalog.readAll();

    expect(books, hasLength(1));
    final book = books.single;
    expect(book.isBound, isFalse);
    expect(book.title, 'Remote Book');
    expect(book.annotations.map((item) => item.ref.annotationId),
        ['same-cfi-a', 'same-cfi-b', 'unsupported']);
    expect(book.annotations.take(2).map((item) => item.epubCfi).toSet(),
        {'epubcfi(/6/2!/4/2)'});
    expect(book.annotations.first.navigationCapability,
        AnnotationCapability.localBookUnavailable);
    expect(book.annotations.last.navigationCapability,
        AnnotationCapability.unsupportedTarget);
    expect(book.annotations.first.effectivePersonalNote?.content,
        'Personal same-cfi-a');
    expect(book.annotations.first.localPresentation?.style,
        AnnotationPresentationStyle.underline);
    final csv = canonicalNotesCsvRows(book, book.annotations);
    expect(csv, hasLength(4));
    expect(csv[1][0], 'Remote Book');
    expect(csv[1][3], 'Text same-cfi-a');
    expect(csv[1][4], 'Context for same-cfi-a.');
    expect(csv[1][5], 'Personal same-cfi-a');
  });
}
