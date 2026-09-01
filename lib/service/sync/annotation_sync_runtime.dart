import 'dart:async';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/enums/sync_protocol.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/service/sync/annotation_protocol.dart';
import 'package:anx_reader/service/sync/annotation_presentation_protocol.dart';
import 'package:anx_reader/service/sync/annotation_sync_coordinator.dart';
import 'package:anx_reader/service/sync/conditional_webdav_transport.dart';
import 'package:anx_reader/service/sync/library_sync_repository.dart';
import 'package:anx_reader/service/sync/library_sync_service.dart';
import 'package:anx_reader/service/sync/reading_activity_protocol.dart';
import 'package:anx_reader/service/sync/reading_activity_repository.dart';
import 'package:anx_reader/service/sync/reading_activity_sync_service.dart';
import 'package:anx_reader/service/sync/organization_repository.dart';
import 'package:anx_reader/service/sync/organization_sync_service.dart';
import 'package:anx_reader/service/sync/organization_protocol.dart';
import 'package:anx_reader/service/sync/shared_state_database.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

const defaultAnnotationRemoteRoot = 'Lingua Reader';
const annotationRemoteRootConfigKey = 'annotationRemoteRoot';

/// Application lifecycle and connectivity adapter for annotation sync.
///
/// It deliberately does not depend on the legacy whole-database sync provider
/// or its upload/download direction dialog.
class AnnotationSyncRuntime {
  AnnotationSyncRuntime._();
  static final AnnotationSyncRuntime instance = AnnotationSyncRuntime._();

  final SharedStateDatabase sharedState = SharedStateDatabase();
  final Map<String, Set<void Function()>> _openBookRefresh = {};
  AnnotationSyncCoordinator? _coordinator;
  AnnotationSyncCoordinator? _presentationCoordinator;
  LibrarySyncRepository? _libraryRepository;
  LibrarySyncService? _libraryService;
  ReadingActivityRepository? _readingActivityRepository;
  ReadingActivitySyncService? _readingActivityService;
  OrganizationRepository? _organizationRepository;
  OrganizationSyncService? _organizationService;
  final StreamController<void> _statusChanges =
      StreamController<void>.broadcast();
  final StreamController<void> _annotationChanges =
      StreamController<void>.broadcast();
  final List<StreamSubscription<void>> _coordinatorStatusSubscriptions = [];
  StreamSubscription<List<ConnectivityResult>>? _connectivity;
  Future<void>? _reconfiguring;
  bool _started = false;

  AnnotationSyncCoordinator? get coordinator => _coordinator;
  AnnotationSyncCoordinator? get presentationCoordinator =>
      _presentationCoordinator;
  Stream<void> get statusChanges => _statusChanges.stream;
  Stream<void> get annotationChanges => _annotationChanges.stream;

  Future<AnnotationSyncStatus> get status async {
    final coordinator = await _ensureCoordinator();
    if (coordinator != null) {
      final statuses = await Future.wait([
        coordinator.domainStatus,
        _presentationCoordinator?.domainStatus ??
            Future.value(AnnotationSyncStatus.synced),
      ]);
      if (statuses.contains(AnnotationSyncStatus.syncing)) {
        return AnnotationSyncStatus.syncing;
      }
      if (statuses.contains(AnnotationSyncStatus.error)) {
        return AnnotationSyncStatus.error;
      }
      if (statuses.contains(AnnotationSyncStatus.pendingOffline)) {
        return AnnotationSyncStatus.pendingOffline;
      }
      return AnnotationSyncStatus.synced;
    }
    final dirty = (await sharedState.pendingOutbox()).any((entry) =>
        entry.domain == annotationSyncDomain ||
        entry.domain == anxPresentationSyncDomain);
    return dirty
        ? AnnotationSyncStatus.pendingOffline
        : AnnotationSyncStatus.synced;
  }

  bool get isConfigured {
    if (!Prefs().webdavStatus) return false;
    if ((Prefs().syncProtocol ?? SyncProtocol.webdav.name) !=
        SyncProtocol.webdav.name) {
      return false;
    }
    final config = Prefs().getSyncInfo(SyncProtocol.webdav);
    return (config['url'] as String?)?.trim().isNotEmpty == true;
  }

  String get remoteRoot {
    final config = Prefs().getSyncInfo(SyncProtocol.webdav);
    final configured =
        (config[annotationRemoteRootConfigKey] as String?)?.trim();
    return configured?.isNotEmpty == true
        ? configured!
        : defaultAnnotationRemoteRoot;
  }

  Future<void> start() async {
    if (_started) return;
    _started = true;
    _connectivity = Connectivity().onConnectivityChanged.listen((results) {
      if (results.any((result) => result != ConnectivityResult.none)) {
        unawaited(onConnectivityRegained());
      }
    });
    final library = await _ensureLibraryRepository();
    await library.bootstrap();
    final activity = await _ensureReadingActivityRepository();
    await activity.bootstrap();
    final organization = await _ensureOrganizationRepository();
    await organization.bootstrap();
    await _ensureCoordinator();
    unawaited(_runDiscovery());
  }

  Future<void> reconfigure() {
    final current = _reconfiguring;
    if (current != null) return current;
    final operation = _performReconfigure();
    _reconfiguring = operation;
    operation.then((_) {
      if (identical(_reconfiguring, operation)) _reconfiguring = null;
    }, onError: (_, __) {
      if (identical(_reconfiguring, operation)) _reconfiguring = null;
    });
    return operation;
  }

  Future<void> _performReconfigure() async {
    final old = _coordinator;
    final oldPresentation = _presentationCoordinator;
    final oldLibrary = _libraryService;
    final oldActivity = _readingActivityService;
    final oldOrganization = _organizationService;
    _coordinator = null;
    _presentationCoordinator = null;
    _libraryService = null;
    _readingActivityService = null;
    _organizationService = null;
    await _cancelCoordinatorStatusSubscriptions();
    if (old != null) await old.close();
    if (oldPresentation != null) await oldPresentation.close();
    if (oldLibrary != null) await oldLibrary.close();
    if (oldActivity != null) await oldActivity.close();
    if (oldOrganization != null) await oldOrganization.close();
    _coordinator = _buildCoordinator();
    unawaited(_runDiscovery());
  }

  /// Called synchronously after the canonical transaction commits. There is no
  /// debounce: the outbox is already durable and a flight starts immediately.
  void notifyLocalMutation(String fingerprint) {
    final id = canonicalMd5Fingerprint(fingerprint);
    _annotationChanges.add(null);
    unawaited(_syncTarget(id, localMutation: true));
  }

  void notifyPresentationMutation() {
    _annotationChanges.add(null);
    unawaited(_syncPresentation(localMutation: true));
  }

  Future<void> publishBook(Book book) async {
    final fingerprint = canonicalMd5Fingerprint(book.md5);
    await (await _ensureLibraryRepository()).publishBook(book);
    unawaited(_libraryService?.notifyCatalogMutation(fingerprint));
  }

  /// Records only a real reader mutation. Opening/restoring a book must not
  /// call this API, because doing so would manufacture a newer LWW stamp.
  Future<void> recordReadingProgress(Book book) async {
    final fingerprint = canonicalMd5Fingerprint(book.md5);
    await (await _ensureLibraryRepository()).recordReadingProgress(
      fingerprint: fingerprint,
      position: book.lastReadPosition,
      percentage: book.readingPercentage,
    );
    unawaited(_libraryService?.notifyReadingMutation(fingerprint));
  }

  Future<void> recordReadingActivity({
    required Book book,
    required DateTime startedAt,
    required int durationSeconds,
  }) async {
    final fingerprint = canonicalMd5Fingerprint(book.md5);
    final repository = await _ensureReadingActivityRepository();
    await repository.recordSession(
      fingerprint: fingerprint,
      startedAt: startedAt,
      durationSeconds: durationSeconds,
    );
    final day = startedAt.toLocal().toIso8601String().substring(0, 10);
    unawaited(_readingActivityService
        ?.notifyMutation(readingActivityDocumentId(fingerprint, day)));
  }

  void notifyOrganizationMutation() {
    unawaited(() async {
      await (await _ensureOrganizationRepository()).bootstrap();
      await _organizationService?.syncKnown(sharedState);
    }());
  }

  Future<void> tombstoneTag(int localId) async {
    await (await _ensureOrganizationRepository())
        .tombstoneLocalRecord(tagDomain, 'sync_tag_ids', localId);
    unawaited(_organizationService?.syncKnown(sharedState));
  }

  Future<void> tombstoneTheme(int localId) async {
    await (await _ensureOrganizationRepository())
        .tombstoneLocalRecord(themeDomain, 'sync_theme_ids', localId);
    unawaited(_organizationService?.syncKnown(sharedState));
  }

  Future<void> publishBookTag(int bookId, int tagLocalId, bool present) async {
    await (await _ensureOrganizationRepository())
        .publishBookTagByLocalIds(bookId, tagLocalId, present);
    unawaited(_organizationService?.syncKnown(sharedState));
  }

  Future<void> syncNow() => _runDiscovery();
  Future<void> onResume() => _runDiscovery();
  Future<void> onConnectivityRegained() => _runDiscovery();

  void bestEffortFlush() {
    final coordinator = _coordinator;
    if (coordinator != null) unawaited(coordinator.syncDirtyAnnotations());
    final presentations = _presentationCoordinator;
    if (presentations != null) {
      unawaited(presentations.syncDirtyAnnotations());
    }
  }

  Future<void> openBook(
      String fingerprint, void Function() refreshOpenReader) async {
    final id = canonicalMd5Fingerprint(fingerprint);
    _openBookRefresh.putIfAbsent(id, () => {}).add(refreshOpenReader);
    unawaited(_syncTarget(id));
  }

  void closeBook(String fingerprint, void Function() refreshOpenReader) {
    final id = canonicalMd5Fingerprint(fingerprint);
    final listeners = _openBookRefresh[id];
    listeners?.remove(refreshOpenReader);
    if (listeners?.isEmpty == true) _openBookRefresh.remove(id);
    bestEffortFlush();
  }

  Future<AnnotationSyncCoordinator?> _ensureCoordinator() async {
    final reconfiguring = _reconfiguring;
    if (reconfiguring != null) {
      await reconfiguring;
      return _coordinator;
    }
    if (!isConfigured) return null;
    if (_coordinator != null) return _coordinator;
    return _coordinator = _buildCoordinator();
  }

  AnnotationSyncCoordinator? _buildCoordinator() {
    if (!isConfigured) return null;
    final config = Prefs().getSyncInfo(SyncProtocol.webdav);
    final uri = Uri.parse((config['url'] as String).trim());
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 15),
      sendTimeout: const Duration(seconds: 15),
    ));
    final transport = ConditionalWebDavTransport(
      baseUri: uri,
      remoteRoot: remoteRoot,
      executor: DioWebDavRequestExecutor(dio),
      username: config['username'] as String?,
      password: config['password'] as String?,
    );
    final annotations = AnnotationSyncCoordinator(
      sharedState: sharedState,
      transport: transport,
      onDocumentChanged: (fingerprint) {
        _annotationChanges.add(null);
        for (final refresh in List<void Function()>.from(
            _openBookRefresh[fingerprint] ?? {})) {
          refresh();
        }
      },
    );
    final libraryRepository = _libraryRepository;
    if (libraryRepository != null) {
      _libraryService = LibrarySyncService(
        sharedState: sharedState,
        repository: libraryRepository,
        transport: transport,
      );
    }
    final activityRepository = _readingActivityRepository;
    if (activityRepository != null) {
      _readingActivityService = ReadingActivitySyncService(
        sharedState: sharedState,
        repository: activityRepository,
        transport: transport,
      );
    }
    final organizationRepository = _organizationRepository;
    if (organizationRepository != null) {
      _organizationService = OrganizationSyncService(
        sharedState: sharedState,
        repository: organizationRepository,
        transport: transport,
      );
    }
    _presentationCoordinator = AnnotationSyncCoordinator(
      sharedState: sharedState,
      transport: transport,
      syncDomain: anxPresentationSyncDomain,
      normalizeDocumentId: (_) => anxPresentationDocumentId,
      remotePathFor: anxPresentationRemotePath,
      decodeDocument: decodeAnxPresentationDocument,
      mergeDocuments: mergeAnxPresentationDocuments,
      validateDocumentId: (_, id) => id == anxPresentationDocumentId,
      onDocumentChanged: (_) {
        _annotationChanges.add(null);
        for (final refreshes in _openBookRefresh.values) {
          for (final refresh in List<void Function()>.from(refreshes)) {
            refresh();
          }
        }
      },
    );
    _coordinatorStatusSubscriptions.addAll([
      annotations.statusChanges.listen((_) => _emitStatus()),
      _presentationCoordinator!.statusChanges.listen((_) => _emitStatus()),
    ]);
    return annotations;
  }

  Future<void> _syncTarget(String fingerprint,
      {bool localMutation = false}) async {
    final coordinator = await _ensureCoordinator();
    if (coordinator == null || !await _networkPolicyAllowsSync()) return;
    try {
      if (localMutation) {
        await coordinator.notifyDirty(fingerprint);
      } else {
        await coordinator.syncBook(fingerprint);
      }
    } catch (error, stackTrace) {
      AnxLog.warning('Annotation sync failed for $fingerprint: '
          '$error\n$stackTrace');
    }
  }

  Future<void> _syncPresentation({bool localMutation = false}) async {
    await _ensureCoordinator();
    final coordinator = _presentationCoordinator;
    if (coordinator == null || !await _networkPolicyAllowsSync()) return;
    try {
      if (localMutation) {
        await coordinator.notifyDirty(anxPresentationDocumentId);
      } else {
        await coordinator.syncBook(anxPresentationDocumentId);
      }
    } catch (error, stackTrace) {
      AnxLog.warning('Anx presentation sync failed: $error\n$stackTrace');
    }
  }

  Future<void> _runDiscovery() async {
    final coordinator = await _ensureCoordinator();
    if (coordinator == null || !await _networkPolicyAllowsSync()) return;
    await (await _ensureOrganizationRepository()).bootstrap();
    final fingerprints = await _knownFingerprints();
    await Future.wait([
      coordinator.syncDirtyAnnotations(),
      coordinator.pullBooks(fingerprints),
      _presentationCoordinator!.syncDirtyAnnotations(),
      _presentationCoordinator!.pullBooks([anxPresentationDocumentId]),
      if (_libraryService != null) _libraryService!.syncKnown(fingerprints),
      if (_readingActivityService != null)
        _readingActivityService!
            .syncKnown(await sharedState.documentIds(readingActivityDomain)),
      if (_organizationService != null)
        _organizationService!.syncKnown(sharedState),
    ]);
  }

  Future<LibrarySyncRepository> _ensureLibraryRepository() async {
    final current = _libraryRepository;
    if (current != null) return current;
    final repository = LibrarySyncRepository(
      sharedState: sharedState,
      projection: SqliteLibraryProjection(),
      deviceId: await LibrarySyncRepository.ensureDeviceId(sharedState),
    );
    return _libraryRepository = repository;
  }

  Future<ReadingActivityRepository> _ensureReadingActivityRepository() async {
    final current = _readingActivityRepository;
    if (current != null) return current;
    final repository = ReadingActivityRepository(
      sharedState: sharedState,
      projection: SqliteReadingActivityProjection(),
      deviceId: await LibrarySyncRepository.ensureDeviceId(sharedState),
    );
    return _readingActivityRepository = repository;
  }

  Future<OrganizationRepository> _ensureOrganizationRepository() async {
    final current = _organizationRepository;
    if (current != null) return current;
    final repository = OrganizationRepository(
      sharedState: sharedState,
      deviceId: await LibrarySyncRepository.ensureDeviceId(sharedState),
    );
    return _organizationRepository = repository;
  }

  Future<bool> _networkPolicyAllowsSync() async {
    final connectivity = await Connectivity().checkConnectivity();
    if (connectivity.contains(ConnectivityResult.none)) return false;
    return !Prefs().onlySyncWhenWifi ||
        connectivity.contains(ConnectivityResult.wifi);
  }

  Future<Set<String>> _knownFingerprints() async {
    final result = <String>{..._openBookRefresh.keys};
    for (final book in await bookDao.selectNotDeleteBooks()) {
      if (p.extension(book.filePath).toLowerCase() != '.epub') continue;
      try {
        final fingerprint = canonicalMd5Fingerprint(book.md5);
        result.add(fingerprint);
        final document = await sharedState.annotationDocument(fingerprint);
        if (document != null &&
            applyAnnotationBookMetadata(
              document,
              title: book.title,
              author: book.author,
            )) {
          // Metadata-only enrichment is a normal v2 canonical mutation. The
          // durable outbox makes old fingerprint-only documents converge on
          // their next ordinary synchronization pass.
          await sharedState.putAnnotationDocument(document);
        }
      } on AnnotationProtocolException {
        // Legacy/unresolved books remain local until they have portable MD5.
      }
    }
    return result;
  }

  Future<void> close() async {
    await _connectivity?.cancel();
    _connectivity = null;
    await _reconfiguring;
    await _cancelCoordinatorStatusSubscriptions();
    await _coordinator?.close();
    await _presentationCoordinator?.close();
    await _libraryService?.close();
    await _readingActivityService?.close();
    await _organizationService?.close();
    _coordinator = null;
    _presentationCoordinator = null;
    _libraryService = null;
    _readingActivityService = null;
    _organizationService = null;
    await sharedState.close();
    _started = false;
  }

  void _emitStatus() {
    if (!_statusChanges.isClosed) _statusChanges.add(null);
  }

  Future<void> _cancelCoordinatorStatusSubscriptions() async {
    final subscriptions =
        List<StreamSubscription<void>>.from(_coordinatorStatusSubscriptions);
    _coordinatorStatusSubscriptions.clear();
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
  }
}

final annotationSyncRuntime = AnnotationSyncRuntime.instance;
