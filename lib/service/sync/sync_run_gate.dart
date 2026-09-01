import 'dart:async';

/// Coalesces overlapping lifecycle triggers into one flight plus, when a
/// trigger arrives mid-flight, one follow-up pass.
class SyncRunGate {
  Future<void>? _flight;
  bool _requested = false;

  bool get isRunning => _flight != null;
  Future<void> get idle => _flight ?? Future<void>.value();

  Future<void> run(Future<void> Function() operation) {
    _requested = true;
    final current = _flight;
    if (current != null) return current;
    final completer = Completer<void>();
    _flight = completer.future;
    () async {
      try {
        do {
          _requested = false;
          await operation();
        } while (_requested);
        completer.complete();
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      } finally {
        _flight = null;
      }
    }();
    return completer.future;
  }
}
