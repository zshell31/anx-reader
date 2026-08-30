import 'dart:convert';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/models/book_note.dart';
import 'package:anx_reader/service/sync/annotation_protocol.dart';
import 'package:anx_reader/service/sync/annotation_read_model.dart';
import 'package:anx_reader/service/sync/native_annotation_projection.dart';
import 'package:anx_reader/service/sync/shared_state_database.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

abstract final class AnnotationProjectionStatus {
  static const materialized = 'materialized';
  static const unsupported = 'unsupported';
  static const unbound = 'unbound';
  static const error = 'error';
  static const tombstoned = 'tombstoned';
}

class NativeAnnotationDefaults {
  final String selectionType;
  final String color;

  const NativeAnnotationDefaults({
    required this.selectionType,
    required this.color,
  });
}

class AnnotationReconciliationResult {
  int inserted = 0;
  int updated = 0;
  int deleted = 0;
  int unchanged = 0;
  int unsupported = 0;
  int unbound = 0;
  int errors = 0;
  int metadataWrites = 0;

  int get nativeWrites => inserted + updated + deleted;
}

/// Rebuilds the Anx-native BookNote projection from canonical shared state.
/// It never writes an AnnotationBookDocument.
class AnnotationProjectionReconciler {
  final SharedStateDatabase sharedState;
  final NativeAnnotationProjectionStore native;
  final NativeAnnotationDefaults Function() defaults;

  AnnotationProjectionReconciler(
    this.sharedState, {
    NativeAnnotationProjectionStore? native,
    NativeAnnotationDefaults Function()? defaults,
  })  : native = native ?? DaoNativeAnnotationProjectionStore(),
        defaults = defaults ??
            (() => NativeAnnotationDefaults(
                  selectionType: Prefs().annotationType,
                  color: Prefs().annotationColor,
                ));

  Future<AnnotationReconciliationResult> run() async {
    final result = AnnotationReconciliationResult();
    for (final document in await sharedState.annotationDocuments()) {
      final book = document['book'] as Map<String, dynamic>;
      final fingerprint = canonicalMd5Fingerprint(book['fingerprint']);
      _addResult(result, await reconcileBook(fingerprint));
    }
    return result;
  }

  /// Reconciles one book after a remote merge without scanning other books.
  Future<AnnotationReconciliationResult> reconcileBook(
      String fingerprint) async {
    final result = AnnotationReconciliationResult();
    final canonicalFingerprint = canonicalMd5Fingerprint(fingerprint);
    final document = await sharedState.annotationDocument(canonicalFingerprint);
    if (document == null) return result;
    final localBooks =
        await native.findBooksByFingerprint(canonicalFingerprint);
    final annotations =
        (document['annotations'] as List).cast<Map<String, dynamic>>();
    for (final annotation in annotations) {
      try {
        await _reconcileOne(
            annotation, canonicalFingerprint, localBooks, result);
      } catch (error) {
        result.errors++;
        if (await sharedState.putAnnotationProjection(
          annotationId: annotation['id'] as String,
          bookFingerprint: canonicalFingerprint,
          nativeNoteId: null,
          status: AnnotationProjectionStatus.error,
          canonicalHash: _hash(annotation),
          lastError: error.toString(),
        )) {
          result.metadataWrites++;
        }
      }
    }
    return result;
  }

  void _addResult(AnnotationReconciliationResult target,
      AnnotationReconciliationResult value) {
    target.inserted += value.inserted;
    target.updated += value.updated;
    target.deleted += value.deleted;
    target.unchanged += value.unchanged;
    target.unsupported += value.unsupported;
    target.unbound += value.unbound;
    target.errors += value.errors;
    target.metadataWrites += value.metadataWrites;
  }

  /// Reconciles one repository mutation without scanning unrelated books.
  ///
  /// [localPresentation] is only a projection hint. It can carry the local
  /// highlight/underline and color chosen while creating or editing a native
  /// row, but none of those values are written to canonical shared state.
  Future<AnnotationReconciliationResult> reconcileAnnotation(
    String fingerprint,
    String annotationId, {
    BookNote? localPresentation,
    bool migrateLegacyPresentation = true,
  }) async {
    final result = AnnotationReconciliationResult();
    final canonicalFingerprint = canonicalMd5Fingerprint(fingerprint);
    final document = await sharedState.annotationDocument(canonicalFingerprint);
    if (document == null) {
      throw StateError(
          'No canonical annotation document for $canonicalFingerprint');
    }
    final annotations =
        (document['annotations'] as List).cast<Map<String, dynamic>>();
    final matches =
        annotations.where((value) => value['id'] == annotationId).toList();
    if (matches.length != 1) {
      throw StateError('Canonical annotation $annotationId was not found');
    }
    final localBooks =
        await native.findBooksByFingerprint(canonicalFingerprint);
    try {
      await _reconcileOne(
          matches.single, canonicalFingerprint, localBooks, result,
          localPresentation: localPresentation,
          migrateLegacyPresentation: migrateLegacyPresentation);
    } catch (error) {
      result.errors++;
      if (await sharedState.putAnnotationProjection(
        annotationId: annotationId,
        bookFingerprint: canonicalFingerprint,
        nativeNoteId: null,
        status: AnnotationProjectionStatus.error,
        canonicalHash: _hash(matches.single),
        lastError: error.toString(),
      )) {
        result.metadataWrites++;
      }
    }
    return result;
  }

  Future<void> _reconcileOne(
    Map<String, dynamic> annotation,
    String fingerprint,
    List<Book> localBooks,
    AnnotationReconciliationResult result, {
    BookNote? localPresentation,
    bool migrateLegacyPresentation = true,
  }) async {
    final annotationId = annotation['id'] as String;
    final existing = await native.findBySharedAnnotationId(annotationId);

    if (annotation.containsKey('deletedAt')) {
      await sharedState.deleteAnnotationPresentation(annotationId);
      if (existing?.id != null) {
        await native.deleteProjection(existing!.id!);
        result.deleted++;
      } else {
        result.unchanged++;
      }
      if (await sharedState.putAnnotationProjection(
        annotationId: annotationId,
        bookFingerprint: fingerprint,
        nativeNoteId: null,
        status: AnnotationProjectionStatus.tombstoned,
        canonicalHash: _hash(annotation),
      )) {
        result.metadataWrites++;
      }
      return;
    }

    final projection = _representable(annotation);
    if (projection == null) {
      if (existing?.id != null) {
        await native.deleteProjection(existing!.id!);
        result.deleted++;
      }
      result.unsupported++;
      if (await sharedState.putAnnotationProjection(
        annotationId: annotationId,
        bookFingerprint: fingerprint,
        nativeNoteId: null,
        status: AnnotationProjectionStatus.unsupported,
        canonicalHash: _hash(annotation),
        lastError: 'unsupported native annotation target',
      )) {
        result.metadataWrites++;
      }
      return;
    }

    final localBook = _resolveBook(localBooks, existing);
    if (localBook == null) {
      if (existing?.id != null) {
        // A native row whose book identity can no longer be validated is not a
        // safe projection. Canonical state remains intact and can rebuild it
        // once an unambiguous local EPUB binding exists again.
        await native.deleteProjection(existing!.id!);
        result.deleted++;
      }
      result.unbound++;
      if (await sharedState.putAnnotationProjection(
        annotationId: annotationId,
        bookFingerprint: fingerprint,
        nativeNoteId: null,
        status: AnnotationProjectionStatus.unbound,
        canonicalHash: projection.hash,
        lastError: localBooks.isEmpty
            ? 'no validated local EPUB book binding'
            : 'ambiguous local EPUB book binding',
      )) {
        result.metadataWrites++;
      }
      return;
    }

    final presentation = await _presentation(
      annotationId,
      annotation['motivation'] as String,
      migrateLegacyPresentation ? localPresentation ?? existing : null,
    );
    final desired = _desiredNote(annotationId, annotation, projection,
        localBook.id, existing, localPresentation, presentation);
    int nativeNoteId;
    if (existing == null) {
      nativeNoteId = await native.insertProjection(desired);
      result.inserted++;
    } else {
      nativeNoteId = existing.id!;
      desired.id = nativeNoteId;
      if (_sameProjection(existing, desired)) {
        result.unchanged++;
      } else {
        await native.updateProjection(desired);
        result.updated++;
      }
    }

    if (await sharedState.putAnnotationProjection(
      annotationId: annotationId,
      bookFingerprint: fingerprint,
      nativeNoteId: nativeNoteId,
      status: AnnotationProjectionStatus.materialized,
      canonicalHash: projection.hash,
    )) {
      result.metadataWrites++;
    }
  }

  Book? _resolveBook(List<Book> books, BookNote? existing) {
    final supported = books.where((book) {
      if (p.extension(book.filePath).toLowerCase() != '.epub') return false;
      try {
        canonicalMd5Fingerprint(book.md5);
        return true;
      } on AnnotationProtocolException {
        return false;
      }
    }).toList(growable: false);
    if (existing != null) {
      final bound = supported.where((book) => book.id == existing.bookId);
      if (bound.length == 1) return bound.single;
    }
    return supported.length == 1 ? supported.single : null;
  }

  _RepresentableProjection? _representable(Map<String, dynamic> annotation) {
    final target = annotation['target'];
    if (target is! Map) return null;
    final cfi = supportedEpubCfi(target);
    if (cfi == null) return null;
    final selectedText = target['selectedText'];
    final chapter = target['chapter'];
    if (selectedText is! String || (chapter != null && chapter is! String)) {
      return null;
    }
    final personalNote = effectivePersonalNote(annotation);
    final material = {
      'motivation': annotation['motivation'],
      'selectedText': selectedText,
      'chapter': chapter ?? '',
      'cfi': cfi,
      'readerNote': personalNote?.content,
      'createdAt': annotation['createdAt'],
      'updatedAt': _projectionUpdatedAt(annotation, personalNote),
    };
    return _RepresentableProjection(
      content: selectedText,
      chapter: chapter as String? ?? '',
      cfi: cfi,
      readerNote: personalNote?.content,
      updatedAt: material['updatedAt']! as String,
      hash: _hash(material),
    );
  }

  String _projectionUpdatedAt(
      Map<String, dynamic> annotation, AnnotationEnrichmentView? personalNote) {
    final annotationTime = annotation['updatedAt'] as String;
    if (personalNote == null ||
        !personalNote.updatedAt.isAfter(DateTime.parse(annotationTime))) {
      return annotationTime;
    }
    return canonicalWireTimestamp(personalNote.updatedAt);
  }

  Future<AnnotationPresentation?> _presentation(
    String annotationId,
    String motivation,
    BookNote? legacyPresentation,
  ) async {
    if (motivation != 'selection') return null;
    final stored = await sharedState.annotationPresentation(annotationId);
    if (stored != null) return stored;
    if (legacyPresentation == null ||
        (legacyPresentation.type != 'highlight' &&
            legacyPresentation.type != 'underline') ||
        legacyPresentation.color.isEmpty) {
      return null;
    }
    final migrated = AnnotationPresentation(
      annotationId: annotationId,
      style: legacyPresentation.type == 'underline'
          ? AnnotationPresentationStyle.underline
          : AnnotationPresentationStyle.highlight,
      color: legacyPresentation.color,
    );
    await sharedState.putAnnotationPresentation(migrated);
    return migrated;
  }

  BookNote _desiredNote(
    String annotationId,
    Map<String, dynamic> annotation,
    _RepresentableProjection projection,
    int bookId,
    BookNote? existing,
    BookNote? localPresentation,
    AnnotationPresentation? presentation,
  ) {
    final localDefaults = defaults();
    final motivation = annotation['motivation'] as String;
    final selectionType = presentation != null
        ? presentation.style.name
        : (localDefaults.selectionType == 'underline'
            ? 'underline'
            : 'highlight');
    final bookmarkPresentation = localPresentation ?? existing;
    return BookNote(
      bookId: bookId,
      content: projection.content,
      cfi: projection.cfi,
      chapter: projection.chapter,
      type: motivation == 'bookmark' ? 'bookmark' : selectionType,
      color: motivation == 'bookmark'
          ? (bookmarkPresentation?.color.isNotEmpty == true
              ? bookmarkPresentation!.color
              : localDefaults.color)
          : presentation?.color ?? localDefaults.color,
      readerNote: projection.readerNote,
      sharedAnnotationId: annotationId,
      createTime: DateTime.parse(annotation['createdAt'] as String),
      updateTime: DateTime.parse(projection.updatedAt),
    );
  }

  bool _sameProjection(BookNote left, BookNote right) =>
      left.bookId == right.bookId &&
      left.content == right.content &&
      left.cfi == right.cfi &&
      left.chapter == right.chapter &&
      left.type == right.type &&
      left.color == right.color &&
      left.readerNote == right.readerNote &&
      left.sharedAnnotationId == right.sharedAnnotationId &&
      _sameInstant(left.createTime, right.createTime) &&
      left.updateTime.isAtSameMomentAs(right.updateTime);

  bool _sameInstant(DateTime? left, DateTime? right) => left == null
      ? right == null
      : right != null && left.isAtSameMomentAs(right);

  String _hash(Object? value) =>
      sha256.convert(utf8.encode(canonicalJson(value))).toString();
}

class _RepresentableProjection {
  final String content;
  final String chapter;
  final String cfi;
  final String? readerNote;
  final String updatedAt;
  final String hash;

  const _RepresentableProjection({
    required this.content,
    required this.chapter,
    required this.cfi,
    required this.readerNote,
    required this.updatedAt,
    required this.hash,
  });
}
