import 'dart:convert';

import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/models/book_note.dart';
import 'package:anx_reader/service/sync/annotation_protocol.dart';
import 'package:anx_reader/service/sync/native_annotation_projection.dart';
import 'package:anx_reader/service/sync/shared_state_database.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

class AnnotationBootstrapResult {
  int imported = 0;
  int alreadyImported = 0;
  int unsupported = 0;
}

/// Portable identity for legacy EPUB BookNotes.
///
/// Version 1 hashes the canonical JSON of:
///
/// * validated lowercase book MD5;
/// * shared motivation (`selection` or `bookmark`);
/// * the trimmed EPUB CFI;
/// * canonical creation timestamp;
/// * selected text; and
/// * chapter (an empty string when absent).
///
/// Book.id, BookNote.id, update time, local color/presentation, and reader-note
/// content are deliberately excluded. The first two are database-local, while
/// the latter fields can change without creating a new annotation. Including
/// CFI prevents equal text at different locations from collapsing; including
/// creation time, motivation, text, and chapter prevents locator-only collapse
/// of distinct annotations at the same CFI. Exact duplicates with no portable
/// distinguishing evidence are intentionally the same logical legacy item.
abstract final class LegacyAnnotationAnchor {
  static const receiptSource = 'anx-booknote-anchor-v1';
  static const _identityVersion = 1;

  static String forNote(String fingerprint, BookNote note) => _hash(
        fingerprint: fingerprint,
        motivation: _motivation(note.type),
        cfi: note.cfi,
        createdAt: canonicalWireTimestamp(
            (note.createTime ?? note.updateTime).toUtc()),
        selectedText: note.content,
        chapter: note.chapter,
      );

  static String? forCanonical(
      String fingerprint, Map<String, dynamic> annotation) {
    final target = annotation['target'];
    final motivation = annotation['motivation'];
    final createdAt = annotation['createdAt'];
    if (target is! Map ||
        motivation is! String ||
        createdAt is! String ||
        (motivation != 'selection' && motivation != 'bookmark')) {
      return null;
    }
    final cfi = supportedEpubCfi(target);
    if (cfi == null) return null;
    return _hash(
      fingerprint: fingerprint,
      motivation: motivation,
      cfi: cfi,
      createdAt: createdAt,
      selectedText: target['selectedText'] as String? ?? '',
      chapter: target['chapter'] as String? ?? '',
    );
  }

  static String _hash({
    required String fingerprint,
    required String motivation,
    required String cfi,
    required String createdAt,
    required String selectedText,
    required String chapter,
  }) {
    final identity = {
      'version': _identityVersion,
      'bookFingerprint': canonicalMd5Fingerprint(fingerprint),
      'motivation': motivation,
      'locator': {'type': 'epub-cfi', 'cfi': cfi.trim()},
      'createdAt': validateWireTimestamp(createdAt, 'createdAt'),
      'selectedText': selectedText,
      'chapter': chapter,
    };
    return sha256.convert(utf8.encode(canonicalJson(identity))).toString();
  }

  static String _motivation(String nativeType) =>
      nativeType == 'bookmark' ? 'bookmark' : 'selection';
}

String? supportedEpubCfi(Map target) {
  final selectors = target['selectors'];
  if (selectors is! List) return null;
  final values = <String>{};
  for (final selector in selectors) {
    if (selector is Map && selector['type'] == 'epub-cfi') {
      final value = selector['cfi'];
      if (value is String && _isEpubCfi(value)) values.add(value.trim());
    }
  }
  return values.length == 1 ? values.single : null;
}

bool _isEpubCfi(String value) {
  final cfi = value.trim();
  return cfi.startsWith('epubcfi(') && cfi.endsWith(')') && cfi.length > 9;
}

/// Imports only identities and locators that can be represented honestly.
/// Unsupported rows remain untouched and receive a durable recognition receipt.
class LegacyAnnotationBootstrap {
  final SharedStateDatabase sharedState;
  final NativeAnnotationProjectionStore native;
  final Uuid uuid;

  LegacyAnnotationBootstrap(
    this.sharedState, {
    NativeAnnotationProjectionStore? native,
    Uuid? uuid,
  })  : native = native ?? DaoNativeAnnotationProjectionStore(),
        uuid = uuid ?? const Uuid();

  Future<AnnotationBootstrapResult> run() async {
    final result = AnnotationBootstrapResult();
    final bookCache = <int, Book?>{};
    for (final note in await native.enumerateLegacyUnboundNotes()) {
      final noteId = note.id;
      if (noteId == null) {
        result.unsupported++;
        continue;
      }
      final book = bookCache.containsKey(note.bookId)
          ? bookCache[note.bookId]
          : (bookCache[note.bookId] = await native.readBook(note.bookId));
      final reason = _unsupportedReason(book, note);
      if (reason != null) {
        final sourceKey = _unsupportedReceiptKey(book, note);
        if (await sharedState.importReceipt(
                'tb_notes-unsupported-v1', sourceKey) ==
            null) {
          await sharedState.recordImport(
            source: 'tb_notes-unsupported-v1',
            sourceKey: sourceKey,
            status: 'unsupported',
            detail: reason,
          );
        }
        result.unsupported++;
        continue;
      }

      final fingerprint = canonicalMd5Fingerprint(book!.md5);
      final anchor = LegacyAnnotationAnchor.forNote(fingerprint, note);
      final receipt = await sharedState.importReceipt(
          LegacyAnnotationAnchor.receiptSource, anchor);
      final document = await sharedState.annotationDocument(fingerprint) ??
          {
            'schemaVersion': 2,
            'book': {
              'fingerprintAlgorithm': 'md5',
              'fingerprint': fingerprint,
            },
            'annotations': <Object>[],
          };
      final annotations =
          (document['annotations'] as List).cast<Map<String, dynamic>>();

      Map<String, dynamic>? canonical;
      if (receipt?.sharedId != null) {
        canonical = _findById(annotations, receipt!.sharedId!);
      }
      canonical ??= _findByAnchor(annotations, fingerprint, anchor);

      final wasImported = canonical != null;
      final sharedId = canonical?['id'] as String? ??
          uuid.v5(Namespace.url.value, 'anx:legacy-annotation:v1:$anchor');
      canonical ??= _annotation(note, sharedId);
      if (!wasImported) {
        annotations.add(canonical);
        annotations
            .sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
        await sharedState.putAnnotationDocument(document);
      }

      // Binding is a local cache. The receipt and canonical match above remain
      // valid when a replacement database uses entirely different local IDs.
      await native.bindSharedAnnotation(noteId, sharedId);
      final tombstoned = canonical.containsKey('deletedAt');
      await sharedState.recordImport(
        source: LegacyAnnotationAnchor.receiptSource,
        sourceKey: anchor,
        sharedId: sharedId,
        status: tombstoned ? 'tombstoned' : 'recognized',
        detail: 'last native hint book=${note.bookId}, note=$noteId',
      );
      if (wasImported) {
        result.alreadyImported++;
      } else {
        result.imported++;
      }
    }
    return result;
  }

  Map<String, dynamic>? _findById(
      List<Map<String, dynamic>> annotations, String id) {
    for (final annotation in annotations) {
      if (annotation['id'] == id) return annotation;
    }
    return null;
  }

  Map<String, dynamic>? _findByAnchor(List<Map<String, dynamic>> annotations,
      String fingerprint, String anchor) {
    for (final annotation in annotations) {
      if (LegacyAnnotationAnchor.forCanonical(fingerprint, annotation) ==
          anchor) {
        return annotation;
      }
    }
    return null;
  }

  String? _unsupportedReason(Book? book, BookNote note) {
    if (book == null) return 'local book binding not found';
    final extension = p.extension(book.filePath).toLowerCase();
    if (extension != '.epub') return 'unsupported format $extension';
    try {
      canonicalMd5Fingerprint(book.md5);
    } on AnnotationProtocolException {
      return 'invalid MD5 fingerprint';
    }
    if (!_isEpubCfi(note.cfi)) return 'invalid or non-EPUB-CFI locator';
    return null;
  }

  String _unsupportedReceiptKey(Book? book, BookNote note) {
    final evidence = {
      'version': 1,
      'format': book == null ? null : p.extension(book.filePath).toLowerCase(),
      'rawFingerprint': book?.md5,
      'motivation': note.type == 'bookmark' ? 'bookmark' : 'selection',
      'locator': note.cfi,
      'createdAt':
          canonicalWireTimestamp((note.createTime ?? note.updateTime).toUtc()),
      'selectedText': note.content,
      'chapter': note.chapter,
    };
    return sha256.convert(utf8.encode(canonicalJson(evidence))).toString();
  }

  Map<String, dynamic> _annotation(BookNote note, String sharedId) {
    final created =
        canonicalWireTimestamp((note.createTime ?? note.updateTime).toUtc());
    final updated = canonicalWireTimestamp(note.updateTime.toUtc());
    final enrichments = <Map<String, dynamic>>[];
    if (note.readerNote?.isNotEmpty == true) {
      enrichments.add({
        'id': 'personal-note:$sharedId',
        'kind': 'personal-note',
        'content': note.readerNote,
        'createdAt': created,
        'updatedAt': updated,
      });
    }
    return {
      'id': sharedId,
      'motivation': note.type == 'bookmark' ? 'bookmark' : 'selection',
      'createdAt': created,
      'updatedAt': updated,
      'target': {
        'selectedText': note.content,
        'chapter': note.chapter,
        'selectors': [
          {'type': 'epub-cfi', 'cfi': note.cfi.trim()}
        ],
      },
      // Legacy rows do not contain the original Foliate selection context.
      'enrichments': enrichments,
    };
  }
}
