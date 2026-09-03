import 'dart:io';

import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/service/sync/domain_stamp.dart';
import 'package:anx_reader/service/sync/library_asset_sync.dart';
import 'package:anx_reader/service/sync/library_protocol.dart';
import 'package:anx_reader/service/sync/library_sync_repository.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

class MemoryAssets implements LibraryAssetTransport {
  final Map<String, List<int>> objects = {};
  int uploads = 0;
  int downloads = 0;
  int existenceChecks = 0;

  String key(List<String> path) => path.join('/');

  @override
  Future<void> download(List<String> remotePath, String localPath) async {
    downloads++;
    await File(localPath).writeAsBytes(objects[key(remotePath)]!);
  }

  @override
  Future<bool> exists(List<String> path) async {
    existenceChecks++;
    return objects.containsKey(key(path));
  }

  @override
  Future<void> upload(String localPath, List<String> remotePath) async {
    uploads++;
    objects[key(remotePath)] = await File(localPath).readAsBytes();
  }
}

class BindingProjection implements LibraryProjection {
  String? boundPath;
  String? boundCoverPath;

  @override
  Future<void> bindBookAsset(
      String fingerprint, String relativePath, String extension) async {
    boundPath = relativePath;
  }

  @override
  Future<String?> localBookAssetPath(String fingerprint) async => boundPath;

  @override
  Future<String?> localCoverAssetPath(String fingerprint) async =>
      boundCoverPath;

  @override
  Future<void> bindCoverAsset(
      String fingerprint, String relativePath, String extension) async {
    boundCoverPath = relativePath;
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

Map<String, dynamic> catalog(List<int> bytes,
    {bool present = true, List<int>? coverBytes}) {
  final fingerprint = md5.convert([42, ...bytes]).toString();
  final digest = sha256.convert(bytes).toString();
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
    'bookAsset': stampedValue({
      'algorithm': 'sha256',
      'digest': digest,
      'extension': '.epub',
    }, stamp),
    if (coverBytes != null)
      'coverAsset': stampedValue({
        'algorithm': 'sha256',
        'digest': sha256.convert(coverBytes).toString(),
        'extension': '.png',
      }, stamp),
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
    final file = File('${directory.path}/randomized-name.epub');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
    projection.boundPath = 'randomized-name.epub';
    expect((await service.syncBook(document)).uploaded, isTrue);
    expect((await service.syncBook(document)).uploaded, isFalse);
    expect(transport.uploads, 1);
    expect(transport.existenceChecks, 1);
  });

  test('reuses verified immutable local and remote asset state', () async {
    final bytes = <int>[21, 22, 23, 24];
    final document = catalog(bytes);
    final digest = ((document['bookAsset'] as Map)['value'] as Map)['digest'];
    final file = File('${directory.path}/book.epub');
    await file.writeAsBytes(bytes);
    projection.boundPath = 'book.epub';
    transport.objects[libraryBookAssetSegments(digest).join('/')] = bytes;

    expect((await service.syncBook(document)).bound, isTrue);
    expect((await service.syncBook(document)).bound, isTrue);

    expect(transport.existenceChecks, 1);
    expect(transport.uploads, 0);
    expect(transport.downloads, 0);
  });

  test('availability reuses state populated by asset synchronization',
      () async {
    final bytes = <int>[25, 26, 27, 28];
    final document = catalog(bytes);
    final digest = ((document['bookAsset'] as Map)['value'] as Map)['digest'];
    final file = File('${directory.path}/book.epub');
    await file.writeAsBytes(bytes);
    projection.boundPath = 'book.epub';
    transport.objects[libraryBookAssetSegments(digest).join('/')] = bytes;

    await service.syncBook(document);
    final availability = await service.bookAvailability(document);

    expect(availability.localVerified, isTrue);
    expect(availability.remote, isTrue);
    expect(availability.released, isFalse);
    expect(transport.existenceChecks, 1);
  });

  test('remote presence is checked again after the short cache lifetime',
      () async {
    final bytes = <int>[31, 32, 33, 34];
    final document = catalog(bytes);
    final digest = ((document['bookAsset'] as Map)['value'] as Map)['digest'];
    final file = File('${directory.path}/book.epub');
    await file.writeAsBytes(bytes);
    projection.boundPath = 'book.epub';
    transport.objects[libraryBookAssetSegments(digest).join('/')] = bytes;
    var now = DateTime.utc(2026);
    service = LibraryAssetSyncService(
      transport: transport,
      projection: projection,
      resolveLocalPath: (relative) => '${directory.path}/$relative',
      clock: () => now,
    );

    await service.syncBook(document);
    now = now.add(LibraryAssetSyncService.remotePresenceCacheLifetime);
    await service.syncBook(document);

    expect(transport.existenceChecks, 2);
  });

  test('downloads, verifies, and binds a remote-only asset', () async {
    final bytes = <int>[5, 6, 7, 8];
    final document = catalog(bytes);
    final digest = ((document['bookAsset'] as Map)['value'] as Map)['digest'];
    transport.objects[libraryBookAssetSegments(digest).join('/')] = bytes;
    final result = await service.syncBook(document);
    expect(result.downloaded, isTrue);
    expect(result.bound, isTrue);
    expect(projection.boundPath, 'file/$digest.epub');
  });

  test('rejects corrupt download before binding', () async {
    final document = catalog(<int>[9, 10]);
    final digest = ((document['bookAsset'] as Map)['value'] as Map)['digest'];
    transport.objects[libraryBookAssetSegments(digest).join('/')] = [99];
    Logger.root.level = Level.ALL;
    final records = <LogRecord>[];
    final subscription = AnxLog.log.onRecord.listen(records.add);
    await expectLater(service.syncBook(document),
        throwsA(isA<LibraryAssetFingerprintMismatch>()));
    await Future<void>.delayed(Duration.zero);
    await subscription.cancel();
    final diagnostics = records.map((record) => record.message).join('\n');
    expect(diagnostics, contains('action=reject reason=sha256-mismatch'));
    expect(diagnostics, isNot(contains(digest)));
    expect(diagnostics, isNot(contains(directory.path)));
    expect(projection.boundPath, isNull);
  });

  test('tombstone never deletes or downloads immutable bytes', () async {
    final bytes = <int>[11, 12];
    final document = catalog(bytes, present: false);
    final digest = ((document['bookAsset'] as Map)['value'] as Map)['digest'];
    transport.objects[libraryBookAssetSegments(digest).join('/')] = bytes;
    await service.syncBook(document);
    expect(transport.objects,
        contains(libraryBookAssetSegments(digest).join('/')));
    expect(transport.downloads, 0);
  });

  test('semantic TXT fingerprint is independent from converted asset bytes',
      () async {
    final convertedEpub = <int>[80, 75, 3, 4, 99];
    final document = catalog(convertedEpub);
    final fingerprint = document['fingerprint'] as String;
    final digest = ((document['bookAsset'] as Map)['value'] as Map)['digest'];
    expect(fingerprint, isNot(digest));
    expect(digest, sha256.convert(convertedEpub).toString());
  });

  test('released local book is not automatically downloaded', () async {
    final bytes = <int>[13, 14];
    final document = catalog(bytes);
    final digest = ((document['bookAsset'] as Map)['value'] as Map)['digest'];
    transport.objects[libraryBookAssetSegments(digest).join('/')] = bytes;
    service = LibraryAssetSyncService(
      transport: transport,
      projection: projection,
      resolveLocalPath: (relative) => '${directory.path}/$relative',
      isReleased: (_, __) async => true,
    );
    final result = await service.syncBook(document);
    expect(result.downloaded, isFalse);
    expect(result.missing, isTrue);
    expect(transport.downloads, 0);
  });

  test('custom cover uses an independent immutable SHA-256 asset', () async {
    final bookBytes = <int>[15, 16];
    final coverBytes = <int>[137, 80, 78, 71];
    final document = catalog(bookBytes, coverBytes: coverBytes);
    final bookDigest =
        ((document['bookAsset'] as Map)['value'] as Map)['digest'];
    final coverDigest =
        ((document['coverAsset'] as Map)['value'] as Map)['digest'];
    transport.objects[libraryBookAssetSegments(bookDigest).join('/')] =
        bookBytes;
    transport.objects[libraryCoverAssetSegments(coverDigest).join('/')] =
        coverBytes;
    final result = await service.syncBook(document);
    expect(result.downloaded, isTrue);
    expect(projection.boundCoverPath, 'cover/$coverDigest.png');
  });
}
