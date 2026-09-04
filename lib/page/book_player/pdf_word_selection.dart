import 'package:flutter/painting.dart';
import 'package:pdfrx/pdfrx.dart';

/// Finds the character under [point] while keeping the hit inside one PDF text
/// fragment. PDFium often exposes a whole paragraph as a single fragment, so
/// the fragment itself is not a useful word boundary.
int? findPdfCharacterIndex(PdfPageText pageText, PdfPoint point) {
  for (final fragment in pageText.fragments) {
    if (!fragment.bounds.containsPoint(point)) continue;

    var closestIndex = -1;
    var closestDistance = double.infinity;
    for (var index = fragment.index; index < fragment.end; index++) {
      final rect = pageText.charRects[index];
      if (rect.containsPoint(point)) return index;
      final distance = rect.distanceSquaredTo(point);
      if (distance < closestDistance) {
        closestIndex = index;
        closestDistance = distance;
      }
    }
    return closestIndex < 0 ? null : closestIndex;
  }
  return null;
}

/// Returns the Unicode word containing [characterIndex].
///
/// Flutter delegates these boundaries to the paragraph engine, giving us the
/// same Unicode-aware behavior as editable/selectable Flutter text rather than
/// an ASCII-only whitespace heuristic.
TextRange? pdfWordRangeAt(String text, int characterIndex) {
  if (text.isEmpty || characterIndex < 0 || characterIndex >= text.length) {
    return null;
  }
  final painter = TextPainter(
    text: TextSpan(text: text),
    textDirection: TextDirection.ltr,
  )..layout();
  try {
    final range = painter.getWordBoundary(TextPosition(offset: characterIndex));
    if (!range.isValid || range.isCollapsed) return null;
    final selected = range.textInside(text);
    if (selected.trim().isEmpty) return null;
    return range;
  } finally {
    painter.dispose();
  }
}
