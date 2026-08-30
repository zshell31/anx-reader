import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/service/sync/annotation_protocol.dart';
import 'package:anx_reader/service/sync/annotation_read_model.dart';
import 'package:anx_reader/service/sync/annotation_repository.dart';
import 'package:anx_reader/service/sync/shared_state_database.dart';

/// Canonical annotations for one protocol-v2 book document, with an optional
/// local catalog binding. Remote-only documents deliberately remain readable.
class AnnotationBookUiModel {
  final String fingerprint;
  final String title;
  final String author;
  final Book? localBook;
  final List<AnnotationUiModel> annotations;

  const AnnotationBookUiModel({
    required this.fingerprint,
    required this.title,
    required this.author,
    required this.localBook,
    required this.annotations,
  });

  bool get isBound => localBook != null;
}

/// One-way application read service over canonical annotation documents.
class CanonicalAnnotationCatalog {
  final SharedStateDatabase sharedState;
  final Future<List<Book>> Function() loadLocalBooks;

  const CanonicalAnnotationCatalog(
    this.sharedState, {
    required this.loadLocalBooks,
  });

  Future<List<AnnotationBookUiModel>> readAll() async {
    final documents = await sharedState.annotationDocuments();
    final presentations = await sharedState.annotationPresentations();
    final books = await loadLocalBooks();
    final booksByFingerprint = <String, Book>{};
    for (final book in books) {
      final fingerprint = _validFingerprint(book.md5);
      if (fingerprint != null && !book.isDeleted) {
        booksByFingerprint.putIfAbsent(fingerprint, () => book);
      }
    }

    final result = <AnnotationBookUiModel>[];
    for (final document in documents) {
      final metadata = document['book'] as Map<String, dynamic>;
      final fingerprint = canonicalMd5Fingerprint(metadata['fingerprint']);
      final localBook = booksByFingerprint[fingerprint];
      final annotations = CanonicalAnnotationReadAdapter(
        presentations: presentations,
        localBookAvailable: (_) => localBook != null,
      ).read(document);
      if (annotations.isEmpty) continue;
      result.add(AnnotationBookUiModel(
        fingerprint: fingerprint,
        title:
            _metadataText(metadata['title']) ?? localBook?.title ?? fingerprint,
        author: _metadataText(metadata['author']) ?? localBook?.author ?? '',
        localBook: localBook,
        annotations: annotations,
      ));
    }
    result.sort((left, right) => left.title.compareTo(right.title));
    return List.unmodifiable(result);
  }

  Future<AnnotationBookUiModel?> readBook(String fingerprint) async {
    final normalized = canonicalMd5Fingerprint(fingerprint);
    final document = await sharedState.annotationDocument(normalized);
    if (document == null) return null;
    final presentations = await sharedState.annotationPresentations();
    final books = await loadLocalBooks();
    Book? localBook;
    for (final book in books) {
      if (!book.isDeleted && _validFingerprint(book.md5) == normalized) {
        localBook = book;
        break;
      }
    }
    final metadata = document['book'] as Map<String, dynamic>;
    return AnnotationBookUiModel(
      fingerprint: normalized,
      title: _metadataText(metadata['title']) ?? localBook?.title ?? normalized,
      author: _metadataText(metadata['author']) ?? localBook?.author ?? '',
      localBook: localBook,
      annotations: CanonicalAnnotationReadAdapter(
        presentations: presentations,
        localBookAvailable: (_) => localBook != null,
      ).read(document),
    );
  }
}

String? _validFingerprint(String? value) {
  try {
    return canonicalMd5Fingerprint(value);
  } on Object {
    return null;
  }
}

String? _metadataText(Object? value) {
  if (value is! String || value.trim().isEmpty) return null;
  return value.trim();
}

final canonicalAnnotationCatalog = CanonicalAnnotationCatalog(
  annotationRepository.sharedState,
  loadLocalBooks: bookDao.selectBooks,
);
