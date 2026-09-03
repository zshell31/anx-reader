import 'dart:async';

import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/models/sync_status.dart';
import 'package:anx_reader/providers/sync.dart';
import 'package:anx_reader/service/sync/annotation_sync_runtime.dart';
import 'package:anx_reader/service/sync/sync_diagnostics.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'sync_status.g.dart';

@Riverpod(keepAlive: true)
class SyncStatus extends _$SyncStatus {
  List<Book> allBooksInBookShelf = [];
  StreamSubscription<void>? _assetChangesSubscription;
  bool _refreshing = false;
  bool _refreshAgain = false;

  @override
  Future<SyncStatusModel> build() async {
    final stopwatch = Stopwatch()..start();
    if (_assetChangesSubscription == null) {
      _assetChangesSubscription = annotationSyncRuntime.assetChanges.listen(
        (_) => unawaited(refresh()),
      );
      ref.onDispose(() => _assetChangesSubscription?.cancel());
    }
    allBooksInBookShelf = await bookDao.selectNotDeleteBooks();
    final entries = await Future.wait(allBooksInBookShelf.map((book) async => (
          book: book,
          value:
              await ref.read(syncProvider.notifier).bookAssetAvailability(book),
        )));
    List<int> ids(bool Function(BookAssetAvailability) include) => entries
        .where((entry) => include(entry.value))
        .map((entry) => entry.book.id)
        .toList();
    final result = SyncStatusModel(
      localOnly: ids((value) => value.localVerified && !value.remote),
      remoteOnly: ids(
          (value) => !value.localVerified && value.remote && !value.released),
      both: ids((value) => value.localVerified && value.remote),
      nonExistent: ids((value) => !value.localVerified && !value.remote),
      released: ids((value) => value.released),
      downloading: const [],
      uploading: const [],
    );
    syncDebug('asset-status books=${entries.length} '
        'localOnly=${result.localOnly.length} '
        'remoteOnly=${result.remoteOnly.length} both=${result.both.length} '
        'missing=${result.nonExistent.length} '
        'released=${result.released.length} '
        'durationMs=${stopwatch.elapsedMilliseconds}');
    return result;
  }

  Future<void> refresh() async {
    if (_refreshing) {
      _refreshAgain = true;
      return;
    }
    _refreshing = true;
    try {
      do {
        _refreshAgain = false;
        state = AsyncData(await build());
      } while (_refreshAgain);
    } finally {
      _refreshing = false;
    }
  }

  Future<int?> pathToBookId(String filePath) async {
    if (filePath.endsWith('.db')) return null;
    Book? match() => allBooksInBookShelf
        .where((book) => filePath.contains(book.filePath))
        .firstOrNull;
    var book = match();
    if (book == null) {
      allBooksInBookShelf = await bookDao.selectNotDeleteBooks();
      book = match();
    }
    return book?.id;
  }

  bool isCover(String filePath) => filePath.contains('/cover/');

  Future<void> addDownloading(String filePath) =>
      _updateProgress(filePath, downloading: true, add: true);

  Future<void> addUploading(String filePath) =>
      _updateProgress(filePath, downloading: false, add: true);

  Future<void> removeDownloading(String filePath) =>
      _updateProgress(filePath, downloading: true, add: false);

  Future<void> removeUploading(String filePath) =>
      _updateProgress(filePath, downloading: false, add: false);

  Future<void> _updateProgress(
    String filePath, {
    required bool downloading,
    required bool add,
  }) async {
    if (isCover(filePath)) return;
    final bookId = await pathToBookId(filePath);
    final current = state.value;
    if (bookId == null || current == null) return;
    List<int> update(List<int> values) => add
        ? {...values, bookId}.toList()
        : values.where((id) => id != bookId).toList();
    state = AsyncData(current.copyWith(
      downloading:
          downloading ? update(current.downloading) : current.downloading,
      uploading: downloading ? current.uploading : update(current.uploading),
      both: add ? current.both : {...current.both, bookId}.toList(),
    ));
    if (!add) ref.invalidateSelf();
  }
}
