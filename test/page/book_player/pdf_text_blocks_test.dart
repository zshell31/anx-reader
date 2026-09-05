import 'dart:async';

import 'package:anx_reader/page/book_player/pdf_text_blocks.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PDF text block extraction', () {
    test('keeps a sentence continuing in the next column together', () {
      const text = 'A sentence that\ncontinues in the next column.';
      final blocks = extractPdfTextBlocks(PdfPageTextSource(
        pageNumber: 1,
        fullText: text,
        lines: [
          const PdfTextLine(
              start: 0, left: 20, right: 200, top: 50, bottom: 40),
          PdfTextLine(
              start: text.indexOf('continues'),
              left: 240,
              right: 420,
              top: 700,
              bottom: 690),
        ],
      ));
      expect(
          blocks.single.text, 'A sentence that continues in the next column.');
    });

    test('uses PDF line spacing and indents without splitting wrapped lines',
        () {
      const text =
          'First line\nwrapped.\nIndented paragraph\ncontinued.\nAfter gap.';
      final blocks = extractPdfTextBlocks(PdfPageTextSource(
        pageNumber: 1,
        fullText: text,
        lines: [
          for (final row in [
            ('First', 20.0, 100.0),
            ('wrapped', 20.0, 86.0),
            ('Indented', 32.0, 72.0),
            ('continued', 20.0, 58.0),
            ('After', 20.0, 34.0),
          ])
            PdfTextLine(
              start: text.indexOf(row.$1),
              left: row.$2,
              right: 200,
              top: row.$3,
              bottom: row.$3 - 10,
            ),
        ],
      ));
      expect(blocks.map((block) => block.text), [
        'First line wrapped.',
        'Indented paragraph continued.',
        'After gap.',
      ]);
      expect(text.substring(blocks[1].sourceStart, blocks[1].sourceEnd),
          'Indented paragraph\ncontinued.');
    });

    test('keeps paragraph order and portable source offsets', () {
      const fullText = '  First line\nwraps here.\n\nSecond paragraph.  ';

      final blocks = extractPdfTextBlocks(
        const PdfPageTextSource(pageNumber: 4, fullText: fullText),
      );

      expect(blocks.map((block) => block.text), [
        'First line wraps here.',
        'Second paragraph.',
      ]);
      expect(blocks.map((block) => block.blockIndex), [0, 1]);
      expect(blocks.every((block) => block.pageNumber == 4), isTrue);
      expect(
        blocks.map(
          (block) => fullText.substring(block.sourceStart, block.sourceEnd),
        ),
        ['First line\nwraps here.', 'Second paragraph.'],
      );
    });

    test('joins wrapped lines and repairs lowercase hyphenation', () {
      final blocks = extractPdfTextBlocks(
        const PdfPageTextSource(
          pageNumber: 1,
          fullText: 'A hyphen-\nated word\nnext line.\n\nTitle-\nCase stays.',
        ),
      );

      expect(blocks.map((block) => block.text), [
        'A hyphenated word next line.',
        'Title-Case stays.',
      ]);
    });

    test('returns no blocks for a scanned or whitespace-only page', () {
      expect(
        extractPdfTextBlocks(
          const PdfPageTextSource(pageNumber: 2, fullText: ' \n\t\n '),
        ),
        isEmpty,
      );
    });
  });

  group('PDF page-lazy block loader', () {
    test('loads only requested pages and memoizes each successful page',
        () async {
      final requested = <int>[];
      final loader = PdfTextBlockPageLoader(loadPageText: (page) async {
        requested.add(page);
        return PdfPageTextSource(
          pageNumber: page,
          fullText: 'Page $page text.',
        );
      });

      expect(requested, isEmpty);
      final first = await loader.loadPage(3);
      final same = await loader.loadPage(3);
      final next = await loader.loadPage(4);

      expect(requested, [3, 4]);
      expect(identical(first, same), isTrue);
      expect(first.single.text, 'Page 3 text.');
      expect(next.single.pageNumber, 4);
      expect(() => first.add(first.single), throwsUnsupportedError);
    });

    test('shares an in-flight request and retries after a failure', () async {
      var attempts = 0;
      final pending = Completer<PdfPageTextSource>();
      final loader = PdfTextBlockPageLoader(loadPageText: (page) {
        attempts++;
        if (attempts == 1) return pending.future;
        return Future.value(
          PdfPageTextSource(pageNumber: page, fullText: 'recovered'),
        );
      });

      final first = loader.loadPage(1);
      final concurrent = loader.loadPage(1);
      expect(identical(first, concurrent), isTrue);
      pending.completeError(StateError('failed'));
      await expectLater(first, throwsStateError);

      expect((await loader.loadPage(1)).single.text, 'recovered');
      expect(attempts, 2);
    });
  });
}
