import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

const double _selectionHandleHitSize = 40;

/// Builds Android Material selection handles while preserving pdfrx's anchor
/// corners (start above the selection, end below it).
Widget buildPdfSelectionHandle(
  BuildContext context,
  PdfTextSelectionAnchor anchor,
  PdfViewerTextSelectionAnchorHandleState _,
) {
  final (type, quarterTurns, alignment) =
      switch ((anchor.direction, anchor.type)) {
    (
      PdfTextDirection.ltr || PdfTextDirection.unknown,
      PdfTextSelectionAnchorType.a,
    ) =>
      (TextSelectionHandleType.right, 2, Alignment.bottomRight),
    (
      PdfTextDirection.ltr || PdfTextDirection.unknown,
      PdfTextSelectionAnchorType.b,
    ) =>
      (TextSelectionHandleType.right, 0, Alignment.topLeft),
    (
      PdfTextDirection.rtl || PdfTextDirection.vrtl,
      PdfTextSelectionAnchorType.a,
    ) =>
      (TextSelectionHandleType.right, 3, Alignment.bottomLeft),
    (
      PdfTextDirection.rtl || PdfTextDirection.vrtl,
      PdfTextSelectionAnchorType.b,
    ) =>
      (TextSelectionHandleType.left, 0, Alignment.topRight),
  };

  final handle = materialTextSelectionControls.buildHandle(
    context,
    type,
    anchor.rect.height,
  );
  return SizedBox.square(
    dimension: _selectionHandleHitSize,
    child: Align(
      alignment: alignment,
      child: RotatedBox(quarterTurns: quarterTurns, child: handle),
    ),
  );
}
