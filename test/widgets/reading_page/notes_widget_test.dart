import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/main.dart' show navigatorKey;
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/models/book_notes_state.dart';
import 'package:anx_reader/page/book_player/annotation_editor/annotation_editor.dart';
import 'package:anx_reader/providers/book_notes.dart';
import 'package:anx_reader/service/sync/annotation_catalog.dart';
import 'package:anx_reader/service/sync/annotation_read_model.dart';
import 'package:anx_reader/widgets/book_notes/book_note_tile.dart';
import 'package:anx_reader/widgets/reading_page/notes_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icons_plus/icons_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _fingerprint = '0123456789abcdef0123456789abcdef';
const _timestamp = '2026-08-30T10:00:00.000Z';

class _NotesController extends BookNotesController {
  @override
  Future<BookNotesState> build(String fingerprint) async {
    final notes = const CanonicalAnnotationReadAdapter().read({
      'schemaVersion': 2,
      'book': {'fingerprintAlgorithm': 'md5', 'fingerprint': fingerprint},
      'annotations': [
        _annotation('first', 'Chapter 1', 'Pitch black'),
        _annotation('second', 'Chapter 1', 'The doorway'),
        _annotation('third', 'Chapter 2', 'A contraption'),
        _annotation('fourth', null, 'Unassigned'),
      ],
    });
    return BookNotesState(
      book: AnnotationBookUiModel(
        fingerprint: fingerprint,
        title: 'Book',
        author: '',
        localBook: Book.mock().copyWith(md5: fingerprint),
        annotations: notes,
      ),
      allAnnotations: notes,
      visibleAnnotations: notes,
      viewSortMode: const NotesSortMode(
          field: NotesSortField.cfi, direction: SortDirection.asc),
      exportSortMode: const NotesSortMode(
          field: NotesSortField.cfi, direction: SortDirection.asc),
      showBookmarks: true,
      enabledTypeColors: NoteFilterDefaults.initialTypeColorSelection(),
      selectedAnnotationIds: {},
    );
  }
}

Map<String, dynamic> _annotation(String id, String? chapter, String text) => {
      'id': id,
      'motivation': 'selection',
      'createdAt': _timestamp,
      'updatedAt': _timestamp,
      'target': {
        'selectedText': text,
        if (chapter != null) 'chapter': chapter,
        'selectors': [
          {'type': 'epub-cfi', 'cfi': 'epubcfi(/6/2!/4/2)'}
        ],
      },
      'enrichments': [
        if (id == 'second')
          {
            'id': 'personal',
            'kind': 'personal-note',
            'content': 'My secret comment',
            'createdAt': _timestamp,
            'updatedAt': _timestamp,
          },
      ],
    };

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs().initPrefs();
  });

  Future<void> open(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        bookNotesControllerProvider(_fingerprint)
            .overrideWith(_NotesController.new)
      ],
      child: MaterialApp(
        navigatorKey: navigatorKey,
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        home: Scaffold(
            body: ReadingNotes(book: Book.mock().copyWith(md5: _fingerprint))),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('chapters start collapsed and expand independently',
      (tester) async {
    await open(tester);
    expect(find.byType(ExpansionTile), findsNWidgets(3));
    expect(find.text('Without chapter'), findsOneWidget);
    expect(find.byType(BookNoteTile), findsNothing);
    expect(find.byIcon(Icons.chevron_right), findsNWidgets(3));
    await tester.tap(find.text('Chapter 1'));
    await tester.pumpAndSettle();
    expect(find.byType(BookNoteTile), findsNWidgets(2));
    expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right), findsNWidgets(2));
    expect(find.text('Pitch black'), findsOneWidget);
    expect(find.text('A contraption'), findsNothing);
    await tester.tap(find.text('Chapter 1').first);
    await tester.pumpAndSettle();
    expect(find.byType(BookNoteTile), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('edit button opens the note editor', (tester) async {
    await open(tester);
    await tester.tap(find.text('Chapter 1'));
    await tester.pumpAndSettle();
    final editButton = find.byIcon(Icons.edit_outlined).first;
    await Scrollable.ensureVisible(tester.element(editButton), alignment: 0.5);
    await tester.pumpAndSettle();
    await tester.tap(editButton);
    await tester.pumpAndSettle();
    expect(find.byType(AnnotationEditorDialog), findsOneWidget);
    final editor = tester
        .widget<AnnotationEditorDialog>(find.byType(AnnotationEditorDialog));
    expect(editor.controller.draft.existingRef?.annotationId, 'first');
    expect(find.text('Google Translate'), findsOneWidget);
    expect(find.text('LDOCE'), findsOneWidget);
    expect(find.byIcon(Icons.auto_awesome), findsWidgets);
    expect(editor.controller.draft.selection.selectedText, 'Pitch black');
    await tester.tap(find.descendant(
      of: find.byType(AnnotationEditorDialog),
      matching: find.byTooltip('Close'),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(AnnotationEditorDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('filter controls stay above the list when scrolling',
      (tester) async {
    await open(tester);
    await tester.tap(find.text('Chapter 1'));
    await tester.pumpAndSettle();
    final filter = find.widgetWithIcon(IconButton, EvaIcons.funnel_outline);
    final before = tester.getRect(filter);
    expect(before.bottom,
        lessThanOrEqualTo(tester.getRect(find.byType(ListView)).top));
    await tester.drag(find.byType(ListView), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(tester.getRect(filter), before);
    await tester.tap(filter);
    await tester.pumpAndSettle();
    expect(find.text('By chapter'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'search matches text, chapter and comments; clearing collapses results',
      (tester) async {
    await open(tester);
    await tester.enterText(find.byType(TextField), '  PITCH  ');
    await tester.pumpAndSettle();
    expect(find.byType(ExpansionTile), findsOneWidget);
    expect(find.text('Pitch black'), findsOneWidget);
    expect(find.text('The doorway'), findsNothing);

    await tester.enterText(find.byType(TextField), 'secret');
    await tester.pumpAndSettle();
    expect(find.text('The doorway'), findsOneWidget);
    await tester.ensureVisible(find.text('The doorway'));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('The doorway'));
    await tester.pumpAndSettle();
    final container =
        ProviderScope.containerOf(tester.element(find.byType(ReadingNotes)));
    expect(
        container
            .read(bookNotesControllerProvider(_fingerprint))
            .requireValue
            .isSelecting,
        isTrue);

    await tester.enterText(find.byType(TextField), 'chapter 2');
    await tester.pumpAndSettle();
    expect(find.text('A contraption'), findsOneWidget);
    expect(
        container
            .read(bookNotesControllerProvider(_fingerprint))
            .requireValue
            .isSelecting,
        isFalse);

    await tester.enterText(find.byType(TextField), 'not present');
    await tester.pumpAndSettle();
    expect(find.text('No matching notes'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.clear));
    await tester.pumpAndSettle();
    expect(find.byType(ExpansionTile), findsNWidgets(3));
    expect(find.byType(BookNoteTile), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
