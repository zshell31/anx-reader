import 'dart:io';
import 'dart:convert';
import 'package:anx_reader/service/annotation_enrichment/notes_rfc_analysis_schema.dart';
import 'package:langchain_openai/langchain_openai.dart';
import 'package:langchain_core/prompts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:anx_reader/enums/ai_reasoning_effort.dart';
import 'package:anx_reader/models/ai_provider.dart';
import 'package:anx_reader/page/book_player/annotation_editor/annotation_editor_draft.dart';
import 'package:anx_reader/page/book_player/selection_persistence_session.dart';
import 'package:anx_reader/service/ai/effective_route.dart';
import 'package:anx_reader/service/ai/langchain_ai_config.dart';
import 'package:anx_reader/service/annotation_enrichment/annotation_ai_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('analysis sends the RFC schema through the real OpenAI adapter',
      () async {
    final original = EffectiveAiRoute(
      config: _route().config.copyWith(baseUrl: 'https://api.openai.com/v1'),
      protocol: AiProtocol.openai,
      provider: _route().provider,
    );
    late Map<String, dynamic> sent;
    final service = AnnotationAiService(
      resolveRoute: () => original,
      generate: (messages, route) async {
        final client = MockClient((request) async {
          sent = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
              jsonEncode({
                'id': 'test',
                'object': 'chat.completion',
                'created': 1,
                'model': 'model',
                'choices': [
                  {
                    'index': 0,
                    'finish_reason': 'stop',
                    'message': {
                      'role': 'assistant',
                      'content': jsonEncode({
                        'translation': 'перевод',
                        'translationNotes': '',
                        'grammar': '',
                        'usage': '',
                        'chunks': [],
                      }),
                    }
                  }
                ],
              }),
              200,
              headers: {'content-type': 'application/json'});
        });
        addTearDown(client.close);
        final model = ChatOpenAI(
            apiKey: 'test',
            client: client,
            defaultOptions: route.config.toOpenAIOptions());
        final result = await model.invoke(PromptValue.chat(messages));
        return result.output.content;
      },
    );
    await service.analyze(
        selectedText: 'take',
        context: '',
        bookTitle: '',
        chapter: '',
        targetLanguageCode: 'ru',
        targetLanguageName: 'Russian');
    expect(sent['response_format'], {
      'type': 'json_schema',
      'json_schema': {
        'name': 'annotation_analysis',
        'strict': true,
        'schema': jsonDecode(
            File('protocol/notes-rfc/schemas/ai-analysis.schema.json')
                .readAsStringSync()),
      },
    });
    expect(original.config.toOpenAIOptions().responseFormat, isNull);
  });

  test('vendored schema matches RFC and prompt supplies it to other providers',
      () {
    expect(
        notesRfcAnalysisSchema,
        jsonDecode(File('protocol/notes-rfc/schemas/ai-analysis.schema.json')
            .readAsStringSync()));
    expect(annotationAnalysisRoute(_route()).config.responseFormat, isNull);
    final prompt = buildAnnotationAnalysisPrompt(
        selectedText: 'take',
        context: '',
        bookTitle: '',
        chapter: '',
        targetLanguageCode: 'ru',
        targetLanguageName: 'Russian');
    expect(prompt, contains(jsonEncode(notesRfcAnalysisSchema)));
  });

  final fixtures = jsonDecode(
      File('protocol/notes-rfc/fixtures/ai/analysis.json')
          .readAsStringSync()) as List;
  test('caps new generated output at seven while retaining the seventh chunk',
      () async {
    final fixture =
        fixtures.firstWhere((f) => f['id'] == 'seven-chunks-new-examples');
    final payload = jsonDecode(jsonEncode(fixture['result'])) as Map;
    (payload['chunks'] as List)
        .add({...payload['chunks'][0] as Map, 'canonicalForm': 'eighth'});
    final service = AnnotationAiService(
        resolveRoute: () => _route(),
        generate: (_, __) async => jsonEncode(payload));
    final result = await service.analyze(
        selectedText: fixture['selectedText'],
        context: fixture['contextText'],
        bookTitle: '',
        chapter: '',
        targetLanguageCode: 'ru',
        targetLanguageName: 'Russian');
    expect(result.commentary!.chunks!.map((c) => c.canonicalForm).toList(),
        [for (final c in fixture['result']['chunks']) c['canonicalForm']]);
  });
  for (final fixture in fixtures) {
    test('RFC analysis ${fixture['id'] ?? fixture['name']}', () async {
      final payload = fixture['result'] as Map;
      final service = AnnotationAiService(
          resolveRoute: () => _route(),
          generate: (_, __) async => jsonEncode(payload));
      final result = await service.analyze(
          selectedText: fixture['selectedText'],
          context: fixture['contextText'],
          bookTitle: '',
          chapter: '',
          targetLanguageCode: 'ru',
          targetLanguageName: 'Russian');
      final commentary = result.commentary!;
      expect(commentary.translation ?? '', payload['translation']);
      expect(commentary.translationNotes ?? '', payload['translationNotes']);
      expect(commentary.grammar ?? '', payload['grammar']);
      expect(commentary.usage ?? '', payload['usage']);
      expect(commentary.chunks?.map((c) => c.toMap()).toList() ?? [], [
        for (final chunk in payload['chunks'])
          {
            for (final entry in (chunk as Map).entries)
              if (entry.value != null &&
                  !(entry.value is List && (entry.value as List).isEmpty))
                entry.key: entry.value
          }
      ]);
    });
  }
  test(
      'historical chunk hydration preserves extension fields and producer-exceeding counts',
      () {
    final chunk = {
      'canonicalForm': 'take care',
      'meaning': 'care',
      'examples': ['one', 'two', 'three'],
      'future': {
        'nested': [1, null]
      }
    };
    final raw = {
      'chunks': List.generate(8, (_) => chunk),
      'futureCommentary': true
    };
    expect(AnnotationEditorCommentary.fromMap(raw).toMap(), raw);
    expect(AiChunk.fromMap(chunk, generated: true).examples, ['one', 'two']);
  });

  test('analysis limits chunks to the selection and its containing sentence',
      () {
    final prompt = buildAnnotationAnalysisPrompt(
      selectedText: 'gave up',
      context: 'He broke the ice. She gave up waiting. They hit the road.',
      bookTitle: 'Book',
      chapter: 'One',
      targetLanguageCode: 'ru',
      targetLanguageName: 'Russian',
    );
    expect(
        prompt,
        contains(File('protocol/notes-rfc/ai/reference-prompt.txt')
            .readAsStringSync()
            .trim()));
    expect(prompt, contains('"selectedText":"gave up"'));
    expect(prompt,
        contains('Never mine unrelated expressions or neighboring sentences'));
    expect(prompt, contains('selectedText is an explicit learning target'));
    expect(prompt, contains('Chunks supplement selectedText'));
    expect(prompt,
        contains('This restriction does not apply to selectedText itself'));
    expect(prompt, contains('Do not emit a synthetic chunk'));
    expect(prompt,
        contains('directly overlaps or semantically contains selectedText'));
  });

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
{"translation":"переклад","translationNotes":"нотатки","grammar":"граматика","usage":"вживання","chunks":[{"canonicalForm":"have one's suspicions","surfaceForm":"had your suspicions","meaning":"мати підозри","type":"expression","examples":["I've had my suspicions for a while."]}]}
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
    expect(result.commentary?.chunks?.single.toMap(), {
      'canonicalForm': "have one's suspicions",
      'surfaceForm': 'had your suspicions',
      'meaning': 'мати підозри',
      'type': 'expression',
      'examples': ["I've had my suspicions for a while."],
    });
    expect(prompt, contains('0–7 chunks'));
    expect(prompt, contains('do not copy selectedText or contextText'));
    expect(prompt, contains('do not merely swap names or pronouns'));
    expect(prompt, contains('transferable grammar'));
  });

  test('old analysis without chunks still decodes', () async {
    final service = AnnotationAiService(
      resolveRoute: () => _route(),
      generate: (_, __) async =>
          '{"translation":"переклад","translationNotes":"","grammar":"","usage":""}',
    );
    final result = await service.analyze(
      selectedText: 'text',
      context: null,
      bookTitle: 'Book',
      chapter: '',
      targetLanguageCode: 'uk',
      targetLanguageName: 'Українська',
    );
    expect(result.commentary?.chunks, isNull);
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
