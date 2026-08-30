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
}
