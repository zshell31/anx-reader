import 'dart:convert';
import 'dart:io';
import 'package:anx_reader/page/book_player/pdf_selection.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';

void main() {
  for (final fixture in jsonDecode(
      File('protocol/notes-rfc/fixtures/editor/pdf-selection-runs.json')
          .readAsStringSync()) as List) {
    test('RFC PDF capture uses page text offsets: ${fixture['id']}', () async {
      final fullText = fixture['fullText'] as String;
      final expected = fixture['expected'] as Map;
      final start = (expected['prefix'] as String).length;
      final text = PdfPageText(
          pageNumber: fixture['page'],
          fullText: fullText,
          charRects: [],
          fragments: []);
      final data = await buildPdfSelectionData([
        PdfPageTextRange(
            pageText: text,
            start: start,
            end: start + (expected['exact'] as String).length)
      ], (_) async => const Size(600, 800));
      expect(data!.target.pageTargets.single.toJson(), expected);
      expect(data.context, fullText);
      final restored = data.target.pageTargets.single.resolve(fullText)!;
      expect(restored.start, start);
    });
  }
  test(
      'saves both page-local quotes for a selection crossing the page boundary',
      () async {
    const first = PdfPageText(
        pageNumber: 4,
        fullText: 'Before carrying subtle notes',
        charRects: [],
        fragments: []);
    const second = PdfPageText(
        pageNumber: 5,
        fullText: 'hug the area. After',
        charRects: [],
        fragments: []);
    final data = await buildPdfSelectionData([
      PdfPageTextRange(pageText: first, start: 7, end: first.fullText.length),
      PdfPageTextRange(pageText: second, start: 0, end: 12),
    ], (_) async => const Size(600, 800));
    expect(data!.target.exact, 'carrying subtle notes hug the area');
    expect(data.target.pageTargets.map((part) => part.page), [4, 5]);
    expect(data.target.pageTargets.first.prefix, 'Before ');
    expect(data.target.pageTargets.last.suffix, '. After');
    expect(data.target.toSelectors().last['type'], 'anx-pdf-page-range');
  });
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

  test('carries the first selected range offset into the PDF selector',
      () async {
    const text = 'Before selected after';
    const pageText = PdfPageText(
      pageNumber: 3,
      fullText: text,
      charRects: [],
      fragments: [],
    );
    final range = PdfPageTextRange(
      pageText: pageText,
      start: text.indexOf('selected'),
      end: text.indexOf(' after'),
    );

    final data = await buildPdfSelectionData(
      [range],
      (_) async => const Size(600, 800),
      resolvePageOffset: (_) => 0.4,
    );

    expect(data?.target.pageOffsetRatio, 0.4);
    expect(data?.target.toSelectors().first, {
      'type': 'pdf-page',
      'page': 3,
      'pageOffsetRatio': 0.4,
    });
  });
}
