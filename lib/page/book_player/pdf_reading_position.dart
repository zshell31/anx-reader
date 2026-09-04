const String pdfReadingPositionPrefix = 'pdf-page:';

String encodePdfReadingPosition(
  int pageNumber, {
  double? pageOffsetRatio,
}) {
  if (pageNumber < 1) {
    throw ArgumentError.value(pageNumber, 'pageNumber', 'must be positive');
  }
  final offset = pageOffsetRatio;
  if (offset == null || !offset.isFinite) {
    return '$pdfReadingPositionPrefix$pageNumber';
  }
  final normalized = offset.clamp(0, 1).toStringAsFixed(6);
  final compact = normalized
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
  return '$pdfReadingPositionPrefix$pageNumber@$compact';
}

int? decodePdfReadingPosition(String? value) {
  final match = _pdfReadingPositionMatch(value);
  if (match == null) return null;
  final pageNumber = int.tryParse(match.group(1)!);
  return pageNumber != null && pageNumber > 0 ? pageNumber : null;
}

double? decodePdfReadingOffset(String? value) {
  final match = _pdfReadingPositionMatch(value);
  if (match == null || decodePdfReadingPosition(value) == null) return null;
  final rawOffset = match.group(2);
  if (rawOffset == null) return null;
  final offset = double.tryParse(rawOffset);
  if (offset == null || !offset.isFinite) return null;
  return offset.clamp(0, 1);
}

RegExpMatch? _pdfReadingPositionMatch(String? value) {
  if (value == null || !value.startsWith(pdfReadingPositionPrefix)) {
    return null;
  }
  return RegExp(r'^(\d+)(?:@([0-9]*\.?[0-9]+))?$')
      .firstMatch(value.substring(pdfReadingPositionPrefix.length));
}

double pdfReadingPercentage(int pageNumber, int pageCount) {
  if (pageCount < 1) return 0;
  return pageNumber.clamp(1, pageCount) / pageCount;
}
