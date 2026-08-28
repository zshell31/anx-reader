import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/dao/book_note.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/models/book_note.dart';
import 'package:anx_reader/service/sync/annotation_protocol.dart';
import 'package:anx_reader/service/sync/shared_state_database.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

class AnnotationBootstrapResult {
  int imported = 0;
  int alreadyImported = 0;
  int unsupported = 0;
}

/// Imports only identity/locator combinations that can be described honestly.
/// Unsupported rows remain untouched and receive a durable receipt explaining why.
class LegacyAnnotationBootstrap {
  final SharedStateDatabase sharedState;
  final BookNoteDao notes;
  final BookDao books;
  final Uuid uuid;
  LegacyAnnotationBootstrap(this.sharedState,
      {BookNoteDao? notes, BookDao? books, Uuid? uuid})
      : notes = notes ?? BookNoteDao(),
        books = books ?? BookDao(),
        uuid = uuid ?? const Uuid();

  Future<AnnotationBootstrapResult> run() async {
    final result = AnnotationBootstrapResult();
    final bookCache = <int, Book>{};
    for (final note in await notes.selectUnboundAnnotations()) {
      final sourceKey = '${note.bookId}:${note.id}';
      final receiptId =
          await sharedState.importedSharedId('tb_notes', sourceKey);
      if (receiptId != null) {
        await notes.bindSharedAnnotation(note.id!, receiptId);
        result.alreadyImported++;
        continue;
      }
      final book =
          bookCache[note.bookId] ??= await books.selectBookById(note.bookId);
      final reason = _unsupportedReason(book);
      if (reason != null) {
        await sharedState.recordImport(
            source: 'tb_notes',
            sourceKey: sourceKey,
            status: 'unsupported',
            detail: reason);
        result.unsupported++;
        continue;
      }
      final fingerprint = canonicalMd5Fingerprint(book.md5);
      final sharedId =
          uuid.v5(Namespace.url.value, 'anx:tb_notes:$fingerprint:$sourceKey');
      final existing = await sharedState.annotationDocument(fingerprint) ??
          {
            'schemaVersion': 2,
            'book': {'fingerprintAlgorithm': 'md5', 'fingerprint': fingerprint},
            'annotations': <Object>[],
          };
      final annotations =
          (existing['annotations'] as List).cast<Map<String, dynamic>>();
      if (!annotations.any((item) => item['id'] == sharedId)) {
        annotations.add(_annotation(note, sharedId));
        annotations
            .sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
        await sharedState.putAnnotationDocument(existing);
      }
      // Canonical persistence precedes native projection identity. A crash here is
      // repaired deterministically by the same UUID on the next bootstrap.
      await notes.bindSharedAnnotation(note.id!, sharedId);
      await sharedState.recordImport(
          source: 'tb_notes',
          sourceKey: sourceKey,
          sharedId: sharedId,
          status: 'materialized');
      result.imported++;
    }
    return result;
  }

  String? _unsupportedReason(Book book) {
    final extension = p.extension(book.filePath).toLowerCase();
    if (extension != '.epub') return 'unbound format $extension';
    try {
      canonicalMd5Fingerprint(book.md5);
    } on AnnotationProtocolException {
      return 'invalid MD5 fingerprint';
    }
    return null;
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
        'updatedAt': updated
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
          {'type': 'epub-cfi', 'cfi': note.cfi}
        ],
      },
      'enrichments': enrichments,
    };
  }
}
