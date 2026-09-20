import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

/// Hash files without copying their contents through the platform channel or
/// blocking the UI isolate. Android's provider uses native SHA acceleration.
class FileDigestService {
  FileDigestService({bool? nativeAndroid})
      : nativeAndroid = nativeAndroid ?? Platform.isAndroid;

  final bool nativeAndroid;
  static const channel = MethodChannel('com.anxcye.anx_reader/file_digest');

  Future<String> sha256File(String path) async {
    if (nativeAndroid) {
      try {
        final digest =
            await channel.invokeMethod<String>('sha256', {'path': path});
        if (digest == null || !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
          throw StateError('Invalid native SHA-256 result');
        }
        return digest;
      } on MissingPluginException {
        // Older/test platform embeddings can use the portable implementation.
      }
    }
    return Isolate.run(() async =>
        (await sha256.bind(File(path).openRead()).first).toString());
  }
}

final fileDigestService = FileDigestService();
