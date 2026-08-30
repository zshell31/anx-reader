import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('production semantic mutation call sites do not bypass repository', () {
    const semanticCallSites = [
      'lib/widgets/context_menu/excerpt_menu.dart',
      'lib/providers/book_notes.dart',
      'lib/providers/bookmark.dart',
    ];
    final forbidden = RegExp(
      r'''bookNoteDao\.(save|updateBookNoteById|deleteBookNoteById)|\.(insert|update|delete)\(\s*['"]tb_notes['"]''',
    );

    for (final path in semanticCallSites) {
      final source = File(path).readAsStringSync();
      expect(forbidden.hasMatch(source), isFalse, reason: path);
      expect(source, contains('annotationRepository'), reason: path);
    }
    final editor = File('lib/widgets/context_menu/reader_note_menu.dart')
        .readAsStringSync();
    expect(forbidden.hasMatch(editor), isFalse);
    expect(editor, contains('widget.onSave'));
  });

  test('transient selection lifecycle has no annotation mutation dependency',
      () {
    const transientSelectionSites = [
      'lib/page/book_player/selection_session_bridge.dart',
      'lib/page/book_player/epub_player.dart',
      'lib/widgets/context_menu/context_menu.dart',
    ];

    for (final path in transientSelectionSites) {
      final source = File(path).readAsStringSync();
      expect(source, isNot(contains('annotationRepository')), reason: path);
      expect(source, isNot(contains('createSelectionAnnotation')),
          reason: path);
    }
  });

  test('selection save workflow uses canonical identities', () {
    final source =
        File('lib/widgets/context_menu/excerpt_menu.dart').readAsStringSync();
    expect(source, contains('annotationRepository.saveTranslation(ref'));
    expect(source, contains('annotationRepository.setPersonalNote(ref'));
    expect(source, contains('annotationRepository.updatePresentation('));
    expect(source, contains('annotationRepository.tombstoneAnnotation('));
    expect(source, isNot(contains('saveTranslationForNativeId')));
    expect(source, isNot(contains('setPersonalNoteForNativeId')));
    expect(source, isNot(contains('updatePresentationForNativeId')));
    expect(source, isNot(contains('tombstoneAnnotationForBookNote')));
  });

  test(
      'lookup context is transient and annotation creation uses only annotation context',
      () {
    final playerSource =
        File('lib/page/book_player/epub_player.dart').readAsStringSync();
    final menuSource =
        File('lib/widgets/context_menu/context_menu.dart').readAsStringSync();
    final excerptSource =
        File('lib/widgets/context_menu/excerpt_menu.dart').readAsStringSync();

    expect(playerSource,
        contains("_selectionContext(location, 'annotationContext')"));
    expect(
        playerSource, contains("_selectionContext(location, 'lookupContext')"));
    expect(menuSource, contains('annotationContext: widget.annotationContext'));
    expect(menuSource, contains('lookupContext: widget.lookupContext'));
    expect(excerptSource, contains('context: snapshot.annotationContext'));
    expect(excerptSource, isNot(contains('context: snapshot.lookupContext')));
  });

  test('rendered annotation taps use a bridge path distinct from selections',
      () {
    final bookSource = File('assets/foliate-js/src/book.js').readAsStringSync();
    final viewSource = File('assets/foliate-js/src/view.js').readAsStringSync();

    expect(viewSource, contains("this.#emit('show-annotation'"));
    expect(bookSource, contains("addEventListener('show-annotation'"));
    expect(bookSource, contains("callFlutter('onAnnotationClick'"));
    expect(bookSource, contains("callFlutter('onSelectionActionsRequested'"));
    expect(
        bookSource,
        isNot(
            contains("callFlutter('onSelectionActionsRequested', annotation")));
  });
}
