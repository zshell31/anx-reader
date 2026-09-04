import 'package:anx_reader/page/book_player/pdf_edge_tap.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('maps the left and right edge to page turns', () {
    expect(
      pdfEdgeTapAction(x: 40, viewWidth: 400),
      PdfEdgeTapAction.previousPage,
    );
    expect(
      pdfEdgeTapAction(x: 360, viewWidth: 400),
      PdfEdgeTapAction.nextPage,
    );
    expect(pdfEdgeTapAction(x: 200, viewWidth: 400), isNull);
  });

  test('caps edge zones on wide layouts', () {
    expect(pdfEdgeTapAction(x: 95, viewWidth: 1200), isNotNull);
    expect(pdfEdgeTapAction(x: 100, viewWidth: 1200), isNull);
  });

  test('does not overlap edge zones in a narrow viewport', () {
    expect(
      pdfEdgeTapAction(x: 20, viewWidth: 80),
      PdfEdgeTapAction.previousPage,
    );
    expect(
      pdfEdgeTapAction(x: 60, viewWidth: 80),
      PdfEdgeTapAction.nextPage,
    );
  });
}
