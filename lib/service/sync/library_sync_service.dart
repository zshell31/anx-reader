import 'package:anx_reader/service/sync/annotation_protocol.dart';
import 'package:anx_reader/service/sync/conditional_webdav_transport.dart';
import 'package:anx_reader/service/sync/library_protocol.dart';
import 'package:anx_reader/service/sync/library_sync_repository.dart';
import 'package:anx_reader/service/sync/shared_document_sync_coordinator.dart';
import 'package:anx_reader/service/sync/shared_state_database.dart';

class LibrarySyncService {
  final SharedStateDatabase sharedState;
  final LibrarySyncRepository repository;
  late final SharedDocumentSyncCoordinator catalog;
  late final SharedDocumentSyncCoordinator readingState;

  LibrarySyncService({
    required this.sharedState,
    required this.repository,
    required AnnotationWebDavTransport transport,
  }) {
    catalog = SharedDocumentSyncCoordinator(
      sharedState: sharedState,
      transport: transport,
      syncDomain: libraryCatalogDomain,
      normalizeDocumentId: canonicalMd5Fingerprint,
      remotePathFor: libraryCatalogRemotePath,
      decodeDocument: decodeLibraryCatalogDocument,
      mergeDocuments: mergeLibraryCatalogDocuments,
      validateDocumentId: (document, id) => document['fingerprint'] == id,
      onDocumentChanged: (id) =>
          repository.projectCanonical(libraryCatalogDomain, id),
    );
    readingState = SharedDocumentSyncCoordinator(
      sharedState: sharedState,
      transport: transport,
      syncDomain: readingStateDomain,
      normalizeDocumentId: canonicalMd5Fingerprint,
      remotePathFor: readingStateRemotePath,
      decodeDocument: decodeReadingStateDocument,
      mergeDocuments: mergeReadingStateDocuments,
      validateDocumentId: (document, id) => document['fingerprint'] == id,
      onDocumentChanged: (id) =>
          repository.projectCanonical(readingStateDomain, id),
    );
  }

  Future<void> syncKnown(Iterable<String> fingerprints) async {
    final ids = fingerprints.map(canonicalMd5Fingerprint).toSet();
    await Future.wait([
      catalog.syncKnown(ids),
      readingState.syncKnown(ids),
    ]);
  }

  Future<void> syncCatalog(
    Iterable<String> fingerprints, {
    Map<String, String> remoteStrongEtags = const {},
  }) async {
    final ids = fingerprints.map(canonicalMd5Fingerprint).toSet();
    await catalog.syncKnown(
      ids,
      discoveredStrongEtags: remoteStrongEtags,
    );
  }

  Future<void> syncReadingState(
    Iterable<String> fingerprints, {
    Map<String, String> remoteStrongEtags = const {},
  }) async {
    final ids = fingerprints.map(canonicalMd5Fingerprint).toSet();
    await readingState.syncKnown(
      ids,
      discoveredStrongEtags: remoteStrongEtags,
    );
  }

  Future<void> notifyCatalogMutation(String fingerprint) =>
      catalog.notifyDirty(fingerprint);

  Future<void> notifyReadingMutation(String fingerprint) =>
      readingState.notifyDirty(fingerprint);

  Future<void> close() async {
    await catalog.close();
    await readingState.close();
  }
}
