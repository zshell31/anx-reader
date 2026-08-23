import 'dart:io';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:flutter/services.dart';

const String externalDictionaryChannelName =
    'com.anxcye.anx_reader/external_dictionary';

class ExternalDictionaryHandler {
  const ExternalDictionaryHandler({
    required this.label,
    required this.packageName,
    required this.activityName,
    required this.componentName,
  });

  factory ExternalDictionaryHandler.fromMap(Map<Object?, Object?> map) {
    return ExternalDictionaryHandler(
      label: map['label']! as String,
      packageName: map['packageName']! as String,
      activityName: map['activityName']! as String,
      componentName: map['componentName']! as String,
    );
  }

  final String label;
  final String packageName;
  final String activityName;
  final String componentName;
}

enum DictionaryLaunchStatus {
  launched,
  handlerUnavailable,
  noHandlers,
  failed,
}

enum DictionaryLookupStatus {
  launched,
  noHandlers,
  unsupported,
  failed,
}

abstract interface class ExternalDictionaryGateway {
  Future<List<ExternalDictionaryHandler>> listHandlers();

  Future<DictionaryLaunchStatus> launch({
    required String text,
    String? componentName,
  });
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

class MethodChannelExternalDictionaryGateway
    implements ExternalDictionaryGateway {
  const MethodChannelExternalDictionaryGateway({
    MethodChannel channel = const MethodChannel(externalDictionaryChannelName),
  }) : _channel = channel;

  final MethodChannel _channel;

  @override
  Future<List<ExternalDictionaryHandler>> listHandlers() async {
    final result = await _channel.invokeListMethod<Object?>('listHandlers');
    return (result ?? const <Object?>[])
        .map((entry) => ExternalDictionaryHandler.fromMap(
              Map<Object?, Object?>.from(entry! as Map),
            ))
        .toList(growable: false);
  }

  @override
  Future<DictionaryLaunchStatus> launch({
    required String text,
    String? componentName,
  }) async {
    final result = await _channel.invokeMethod<String>('launch', {
      'text': text,
      if (componentName != null) 'componentName': componentName,
    });
    return switch (result) {
      'launched' => DictionaryLaunchStatus.launched,
      'handlerUnavailable' => DictionaryLaunchStatus.handlerUnavailable,
      'noHandlers' => DictionaryLaunchStatus.noHandlers,
      _ => DictionaryLaunchStatus.failed,
    };
  }
}

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
