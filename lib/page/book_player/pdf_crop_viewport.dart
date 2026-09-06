import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Keeps the viewport inside the horizontal crop while allowing vertical reading.
({Offset center, double zoom}) constrainPdfCropViewport({
  required Offset center,
  required double zoom,
  required Size viewSize,
  required Rect crop,
  required double documentHeight,
}) {
  final effectiveZoom = math.max(zoom, viewSize.width / crop.width);
  final halfWidth = viewSize.width / effectiveZoom / 2;
  final halfHeight = viewSize.height / effectiveZoom / 2;
  final minX = crop.left + halfWidth;
  final maxX = crop.right - halfWidth;
  return (
    center: Offset(
      minX >= maxX ? crop.center.dx : center.dx.clamp(minX, maxX),
      documentHeight <= halfHeight * 2
          ? documentHeight / 2
          : center.dy.clamp(halfHeight, documentHeight - halfHeight),
    ),
    zoom: effectiveZoom,
  );
}
