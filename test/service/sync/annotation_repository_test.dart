import 'dart:convert';
import 'dart:io';

import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/models/book_note.dart';
import 'package:anx_reader/service/sync/annotation_projection_reconciler.dart';
import 'package:anx_reader/service/sync/annotation_presentation_protocol.dart';
import 'package:anx_reader/service/sync/annotation_read_model.dart';
import 'package:anx_reader/service/sync/annotation_repository.dart';
import 'package:anx_reader/service/sync/annotation_sync_coordinator.dart';
import 'package:anx_reader/service/sync/native_annotation_projection.dart';
import 'package:anx_reader/service/sync/shared_state_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const fingerprint = '0123456789abcdef0123456789abcdef';

Book testBook() => Book(
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
      createTime: DateTime.utc(2026),
      updateTime: DateTime.utc(2026),
    );

class RecordingSharedState extends SharedStateDatabase {
  RecordingSharedState({required super.path, required super.factory});

  final events = <String>[];
  bool failWrites = false;

  @override
  Future<int> putAnnotationDocument(Map<String, dynamic> input) async {
    if (failWrites) throw StateError('canonical failure');
    final revision = await super.putAnnotationDocument(input);
    events.add('canonical');
    return revision;
  }
}

class FakeNativeStore implements NativeAnnotationProjectionStore {
  FakeNativeStore(this.shared);

  final RecordingSharedState shared;
  final books = <Book>[testBook()];
  final notes = <BookNote>[];
  final events = <String>[];
  int nextId = 100;
  bool failInsert = false;
  bool failUpdate = false;
  bool failDelete = false;

  @override
  Future<void> bindSharedAnnotation(
      int nativeNoteId, String annotationId) async {
    notes.singleWhere((value) => value.id == nativeNoteId).sharedAnnotationId =
        annotationId;
  }

  @override
  Future<void> deleteProjection(int nativeNoteId) async {
    events.add('delete');
    if (failDelete) throw StateError('projection delete failure');
    notes.removeWhere((value) => value.id == nativeNoteId);
  }

  @override
  Future<List<BookNote>> enumerateLegacyUnboundNotes() async => notes
      .where((value) => value.sharedAnnotationId == null)
      .toList(growable: false);

  @override
  Future<List<Book>> findBooksByFingerprint(String value) async =>
      value == fingerprint ? books : const [];

  @override
  Future<BookNote?> findBySharedAnnotationId(String annotationId) async {
    final matches = notes
        .where((value) => value.sharedAnnotationId == annotationId)
        .toList();
    return matches.isEmpty ? null : matches.single;
  }

  @override
  Future<int> insertProjection(BookNote note) async {
    events.add('insert');
    expect(await shared.annotationDocument(fingerprint), isNotNull,
        reason: 'canonical state must exist before native insertion');
    if (failInsert) throw StateError('projection insert failure');
    note.id = nextId++;
    notes.add(note);
    return note.id!;
  }

  @override
  Future<Book?> readBook(int localBookId) async {
    final matches = books.where((value) => value.id == localBookId).toList();
    return matches.isEmpty ? null : matches.single;
  }

  @override
  Future<BookNote> readProjection(int nativeNoteId) async =>
      notes.singleWhere((value) => value.id == nativeNoteId);

  @override
  Future<void> updateProjection(BookNote note) async {
    events.add('update');
    if (failUpdate) throw StateError('projection update failure');
    final index = notes.indexWhere((value) => value.id == note.id);
    if (index < 0) throw StateError('missing native projection');
    notes[index] = note;
  }
}

void main() {
  sqfliteFfiInit();

  late Directory temp;
  late RecordingSharedState shared;
  late FakeNativeStore native;
  late AnnotationRepository repository;
  var clock = DateTime.utc(2026, 8, 28, 12, 0);

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('annotation-repository-');
    shared = RecordingSharedState(
      path: '${temp.path}/shared.db',
      factory: databaseFactoryFfi,
    );
    native = FakeNativeStore(shared);
    repository = AnnotationRepository(
      shared,
      native: native,
      now: () => clock,
      projectionDefaults: () => const NativeAnnotationDefaults(
        selectionType: 'highlight',
        color: 'default',
      ),
    );
  });

  tearDown(() async {
    await shared.close();
    await temp.delete(recursive: true);
  });

  Future<BookNote> createSelection({String? context = 'real live context'}) =>
      repository.createSelectionAnnotation(
        AnnotationCreation(
          book: testBook(),
          selectedText: 'selected words',
          epubCfi: 'epubcfi(/6/2!/4/2,/1:0,/1:14)',
          chapter: 'Chapter 1',
          context: context,
          type: 'underline',
          color: 'ff0000',
        ),
      );

  CanonicalSelectionCreation canonicalCreation(
          {String cfi = 'epubcfi(/6/2!/4/2,/1:0,/1:14)'}) =>
      CanonicalSelectionCreation(
        book: testBook(),
        selectedText: 'selected words',
        epubCfi: cfi,
        chapter: 'Chapter 1',
        context: 'real live context',
      );

  Future<SharedOutboxEntry> annotationOutbox() async =>
      (await shared.pendingOutbox())
          .singleWhere((entry) => entry.domain == annotationSyncDomain);

  test('canonical mutation is dirty and scheduler-notified before projection',
      () async {
    var notifications = 0;
    repository = AnnotationRepository(
      shared,
      native: native,
      now: () => clock,
      onCanonicalMutation: (value) {
        expect(value, fingerprint);
        shared.events.add('scheduled');
        notifications++;
      },
      projectionDefaults: () => const NativeAnnotationDefaults(
        selectionType: 'highlight',
        color: 'default',
      ),
    );

    await createSelection();

    expect(notifications, 1);
    expect(shared.events, ['canonical', 'scheduled']);
    expect((await annotationOutbox()).documentId, fingerprint);
    expect(native.events, ['insert']);
  });

  Map<String, dynamic> annotationOf(
          Map<String, dynamic> document, String annotationId) =>
      (document['annotations'] as List)
          .cast<Map<String, dynamic>>()
          .singleWhere((value) => value['id'] == annotationId);

  test('EPUB selection commits canonical context and dirty ID before BookNote',
      () async {
    final note = await createSelection();
    final id = note.sharedAnnotationId!;
    final document = (await shared.annotationDocument(fingerprint))!;
    final annotation = annotationOf(document, id);

    expect(id, isNotEmpty);
    expect(note.id, 100);
    expect(note.sharedAnnotationId, annotation['id']);
    expect(annotation['motivation'], 'selection');
    expect(annotation['target']['context'], 'real live context');
    expect(annotation['target']['selectedText'], 'selected words');
    expect(annotation['target']['selectors'], [
      {
        'type': 'epub-cfi',
        'cfi': 'epubcfi(/6/2!/4/2,/1:0,/1:14)',
      }
    ]);
    expect(document['book'], {
      'fingerprintAlgorithm': 'md5',
      'fingerprint': fingerprint,
      'title': 'Book',
      'author': 'Author',
    });
    final presentation = await shared.annotationPresentation(id);
    expect(presentation?.style, AnnotationPresentationStyle.underline);
    expect(presentation?.color, 'ff0000');
    expect(shared.events, ['canonical']);
    expect(native.events, ['insert']);
    final outbox = await annotationOutbox();
    expect(outbox.documentId, fingerprint);
    expect(outbox.localRevision, 1);
  });

  test('selection without useful sentence context omits canonical context',
      () async {
    final note = await createSelection(context: null);
    final document = (await shared.annotationDocument(fingerprint))!;
    final annotation = annotationOf(document, note.sharedAnnotationId!);

    expect(annotation['target'], isNot(contains('context')));
  });

  group('canonical identity mutation API', () {
    test('create returns AnnotationRef and same-CFI creates separate UUIDs',
        () async {
      final first = await repository.createAnnotation(canonicalCreation());
      final second = await repository.createAnnotation(canonicalCreation());

      expect(first.ref.bookFingerprint, fingerprint);
      expect(first.ref.annotationId, isNot(second.ref.annotationId));
      expect(first.compatibilityProjection?.sharedAnnotationId,
          first.ref.annotationId);
      final document = (await shared.annotationDocument(fingerprint))!;
      expect(document['annotations'], hasLength(2));
    });

    test('first translation is one coherent canonical revision', () async {
      final result = await repository.createAnnotationWithTranslation(
          canonicalCreation(), 'перевод');
      final document = (await shared.annotationDocument(fingerprint))!;
      final annotation = annotationOf(document, result.ref.annotationId);

      expect((await annotationOutbox()).localRevision, 1);
      expect(document['annotations'], hasLength(1));
      expect(annotation['enrichments'], hasLength(1));
      expect(annotation['enrichments'].single['kind'], 'translation');
      expect(annotation['enrichments'].single['content'], 'перевод');
    });

    test('material, AI thread, and personal-note saves preserve each other',
        () async {
      final created = await repository.createAnnotation(canonicalCreation());
      final ref = created.ref;
      await repository.saveDictionaryResult(ref, 'definition');
      await repository.saveAiAnalysis(ref, 'analysis');
      await repository.saveTranslation(ref, 'translation');
      await repository.saveAiThread(ref, const [
        AiThreadMessageInput(role: 'user', content: 'why?'),
        AiThreadMessageInput(role: 'assistant', content: 'because'),
      ]);
      await repository.setPersonalNote(ref, 'remember');
      await repository.setPersonalNote(ref, 'edited');

      final annotation = annotationOf(
          (await shared.annotationDocument(fingerprint))!, ref.annotationId);
      final enrichments =
          (annotation['enrichments'] as List).cast<Map<String, dynamic>>();
      expect(
          enrichments.map((value) => value['kind']),
          containsAll([
            'dictionary',
            'ai-analysis',
            'translation',
            'ai-thread',
            'personal-note',
          ]));
      final personal =
          enrichments.singleWhere((value) => value['kind'] == 'personal-note');
      expect(personal['content'], 'edited');
      final thread =
          enrichments.singleWhere((value) => value['kind'] == 'ai-thread');
      expect(thread['messages'], hasLength(2));
    });

    test('unknown remote fields survive canonical enrichment mutation',
        () async {
      final created = await repository.createAnnotation(canonicalCreation());
      var document = (await shared.annotationDocument(fingerprint))!;
      final annotation = annotationOf(document, created.ref.annotationId);
      annotation['futureField'] = {
        'nested': [true]
      };
      (annotation['target']['selectors'] as List).add({
        'type': 'future-selector',
        'future': {'kept': true},
      });
      await shared.putAnnotationDocument(document);

      await repository.saveDictionaryResult(created.ref, 'definition');
      document = (await shared.annotationDocument(fingerprint))!;
      final updated = annotationOf(document, created.ref.annotationId);
      expect(updated['futureField'], {
        'nested': [true]
      });
      expect(updated['target']['selectors'], hasLength(2));
    });

    test('presentation mutation leaves canonical bytes and timestamps intact',
        () async {
      final created = await repository.createAnnotation(canonicalCreation());
      final before = await shared.canonicalDocument('annotations', fingerprint);
      final annotationBefore = annotationOf(
          (await shared.annotationDocument(fingerprint))!,
          created.ref.annotationId)['updatedAt'];

      final result = await repository.updatePresentation(
          created.ref, 'underline', 'ffff00');

      expect(result.ref, created.ref);
      expect(
          await shared.canonicalDocument('annotations', fingerprint), before);
      expect(
          annotationOf((await shared.annotationDocument(fingerprint))!,
              created.ref.annotationId)['updatedAt'],
          annotationBefore);
      expect(
          (await shared.annotationPresentation(created.ref.annotationId))
              ?.style,
          AnnotationPresentationStyle.underline);
    });

    test('canonical success is retained and reported when refresh fails',
        () async {
      native.failInsert = true;
      final result = await repository.createAnnotationWithTranslation(
          canonicalCreation(), 'durable');

      expect(result.rendererRefreshSucceeded, isFalse);
      expect(result.rendererRefreshFailure, isNotNull);
      final annotation = annotationOf(
          (await shared.annotationDocument(fingerprint))!,
          result.ref.annotationId);
      expect(annotation['enrichments'].single['content'], 'durable');
      expect(shared.events.first, 'canonical');
      expect(native.events, ['insert']);
    });

    test('tombstone mutates by AnnotationRef and remains semantic', () async {
      final created = await repository.createAnnotation(canonicalCreation());
      final result = await repository.tombstoneAnnotation(created.ref);
      final annotation = annotationOf(
          (await shared.annotationDocument(fingerprint))!,
          created.ref.annotationId);

      expect(result.ref, created.ref);
      expect(annotation['deletedAt'], isNotNull);
      expect(native.notes, isEmpty);
    });
  });

  test('semantic first save can create without persisting default presentation',
      () async {
    final note = await repository.createSelectionAnnotation(
      AnnotationCreation(
        book: testBook(),
        selectedText: 'selected words',
        epubCfi: 'epubcfi(/6/2!/4/2,/1:0,/1:14)',
        chapter: 'Chapter 1',
        context: 'real live context',
        type: 'highlight',
        color: 'default',
        persistPresentation: false,
      ),
    );

    expect(
        await shared.annotationPresentation(note.sharedAnnotationId!), isNull);
    expect((await annotationOutbox()).localRevision, 1);
  });

  test('translation is written only by explicit save and retains identity',
      () async {
    final note = await repository.createSelectionAnnotation(
      AnnotationCreation(
        book: testBook(),
        selectedText: 'selected words',
        epubCfi: 'epubcfi(/6/2!/4/2,/1:0,/1:14)',
        chapter: 'Chapter 1',
        context: 'real live context',
        type: 'highlight',
        color: 'default',
        persistPresentation: false,
      ),
    );
    final ref = await repository.annotationRefForNativeId(note.id!);

    clock = clock.add(const Duration(minutes: 1));
    final updated =
        await repository.saveTranslationForNativeId(note.id!, 'перевод');
    final annotation = annotationOf(
        (await shared.annotationDocument(fingerprint))!, ref.annotationId);

    expect(updated.sharedAnnotationId, ref.annotationId);
    expect(annotation['enrichments'], hasLength(1));
    expect(annotation['enrichments'].single['kind'], 'translation');
    expect(annotation['enrichments'].single['content'], 'перевод');
    expect(await shared.annotationPresentation(ref.annotationId), isNull);
  });

  test('personal note create/edit/clear tombstones and preserves unknown data',
      () async {
    final note = await createSelection();
    final id = note.sharedAnnotationId!;
    var document = (await shared.annotationDocument(fingerprint))!;
    final annotation = annotationOf(document, id);
    annotation['futureField'] = {'kept': true};
    annotation['target']['selectors'].add({
      'type': 'future-selector',
      'payload': {'kept': true},
    });
    annotation['enrichments'].addAll([
      {
        'id': 'translation-1',
        'kind': 'translation',
        'content': 'translation',
        'createdAt': '2026-08-28T11:00:00.000Z',
        'updatedAt': '2026-08-28T11:00:00.000Z',
      },
      {
        'id': 'personal-note-conflict',
        'kind': 'personal-note',
        'content': 'older untouched note',
        'createdAt': '2026-08-28T10:00:00.000Z',
        'updatedAt': '2026-08-28T10:00:00.000Z',
      },
      {
        'id': 'ai-thread-1',
        'kind': 'ai-thread',
        'createdAt': '2026-08-28T11:00:00.000Z',
        'updatedAt': '2026-08-28T11:00:00.000Z',
        'contextSnapshot': {
          'selectedText': 'selected words',
          'enrichmentIds': ['translation-1'],
        },
        'messages': [
          {
            'id': 'message-1',
            'role': 'assistant',
            'sequence': 0,
            'content': 'analysis',
            'createdAt': '2026-08-28T11:00:00.000Z',
            'updatedAt': '2026-08-28T11:00:00.000Z',
          }
        ],
      },
    ]);
    await shared.putAnnotationDocument(document);

    clock = clock.add(const Duration(minutes: 1));
    await repository.setPersonalNoteForNativeId(note.id!, 'first');
    clock = clock.add(const Duration(minutes: 1));
    await repository.setPersonalNoteForNativeId(note.id!, 'edited');
    expect(native.notes.single.readerNote, 'edited');

    clock = clock.add(const Duration(minutes: 1));
    await repository.setPersonalNoteForNativeId(note.id!, '');
    document = (await shared.annotationDocument(fingerprint))!;
    final result = annotationOf(document, id);
    final personal = (result['enrichments'] as List)
        .cast<Map<String, dynamic>>()
        .singleWhere((value) => value['id'] == 'personal-note:$id');
    expect(personal['id'], 'personal-note:$id');
    expect(personal['content'], '');
    expect(personal['deletedAt'], personal['updatedAt']);
    expect(native.notes.single.readerNote, isNull);
    expect(result['futureField'], {'kept': true});
    expect(result['target']['context'], 'real live context');
    expect(result['target']['selectors'], hasLength(2));
    expect(
        (result['enrichments'] as List).map((value) => value['id']),
        containsAll([
          'translation-1',
          'personal-note-conflict',
          'ai-thread-1',
          'personal-note:$id',
        ]));
    final conflict = (result['enrichments'] as List)
        .cast<Map<String, dynamic>>()
        .singleWhere((value) => value['id'] == 'personal-note-conflict');
    expect(conflict['content'], 'older untouched note');
    expect(conflict.containsKey('deletedAt'), isFalse);
    expect((await annotationOutbox()).localRevision, 5);
  });

  test('presentation-only changes preserve canonical bytes and revision',
      () async {
    var presentationNotifications = 0;
    repository = AnnotationRepository(
      shared,
      native: native,
      now: () => clock,
      onPresentationMutation: () => presentationNotifications++,
      projectionDefaults: () => const NativeAnnotationDefaults(
        selectionType: 'highlight',
        color: 'default',
      ),
    );
    final note = await createSelection();
    final before = await shared.canonicalDocument('annotations', fingerprint);
    final revision = (await annotationOutbox()).localRevision;

    final recolored = await repository.updatePresentationForNativeId(
        note.id!, 'underline', '00ff00');
    expect(await shared.canonicalDocument('annotations', fingerprint),
        orderedEquals(before!));
    expect((await annotationOutbox()).localRevision, revision);
    expect(recolored.type, 'underline');
    expect(recolored.color, '00ff00');
    var sidecar = await shared.annotationPresentation(note.sharedAnnotationId!);
    expect(sidecar?.style, AnnotationPresentationStyle.underline);
    expect(sidecar?.color, '00ff00');

    final retyped = await repository.updatePresentationForNativeId(
        note.id!, 'highlight', '00ff00');
    final after = await shared.canonicalDocument('annotations', fingerprint);

    expect(after, orderedEquals(before));
    expect((await annotationOutbox()).localRevision, revision);
    expect(retyped.type, 'highlight');
    expect(retyped.updateTime, note.updateTime);
    sidecar = await shared.annotationPresentation(note.sharedAnnotationId!);
    expect(sidecar?.style, AnnotationPresentationStyle.highlight);
    expect(sidecar?.color, '00ff00');
    expect(presentationNotifications, 3);
    final presentationOutbox = (await shared.pendingOutbox())
        .singleWhere((entry) => entry.domain == anxPresentationSyncDomain);
    expect(presentationOutbox.documentId, anxPresentationDocumentId);
    expect(presentationOutbox.localRevision, 3);
  });

  test('bookmark creation and deletion use canonical identity', () async {
    final result = await repository.createBookmark(
      BookmarkCreation(
        book: testBook(),
        content: 'Bookmark location',
        epubCfi: 'epubcfi(/6/4!/4/2)',
        chapter: 'Chapter 2',
        percentage: 0.42,
      ),
    );
    final document = (await shared.annotationDocument(fingerprint))!;
    final annotation = annotationOf(document, result.ref.annotationId);
    expect(annotation['motivation'], 'bookmark');
    expect(jsonEncode(annotation), isNot(contains('0.42')));

    clock = clock.add(const Duration(minutes: 1));
    await repository.tombstoneAnnotation(result.ref);
    final deleted = annotationOf(
        (await shared.annotationDocument(fingerprint))!,
        result.ref.annotationId);
    expect(deleted['deletedAt'], isNotNull);
    expect(
        await shared.annotationPresentation(result.ref.annotationId), isNull);
    expect(native.notes, isEmpty);
  });

  test('annotation delete persists tombstone before native removal', () async {
    final note = await createSelection();
    clock = clock.add(const Duration(minutes: 1));
    await repository.tombstoneAnnotationForBookNote(note);
    final annotation = annotationOf(
        (await shared.annotationDocument(fingerprint))!,
        note.sharedAnnotationId!);
    expect(annotation['deletedAt'], annotation['updatedAt']);
    expect(shared.events, ['canonical', 'canonical']);
    expect(native.events, ['insert', 'delete']);
    expect(native.notes, isEmpty);
  });

  test('bulk delete tombstones every canonical annotation', () async {
    final first = await createSelection();
    clock = clock.add(const Duration(minutes: 1));
    final second = await createSelection(context: 'second context');
    clock = clock.add(const Duration(minutes: 1));

    await repository.tombstoneAnnotations([first, second]);

    final annotations =
        ((await shared.annotationDocument(fingerprint))!['annotations'] as List)
            .cast<Map<String, dynamic>>();
    expect(annotations, hasLength(2));
    expect(
        annotations.every((value) => value.containsKey('deletedAt')), isTrue);
    expect(native.notes, isEmpty);
    expect((await annotationOutbox()).localRevision, 4);
  });

  test('canonical failure prevents native write', () async {
    shared.failWrites = true;
    await expectLater(createSelection(), throwsStateError);
    expect(native.events, isEmpty);
    expect(native.notes, isEmpty);
    expect(await shared.annotationDocument(fingerprint), isNull);
  });

  test('projection failure leaves dirty canonical state for reconciliation',
      () async {
    native.failInsert = true;
    await expectLater(
        createSelection(), throwsA(isA<AnnotationProjectionException>()));
    final document = (await shared.annotationDocument(fingerprint))!;
    final id = document['annotations'].single['id'] as String;
    expect(native.notes, isEmpty);
    expect((await annotationOutbox()).localRevision, 1);

    native.failInsert = false;
    final result = await AnnotationProjectionReconciler(
      shared,
      native: native,
      defaults: () => const NativeAnnotationDefaults(
        selectionType: 'highlight',
        color: 'default',
      ),
    ).reconcileAnnotation(fingerprint, id);
    expect(result.inserted, 1);
    expect(native.notes.single.sharedAnnotationId, id);
  });

  test('delete projection failure keeps recoverable canonical tombstone',
      () async {
    final note = await createSelection();
    native.failDelete = true;
    clock = clock.add(const Duration(minutes: 1));
    await expectLater(repository.tombstoneAnnotationForBookNote(note),
        throwsA(isA<AnnotationProjectionException>()));
    final annotation = annotationOf(
        (await shared.annotationDocument(fingerprint))!,
        note.sharedAnnotationId!);
    expect(annotation['deletedAt'], isNotNull);
    expect(native.notes, hasLength(1));

    native.failDelete = false;
    await AnnotationProjectionReconciler(shared, native: native).run();
    expect(native.notes, isEmpty);
  });

  test('personal-note projection failure keeps canonical edit recoverable',
      () async {
    final note = await createSelection();
    native.failUpdate = true;
    clock = clock.add(const Duration(minutes: 1));
    await expectLater(
        repository.setPersonalNoteForNativeId(note.id!, 'durable idea'),
        throwsA(isA<AnnotationProjectionException>()));
    final annotation = annotationOf(
        (await shared.annotationDocument(fingerprint))!,
        note.sharedAnnotationId!);
    expect(annotation['enrichments'].single['content'], 'durable idea');
    expect(native.notes.single.readerNote, isNull);

    native.failUpdate = false;
    await AnnotationProjectionReconciler(
      shared,
      native: native,
      defaults: () => const NativeAnnotationDefaults(
        selectionType: 'highlight',
        color: 'default',
      ),
    ).run();
    expect(native.notes.single.readerNote, 'durable idea');
  });

  test('excerpt edits fail before canonical or native state changes', () async {
    final note = await createSelection();
    final before = await shared.canonicalDocument('annotations', fingerprint);
    final revision = (await annotationOutbox()).localRevision;
    final proposed = BookNote(
      id: note.id,
      bookId: note.bookId,
      content: 'rewritten excerpt',
      cfi: note.cfi,
      chapter: note.chapter,
      type: note.type,
      color: note.color,
      readerNote: note.readerNote,
      sharedAnnotationId: note.sharedAnnotationId,
      createTime: note.createTime,
      updateTime: note.updateTime,
    );
    await expectLater(repository.updateNativeAnnotation(proposed),
        throwsA(isA<AnnotationExcerptEditUnsupported>()));
    expect(await shared.canonicalDocument('annotations', fingerprint),
        orderedEquals(before!));
    expect((await annotationOutbox()).localRevision, revision);
    expect(native.notes.single.content, 'selected words');
  });
}
