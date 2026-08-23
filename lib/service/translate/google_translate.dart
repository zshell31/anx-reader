import 'dart:convert';

import 'package:anx_reader/enums/lang_list.dart';
import 'package:anx_reader/service/translate/index.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

const googleTranslateEndpoint =
    'https://translate.googleapis.com/translate_a/single';

class GoogleTranslateProvider extends TranslateServiceProvider {
  GoogleTranslateProvider({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  @override
  TranslateService get service => TranslateService.googleWeb;

  @override
  String getLabel(BuildContext context) => 'Google Translate';

  @override
  String mapLanguageCode(LangListEnum lang) =>
      lang == LangListEnum.auto ? 'auto' : lang.code;

  @override
  Widget translate(
    String text,
    LangListEnum from,
    LangListEnum to, {
    String? contextText,
    bool isFullText = false,
  }) {
    return convertStreamToWidget(translateStream(text, from, to));
  }

  @override
  Stream<String> translateStream(
    String text,
    LangListEnum from,
    LangListEnum to, {
    String? contextText,
    bool isFullText = false,
  }) async* {
    // Keep this selection-only provider out of full-text translation flows.
    if (isFullText) {
      yield '...';
      return;
    }

    try {
      yield '...';

      // This endpoint is undocumented and unsupported by Google, so its
      // availability and response shape may change without notice.
      final response = await _dio.get<dynamic>(
        googleTranslateEndpoint,
        queryParameters: <String, dynamic>{
          'client': 'gtx',
          'sl': mapLanguageCode(from),
          'tl': mapLanguageCode(to),
          'dt': 't',
          'q': text,
        },
      );

      if (response.statusCode != 200) {
        throw GoogleTranslateException(_messageForStatus(response.statusCode));
      }

      yield parseGoogleTranslateResponse(response.data);
    } on GoogleTranslateException catch (error) {
      AnxLog.severe('Google Translate failed: ${error.message}');
      yield* Stream<String>.error(error);
    } on DioException catch (error) {
      final statusCode = error.response?.statusCode;
      AnxLog.severe(
        'Google Translate request failed: '
        'status=${statusCode ?? 'network'}, type=${error.type.name}',
      );
      yield* Stream<String>.error(
        GoogleTranslateException(_messageForStatus(statusCode)),
      );
    } catch (error) {
      AnxLog.severe(
        'Google Translate returned an invalid response: ${error.runtimeType}',
      );
      yield* Stream<String>.error(
        const GoogleTranslateException(
          'Google Translate returned an unexpected response.',
        ),
      );
    }
  }

  String _messageForStatus(int? statusCode) {
    switch (statusCode) {
      case null:
        return 'Unable to reach Google Translate. Check your network connection.';
      case 403:
        return 'Google Translate denied the request (HTTP 403). Please try again later.';
      case 429:
        return 'Google Translate rate limit reached (HTTP 429). Please try again later.';
      default:
        return 'Google Translate request failed (HTTP $statusCode). Please try again.';
    }
  }
}

String parseGoogleTranslateResponse(dynamic responseData) {
  dynamic decoded = responseData;
  if (decoded is String) {
    try {
      decoded = jsonDecode(decoded);
    } on FormatException {
      throw const GoogleTranslateException(
        'Google Translate returned an unexpected response.',
      );
    }
  }

  final segments = decoded is List && decoded.isNotEmpty ? decoded.first : null;
  if (segments is! List) {
    throw const GoogleTranslateException(
      'Google Translate returned an unexpected response.',
    );
  }

  final translation = StringBuffer();
  for (final segment in segments) {
    if (segment is! List || segment.isEmpty) continue;
    final translatedText = segment.first;
    if (translatedText is String && translatedText.isNotEmpty) {
      translation.write(translatedText);
    }
  }

  if (translation.isEmpty) {
    throw const GoogleTranslateException(
      'Google Translate returned an unexpected response.',
    );
  }
  return translation.toString();
}

class GoogleTranslateException implements Exception {
  const GoogleTranslateException(this.message);

  final String message;

  @override
  String toString() => message;
}
