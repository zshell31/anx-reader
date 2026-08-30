import 'package:anx_reader/page/book_player/foliate_annotation_adapter.dart';
import 'package:anx_reader/service/sync/annotation_read_model.dart';
import 'package:flutter_test/flutter_test.dart';

const fingerprint = '0123456789abcdef0123456789abcdef';
const timestamp = '2026-08-30T10:00:00.000Z';

Map<String, dynamic> annotation(String id, String cfi,
        {String motivation = 'selection'}) =>
    <String, dynamic>{
      'id': id,
      'motivation': motivation,
      'createdAt': timestamp,
      'updatedAt': timestamp,
      'target': <String, dynamic>{
        'selectedText': 'text\n$id',
        'selectors': [
          <String, dynamic>{'type': 'epub-cfi', 'cfi': cfi},
        ],
      },
      'enrichments': <Object>[],
    };

Map<String, dynamic> document(List<Map<String, dynamic>> annotations) =>
    <String, dynamic>{
      'schemaVersion': 2,
      'book': <String, dynamic>{
        'fingerprintAlgorithm': 'md5',
        'fingerprint': fingerprint,
      },
      'annotations': annotations,
    };

void main() {
  const adapter = FoliateAnnotationAdapter(
    defaultStyle: AnnotationPresentationStyle.highlight,
    defaultColor: '66CCFF',
  );

  test('uses canonical UUID as DTO identity and independent render key', () {
    const sameCfi = 'epubcfi(/6/2!/4/2,/1:0,/1:4)';
    final models = const CanonicalAnnotationReadAdapter().read(document([
      annotation('uuid-a', sameCfi),
      annotation('uuid-b', sameCfi),
    ]));

    final payloads = adapter.adapt(models).map((dto) => dto.toJson()).toList();
    expect(payloads.map((payload) => payload['id']), ['uuid-a', 'uuid-b']);
    expect(
        payloads.map((payload) => payload['renderKey']), ['uuid-a', 'uuid-b']);
    expect(payloads.map((payload) => payload['value']), [sameCfi, sameCfi]);
  });

  test('combines explicit presentation with defaults without persisting them',
      () {
    final models = CanonicalAnnotationReadAdapter(presentations: const {
      'explicit': AnnotationPresentation(
        annotationId: 'explicit',
        style: AnnotationPresentationStyle.underline,
        color: '00ff00',
      ),
    }).read(document([
      annotation('explicit', 'epubcfi(/6/2!/4/2,/1:0,/1:4)'),
      annotation('default', 'epubcfi(/6/2!/4/4,/1:0,/1:4)'),
    ]));

    final payloads = adapter.adapt(models).map((dto) => dto.toJson()).toList();
    final byId = {for (final payload in payloads) payload['id']: payload};
    expect(byId['explicit']!['type'], 'underline');
    expect(byId['explicit']!['color'], '#00ff00');
    expect(byId['default']!['type'], 'highlight');
    expect(byId['default']!['color'], '#66CCFF');
    expect(byId['explicit']!['note'], 'text explicit');
  });

  test('maps bookmark motivation and omits unrenderable selectors', () {
    final models = const CanonicalAnnotationReadAdapter().read(document([
      annotation('bookmark', 'epubcfi(/6/2!/4/2)', motivation: 'bookmark'),
      <String, dynamic>{
        ...annotation('unsupported', 'epubcfi(/6/2!/4/4)'),
        'target': <String, dynamic>{
          'selectedText': 'unsupported',
          'selectors': [
            <String, dynamic>{'type': 'text-quote', 'exact': 'unsupported'},
          ],
        },
      },
    ]));

    final payloads = adapter.adapt(models).map((dto) => dto.toJson()).toList();
    expect(payloads, hasLength(1));
    expect(payloads.single['id'], 'bookmark');
    expect(payloads.single['type'], 'bookmark');
  });
}
