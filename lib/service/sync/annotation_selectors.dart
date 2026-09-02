class PdfTextMatch {
  const PdfTextMatch({required this.start, required this.end});

  final int start;
  final int end;
}

class PdfAnnotationTarget {
  const PdfAnnotationTarget({
    required this.page,
    required this.exact,
    required this.prefix,
    required this.suffix,
  });

  final int page;
  final String exact;
  final String prefix;
  final String suffix;

  factory PdfAnnotationTarget.fromPageText({
    required int page,
    required String pageText,
    required int start,
    required int end,
    int contextLength = 64,
  }) {
    if (page < 1 || start < 0 || end > pageText.length || start >= end) {
      throw RangeError('Invalid PDF text selection');
    }
    final raw = pageText.substring(start, end);
    final exact = raw.trim();
    if (exact.isEmpty) throw ArgumentError('PDF selection must contain text');
    final leading = raw.indexOf(exact);
    final exactStart = start + leading;
    final exactEnd = exactStart + exact.length;
    return PdfAnnotationTarget(
      page: page,
      exact: exact,
      prefix: pageText.substring(
        (exactStart - contextLength).clamp(0, exactStart),
        exactStart,
      ),
      suffix: pageText.substring(
        exactEnd,
        (exactEnd + contextLength).clamp(exactEnd, pageText.length),
      ),
    );
  }

  static PdfAnnotationTarget? fromSelectors(Object? value) {
    if (value is! List) return null;
    final pages = <int>{};
    final quotes = <({String exact, String prefix, String suffix})>{};
    for (final selector in value) {
      if (selector is! Map) continue;
      if (selector['type'] == 'pdf-page') {
        final page = selector['page'];
        if (page is int && page > 0) pages.add(page);
      } else if (selector['type'] == 'text-quote') {
        final exact = selector['exact'];
        final prefix = selector['prefix'];
        final suffix = selector['suffix'];
        if (exact is String &&
            exact.isNotEmpty &&
            (prefix == null || prefix is String) &&
            (suffix == null || suffix is String)) {
          quotes.add((
            exact: exact,
            prefix: prefix as String? ?? '',
            suffix: suffix as String? ?? '',
          ));
        }
      }
    }
    if (pages.length != 1 || quotes.length != 1) return null;
    final quote = quotes.single;
    return PdfAnnotationTarget(
      page: pages.single,
      exact: quote.exact,
      prefix: quote.prefix,
      suffix: quote.suffix,
    );
  }

  List<Map<String, Object?>> toSelectors() => [
        {'type': 'pdf-page', 'page': page},
        {
          'type': 'text-quote',
          'exact': exact,
          if (prefix.isNotEmpty) 'prefix': prefix,
          if (suffix.isNotEmpty) 'suffix': suffix,
        },
      ];

  PdfTextMatch? resolve(String pageText) {
    final candidates = <PdfTextMatch>[];
    var start = pageText.indexOf(exact);
    while (start >= 0) {
      final end = start + exact.length;
      final prefixMatches =
          prefix.isEmpty || pageText.substring(0, start).endsWith(prefix);
      final suffixMatches =
          suffix.isEmpty || pageText.substring(end).startsWith(suffix);
      if (prefixMatches && suffixMatches) {
        candidates.add(PdfTextMatch(start: start, end: end));
      }
      start = pageText.indexOf(exact, start + 1);
    }
    return candidates.length == 1 ? candidates.single : null;
  }
}
