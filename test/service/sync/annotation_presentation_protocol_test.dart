import 'package:anx_reader/service/sync/annotation_presentation_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> presentation(String id, String time,
        {String style = 'highlight',
        String color = 'red',
        bool reset = false}) =>
    <String, dynamic>{
      'annotationId': id,
      'updatedAt': time,
      if (reset)
        'resetAt': time
      else ...{
        'style': style,
        'color': color,
      },
    };

Map<String, dynamic> document(Iterable<Map<String, dynamic>> entries) =>
    <String, dynamic>{
      'format': anxPresentationFormat,
      'version': anxPresentationVersion,
      'presentations': entries.toList(),
    };

void main() {
  test('merge is commutative and newer updates converge', () {
    final older = document([
      presentation('a', '2026-08-30T10:00:00.000Z', color: 'red'),
    ]);
    final newer = document([
      presentation('a', '2026-08-30T11:00:00.000Z',
          style: 'underline', color: 'blue'),
      presentation('b', '2026-08-30T09:00:00.000Z'),
    ]);

    expect(mergeAnxPresentationDocuments(older, newer),
        mergeAnxPresentationDocuments(newer, older));
    final entries =
        (mergeAnxPresentationDocuments(older, newer)['presentations'] as List)
            .cast<Map<String, dynamic>>();
    expect(entries.map((entry) => entry['annotationId']), ['a', 'b']);
    expect(entries.first['style'], 'underline');
    expect(entries.first['color'], 'blue');
  });

  test('reset wins an exact tie and remains a retained tombstone', () {
    final update = document([
      presentation('a', '2026-08-30T11:00:00.000Z', color: 'blue'),
    ]);
    final reset = document([
      presentation('a', '2026-08-30T11:00:00.000Z', reset: true),
    ]);

    final winner =
        (mergeAnxPresentationDocuments(update, reset)['presentations'] as List)
            .single as Map<String, dynamic>;
    expect(winner['resetAt'], winner['updatedAt']);
    expect(winner, isNot(contains('style')));
    expect(winner, isNot(contains('color')));
  });

  test('a later explicit update intentionally restores after reset', () {
    final reset = document([
      presentation('a', '2026-08-30T11:00:00.000Z', reset: true),
    ]);
    final restored = document([
      presentation('a', '2026-08-30T12:00:00.000Z', color: 'green'),
    ]);

    final winner =
        (mergeAnxPresentationDocuments(reset, restored)['presentations']
                as List)
            .single as Map<String, dynamic>;
    expect(winner['color'], 'green');
    expect(winner, isNot(contains('resetAt')));
  });

  test('presentation path and format are isolated from protocol v2', () {
    expect(anxPresentationRemotePath(anxPresentationDocumentId),
        ['anx', 'annotation-presentations.json']);
    expect(emptyAnxPresentationDocument(), isNot(contains('schemaVersion')));
    expect(emptyAnxPresentationDocument(), isNot(contains('annotations')));
  });
}
