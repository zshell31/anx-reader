import 'dart:async';

import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/models/book_note.dart';
import 'package:anx_reader/service/sync/annotation_projection_reconciler.dart';
import 'package:anx_reader/service/sync/annotation_protocol.dart';
import 'package:anx_reader/service/sync/annotation_read_model.dart';
import 'package:anx_reader/service/sync/annotation_sync_runtime.dart';
import 'package:anx_reader/service/sync/native_annotation_projection.dart';
import 'package:anx_reader/service/sync/shared_state_database.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

/// A canonical mutation was committed, but its lossy BookNote projection did
/// not materialize. The mutation must not be rolled back: startup
/// reconciliation will retry it from shared state.
class AnnotationProjectionException implements Exception {
  final String annotationId;
  final Object? cause;

  const AnnotationProjectionException(this.annotationId, [this.cause]);

  @override
  String toString() =>
      'Canonical annotation $annotationId is durable, but projection failed'
      '${cause == null ? '' : ': $cause'}';
}

/// Editing the quoted excerpt is intentionally unsupported.
///
/// BookNote.content used to look like an editable note, but it is the selected
/// source text. Changing it alone would make the CFI, context, and any portable
/// quote selector describe different source content. Personal commentary stays
/// editable through the personal-note enrichment instead.
class AnnotationExcerptEditUnsupported implements Exception {
  const AnnotationExcerptEditUnsupported();

  @override
  String toString() => 'Selected source text cannot be edited independently';
}

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

/// A successful canonical mutation and the independent compatibility refresh
/// outcome that followed it. [rendererRefreshFailure] never means the
/// canonical mutation failed or was rolled back.
class AnnotationMutationResult {
  final AnnotationRef ref;
  final BookNote? compatibilityProjection;
  final AnnotationProjectionException? rendererRefreshFailure;

  const AnnotationMutationResult({
    required this.ref,
    required this.compatibilityProjection,
    required this.rendererRefreshFailure,
  });

  bool get rendererRefreshSucceeded => rendererRefreshFailure == null;
}

class AnnotationCreation {
  final Book book;
  final String selectedText;
  final String epubCfi;
  final String chapter;
  final String? context;
  final String type;
  final String color;
  final bool persistPresentation;

  const AnnotationCreation({
    required this.book,
    required this.selectedText,
    required this.epubCfi,
    required this.chapter,
    required this.context,
    required this.type,
    required this.color,
    this.persistPresentation = true,
  });
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
/// Ownership is deliberately split:
///
/// * shared semantic operations patch the current canonical entity, commit the
///   document plus dirty revision, and only then materialize BookNote;
/// * highlight/underline and color are client-local presentation and update
///   only BookNote, without touching canonical bytes or the outbox;
/// * BookNote.content is a lossy projection of selectedText and is read-only.
class AnnotationRepository {
  final SharedStateDatabase sharedState;
  final NativeAnnotationProjectionStore native;
  final Uuid uuid;
  final DateTime Function() now;
  final void Function(String fingerprint)? onCanonicalMutation;
  final void Function()? onPresentationMutation;
  late final AnnotationProjectionReconciler _reconciler;
  Future<void> _serial = Future<void>.value();

  AnnotationRepository(
    this.sharedState, {
    NativeAnnotationProjectionStore? native,
    Uuid? uuid,
    DateTime Function()? now,
    this.onCanonicalMutation,
    this.onPresentationMutation,
    AnnotationProjectionReconciler? reconciler,
    NativeAnnotationDefaults Function()? projectionDefaults,
  })  : native = native ?? DaoNativeAnnotationProjectionStore(),
        uuid = uuid ?? const Uuid(),
        now = now ?? DateTime.now {
    _reconciler = reconciler ??
        AnnotationProjectionReconciler(sharedState,
            native: this.native, defaults: projectionDefaults);
  }

  Future<T> _enqueue<T>(Future<T> Function() operation) {
    final next = _serial.then((_) => operation());
    _serial = next.then<void>((_) {}, onError: (_, __) {});
    return next;
  }

  Future<AnnotationMutationResult> createAnnotation(
          CanonicalSelectionCreation input) =>
      _enqueue(() => _createCanonicalAnnotation(input));

  Future<AnnotationMutationResult> createAnnotationWithTranslation(
          CanonicalSelectionCreation input, String content) =>
      _enqueue(() => _createCanonicalAnnotation(input,
          firstMaterialKind: 'translation', firstContent: content.trim()));

  Future<AnnotationMutationResult> createAnnotationWithPersonalNote(
          CanonicalSelectionCreation input, String content) =>
      _enqueue(() =>
          _createCanonicalAnnotation(input, firstPersonalNote: content.trim()));

  Future<AnnotationMutationResult> saveTranslation(
          AnnotationRef ref, String content) =>
      _enqueue(() => _saveMaterial(ref, 'translation', content));

  Future<AnnotationMutationResult> saveDictionaryResult(
          AnnotationRef ref, String content) =>
      _enqueue(() => _saveMaterial(ref, 'dictionary', content));

  Future<AnnotationMutationResult> saveAiAnalysis(
          AnnotationRef ref, String content) =>
      _enqueue(() => _saveMaterial(ref, 'ai-analysis', content));

  Future<AnnotationMutationResult> saveAiThread(
          AnnotationRef ref, Iterable<AiThreadMessageInput> messages,
          {Iterable<String> enrichmentIds = const []}) =>
      _enqueue(
          () => _saveAiThread(ref, messages, enrichmentIds: enrichmentIds));

  Future<AnnotationMutationResult> setPersonalNote(
          AnnotationRef ref, String value) =>
      _enqueue(() => _setPersonalNoteByRef(ref, value.trim()));

  Future<AnnotationMutationResult> tombstoneAnnotation(AnnotationRef ref) =>
      _enqueue(() => _tombstoneByRef(ref));

  Future<AnnotationMutationResult> updatePresentation(
          AnnotationRef ref, String type, String color) =>
      _enqueue(() => _updatePresentationByRef(ref, type, color));

  /// Compatibility API for BookNote consumers not yet migrated to
  /// [createAnnotation]. Do not add new callers.
  Future<BookNote> createSelectionAnnotation(AnnotationCreation input) =>
      _enqueue(() async {
        final fingerprint = _fingerprint(input.book);
        _epubCfi(input.epubCfi);
        final timestamp = canonicalWireTimestamp(now());
        final annotationId = uuid.v4();
        final target = <String, dynamic>{
          'selectedText': input.selectedText,
          'chapter': input.chapter,
          if (input.context?.trim().isNotEmpty == true)
            'context': input.context,
          'selectors': [
            {'type': 'epub-cfi', 'cfi': input.epubCfi.trim()}
          ],
        };
        final annotation = <String, dynamic>{
          'id': annotationId,
          'motivation': 'selection',
          'createdAt': timestamp,
          'updatedAt': timestamp,
          'target': target,
          'enrichments': <Object>[],
        };
        final document = await _document(input.book, fingerprint);
        (document['annotations'] as List).add(annotation);

        final presentation = BookNote(
          bookId: input.book.id,
          content: input.selectedText,
          cfi: input.epubCfi.trim(),
          chapter: input.chapter,
          type: input.type == 'underline' ? 'underline' : 'highlight',
          color: input.color,
          sharedAnnotationId: annotationId,
          createTime: DateTime.parse(timestamp),
          updateTime: DateTime.parse(timestamp),
        );
        await _commit(fingerprint, document);
        if (input.persistPresentation) {
          await _putPresentation(AnnotationPresentation(
            annotationId: annotationId,
            style: input.type == 'underline'
                ? AnnotationPresentationStyle.underline
                : AnnotationPresentationStyle.highlight,
            color: input.color,
          ));
        }
        return (await _project(fingerprint, annotationId,
            localPresentation:
                input.persistPresentation ? presentation : null))!;
      });

  /// Resolves the canonical identity of a legacy renderer/UI handle.
  ///
  /// This compatibility read exists only while remaining consumers still
  /// receive native BookNote IDs. New semantic mutations must retain the
  /// returned [AnnotationRef] instead of searching by selector/CFI.
  Future<AnnotationRef> annotationRefForNativeId(int nativeNoteId) async {
    final existing = await native.readProjection(nativeNoteId);
    final binding = await _canonicalBinding(existing);
    return AnnotationRef(
      bookFingerprint: binding.fingerprint,
      annotationId: binding.annotationId,
    );
  }

  /// M4E.6 compatibility entrypoint. M4E.7 replaces its native identity with
  /// a canonical AnnotationRef mutation API.
  Future<BookNote> saveTranslationForNativeId(
          int nativeNoteId, String content) =>
      _enqueue(() async {
        final existing = await native.readProjection(nativeNoteId);
        return _appendMaterialEnrichment(
            existing, 'translation', content.trim());
      });

  Future<AnnotationMutationResult> createBookmark(BookmarkCreation input) =>
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
        return _refreshCanonical(AnnotationRef(
          bookFingerprint: fingerprint,
          annotationId: annotationId,
        ));
      });

  /// Compatibility API for remaining native-ID UI consumers.
  Future<BookNote> setPersonalNoteForNativeId(int nativeNoteId, String value) =>
      _enqueue(() async {
        final existing = await native.readProjection(nativeNoteId);
        return _setPersonalNote(existing, value.trim());
      });

  /// Applies the notes-page edit. Selected text is immutable; personal-note
  /// changes are canonical-first, while type/color-only edits stay local.
  /// Compatibility API for the pre-M4E Notes UI.
  Future<BookNote> updateNativeAnnotation(BookNote proposed) =>
      _enqueue(() async {
        final nativeId = proposed.id;
        if (nativeId == null) throw ArgumentError.notNull('proposed.id');
        final existing = await native.readProjection(nativeId);
        if (proposed.content != existing.content) {
          throw const AnnotationExcerptEditUnsupported();
        }
        if (existing.type == 'bookmark' || proposed.type == 'bookmark') {
          if (existing.type != proposed.type) {
            throw ArgumentError('Bookmark motivation is not presentation');
          }
        }
        if ((proposed.readerNote ?? '') != (existing.readerNote ?? '')) {
          return _setPersonalNote(existing, proposed.readerNote?.trim() ?? '',
              localPresentation: proposed);
        }
        return _updatePresentation(existing, proposed.type, proposed.color);
      });

  /// Compatibility API for remaining native-ID presentation consumers.
  Future<BookNote> updatePresentationForNativeId(
          int nativeNoteId, String type, String color) =>
      _enqueue(() async {
        final existing = await native.readProjection(nativeNoteId);
        return _updatePresentation(existing, type, color);
      });

  /// Compatibility API for remaining BookNote deletion consumers.
  Future<void> tombstoneAnnotationForBookNote(BookNote note) =>
      _enqueue(() => _tombstoneAnnotation(note));

  /// Compatibility bulk API for the pre-M4E Notes UI.
  Future<void> tombstoneAnnotations(Iterable<BookNote> notes) =>
      _enqueue(() async {
        AnnotationProjectionException? projectionFailure;
        for (final note in notes) {
          try {
            await _tombstoneAnnotation(note);
          } on AnnotationProjectionException catch (error) {
            projectionFailure ??= error;
          }
        }
        if (projectionFailure != null) throw projectionFailure;
      });

  Future<AnnotationMutationResult> _createCanonicalAnnotation(
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
    return _refreshCanonical(AnnotationRef(
        bookFingerprint: fingerprint, annotationId: annotationId));
  }

  Future<AnnotationMutationResult> _saveMaterial(
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
    return _refreshCanonical(ref);
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

  Future<AnnotationMutationResult> _saveAiThread(
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
    return _refreshCanonical(ref);
  }

  Future<AnnotationMutationResult> _setPersonalNoteByRef(
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
    return _refreshCanonical(ref);
  }

  Future<AnnotationMutationResult> _tombstoneByRef(AnnotationRef ref) async {
    final binding = await _canonicalBindingByRef(ref);
    final annotation = binding.annotation;
    if (!annotation.containsKey('deletedAt')) {
      final timestamp = _nextTimestamp(annotation);
      annotation['updatedAt'] = timestamp;
      annotation['deletedAt'] = timestamp;
      await _commit(binding.fingerprint, binding.document);
    }
    await _resetPresentation(ref.annotationId);
    return _refreshCanonical(ref);
  }

  Future<AnnotationMutationResult> _updatePresentationByRef(
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
    return _refreshCanonical(ref);
  }

  Future<AnnotationMutationResult> _refreshCanonical(AnnotationRef ref) async {
    try {
      final result = await _reconciler.reconcileAnnotation(
          ref.bookFingerprint, ref.annotationId,
          migrateLegacyPresentation: false);
      if (result.errors != 0) {
        throw AnnotationProjectionException(ref.annotationId);
      }
      return AnnotationMutationResult(
        ref: ref,
        compatibilityProjection:
            await native.findBySharedAnnotationId(ref.annotationId),
        rendererRefreshFailure: null,
      );
    } catch (error) {
      final failure = error is AnnotationProjectionException
          ? error
          : AnnotationProjectionException(ref.annotationId, error);
      AnxLog.warning(failure.toString());
      return AnnotationMutationResult(
        ref: ref,
        compatibilityProjection: null,
        rendererRefreshFailure: failure,
      );
    }
  }

  Future<BookNote> _setPersonalNote(BookNote existing, String value,
      {BookNote? localPresentation}) async {
    final binding = await _canonicalBinding(existing);
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
    final ownedNotes = personal
        .where((item) =>
            item['id'] == deterministicId ||
            (item['id'] as String).startsWith('$deterministicId:'))
        .toList()
      ..sort(compareCanonicalEntityRecency);
    final ownedWinner = ownedNotes.isEmpty ? null : ownedNotes.last;

    if (value.isEmpty) {
      final owned = ownedWinner ??
          <String, dynamic>{
            'id': deterministicId,
            'kind': 'personal-note',
            'content': '',
            'createdAt': timestamp,
            'updatedAt': timestamp,
          };
      if (ownedWinner == null) enrichments.add(owned);
      owned['content'] = '';
      owned['updatedAt'] = timestamp;
      owned['deletedAt'] = timestamp;
    } else {
      Map<String, dynamic>? owned = ownedWinner;
      if (owned == null || owned.containsKey('deletedAt')) {
        final deterministicAvailable =
            !enrichments.any((item) => item['id'] == deterministicId);
        owned = <String, dynamic>{
          'id': deterministicAvailable
              ? deterministicId
              : '$deterministicId:${uuid.v4()}',
          'kind': 'personal-note',
          'content': value,
          'createdAt': timestamp,
          'updatedAt': timestamp,
        };
        enrichments.add(owned);
      } else {
        owned['content'] = value;
        owned['updatedAt'] = timestamp;
      }
    }
    annotation['updatedAt'] = timestamp;
    await _commit(binding.fingerprint, binding.document);
    if (localPresentation == null) {
      final updated = BookNote(
        id: existing.id,
        bookId: existing.bookId,
        content: existing.content,
        cfi: existing.cfi,
        chapter: existing.chapter,
        type: existing.type,
        color: existing.color,
        readerNote: value.isEmpty ? null : value,
        sharedAnnotationId: existing.sharedAnnotationId,
        createTime: existing.createTime,
        updateTime: DateTime.parse(timestamp),
      );
      try {
        await native.updateProjection(updated);
        return updated;
      } catch (error) {
        final failure =
            AnnotationProjectionException(binding.annotationId, error);
        AnxLog.warning(failure.toString());
        throw failure;
      }
    }
    return (await _project(binding.fingerprint, binding.annotationId,
        localPresentation: localPresentation))!;
  }

  Future<BookNote> _appendMaterialEnrichment(
      BookNote existing, String kind, String content) async {
    if (!const {'translation', 'dictionary', 'ai-analysis'}.contains(kind)) {
      throw ArgumentError.value(kind, 'kind', 'unsupported material kind');
    }
    if (content.isEmpty) {
      throw ArgumentError.value(content, 'content', 'must not be empty');
    }
    final binding = await _canonicalBinding(existing);
    final annotation = binding.annotation;
    _ensureAlive(annotation);
    final timestamp = _nextTimestamp(annotation);
    (annotation['enrichments'] as List).add(<String, dynamic>{
      'id': '$kind:${uuid.v4()}',
      'kind': kind,
      'content': content,
      'createdAt': timestamp,
      'updatedAt': timestamp,
    });
    annotation['updatedAt'] = timestamp;
    await _commit(binding.fingerprint, binding.document);
    // Material enrichments do not change the legacy BookNote projection.
    // Returning it directly also avoids mistaking its effective default style
    // for an explicitly chosen presentation during compatibility migration.
    return existing;
  }

  Future<BookNote> _updatePresentation(
      BookNote existing, String type, String color) async {
    if (existing.type == 'bookmark') {
      if (type != 'bookmark') {
        throw ArgumentError('Bookmark motivation is not presentation');
      }
    } else if (type != 'highlight' && type != 'underline') {
      throw ArgumentError.value(type, 'type', 'must be highlight or underline');
    }
    final updated = BookNote(
      id: existing.id,
      bookId: existing.bookId,
      content: existing.content,
      cfi: existing.cfi,
      chapter: existing.chapter,
      type: type,
      color: color,
      readerNote: existing.readerNote,
      sharedAnnotationId: existing.sharedAnnotationId,
      createTime: existing.createTime,
      // Presentation does not advance semantic projection time.
      updateTime: existing.updateTime,
    );
    if (existing.type != 'bookmark') {
      final annotationId = existing.sharedAnnotationId;
      if (annotationId == null || annotationId.isEmpty) {
        throw StateError('Presentation is not bound to canonical annotation');
      }
      await _putPresentation(AnnotationPresentation(
        annotationId: annotationId,
        style: type == 'underline'
            ? AnnotationPresentationStyle.underline
            : AnnotationPresentationStyle.highlight,
        color: color,
      ));
    }
    await native.updateProjection(updated);
    return updated;
  }

  Future<void> _tombstoneAnnotation(BookNote note) async {
    final binding = await _canonicalBinding(note);
    final annotation = binding.annotation;
    if (!annotation.containsKey('deletedAt')) {
      final timestamp = _nextTimestamp(annotation);
      annotation['updatedAt'] = timestamp;
      annotation['deletedAt'] = timestamp;
      await _commit(binding.fingerprint, binding.document);
    }
    await _resetPresentation(binding.annotationId);
    await _project(binding.fingerprint, binding.annotationId);
  }

  Future<_CanonicalBinding> _canonicalBinding(BookNote note) async {
    final annotationId = note.sharedAnnotationId;
    if (annotationId == null || annotationId.isEmpty) {
      throw StateError('Semantic annotation is not bound to canonical state');
    }
    final book = await native.readBook(note.bookId);
    if (book == null) throw StateError('Book ${note.bookId} was not found');
    final fingerprint = _fingerprint(book);
    final document = await sharedState.annotationDocument(fingerprint);
    if (document == null) {
      throw StateError('Canonical annotation document was not found');
    }
    final annotations =
        (document['annotations'] as List).cast<Map<String, dynamic>>();
    final matches =
        annotations.where((value) => value['id'] == annotationId).toList();
    if (matches.length != 1) {
      throw StateError('Canonical annotation $annotationId was not found');
    }
    return _CanonicalBinding(
        fingerprint, annotationId, document, matches.single);
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

  Future<BookNote?> _project(String fingerprint, String annotationId,
      {BookNote? localPresentation}) async {
    try {
      final result = await _reconciler.reconcileAnnotation(
          fingerprint, annotationId,
          localPresentation: localPresentation);
      if (result.errors != 0) {
        throw AnnotationProjectionException(annotationId);
      }
      final projection = await native.findBySharedAnnotationId(annotationId);
      if (projection != null) return projection;

      // Tombstones deliberately have no native projection.
      final document = await sharedState.annotationDocument(fingerprint);
      final annotation = (document!['annotations'] as List)
          .cast<Map<String, dynamic>>()
          .singleWhere((value) => value['id'] == annotationId);
      if (annotation.containsKey('deletedAt')) return null;
      throw AnnotationProjectionException(annotationId);
    } on AnnotationProjectionException catch (error) {
      AnxLog.warning(error.toString());
      rethrow;
    } catch (error) {
      final failure = AnnotationProjectionException(annotationId, error);
      AnxLog.warning(failure.toString());
      throw failure;
    }
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
