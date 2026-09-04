import 'dart:convert';
import 'dart:typed_data';

import 'package:anx_reader/service/ai/effective_route.dart';
import 'package:anx_reader/service/ai/langchain_ai_config.dart';
import 'package:anx_reader/models/ai_provider.dart';
import 'package:anx_reader/service/annotation_enrichment/openai_audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  test('passes exact selected text and configured model and voice', () async {
    final requests = <Map<String, Object?>>[];
    final service = OpenAiAudioService(
      resolveRoute: _route,
      model: () => 'tts-model',
      voice: () => 'coral',
      post: (url, {required headers, required body}) async {
        requests.add({
          'url': url.toString(),
          'headers': headers,
          'body': jsonDecode(body as String),
        });
        if (url.path.endsWith('/audio/speech')) {
          return http.Response.bytes([1, 2, 3], 200);
        }
        return http.Response(
          jsonEncode({
            'output': [
              {
                'content': [
                  {'type': 'output_text', 'text': 'ðə tɛkst'}
                ]
              }
            ]
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      },
    );

    final result = await service.generate('  the text  ');
    final speech = requests.singleWhere(
        (request) => (request['url'] as String).endsWith('/audio/speech'));
    final speechBody = speech['body'] as Map<String, dynamic>;
    final ipa = requests.singleWhere(
        (request) => (request['url'] as String).endsWith('/responses'));
    expect(speechBody, containsPair('input', 'the text'));
    expect(speechBody, containsPair('model', 'tts-model'));
    expect(speechBody, containsPair('voice', 'coral'));
    expect(jsonEncode(ipa['body']), contains('the text'));
    expect(result.bytes, Uint8List.fromList([1, 2, 3]));
    expect(result.ipa, 'ðə tɛkst');
    expect(result.model, 'tts-model');
    expect(result.voice, 'coral');
    expect(result.assetRef, startsWith('annotation-assets/audio/'));
    expect(result.sha256, hasLength(64));
  });

  test('API failure produces no partial result', () async {
    final service = OpenAiAudioService(
      resolveRoute: _route,
      model: () => 'tts-model',
      voice: () => 'alloy',
      post: (url, {required headers, required body}) async =>
          url.path.endsWith('/audio/speech')
              ? http.Response('failed', 500)
              : http.Response('{"output":[]}', 200),
    );
    await expectLater(service.generate('text'), throwsA(isA<StateError>()));
  });
}

EffectiveAiRoute _route() => EffectiveAiRoute(
      config: LangchainAiConfig(
        identifier: 'openai',
        model: 'ipa-model',
        apiKey: 'secret',
        baseUrl: 'https://api.openai.com/v1',
      ),
      protocol: AiProtocol.openai,
    );
