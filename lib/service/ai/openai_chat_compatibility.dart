import 'dart:convert';

import 'package:http/http.dart' as http;

/// Request-level compatibility policy for OpenAI's Chat Completions API.
///
/// Keep model/API exceptions here so provider configuration and callers do not
/// need to know about transport-specific capability gaps.
class OpenAiChatCompatibilityPolicy {
  const OpenAiChatCompatibilityPolicy._();

  static bool isOfficialOpenAiEndpoint(String baseUrl) {
    final uri = Uri.tryParse(baseUrl);
    return uri?.host.toLowerCase() == 'api.openai.com';
  }

  static String? effectiveReasoningEffort({
    required Uri endpoint,
    required String model,
    required bool hasFunctionTools,
    required String? configuredReasoningEffort,
  }) {
    if (_requiresNoReasoningForFunctionTools(
      endpoint: endpoint,
      model: model,
      hasFunctionTools: hasFunctionTools,
    )) {
      return configuredReasoningEffort == null
          ? null
          : OpenAiReasoningEffort.none;
    }

    return configuredReasoningEffort;
  }

  static bool _requiresNoReasoningForFunctionTools({
    required Uri endpoint,
    required String model,
    required bool hasFunctionTools,
  }) {
    return hasFunctionTools &&
        endpoint.host.toLowerCase() == 'api.openai.com' &&
        endpoint.path.endsWith('/chat/completions') &&
        RegExp(r'^gpt-5\.6(?:-|$)', caseSensitive: false).hasMatch(model);
  }
}

abstract final class OpenAiReasoningEffort {
  static const none = 'none';
}

/// Applies [OpenAiChatCompatibilityPolicy] immediately before an OpenAI Chat
/// Completions request is sent.
///
/// The current LangChain adapter cannot express `reasoning_effort: "none"`,
/// so the narrow request rewrite lives at its HTTP boundary.
class OpenAiChatCompatibilityClient extends http.BaseClient {
  OpenAiChatCompatibilityClient({http.Client? inner})
      : _inner = inner ?? http.Client();

  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request is http.Request && request.method == 'POST') {
      request.body = _compatibleBody(request.url, request.body);
    }
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}

String _compatibleBody(Uri endpoint, String body) {
  if (endpoint.host.toLowerCase() != 'api.openai.com' ||
      !endpoint.path.endsWith('/chat/completions')) {
    return body;
  }

  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException {
    return body;
  }
  if (decoded is! Map<String, dynamic>) return body;

  final model = decoded['model'];
  final tools = decoded['tools'];
  final reasoningEffort = decoded['reasoning_effort'];
  if (model is! String || reasoningEffort is! String) return body;

  final effectiveReasoningEffort =
      OpenAiChatCompatibilityPolicy.effectiveReasoningEffort(
    endpoint: endpoint,
    model: model,
    hasFunctionTools: tools is List &&
        tools.any(
          (tool) => tool is Map && tool['type'] == 'function',
        ),
    configuredReasoningEffort: reasoningEffort,
  );
  if (effectiveReasoningEffort == reasoningEffort) return body;

  decoded['reasoning_effort'] = effectiveReasoningEffort;
  return jsonEncode(decoded);
}
