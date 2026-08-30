enum SelectionSessionBridgePhase { idle, selected, actionsVisible }

/// Flutter-side projection of the JavaScript-owned selection session.
///
/// It does not create sessions. It only rejects stale bridge messages and lets
/// the player bind an OverlayEntry to the matching JavaScript generation.
class SelectionSessionBridgeState {
  int? _generation;
  Map<String, dynamic>? _selection;
  SelectionSessionBridgePhase _phase = SelectionSessionBridgePhase.idle;

  int? get generation => _generation;
  Map<String, dynamic>? get selection => _selection;
  SelectionSessionBridgePhase get phase => _phase;

  bool selectionChanged(Map<String, dynamic> payload) {
    final generation = _readGeneration(payload);
    if (generation == null ||
        (_generation != null && generation < _generation!)) {
      return false;
    }

    _generation = generation;
    _selection = Map<String, dynamic>.unmodifiable(payload);
    _phase = SelectionSessionBridgePhase.selected;
    return true;
  }

  bool actionsRequested(Map<String, dynamic> payload) {
    final generation = _readGeneration(payload);
    if (generation == null || generation != _generation) {
      return false;
    }

    _selection = Map<String, dynamic>.unmodifiable(payload);
    _phase = SelectionSessionBridgePhase.actionsVisible;
    return true;
  }

  bool actionsHidden(int generation) {
    if (generation != _generation) return false;
    _phase = SelectionSessionBridgePhase.selected;
    return true;
  }

  bool selectionCleared(int generation) {
    if (generation != _generation) return false;
    reset();
    return true;
  }

  bool matches(int generation) => generation == _generation;

  void reset() {
    _generation = null;
    _selection = null;
    _phase = SelectionSessionBridgePhase.idle;
  }

  static int? _readGeneration(Map<String, dynamic> payload) {
    final value = payload['sessionId'];
    return value is num && value > 0 ? value.toInt() : null;
  }
}
