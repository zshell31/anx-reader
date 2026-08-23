import 'dart:io';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/service/android/process_text.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:flutter/services.dart';

typedef ExternalDictionaryHandler = ProcessTextHandler;
typedef ExternalDictionaryGateway = ProcessTextGateway;
typedef DictionaryLaunchStatus = ProcessTextLaunchStatus;

enum DictionaryLookupStatus {
  launched,
  noHandlers,
  unsupported,
  failed,
}

abstract interface class ExternalDictionaryPreferenceStore {
  String? get preferredComponent;

  set preferredComponent(String? value);
}

class PrefsExternalDictionaryPreferenceStore
    implements ExternalDictionaryPreferenceStore {
  @override
  String? get preferredComponent => Prefs().externalDictionaryComponent;

  @override
  set preferredComponent(String? value) {
    Prefs().externalDictionaryComponent = value;
  }
}

typedef MethodChannelExternalDictionaryGateway
    = MethodChannelProcessTextGateway;

class ExternalDictionaryService {
  ExternalDictionaryService({
    ExternalDictionaryGateway? gateway,
    ExternalDictionaryPreferenceStore? preferences,
    bool? isAndroid,
  })  : _gateway = gateway ?? const MethodChannelExternalDictionaryGateway(),
        _preferences = preferences ?? PrefsExternalDictionaryPreferenceStore(),
        _isAndroid = isAndroid ?? Platform.isAndroid;

  final ExternalDictionaryGateway _gateway;
  final ExternalDictionaryPreferenceStore _preferences;
  final bool _isAndroid;

  bool get isSupported => _isAndroid;

  String? get preferredComponent => _preferences.preferredComponent;

  set preferredComponent(String? value) {
    _preferences.preferredComponent = value;
  }

  Future<List<ExternalDictionaryHandler>> listHandlers() async {
    if (!_isAndroid) return const [];

    final handlers = await _gateway.listHandlers();
    final preferred = preferredComponent;
    if (preferred != null &&
        !handlers.any((handler) => handler.componentName == preferred)) {
      AnxLog.info('External dictionary: configured handler unavailable');
      preferredComponent = null;
    }
    return handlers;
  }

  Future<DictionaryLookupStatus> lookup(String selectedText) async {
    if (!_isAndroid) return DictionaryLookupStatus.unsupported;

    try {
      AnxLog.info('External dictionary: action invoked');
      final handlers = await listHandlers();
      if (handlers.isEmpty) {
        AnxLog.info('External dictionary: no handlers installed');
        return DictionaryLookupStatus.noHandlers;
      }

      final preferred = preferredComponent;
      if (preferred != null) {
        final handler = handlers
            .where((handler) => handler.componentName == preferred)
            .firstOrNull;
        if (handler != null) {
          AnxLog.info(
            'External dictionary: launching ${handler.componentName}',
          );
          final result = await _gateway.launch(
            text: selectedText,
            componentName: handler.componentName,
          );
          if (result == DictionaryLaunchStatus.launched) {
            return DictionaryLookupStatus.launched;
          }
          if (result != DictionaryLaunchStatus.handlerUnavailable) {
            return _lookupStatusFor(result);
          }
          AnxLog.info('External dictionary: preferred handler disappeared');
          preferredComponent = null;
        }
      }

      final result = await _gateway.launch(text: selectedText);
      return _lookupStatusFor(result);
    } on PlatformException catch (error) {
      AnxLog.warning(
        'External dictionary: platform failure (${error.code})',
      );
      return DictionaryLookupStatus.failed;
    } catch (error) {
      AnxLog.warning('External dictionary: launch failure ($error)');
      return DictionaryLookupStatus.failed;
    }
  }

  DictionaryLookupStatus _lookupStatusFor(DictionaryLaunchStatus status) {
    return switch (status) {
      DictionaryLaunchStatus.launched => DictionaryLookupStatus.launched,
      DictionaryLaunchStatus.noHandlers => DictionaryLookupStatus.noHandlers,
      DictionaryLaunchStatus.handlerUnavailable ||
      DictionaryLaunchStatus.failed =>
        DictionaryLookupStatus.failed,
    };
  }
}
