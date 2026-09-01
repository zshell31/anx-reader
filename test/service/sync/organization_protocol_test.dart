import 'package:anx_reader/service/sync/domain_stamp.dart';
import 'package:anx_reader/service/sync/organization_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

const groupId = '00000000-0000-4000-8000-000000000010';
const parentId = '00000000-0000-4000-8000-000000000011';
const tagId = '00000000-0000-4000-8000-000000000020';
const themeId = '00000000-0000-4000-8000-000000000030';
const fingerprint = '0123456789abcdef0123456789abcdef';

DomainStamp stamp(int day, String device) =>
    DomainStamp(modifiedAt: DateTime.utc(2025, 1, day), deviceId: device);

Map<String, dynamic> group({
  String name = 'Shelf',
  String? parent,
  bool deleted = false,
  int day = 1,
}) =>
    decodeGroupDocument({
      'schemaVersion': 1,
      'domain': groupDomain,
      'id': groupId,
      'deleted': stampedValue(deleted, stamp(day, 'device')),
      'fields': {
        'name': stampedValue(name, stamp(day, 'device')),
        'parentId': stampedValue(parent, stamp(day, 'device')),
      },
    });

void main() {
  test('group uses UUID identity and parent UUID', () {
    final doc = group(parent: parentId);
    expect(doc['id'], groupId);
    expect((doc['fields']['parentId'] as Map)['value'], parentId);
    expect(doc.toString(), isNot(contains('local_id')));
  });

  test('new group tombstone defeats stale live record', () {
    final merged = mergeGroupDocuments(
        group(name: 'stale', day: 1), group(deleted: true, day: 3));
    expect((merged['deleted'] as Map)['value'], isTrue);
  });

  test('tag fields merge independently', () {
    Map<String, dynamic> tag(
            String name, int color, int nameDay, int colorDay) =>
        decodeTagDocument({
          'schemaVersion': 1,
          'domain': tagDomain,
          'id': tagId,
          'deleted': stampedValue(false, stamp(1, 'a')),
          'fields': {
            'name': stampedValue(name, stamp(nameDay, 'a')),
            'color': stampedValue(color, stamp(colorDay, 'a')),
          },
        });
    final merged =
        mergeTagDocuments(tag('new name', 1, 3, 1), tag('old name', 2, 1, 3));
    expect((merged['fields']['name'] as Map)['value'], 'new name');
    expect((merged['fields']['color'] as Map)['value'], 2);
  });

  test('book-tag removal is an explicit stamped membership', () {
    Map<String, dynamic> relation(bool present, int day) =>
        decodeBookTagDocument({
          'schemaVersion': 1,
          'bookFingerprint': fingerprint,
          'tagId': tagId,
          'membership': stampedValue(present, stamp(day, 'a')),
        });
    final merged = mergeBookTagDocuments(relation(true, 1), relation(false, 2));
    expect((merged['membership'] as Map)['value'], isFalse);
    expect(bookTagDocumentId(fingerprint, tagId), '$fingerprint@$tagId');
  });

  test('theme wire format excludes device-local background image path', () {
    final doc = decodeThemeDocument({
      'schemaVersion': 1,
      'domain': themeDomain,
      'id': themeId,
      'deleted': stampedValue(false, stamp(1, 'a')),
      'fields': {
        'backgroundColor': stampedValue('ff000000', stamp(1, 'a')),
        'textColor': stampedValue('ffffffff', stamp(1, 'a')),
      },
    });
    expect(doc.toString(), isNot(contains('backgroundImagePath')));
    expect(doc.toString(), isNot(contains('background_image_path')));
  });
}
