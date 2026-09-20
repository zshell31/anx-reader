import 'dart:io';
import 'package:anx_reader/service/sync/library_transfer_progress.dart';
import 'package:anx_reader/service/sync/library_asset_sync.dart';
import 'package:anx_reader/service/sync/sync_client_base.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _Client extends Fake implements SyncClientBase {
  bool fail = false;
  @override
  Future<void> mkdirAll(String path) async {}
  @override
  Future<void> uploadFile(String localPath, String remotePath,
      {bool replace = true,
      void Function(int, int)? onProgress,
      CancelToken? cancelToken}) async {
    onProgress!(5, 10);
    expect(libraryTransferProgress.snapshot[localPath]?.fraction, 0.5);
    if (fail) throw StateError('Upload failed');
    onProgress(10, 10);
  }
}

void main() {
  test(
      'late subscribers see current progress; concurrent uploads remain independent',
      () async {
    final progress = LibraryTransferProgress();
    progress.update('a', 5, 10);
    expect((await progress.stream.first)['a']?.fraction, 0.5);
    progress.update('b', 1, 10);
    progress.finish('a');
    expect(progress.snapshot.keys, ['b']);
    await progress.dispose();
  });
  test(
      'real transport publishes byte progress and clears it on success and failure',
      () async {
    final directory = await Directory.systemTemp.createTemp('anx-upload-test-');
    final file =
        await File('${directory.path}/book').writeAsBytes(List.filled(10, 0));
    final client = _Client();
    final transport = SyncClientLibraryAssetTransport(client);
    try {
      await transport.upload(file.path, ['assets', 'book']);
      expect(libraryTransferProgress.snapshot, isEmpty);
      client.fail = true;
      await expectLater(
          transport.upload(file.path, ['assets', 'book']), throwsStateError);
      expect(libraryTransferProgress.snapshot, isEmpty);
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
