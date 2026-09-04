import 'dart:async';
import 'dart:convert';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/enums/sync_protocol.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/service/sync/annotation_audio_asset_sync.dart';
import 'package:anx_reader/service/sync/annotation_protocol.dart';
import 'package:anx_reader/service/sync/annotation_presentation_protocol.dart';
import 'package:anx_reader/service/sync/annotation_sync_coordinator.dart';
import 'package:anx_reader/service/sync/conditional_webdav_transport.dart';
import 'package:anx_reader/service/sync/library_sync_repository.dart';
import 'package:anx_reader/service/sync/library_sync_service.dart';
import 'package:anx_reader/service/sync/library_protocol.dart';
import 'package:anx_reader/service/sync/library_asset_sync.dart';
import 'package:anx_reader/service/sync/reading_activity_protocol.dart';
import 'package:anx_reader/service/sync/reading_activity_repository.dart';
import 'package:anx_reader/service/sync/reading_activity_sync_service.dart';
import 'package:anx_reader/service/sync/organization_repository.dart';
import 'package:anx_reader/service/sync/organization_sync_service.dart';
import 'package:anx_reader/service/sync/remote_document_discovery.dart';
import 'package:anx_reader/service/sync/shared_state_database.dart';
import 'package:anx_reader/service/sync/sync_run_gate.dart';
import 'package:anx_reader/service/sync/sync_diagnostics.dart';
import 'package:anx_reader/service/sync/sync_summary.dart';
import 'package:anx_reader/service/sync/sync_client_factory.dart';
import 'package:anx_reader/service/sync/sync_client_base.dart';
import 'package:anx_reader/service/sync/translation_cache_sync_service.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:crypto/crypto.dart';
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

  static const assetPresenceReceiptLifetime = Duration(hours: 24);

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
  final StreamController<void> _assetChanges =
      StreamController<void>.broadcast();
  final List<StreamSubscription<void>> _coordinatorStatusSubscriptions = [];
  final SyncRunGate _runGate = SyncRunGate();
  StreamSubscription<List<ConnectivityResult>>? _connectivity;
  Future<void>? _reconfiguring;
  ConditionalWebDavTransport? _documentTransport;
  SyncClientBase? _auxiliarySyncClient;
  LibraryAssetSyncService? _assetSyncService;
  AnnotationAudioAssetSyncService? _annotationAudioAssetSyncService;
  TranslationCacheSyncService? _translationCacheSyncService;
  DateTime? _lastCompletedAt;
  int _lastDiscoveredDocumentCount = 0;
  bool _lastRunFailed = false;
  bool _started = false;
  String _pendingTrigger = 'startup';
  String? _lastSkipReason;

  AnnotationSyncCoordinator? get coordinator => _coordinator;
  AnnotationSyncCoordinator? get presentationCoordinator =>
      _presentationCoordinator;
  Stream<void> get statusChanges => _statusChanges.stream;
  Stream<void> get annotationChanges => _annotationChanges.stream;
  Stream<void> get assetChanges => _assetChanges.stream;

  Future<AnnotationSyncStatus> get status async => (await summary).status;

  Future<SharedSyncSummary> get summary async {
    await _ensureLibraryRepository();
    await _ensureReadingActivityRepository();
    await _ensureOrganizationRepository();
    await _ensureCoordinator();
    final coordinators = _allCoordinators;
    final statuses = await Future.wait(
        coordinators.map((coordinator) => coordinator.domainStatus));
    final pending = await sharedState.pendingOutbox();
    final active = coordinators.fold(
        0, (total, coordinator) => total + coordinator.activeDocumentCount);
    final failed = pending.where((entry) => entry.lastError != null).length;
    final overall =
        active > 0 || statuses.contains(AnnotationSyncStatus.syncing)
            ? AnnotationSyncStatus.syncing
            : _lastRunFailed || statuses.contains(AnnotationSyncStatus.error)
                ? AnnotationSyncStatus.error
                : pending.isNotEmpty ||
                        statuses.contains(AnnotationSyncStatus.pendingOffline)
                    ? AnnotationSyncStatus.pendingOffline
                    : AnnotationSyncStatus.synced;
    return SharedSyncSummary(
      status: overall,
      activeDocumentCount: active,
      pendingDocumentCount: pending.length,
      failedDocumentCount: failed,
      discoveredDocumentCount: _lastDiscoveredDocumentCount,
      lastCompletedAt: _lastCompletedAt,
    );
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
    final library = await _ensureLibraryRepository();
    await library.bootstrap();
    final activity = await _ensureReadingActivityRepository();
    await activity.bootstrap();
    final organization = await _ensureOrganizationRepository();
    await organization.bootstrap();
    await _ensureCoordinator();
    _connectivity = Connectivity().onConnectivityChanged.listen((results) {
      if (results.any((result) => result != ConnectivityResult.none)) {
        unawaited(onConnectivityRegained());
      }
    });
    unawaited(_runDiscovery(trigger: 'startup'));
  }

  Future<void> reconfigure() {
    final current = _reconfiguring;
    if (current != null) return current;
    final operation = _performReconfigure();
    _reconfiguring = operation;
    operation.then((_) {
      if (identical(_reconfiguring, operation)) {
        _reconfiguring = null;
        unawaited(_runDiscovery(trigger: 'mutation'));
      }
    }, onError: (_, __) {
      if (identical(_reconfiguring, operation)) _reconfiguring = null;
    });
    return operation;
  }

  Future<void> _performReconfigure() async {
    await _runGate.idle;
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
    _documentTransport = null;
    _auxiliarySyncClient = null;
    _assetSyncService = null;
    _annotationAudioAssetSyncService = null;
    _translationCacheSyncService = null;
    await _cancelCoordinatorStatusSubscriptions();
    if (old != null) await old.close();
    if (oldPresentation != null) await oldPresentation.close();
    if (oldLibrary != null) await oldLibrary.close();
    if (oldActivity != null) await oldActivity.close();
    if (oldOrganization != null) await oldOrganization.close();
    _coordinator = _buildCoordinator();
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
    if (Prefs().autoSync) {
      unawaited(_libraryService?.notifyCatalogMutation(fingerprint));
    }
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
    if (Prefs().autoSync) {
      unawaited(_libraryService?.notifyReadingMutation(fingerprint));
    }
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
    if (Prefs().autoSync) {
      unawaited(_readingActivityService
          ?.notifyMutation(readingActivityDocumentId(fingerprint, day)));
    }
  }

  Future<void> deleteReadingHistory(Iterable<int> localBookIds) async {
    final fingerprints = <String>[];
    for (final id in localBookIds) {
      try {
        fingerprints.add(
            canonicalMd5Fingerprint((await bookDao.selectBookById(id)).md5));
      } catch (_) {
        // Books without a portable identity keep device-local history only.
      }
    }
    final changed = await (await _ensureReadingActivityRepository())
        .deleteHistoryForFingerprints(fingerprints);
    if (Prefs().autoSync) {
      for (final id in changed) {
        unawaited(_readingActivityService?.notifyMutation(id));
      }
    }
  }

  void notifyOrganizationMutation() {
    unawaited(() async {
      await (await _ensureOrganizationRepository()).bootstrap();
      if (Prefs().autoSync) {
        await _organizationService?.syncKnown(sharedState);
      }
    }());
  }

  Future<void> tombstoneTag(int localId) async {
    await (await _ensureOrganizationRepository()).tombstoneTag(localId);
    if (Prefs().autoSync) {
      unawaited(_organizationService?.syncKnown(sharedState));
    }
  }

  Future<void> tombstoneGroup(int localId) async {
    await (await _ensureOrganizationRepository()).tombstoneGroup(localId);
    if (Prefs().autoSync) {
      unawaited(_organizationService?.syncKnown(sharedState));
    }
  }

  Future<void> tombstoneTheme(int localId) async {
    await (await _ensureOrganizationRepository()).tombstoneTheme(localId);
    if (Prefs().autoSync) {
      unawaited(_organizationService?.syncKnown(sharedState));
    }
  }

  Future<void> publishBookTag(int bookId, int tagLocalId, bool present) async {
    await (await _ensureOrganizationRepository())
        .publishBookTagByLocalIds(bookId, tagLocalId, present);
    if (Prefs().autoSync) {
      unawaited(_organizationService?.syncKnown(sharedState));
    }
  }

  Future<void> publishBookGroup(Book book) async {
    final repository = await _ensureOrganizationRepository();
    await repository.bootstrap();
    await repository.publishBookGroupByLocalIds(book.id, book.groupId);
    final fingerprint = canonicalMd5Fingerprint(book.md5);
    if (Prefs().autoSync) {
      unawaited(_libraryService?.notifyCatalogMutation(fingerprint));
    }
  }

  Future<void> syncNow() => _runDiscovery(manual: true, trigger: 'manual');
  Future<void> syncAutomatic({String trigger = 'mutation'}) =>
      _runDiscovery(trigger: trigger);
  Future<void> onResume() => _runDiscovery(trigger: 'resume');
  Future<void> onConnectivityRegained() =>
      _runDiscovery(trigger: 'connectivity');

  void bestEffortFlush() {
    if (!Prefs().autoSync) return;
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
    _documentTransport = transport;
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
      for (final coordinator in _allCoordinators)
        coordinator.statusChanges.listen((_) => _emitStatus()),
    ]);
    return annotations;
  }

  Future<void> _syncTarget(String fingerprint,
      {bool localMutation = false}) async {
    if (!Prefs().autoSync) return;
    final coordinator = await _ensureCoordinator();
    if (coordinator == null || !await _networkPolicyAllowsSync()) return;
    try {
      if (localMutation) {
        await _syncAnnotationAudioAssetsFor(fingerprint);
        await coordinator.notifyDirty(fingerprint);
      } else {
        await coordinator.syncBook(fingerprint);
        await _syncAnnotationAudioAssetsFor(fingerprint);
      }
    } catch (error) {
      AnxLog.warning('Shared sync target failed domain=$annotationSyncDomain '
          'error=${safeSyncError(error)}');
    }
  }

  Future<void> _syncPresentation({bool localMutation = false}) async {
    if (!Prefs().autoSync) return;
    await _ensureCoordinator();
    final coordinator = _presentationCoordinator;
    if (coordinator == null || !await _networkPolicyAllowsSync()) return;
    try {
      if (localMutation) {
        await coordinator.notifyDirty(anxPresentationDocumentId);
      } else {
        await coordinator.syncBook(anxPresentationDocumentId);
      }
    } catch (error) {
      AnxLog.warning('Shared sync target failed '
          'domain=$anxPresentationSyncDomain error=${safeSyncError(error)}');
    }
  }

  Future<void> _runDiscovery({bool manual = false, required String trigger}) {
    if (!manual && !Prefs().autoSync) {
      _logSkip('auto-disabled');
      return Future.value();
    }
    final passiveTrigger = trigger == 'startup' ||
        trigger == 'connectivity' ||
        trigger == 'resume';
    final queueFollowUp = manual || !passiveTrigger;
    if (!_runGate.isRunning || queueFollowUp) {
      _pendingTrigger = trigger;
    } else {
      syncDebug('trigger=$trigger coalesced=active-run');
    }
    final reconfiguring = _reconfiguring;
    return reconfiguring ??
        _runGate.run(
          () {
            final passTrigger = _pendingTrigger;
            return runWithSyncDiagnostics(
                passTrigger, (_) => _runDiscoveryPass(passTrigger));
          },
          queueFollowUp: queueFollowUp,
        );
  }

  Future<void> _runDiscoveryPass(String trigger) async {
    final startedAt = DateTime.now();
    var attempted = false;
    Object? fatalError;
    _lastRunFailed = false;
    _emitStatus();
    try {
      await _ensureLibraryRepository();
      await _ensureReadingActivityRepository();
      await _ensureOrganizationRepository();
      final coordinator = await _ensureCoordinator();
      if (coordinator == null) {
        _logSkip('not-configured');
        return;
      }
      if (!await _networkPolicyAllowsSync()) return;
      attempted = true;
      _lastSkipReason = null;
      syncInfo('started trigger=$trigger auto=${Prefs().autoSync} '
          'wifiOnly=${Prefs().onlySyncWhenWifi}');
      syncDebug('phase=bootstrap started');
      await (await _ensureOrganizationRepository()).bootstrap();
      syncDebug('phase=bootstrap completed');
      syncDebug('phase=discovery started');
      var remote = const RemoteDocumentIndex({});
      var remoteIndexAuthoritative = false;
      final transport = _documentTransport;
      if (transport != null) {
        try {
          remote = await RemoteDocumentDiscovery(transport.list).discover();
          remoteIndexAuthoritative = true;
        } catch (error) {
          _lastRunFailed = true;
          syncWarning('phase=discovery failed '
              'error=${safeSyncError(error)}');
        }
      }
      _lastDiscoveredDocumentCount = remote.documentCount;
      syncDebug('phase=discovery completed '
          'documents=${remote.documentCount}');
      final initialFingerprints = {
        ...await _knownFingerprints(),
        ...remote.ids(annotationSyncDomain),
        ...remote.ids(libraryCatalogDomain),
        ...remote.ids(readingStateDomain),
      };
      if (_organizationService != null) {
        syncDebug('phase=organization started');
        await _organizationService!.syncKnown(
          sharedState,
          remoteIdsByDomain: remote.idsByDomain,
          remoteStrongEtagsByDomain: remote.strongEtagsByDomain,
          remoteIndexAuthoritative: remoteIndexAuthoritative,
        );
        syncDebug('phase=organization completed');
      }
      syncDebug('phase=catalog started');
      await _libraryService?.syncCatalog(
        remoteDocumentPullTargets(
          localIds: initialFingerprints,
          remoteIds: remote.ids(libraryCatalogDomain),
          remoteIndexAuthoritative: remoteIndexAuthoritative,
        ),
        remoteStrongEtags: remote.strongEtags(libraryCatalogDomain),
      );
      syncDebug('phase=catalog completed');
      syncDebug('phase=assets started');
      await _syncSharedLibraryAssets();
      syncDebug('phase=assets completed');
      _emitAssetChanges();
      final fingerprints = {
        ...initialFingerprints,
        ...await _knownFingerprints(),
        ...await sharedState.documentIds(libraryCatalogDomain),
      };
      syncDebug('phase=content-domains started');
      await Future.wait([
        coordinator.syncKnown(
          remoteDocumentPullTargets(
            localIds: fingerprints,
            remoteIds: remote.ids(annotationSyncDomain),
            remoteIndexAuthoritative: remoteIndexAuthoritative,
          ),
          discoveredStrongEtags: remote.strongEtags(annotationSyncDomain),
        ),
        _presentationCoordinator!.syncKnown([anxPresentationDocumentId]),
        if (_libraryService != null)
          _libraryService!.syncReadingState(
            remoteDocumentPullTargets(
              localIds: fingerprints,
              remoteIds: remote.ids(readingStateDomain),
              remoteIndexAuthoritative: remoteIndexAuthoritative,
            ),
            remoteStrongEtags: remote.strongEtags(readingStateDomain),
          ),
        if (_readingActivityService != null)
          _readingActivityService!.syncKnown(
            remoteDocumentPullTargets(
              localIds: await sharedState.documentIds(readingActivityDomain),
              remoteIds: remote.ids(readingActivityDomain),
              remoteIndexAuthoritative: remoteIndexAuthoritative,
            ),
            remoteStrongEtags: remote.strongEtags(readingActivityDomain),
          ),
      ]);
      syncDebug('phase=content-domains completed');
      syncDebug('phase=annotation-audio-assets started');
      await _syncSharedAnnotationAudioAssets();
      syncDebug('phase=annotation-audio-assets completed');
      await _syncTranslationCacheBestEffort();
    } catch (error) {
      _lastRunFailed = true;
      fatalError = error;
    } finally {
      if (attempted) {
        _lastCompletedAt = DateTime.now().toUtc();
        var pending = -1;
        var failed = -1;
        try {
          final outbox = await sharedState.pendingOutbox();
          pending = outbox.length;
          failed = outbox.where((entry) => entry.lastError != null).length;
        } catch (_) {
          _lastRunFailed = true;
        }
        final duration = DateTime.now().difference(startedAt).inMilliseconds;
        if (fatalError == null) {
          syncInfo('completed discovered=$_lastDiscoveredDocumentCount '
              'pending=$pending failed=$failed durationMs=$duration');
        } else {
          syncWarning('failed error=${safeSyncError(fatalError)} '
              'discovered=$_lastDiscoveredDocumentCount pending=$pending '
              'failed=$failed durationMs=$duration');
        }
      }
      _emitStatus();
    }
  }

  Future<void> _syncSharedLibraryAssets() async {
    if (SyncClientFactory.currentClient == null) {
      SyncClientFactory.initializeCurrentClient();
    }
    final client = SyncClientFactory.currentClient;
    if (client == null) return;
    _ensureAuxiliarySyncServices(client);
    final service = _assetSyncService!;
    var checked = 0;
    var uploaded = 0;
    var downloaded = 0;
    var released = 0;
    var missing = 0;
    var trustedRemote = 0;
    for (final id in await sharedState.documentIds(libraryCatalogDomain)) {
      final bytes =
          await sharedState.canonicalDocument(libraryCatalogDomain, id);
      if (bytes == null) continue;
      checked++;
      final document =
          decodeLibraryCatalogDocument(jsonDecode(utf8.decode(bytes)));
      final knownRemote = await _knownRemoteAsset(document);
      if (knownRemote == true) trustedRemote++;
      final result = await service.syncBook(
        document,
        knownBookRemote: knownRemote,
      );
      final availability = await service.bookAvailability(
        document,
        knownRemote: knownRemote,
      );
      await _recordAssetPresence(
        document,
        availability.remote,
        refresh: knownRemote == null,
      );
      if (result.uploaded) uploaded++;
      if (result.downloaded) downloaded++;
      if (result.released) released++;
      if (result.missing) missing++;
    }
    syncInfo('assets checked=$checked uploaded=$uploaded '
        'downloaded=$downloaded released=$released missing=$missing '
        'trustedRemote=$trustedRemote');
  }

  Future<void> _syncTranslationCacheBestEffort() async {
    final client = SyncClientFactory.currentClient;
    if (client == null) return;
    _ensureAuxiliarySyncServices(client);
    syncDebug('phase=translation-cache started');
    try {
      await _translationCacheSyncService!.sync();
      syncDebug('phase=translation-cache completed');
    } catch (error) {
      syncWarning('phase=translation-cache failed '
          'error=${safeSyncError(error)}');
    }
  }

  Future<void> _syncSharedAnnotationAudioAssets() async {
    var uploaded = 0;
    var downloaded = 0;
    var missing = 0;
    for (final fingerprint
        in await sharedState.documentIds(annotationSyncDomain)) {
      final result = await _syncAnnotationAudioAssetsFor(fingerprint);
      uploaded += result.uploaded;
      downloaded += result.downloaded;
      missing += result.missing;
    }
    syncInfo('annotationAudioAssets uploaded=$uploaded '
        'downloaded=$downloaded missing=$missing');
  }

  Future<AnnotationAudioAssetSyncResult> _syncAnnotationAudioAssetsFor(
    String fingerprint,
  ) async {
    if (SyncClientFactory.currentClient == null) {
      SyncClientFactory.initializeCurrentClient();
    }
    final client = SyncClientFactory.currentClient;
    if (client == null) return const AnnotationAudioAssetSyncResult();
    _ensureAuxiliarySyncServices(client);
    final bytes = await sharedState.canonicalDocument(
      annotationSyncDomain,
      canonicalMd5Fingerprint(fingerprint),
    );
    if (bytes == null) return const AnnotationAudioAssetSyncResult();
    final document = decodeAnnotationDocument(jsonDecode(utf8.decode(bytes)));
    return _annotationAudioAssetSyncService!.syncDocument(document);
  }

  void _ensureAuxiliarySyncServices(SyncClientBase client) {
    if (identical(_auxiliarySyncClient, client)) return;
    _auxiliarySyncClient = client;
    _assetSyncService = LibraryAssetSyncService(
      transport: SyncClientLibraryAssetTransport(client),
      projection: SqliteLibraryProjection(),
      isReleased: (fingerprint, digest) async {
        final receipt = await sharedState.importReceipt(
            libraryAssetReleaseSource, fingerprint);
        return receipt?.status == 'released' && receipt?.sharedId == digest;
      },
      loadLocalVerification: _loadLocalAssetVerification,
      saveLocalVerification: _saveLocalAssetVerification,
    );
    _annotationAudioAssetSyncService = AnnotationAudioAssetSyncService(
      transport: SyncClientAnnotationAudioAssetTransport(client),
      remoteRoot: remoteRoot,
    );
    _translationCacheSyncService = TranslationCacheSyncService(client: client);
  }

  Future<LibraryBookAssetAvailability?> bookAssetAvailability(
      Map<String, dynamic> catalogDocument) async {
    if (SyncClientFactory.currentClient == null) {
      SyncClientFactory.initializeCurrentClient();
    }
    final client = SyncClientFactory.currentClient;
    if (client == null) return null;
    _ensureAuxiliarySyncServices(client);
    final document = decodeLibraryCatalogDocument(catalogDocument);
    final knownRemote = await _knownRemoteAsset(document);
    return _assetSyncService!.bookAvailability(
      document,
      knownRemote: knownRemote,
    );
  }

  Future<void> _recordAssetPresence(
    Map<String, dynamic> catalogDocument,
    bool remote, {
    bool refresh = false,
  }) async {
    final fingerprint = catalogDocument['fingerprint'] as String;
    final asset = (catalogDocument['bookAsset']
        as Map<String, dynamic>)['value'] as Map<String, dynamic>;
    final digest = (asset['digest'] as String).toLowerCase();
    final status = remote ? 'present' : 'missing';
    final current = await sharedState.importReceipt(
        libraryAssetPresenceSource, fingerprint);
    if (!refresh && current?.sharedId == digest && current?.status == status) {
      return;
    }
    await sharedState.recordImport(
      source: libraryAssetPresenceSource,
      sourceKey: fingerprint,
      sharedId: digest,
      status: status,
    );
  }

  Future<bool?> _knownRemoteAsset(Map<String, dynamic> catalogDocument) async {
    final fingerprint = catalogDocument['fingerprint'] as String;
    final asset = (catalogDocument['bookAsset']
        as Map<String, dynamic>)['value'] as Map<String, dynamic>;
    final digest = (asset['digest'] as String).toLowerCase();
    final receipt = await sharedState.importReceipt(
        libraryAssetPresenceSource, fingerprint);
    if (receipt?.status != 'present' || receipt?.sharedId != digest) {
      return null;
    }
    final expiresAt = receipt!.importedAt.add(assetPresenceReceiptLifetime);
    return DateTime.now().toUtc().isBefore(expiresAt) ? true : null;
  }

  String _localAssetVerificationKey(String path) =>
      sha256.convert(utf8.encode(path)).toString();

  Future<LibraryLocalAssetVerification?> _loadLocalAssetVerification(
      String path) async {
    final receipt = await sharedState.importReceipt(
      libraryLocalAssetVerificationSource,
      _localAssetVerificationKey(path),
    );
    if (receipt?.status != 'verified' ||
        receipt?.sharedId == null ||
        receipt?.detail == null) {
      return null;
    }
    try {
      final detail = jsonDecode(receipt!.detail!) as Map<String, dynamic>;
      return LibraryLocalAssetVerification(
        digest: receipt.sharedId!,
        size: detail['size'] as int,
        modified: DateTime.parse(detail['modified'] as String),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveLocalAssetVerification(
    String path,
    LibraryLocalAssetVerification? verification,
  ) async {
    final key = _localAssetVerificationKey(path);
    final current = await sharedState.importReceipt(
      libraryLocalAssetVerificationSource,
      key,
    );
    if (verification == null) {
      if (current == null || current.status == 'invalid') return;
      await sharedState.recordImport(
        source: libraryLocalAssetVerificationSource,
        sourceKey: key,
        status: 'invalid',
      );
      return;
    }
    final detail = jsonEncode({
      'size': verification.size,
      'modified': verification.modified.toUtc().toIso8601String(),
    });
    if (current?.status == 'verified' &&
        current?.sharedId == verification.digest &&
        current?.detail == detail) {
      return;
    }
    await sharedState.recordImport(
      source: libraryLocalAssetVerificationSource,
      sourceKey: key,
      sharedId: verification.digest,
      status: 'verified',
      detail: detail,
    );
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
    if (connectivity.contains(ConnectivityResult.none)) {
      _logSkip('no-network');
      return false;
    }
    final allowed = !Prefs().onlySyncWhenWifi ||
        connectivity.contains(ConnectivityResult.wifi);
    if (!allowed) _logSkip('wifi-policy');
    return allowed;
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
    await _runGate.idle;
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
    _documentTransport = null;
    _auxiliarySyncClient = null;
    _assetSyncService = null;
    _annotationAudioAssetSyncService = null;
    _translationCacheSyncService = null;
    await sharedState.close();
    _started = false;
  }

  void _emitStatus() {
    if (!_statusChanges.isClosed) _statusChanges.add(null);
  }

  void _emitAssetChanges() {
    if (!_assetChanges.isClosed) _assetChanges.add(null);
  }

  List<SharedDocumentSyncCoordinator> get _allCoordinators => [
        if (_coordinator != null) _coordinator!,
        if (_presentationCoordinator != null) _presentationCoordinator!,
        if (_libraryService != null) ...[
          _libraryService!.catalog,
          _libraryService!.readingState,
        ],
        if (_readingActivityService != null)
          _readingActivityService!.coordinator,
        if (_organizationService != null) ..._organizationService!.coordinators,
      ];

  void _logSkip(String reason) {
    if (_lastSkipReason == reason) return;
    _lastSkipReason = reason;
    syncInfo('skipped reason=$reason');
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
