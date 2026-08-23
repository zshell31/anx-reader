import 'dart:io';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/service/android/process_text.dart';
import 'package:anx_reader/service/translate/google_translate_app.dart';
import 'package:anx_reader/service/translate/index.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const googleHandler = ProcessTextHandler(
    label: 'Translate',
    packageName: googleTranslatePackageName,
    activityName: 'discovered.at.runtime.ProcessTextActivity',
    componentName:
        '$googleTranslatePackageName/discovered.at.runtime.ProcessTextActivity',
  );

  test('selects the exact Google package and forwards text unchanged',
      () async {
    const selected = '  exact phrase\n第二行  ';
    final gateway = _FakeGateway(handlers: const [
      ProcessTextHandler(
        label: 'Impostor',
        packageName: 'com.google.android.apps.translate.fake',
        activityName: 'FakeActivity',
        componentName: 'com.google.android.apps.translate.fake/FakeActivity',
      ),
      googleHandler,
    ]);
    final service = GoogleTranslateAppService(
      gateway: gateway,
      isAndroid: true,
    );

    expect(
        await service.translate(selected), GoogleTranslateAppStatus.launched);
    expect(gateway.launches.single.text, selected);
    expect(gateway.launches.single.componentName, googleHandler.componentName);
    expect(gateway.copies, isEmpty);
  });

  test('multiple Google handlers are selected deterministically', () async {
    const first = ProcessTextHandler(
      label: 'Translate Z',
      packageName: googleTranslatePackageName,
      activityName: 'z.RuntimeActivity',
      componentName: '$googleTranslatePackageName/z.RuntimeActivity',
    );
    const second = ProcessTextHandler(
      label: 'Translate A',
      packageName: googleTranslatePackageName,
      activityName: 'a.RuntimeActivity',
      componentName: '$googleTranslatePackageName/a.RuntimeActivity',
    );
    final gateway = _FakeGateway(handlers: const [first, second]);
    final service = GoogleTranslateAppService(
      gateway: gateway,
      isAndroid: true,
    );

    expect(await service.translate('word'), GoogleTranslateAppStatus.launched);
    expect(gateway.launches.single.componentName, second.componentName);
  });

  test('installed package without PROCESS_TEXT uses exact clipboard fallback',
      () async {
    const selected = ' phrase with spaces ';
    final gateway = _FakeGateway(handlers: const []);
    final service = GoogleTranslateAppService(
      gateway: gateway,
      isAndroid: true,
    );

    expect(
      await service.translate(selected),
      GoogleTranslateAppStatus.clipboardFallback,
    );
    expect(gateway.launches, isEmpty);
    expect(gateway.copies.single.text, selected);
    expect(
      gateway.copies.single.message,
      googleTranslateTapToTranslateMessage,
    );
  });

  test('handler disappearing before launch uses clipboard fallback', () async {
    final gateway = _FakeGateway(
      handlers: const [googleHandler],
      launchStatus: ProcessTextLaunchStatus.handlerUnavailable,
    );
    final service = GoogleTranslateAppService(
      gateway: gateway,
      isAndroid: true,
    );

    expect(
      await service.translate('word'),
      GoogleTranslateAppStatus.clipboardFallback,
    );
    expect(gateway.copies.single.text, 'word');
  });

  test('clipboard failure returns a controlled failure', () async {
    final gateway = _FakeGateway(
      handlers: const [],
      copySucceeds: false,
    );
    final service = GoogleTranslateAppService(
      gateway: gateway,
      isAndroid: true,
    );

    expect(
      await service.translate('word'),
      GoogleTranslateAppStatus.failed,
    );
    expect(gateway.copies.single.text, 'word');
  });

  test('absent Google package returns controlled result without fallback',
      () async {
    final gateway = _FakeGateway(
      handlers: const [googleHandler],
      packageInstalled: false,
    );
    final service = GoogleTranslateAppService(
      gateway: gateway,
      isAndroid: true,
    );

    expect(
      await service.translate('word'),
      GoogleTranslateAppStatus.notInstalled,
    );
    expect(gateway.listCallCount, 0);
    expect(gateway.launches, isEmpty);
    expect(gateway.copies, isEmpty);
  });

  test('non-Android behavior is controlled and does not call the bridge',
      () async {
    final gateway = _FakeGateway(handlers: const [googleHandler]);
    final service = GoogleTranslateAppService(
      gateway: gateway,
      isAndroid: false,
    );

    expect(
      await service.translate('word'),
      GoogleTranslateAppStatus.unsupported,
    );
    expect(gateway.packageChecks, isEmpty);
    expect(gateway.listCallCount, 0);
  });

  test('existing ML Kit and Google Cloud providers remain configured',
      () async {
    SharedPreferences.setMockInitialValues(const {});
    await Prefs().initPrefs();

    expect(TranslateService.googleWeb.name, 'googleWeb');
    expect(TranslateService.googleApi.name, 'googleApi');
    expect(
        TranslateService.selectionValues, contains(TranslateService.googleWeb));
    expect(
        TranslateService.selectionValues, contains(TranslateService.googleApi));
  });

  test('native bridge uses only the public PROCESS_TEXT contract', () {
    final source = File(
      'android/app/src/main/kotlin/com/anxcye/anx_reader/MainActivity.kt',
    ).readAsStringSync();
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();

    expect(source, contains('Intent.ACTION_PROCESS_TEXT'));
    expect(source, contains('type = "text/plain"'));
    expect(source, contains('Intent.EXTRA_PROCESS_TEXT, text'));
    expect(source, contains('Intent.EXTRA_PROCESS_TEXT_READONLY, true'));
    expect(source, contains('queryIntentActivities'));
    expect(source, contains('intent.component = component'));
    expect(source, contains('ClipData.newPlainText("Selected text", text)'));
    for (final privateActivity in [
      ['Translate', 'Activity'].join(),
      ['Home', 'Activity'].join(),
      ['CopyDrop', 'Activity'].join(),
    ]) {
      expect(source, isNot(contains(privateActivity)));
    }
    for (final privateExtra in [
      ['key', 'text', 'input'].join('_'),
      ['key', 'language', 'from'].join('_'),
      ['key', 'language', 'to'].join('_'),
      ['key', 'from', 'floating', 'window'].join('_'),
    ]) {
      expect(source, isNot(contains(privateExtra)));
    }
    expect(
      manifest,
      contains('android:name="android.intent.action.PROCESS_TEXT"'),
    );
    expect(manifest, contains('android:mimeType="text/plain"'));
    expect(
      manifest,
      contains('android:name="com.google.android.apps.translate"'),
    );
    expect(
      manifest,
      isNot(contains(['QUERY', 'ALL', 'PACKAGES'].join('_'))),
    );
  });
}

class _Launch {
  const _Launch(this.text, this.componentName);

  final String text;
  final String? componentName;
}

class _Copy {
  const _Copy(this.text, this.message);

  final String text;
  final String message;
}

class _FakeGateway implements ProcessTextGateway {
  _FakeGateway({
    required this.handlers,
    this.packageInstalled = true,
    this.launchStatus = ProcessTextLaunchStatus.launched,
    this.copySucceeds = true,
  });

  final List<ProcessTextHandler> handlers;
  final bool packageInstalled;
  final ProcessTextLaunchStatus launchStatus;
  final bool copySucceeds;
  final List<String> packageChecks = [];
  final List<_Launch> launches = [];
  final List<_Copy> copies = [];
  int listCallCount = 0;

  @override
  Future<List<ProcessTextHandler>> listHandlers() async {
    listCallCount += 1;
    return handlers;
  }

  @override
  Future<ProcessTextLaunchStatus> launch({
    required String text,
    String? componentName,
  }) async {
    launches.add(_Launch(text, componentName));
    return launchStatus;
  }

  @override
  Future<bool> isPackageInstalled(String packageName) async {
    packageChecks.add(packageName);
    return packageInstalled;
  }

  @override
  Future<bool> copyText({
    required String text,
    required String message,
  }) async {
    copies.add(_Copy(text, message));
    return copySucceeds;
  }
}
