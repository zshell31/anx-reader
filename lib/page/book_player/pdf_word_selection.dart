import 'package:flutter/painting.dart';
import 'package:pdfrx/pdfrx.dart';

/// Finds the nearest non-whitespace character within [hitTestMargin] PDF units.
/// The caller converts the screen-space touch tolerance to page coordinates.
int? findPdfCharacterIndex(PdfPageText pageText, PdfPoint point,
    {double hitTestMargin = 0}) {
  int? closestIndex;
  var closestDistance = double.infinity;
  for (var index = 0; index < pageText.charRects.length; index++) {
    if (index >= pageText.fullText.length ||
        pageText.fullText[index].trim().isEmpty) {
      continue;
    }
    final rect = pageText.charRects[index];
    final distance = rect.distanceSquaredTo(point);
    if (distance < closestDistance) {
      closestIndex = index;
      closestDistance = distance;
    }
  }
  return closestDistance <= hitTestMargin * hitTestMargin ? closestIndex : null;
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
