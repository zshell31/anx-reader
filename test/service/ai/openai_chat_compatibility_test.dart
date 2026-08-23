import 'dart:convert';

import 'package:anx_reader/service/ai/openai_chat_compatibility.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const officialChatCompletions = 'https://api.openai.com/v1/chat/completions';

  String? effectiveEffort({
    required String model,
    required bool hasFunctionTools,
    required String? configuredReasoningEffort,
    String endpoint = officialChatCompletions,
  }) {
    return OpenAiChatCompatibilityPolicy.effectiveReasoningEffort(
      endpoint: Uri.parse(endpoint),
      model: model,
      hasFunctionTools: hasFunctionTools,
      configuredReasoningEffort: configuredReasoningEffort,
    );
  }

  group('OpenAiChatCompatibilityPolicy', () {
    test('uses none for GPT-5.6 Terra tool requests with medium reasoning', () {
      expect(
        effectiveEffort(
          model: 'gpt-5.6-terra',
          hasFunctionTools: true,
          configuredReasoningEffort: 'medium',
        ),
        OpenAiReasoningEffort.none,
      );
    });

    test('keeps medium for GPT-5.6 Terra requests without tools', () {
      expect(
        effectiveEffort(
          model: 'gpt-5.6-terra',
          hasFunctionTools: false,
          configuredReasoningEffort: 'medium',
        ),
        'medium',
      );
    });

    test('keeps reasoning already set to none', () {
      expect(
        effectiveEffort(
          model: 'gpt-5.6-terra',
          hasFunctionTools: true,
          configuredReasoningEffort: OpenAiReasoningEffort.none,
        ),
        OpenAiReasoningEffort.none,
      );
    });

    test('keeps non-affected OpenAI model behavior unchanged', () {
      expect(
        effectiveEffort(
          model: 'gpt-5.3-chat-latest',
          hasFunctionTools: true,
          configuredReasoningEffort: 'medium',
        ),
        'medium',
      );
    });

    test('keeps OpenAI-compatible provider behavior unchanged', () {
      expect(
        effectiveEffort(
          endpoint: 'https://openrouter.ai/api/v1/chat/completions',
          model: 'gpt-5.6-terra',
          hasFunctionTools: true,
          configuredReasoningEffort: 'medium',
        ),
        'medium',
      );
    });
  });

  test('compatibility client sends none for an affected tool request',
      () async {
    late Map<String, dynamic> sentBody;
    final client = OpenAiChatCompatibilityClient(
      inner: MockClient((request) async {
        sentBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response('{}', 200);
      }),
    );
    addTearDown(client.close);

    await client.post(
      Uri.parse(officialChatCompletions),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({
        'model': 'gpt-5.6-terra',
        'reasoning_effort': 'medium',
        'tools': [
          {
            'type': 'function',
            'function': {'name': 'lookup'},
          },
        ],
      }),
    );

    expect(sentBody['reasoning_effort'], OpenAiReasoningEffort.none);
  });
}
