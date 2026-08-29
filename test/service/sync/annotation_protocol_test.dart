import 'package:anx_reader/service/sync/annotation_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

const fingerprint = '0123456789abcdef0123456789abcdef';
const timestamp = '2026-08-28T12:34:56.789Z';

Map<String, dynamic> document(List<Map<String, dynamic>> annotations,
        {int version = 2}) =>
    {
      'schemaVersion': version,
      'book': {'fingerprintAlgorithm': 'md5', 'fingerprint': fingerprint},
      'annotations': annotations,
    };

Map<String, dynamic> annotation(String id, {String text = 'text'}) => {
      'id': id,
      'motivation': 'selection',
      'createdAt': timestamp,
      'updatedAt': timestamp,
      'target': {
        'selectedText': text,
        'selectors': [
          {'type': 'unknown-future', 'payload': 'kept'}
        ],
      },
      'enrichments': <Object>[],
    };

void main() {
  test('book display metadata is preserved and canonicalized deterministically',
      () {
    final input = document(const [])
      ..['book'] = {
        'title': '  Dungeon Crawler Carl  ',
        'fingerprint': fingerprint.toUpperCase(),
        'fingerprintAlgorithm': 'md5',
        'author': 'Matt Dinniman',
        'futureHint': {'z': 2, 'a': 1},
      };

    final decoded = decodeAnnotationDocument(input);
    expect(decoded['book']['title'], '  Dungeon Crawler Carl  ');
    expect(decoded['book']['author'], 'Matt Dinniman');
    expect(decoded['book']['futureHint'], {'z': 2, 'a': 1});
    expect(canonicalAnnotationDocumentJson(decoded),
        canonicalAnnotationDocumentJson(decodeAnnotationDocument(decoded)));
  });

  test('known metadata enriches an old v2 document without changing identity',
      () {
    final input = document(const []);
    expect(
        applyAnnotationBookMetadata(
          input,
          title: ' Dungeon Crawler Carl ',
          author: ' Matt Dinniman ',
        ),
        isTrue);
    expect(input['book'], {
      'fingerprintAlgorithm': 'md5',
      'fingerprint': fingerprint,
      'title': 'Dungeon Crawler Carl',
      'author': 'Matt Dinniman',
    });
    expect(
        applyAnnotationBookMetadata(input, title: '  ', author: ''), isFalse);
  });

  test('canonicalizes timestamps and rejects noncanonical timestamps', () {
    expect(canonicalWireTimestamp(DateTime.parse(timestamp)), timestamp);
    expect(() => validateWireTimestamp('2026-08-28T12:34:56Z', 'time'),
        throwsA(isA<AnnotationProtocolException>()));
  });

  test('normalizes and validates MD5 fingerprints', () {
    expect(canonicalMd5Fingerprint(fingerprint.toUpperCase()), fingerprint);
    expect(() => canonicalMd5Fingerprint('not-md5'),
        throwsA(isA<AnnotationProtocolException>()));
  });

  test('migrates v1, strips presentation, and preserves unknown data', () {
    final legacy = annotation('a')
      ..remove('motivation')
      ..['presentation'] = {
        'type': 'underline',
        'color': 'blue',
        'updatedAt': timestamp
      }
      ..['future'] = {'value': 'kept'};
    final migrated = decodeAnnotationDocument(document([legacy], version: 1));
    final value = (migrated['annotations'] as List).single as Map;
    expect(migrated['schemaVersion'], 2);
    expect(value['motivation'], 'selection');
    expect(value.containsKey('presentation'), isFalse);
    expect(value['future'], {'value': 'kept'});
  });

  test('merge is deterministic, idempotent, and preserves unknown selectors',
      () {
    final left = document([annotation('b'), annotation('a', text: 'alpha')]);
    final right = document([annotation('a', text: 'omega'), annotation('c')]);
    final merged = mergeAnnotationDocuments(left, right);
    expect((merged['annotations'] as List).map((item) => item['id']),
        ['a', 'b', 'c']);
    expect((merged['annotations'] as List).first['target']['selectedText'],
        'omega');
    expect((merged['annotations'] as List).first['target']['selectors'], [
      {'type': 'unknown-future', 'payload': 'kept'}
    ]);
    expect(mergeAnnotationDocuments(merged, merged), merged);
    expect(mergeAnnotationDocuments(right, left), merged);
  });

  test('nested tombstones are sticky', () {
    final alive = annotation('a')
      ..['enrichments'] = [
        {
          'id': 'personal-note:a',
          'kind': 'personal-note',
          'content': 'old',
          'createdAt': timestamp,
          'updatedAt': timestamp
        }
      ];
    final deleted = annotation('a')
      ..['enrichments'] = [
        {
          'id': 'personal-note:a',
          'kind': 'personal-note',
          'content': '',
          'createdAt': timestamp,
          'updatedAt': timestamp,
          'deletedAt': timestamp
        }
      ];
    final merged =
        mergeAnnotationDocuments(document([alive]), document([deleted]));
    expect(merged['annotations'][0]['enrichments'][0]['deletedAt'], timestamp);
  });

  test('AI thread and message tombstones are independently sticky', () {
    Map<String, dynamic> thread(
            {bool deleted = false, bool messageDeleted = false}) =>
        {
          'id': 'thread-a',
          'kind': 'ai-thread',
          'createdAt': timestamp,
          'updatedAt': timestamp,
          if (deleted) 'deletedAt': timestamp,
          'contextSnapshot': {
            'selectedText': 'selected',
            'enrichmentIds': <String>[],
          },
          'messages': [
            {
              'id': 'message-a',
              'role': 'assistant',
              'sequence': 0,
              'content': 'answer',
              'createdAt': timestamp,
              'updatedAt': timestamp,
              if (messageDeleted) 'deletedAt': timestamp,
            }
          ],
        };
    final live = annotation('a')..['enrichments'] = [thread()];
    final deleted = annotation('a')
      ..['enrichments'] = [thread(deleted: true, messageDeleted: true)];

    final merged =
        mergeAnnotationDocuments(document([live]), document([deleted]));
    final mergedThread =
        merged['annotations'][0]['enrichments'][0] as Map<String, dynamic>;
    expect(mergedThread['deletedAt'], timestamp);
    expect(mergedThread['messages'][0]['deletedAt'], timestamp);
  });
}
