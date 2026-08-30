import 'dart:convert';

import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/service/sync/annotation_protocol.dart';
import 'package:anx_reader/service/sync/annotation_read_model.dart';
import 'package:anx_reader/service/sync/legacy_annotation_store.dart';
import 'package:anx_reader/service/sync/shared_state_database.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

class AnnotationBootstrapResult {
  int imported = 0;
  int alreadyImported = 0;
  int unsupported = 0;
  final Set<String> changedFingerprints = {};
  bool presentationChanged = false;
}

/// Portable identity for legacy EPUB annotation rows.
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
/// Local book/row IDs, update time, presentation, and personal-note
/// content are deliberately excluded. The first two are database-local, while
/// the latter fields can change without creating a new annotation. Including
/// CFI prevents equal text at different locations from collapsing; including
/// creation time, motivation, text, and chapter prevents locator-only collapse
/// of distinct annotations at the same CFI. Exact duplicates with no portable
/// distinguishing evidence are intentionally the same logical legacy item.
abstract final class LegacyAnnotationAnchor {
  static const receiptSource = 'anx-booknote-anchor-v1';
  static const _identityVersion = 1;

  static String forRow(String fingerprint, LegacyAnnotationRow row) => _hash(
        fingerprint: fingerprint,
        motivation: _motivation(row.type),
        cfi: row.cfi,
        createdAt:
            canonicalWireTimestamp((row.createTime ?? row.updateTime).toUtc()),
        selectedText: row.selectedText,
        chapter: row.chapter,
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

/// Imports only identities and locators that can be represented honestly.
/// Unsupported rows remain untouched and receive a durable recognition receipt.
class LegacyAnnotationBootstrap {
  final SharedStateDatabase sharedState;
  final LegacyAnnotationStore legacy;
  final Uuid uuid;

  LegacyAnnotationBootstrap(
    this.sharedState, {
    LegacyAnnotationStore? legacy,
    Uuid? uuid,
  })  : legacy = legacy ?? DatabaseLegacyAnnotationStore(),
        uuid = uuid ?? const Uuid();

  Future<AnnotationBootstrapResult> run() async {
    final result = AnnotationBootstrapResult();
    final bookCache = <int, Book?>{};
    for (final row in await legacy.readAnnotations()) {
      final rowId = row.rowId;
      if (rowId == null) {
        result.unsupported++;
        continue;
      }
      final book = bookCache.containsKey(row.localBookId)
          ? bookCache[row.localBookId]
          : (bookCache[row.localBookId] =
              await legacy.readBook(row.localBookId));
      final reason = _unsupportedReason(book, row);
      if (reason != null) {
        final sourceKey = _unsupportedReceiptKey(book, row);
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
      final anchor = LegacyAnnotationAnchor.forRow(fingerprint, row);
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
      final metadataChanged = applyAnnotationBookMetadata(
        document,
        title: book.title,
        author: book.author,
      );
      final annotations =
          (document['annotations'] as List).cast<Map<String, dynamic>>();

      Map<String, dynamic>? canonical;
      if (receipt?.sharedId != null) {
        canonical = _findById(annotations, receipt!.sharedId!);
      }
      if (canonical == null && row.canonicalIdHint?.isNotEmpty == true) {
        canonical = _findById(annotations, row.canonicalIdHint!);
      }
      canonical ??= _findByAnchor(annotations, fingerprint, anchor);

      final wasImported = canonical != null;
      final tombstoneReceipt = receipt?.status == 'tombstoned';
      final sharedId = canonical?['id'] as String? ??
          receipt?.sharedId ??
          row.canonicalIdHint ??
          uuid.v5(Namespace.url.value, 'anx:legacy-annotation:v1:$anchor');
      if (canonical == null && tombstoneReceipt) {
        result.alreadyImported++;
        continue;
      }
      canonical ??= _annotation(row, sharedId);
      if (!wasImported) {
        annotations.add(canonical);
        annotations
            .sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
      }
      if (!wasImported || metadataChanged) {
        await sharedState.putAnnotationDocument(document);
        result.changedFingerprints.add(fingerprint);
      }

      final tombstoned = canonical.containsKey('deletedAt');
      if (!tombstoned &&
          canonical['motivation'] == 'selection' &&
          !await sharedState.hasAnnotationPresentationOperation(sharedId)) {
        result.presentationChanged |=
            await sharedState.putAnnotationPresentation(AnnotationPresentation(
          annotationId: sharedId,
          style: row.type == 'underline'
              ? AnnotationPresentationStyle.underline
              : AnnotationPresentationStyle.highlight,
          color: row.color,
        ));
      }
      await sharedState.recordImport(
        source: LegacyAnnotationAnchor.receiptSource,
        sourceKey: anchor,
        sharedId: sharedId,
        status: tombstoned ? 'tombstoned' : 'recognized',
        detail:
            'last legacy hint book=${row.localBookId}, row=$rowId; read-only',
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

  String? _unsupportedReason(Book? book, LegacyAnnotationRow row) {
    if (book == null) return 'local book binding not found';
    final extension = p.extension(book.filePath).toLowerCase();
    if (extension != '.epub') return 'unsupported format $extension';
    try {
      canonicalMd5Fingerprint(book.md5);
    } on AnnotationProtocolException {
      return 'invalid MD5 fingerprint';
    }
    if (!isEpubCfi(row.cfi)) return 'invalid or non-EPUB-CFI locator';
    return null;
  }

  String _unsupportedReceiptKey(Book? book, LegacyAnnotationRow row) {
    final evidence = {
      'version': 1,
      'format': book == null ? null : p.extension(book.filePath).toLowerCase(),
      'rawFingerprint': book?.md5,
      'motivation': row.type == 'bookmark' ? 'bookmark' : 'selection',
      'locator': row.cfi,
      'createdAt':
          canonicalWireTimestamp((row.createTime ?? row.updateTime).toUtc()),
      'selectedText': row.selectedText,
      'chapter': row.chapter,
    };
    return sha256.convert(utf8.encode(canonicalJson(evidence))).toString();
  }

  Map<String, dynamic> _annotation(LegacyAnnotationRow row, String sharedId) {
    final created =
        canonicalWireTimestamp((row.createTime ?? row.updateTime).toUtc());
    final updated = canonicalWireTimestamp(row.updateTime.toUtc());
    final enrichments = <Map<String, dynamic>>[];
    if (row.personalNote?.isNotEmpty == true) {
      enrichments.add({
        'id': 'personal-note:$sharedId',
        'kind': 'personal-note',
        'content': row.personalNote,
        'createdAt': created,
        'updatedAt': updated,
      });
    }
    return {
      'id': sharedId,
      'motivation': row.type == 'bookmark' ? 'bookmark' : 'selection',
      'createdAt': created,
      'updatedAt': updated,
      'target': {
        'selectedText': row.selectedText,
        'chapter': row.chapter,
        if (row.type == 'bookmark' && row.bookmarkPercentage != null)
          'progress': {'fraction': row.bookmarkPercentage},
        'selectors': [
          {'type': 'epub-cfi', 'cfi': row.cfi.trim()}
        ],
      },
      // Legacy rows do not contain the original Foliate selection context.
      'enrichments': enrichments,
    };
  }
}
