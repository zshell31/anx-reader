import 'package:anx_reader/page/book_player/pdf_reading_position.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PDF reading position', () {
    test('round-trips a positive page number', () {
      expect(encodePdfReadingPosition(42), 'pdf-page:42');
      expect(decodePdfReadingPosition('pdf-page:42'), 42);
    });

    test('does not interpret EPUB or malformed positions as PDF pages', () {
      expect(decodePdfReadingPosition('epubcfi(/6/2!/4/2:1)'), isNull);
      expect(decodePdfReadingPosition('pdf-page:0'), isNull);
      expect(decodePdfReadingPosition('pdf-page:not-a-number'), isNull);
      expect(decodePdfReadingPosition(null), isNull);
    });

    test('rejects invalid encoded pages', () {
      expect(() => encodePdfReadingPosition(0), throwsArgumentError);
    });

    test('maps pages to bounded reading percentages', () {
      expect(pdfReadingPercentage(1, 4), 0.25);
      expect(pdfReadingPercentage(4, 4), 1);
      expect(pdfReadingPercentage(99, 4), 1);
      expect(pdfReadingPercentage(1, 0), 0);
    });
  });
}
