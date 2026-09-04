enum PdfEdgeTapAction { previousPage, nextPage }

PdfEdgeTapAction? pdfEdgeTapAction({
  required double x,
  required double viewWidth,
  double edgeFraction = 0.2,
  double minEdgeWidth = 48,
  double maxEdgeWidth = 96,
}) {
  if (!x.isFinite || !viewWidth.isFinite || viewWidth <= 0) return null;
  final edgeWidth = (viewWidth * edgeFraction).clamp(
    minEdgeWidth.clamp(0, viewWidth / 2),
    maxEdgeWidth.clamp(0, viewWidth / 2),
  );
  if (x <= edgeWidth) return PdfEdgeTapAction.previousPage;
  if (x >= viewWidth - edgeWidth) return PdfEdgeTapAction.nextPage;
  return null;
}
