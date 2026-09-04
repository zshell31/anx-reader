import 'package:anx_reader/page/book_player/pdf_viewport.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('refits only after a material viewport width change', () {
    expect(shouldRefitPdfViewport(const Size(800, 600), null), isFalse);
    expect(
      shouldRefitPdfViewport(
        const Size(800.4, 600),
        const Size(800, 600),
      ),
      isFalse,
    );
    expect(
      shouldRefitPdfViewport(
        const Size(600, 800),
        const Size(800, 600),
      ),
      isTrue,
    );
  });
}
