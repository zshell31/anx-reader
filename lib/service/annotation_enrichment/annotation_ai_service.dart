import 'dart:async';
import 'dart:convert';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/page/book_player/annotation_editor/annotation_editor_draft.dart';
import 'package:anx_reader/service/ai/effective_route.dart';
import 'package:anx_reader/service/ai/index.dart';
import 'package:anx_reader/utils/ai_reasoning_parser.dart';
import 'package:langchain_core/chat_models.dart';

typedef AnnotationAiGenerate = Future<String> Function(
  List<ChatMessage> messages,
  EffectiveAiRoute route,
);

class AnnotationAiService {
  final EffectiveAiRoute? Function() resolveRoute;
  final AnnotationAiGenerate generate;
  final Duration timeout;

  AnnotationAiService({
    EffectiveAiRoute? Function()? resolveRoute,
    AnnotationAiGenerate? generate,
    this.timeout = const Duration(minutes: 2),
  })  : resolveRoute = resolveRoute ?? resolveEffectiveAiRouteFromPrefs,
        generate = generate ?? _generate;

  Future<AnnotationEditorSourceResult> analyze({
    required String selectedText,
    required String? context,
    required String bookTitle,
    required String chapter,
    required String targetLanguageCode,
    required String targetLanguageName,
  }) async {
    final route = _route();
    final prompt = buildAnnotationAnalysisPrompt(
      selectedText: selectedText,
      context: context,
      bookTitle: bookTitle,
      chapter: chapter,
      targetLanguageCode: targetLanguageCode,
      targetLanguageName: targetLanguageName,
    );
    final raw = await generate(
      [ChatMessage.humanText(prompt)],
      route,
    ).timeout(timeout);
    final payload = _decodeObject(splitReasoningEnvelope(raw).answerContent);
    final commentary = AnnotationEditorCommentary(
      translation: _text(payload['translation']),
      translationNotes: _text(payload['translationNotes']),
      grammar: _text(payload['grammar']),
      usage: _text(payload['usage']),
    );
    if (commentary.toMap().isEmpty) {
      throw const FormatException('AI returned an empty annotation analysis.');
    }
    return AnnotationEditorSourceResult(
      providerId: route.provider?.id ?? Prefs().selectedAiService,
      providerName: route.provider?.title ?? Prefs().selectedAiService,
      kind: 'ai-analysis',
      translation: commentary.translation,
      commentary: commentary,
    );
  }

  Future<String> followUp({
    required AnnotationEditorDraft draft,
    required String question,
    required String targetLanguageCode,
    required String targetLanguageName,
  }) async {
    final route = _route();
    final messages = buildAnnotationFollowUpMessages(
      draft: draft,
      question: question,
      targetLanguageCode: targetLanguageCode,
      targetLanguageName: targetLanguageName,
    );
    final raw = await generate(messages, route).timeout(timeout);
    final answer = splitReasoningEnvelope(raw).answerContent.trim();
    if (answer.isEmpty) throw StateError('AI returned an empty answer.');
    return answer;
  }

  EffectiveAiRoute _route() {
    final route = resolveRoute();
    if (route == null) throw StateError('AI service is not configured.');
    return route;
  }
}

String buildAnnotationAnalysisPrompt({
  required String selectedText,
  required String? context,
  required String bookTitle,
  required String chapter,
  required String targetLanguageCode,
  required String targetLanguageName,
}) =>
    '''Analyze the selected book text for a language learner.
Write every explanatory value in $targetLanguageName ($targetLanguageCode).
Do not default to English unless that is the configured target language.
Return only one JSON object with string fields: translation, translationNotes, grammar, usage.

Selected text:
${selectedText.trim()}

${context?.trim().isNotEmpty == true ? 'Reading context:\n${context!.trim()}\n\n' : ''}Book: ${bookTitle.trim()}
Chapter: ${chapter.trim()}''';

List<ChatMessage> buildAnnotationFollowUpMessages({
  required AnnotationEditorDraft draft,
  required String question,
  required String targetLanguageCode,
  required String targetLanguageName,
}) {
  final materials = <String>[
    if (draft.personalNote.trim().isNotEmpty)
      'Personal note:\n${draft.personalNote.trim()}',
    for (final provider in AnnotationEditorProvider.values)
      if (draft.sourceResults[provider] case final result?)
        '${result.providerName}:\n${_resultContext(result)}',
  ];
  return [
    ChatMessage.system(
      'Answer annotation follow-up questions in $targetLanguageName '
      '($targetLanguageCode). Use only the compact supplied reading context '
      'and materials; do not assume access to the whole book.',
    ),
    ChatMessage.humanText('''Selected text:
${draft.selection.selectedText.trim()}

Reading context:
${draft.selection.lookupContext?.trim() ?? draft.selection.annotationContext?.trim() ?? ''}

Book: ${draft.bookTitle}
Chapter: ${draft.selection.chapter}

Saved and draft materials:
${materials.join('\n\n').substring(0, materials.join('\n\n').length.clamp(0, 30000))}'''),
    for (final message in draft.aiMessages)
      if (message.role == 'assistant')
        ChatMessage.ai(message.content)
      else if (message.role == 'user')
        ChatMessage.humanText(message.content),
    ChatMessage.humanText(question.trim()),
  ];
}

String _resultContext(AnnotationEditorSourceResult result) => [
      if (result.translation?.trim().isNotEmpty == true)
        'Translation: ${result.translation!.trim()}',
      if (result.markdown?.trim().isNotEmpty == true) result.markdown!.trim(),
      if (result.commentary case final commentary?)
        for (final entry in commentary.toMap().entries)
          '${entry.key}: ${entry.value}',
    ].join('\n\n');

Future<String> _generate(
  List<ChatMessage> messages,
  EffectiveAiRoute route,
) async {
  String? latest;
  await for (final value in aiGenerateStreamWithRoute(messages, route)) {
    latest = value;
  }
  return latest ?? '';
}

Map<String, dynamic> _decodeObject(String value) {
  var source = value.trim();
  if (source.startsWith('```')) {
    source = source.replaceFirst(RegExp(r'^```(?:json)?\s*'), '');
    source = source.replaceFirst(RegExp(r'\s*```$'), '');
  }
  final decoded = jsonDecode(source);
  if (decoded is! Map) {
    throw const FormatException('AI returned an unknown analysis format.');
  }
  return decoded.cast<String, dynamic>();
}

String? _text(Object? value) =>
    value is String && value.trim().isNotEmpty ? value.trim() : null;
