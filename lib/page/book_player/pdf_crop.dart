import 'dart:math' as math;
import 'package:flutter/widgets.dart';
import 'package:pdfrx/pdfrx.dart';

enum PdfCropMode { off, automatic, manual }

class PdfCropSettings {
  const PdfCropSettings(
      {this.mode = PdfCropMode.off,
      this.manual = const Rect.fromLTRB(.08, .04, .92, .96)});
  final PdfCropMode mode;
  final Rect manual;

  factory PdfCropSettings.fromMap(Map<String, dynamic> map) {
    final values = map['rect'];
    var rect = const Rect.fromLTRB(.08, .04, .92, .96);
    if (values is List &&
        values.length == 4 &&
        values.every((v) => v is num && v.isFinite)) {
      final candidate = Rect.fromLTRB(
          (values[0] as num).toDouble(),
          (values[1] as num).toDouble(),
          (values[2] as num).toDouble(),
          (values[3] as num).toDouble());
      if (candidate.left >= 0 &&
          candidate.top >= 0 &&
          candidate.right <= 1 &&
          candidate.bottom <= 1 &&
          candidate.width >= .1 &&
          candidate.height >= .1) {
        rect = candidate;
      }
    }
    return PdfCropSettings(
        mode: PdfCropMode.values.firstWhere((v) => v.name == map['mode'],
            orElse: () => PdfCropMode.off),
        manual: rect);
  }
  Map<String, dynamic> toMap() => {
        'mode': mode.name,
        'rect': [manual.left, manual.top, manual.right, manual.bottom]
      };
}

/// Progressive loading exposes placeholder pages whose text is still empty.
Future<Rect> loadAutomaticPdfCrop(PdfPage page) async {
  final loaded = await page.ensureLoaded();
  final text = await loaded.loadStructuredText();
  return automaticPdfCrop([
    for (var i = 0; i < text.charRects.length && i < text.fullText.length; i++)
      if (text.fullText[i].trim().isNotEmpty)
        text.charRects[i].toRect(page: loaded),
  ], Size(loaded.width, loaded.height));
}

/// Detects horizontal text margins, with a small safety gap. Image-only pages stay whole.
Rect automaticPdfCrop(Iterable<Rect> textRects, Size pageSize) {
  Rect? bounds;
  for (final rect in textRects) {
    if (!rect.isFinite || rect.isEmpty) continue;
    bounds = bounds?.expandToInclude(rect) ?? rect;
  }
  if (bounds == null || pageSize.isEmpty) {
    return const Rect.fromLTWH(0, 0, 1, 1);
  }
  final left = (bounds.left / pageSize.width - .015).clamp(0.0, .3);
  final right = (bounds.right / pageSize.width + .015).clamp(.7, 1.0);
  return Rect.fromLTRB(left, 0, right, 1);
}

PdfPageLayout layoutCroppedPdfPages(
    List<Size> sizes, Rect Function(int index) cropFor,
    {double gap = 8}) {
  final pages = <Rect>[];
  final visible = <Rect>[];
  final width = sizes.fold(0.0, (w, s) => math.max(w, s.width));
  var y = 0.0;
  for (var i = 0; i < sizes.length; i++) {
    final crop = cropFor(i);
    final scale = width / (sizes[i].width * crop.width);
    final fullSize = sizes[i] * scale;
    final height = fullSize.height * crop.height;
    pages.add(Rect.fromLTWH(-crop.left * fullSize.width,
        y - crop.top * fullSize.height, fullSize.width, fullSize.height));
    visible.add(Rect.fromLTWH(0, y, width, height));
    y += height + gap;
  }
  return PdfPageLayout(
      pageLayouts: pages,
      visiblePageRects: visible,
      documentSize: Size(width, math.max(0, y - gap)));
}

/// [handle] uses -1/0/1 for the left/center/right and top/center/bottom edges.
Rect adjustPdfCrop(Rect rect, Offset delta, Offset handle) {
  if (handle == Offset.zero) {
    return rect.shift(Offset(delta.dx.clamp(-rect.left, 1 - rect.right),
        delta.dy.clamp(-rect.top, 1 - rect.bottom)));
  }
  return Rect.fromLTRB(
    handle.dx < 0
        ? (rect.left + delta.dx).clamp(0, rect.right - .1)
        : rect.left,
    handle.dy < 0 ? (rect.top + delta.dy).clamp(0, rect.bottom - .1) : rect.top,
    handle.dx > 0
        ? (rect.right + delta.dx).clamp(rect.left + .1, 1)
        : rect.right,
    handle.dy > 0
        ? (rect.bottom + delta.dy).clamp(rect.top + .1, 1)
        : rect.bottom,
  );
}
