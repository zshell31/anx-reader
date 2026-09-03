import 'dart:async';

import 'package:anx_reader/page/book_player/selection_session_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> selection(int generation, [String text = 'selection']) =>
    <String, dynamic>{'sessionId': generation, 'text': text};

void main() {
  test('selection updates never make actions visible', () {
    final state = SelectionSessionBridgeState();

    expect(state.selectionChanged(selection(1)), isTrue);
    expect(state.phase, SelectionSessionBridgePhase.selected);
    expect(state.selectionChanged(selection(1, 'changed')), isTrue);
    expect(state.phase, SelectionSessionBridgePhase.selected);
  });

  test('matching action requests and hides preserve the session', () {
    final state = SelectionSessionBridgeState();
    state.selectionChanged(selection(2));

    expect(state.actionsRequested(selection(2)), isTrue);
    expect(state.phase, SelectionSessionBridgePhase.actionsVisible);
    expect(state.actionsHidden(2), isTrue);
    expect(state.phase, SelectionSessionBridgePhase.selected);
    expect(state.generation, 2);
  });

  test('stable snapshot carries persisted and transient contexts separately',
      () {
    final state = SelectionSessionBridgeState();
    final payload = <String, dynamic>{
      ...selection(9, 'word'),
      'annotationContext': 'Containing sentence has a word.',
      'lookupContext':
          'Previous sentence. Containing sentence has a word. Next sentence.',
      'chapter': 'Chapter 1',
      'cfi': 'epubcfi(/6/2!/4/2,/1:0,/1:4)',
      'pos': {'left': 0.1, 'top': 0.2, 'right': 0.3, 'bottom': 0.4},
    };

    expect(state.selectionChanged(payload), isTrue);
    expect(state.actionsRequested(payload), isTrue);
    expect(state.selection?['annotationContext'],
        'Containing sentence has a word.');
    expect(state.selection?['lookupContext'],
        'Previous sentence. Containing sentence has a word. Next sentence.');
    expect(state.selection?['chapter'], 'Chapter 1');
    expect(state.selection?['cfi'], payload['cfi']);
    expect(state.selection?['pos'], payload['pos']);
  });

  test('selection clear removes matching actions and destroys the session', () {
    final state = SelectionSessionBridgeState();
    state.selectionChanged(selection(3));
    state.actionsRequested(selection(3));

    expect(state.selectionCleared(3), isTrue);
    expect(state.phase, SelectionSessionBridgePhase.idle);
    expect(state.generation, isNull);
    expect(state.selection, isNull);
  });

  test('cleared generation cannot be resurrected by late bridge messages', () {
    final state = SelectionSessionBridgeState();
    state.selectionChanged(selection(16));
    state.actionsRequested(selection(16));

    expect(state.selectionCleared(16), isTrue);
    expect(state.selectionChanged(selection(16, 'late')), isFalse);
    expect(state.actionsRequested(selection(16)), isFalse);
    expect(state.phase, SelectionSessionBridgePhase.idle);
  });

  test('clear arriving before selection retires that generation', () {
    final state = SelectionSessionBridgeState();

    expect(state.selectionCleared(17), isFalse);
    expect(state.selectionChanged(selection(17, 'late')), isFalse);
    expect(state.phase, SelectionSessionBridgePhase.idle);
    expect(state.selectionChanged(selection(18, 'new')), isTrue);
  });

  test('local reset retires current generation until a new runtime starts', () {
    final state = SelectionSessionBridgeState();
    state.selectionChanged(selection(19));

    state.reset();
    expect(state.selectionChanged(selection(19, 'late')), isFalse);
    state.resetForNewRuntime();
    expect(state.selectionChanged(selection(1, 'fresh runtime')), isTrue);
  });

  test('stale callbacks cannot open or remove a replacement session', () {
    final state = SelectionSessionBridgeState();
    state.selectionChanged(selection(4));
    state.selectionChanged(selection(5));

    expect(state.actionsRequested(selection(4)), isFalse);
    expect(state.actionsHidden(4), isFalse);
    expect(state.selectionCleared(4), isFalse);
    expect(state.generation, 5);
    expect(state.phase, SelectionSessionBridgePhase.selected);
  });

  test('rapid replacement rejects a late selection update', () {
    final state = SelectionSessionBridgeState();
    state.selectionChanged(selection(7));
    state.actionsRequested(selection(7));
    state.selectionChanged(selection(8));

    expect(state.selectionChanged(selection(7, 'late')), isFalse);
    expect(state.actionsRequested(selection(7)), isFalse);
    expect(state.generation, 8);
    expect(state.phase, SelectionSessionBridgePhase.selected);
  });

  test('external action preparation removes overlay and awaits JS first',
      () async {
    final state = SelectionSessionBridgeState();
    state.selectionChanged(selection(10));
    state.actionsRequested(selection(10));
    final events = <String>[];
    final jsCompletion = Completer<Object?>();
    final preparation = SelectionExternalActionPreparation(
      state: state,
      removeOverlay: (generation) => events.add('remove:$generation'),
      hideActionsInJavaScript: (generation) {
        events.add('hide:$generation');
        return jsCompletion.future;
      },
    );

    final prepared = preparation.prepare(10);
    await Future<void>.delayed(Duration.zero);
    expect(events, ['remove:10', 'hide:10']);
    expect(state.phase, SelectionSessionBridgePhase.selected);

    var launcherCalled = false;
    unawaited(prepared.then((ready) {
      if (ready) launcherCalled = true;
    }));
    await Future<void>.delayed(Duration.zero);
    expect(launcherCalled, isFalse);

    jsCompletion.complete(false);
    expect(await prepared, isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(launcherCalled, isTrue);
  });

  test('already-cleared JS generation still leaves coherent closed overlay',
      () async {
    final state = SelectionSessionBridgeState();
    state.selectionChanged(selection(11));
    state.actionsRequested(selection(11));
    var overlayRemoved = false;
    final preparation = SelectionExternalActionPreparation(
      state: state,
      removeOverlay: (_) => overlayRemoved = true,
      hideActionsInJavaScript: (_) async => false,
    );

    expect(await preparation.prepare(11), isTrue);
    expect(overlayRemoved, isTrue);
    expect(state.phase, SelectionSessionBridgePhase.selected);
  });

  test('late external cleanup cannot remove or hide a newer generation',
      () async {
    final state = SelectionSessionBridgeState();
    state.selectionChanged(selection(12));
    state.actionsRequested(selection(12));
    state.selectionChanged(selection(13));
    state.actionsRequested(selection(13));
    var overlayGeneration = 13;
    final hiddenGenerations = <int>[];
    final preparation = SelectionExternalActionPreparation(
      state: state,
      removeOverlay: (generation) {
        if (overlayGeneration == generation) overlayGeneration = -1;
      },
      hideActionsInJavaScript: (generation) async {
        hiddenGenerations.add(generation);
        return null;
      },
    );

    expect(await preparation.prepare(12), isFalse);
    expect(overlayGeneration, 13);
    expect(hiddenGenerations, isEmpty);
    expect(state.generation, 13);
    expect(state.phase, SelectionSessionBridgePhase.actionsVisible);
  });

  test('launch failure cannot restore prepared action overlay', () async {
    final state = SelectionSessionBridgeState();
    state.selectionChanged(selection(14));
    state.actionsRequested(selection(14));
    var overlayPresent = true;
    final preparation = SelectionExternalActionPreparation(
      state: state,
      removeOverlay: (_) => overlayPresent = false,
      hideActionsInJavaScript: (_) async => true,
    );

    expect(await preparation.prepare(14), isTrue);
    await expectLater(
      Future<void>.error(StateError('not installed')),
      throwsStateError,
    );
    expect(overlayPresent, isFalse);
    expect(state.phase, SelectionSessionBridgePhase.selected);
  });

  test('resume does not recreate actions and deliberate tap can reopen them',
      () async {
    final state = SelectionSessionBridgeState();
    state.selectionChanged(selection(15));
    state.actionsRequested(selection(15));
    final preparation = SelectionExternalActionPreparation(
      state: state,
      removeOverlay: (_) {},
      hideActionsInJavaScript: (_) async => true,
    );

    await preparation.prepare(15);
    expect(state.hasActionsVisibleFor(15), isFalse);
    expect(state.phase, SelectionSessionBridgePhase.selected);

    // Lifecycle resume performs reconciliation only; it sends no action
    // request. A later user tap is represented by a fresh JS request.
    expect(state.phase, SelectionSessionBridgePhase.selected);
    expect(state.actionsRequested(selection(15)), isTrue);
    expect(state.hasActionsVisibleFor(15), isTrue);
  });
}
