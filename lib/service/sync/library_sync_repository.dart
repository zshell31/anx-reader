import 'dart:convert';

import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/service/sync/annotation_protocol.dart';
import 'package:anx_reader/service/sync/domain_stamp.dart';
import 'package:anx_reader/service/sync/library_protocol.dart';
import 'package:anx_reader/service/sync/shared_state_database.dart';
import 'package:uuid/uuid.dart';
import 'package:path/path.dart' as p;

abstract interface class LibraryProjection {
  Future<List<Book>> allBooks();
  Future<Book?> bookByFingerprint(String fingerprint);
  Future<void> projectCatalog(Map<String, dynamic> document);
  Future<void> projectReadingState(Map<String, dynamic> document);
  Future<void> bindBookAsset(
      String fingerprint, String relativePath, String extension);
}

class SqliteLibraryProjection implements LibraryProjection {
  final BookDao books;
  SqliteLibraryProjection({BookDao? books}) : books = books ?? bookDao;

  @override
  Future<List<Book>> allBooks() => books.selectAllBooks();

  @override
  Future<Book?> bookByFingerprint(String fingerprint) async {
    final matches = await books.selectBooksByFingerprint(fingerprint);
    if (matches.isNotEmpty) return matches.first;
    return books.getBookByMd5(fingerprint);
  }

  @override
  Future<void> projectCatalog(Map<String, dynamic> input) async {
    final document = decodeLibraryCatalogDocument(input);
    final fingerprint = document['fingerprint'] as String;
    final membership = document['membership'] as Map<String, dynamic>;
    final metadata = document['metadata'] as Map<String, dynamic>;
    final existing = await bookByFingerprint(fingerprint);
    String text(String field) =>
        (metadata[field] as Map<String, dynamic>)['value'] as String? ?? '';
    final rating =
        (metadata['rating'] as Map<String, dynamic>)['value'] as double;
    final deleted = membership['value'] != true;
    if (existing == null) {
      await books.insertBook(Book(
        id: -1,
        title: text('title'),
        coverPath: '',
        filePath: '',
        lastReadPosition: '',
        readingPercentage: 0,
        author: text('author'),
        isDeleted: deleted,
        description: text('description'),
        rating: rating,
        md5: fingerprint,
        createTime: DateTime.now(),
        updateTime: DateTime.now(),
      ));
      return;
    }
    await books.updateBook(existing.copyWith(
      title: text('title'),
      author: text('author'),
      description: text('description'),
      rating: rating,
      isDeleted: deleted,
    ));
  }

  @override
  Future<void> projectReadingState(Map<String, dynamic> input) async {
    final document = decodeReadingStateDocument(input);
    final existing = await bookByFingerprint(document['fingerprint'] as String);
    if (existing == null || existing.isDeleted) return;
    await books.updateBook(existing.copyWith(
      lastReadPosition: document['position'] as String,
      readingPercentage: document['percentage'] as double,
    ));
  }

  @override
  Future<void> bindBookAsset(
      String fingerprint, String relativePath, String extension) async {
    final existing = await bookByFingerprint(fingerprint);
    if (existing == null) return;
    await books.updateBook(existing.copyWith(
      filePath: relativePath,
      md5: fingerprint,
      isDeleted: false,
    ));
  }
}

class LibrarySyncRepository {
  static const catalogBootstrapSource = 'library-catalog-v1';
  static const readingBootstrapSource = 'reading-state-v1';

  final SharedStateDatabase sharedState;
  final LibraryProjection projection;
  final DateTime Function() now;
  final String deviceId;

  LibrarySyncRepository({
    required this.sharedState,
    required this.projection,
    required this.deviceId,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;

  static Future<String> ensureDeviceId(SharedStateDatabase store,
      {Uuid uuid = const Uuid()}) async {
    final existing = await store.importedSharedId('local-identity', 'device');
    if (existing != null) return existing;
    final generated = uuid.v4();
    await store.recordImport(
      source: 'local-identity',
      sourceKey: 'device',
      sharedId: generated,
      status: 'complete',
    );
    return generated;
  }

  DomainStamp stamp([DateTime? instant]) =>
      DomainStamp(modifiedAt: (instant ?? now()).toUtc(), deviceId: deviceId);

  Future<int> publishBook(Book book, {DomainStamp? mutationStamp}) async {
    final fingerprint = canonicalMd5Fingerprint(book.md5);
    final valueStamp = mutationStamp ?? stamp();
    final current = await _read(libraryCatalogDomain, fingerprint);
    final candidate =
        _catalogFromBook(book, fingerprint, valueStamp, current: current);
    final merged = current == null
        ? candidate
        : mergeLibraryCatalogDocuments(current, candidate);
    await sharedState.putCanonicalDocument(
        libraryCatalogDomain, fingerprint, encodeDomainDocument(merged));
    await projection.projectCatalog(merged);
    return (await sharedState.documentSnapshot(
            libraryCatalogDomain, fingerprint))!
        .localRevision;
  }

  Future<void> recordReadingProgress({
    required String fingerprint,
    required String position,
    required double percentage,
    DomainStamp? mutationStamp,
  }) async {
    final id = canonicalMd5Fingerprint(fingerprint);
    final candidate = decodeReadingStateDocument({
      'schemaVersion': readingStateSchemaVersion,
      'fingerprint': id,
      'position': position,
      'percentage': percentage,
      'stamp': (mutationStamp ?? stamp()).toJson(),
    });
    final current = await _read(readingStateDomain, id);
    if (current != null &&
        DomainStamp.fromJson(current['stamp'])
                .compareTo(DomainStamp.fromJson(candidate['stamp'])) >=
            0) {
      return;
    }
    final merged = current == null
        ? candidate
        : mergeReadingStateDocuments(current, candidate);
    await sharedState.putCanonicalDocument(
        readingStateDomain, id, encodeDomainDocument(merged));
    await projection.projectReadingState(merged);
  }

  Future<void> projectCanonical(String domain, String id) async {
    final document = await _read(domain, id);
    if (document == null) return;
    if (domain == libraryCatalogDomain) {
      await projection.projectCatalog(document);
    } else if (domain == readingStateDomain) {
      await projection.projectReadingState(document);
    }
  }

  Future<int> bootstrap() async {
    var imported = 0;
    for (final book in await projection.allBooks()) {
      String fingerprint;
      try {
        fingerprint = canonicalMd5Fingerprint(book.md5);
      } catch (_) {
        continue;
      }
      if (await sharedState.importReceipt(
              catalogBootstrapSource, fingerprint) ==
          null) {
        final legacyStamp = stamp(book.updateTime);
        await publishBook(book, mutationStamp: legacyStamp);
        await sharedState.recordImport(
          source: catalogBootstrapSource,
          sourceKey: fingerprint,
          sharedId: fingerprint,
          status: 'complete',
        );
        imported++;
      }
      if ((book.lastReadPosition.isNotEmpty || book.readingPercentage > 0) &&
          await sharedState.importReceipt(
                  readingBootstrapSource, fingerprint) ==
              null) {
        await recordReadingProgress(
          fingerprint: fingerprint,
          position: book.lastReadPosition,
          percentage: book.readingPercentage,
          mutationStamp: stamp(book.updateTime),
        );
        await sharedState.recordImport(
          source: readingBootstrapSource,
          sourceKey: fingerprint,
          sharedId: fingerprint,
          status: 'complete',
        );
      }
    }
    return imported;
  }

  Map<String, dynamic> _catalogFromBook(
      Book book, String fingerprint, DomainStamp valueStamp,
      {Map<String, dynamic>? current}) {
    final existingMetadata = current?['metadata'] as Map<String, dynamic>?;
    Map<String, dynamic> field(String name, Object? value) {
      final previous = existingMetadata?[name] as Map<String, dynamic>?;
      return previous != null && previous['value'] == value
          ? previous
          : stampedValue(value, valueStamp);
    }

    final previousMembership = current?['membership'] as Map<String, dynamic>?;
    final present = !book.isDeleted;
    return decodeLibraryCatalogDocument({
      'schemaVersion': libraryCatalogSchemaVersion,
      'fingerprint': fingerprint,
      'membership':
          previousMembership != null && previousMembership['value'] == present
              ? previousMembership
              : stampedValue(present, valueStamp),
      'metadata': {
        'title': field('title', book.title),
        'author': field('author', book.author),
        'description': field('description', book.description),
        'rating': field('rating', book.rating),
      },
      'bookAsset': {
        'algorithm': 'md5',
        'digest': fingerprint,
        'extension': _portableExtension(book.filePath),
      },
    });
  }

  String _portableExtension(String path) {
    final extension = p.extension(path).toLowerCase();
    return RegExp(r'^\.[a-z0-9]{1,8}$').hasMatch(extension)
        ? extension
        : '.epub';
  }

  Future<Map<String, dynamic>?> _read(String domain, String id) async {
    final bytes = await sharedState.canonicalDocument(domain, id);
    if (bytes == null) return null;
    final decoded = jsonDecode(utf8.decode(bytes));
    return domain == libraryCatalogDomain
        ? decodeLibraryCatalogDocument(decoded)
        : decodeReadingStateDocument(decoded);
  }
}
