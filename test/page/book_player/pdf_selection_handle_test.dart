import 'package:anx_reader/page/book_player/pdf_selection_handle.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';

void main() {
  testWidgets('empty padding around a PDF handle accepts drag gestures',
      (tester) async {
    var dragged = false;
    final text = PdfPageText(
        pageNumber: 1, fullText: 'a', charRects: const [], fragments: const []);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Center(child: Builder(builder: (context) {
        return GestureDetector(
          onPanStart: (_) => dragged = true,
          child: buildPdfSelectionHandle(
            context,
            PdfTextSelectionAnchor(const Rect.fromLTWH(0, 0, 12, 20),
                PdfTextDirection.ltr, PdfTextSelectionAnchorType.b, text, 0),
            PdfViewerTextSelectionAnchorHandleState.normal,
          ),
        );
      }))),
    ));
    final handle = find.byType(ColoredBox).last;
    expect(tester.getSize(handle), const Size(48, 48));
    await tester.dragFrom(tester.getBottomRight(handle) - const Offset(2, 2),
        const Offset(30, 0));
    expect(dragged, isTrue);
  });
}
