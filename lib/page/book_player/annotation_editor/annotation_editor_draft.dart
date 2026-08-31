import 'dart:convert';

import 'package:anx_reader/page/book_player/selection_persistence_session.dart';
import 'package:anx_reader/service/sync/annotation_read_model.dart';

enum AnnotationEditorProvider { googleTranslate, ldoce, ai }

extension AnnotationEditorProviderIdentity on AnnotationEditorProvider {
  String get providerId => switch (this) {
        AnnotationEditorProvider.googleTranslate => 'google-translate',
        AnnotationEditorProvider.ldoce => 'ldoce',
        AnnotationEditorProvider.ai => 'openai',
      };

  String get providerName => switch (this) {
        AnnotationEditorProvider.googleTranslate => 'Google Translate',
        AnnotationEditorProvider.ldoce => 'LDOCE',
        AnnotationEditorProvider.ai => 'OpenAI',
      };

  String get kind => switch (this) {
        AnnotationEditorProvider.googleTranslate => 'translation',
        AnnotationEditorProvider.ldoce => 'dictionary',
        AnnotationEditorProvider.ai => 'ai-analysis',
      };
}

class AnnotationEditorCommentary {
  final String? translation;
  final String? translationNotes;
  final String? grammar;
  final String? usage;
  final Map<String, Object?> unknownFields;

  const AnnotationEditorCommentary({
    this.translation,
    this.translationNotes,
    this.grammar,
    this.usage,
    this.unknownFields = const {},
  });

  factory AnnotationEditorCommentary.fromMap(Map<Object?, Object?> value) =>
      AnnotationEditorCommentary(
        translation: _optionalText(value['translation']),
        translationNotes: _optionalText(value['translationNotes']),
        grammar: _optionalText(value['grammar']),
        usage: _optionalText(value['usage']),
        unknownFields: Map.unmodifiable({
          for (final entry in value.entries)
            if (entry.key is String &&
                !const {
                  'translation',
                  'translationNotes',
                  'grammar',
                  'usage',
                }.contains(entry.key))
              entry.key as String: entry.value,
        }),
      );

  Map<String, Object?> toMap() => {
        ...unknownFields,
        if (translation?.isNotEmpty == true) 'translation': translation!,
        if (translationNotes?.isNotEmpty == true)
          'translationNotes': translationNotes!,
        if (grammar?.isNotEmpty == true) 'grammar': grammar!,
        if (usage?.isNotEmpty == true) 'usage': usage!,
      };
}

/// Semantic provider material held only by an annotation editor draft.
class AnnotationEditorSourceResult {
  final String? enrichmentId;
  final String providerId;
  final String providerName;
  final String kind;
  final String? translation;
  final String? markdown;
  final AnnotationEditorCommentary? commentary;
  final Map<String, String> metadata;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const AnnotationEditorSourceResult({
    this.enrichmentId,
    required this.providerId,
    required this.providerName,
    required this.kind,
    this.translation,
    this.markdown,
    this.commentary,
    this.metadata = const {},
    this.createdAt,
    this.updatedAt,
  });

  factory AnnotationEditorSourceResult.fromEnrichment(
    AnnotationEnrichmentView enrichment,
  ) {
    final rawMetadata = enrichment.data['metadata'];
    return AnnotationEditorSourceResult(
      enrichmentId: enrichment.id,
      providerId: enrichment.providerId ?? 'unknown',
      providerName:
          enrichment.providerName ?? enrichment.providerId ?? 'Unknown',
      kind: enrichment.kind,
      translation: enrichment.translation,
      markdown: enrichment.markdown,
      commentary: enrichment.commentary == null
          ? null
          : AnnotationEditorCommentary.fromMap(enrichment.commentary!),
      metadata: rawMetadata is Map
          ? Map.unmodifiable({
              for (final entry in rawMetadata.entries)
                if (entry.key is String && entry.value is String)
                  entry.key as String: entry.value as String,
            })
          : const {},
      createdAt: enrichment.createdAt,
      updatedAt: enrichment.updatedAt,
    );
  }

  Map<String, Object?> semanticState() => {
        'enrichmentId': enrichmentId,
        'providerId': providerId,
        'providerName': providerName,
        'kind': kind,
        'translation': translation,
        'markdown': markdown,
        'commentary': commentary?.toMap(),
        'metadata': metadata,
        'createdAt': createdAt?.toUtc().toIso8601String(),
      };
}

class AnnotationEditorMessage {
  final String? messageId;
  final String role;
  final String content;
  final int sequence;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const AnnotationEditorMessage({
    this.messageId,
    required this.role,
    required this.content,
    required this.sequence,
    this.createdAt,
    this.updatedAt,
  });

  Map<String, Object?> semanticState() => {
        'messageId': messageId,
        'role': role,
        'content': content,
        'sequence': sequence,
        'createdAt': createdAt?.toUtc().toIso8601String(),
      };
}

class AnnotationEditorProviderState {
  final bool loading;
  final String? error;
  final int generation;

  const AnnotationEditorProviderState({
    this.loading = false,
    this.error,
    this.generation = 0,
  });
}

class AnnotationEditorRequest {
  final AnnotationEditorProvider provider;
  final int generation;

  const AnnotationEditorRequest(this.provider, this.generation);
}

/// Mutable application state for one modal editor lifetime.
///
/// None of these operations persist canonical state. The repository Save
/// boundary consumes a snapshot of this draft explicitly.
class AnnotationEditorDraft {
  final SelectionSnapshot selection;
  final AnnotationRef? existingRef;
  final String bookTitle;

  String personalNote;
  String? aiThreadId;
  DateTime? aiThreadCreatedAt;
  final Map<AnnotationEditorProvider, AnnotationEditorSourceResult>
      sourceResults;
  final List<AnnotationEditorMessage> aiMessages;
  final Set<String> observedMaterialIds;
  final Set<String> observedAiThreadIds;
  final Map<AnnotationEditorProvider, AnnotationEditorProviderState>
      providerStates;

  late final String _initialState;
  bool _closed = false;

  AnnotationEditorDraft._({
    required this.selection,
    required this.existingRef,
    required this.bookTitle,
    required this.personalNote,
    required this.sourceResults,
    required this.aiMessages,
    required this.observedMaterialIds,
    required this.observedAiThreadIds,
    required this.providerStates,
    this.aiThreadId,
    this.aiThreadCreatedAt,
  }) {
    _initialState = _editableState();
  }

  factory AnnotationEditorDraft.forSelection({
    required SelectionSnapshot selection,
    required String bookTitle,
  }) =>
      AnnotationEditorDraft._(
        selection: selection,
        existingRef: null,
        bookTitle: bookTitle,
        personalNote: '',
        sourceResults: {},
        aiMessages: [],
        observedMaterialIds: const {},
        observedAiThreadIds: const {},
        providerStates: _emptyProviderStates(),
      );

  factory AnnotationEditorDraft.forAnnotation({
    required SelectionSnapshot selection,
    required String bookTitle,
    required AnnotationUiModel annotation,
  }) {
    final results = <AnnotationEditorProvider, AnnotationEditorSourceResult>{};
    final materialCandidates =
        <AnnotationEditorProvider, List<AnnotationEnrichmentView>>{};
    final threads = <AnnotationEnrichmentView>[];
    for (final enrichment in annotation.allEnrichments) {
      if (enrichment.kind == 'ai-thread') {
        threads.add(enrichment);
        continue;
      }
      final provider = _providerFor(enrichment);
      if (provider == null) continue;
      materialCandidates.putIfAbsent(provider, () => []).add(enrichment);
    }
    for (final entry in materialCandidates.entries) {
      entry.value.sort(_compareEnrichmentViews);
      final winner = entry.value.last;
      if (!winner.isTombstoned) {
        results[entry.key] =
            AnnotationEditorSourceResult.fromEnrichment(winner);
      }
    }
    threads.sort(_compareEnrichmentViews);
    final thread =
        threads.lastOrNull?.isTombstoned == true ? null : threads.lastOrNull;
    final messages =
        thread == null ? <AnnotationEditorMessage>[] : _messages(thread);
    return AnnotationEditorDraft._(
      selection: selection,
      existingRef: annotation.ref,
      bookTitle: bookTitle,
      personalNote: annotation.effectivePersonalNote?.content ?? '',
      sourceResults: results,
      aiMessages: messages,
      observedMaterialIds: Set.unmodifiable(
        materialCandidates.values
            .expand((candidates) => candidates)
            .map((candidate) => candidate.id),
      ),
      observedAiThreadIds: Set.unmodifiable(
        threads.map((candidate) => candidate.id),
      ),
      providerStates: _emptyProviderStates(),
      aiThreadId: thread?.id,
      aiThreadCreatedAt: thread?.createdAt,
    );
  }

  bool get isClosed => _closed;
  bool get isNew => existingRef == null;
  bool get isDirty => isNew || _editableState() != _initialState;

  AnnotationEditorProviderState stateFor(AnnotationEditorProvider provider) =>
      providerStates[provider]!;

  AnnotationEditorRequest startProvider(AnnotationEditorProvider provider) {
    _ensureOpen();
    final current = stateFor(provider);
    final next = current.generation + 1;
    providerStates[provider] = AnnotationEditorProviderState(
      loading: true,
      generation: next,
    );
    return AnnotationEditorRequest(provider, next);
  }

  bool completeProvider(
    AnnotationEditorRequest request,
    AnnotationEditorSourceResult result,
  ) {
    if (!_accepts(request)) return false;
    final providerMatches = request.provider == AnnotationEditorProvider.ai
        ? result.providerId.isNotEmpty
        : result.providerId == request.provider.providerId;
    if (!providerMatches || result.kind != request.provider.kind) {
      throw ArgumentError('Provider result identity does not match request');
    }
    final previous = sourceResults[request.provider];
    sourceResults[request.provider] = AnnotationEditorSourceResult(
      enrichmentId: previous?.enrichmentId ?? result.enrichmentId,
      providerId: result.providerId,
      providerName: result.providerName,
      kind: result.kind,
      translation: result.translation,
      markdown: result.markdown,
      commentary: result.commentary,
      metadata: Map.unmodifiable(result.metadata),
      createdAt: previous?.createdAt ?? result.createdAt,
      updatedAt: result.updatedAt,
    );
    providerStates[request.provider] = AnnotationEditorProviderState(
      generation: request.generation,
    );
    return true;
  }

  bool failProvider(AnnotationEditorRequest request, Object error) {
    if (!_accepts(request)) return false;
    providerStates[request.provider] = AnnotationEditorProviderState(
      error: error.toString(),
      generation: request.generation,
    );
    return true;
  }

  void removeProvider(AnnotationEditorProvider provider) {
    _ensureOpen();
    sourceResults.remove(provider);
    final current = stateFor(provider);
    providerStates[provider] = AnnotationEditorProviderState(
      generation: current.generation + 1,
    );
  }

  void setPersonalNote(String value) {
    _ensureOpen();
    personalNote = value;
  }

  void addAiExchange(String question, String answer, {DateTime? createdAt}) {
    _ensureOpen();
    final timestamp = createdAt ?? DateTime.now();
    final next = aiMessages.isEmpty
        ? 0
        : aiMessages.map((message) => message.sequence).reduce(
                  (left, right) => left > right ? left : right,
                ) +
            1;
    aiMessages.addAll([
      AnnotationEditorMessage(
        role: 'user',
        content: question.trim(),
        sequence: next,
        createdAt: timestamp,
        updatedAt: timestamp,
      ),
      AnnotationEditorMessage(
        role: 'assistant',
        content: answer.trim(),
        sequence: next + 1,
        createdAt: timestamp,
        updatedAt: timestamp,
      ),
    ]);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final provider in AnnotationEditorProvider.values) {
      final current = stateFor(provider);
      providerStates[provider] = AnnotationEditorProviderState(
        generation: current.generation + 1,
      );
    }
  }

  bool _accepts(AnnotationEditorRequest request) {
    if (_closed) return false;
    final current = stateFor(request.provider);
    return current.loading && current.generation == request.generation;
  }

  void _ensureOpen() {
    if (_closed) throw StateError('Annotation editor draft is closed');
  }

  String _editableState() => jsonEncode({
        'personalNote': personalNote,
        'sourceResults': {
          for (final provider in AnnotationEditorProvider.values)
            provider.providerId: sourceResults[provider]?.semanticState(),
        },
        'aiThreadId': aiThreadId,
        'aiMessages': [
          for (final message in aiMessages) message.semanticState()
        ],
      });
}

Map<AnnotationEditorProvider, AnnotationEditorProviderState>
    _emptyProviderStates() => {
          for (final provider in AnnotationEditorProvider.values)
            provider: const AnnotationEditorProviderState(),
        };

AnnotationEditorProvider? _providerFor(AnnotationEnrichmentView enrichment) {
  if (enrichment.providerId == 'google-translate' &&
      enrichment.kind == 'translation') {
    return AnnotationEditorProvider.googleTranslate;
  }
  if (enrichment.providerId == 'ldoce' && enrichment.kind == 'dictionary') {
    return AnnotationEditorProvider.ldoce;
  }
  if (enrichment.kind == 'ai-analysis') return AnnotationEditorProvider.ai;
  return null;
}

List<AnnotationEditorMessage> _messages(AnnotationEnrichmentView thread) {
  final raw = thread.data['messages'];
  if (raw is! List) return [];
  final result = <AnnotationEditorMessage>[];
  for (final value in raw) {
    if (value is! Map) continue;
    final role = value['role'];
    final content = value['content'];
    final sequence = value['sequence'];
    if (role is! String || content is! String || sequence is! int) continue;
    result.add(AnnotationEditorMessage(
      messageId: _optionalText(value['id']),
      role: role,
      content: content,
      sequence: sequence,
      createdAt: _optionalDate(value['createdAt']),
      updatedAt: _optionalDate(value['updatedAt']),
    ));
  }
  result.sort((left, right) {
    final sequence = left.sequence.compareTo(right.sequence);
    return sequence != 0
        ? sequence
        : (left.messageId ?? '').compareTo(right.messageId ?? '');
  });
  return result;
}

String? _optionalText(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

DateTime? _optionalDate(Object? value) {
  if (value is! String) return null;
  return DateTime.tryParse(value);
}

int _compareEnrichmentViews(
  AnnotationEnrichmentView left,
  AnnotationEnrichmentView right,
) =>
    compareCanonicalEntityRecency(
      left.data.cast<String, dynamic>(),
      right.data.cast<String, dynamic>(),
    );
