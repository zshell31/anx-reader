import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';

void main() {
  List<PdfRect> lines(String text, List<PdfRect> rects) => PdfPageTextRange(
        pageText: PdfPageText(
          pageNumber: 1,
          fullText: text,
          charRects: rects,
          fragments: const [],
        ),
        start: 0,
        end: text.length,
      ).enumerateLineBoundingRects().toList();

  test('unifies adjacent glyphs with different heights', () {
    expect(
        lines('abc', const [
          PdfRect(0, 10, 4, 0),
          PdfRect(5, 8, 9, 1),
          PdfRect(10, 11, 14, -1),
        ]),
        const [PdfRect(0, 11, 14, -1)]);
  });

  test('keeps lines and columns separate', () {
    expect(
        lines('abcd', const [
          PdfRect(0, 30, 4, 20),
          PdfRect(5, 30, 9, 20),
          PdfRect(0, 15, 4, 5),
          PdfRect(60, 15, 64, 5),
        ]),
        const [
          PdfRect(0, 30, 9, 20),
          PdfRect(0, 15, 4, 5),
          PdfRect(60, 15, 64, 5),
        ]);
  });

  test('respects line breaks and right to left text', () {
    expect(
        lines('ab\nc', const [
          PdfRect(5, 10, 9, 0),
          PdfRect(0, 10, 4, 0),
          PdfRect(0, 0, 0, 0),
          PdfRect(0, 10, 4, 0),
        ]),
        const [PdfRect(0, 10, 9, 0), PdfRect(0, 10, 4, 0)]);
  });
}
