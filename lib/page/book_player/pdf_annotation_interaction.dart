import 'dart:ui';

import 'package:anx_reader/service/sync/annotation_selectors.dart';

enum PdfAnnotationHitKind { none, unique, ambiguous }

class PdfAnnotationHit<T> {
  const PdfAnnotationHit._(this.kind, this.annotation);

  const PdfAnnotationHit.none() : this._(PdfAnnotationHitKind.none, null);

  const PdfAnnotationHit.unique(T annotation)
      : this._(PdfAnnotationHitKind.unique, annotation);

  const PdfAnnotationHit.ambiguous()
      : this._(PdfAnnotationHitKind.ambiguous, null);

  final PdfAnnotationHitKind kind;
  final T? annotation;
}

PdfAnnotationHit<T> hitTestPdfAnnotations<T>({
  required Offset position,
  required Iterable<T> annotations,
  required Iterable<Rect> Function(T annotation) rectsFor,
}) {
  T? match;
  for (final annotation in annotations) {
    if (!rectsFor(annotation).any((rect) => rect.contains(position))) {
      continue;
    }
    if (match != null) return const PdfAnnotationHit.ambiguous();
    match = annotation;
  }
  return match == null
      ? const PdfAnnotationHit.none()
      : PdfAnnotationHit.unique(match);
}

class PdfAnnotationResolution<TAnnotation, TPageText> {
  const PdfAnnotationResolution({
    required this.annotation,
    required this.pageText,
    required this.match,
  });

  final TAnnotation annotation;
  final TPageText pageText;
  final PdfTextMatch match;
}

Future<List<PdfAnnotationResolution<TAnnotation, TPageText>>>
    resolvePdfAnnotationsByPage<TAnnotation, TPageText>({
  required Iterable<TAnnotation> annotations,
  required PdfAnnotationTarget? Function(TAnnotation annotation) targetFor,
  required Future<TPageText> Function(int pageNumber) loadPageText,
  required String Function(TPageText pageText) fullTextFor,
}) async {
  final byPage = <int, List<(TAnnotation, PdfAnnotationTarget)>>{};
  for (final annotation in annotations) {
    final target = targetFor(annotation);
    if (target == null) continue;
    (byPage[target.page] ??= []).add((annotation, target));
  }

  final resolved = <PdfAnnotationResolution<TAnnotation, TPageText>>[];
  for (final pageEntry in byPage.entries) {
    final pageText = await loadPageText(pageEntry.key);
    final fullText = fullTextFor(pageText);
    for (final (annotation, target) in pageEntry.value) {
      final match = target.resolve(fullText);
      if (match == null) continue;
      resolved.add(PdfAnnotationResolution(
        annotation: annotation,
        pageText: pageText,
        match: match,
      ));
    }
  }
  return resolved;
}
