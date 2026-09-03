import 'dart:io';

import 'package:anx_reader/service/sync/library_protocol.dart';
import 'package:anx_reader/service/sync/library_sync_repository.dart';
import 'package:anx_reader/service/sync/sync_client_base.dart';
import 'package:anx_reader/service/sync/sync_diagnostics.dart';
import 'package:anx_reader/utils/get_path/get_base_path.dart';
import 'package:crypto/crypto.dart';

const libraryAssetReleaseSource = 'library-asset-release-v1';
const libraryAssetPresenceSource = 'library-asset-presence-v1';
const libraryLocalAssetVerificationSource =
    'library-local-asset-verification-v1';

typedef LibraryLocalAssetVerificationLoader
    = Future<LibraryLocalAssetVerification?> Function(String path);
typedef LibraryLocalAssetVerificationSaver = Future<void> Function(
  String path,
  LibraryLocalAssetVerification? verification,
);

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
  static const remotePresenceCacheLifetime = Duration(minutes: 1);

  final LibraryAssetTransport transport;
  final LibraryProjection projection;
  final String Function(String relativePath) resolveLocalPath;
  final Future<bool> Function(String fingerprint, String digest) isReleased;
  final LibraryLocalAssetVerificationLoader? loadLocalVerification;
  final LibraryLocalAssetVerificationSaver? saveLocalVerification;
  final Future<String> Function(String path) contentDigest;
  final DateTime Function() _clock;
  final Map<String, DateTime> _knownRemoteAssets = {};
  final Map<String, Future<bool>> _remotePresenceChecks = {};
  final Map<String, Future<bool>> _localVerificationChecks = {};
  final Map<String, LibraryLocalAssetVerification> _verifiedLocalAssets = {};

  LibraryAssetSyncService({
    required this.transport,
    required this.projection,
    String Function(String relativePath)? resolveLocalPath,
    Future<bool> Function(String fingerprint, String digest)? isReleased,
    this.loadLocalVerification,
    this.saveLocalVerification,
    Future<String> Function(String path)? contentDigest,
    DateTime Function()? clock,
  })  : resolveLocalPath = resolveLocalPath ?? getBasePath,
        isReleased = isReleased ?? ((_, __) async => false),
        contentDigest = contentDigest ?? _sha256File,
        _clock = clock ?? DateTime.now;

  Future<LibraryAssetSyncResult> syncBook(
    Map<String, dynamic> catalogDocument, {
    bool? knownBookRemote,
  }) async {
    final document = decodeLibraryCatalogDocument(catalogDocument);
    final membership = document['membership'] as Map<String, dynamic>;
    if (membership['value'] != true) {
      return const LibraryAssetSyncResult();
    }
    final cover = await _syncCover(document);
    final book = await _syncBookAsset(
      document,
      knownRemote: knownBookRemote,
    );
    return cover.combine(book);
  }

  /// Returns the current book-asset state while reusing the digest and remote
  /// presence caches populated by [syncBook].
  Future<LibraryBookAssetAvailability> bookAvailability(
    Map<String, dynamic> catalogDocument, {
    bool? knownRemote,
  }) async {
    final document = decodeLibraryCatalogDocument(catalogDocument);
    final membership = document['membership'] as Map<String, dynamic>;
    if (membership['value'] != true) {
      return const LibraryBookAssetAvailability();
    }
    final fingerprint = document['fingerprint'] as String;
    final asset = (document['bookAsset'] as Map<String, dynamic>)['value']
        as Map<String, dynamic>;
    final digest = _canonicalSha256(asset['digest']);
    final extension = asset['extension'] as String;
    final boundRelativePath = await projection.localBookAssetPath(fingerprint);
    final relativePath = boundRelativePath ?? 'file/$digest$extension';
    final localValid = await _matchesLocalDigest(
      File(resolveLocalPath(relativePath)),
      digest,
    );
    final remoteExists =
        knownRemote ?? await _remoteExists(libraryBookAssetSegments(digest));
    final released =
        !localValid && remoteExists && await isReleased(fingerprint, digest);
    return LibraryBookAssetAvailability(
      localVerified: localValid,
      remote: remoteExists,
      released: released,
    );
  }

  Future<LibraryAssetSyncResult> _syncBookAsset(
    Map<String, dynamic> document, {
    bool? knownRemote,
  }) async {
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
    final localValid = await _matchesLocalDigest(local, digest);
    final remoteExists = knownRemote ?? await _remoteExists(remotePath);

    if (localValid && !remoteExists) {
      syncDebug('asset type=book digest=${shortSyncId(digest)} action=upload');
      await transport.upload(localPath, remotePath);
      _rememberRemoteAsset(remotePath);
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
        final actual = await contentDigest(partialPath);
        if (actual != digest) {
          syncWarning('asset type=book digest=${shortSyncId(digest)} '
              'action=reject reason=sha256-mismatch');
          throw LibraryAssetFingerprintMismatch(digest, actual);
        }
        if (downloadFile.existsSync()) await downloadFile.delete();
        await partial.rename(downloadPath);
        await _rememberLocalDigest(downloadFile, digest);
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
    final localValid = await _matchesLocalDigest(local, digest);
    final remoteExists = await _remoteExists(remotePath);
    if (localValid && !remoteExists) {
      syncDebug('asset type=cover digest=${shortSyncId(digest)} action=upload');
      await transport.upload(localPath, remotePath);
      _rememberRemoteAsset(remotePath);
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
        final actual = await contentDigest(partial.path);
        if (actual != digest) {
          syncWarning('asset type=cover digest=${shortSyncId(digest)} '
              'action=reject reason=sha256-mismatch');
          throw LibraryAssetFingerprintMismatch(digest, actual);
        }
        if (target.existsSync()) await target.delete();
        await partial.rename(targetPath);
        await _rememberLocalDigest(target, digest);
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

  Future<bool> _remoteExists(List<String> path) async {
    final key = path.join('/');
    final checkedAt = _knownRemoteAssets[key];
    if (checkedAt != null &&
        _clock().isBefore(checkedAt.add(remotePresenceCacheLifetime))) {
      return true;
    }
    final active = _remotePresenceChecks[key];
    if (active != null) return active;
    final check = transport.exists(path);
    _remotePresenceChecks[key] = check;
    try {
      final exists = await check;
      if (exists) {
        _knownRemoteAssets[key] = _clock();
      } else {
        _knownRemoteAssets.remove(key);
      }
      return exists;
    } finally {
      if (identical(_remotePresenceChecks[key], check)) {
        _remotePresenceChecks.remove(key);
      }
    }
  }

  void _rememberRemoteAsset(List<String> path) {
    _knownRemoteAssets[path.join('/')] = _clock();
  }

  Future<bool> _matchesLocalDigest(File file, String expected) {
    final key = '${file.path}\u0000$expected';
    final active = _localVerificationChecks[key];
    if (active != null) return active;
    late final Future<bool> check;
    check = _checkLocalDigest(file, expected).whenComplete(() {
      if (identical(_localVerificationChecks[key], check)) {
        _localVerificationChecks.remove(key);
      }
    });
    _localVerificationChecks[key] = check;
    return check;
  }

  Future<bool> _checkLocalDigest(File file, String expected) async {
    final stopwatch = Stopwatch()..start();
    if (!file.existsSync()) {
      _verifiedLocalAssets.remove(file.path);
      await saveLocalVerification?.call(file.path, null);
      syncDebug('asset-local digest=${shortSyncId(expected)} '
          'verification=miss reason=file-absent '
          'durationMs=${stopwatch.elapsedMilliseconds}');
      return false;
    }
    final stat = await file.stat();
    final memory = _verifiedLocalAssets[file.path];
    final cached = memory ?? await loadLocalVerification?.call(file.path);
    final mismatch = libraryLocalAssetVerificationMismatch(
      cached,
      expectedDigest: expected,
      actualSize: stat.size,
      actualModified: stat.modified,
    );
    if (mismatch == null) {
      _verifiedLocalAssets[file.path] = cached!;
      syncDebug('asset-local digest=${shortSyncId(expected)} '
          'verification=hit source=${memory == null ? 'persisted' : 'memory'} '
          'durationMs=${stopwatch.elapsedMilliseconds}');
      return true;
    }
    syncDebug('asset-local digest=${shortSyncId(expected)} '
        'verification=miss reason=$mismatch action=sha256');
    final actual = await contentDigest(file.path);
    if (actual != expected) {
      _verifiedLocalAssets.remove(file.path);
      await saveLocalVerification?.call(file.path, null);
      syncWarning('asset-local digest=${shortSyncId(expected)} '
          'verification=failed reason=sha256-mismatch '
          'durationMs=${stopwatch.elapsedMilliseconds}');
      return false;
    }
    final verification = LibraryLocalAssetVerification(
      digest: actual,
      size: stat.size,
      modified: stat.modified,
    );
    _verifiedLocalAssets[file.path] = verification;
    await saveLocalVerification?.call(file.path, verification);
    syncDebug('asset-local digest=${shortSyncId(expected)} '
        'verification=stored result=sha256-match '
        'durationMs=${stopwatch.elapsedMilliseconds}');
    return true;
  }

  Future<void> _rememberLocalDigest(File file, String digest) async {
    final stat = await file.stat();
    final verification = LibraryLocalAssetVerification(
      digest: digest,
      size: stat.size,
      modified: stat.modified,
    );
    _verifiedLocalAssets[file.path] = verification;
    await saveLocalVerification?.call(file.path, verification);
  }
}

Future<String> _sha256File(String path) async =>
    (await sha256.bind(File(path).openRead()).first).toString();

class LibraryLocalAssetVerification {
  const LibraryLocalAssetVerification({
    required this.digest,
    required this.size,
    required this.modified,
  });

  final String digest;
  final int size;
  final DateTime modified;
}

String? libraryLocalAssetVerificationMismatch(
  LibraryLocalAssetVerification? verification, {
  required String expectedDigest,
  required int actualSize,
  required DateTime actualModified,
}) {
  if (verification == null) return 'receipt-missing';
  if (verification.digest != expectedDigest) return 'digest-changed';
  if (verification.size != actualSize) return 'size-changed';
  // FileStat reports local time on Android, while persisted ISO timestamps
  // are restored as UTC. Compare the instant rather than the representation.
  if (!verification.modified.isAtSameMomentAs(actualModified)) {
    return 'modified-changed';
  }
  return null;
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

class LibraryBookAssetAvailability {
  final bool localVerified;
  final bool remote;
  final bool released;

  const LibraryBookAssetAvailability({
    this.localVerified = false,
    this.remote = false,
    this.released = false,
  });
}
