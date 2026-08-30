import 'dart:async';

import 'package:anx_reader/service/sync/annotation_read_model.dart';

class SelectionSnapshot {
  final String selectedText;
  final String? annotationContext;
  final String? lookupContext;
  final String chapter;
  final String selector;

  const SelectionSnapshot({
    required this.selectedText,
    required this.annotationContext,
    required this.lookupContext,
    required this.chapter,
    required this.selector,
  });
}

class SelectionAnnotationHandle {
  final AnnotationRef ref;
  final int nativeCompatibilityId;

  const SelectionAnnotationHandle({
    required this.ref,
    required this.nativeCompatibilityId,
  });
}

/// Persistence and transient provider state owned by one active selection.
///
/// The native ID is a temporary compatibility handle until M4E.7 migrates all
/// mutations to [AnnotationRef]. It is never used to discover another
/// annotation by selector/CFI.
class SelectionPersistenceSession {
  final SelectionSnapshot snapshot;

  SelectionAnnotationHandle? _annotation;
  Future<SelectionAnnotationHandle>? _creation;

  String? translation;
  String? dictionary;
  String? aiAnalysis;
  List<String>? aiThread;

  SelectionPersistenceSession(this.snapshot,
      {SelectionAnnotationHandle? existingAnnotation})
      : _annotation = existingAnnotation;

  AnnotationRef? get annotationRef => _annotation?.ref;
  SelectionAnnotationHandle? get annotation => _annotation;

  void attachExisting(SelectionAnnotationHandle annotation) {
    final current = _annotation;
    if (current != null && current.ref != annotation.ref) {
      throw StateError('SelectionSession is already bound to ${current.ref}');
    }
    _annotation = annotation;
  }

  Future<SelectionAnnotationHandle> ensureAnnotation(
      Future<SelectionAnnotationHandle> Function(SelectionSnapshot snapshot)
          create) async {
    final current = _annotation;
    if (current != null) return current;

    final pending = _creation;
    if (pending != null) return pending;

    final operation = create(snapshot);
    _creation = operation;
    try {
      final created = await operation;
      _annotation = created;
      return created;
    } finally {
      _creation = null;
    }
  }

  Future<T> persist<T>({
    required Future<SelectionAnnotationHandle> Function(
            SelectionSnapshot snapshot)
        create,
    required Future<T> Function(SelectionAnnotationHandle annotation) save,
  }) async {
    final annotation = await ensureAnnotation(create);
    return save(annotation);
  }
}
