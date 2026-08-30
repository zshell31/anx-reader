import 'dart:collection';

import 'package:anx_reader/service/sync/annotation_protocol.dart';

enum AnnotationMotivation { selection, bookmark }

enum AnnotationPresentationStyle { highlight, underline }

enum AnnotationCapability {
  available,
  unsupportedTarget,
  localBookUnavailable,
}

enum AnnotationTombstoneState { active, tombstoned }

/// Canonical annotation identity across UI, repository, and renderer layers.
class AnnotationRef {
  final String bookFingerprint;
  final String annotationId;

  AnnotationRef({
    required String bookFingerprint,
    required this.annotationId,
  }) : bookFingerprint = canonicalMd5Fingerprint(bookFingerprint) {
    if (annotationId.isEmpty) {
      throw ArgumentError.value(
          annotationId, 'annotationId', 'must not be empty');
    }
  }

  @override
  bool operator ==(Object other) =>
      other is AnnotationRef &&
      other.bookFingerprint == bookFingerprint &&
      other.annotationId == annotationId;

  @override
  int get hashCode => Object.hash(bookFingerprint, annotationId);

  @override
  String toString() => '$bookFingerprint/$annotationId';
}

/// Client-local presentation. This is deliberately not serializable to the
/// shared annotation protocol.
class AnnotationPresentation {
  final String annotationId;
  final AnnotationPresentationStyle style;
  final String color;

  const AnnotationPresentation({
    required this.annotationId,
    required this.style,
    required this.color,
  });
}

/// A read-only view over one canonical enrichment.
///
/// [data] is recursively unmodifiable and exists for kind-specific UI that
/// needs protocol fields not yet promoted to typed getters. There is no reverse
/// serialization API: protocol code remains the only canonical wire boundary.
class AnnotationEnrichmentView {
  final String id;
  final String kind;
  final DateTime createdAt;
  final DateTime updatedAt;
  final Map<String, Object?> data;

  AnnotationEnrichmentView._(Map<String, dynamic> enrichment)
      : id = enrichment['id'] as String,
        kind = enrichment['kind'] as String,
        createdAt = DateTime.parse(enrichment['createdAt'] as String),
        updatedAt = DateTime.parse(enrichment['updatedAt'] as String),
        data = _readOnlyJsonMap(enrichment);

  String? get content =>
      data['content'] is String ? data['content'] as String : null;

  String? get translation =>
      data['translation'] is String ? data['translation'] as String : null;

  String? get markdown =>
      data['markdown'] is String ? data['markdown'] as String : null;

  String? get providerId =>
      data['providerId'] is String ? data['providerId'] as String : null;

  String? get providerName =>
      data['providerName'] is String ? data['providerName'] as String : null;

  Map<String, Object?>? get commentary => data['commentary'] is Map
      ? (data['commentary'] as Map).cast<String, Object?>()
      : null;

  String? commentaryValue(String field) {
    final value = commentary?[field];
    return value is String ? value : null;
  }

  /// Known human-readable material fields, without stringifying arbitrary JSON.
  Iterable<String> get searchableText sync* {
    for (final value in <String?>[
      content,
      translation,
      markdown,
      commentaryValue('translation'),
      commentaryValue('translationNotes'),
      commentaryValue('grammar'),
      commentaryValue('usage'),
    ]) {
      if (value?.isNotEmpty == true) yield value!;
    }
  }
}

class AnnotationCapabilities {
  final AnnotationCapability navigation;
  final AnnotationCapability rendering;
  final String? epubCfi;

  const AnnotationCapabilities({
    required this.navigation,
    required this.rendering,
    required this.epubCfi,
  });
}

/// A typed, read-only projection for UI and renderer consumers.
///
/// It intentionally has no `toJson`/`toMap`: mutations must patch the original
/// canonical document through repository APIs so unknown fields survive.
class AnnotationUiModel {
  final AnnotationRef ref;
  final AnnotationMotivation motivation;
  final String selectedText;
  final String? annotationContext;
  final String? chapter;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<AnnotationEnrichmentView> activeEnrichments;
  final AnnotationEnrichmentView? effectivePersonalNote;
  final AnnotationCapability navigationCapability;
  final AnnotationCapability renderingCapability;
  final String? epubCfi;
  final double? bookmarkPercentage;
  final AnnotationPresentation? localPresentation;
  final AnnotationTombstoneState tombstoneState;

  const AnnotationUiModel({
    required this.ref,
    required this.motivation,
    required this.selectedText,
    required this.annotationContext,
    required this.chapter,
    required this.createdAt,
    required this.updatedAt,
    required this.activeEnrichments,
    required this.effectivePersonalNote,
    required this.navigationCapability,
    required this.renderingCapability,
    required this.epubCfi,
    required this.bookmarkPercentage,
    required this.localPresentation,
    required this.tombstoneState,
  });

  bool get isTombstoned =>
      tombstoneState == AnnotationTombstoneState.tombstoned;

  /// Resolves display-only presentation without materializing current defaults.
  AnnotationPresentation effectivePresentation({
    required String defaultStyle,
    required String defaultColor,
  }) {
    final explicit = localPresentation;
    if (explicit != null) return explicit;
    return AnnotationPresentation(
      annotationId: ref.annotationId,
      style: defaultStyle == 'underline'
          ? AnnotationPresentationStyle.underline
          : AnnotationPresentationStyle.highlight,
      color: defaultColor.replaceFirst(RegExp(r'^#'), ''),
    );
  }
}

/// One-way adapter from protocol-owned canonical maps to typed read models.
class CanonicalAnnotationReadAdapter {
  final Map<String, AnnotationPresentation> presentations;
  final bool Function(String bookFingerprint) localBookAvailable;

  const CanonicalAnnotationReadAdapter({
    this.presentations = const {},
    this.localBookAvailable = _alwaysAvailable,
  });

  List<AnnotationUiModel> read(
    Object? canonicalDocument, {
    bool includeTombstones = false,
  }) {
    final document = decodeAnnotationDocument(canonicalDocument);
    final book = document['book'] as Map<String, dynamic>;
    final fingerprint = canonicalMd5Fingerprint(book['fingerprint']);
    final hasLocalBook = localBookAvailable(fingerprint);
    final annotations =
        (document['annotations'] as List).cast<Map<String, dynamic>>();
    return List.unmodifiable([
      for (final annotation in annotations)
        if (includeTombstones || !isProtocolEntityTombstoned(annotation))
          _readAnnotation(annotation, fingerprint, hasLocalBook),
    ]);
  }

  AnnotationUiModel _readAnnotation(
    Map<String, dynamic> annotation,
    String fingerprint,
    bool hasLocalBook,
  ) {
    final annotationId = annotation['id'] as String;
    final target = annotation['target'] as Map<String, dynamic>;
    final presentation = presentations[annotationId];
    if (presentation != null && presentation.annotationId != annotationId) {
      throw ArgumentError('Presentation map key $annotationId does not match '
          '${presentation.annotationId}');
    }
    final capabilities = determineAnnotationCapabilities(
      annotation,
      localBookAvailable: hasLocalBook,
    );
    final selectedText = target['selectedText'];
    final context = target['context'];
    final chapter = target['chapter'];
    return AnnotationUiModel(
      ref: AnnotationRef(
        bookFingerprint: fingerprint,
        annotationId: annotationId,
      ),
      motivation: annotation['motivation'] == 'bookmark'
          ? AnnotationMotivation.bookmark
          : AnnotationMotivation.selection,
      selectedText: selectedText is String ? selectedText : '',
      annotationContext:
          context is String && context.isNotEmpty ? context : null,
      chapter: chapter is String && chapter.isNotEmpty ? chapter : null,
      createdAt: DateTime.parse(annotation['createdAt'] as String),
      updatedAt: DateTime.parse(annotation['updatedAt'] as String),
      activeEnrichments: activeAnnotationEnrichments(annotation),
      effectivePersonalNote: effectivePersonalNote(annotation),
      navigationCapability: capabilities.navigation,
      renderingCapability: capabilities.rendering,
      epubCfi: capabilities.epubCfi,
      bookmarkPercentage: annotation['motivation'] == 'bookmark'
          ? bookmarkProgressFraction(target)
          : null,
      localPresentation: presentation,
      tombstoneState: annotationTombstoneState(annotation),
    );
  }
}

double? bookmarkProgressFraction(Map target) {
  final progress = target['progress'];
  if (progress is! Map) return null;
  final fraction = progress['fraction'];
  if (fraction is! num || !fraction.isFinite) return null;
  final value = fraction.toDouble();
  return value >= 0 && value <= 1 ? value : null;
}

bool _alwaysAvailable(String _) => true;

AnnotationTombstoneState annotationTombstoneState(Map entity) =>
    isProtocolEntityTombstoned(entity)
        ? AnnotationTombstoneState.tombstoned
        : AnnotationTombstoneState.active;

bool isProtocolEntityTombstoned(Map entity) => entity.containsKey('deletedAt');

List<AnnotationEnrichmentView> activeAnnotationEnrichments(
    Map<String, dynamic> annotation) {
  final enrichments = (annotation['enrichments'] as List)
      .cast<Map<String, dynamic>>()
      .where((enrichment) => !isProtocolEntityTombstoned(enrichment))
      .map(AnnotationEnrichmentView._);
  return List.unmodifiable(enrichments);
}

/// Selects the deterministic effective enrichment of [kind].
///
/// Tombstones participate in winner selection so an older active value cannot
/// resurrect after a newer delete. The winning tombstone therefore produces
/// `null`.
AnnotationEnrichmentView? _effectiveAnnotationEnrichment(
  Map<String, dynamic> annotation,
  String kind,
) {
  final candidates = (annotation['enrichments'] as List)
      .cast<Map<String, dynamic>>()
      .where((enrichment) => enrichment['kind'] == kind)
      .toList()
    ..sort(compareCanonicalEntityRecency);
  if (candidates.isEmpty || isProtocolEntityTombstoned(candidates.last)) {
    return null;
  }
  return AnnotationEnrichmentView._(candidates.last);
}

AnnotationEnrichmentView? effectivePersonalNote(
    Map<String, dynamic> annotation) {
  final winner = _effectiveAnnotationEnrichment(annotation, 'personal-note');
  return winner?.content == null ? null : winner;
}

/// Canonical last-writer ordering used by protocol-derived effective values.
int compareCanonicalEntityRecency(
    Map<String, dynamic> left, Map<String, dynamic> right) {
  final time =
      (left['updatedAt'] as String).compareTo(right['updatedAt'] as String);
  return time != 0 ? time : canonicalJson(left).compareTo(canonicalJson(right));
}

String? supportedEpubCfi(Map target) {
  final selectors = target['selectors'];
  if (selectors is! List) return null;
  final values = <String>{};
  for (final selector in selectors) {
    if (selector is Map && selector['type'] == 'epub-cfi') {
      final value = selector['cfi'];
      if (value is String && isEpubCfi(value)) values.add(value.trim());
    }
  }
  return values.length == 1 ? values.single : null;
}

bool isEpubCfi(String value) {
  final cfi = value.trim();
  return cfi.startsWith('epubcfi(') && cfi.endsWith(')') && cfi.length > 9;
}

AnnotationCapabilities determineAnnotationCapabilities(
  Map<String, dynamic> annotation, {
  required bool localBookAvailable,
}) {
  final target = annotation['target'];
  if (target is! Map) {
    return const AnnotationCapabilities(
      navigation: AnnotationCapability.unsupportedTarget,
      rendering: AnnotationCapability.unsupportedTarget,
      epubCfi: null,
    );
  }
  final cfi = supportedEpubCfi(target);
  final navigationSupported = cfi != null;
  final renderingSupported = cfi != null && target['selectedText'] is String;
  AnnotationCapability capability(bool supported) => !supported
      ? AnnotationCapability.unsupportedTarget
      : localBookAvailable
          ? AnnotationCapability.available
          : AnnotationCapability.localBookUnavailable;
  return AnnotationCapabilities(
    navigation: capability(navigationSupported),
    rendering: capability(renderingSupported),
    epubCfi: cfi,
  );
}

Map<String, Object?> _readOnlyJsonMap(Map value) =>
    _readOnlyJson(value) as Map<String, Object?>;

Object? _readOnlyJson(Object? value) {
  if (value is Map) {
    return UnmodifiableMapView<String, Object?>(
        value.map((key, item) => MapEntry(key as String, _readOnlyJson(item))));
  }
  if (value is List) {
    return List<Object?>.unmodifiable(value.map(_readOnlyJson));
  }
  return value;
}
