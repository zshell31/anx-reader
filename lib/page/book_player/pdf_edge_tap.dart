import 'package:flutter/widgets.dart';

enum PdfEdgeTapAction { previousPage, nextPage, scrollUp, scrollDown }

PdfEdgeTapAction? pdfEdgeTapAction({
  required double x,
  required double viewWidth,
  double? y,
  double? viewHeight,
  double edgeFraction = 0.2,
  double minEdgeWidth = 48,
  double maxEdgeWidth = 96,
}) {
  if (!x.isFinite || !viewWidth.isFinite || viewWidth <= 0) return null;
  if (y != null &&
      y.isFinite &&
      viewHeight != null &&
      viewHeight.isFinite &&
      viewHeight > 0) {
    final edgeHeight = (viewHeight * edgeFraction).clamp(
      minEdgeWidth.clamp(0, viewHeight / 2),
      maxEdgeWidth.clamp(0, viewHeight / 2),
    );
    if (y <= edgeHeight) return PdfEdgeTapAction.scrollUp;
    if (y >= viewHeight - edgeHeight) return PdfEdgeTapAction.scrollDown;
  }
  final edgeWidth = (viewWidth * edgeFraction).clamp(
    minEdgeWidth.clamp(0, viewWidth / 2),
    maxEdgeWidth.clamp(0, viewWidth / 2),
  );
  if (x <= edgeWidth) return PdfEdgeTapAction.previousPage;
  if (x >= viewWidth - edgeWidth) return PdfEdgeTapAction.nextPage;
  return null;
}

/// Scroll within the visible (possibly cropped) page with 15% overlap.
/// A null target means the page boundary has already been reached.
Offset? pdfVerticalTapTarget({
  required Rect viewport,
  required Rect page,
  required bool down,
}) {
  final remaining =
      down ? page.bottom - viewport.bottom : viewport.top - page.top;
  if (remaining <= 0.5 || viewport.height <= 0) return null;
  final distance = (viewport.height * 0.85).clamp(0.0, remaining);
  return viewport.center.translate(0, down ? distance : -distance);
}
