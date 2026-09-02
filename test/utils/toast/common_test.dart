import 'package:anx_reader/utils/toast/common.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('best-effort toast is harmless before initialization',
      (tester) async {
    expect(AnxToast.tryShow('Syncing'), isFalse);
  });
}
