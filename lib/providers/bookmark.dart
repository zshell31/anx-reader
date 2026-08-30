import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/models/bookmark.dart';
import 'package:anx_reader/service/sync/annotation_catalog.dart';
import 'package:anx_reader/service/sync/annotation_read_model.dart';
import 'package:anx_reader/service/sync/annotation_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'bookmark.g.dart';

@Riverpod(keepAlive: true)
class Bookmark extends _$Bookmark {
  @override
  Future<List<BookmarkModel>> build(int bookId) async {
    final book = await bookDao.selectBookById(bookId);
    if (book.md5 == null) return const [];
    final annotationBook = await canonicalAnnotationCatalog.readBook(book.md5!);
    if (annotationBook == null) return const [];
    return [
      for (final annotation in annotationBook.annotations)
        if (annotation.motivation == AnnotationMotivation.bookmark &&
            annotation.epubCfi != null)
          BookmarkModel(
            ref: annotation.ref,
            bookId: bookId,
            content: annotation.selectedText,
            cfi: annotation.epubCfi!,
            chapter: annotation.chapter ?? '',
            createTime: annotation.createdAt,
            updateTime: annotation.updatedAt,
          ),
    ];
  }

  void refreshBookmarks() => ref.invalidateSelf();

  Future<BookmarkModel> addBookmark(BookmarkModel bookmark) async {
    final existing = state.valueOrNull ?? const <BookmarkModel>[];
    final book = await bookDao.selectBookById(bookId);
    final result = await annotationRepository.createBookmark(
      BookmarkCreation(
        book: book,
        content: bookmark.content,
        epubCfi: bookmark.cfi,
        chapter: bookmark.chapter,
        percentage: bookmark.percentage ?? 0,
      ),
    );
    final created = bookmark.copyWith(ref: result.ref);
    state = AsyncData([...existing, created]);
    return created;
  }

  Future<void> removeBookmark(AnnotationRef annotationRef) async {
    await annotationRepository.tombstoneAnnotation(annotationRef);
    state = AsyncData((state.valueOrNull ?? const <BookmarkModel>[])
        .where((bookmark) => bookmark.ref != annotationRef)
        .toList());
  }
}
