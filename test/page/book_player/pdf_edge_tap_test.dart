import 'package:anx_reader/page/book_player/pdf_edge_tap.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';

void main() {
  test('top and bottom taps scroll, including corners', () {
    expect(pdfEdgeTapAction(x: 10, y: 30, viewWidth: 400, viewHeight: 800),
        PdfEdgeTapAction.scrollUp);
    expect(pdfEdgeTapAction(x: 390, y: 770, viewWidth: 400, viewHeight: 800),
        PdfEdgeTapAction.scrollDown);
    expect(pdfEdgeTapAction(x: 200, y: 400, viewWidth: 400, viewHeight: 800),
        isNull);
  });

  test('vertical taps overlap viewports and stop at cropped page bounds', () {
    const page = Rect.fromLTRB(20, 100, 420, 1600);
    expect(
        pdfVerticalTapTarget(
            viewport: const Rect.fromLTWH(30, 100, 200, 600),
            page: page,
            down: true),
        const Offset(130, 910));
    expect(
        pdfVerticalTapTarget(
            viewport: const Rect.fromLTWH(30, 900, 200, 600),
            page: page,
            down: true),
        const Offset(130, 1300));
    expect(
        pdfVerticalTapTarget(
            viewport: const Rect.fromLTWH(30, 300, 200, 600),
            page: page,
            down: false),
        const Offset(130, 400));
    expect(
        pdfVerticalTapTarget(
            viewport: const Rect.fromLTWH(30, 1000, 200, 600),
            page: page,
            down: true),
        isNull);
    expect(
        pdfVerticalTapTarget(
            viewport: const Rect.fromLTWH(30, 100, 200, 600),
            page: page,
            down: false),
        isNull);
    expect(
        pdfVerticalTapTarget(
            viewport: const Rect.fromLTWH(0, 0, 500, 1800),
            page: page,
            down: true),
        isNull);
  });

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
