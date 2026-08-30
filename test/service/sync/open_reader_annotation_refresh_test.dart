import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String source(String path) => File(path).readAsStringSync();

  test('Foliate refresh replaces its canonical renderer snapshot', () {
    final bridge = source('lib/page/book_player/epub_player.dart');
    final foliate = source('assets/foliate-js/src/book.js');

    expect(bridge, contains("source: 'renderAnnotations(\$allAnnotations)'"));
    expect(bridge, contains('CanonicalAnnotationReadAdapter('));
    expect(bridge, contains('FoliateAnnotationAdapter('));
    expect(bridge, isNot(contains('selectBookNotesByBookId')));
    expect(bridge, isNot(contains('const allAnnotations =')));
    expect(foliate, contains('this.annotations.clear()'));
    expect(foliate, contains('this.annotationsByValue.clear()'));
    expect(foliate, contains('this.annotationsById.clear()'));
    expect(foliate, contains('this.view.addAnnotation(annotation, true)'));
  });

  test('renderer hit testing uses canonical UUID independently from CFI', () {
    final player = source('lib/page/book_player/epub_player.dart');
    final foliate = source('assets/foliate-js/src/book.js');
    final view = source('assets/foliate-js/src/view.js');
    final excerpt = source('lib/widgets/context_menu/excerpt_menu.dart');

    expect(foliate, contains('annotationsById = new Map()'));
    expect(foliate, contains('annotationForRenderKey('));
    expect(view, contains('rendererAnnotationKey(annotation)'));
    expect(view, contains("this.#emit('show-annotation', { renderKey"));
    expect(player,
        contains("final id = annotation['annotation']['id'] as String"));
    expect(player, contains('annotationId: id'));
    expect(player, isNot(contains('annotationRefForNativeId')));
    expect(excerpt,
        contains('annotationRepository.tombstoneAnnotation(handle.ref)'));
  });

  test('bookmark creation does not dedupe against a selection at the same CFI',
      () {
    final bookmarks = source('lib/providers/bookmark.dart');
    expect(bookmarks,
        contains('annotation.motivation == AnnotationMotivation.bookmark'));
    expect(bookmarks, isNot(contains('value.cfi == bookmark.cfi')));
    expect(bookmarks, isNot(contains('bookNoteDao')));
  });
}
