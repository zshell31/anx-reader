import 'dart:io';

import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/service/sync/domain_stamp.dart';
import 'package:anx_reader/service/sync/library_asset_sync.dart';
import 'package:anx_reader/service/sync/library_protocol.dart';
import 'package:anx_reader/service/sync/library_sync_repository.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

class MemoryAssets implements LibraryAssetTransport {
  final Map<String, List<int>> objects = {};
  int uploads = 0;
  int downloads = 0;

  String key(List<String> path) => path.join('/');

  @override
  Future<void> download(List<String> remotePath, String localPath) async {
    downloads++;
    await File(localPath).writeAsBytes(objects[key(remotePath)]!);
  }

  @override
  Future<bool> exists(List<String> path) async =>
      objects.containsKey(key(path));

  @override
  Future<void> upload(String localPath, List<String> remotePath) async {
    uploads++;
    objects[key(remotePath)] = await File(localPath).readAsBytes();
  }
}

class BindingProjection implements LibraryProjection {
  String? boundPath;

  @override
  Future<void> bindBookAsset(
      String fingerprint, String relativePath, String extension) async {
    boundPath = relativePath;
  }

  @override
  Future<List<Book>> allBooks() async => const [];
  @override
  Future<Book?> bookByFingerprint(String fingerprint) async => null;
  @override
  Future<void> projectCatalog(Map<String, dynamic> document) async {}
  @override
  Future<void> projectReadingState(Map<String, dynamic> document) async {}
}

Map<String, dynamic> catalog(List<int> bytes, {bool present = true}) {
  final fingerprint = md5.convert(bytes).toString();
  final stamp =
      DomainStamp(modifiedAt: DateTime.utc(2025), deviceId: 'device-a');
  return decodeLibraryCatalogDocument({
    'schemaVersion': 1,
    'fingerprint': fingerprint,
    'membership': stampedValue(present, stamp),
    'metadata': {
      'title': stampedValue('Book', stamp),
      'author': stampedValue('', stamp),
      'description': stampedValue(null, stamp),
      'rating': stampedValue(0.0, stamp),
    },
    'bookAsset': {
      'algorithm': 'md5',
      'digest': fingerprint,
      'extension': '.epub',
    },
  });
}

void main() {
  late Directory directory;
  late MemoryAssets transport;
  late BindingProjection projection;
  late LibraryAssetSyncService service;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('anx-asset-test-');
    transport = MemoryAssets();
    projection = BindingProjection();
    service = LibraryAssetSyncService(
      transport: transport,
      projection: projection,
      resolveLocalPath: (relative) => '${directory.path}/$relative',
    );
  });

  tearDown(() => directory.delete(recursive: true));

  test('uploads a valid local immutable asset once', () async {
    final bytes = <int>[1, 2, 3, 4];
    final document = catalog(bytes);
    final fingerprint = document['fingerprint'] as String;
    final file = File('${directory.path}/file/$fingerprint.epub');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
    expect((await service.syncBook(document)).uploaded, isTrue);
    expect((await service.syncBook(document)).uploaded, isFalse);
    expect(transport.uploads, 1);
  });

  test('downloads, verifies, and binds a remote-only asset', () async {
    final bytes = <int>[5, 6, 7, 8];
    final document = catalog(bytes);
    final fingerprint = document['fingerprint'] as String;
    transport.objects[libraryBookAssetSegments(fingerprint).join('/')] = bytes;
    final result = await service.syncBook(document);
    expect(result.downloaded, isTrue);
    expect(result.bound, isTrue);
    expect(projection.boundPath, 'file/$fingerprint.epub');
  });

  test('rejects corrupt download before binding', () async {
    final document = catalog(<int>[9, 10]);
    final fingerprint = document['fingerprint'] as String;
    transport.objects[libraryBookAssetSegments(fingerprint).join('/')] = [99];
    await expectLater(service.syncBook(document),
        throwsA(isA<LibraryAssetFingerprintMismatch>()));
    expect(projection.boundPath, isNull);
  });

  test('tombstone never deletes or downloads immutable bytes', () async {
    final bytes = <int>[11, 12];
    final document = catalog(bytes, present: false);
    final fingerprint = document['fingerprint'] as String;
    transport.objects[libraryBookAssetSegments(fingerprint).join('/')] = bytes;
    await service.syncBook(document);
    expect(transport.objects,
        contains(libraryBookAssetSegments(fingerprint).join('/')));
    expect(transport.downloads, 0);
  });
}
