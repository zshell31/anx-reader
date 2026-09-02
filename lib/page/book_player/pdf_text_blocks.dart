import 'dart:collection';

class PdfPageTextSource {
  const PdfPageTextSource({required this.pageNumber, required this.fullText});

  final int pageNumber;
  final String fullText;
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
  final separators = RegExp(r'(?:\r?\n)[\t ]*(?:\r?\n)+').allMatches(text);
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

  for (final separator in separators) {
    addBlock(start, separator.start);
    start = separator.end;
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
