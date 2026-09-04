import 'dart:math' as math;

import 'package:anx_reader/service/sync/annotation_selectors.dart';
import 'package:flutter/widgets.dart';
import 'package:pdfrx/pdfrx.dart';

typedef PdfPageSizeLoader = Future<Size?> Function(int pageNumber);
typedef PdfPageOffsetResolver = double? Function(PdfPageTextRange range);

class PdfSelectionData {
  const PdfSelectionData({required this.target, required this.context});

  final PdfAnnotationTarget target;
  final String context;
}

bool isPdfPageNumberFragment({
  required String text,
  required int pageNumber,
  required PdfRect bounds,
  required Size pageSize,
}) {
  if (text.trim() != '$pageNumber' ||
      pageSize.width <= 0 ||
      pageSize.height <= 0) {
    return false;
  }
  final centerDistance = (bounds.center.x - pageSize.width / 2).abs();
  final relativeCenterY = bounds.center.y / pageSize.height;
  return centerDistance <= pageSize.width * 0.12 &&
      (relativeCenterY <= 0.2 || relativeCenterY >= 0.8);
}

String joinPdfSelectionParts(Iterable<String> parts) {
  var joined = '';
  final closingPunctuation = RegExp(r'^[,.;:!?…%)\]}]');
  final openingOrHyphen = RegExp(r'[([{“‘\-/]$');
  for (final rawPart in parts) {
    final part = rawPart.trim();
    if (part.isEmpty) continue;
    final needsSpace = joined.isNotEmpty &&
        !RegExp(r'\s').hasMatch(joined[joined.length - 1]) &&
        !RegExp(r'\s').hasMatch(part[0]) &&
        !closingPunctuation.hasMatch(part) &&
        !openingOrHyphen.hasMatch(joined);
    joined += '${needsSpace ? ' ' : ''}$part';
  }
  return joined;
}

Future<PdfSelectionData?> buildPdfSelectionData(
  List<PdfPageTextRange> ranges,
  PdfPageSizeLoader loadPageSize, {
  PdfPageOffsetResolver? resolvePageOffset,
}) async {
  final targets = <PdfAnnotationPageTarget>[];
  for (final range in ranges) {
    final pageText = range.pageText;
    final pageSize = await loadPageSize(range.pageNumber);
    final exclusions = pageSize == null
        ? const <PdfPageTextFragment>[]
        : pageText.fragments.where((fragment) {
            return fragment.end > range.start &&
                fragment.index < range.end &&
                isPdfPageNumberFragment(
                  text: fragment.text,
                  pageNumber: range.pageNumber,
                  bounds: fragment.bounds,
                  pageSize: pageSize,
                );
          }).toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    var cursor = range.start;
    for (final exclusion in exclusions) {
      final end = math.min(range.end, exclusion.index);
      if (end > cursor) {
        targets.add(PdfAnnotationPageTarget.fromPageText(
          page: range.pageNumber,
          pageText: pageText.fullText,
          start: cursor,
          end: end,
        ));
      }
      cursor = math.max(cursor, exclusion.end);
    }
    if (range.end > cursor) {
      targets.add(PdfAnnotationPageTarget.fromPageText(
        page: range.pageNumber,
        pageText: pageText.fullText,
        start: cursor,
        end: range.end,
      ));
    }
  }
  final exact = joinPdfSelectionParts(targets.map((target) => target.exact));
  if (targets.isEmpty || exact.isEmpty) return null;
  final pageOffsetRatio =
      ranges.isEmpty ? null : resolvePageOffset?.call(ranges.first);
  final target = targets.length == 1
      ? PdfAnnotationTarget(
          page: targets.single.page,
          exact: targets.single.exact,
          prefix: targets.single.prefix,
          suffix: targets.single.suffix,
          pageOffsetRatio: pageOffsetRatio,
        )
      : PdfAnnotationTarget.fromPageTargets(
          targets: targets,
          exact: exact,
          pageOffsetRatio: pageOffsetRatio,
        );
  return PdfSelectionData(
    target: target,
    context: '${target.prefix}${target.exact}${target.suffix}',
  );
}
