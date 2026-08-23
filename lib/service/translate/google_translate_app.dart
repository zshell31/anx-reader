import 'dart:io';

import 'package:anx_reader/service/android/process_text.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:flutter/services.dart';

const String googleTranslatePackageName = 'com.google.android.apps.translate';
const String googleTranslateTapToTranslateMessage =
    "Text copied. Use Google Translate's Tap to Translate.";

enum GoogleTranslateAppStatus {
  launched,
  clipboardFallback,
  notInstalled,
  unsupported,
  failed,
}

class GoogleTranslateAppService {
  GoogleTranslateAppService({
    ProcessTextGateway? gateway,
    bool? isAndroid,
  })  : _gateway = gateway ?? const MethodChannelProcessTextGateway(),
        _isAndroid = isAndroid ?? Platform.isAndroid;

  final ProcessTextGateway _gateway;
  final bool _isAndroid;

  bool get isSupported => _isAndroid;

  Future<GoogleTranslateAppStatus> translate(String selectedText) async {
    if (!_isAndroid) return GoogleTranslateAppStatus.unsupported;

    try {
      if (!await _gateway.isPackageInstalled(googleTranslatePackageName)) {
        AnxLog.info('Google Translate app: package not installed');
        return GoogleTranslateAppStatus.notInstalled;
      }

      final handlers = (await _gateway.listHandlers())
          .where(
            (handler) => handler.packageName == googleTranslatePackageName,
          )
          .toList(growable: false)
        ..sort((a, b) => a.componentName.compareTo(b.componentName));

      if (handlers.isEmpty) {
        AnxLog.info('Google Translate app: PROCESS_TEXT handler unavailable');
        return _copyForTapToTranslate(selectedText);
      }

      if (handlers.length > 1) {
        AnxLog.info(
          'Google Translate app: multiple PROCESS_TEXT handlers found; '
          'using ${handlers.first.componentName} from '
          '${handlers.map((handler) => handler.componentName).join(', ')}',
        );
      } else {
        AnxLog.info(
          'Google Translate app: PROCESS_TEXT handler discovered '
          '(${handlers.single.componentName})',
        );
      }

      final launchStatus = await _gateway.launch(
        text: selectedText,
        componentName: handlers.first.componentName,
      );
      if (launchStatus == ProcessTextLaunchStatus.launched) {
        AnxLog.info(
          'Google Translate app: launch succeeded '
          '(${handlers.first.componentName})',
        );
        return GoogleTranslateAppStatus.launched;
      }
      if (launchStatus == ProcessTextLaunchStatus.handlerUnavailable ||
          launchStatus == ProcessTextLaunchStatus.noHandlers) {
        AnxLog.info(
          'Google Translate app: PROCESS_TEXT handler became unavailable',
        );
        return _copyForTapToTranslate(selectedText);
      }

      AnxLog.warning('Google Translate app: launch failed');
      return GoogleTranslateAppStatus.failed;
    } on PlatformException catch (error) {
      AnxLog.warning(
        'Google Translate app: platform failure (${error.code})',
      );
      return GoogleTranslateAppStatus.failed;
    } catch (error) {
      AnxLog.warning('Google Translate app: integration failure ($error)');
      return GoogleTranslateAppStatus.failed;
    }
  }

  Future<GoogleTranslateAppStatus> _copyForTapToTranslate(
    String selectedText,
  ) async {
    final copied = await _gateway.copyText(
      text: selectedText,
      message: googleTranslateTapToTranslateMessage,
    );
    if (!copied) {
      AnxLog.warning('Google Translate app: clipboard fallback failed');
      return GoogleTranslateAppStatus.failed;
    }
    AnxLog.info('Google Translate app: clipboard fallback used');
    return GoogleTranslateAppStatus.clipboardFallback;
  }
}
