import 'package:anx_reader/service/sync/annotation_sync_coordinator.dart';
import 'package:anx_reader/service/sync/shared_document_sync_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('annotation coordinator is assignable to shared core', () {
    SharedDocumentSyncCoordinator? core;
    AnnotationSyncCoordinator? facade;
    core = facade;
    expect(core, isNull);
  });
}
