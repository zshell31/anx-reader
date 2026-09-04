import 'package:anx_reader/service/sync/annotation_selectors.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PDF annotation selectors', () {
    test('serialize and restore pdf-page plus contextual text-quote', () {
      const pageText = 'Before. He looked at her. After.';
      final target = PdfAnnotationTarget.fromPageText(
        page: 42,
        pageText: pageText,
        start: pageText.indexOf('He looked'),
        end: pageText.indexOf(' After'),
      );

      final restored = PdfAnnotationTarget.fromSelectors(target.toSelectors());

      expect(restored?.page, 42);
      expect(restored?.exact, 'He looked at her.');
      expect(restored?.prefix, 'Before. ');
      expect(restored?.suffix, ' After.');
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
