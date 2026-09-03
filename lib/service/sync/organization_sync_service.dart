import 'package:anx_reader/service/sync/conditional_webdav_transport.dart';
import 'package:anx_reader/service/sync/organization_protocol.dart';
import 'package:anx_reader/service/sync/organization_repository.dart';
import 'package:anx_reader/service/sync/shared_document_sync_coordinator.dart';
import 'package:anx_reader/service/sync/shared_state_database.dart';

class OrganizationSyncService {
  final List<SharedDocumentSyncCoordinator> coordinators;
  final OrganizationRepository repository;

  OrganizationSyncService({
    required SharedStateDatabase sharedState,
    required this.repository,
    required AnnotationWebDavTransport transport,
  }) : coordinators = [
          _coordinator(
              sharedState,
              repository,
              transport,
              groupDomain,
              groupRemotePath,
              decodeGroupDocument,
              mergeGroupDocuments,
              recordMatchesId),
          _coordinator(
              sharedState,
              repository,
              transport,
              tagDomain,
              tagRemotePath,
              decodeTagDocument,
              mergeTagDocuments,
              recordMatchesId),
          _coordinator(
              sharedState,
              repository,
              transport,
              themeDomain,
              themeRemotePath,
              decodeThemeDocument,
              mergeThemeDocuments,
              recordMatchesId),
          _coordinator(
              sharedState,
              repository,
              transport,
              bookTagDomain,
              bookTagRemotePath,
              decodeBookTagDocument,
              mergeBookTagDocuments,
              bookTagMatchesId),
        ];

  static SharedDocumentSyncCoordinator _coordinator(
    SharedStateDatabase sharedState,
    OrganizationRepository repository,
    AnnotationWebDavTransport transport,
    String domain,
    List<String> Function(String) path,
    Map<String, dynamic> Function(Object?) decode,
    Map<String, dynamic> Function(Map<String, dynamic>, Map<String, dynamic>)
        merge,
    bool Function(Map<String, dynamic>, String) validate,
  ) =>
      SharedDocumentSyncCoordinator(
        sharedState: sharedState,
        transport: transport,
        syncDomain: domain,
        normalizeDocumentId: (id) => id,
        remotePathFor: path,
        decodeDocument: decode,
        mergeDocuments: merge,
        validateDocumentId: validate,
        onDocumentChanged: (id) => repository.projectCanonical(domain, id),
      );

  Future<void> syncKnown(
    SharedStateDatabase state, {
    Map<String, Set<String>> remoteIdsByDomain = const {},
    Map<String, Map<String, String>> remoteStrongEtagsByDomain = const {},
  }) async {
    final work = <Future<void>>[];
    for (final coordinator in coordinators) {
      work.add(coordinator.syncDirtyAnnotations());
      final documentIds = {
        ...await state.documentIds(coordinator.syncDomain),
        ...remoteIdsByDomain[coordinator.syncDomain] ?? const <String>{},
      };
      work.add(coordinator.pullBooks(
        documentIds,
        discoveredStrongEtags:
            remoteStrongEtagsByDomain[coordinator.syncDomain] ?? const {},
      ));
    }
    await Future.wait(work);
    await repository.projectAllCanonicalGroups();
  }

  Future<void> close() =>
      Future.wait(coordinators.map((coordinator) => coordinator.close()));
}
