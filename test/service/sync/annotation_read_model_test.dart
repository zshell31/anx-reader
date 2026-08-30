import 'package:anx_reader/service/sync/annotation_protocol.dart';
import 'package:anx_reader/service/sync/annotation_read_model.dart';
import 'package:flutter_test/flutter_test.dart';

const fingerprint = '0123456789abcdef0123456789abcdef';
const createdAt = '2026-08-20T10:00:00.000Z';

Map<String, dynamic> annotation(
  String id, {
  String updatedAt = createdAt,
  String motivation = 'selection',
  Object? selectedText = 'selected',
  List<Map<String, dynamic>>? selectors,
  List<Map<String, dynamic>>? enrichments,
  bool deleted = false,
}) =>
    {
      'id': id,
      'motivation': motivation,
      'createdAt': createdAt,
      'updatedAt': updatedAt,
      if (deleted) 'deletedAt': updatedAt,
      'target': {
        'selectedText': selectedText,
        'chapter': 'Chapter 1',
        'context': 'Sentence containing selected.',
        'selectors': selectors ??
            [
              {'type': 'epub-cfi', 'cfi': 'epubcfi(/6/2[$id])'},
              {
                'type': 'future-selector',
                'payload': {'kept': true}
              },
            ],
      },
      'enrichments': enrichments ?? <Map<String, dynamic>>[],
      'futureAnnotation': {'kept': true},
    };

Map<String, dynamic> document(List<Map<String, dynamic>> annotations) => {
      'schemaVersion': 2,
      'book': {
        'fingerprintAlgorithm': 'md5',
        'fingerprint': fingerprint.toUpperCase(),
      },
      'annotations': annotations,
      'futureDocument': {'kept': true},
    };

Map<String, dynamic> enrichment(
  String id,
  String kind,
  String content, {
  String updatedAt = createdAt,
  bool deleted = false,
}) =>
    {
      'id': id,
      'kind': kind,
      'content': content,
      'createdAt': createdAt,
      'updatedAt': updatedAt,
      if (deleted) 'deletedAt': updatedAt,
      'futurePayload': {
        'nested': [true]
      },
    };

void main() {
  group('canonical annotation read model', () {
    test('maps canonical semantics, identity, capabilities, and presentation',
        () {
      final input = document([
        annotation(
          'annotation-a',
          enrichments: [
            enrichment('translation-a', 'translation', 'translation'),
            enrichment('note-a', 'personal-note', 'remember'),
          ],
        ),
      ]);
      final before = canonicalAnnotationDocumentJson(input);
      const presentation = AnnotationPresentation(
        annotationId: 'annotation-a',
        style: AnnotationPresentationStyle.underline,
        color: 'ffee00',
      );

      final models = const CanonicalAnnotationReadAdapter(
        presentations: {'annotation-a': presentation},
      ).read(input);

      expect(models, hasLength(1));
      final model = models.single;
      expect(
        model.ref,
        AnnotationRef(
          bookFingerprint: fingerprint.toUpperCase(),
          annotationId: 'annotation-a',
        ),
      );
      expect(model.motivation, AnnotationMotivation.selection);
      expect(model.selectedText, 'selected');
      expect(model.annotationContext, 'Sentence containing selected.');
      expect(model.chapter, 'Chapter 1');
      expect(model.activeEnrichments.map((value) => value.id),
          ['note-a', 'translation-a']);
      expect(model.effectivePersonalNote?.content, 'remember');
      expect(model.epubCfi, 'epubcfi(/6/2[annotation-a])');
      expect(model.navigationCapability, AnnotationCapability.available);
      expect(model.renderingCapability, AnnotationCapability.available);
      expect(model.localPresentation, same(presentation));
      expect(canonicalAnnotationDocumentJson(input), before,
          reason: 'read adapters must not mutate or reserialize source maps');
    });

    test('effective presentation keeps explicit and current defaults distinct',
        () {
      final implicit = const CanonicalAnnotationReadAdapter()
          .read(document([annotation('implicit')]))
          .single;
      final first = implicit.effectivePresentation(
        defaultStyle: 'highlight',
        defaultColor: '#66CCFF',
      );
      final changed = implicit.effectivePresentation(
        defaultStyle: 'underline',
        defaultColor: '00ff00',
      );

      expect(implicit.localPresentation, isNull);
      expect(first.style, AnnotationPresentationStyle.highlight);
      expect(first.color, '66CCFF');
      expect(changed.style, AnnotationPresentationStyle.underline);
      expect(changed.color, '00ff00');

      const explicit = AnnotationPresentation(
        annotationId: 'explicit',
        style: AnnotationPresentationStyle.highlight,
        color: 'red',
      );
      final explicitModel = const CanonicalAnnotationReadAdapter(
        presentations: {'explicit': explicit},
      ).read(document([annotation('explicit')])).single;
      expect(
        explicitModel.effectivePresentation(
          defaultStyle: 'underline',
          defaultColor: 'blue',
        ),
        same(explicit),
      );
    });

    test('keeps same-CFI annotations separate by canonical UUID', () {
      final sharedSelector = [
        {'type': 'epub-cfi', 'cfi': 'epubcfi(/6/2)'}
      ];
      final models = const CanonicalAnnotationReadAdapter().read(document([
        annotation('annotation-a', selectors: sharedSelector),
        annotation('annotation-b', selectors: sharedSelector),
      ]));

      expect(models.map((value) => value.ref.annotationId),
          ['annotation-a', 'annotation-b']);
      expect(models.map((value) => value.epubCfi),
          ['epubcfi(/6/2)', 'epubcfi(/6/2)']);
    });

    test('reads valid bookmark progress and ignores invalid remote progress',
        () {
      final valid = annotation('bookmark-valid', motivation: 'bookmark');
      (valid['target'] as Map)['progress'] = {'fraction': 0.42};
      final invalid = annotation('bookmark-invalid', motivation: 'bookmark');
      (invalid['target'] as Map)['progress'] = {'fraction': 4.2};

      final models = const CanonicalAnnotationReadAdapter()
          .read(document([valid, invalid]));

      expect(models[0].bookmarkPercentage, isNull);
      expect(models[1].bookmarkPercentage, 0.42);
      expect(models.every((model) => model.localPresentation == null), isTrue);
    });

    test('bookmark progress survives deterministic remote merge', () {
      final local =
          annotation('bookmark', motivation: 'bookmark', updatedAt: createdAt);
      final remote = annotation(
        'bookmark',
        motivation: 'bookmark',
        updatedAt: '2026-08-21T10:00:00.000Z',
      );
      (remote['target'] as Map)['progress'] = {'fraction': 0.61};

      final merged = mergeAnnotationDocuments(
        document([local]),
        document([remote]),
      );
      final reverse = mergeAnnotationDocuments(
        document([remote]),
        document([local]),
      );

      expect(canonicalJson(merged), canonicalJson(reverse));
      expect(
          const CanonicalAnnotationReadAdapter()
              .read(merged)
              .single
              .bookmarkPercentage,
          0.61);
      expect(merged['schemaVersion'], 2);
    });

    test('filters annotation tombstones unless explicitly requested', () {
      final input = document([
        annotation('active'),
        annotation('deleted', deleted: true),
      ]);

      expect(const CanonicalAnnotationReadAdapter().read(input), hasLength(1));
      final all = const CanonicalAnnotationReadAdapter()
          .read(input, includeTombstones: true);
      expect(all, hasLength(2));
      expect(all.last.tombstoneState, AnnotationTombstoneState.tombstoned);
      expect(all.last.isTombstoned, isTrue);
    });

    test('uses tombstone-aware deterministic personal-note winner semantics',
        () {
      final newer = '2026-08-21T10:00:00.000Z';
      final value = annotation('annotation-a', enrichments: [
        enrichment('note-old', 'personal-note', 'old'),
        enrichment('translation-deleted', 'translation', 'gone', deleted: true),
        enrichment('note-new', 'personal-note', 'new', updatedAt: newer),
      ]);

      expect(activeAnnotationEnrichments(value).map((item) => item.id),
          ['note-old', 'note-new']);
      expect(effectivePersonalNote(value)?.content, 'new');

      (value['enrichments'] as List).add(
        enrichment('note-deleted', 'personal-note', '',
            updatedAt: '2026-08-22T10:00:00.000Z', deleted: true),
      );
      expect(effectivePersonalNote(value), isNull,
          reason: 'a newer tombstone must suppress older active notes');
    });

    test('uses canonical JSON as the personal-note timestamp tie-break', () {
      final value = annotation('annotation-a', enrichments: [
        enrichment('note-a', 'personal-note', 'alpha'),
        enrichment('note-z', 'personal-note', 'omega'),
      ]);

      expect(effectivePersonalNote(value)?.content, 'omega');
    });

    test('exposes enrichment payload as recursively read-only data', () {
      final model = const CanonicalAnnotationReadAdapter()
          .read(document([
            annotation('annotation-a', enrichments: [
              enrichment('translation-a', 'translation', 'translation'),
            ]),
          ]))
          .single;
      final data = model.activeEnrichments.single.data;

      expect(data['futurePayload'], {
        'nested': [true]
      });
      expect(() => data['new'] = 'value', throwsUnsupportedError);
      final nested = data['futurePayload'] as Map<String, Object?>;
      expect(() => nested['new'] = 'value', throwsUnsupportedError);
      final list = nested['nested'] as List<Object?>;
      expect(() => list.add(false), throwsUnsupportedError);
    });

    test('exposes Lingua-compatible semantic material fields', () {
      final model = const CanonicalAnnotationReadAdapter()
          .read(document([
            annotation('annotation-a', enrichments: [
              {
                'id': 'dictionary-a',
                'kind': 'dictionary',
                'providerId': 'ldoce',
                'providerName': 'LDOCE',
                'translation': 'short definition',
                'markdown': '**full article**',
                'commentary': {
                  'translation': 'commentary translation',
                  'translationNotes': 'notes',
                  'grammar': 'grammar',
                  'usage': 'usage',
                },
                'createdAt': createdAt,
                'updatedAt': createdAt,
              },
            ]),
          ]))
          .single
          .activeEnrichments
          .single;

      expect(model.content, isNull);
      expect(model.translation, 'short definition');
      expect(model.markdown, '**full article**');
      expect(model.providerId, 'ldoce');
      expect(model.providerName, 'LDOCE');
      expect(model.commentaryValue('grammar'), 'grammar');
      expect(model.searchableText, [
        'short definition',
        '**full article**',
        'commentary translation',
        'notes',
        'grammar',
        'usage',
      ]);
      expect(() => model.commentary!['new'] = 'value', throwsUnsupportedError);
    });

    test('distinguishes navigation and rendering capability without hiding',
        () {
      final unavailable = CanonicalAnnotationReadAdapter(
        localBookAvailable: (_) => false,
      ).read(document([annotation('unbound')])).single;
      expect(unavailable.navigationCapability,
          AnnotationCapability.localBookUnavailable);
      expect(unavailable.renderingCapability,
          AnnotationCapability.localBookUnavailable);

      final nonRenderable = const CanonicalAnnotationReadAdapter()
          .read(
            document([annotation('invalid-text', selectedText: 42)]),
          )
          .single;
      expect(
          nonRenderable.navigationCapability, AnnotationCapability.available);
      expect(nonRenderable.renderingCapability,
          AnnotationCapability.unsupportedTarget);

      final unsupported = const CanonicalAnnotationReadAdapter()
          .read(
            document([annotation('future', selectors: const [])]),
          )
          .single;
      expect(unsupported.navigationCapability,
          AnnotationCapability.unsupportedTarget);
      expect(unsupported.renderingCapability,
          AnnotationCapability.unsupportedTarget);
    });
  });

  group('EPUB CFI semantic helper', () {
    test('accepts one unique genuine CFI and rejects ambiguity', () {
      expect(
        supportedEpubCfi({
          'selectors': [
            {'type': 'future-selector', 'value': 'kept'},
            {'type': 'epub-cfi', 'cfi': ' epubcfi(/6/2) '},
            {'type': 'epub-cfi', 'cfi': 'epubcfi(/6/2)'},
          ],
        }),
        'epubcfi(/6/2)',
      );
      expect(
        supportedEpubCfi({
          'selectors': [
            {'type': 'epub-cfi', 'cfi': 'epubcfi(/6/2)'},
            {'type': 'epub-cfi', 'cfi': 'epubcfi(/6/4)'},
          ],
        }),
        isNull,
      );
      expect(isEpubCfi('not-a-cfi'), isFalse);
    });
  });
}
