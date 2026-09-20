import 'dart:async';

class LibraryTransfer {
  const LibraryTransfer(this.path, this.sent, this.total);
  final String path;
  final int sent;
  final int total;
  double? get fraction => total > 0 ? (sent / total).clamp(0.0, 1.0) : null;
}

/// Transient UI progress; never part of canonical synchronization state.
class LibraryTransferProgress {
  final _changes =
      StreamController<Map<String, LibraryTransfer>>.broadcast(sync: true);
  final Map<String, LibraryTransfer> _active = {};
  Map<String, LibraryTransfer> get snapshot => Map.unmodifiable(_active);

  Stream<Map<String, LibraryTransfer>> get stream => Stream.multi((listener) {
        final subscription = _changes.stream.listen(listener.addSync);
        listener.addSync(snapshot);
        listener.onCancel = subscription.cancel;
      });

  void update(String path, int sent, int total) {
    final previous = _active[path];
    final current = LibraryTransfer(path, sent, total);
    if (previous != null &&
        previous.total == total &&
        ((previous.fraction ?? 0) * 100).floor() ==
            ((current.fraction ?? 0) * 100).floor()) {
      return;
    }
    _active[path] = current;
    _changes.add(snapshot);
  }

  void finish(String path) {
    _active.remove(path);
    _changes.add(snapshot);
  }

  Future<void> dispose() => _changes.close();
}

final libraryTransferProgress = LibraryTransferProgress();
