import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/page/book_player/annotation_editor/annotation_editor_draft.dart';
import 'package:anx_reader/service/annotation_enrichment/annotation_ai_service.dart';
import 'package:anx_reader/service/annotation_enrichment/google_annotation_translate.dart';
import 'package:anx_reader/service/annotation_enrichment/ldoce_annotation_dictionary.dart';
import 'package:anx_reader/service/sync/annotation_read_model.dart';
import 'package:anx_reader/service/sync/annotation_repository.dart';
import 'package:flutter/foundation.dart';

typedef SaveAnnotationEditor = Future<AnnotationRef> Function(
  AnnotationEditorSaveInput input,
);
typedef DeleteAnnotationEditor = Future<AnnotationRef> Function(
  AnnotationRef ref,
);

class AnnotationEditorController extends ChangeNotifier {
  final AnnotationEditorDraft draft;
  final Book book;
  final GoogleAnnotationTranslateService google;
  final LdoceAnnotationDictionaryService ldoce;
  final AnnotationAiService ai;
  final SaveAnnotationEditor saveDraft;
  final DeleteAnnotationEditor deleteAnnotation;
  final String Function() targetLanguageCode;
  final String Function() targetLanguageName;

  bool saving = false;
  String? saveError;
  bool chatLoading = false;
  String? chatError;
  int _chatGeneration = 0;
  bool _disposed = false;

  AnnotationEditorController({
    required this.draft,
    required this.book,
    GoogleAnnotationTranslateService? google,
    LdoceAnnotationDictionaryService? ldoce,
    AnnotationAiService? ai,
    SaveAnnotationEditor? saveDraft,
    DeleteAnnotationEditor? deleteAnnotation,
    String Function()? targetLanguageCode,
    String Function()? targetLanguageName,
  })  : google = google ?? GoogleAnnotationTranslateService(),
        ldoce = ldoce ?? LdoceAnnotationDictionaryService(),
        ai = ai ?? AnnotationAiService(),
        saveDraft = saveDraft ?? annotationRepository.saveAnnotationEditorDraft,
        deleteAnnotation =
            deleteAnnotation ?? annotationRepository.tombstoneAnnotation,
        targetLanguageCode =
            targetLanguageCode ?? (() => Prefs().translateTo.code),
        targetLanguageName =
            targetLanguageName ?? (() => Prefs().translateTo.nativeName);

  Future<void> runProvider(AnnotationEditorProvider provider) async {
    final request = draft.startProvider(provider);
    notifyListeners();
    try {
      final AnnotationEditorSourceResult result;
      switch (provider) {
        case AnnotationEditorProvider.googleTranslate:
          final translation = await google.translate(
            draft.selection.selectedText,
            targetLanguage: targetLanguageCode(),
          );
          result = AnnotationEditorSourceResult(
            providerId: provider.providerId,
            providerName: provider.providerName,
            kind: provider.kind,
            translation: translation.text,
            metadata: {
              if (translation.detectedLanguage != null)
                'detectedLanguage': translation.detectedLanguage!,
            },
          );
          break;
        case AnnotationEditorProvider.ldoce:
          final article = await ldoce.lookup(draft.selection.selectedText);
          result = AnnotationEditorSourceResult(
            providerId: provider.providerId,
            providerName: provider.providerName,
            kind: provider.kind,
            translation: article.shortDefinition,
            markdown: ldoceArticleToMarkdown(article),
            metadata: {'url': article.url},
          );
          break;
        case AnnotationEditorProvider.ai:
          result = await ai.analyze(
            selectedText: draft.selection.selectedText,
            context: draft.selection.lookupContext,
            bookTitle: draft.bookTitle,
            chapter: draft.selection.chapter,
            targetLanguageCode: targetLanguageCode(),
            targetLanguageName: targetLanguageName(),
          );
          break;
      }
      draft.completeProvider(request, result);
    } catch (error) {
      draft.failProvider(request, error);
    }
    _notifyIfAlive();
  }

  void removeProvider(AnnotationEditorProvider provider) {
    draft.removeProvider(provider);
    notifyListeners();
  }

  void setPersonalNote(String value) {
    draft.setPersonalNote(value);
    notifyListeners();
  }

  Future<void> ask(String question) async {
    final value = question.trim();
    if (value.isEmpty || chatLoading) return;
    final generation = ++_chatGeneration;
    chatLoading = true;
    chatError = null;
    notifyListeners();
    try {
      final answer = await ai.followUp(
        draft: draft,
        question: value,
        targetLanguageCode: targetLanguageCode(),
        targetLanguageName: targetLanguageName(),
      );
      if (!_disposed && generation == _chatGeneration) {
        draft.addAiExchange(value, answer);
      }
    } catch (error) {
      if (!_disposed && generation == _chatGeneration) {
        chatError = error.toString();
      }
    } finally {
      if (!_disposed && generation == _chatGeneration) {
        chatLoading = false;
        notifyListeners();
      }
    }
  }

  Future<AnnotationRef?> save() async {
    if (saving || !draft.isDirty) return null;
    saving = true;
    saveError = null;
    notifyListeners();
    try {
      return await saveDraft(_saveInput());
    } catch (error) {
      saveError = error.toString();
      return null;
    } finally {
      if (!_disposed) {
        saving = false;
        notifyListeners();
      }
    }
  }

  Future<bool> delete() async {
    final ref = draft.existingRef;
    if (ref == null || saving) return false;
    saving = true;
    saveError = null;
    notifyListeners();
    try {
      await deleteAnnotation(ref);
      return true;
    } catch (error) {
      saveError = error.toString();
      return false;
    } finally {
      if (!_disposed) {
        saving = false;
        notifyListeners();
      }
    }
  }

  AnnotationEditorSaveInput _saveInput() => AnnotationEditorSaveInput(
        creation: draft.existingRef == null
            ? CanonicalSelectionCreation(
                book: book,
                selectedText: draft.selection.selectedText,
                epubCfi: draft.selection.selector,
                chapter: draft.selection.chapter,
                context: draft.selection.annotationContext,
              )
            : null,
        existingRef: draft.existingRef,
        materials: [
          for (final provider in AnnotationEditorProvider.values)
            if (draft.sourceResults[provider] case final result?)
              AnnotationEditorMaterialInput(
                enrichmentId: result.enrichmentId,
                providerId: result.providerId,
                providerName: result.providerName,
                kind: result.kind,
                translation: result.translation,
                markdown: result.markdown,
                commentary: result.commentary?.toMap() ?? const {},
                metadata: result.metadata,
              ),
        ],
        personalNote: draft.personalNote,
        aiThreadId: draft.aiThreadId,
        aiMessages: [
          for (final message in draft.aiMessages)
            AnnotationEditorMessageInput(
              messageId: message.messageId,
              role: message.role,
              content: message.content,
              sequence: message.sequence,
              createdAt: message.createdAt,
            ),
        ],
      );

  void _notifyIfAlive() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _chatGeneration++;
    draft.close();
    super.dispose();
  }
}
