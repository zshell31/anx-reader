import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/enums/lang_list.dart';
import 'package:anx_reader/main.dart';
import 'package:anx_reader/service/ai/prompt_generate.dart';
import 'package:anx_reader/service/ai/index.dart';
import 'package:anx_reader/service/ai/effective_route.dart';
import 'package:anx_reader/service/config/config_item.dart';
import 'package:anx_reader/service/translate/index.dart';
import 'package:anx_reader/widgets/ai/ai_stream.dart';
import 'package:flutter/material.dart';

class AiTranslateProvider extends TranslateServiceProvider {
  @override
  TranslateService get service => TranslateService.ai;

  @override
  String getLabel(BuildContext context) => L10n.of(context).navBarAI;

  /// AI translation uses native language names (e.g., "简体中文", "English")
  /// instead of ISO codes for better prompt understanding.
  @override
  String mapLanguageCode(LangListEnum lang) => lang.nativeName;

  @override
  Widget translate(
    String text,
    LangListEnum from,
    LangListEnum to, {
    String? contextText,
    bool isFullText = false,
  }) {
    final prompt = isFullText
        ? generatePromptFullTextTranslate(
            text,
            mapLanguageCode(to),
            mapLanguageCode(from),
            contextText: contextText,
          )
        : generatePromptTranslate(
            text,
            mapLanguageCode(to),
            mapLanguageCode(from),
            contextText: contextText,
          );

    return AiStream(
      prompt: prompt,
      regenerate: true,
    );
  }

  @override
  Object captureRouteSnapshot() =>
      EffectiveAiRouteSnapshot(resolveEffectiveAiRouteFromPrefs());

  @override
  Stream<String> translateStream(
    String text,
    LangListEnum from,
    LangListEnum to, {
    String? contextText,
    bool isFullText = false,
  }) async* {
    yield* translateStreamForRoute(
      text,
      from,
      to,
      contextText: contextText,
      isFullText: isFullText,
      routeSnapshot:
          EffectiveAiRouteSnapshot(resolveEffectiveAiRouteFromPrefs()),
    );
  }

  @override
  Stream<String> translateStreamForRoute(
    String text,
    LangListEnum from,
    LangListEnum to, {
    String? contextText,
    bool isFullText = false,
    Object? routeSnapshot,
  }) async* {
    try {
      final payload = isFullText
          ? generatePromptFullTextTranslate(
              text,
              mapLanguageCode(to),
              mapLanguageCode(from),
              contextText: contextText,
            )
          : generatePromptTranslate(
              text,
              mapLanguageCode(to),
              mapLanguageCode(from),
              contextText: contextText,
            );

      final messages = payload.buildMessages();

      await for (final result in aiGenerateStreamWithRoute(
        messages,
        (routeSnapshot! as EffectiveAiRouteSnapshot).route,
      )) {
        yield result;
      }
    } catch (e) {
      yield* Stream<String>.error(Exception(
          L10n.of(navigatorKey.currentContext!).translateError + e.toString()));
    }
  }

  @override
  List<ConfigItem> getConfigItems(BuildContext context) {
    return [
      ConfigItem(
        key: 'tip',
        label: 'Tip',
        type: ConfigItemType.tip,
        defaultValue:
            L10n.of(navigatorKey.currentContext!).settingsTranslateAiTip,
      ),
    ];
  }
}
