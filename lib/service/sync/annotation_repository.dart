import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/service/sync/annotation_protocol.dart';
import 'package:anx_reader/service/sync/annotation_read_model.dart';
import 'package:anx_reader/service/sync/annotation_sync_runtime.dart';
import 'package:anx_reader/service/sync/shared_state_database.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

class CanonicalSelectionCreation {
  final Book book;
  final String selectedText;
  final String epubCfi;
  final String chapter;
  final String? context;

  const CanonicalSelectionCreation({
    required this.book,
    required this.selectedText,
    required this.epubCfi,
    required this.chapter,
    required this.context,
  });
}

class AiThreadMessageInput {
  final String role;
  final String content;

  const AiThreadMessageInput({required this.role, required this.content});
}

class BookmarkCreation {
  final Book book;
  final String content;
  final String epubCfi;
  final String chapter;
  final double percentage;

  const BookmarkCreation({
    required this.book,
    required this.content,
    required this.epubCfi,
    required this.chapter,
    required this.percentage,
  });
}

/// The production boundary between UI/Foliate and shared annotations.
///
/// Semantic mutations commit canonical documents before notifying UI/renderer
/// listeners. Presentation mutations write only the independent synchronized
/// Anx presentation domain.
class AnnotationRepository {
  final SharedStateDatabase sharedState;
  final Uuid uuid;
  final DateTime Function() now;
  final void Function(String fingerprint)? onCanonicalMutation;
  final void Function()? onPresentationMutation;
  Future<void> _serial = Future<void>.value();

  AnnotationRepository(
    this.sharedState, {
    Uuid? uuid,
    DateTime Function()? now,
    this.onCanonicalMutation,
    this.onPresentationMutation,
  })  : uuid = uuid ?? const Uuid(),
        now = now ?? DateTime.now;

  Future<T> _enqueue<T>(Future<T> Function() operation) {
    final next = _serial.then((_) => operation());
    _serial = next.then<void>((_) {}, onError: (_, __) {});
    return next;
  }

  Future<AnnotationRef> createAnnotation(CanonicalSelectionCreation input) =>
      _enqueue(() => _createCanonicalAnnotation(input));

  Future<AnnotationRef> createAnnotationWithTranslation(
          CanonicalSelectionCreation input, String content) =>
      _enqueue(() => _createCanonicalAnnotation(input,
          firstMaterialKind: 'translation', firstContent: content.trim()));

  Future<AnnotationRef> createAnnotationWithPersonalNote(
          CanonicalSelectionCreation input, String content) =>
      _enqueue(() =>
          _createCanonicalAnnotation(input, firstPersonalNote: content.trim()));

  Future<AnnotationRef> saveTranslation(AnnotationRef ref, String content) =>
      _enqueue(() => _saveMaterial(ref, 'translation', content));

  Future<AnnotationRef> saveDictionaryResult(
          AnnotationRef ref, String content) =>
      _enqueue(() => _saveMaterial(ref, 'dictionary', content));

  Future<AnnotationRef> saveAiAnalysis(AnnotationRef ref, String content) =>
      _enqueue(() => _saveMaterial(ref, 'ai-analysis', content));

  Future<AnnotationRef> saveAiThread(
          AnnotationRef ref, Iterable<AiThreadMessageInput> messages,
          {Iterable<String> enrichmentIds = const []}) =>
      _enqueue(
          () => _saveAiThread(ref, messages, enrichmentIds: enrichmentIds));

  Future<AnnotationRef> setPersonalNote(AnnotationRef ref, String value) =>
      _enqueue(() => _setPersonalNoteByRef(ref, value.trim()));

  Future<AnnotationRef> tombstoneAnnotation(AnnotationRef ref) =>
      _enqueue(() => _tombstoneByRef(ref));

  Future<AnnotationRef> updatePresentation(
          AnnotationRef ref, String type, String color) =>
      _enqueue(() => _updatePresentationByRef(ref, type, color));

  Future<AnnotationRef> createBookmark(BookmarkCreation input) =>
      _enqueue(() async {
        final fingerprint = _fingerprint(input.book);
        _epubCfi(input.epubCfi);
        final timestamp = canonicalWireTimestamp(now());
        final annotationId = uuid.v4();
        final document = await _document(input.book, fingerprint);
        (document['annotations'] as List).add(<String, dynamic>{
          'id': annotationId,
          'motivation': 'bookmark',
          'createdAt': timestamp,
          'updatedAt': timestamp,
          'target': {
            'selectedText': input.content,
            'chapter': input.chapter,
            'selectors': [
              {'type': 'epub-cfi', 'cfi': input.epubCfi.trim()}
            ],
          },
          'enrichments': <Object>[],
        });
        await _commit(fingerprint, document);
        return AnnotationRef(
          bookFingerprint: fingerprint,
          annotationId: annotationId,
        );
      });

  Future<AnnotationRef> _createCanonicalAnnotation(
      CanonicalSelectionCreation input,
      {String? firstMaterialKind,
      String? firstContent,
      String? firstPersonalNote}) async {
    final fingerprint = _fingerprint(input.book);
    _epubCfi(input.epubCfi);
    if (firstMaterialKind != null) {
      _validateMaterial(firstMaterialKind, firstContent ?? '');
    }
    if (firstPersonalNote != null && firstPersonalNote.isEmpty) {
      throw ArgumentError.value(
          firstPersonalNote, 'firstPersonalNote', 'must not be empty');
    }
    final timestamp = canonicalWireTimestamp(now());
    final annotationId = uuid.v4();
    final annotation = <String, dynamic>{
      'id': annotationId,
      'motivation': 'selection',
      'createdAt': timestamp,
      'updatedAt': timestamp,
      'target': <String, dynamic>{
        'selectedText': input.selectedText,
        'chapter': input.chapter,
        if (input.context?.trim().isNotEmpty == true) 'context': input.context,
        'selectors': [
          {'type': 'epub-cfi', 'cfi': input.epubCfi.trim()}
        ],
      },
      'enrichments': <Object>[
        if (firstMaterialKind != null)
          _materialEnrichment(
              firstMaterialKind, firstContent!.trim(), timestamp),
        if (firstPersonalNote?.isNotEmpty == true)
          <String, dynamic>{
            'id': 'personal-note:$annotationId',
            'kind': 'personal-note',
            'content': firstPersonalNote,
            'createdAt': timestamp,
            'updatedAt': timestamp,
          },
      ],
    };
    final document = await _document(input.book, fingerprint);
    (document['annotations'] as List).add(annotation);
    await _commit(fingerprint, document);
    return AnnotationRef(
        bookFingerprint: fingerprint, annotationId: annotationId);
  }

  Future<AnnotationRef> _saveMaterial(
      AnnotationRef ref, String kind, String content) async {
    final value = content.trim();
    _validateMaterial(kind, value);
    final binding = await _canonicalBindingByRef(ref);
    _ensureAlive(binding.annotation);
    final timestamp = _nextTimestamp(binding.annotation);
    (binding.annotation['enrichments'] as List)
        .add(_materialEnrichment(kind, value, timestamp));
    binding.annotation['updatedAt'] = timestamp;
    await _commit(binding.fingerprint, binding.document);
    return ref;
  }

  Map<String, dynamic> _materialEnrichment(
          String kind, String content, String timestamp) =>
      <String, dynamic>{
        'id': '$kind:${uuid.v4()}',
        'kind': kind,
        'content': content,
        'createdAt': timestamp,
        'updatedAt': timestamp,
      };

  void _validateMaterial(String kind, String content) {
    if (!const {'translation', 'dictionary', 'ai-analysis'}.contains(kind)) {
      throw ArgumentError.value(kind, 'kind', 'unsupported material kind');
    }
    if (content.trim().isEmpty) {
      throw ArgumentError.value(content, 'content', 'must not be empty');
    }
  }

  Future<AnnotationRef> _saveAiThread(
      AnnotationRef ref, Iterable<AiThreadMessageInput> input,
      {required Iterable<String> enrichmentIds}) async {
    final messages = input.toList(growable: false);
    if (messages.isEmpty) {
      throw ArgumentError.value(messages, 'messages', 'must not be empty');
    }
    final binding = await _canonicalBindingByRef(ref);
    _ensureAlive(binding.annotation);
    final timestamp = _nextTimestamp(binding.annotation);
    final selectedText =
        (binding.annotation['target'] as Map)['selectedText'] as String;
    (binding.annotation['enrichments'] as List).add(<String, dynamic>{
      'id': 'ai-thread:${uuid.v4()}',
      'kind': 'ai-thread',
      'createdAt': timestamp,
      'updatedAt': timestamp,
      'contextSnapshot': {
        'selectedText': selectedText,
        'enrichmentIds': enrichmentIds.toList(growable: false),
      },
      'messages': [
        for (var index = 0; index < messages.length; index++)
          <String, dynamic>{
            'id': 'ai-message:${uuid.v4()}',
            'role': messages[index].role,
            'sequence': index,
            'content': messages[index].content,
            'createdAt': timestamp,
            'updatedAt': timestamp,
          },
      ],
    });
    binding.annotation['updatedAt'] = timestamp;
    await _commit(binding.fingerprint, binding.document);
    return ref;
  }

  Future<AnnotationRef> _setPersonalNoteByRef(
      AnnotationRef ref, String value) async {
    final binding = await _canonicalBindingByRef(ref);
    final annotation = binding.annotation;
    _ensureAlive(annotation);
    final enrichments =
        (annotation['enrichments'] as List).cast<Map<String, dynamic>>();
    final personal = enrichments
        .where((item) => item['kind'] == 'personal-note')
        .toList()
      ..sort(compareCanonicalEntityRecency);
    final timestamp = _nextTimestamp(annotation, after: personal);
    final deterministicId = 'personal-note:${binding.annotationId}';
    final owned = personal
        .where((item) =>
            item['id'] == deterministicId ||
            (item['id'] as String).startsWith('$deterministicId:'))
        .toList()
      ..sort(compareCanonicalEntityRecency);
    var winner = owned.isEmpty ? null : owned.last;
    if (value.isEmpty) {
      winner ??= <String, dynamic>{
        'id': deterministicId,
        'kind': 'personal-note',
        'content': '',
        'createdAt': timestamp,
        'updatedAt': timestamp,
      };
      if (!enrichments.contains(winner)) enrichments.add(winner);
      winner['content'] = '';
      winner['updatedAt'] = timestamp;
      winner['deletedAt'] = timestamp;
    } else if (winner == null || winner.containsKey('deletedAt')) {
      final idAvailable =
          !enrichments.any((item) => item['id'] == deterministicId);
      enrichments.add(<String, dynamic>{
        'id': idAvailable ? deterministicId : '$deterministicId:${uuid.v4()}',
        'kind': 'personal-note',
        'content': value,
        'createdAt': timestamp,
        'updatedAt': timestamp,
      });
    } else {
      winner['content'] = value;
      winner['updatedAt'] = timestamp;
    }
    annotation['updatedAt'] = timestamp;
    await _commit(binding.fingerprint, binding.document);
    return ref;
  }

  Future<AnnotationRef> _tombstoneByRef(AnnotationRef ref) async {
    final binding = await _canonicalBindingByRef(ref);
    final annotation = binding.annotation;
    if (!annotation.containsKey('deletedAt')) {
      final timestamp = _nextTimestamp(annotation);
      annotation['updatedAt'] = timestamp;
      annotation['deletedAt'] = timestamp;
      await _commit(binding.fingerprint, binding.document);
    }
    await _resetPresentation(ref.annotationId);
    return ref;
  }

  Future<AnnotationRef> _updatePresentationByRef(
      AnnotationRef ref, String type, String color) async {
    final binding = await _canonicalBindingByRef(ref);
    _ensureAlive(binding.annotation);
    if (binding.annotation['motivation'] != 'selection') {
      throw ArgumentError('Bookmark motivation is not presentation');
    }
    if (type != 'highlight' && type != 'underline') {
      throw ArgumentError.value(type, 'type', 'must be highlight or underline');
    }
    await _putPresentation(AnnotationPresentation(
      annotationId: ref.annotationId,
      style: type == 'underline'
          ? AnnotationPresentationStyle.underline
          : AnnotationPresentationStyle.highlight,
      color: color,
    ));
    return ref;
  }

  Future<_CanonicalBinding> _canonicalBindingByRef(AnnotationRef ref) async {
    final document = await sharedState.annotationDocument(ref.bookFingerprint);
    if (document == null) {
      throw StateError('Canonical annotation document was not found');
    }
    final annotations =
        (document['annotations'] as List).cast<Map<String, dynamic>>();
    final matches =
        annotations.where((value) => value['id'] == ref.annotationId).toList();
    if (matches.length != 1) {
      throw StateError(
          'Canonical annotation ${ref.annotationId} was not found');
    }
    return _CanonicalBinding(
        ref.bookFingerprint, ref.annotationId, document, matches.single);
  }

  Future<Map<String, dynamic>> _document(Book book, String fingerprint) async {
    final document = await sharedState.annotationDocument(fingerprint) ??
        <String, dynamic>{
          'schemaVersion': 2,
          'book': {
            'fingerprintAlgorithm': 'md5',
            'fingerprint': fingerprint,
          },
          'annotations': <Object>[],
        };
    applyAnnotationBookMetadata(document,
        title: book.title, author: book.author);
    return document;
  }

  Future<void> _commit(
      String fingerprint, Map<String, dynamic> document) async {
    await sharedState.putAnnotationDocument(document);
    onCanonicalMutation?.call(fingerprint);
  }

  String _fingerprint(Book book) {
    if (p.extension(book.filePath).toLowerCase() != '.epub') {
      throw UnsupportedError('Only EPUB annotations are protocol-v2 capable');
    }
    return canonicalMd5Fingerprint(book.md5);
  }

  void _epubCfi(String value) {
    final cfi = value.trim();
    if (!cfi.startsWith('epubcfi(') || !cfi.endsWith(')') || cfi.length <= 9) {
      throw ArgumentError.value(value, 'epubCfi', 'must be a genuine EPUB CFI');
    }
  }

  void _ensureAlive(Map<String, dynamic> annotation) {
    if (isProtocolEntityTombstoned(annotation)) {
      throw StateError('Cannot edit a tombstoned annotation');
    }
  }

  String _nextTimestamp(Map<String, dynamic> annotation,
      {Iterable<Map<String, dynamic>> after = const []}) {
    var candidate = now().toUtc();
    var previous = DateTime.parse(annotation['updatedAt'] as String).toUtc();
    for (final entity in after) {
      final entityTime = DateTime.parse(entity['updatedAt'] as String).toUtc();
      if (entityTime.isAfter(previous)) previous = entityTime;
    }
    if (!candidate.isAfter(previous)) {
      candidate = previous.add(const Duration(milliseconds: 1));
    }
    return canonicalWireTimestamp(candidate);
  }

  Future<void> _putPresentation(AnnotationPresentation presentation) async {
    if (await sharedState.putAnnotationPresentation(presentation)) {
      onPresentationMutation?.call();
    }
  }

  Future<void> _resetPresentation(String annotationId) async {
    if (await sharedState.deleteAnnotationPresentation(annotationId)) {
      onPresentationMutation?.call();
    }
  }
}

class _CanonicalBinding {
  final String fingerprint;
  final String annotationId;
  final Map<String, dynamic> document;
  final Map<String, dynamic> annotation;

  const _CanonicalBinding(
      this.fingerprint, this.annotationId, this.document, this.annotation);
}

final annotationRepository = AnnotationRepository(
  SharedStateDatabase(),
  onCanonicalMutation: annotationSyncRuntime.notifyLocalMutation,
  onPresentationMutation: annotationSyncRuntime.notifyPresentationMutation,
);
