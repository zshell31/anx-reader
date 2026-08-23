import 'package:anx_reader/enums/lang_list.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/service/config/config_item.dart';
import 'package:anx_reader/service/translate/index.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_language_id/google_mlkit_language_id.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';

const googleTranslateDownloadingModelStatus = 'Downloading translation model…';

abstract class GoogleMlKitClient {
  bool get isSupported;

  Future<String> identifyLanguage(String text);

  Future<bool> isModelDownloaded(String languageCode);

  Future<bool> downloadModel(String languageCode);

  Future<String> translate(
    String text,
    TranslateLanguage source,
    TranslateLanguage target,
  );
}

class NativeGoogleMlKitClient implements GoogleMlKitClient {
  NativeGoogleMlKitClient({OnDeviceTranslatorModelManager? modelManager})
      : _modelManager = modelManager ?? OnDeviceTranslatorModelManager();

  final OnDeviceTranslatorModelManager _modelManager;

  @override
  bool get isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  Future<String> identifyLanguage(String text) async {
    final identifier = LanguageIdentifier(confidenceThreshold: 0.5);
    try {
      return await identifier.identifyLanguage(text);
    } finally {
      await identifier.close();
    }
  }

  @override
  Future<bool> isModelDownloaded(String languageCode) =>
      _modelManager.isModelDownloaded(languageCode);

  @override
  Future<bool> downloadModel(String languageCode) =>
      _modelManager.downloadModel(languageCode);

  @override
  Future<String> translate(
    String text,
    TranslateLanguage source,
    TranslateLanguage target,
  ) async {
    final translator = OnDeviceTranslator(
      sourceLanguage: source,
      targetLanguage: target,
    );
    try {
      return await translator.translateText(text);
    } finally {
      try {
        await translator.close();
      } catch (error) {
        AnxLog.warning(
          'Google ML Kit translator cleanup failed: ${error.runtimeType}',
        );
      }
    }
  }
}

class GoogleTranslateProvider extends TranslateServiceProvider {
  GoogleTranslateProvider({
    GoogleMlKitClient? client,
    this.reliableSourceLanguage,
  }) : _client = client ?? NativeGoogleMlKitClient();

  final GoogleMlKitClient _client;

  /// A concrete book/source language can be supplied by selection flows that
  /// have reliable metadata. The current reader does not persist book language,
  /// so Auto otherwise uses local ML Kit language identification.
  final LangListEnum? reliableSourceLanguage;

  @override
  TranslateService get service => TranslateService.googleWeb;

  @override
  String getLabel(BuildContext context) => 'Google Translate';

  @override
  String mapLanguageCode(LangListEnum lang) {
    if (lang == LangListEnum.auto) return 'auto';
    return mapAnxLanguageToMlKit(lang).bcpCode;
  }

  @override
  List<ConfigItem> getConfigItems(BuildContext context) => <ConfigItem>[
        ConfigItem(
          key: 'on_device_tip',
          label: 'On-device',
          type: ConfigItemType.tip,
          defaultValue:
              'Works offline after the required language models are downloaded.',
        ),
      ];

  @override
  Widget translate(
    String text,
    LangListEnum from,
    LangListEnum to, {
    String? contextText,
    bool isFullText = false,
  }) {
    return _GoogleTranslateResult(
      stream: translateStream(text, from, to, contextText: contextText),
    );
  }

  @override
  Stream<String> translateStream(
    String text,
    LangListEnum from,
    LangListEnum to, {
    String? contextText,
    bool isFullText = false,
  }) async* {
    if (isFullText) {
      yield '...';
      return;
    }

    if (!_client.isSupported) {
      yield* Stream<String>.error(const GoogleTranslateException(
        'On-device Google translation is not supported on this platform.',
      ));
      return;
    }

    try {
      yield '...';
      AnxLog.info('Google ML Kit translation selected');

      final source = await resolveMlKitSourceLanguage(
        configuredSource: from,
        reliableSource: reliableSourceLanguage,
        text: text,
        identifyLanguage: _client.identifyLanguage,
      );
      final target = mapAnxLanguageToMlKit(to, role: 'target');
      AnxLog.info(
        'Google ML Kit translation languages: '
        'source=${source.bcpCode}, target=${target.bcpCode}',
      );

      var showedDownloadStatus = false;
      for (final languageCode in <String>{
        source.bcpCode,
        target.bcpCode,
      }) {
        final installed = await _client.isModelDownloaded(languageCode);
        AnxLog.info(
          'Google ML Kit model $languageCode installed=$installed',
        );
        if (installed) continue;

        if (!showedDownloadStatus) {
          yield googleTranslateDownloadingModelStatus;
          showedDownloadStatus = true;
        }
        AnxLog.info('Google ML Kit model download started: $languageCode');
        try {
          final downloaded = await _client.downloadModel(languageCode);
          if (!downloaded) {
            throw const GoogleTranslateException(
              'Unable to download the translation model. Check your connection and try again.',
            );
          }
          AnxLog.info(
            'Google ML Kit model download succeeded: $languageCode',
          );
        } catch (error) {
          AnxLog.severe(
            'Google ML Kit model download failed: '
            'language=$languageCode, error=${error.runtimeType}',
          );
          if (error is GoogleTranslateException) rethrow;
          throw const GoogleTranslateException(
            'Unable to download the translation model. Check your connection and try again.',
          );
        }
      }

      try {
        final translated = await _client.translate(text, source, target);
        if (translated.trim().isEmpty) {
          throw const GoogleTranslateException(
            'Google Translate returned no translation.',
          );
        }
        AnxLog.info('Google ML Kit translation succeeded');
        yield translated;
      } catch (error) {
        AnxLog.severe(
          'Google ML Kit translation failed: ${error.runtimeType}',
        );
        if (error is GoogleTranslateException) rethrow;
        throw const GoogleTranslateException(
          'Unable to translate this selection on device. Please try again.',
        );
      }
    } on GoogleTranslateException catch (error) {
      AnxLog.severe('Google ML Kit translation stopped: ${error.message}');
      yield* Stream<String>.error(error);
    } on PlatformException catch (error) {
      AnxLog.severe('Google ML Kit platform failure: code=${error.code}');
      yield* Stream<String>.error(const GoogleTranslateException(
        'Unable to use on-device translation. Please try again.',
      ));
    } catch (error) {
      AnxLog.severe(
        'Google ML Kit unexpected failure: ${error.runtimeType}',
      );
      yield* Stream<String>.error(const GoogleTranslateException(
        'Unable to use on-device translation. Please try again.',
      ));
    }
  }
}

Future<TranslateLanguage> resolveMlKitSourceLanguage({
  required LangListEnum configuredSource,
  required LangListEnum? reliableSource,
  required String text,
  required Future<String> Function(String text) identifyLanguage,
}) async {
  if (configuredSource != LangListEnum.auto) {
    return mapAnxLanguageToMlKit(configuredSource, role: 'source');
  }

  if (reliableSource != null && reliableSource != LangListEnum.auto) {
    return mapAnxLanguageToMlKit(reliableSource, role: 'source');
  }

  final identifiedCode = await identifyLanguage(text);
  if (identifiedCode.toLowerCase() == 'und') {
    throw const GoogleTranslateException(
      'The source language could not be identified. Choose it explicitly and try again.',
    );
  }

  final identified = mlKitLanguageForCode(identifiedCode);
  if (identified == null) {
    throw GoogleTranslateException(
      'The identified source language ($identifiedCode) is not supported by on-device translation.',
    );
  }
  return identified;
}

TranslateLanguage mapAnxLanguageToMlKit(
  LangListEnum language, {
  String role = 'language',
}) {
  if (language == LangListEnum.auto) {
    throw GoogleTranslateException(
      'Choose a concrete $role language for on-device translation.',
    );
  }

  final mapped = mlKitLanguageForCode(language.code);
  if (mapped == null) {
    throw GoogleTranslateException(
      '${language.nativeName} is not supported by on-device translation.',
    );
  }
  return mapped;
}

/// Central mapping from Anx/BCP-47 identifiers to ML Kit languages. Regional
/// Chinese variants share ML Kit's single Chinese translation model.
TranslateLanguage? mlKitLanguageForCode(String languageCode) {
  final normalized = languageCode.replaceAll('_', '-').toLowerCase();
  final baseCode = normalized.split('-').first;
  if (baseCode == 'zh') return TranslateLanguage.chinese;
  if (baseCode == 'nb' || baseCode == 'no') {
    return TranslateLanguage.norwegian;
  }

  for (final language in TranslateLanguage.values) {
    if (language.bcpCode == baseCode) return language;
  }
  return null;
}

class _GoogleTranslateResult extends StatelessWidget {
  const _GoogleTranslateResult({required this.stream});

  final Stream<String> stream;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<String>(
      stream: stream,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Text('Error: ${snapshot.error}');
        }

        final value = snapshot.data ?? '...';
        final isStatus =
            value == '...' || value == googleTranslateDownloadingModelStatus;
        if (isStatus) return Text(value);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            SelectableText(value),
            const SizedBox(height: 4),
            Row(
              children: [
                // Current ML Kit guidelines apply the Cloud Translation
                // attribution rules to on-device results. Use Google's
                // unmodified compact official badge adjacent to the result.
                Image.asset(
                  'assets/images/google_translate_attribution.png',
                  height: 14,
                  fit: BoxFit.contain,
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => Clipboard.setData(
                    ClipboardData(text: value),
                  ),
                  child: Text(L10n.of(context).commonCopy),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class GoogleTranslateException implements Exception {
  const GoogleTranslateException(this.message);

  final String message;

  @override
  String toString() => message;
}
