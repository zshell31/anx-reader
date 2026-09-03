import 'package:anx_reader/service/sync/conditional_webdav_transport.dart';
import 'package:anx_reader/service/sync/reading_activity_protocol.dart';
import 'package:anx_reader/service/sync/reading_activity_repository.dart';
import 'package:anx_reader/service/sync/shared_document_sync_coordinator.dart';
import 'package:anx_reader/service/sync/shared_state_database.dart';

class ReadingActivitySyncService {
  final SharedDocumentSyncCoordinator coordinator;

  ReadingActivitySyncService({
    required SharedStateDatabase sharedState,
    required ReadingActivityRepository repository,
    required AnnotationWebDavTransport transport,
  }) : coordinator = SharedDocumentSyncCoordinator(
          sharedState: sharedState,
          transport: transport,
          syncDomain: readingActivityDomain,
          normalizeDocumentId: (id) => id,
          remotePathFor: readingActivityRemotePath,
          decodeDocument: decodeReadingActivityDocument,
          decodeFailureLabel: readingActivityDecodeFailureLabel,
          isRecoverableRemotePlaceholder: (body) => body.isEmpty,
          mergeDocuments: mergeReadingActivityDocuments,
          validateDocumentId: readingActivityMatchesId,
          onDocumentChanged: repository.projectCanonical,
        );

  Future<void> syncKnown(
    Iterable<String> documentIds, {
    Map<String, String> remoteStrongEtags = const {},
  }) =>
      coordinator.syncKnown(
        documentIds,
        discoveredStrongEtags: remoteStrongEtags,
      );

  Future<void> notifyMutation(String documentId) =>
      coordinator.notifyDirty(documentId);

  Future<void> close() => coordinator.close();
}
