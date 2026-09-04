import 'package:anx_reader/page/book_player/pdf_selection.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';

void main() {
  test('joins cross-page fragments without separating punctuation', () {
    expect(
      joinPdfSelectionParts(['The sentence', 'continues', '.']),
      'The sentence continues.',
    );
    expect(joinPdfSelectionParts(['hyphen-', 'ated']), 'hyphen-ated');
  });

  test('recognizes only a centered page number at a page edge', () {
    expect(
      isPdfPageNumberFragment(
        text: ' 5 ',
        pageNumber: 5,
        bounds: const PdfRect(290, 20, 310, 10),
        pageSize: const Size(600, 800),
      ),
      isTrue,
    );
    expect(
      isPdfPageNumberFragment(
        text: '5',
        pageNumber: 5,
        bounds: const PdfRect(100, 420, 120, 400),
        pageSize: const Size(600, 800),
      ),
      isFalse,
    );
    expect(
      isPdfPageNumberFragment(
        text: '2023',
        pageNumber: 5,
        bounds: const PdfRect(290, 20, 310, 10),
        pageSize: const Size(600, 800),
      ),
      isFalse,
    );
  });
}
