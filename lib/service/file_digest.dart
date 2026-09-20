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

  Future<String> sha256File(String path) => _digest(path, 'sha256', 64);
  Future<String> md5File(String path) => _digest(path, 'md5', 32);

  Future<String> _digest(String path, String method, int length) async {
    if (nativeAndroid) {
      try {
        final digest =
            await channel.invokeMethod<String>(method, {'path': path});
        if (digest == null ||
            !RegExp('^[0-9a-f]{$length}\$').hasMatch(digest)) {
          throw StateError('Invalid native $method result');
        }
        return digest;
      } on MissingPluginException {
        // Older/test platform embeddings can use the portable implementation.
      }
    }
    return Isolate.run(() async => (await (method == 'md5' ? md5 : sha256)
            .bind(File(path).openRead())
            .first)
        .toString());
  }
}

final fileDigestService = FileDigestService();
