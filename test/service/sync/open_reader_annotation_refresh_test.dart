import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String source(String path) => File(path).readAsStringSync();

  test('Foliate refresh replaces its projection snapshot', () {
    final bridge = source('lib/page/book_player/epub_player.dart');
    final foliate = source('assets/foliate-js/src/book.js');

    expect(bridge, contains("source: 'renderAnnotations(\$allAnnotations)'"));
    expect(bridge, isNot(contains('const allAnnotations =')));
    expect(foliate, contains('this.annotations.clear()'));
    expect(foliate, contains('this.annotationsByValue.clear()'));
    expect(foliate, contains('this.annotationsById.clear()'));
    expect(foliate, contains('this.view.addAnnotation(annotation, true)'));
  });

  test('incremental renderer operations use native annotation identity', () {
    final player = source('lib/page/book_player/epub_player.dart');
    final foliate = source('assets/foliate-js/src/book.js');
    final excerpt = source('lib/widgets/context_menu/excerpt_menu.dart');
    final notes = source('lib/widgets/book_notes/book_notes_list.dart');
    final bookmarks = source('lib/providers/bookmark.dart');

    expect(foliate, contains('annotationsById = new Map()'));
    expect(foliate, contains('this.annotationsById.get(annotation.id)'));
    expect(foliate, contains('this.annotationsById.get(id)'));
    expect(player, contains("source: 'removeAnnotation(\${jsonEncode(cfi)},"));
    expect(excerpt, contains('id: current.id'));
    expect(notes, contains('id: note.id'));
    expect(bookmarks, contains('id: bookmark.id'));
  });

  test('bookmark creation does not dedupe against a selection at the same CFI',
      () {
    final bookmarks = source('lib/providers/bookmark.dart');
    expect(bookmarks, contains("cfi = ? AND book_id = ? AND type = ?"));
    expect(bookmarks, contains("[bookmark.cfi, bookId, 'bookmark']"));
  });
}
