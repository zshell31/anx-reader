import 'dart:io';

import 'package:anx_reader/service/sync/annotation_protocol.dart';
import 'package:anx_reader/service/sync/library_protocol.dart';
import 'package:anx_reader/service/sync/library_sync_repository.dart';
import 'package:anx_reader/service/sync/sync_client_base.dart';
import 'package:anx_reader/utils/get_path/get_base_path.dart';
import 'package:crypto/crypto.dart';

List<String> libraryBookAssetSegments(String fingerprint) => [
      'anx',
      'assets',
      'books',
      'md5',
      canonicalMd5Fingerprint(fingerprint),
    ];

abstract interface class LibraryAssetTransport {
  Future<bool> exists(List<String> path);
  Future<void> upload(String localPath, List<String> remotePath);
  Future<void> download(List<String> remotePath, String localPath);
}

class SyncClientLibraryAssetTransport implements LibraryAssetTransport {
  final SyncClientBase client;
  SyncClientLibraryAssetTransport(this.client);

  String _path(List<String> segments) => segments.join('/');

  @override
  Future<bool> exists(List<String> path) => client.isExist(_path(path));

  @override
  Future<void> upload(String localPath, List<String> remotePath) async {
    await client
        .mkdirAll(remotePath.sublist(0, remotePath.length - 1).join('/'));
    await client.uploadFile(localPath, _path(remotePath), replace: false);
  }

  @override
  Future<void> download(List<String> remotePath, String localPath) =>
      client.downloadFile(_path(remotePath), localPath);
}

class LibraryAssetSyncService {
  final LibraryAssetTransport transport;
  final LibraryProjection projection;
  final String Function(String relativePath) resolveLocalPath;

  LibraryAssetSyncService({
    required this.transport,
    required this.projection,
    String Function(String relativePath)? resolveLocalPath,
  }) : resolveLocalPath = resolveLocalPath ?? getBasePath;

  Future<LibraryAssetSyncResult> syncBook(
      Map<String, dynamic> catalogDocument) async {
    final document = decodeLibraryCatalogDocument(catalogDocument);
    final membership = document['membership'] as Map<String, dynamic>;
    if (membership['value'] != true) {
      return const LibraryAssetSyncResult();
    }
    final fingerprint = document['fingerprint'] as String;
    final asset = document['bookAsset'] as Map<String, dynamic>;
    final extension = asset['extension'] as String;
    final remotePath = libraryBookAssetSegments(fingerprint);
    final relativePath = 'file/$fingerprint$extension';
    final localPath = resolveLocalPath(relativePath);
    final local = File(localPath);
    final localValid =
        local.existsSync() && await _fingerprint(localPath) == fingerprint;
    final remoteExists = await transport.exists(remotePath);

    if (localValid && !remoteExists) {
      await transport.upload(localPath, remotePath);
      return const LibraryAssetSyncResult(uploaded: true);
    }
    if (!localValid && remoteExists) {
      await local.parent.create(recursive: true);
      final partialPath = '$localPath.part';
      final partial = File(partialPath);
      if (partial.existsSync()) await partial.delete();
      try {
        await transport.download(remotePath, partialPath);
        final actual = await _fingerprint(partialPath);
        if (actual != fingerprint) {
          throw LibraryAssetFingerprintMismatch(fingerprint, actual);
        }
        if (local.existsSync()) await local.delete();
        await partial.rename(localPath);
        await projection.bindBookAsset(fingerprint, relativePath, extension);
        return const LibraryAssetSyncResult(downloaded: true, bound: true);
      } finally {
        if (partial.existsSync()) await partial.delete();
      }
    }
    if (localValid) {
      await projection.bindBookAsset(fingerprint, relativePath, extension);
      return const LibraryAssetSyncResult(bound: true);
    }
    return const LibraryAssetSyncResult(missing: true);
  }

  Future<String> _fingerprint(String path) async =>
      (await md5.bind(File(path).openRead()).first).toString();
}

class LibraryAssetFingerprintMismatch implements Exception {
  final String expected;
  final String actual;
  const LibraryAssetFingerprintMismatch(this.expected, this.actual);

  @override
  String toString() =>
      'Library asset fingerprint mismatch: expected $expected, got $actual';
}

class LibraryAssetSyncResult {
  final bool uploaded;
  final bool downloaded;
  final bool bound;
  final bool missing;
  const LibraryAssetSyncResult({
    this.uploaded = false,
    this.downloaded = false,
    this.bound = false,
    this.missing = false,
  });
}
