import 'dart:convert';
import 'dart:io';

import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/page/book_player/annotation_editor/annotation_editor_controller.dart';
import 'package:anx_reader/page/book_player/annotation_editor/annotation_editor_draft.dart';
import 'package:anx_reader/page/book_player/selection_persistence_session.dart';
import 'package:anx_reader/service/sync/annotation_protocol.dart';
import 'package:anx_reader/service/sync/annotation_read_model.dart';
import 'package:anx_reader/service/sync/annotation_repository.dart';
import 'package:anx_reader/service/sync/shared_state_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  final lingua = jsonDecode(
    File('test/fixtures/lingua_annotation_book_v2.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final anx = jsonDecode(
    File('test/fixtures/anx_annotation_editor_book_v2.json').readAsStringSync(),
  ) as Map<String, dynamic>;

  test('Lingua material fixture is readable through semantic Anx fields', () {
    final decoded = decodeAnnotationDocument(lingua);
    final model = const CanonicalAnnotationReadAdapter().read(decoded).single;
    final byKind = _byKind(model);

    expect(decoded['schemaVersion'], 2);
    expect(byKind['translation']?.translation, 'случайно встретил');
    expect(byKind['translation']?.providerId, 'google-translate');
    expect(byKind['translation']?.data['metadata'], {
      'detectedLanguage': 'en',
      'futureMetadataField': 'preserve',
    });
    expect(byKind['dictionary']?.markdown, contains('come across somebody'));
    expect(byKind['dictionary']?.providerName, 'LDOCE');
    expect(byKind['ai-analysis']?.commentaryValue('translationNotes'),
        'Фразовый глагол.');
    expect(byKind['ai-analysis']?.commentaryValue('grammar'), 'Past simple.');
    expect(byKind['ai-analysis']?.commentaryValue('usage'), 'Neutral.');
    expect(byKind['ai-analysis']?.commentary?['chunks'], [
      {
        'canonicalForm': 'come across someone',
        'surfaceForm': 'came across an old friend',
        'meaning': 'случайно встретить кого-либо',
        'type': 'phrasal_verb',
        'examples': ['I came across Maya at the station.'],
      },
    ]);
    expect(byKind['ai-thread']?.data['messages'], hasLength(2));
  });

  test('known semantic fields are searchable without flattening unknown JSON',
      () {
    final model = const CanonicalAnnotationReadAdapter().read(lingua).single;
    final searchable = model.activeEnrichments
        .expand((item) => item.searchableText)
        .join('\n');

    expect(searchable, contains('случайно встретил'));
    expect(searchable, contains('come across somebody'));
    expect(searchable, contains('Фразовый глагол.'));
    expect(searchable, contains('Past simple.'));
    expect(searchable, contains('Neutral.'));
    expect(searchable, isNot(contains('preserve')));
  });

  test('Lingua fixture preserves unknown fields and deterministic merge', () {
    final before = canonicalAnnotationDocumentJson(lingua);
    final decoded = decodeAnnotationDocument(lingua);

    expect(canonicalAnnotationDocumentJson(decoded), before);
    expect(decoded['futureDocumentField'], {'preserve': true});
    final annotation = (decoded['annotations'] as List).single as Map;
    expect(annotation['futureAnnotationField'], ['preserve']);
    final translation = (annotation['enrichments'] as List)
        .cast<Map>()
        .singleWhere((item) => item['kind'] == 'translation');
    expect(translation['futureMaterialField'], {'preserve': true});
    expect(canonicalJson(mergeAnnotationDocuments(decoded, lingua)), before);
  });

  test('Lingua fixture hydrates every editor slot and ordered AI thread', () {
    final model = const CanonicalAnnotationReadAdapter().read(lingua).single;
    final draft = AnnotationEditorDraft.forAnnotation(
      selection: _selectionFrom(model),
      bookTitle: 'Lingua fixture',
      annotation: model,
    );

    expect(draft.sourceResults, hasLength(3));
    expect(
      draft
          .sourceResults[AnnotationEditorProvider.googleTranslate]?.translation,
      'случайно встретил',
    );
    expect(draft.sourceResults[AnnotationEditorProvider.ldoce]?.markdown,
        contains('come across somebody'));
    expect(
      draft.sourceResults[AnnotationEditorProvider.ai]?.commentary?.grammar,
      'Past simple.',
    );
    expect(
      draft.sourceResults[AnnotationEditorProvider.ai]?.commentary?.chunks
          ?.single.canonicalForm,
      'come across someone',
    );
    expect(draft.aiThreadId, 'lingua-thread');
    expect(
      draft.aiMessages.map((message) => message.role),
      ['user', 'assistant'],
    );
    expect(
      draft.aiMessages.map((message) => message.content),
      ['Is it formal?', 'It is neutral.'],
    );
  });

  test('Anx editor fixture satisfies Lingua material and thread contract', () {
    final decoded = decodeAnnotationDocument(anx);
    final model = const CanonicalAnnotationReadAdapter().read(decoded).single;
    final byKind = _byKind(model);

    expect(canonicalAnnotationDocumentJson(decoded),
        canonicalAnnotationDocumentJson(anx));
    expect(
        byKind.keys,
        containsAll([
          'translation',
          'dictionary',
          'ai-analysis',
          'ai-thread',
        ]));
    expect(byKind['translation']?.providerId, 'google-translate');
    expect(byKind['translation']?.translation, isNotEmpty);
    expect(byKind['dictionary']?.providerId, 'ldoce');
    expect(byKind['dictionary']?.markdown, isNotEmpty);
    expect(byKind['ai-analysis']?.providerId, 'configured-route');
    expect(byKind['ai-analysis']?.commentaryValue('translationNotes'),
        'Идиоматическая фраза.');
    final thread = byKind['ai-thread']!;
    expect(thread.data['contextSnapshot'],
        containsPair('selectedText', 'take it for granted'));
    expect(thread.data['messages'], hasLength(2));

    final draft = AnnotationEditorDraft.forAnnotation(
      selection: _selectionFrom(model),
      bookTitle: 'Anx fixture',
      annotation: model,
    );
    expect(draft.sourceResults, hasLength(3));
    expect(draft.aiMessages, hasLength(2));
  });

  test('editor Save retains unknown Lingua fields at every owned boundary',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('anx_cross_client_editor_');
    final shared = SharedStateDatabase(
      path: p.join(directory.path, 'shared_state.db'),
      factory: databaseFactoryFfi,
      now: () => DateTime.parse('2026-08-31T10:00:00.000Z'),
    );
    try {
      await shared.putAnnotationDocument(lingua);
      final model = const CanonicalAnnotationReadAdapter().read(lingua).single;
      final draft = AnnotationEditorDraft.forAnnotation(
        selection: _selectionFrom(model),
        bookTitle: 'Lingua fixture',
        annotation: model,
      );
      final repository = AnnotationRepository(
        shared,
        now: () => DateTime.parse('2026-08-31T10:00:00.000Z'),
      );
      final controller = AnnotationEditorController(
        draft: draft,
        book: _book(model.ref.bookFingerprint),
        saveDraft: repository.saveAnnotationEditorDraft,
        deleteAnnotation: repository.tombstoneAnnotation,
        targetLanguageCode: () => 'ru',
        targetLanguageName: () => 'Русский',
      );
      controller.setPersonalNote('Anx edit');
      expect(await controller.save(), model.ref);
      controller.dispose();

      final saved =
          (await shared.annotationDocument(model.ref.bookFingerprint))!;
      expect(saved['futureDocumentField'], {'preserve': true});
      expect(saved['book'], containsPair('title', 'Lingua fixture'));
      final annotation = (saved['annotations'] as List).single as Map;
      expect(annotation['futureAnnotationField'], ['preserve']);
      expect(annotation['target']['futureTargetField'], {'preserve': true});
      expect(annotation['target']['selectors'].single['futureSelectorField'],
          'preserve');

      final enrichments =
          (annotation['enrichments'] as List).cast<Map<String, dynamic>>();
      final translation =
          enrichments.singleWhere((item) => item['id'] == 'lingua-translation');
      expect(translation['futureMaterialField'], {'preserve': true});
      expect(translation['metadata']['futureMetadataField'], 'preserve');
      final analysis =
          enrichments.singleWhere((item) => item['id'] == 'lingua-ai');
      expect(analysis['futureAiField'], ['preserve']);
      expect(analysis['commentary']['futureCommentaryField'], 'preserve');
      expect(analysis['commentary']['chunks'], [
        {
          'canonicalForm': 'come across someone',
          'surfaceForm': 'came across an old friend',
          'meaning': 'случайно встретить кого-либо',
          'type': 'phrasal_verb',
          'examples': ['I came across Maya at the station.'],
        },
      ]);
      final thread =
          enrichments.singleWhere((item) => item['id'] == 'lingua-thread');
      expect(thread['futureThreadField'], ['preserve']);
      expect(
          thread['contextSnapshot']['futureContextField'], {'preserve': true});
      expect(thread['messages'].first['futureMessageField'], 'preserve');
    } finally {
      await shared.close();
      await directory.delete(recursive: true);
    }
  });
}

Map<String, AnnotationEnrichmentView> _byKind(AnnotationUiModel model) => {
      for (final item in model.activeEnrichments) item.kind: item,
    };

SelectionSnapshot _selectionFrom(AnnotationUiModel model) => SelectionSnapshot(
      selectedText: model.selectedText,
      annotationContext: model.annotationContext,
      lookupContext: model.annotationContext,
      chapter: model.chapter ?? '',
      selector: model.epubCfi!,
    );

Book _book(String fingerprint) => Book(
      id: 1,
      title: 'Lingua fixture',
      coverPath: '',
      filePath: 'book.epub',
      lastReadPosition: '',
      readingPercentage: 0,
      author: 'Author',
      isDeleted: false,
      rating: 0,
      md5: fingerprint,
      createTime: DateTime(2026),
      updateTime: DateTime(2026),
    );
