import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String source(String path) => File(path).readAsStringSync();

String sourceWithoutImports(String path) => source(path)
    .split('\n')
    .where((line) => !line.trimLeft().startsWith('import '))
    .join('\n');

void main() {
  test('semantic UI path is canonical document to read model to Notes', () {
    final catalog = source('lib/service/sync/annotation_catalog.dart');
    final provider = source('lib/providers/book_notes.dart');
    final export = source('lib/service/notes/export_notes.dart');

    expect(catalog, contains('sharedState.annotationDocuments()'));
    expect(catalog, contains('CanonicalAnnotationReadAdapter('));
    expect(provider, contains('canonicalAnnotationCatalog.readBook('));
    expect(export, contains('AnnotationUiModel'));
    for (final value in [catalog, provider, export]) {
      expect(value, isNot(contains('tb_notes')));
      expect(value, isNot(contains('shared_annotation_id')));
    }
  });

  test('renderer path combines canonical semantics and Anx presentation', () {
    final player = source('lib/page/book_player/epub_player.dart');
    final adapter =
        source('lib/page/book_player/foliate_annotation_adapter.dart');

    expect(player, contains('sharedState.annotationDocument('));
    expect(player, contains('sharedState.annotationPresentations()'));
    expect(player, contains('CanonicalAnnotationReadAdapter('));
    expect(player, contains('FoliateAnnotationAdapter('));
    expect(adapter, contains('annotation.ref.annotationId'));
    expect(adapter, contains("'renderKey': id"));
    expect(player, isNot(contains('tb_notes')));
    expect(player, isNot(contains('nativeNoteId')));
  });

  test('selection path remains transient until explicit repository calls', () {
    final javascript = source('assets/foliate-js/src/book.js');
    final bridge = source('lib/page/book_player/selection_session_bridge.dart');
    final persistence =
        source('lib/page/book_player/selection_persistence_session.dart');

    expect(javascript, contains('new SelectionSessionMachine()'));
    expect(javascript, contains("callFlutter('onSelectionChanged'"));
    expect(javascript, contains("callFlutter('onSelectionActionsRequested'"));
    expect(bridge, isNot(contains('annotationRepository')));
    expect(persistence, contains('AnnotationRef? get annotationRef'));
    expect(persistence, isNot(contains('tb_notes')));
  });

  test('presentation sync is independent from protocol-v2 annotation bytes',
      () {
    final database = source('lib/service/sync/shared_state_database.dart');
    final presentation =
        source('lib/service/sync/annotation_presentation_protocol.dart');
    final runtime = source('lib/service/sync/annotation_sync_runtime.dart');

    expect(presentation,
        contains("anxPresentationSyncDomain = 'anx-annotation-presentations'"));
    expect(
        presentation, contains("anxPresentationDocumentId = 'presentations'"));
    expect(database, contains('putAnnotationPresentation('));
    expect(runtime, contains('syncDomain: anxPresentationSyncDomain'));
    expect(runtime, contains('mergeAnxPresentationDocuments'));
  });

  test('removed runtime types and services cannot return', () {
    final removedRuntimeConcepts = RegExp(
      r'\bBookNote\b|\breaderNote\b|\bsharedAnnotationId\b|'
      r'\bnativeNoteId\b|\bbookNoteDao\b|'
      r'\bAnnotationProjectionReconciler\b|'
      r'\bNativeAnnotationProjectionStore\b',
    );
    final occurrences = <String>{};
    for (final file in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))) {
      if (removedRuntimeConcepts.hasMatch(sourceWithoutImports(file.path))) {
        occurrences.add(file.path);
      }
    }

    expect(occurrences, isEmpty);
  });

  test('physical legacy evidence is confined to migration-only code', () {
    const allowed = {
      'lib/dao/database.dart',
      'lib/service/sync/legacy_annotation_bootstrap.dart',
      'lib/service/sync/legacy_annotation_store.dart',
      'lib/service/sync/shared_state_database.dart',
    };
    final physicalLegacyEvidence = RegExp(
      r'\btb_notes\b|\breader_note\b|\bshared_annotation_id\b|'
      r'\bannotation_projections\b|\bannotation_presentations\b',
    );
    final occurrences = <String>{};
    for (final file in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))) {
      if (physicalLegacyEvidence.hasMatch(sourceWithoutImports(file.path))) {
        occurrences.add(file.path);
      }
    }

    expect(occurrences.difference(allowed), isEmpty);
    expect(
        occurrences,
        containsAll({
          'lib/dao/database.dart',
          'lib/service/sync/legacy_annotation_bootstrap.dart',
          'lib/service/sync/legacy_annotation_store.dart',
          'lib/service/sync/shared_state_database.dart',
        }));
  });

  test('sync has document listeners and no materialization layer', () {
    final coordinator =
        source('lib/service/sync/annotation_sync_coordinator.dart');
    final runtime = source('lib/service/sync/annotation_sync_runtime.dart');

    expect(coordinator, contains('SharedDocumentChanged'));
    expect(coordinator, contains('_notifyDocumentChanged'));
    expect(runtime, contains('onDocumentChanged:'));
    expect(coordinator, isNot(contains('reconcileProjection')));
    expect(runtime, isNot(contains('AnnotationProjectionReconciler')));
  });
}
