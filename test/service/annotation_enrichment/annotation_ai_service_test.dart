import 'package:anx_reader/enums/ai_reasoning_effort.dart';
import 'package:anx_reader/models/ai_provider.dart';
import 'package:anx_reader/page/book_player/annotation_editor/annotation_editor_draft.dart';
import 'package:anx_reader/page/book_player/selection_persistence_session.dart';
import 'package:anx_reader/service/ai/effective_route.dart';
import 'package:anx_reader/service/ai/langchain_ai_config.dart';
import 'package:anx_reader/service/annotation_enrichment/annotation_ai_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('analysis prompt uses configured language and does not force English',
      () {
    final prompt = buildAnnotationAnalysisPrompt(
      selectedText: 'take it for granted',
      context: 'Do not take it for granted.',
      bookTitle: 'Book',
      chapter: 'One',
      targetLanguageCode: 'uk',
      targetLanguageName: 'Українська',
    );
    expect(prompt, contains('Українська (uk)'));
    expect(prompt, isNot(contains('Write every explanatory value in English')));
  });

  test('analysis returns structured semantic fields and actual route identity',
      () async {
    late String prompt;
    final service = AnnotationAiService(
      resolveRoute: () => _route(),
      generate: (messages, _) async {
        prompt = messages.single.contentAsString;
        return '''```json
{"translation":"переклад","translationNotes":"нотатки","grammar":"граматика","usage":"вживання"}
```''';
      },
    );
    final result = await service.analyze(
      selectedText: 'text',
      context: 'context',
      bookTitle: 'Book',
      chapter: 'One',
      targetLanguageCode: 'uk',
      targetLanguageName: 'Українська',
    );

    expect(prompt, contains('Українська (uk)'));
    expect(result.providerId, 'route-id');
    expect(result.providerName, 'Configured route');
    expect(result.translation, 'переклад');
    expect(result.commentary?.translationNotes, 'нотатки');
    expect(result.commentary?.grammar, 'граматика');
    expect(result.commentary?.usage, 'вживання');
  });

  test('follow-up receives prior conversation and all draft materials',
      () async {
    late String combined;
    final draft = AnnotationEditorDraft.forSelection(
      selection: const SelectionSnapshot(
        selectedText: 'phrase',
        annotationContext: 'compact context',
        lookupContext: 'wider lookup context',
        chapter: 'Chapter',
        selector: 'epubcfi(/6/2!/4/2:1)',
      ),
      bookTitle: 'Book',
    );
    for (final value in [
      const AnnotationEditorSourceResult(
        providerId: 'google-translate',
        providerName: 'Google Translate',
        kind: 'translation',
        translation: 'google result',
      ),
      const AnnotationEditorSourceResult(
        providerId: 'ldoce',
        providerName: 'LDOCE',
        kind: 'dictionary',
        markdown: 'dictionary result',
      ),
      const AnnotationEditorSourceResult(
        providerId: 'openai',
        providerName: 'OpenAI',
        kind: 'ai-analysis',
        commentary: AnnotationEditorCommentary(grammar: 'analysis result'),
      ),
    ]) {
      final provider = AnnotationEditorProvider.values.singleWhere(
        (provider) => provider.providerId == value.providerId,
      );
      final request = draft.startProvider(provider);
      draft.completeProvider(request, value);
    }
    draft.setPersonalNote('personal note');
    draft.addAiExchange('old question', 'old answer');
    final service = AnnotationAiService(
      resolveRoute: () => _route(),
      generate: (messages, _) async {
        combined =
            messages.map((message) => message.contentAsString).join('\n');
        return 'new answer';
      },
    );

    expect(
      await service.followUp(
        draft: draft,
        question: 'new question',
        targetLanguageCode: 'ru',
        targetLanguageName: 'Русский',
      ),
      'new answer',
    );
    for (final expected in [
      'wider lookup context',
      'google result',
      'dictionary result',
      'analysis result',
      'personal note',
      'old question',
      'old answer',
      'new question',
    ]) {
      expect(combined, contains(expected));
    }
  });
}

EffectiveAiRoute _route() => EffectiveAiRoute(
      config: LangchainAiConfig(
        identifier: 'route-id',
        model: 'model',
        apiKey: 'key',
        baseUrl: 'https://example.test',
        reasoningEffort: AiReasoningEffort.auto,
      ),
      protocol: AiProtocol.openai,
      provider: AiProvider(
        id: 'route-id',
        title: 'Configured route',
        url: 'https://example.test',
        protocol: AiProtocol.openai,
        model: 'model',
        apiKeys: const [AiApiKey(id: 'key', key: 'secret')],
      ),
    );
