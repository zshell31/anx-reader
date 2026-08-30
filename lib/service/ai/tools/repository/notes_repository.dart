import 'package:anx_reader/service/sync/annotation_catalog.dart';
import 'package:anx_reader/service/sync/annotation_read_model.dart';

class NoteSearchResult {
  NoteSearchResult({required this.book, required this.note});

  final AnnotationBookUiModel book;
  final AnnotationUiModel note;

  Map<String, dynamic> toMap() => {
        if (book.localBook != null) 'bookId': book.localBook!.id,
        'bookFingerprint': book.fingerprint,
        'bookTitle': book.title,
        'author': book.author,
        'annotationId': note.ref.annotationId,
        'chapter': note.chapter,
        'snippet': _buildSnippet(),
        'content': note.selectedText,
        'personalNote': note.effectivePersonalNote?.content,
        'cfi': note.epubCfi,
        'updatedAt': note.updatedAt.toIso8601String(),
      };

  String _buildSnippet() {
    final personalNote = note.effectivePersonalNote?.content?.trim();
    if (personalNote?.isNotEmpty == true) return personalNote!;
    final content = note.selectedText.trim();
    return content.length > 160 ? '${content.substring(0, 157)}…' : content;
  }
}

class NotesRepository {
  const NotesRepository();

  Future<List<NoteSearchResult>> searchNotes({
    String? keyword,
    int? bookId,
    DateTime? from,
    DateTime? to,
    int limit = 10,
  }) async {
    final query = keyword?.trim().toLowerCase();
    final results = <NoteSearchResult>[];
    for (final book in await canonicalAnnotationCatalog.readAll()) {
      if (bookId != null && book.localBook?.id != bookId) continue;
      for (final note in book.annotations) {
        if (from != null && note.updatedAt.isBefore(from)) continue;
        if (to != null && note.updatedAt.isAfter(to)) continue;
        if (query?.isNotEmpty == true) {
          final text = [
            note.selectedText,
            note.chapter ?? '',
            note.annotationContext ?? '',
            note.effectivePersonalNote?.content ?? '',
            ...note.activeEnrichments.expand((item) => item.searchableText),
          ].join('\n').toLowerCase();
          if (!text.contains(query!)) continue;
        }
        results.add(NoteSearchResult(book: book, note: note));
        if (results.length >= limit) return results;
      }
    }
    return results;
  }
}
