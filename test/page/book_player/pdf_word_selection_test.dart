import 'package:anx_reader/page/book_player/pdf_word_selection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('selects only the touched word inside a paragraph fragment', () {
    const text = 'present at last a fresh new version';

    final range = pdfWordRangeAt(text, text.indexOf('last') + 1);

    expect(range?.textInside(text), 'last');
  });

  test('uses Unicode-aware word boundaries', () {
    const text = 'Привет, читатель!';

    final range = pdfWordRangeAt(text, text.indexOf('читатель') + 2);

    expect(range?.textInside(text), 'читатель');
  });

  test('finds the closest character within the hit fragment', () {
    const bounds = PdfRect(0, 10, 40, 0);
    final pageText = PdfPageText(
      pageNumber: 1,
      fullText: 'at last',
      charRects: const [
        PdfRect(0, 10, 5, 0),
        PdfRect(5, 10, 10, 0),
        PdfRect(10, 10, 15, 0),
        PdfRect(15, 10, 20, 0),
        PdfRect(20, 10, 25, 0),
        PdfRect(25, 10, 30, 0),
        PdfRect(30, 10, 35, 0),
      ],
      fragments: const [],
    );
    final fragment = PdfPageTextFragment(
      pageText: pageText,
      index: 0,
      length: 7,
      bounds: bounds,
      charRects: pageText.charRects,
      direction: PdfTextDirection.ltr,
    );
    final structured = PdfPageText(
      pageNumber: 1,
      fullText: pageText.fullText,
      charRects: pageText.charRects,
      fragments: [fragment],
    );

    expect(findPdfCharacterIndex(structured, const PdfPoint(27, 5)), 5);
  });
}
