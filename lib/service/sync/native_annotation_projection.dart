import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/dao/book_note.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/models/book_note.dart';

/// The deliberately narrow native boundary needed by M4C.
///
/// Canonical mutation belongs to the later M4D repository. This interface only
/// exposes legacy discovery and rebuildable BookNote projection operations.
abstract interface class NativeAnnotationProjectionStore {
  Future<List<BookNote>> enumerateLegacyUnboundNotes();

  Future<Book?> readBook(int localBookId);

  Future<List<Book>> findBooksByFingerprint(String fingerprint);

  Future<void> bindSharedAnnotation(int nativeNoteId, String annotationId);

  Future<BookNote?> findBySharedAnnotationId(String annotationId);

  Future<int> insertProjection(BookNote note);

  Future<void> updateProjection(BookNote note);

  Future<void> deleteProjection(int nativeNoteId);
}

class DaoNativeAnnotationProjectionStore
    implements NativeAnnotationProjectionStore {
  final BookNoteDao notes;
  final BookDao books;

  DaoNativeAnnotationProjectionStore({BookNoteDao? notes, BookDao? books})
      : notes = notes ?? BookNoteDao(),
        books = books ?? BookDao();

  @override
  Future<List<BookNote>> enumerateLegacyUnboundNotes() =>
      notes.selectUnboundAnnotations();

  @override
  Future<Book?> readBook(int localBookId) async {
    try {
      return await books.selectBookById(localBookId);
    } on StateError {
      return null;
    }
  }

  @override
  Future<List<Book>> findBooksByFingerprint(String fingerprint) =>
      books.selectBooksByFingerprint(fingerprint);

  @override
  Future<void> bindSharedAnnotation(int nativeNoteId, String annotationId) =>
      notes.bindSharedAnnotation(nativeNoteId, annotationId);

  @override
  Future<BookNote?> findBySharedAnnotationId(String annotationId) =>
      notes.selectBySharedAnnotationId(annotationId);

  @override
  Future<int> insertProjection(BookNote note) =>
      notes.insertSharedProjection(note);

  @override
  Future<void> updateProjection(BookNote note) =>
      notes.updateBookNoteById(note);

  @override
  Future<void> deleteProjection(int nativeNoteId) =>
      notes.deleteBookNoteById(nativeNoteId);
}
