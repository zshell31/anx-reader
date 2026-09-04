import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/l10n/generated/L10n_ru.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/page/book_player/annotation_editor/annotation_editor.dart';
import 'package:anx_reader/page/book_player/annotation_editor/annotation_editor_controller.dart';
import 'package:anx_reader/page/book_player/annotation_editor/annotation_editor_draft.dart';
import 'package:anx_reader/page/book_player/selection_persistence_session.dart';
import 'package:anx_reader/service/annotation_enrichment/annotation_ai_service.dart';
import 'package:anx_reader/service/annotation_enrichment/google_annotation_translate.dart';
import 'package:anx_reader/service/annotation_enrichment/ldoce_annotation_dictionary.dart';
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
      expect(dialogWidth, equals((size.width - 24).clamp(0, 760)));

      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      await tester.tap(_promptAction('Discard'));
      await tester.pumpAndSettle();
    }
  });

  testWidgets('AI analysis renders structured chunks', (tester) async {
    final draft = AnnotationEditorDraft.forSelection(
      selection: _selection(),
      bookTitle: 'Book',
    );
    final request = draft.startProvider(AnnotationEditorProvider.ai);
    draft.completeProvider(
      request,
      const AnnotationEditorSourceResult(
        providerId: 'openai',
        providerName: 'OpenAI',
        kind: 'ai-analysis',
        commentary: AnnotationEditorCommentary(
          chunks: [
            AiChunk(
              canonicalForm: "have one's suspicions",
              surfaceForm: 'had your suspicions',
              meaning: 'иметь подозрения',
              examples: ["I've had my suspicions for a while."],
            ),
          ],
        ),
      ),
    );
    final controller = _controller(draft: draft);
    addTearDown(controller.dispose);
    await _openDialog(tester, controller);
    await tester.tap(find.text('OpenAI'));
    await tester.pumpAndSettle();
    expect(find.text('Useful chunks'), findsOneWidget);
    expect(
      find.textContaining("have one's suspicions", findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('Audio is fourth provider and renders playable draft with IPA',
      (tester) async {
    final draft = AnnotationEditorDraft.forSelection(
      selection: _selection(),
      bookTitle: 'Book',
    );
    final request = draft.startProvider(AnnotationEditorProvider.audio);
    draft.completeProvider(
      request,
      AnnotationEditorSourceResult(
        providerId: 'openai-audio',
        providerName: 'Audio',
        kind: 'audio',
        ipa: 'wɜːd',
        voice: 'alloy',
        model: 'gpt-4o-mini-tts',
        audio: const {
          'assetRef': 'annotation-assets/audio/test.mp3',
          'format': 'mp3',
          'mimeType': 'audio/mpeg',
          'byteLength': 3,
          'sha256':
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        },
        audioBytes: Uint8List.fromList([1, 2, 3]),
      ),
    );
    final controller = _controller(draft: draft);
    addTearDown(controller.dispose);
    await _openDialog(tester, controller);

    expect(
        AnnotationEditorProvider.values.last, AnnotationEditorProvider.audio);
    await tester.tap(find.text('Audio'));
    await tester.pumpAndSettle();
    expect(find.text('IPA: wɜːd'), findsOneWidget);
    final play = tester.widget<TextButton>(
      find.byKey(const Key('annotation-editor-audio-play')),
    );
    expect(play.onPressed, isNotNull);
  });

  testWidgets('existing annotation opens at full width and scroll offset zero',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    final controller = _controller(draft: _existingDraft());
    addTearDown(controller.dispose);

    await _openDialog(tester, controller);

    final scaffold = find.descendant(
      of: find.byType(Dialog),
      matching: find.byType(Scaffold),
    );
    expect(tester.getSize(scaffold).width, 760);
    final media = MediaQuery.of(tester.element(scaffold));
    expect(
      tester.getSize(scaffold).height,
      math.min(
        media.size.height * 0.94,
        media.size.height - media.viewInsets.bottom - 24,
      ),
    );
    expect(
      tester.getTopLeft(find.text('“phrase”')).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(find.byType(AppBar)).dy),
    );
  });

  testWidgets('context uses right and down disclosure arrows', (tester) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    await _openDialog(tester, controller);

    final contextTile = find.ancestor(
      of: find.text('Context'),
      matching: find.byType(ExpansionTile),
    );
    final disclosure = find.descendant(
      of: contextTile,
      matching: find.byType(AnimatedRotation),
    );
    expect(tester.widget<AnimatedRotation>(disclosure).turns, 0);

    await tester.tap(find.text('Context'));
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedRotation>(disclosure).turns, 0.25);
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

  testWidgets('source chips run every provider and reveal their results',
      (tester) async {
    final controller = _controller(
      google: _CountingGoogle(),
      ldoce: _ImmediateLdoce(),
      ai: _ImmediateAi(),
    );
    addTearDown(controller.dispose);
    await _openDialog(tester, controller);

    await tester.tap(find.widgetWithText(ActionChip, 'Google Translate'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    expect(
      controller.draft.sourceResults[AnnotationEditorProvider.googleTranslate]
          ?.translation,
      'translated',
    );

    await tester.tap(find.widgetWithText(ActionChip, 'LDOCE'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    expect(
      controller
          .draft.sourceResults[AnnotationEditorProvider.ldoce]?.translation,
      'dictionary definition',
    );

    await tester.tap(find.widgetWithText(ActionChip, 'OpenAI'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    expect(
      controller.draft.sourceResults[AnnotationEditorProvider.ai]?.commentary
          ?.grammar,
      'grammar analysis',
    );
  });

  testWidgets('provider failures stay visible and can be retried',
      (tester) async {
    final google = _FailingGoogle();
    final controller = _controller(google: google);
    addTearDown(controller.dispose);
    await _openDialog(tester, controller);

    await tester.tap(find.widgetWithText(ActionChip, 'Google Translate'));
    await tester.pumpAndSettle();

    expect(find.textContaining('network unavailable'), findsOneWidget);
    expect(find.widgetWithText(ActionChip, 'Google Translate'), findsOneWidget);
    expect(google.calls, 1);
  });

  testWidgets('existing source does not rerun its initial provider',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
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

    expect(find.text('saved translation'), findsNothing);
    expect(find.text('Edit annotation'), findsOneWidget);
    expect(google.calls, 0);

    await tester.tap(find.text('Google Translate'));
    await tester.pumpAndSettle();
    expect(find.text('saved translation'), findsOneWidget);
  });

  testWidgets('source cards collapse but a refreshing card stays expanded',
      (tester) async {
    final google = _PendingGoogle();
    final controller = _controller(
      draft: _draftWithAllSources(),
      google: google,
    );
    addTearDown(controller.dispose);
    await _openDialog(tester, controller);

    final googleCard = find.ancestor(
      of: find.text('Google Translate'),
      matching: find.byType(Card),
    );
    expect(find.text('google result'), findsNothing);
    expect(
      find.descendant(
        of: googleCard,
        matching: find.byIcon(Icons.chevron_right),
      ),
      findsOneWidget,
    );
    expect(
      tester
          .widget<AnimatedRotation>(find.descendant(
            of: googleCard,
            matching: find.byType(AnimatedRotation),
          ))
          .turns,
      0,
    );

    await tester.tap(find.text('Google Translate'));
    await tester.pumpAndSettle();
    expect(find.text('google result'), findsOneWidget);
    expect(
      tester
          .widget<AnimatedRotation>(find.descendant(
            of: googleCard,
            matching: find.byType(AnimatedRotation),
          ))
          .turns,
      0.25,
    );

    await tester.tap(find.text('Google Translate'));
    await tester.pumpAndSettle();
    expect(find.text('google result'), findsNothing);

    await tester.tap(find.descendant(
      of: googleCard,
      matching: find.byIcon(Icons.refresh),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(google.calls, 1);
    expect(find.text('google result'), findsOneWidget);

    await tester.tap(find.text('Google Translate'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('google result'), findsOneWidget);

    google.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('write idea intent focuses personal notes', (tester) async {
    final controller = _controller();
    addTearDown(controller.dispose);

    await _openDialog(tester, controller, focusPersonalNote: true);
    await tester.pump();

    final noteField = tester.widget<TextField>(
      find.byKey(const Key('annotation-editor-personal-note')),
    );
    expect(noteField.focusNode?.hasFocus, isTrue);
  });

  testWidgets('write idea fills the available area above the keyboard',
      (tester) async {
    await tester.binding.setSurfaceSize(null);
    tester.view.physicalSize = const Size(3600, 2700);
    addTearDown(tester.view.resetPhysicalSize);
    final controller = _controller(draft: _existingDraft());
    addTearDown(controller.dispose);

    await _openDialog(tester, controller, focusPersonalNote: true);
    tester.view.viewInsets = const FakeViewPadding(bottom: 900);
    addTearDown(tester.view.resetViewInsets);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final scaffold = find.descendant(
      of: find.byType(Dialog),
      matching: find.byType(Scaffold),
    );
    final rect = tester.getRect(scaffold);
    final logicalHeight =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    final logicalBottomInset =
        tester.view.viewInsets.bottom / tester.view.devicePixelRatio;
    expect(rect.top, 12);
    expect(rect.bottom, logicalHeight - logicalBottomInset - 12);
  });

  test('editor has generated Russian localization strings', () {
    final l10n = L10nRu();

    expect(l10n.annotationEditorNewTitle, 'Новая аннотация');
    expect(l10n.annotationEditorAddSource, 'Добавить источник');
    expect(l10n.annotationEditorPersonalNote, 'Личная заметка');
    expect(l10n.annotationEditorAiChat, 'Чат с ИИ');
  });
}

Future<void> _openDialog(
  WidgetTester tester,
  AnnotationEditorController controller, {
  AnnotationEditorProvider? initialProvider,
  bool focusPersonalNote = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Builder(
        builder: (context) => TextButton(
          key: const Key('open-editor'),
          onPressed: () => showDialog<Object?>(
            context: context,
            barrierDismissible: false,
            builder: (_) => AnnotationEditorDialog(
              controller: controller,
              initialProvider: initialProvider,
              focusPersonalNote: focusPersonalNote,
            ),
          ),
          child: const Text('Open editor'),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('open-editor')));
  await tester.pump();
}

Finder _promptAction(String label) => find.descendant(
      of: find.byType(AlertDialog),
      matching: find.text(label),
    );

AnnotationEditorController _controller({
  AnnotationEditorDraft? draft,
  GoogleAnnotationTranslateService? google,
  LdoceAnnotationDictionaryService? ldoce,
  AnnotationAiService? ai,
  SaveAnnotationEditor? saveDraft,
}) =>
    AnnotationEditorController(
      draft: draft ?? _newDraft(),
      book: _book(),
      google: google,
      ldoce: ldoce,
      ai: ai,
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

class _PendingGoogle extends GoogleAnnotationTranslateService {
  final Completer<GoogleAnnotationTranslation> _completer = Completer();
  int calls = 0;

  void complete() {
    _completer.complete(
      const GoogleAnnotationTranslation(text: 'refreshed translation'),
    );
  }

  @override
  Future<GoogleAnnotationTranslation> translate(
    String text, {
    required String targetLanguage,
  }) {
    calls++;
    return _completer.future;
  }
}

class _FailingGoogle extends GoogleAnnotationTranslateService {
  int calls = 0;

  @override
  Future<GoogleAnnotationTranslation> translate(
    String text, {
    required String targetLanguage,
  }) async {
    calls++;
    throw StateError('network unavailable');
  }
}

class _ImmediateLdoce extends LdoceAnnotationDictionaryService {
  @override
  Future<LdoceArticle> lookup(String text) async => const LdoceArticle(
        title: 'phrase',
        url: 'https://example.test/phrase',
        entries: [
          LdoceEntry(
            headword: 'phrase',
            senses: [LdoceSense(definition: 'dictionary definition')],
          ),
        ],
      );
}

class _ImmediateAi extends AnnotationAiService {
  @override
  Future<AnnotationEditorSourceResult> analyze({
    required String selectedText,
    required String? context,
    required String bookTitle,
    required String chapter,
    required String targetLanguageCode,
    required String targetLanguageName,
  }) async =>
      const AnnotationEditorSourceResult(
        providerId: 'route-id',
        providerName: 'Configured AI',
        kind: 'ai-analysis',
        commentary: AnnotationEditorCommentary(grammar: 'grammar analysis'),
      );

  @override
  Future<String> followUp({
    required AnnotationEditorDraft draft,
    required String question,
    required String targetLanguageCode,
    required String targetLanguageName,
  }) async =>
      'answer';
}
