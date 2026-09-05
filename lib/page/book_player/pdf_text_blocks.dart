import 'dart:collection';

class PdfPageTextSource {
  const PdfPageTextSource({
    required this.pageNumber,
    required this.fullText,
    this.lines = const [],
  });

  final int pageNumber;
  final String fullText;
  final List<PdfTextLine> lines;
}

/// Line geometry in PDF coordinates (the vertical axis points upwards).
class PdfTextLine {
  const PdfTextLine({
    required this.start,
    required this.left,
    required this.right,
    required this.top,
    required this.bottom,
  });

  final int start;
  final double left;
  final double right;
  final double top;
  final double bottom;
}

class PdfTextBlock {
  const PdfTextBlock({
    required this.pageNumber,
    required this.blockIndex,
    required this.sourceStart,
    required this.sourceEnd,
    required this.text,
  });

  final int pageNumber;
  final int blockIndex;
  final int sourceStart;
  final int sourceEnd;
  final String text;
}

typedef PdfPageTextSourceLoader = Future<PdfPageTextSource> Function(
  int pageNumber,
);

class PdfTextBlockPageLoader {
  PdfTextBlockPageLoader({required PdfPageTextSourceLoader loadPageText})
      : _loadPageText = loadPageText;

  final PdfPageTextSourceLoader _loadPageText;
  final Map<int, Future<List<PdfTextBlock>>> _pages = {};

  Future<List<PdfTextBlock>> loadPage(int pageNumber) {
    if (pageNumber < 1) {
      return Future.error(
        RangeError.range(pageNumber, 1, null, 'pageNumber'),
      );
    }
    return _pages.putIfAbsent(pageNumber, () async {
      try {
        final source = await _loadPageText(pageNumber);
        if (source.pageNumber != pageNumber) {
          throw StateError(
            'Requested PDF page $pageNumber but loaded ${source.pageNumber}',
          );
        }
        return UnmodifiableListView(extractPdfTextBlocks(source));
      } catch (_) {
        _pages.remove(pageNumber);
        rethrow;
      }
    });
  }

  void invalidatePage(int pageNumber) => _pages.remove(pageNumber);

  void clear() => _pages.clear();
}

List<PdfTextBlock> extractPdfTextBlocks(PdfPageTextSource source) {
  if (source.pageNumber < 1) {
    throw RangeError.range(source.pageNumber, 1, null, 'pageNumber');
  }
  final text = source.fullText;
  final blocks = <PdfTextBlock>[];
  final boundaries = <int>{
    ...RegExp(r'(?:\r?\n)[\t ]*(?:\r?\n)+')
        .allMatches(text)
        .map((match) => match.end),
  };
  final lines = source.lines;
  for (var i = 1; i < lines.length; i++) {
    final previous = lines[i - 1];
    final current = lines[i];
    final height = (previous.top - previous.bottom).abs();
    if (height <= 0 || current.start <= 0 || current.start >= text.length) {
      continue;
    }
    final gap = previous.bottom - current.top;
    final indent = current.left - previous.left;
    final currentHeight = (current.top - current.bottom).abs();
    final gapScale =
        currentHeight > 0 && currentHeight < height ? currentHeight : height;
    final columnTransition = current.top > previous.top + height ||
        current.left > previous.right + height;
    final continuesSentence = RegExp(r'^\p{Ll}', unicode: true)
            .hasMatch(text.substring(current.start).trimLeft()) &&
        !RegExp(r'[.!?:;][\s”’"\x27]*$')
            .hasMatch(text.substring(previous.start, current.start));
    // A larger vertical gap, a first-line indent, or a column transition.
    // Ordinary wrapped lines remain in the same paragraph.
    if (columnTransition && continuesSentence) continue;
    if (gap > gapScale * 0.8 ||
        (indent > height * 0.7 && indent < height * 4) ||
        columnTransition) {
      boundaries.add(current.start);
    }
  }
  var start = 0;

  void addBlock(int rawStart, int rawEnd) {
    while (rawStart < rawEnd && _isWhitespace(text.codeUnitAt(rawStart))) {
      rawStart++;
    }
    while (rawEnd > rawStart && _isWhitespace(text.codeUnitAt(rawEnd - 1))) {
      rawEnd--;
    }
    if (rawStart == rawEnd) return;
    final normalized = _normalizePdfParagraph(text.substring(rawStart, rawEnd));
    if (normalized.isEmpty) return;
    blocks.add(PdfTextBlock(
      pageNumber: source.pageNumber,
      blockIndex: blocks.length,
      sourceStart: rawStart,
      sourceEnd: rawEnd,
      text: normalized,
    ));
  }

  for (final boundary in boundaries.toList()..sort()) {
    addBlock(start, boundary);
    start = boundary;
  }
  addBlock(start, text.length);
  return blocks;
}

String _normalizePdfParagraph(String value) {
  final lines = value.split(RegExp(r'\r?\n'));
  var output = '';
  for (var index = 0; index < lines.length; index++) {
    final line = lines[index].trim().replaceAll(RegExp(r'[\t ]+'), ' ');
    if (line.isEmpty) continue;
    if (output.isNotEmpty) {
      if (output.endsWith('-')) {
        if (RegExp(r'^\p{Ll}', unicode: true).hasMatch(line)) {
          output = output.substring(0, output.length - 1);
        }
      } else {
        output += ' ';
      }
    }
    output += line;
  }
  return output;
}

bool _isWhitespace(int codeUnit) =>
    codeUnit == 0x09 ||
    codeUnit == 0x0a ||
    codeUnit == 0x0b ||
    codeUnit == 0x0c ||
    codeUnit == 0x0d ||
    codeUnit == 0x20;
