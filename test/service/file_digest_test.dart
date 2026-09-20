import 'dart:io';

import 'package:anx_reader/service/file_digest.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late File file;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('anx-file-digest-');
    file = File('${directory.path}/book.pdf');
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(FileDigestService.channel, null);
    await directory.delete(recursive: true);
  });

  test('portable digest preserves exact SHA-256 across stream chunks',
      () async {
    final bytes = List<int>.generate(700001, (index) => index % 256);
    await file.writeAsBytes(bytes);
    expect(await FileDigestService(nativeAndroid: false).sha256File(file.path),
        sha256.convert(bytes).toString());
  });

  test('native channel receives only a path and returns the digest', () async {
    final expected = sha256.convert([0, 128, 255]).toString();
    messenger.setMockMethodCallHandler(FileDigestService.channel, (call) async {
      expect(call.method, 'sha256');
      expect(call.arguments, {'path': file.path});
      return expected;
    });
    expect(await FileDigestService(nativeAndroid: true).sha256File(file.path),
        expected);
  });

  test('missing plugin falls back to portable hashing', () async {
    await file.writeAsString('abc');
    expect(await FileDigestService(nativeAndroid: true).sha256File(file.path),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
  });

  test('native errors and invalid digests cannot establish trust', () async {
    final service = FileDigestService(nativeAndroid: true);
    messenger.setMockMethodCallHandler(
        FileDigestService.channel, (_) async => 'bad');
    await expectLater(service.sha256File(file.path), throwsStateError);
    messenger.setMockMethodCallHandler(FileDigestService.channel,
        (_) async => throw PlatformException(code: 'FILE_DIGEST_ERROR'));
    await expectLater(
        service.sha256File(file.path), throwsA(isA<PlatformException>()));
  });

  test('missing portable file fails instead of returning an empty digest',
      () async {
    await expectLater(
        FileDigestService(nativeAndroid: false).sha256File(file.path),
        throwsA(isA<FileSystemException>()));
  });
}
