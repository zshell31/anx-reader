/// Shared RFC chapter rules. Outline entries retain depth-first source order.
class PdfChapter {
  const PdfChapter({required this.page, required this.title});
  final int page;
  final String title;
}

int? annotationPdfPage(List selectors) {
  final pages =
      selectors.whereType<Map>().where((s) => s['type'] == 'pdf-page').toList();
  if (pages.length != 1) return null;
  final page = pages.single['page'];
  return page is int && page > 0 && page <= 9007199254740991 ? page : null;
}

String pdfChapterAt(int page, Iterable<PdfChapter> outline) {
  PdfChapter? current;
  for (final item in outline) {
    if (item.page > 0 &&
        item.page <= page &&
        item.title.trim().isNotEmpty &&
        (current == null || item.page >= current.page)) {
      current = item;
    }
  }
  return current?.title.trim() ?? 'Page $page';
}

String? annotationChapterLabel(Object? chapter, List selectors,
    {Iterable<PdfChapter>? outline}) {
  final label = chapter is String && chapter.trim().isNotEmpty ? chapter : null;
  final page = annotationPdfPage(selectors);
  if (page == null) return label;
  if (outline != null) return pdfChapterAt(page, outline);
  return label == null ||
          RegExp(r'^(?:Страница \d+|Page \d+|Pages \d+-\d+)$')
              .hasMatch(label.trim())
      ? 'Page $page'
      : label;
}
