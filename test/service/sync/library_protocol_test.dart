import 'dart:convert';

import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/service/sync/domain_stamp.dart';
import 'package:anx_reader/service/sync/library_protocol.dart';
import 'package:anx_reader/service/sync/library_sync_repository.dart';
import 'package:anx_reader/service/sync/shared_state_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const fingerprint = '0123456789abcdef0123456789abcdef';

DomainStamp stamp(String time, String device) =>
    DomainStamp(modifiedAt: DateTime.parse(time), deviceId: device);

Book book({
  bool deleted = false,
  String title = 'Title',
  String position = '',
  double percentage = 0,
}) =>
    Book(
      id: 44,
      title: title,
      coverPath: 'cover/private.png',
      filePath: 'file/private.epub',
      lastReadPosition: position,
      readingPercentage: percentage,
      author: 'Author',
      isDeleted: deleted,
      description: 'Description',
      rating: 4.5,
      groupId: 73,
      md5: fingerprint,
      createTime: DateTime.utc(2024),
      updateTime: DateTime.utc(2025),
    );

class MemoryProjection implements LibraryProjection {
  final List<Book> books;
  final List<Map<String, dynamic>> catalogs = [];
  final List<Map<String, dynamic>> positions = [];
  MemoryProjection(this.books);

  @override
  Future<List<Book>> allBooks() async => books;

  @override
  Future<Book?> bookByFingerprint(String value) async =>
      books.where((book) => book.md5 == value).firstOrNull;

  @override
  Future<void> projectCatalog(Map<String, dynamic> document) async {
    catalogs.add(document);
  }

  @override
  Future<void> projectReadingState(Map<String, dynamic> document) async {
    positions.add(document);
  }
}

void main() {
  sqfliteFfiInit();
  late SharedStateDatabase store;
  late MemoryProjection projection;
  late LibrarySyncRepository repository;

  setUp(() async {
    store = SharedStateDatabase(
      path: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    projection =
        MemoryProjection([book(position: 'epubcfi(/6/2)', percentage: .2)]);
    repository = LibrarySyncRepository(
      sharedState: store,
      projection: projection,
      deviceId: 'device-a',
      now: () => DateTime.utc(2026),
    );
  });

  tearDown(() => store.close());

  test('first publication is portable and creates pending catalog state',
      () async {
    await repository.publishBook(projection.books.single);
    final bytes =
        await store.canonicalDocument(libraryCatalogDomain, fingerprint);
    final text = utf8.decode(bytes!);
    expect(text, contains(fingerprint));
    expect(text, isNot(contains('private.epub')));
    expect(text, isNot(contains('private.png')));
    expect(text, isNot(contains('"id":44')));
    expect(text, isNot(contains('group_id')));
    expect(
        await store.outboxEntry(libraryCatalogDomain, fingerprint), isNotNull);
  });

  test('field-level merge preserves independent metadata updates', () {
    Map<String, dynamic> record(String title, String author,
            DomainStamp titleStamp, DomainStamp authorStamp) =>
        decodeLibraryCatalogDocument({
          'schemaVersion': 1,
          'fingerprint': fingerprint,
          'membership': stampedValue(true, stamp('2025-01-01T00:00:00Z', 'a')),
          'metadata': {
            'title': stampedValue(title, titleStamp),
            'author': stampedValue(author, authorStamp),
            'description':
                stampedValue(null, stamp('2025-01-01T00:00:00Z', 'a')),
            'rating': stampedValue(0.0, stamp('2025-01-01T00:00:00Z', 'a')),
          },
          'bookAsset': {'algorithm': 'md5', 'digest': fingerprint},
        });
    final merged = mergeLibraryCatalogDocuments(
      record('new title', 'old author', stamp('2025-02-01T00:00:00Z', 'a'),
          stamp('2025-01-01T00:00:00Z', 'a')),
      record('old title', 'new author', stamp('2025-01-01T00:00:00Z', 'b'),
          stamp('2025-02-01T00:00:00Z', 'b')),
    );
    final metadata = merged['metadata'] as Map<String, dynamic>;
    expect((metadata['title'] as Map)['value'], 'new title');
    expect((metadata['author'] as Map)['value'], 'new author');
  });

  test('new tombstone defeats stale live membership', () async {
    await repository.publishBook(book(),
        mutationStamp: stamp('2025-01-01T00:00:00Z', 'a'));
    await repository.publishBook(book(deleted: true),
        mutationStamp: stamp('2025-02-01T00:00:00Z', 'b'));
    await repository.publishBook(book(),
        mutationStamp: stamp('2025-01-15T00:00:00Z', 'c'));
    final decoded = jsonDecode(utf8.decode(
        (await store.canonicalDocument(libraryCatalogDomain, fingerprint))!));
    expect(decoded['membership']['value'], isFalse);
  });

  test('reading position uses deterministic stamp, not maximum percentage',
      () async {
    await repository.recordReadingProgress(
      fingerprint: fingerprint,
      position: 'later-percentage',
      percentage: .9,
      mutationStamp: stamp('2025-01-01T00:00:00Z', 'z'),
    );
    await repository.recordReadingProgress(
      fingerprint: fingerprint,
      position: 'newest-mutation',
      percentage: .2,
      mutationStamp: stamp('2025-02-01T00:00:00Z', 'a'),
    );
    await repository.recordReadingProgress(
      fingerprint: fingerprint,
      position: 'stale',
      percentage: 1,
      mutationStamp: stamp('2025-01-15T00:00:00Z', 'x'),
    );
    final decoded = jsonDecode(utf8.decode(
        (await store.canonicalDocument(readingStateDomain, fingerprint))!));
    expect(decoded['position'], 'newest-mutation');
    expect(decoded['percentage'], .2);
  });

  test('bootstrap is idempotent and records explicit receipts', () async {
    expect(await repository.bootstrap(), 1);
    final catalogRevision =
        (await store.documentSnapshot(libraryCatalogDomain, fingerprint))!
            .localRevision;
    final readingRevision =
        (await store.documentSnapshot(readingStateDomain, fingerprint))!
            .localRevision;
    expect(await repository.bootstrap(), 0);
    expect(
        (await store.documentSnapshot(libraryCatalogDomain, fingerprint))!
            .localRevision,
        catalogRevision);
    expect(
        (await store.documentSnapshot(readingStateDomain, fingerprint))!
            .localRevision,
        readingRevision);
    expect(
        await store.importReceipt(
            LibrarySyncRepository.catalogBootstrapSource, fingerprint),
        isNotNull);
  });

  test('remote-only canonical record projects without local identity',
      () async {
    final remote = decodeLibraryCatalogDocument({
      'schemaVersion': 1,
      'fingerprint': fingerprint,
      'membership': stampedValue(true, stamp('2025-01-01T00:00:00Z', 'remote')),
      'metadata': {
        'title':
            stampedValue('Remote', stamp('2025-01-01T00:00:00Z', 'remote')),
        'author': stampedValue('', stamp('2025-01-01T00:00:00Z', 'remote')),
        'description':
            stampedValue(null, stamp('2025-01-01T00:00:00Z', 'remote')),
        'rating': stampedValue(0.0, stamp('2025-01-01T00:00:00Z', 'remote')),
      },
      'bookAsset': {'algorithm': 'md5', 'digest': fingerprint},
    });
    await store.applyRemoteMerge(
        libraryCatalogDomain, fingerprint, null, encodeDomainDocument(remote));
    await repository.projectCanonical(libraryCatalogDomain, fingerprint);
    expect(projection.catalogs.single['fingerprint'], fingerprint);
  });
}
