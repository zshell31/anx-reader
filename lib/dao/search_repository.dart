import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/models/search_note_group.dart';
import 'package:anx_reader/models/search_result_data.dart';
import 'package:anx_reader/service/sync/annotation_catalog.dart';

class SearchRepository {
  const SearchRepository();

  Future<SearchResultData> search(
    String keyword, {
    int? bookId,
    DateTime? from,
    DateTime? to,
    int? limit,
  }) async {
    final query = keyword.trim();
    if (query.isEmpty) return SearchResultData.empty;

    final books = await bookDao.searchBooks(query);
    final canonicalBooks = await canonicalAnnotationCatalog.readAll();
    var remaining = limit ?? 0x7fffffff;
    final groups = <SearchNoteGroup>[];
    for (final annotationBook in canonicalBooks) {
      if (bookId != null && annotationBook.localBook?.id != bookId) continue;
      final matches = annotationBook.annotations.where((annotation) {
        if (remaining <= 0) return false;
        if (from != null && annotation.updatedAt.isBefore(from)) return false;
        if (to != null && annotation.updatedAt.isAfter(to)) return false;
        final personalNote = annotation.effectivePersonalNote?.content ?? '';
        final haystack = [
          annotation.selectedText,
          annotation.chapter ?? '',
          annotation.annotationContext ?? '',
          personalNote,
          ...annotation.activeEnrichments
              .map((enrichment) => enrichment.content ?? ''),
        ].join('\n').toLowerCase();
        if (!haystack.contains(query.toLowerCase())) return false;
        remaining--;
        return true;
      }).toList();
      if (matches.isNotEmpty) {
        groups.add(SearchNoteGroup(book: annotationBook, notes: matches));
      }
      if (remaining <= 0) break;
    }
    return SearchResultData(books: books, noteGroups: groups);
  }
}
