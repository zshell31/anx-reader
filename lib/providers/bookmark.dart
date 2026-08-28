import 'package:anx_reader/dao/database.dart';
import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/models/bookmark.dart';
import 'package:anx_reader/models/book_note.dart';
import 'package:anx_reader/page/reading_page.dart';
import 'package:anx_reader/service/sync/annotation_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'bookmark.g.dart';

@Riverpod(keepAlive: true)
class Bookmark extends _$Bookmark {
  @override
  Future<List<BookmarkModel>> build(int bookId) async {
    final db = await DBHelper().database;
    final List<Map<String, dynamic>> maps = await db.query('tb_notes',
        where: 'type = ? AND book_id = ?', whereArgs: ['bookmark', bookId]);

    return List.generate(maps.length, (i) {
      return BookmarkModel(
        id: maps[i]['id'],
        bookId: maps[i]['book_id'],
        content: maps[i]['content'],
        cfi: maps[i]['cfi'],
        percentage: double.tryParse(maps[i]['color']) ?? 0.0,
        chapter: maps[i]['chapter'],
        sharedAnnotationId: maps[i]['shared_annotation_id'] as String?,
        createTime: DateTime.parse(maps[i]['create_time']),
        updateTime: DateTime.parse(maps[i]['update_time']),
      );
    });
  }

  void refreshBookmarks() {
    ref.invalidateSelf();
  }

  Future<BookmarkModel> addBookmark(BookmarkModel bookmark) async {
    final db = await DBHelper().database;

    final List<Map<String, dynamic>> maps = await db.query('tb_notes',
        where: 'cfi = ? AND book_id = ? AND type = ?',
        whereArgs: [bookmark.cfi, bookId, 'bookmark']);
    if (maps.isEmpty) {
      final book = await BookDao().selectBookById(bookId);
      final projection = await annotationRepository.createBookmark(
        BookmarkCreation(
          book: book,
          content: bookmark.content,
          epubCfi: bookmark.cfi,
          chapter: bookmark.chapter,
          percentage: bookmark.percentage,
        ),
      );

      bookmark = bookmark.copyWith(
        id: projection.id,
        sharedAnnotationId: projection.sharedAnnotationId,
        createTime: projection.createTime,
        updateTime: projection.updateTime,
      );
      List<BookmarkModel> newState = [
        ...state.valueOrNull ?? [],
        bookmark,
      ];

      newState.sort((a, b) => a.percentage.compareTo(b.percentage));
      state = AsyncData(newState);
    }

    return bookmark;
  }

  Future<void> removeBookmark({int? id, String? cfi}) async {
    assert(id != null || cfi != null, 'Either id or cfi must be provided');
    assert(!(id != null && cfi != null),
        'Only one of id or cfi should be provided');

    final bookmarks = state.valueOrNull ?? const <BookmarkModel>[];
    final matches = bookmarks.where(
        (bookmark) => id != null ? bookmark.id == id : bookmark.cfi == cfi);
    if (matches.isEmpty) return;
    final bookmark = matches.first;
    id = bookmark.id;
    if (id == null) return;
    await annotationRepository.tombstoneAnnotation(
      BookNote(
        id: bookmark.id,
        bookId: bookmark.bookId,
        content: bookmark.content,
        cfi: bookmark.cfi,
        chapter: bookmark.chapter,
        type: 'bookmark',
        color: bookmark.percentage.toString(),
        sharedAnnotationId: bookmark.sharedAnnotationId,
        createTime: bookmark.createTime,
        updateTime: bookmark.updateTime,
      ),
    );

    final newState = bookmarks.where((value) => value.id != id).toList();
    state = AsyncData(newState);
    epubPlayerKey.currentState?.removeAnnotation(bookmark.cfi, id: bookmark.id);
  }
}
