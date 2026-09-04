import 'dart:io';
import 'dart:typed_data';

import 'package:anx_reader/service/sync/annotation_protocol.dart';
import 'package:anx_reader/service/sync/annotation_read_model.dart';
import 'package:anx_reader/service/sync/sync_client_base.dart';
import 'package:anx_reader/utils/get_path/get_base_path.dart';
import 'package:crypto/crypto.dart';

List<String> annotationAudioAssetRemoteSegments(
  String remoteRoot,
  String assetRef,
) {
  final root = remoteRoot
      .split('/')
      .map((segment) => segment.trim())
      .where((segment) => segment.isNotEmpty)
      .toList(growable: false);
  return [...root, ...annotationAudioAssetRefSegments(assetRef)];
}

List<String> annotationAudioAssetRefSegments(String assetRef) {
  if (!RegExp(r'^annotation-assets/audio/[A-Za-z0-9][A-Za-z0-9._-]*$')
      .hasMatch(assetRef)) {
    throw ArgumentError.value(assetRef, 'assetRef', 'invalid audio asset ref');
  }
  return assetRef.split('/');
}

class AnnotationAudioAsset {
  final String assetRef;
  final int byteLength;
  final String sha256;

  const AnnotationAudioAsset({
    required this.assetRef,
    required this.byteLength,
    required this.sha256,
  });

  factory AnnotationAudioAsset.fromMetadata(Map<String, Object?> metadata) {
    final assetRef = metadata['assetRef'];
    final byteLength = metadata['byteLength'];
    final digest = metadata['sha256'];
    if (assetRef is! String ||
        byteLength is! int ||
        byteLength < 0 ||
        digest is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
      throw ArgumentError.value(metadata, 'metadata', 'invalid audio asset');
    }
    annotationAudioAssetRefSegments(assetRef);
    return AnnotationAudioAsset(
      assetRef: assetRef,
      byteLength: byteLength,
      sha256: digest,
    );
  }
}

Iterable<AnnotationAudioAsset> annotationAudioAssets(
  Map<String, dynamic> document,
) sync* {
  final normalized = decodeAnnotationDocument(document);
  final seen = <String>{};
  for (final annotation
      in (normalized['annotations'] as List).cast<Map<String, dynamic>>()) {
    if (isProtocolEntityTombstoned(annotation)) continue;
    for (final enrichment
        in (annotation['enrichments'] as List).cast<Map<String, dynamic>>()) {
      if (enrichment['kind'] != 'audio' ||
          isProtocolEntityTombstoned(enrichment)) {
        continue;
      }
      final metadata = (enrichment['audio'] as Map).cast<String, Object?>();
      final asset = AnnotationAudioAsset.fromMetadata(metadata);
      if (seen.add(asset.assetRef)) yield asset;
    }
  }
}

class AnnotationAudioAssetIntegrityException implements Exception {
  final String reason;
  const AnnotationAudioAssetIntegrityException(this.reason);

  @override
  String toString() => 'Annotation audio asset integrity failure: $reason';
}

class AnnotationAudioAssetStore {
  final String Function(String relativePath) resolveLocalPath;

  AnnotationAudioAssetStore({
    String Function(String relativePath)? resolveLocalPath,
  }) : resolveLocalPath = resolveLocalPath ?? getBasePath;

  String pathFor(String assetRef) {
    annotationAudioAssetRefSegments(assetRef);
    return resolveLocalPath(assetRef);
  }

  Future<bool> contains(AnnotationAudioAsset asset) async {
    final file = File(pathFor(asset.assetRef));
    if (!await file.exists()) return false;
    if (await file.length() != asset.byteLength) return false;
    return await _fileDigest(file) == asset.sha256;
  }

  Future<void> persist(
    Map<String, Object?> metadata,
    Uint8List bytes,
  ) async {
    final asset = AnnotationAudioAsset.fromMetadata(metadata);
    _verifyBytes(asset, bytes);
    final target = File(pathFor(asset.assetRef));
    if (await contains(asset)) return;
    await target.parent.create(recursive: true);
    final partial = File('${target.path}.part');
    if (await partial.exists()) await partial.delete();
    try {
      await partial.writeAsBytes(bytes, flush: true);
      if (await target.exists()) await target.delete();
      await partial.rename(target.path);
    } finally {
      if (await partial.exists()) await partial.delete();
    }
  }

  Future<void> installDownloaded(
    AnnotationAudioAsset asset,
    String partialPath,
  ) async {
    final partial = File(partialPath);
    if (!await partial.exists() || await partial.length() != asset.byteLength) {
      throw const AnnotationAudioAssetIntegrityException(
          'byte-length-mismatch');
    }
    if (await _fileDigest(partial) != asset.sha256) {
      throw const AnnotationAudioAssetIntegrityException('sha256-mismatch');
    }
    final target = File(pathFor(asset.assetRef));
    await target.parent.create(recursive: true);
    if (await target.exists()) await target.delete();
    await partial.rename(target.path);
  }

  void _verifyBytes(AnnotationAudioAsset asset, Uint8List bytes) {
    if (bytes.length != asset.byteLength) {
      throw const AnnotationAudioAssetIntegrityException(
          'byte-length-mismatch');
    }
    if (sha256.convert(bytes).toString() != asset.sha256) {
      throw const AnnotationAudioAssetIntegrityException('sha256-mismatch');
    }
  }
}

abstract interface class AnnotationAudioAssetTransport {
  Future<bool> exists(List<String> path);
  Future<void> upload(String localPath, List<String> remotePath);
  Future<void> download(List<String> remotePath, String localPath);
}

class SyncClientAnnotationAudioAssetTransport
    implements AnnotationAudioAssetTransport {
  final SyncClientBase client;
  SyncClientAnnotationAudioAssetTransport(this.client);

  String _path(List<String> segments) => segments.join('/');

  @override
  Future<bool> exists(List<String> path) => client.isExist(_path(path));

  @override
  Future<void> upload(String localPath, List<String> remotePath) async {
    await client.mkdirAll(
      remotePath.sublist(0, remotePath.length - 1).join('/'),
    );
    await client.uploadFile(localPath, _path(remotePath), replace: false);
  }

  @override
  Future<void> download(List<String> remotePath, String localPath) =>
      client.downloadFile(_path(remotePath), localPath);
}

class AnnotationAudioAssetSyncResult {
  final int uploaded;
  final int downloaded;
  final int missing;

  const AnnotationAudioAssetSyncResult({
    this.uploaded = 0,
    this.downloaded = 0,
    this.missing = 0,
  });
}

class AnnotationAudioAssetSyncService {
  final AnnotationAudioAssetTransport transport;
  final AnnotationAudioAssetStore store;
  final String remoteRoot;

  AnnotationAudioAssetSyncService({
    required this.transport,
    required this.remoteRoot,
    AnnotationAudioAssetStore? store,
  }) : store = store ?? AnnotationAudioAssetStore();

  Future<AnnotationAudioAssetSyncResult> syncDocument(
    Map<String, dynamic> document,
  ) async {
    var uploaded = 0;
    var downloaded = 0;
    var missing = 0;
    for (final asset in annotationAudioAssets(document)) {
      final local = await store.contains(asset);
      final remotePath = annotationAudioAssetRemoteSegments(
        remoteRoot,
        asset.assetRef,
      );
      final remote = await transport.exists(remotePath);
      if (local && !remote) {
        await transport.upload(store.pathFor(asset.assetRef), remotePath);
        uploaded++;
      } else if (!local && remote) {
        final targetPath = store.pathFor(asset.assetRef);
        final partial = File('$targetPath.part');
        await partial.parent.create(recursive: true);
        if (await partial.exists()) await partial.delete();
        try {
          await transport.download(remotePath, partial.path);
          await store.installDownloaded(asset, partial.path);
          downloaded++;
        } finally {
          if (await partial.exists()) await partial.delete();
        }
      } else if (!local && !remote) {
        missing++;
      }
    }
    return AnnotationAudioAssetSyncResult(
      uploaded: uploaded,
      downloaded: downloaded,
      missing: missing,
    );
  }
}

Future<String> _fileDigest(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();
