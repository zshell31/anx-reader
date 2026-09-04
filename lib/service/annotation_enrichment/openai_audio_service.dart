import 'dart:convert';
import 'dart:typed_data';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/models/ai_provider.dart';
import 'package:anx_reader/service/ai/effective_route.dart';
import 'package:anx_reader/service/ai/langchain_ai_config.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

typedef OpenAiAudioPost = Future<http.Response> Function(
  Uri url, {
  required Map<String, String> headers,
  required Object body,
});

class OpenAiAudioResult {
  final Uint8List bytes;
  final String ipa;
  final String voice;
  final String model;
  final String format;
  final String mimeType;
  final String assetRef;
  final String sha256;

  const OpenAiAudioResult({
    required this.bytes,
    required this.ipa,
    required this.voice,
    required this.model,
    required this.format,
    required this.mimeType,
    required this.assetRef,
    required this.sha256,
  });
}

class OpenAiAudioService {
  final EffectiveAiRoute? Function() resolveRoute;
  final String Function() model;
  final String Function() voice;
  final OpenAiAudioPost post;
  final Uuid uuid;

  OpenAiAudioService({
    EffectiveAiRoute? Function()? resolveRoute,
    String Function()? model,
    String Function()? voice,
    OpenAiAudioPost? post,
    Uuid? uuid,
  })  : resolveRoute = resolveRoute ?? resolveEffectiveAiRouteFromPrefs,
        model = model ?? (() => ''),
        voice = voice ?? (() => ''),
        post = post ?? _post,
        uuid = uuid ?? const Uuid();

  Future<OpenAiAudioResult> generate(String selectedText) async {
    final text = selectedText.trim();
    if (text.isEmpty) throw ArgumentError.value(selectedText, 'selectedText');
    final route = resolveRoute();
    if (route == null || route.config.apiKey.trim().isEmpty) {
      throw StateError('The selected OpenAI provider is not configured.');
    }
    if (route.protocol != AiProtocol.openai ||
        (route.provider != null && route.provider?.id != 'openai')) {
      throw StateError(
          'Audio is available only for the built-in OpenAI provider.');
    }
    final modelOverride = model().trim();
    final voiceOverride = voice().trim();
    final legacyOpenAiProvider = route.provider?.id == 'openai';
    final audioModel = (modelOverride.isNotEmpty
            ? modelOverride
            : route.provider?.ttsModel.trim().isNotEmpty == true
                ? route.provider!.ttsModel.trim()
                : legacyOpenAiProvider
                    ? Prefs().openAiAudioModel
                    : '')
        .trim();
    final audioVoice = (voiceOverride.isNotEmpty
            ? voiceOverride
            : route.provider?.ttsVoice.trim().isNotEmpty == true
                ? route.provider!.ttsVoice.trim()
                : legacyOpenAiProvider
                    ? Prefs().openAiAudioVoice
                    : '')
        .trim();
    if (audioModel.isEmpty || audioVoice.isEmpty) {
      throw StateError('OpenAI Audio model and voice must be configured.');
    }
    final headers = <String, String>{
      ...route.config.headers,
      'Authorization': 'Bearer ${route.config.apiKey}',
      'Content-Type': 'application/json',
    };
    final base = _baseUrl(route.config);
    final responses = await Future.wait([
      post(
        base.resolve('audio/speech'),
        headers: headers,
        body: jsonEncode({
          'model': audioModel,
          'voice': audioVoice,
          'input': text,
          'response_format': 'mp3',
        }),
      ),
      post(
        base.resolve('responses'),
        headers: headers,
        body: jsonEncode({
          'model': route.config.model,
          'store': false,
          'input': [
            {
              'role': 'system',
              'content':
                  'Return only the IPA transcription of the exact supplied text. Preserve word boundaries and punctuation where useful. Do not translate or explain.'
            },
            {'role': 'user', 'content': text},
          ],
        }),
      ),
    ]);
    final speech = responses[0];
    final ipaResponse = responses[1];
    if (speech.statusCode < 200 || speech.statusCode >= 300) {
      throw StateError('OpenAI speech failed: HTTP ${speech.statusCode}.');
    }
    if (ipaResponse.statusCode < 200 || ipaResponse.statusCode >= 300) {
      throw StateError('OpenAI IPA failed: HTTP ${ipaResponse.statusCode}.');
    }
    final bytes = speech.bodyBytes;
    if (bytes.isEmpty) throw StateError('OpenAI returned empty audio.');
    final ipa = _responseText(ipaResponse.body);
    if (ipa.isEmpty) throw StateError('OpenAI returned empty IPA.');
    final filename = '${uuid.v4()}.mp3';
    return OpenAiAudioResult(
      bytes: bytes,
      ipa: ipa,
      voice: audioVoice,
      model: audioModel,
      format: 'mp3',
      mimeType: 'audio/mpeg',
      assetRef: 'annotation-assets/audio/$filename',
      sha256: sha256.convert(bytes).toString(),
    );
  }
}

bool selectedAiProviderSupportsOpenAiAudio() {
  final rawProviders = Prefs().getAiProviders();
  if (rawProviders.isEmpty) {
    return Prefs().selectedAiService == 'openai';
  }
  try {
    final providers = rawProviders
        .map((json) => AiProvider.fromJson(json as Map<String, dynamic>))
        .toList();
    final selectedId = Prefs().selectedAiService;
    final selected =
        providers.where((item) => item.id == selectedId).firstOrNull ??
            providers.where((item) => item.enabled).firstOrNull;
    return selected?.enabled == true &&
        selected?.id == 'openai' &&
        selected?.protocol == AiProtocol.openai;
  } catch (_) {
    return false;
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}

Uri _baseUrl(LangchainAiConfig config) {
  final raw = config.baseUrl?.trim();
  final value = raw == null || raw.isEmpty ? 'https://api.openai.com/v1/' : raw;
  return Uri.parse(value.endsWith('/') ? value : '$value/');
}

String _responseText(String body) {
  final payload = jsonDecode(body);
  if (payload is! Map) return '';
  final output = payload['output'];
  if (output is! List) return '';
  for (final item in output.whereType<Map>()) {
    final content = item['content'];
    if (content is! List) continue;
    for (final part in content.whereType<Map>()) {
      if (part['type'] == 'output_text' && part['text'] is String) {
        return (part['text'] as String).trim();
      }
    }
  }
  return '';
}

Future<http.Response> _post(
  Uri url, {
  required Map<String, String> headers,
  required Object body,
}) =>
    http.post(url, headers: headers, body: body);
