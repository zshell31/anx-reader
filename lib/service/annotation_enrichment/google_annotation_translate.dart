import 'dart:convert';

import 'package:http/http.dart' as http;

const googleAnnotationTranslateBaseUrl =
    'https://translate.googleapis.com/translate_a/single';

class GoogleAnnotationTranslation {
  final String text;
  final String? detectedLanguage;

  const GoogleAnnotationTranslation({
    required this.text,
    this.detectedLanguage,
  });
}

String normalizeAnnotationTranslationText(String text) =>
    text.replaceAll(RegExp(r'\s+'), ' ').trim();

Uri googleAnnotationTranslateUri(
  String text, {
  required String targetLanguage,
  String baseUrl = googleAnnotationTranslateBaseUrl,
}) =>
    Uri.parse(baseUrl).replace(queryParameters: {
      'client': 'gtx',
      'sl': 'auto',
      'tl': targetLanguage,
      'dt': 't',
      'q': normalizeAnnotationTranslationText(text),
    });

GoogleAnnotationTranslation parseGoogleAnnotationTranslation(Object? payload) {
  if (payload is! List || payload.isEmpty || payload.first is! List) {
    throw const FormatException(
      'Google Translate returned an unknown response format.',
    );
  }
  final segments = payload.first as List;
  final translation = segments
      .map((segment) =>
          segment is List && segment.isNotEmpty && segment.first is String
              ? segment.first as String
              : '')
      .join()
      .trim();
  if (translation.isEmpty) {
    throw const FormatException('Google Translate returned an empty result.');
  }
  return GoogleAnnotationTranslation(
    text: translation,
    detectedLanguage: payload.length > 2 && payload[2] is String
        ? payload[2] as String
        : null,
  );
}

class GoogleAnnotationTranslateService {
  final http.Client client;
  final Duration timeout;
  final String baseUrl;

  GoogleAnnotationTranslateService({
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
    this.baseUrl = googleAnnotationTranslateBaseUrl,
  }) : client = client ?? http.Client();

  Future<GoogleAnnotationTranslation> translate(
    String text, {
    required String targetLanguage,
  }) async {
    final response = await client.get(
      googleAnnotationTranslateUri(
        text,
        targetLanguage: targetLanguage,
        baseUrl: baseUrl,
      ),
      headers: const {'Accept': 'application/json'},
    ).timeout(timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'Google Translate request failed with HTTP ${response.statusCode}.',
      );
    }
    return parseGoogleAnnotationTranslation(jsonDecode(response.body));
  }
}

class HttpException implements Exception {
  final String message;

  const HttpException(this.message);

  @override
  String toString() => message;
}
