import 'dart:convert';

import 'package:anx_reader/models/full_text_translation_cache.dart';
import 'package:anx_reader/service/ai/effective_route.dart';
import 'package:anx_reader/service/translate/index.dart';

String buildProviderFingerprint(
  TranslateService service, {
  Object? routeSnapshot,
}) {
  final provider = service.provider;
  final effectiveRoute = routeSnapshot ?? provider.captureRouteSnapshot();
  final route = switch (service) {
    TranslateService.ai =>
      _aiRoute((effectiveRoute! as EffectiveAiRouteSnapshot).route),
    TranslateService.googleApi => <String, Object?>{
        'protocol': 'google_translation_v2',
        'endpoint': 'https://translation.googleapis.com/language/translate/v2',
      },
    TranslateService.microsoftApi => <String, Object?>{
        'protocol': 'microsoft_translation_v3',
        'endpoint': 'https://api.cognitive.microsofttranslator.com/translate',
        'region':
            (effectiveRoute! as Map<String, dynamic>)['region']?.toString() ??
                'global',
      },
    TranslateService.deepl => <String, Object?>{
        'protocol': 'deepl_v2',
        'endpoint': _sanitizeEndpoint(
          (effectiveRoute! as Map<String, dynamic>)['api_url']?.toString() ??
              'https://api-free.deepl.com/v2/translate',
        ),
      },
    TranslateService.bingWeb || TranslateService.googleWeb => <String, Object?>{
        'uncacheable': service.name
      },
  };
  return sha256Text(_canonicalJson(route));
}

Map<String, Object?> _aiRoute(EffectiveAiRoute? route) {
  if (route == null) return <String, Object?>{'protocol': 'unconfigured_ai'};
  final config = route.config;
  return <String, Object?>{
    'protocol': route.protocol.code,
    'endpoint': _sanitizeEndpoint(config.baseUrl ?? ''),
    'model': config.model,
    'reasoningEffort': config.reasoningEffort.code,
    'temperature': config.temperature,
    'topP': config.topP,
    'maxTokens': config.maxTokens,
    'maxOutputTokens': config.maxOutputTokens,
    'headers': _sanitizeOptions(config.headers),
    'additional': _sanitizeOptions(config.additional),
  };
}

String _sanitizeEndpoint(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null || !uri.hasScheme) return raw.trim().split('?').first;
  return uri
      .replace(
        userInfo: '',
        query: '',
        fragment: '',
      )
      .toString()
      .replaceFirst(RegExp(r'/$'), '');
}

Object? _sanitizeOptions(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return <String, Object?>{
      for (final key in keys)
        if (!_secretKey.hasMatch(key)) key: _sanitizeOptions(value[key]),
    };
  }
  if (value is List) return value.map(_sanitizeOptions).toList();
  return value;
}

final RegExp _secretKey = RegExp(
  r'(api.?key|authorization|cookie|password|secret|token)',
  caseSensitive: false,
);

String _canonicalJson(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return jsonEncode(<String, Object?>{
      for (final key in keys) key: value[key],
    });
  }
  return jsonEncode(value);
}
