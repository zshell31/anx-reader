import 'dart:io';

import 'package:anx_reader/service/sync/library_protocol.dart';
import 'package:anx_reader/service/sync/library_sync_repository.dart';
import 'package:anx_reader/service/sync/sync_client_base.dart';
import 'package:anx_reader/service/sync/sync_diagnostics.dart';
import 'package:anx_reader/utils/get_path/get_base_path.dart';
import 'package:crypto/crypto.dart';

const libraryAssetReleaseSource = 'library-asset-release-v1';

List<String> libraryBookAssetSegments(String digest) => [
      'anx',
      'assets',
      'books',
      'sha256',
      _canonicalSha256(digest),
    ];

List<String> libraryCoverAssetSegments(String digest) => [
      'anx',
      'assets',
      'covers',
      'sha256',
      _canonicalSha256(digest),
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
  final Future<bool> Function(String fingerprint, String digest) isReleased;

  LibraryAssetSyncService({
    required this.transport,
    required this.projection,
    String Function(String relativePath)? resolveLocalPath,
    Future<bool> Function(String fingerprint, String digest)? isReleased,
  })  : resolveLocalPath = resolveLocalPath ?? getBasePath,
        isReleased = isReleased ?? ((_, __) async => false);

  Future<LibraryAssetSyncResult> syncBook(
      Map<String, dynamic> catalogDocument) async {
    final document = decodeLibraryCatalogDocument(catalogDocument);
    final membership = document['membership'] as Map<String, dynamic>;
    if (membership['value'] != true) {
      return const LibraryAssetSyncResult();
    }
    final cover = await _syncCover(document);
    final book = await _syncBookAsset(document);
    return cover.combine(book);
  }

  Future<LibraryAssetSyncResult> _syncBookAsset(
      Map<String, dynamic> document) async {
    final fingerprint = document['fingerprint'] as String;
    final asset = (document['bookAsset'] as Map<String, dynamic>)['value']
        as Map<String, dynamic>;
    final digest = _canonicalSha256(asset['digest']);
    final extension = asset['extension'] as String;
    final remotePath = libraryBookAssetSegments(digest);
    final boundRelativePath = await projection.localBookAssetPath(fingerprint);
    final relativePath = boundRelativePath ?? 'file/$digest$extension';
    final localPath = resolveLocalPath(relativePath);
    final local = File(localPath);
    final localValid =
        local.existsSync() && await _contentDigest(localPath) == digest;
    final remoteExists = await transport.exists(remotePath);

    if (localValid && !remoteExists) {
      syncDebug('asset type=book digest=${shortSyncId(digest)} action=upload');
      await transport.upload(localPath, remotePath);
      return const LibraryAssetSyncResult(uploaded: true);
    }
    final released = !localValid && remoteExists
        ? await isReleased(fingerprint, digest)
        : false;
    if (!localValid && remoteExists && !released) {
      syncDebug(
          'asset type=book digest=${shortSyncId(digest)} action=download');
      final downloadRelativePath = 'file/$digest$extension';
      final downloadPath = resolveLocalPath(downloadRelativePath);
      final downloadFile = File(downloadPath);
      await downloadFile.parent.create(recursive: true);
      final partialPath = '$downloadPath.part';
      final partial = File(partialPath);
      if (partial.existsSync()) await partial.delete();
      try {
        await transport.download(remotePath, partialPath);
        final actual = await _contentDigest(partialPath);
        if (actual != digest) {
          syncWarning('asset type=book digest=${shortSyncId(digest)} '
              'action=reject reason=sha256-mismatch');
          throw LibraryAssetFingerprintMismatch(digest, actual);
        }
        if (downloadFile.existsSync()) await downloadFile.delete();
        await partial.rename(downloadPath);
        await projection.bindBookAsset(
            fingerprint, downloadRelativePath, extension);
        return const LibraryAssetSyncResult(downloaded: true, bound: true);
      } finally {
        if (partial.existsSync()) await partial.delete();
      }
    }
    if (localValid) {
      await projection.bindBookAsset(fingerprint, relativePath, extension);
      return const LibraryAssetSyncResult(bound: true);
    }
    if (released) {
      syncDebug('asset type=book digest=${shortSyncId(digest)} action=skip '
          'reason=released');
      return const LibraryAssetSyncResult(missing: true, released: true);
    }
    syncDebug('asset type=book digest=${shortSyncId(digest)} action=skip '
        'reason=missing');
    return const LibraryAssetSyncResult(missing: true);
  }

  Future<LibraryAssetSyncResult> _syncCover(
      Map<String, dynamic> document) async {
    final stamped = document['coverAsset'];
    if (stamped == null) return const LibraryAssetSyncResult();
    final fingerprint = document['fingerprint'] as String;
    final asset =
        (stamped as Map<String, dynamic>)['value'] as Map<String, dynamic>;
    final digest = _canonicalSha256(asset['digest']);
    final extension = asset['extension'] as String;
    final remotePath = libraryCoverAssetSegments(digest);
    final boundRelativePath = await projection.localCoverAssetPath(fingerprint);
    final relativePath = boundRelativePath ?? 'cover/$digest$extension';
    final localPath = resolveLocalPath(relativePath);
    final local = File(localPath);
    final localValid =
        local.existsSync() && await _contentDigest(localPath) == digest;
    final remoteExists = await transport.exists(remotePath);
    if (localValid && !remoteExists) {
      syncDebug('asset type=cover digest=${shortSyncId(digest)} action=upload');
      await transport.upload(localPath, remotePath);
      return const LibraryAssetSyncResult(uploaded: true);
    }
    if (!localValid && remoteExists) {
      syncDebug(
          'asset type=cover digest=${shortSyncId(digest)} action=download');
      final targetRelativePath = 'cover/$digest$extension';
      final targetPath = resolveLocalPath(targetRelativePath);
      final target = File(targetPath);
      await target.parent.create(recursive: true);
      final partial = File('$targetPath.part');
      if (partial.existsSync()) await partial.delete();
      try {
        await transport.download(remotePath, partial.path);
        final actual = await _contentDigest(partial.path);
        if (actual != digest) {
          syncWarning('asset type=cover digest=${shortSyncId(digest)} '
              'action=reject reason=sha256-mismatch');
          throw LibraryAssetFingerprintMismatch(digest, actual);
        }
        if (target.existsSync()) await target.delete();
        await partial.rename(targetPath);
        await projection.bindCoverAsset(
            fingerprint, targetRelativePath, extension);
        return const LibraryAssetSyncResult(downloaded: true, bound: true);
      } finally {
        if (partial.existsSync()) await partial.delete();
      }
    }
    if (localValid) {
      await projection.bindCoverAsset(fingerprint, relativePath, extension);
      return const LibraryAssetSyncResult(bound: true);
    }
    syncDebug('asset type=cover digest=${shortSyncId(digest)} action=skip '
        'reason=missing');
    return const LibraryAssetSyncResult(missing: true);
  }

  Future<String> _contentDigest(String path) async =>
      (await sha256.bind(File(path).openRead()).first).toString();
}

String _canonicalSha256(Object? value) {
  if (value is! String || !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(value)) {
    throw const FormatException('invalid SHA-256 digest');
  }
  return value.toLowerCase();
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
  final bool released;
  const LibraryAssetSyncResult({
    this.uploaded = false,
    this.downloaded = false,
    this.bound = false,
    this.missing = false,
    this.released = false,
  });

  LibraryAssetSyncResult combine(LibraryAssetSyncResult other) =>
      LibraryAssetSyncResult(
        uploaded: uploaded || other.uploaded,
        downloaded: downloaded || other.downloaded,
        bound: bound || other.bound,
        missing: missing || other.missing,
        released: released || other.released,
      );
}
