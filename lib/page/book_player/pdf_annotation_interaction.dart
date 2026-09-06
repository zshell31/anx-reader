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
  double hitSlop = 0,
}) {
  T? match;
  var bestDistance = double.infinity;
  var ambiguous = false;
  for (final annotation in annotations) {
    var distance = double.infinity;
    for (final rect in rectsFor(annotation)) {
      final dx = position.dx < rect.left
          ? rect.left - position.dx
          : position.dx > rect.right
              ? position.dx - rect.right
              : 0.0;
      final dy = position.dy < rect.top
          ? rect.top - position.dy
          : position.dy > rect.bottom
              ? position.dy - rect.bottom
              : 0.0;
      final candidate = dx > dy ? dx : dy;
      if (candidate < distance) distance = candidate;
    }
    if (distance > hitSlop) continue;
    if (distance < bestDistance) {
      bestDistance = distance;
      match = annotation;
      ambiguous = false;
    } else if (distance == bestDistance) {
      ambiguous = true;
    }
  }
  if (ambiguous) return const PdfAnnotationHit.ambiguous();
  return match == null
      ? const PdfAnnotationHit.none()
      : PdfAnnotationHit.unique(match);
}

class PdfAnnotationResolution<TAnnotation, TPageText> {
  const PdfAnnotationResolution({
    required this.annotation,
    required this.pageText,
    required this.match,
    required this.target,
  });

  final TAnnotation annotation;
  final TPageText pageText;
  final PdfTextMatch match;
  final PdfAnnotationPageTarget target;
}

Future<List<PdfAnnotationResolution<TAnnotation, TPageText>>>
    resolvePdfAnnotationsByPage<TAnnotation, TPageText>({
  required Iterable<TAnnotation> annotations,
  required PdfAnnotationTarget? Function(TAnnotation annotation) targetFor,
  required Future<TPageText> Function(int pageNumber) loadPageText,
  required String Function(TPageText pageText) fullTextFor,
}) async {
  final byPage = <int, List<(TAnnotation, PdfAnnotationPageTarget)>>{};
  for (final annotation in annotations) {
    final target = targetFor(annotation);
    if (target == null) continue;
    for (final pageTarget in target.pageTargets) {
      (byPage[pageTarget.page] ??= []).add((annotation, pageTarget));
    }
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
        target: target,
      ));
    }
  }
  return resolved;
}
