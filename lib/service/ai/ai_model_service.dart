import 'dart:convert';
import 'package:http/http.dart' as http;

/// Models documented for POST /audio/speech, not transcription or Realtime.
/// https://developers.openai.com/api/reference/resources/audio/subresources/speech/methods/create
const openAiSpeechModels = {
  'tts-1',
  'tts-1-hd',
  'gpt-4o-mini-tts',
  'gpt-4o-mini-tts-2025-12-15',
};

/// Fetches the list of available model IDs from an OpenAI-compatible /models endpoint.
///
/// Returns a sorted list of model ID strings on success, or throws an exception
/// with a descriptive message on failure.
Future<List<String>> fetchAiModels({
  required String url,
  required String apiKey,
  bool ttsOnly = false,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final baseUrl = url.trim();
  final modelsUrl =
      baseUrl.endsWith('/') ? '${baseUrl}models' : '$baseUrl/models';

  final response = await http.get(
    Uri.parse(modelsUrl),
    headers: {
      'Authorization': 'Bearer $apiKey',
      'Content-Type': 'application/json',
    },
  ).timeout(timeout);

  if (response.statusCode != 200) {
    throw Exception('HTTP ${response.statusCode}: ${response.body}');
  }

  final data = jsonDecode(response.body);
  final List<dynamic> models = data['data'] ?? [];

  if (models.isEmpty) {
    return [];
  }

  final ids =
      models.map<String>((m) => (m['id'] ?? m.toString()) as String).toList();
  final filtered = ids
      .where((id) => !ttsOnly || openAiSpeechModels.contains(id))
      .toSet()
      .toList()
    ..sort();
  return filtered;
}
