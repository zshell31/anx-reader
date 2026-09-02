import 'dart:async';

import 'package:anx_reader/service/sync/conditional_webdav_transport.dart';
import 'package:anx_reader/utils/log/common.dart';

final Object _syncRunZoneKey = Object();
int _nextSyncRunId = 0;

class SyncDiagnosticRun {
  const SyncDiagnosticRun({required this.id, required this.trigger});

  final int id;
  final String trigger;
}

SyncDiagnosticRun? get currentSyncDiagnosticRun =>
    Zone.current[_syncRunZoneKey] as SyncDiagnosticRun?;

Future<T> runWithSyncDiagnostics<T>(
  String trigger,
  Future<T> Function(SyncDiagnosticRun run) body,
) {
  final run = SyncDiagnosticRun(id: ++_nextSyncRunId, trigger: trigger);
  return runZoned(() => body(run), zoneValues: {_syncRunZoneKey: run});
}

String get syncLogPrefix {
  final run = currentSyncDiagnosticRun;
  return run == null ? 'sync' : 'sync run=${run.id}';
}

String shortSyncId(String id) {
  final normalized = id.trim();
  if (normalized.length <= 8) return normalized;
  return '${normalized.substring(0, 8)}…';
}

String safeSyncError(Object error) {
  if (error is WebDavTransportException) {
    return error.status == null
        ? 'WebDavTransportException'
        : 'WebDavTransportException/http-${error.status}';
  }
  return error.runtimeType.toString();
}

void syncDebug(String fields) => AnxLog.debug('$syncLogPrefix $fields');
void syncInfo(String fields) => AnxLog.info('$syncLogPrefix $fields');
void syncWarning(String fields) => AnxLog.warning('$syncLogPrefix $fields');
void syncSevere(String fields) => AnxLog.severe('$syncLogPrefix $fields');
