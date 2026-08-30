import 'package:anx_reader/page/book_player/selection_ai_persistence_context.dart';
import 'package:anx_reader/page/book_player/selection_persistence_session.dart';
import 'package:anx_reader/service/sync/annotation_read_model.dart';
import 'package:anx_reader/service/sync/annotation_repository.dart';
import 'package:flutter_test/flutter_test.dart';

const fingerprint = '0123456789abcdef0123456789abcdef';

SelectionSnapshot snapshot() => const SelectionSnapshot(
      selectedText: 'came across',
      annotationContext: 'I came across an old friend.',
      lookupContext:
          'Yesterday was unusual. I came across an old friend. We talked.',
      chapter: 'Chapter 1',
      selector: 'epubcfi(/6/2!/4/2:1)',
    );

SelectionAnnotationHandle handle(String id) => SelectionAnnotationHandle(
      ref: AnnotationRef(bookFingerprint: fingerprint, annotationId: id),
    );

void main() {
  test('opening, receiving, and closing selection AI writes nothing', () {
    var creates = 0;
    var writes = 0;
    final context = SelectionAiPersistenceContext(
      session: SelectionPersistenceSession(snapshot()),
      createAnnotation: (_) async {
        creates++;
        return handle('created');
      },
      saveAnalysisToAnnotation: (ref, analysis) async {
        writes++;
        return ref;
      },
      saveConversationToAnnotation: (ref, messages) async {
        writes++;
        return ref;
      },
    );

    final prompt = context.initialPrompt;
    const transientResponse = 'A transient response';

    expect(prompt, contains('came across'));
    expect(prompt, contains('Yesterday was unusual'));
    expect(transientResponse, isNotEmpty);
    expect(creates, 0);
    expect(writes, 0);
    expect(context.session.annotationRef, isNull);
  });

  test('Save Analysis creates once and conversation reuses exact ref',
      () async {
    var creates = 0;
    final saved = <String>[];
    final context = SelectionAiPersistenceContext(
      session: SelectionPersistenceSession(snapshot()),
      createAnnotation: (_) async {
        creates++;
        return handle('annotation-a');
      },
      saveAnalysisToAnnotation: (ref, analysis) async {
        saved.add('analysis:${ref.annotationId}:$analysis');
        return ref;
      },
      saveConversationToAnnotation: (ref, messages) async {
        saved.add('thread:${ref.annotationId}:${messages.length}');
        return ref;
      },
    );

    final analysisRef = await context.saveAnalysis('analysis result');
    final threadRef = await context.saveConversation(const [
      AiThreadMessageInput(role: 'user', content: 'question'),
      AiThreadMessageInput(role: 'assistant', content: 'answer'),
    ]);

    expect(creates, 1);
    expect(analysisRef.annotationId, 'annotation-a');
    expect(threadRef, analysisRef);
    expect(saved, [
      'analysis:annotation-a:analysis result',
      'thread:annotation-a:2',
    ]);
  });

  test('existing annotation receives AI saves without creation', () async {
    var creates = 0;
    AnnotationRef? savedRef;
    final context = SelectionAiPersistenceContext(
      session: SelectionPersistenceSession(
        snapshot(),
        existingAnnotation: handle('existing'),
      ),
      createAnnotation: (_) async {
        creates++;
        return handle('wrong');
      },
      saveAnalysisToAnnotation: (ref, analysis) async {
        savedRef = ref;
        return ref;
      },
      saveConversationToAnnotation: (ref, messages) async => ref,
    );

    await context.saveAnalysis('analysis');

    expect(creates, 0);
    expect(savedRef?.annotationId, 'existing');
  });

  test('same-CFI selection AI contexts never reuse identity implicitly',
      () async {
    var next = 0;
    SelectionAiPersistenceContext build() => SelectionAiPersistenceContext(
          session: SelectionPersistenceSession(snapshot()),
          createAnnotation: (_) async => handle('annotation-${++next}'),
          saveAnalysisToAnnotation: (ref, analysis) async => ref,
          saveConversationToAnnotation: (ref, messages) async => ref,
        );
    final first = build();
    final second = build();

    await first.saveAnalysis('first');
    await second.saveAnalysis('second');

    expect(first.session.annotationRef, isNot(second.session.annotationRef));
    expect(next, 2);
  });
}
