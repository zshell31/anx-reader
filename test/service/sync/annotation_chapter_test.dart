import 'dart:convert';
import 'dart:io';
import 'package:anx_reader/service/sync/annotation_chapter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final fixture in jsonDecode(
      File('protocol/notes-rfc/fixtures/editor/pdf-chapters.json')
          .readAsStringSync()) as List) {
    test('RFC PDF chapters: ${fixture['id']}', () {
      final before = jsonEncode(fixture);
      expect(
          annotationChapterLabel(fixture['chapter'], fixture['selectors'],
              outline: (fixture['outline'] as List?)?.map((item) =>
                  PdfChapter(page: item['page'], title: item['title']))),
          fixture['expected']);
      expect(jsonEncode(fixture), before);
    });
  }
}
