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
    expect(source, contains('hasPersistedAnnotation'));
    expect(source,
        contains('final ref = widget.persistenceSession.annotationRef'));
    expect(
      source,
      isNot(contains(
          'await widget.persistenceSession.ensureAnnotation(\n        _createOrResolve,\n      );\n      await annotationRepository.tombstoneAnnotation')),
    );
    expect(source, isNot(contains('saveTranslationForNativeId')));
    expect(source, isNot(contains('setPersonalNoteForNativeId')));
    expect(source, isNot(contains('updatePresentationForNativeId')));
    expect(source, isNot(contains('tombstoneAnnotationForBookNote')));
  });

  test('Notes and semantic consumers read canonical annotations only', () {
    const canonicalConsumers = [
      'lib/providers/book_notes.dart',
      'lib/providers/bookmark.dart',
      'lib/providers/notes_statistics.dart',
      'lib/providers/random_highlight_provider.dart',
      'lib/widgets/book_notes/book_note_tile.dart',
      'lib/widgets/book_notes/book_notes_list.dart',
      'lib/widgets/context_menu/excerpt_menu.dart',
      'lib/widgets/context_menu/reader_note_menu.dart',
      'lib/service/notes/export_notes.dart',
      'lib/dao/search_repository.dart',
      'lib/service/ai/tools/repository/notes_repository.dart',
    ];
    final forbidden = RegExp(
        r'book_note\.dart|bookNoteDao|readerNote|sharedAnnotationId|nativeNoteId');
    for (final path in canonicalConsumers) {
      expect(forbidden.hasMatch(File(path).readAsStringSync()), isFalse,
          reason: path);
    }

    final state = File('lib/models/book_notes_state.dart').readAsStringSync();
    final list =
        File('lib/widgets/book_notes/book_notes_list.dart').readAsStringSync();
    expect(state, contains('Set<String> selectedAnnotationIds'));
    expect(list, contains('ValueKey(bookNote.ref.annotationId)'));
    expect(File('lib/providers/book_notes.dart').readAsStringSync(),
        contains('tombstoneAnnotation(annotation.ref)'));
  });

  test('Notes surfaces share effective presentation and dirty persistence', () {
    final provider = File('lib/providers/book_notes.dart').readAsStringSync();
    final tile =
        File('lib/widgets/book_notes/book_note_tile.dart').readAsStringSync();
    final editor =
        File('lib/widgets/book_notes/book_notes_list.dart').readAsStringSync();
    final renderer =
        File('lib/page/book_player/foliate_annotation_adapter.dart')
            .readAsStringSync();

    for (final source in [provider, tile, editor, renderer]) {
      expect(source, contains('.effectivePresentation('));
    }
    expect(editor, contains('presentationDirty'));
    expect(editor, contains('personalNoteDirty'));
    expect(editor, contains('personalNote: personalNoteDirty'));
    expect(editor, contains('type: !isBookmark && presentationDirty'));
    expect(provider, contains('if (personalNote != null)'));
  });

  test('modern runtime has no legacy annotation-table writes or reads', () {
    const migrationOnly = {
      'lib/dao/database.dart',
      'lib/service/sync/legacy_annotation_bootstrap.dart',
      'lib/service/sync/legacy_annotation_store.dart',
    };
    final legacyTableAccess = RegExp(r'tb_notes|shared_annotation_id');
    final activeFiles = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .where((file) => !migrationOnly.contains(file.path));

    for (final file in activeFiles) {
      expect(legacyTableAccess.hasMatch(file.readAsStringSync()), isFalse,
          reason: file.path);
    }
    final migration = File('lib/service/sync/legacy_annotation_store.dart')
        .readAsStringSync();
    expect(migration, contains("'tb_notes'"));
    expect(migration, isNot(contains('insert(')));
    expect(migration, isNot(contains('update(')));
    expect(migration, isNot(contains('delete(')));
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
