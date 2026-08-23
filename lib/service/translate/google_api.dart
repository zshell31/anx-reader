import 'package:anx_reader/enums/lang_list.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/service/config/config_item.dart';
import 'package:anx_reader/service/translate/index.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:anx_reader/config/shared_preference_provider.dart';

const googleTranslationApiEndpoint =
    'https://translation.googleapis.com/language/translate/v2';

class GoogleApiTranslateProvider extends TranslateServiceProvider {
  GoogleApiTranslateProvider({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  @override
  TranslateService get service => TranslateService.googleApi;

  @override
  String getLabel(BuildContext context) =>
      L10n.of(context).translateGoogleCloud;

  @override
  Widget translate(
    String text,
    LangListEnum from,
    LangListEnum to, {
    String? contextText,
    bool isFullText = false,
  }) {
    return convertStreamToWidget(
      translateStream(text, from, to, contextText: contextText),
    );
  }

  @override
  Stream<String> translateStream(
    String text,
    LangListEnum from,
    LangListEnum to, {
    String? contextText,
    bool isFullText = false,
  }) =>
      _translateStream(text, from, to, getConfig());

  @override
  Stream<String> translateStreamForRoute(
    String text,
    LangListEnum from,
    LangListEnum to, {
    String? contextText,
    bool isFullText = false,
    Object? routeSnapshot,
  }) =>
      _translateStream(text, from, to, routeSnapshot! as Map<String, dynamic>);

  Stream<String> _translateStream(
    String text,
    LangListEnum from,
    LangListEnum to,
    Map<String, dynamic> config,
  ) async* {
    final apiKey = config['api_key']?.toString().trim() ?? '';

    if (apiKey.isEmpty) {
      yield* Stream.error(const GoogleApiTranslationException(
        'Configure a Google Cloud Translation API key in translation settings.',
      ));
      return;
    }

    try {
      yield "...";

      final body = <String, dynamic>{
        'q': text,
        'target': mapLanguageCode(to),
        'format': 'text',
      };

      if (from != LangListEnum.auto) {
        body['source'] = mapLanguageCode(from);
      }

      final response = await _dio.post<dynamic>(
        googleTranslationApiEndpoint,
        data: body,
        options: Options(
          headers: <String, String>{
            Headers.contentTypeHeader: Headers.jsonContentType,
            'X-Goog-Api-Key': apiKey,
          },
        ),
      );

      if (response.statusCode == 200) {
        yield parseGoogleTranslationResponse(response.data);
      } else {
        throw GoogleApiTranslationException(
          _messageForStatus(response.statusCode),
        );
      }
    } on GoogleApiTranslationException catch (error) {
      AnxLog.severe('Google Cloud translation failed: ${error.message}');
      yield* Stream.error(error);
    } on DioException catch (error) {
      final statusCode = error.response?.statusCode;
      final message = statusCode == null
          ? 'Unable to reach Google Cloud Translation. Check your network connection.'
          : _messageForStatus(statusCode);
      AnxLog.severe(
        'Google Cloud translation request failed: '
        'status=${statusCode ?? 'network'}, type=${error.type.name}',
      );
      yield* Stream.error(GoogleApiTranslationException(message));
    } catch (error) {
      AnxLog.severe(
        'Google Cloud translation returned an invalid response: '
        '${error.runtimeType}',
      );
      yield* Stream.error(const GoogleApiTranslationException(
        'Google Cloud Translation returned an unexpected response.',
      ));
    }
  }

  String _messageForStatus(int? statusCode) {
    switch (statusCode) {
      case 400:
        return 'Google Cloud Translation rejected the request. Check the selected languages.';
      case 403:
        return 'Google Cloud Translation denied the request. Check that the API key is valid, the API is enabled, and quota is available.';
      default:
        return 'Google Cloud Translation request failed${statusCode == null ? '' : ' (HTTP $statusCode)'}. Please try again.';
    }
  }

  @override
  List<ConfigItem> getConfigItems(BuildContext context) {
    return [
      ConfigItem(
        key: 'tip',
        label: L10n.of(context).translateTip,
        type: ConfigItemType.tip,
        defaultValue: L10n.of(context).translateGoogleHelpText,
        link: 'https://anx.anxcye.com/docs/translate/google',
      ),
      ConfigItem(
        key: 'api_key',
        label: 'API Key',
        description: L10n.of(context).translateGoogleApiKeyDescription,
        type: ConfigItemType.password,
        defaultValue: '',
      ),
    ];
  }

  @override
  Map<String, dynamic> getConfig() {
    final config = Prefs().getTranslateServiceConfig(service);
    return config ?? {'api_key': ''};
  }

  @override
  void saveConfig(Map<String, dynamic> config) {
    Prefs().saveTranslateServiceConfig(service, config);
  }
}

String parseGoogleTranslationResponse(dynamic responseData) {
  if (responseData is! Map) {
    throw const GoogleApiTranslationException(
      'Google Cloud Translation returned an unexpected response.',
    );
  }

  final data = responseData['data'];
  final translations = data is Map ? data['translations'] : null;
  final first = translations is List && translations.isNotEmpty
      ? translations.first
      : null;
  final translatedText = first is Map ? first['translatedText'] : null;

  if (translatedText is! String || translatedText.isEmpty) {
    throw const GoogleApiTranslationException(
      'Google Cloud Translation returned an unexpected response.',
    );
  }

  return translatedText;
}

class GoogleApiTranslationException implements Exception {
  const GoogleApiTranslationException(this.message);

  final String message;

  @override
  String toString() => message;
}
