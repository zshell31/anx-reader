import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/service/dictionary/external_dictionary.dart';
import 'package:anx_reader/utils/toast/common.dart';
import 'package:flutter/material.dart';

class ExternalDictionarySettingsTile extends StatefulWidget {
  const ExternalDictionarySettingsTile({
    super.key,
    ExternalDictionaryService? service,
  }) : _service = service;

  final ExternalDictionaryService? _service;

  @override
  State<ExternalDictionarySettingsTile> createState() =>
      _ExternalDictionarySettingsTileState();
}

class _ExternalDictionarySettingsTileState
    extends State<ExternalDictionarySettingsTile> {
  late final ExternalDictionaryService _service =
      widget._service ?? ExternalDictionaryService();
  List<ExternalDictionaryHandler> _handlers = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refreshHandlers();
  }

  Future<void> _refreshHandlers() async {
    try {
      final handlers = await _service.listHandlers();
      if (!mounted) return;
      setState(() {
        _handlers = handlers;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  String _currentLabel(L10n l10n) {
    final preferred = _service.preferredComponent;
    if (preferred == null) return l10n.dictionaryAskEveryTime;
    return _handlers
            .where((handler) => handler.componentName == preferred)
            .map((handler) => handler.label)
            .firstOrNull ??
        l10n.dictionaryAskEveryTime;
  }

  Future<void> _chooseHandler() async {
    await _refreshHandlers();
    if (!mounted) return;
    if (_handlers.isEmpty) {
      AnxToast.show(L10n.of(context).dictionaryNoCompatibleApp);
      return;
    }

    final selected = await showModalBottomSheet<String?>(
      context: context,
      builder: (context) {
        final l10n = L10n.of(context);
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                leading: const Icon(Icons.touch_app),
                title: Text(l10n.dictionaryAskEveryTime),
                onTap: () => Navigator.pop(context, ''),
              ),
              for (final handler in _handlers)
                ListTile(
                  leading: const Icon(Icons.menu_book),
                  title: Text(handler.label),
                  subtitle: Text(handler.packageName),
                  onTap: () => Navigator.pop(context, handler.componentName),
                ),
            ],
          ),
        );
      },
    );
    if (selected == null || !mounted) return;
    setState(() {
      _service.preferredComponent = selected.isEmpty ? null : selected;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.menu_book),
      title: Text(l10n.settingsExternalDictionary),
      subtitle: Text(
        _loading ? '…' : _currentLabel(l10n),
      ),
      onTap: _loading ? null : _chooseHandler,
    );
  }
}
