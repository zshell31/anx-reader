import 'dart:convert';
import 'dart:io';
import 'package:anx_reader/service/sync/annotation_selectors.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final fixture in jsonDecode(
      File('protocol/notes-rfc/fixtures/editor/pdf-selection-runs.json')
          .readAsStringSync()) as List) {
    test('RFC new PDF quote from Lingua ${fixture['id']}', () {
      final quote = PdfAnnotationPageTarget.fromJson(fixture['expected'])!;
      final text = fixture['fullText'] as String;
      final restored = quote.resolve(text)!;
      expect(text.substring(restored.start, restored.end), quote.exact);
      expect(restored.start, quote.prefix.length);
      final created = PdfAnnotationPageTarget.fromPageText(
          page: quote.page,
          pageText: text,
          start: restored.start,
          end: restored.end);
      expect(created.toJson(), fixture['expected']);
    });
  }
  test('restores Lingua cross-page selectors and preserves the shared anchors',
      () {
    final fixture = jsonDecode(
        File('test/fixtures/pdf_cross_page.json').readAsStringSync());
    final target = PdfAnnotationTarget.fromSelectors(fixture['selectors'])!;
    expect(target.pageTargets.map((part) => part.page), [4, 5]);
    expect(target.toSelectors(), fixture['selectors']);
    for (final part in target.pageTargets) {
      final text = fixture['pages']['${part.page}'] as String;
      final match = part.resolve(text)!;
      expect(text.substring(match.start, match.end), part.exact);
    }
  });

  test('rejects malformed or backwards page fragments', () {
    final fixture = jsonDecode(
        File('test/fixtures/pdf_cross_page.json').readAsStringSync());
    final selectors = fixture['selectors'] as List;
    selectors.last['fragments'] = [];
    expect(PdfAnnotationTarget.fromSelectors(selectors), isNull);
    selectors.last['fragments'] = [
      {'page': 4, 'exact': 'first'},
      {'page': 3, 'exact': 'second'},
    ];
    expect(PdfAnnotationTarget.fromSelectors(selectors), isNull);
  });
  for (final fixture in jsonDecode(
          File('test/fixtures/pdf_quote_matching.json').readAsStringSync())
      as List) {
    test('shared PDF quote: ${fixture['name']}', () {
      final quote = fixture['quote'];
      final source = fixture['text'] as String;
      final target = PdfAnnotationPageTarget(
          page: 1,
          exact: quote['exact'],
          prefix: quote['prefix'] ?? '',
          suffix: quote['suffix'] ?? '');
      final match = target.resolve(source);
      expect(match == null ? null : source.substring(match.start, match.end),
          fixture['expected']);
    });
  }
  group('PDF annotation selectors', () {
    test('matches Lingua line breaks to PDFium text with source offsets', () {
      const quote =
          'Most evenings, delicate mists roll down from the mountains,\n'
          'creeping into the town’s streets.';
      const source = '5\r\nhug the area. '
          'Most evenings, delicate mists roll down from the mountains, \r\n'
          'creeping into the town’s streets. \r\nTo visitors';
      const target = PdfAnnotationPageTarget(
          page: 5, exact: quote, prefix: '', suffix: ' \nTo visitors');
      final match = target.resolve(source)!;
      expect(match.start, source.indexOf('Most evenings'));
      expect(match.end, source.indexOf('streets.') + 'streets.'.length);
    });

    test('normalization does not hide an ambiguous second occurrence', () {
      const target = PdfAnnotationPageTarget(
          page: 1, exact: 'same phrase', prefix: '', suffix: '');
      expect(target.resolve('same phrase and same\r\nphrase'), isNull);
      expect(target.resolve('samephrase'), isNull);
    });

    test(
        'legacy selected text supplies a missing quote only for page selectors',
        () {
      final selectors = [
        {'type': 'pdf-page', 'page': 4}
      ];
      final target = PdfAnnotationTarget.fromSelectors(selectors,
          legacySelectedText: 'play out');
      expect(target?.resolve('Your adventures play out through')?.start, 16);
      expect(selectors, [
        {'type': 'pdf-page', 'page': 4}
      ]);
      expect(
          PdfAnnotationTarget.fromSelectors([
            ...selectors,
            {'type': 'text-quote', 'exact': ''},
          ], legacySelectedText: 'play out'),
          isNull);
    });

    test('serialize and restore pdf-page plus contextual text-quote', () {
      const pageText = 'Before. He looked at her. After.';
      final target = PdfAnnotationTarget.fromPageText(
        page: 42,
        pageText: pageText,
        start: pageText.indexOf('He looked'),
        end: pageText.indexOf(' After'),
        pageOffsetRatio: 0.375,
      );

      final restored = PdfAnnotationTarget.fromSelectors(target.toSelectors());

      expect(restored?.page, 42);
      expect(restored?.exact, 'He looked at her.');
      expect(restored?.prefix, 'Before. ');
      expect(restored?.suffix, ' After.');
      expect(restored?.pageOffsetRatio, 0.375);
      expect(restored?.toSelectors().first, {
        'type': 'pdf-page',
        'page': 42,
        'pageOffsetRatio': 0.375,
      });
      expect(restored?.resolve(pageText)?.start, pageText.indexOf('He looked'));
    });

    test('context selects only one of two identical phrases', () {
      const pageText = 'Alpha repeated phrase one. Beta repeated phrase two.';
      final second = pageText.lastIndexOf('repeated phrase');
      final target = PdfAnnotationTarget.fromPageText(
        page: 1,
        pageText: pageText,
        start: second,
        end: second + 'repeated phrase'.length,
        contextLength: 6,
      );

      final match = target.resolve(pageText);

      expect(match, isNotNull);
      expect(match!.start, second);
      expect(pageText.substring(match.start, match.end), 'repeated phrase');
    });

    test('ambiguous quote remains unresolved instead of matching both', () {
      const pageText = 'same phrase and same phrase';
      const target = PdfAnnotationTarget(
        page: 1,
        exact: 'same phrase',
        prefix: '',
        suffix: '',
      );

      expect(target.resolve(pageText), isNull);
    });

    test('unsupported or conflicting selectors remain unsupported', () {
      expect(
        PdfAnnotationTarget.fromSelectors([
          {'type': 'pdf-page', 'page': 1},
          {'type': 'pdf-page', 'page': 2},
          {'type': 'text-quote', 'exact': 'text'},
        ]),
        isNull,
      );
      expect(
        PdfAnnotationTarget.fromSelectors([
          {'type': 'future-selector', 'value': 'preserve'},
        ]),
        isNull,
      );
    });

    test('clamps a Lingua PDF page offset while parsing', () {
      final restored = PdfAnnotationTarget.fromSelectors([
        {'type': 'pdf-page', 'page': 7, 'pageOffsetRatio': 1.25},
        {'type': 'text-quote', 'exact': 'selected'},
      ]);

      expect(restored?.pageOffsetRatio, 1);
    });

    test('multi-page quote round-trips with page-local render targets', () {
      final target = PdfAnnotationTarget.fromPageTargets(
        targets: const [
          PdfAnnotationPageTarget(
            page: 4,
            exact: 'The sentence',
            prefix: 'Before. ',
            suffix: '',
          ),
          PdfAnnotationPageTarget(
            page: 5,
            exact: 'continues here.',
            prefix: '',
            suffix: ' After.',
          ),
        ],
        exact: 'The sentence continues here.',
      );

      final restored = PdfAnnotationTarget.fromSelectors(target.toSelectors());

      expect(restored?.page, 4);
      expect(restored?.endPage, 5);
      expect(restored?.exact, 'The sentence continues here.');
      expect(restored?.pageTargets.map((part) => part.exact), [
        'The sentence',
        'continues here.',
      ]);
      expect(restored?.pageTargets.first.resolve('Before. The sentence'),
          isNotNull);
      expect(restored?.pageTargets.last.resolve('continues here. After.'),
          isNotNull);
    });
  });
}
