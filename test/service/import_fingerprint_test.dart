import 'dart:io';
import 'package:anx_reader/models/import_file_check.dart';
import 'package:anx_reader/service/md5_service.dart';
import 'package:anx_reader/service/file_digest.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late File file;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('anx-import-hash-');
    file = await File('${directory.path}/book.pdf').writeAsString('abc');
  });
  tearDown(() => directory.delete(recursive: true));

  test('MD5 portable and missing-native fallback match the canonical identity',
      () async {
    for (final native in [false, true]) {
      expect(await FileDigestService(nativeAndroid: native).md5File(file.path),
          '900150983cd24fb0d6963f7d28e17f72');
    }
  });
  test('reuses the checked digest of the unchanged staged file', () async {
    final checked = ImportFileCheck(
        filePath: file.path,
        md5: 'checked-value',
        fingerprintStat: await file.stat(),
        isDuplicate: false);
    expect(await MD5Service.forImport(file, checked), 'checked-value');
  });
  test('rechecks a changed file rather than assigning the stale book identity',
      () async {
    final checked = ImportFileCheck(
        filePath: file.path,
        md5: 'checked-value',
        fingerprintStat: await file.stat(),
        isDuplicate: false);
    await file.writeAsString('abcd');
    expect(await MD5Service.forImport(file, checked),
        'e2fc714c4727ee9395f324cd2e7f331f');
  });
}
