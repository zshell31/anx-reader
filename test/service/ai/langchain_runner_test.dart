import 'dart:async';

import 'package:anx_reader/service/ai/langchain_runner.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:langchain/langchain.dart';

void main() {
  test('cancelling one concurrent stream cancels only its model subscription',
      () async {
    final runner = CancelableLangchainRunner();
    final firstModel = _ControlledChatModel();
    final secondModel = _ControlledChatModel();
    final prompt = PromptValue.chat(<ChatMessage>[
      ChatMessage.humanText('translate'),
    ]);

    final first = runner.stream(model: firstModel, prompt: prompt).listen(null);
    final second =
        runner.stream(model: secondModel, prompt: prompt).listen(null);
    await Future<void>.delayed(Duration.zero);

    await first.cancel();
    expect(firstModel.cancellations, 1);
    expect(secondModel.cancellations, 0);

    await second.cancel();
    expect(secondModel.cancellations, 1);
  });
}

class _ControlledChatModel implements BaseChatModel<ChatModelOptions> {
  _ControlledChatModel() {
    _controller = StreamController<ChatResult>(
      onCancel: () => cancellations++,
    );
  }

  late final StreamController<ChatResult> _controller;
  int cancellations = 0;

  @override
  Stream<ChatResult> stream(
    PromptValue input, {
    ChatModelOptions? options,
  }) =>
      _controller.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
