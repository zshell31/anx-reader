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

class AnnotationEditorMaterialInput {
  final String? enrichmentId;
  final String providerId;
  final String providerName;
  final String kind;
  final String? translation;
  final String? markdown;
  final Map<String, String> commentary;
  final Map<String, String> metadata;

  const AnnotationEditorMaterialInput({
    this.enrichmentId,
    required this.providerId,
    required this.providerName,
    required this.kind,
    this.translation,
    this.markdown,
    this.commentary = const {},
    this.metadata = const {},
  });
}

class AnnotationEditorMessageInput {
  final String? messageId;
  final String role;
  final String content;
  final int sequence;
  final DateTime? createdAt;

  const AnnotationEditorMessageInput({
    this.messageId,
    required this.role,
    required this.content,
    required this.sequence,
    this.createdAt,
  });
}

class AnnotationEditorSaveInput {
  final CanonicalSelectionCreation? creation;
  final AnnotationRef? existingRef;
  final List<AnnotationEditorMaterialInput> materials;
  final String personalNote;
  final String? aiThreadId;
  final List<AnnotationEditorMessageInput> aiMessages;

  const AnnotationEditorSaveInput({
    this.creation,
    this.existingRef,
    this.materials = const [],
    this.personalNote = '',
    this.aiThreadId,
    this.aiMessages = const [],
  });
}

const _anxProviderId = 'anx-reader';
const _anxProviderName = 'Anx Reader';

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

  Future<AnnotationRef> saveAnnotationEditorDraft(
          AnnotationEditorSaveInput input) =>
      _enqueue(() => _saveAnnotationEditorDraft(input));

  Future<AnnotationRef> createAnnotationWithTranslation(
    CanonicalSelectionCreation input,
    String content, {
    String providerId = _anxProviderId,
    String providerName = _anxProviderName,
  }) =>
      _enqueue(() => _createCanonicalAnnotation(
            input,
            firstMaterial: (timestamp) => _translationEnrichment(
                content.trim(), timestamp,
                providerId: providerId, providerName: providerName),
          ));

  Future<AnnotationRef> createAnnotationWithPersonalNote(
          CanonicalSelectionCreation input, String content) =>
      _enqueue(() =>
          _createCanonicalAnnotation(input, firstPersonalNote: content.trim()));

  Future<AnnotationRef> saveTranslation(
    AnnotationRef ref,
    String content, {
    String providerId = _anxProviderId,
    String providerName = _anxProviderName,
  }) =>
      _enqueue(() => _saveMaterial(
            ref,
            (timestamp) => _translationEnrichment(
              content.trim(),
              timestamp,
              providerId: providerId,
              providerName: providerName,
            ),
          ));

  Future<AnnotationRef> saveDictionaryResult(
    AnnotationRef ref,
    String markdown, {
    String? translation,
    String providerId = _anxProviderId,
    String providerName = _anxProviderName,
    Map<String, String> metadata = const {},
  }) =>
      _enqueue(() => _saveMaterial(
            ref,
            (timestamp) => _dictionaryEnrichment(
              markdown.trim(),
              timestamp,
              translation: translation?.trim(),
              providerId: providerId,
              providerName: providerName,
              metadata: metadata,
            ),
          ));

  Future<AnnotationRef> saveAiAnalysis(
    AnnotationRef ref,
    String analysis, {
    String? translation,
    String? translationNotes,
    String? grammar,
    String? usage,
    String providerId = _anxProviderId,
    String providerName = _anxProviderName,
  }) =>
      _enqueue(() => _saveMaterial(
            ref,
            (timestamp) => _aiAnalysisEnrichment(
              analysis.trim(),
              timestamp,
              translation: translation?.trim(),
              translationNotes: translationNotes?.trim(),
              grammar: grammar?.trim(),
              usage: usage?.trim(),
              providerId: providerId,
              providerName: providerName,
            ),
          ));

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
        _bookmarkPercentage(input.percentage);
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
            'progress': {'fraction': input.percentage},
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
      {Map<String, dynamic> Function(String timestamp)? firstMaterial,
      String? firstPersonalNote}) async {
    final fingerprint = _fingerprint(input.book);
    _epubCfi(input.epubCfi);
    if (firstPersonalNote != null && firstPersonalNote.isEmpty) {
      throw ArgumentError.value(
          firstPersonalNote, 'firstPersonalNote', 'must not be empty');
    }
    final timestamp = canonicalWireTimestamp(now());
    final material = firstMaterial?.call(timestamp);
    if (material != null) _validateMaterial(material);
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
        if (material != null) material,
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

  Future<AnnotationRef> _saveAnnotationEditorDraft(
      AnnotationEditorSaveInput input) async {
    if ((input.creation == null) == (input.existingRef == null)) {
      throw ArgumentError(
        'Exactly one of creation or existingRef must be supplied',
      );
    }
    _validateEditorInput(input);
    final _CanonicalBinding binding;
    final AnnotationRef ref;
    if (input.existingRef case final existing?) {
      binding = await _canonicalBindingByRef(existing);
      _ensureAlive(binding.annotation);
      ref = existing;
    } else {
      final creation = input.creation!;
      final fingerprint = _fingerprint(creation.book);
      _epubCfi(creation.epubCfi);
      final timestamp = canonicalWireTimestamp(now());
      final annotationId = uuid.v4();
      final document = await _document(creation.book, fingerprint);
      final annotation = <String, dynamic>{
        'id': annotationId,
        'motivation': 'selection',
        'createdAt': timestamp,
        'updatedAt': timestamp,
        'target': <String, dynamic>{
          'selectedText': creation.selectedText,
          'chapter': creation.chapter,
          if (creation.context?.trim().isNotEmpty == true)
            'context': creation.context,
          'selectors': [
            {'type': 'epub-cfi', 'cfi': creation.epubCfi.trim()}
          ],
        },
        'enrichments': <Object>[],
      };
      (document['annotations'] as List).add(annotation);
      binding =
          _CanonicalBinding(fingerprint, annotationId, document, annotation);
      ref = AnnotationRef(
        bookFingerprint: fingerprint,
        annotationId: annotationId,
      );
    }

    final before = canonicalJson(binding.annotation);
    final enrichments = (binding.annotation['enrichments'] as List)
        .cast<Map<String, dynamic>>();
    final timestamp = _nextTimestamp(binding.annotation, after: enrichments);
    _reconcileEditorMaterials(enrichments, input.materials, timestamp);
    _reconcileEditorPersonalNote(
      enrichments,
      binding.annotationId,
      input.personalNote.trim(),
      timestamp,
    );
    _reconcileEditorThread(
      enrichments,
      binding.annotation,
      input.aiThreadId,
      input.aiMessages,
      timestamp,
    );
    final changed = canonicalJson(binding.annotation) != before;
    if (input.existingRef == null || changed) {
      binding.annotation['updatedAt'] = timestamp;
      await _commit(binding.fingerprint, binding.document);
    }
    return ref;
  }

  void _validateEditorInput(AnnotationEditorSaveInput input) {
    final slots = <String>{};
    for (final material in input.materials) {
      if (!const {'translation', 'dictionary', 'ai-analysis'}
          .contains(material.kind)) {
        throw ArgumentError.value(material.kind, 'kind');
      }
      final slot = _editorMaterialSlot(material.kind, material.providerId);
      if (!slots.add(slot)) {
        throw ArgumentError('Only one editor result is allowed per slot');
      }
      _validateMaterial({
        'kind': material.kind,
        'translation': material.translation,
        'markdown': material.markdown,
        'commentary': material.commentary,
      });
    }
    for (final message in input.aiMessages) {
      if (!const {'system', 'user', 'assistant'}.contains(message.role) ||
          message.content.trim().isEmpty ||
          message.sequence < 0) {
        throw ArgumentError('Invalid editor AI message');
      }
    }
  }

  void _reconcileEditorMaterials(
    List<Map<String, dynamic>> enrichments,
    List<AnnotationEditorMaterialInput> desired,
    String timestamp,
  ) {
    final desiredBySlot = {
      for (final material in desired)
        _editorMaterialSlot(material.kind, material.providerId): material,
    };
    for (final slot in const {
      'translation:google-translate',
      'dictionary:ldoce',
      'ai-analysis',
    }) {
      final candidates = enrichments
          .where((item) => _editorMaterialSlotForEntity(item) == slot)
          .toList();
      final material = desiredBySlot[slot];
      Map<String, dynamic>? winner;
      if (material != null && material.enrichmentId != null) {
        winner = candidates
            .where((item) => item['id'] == material.enrichmentId)
            .firstOrNull;
        if (winner != null && isProtocolEntityTombstoned(winner)) {
          winner = null;
        }
      }
      if (material != null) {
        if (winner == null && material.enrichmentId == null) {
          final ordered = candidates.toList()
            ..sort(compareCanonicalEntityRecency);
          final current = ordered.lastOrNull;
          if (current != null && !isProtocolEntityTombstoned(current)) {
            winner = current;
          }
        }
        winner ??= _newEditorMaterial(material, timestamp);
        if (!enrichments.contains(winner)) enrichments.add(winner);
        _patchEditorMaterial(winner, material, timestamp);
      }
      for (final candidate in candidates) {
        if (candidate == winner || isProtocolEntityTombstoned(candidate)) {
          continue;
        }
        candidate['updatedAt'] = timestamp;
        candidate['deletedAt'] = timestamp;
      }
    }
  }

  Map<String, dynamic> _newEditorMaterial(
    AnnotationEditorMaterialInput material,
    String timestamp,
  ) =>
      <String, dynamic>{
        'id': '${material.kind}:${uuid.v4()}',
        'kind': material.kind,
        'createdAt': timestamp,
        'updatedAt': timestamp,
      };

  void _patchEditorMaterial(
    Map<String, dynamic> target,
    AnnotationEditorMaterialInput material,
    String timestamp,
  ) {
    final before = canonicalJson(target);
    target['kind'] = material.kind;
    target['providerId'] = material.providerId;
    target['providerName'] = material.providerName;
    _setOptional(target, 'translation', material.translation?.trim());
    _setOptional(target, 'markdown', material.markdown?.trim());
    _setOptionalMap(target, 'commentary', material.commentary);
    _setOptionalMap(target, 'metadata', material.metadata);
    target.remove('deletedAt');
    if (canonicalJson(target) != before) target['updatedAt'] = timestamp;
  }

  void _reconcileEditorPersonalNote(
    List<Map<String, dynamic>> enrichments,
    String annotationId,
    String value,
    String timestamp,
  ) {
    final candidates = enrichments
        .where((item) => item['kind'] == 'personal-note')
        .toList()
      ..sort(compareCanonicalEntityRecency);
    final latest = candidates.lastOrNull;
    if (value.isEmpty) {
      if (latest != null && !isProtocolEntityTombstoned(latest)) {
        latest['content'] = '';
        latest['updatedAt'] = timestamp;
        latest['deletedAt'] = timestamp;
      }
      return;
    }
    Map<String, dynamic>? target = latest;
    if (target == null || isProtocolEntityTombstoned(target)) {
      final deterministicId = 'personal-note:$annotationId';
      target = <String, dynamic>{
        'id': candidates.any((item) => item['id'] == deterministicId)
            ? '$deterministicId:${uuid.v4()}'
            : deterministicId,
        'kind': 'personal-note',
        'createdAt': timestamp,
        'updatedAt': timestamp,
      };
      enrichments.add(target);
    }
    if (target['content'] != value || target.containsKey('deletedAt')) {
      target['content'] = value;
      target['updatedAt'] = timestamp;
    }
    target.remove('deletedAt');
  }

  void _reconcileEditorThread(
    List<Map<String, dynamic>> enrichments,
    Map<String, dynamic> annotation,
    String? desiredThreadId,
    List<AnnotationEditorMessageInput> messages,
    String timestamp,
  ) {
    final candidates =
        enrichments.where((item) => item['kind'] == 'ai-thread').toList();
    Map<String, dynamic>? target;
    if (desiredThreadId != null) {
      target =
          candidates.where((item) => item['id'] == desiredThreadId).firstOrNull;
      if (target != null && isProtocolEntityTombstoned(target)) target = null;
    }
    if (messages.isEmpty) {
      for (final candidate in candidates) {
        if (!isProtocolEntityTombstoned(candidate)) {
          candidate['updatedAt'] = timestamp;
          candidate['deletedAt'] = timestamp;
        }
      }
      return;
    }
    target ??= <String, dynamic>{
      'id': 'ai-thread:${uuid.v4()}',
      'kind': 'ai-thread',
      'createdAt': timestamp,
      'updatedAt': timestamp,
      'contextSnapshot': <String, dynamic>{},
      'messages': <Object>[],
    };
    if (!enrichments.contains(target)) enrichments.add(target);
    final threadBefore = canonicalJson(target);
    final existingMessages = (target['messages'] as List?)
            ?.whereType<Map>()
            .map((value) => value.cast<String, dynamic>())
            .toList() ??
        <Map<String, dynamic>>[];
    final patched = <Map<String, dynamic>>[];
    for (final message in messages) {
      Map<String, dynamic>? entity;
      if (message.messageId != null) {
        entity = existingMessages
            .where((item) => item['id'] == message.messageId)
            .firstOrNull;
        if (entity != null && isProtocolEntityTombstoned(entity)) entity = null;
      }
      entity ??= <String, dynamic>{
        'id': 'ai-message:${uuid.v4()}',
        'createdAt': canonicalWireTimestamp(message.createdAt ?? now()),
      };
      final messageBefore = canonicalJson(entity);
      entity['role'] = message.role;
      entity['sequence'] = message.sequence;
      entity['content'] = message.content.trim();
      entity.remove('deletedAt');
      if (canonicalJson(entity) != messageBefore) {
        entity['updatedAt'] = timestamp;
      }
      patched.add(entity);
    }
    final patchedIds = patched.map((item) => item['id']).toSet();
    patched.addAll(
      existingMessages.where((item) => !patchedIds.contains(item['id'])),
    );
    target['messages'] = patched;
    target['contextSnapshot'] = <String, dynamic>{
      ...?target['contextSnapshot'] as Map<String, dynamic>?,
      'selectedText': (annotation['target'] as Map)['selectedText'],
      if ((annotation['target'] as Map)['context'] case final String context)
        'context': context,
      if ((annotation['target'] as Map)['chapter'] case final String chapter)
        'chapter': chapter,
      'enrichmentIds': enrichments
          .where((item) =>
              !isProtocolEntityTombstoned(item) &&
              const {'translation', 'dictionary', 'ai-analysis'}
                  .contains(item['kind']))
          .map((item) => item['id'] as String)
          .toList()
        ..sort(),
    };
    target.remove('deletedAt');
    if (canonicalJson(target) != threadBefore) target['updatedAt'] = timestamp;
    for (final candidate in candidates) {
      if (candidate != target && !isProtocolEntityTombstoned(candidate)) {
        candidate['updatedAt'] = timestamp;
        candidate['deletedAt'] = timestamp;
      }
    }
  }

  String _editorMaterialSlot(String kind, String providerId) {
    if (kind == 'ai-analysis') return 'ai-analysis';
    return '$kind:$providerId';
  }

  String? _editorMaterialSlotForEntity(Map<String, dynamic> entity) {
    if (entity['kind'] == 'ai-analysis') return 'ai-analysis';
    if (entity['kind'] == 'translation' &&
        entity['providerId'] == 'google-translate') {
      return 'translation:google-translate';
    }
    if (entity['kind'] == 'dictionary' && entity['providerId'] == 'ldoce') {
      return 'dictionary:ldoce';
    }
    return null;
  }

  void _setOptional(Map<String, dynamic> target, String key, String? value) {
    if (value?.isNotEmpty == true) {
      target[key] = value;
    } else {
      target.remove(key);
    }
  }

  void _setOptionalMap(
    Map<String, dynamic> target,
    String key,
    Map<String, String> value,
  ) {
    if (value.isEmpty) {
      target.remove(key);
    } else {
      target[key] = Map<String, String>.from(value);
    }
  }

  Future<AnnotationRef> _saveMaterial(AnnotationRef ref,
      Map<String, dynamic> Function(String timestamp) create) async {
    final binding = await _canonicalBindingByRef(ref);
    _ensureAlive(binding.annotation);
    final timestamp = _nextTimestamp(binding.annotation);
    final enrichment = create(timestamp);
    _validateMaterial(enrichment);
    (binding.annotation['enrichments'] as List).add(enrichment);
    binding.annotation['updatedAt'] = timestamp;
    await _commit(binding.fingerprint, binding.document);
    return ref;
  }

  Map<String, dynamic> _translationEnrichment(
    String translation,
    String timestamp, {
    required String providerId,
    required String providerName,
  }) =>
      <String, dynamic>{
        'id': 'translation:${uuid.v4()}',
        'kind': 'translation',
        'providerId': providerId,
        'providerName': providerName,
        'translation': translation,
        'createdAt': timestamp,
        'updatedAt': timestamp,
      };

  Map<String, dynamic> _dictionaryEnrichment(
    String markdown,
    String timestamp, {
    String? translation,
    required String providerId,
    required String providerName,
    required Map<String, String> metadata,
  }) =>
      <String, dynamic>{
        'id': 'dictionary:${uuid.v4()}',
        'kind': 'dictionary',
        'providerId': providerId,
        'providerName': providerName,
        if (translation?.isNotEmpty == true) 'translation': translation,
        'markdown': markdown,
        if (metadata.isNotEmpty) 'metadata': Map<String, String>.from(metadata),
        'createdAt': timestamp,
        'updatedAt': timestamp,
      };

  Map<String, dynamic> _aiAnalysisEnrichment(
    String analysis,
    String timestamp, {
    String? translation,
    String? translationNotes,
    String? grammar,
    String? usage,
    required String providerId,
    required String providerName,
  }) {
    final notes =
        translationNotes?.isNotEmpty == true ? translationNotes! : analysis;
    return <String, dynamic>{
      'id': 'ai-analysis:${uuid.v4()}',
      'kind': 'ai-analysis',
      'providerId': providerId,
      'providerName': providerName,
      if (translation?.isNotEmpty == true) 'translation': translation,
      'commentary': <String, dynamic>{
        if (translation?.isNotEmpty == true) 'translation': translation,
        if (notes.isNotEmpty) 'translationNotes': notes,
        if (grammar?.isNotEmpty == true) 'grammar': grammar,
        if (usage?.isNotEmpty == true) 'usage': usage,
      },
      'createdAt': timestamp,
      'updatedAt': timestamp,
    };
  }

  void _validateMaterial(Map<String, dynamic> enrichment) {
    final kind = enrichment['kind'];
    if (!const {'translation', 'dictionary', 'ai-analysis'}.contains(kind)) {
      throw ArgumentError.value(kind, 'kind', 'unsupported material kind');
    }
    final hasPayload = <Object?>[
      enrichment['content'],
      enrichment['translation'],
      enrichment['markdown'],
      ...(enrichment['commentary'] is Map
          ? (enrichment['commentary'] as Map).values
          : const <Object?>[]),
    ].any((value) => value is String && value.trim().isNotEmpty);
    if (!hasPayload) {
      throw ArgumentError('material enrichment must contain semantic content');
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

  void _bookmarkPercentage(double value) {
    if (!value.isFinite || value < 0 || value > 1) {
      throw ArgumentError.value(value, 'percentage', 'must be between 0 and 1');
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
