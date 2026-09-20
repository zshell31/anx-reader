import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/page/reading_page.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

class _Wakelock extends WakelockPlusPlatformInterface {
  bool active = false;
  @override
  Future<void> toggle({required bool enable}) async => active = enable;
  @override
  Future<bool> get enabled async => active;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Wakelock wakelock;
  late WakelockPlusPlatformInterface previous;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs().initPrefs();
    previous = wakelockPlusPlatformInstance;
    wakelock = _Wakelock();
    wakelockPlusPlatformInstance = wakelock;
  });
  tearDown(() => wakelockPlusPlatformInstance = previous);

  testWidgets(
      'keep on cancels a previous timeout and survives hours of reading',
      (tester) async {
    final reader = ReadingPageState();
    await reader.setAwakeTimer(5);
    await tester.pump(const Duration(minutes: 4));
    Prefs().keepScreenOn = true;
    reader.resetAwakeTimer();
    await tester.pump(const Duration(hours: 2));
    expect(wakelock.active, isTrue);
    Prefs().keepScreenOn = false;
    await reader.setAwakeTimer(0);
    expect(wakelock.active, isFalse);
  });

  testWidgets('activity renews the finite timeout; zero releases immediately',
      (tester) async {
    final reader = ReadingPageState();
    Prefs().awakeTime = 5;
    reader.resetAwakeTimer();
    await tester.pump(const Duration(minutes: 4));
    reader.resetAwakeTimer();
    await tester.pump(const Duration(minutes: 4));
    expect(wakelock.active, isTrue);
    await tester.pump(const Duration(minutes: 1));
    expect(wakelock.active, isFalse);
    await reader.setAwakeTimer(5);
    expect(wakelock.active, isTrue);
    await reader.setAwakeTimer(0);
    expect(wakelock.active, isFalse);
    await tester.pump(const Duration(minutes: 10));
    expect(wakelock.active, isFalse);
  });
}
