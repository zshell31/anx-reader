enum SelectionSessionBridgePhase { idle, selected, actionsVisible }

typedef RemoveSelectionOverlay = void Function(int generation);
typedef HideSelectionActionsInJavaScript = Future<Object?> Function(
    int generation);

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

  /// Claims a matching visible-actions request for an operation that is about
  /// to leave the app. The JavaScript hide is performed separately and may
  /// safely report that its generation has already ended.
  bool prepareExternalAction(int generation) {
    if (generation != _generation ||
        _phase != SelectionSessionBridgePhase.actionsVisible) {
      return false;
    }
    _phase = SelectionSessionBridgePhase.selected;
    return true;
  }

  bool hasActionsVisibleFor(int generation) =>
      generation == _generation &&
      _phase == SelectionSessionBridgePhase.actionsVisible;

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

/// Completes the selection UI handoff required before launching an external
/// activity. Overlay removal and the Flutter phase transition happen before
/// the awaited JavaScript generation-scoped hide.
class SelectionExternalActionPreparation {
  SelectionExternalActionPreparation({
    required SelectionSessionBridgeState state,
    required RemoveSelectionOverlay removeOverlay,
    required HideSelectionActionsInJavaScript hideActionsInJavaScript,
  })  : _state = state,
        _removeOverlay = removeOverlay,
        _hideActionsInJavaScript = hideActionsInJavaScript;

  final SelectionSessionBridgeState _state;
  final RemoveSelectionOverlay _removeOverlay;
  final HideSelectionActionsInJavaScript _hideActionsInJavaScript;

  Future<bool> prepare(int generation) async {
    if (!_state.prepareExternalAction(generation)) {
      // This can only remove an overlay carrying the stale generation; the
      // caller's generation guard protects any replacement request.
      _removeOverlay(generation);
      return false;
    }

    _removeOverlay(generation);
    try {
      await _hideActionsInJavaScript(generation);
    } catch (_) {
      // The owning Document may already be gone. Flutter is already coherent
      // and no newer generation is modified by this failed old transition.
    }
    return true;
  }
}
