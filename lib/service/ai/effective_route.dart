import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/models/ai_provider.dart';
import 'package:anx_reader/service/ai/ai_key_rotator.dart';
import 'package:anx_reader/service/ai/langchain_ai_config.dart';

class EffectiveAiRoute {
  const EffectiveAiRoute({
    required this.config,
    required this.protocol,
    this.provider,
    this.providers = const <AiProvider>[],
  });

  final LangchainAiConfig config;
  final AiProtocol protocol;
  final AiProvider? provider;
  final List<AiProvider> providers;
}

class EffectiveAiRouteSnapshot {
  const EffectiveAiRouteSnapshot(this.route);

  final EffectiveAiRoute? route;
}

/// Resolves the preference-backed route used by full-text AI translation.
/// Both request execution and cache fingerprinting call this resolver so their
/// effective routing rules cannot drift apart.
EffectiveAiRoute? resolveEffectiveAiRouteFromPrefs({String? identifier}) {
  final rawProviders = Prefs().getAiProviders();
  if (rawProviders.isNotEmpty) {
    final providers = rawProviders
        .map((json) => AiProvider.fromJson(json as Map<String, dynamic>))
        .toList();
    AiProvider? provider;
    if (identifier != null) {
      provider = providers.where((item) => item.id == identifier).firstOrNull;
    } else {
      final selectedId = Prefs().selectedAiService;
      provider = providers.where((item) => item.id == selectedId).firstOrNull;
      provider ??= providers.where((item) => item.enabled).firstOrNull;
    }
    if (provider != null &&
        provider.enabled &&
        AiKeyRotator.hasValidKey(provider)) {
      final apiKey = AiKeyRotator.getNextKey(provider);
      if (apiKey != null) {
        return EffectiveAiRoute(
          config: LangchainAiConfig.fromProvider(
            providerId: provider.id,
            model: provider.model,
            apiKey: apiKey,
            url: provider.url,
            reasoningEffort: provider.reasoningEffort,
          ),
          protocol: provider.protocol,
          provider: provider,
          providers: providers,
        );
      }
    }
  }

  final selectedIdentifier = identifier ?? Prefs().selectedAiService;
  final savedConfig = Prefs().getAiConfig(selectedIdentifier);
  if (savedConfig.isEmpty) return null;
  return EffectiveAiRoute(
    config: LangchainAiConfig.fromPrefs(selectedIdentifier, savedConfig),
    protocol: _legacyProtocol(selectedIdentifier),
  );
}

AiProtocol _legacyProtocol(String identifier) => switch (identifier) {
      'claude' => AiProtocol.claude,
      'gemini' => AiProtocol.gemini,
      _ => AiProtocol.openai,
    };

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
