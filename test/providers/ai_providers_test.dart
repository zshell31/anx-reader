import 'dart:convert';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/providers/ai_providers.dart';
import 'package:anx_reader/service/annotation_enrichment/openai_audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('migrates legacy OpenAI Audio settings into the OpenAI provider',
      () async {
    SharedPreferences.setMockInitialValues({
      'openAiAudioModel': 'legacy-tts',
      'openAiAudioVoice': 'legacy-voice',
      'aiProviders': jsonEncode([
        {
          'id': 'openai',
          'title': 'OpenAI',
          'url': 'https://api.openai.com/v1',
          'protocol': 'openai',
          'model': 'gpt-text',
        },
        {
          'id': 'claude',
          'title': 'Claude',
          'url': 'https://api.anthropic.com',
          'protocol': 'claude',
          'model': 'claude-text',
        },
      ]),
    });
    await Prefs().initPrefs();
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final providers = container.read(aiProvidersProvider);

    expect(providers.first.ttsModel, 'legacy-tts');
    expect(providers.first.ttsVoice, 'legacy-voice');
    expect(providers.last.ttsModel, isEmpty);
    expect(providers.last.ttsVoice, isEmpty);
    final persisted = Prefs().getAiProviders().cast<Map<String, dynamic>>();
    expect(persisted.first['ttsModel'], 'legacy-tts');
    expect(persisted.first['ttsVoice'], 'legacy-voice');
  });

  test('Audio capability follows the selected built-in OpenAI provider',
      () async {
    SharedPreferences.setMockInitialValues({
      'selectedAiService': 'claude',
      'aiProviders': jsonEncode([
        {
          'id': 'openai',
          'title': 'OpenAI',
          'url': 'https://api.openai.com/v1',
          'protocol': 'openai',
          'model': 'gpt-text',
          'ttsModel': 'gpt-4o-mini-tts',
          'ttsVoice': 'alloy',
        },
        {
          'id': 'claude',
          'title': 'Claude',
          'url': 'https://api.anthropic.com',
          'protocol': 'claude',
          'model': 'claude-text',
        },
        {
          'id': 'custom-openai-compatible',
          'title': 'Custom compatible',
          'url': 'https://example.test/v1',
          'protocol': 'openai',
          'model': 'custom-text',
        },
      ]),
    });
    await Prefs().initPrefs();

    expect(selectedAiProviderSupportsOpenAiAudio(), isFalse);
    Prefs().selectedAiService = 'custom-openai-compatible';
    expect(selectedAiProviderSupportsOpenAiAudio(), isFalse);
    Prefs().selectedAiService = 'openai';
    expect(selectedAiProviderSupportsOpenAiAudio(), isTrue);
  });
}
