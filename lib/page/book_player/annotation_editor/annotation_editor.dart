import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/page/book_player/annotation_editor/annotation_editor_controller.dart';
import 'package:anx_reader/page/book_player/annotation_editor/annotation_editor_draft.dart';
import 'package:anx_reader/page/book_player/selection_persistence_session.dart';
import 'package:anx_reader/service/sync/annotation_catalog.dart';
import 'package:anx_reader/service/sync/annotation_read_model.dart';
import 'package:anx_reader/service/translate/google_translate_app.dart';
import 'package:anx_reader/utils/toast/common.dart';
import 'package:anx_reader/widgets/markdown/styled_markdown.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

enum AnnotationEditorOutcome { saved, deleted, discarded }

Future<AnnotationEditorOutcome?> showAnnotationEditor({
  required BuildContext context,
  required Book book,
  required SelectionPersistenceSession session,
  AnnotationEditorProvider? initialProvider,
}) async {
  final snapshot = session.snapshot;
  final ref = session.annotationRef;
  final AnnotationEditorDraft draft;
  if (ref == null) {
    draft = AnnotationEditorDraft.forSelection(
      selection: snapshot,
      bookTitle: book.title,
    );
  } else {
    final canonicalBook =
        await canonicalAnnotationCatalog.readBook(ref.bookFingerprint);
    final annotation = canonicalBook?.annotations
        .where((candidate) => candidate.ref == ref)
        .firstOrNull;
    if (annotation == null) {
      throw StateError(
          'Canonical annotation ${ref.annotationId} was not found');
    }
    draft = AnnotationEditorDraft.forAnnotation(
      selection: snapshot,
      bookTitle: canonicalBook?.title ?? book.title,
      annotation: annotation,
    );
  }
  if (!context.mounted) return null;
  final controller = AnnotationEditorController(draft: draft, book: book);
  try {
    final result = await showDialog<_AnnotationEditorResult>(
      context: context,
      barrierDismissible: false,
      useSafeArea: true,
      builder: (context) => AnnotationEditorDialog(
        controller: controller,
        initialProvider: initialProvider,
      ),
    );
    if (result?.outcome == AnnotationEditorOutcome.saved &&
        result?.ref != null &&
        session.annotationRef == null) {
      session.attachExisting(SelectionAnnotationHandle(ref: result!.ref!));
    }
    return result?.outcome;
  } finally {
    controller.dispose();
  }
}

class _AnnotationEditorResult {
  final AnnotationEditorOutcome outcome;
  final AnnotationRef? ref;

  const _AnnotationEditorResult(this.outcome, {this.ref});
}

class AnnotationEditorDialog extends StatefulWidget {
  final AnnotationEditorController controller;
  final AnnotationEditorProvider? initialProvider;

  const AnnotationEditorDialog({
    super.key,
    required this.controller,
    this.initialProvider,
  });

  @override
  State<AnnotationEditorDialog> createState() => _AnnotationEditorDialogState();
}

class _AnnotationEditorDialogState extends State<AnnotationEditorDialog> {
  late final TextEditingController _noteController;
  final TextEditingController _questionController = TextEditingController();
  bool _closePromptOpen = false;

  AnnotationEditorController get controller => widget.controller;
  AnnotationEditorDraft get draft => controller.draft;

  @override
  void initState() {
    super.initState();
    _noteController = TextEditingController(text: draft.personalNote);
    _noteController.addListener(_noteChanged);
    controller.addListener(_changed);
    if (widget.initialProvider != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && draft.sourceResults[widget.initialProvider!] == null) {
          controller.runProvider(widget.initialProvider!);
        }
      });
    }
  }

  @override
  void dispose() {
    controller.removeListener(_changed);
    _noteController
      ..removeListener(_noteChanged)
      ..dispose();
    _questionController.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _noteChanged() => controller.setPersonalNote(_noteController.text);

  Future<void> _save() async {
    final ref = await controller.save();
    if (!mounted || ref == null) return;
    Navigator.of(context).pop(
      _AnnotationEditorResult(AnnotationEditorOutcome.saved, ref: ref),
    );
  }

  Future<void> _requestClose() async {
    if (!draft.isDirty) {
      Navigator.of(context).pop(
        const _AnnotationEditorResult(AnnotationEditorOutcome.discarded),
      );
      return;
    }
    if (_closePromptOpen) return;
    _closePromptOpen = true;
    final action = await showDialog<_UnsavedAction>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save annotation changes?'),
        content: const Text(
          'Provider results, AI answers, and note changes have not been saved.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, _UnsavedAction.cancel),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, _UnsavedAction.discard),
            child: const Text('Discard'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, _UnsavedAction.save),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    _closePromptOpen = false;
    if (!mounted) return;
    if (action == _UnsavedAction.save) {
      await _save();
    } else if (action == _UnsavedAction.discard) {
      Navigator.of(context).pop(
        const _AnnotationEditorResult(AnnotationEditorOutcome.discarded),
      );
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete annotation?'),
        content: const Text(
          'The highlight and every saved source, note, and AI message will be deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final deleted = await controller.delete();
    if (mounted && deleted) {
      Navigator.of(context).pop(
        const _AnnotationEditorResult(AnnotationEditorOutcome.deleted),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final theme = Theme.of(context);
    final eInk = Prefs().eInkMode;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _requestClose();
      },
      child: AnimatedPadding(
        duration: eInk ? Duration.zero : const Duration(milliseconds: 150),
        padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
        child: Dialog(
          insetPadding: const EdgeInsets.all(12),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 760,
              maxHeight: media.size.height * 0.94,
            ),
            child: Scaffold(
              appBar: AppBar(
                automaticallyImplyLeading: false,
                title: Text(draft.isNew ? 'New annotation' : 'Edit annotation'),
                actions: [
                  IconButton(
                    tooltip: 'Close',
                    onPressed: controller.saving ? null : _requestClose,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              body: SingleChildScrollView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SelectableText(
                      '“${draft.selection.selectedText}”',
                      style: theme.textTheme.titleLarge,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      [draft.selection.chapter, draft.bookTitle]
                          .where((value) => value.trim().isNotEmpty)
                          .join(' · '),
                      style: theme.textTheme.bodySmall,
                    ),
                    if (draft.selection.lookupContext?.trim().isNotEmpty ==
                        true)
                      ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        title: const Text('Context'),
                        children: [
                          Align(
                            alignment: Alignment.centerLeft,
                            child: SelectableText(
                              draft.selection.lookupContext!.trim(),
                            ),
                          ),
                        ],
                      ),
                    const SizedBox(height: 12),
                    Text('Add source', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final provider in AnnotationEditorProvider.values)
                          if (draft.sourceResults[provider] == null)
                            _ProviderButton(
                              provider: provider,
                              state: draft.stateFor(provider),
                              onPressed: () => controller.runProvider(provider),
                            ),
                      ],
                    ),
                    for (final provider in AnnotationEditorProvider.values)
                      if (draft.sourceResults[provider] case final result?) ...[
                        const SizedBox(height: 12),
                        _SourceCard(
                          provider: provider,
                          result: result,
                          selectedText: draft.selection.selectedText,
                          state: draft.stateFor(provider),
                          onRefresh: () => controller.runProvider(provider),
                          onRemove: () => controller.removeProvider(provider),
                        ),
                      ],
                    const SizedBox(height: 20),
                    Text('Personal note', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _noteController,
                      minLines: 3,
                      maxLines: 8,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        hintText: 'Association, context, or mnemonic',
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text('AI chat', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 8),
                    if (draft.aiMessages.isEmpty)
                      const Text(
                        'Ask about the phrase, translations, grammar, or dictionary material.',
                      ),
                    for (final message in draft.aiMessages)
                      _ChatMessage(message: message),
                    if (controller.chatError case final error?)
                      _ErrorText(error),
                    const SizedBox(height: 8),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _questionController,
                            minLines: 1,
                            maxLines: 5,
                            enabled: !controller.chatLoading,
                            decoration: const InputDecoration(
                              border: OutlineInputBorder(),
                              hintText: 'Ask a follow-up question…',
                            ),
                            onSubmitted: (_) => _sendQuestion(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton.filled(
                          tooltip: 'Send',
                          onPressed:
                              controller.chatLoading ? null : _sendQuestion,
                          icon: controller.chatLoading
                              ? const SizedBox.square(
                                  dimension: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.send),
                        ),
                      ],
                    ),
                    if (controller.saveError case final error?)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: _ErrorText(error),
                      ),
                  ],
                ),
              ),
              bottomNavigationBar: SafeArea(
                top: false,
                child: Material(
                  elevation: eInk ? 0 : 8,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        if (!draft.isNew)
                          TextButton.icon(
                            onPressed: controller.saving ? null : _delete,
                            icon: const Icon(Icons.delete_outline),
                            label: const Text('Delete annotation'),
                          ),
                        const Spacer(),
                        TextButton(
                          onPressed: controller.saving ? null : _requestClose,
                          child: const Text('Cancel'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: !draft.isDirty || controller.saving
                              ? null
                              : _save,
                          child: controller.saving
                              ? const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Text('Save'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _sendQuestion() async {
    final question = _questionController.text.trim();
    if (question.isEmpty) return;
    FocusScope.of(context).unfocus();
    await controller.ask(question);
    if (mounted && controller.chatError == null) _questionController.clear();
  }
}

enum _UnsavedAction { save, discard, cancel }

class _ProviderButton extends StatelessWidget {
  final AnnotationEditorProvider provider;
  final AnnotationEditorProviderState state;
  final VoidCallback onPressed;

  const _ProviderButton({
    required this.provider,
    required this.state,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) => ActionChip(
        avatar: state.loading
            ? const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(_providerIcon(provider), size: 18),
        label: Text(provider.providerName),
        onPressed: state.loading ? null : onPressed,
      );
}

class _SourceCard extends StatelessWidget {
  final AnnotationEditorProvider provider;
  final AnnotationEditorSourceResult result;
  final String selectedText;
  final AnnotationEditorProviderState state;
  final VoidCallback onRefresh;
  final VoidCallback onRemove;

  const _SourceCard({
    required this.provider,
    required this.result,
    required this.selectedText,
    required this.state,
    required this.onRefresh,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) => Card.outlined(
        child: ExpansionTile(
          initiallyExpanded: true,
          leading: Icon(_providerIcon(provider)),
          title: Text(result.providerName),
          subtitle: state.error == null ? null : _ErrorText(state.error!),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (state.loading)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                IconButton(
                  tooltip: 'Refresh',
                  onPressed: onRefresh,
                  icon: const Icon(Icons.refresh),
                ),
              IconButton(
                tooltip: 'Remove source',
                onPressed: onRemove,
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            if (provider == AnnotationEditorProvider.ai &&
                result.commentary != null)
              _AiAnalysis(commentary: result.commentary!)
            else if (result.markdown?.isNotEmpty == true)
              StyledMarkdown(data: result.markdown!)
            else if (result.translation?.isNotEmpty == true)
              Align(
                alignment: Alignment.centerLeft,
                child: SelectableText(result.translation!),
              ),
            if (result.metadata['detectedLanguage'] case final language?)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('Detected language: $language'),
                ),
              ),
            if (provider == AnnotationEditorProvider.googleTranslate)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () async {
                    final status = await GoogleTranslateAppService()
                        .translate(selectedText);
                    if (context.mounted &&
                        status == GoogleTranslateAppStatus.failed) {
                      AnxToast.show('Unable to open Google Translate');
                    }
                  },
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Open in Google Translate'),
                ),
              ),
            if (provider == AnnotationEditorProvider.ldoce)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => launchUrl(
                    Uri.parse(result.metadata['url'] ??
                        'https://www.ldoceonline.com/'),
                    mode: LaunchMode.externalApplication,
                  ),
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Open in LDOCE'),
                ),
              ),
          ],
        ),
      );
}

class _AiAnalysis extends StatelessWidget {
  final AnnotationEditorCommentary commentary;

  const _AiAnalysis({required this.commentary});

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final section in <(String, String?)>[
            ('Translation', commentary.translation),
            ('Notes', commentary.translationNotes),
            ('Grammar', commentary.grammar),
            ('Usage', commentary.usage),
          ])
            if (section.$2?.isNotEmpty == true) ...[
              Text(section.$1, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              StyledMarkdown(data: section.$2!),
              const SizedBox(height: 12),
            ],
        ],
      );
}

class _ChatMessage extends StatelessWidget {
  final AnnotationEditorMessage message;

  const _ChatMessage({required this.message});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              message.role == 'assistant' ? 'AI' : 'You',
              style: Theme.of(context).textTheme.labelMedium,
            ),
            const SizedBox(height: 2),
            if (message.role == 'assistant')
              StyledMarkdown(data: message.content)
            else
              SelectableText(message.content),
          ],
        ),
      );
}

class _ErrorText extends StatelessWidget {
  final String value;

  const _ErrorText(this.value);

  @override
  Widget build(BuildContext context) => Text(
        value,
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      );
}

IconData _providerIcon(AnnotationEditorProvider provider) => switch (provider) {
      AnnotationEditorProvider.googleTranslate => Icons.g_translate,
      AnnotationEditorProvider.ldoce => Icons.menu_book,
      AnnotationEditorProvider.ai => Icons.auto_awesome,
    };
