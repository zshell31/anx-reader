import 'dart:io';

import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/service/sync/annotation_protocol.dart';
import 'package:anx_reader/service/sync/annotation_read_model.dart';
import 'package:anx_reader/service/sync/annotation_repository.dart';
import 'package:anx_reader/service/sync/annotation_selectors.dart';
import 'package:anx_reader/service/sync/shared_state_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const fingerprint = '0123456789abcdef0123456789abcdef';
const cfi = 'epubcfi(/6/4!/4/2:3)';
final instant = DateTime.parse('2026-01-02T03:04:05.000Z');

Book localBook() => Book(
      id: 7,
      title: 'Book',
      coverPath: '',
      filePath: 'book.epub',
      lastReadPosition: '',
      readingPercentage: 0,
      author: 'Author',
      isDeleted: false,
      rating: 0,
      md5: fingerprint,
      createTime: instant,
      updateTime: instant,
    );

Book localPdf() => localBook()..filePath = 'book.pdf';

CanonicalSelectionCreation creation({String? context = 'A sentence.'}) =>
    CanonicalSelectionCreation(
      book: localBook(),
      selectedText: 'selected text',
      epubCfi: cfi,
      chapter: 'Chapter 1',
      context: context,
    );

Map<String, dynamic> annotationOf(Map<String, dynamic> document, String id) =>
    (document['annotations'] as List)
        .cast<Map<String, dynamic>>()
        .singleWhere((annotation) => annotation['id'] == id);

void main() {
  sqfliteFfiInit();

  late Directory directory;
  late SharedStateDatabase shared;
  late AnnotationRepository repository;
  late List<String> semanticNotifications;
  late int presentationNotifications;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('anx_repository_test_');
    shared = SharedStateDatabase(
      path: p.join(directory.path, 'shared_state.db'),
      factory: databaseFactoryFfi,
      now: () => instant,
    );
    semanticNotifications = [];
    presentationNotifications = 0;
    repository = AnnotationRepository(
      shared,
      now: () => instant,
      onCanonicalMutation: semanticNotifications.add,
      onPresentationMutation: () => presentationNotifications++,
    );
  });

  tearDown(() async {
    await shared.close();
    await directory.delete(recursive: true);
  });

  test('creation commits canonical state before notifying listeners', () async {
    Map<String, dynamic>? visibleAtNotification;
    repository = AnnotationRepository(
      shared,
      now: () => instant,
      onCanonicalMutation: (id) {
        expect(id, fingerprint);
        semanticNotifications.add(id);
      },
    );

    final ref = await repository.createAnnotation(creation());
    visibleAtNotification = await shared.annotationDocument(fingerprint);

    expect(ref.bookFingerprint, fingerprint);
    expect(ref.annotationId, isNotEmpty);
    expect(semanticNotifications, [fingerprint]);
    final annotation = annotationOf(visibleAtNotification!, ref.annotationId);
    expect(annotation['target']['context'], 'A sentence.');
    expect((await shared.pendingOutbox()).single.documentId, fingerprint);
  });

  test('PDF creation uses portable page and contextual quote selectors',
      () async {
    const pageText = 'First repeated phrase. Second repeated phrase.';
    final start = pageText.lastIndexOf('repeated phrase');
    final target = PdfAnnotationTarget.fromPageText(
      page: 3,
      pageText: pageText,
      start: start,
      end: start + 'repeated phrase'.length,
      pageOffsetRatio: 0.625,
    );

    final ref = await repository.createAnnotation(
      CanonicalSelectionCreation.pdf(
        book: localPdf(),
        selectedText: target.exact,
        target: target,
        chapter: 'Page 3',
        context: pageText,
      ),
    );

    final document = await shared.annotationDocument(fingerprint);
    final annotation = annotationOf(document!, ref.annotationId);
    final restored = PdfAnnotationTarget.fromSelectors(
      annotation['target']['selectors'],
    );
    expect(restored?.page, 3);
    expect(restored?.pageOffsetRatio, 0.625);
    expect(restored?.resolve(pageText)?.start, start);
    expect(
      CanonicalAnnotationReadAdapter().read(document).single.pdfTarget?.exact,
      'repeated phrase',
    );
  });

  test('missing context is omitted and same CFI never implies reuse', () async {
    final first = await repository.createAnnotation(creation(context: '  '));
    final second = await repository.createAnnotation(creation(context: null));
    final document = (await shared.annotationDocument(fingerprint))!;

    expect(first, isNot(second));
    expect(first.annotationId, isNot(second.annotationId));
    expect(document['annotations'], hasLength(2));
    for (final annotation in (document['annotations'] as List).cast<Map>()) {
      expect(annotation['target'], isNot(contains('context')));
      expect(annotation['target']['selectors'].single['cfi'], cfi);
    }
  });

  test('first-save translation and personal note are canonical enrichments',
      () async {
    final translation = await repository.createAnnotationWithTranslation(
        creation(), ' translated ');
    final personal = await repository.createAnnotationWithPersonalNote(
        creation(), ' remember ');
    final document = (await shared.annotationDocument(fingerprint))!;

    expect(
        annotationOf(document, translation.annotationId)['enrichments'],
        contains(predicate<Map>((value) =>
            value['kind'] == 'translation' &&
            value['translation'] == 'translated' &&
            value['providerId'] == 'anx-reader' &&
            !value.containsKey('content'))));
    expect(
        annotationOf(document, personal.annotationId)['enrichments'],
        contains(predicate<Map>((value) =>
            value['kind'] == 'personal-note' &&
            value['content'] == 'remember')));
  });

  test('canonical enrichment APIs retain AnnotationRef identity', () async {
    final ref = await repository.createAnnotation(creation());

    expect(
        await repository.saveDictionaryResult(
          ref,
          '**full definition**',
          translation: 'definition',
          providerId: 'dictionary-provider',
          providerName: 'Dictionary Provider',
          metadata: const {'source': 'test'},
        ),
        ref);
    expect(
        await repository.saveAiAnalysis(
          ref,
          'analysis',
          translation: 'перевод',
          grammar: 'grammar',
          usage: 'usage',
          providerId: 'ai-provider',
          providerName: 'AI Provider',
        ),
        ref);
    expect(await repository.saveTranslation(ref, 'translation'), ref);
    expect(
        await repository.saveAiThread(
          ref,
          const [
            AiThreadMessageInput(role: 'user', content: 'question'),
            AiThreadMessageInput(role: 'assistant', content: 'answer'),
          ],
          enrichmentIds: const ['translation:known'],
        ),
        ref);

    final annotation = annotationOf(
        (await shared.annotationDocument(fingerprint))!, ref.annotationId);
    expect((annotation['enrichments'] as List).map((value) => value['kind']),
        containsAll(['dictionary', 'ai-analysis', 'translation', 'ai-thread']));
    final materials =
        (annotation['enrichments'] as List).cast<Map<String, dynamic>>();
    final dictionary =
        materials.singleWhere((value) => value['kind'] == 'dictionary');
    expect(dictionary['translation'], 'definition');
    expect(dictionary['markdown'], '**full definition**');
    expect(dictionary['metadata'], {'source': 'test'});
    expect(dictionary, isNot(contains('content')));
    final analysis =
        materials.singleWhere((value) => value['kind'] == 'ai-analysis');
    expect(analysis['translation'], 'перевод');
    expect(analysis['commentary'], {
      'translation': 'перевод',
      'translationNotes': 'analysis',
      'grammar': 'grammar',
      'usage': 'usage',
    });
    expect(analysis, isNot(contains('content')));
    final savedTranslation =
        materials.singleWhere((value) => value['kind'] == 'translation');
    expect(savedTranslation['translation'], 'translation');
    expect(savedTranslation, isNot(contains('content')));
    final thread = (annotation['enrichments'] as List)
        .cast<Map<String, dynamic>>()
        .singleWhere((value) => value['kind'] == 'ai-thread');
    expect(thread['messages'], hasLength(2));
    expect(thread['contextSnapshot']['enrichmentIds'], ['translation:known']);
  });

  test('editor first Save creates all material in one canonical revision',
      () async {
    final ref = await repository.saveAnnotationEditorDraft(
      AnnotationEditorSaveInput(
        creation: creation(),
        materials: const [
          AnnotationEditorMaterialInput(
            providerId: 'google-translate',
            providerName: 'Google Translate',
            kind: 'translation',
            translation: 'перевод',
            metadata: {'detectedLanguage': 'en'},
          ),
          AnnotationEditorMaterialInput(
            providerId: 'ldoce',
            providerName: 'LDOCE',
            kind: 'dictionary',
            translation: 'definition',
            markdown: '**LDOCE**',
            metadata: {'url': 'https://www.ldoceonline.com/dictionary/test'},
          ),
          AnnotationEditorMaterialInput(
            providerId: 'configured-route',
            providerName: 'Configured AI',
            kind: 'ai-analysis',
            translation: 'AI translation',
            commentary: {
              'translation': 'AI translation',
              'translationNotes': 'notes',
              'grammar': 'grammar',
              'usage': 'usage',
            },
          ),
          AnnotationEditorMaterialInput(
            providerId: 'openai-audio',
            providerName: 'Audio',
            kind: 'audio',
            ipa: 'səˈlɛktɪd tɛkst',
            voice: 'alloy',
            model: 'gpt-4o-mini-tts',
            audio: {
              'assetRef': 'annotation-assets/audio/test.mp3',
              'format': 'mp3',
              'mimeType': 'audio/mpeg',
              'byteLength': 3,
              'sha256':
                  'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            },
          ),
        ],
        personalNote: 'remember',
        aiMessages: const [
          AnnotationEditorMessageInput(
            role: 'user',
            content: 'Why?',
            sequence: 0,
          ),
          AnnotationEditorMessageInput(
            role: 'assistant',
            content: 'Because.',
            sequence: 1,
          ),
          AnnotationEditorMessageInput(
            role: 'user',
            content: 'Formal?',
            sequence: 2,
          ),
          AnnotationEditorMessageInput(
            role: 'assistant',
            content: 'Neutral.',
            sequence: 3,
          ),
        ],
      ),
    );

    final snapshot = await shared.documentSnapshot('annotations', fingerprint);
    final document = (await shared.annotationDocument(fingerprint))!;
    final annotation = annotationOf(document, ref.annotationId);
    expect(snapshot?.localRevision, 1,
        reason: 'one editor Save is one canonical commit');
    expect(semanticNotifications, [fingerprint]);
    expect(document['annotations'], hasLength(1));
    expect(
      (annotation['enrichments'] as List).map((item) => item['kind']),
      containsAll([
        'translation',
        'dictionary',
        'ai-analysis',
        'audio',
        'personal-note',
        'ai-thread',
      ]),
    );
    final translation = (annotation['enrichments'] as List)
        .cast<Map>()
        .singleWhere((item) => item['kind'] == 'translation');
    expect(translation['translation'], 'перевод');
    expect(translation, isNot(contains('content')));
    final dictionary = (annotation['enrichments'] as List)
        .cast<Map>()
        .singleWhere((item) => item['kind'] == 'dictionary');
    expect(dictionary['markdown'], '**LDOCE**');
    final analysis = (annotation['enrichments'] as List)
        .cast<Map>()
        .singleWhere((item) => item['kind'] == 'ai-analysis');
    expect(analysis['providerId'], 'configured-route');
    expect(analysis['commentary']['grammar'], 'grammar');
    final audio = (annotation['enrichments'] as List)
        .cast<Map>()
        .singleWhere((item) => item['kind'] == 'audio');
    expect(audio['ipa'], 'səˈlɛktɪd tɛkst');
    expect(audio['audio']['assetRef'], 'annotation-assets/audio/test.mp3');
    final thread = (annotation['enrichments'] as List)
        .cast<Map>()
        .singleWhere((item) => item['kind'] == 'ai-thread');
    expect(thread['messages'], hasLength(4));
    expect(thread['contextSnapshot']['context'], 'A sentence.');
  });

  test('editor edit preserves UUID, IDs, createdAt, and unknown fields',
      () async {
    final ref = await repository.saveAnnotationEditorDraft(
      AnnotationEditorSaveInput(
        creation: creation(),
        materials: const [
          AnnotationEditorMaterialInput(
            providerId: 'google-translate',
            providerName: 'Google Translate',
            kind: 'translation',
            translation: 'first',
          ),
        ],
        aiMessages: const [
          AnnotationEditorMessageInput(
            role: 'user',
            content: 'Why?',
            sequence: 0,
          ),
          AnnotationEditorMessageInput(
            role: 'assistant',
            content: 'Because.',
            sequence: 1,
          ),
        ],
      ),
    );
    var document = (await shared.annotationDocument(fingerprint))!;
    final annotation = annotationOf(document, ref.annotationId);
    annotation['futureField'] = {'keep': true};
    final translation = (annotation['enrichments'] as List)
        .cast<Map<String, dynamic>>()
        .singleWhere((item) => item['kind'] == 'translation');
    translation['futureMaterial'] = true;
    final translationId = translation['id'];
    final translationCreated = translation['createdAt'];
    final thread = (annotation['enrichments'] as List)
        .cast<Map<String, dynamic>>()
        .singleWhere((item) => item['kind'] == 'ai-thread');
    final threadId = thread['id'] as String;
    final oldMessages = (thread['messages'] as List).cast<Map>();
    await shared.putAnnotationDocument(document);
    final revisionBefore =
        (await shared.documentSnapshot('annotations', fingerprint))!
            .localRevision;

    final result = await repository.saveAnnotationEditorDraft(
      AnnotationEditorSaveInput(
        existingRef: ref,
        materials: [
          AnnotationEditorMaterialInput(
            enrichmentId: translationId as String,
            providerId: 'google-translate',
            providerName: 'Google Translate',
            kind: 'translation',
            translation: 'refreshed',
          ),
        ],
        aiThreadId: threadId,
        aiMessages: [
          AnnotationEditorMessageInput(
            messageId: oldMessages[0]['id'] as String,
            role: 'user',
            content: 'Why?',
            sequence: 0,
          ),
          AnnotationEditorMessageInput(
            messageId: oldMessages[1]['id'] as String,
            role: 'assistant',
            content: 'Because.',
            sequence: 1,
          ),
          const AnnotationEditorMessageInput(
            role: 'user',
            content: 'Formal?',
            sequence: 2,
          ),
          const AnnotationEditorMessageInput(
            role: 'assistant',
            content: 'Neutral.',
            sequence: 3,
          ),
        ],
      ),
    );

    expect(result, ref);
    document = (await shared.annotationDocument(fingerprint))!;
    expect(document['annotations'], hasLength(1));
    final edited = annotationOf(document, ref.annotationId);
    expect(edited['futureField'], {'keep': true});
    final editedTranslation = (edited['enrichments'] as List)
        .cast<Map>()
        .singleWhere((item) => item['id'] == translationId);
    expect(editedTranslation['translation'], 'refreshed');
    expect(editedTranslation['createdAt'], translationCreated);
    expect(editedTranslation['futureMaterial'], true);
    final editedThread = (edited['enrichments'] as List)
        .cast<Map>()
        .singleWhere((item) => item['id'] == threadId);
    expect(editedThread['messages'], hasLength(4));
    expect(
      (await shared.documentSnapshot('annotations', fingerprint))!
          .localRevision,
      revisionBefore + 1,
      reason: 'the entire editor edit must commit exactly once',
    );
  });

  test('editor removal is tombstoned on Save and Cancel performs no mutation',
      () async {
    final ref = await repository.saveAnnotationEditorDraft(
      AnnotationEditorSaveInput(
        creation: creation(),
        materials: const [
          AnnotationEditorMaterialInput(
            providerId: 'google-translate',
            providerName: 'Google Translate',
            kind: 'translation',
            translation: 'translation',
          ),
          AnnotationEditorMaterialInput(
            providerId: 'ldoce',
            providerName: 'LDOCE',
            kind: 'dictionary',
            markdown: 'dictionary',
          ),
          AnnotationEditorMaterialInput(
            providerId: 'route',
            providerName: 'AI',
            kind: 'ai-analysis',
            commentary: {'grammar': 'grammar'},
          ),
        ],
      ),
    );
    final beforeCancel =
        await shared.canonicalDocument('annotations', fingerprint);
    final revisionBeforeCancel =
        (await shared.documentSnapshot('annotations', fingerprint))!
            .localRevision;

    // Removing from an in-memory draft and cancelling invokes no repository API.
    expect(
      await shared.canonicalDocument('annotations', fingerprint),
      orderedEquals(beforeCancel!),
    );
    expect(
      (await shared.documentSnapshot('annotations', fingerprint))!
          .localRevision,
      revisionBeforeCancel,
    );

    await repository.saveAnnotationEditorDraft(
      AnnotationEditorSaveInput(
        existingRef: ref,
        materials: const [
          AnnotationEditorMaterialInput(
            providerId: 'google-translate',
            providerName: 'Google Translate',
            kind: 'translation',
            translation: 'translation',
          ),
          AnnotationEditorMaterialInput(
            providerId: 'route',
            providerName: 'AI',
            kind: 'ai-analysis',
            commentary: {'grammar': 'grammar'},
          ),
        ],
      ),
    );
    final annotation = annotationOf(
      (await shared.annotationDocument(fingerprint))!,
      ref.annotationId,
    );
    final enrichments =
        (annotation['enrichments'] as List).cast<Map<String, dynamic>>();
    expect(
      enrichments.singleWhere((item) => item['kind'] == 'dictionary'),
      contains('deletedAt'),
    );
    expect(
      enrichments.singleWhere((item) => item['kind'] == 'translation'),
      isNot(contains('deletedAt')),
    );
    expect(
      enrichments.singleWhere((item) => item['kind'] == 'ai-analysis'),
      isNot(contains('deletedAt')),
    );
  });

  test('editor never resurrects a tombstoned enrichment ID', () async {
    final ref = await repository.saveAnnotationEditorDraft(
      AnnotationEditorSaveInput(
        creation: creation(),
        materials: const [
          AnnotationEditorMaterialInput(
            providerId: 'google-translate',
            providerName: 'Google Translate',
            kind: 'translation',
            translation: 'first',
          ),
        ],
      ),
    );
    var document = (await shared.annotationDocument(fingerprint))!;
    final old =
        (annotationOf(document, ref.annotationId)['enrichments'] as List)
            .cast<Map<String, dynamic>>()
            .single;
    final oldId = old['id'] as String;
    old['deletedAt'] = '2026-01-02T03:04:06.000Z';
    old['updatedAt'] = '2026-01-02T03:04:06.000Z';
    await shared.putAnnotationDocument(document);

    await repository.saveAnnotationEditorDraft(
      AnnotationEditorSaveInput(
        existingRef: ref,
        materials: [
          AnnotationEditorMaterialInput(
            enrichmentId: oldId,
            providerId: 'google-translate',
            providerName: 'Google Translate',
            kind: 'translation',
            translation: 'second',
          ),
        ],
      ),
    );
    document = (await shared.annotationDocument(fingerprint))!;
    final translations =
        (annotationOf(document, ref.annotationId)['enrichments'] as List)
            .cast<Map<String, dynamic>>()
            .where((item) => item['kind'] == 'translation')
            .toList();
    expect(translations, hasLength(2));
    expect(
      translations.singleWhere((item) => item['id'] == oldId),
      contains('deletedAt'),
    );
    expect(
      translations.singleWhere((item) => item['id'] != oldId)['translation'],
      'second',
    );
  });

  test('editor Save clears personal note with its stable tombstone', () async {
    final ref = await repository.saveAnnotationEditorDraft(
      AnnotationEditorSaveInput(
        creation: creation(),
        personalNote: 'remember',
      ),
    );
    var annotation = annotationOf(
      (await shared.annotationDocument(fingerprint))!,
      ref.annotationId,
    );
    final note = (annotation['enrichments'] as List)
        .cast<Map<String, dynamic>>()
        .singleWhere((item) => item['kind'] == 'personal-note');
    final noteId = note['id'];

    await repository.saveAnnotationEditorDraft(
      AnnotationEditorSaveInput(existingRef: ref, personalNote: ''),
    );

    annotation = annotationOf(
      (await shared.annotationDocument(fingerprint))!,
      ref.annotationId,
    );
    final cleared = (annotation['enrichments'] as List)
        .cast<Map<String, dynamic>>()
        .singleWhere((item) => item['kind'] == 'personal-note');
    expect(cleared['id'], noteId);
    expect(cleared['content'], '');
    expect(cleared, contains('deletedAt'));
  });

  test('editor removes AI and Google independently', () async {
    final ref = await repository.saveAnnotationEditorDraft(
      AnnotationEditorSaveInput(
        creation: creation(),
        materials: const [
          AnnotationEditorMaterialInput(
            providerId: 'google-translate',
            providerName: 'Google Translate',
            kind: 'translation',
            translation: 'google',
          ),
          AnnotationEditorMaterialInput(
            providerId: 'ldoce',
            providerName: 'LDOCE',
            kind: 'dictionary',
            markdown: 'dictionary',
          ),
          AnnotationEditorMaterialInput(
            providerId: 'route',
            providerName: 'AI',
            kind: 'ai-analysis',
            commentary: {'grammar': 'grammar'},
          ),
        ],
      ),
    );
    var annotation = annotationOf(
      (await shared.annotationDocument(fingerprint))!,
      ref.annotationId,
    );
    final initial =
        (annotation['enrichments'] as List).cast<Map<String, dynamic>>();
    final google = initial.singleWhere((item) => item['kind'] == 'translation');
    final dictionary =
        initial.singleWhere((item) => item['kind'] == 'dictionary');
    final ai = initial.singleWhere((item) => item['kind'] == 'ai-analysis');
    final observedIds = initial.map((item) => item['id'] as String).toSet();

    await repository.saveAnnotationEditorDraft(
      AnnotationEditorSaveInput(
        existingRef: ref,
        observedMaterialIds: observedIds,
        materials: [
          AnnotationEditorMaterialInput(
            enrichmentId: google['id'] as String,
            providerId: 'google-translate',
            providerName: 'Google Translate',
            kind: 'translation',
            translation: 'google',
          ),
          AnnotationEditorMaterialInput(
            enrichmentId: dictionary['id'] as String,
            providerId: 'ldoce',
            providerName: 'LDOCE',
            kind: 'dictionary',
            markdown: 'dictionary',
          ),
        ],
      ),
    );
    annotation = annotationOf(
      (await shared.annotationDocument(fingerprint))!,
      ref.annotationId,
    );
    var materials =
        (annotation['enrichments'] as List).cast<Map<String, dynamic>>();
    expect(materials.singleWhere((item) => item['id'] == ai['id']),
        contains('deletedAt'));
    expect(materials.singleWhere((item) => item['id'] == google['id']),
        isNot(contains('deletedAt')));

    await repository.saveAnnotationEditorDraft(
      AnnotationEditorSaveInput(
        existingRef: ref,
        observedMaterialIds: observedIds,
        materials: [
          AnnotationEditorMaterialInput(
            enrichmentId: dictionary['id'] as String,
            providerId: 'ldoce',
            providerName: 'LDOCE',
            kind: 'dictionary',
            markdown: 'dictionary',
          ),
        ],
      ),
    );
    annotation = annotationOf(
      (await shared.annotationDocument(fingerprint))!,
      ref.annotationId,
    );
    materials =
        (annotation['enrichments'] as List).cast<Map<String, dynamic>>();
    expect(materials.singleWhere((item) => item['id'] == google['id']),
        contains('deletedAt'));
    expect(materials.singleWhere((item) => item['id'] == dictionary['id']),
        isNot(contains('deletedAt')));
  });

  test('no-op existing editor Save writes no revision or notification',
      () async {
    final ref = await repository.saveAnnotationEditorDraft(
      AnnotationEditorSaveInput(
        creation: creation(),
        materials: const [
          AnnotationEditorMaterialInput(
            providerId: 'google-translate',
            providerName: 'Google Translate',
            kind: 'translation',
            translation: 'same',
          ),
        ],
        personalNote: 'same note',
        aiMessages: const [
          AnnotationEditorMessageInput(
            role: 'user',
            content: 'Why?',
            sequence: 0,
          ),
          AnnotationEditorMessageInput(
            role: 'assistant',
            content: 'Because.',
            sequence: 1,
          ),
        ],
      ),
    );
    final before = (await shared.annotationDocument(fingerprint))!;
    final annotation = annotationOf(before, ref.annotationId);
    final enrichments =
        (annotation['enrichments'] as List).cast<Map<String, dynamic>>();
    final translation =
        enrichments.singleWhere((item) => item['kind'] == 'translation');
    final thread =
        enrichments.singleWhere((item) => item['kind'] == 'ai-thread');
    final messages = (thread['messages'] as List).cast<Map<String, dynamic>>();
    final revision =
        (await shared.documentSnapshot('annotations', fingerprint))!
            .localRevision;
    semanticNotifications.clear();

    expect(
      await repository.saveAnnotationEditorDraft(
        AnnotationEditorSaveInput(
          existingRef: ref,
          observedMaterialIds: {translation['id'] as String},
          observedAiThreadIds: {thread['id'] as String},
          materials: [
            AnnotationEditorMaterialInput(
              enrichmentId: translation['id'] as String,
              providerId: 'google-translate',
              providerName: 'Google Translate',
              kind: 'translation',
              translation: 'same',
            ),
          ],
          personalNote: 'same note',
          aiThreadId: thread['id'] as String,
          aiMessages: [
            for (final message in messages)
              AnnotationEditorMessageInput(
                messageId: message['id'] as String,
                role: message['role'] as String,
                content: message['content'] as String,
                sequence: message['sequence'] as int,
                createdAt: DateTime.parse(message['createdAt'] as String),
              ),
          ],
        ),
      ),
      ref,
    );

    expect(await shared.annotationDocument(fingerprint), before);
    expect(
      (await shared.documentSnapshot('annotations', fingerprint))!
          .localRevision,
      revision,
    );
    expect(semanticNotifications, isEmpty);
  });

  test('stale editor Save preserves concurrently unseen material and thread',
      () async {
    final ref = await repository.saveAnnotationEditorDraft(
      AnnotationEditorSaveInput(
        creation: creation(),
        materials: const [
          AnnotationEditorMaterialInput(
            providerId: 'google-translate',
            providerName: 'Google Translate',
            kind: 'translation',
            translation: 'initial',
          ),
        ],
        aiMessages: const [
          AnnotationEditorMessageInput(
            role: 'user',
            content: 'Why?',
            sequence: 0,
          ),
          AnnotationEditorMessageInput(
            role: 'assistant',
            content: 'Because.',
            sequence: 1,
          ),
        ],
      ),
    );
    var document = (await shared.annotationDocument(fingerprint))!;
    final annotation = annotationOf(document, ref.annotationId);
    final enrichments =
        (annotation['enrichments'] as List).cast<Map<String, dynamic>>();
    final originalMaterial =
        enrichments.singleWhere((item) => item['kind'] == 'translation');
    final originalThread =
        enrichments.singleWhere((item) => item['kind'] == 'ai-thread');
    final originalMessages =
        (originalThread['messages'] as List).cast<Map<String, dynamic>>();
    final observedMaterialIds = {originalMaterial['id'] as String};
    final observedThreadIds = {originalThread['id'] as String};
    const concurrentTimestamp = '2026-01-02T03:04:06.000Z';
    (originalThread['messages'] as List).add({
      'id': 'concurrent-message',
      'role': 'system',
      'sequence': 2,
      'content': 'Concurrent context',
      'createdAt': concurrentTimestamp,
      'updatedAt': concurrentTimestamp,
    });
    enrichments.addAll([
      {
        'id': 'concurrent-google',
        'kind': 'translation',
        'providerId': 'google-translate',
        'providerName': 'Google Translate',
        'translation': 'concurrent',
        'createdAt': concurrentTimestamp,
        'updatedAt': concurrentTimestamp,
      },
      {
        'id': 'concurrent-thread',
        'kind': 'ai-thread',
        'contextSnapshot': {
          'selectedText': 'selected text',
          'enrichmentIds': <Object>[],
        },
        'messages': <Object>[],
        'createdAt': concurrentTimestamp,
        'updatedAt': concurrentTimestamp,
      },
    ]);
    await shared.putAnnotationDocument(document);

    await repository.saveAnnotationEditorDraft(
      AnnotationEditorSaveInput(
        existingRef: ref,
        observedMaterialIds: observedMaterialIds,
        observedAiThreadIds: observedThreadIds,
        materials: [
          AnnotationEditorMaterialInput(
            enrichmentId: originalMaterial['id'] as String,
            providerId: 'google-translate',
            providerName: 'Google Translate',
            kind: 'translation',
            translation: 'initial',
          ),
        ],
        aiThreadId: originalThread['id'] as String,
        aiMessages: [
          for (final message in originalMessages.take(2))
            AnnotationEditorMessageInput(
              messageId: message['id'] as String,
              role: message['role'] as String,
              content: message['content'] as String,
              sequence: message['sequence'] as int,
              createdAt: DateTime.parse(message['createdAt'] as String),
            ),
        ],
      ),
    );

    document = (await shared.annotationDocument(fingerprint))!;
    final saved = annotationOf(document, ref.annotationId);
    final savedEnrichments =
        (saved['enrichments'] as List).cast<Map<String, dynamic>>();
    expect(
      savedEnrichments.singleWhere((item) => item['id'] == 'concurrent-google'),
      isNot(contains('deletedAt')),
    );
    final concurrentThread = savedEnrichments
        .singleWhere((item) => item['id'] == 'concurrent-thread');
    expect(concurrentThread, isNot(contains('deletedAt')));
    final savedOriginalThread = savedEnrichments
        .singleWhere((item) => item['id'] == originalThread['id']);
    expect(
      (savedOriginalThread['messages'] as List).map((message) => message['id']),
      contains('concurrent-message'),
    );
  });

  test('personal note edit and clear preserve unknown canonical data',
      () async {
    final ref = await repository.createAnnotation(creation());
    var document = (await shared.annotationDocument(fingerprint))!;
    annotationOf(document, ref.annotationId)['futureField'] = {'keep': true};
    await shared.putAnnotationDocument(document);

    await repository.setPersonalNote(ref, 'first');
    await repository.setPersonalNote(ref, 'edited');
    await repository.setPersonalNote(ref, '');

    document = (await shared.annotationDocument(fingerprint))!;
    final annotation = annotationOf(document, ref.annotationId);
    expect(annotation['futureField'], {'keep': true});
    final personal = (annotation['enrichments'] as List)
        .cast<Map<String, dynamic>>()
        .where((value) => value['kind'] == 'personal-note')
        .toList();
    expect(personal, hasLength(1));
    expect(personal.single['deletedAt'], isNotNull);
  });

  test('presentation mutation changes no semantic bytes or revision', () async {
    final ref = await repository.createAnnotation(creation());
    final beforeBytes =
        await shared.canonicalDocument('annotations', fingerprint);
    final beforeSnapshot =
        await shared.documentSnapshot('annotations', fingerprint);
    final beforeUpdatedAt = annotationOf(
        (await shared.annotationDocument(fingerprint))!,
        ref.annotationId)['updatedAt'];

    expect(
        await repository.updatePresentation(ref, 'underline', '00ff00'), ref);

    expect(await shared.canonicalDocument('annotations', fingerprint),
        orderedEquals(beforeBytes!));
    final afterSnapshot =
        await shared.documentSnapshot('annotations', fingerprint);
    expect(afterSnapshot!.localRevision, beforeSnapshot!.localRevision);
    expect(
        annotationOf((await shared.annotationDocument(fingerprint))!,
            ref.annotationId)['updatedAt'],
        beforeUpdatedAt);
    expect((await shared.annotationPresentation(ref.annotationId))?.color,
        '00ff00');
    expect(presentationNotifications, 1);
  });

  test('editing only personal note does not materialize presentation defaults',
      () async {
    final ref = await repository.createAnnotation(creation());

    await repository.setPersonalNote(ref, 'note only');

    expect(await shared.annotationPresentation(ref.annotationId), isNull);
    expect(await shared.hasAnnotationPresentationOperation(ref.annotationId),
        isFalse);
    final annotation = annotationOf(
        (await shared.annotationDocument(fingerprint))!, ref.annotationId);
    expect(annotation['enrichments'].single['content'], 'note only');
  });

  test('bookmark motivation is canonical and presentation is rejected',
      () async {
    final ref = await repository.createBookmark(BookmarkCreation(
      book: localBook(),
      content: 'bookmark',
      epubCfi: cfi,
      chapter: 'Chapter 1',
      percentage: 0.5,
    ));
    final annotation = annotationOf(
        (await shared.annotationDocument(fingerprint))!, ref.annotationId);
    expect(annotation['motivation'], 'bookmark');
    expect(annotation['target']['progress']['fraction'], 0.5);
    expect(
        const CanonicalAnnotationReadAdapter()
            .read((await shared.annotationDocument(fingerprint))!)
            .single
            .bookmarkPercentage,
        0.5);
    await expectLater(repository.updatePresentation(ref, 'highlight', 'red'),
        throwsA(isA<ArgumentError>()));
  });

  test('bookmark percentage validation rejects invalid canonical writes',
      () async {
    for (final percentage in [double.nan, -0.01, 1.01]) {
      await expectLater(
        repository.createBookmark(BookmarkCreation(
          book: localBook(),
          content: 'bookmark',
          epubCfi: cfi,
          chapter: 'Chapter 1',
          percentage: percentage,
        )),
        throwsA(isA<ArgumentError>()),
      );
    }
    expect(await shared.annotationDocument(fingerprint), isNull);
  });

  test('bookmark percentage survives database restart', () async {
    final ref = await repository.createBookmark(BookmarkCreation(
      book: localBook(),
      content: 'bookmark',
      epubCfi: cfi,
      chapter: 'Chapter 1',
      percentage: 0.73,
    ));
    await shared.close();
    shared = SharedStateDatabase(
      path: p.join(directory.path, 'shared_state.db'),
      factory: databaseFactoryFfi,
      now: () => instant,
    );

    final model = const CanonicalAnnotationReadAdapter()
        .read((await shared.annotationDocument(fingerprint))!)
        .singleWhere((annotation) => annotation.ref == ref);
    expect(model.bookmarkPercentage, 0.73);
  });

  test('deletion creates sticky tombstone and resets presentation', () async {
    final ref = await repository.createAnnotation(creation());
    await repository.updatePresentation(ref, 'highlight', 'red');

    expect(await repository.tombstoneAnnotation(ref), ref);
    expect(await repository.tombstoneAnnotation(ref), ref);

    final annotation = annotationOf(
        (await shared.annotationDocument(fingerprint))!, ref.annotationId);
    expect(annotation['deletedAt'], isNotNull);
    expect(await shared.annotationPresentation(ref.annotationId), isNull);
    expect(await shared.hasAnnotationPresentationOperation(ref.annotationId),
        isTrue,
        reason: 'the synchronized reset must remain sticky');
    await expectLater(repository.setPersonalNote(ref, 'resurrect'),
        throwsA(isA<StateError>()));
  });

  test('unsupported and unbound canonical annotations need no numeric ID',
      () async {
    final document = <String, dynamic>{
      'schemaVersion': 2,
      'book': {
        'fingerprintAlgorithm': 'md5',
        'fingerprint': fingerprint,
      },
      'annotations': [
        {
          'id': 'unsupported-id',
          'motivation': 'selection',
          'createdAt': canonicalWireTimestamp(instant),
          'updatedAt': canonicalWireTimestamp(instant),
          'target': {
            'selectedText': 'remote',
            'selectors': [
              {
                'type': 'future-selector',
                'value': {'unknown': true}
              }
            ],
          },
          'enrichments': <Object>[],
        }
      ],
    };
    await shared.putAnnotationDocument(document);
    final ref = AnnotationRef(
        bookFingerprint: fingerprint, annotationId: 'unsupported-id');

    expect(await repository.saveTranslation(ref, 'works'), ref);
    final updated = annotationOf(
        (await shared.annotationDocument(fingerprint))!, ref.annotationId);
    expect(updated['target']['selectors'].single['value'], {'unknown': true});
    expect(updated['enrichments'].single['kind'], 'translation');
  });

  test('repository source has no legacy table, model, DAO, or numeric identity',
      () {
    final source =
        File('lib/service/sync/annotation_repository.dart').readAsStringSync();
    expect(source, isNot(contains('tb_notes')));
    expect(source, isNot(contains('BookNote')));
    expect(source, isNot(contains('nativeNoteId')));
    expect(source, isNot(contains('sharedAnnotationId')));
    expect(source, isNot(contains('Projection')));
  });
}
