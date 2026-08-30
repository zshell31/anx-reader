import 'package:anx_reader/page/book_player/selection_persistence_session.dart';
import 'package:anx_reader/service/sync/annotation_read_model.dart';
import 'package:anx_reader/service/sync/annotation_repository.dart';

typedef CreateSelectionAnnotation = Future<SelectionAnnotationHandle> Function(
    SelectionSnapshot snapshot);
typedef SaveSelectionAnalysis = Future<AnnotationRef> Function(
    AnnotationRef ref, String analysis);
typedef SaveSelectionConversation = Future<AnnotationRef> Function(
    AnnotationRef ref, Iterable<AiThreadMessageInput> messages);

/// Optional persistence boundary carried only by selection-originated AI chat.
class SelectionAiPersistenceContext {
  final SelectionPersistenceSession session;
  final CreateSelectionAnnotation createAnnotation;
  final SaveSelectionAnalysis saveAnalysisToAnnotation;
  final SaveSelectionConversation saveConversationToAnnotation;

  const SelectionAiPersistenceContext({
    required this.session,
    required this.createAnnotation,
    required this.saveAnalysisToAnnotation,
    required this.saveConversationToAnnotation,
  });

  factory SelectionAiPersistenceContext.canonical({
    required SelectionPersistenceSession session,
    required CreateSelectionAnnotation createAnnotation,
    AnnotationRepository? repository,
  }) {
    final target = repository ?? annotationRepository;
    return SelectionAiPersistenceContext(
      session: session,
      createAnnotation: createAnnotation,
      saveAnalysisToAnnotation: target.saveAiAnalysis,
      saveConversationToAnnotation: target.saveAiThread,
    );
  }

  String get initialPrompt {
    final selected = session.snapshot.selectedText.trim();
    final context = session.snapshot.lookupContext?.trim();
    return [
      'Analyze the selected text from the book.',
      'Selected text:\n$selected',
      if (context?.isNotEmpty == true) 'Reading context:\n$context',
    ].join('\n\n');
  }

  Future<AnnotationRef> saveAnalysis(String analysis) {
    final value = analysis.trim();
    if (value.isEmpty) {
      throw ArgumentError.value(analysis, 'analysis', 'must not be empty');
    }
    return session.persist(
      create: createAnnotation,
      save: (annotation) => saveAnalysisToAnnotation(annotation.ref, value),
    );
  }

  Future<AnnotationRef> saveConversation(
      Iterable<AiThreadMessageInput> messages) {
    final values = messages.toList(growable: false);
    if (values.isEmpty) {
      throw ArgumentError.value(values, 'messages', 'must not be empty');
    }
    return session.persist(
      create: createAnnotation,
      save: (annotation) =>
          saveConversationToAnnotation(annotation.ref, values),
    );
  }
}
