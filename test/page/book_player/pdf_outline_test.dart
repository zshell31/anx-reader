import 'package:anx_reader/page/book_player/pdf_outline.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';

void main() {
  test('converts nested PDF outline to reader contents items', () {
    const chapter = PdfOutlineNode(
      title: 'Chapter 1',
      dest: PdfDest(3, PdfDestCommand.fit, null),
      children: [
        PdfOutlineNode(
          title: 'Section 1.1',
          dest: PdfDest(5, PdfDestCommand.xyz, [12, 34, 2]),
          children: [],
        ),
      ],
    );

    final result = buildPdfOutlineToc([chapter], 10);

    expect(result.items.single.label, 'Chapter 1');
    expect(result.items.single.startPage, 3);
    expect(result.items.single.startPercentage, 0.2);
    expect(result.items.single.subitems.single.level, 1);
    expect(
      result.destinations[result.items.single.subitems.single.href],
      const PdfDest(5, PdfDestCommand.xyz, [12, 34, 2]),
    );
  });

  test('keeps grouping nodes without inventing a destination', () {
    const group = PdfOutlineNode(
      title: 'Part',
      dest: null,
      children: [],
    );

    final result = buildPdfOutlineToc([group], 8);

    expect(result.items.single.startPage, 0);
    expect(result.destinations, isEmpty);
  });
}
