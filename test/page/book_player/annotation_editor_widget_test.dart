import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/page/book_player/annotation_editor/annotation_editor.dart';
import 'package:anx_reader/page/book_player/annotation_editor/annotation_editor_controller.dart';
import 'package:anx_reader/page/book_player/annotation_editor/annotation_editor_draft.dart';
import 'package:anx_reader/page/book_player/selection_persistence_session.dart';
import 'package:anx_reader/service/annotation_enrichment/google_annotation_translate.dart';
import 'package:anx_reader/service/sync/annotation_read_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _fingerprint = '0123456789abcdef0123456789abcdef';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs().initPrefs();
  });

  testWidgets('all source cards coexist at phone and desktop widths',
      (tester) async {
    for (final size in <Size>[
      const Size(390, 780),
      const Size(1200, 900),
    ]) {
      await tester.binding.setSurfaceSize(size);
      final controller = _controller(draft: _draftWithAllSources());
      addTearDown(controller.dispose);

      await _openDialog(tester, controller);

      expect(find.byType(Card), findsNWidgets(3));
      expect(find.text('Google Translate'), findsOneWidget);
      expect(find.text('LDOCE'), findsOneWidget);
      expect(find.text('Configured AI'), findsOneWidget);
      expect(tester.takeException(), isNull);

      final dialogWidth = tester
          .getSize(
            find.descendant(
              of: find.byType(Dialog),
              matching: find.byType(Scaffold),
            ),
          )
          .width;
      expect(dialogWidth, lessThanOrEqualTo(760));
      expect(dialogWidth, lessThanOrEqualTo(size.width - 24));

      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      await tester.tap(_promptAction('Discard'));
      await tester.pumpAndSettle();
    }
  });

  testWidgets('bottom actions stay visible while editor body scrolls',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 640));
    final controller = _controller(draft: _draftWithAllSources());
    addTearDown(controller.dispose);
    await _openDialog(tester, controller);

    final save = find.widgetWithText(FilledButton, 'Save');
    final cancel = find.widgetWithText(TextButton, 'Cancel');
    final initialSavePosition = tester.getTopLeft(save);

    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -500),
    );
    await tester.pump();

    expect(save, findsOneWidget);
    expect(cancel, findsOneWidget);
    expect(tester.getTopLeft(save), initialSavePosition);
    expect(find.text('AI chat'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dirty dismissal offers cancel, discard, and save',
      (tester) async {
    var saves = 0;
    final controller = _controller(
      saveDraft: (_) async {
        saves++;
        return _ref();
      },
    );
    addTearDown(controller.dispose);
    await _openDialog(tester, controller);

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('Save annotation changes?'), findsOneWidget);
    expect(_promptAction('Cancel'), findsOneWidget);
    expect(_promptAction('Discard'), findsOneWidget);
    expect(_promptAction('Save'), findsOneWidget);

    await tester.tap(_promptAction('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('New annotation'), findsOneWidget);
    expect(saves, 0);

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(_promptAction('Discard'));
    await tester.pumpAndSettle();

    expect(find.text('New annotation'), findsNothing);
    expect(saves, 0);
  });

  testWidgets('initial provider starts after the first frame', (tester) async {
    final google = _CountingGoogle();
    final controller = _controller(google: google);
    addTearDown(controller.dispose);

    expect(google.calls, 0);
    await _openDialog(
      tester,
      controller,
      initialProvider: AnnotationEditorProvider.googleTranslate,
    );
    expect(google.calls, 1);

    await tester.pump();
    expect(find.text('translated'), findsOneWidget);
    expect(google.calls, 1);
  });

  testWidgets('existing source does not rerun its initial provider',
      (tester) async {
    final google = _CountingGoogle();
    final controller = _controller(
      draft: _existingDraft(),
      google: google,
    );
    addTearDown(controller.dispose);

    await _openDialog(
      tester,
      controller,
      initialProvider: AnnotationEditorProvider.googleTranslate,
    );
    await tester.pump();

    expect(find.text('saved translation'), findsOneWidget);
    expect(find.text('Edit annotation'), findsOneWidget);
    expect(google.calls, 0);
  });
}

Future<void> _openDialog(
  WidgetTester tester,
  AnnotationEditorController controller, {
  AnnotationEditorProvider? initialProvider,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => showDialog<Object?>(
            context: context,
            barrierDismissible: false,
            builder: (_) => AnnotationEditorDialog(
              controller: controller,
              initialProvider: initialProvider,
            ),
          ),
          child: const Text('Open editor'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open editor'));
  await tester.pump();
}

Finder _promptAction(String label) => find.descendant(
      of: find.byType(AlertDialog),
      matching: find.text(label),
    );

AnnotationEditorController _controller({
  AnnotationEditorDraft? draft,
  GoogleAnnotationTranslateService? google,
  SaveAnnotationEditor? saveDraft,
}) =>
    AnnotationEditorController(
      draft: draft ?? _newDraft(),
      book: _book(),
      google: google,
      saveDraft: saveDraft ?? (_) async => _ref(),
      deleteAnnotation: (ref) async => ref,
      targetLanguageCode: () => 'uk',
      targetLanguageName: () => 'Українська',
    );

AnnotationEditorDraft _newDraft() => AnnotationEditorDraft.forSelection(
      selection: _selection(),
      bookTitle: 'Book',
    );

AnnotationEditorDraft _draftWithAllSources() {
  final draft = _newDraft();
  _complete(
    draft,
    AnnotationEditorProvider.googleTranslate,
    const AnnotationEditorSourceResult(
      providerId: 'google-translate',
      providerName: 'Google Translate',
      kind: 'translation',
      translation: 'google result',
    ),
  );
  _complete(
    draft,
    AnnotationEditorProvider.ldoce,
    const AnnotationEditorSourceResult(
      providerId: 'ldoce',
      providerName: 'LDOCE',
      kind: 'dictionary',
      translation: 'dictionary result',
    ),
  );
  _complete(
    draft,
    AnnotationEditorProvider.ai,
    const AnnotationEditorSourceResult(
      providerId: 'configured-route',
      providerName: 'Configured AI',
      kind: 'ai-analysis',
      translation: 'AI result',
    ),
  );
  return draft;
}

void _complete(
  AnnotationEditorDraft draft,
  AnnotationEditorProvider provider,
  AnnotationEditorSourceResult result,
) {
  final request = draft.startProvider(provider);
  draft.completeProvider(request, result);
}

AnnotationEditorDraft _existingDraft() {
  final annotation = CanonicalAnnotationReadAdapter().read({
    'schemaVersion': 2,
    'book': {
      'fingerprintAlgorithm': 'md5',
      'fingerprint': _fingerprint,
    },
    'annotations': [
      {
        'id': 'annotation-a',
        'motivation': 'selection',
        'createdAt': '2026-01-01T00:00:00.000Z',
        'updatedAt': '2026-01-01T00:00:00.000Z',
        'target': {
          'selectedText': 'phrase',
          'chapter': 'Chapter',
          'selectors': [
            {'type': 'epub-cfi', 'cfi': 'epubcfi(/6/2!/4/2:1)'},
          ],
        },
        'enrichments': [
          {
            'id': 'translation:a',
            'kind': 'translation',
            'providerId': 'google-translate',
            'providerName': 'Google Translate',
            'translation': 'saved translation',
            'createdAt': '2026-01-01T00:00:00.000Z',
            'updatedAt': '2026-01-01T00:00:00.000Z',
          },
        ],
      },
    ],
  }).single;
  return AnnotationEditorDraft.forAnnotation(
    selection: _selection(),
    bookTitle: 'Book',
    annotation: annotation,
  );
}

SelectionSnapshot _selection() => const SelectionSnapshot(
      selectedText: 'phrase',
      annotationContext: 'compact context',
      lookupContext: 'wider context',
      chapter: 'Chapter',
      selector: 'epubcfi(/6/2!/4/2:1)',
    );

Book _book() => Book(
      id: 1,
      title: 'Book',
      coverPath: '',
      filePath: 'book.epub',
      lastReadPosition: '',
      readingPercentage: 0,
      author: 'Author',
      isDeleted: false,
      rating: 0,
      md5: _fingerprint,
      createTime: DateTime(2026),
      updateTime: DateTime(2026),
    );

AnnotationRef _ref() => AnnotationRef(
      bookFingerprint: _fingerprint,
      annotationId: 'annotation-a',
    );

class _CountingGoogle extends GoogleAnnotationTranslateService {
  int calls = 0;

  @override
  Future<GoogleAnnotationTranslation> translate(
    String text, {
    required String targetLanguage,
  }) async {
    calls++;
    return const GoogleAnnotationTranslation(text: 'translated');
  }
}
