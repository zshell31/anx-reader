import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/widgets/common/axis_flex.dart';
import 'package:flutter/material.dart';
import 'package:icons_plus/icons_plus.dart';

class ReaderNoteMenu extends StatefulWidget {
  const ReaderNoteMenu({
    super.key,
    this.initialValue,
    required this.decoration,
    required this.axis,
    required this.onVisibilityChange,
    required this.onSizeChanged,
    required this.onSave,
  });

  final String? initialValue;
  final BoxDecoration decoration;
  final Axis axis;
  final ValueChanged<bool> onVisibilityChange;
  final VoidCallback onSizeChanged;
  final Future<void> Function(String value) onSave;

  @override
  State<ReaderNoteMenu> createState() => ReaderNoteMenuState();
}

class ReaderNoteMenuState extends State<ReaderNoteMenu> {
  bool _showNoteDialog = false;
  final textFieldController = TextEditingController();
  bool showSaveButton = false;

  @override
  void initState() {
    super.initState();
    final value = widget.initialValue?.trim();
    if (value?.isNotEmpty == true) {
      textFieldController.text = value!;
      _showNoteDialog = true;
    }
  }

  @override
  void dispose() {
    textFieldController.dispose();
    super.dispose();
  }

  void _notifyVisibility(bool visible) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.onVisibilityChange(visible);
      }
    });
  }

  void _notifySizeChange() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.onSizeChanged();
      }
    });
  }

  void _setShowNoteDialog(bool value) {
    if (!mounted) {
      _showNoteDialog = value;
      return;
    }
    if (_showNoteDialog == value) {
      setState(() {});
      _notifySizeChange();
      _notifyVisibility(value);
      return;
    }
    setState(() {
      _showNoteDialog = value;
    });
    _notifyVisibility(value);
    _notifySizeChange();
  }

  Future<void> showNoteDialog([String? value]) async {
    if (value != null) textFieldController.text = value;
    _setShowNoteDialog(true);
  }

  Future<void> saveNote() async {
    textFieldController.text = textFieldController.text.trim();
    await widget.onSave(textFieldController.text);
    _notifySizeChange();
  }

  @override
  Widget build(BuildContext context) {
    return Expanded(
        child: AnimatedSize(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: widget.axis == Axis.vertical ? double.infinity : 200,
          maxWidth: widget.axis == Axis.vertical ? 100 : double.infinity,
        ),
        child: !_showNoteDialog
            ? null
            : Container(
                decoration: widget.decoration,
                padding: const EdgeInsets.all(8),
                child: AxisFlex(
                  reverse: false,
                  axis: widget.axis,
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        // scrollDirection: widget.axis,
                        child: TextField(
                          controller: textFieldController,
                          decoration: InputDecoration(
                            border: InputBorder.none,
                            hintText: L10n.of(context).contextMenuAddNoteTips,
                          ),
                          maxLines: widget.axis == Axis.vertical
                              ? double.maxFinite.toInt()
                              : 5,
                          minLines: 1,
                          onSubmitted: (String value) async {
                            await saveNote();
                          },
                          onChanged: (String value) {
                            setState(() {
                              showSaveButton = true;
                            });
                            _notifySizeChange();
                          },
                        ),
                      ),
                    ),
                    if (showSaveButton)
                      IconButton(
                        icon: const Icon(EvaIcons.checkmark_circle_2_outline),
                        onPressed: () async {
                          await saveNote();
                          if (!context.mounted) return;
                          // remove focus
                          FocusScope.of(context).unfocus();
                          setState(() {
                            showSaveButton = false;
                          });
                          _notifySizeChange();
                        },
                      ),
                  ],
                ),
              ),
      ),
    ));
  }
}
