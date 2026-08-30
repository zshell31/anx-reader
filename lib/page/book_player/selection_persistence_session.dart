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

  const SelectionAnnotationHandle({
    required this.ref,
  });
}

class SelectionFirstSaveResult<T> {
  final SelectionAnnotationHandle annotation;
  final T value;

  const SelectionFirstSaveResult(this.annotation, this.value);
}

/// Persistence and transient provider state owned by one active selection.
///
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
  bool get hasPersistedAnnotation => _annotation != null;

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

  Future<T> persistWithFirstSave<T>({
    required Future<SelectionFirstSaveResult<T>> Function(
            SelectionSnapshot snapshot)
        createAndSave,
    required Future<T> Function(AnnotationRef ref) save,
  }) async {
    final current = _annotation;
    if (current != null) return save(current.ref);
    final pending = _creation;
    if (pending != null) return save((await pending).ref);

    final operation = createAndSave(snapshot);
    final creation = operation.then((result) => result.annotation);
    _creation = creation;
    try {
      final result = await operation;
      _annotation = result.annotation;
      return result.value;
    } finally {
      _creation = null;
    }
  }
}
