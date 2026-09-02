import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:anx_reader/service/sync/annotation_protocol.dart';
import 'package:anx_reader/service/sync/conditional_webdav_transport.dart';
import 'package:anx_reader/service/sync/sync_diagnostics.dart';
import 'package:anx_reader/service/sync/shared_state_database.dart';

const annotationSyncDomain = 'annotations';
const defaultAnnotationPreconditionRetries = 2;
const defaultAnnotationLockContentionRetries = 3;

enum AnnotationSyncStatus { synced, syncing, pendingOffline, error }

class MalformedRemoteAnnotationException implements Exception {
  final Object cause;
  const MalformedRemoteAnnotationException(this.cause);

  @override
  String toString() => 'Malformed remote annotation document: $cause';
}

typedef SharedDocumentChanged = FutureOr<void> Function(String documentId);
typedef AnnotationRetryScheduler = Timer Function(
    Duration delay, void Function() callback);
typedef AnnotationLockRetryDelay = Future<void> Function(Duration delay);
typedef SharedDocumentDecoder = Map<String, dynamic> Function(Object? input);
typedef SharedDocumentMerger = Map<String, dynamic> Function(
    Map<String, dynamic> local, Map<String, dynamic> remote);
typedef SharedDocumentIdValidator = bool Function(
    Map<String, dynamic> document, String documentId);

bool _annotationDocumentMatchesId(
    Map<String, dynamic> document, String documentId) {
  final book = document['book'] as Map<String, dynamic>;
  return canonicalMd5Fingerprint(book['fingerprint']) == documentId;
}

/// Domain-neutral, revision-safe WebDAV document convergence coordinator.
///
/// Domain code supplies decoding, identity validation, normalization, merge,
/// projection notification, and remote paths. Network work is single-flight
/// per document. SQLite transactions are
/// limited to snapshots and compare-and-set writes; no transaction spans a
/// GET, local notification, retry delay, or PUT.
class SharedDocumentSyncCoordinator {
  final SharedStateDatabase sharedState;
  final AnnotationWebDavTransport transport;
  final String syncDomain;
  final String Function(String documentId) normalizeDocumentId;
  final List<String> Function(String documentId) remotePathFor;
  final SharedDocumentDecoder decodeDocument;
  final SharedDocumentMerger mergeDocuments;
  final SharedDocumentIdValidator validateDocumentId;
  final SharedDocumentChanged? onDocumentChanged;
  final int maxPreconditionRetries;
  final int maxLockContentionRetries;
  final List<Duration> lockContentionBackoff;
  final AnnotationLockRetryDelay waitForLockRetry;
  final List<Duration> networkBackoff;
  final AnnotationRetryScheduler scheduleRetry;

  final Map<String, Future<void>> _flights = {};
  final Map<String, int> _requestedGeneration = {};
  final Map<String, Timer> _retryTimers = {};
  final Set<String> _active = {};
  final Map<String, Object> _lastFailures = {};
  final Map<String, int> _networkAttempts = {};
  final StreamController<void> _statusChanges =
      StreamController<void>.broadcast();
  bool _closing = false;

  SharedDocumentSyncCoordinator({
    required this.sharedState,
    required this.transport,
    this.syncDomain = annotationSyncDomain,
    String Function(String documentId)? normalizeDocumentId,
    List<String> Function(String documentId)? remotePathFor,
    SharedDocumentDecoder? decodeDocument,
    SharedDocumentMerger? mergeDocuments,
    SharedDocumentIdValidator? validateDocumentId,
    this.onDocumentChanged,
    this.maxPreconditionRetries = defaultAnnotationPreconditionRetries,
    this.maxLockContentionRetries = defaultAnnotationLockContentionRetries,
    this.lockContentionBackoff = const [
      Duration(milliseconds: 150),
      Duration(milliseconds: 350),
      Duration(milliseconds: 750),
    ],
    AnnotationLockRetryDelay? waitForLockRetry,
    this.networkBackoff = const [
      Duration(seconds: 2),
      Duration(seconds: 10),
      Duration(minutes: 1),
    ],
    AnnotationRetryScheduler? scheduleRetry,
  })  : normalizeDocumentId = normalizeDocumentId ?? canonicalMd5Fingerprint,
        remotePathFor = remotePathFor ?? annotationDocumentRemotePath,
        decodeDocument = decodeDocument ?? decodeAnnotationDocument,
        mergeDocuments = mergeDocuments ?? mergeAnnotationDocuments,
        validateDocumentId = validateDocumentId ?? _annotationDocumentMatchesId,
        waitForLockRetry = waitForLockRetry ?? Future<void>.delayed,
        scheduleRetry =
            scheduleRetry ?? ((delay, callback) => Timer(delay, callback)) {
    if (maxPreconditionRetries < 0) {
      throw ArgumentError.value(
          maxPreconditionRetries, 'maxPreconditionRetries');
    }
    if (maxLockContentionRetries < 0) {
      throw ArgumentError.value(
          maxLockContentionRetries, 'maxLockContentionRetries');
    }
  }

  Stream<void> get statusChanges => _statusChanges.stream;
  int get activeDocumentCount => _active.length;

  Future<AnnotationSyncStatus> get domainStatus async {
    if (_active.isNotEmpty) return AnnotationSyncStatus.syncing;
    if (_lastFailures.isNotEmpty) {
      return _lastFailures.values.every(_isRetryableNetworkFailure)
          ? AnnotationSyncStatus.pendingOffline
          : AnnotationSyncStatus.error;
    }
    final pending = (await sharedState.pendingOutbox())
        .where((entry) => entry.domain == syncDomain);
    var hasPending = false;
    for (final entry in pending) {
      hasPending = true;
      if (await status(entry.documentId) == AnnotationSyncStatus.error) {
        return AnnotationSyncStatus.error;
      }
    }
    return hasPending
        ? AnnotationSyncStatus.pendingOffline
        : AnnotationSyncStatus.synced;
  }

  Future<AnnotationSyncStatus> status(String fingerprint) async {
    final id = normalizeDocumentId(fingerprint);
    if (_active.contains(id)) return AnnotationSyncStatus.syncing;
    final outbox = await sharedState.outboxEntry(syncDomain, id);
    if (outbox == null) return AnnotationSyncStatus.synced;
    final failure = _lastFailures[id];
    if (failure == null && outbox.lastError != null) {
      final persisted = outbox.lastError!;
      return persisted.startsWith('WebDavTransportException') &&
              !persisted.contains('HTTP 401') &&
              !persisted.contains('HTTP 403')
          ? AnnotationSyncStatus.pendingOffline
          : AnnotationSyncStatus.error;
    }
    return failure == null || _isRetryableNetworkFailure(failure)
        ? AnnotationSyncStatus.pendingOffline
        : AnnotationSyncStatus.error;
  }

  /// Coalesces with an existing book flight and requests an immediate follow-up
  /// pass so mutations arriving during GET/PUT cannot be stranded.
  Future<void> syncBook(String fingerprint) {
    if (_closing) throw StateError('Annotation sync coordinator is closed');
    final id = normalizeDocumentId(fingerprint);
    _requestedGeneration[id] = (_requestedGeneration[id] ?? 0) + 1;
    final current = _flights[id];
    if (current != null) return current;
    final flight = _runSingleFlight(id);
    _flights[id] = flight;
    return flight;
  }

  Future<void> notifyDirty(String fingerprint) {
    final id = normalizeDocumentId(fingerprint);
    _networkAttempts.remove(id);
    return syncBook(id);
  }

  Future<void> pullBook(String fingerprint) => syncBook(fingerprint);

  Future<void> syncDirtyAnnotations() async {
    final pending = (await sharedState.pendingOutbox())
        .where((entry) => entry.domain == syncDomain)
        .toList(growable: false);
    syncDebug('domain=$syncDomain pending=${pending.length}');
    await Future.wait(pending.map((entry) async {
      try {
        await syncBook(entry.documentId);
      } catch (_) {
        // Each document records and schedules its own durable failure.
      }
    }));
  }

  Future<void> pullBooks(Iterable<String> fingerprints) async {
    final documents = fingerprints.toList(growable: false);
    syncDebug('domain=$syncDomain known=${documents.length}');
    await Future.wait(documents.map((fingerprint) async {
      try {
        await pullBook(fingerprint);
      } catch (_) {
        // Discovery is best effort and independent per book.
      }
    }));
  }

  Future<void> _runSingleFlight(String id) async {
    _active.add(id);
    _emitStatus();
    try {
      while (true) {
        final generation = _requestedGeneration[id]!;
        try {
          await _singlePass(id);
        } catch (_) {
          // A notification received during the failed request represents a
          // newer durable revision/generation. Give that work an immediate
          // pass before applying backoff (or stopping on a non-retryable
          // error); otherwise it can be stranded behind obsolete failure
          // state until another lifecycle trigger.
          if (_requestedGeneration[id] != generation) continue;
          rethrow;
        }
        final dirty = await sharedState.outboxEntry(syncDomain, id) != null;
        if (_requestedGeneration[id] == generation && !dirty) break;
      }
      _lastFailures.remove(id);
      _networkAttempts.remove(id);
      _retryTimers.remove(id)?.cancel();
    } catch (error) {
      _lastFailures[id] = error;
      if (_isRetryableNetworkFailure(error)) {
        _networkAttempts[id] = (_networkAttempts[id] ?? 0) + 1;
      }
      await _scheduleNetworkRetry(id, error);
      rethrow;
    } finally {
      _active.remove(id);
      _flights.remove(id);
      _emitStatus();
    }
  }

  Future<void> _singlePass(String id) async {
    final entry = await sharedState.outboxEntry(syncDomain, id);
    if (entry == null) {
      syncDebug('domain=$syncDomain doc=${shortSyncId(id)} action=pull');
      await _pullClean(id);
      return;
    }
    syncDebug('domain=$syncDomain doc=${shortSyncId(id)} action=push '
        'revision=${entry.localRevision}');
    final work =
        await sharedState.beginSync(syncDomain, id, entry.localRevision);
    if (work == null) return;
    try {
      await _pushDirty(work);
    } catch (error) {
      await sharedState.recordFailure(
          syncDomain, id, work.localRevision, error);
      rethrow;
    }
  }

  Future<void> _pushDirty(SharedSyncWork work) async {
    var failures = 0;
    var lockContentions = 0;
    var conditionalCreateRejected = false;
    while (true) {
      final remote = await transport.get(remotePathFor(work.documentId));
      if ((remote == null && conditionalCreateRejected) ||
          (remote != null && failures > maxPreconditionRetries)) {
        syncDebug('domain=$syncDomain doc=${shortSyncId(work.documentId)} '
            'action=lock-fallback revision=${work.localRevision}');
        try {
          await _writeUnderExclusiveLock(work.documentId, work.localRevision,
              expectDirty: true);
          return;
        } on WebDavLocked {
          lockContentions++;
          syncWarning('domain=$syncDomain doc=${shortSyncId(work.documentId)} '
              'lock=contended retry=$lockContentions');
          if (lockContentions > maxLockContentionRetries) rethrow;
          await _waitForLockContention(lockContentions);
          continue;
        }
      }
      final remoteDocument =
          remote == null ? null : _decodeRemote(remote, work.documentId);
      final merged = await _mergeRemoteSafely(work.documentId, remoteDocument,
          strongEtag: remote?.etag);
      if (merged == null ||
          merged.snapshot.localRevision != work.localRevision ||
          !merged.snapshot.dirty) {
        return;
      }

      await _notifyDocumentChanged(work.documentId);
      final beforePut =
          await sharedState.documentSnapshot(syncDomain, work.documentId);
      if (beforePut == null ||
          beforePut.localRevision != work.localRevision ||
          !beforePut.dirty) {
        return;
      }
      if (remote != null &&
          _sameCanonical(
              merged.bytes, utf8.encode(canonicalJson(remoteDocument!)))) {
        await sharedState.markConverged(
            syncDomain, work.documentId, work.localRevision,
            strongEtag: remote.etag);
        syncDebug('domain=$syncDomain doc=${shortSyncId(work.documentId)} '
            'action=already-converged result=converged '
            'revision=${work.localRevision} etag=present');
        return;
      }

      try {
        final action = remote == null ? 'create' : 'replace';
        syncDebug('domain=$syncDomain doc=${shortSyncId(work.documentId)} '
            'action=$action revision=${work.localRevision} '
            'etag=${remote == null ? 'absent' : 'present'}');
        final write = remote == null
            ? await transport.create(
                remotePathFor(work.documentId), merged.bytes)
            : await transport.replace(
                remotePathFor(work.documentId), merged.bytes, remote.etag);
        await sharedState.markConverged(
            syncDomain, work.documentId, work.localRevision,
            strongEtag: write.etag);
        syncDebug('domain=$syncDomain doc=${shortSyncId(work.documentId)} '
            'action=$action result=converged revision=${work.localRevision} '
            'etag=${write.etag == null ? 'absent' : 'present'}');
        return;
      } on WebDavPreconditionFailed {
        final action = remote == null ? 'create' : 'replace';
        if (remote == null) {
          conditionalCreateRejected = true;
          syncWarning('domain=$syncDomain doc=${shortSyncId(work.documentId)} '
              'action=$action conflict=412 retry=1');
          continue;
        }
        failures++;
        syncWarning('domain=$syncDomain doc=${shortSyncId(work.documentId)} '
            'action=$action conflict=412 retry=$failures');
      }
    }
  }

  Future<void> _pullClean(String id) async {
    var failures = 0;
    var lockContentions = 0;
    var conditionalCreateRejected = false;
    while (true) {
      final remote = await transport.get(remotePathFor(id));
      if ((remote == null && conditionalCreateRejected) ||
          (remote != null && failures > maxPreconditionRetries)) {
        syncDebug('domain=$syncDomain doc=${shortSyncId(id)} '
            'action=lock-fallback');
        try {
          await _writeUnderExclusiveLock(id, null, expectDirty: false);
          return;
        } on WebDavLocked {
          lockContentions++;
          syncWarning('domain=$syncDomain doc=${shortSyncId(id)} '
              'lock=contended retry=$lockContentions');
          if (lockContentions > maxLockContentionRetries) rethrow;
          await _waitForLockContention(lockContentions);
          continue;
        }
      }
      final remoteDocument = remote == null ? null : _decodeRemote(remote, id);
      final local = await sharedState.documentSnapshot(syncDomain, id);
      if (local == null && remoteDocument == null) return;

      final merged = await _mergeRemoteSafely(id, remoteDocument,
          strongEtag: remote?.etag);
      if (merged == null || merged.snapshot.dirty) return;
      await _notifyDocumentChanged(id);

      if (remote != null &&
          _sameCanonical(
              merged.bytes, utf8.encode(canonicalJson(remoteDocument!)))) {
        await sharedState.markRemoteConverged(
            syncDomain, id, merged.snapshot.localRevision,
            strongEtag: remote.etag);
        syncDebug('domain=$syncDomain doc=${shortSyncId(id)} '
            'action=already-converged result=converged '
            'revision=${merged.snapshot.localRevision} etag=present');
        return;
      }

      final beforePut = await sharedState.documentSnapshot(syncDomain, id);
      if (beforePut == null ||
          beforePut.localRevision != merged.snapshot.localRevision ||
          beforePut.dirty) {
        return;
      }
      try {
        final action = remote == null ? 'create' : 'replace';
        syncDebug('domain=$syncDomain doc=${shortSyncId(id)} action=$action '
            'revision=${merged.snapshot.localRevision} '
            'etag=${remote == null ? 'absent' : 'present'}');
        final write = remote == null
            ? await transport.create(remotePathFor(id), merged.bytes)
            : await transport.replace(
                remotePathFor(id), merged.bytes, remote.etag);
        await sharedState.markRemoteConverged(
            syncDomain, id, merged.snapshot.localRevision,
            strongEtag: write.etag);
        syncDebug('domain=$syncDomain doc=${shortSyncId(id)} action=$action '
            'result=converged revision=${merged.snapshot.localRevision} '
            'etag=${write.etag == null ? 'absent' : 'present'}');
        return;
      } on WebDavPreconditionFailed {
        final action = remote == null ? 'create' : 'replace';
        if (remote == null) {
          conditionalCreateRejected = true;
          syncWarning('domain=$syncDomain doc=${shortSyncId(id)} '
              'action=$action conflict=412 retry=1');
          continue;
        }
        failures++;
        syncWarning('domain=$syncDomain doc=${shortSyncId(id)} '
            'action=$action conflict=412 retry=$failures');
      }
    }
  }

  Future<void> _writeUnderExclusiveLock(String id, int? expectedRevision,
      {required bool expectDirty}) async {
    final path = remotePathFor(id);
    final lock = await transport.lock(path);
    Object? primaryFailure;
    var putSucceeded = false;
    try {
      final remote = lock.created ? null : await transport.get(path);
      if (!lock.created && remote == null) {
        throw const WebDavTransportException(
            'LOCK returned 200 but the existing representation is unavailable');
      }
      final remoteDocument = remote == null ? null : _decodeRemote(remote, id);
      final merged = await _mergeRemoteSafely(id, remoteDocument,
          strongEtag: remote?.etag);
      final targetRevision = expectedRevision ?? merged?.snapshot.localRevision;
      if (merged == null ||
          merged.snapshot.localRevision != targetRevision ||
          merged.snapshot.dirty != expectDirty) {
        return;
      }

      await _notifyDocumentChanged(id);
      final beforePut = await sharedState.documentSnapshot(syncDomain, id);
      if (beforePut == null ||
          beforePut.localRevision != targetRevision ||
          beforePut.dirty != expectDirty) {
        return;
      }

      if (remote != null &&
          _sameCanonical(
              merged.bytes, utf8.encode(canonicalJson(remoteDocument!)))) {
        if (expectDirty) {
          await sharedState.markConverged(
              syncDomain, id, beforePut.localRevision,
              strongEtag: remote.etag);
        } else {
          await sharedState.markRemoteConverged(
              syncDomain, id, beforePut.localRevision,
              strongEtag: remote.etag);
        }
        syncDebug('domain=$syncDomain doc=${shortSyncId(id)} '
            'action=already-converged result=converged '
            'revision=${beforePut.localRevision} etag=present');
        return;
      }

      syncDebug('domain=$syncDomain doc=${shortSyncId(id)} action=replace '
          'revision=${beforePut.localRevision} lock=exclusive');
      final write = await transport.putLocked(path, merged.bytes, lock);
      putSucceeded = true;
      if (expectDirty) {
        await sharedState.markConverged(syncDomain, id, beforePut.localRevision,
            strongEtag: write.etag);
      } else {
        await sharedState.markRemoteConverged(
            syncDomain, id, beforePut.localRevision,
            strongEtag: write.etag);
      }
      syncDebug('domain=$syncDomain doc=${shortSyncId(id)} action=replace '
          'result=converged revision=${beforePut.localRevision} '
          'lock=exclusive etag=${write.etag == null ? 'absent' : 'present'}');
    } catch (error, stackTrace) {
      primaryFailure = error;
      Error.throwWithStackTrace(error, stackTrace);
    } finally {
      try {
        await transport.unlock(path, lock);
      } catch (error, stackTrace) {
        syncWarning('domain=$syncDomain doc=${shortSyncId(id)} '
            'action=unlock-cleanup error=${safeSyncError(error)}');
        if (primaryFailure == null && !putSucceeded) {
          Error.throwWithStackTrace(error, stackTrace);
        }
      }
    }
  }

  Future<void> _waitForLockContention(int attempt) {
    final delay = lockContentionBackoff.isEmpty
        ? Duration.zero
        : lockContentionBackoff[
            (attempt - 1).clamp(0, lockContentionBackoff.length - 1)];
    return waitForLockRetry(delay);
  }

  Future<_RemoteMerge?> _mergeRemoteSafely(
      String id, Map<String, dynamic>? remote,
      {String? strongEtag}) async {
    while (true) {
      final snapshot = await sharedState.documentSnapshot(syncDomain, id);
      if (snapshot == null && remote == null) return null;
      final local = snapshot == null ? null : _decodeLocal(snapshot);
      final document = local == null
          ? remote!
          : remote == null
              ? local
              : mergeDocuments(local, remote);
      final action = local == null
          ? 'pull'
          : remote == null
              ? 'push'
              : 'merge';
      final bytes = Uint8List.fromList(utf8.encode(canonicalJson(document)));
      final applied = await sharedState.applyRemoteMerge(
        syncDomain,
        id,
        snapshot?.localRevision,
        bytes,
        strongEtag: strongEtag,
      );
      if (!applied) continue;
      final current = await sharedState.documentSnapshot(syncDomain, id);
      if (current == null) throw StateError('Remote merge disappeared');
      syncDebug('domain=$syncDomain doc=${shortSyncId(id)} action=$action '
          'revision=${current.localRevision} result=canonicalized');
      return _RemoteMerge(current, bytes);
    }
  }

  Map<String, dynamic> _decodeLocal(SharedDocumentSnapshot snapshot) =>
      decodeDocument(jsonDecode(utf8.decode(snapshot.canonicalState)));

  Map<String, dynamic> _decodeRemote(WebDavObject remote, String id) {
    late final Map<String, dynamic> document;
    try {
      document = decodeDocument(
          jsonDecode(utf8.decode(remote.body, allowMalformed: false)));
    } catch (error) {
      syncWarning('domain=$syncDomain doc=${shortSyncId(id)} '
          'reason=malformed-remote');
      throw MalformedRemoteAnnotationException(error);
    }
    if (!validateDocumentId(document, id)) {
      syncWarning('domain=$syncDomain doc=${shortSyncId(id)} '
          'reason=identity-mismatch');
      throw const MalformedRemoteAnnotationException(
          FormatException('document identity does not match path'));
    }
    return document;
  }

  Future<void> _notifyDocumentChanged(String id) async {
    try {
      await onDocumentChanged?.call(id);
    } catch (_) {
      // Canonical convergence is independent of local UI/renderer listeners.
    }
  }

  Future<void> _scheduleNetworkRetry(String id, Object error) async {
    if (_closing || !_isRetryableNetworkFailure(error)) return;
    if (networkBackoff.isEmpty || _retryTimers.containsKey(id)) return;
    final entry = await sharedState.outboxEntry(syncDomain, id);
    final durableAttempts = entry?.attempts ?? 0;
    final memoryAttempts = _networkAttempts[id] ?? 0;
    final recordedAttempts =
        durableAttempts > memoryAttempts ? durableAttempts : memoryAttempts;
    if (recordedAttempts > networkBackoff.length) return;
    final attempt = recordedAttempts < 1 ? 1 : recordedAttempts;
    final delay = networkBackoff[attempt - 1];
    syncWarning('domain=$syncDomain doc=${shortSyncId(id)} '
        'retryScheduled=${_durationLabel(delay)} '
        'error=${safeSyncError(error)}');
    _retryTimers[id] = scheduleRetry(delay, () {
      _retryTimers.remove(id);
      unawaited(syncBook(id).catchError((_) {}));
    });
  }

  bool _isRetryableNetworkFailure(Object error) =>
      error is WebDavTransportException &&
      error is! WebDavPreconditionFailed &&
      error.status != 401 &&
      error.status != 403;

  bool _sameCanonical(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }

  String _durationLabel(Duration duration) {
    if (duration.inMilliseconds % 1000 != 0) {
      return '${duration.inMilliseconds}ms';
    }
    if (duration.inSeconds % 60 != 0) return '${duration.inSeconds}s';
    return '${duration.inMinutes}m';
  }

  void _emitStatus() {
    if (!_statusChanges.isClosed) _statusChanges.add(null);
  }

  Future<void> close() async {
    _closing = true;
    for (final timer in _retryTimers.values) {
      timer.cancel();
    }
    _retryTimers.clear();
    final flights = _flights.values.toList(growable: false);
    await Future.wait(flights.map((flight) => flight.catchError((_) {})));
    for (final timer in _retryTimers.values) {
      timer.cancel();
    }
    _retryTimers.clear();
    await _statusChanges.close();
  }
}

/// Backwards-compatible annotation facade.
///
/// Annotation-specific defaults remain here while other domains instantiate
/// [SharedDocumentSyncCoordinator] with their own protocol functions.
class AnnotationSyncCoordinator extends SharedDocumentSyncCoordinator {
  AnnotationSyncCoordinator({
    required super.sharedState,
    required super.transport,
    super.syncDomain = annotationSyncDomain,
    super.normalizeDocumentId,
    super.remotePathFor,
    super.decodeDocument,
    super.mergeDocuments,
    super.validateDocumentId,
    super.onDocumentChanged,
    super.maxPreconditionRetries = defaultAnnotationPreconditionRetries,
    super.maxLockContentionRetries = defaultAnnotationLockContentionRetries,
    super.lockContentionBackoff = const [
      Duration(milliseconds: 150),
      Duration(milliseconds: 350),
      Duration(milliseconds: 750),
    ],
    super.waitForLockRetry,
    super.networkBackoff = const [
      Duration(seconds: 2),
      Duration(seconds: 10),
      Duration(minutes: 1),
    ],
    super.scheduleRetry,
  });
}

class _RemoteMerge {
  final SharedDocumentSnapshot snapshot;
  final Uint8List bytes;
  const _RemoteMerge(this.snapshot, this.bytes);
}
