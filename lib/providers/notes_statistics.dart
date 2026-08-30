import 'package:anx_reader/dao/reading_time.dart';
import 'package:anx_reader/service/sync/annotation_catalog.dart';
import 'package:anx_reader/service/sync/annotation_sync_runtime.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'notes_statistics.g.dart';

final canonicalAnnotationBooksProvider =
    StreamProvider<List<AnnotationBookUiModel>>((ref) async* {
  yield await canonicalAnnotationCatalog.readAll();
  await for (final _ in annotationSyncRuntime.annotationChanges) {
    yield await canonicalAnnotationCatalog.readAll();
  }
});

class AnnotationBookNotesSummary {
  final AnnotationBookUiModel book;
  final int readingTime;

  const AnnotationBookNotesSummary({
    required this.book,
    required this.readingTime,
  });
}

@riverpod
class NotesStatistics extends _$NotesStatistics {
  @override
  Future<Map<String, int>> build() async {
    final books = await ref.watch(canonicalAnnotationBooksProvider.future);
    return _getNotesStatistics(books);
  }

  Map<String, int> _getNotesStatistics(List<AnnotationBookUiModel> books) {
    return {
      'numberOfNotes':
          books.fold(0, (count, book) => count + book.annotations.length),
      'numberOfBooks': books.length,
    };
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    ref.invalidate(canonicalAnnotationBooksProvider);
    state = AsyncValue.data(_getNotesStatistics(
        await ref.read(canonicalAnnotationBooksProvider.future)));
  }
}

@riverpod
class BookIdAndNotes extends _$BookIdAndNotes {
  @override
  Future<List<AnnotationBookNotesSummary>> build() async {
    final books = await ref.watch(canonicalAnnotationBooksProvider.future);
    final result = <AnnotationBookNotesSummary>[];
    for (final annotationBook in books) {
      final localBook = annotationBook.localBook;
      final readingTime = localBook == null
          ? 0
          : await readingTimeDao.selectTotalReadingTimeByBookId(localBook.id);
      result.add(AnnotationBookNotesSummary(
        book: annotationBook,
        readingTime: readingTime,
      ));
    }
    return result;
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    ref.invalidate(canonicalAnnotationBooksProvider);
    state = AsyncValue.data(await build());
  }
}

@riverpod
class BookReadingTime extends _$BookReadingTime {
  @override
  Future<int> build(int bookId) async {
    return _getBookReadingTime(bookId);
  }

  Future<int> _getBookReadingTime(int bookId) async {
    return await readingTimeDao.selectTotalReadingTimeByBookId(bookId);
  }

  Future<void> refresh(int bookId) async {
    state = const AsyncValue.loading();
    state = AsyncValue.data(await _getBookReadingTime(bookId));
  }
}
