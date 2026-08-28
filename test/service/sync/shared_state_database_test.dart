import 'package:anx_reader/service/sync/shared_state_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  test('canonical document and idempotent outbox survive reopen', () async {
    final path = inMemoryDatabasePath;
    final store = SharedStateDatabase(path: path, factory: databaseFactoryFfi);
    final document = {
      'schemaVersion': 2,
      'book': {
        'fingerprintAlgorithm': 'md5',
        'fingerprint': '0123456789ABCDEF0123456789ABCDEF'
      },
      'annotations': <Object>[]
    };
    await store.putAnnotationDocument(document);
    await store.putAnnotationDocument(document);
    expect(await store.pendingOutbox(), hasLength(1));
    expect(
        (await store.annotationDocument(
            '0123456789abcdef0123456789abcdef'))?['schemaVersion'],
        2);
    await store.markConverged('annotations', '0123456789abcdef0123456789abcdef',
        strongEtag: '"v1"');
    expect(await store.pendingOutbox(), isEmpty);
    await store.close();
  });
}
