import 'dart:ui';

import 'package:anx_reader/page/book_player/pdf_annotation_interaction.dart';
import 'package:anx_reader/service/sync/annotation_read_model.dart';
import 'package:anx_reader/service/sync/annotation_selectors.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PDF annotation hit testing', () {
    test('resolves the annotation whose rendered rectangle was tapped', () {
      final firstRef = AnnotationRef(
        bookFingerprint: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        annotationId: 'first',
      );
      final secondRef = AnnotationRef(
        bookFingerprint: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        annotationId: 'second',
      );
      final rects = <AnnotationRef, List<Rect>>{
        firstRef: [const Rect.fromLTWH(0, 0, 40, 12)],
        secondRef: [const Rect.fromLTWH(0, 20, 40, 12)],
      };

      final first = hitTestPdfAnnotations(
        position: const Offset(10, 6),
        annotations: rects.keys,
        rectsFor: (annotation) => rects[annotation]!,
      );
      final second = hitTestPdfAnnotations(
        position: const Offset(10, 26),
        annotations: rects.keys,
        rectsFor: (annotation) => rects[annotation]!,
      );

      expect(first.kind, PdfAnnotationHitKind.unique);
      expect(first.annotation, same(firstRef));
      expect(second.kind, PdfAnnotationHitKind.unique);
      expect(second.annotation, same(secondRef));
    });

    test('does not arbitrarily select overlapping annotations', () {
      final hit = hitTestPdfAnnotations(
        position: const Offset(10, 6),
        annotations: const ['first', 'second'],
        rectsFor: (_) => [const Rect.fromLTWH(0, 0, 40, 12)],
      );

      expect(hit.kind, PdfAnnotationHitKind.ambiguous);
      expect(hit.annotation, isNull);
    });

    test('reports no hit outside rendered annotations', () {
      final hit = hitTestPdfAnnotations(
        position: const Offset(50, 50),
        annotations: const ['annotation'],
        rectsFor: (_) => [const Rect.fromLTWH(0, 0, 40, 12)],
      );

      expect(hit.kind, PdfAnnotationHitKind.none);
    });
  });

  test('restoration loads structured text once for annotations on one page',
      () async {
    final targets = <String, PdfAnnotationTarget>{
      'first': const PdfAnnotationTarget(
        page: 3,
        exact: 'alpha',
        prefix: '',
        suffix: ' beta',
      ),
      'second': const PdfAnnotationTarget(
        page: 3,
        exact: 'beta',
        prefix: 'alpha ',
        suffix: '',
      ),
    };
    final loads = <int>[];

    final resolved = await resolvePdfAnnotationsByPage(
      annotations: targets.keys,
      targetFor: (annotation) => targets[annotation],
      loadPageText: (page) async {
        loads.add(page);
        return 'alpha beta';
      },
      fullTextFor: (text) => text,
    );

    expect(loads, [3]);
    expect(resolved.map((item) => item.annotation), ['first', 'second']);
    expect(resolved.map((item) => item.match.start), [0, 6]);
  });

  test('ambiguous semantic targets stay unresolved', () async {
    final resolved = await resolvePdfAnnotationsByPage(
      annotations: const ['ambiguous'],
      targetFor: (_) => const PdfAnnotationTarget(
        page: 1,
        exact: 'same',
        prefix: '',
        suffix: '',
      ),
      loadPageText: (_) async => 'same and same',
      fullTextFor: (text) => text,
    );

    expect(resolved, isEmpty);
  });

  test('restores every page-local part of a cross-page annotation', () async {
    final target = PdfAnnotationTarget.fromPageTargets(
      targets: const [
        PdfAnnotationPageTarget(
          page: 2,
          exact: 'ending',
          prefix: '',
          suffix: '',
        ),
        PdfAnnotationPageTarget(
          page: 3,
          exact: 'beginning',
          prefix: '',
          suffix: '',
        ),
      ],
      exact: 'ending beginning',
    );

    final resolved = await resolvePdfAnnotationsByPage(
      annotations: ['cross-page'],
      targetFor: (_) => target,
      loadPageText: (page) async => page == 2 ? 'ending' : 'beginning',
      fullTextFor: (text) => text,
    );

    expect(resolved.map((item) => item.target.page), [2, 3]);
  });
}
