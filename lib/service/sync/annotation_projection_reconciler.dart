import 'dart:convert';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/models/book_note.dart';
import 'package:anx_reader/service/sync/annotation_protocol.dart';
import 'package:anx_reader/service/sync/legacy_annotation_bootstrap.dart';
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
      final localBooks = await native.findBooksByFingerprint(fingerprint);
      final annotations =
          (document['annotations'] as List).cast<Map<String, dynamic>>();
      for (final annotation in annotations) {
        try {
          await _reconcileOne(annotation, fingerprint, localBooks, result);
        } catch (error) {
          result.errors++;
          if (await sharedState.putAnnotationProjection(
            annotationId: annotation['id'] as String,
            bookFingerprint: fingerprint,
            nativeNoteId: null,
            status: AnnotationProjectionStatus.error,
            canonicalHash: _hash(annotation),
            lastError: error.toString(),
          )) {
            result.metadataWrites++;
          }
        }
      }
    }
    return result;
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
          localPresentation: localPresentation);
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
  }) async {
    final annotationId = annotation['id'] as String;
    final existing = await native.findBySharedAnnotationId(annotationId);

    if (annotation.containsKey('deletedAt')) {
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

    final desired = _desiredNote(annotationId, annotation, projection,
        localBook.id, existing, localPresentation);
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
    final personalNote = _projectedPersonalNote(annotation);
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

  _PersonalNote? _projectedPersonalNote(Map<String, dynamic> annotation) {
    final enrichments = annotation['enrichments'] as List;
    final personalNotes = enrichments
        .cast<Map<String, dynamic>>()
        .where((item) => item['kind'] == 'personal-note')
        .toList();
    if (personalNotes.isEmpty) return null;
    // Tombstones participate in winner selection. Otherwise an older active
    // enrichment could resurrect a note that the user explicitly cleared.
    personalNotes.sort((left, right) {
      final time =
          (left['updatedAt'] as String).compareTo(right['updatedAt'] as String);
      return time != 0
          ? time
          : canonicalJson(left).compareTo(canonicalJson(right));
    });
    final winner = personalNotes.last;
    if (winner.containsKey('deletedAt') || winner['content'] is! String) {
      return null;
    }
    return _PersonalNote(
        winner['content'] as String, winner['updatedAt'] as String);
  }

  String _projectionUpdatedAt(
      Map<String, dynamic> annotation, _PersonalNote? personalNote) {
    final annotationTime = annotation['updatedAt'] as String;
    if (personalNote == null ||
        annotationTime.compareTo(personalNote.updatedAt) >= 0) {
      return annotationTime;
    }
    return personalNote.updatedAt;
  }

  BookNote _desiredNote(
    String annotationId,
    Map<String, dynamic> annotation,
    _RepresentableProjection projection,
    int bookId,
    BookNote? existing,
    BookNote? localPresentation,
  ) {
    final localDefaults = defaults();
    final motivation = annotation['motivation'] as String;
    final presentation = localPresentation ?? existing;
    final selectionType = presentation != null &&
            (presentation.type == 'highlight' ||
                presentation.type == 'underline')
        ? presentation.type
        : (localDefaults.selectionType == 'underline'
            ? 'underline'
            : 'highlight');
    return BookNote(
      bookId: bookId,
      content: projection.content,
      cfi: projection.cfi,
      chapter: projection.chapter,
      type: motivation == 'bookmark' ? 'bookmark' : selectionType,
      color: presentation?.color.isNotEmpty == true
          ? presentation!.color
          : localDefaults.color,
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

class _PersonalNote {
  final String content;
  final String updatedAt;

  const _PersonalNote(this.content, this.updatedAt);
}
