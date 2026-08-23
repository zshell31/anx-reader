import 'package:flutter/services.dart';

const String androidProcessTextChannelName =
    'com.anxcye.anx_reader/process_text';

class ProcessTextHandler {
  const ProcessTextHandler({
    required this.label,
    required this.packageName,
    required this.activityName,
    required this.componentName,
  });

  factory ProcessTextHandler.fromMap(Map<Object?, Object?> map) {
    return ProcessTextHandler(
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

enum ProcessTextLaunchStatus {
  launched,
  handlerUnavailable,
  noHandlers,
  failed,
}

abstract interface class ProcessTextGateway {
  Future<List<ProcessTextHandler>> listHandlers();

  Future<ProcessTextLaunchStatus> launch({
    required String text,
    String? componentName,
  });

  Future<bool> isPackageInstalled(String packageName);

  Future<bool> copyText({
    required String text,
    required String message,
  });
}

class MethodChannelProcessTextGateway implements ProcessTextGateway {
  const MethodChannelProcessTextGateway({
    MethodChannel channel = const MethodChannel(androidProcessTextChannelName),
  }) : _channel = channel;

  final MethodChannel _channel;

  @override
  Future<List<ProcessTextHandler>> listHandlers() async {
    final result = await _channel.invokeListMethod<Object?>('listHandlers');
    return (result ?? const <Object?>[])
        .map((entry) => ProcessTextHandler.fromMap(
              Map<Object?, Object?>.from(entry! as Map),
            ))
        .toList(growable: false);
  }

  @override
  Future<ProcessTextLaunchStatus> launch({
    required String text,
    String? componentName,
  }) async {
    final result = await _channel.invokeMethod<String>('launch', {
      'text': text,
      if (componentName != null) 'componentName': componentName,
    });
    return switch (result) {
      'launched' => ProcessTextLaunchStatus.launched,
      'handlerUnavailable' => ProcessTextLaunchStatus.handlerUnavailable,
      'noHandlers' => ProcessTextLaunchStatus.noHandlers,
      _ => ProcessTextLaunchStatus.failed,
    };
  }

  @override
  Future<bool> isPackageInstalled(String packageName) async {
    return await _channel.invokeMethod<bool>(
          'isPackageInstalled',
          {'packageName': packageName},
        ) ??
        false;
  }

  @override
  Future<bool> copyText({
    required String text,
    required String message,
  }) async {
    return await _channel.invokeMethod<bool>('copyText', {
          'text': text,
          'message': message,
        }) ??
        false;
  }
}
