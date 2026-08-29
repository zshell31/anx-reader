import 'dart:async';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/enums/sync_protocol.dart';
import 'package:anx_reader/service/sync/annotation_projection_reconciler.dart';
import 'package:anx_reader/service/sync/annotation_protocol.dart';
import 'package:anx_reader/service/sync/annotation_sync_coordinator.dart';
import 'package:anx_reader/service/sync/conditional_webdav_transport.dart';
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
  StreamSubscription<List<ConnectivityResult>>? _connectivity;
  Future<void>? _reconfiguring;
  bool _started = false;

  AnnotationSyncCoordinator? get coordinator => _coordinator;
  Stream<void> get statusChanges =>
      _coordinator?.statusChanges ?? const Stream<void>.empty();

  Future<AnnotationSyncStatus> get status async {
    final coordinator = await _ensureCoordinator();
    if (coordinator != null) return coordinator.domainStatus;
    final dirty = (await sharedState.pendingOutbox())
        .any((entry) => entry.domain == annotationSyncDomain);
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
    _coordinator = null;
    if (old != null) await old.close();
    _coordinator = _buildCoordinator();
    unawaited(_runDiscovery());
  }

  /// Called synchronously after the canonical transaction commits. There is no
  /// debounce: the outbox is already durable and a flight starts immediately.
  void notifyLocalMutation(String fingerprint) {
    final id = canonicalMd5Fingerprint(fingerprint);
    unawaited(_syncTarget(id, localMutation: true));
  }

  Future<void> syncNow() => _runDiscovery();
  Future<void> onResume() => _runDiscovery();
  Future<void> onConnectivityRegained() => _runDiscovery();

  void bestEffortFlush() {
    final coordinator = _coordinator;
    if (coordinator != null) unawaited(coordinator.syncDirtyAnnotations());
  }

  Future<void> openBook(
      String fingerprint, void Function() refreshOpenReader) async {
    final id = canonicalMd5Fingerprint(fingerprint);
    _openBookRefresh.putIfAbsent(id, () => {}).add(refreshOpenReader);
    try {
      final result =
          await AnnotationProjectionReconciler(sharedState).reconcileBook(id);
      if (result.nativeWrites > 0) refreshOpenReader();
    } catch (error, stackTrace) {
      AnxLog.warning(
          'Annotation book-open reconciliation failed: $error\n$stackTrace');
    }
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
    return AnnotationSyncCoordinator(
      sharedState: sharedState,
      transport: transport,
      reconcileProjection: (fingerprint) =>
          AnnotationProjectionReconciler(sharedState)
              .reconcileBook(fingerprint),
      onProjectionChanged: (fingerprint, _) {
        for (final refresh in List<void Function()>.from(
            _openBookRefresh[fingerprint] ?? {})) {
          refresh();
        }
      },
    );
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

  Future<void> _runDiscovery() async {
    final coordinator = await _ensureCoordinator();
    if (coordinator == null || !await _networkPolicyAllowsSync()) return;
    await Future.wait([
      coordinator.syncDirtyAnnotations(),
      coordinator.pullBooks(await _knownFingerprints()),
    ]);
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
    await _coordinator?.close();
    _coordinator = null;
    await sharedState.close();
    _started = false;
  }
}

final annotationSyncRuntime = AnnotationSyncRuntime.instance;
