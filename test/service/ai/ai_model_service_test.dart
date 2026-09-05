import 'dart:convert';
import 'package:anx_reader/service/ai/ai_model_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('TTS discovery only returns available Speech endpoint models', () async {
    await http.runWithClient(() async {
      final models = await fetchAiModels(
          url: 'https://example.com/v1/', apiKey: 'test', ttsOnly: true);
      expect(models, ['gpt-4o-mini-tts-2025-12-15', 'tts-1']);
      final all =
          await fetchAiModels(url: 'https://example.com/v1', apiKey: 'test');
      expect(all, contains('gpt-audio'));
    },
        () => MockClient((request) async => http.Response(
            jsonEncode({
              'data': [
                for (final id in [
                  'tts-1',
                  'tts-1',
                  'gpt-4o-mini-tts-2025-12-15',
                  'whisper-1',
                  'gpt-4o-transcribe',
                  'gpt-audio',
                  'gpt-realtime',
                  'unknown-tts-model'
                ])
                  {'id': id},
              ]
            }),
            200)));
  });

  test('no supported models remains empty and HTTP errors propagate', () async {
    await http.runWithClient(() async {
      expect(
          await fetchAiModels(
              url: 'https://example.com', apiKey: 'test', ttsOnly: true),
          isEmpty);
    },
        () => MockClient(
            (_) async => http.Response('{"data":[{"id":"whisper-1"}]}', 200)));
    await http.runWithClient(() async {
      await expectLater(
          fetchAiModels(
              url: 'https://example.com', apiKey: 'test', ttsOnly: true),
          throwsException);
    }, () => MockClient((_) async => http.Response('Unauthorized', 401)));
  });
}
