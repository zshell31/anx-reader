import 'dart:async';

import 'package:anx_reader/page/book_player/selection_persistence_session.dart';
import 'package:anx_reader/service/sync/annotation_read_model.dart';
import 'package:flutter_test/flutter_test.dart';

const fingerprint = '0123456789abcdef0123456789abcdef';

SelectionSnapshot snapshot({String selector = 'epubcfi(/6/2!/4/2:1)'}) =>
    SelectionSnapshot(
      selectedText: 'take something for granted',
      annotationContext: 'Do not take something for granted.',
      lookupContext: 'Context before. Do not take something for granted.',
      chapter: 'Chapter 1',
      selector: selector,
    );

SelectionAnnotationHandle handle(String id, int nativeId) =>
    SelectionAnnotationHandle(
      ref: AnnotationRef(bookFingerprint: fingerprint, annotationId: id),
    );

void main() {
  test('opening actions and transient lookup lifecycle write nothing', () {
    var writes = 0;
    final session = SelectionPersistenceSession(snapshot());

    session.translation = 'принимать как должное';
    session.dictionary = 'an explanation';
    session.aiAnalysis = 'an analysis';
    session.translation = null;

    expect(writes, 0);
    expect(session.annotationRef, isNull);
    expect(session.hasPersistedAnnotation, isFalse);
  });

  test('transient delete eligibility never creates an annotation', () {
    var writes = 0;
    final session = SelectionPersistenceSession(snapshot());

    final canDelete = session.hasPersistedAnnotation;

    expect(canDelete, isFalse);
    expect(session.annotationRef, isNull);
    expect(writes, 0);
  });

  test('provider failure and closing a result write nothing', () async {
    var writes = 0;
    final session = SelectionPersistenceSession(snapshot());

    try {
      throw StateError('provider failed');
    } catch (_) {
      session.dictionary = null;
    }

    expect(writes, 0);
    expect(session.annotationRef, isNull);
  });

  test('opening personal-note state writes nothing', () {
    var writes = 0;
    final session = SelectionPersistenceSession(snapshot());
    var editorOpen = true;

    expect(editorOpen, isTrue);
    expect(writes, 0);
    expect(session.annotationRef, isNull);
  });

  test('first explicit save creates once and later actions reuse the ref',
      () async {
    var creates = 0;
    var saves = 0;
    final session = SelectionPersistenceSession(snapshot());

    Future<SelectionAnnotationHandle> create(SelectionSnapshot value) async {
      creates++;
      expect(value.annotationContext, 'Do not take something for granted.');
      return handle('annotation-a', 7);
    }

    await session.persist(
      create: create,
      save: (annotation) async {
        saves++;
        expect(annotation.ref.annotationId, 'annotation-a');
      },
    );
    await session.persist(create: create, save: (_) async => saves++);

    expect(creates, 1);
    expect(saves, 2);
    expect(session.annotationRef?.annotationId, 'annotation-a');
    expect(session.hasPersistedAnnotation, isTrue);
  });

  test('concurrent persistence creates only one annotation', () async {
    var creates = 0;
    final completer = Completer<SelectionAnnotationHandle>();
    final session = SelectionPersistenceSession(snapshot());

    Future<SelectionAnnotationHandle> create(_) {
      creates++;
      return completer.future;
    }

    final first = session.ensureAnnotation(create);
    final second = session.ensureAnnotation(create);
    completer.complete(handle('annotation-a', 7));

    expect((await first).ref, (await second).ref);
    expect(creates, 1);
  });

  test('same-CFI session does not implicitly reuse another annotation',
      () async {
    var next = 0;
    final first = SelectionPersistenceSession(snapshot());
    final second = SelectionPersistenceSession(snapshot());

    Future<SelectionAnnotationHandle> create(_) async {
      next++;
      return handle('annotation-$next', next);
    }

    await first.ensureAnnotation(create);
    await second.ensureAnnotation(create);

    expect(first.annotationRef, isNot(second.annotationRef));
    expect(next, 2);
  });

  test('existing AnnotationRef receives saves without creation', () async {
    var creates = 0;
    AnnotationRef? savedTo;
    final existing = handle('existing', 11);
    final session =
        SelectionPersistenceSession(snapshot(), existingAnnotation: existing);

    await session.persist(
      create: (_) async {
        creates++;
        return handle('wrong', 12);
      },
      save: (annotation) async => savedTo = annotation.ref,
    );

    expect(creates, 0);
    expect(savedTo, existing.ref);
  });

  test('lookupContext is transient and creation sees annotationContext only',
      () async {
    final session = SelectionPersistenceSession(snapshot());
    String? providerContext;
    String? persistedContext;

    providerContext = session.snapshot.lookupContext;
    await session.ensureAnnotation((value) async {
      persistedContext = value.annotationContext;
      return handle('annotation-a', 7);
    });

    expect(providerContext, contains('Context before'));
    expect(persistedContext, 'Do not take something for granted.');
    expect(persistedContext, isNot(providerContext));
  });

  test('explicit presentation action is persistent intent', () async {
    var creates = 0;
    var presentationWrites = 0;
    final session = SelectionPersistenceSession(snapshot());

    await session.persist(
      create: (_) async {
        creates++;
        return handle('annotation-a', 7);
      },
      save: (_) async => presentationWrites++,
    );

    expect(creates, 1);
    expect(presentationWrites, 1);
  });
}
