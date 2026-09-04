import 'dart:convert';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/page/settings_page/ai_provider_detail_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({
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
      ]),
    });
    await Prefs().initPrefs();
  });

  testWidgets('shows Audio settings inside the built-in OpenAI provider only',
      (tester) async {
    await _pumpProvider(tester, 'openai');

    expect(find.text('OpenAI Audio'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'TTS model'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'TTS voice'), findsOneWidget);

    await _pumpProvider(tester, 'claude');

    expect(find.text('OpenAI Audio'), findsNothing);
    expect(find.widgetWithText(TextField, 'TTS model'), findsNothing);
    expect(find.widgetWithText(TextField, 'TTS voice'), findsNothing);
  });

  testWidgets('saves Audio model and voice on the OpenAI provider',
      (tester) async {
    await _pumpProvider(tester, 'openai');

    await tester.enterText(
      find.byKey(const Key('ai-provider-tts-model')),
      'new-tts-model',
    );
    await tester.enterText(
      find.byKey(const Key('ai-provider-tts-voice')),
      'verse',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final openAi = Prefs()
        .getAiProviders()
        .cast<Map<String, dynamic>>()
        .firstWhere((provider) => provider['id'] == 'openai');
    expect(openAi['ttsModel'], 'new-tts-model');
    expect(openAi['ttsVoice'], 'verse');
  });
}

Future<void> _pumpProvider(WidgetTester tester, String providerId) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        home: AiProviderDetailPage(providerId: providerId),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
