import 'dart:io';

import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/service/sync/annotation_protocol.dart';
import 'package:anx_reader/service/sync/annotation_read_model.dart';
import 'package:anx_reader/service/sync/annotation_repository.dart';
import 'package:anx_reader/service/sync/shared_state_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const fingerprint = '0123456789abcdef0123456789abcdef';
const cfi = 'epubcfi(/6/4!/4/2:3)';
final instant = DateTime.parse('2026-01-02T03:04:05.000Z');

Book localBook() => Book(
      id: 7,
      title: 'Book',
      coverPath: '',
      filePath: 'book.epub',
      lastReadPosition: '',
      readingPercentage: 0,
      author: 'Author',
      isDeleted: false,
      rating: 0,
      md5: fingerprint,
      createTime: instant,
      updateTime: instant,
    );

CanonicalSelectionCreation creation({String? context = 'A sentence.'}) =>
    CanonicalSelectionCreation(
      book: localBook(),
      selectedText: 'selected text',
      epubCfi: cfi,
      chapter: 'Chapter 1',
      context: context,
    );

Map<String, dynamic> annotationOf(Map<String, dynamic> document, String id) =>
    (document['annotations'] as List)
        .cast<Map<String, dynamic>>()
        .singleWhere((annotation) => annotation['id'] == id);

void main() {
  sqfliteFfiInit();

  late Directory directory;
  late SharedStateDatabase shared;
  late AnnotationRepository repository;
  late List<String> semanticNotifications;
  late int presentationNotifications;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('anx_repository_test_');
    shared = SharedStateDatabase(
      path: p.join(directory.path, 'shared_state.db'),
      factory: databaseFactoryFfi,
      now: () => instant,
    );
    semanticNotifications = [];
    presentationNotifications = 0;
    repository = AnnotationRepository(
      shared,
      now: () => instant,
      onCanonicalMutation: semanticNotifications.add,
      onPresentationMutation: () => presentationNotifications++,
    );
  });

  tearDown(() async {
    await shared.close();
    await directory.delete(recursive: true);
  });

  test('creation commits canonical state before notifying listeners', () async {
    Map<String, dynamic>? visibleAtNotification;
    repository = AnnotationRepository(
      shared,
      now: () => instant,
      onCanonicalMutation: (id) {
        expect(id, fingerprint);
        semanticNotifications.add(id);
      },
    );

    final ref = await repository.createAnnotation(creation());
    visibleAtNotification = await shared.annotationDocument(fingerprint);

    expect(ref.bookFingerprint, fingerprint);
    expect(ref.annotationId, isNotEmpty);
    expect(semanticNotifications, [fingerprint]);
    final annotation = annotationOf(visibleAtNotification!, ref.annotationId);
    expect(annotation['target']['context'], 'A sentence.');
    expect((await shared.pendingOutbox()).single.documentId, fingerprint);
  });

  test('missing context is omitted and same CFI never implies reuse', () async {
    final first = await repository.createAnnotation(creation(context: '  '));
    final second = await repository.createAnnotation(creation(context: null));
    final document = (await shared.annotationDocument(fingerprint))!;

    expect(first, isNot(second));
    expect(first.annotationId, isNot(second.annotationId));
    expect(document['annotations'], hasLength(2));
    for (final annotation in (document['annotations'] as List).cast<Map>()) {
      expect(annotation['target'], isNot(contains('context')));
      expect(annotation['target']['selectors'].single['cfi'], cfi);
    }
  });

  test('first-save translation and personal note are canonical enrichments',
      () async {
    final translation = await repository.createAnnotationWithTranslation(
        creation(), ' translated ');
    final personal = await repository.createAnnotationWithPersonalNote(
        creation(), ' remember ');
    final document = (await shared.annotationDocument(fingerprint))!;

    expect(
        annotationOf(document, translation.annotationId)['enrichments'],
        contains(predicate<Map>((value) =>
            value['kind'] == 'translation' &&
            value['content'] == 'translated')));
    expect(
        annotationOf(document, personal.annotationId)['enrichments'],
        contains(predicate<Map>((value) =>
            value['kind'] == 'personal-note' &&
            value['content'] == 'remember')));
  });

  test('canonical enrichment APIs retain AnnotationRef identity', () async {
    final ref = await repository.createAnnotation(creation());

    expect(await repository.saveDictionaryResult(ref, 'definition'), ref);
    expect(await repository.saveAiAnalysis(ref, 'analysis'), ref);
    expect(await repository.saveTranslation(ref, 'translation'), ref);
    expect(
        await repository.saveAiThread(
          ref,
          const [
            AiThreadMessageInput(role: 'user', content: 'question'),
            AiThreadMessageInput(role: 'assistant', content: 'answer'),
          ],
          enrichmentIds: const ['translation:known'],
        ),
        ref);

    final annotation = annotationOf(
        (await shared.annotationDocument(fingerprint))!, ref.annotationId);
    expect((annotation['enrichments'] as List).map((value) => value['kind']),
        containsAll(['dictionary', 'ai-analysis', 'translation', 'ai-thread']));
    final thread = (annotation['enrichments'] as List)
        .cast<Map<String, dynamic>>()
        .singleWhere((value) => value['kind'] == 'ai-thread');
    expect(thread['messages'], hasLength(2));
    expect(thread['contextSnapshot']['enrichmentIds'], ['translation:known']);
  });

  test('personal note edit and clear preserve unknown canonical data',
      () async {
    final ref = await repository.createAnnotation(creation());
    var document = (await shared.annotationDocument(fingerprint))!;
    annotationOf(document, ref.annotationId)['futureField'] = {'keep': true};
    await shared.putAnnotationDocument(document);

    await repository.setPersonalNote(ref, 'first');
    await repository.setPersonalNote(ref, 'edited');
    await repository.setPersonalNote(ref, '');

    document = (await shared.annotationDocument(fingerprint))!;
    final annotation = annotationOf(document, ref.annotationId);
    expect(annotation['futureField'], {'keep': true});
    final personal = (annotation['enrichments'] as List)
        .cast<Map<String, dynamic>>()
        .where((value) => value['kind'] == 'personal-note')
        .toList();
    expect(personal, hasLength(1));
    expect(personal.single['deletedAt'], isNotNull);
  });

  test('presentation mutation changes no semantic bytes or revision', () async {
    final ref = await repository.createAnnotation(creation());
    final beforeBytes =
        await shared.canonicalDocument('annotations', fingerprint);
    final beforeSnapshot =
        await shared.documentSnapshot('annotations', fingerprint);
    final beforeUpdatedAt = annotationOf(
        (await shared.annotationDocument(fingerprint))!,
        ref.annotationId)['updatedAt'];

    expect(
        await repository.updatePresentation(ref, 'underline', '00ff00'), ref);

    expect(await shared.canonicalDocument('annotations', fingerprint),
        orderedEquals(beforeBytes!));
    final afterSnapshot =
        await shared.documentSnapshot('annotations', fingerprint);
    expect(afterSnapshot!.localRevision, beforeSnapshot!.localRevision);
    expect(
        annotationOf((await shared.annotationDocument(fingerprint))!,
            ref.annotationId)['updatedAt'],
        beforeUpdatedAt);
    expect((await shared.annotationPresentation(ref.annotationId))?.color,
        '00ff00');
    expect(presentationNotifications, 1);
  });

  test('bookmark motivation is canonical and presentation is rejected',
      () async {
    final ref = await repository.createBookmark(BookmarkCreation(
      book: localBook(),
      content: 'bookmark',
      epubCfi: cfi,
      chapter: 'Chapter 1',
      percentage: 0.5,
    ));
    final annotation = annotationOf(
        (await shared.annotationDocument(fingerprint))!, ref.annotationId);
    expect(annotation['motivation'], 'bookmark');
    await expectLater(repository.updatePresentation(ref, 'highlight', 'red'),
        throwsA(isA<ArgumentError>()));
  });

  test('deletion creates sticky tombstone and resets presentation', () async {
    final ref = await repository.createAnnotation(creation());
    await repository.updatePresentation(ref, 'highlight', 'red');

    expect(await repository.tombstoneAnnotation(ref), ref);
    expect(await repository.tombstoneAnnotation(ref), ref);

    final annotation = annotationOf(
        (await shared.annotationDocument(fingerprint))!, ref.annotationId);
    expect(annotation['deletedAt'], isNotNull);
    expect(await shared.annotationPresentation(ref.annotationId), isNull);
    expect(await shared.hasAnnotationPresentationOperation(ref.annotationId),
        isTrue,
        reason: 'the synchronized reset must remain sticky');
    await expectLater(repository.setPersonalNote(ref, 'resurrect'),
        throwsA(isA<StateError>()));
  });

  test('unsupported and unbound canonical annotations need no numeric ID',
      () async {
    final document = <String, dynamic>{
      'schemaVersion': 2,
      'book': {
        'fingerprintAlgorithm': 'md5',
        'fingerprint': fingerprint,
      },
      'annotations': [
        {
          'id': 'unsupported-id',
          'motivation': 'selection',
          'createdAt': canonicalWireTimestamp(instant),
          'updatedAt': canonicalWireTimestamp(instant),
          'target': {
            'selectedText': 'remote',
            'selectors': [
              {
                'type': 'future-selector',
                'value': {'unknown': true}
              }
            ],
          },
          'enrichments': <Object>[],
        }
      ],
    };
    await shared.putAnnotationDocument(document);
    final ref = AnnotationRef(
        bookFingerprint: fingerprint, annotationId: 'unsupported-id');

    expect(await repository.saveTranslation(ref, 'works'), ref);
    final updated = annotationOf(
        (await shared.annotationDocument(fingerprint))!, ref.annotationId);
    expect(updated['target']['selectors'].single['value'], {'unknown': true});
    expect(updated['enrichments'].single['kind'], 'translation');
  });

  test('repository source has no legacy table, model, DAO, or numeric identity',
      () {
    final source =
        File('lib/service/sync/annotation_repository.dart').readAsStringSync();
    expect(source, isNot(contains('tb_notes')));
    expect(source, isNot(contains('BookNote')));
    expect(source, isNot(contains('nativeNoteId')));
    expect(source, isNot(contains('sharedAnnotationId')));
    expect(source, isNot(contains('Projection')));
  });
}
