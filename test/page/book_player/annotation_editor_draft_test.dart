import 'package:anx_reader/page/book_player/annotation_editor/annotation_editor_draft.dart';
import 'package:anx_reader/page/book_player/selection_persistence_session.dart';
import 'package:anx_reader/service/sync/annotation_read_model.dart';
import 'package:flutter_test/flutter_test.dart';

const fingerprint = '0123456789abcdef0123456789abcdef';

SelectionSnapshot selection() => const SelectionSnapshot(
      selectedText: 'take it for granted',
      annotationContext: 'Do not take it for granted.',
      lookupContext: 'Remember this. Do not take it for granted. Be careful.',
      chapter: 'Chapter 1',
      selector: 'epubcfi(/6/2!/4/2:1)',
    );

AnnotationEditorSourceResult google(String text) =>
    AnnotationEditorSourceResult(
      providerId: 'google-translate',
      providerName: 'Google Translate',
      kind: 'translation',
      translation: text,
      metadata: const {'detectedLanguage': 'en'},
    );

void main() {
  test('new draft provider exploration and cancellation perform no writes', () {
    var canonicalWrites = 0;
    var outboxWrites = 0;
    final draft = AnnotationEditorDraft.forSelection(
      selection: selection(),
      bookTitle: 'Book',
    );

    final googleRequest =
        draft.startProvider(AnnotationEditorProvider.googleTranslate);
    expect(draft.completeProvider(googleRequest, google('перевод')), isTrue);
    final dictionaryRequest =
        draft.startProvider(AnnotationEditorProvider.ldoce);
    expect(
      draft.completeProvider(
        dictionaryRequest,
        const AnnotationEditorSourceResult(
          providerId: 'ldoce',
          providerName: 'LDOCE',
          kind: 'dictionary',
          translation: 'definition',
          markdown: '**LDOCE**',
        ),
      ),
      isTrue,
    );
    final aiRequest = draft.startProvider(AnnotationEditorProvider.ai);
    expect(
      draft.completeProvider(
        aiRequest,
        const AnnotationEditorSourceResult(
          providerId: 'openai',
          providerName: 'OpenAI',
          kind: 'ai-analysis',
          translation: 'перевод',
          commentary: AnnotationEditorCommentary(grammar: 'grammar'),
        ),
      ),
      isTrue,
    );
    draft.addAiExchange('Why?', 'Because.');
    draft.setPersonalNote('remember');
    draft.close();

    expect(canonicalWrites, 0);
    expect(outboxWrites, 0);
    expect(draft.existingRef, isNull);
  });

  test('providers retain independent result and error state', () {
    final draft = AnnotationEditorDraft.forSelection(
      selection: selection(),
      bookTitle: 'Book',
    );
    final googleRequest =
        draft.startProvider(AnnotationEditorProvider.googleTranslate);
    draft.completeProvider(googleRequest, google('first'));

    final dictionaryRequest =
        draft.startProvider(AnnotationEditorProvider.ldoce);
    draft.failProvider(dictionaryRequest, StateError('not found'));

    expect(
      draft
          .sourceResults[AnnotationEditorProvider.googleTranslate]?.translation,
      'first',
    );
    expect(
      draft.stateFor(AnnotationEditorProvider.ldoce).error,
      contains('not found'),
    );
  });

  test('refresh keeps identity and stale completion cannot overwrite result',
      () {
    final draft = AnnotationEditorDraft.forSelection(
      selection: selection(),
      bookTitle: 'Book',
    );
    final first = draft.startProvider(AnnotationEditorProvider.googleTranslate);
    final second =
        draft.startProvider(AnnotationEditorProvider.googleTranslate);

    expect(draft.completeProvider(first, google('stale')), isFalse);
    expect(draft.completeProvider(second, google('fresh')), isTrue);
    expect(
      draft
          .sourceResults[AnnotationEditorProvider.googleTranslate]?.translation,
      'fresh',
    );
  });

  test('late completion after close is ignored', () {
    final draft = AnnotationEditorDraft.forSelection(
      selection: selection(),
      bookTitle: 'Book',
    );
    final request =
        draft.startProvider(AnnotationEditorProvider.googleTranslate);
    draft.close();

    expect(draft.completeProvider(request, google('late')), isFalse);
    expect(draft.sourceResults, isEmpty);
  });

  test('new draft is saveable while unchanged existing draft is not dirty', () {
    final fresh = AnnotationEditorDraft.forSelection(
      selection: selection(),
      bookTitle: 'Book',
    );
    expect(fresh.isDirty, isTrue);

    final existing = _existingDraft();
    expect(existing.isDirty, isFalse);
    existing.setPersonalNote('changed');
    expect(existing.isDirty, isTrue);
  });

  test(
      'existing canonical material and current AI thread hydrate without calls',
      () {
    var providerCalls = 0;
    final draft = _existingDraft();

    expect(providerCalls, 0);
    expect(draft.existingRef?.annotationId, 'annotation-a');
    expect(draft.personalNote, 'remember');
    expect(
      draft
          .sourceResults[AnnotationEditorProvider.googleTranslate]?.translation,
      'перевод',
    );
    expect(
      draft.sourceResults[AnnotationEditorProvider.ldoce]?.markdown,
      '**LDOCE**',
    );
    expect(
      draft.sourceResults[AnnotationEditorProvider.ai]?.commentary?.grammar,
      'grammar',
    );
    expect(draft.aiThreadId, 'ai-thread:one');
    expect(draft.aiMessages.map((message) => message.content),
        ['Why?', 'Because.']);
  });

  test('newer tombstones do not resurrect older material or AI thread', () {
    final annotation = const CanonicalAnnotationReadAdapter().read({
      'schemaVersion': 2,
      'book': {
        'fingerprintAlgorithm': 'md5',
        'fingerprint': fingerprint,
      },
      'annotations': [
        {
          'id': 'annotation-a',
          'motivation': 'selection',
          'createdAt': '2026-01-01T00:00:00.000Z',
          'updatedAt': '2026-01-01T00:03:00.000Z',
          'target': {
            'selectedText': 'take it for granted',
            'selectors': [
              {'type': 'epub-cfi', 'cfi': 'epubcfi(/6/2!/4/2:1)'},
            ],
          },
          'enrichments': [
            _translation('active', '2026-01-01T00:01:00.000Z'),
            _translation(
              'deleted',
              '2026-01-01T00:03:00.000Z',
              deleted: true,
            ),
            _thread('active', '2026-01-01T00:01:00.000Z'),
            _thread(
              'deleted',
              '2026-01-01T00:03:00.000Z',
              deleted: true,
            ),
          ],
        },
      ],
    }).single;
    final draft = AnnotationEditorDraft.forAnnotation(
      selection: selection(),
      bookTitle: 'Book',
      annotation: annotation,
    );

    expect(draft.sourceResults, isEmpty);
    expect(draft.aiThreadId, isNull);
    expect(draft.aiMessages, isEmpty);
  });
}

Map<String, Object?> _translation(
  String id,
  String updatedAt, {
  bool deleted = false,
}) =>
    {
      'id': 'translation:$id',
      'kind': 'translation',
      'providerId': 'google-translate',
      'providerName': 'Google Translate',
      'translation': id,
      'createdAt': '2026-01-01T00:01:00.000Z',
      'updatedAt': updatedAt,
      if (deleted) 'deletedAt': updatedAt,
    };

Map<String, Object?> _thread(
  String id,
  String updatedAt, {
  bool deleted = false,
}) =>
    {
      'id': 'ai-thread:$id',
      'kind': 'ai-thread',
      'contextSnapshot': {
        'selectedText': 'take it for granted',
        'enrichmentIds': <Object>[],
      },
      'messages': <Object>[],
      'createdAt': '2026-01-01T00:01:00.000Z',
      'updatedAt': updatedAt,
      if (deleted) 'deletedAt': updatedAt,
    };

AnnotationEditorDraft _existingDraft() {
  final document = {
    'schemaVersion': 2,
    'book': {
      'fingerprintAlgorithm': 'md5',
      'fingerprint': fingerprint,
    },
    'annotations': [
      {
        'id': 'annotation-a',
        'motivation': 'selection',
        'createdAt': '2026-01-01T00:00:00.000Z',
        'updatedAt': '2026-01-01T00:05:00.000Z',
        'target': {
          'selectedText': 'take it for granted',
          'chapter': 'Chapter 1',
          'context': 'Do not take it for granted.',
          'selectors': [
            {'type': 'epub-cfi', 'cfi': 'epubcfi(/6/2!/4/2:1)'},
          ],
        },
        'enrichments': [
          {
            'id': 'translation:one',
            'kind': 'translation',
            'providerId': 'google-translate',
            'providerName': 'Google Translate',
            'translation': 'перевод',
            'createdAt': '2026-01-01T00:01:00.000Z',
            'updatedAt': '2026-01-01T00:01:00.000Z',
          },
          {
            'id': 'dictionary:one',
            'kind': 'dictionary',
            'providerId': 'ldoce',
            'providerName': 'LDOCE',
            'translation': 'definition',
            'markdown': '**LDOCE**',
            'createdAt': '2026-01-01T00:02:00.000Z',
            'updatedAt': '2026-01-01T00:02:00.000Z',
          },
          {
            'id': 'ai-analysis:one',
            'kind': 'ai-analysis',
            'providerId': 'openai',
            'providerName': 'OpenAI',
            'translation': 'AI translation',
            'commentary': {'grammar': 'grammar'},
            'createdAt': '2026-01-01T00:03:00.000Z',
            'updatedAt': '2026-01-01T00:03:00.000Z',
          },
          {
            'id': 'personal-note:annotation-a',
            'kind': 'personal-note',
            'content': 'remember',
            'createdAt': '2026-01-01T00:03:00.000Z',
            'updatedAt': '2026-01-01T00:03:00.000Z',
          },
          {
            'id': 'ai-thread:one',
            'kind': 'ai-thread',
            'contextSnapshot': {
              'selectedText': 'take it for granted',
              'enrichmentIds': ['ai-analysis:one'],
            },
            'messages': [
              {
                'id': 'message:assistant',
                'role': 'assistant',
                'sequence': 1,
                'content': 'Because.',
                'createdAt': '2026-01-01T00:04:00.000Z',
                'updatedAt': '2026-01-01T00:04:00.000Z',
              },
              {
                'id': 'message:user',
                'role': 'user',
                'sequence': 0,
                'content': 'Why?',
                'createdAt': '2026-01-01T00:04:00.000Z',
                'updatedAt': '2026-01-01T00:04:00.000Z',
              },
            ],
            'createdAt': '2026-01-01T00:04:00.000Z',
            'updatedAt': '2026-01-01T00:04:00.000Z',
          },
        ],
      },
    ],
  };
  final annotation = CanonicalAnnotationReadAdapter().read(document).single;
  return AnnotationEditorDraft.forAnnotation(
    selection: selection(),
    bookTitle: 'Book',
    annotation: annotation,
  );
}
