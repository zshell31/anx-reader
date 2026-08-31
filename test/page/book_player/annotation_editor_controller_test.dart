import 'dart:async';

import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/page/book_player/annotation_editor/annotation_editor_controller.dart';
import 'package:anx_reader/page/book_player/annotation_editor/annotation_editor_draft.dart';
import 'package:anx_reader/page/book_player/selection_persistence_session.dart';
import 'package:anx_reader/service/annotation_enrichment/annotation_ai_service.dart';
import 'package:anx_reader/service/annotation_enrichment/google_annotation_translate.dart';
import 'package:anx_reader/service/annotation_enrichment/ldoce_annotation_dictionary.dart';
import 'package:anx_reader/service/sync/annotation_read_model.dart';
import 'package:anx_reader/service/sync/annotation_repository.dart';
import 'package:flutter_test/flutter_test.dart';

const fingerprint = '0123456789abcdef0123456789abcdef';

void main() {
  test('provider exploration and AI follow-up do not invoke Save', () async {
    var saves = 0;
    final controller = _controller(
      saveDraft: (_) async {
        saves++;
        return _ref();
      },
      google: _ImmediateGoogle(),
      ldoce: _ImmediateLdoce(),
      ai: _ImmediateAi(),
    );

    await controller.runProvider(AnnotationEditorProvider.googleTranslate);
    await controller.runProvider(AnnotationEditorProvider.ldoce);
    await controller.runProvider(AnnotationEditorProvider.ai);
    await controller.ask('Why?');

    expect(saves, 0);
    expect(controller.draft.sourceResults, hasLength(3));
    expect(controller.draft.aiMessages, hasLength(2));
    controller.dispose();
  });

  test('one explicit Save sends every draft field through one callback',
      () async {
    var saves = 0;
    AnnotationEditorSaveInput? captured;
    final controller = _controller(
      saveDraft: (input) async {
        saves++;
        captured = input;
        return _ref();
      },
      google: _ImmediateGoogle(),
      ldoce: _ImmediateLdoce(),
      ai: _ImmediateAi(),
    );
    await controller.runProvider(AnnotationEditorProvider.googleTranslate);
    await controller.runProvider(AnnotationEditorProvider.ldoce);
    await controller.runProvider(AnnotationEditorProvider.ai);
    await controller.ask('Why?');
    controller.setPersonalNote('remember');

    expect(await controller.save(), _ref());
    expect(saves, 1);
    expect(captured?.creation?.selectedText, 'phrase');
    expect(captured?.existingRef, isNull);
    expect(captured?.materials, hasLength(3));
    expect(captured?.personalNote, 'remember');
    expect(captured?.aiMessages, hasLength(2));
    controller.dispose();
  });

  test('second refresh wins when first provider request completes late',
      () async {
    final google = _ControlledGoogle();
    final controller = _controller(google: google);

    final first =
        controller.runProvider(AnnotationEditorProvider.googleTranslate);
    final second =
        controller.runProvider(AnnotationEditorProvider.googleTranslate);
    google.requests[1].complete(
      const GoogleAnnotationTranslation(text: 'fresh'),
    );
    await second;
    google.requests[0].complete(
      const GoogleAnnotationTranslation(text: 'stale'),
    );
    await first;

    expect(
      controller.draft.sourceResults[AnnotationEditorProvider.googleTranslate]
          ?.translation,
      'fresh',
    );
    controller.dispose();
  });

  test('late provider and chat responses cannot mutate a disposed editor',
      () async {
    final google = _ControlledGoogle();
    final ai = _ControlledAi();
    final controller = _controller(google: google, ai: ai);
    final provider =
        controller.runProvider(AnnotationEditorProvider.googleTranslate);
    final chat = controller.ask('Why?');

    controller.dispose();
    google.requests.single.complete(
      const GoogleAnnotationTranslation(text: 'late'),
    );
    ai.followUpRequest.complete('late answer');
    await Future.wait([provider, chat]);

    expect(controller.draft.sourceResults, isEmpty);
    expect(controller.draft.aiMessages, isEmpty);
  });

  test('removing one source preserves the other draft sources', () async {
    final controller = _controller(
      google: _ImmediateGoogle(),
      ldoce: _ImmediateLdoce(),
      ai: _ImmediateAi(),
    );
    for (final provider in AnnotationEditorProvider.values) {
      await controller.runProvider(provider);
    }

    controller.removeProvider(AnnotationEditorProvider.ldoce);

    expect(
      controller.draft.sourceResults.keys,
      containsAll([
        AnnotationEditorProvider.googleTranslate,
        AnnotationEditorProvider.ai,
      ]),
    );
    expect(
      controller.draft.sourceResults,
      isNot(contains(AnnotationEditorProvider.ldoce)),
    );
    controller.dispose();
  });
}

AnnotationEditorController _controller({
  GoogleAnnotationTranslateService? google,
  LdoceAnnotationDictionaryService? ldoce,
  AnnotationAiService? ai,
  SaveAnnotationEditor? saveDraft,
}) =>
    AnnotationEditorController(
      draft: AnnotationEditorDraft.forSelection(
        selection: const SelectionSnapshot(
          selectedText: 'phrase',
          annotationContext: 'compact context',
          lookupContext: 'wider context',
          chapter: 'Chapter',
          selector: 'epubcfi(/6/2!/4/2:1)',
        ),
        bookTitle: 'Book',
      ),
      book: Book(
        id: 1,
        title: 'Book',
        coverPath: '',
        filePath: 'book.epub',
        lastReadPosition: '',
        readingPercentage: 0,
        author: 'Author',
        isDeleted: false,
        rating: 0,
        md5: fingerprint,
        createTime: DateTime(2026),
        updateTime: DateTime(2026),
      ),
      google: google,
      ldoce: ldoce,
      ai: ai,
      saveDraft: saveDraft ?? (_) async => _ref(),
      deleteAnnotation: (ref) async => ref,
      targetLanguageCode: () => 'uk',
      targetLanguageName: () => 'Українська',
    );

AnnotationRef _ref() => AnnotationRef(
      bookFingerprint: fingerprint,
      annotationId: 'annotation-a',
    );

class _ImmediateGoogle extends GoogleAnnotationTranslateService {
  @override
  Future<GoogleAnnotationTranslation> translate(
    String text, {
    required String targetLanguage,
  }) async =>
      const GoogleAnnotationTranslation(
        text: 'google',
        detectedLanguage: 'en',
      );
}

class _ControlledGoogle extends GoogleAnnotationTranslateService {
  final requests = <Completer<GoogleAnnotationTranslation>>[];

  @override
  Future<GoogleAnnotationTranslation> translate(
    String text, {
    required String targetLanguage,
  }) {
    final completer = Completer<GoogleAnnotationTranslation>();
    requests.add(completer);
    return completer.future;
  }
}

class _ImmediateLdoce extends LdoceAnnotationDictionaryService {
  @override
  Future<LdoceArticle> lookup(String text) async => const LdoceArticle(
        title: 'phrase',
        url: 'https://example.test/phrase',
        entries: [
          LdoceEntry(
            headword: 'phrase',
            senses: [LdoceSense(definition: 'dictionary')],
          ),
        ],
      );
}

class _ImmediateAi extends AnnotationAiService {
  @override
  Future<AnnotationEditorSourceResult> analyze({
    required String selectedText,
    required String? context,
    required String bookTitle,
    required String chapter,
    required String targetLanguageCode,
    required String targetLanguageName,
  }) async =>
      const AnnotationEditorSourceResult(
        providerId: 'route-id',
        providerName: 'Configured AI',
        kind: 'ai-analysis',
        commentary: AnnotationEditorCommentary(grammar: 'analysis'),
      );

  @override
  Future<String> followUp({
    required AnnotationEditorDraft draft,
    required String question,
    required String targetLanguageCode,
    required String targetLanguageName,
  }) async =>
      'answer';
}

class _ControlledAi extends _ImmediateAi {
  final followUpRequest = Completer<String>();

  @override
  Future<String> followUp({
    required AnnotationEditorDraft draft,
    required String question,
    required String targetLanguageCode,
    required String targetLanguageName,
  }) =>
      followUpRequest.future;
}
