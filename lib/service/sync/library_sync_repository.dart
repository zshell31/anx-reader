import 'dart:convert';
import 'dart:io';

import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/dao/database.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/service/sync/annotation_protocol.dart';
import 'package:anx_reader/service/sync/domain_stamp.dart';
import 'package:anx_reader/service/sync/library_protocol.dart';
import 'package:anx_reader/service/sync/shared_state_database.dart';
import 'package:anx_reader/service/sync/sync_diagnostics.dart';
import 'package:anx_reader/utils/get_path/get_base_path.dart';
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import 'package:path/path.dart' as p;

abstract interface class LibraryProjection {
  Future<List<Book>> allBooks();
  Future<Book?> bookByFingerprint(String fingerprint);
  Future<void> projectCatalog(Map<String, dynamic> document);
  Future<void> projectReadingState(Map<String, dynamic> document);
  Future<void> bindBookAsset(
      String fingerprint, String relativePath, String extension);
  Future<String?> localBookAssetPath(String fingerprint);
  Future<String?> localCoverAssetPath(String fingerprint);
  Future<void> bindCoverAsset(
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
    var projectedGroupId = existing?.groupId ?? 0;
    final sharedGroupId =
        (document['groupId'] as Map<String, dynamic>?)?['value'] as String?;
    if (sharedGroupId != null) {
      final mappings = await (await DBHelper().database).query('sync_group_ids',
          columns: ['local_id'],
          where: 'shared_id = ?',
          whereArgs: [sharedGroupId],
          limit: 1);
      if (mappings.isNotEmpty) {
        projectedGroupId = mappings.single['local_id'] as int;
      }
    }
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
        groupId: projectedGroupId,
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
      groupId: projectedGroupId,
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

  @override
  Future<String?> localBookAssetPath(String fingerprint) async {
    final book = await bookByFingerprint(fingerprint);
    return book == null || book.filePath.isEmpty ? null : book.filePath;
  }

  @override
  Future<String?> localCoverAssetPath(String fingerprint) async {
    final book = await bookByFingerprint(fingerprint);
    return book == null || book.coverPath.isEmpty ? null : book.coverPath;
  }

  @override
  Future<void> bindCoverAsset(
      String fingerprint, String relativePath, String extension) async {
    final existing = await bookByFingerprint(fingerprint);
    if (existing == null) return;
    await books.updateBook(existing.copyWith(coverPath: relativePath));
  }
}

class LibrarySyncRepository {
  static const catalogBootstrapSource = 'library-catalog-v1';
  static const readingBootstrapSource = 'reading-state-v1';

  final SharedStateDatabase sharedState;
  final LibraryProjection projection;
  final DateTime Function() now;
  final String deviceId;
  final Future<Map<String, dynamic>?> Function(Book book) assetForBook;
  final Future<Map<String, dynamic>?> Function(Book book) coverAssetForBook;

  LibrarySyncRepository({
    required this.sharedState,
    required this.projection,
    required this.deviceId,
    Future<Map<String, dynamic>?> Function(Book book)? assetForBook,
    Future<Map<String, dynamic>?> Function(Book book)? coverAssetForBook,
    DateTime Function()? now,
  })  : assetForBook = assetForBook ?? _assetForLocalBook,
        coverAssetForBook = coverAssetForBook ?? _coverAssetForLocalBook,
        now = now ?? DateTime.now;

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
    final candidate = await _catalogFromBook(
      book,
      fingerprint,
      valueStamp,
      current: current,
    );
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
    var unresolved = 0;
    for (final book in await projection.allBooks()) {
      String fingerprint;
      try {
        fingerprint = canonicalMd5Fingerprint(book.md5);
      } catch (_) {
        unresolved++;
        continue;
      }
      final catalogReceipt =
          await sharedState.importReceipt(catalogBootstrapSource, fingerprint);
      if (catalogReceipt?.status != 'complete') {
        final legacyStamp = stamp(book.updateTime);
        try {
          await publishBook(book, mutationStamp: legacyStamp);
        } on StateError {
          unresolved++;
          await sharedState.recordImport(
            source: catalogBootstrapSource,
            sourceKey: fingerprint,
            sharedId: fingerprint,
            status: 'blocked',
            detail: 'missing-verifiable-asset',
          );
          continue;
        }
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
    if (unresolved > 0) {
      syncWarning('bootstrap library deferred '
          'reason=no-portable-fingerprint-or-asset count=$unresolved');
    }
    syncDebug('bootstrap library imported=$imported deferred=$unresolved');
    return imported;
  }

  Future<Map<String, dynamic>> _catalogFromBook(
      Book book, String fingerprint, DomainStamp valueStamp,
      {Map<String, dynamic>? current}) async {
    final existingMetadata = current?['metadata'] as Map<String, dynamic>?;
    Map<String, dynamic> field(String name, Object? value) {
      final previous = existingMetadata?[name] as Map<String, dynamic>?;
      return previous != null && previous['value'] == value
          ? previous
          : stampedValue(value, valueStamp);
    }

    final previousMembership = current?['membership'] as Map<String, dynamic>?;
    final previousAsset = current?['bookAsset'] as Map<String, dynamic>?;
    final previousCoverAsset = current?['coverAsset'] as Map<String, dynamic>?;
    final localAsset = await assetForBook(book);
    final asset = localAsset ?? previousAsset?['value'];
    if (asset == null) {
      throw StateError('Book has no verifiable local or canonical asset');
    }
    final stampedAsset = previousAsset != null &&
            canonicalJson(previousAsset['value']) == canonicalJson(asset)
        ? previousAsset
        : stampedValue(asset, valueStamp);
    final localCoverAsset = await coverAssetForBook(book);
    final coverAsset = localCoverAsset ?? previousCoverAsset?['value'];
    final stampedCoverAsset = coverAsset == null
        ? null
        : previousCoverAsset != null &&
                canonicalJson(previousCoverAsset['value']) ==
                    canonicalJson(coverAsset)
            ? previousCoverAsset
            : stampedValue(coverAsset, valueStamp);
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
      'bookAsset': stampedAsset,
      if (stampedCoverAsset != null) 'coverAsset': stampedCoverAsset,
    });
  }

  Future<Map<String, dynamic>?> _read(String domain, String id) async {
    final bytes = await sharedState.canonicalDocument(domain, id);
    if (bytes == null) return null;
    final decoded = jsonDecode(utf8.decode(bytes));
    return domain == libraryCatalogDomain
        ? decodeLibraryCatalogDocument(decoded)
        : decodeReadingStateDocument(decoded);
  }

  static Future<Map<String, dynamic>?> _assetForLocalBook(Book book) async {
    if (book.filePath.isEmpty) return null;
    final file = File(getBasePath(book.filePath));
    if (!await file.exists()) return null;
    return {
      'algorithm': 'sha256',
      'digest': (await sha256.bind(file.openRead()).first).toString(),
      'extension': _portableExtensionStatic(book.filePath),
    };
  }

  static Future<Map<String, dynamic>?> _coverAssetForLocalBook(
      Book book) async {
    if (book.coverPath.isEmpty) return null;
    final file = File(getBasePath(book.coverPath));
    if (!await file.exists()) return null;
    return {
      'algorithm': 'sha256',
      'digest': (await sha256.bind(file.openRead()).first).toString(),
      'extension': _portableExtensionStatic(book.coverPath),
    };
  }

  static String _portableExtensionStatic(String path) {
    final extension = p.extension(path).toLowerCase();
    return RegExp(r'^\.[a-z0-9]{1,8}$').hasMatch(extension)
        ? extension
        : '.epub';
  }
}
