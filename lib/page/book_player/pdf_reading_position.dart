const String pdfReadingPositionPrefix = 'pdf-page:';

String encodePdfReadingPosition(int pageNumber) {
  if (pageNumber < 1) {
    throw ArgumentError.value(pageNumber, 'pageNumber', 'must be positive');
  }
  return '$pdfReadingPositionPrefix$pageNumber';
}

int? decodePdfReadingPosition(String? value) {
  if (value == null || !value.startsWith(pdfReadingPositionPrefix)) {
    return null;
  }
  final pageNumber =
      int.tryParse(value.substring(pdfReadingPositionPrefix.length));
  return pageNumber != null && pageNumber > 0 ? pageNumber : null;
}

double pdfReadingPercentage(int pageNumber, int pageCount) {
  if (pageCount < 1) return 0;
  return pageNumber.clamp(1, pageCount) / pageCount;
}
