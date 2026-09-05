class PdfTextMatch {
  const PdfTextMatch({required this.start, required this.end});

  final int start;
  final int end;
}

class PdfAnnotationPageTarget {
  const PdfAnnotationPageTarget({
    required this.page,
    required this.exact,
    required this.prefix,
    required this.suffix,
  });

  final int page;
  final String exact;
  final String prefix;
  final String suffix;

  factory PdfAnnotationPageTarget.fromPageText({
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
    return PdfAnnotationPageTarget(
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

  PdfTextMatch? resolve(String pageText) {
    final normalized = _NormalizedPdfText(pageText);
    final quote = _NormalizedPdfText(exact).text;
    final before = _NormalizedPdfText(prefix).text;
    final after = _NormalizedPdfText(suffix).text;
    if (quote.trim().isEmpty) return null;
    final candidates = <PdfTextMatch>[];
    var start = normalized.text.indexOf(quote);
    while (start >= 0) {
      final end = start + quote.length;
      final prefixMatches = before.isEmpty ||
          normalized.text.substring(0, start).endsWith(before);
      final suffixMatches =
          after.isEmpty || normalized.text.substring(end).startsWith(after);
      if (prefixMatches && suffixMatches) {
        candidates.add(PdfTextMatch(
          start: normalized.starts[start],
          end: normalized.ends[end - 1],
        ));
      }
      start = normalized.text.indexOf(quote, start + 1);
    }
    return candidates.length == 1 ? candidates.single : null;
  }

  Map<String, Object?> toJson() => {
        'page': page,
        'exact': exact,
        if (prefix.isNotEmpty) 'prefix': prefix,
        if (suffix.isNotEmpty) 'suffix': suffix,
      };

  static PdfAnnotationPageTarget? fromJson(Object? value) {
    if (value is! Map) return null;
    final page = value['page'];
    final exact = value['exact'];
    final prefix = value['prefix'];
    final suffix = value['suffix'];
    if (page is! int ||
        page < 1 ||
        exact is! String ||
        exact.isEmpty ||
        (prefix != null && prefix is! String) ||
        (suffix != null && suffix is! String)) {
      return null;
    }
    return PdfAnnotationPageTarget(
      page: page,
      exact: exact,
      prefix: prefix as String? ?? '',
      suffix: suffix as String? ?? '',
    );
  }
}

/// PDF.js and PDFium emit different whitespace for the same visual lines.
/// Keep UTF-16 source offsets so matches still address PDFium's glyph ranges.
class _NormalizedPdfText {
  _NormalizedPdfText(String source) {
    final buffer = StringBuffer();
    for (final match in RegExp(r'\s+|\S').allMatches(source)) {
      buffer.write(match.group(0)!.trim().isEmpty ? ' ' : match.group(0));
      starts.add(match.start);
      ends.add(match.end);
    }
    text = buffer.toString();
  }

  late final String text;
  final starts = <int>[];
  final ends = <int>[];
}

class PdfAnnotationTarget {
  const PdfAnnotationTarget({
    required this.page,
    required this.exact,
    required this.prefix,
    required this.suffix,
    this.pageOffsetRatio,
    this.firstPageTarget,
    this.additionalPageTargets = const [],
  });

  final int page;
  final String exact;
  final String prefix;
  final String suffix;
  final double? pageOffsetRatio;
  final PdfAnnotationPageTarget? firstPageTarget;
  final List<PdfAnnotationPageTarget> additionalPageTargets;

  List<PdfAnnotationPageTarget> get pageTargets => [
        firstPageTarget ??
            PdfAnnotationPageTarget(
              page: page,
              exact: exact,
              prefix: prefix,
              suffix: suffix,
            ),
        ...additionalPageTargets,
      ];

  int get endPage => pageTargets.last.page;

  factory PdfAnnotationTarget.fromPageTargets({
    required List<PdfAnnotationPageTarget> targets,
    required String exact,
    double? pageOffsetRatio,
  }) {
    if (targets.isEmpty || exact.trim().isEmpty) {
      throw ArgumentError('PDF selection must contain page targets and text');
    }
    final first = targets.first;
    return PdfAnnotationTarget(
      page: first.page,
      exact: exact.trim(),
      prefix: first.prefix,
      suffix: targets.last.suffix,
      pageOffsetRatio: pageOffsetRatio,
      firstPageTarget: first,
      additionalPageTargets: targets.skip(1).toList(growable: false),
    );
  }

  factory PdfAnnotationTarget.fromPageText({
    required int page,
    required String pageText,
    required int start,
    required int end,
    int contextLength = 64,
    double? pageOffsetRatio,
  }) {
    if (page < 1 || start < 0 || end > pageText.length || start >= end) {
      throw RangeError('Invalid PDF text selection');
    }
    final target = PdfAnnotationPageTarget.fromPageText(
      page: page,
      pageText: pageText,
      start: start,
      end: end,
      contextLength: contextLength,
    );
    return PdfAnnotationTarget(
      page: target.page,
      exact: target.exact,
      prefix: target.prefix,
      suffix: target.suffix,
      pageOffsetRatio: pageOffsetRatio,
    );
  }

  static PdfAnnotationTarget? fromSelectors(Object? value,
      {String? legacySelectedText}) {
    if (value is! List) return null;
    // Old Lingua annotations have only a page selector. Derive a local
    // render target without rewriting their shared annotation document.
    if (legacySelectedText != null &&
        legacySelectedText.trim().isNotEmpty &&
        value.isNotEmpty &&
        value.every((item) => item is Map && item['type'] == 'pdf-page')) {
      value = [
        ...value,
        {'type': 'text-quote', 'exact': legacySelectedText.trim()},
      ];
    }
    final pages = <int>{};
    double? pageOffsetRatio;
    final quotes = <({String exact, String prefix, String suffix})>{};
    List<PdfAnnotationPageTarget>? rangeTargets;
    var rangeSelectorCount = 0;
    for (final selector in value) {
      if (selector is! Map) continue;
      if (selector['type'] == 'pdf-page') {
        final page = selector['page'];
        if (page is int && page > 0) pages.add(page);
        final rawOffset = selector['pageOffsetRatio'];
        if (rawOffset is num && rawOffset.isFinite) {
          pageOffsetRatio = rawOffset.toDouble().clamp(0, 1);
        }
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
      } else if (selector['type'] == 'anx-pdf-page-range') {
        rangeSelectorCount++;
        final fragments = selector['fragments'];
        if (fragments is List) {
          final parsed = fragments
              .map(PdfAnnotationPageTarget.fromJson)
              .whereType<PdfAnnotationPageTarget>()
              .toList();
          if (parsed.length == fragments.length && parsed.isNotEmpty) {
            rangeTargets = parsed;
          }
        }
      }
    }
    if (pages.length != 1 || quotes.length != 1) return null;
    if (rangeSelectorCount > 1 ||
        (rangeSelectorCount == 1 && rangeTargets == null)) {
      return null;
    }
    final quote = quotes.single;
    if (rangeTargets != null) {
      if (rangeTargets.first.page != pages.single) return null;
      for (var index = 1; index < rangeTargets.length; index++) {
        if (rangeTargets[index].page < rangeTargets[index - 1].page) {
          return null;
        }
      }
      return PdfAnnotationTarget.fromPageTargets(
        targets: rangeTargets,
        exact: quote.exact,
        pageOffsetRatio: pageOffsetRatio,
      );
    }
    return PdfAnnotationTarget(
      page: pages.single,
      exact: quote.exact,
      prefix: quote.prefix,
      suffix: quote.suffix,
      pageOffsetRatio: pageOffsetRatio,
    );
  }

  List<Map<String, Object?>> toSelectors() => [
        {
          'type': 'pdf-page',
          'page': page,
          if (pageOffsetRatio != null) 'pageOffsetRatio': pageOffsetRatio,
        },
        {
          'type': 'text-quote',
          'exact': exact,
          if (prefix.isNotEmpty) 'prefix': prefix,
          if (suffix.isNotEmpty) 'suffix': suffix,
        },
        if (firstPageTarget != null)
          {
            'type': 'anx-pdf-page-range',
            'fragments': pageTargets.map((target) => target.toJson()).toList(),
          },
      ];

  PdfTextMatch? resolve(String pageText) {
    return pageTargets.first.resolve(pageText);
  }
}
