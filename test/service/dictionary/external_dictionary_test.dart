import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/service/dictionary/external_dictionary.dart';
import 'package:anx_reader/service/translate/index.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const handler = ExternalDictionaryHandler(
    label: 'Offline Dictionary',
    packageName: 'org.example.dictionary',
    activityName: 'org.example.dictionary.ProcessTextActivity',
    componentName:
        'org.example.dictionary/org.example.dictionary.ProcessTextActivity',
  );

  test('compatible handler maps all stable Android identities', () {
    final mapped = ExternalDictionaryHandler.fromMap({
      'label': handler.label,
      'packageName': handler.packageName,
      'activityName': handler.activityName,
      'componentName': handler.componentName,
    });

    expect(mapped.label, handler.label);
    expect(mapped.packageName, handler.packageName);
    expect(mapped.activityName, handler.activityName);
    expect(mapped.componentName, handler.componentName);
  });

  test('stored component round-trips without changing translation provider',
      () async {
    SharedPreferences.setMockInitialValues({
      'translateService': TranslateService.deepl.name,
    });
    await Prefs().initPrefs();
    final store = PrefsExternalDictionaryPreferenceStore();

    expect(store.preferredComponent, isNull);
    store.preferredComponent = handler.componentName;
    expect(store.preferredComponent, handler.componentName);
    expect(Prefs().translateService, TranslateService.deepl);

    store.preferredComponent = null;
    expect(store.preferredComponent, isNull);
    expect(Prefs().translateService, TranslateService.deepl);
  });

  test('Ask every time is the default and launches the filtered chooser',
      () async {
    final gateway = _FakeGateway(handlers: [handler]);
    final preferences = _MemoryPreferences();
    final service = ExternalDictionaryService(
      gateway: gateway,
      preferences: preferences,
      isAndroid: true,
    );

    expect(service.preferredComponent, isNull);
    expect(await service.lookup('word'), DictionaryLookupStatus.launched);
    expect(gateway.launches.single.componentName, isNull);
  });

  test('configured handler launches explicitly while it is installed',
      () async {
    final gateway = _FakeGateway(handlers: [handler]);
    final service = ExternalDictionaryService(
      gateway: gateway,
      preferences: _MemoryPreferences(handler.componentName),
      isAndroid: true,
    );

    expect(await service.lookup('word'), DictionaryLookupStatus.launched);
    expect(gateway.launches.single.componentName, handler.componentName);
  });

  test('stale configured handler is cleared and falls back to chooser',
      () async {
    final gateway = _FakeGateway(handlers: [handler]);
    final preferences = _MemoryPreferences('missing/package.Activity');
    final service = ExternalDictionaryService(
      gateway: gateway,
      preferences: preferences,
      isAndroid: true,
    );

    expect(await service.lookup('word'), DictionaryLookupStatus.launched);
    expect(preferences.preferredComponent, isNull);
    expect(gateway.launches.single.componentName, isNull);
  });

  test('handler disappearing during explicit launch falls back to chooser',
      () async {
    final gateway = _FakeGateway(
      handlers: [handler],
      launchResults: [
        DictionaryLaunchStatus.handlerUnavailable,
        DictionaryLaunchStatus.launched,
      ],
    );
    final preferences = _MemoryPreferences(handler.componentName);
    final service = ExternalDictionaryService(
      gateway: gateway,
      preferences: preferences,
      isAndroid: true,
    );

    expect(await service.lookup('word'), DictionaryLookupStatus.launched);
    expect(preferences.preferredComponent, isNull);
    expect(gateway.launches.map((launch) => launch.componentName), [
      handler.componentName,
      null,
    ]);
  });

  test('empty handler list returns controlled no-dictionary result', () async {
    final gateway = _FakeGateway(handlers: const []);
    final preferences = _MemoryPreferences('stale/component');
    final service = ExternalDictionaryService(
      gateway: gateway,
      preferences: preferences,
      isAndroid: true,
    );

    expect(await service.lookup('word'), DictionaryLookupStatus.noHandlers);
    expect(preferences.preferredComponent, isNull);
    expect(gateway.launches, isEmpty);
  });

  test('selected text is passed to Android without alteration', () async {
    const selected = '  multi-word phrase\n第二行  ';
    final gateway = _FakeGateway(handlers: [handler]);
    final service = ExternalDictionaryService(
      gateway: gateway,
      preferences: _MemoryPreferences(),
      isAndroid: true,
    );

    await service.lookup(selected);
    expect(gateway.launches.single.text, selected);
  });

  test('non-Android lookup is controlled and never calls platform gateway',
      () async {
    final gateway = _FakeGateway(handlers: [handler]);
    final service = ExternalDictionaryService(
      gateway: gateway,
      preferences: _MemoryPreferences(),
      isAndroid: false,
    );

    expect(await service.lookup('word'), DictionaryLookupStatus.unsupported);
    expect(await service.listHandlers(), isEmpty);
    expect(gateway.listCallCount, 0);
    expect(gateway.launches, isEmpty);
  });
}

class _MemoryPreferences implements ExternalDictionaryPreferenceStore {
  _MemoryPreferences([this.preferredComponent]);

  @override
  String? preferredComponent;
}

class _Launch {
  const _Launch(this.text, this.componentName);

  final String text;
  final String? componentName;
}

class _FakeGateway implements ExternalDictionaryGateway {
  _FakeGateway({
    required this.handlers,
    this.launchResults = const [DictionaryLaunchStatus.launched],
  });

  final List<ExternalDictionaryHandler> handlers;
  final List<DictionaryLaunchStatus> launchResults;
  final List<_Launch> launches = [];
  int listCallCount = 0;

  @override
  Future<List<ExternalDictionaryHandler>> listHandlers() async {
    listCallCount += 1;
    return handlers;
  }

  @override
  Future<DictionaryLaunchStatus> launch({
    required String text,
    String? componentName,
  }) async {
    launches.add(_Launch(text, componentName));
    final index = launches.length - 1;
    return launchResults[index.clamp(0, launchResults.length - 1)];
  }
}
