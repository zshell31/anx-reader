import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:anx_reader/service/sync/annotation_projection_reconciler.dart';
import 'package:anx_reader/service/sync/annotation_protocol.dart';
import 'package:anx_reader/service/sync/conditional_webdav_transport.dart';
import 'package:anx_reader/service/sync/shared_state_database.dart';

const annotationSyncDomain = 'annotations';
const defaultAnnotationPreconditionRetries = 2;

enum AnnotationSyncStatus { synced, syncing, pendingOffline, error }

class AnnotationSyncConflictException implements Exception {
  final int attempts;
  const AnnotationSyncConflictException(this.attempts);

  @override
  String toString() =>
      'Annotation sync did not converge after $attempts conditional writes';
}

class MalformedRemoteAnnotationException implements Exception {
  final Object cause;
  const MalformedRemoteAnnotationException(this.cause);

  @override
  String toString() => 'Malformed remote annotation document: $cause';
}

typedef AnnotationProjectionCallback = Future<AnnotationReconciliationResult>
    Function(String fingerprint);
typedef AnnotationProjectionChanged = void Function(
    String fingerprint, AnnotationReconciliationResult result);
typedef AnnotationRetryScheduler = Timer Function(
    Duration delay, void Function() callback);

/// Annotation-specific, revision-safe WebDAV convergence coordinator.
///
/// Network work is single-flight per fingerprint. SQLite transactions are
/// limited to snapshots and compare-and-set writes; no transaction spans a
/// GET, projection update, retry delay, or PUT.
class AnnotationSyncCoordinator {
  final SharedStateDatabase sharedState;
  final AnnotationWebDavTransport transport;
  final AnnotationProjectionCallback reconcileProjection;
  final AnnotationProjectionChanged? onProjectionChanged;
  final int maxPreconditionRetries;
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

  AnnotationSyncCoordinator({
    required this.sharedState,
    required this.transport,
    required this.reconcileProjection,
    this.onProjectionChanged,
    this.maxPreconditionRetries = defaultAnnotationPreconditionRetries,
    this.networkBackoff = const [
      Duration(seconds: 2),
      Duration(seconds: 10),
      Duration(minutes: 1),
    ],
    AnnotationRetryScheduler? scheduleRetry,
  }) : scheduleRetry =
            scheduleRetry ?? ((delay, callback) => Timer(delay, callback)) {
    if (maxPreconditionRetries < 0) {
      throw ArgumentError.value(
          maxPreconditionRetries, 'maxPreconditionRetries');
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
        .where((entry) => entry.domain == annotationSyncDomain);
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
    final id = canonicalMd5Fingerprint(fingerprint);
    if (_active.contains(id)) return AnnotationSyncStatus.syncing;
    final outbox = await sharedState.outboxEntry(annotationSyncDomain, id);
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
    final id = canonicalMd5Fingerprint(fingerprint);
    _requestedGeneration[id] = (_requestedGeneration[id] ?? 0) + 1;
    final current = _flights[id];
    if (current != null) return current;
    final flight = _runSingleFlight(id);
    _flights[id] = flight;
    return flight;
  }

  Future<void> notifyDirty(String fingerprint) {
    final id = canonicalMd5Fingerprint(fingerprint);
    _networkAttempts.remove(id);
    return syncBook(id);
  }

  Future<void> pullBook(String fingerprint) => syncBook(fingerprint);

  Future<void> syncDirtyAnnotations() async {
    final pending = (await sharedState.pendingOutbox())
        .where((entry) => entry.domain == annotationSyncDomain)
        .toList(growable: false);
    await Future.wait(pending.map((entry) async {
      try {
        await syncBook(entry.documentId);
      } catch (_) {
        // Each document records and schedules its own durable failure.
      }
    }));
  }

  Future<void> pullBooks(Iterable<String> fingerprints) async {
    await Future.wait(fingerprints.map((fingerprint) async {
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
        final dirty =
            await sharedState.outboxEntry(annotationSyncDomain, id) != null;
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
    final entry = await sharedState.outboxEntry(annotationSyncDomain, id);
    if (entry == null) {
      await _pullClean(id);
      return;
    }
    final work = await sharedState.beginSync(
        annotationSyncDomain, id, entry.localRevision);
    if (work == null) return;
    try {
      await _pushDirty(work);
    } catch (error) {
      await sharedState.recordFailure(
          annotationSyncDomain, id, work.localRevision, error);
      rethrow;
    }
  }

  Future<void> _pushDirty(SharedSyncWork work) async {
    var failures = 0;
    while (true) {
      final remote =
          await transport.get(annotationDocumentRemotePath(work.documentId));
      final remoteDocument =
          remote == null ? null : _decodeRemote(remote, work.documentId);
      final merged = await _mergeRemoteSafely(work.documentId, remoteDocument,
          strongEtag: remote?.etag);
      if (merged == null ||
          merged.snapshot.localRevision != work.localRevision ||
          !merged.snapshot.dirty) {
        return;
      }

      await _reconcile(work.documentId);
      final beforePut = await sharedState.documentSnapshot(
          annotationSyncDomain, work.documentId);
      if (beforePut == null ||
          beforePut.localRevision != work.localRevision ||
          !beforePut.dirty) {
        return;
      }

      try {
        final write = remote == null
            ? await transport.create(
                annotationDocumentRemotePath(work.documentId), merged.bytes)
            : await transport.replace(
                annotationDocumentRemotePath(work.documentId),
                merged.bytes,
                remote.etag);
        await sharedState.markConverged(
            annotationSyncDomain, work.documentId, work.localRevision,
            strongEtag: write.etag);
        return;
      } on WebDavPreconditionFailed {
        failures++;
        if (failures > maxPreconditionRetries) {
          throw AnnotationSyncConflictException(failures);
        }
      }
    }
  }

  Future<void> _pullClean(String id) async {
    var failures = 0;
    while (true) {
      final remote = await transport.get(annotationDocumentRemotePath(id));
      final remoteDocument = remote == null ? null : _decodeRemote(remote, id);
      final local =
          await sharedState.documentSnapshot(annotationSyncDomain, id);
      if (local == null && remoteDocument == null) return;

      final merged = await _mergeRemoteSafely(id, remoteDocument,
          strongEtag: remote?.etag);
      if (merged == null || merged.snapshot.dirty) return;
      await _reconcile(id);

      if (remote != null &&
          _sameCanonical(
              merged.bytes, utf8.encode(canonicalJson(remoteDocument!)))) {
        await sharedState.markRemoteConverged(
            annotationSyncDomain, id, merged.snapshot.localRevision,
            strongEtag: remote.etag);
        return;
      }

      final beforePut =
          await sharedState.documentSnapshot(annotationSyncDomain, id);
      if (beforePut == null ||
          beforePut.localRevision != merged.snapshot.localRevision ||
          beforePut.dirty) {
        return;
      }
      try {
        final write = remote == null
            ? await transport.create(
                annotationDocumentRemotePath(id), merged.bytes)
            : await transport.replace(
                annotationDocumentRemotePath(id), merged.bytes, remote.etag);
        await sharedState.markRemoteConverged(
            annotationSyncDomain, id, merged.snapshot.localRevision,
            strongEtag: write.etag);
        return;
      } on WebDavPreconditionFailed {
        failures++;
        if (failures > maxPreconditionRetries) {
          throw AnnotationSyncConflictException(failures);
        }
      }
    }
  }

  Future<_RemoteMerge?> _mergeRemoteSafely(
      String id, Map<String, dynamic>? remote,
      {String? strongEtag}) async {
    while (true) {
      final snapshot =
          await sharedState.documentSnapshot(annotationSyncDomain, id);
      if (snapshot == null && remote == null) return null;
      final local = snapshot == null ? null : _decodeLocal(snapshot);
      final document = local == null
          ? remote!
          : remote == null
              ? local
              : mergeAnnotationDocuments(local, remote);
      final bytes = Uint8List.fromList(utf8.encode(canonicalJson(document)));
      final applied = await sharedState.applyRemoteMerge(
        annotationSyncDomain,
        id,
        snapshot?.localRevision,
        bytes,
        strongEtag: strongEtag,
      );
      if (!applied) continue;
      final current =
          await sharedState.documentSnapshot(annotationSyncDomain, id);
      if (current == null) throw StateError('Remote merge disappeared');
      return _RemoteMerge(current, bytes);
    }
  }

  Map<String, dynamic> _decodeLocal(SharedDocumentSnapshot snapshot) =>
      decodeAnnotationDocument(
          jsonDecode(utf8.decode(snapshot.canonicalState)));

  Map<String, dynamic> _decodeRemote(WebDavObject remote, String id) {
    try {
      final document = decodeAnnotationDocument(
          jsonDecode(utf8.decode(remote.body, allowMalformed: false)));
      final book = document['book'] as Map<String, dynamic>;
      if (canonicalMd5Fingerprint(book['fingerprint']) != id) {
        throw const FormatException('book fingerprint does not match path');
      }
      return document;
    } catch (error) {
      throw MalformedRemoteAnnotationException(error);
    }
  }

  Future<void> _reconcile(String id) async {
    try {
      final result = await reconcileProjection(id);
      if (result.nativeWrites > 0) onProjectionChanged?.call(id, result);
    } catch (_) {
      // Canonical convergence is independent of repairable native projection.
    }
  }

  Future<void> _scheduleNetworkRetry(String id, Object error) async {
    if (_closing || !_isRetryableNetworkFailure(error)) return;
    if (networkBackoff.isEmpty || _retryTimers.containsKey(id)) return;
    final entry = await sharedState.outboxEntry(annotationSyncDomain, id);
    final durableAttempts = entry?.attempts ?? 0;
    final memoryAttempts = _networkAttempts[id] ?? 0;
    final recordedAttempts =
        durableAttempts > memoryAttempts ? durableAttempts : memoryAttempts;
    if (recordedAttempts > networkBackoff.length) return;
    final attempt = recordedAttempts < 1 ? 1 : recordedAttempts;
    final delay = networkBackoff[attempt - 1];
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

class _RemoteMerge {
  final SharedDocumentSnapshot snapshot;
  final Uint8List bytes;
  const _RemoteMerge(this.snapshot, this.bytes);
}
