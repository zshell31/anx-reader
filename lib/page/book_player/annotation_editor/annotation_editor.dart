import 'dart:math' as math;

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
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
  bool focusPersonalNote = false,
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
        focusPersonalNote: focusPersonalNote,
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
  final bool focusPersonalNote;

  const AnnotationEditorDialog({
    super.key,
    required this.controller,
    this.initialProvider,
    this.focusPersonalNote = false,
  });

  @override
  State<AnnotationEditorDialog> createState() => _AnnotationEditorDialogState();
}

class _AnnotationEditorDialogState extends State<AnnotationEditorDialog> {
  late final TextEditingController _noteController;
  late final Set<AnnotationEditorProvider> _initialSourceProviders;
  final FocusNode _noteFocusNode = FocusNode();
  final TextEditingController _questionController = TextEditingController();
  final ScrollController _scrollController =
      ScrollController(keepScrollOffset: false);
  bool _closePromptOpen = false;

  AnnotationEditorController get controller => widget.controller;
  AnnotationEditorDraft get draft => controller.draft;

  @override
  void initState() {
    super.initState();
    _initialSourceProviders = Set.unmodifiable(draft.sourceResults.keys);
    _noteController = TextEditingController(text: draft.personalNote);
    _noteController.addListener(_noteChanged);
    controller.addListener(_changed);
    if (widget.focusPersonalNote) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _noteFocusNode.requestFocus();
      });
    }
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
    _noteFocusNode.dispose();
    _questionController.dispose();
    _scrollController.dispose();
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
    final l10n = L10n.of(context);
    final action = await showDialog<_UnsavedAction>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.annotationEditorUnsavedTitle),
        content: Text(l10n.annotationEditorUnsavedMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, _UnsavedAction.cancel),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, _UnsavedAction.discard),
            child: Text(l10n.annotationEditorDiscard),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, _UnsavedAction.save),
            child: Text(l10n.commonSave),
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
    final l10n = L10n.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.annotationEditorDeleteTitle),
        content: Text(l10n.annotationEditorDeleteMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.commonDelete),
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
    final l10n = L10n.of(context);
    final eInk = Prefs().eInkMode;
    final dialogHeight = math.min(
      media.size.height * 0.94,
      math.max(0.0, media.size.height - media.viewInsets.bottom - 24),
    );
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _requestClose();
      },
      child: Dialog(
        insetPadding: const EdgeInsets.all(12),
        insetAnimationDuration:
            eInk ? Duration.zero : const Duration(milliseconds: 150),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 760,
            maxHeight: dialogHeight,
          ),
          child: SizedBox(
            width: double.maxFinite,
            height: dialogHeight,
            child: Scaffold(
              resizeToAvoidBottomInset: false,
              appBar: AppBar(
                automaticallyImplyLeading: false,
                title: Text(
                  draft.isNew
                      ? l10n.annotationEditorNewTitle
                      : l10n.annotationEditorEditTitle,
                ),
                actions: [
                  IconButton(
                    tooltip: l10n.close,
                    onPressed: controller.saving ? null : _requestClose,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              body: SingleChildScrollView(
                controller: _scrollController,
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
                      _ContextSection(
                        title: l10n.annotationEditorContext,
                        text: draft.selection.lookupContext!.trim(),
                      ),
                    const SizedBox(height: 12),
                    Text(
                      l10n.annotationEditorAddSource,
                      style: theme.textTheme.titleMedium,
                    ),
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
                      if (draft.sourceResults[provider] == null)
                        if (draft.stateFor(provider).error case final error?)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: _ErrorText(
                              '${provider.providerName}: $error',
                            ),
                          ),
                    for (final provider in AnnotationEditorProvider.values)
                      if (draft.sourceResults[provider] case final result?) ...[
                        const SizedBox(height: 12),
                        _SourceCard(
                          key: ValueKey(provider),
                          provider: provider,
                          result: result,
                          selectedText: draft.selection.selectedText,
                          state: draft.stateFor(provider),
                          initiallyExpanded:
                              !_initialSourceProviders.contains(provider),
                          onRefresh: () => controller.runProvider(provider),
                          onRemove: () => controller.removeProvider(provider),
                        ),
                      ],
                    const SizedBox(height: 20),
                    Text(
                      l10n.annotationEditorPersonalNote,
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      key: const Key('annotation-editor-personal-note'),
                      controller: _noteController,
                      focusNode: _noteFocusNode,
                      minLines: 3,
                      maxLines: 8,
                      decoration: InputDecoration(
                        border: const OutlineInputBorder(),
                        hintText: l10n.annotationEditorPersonalNoteHint,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      l10n.annotationEditorAiChat,
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    if (draft.aiMessages.isEmpty)
                      Text(l10n.annotationEditorAiChatEmpty),
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
                            decoration: InputDecoration(
                              border: const OutlineInputBorder(),
                              hintText: l10n.annotationEditorQuestionHint,
                            ),
                            onSubmitted: (_) => _sendQuestion(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton.filled(
                          tooltip: l10n.annotationEditorSend,
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
                            label: Text(l10n.annotationEditorDelete),
                          ),
                        const Spacer(),
                        TextButton(
                          onPressed: controller.saving ? null : _requestClose,
                          child: Text(l10n.commonCancel),
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
                              : Text(l10n.commonSave),
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

class _ContextSection extends StatefulWidget {
  final String title;
  final String text;

  const _ContextSection({required this.title, required this.text});

  @override
  State<_ContextSection> createState() => _ContextSectionState();
}

class _ContextSectionState extends State<_ContextSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) => ExpansionTile(
        tilePadding: EdgeInsets.zero,
        initiallyExpanded: false,
        onExpansionChanged: (expanded) {
          setState(() => _expanded = expanded);
        },
        title: Text(widget.title),
        trailing: AnimatedRotation(
          turns: _expanded ? 0.25 : 0,
          duration: Prefs().eInkMode
              ? Duration.zero
              : const Duration(milliseconds: 200),
          child: const Icon(Icons.chevron_right),
        ),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: SelectableText(widget.text),
          ),
        ],
      );
}

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
        label: Text(
          state.loading ? '${provider.providerName}…' : provider.providerName,
        ),
        onPressed: state.loading ? null : onPressed,
      );
}

class _SourceCard extends StatefulWidget {
  final AnnotationEditorProvider provider;
  final AnnotationEditorSourceResult result;
  final String selectedText;
  final AnnotationEditorProviderState state;
  final bool initiallyExpanded;
  final VoidCallback onRefresh;
  final VoidCallback onRemove;

  const _SourceCard({
    super.key,
    required this.provider,
    required this.result,
    required this.selectedText,
    required this.state,
    required this.initiallyExpanded,
    required this.onRefresh,
    required this.onRemove,
  });

  @override
  State<_SourceCard> createState() => _SourceCardState();
}

class _SourceCardState extends State<_SourceCard> {
  final ExpansibleController _expansionController = ExpansibleController();
  late bool _expanded;

  @override
  void initState() {
    super.initState();
    _expanded = widget.initiallyExpanded;
  }

  @override
  void dispose() {
    _expansionController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _SourceCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.state.loading && !_expanded) {
      _expanded = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _expansionController.expand();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    return Card.outlined(
      child: ExpansionTile(
        controller: _expansionController,
        initiallyExpanded: widget.initiallyExpanded,
        onExpansionChanged: (expanded) {
          if (widget.state.loading && !expanded) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _expansionController.expand();
            });
            return;
          }
          setState(() => _expanded = expanded);
        },
        leading: Icon(_providerIcon(widget.provider)),
        title: Row(
          children: [
            Expanded(child: Text(widget.result.providerName)),
            if (widget.state.loading)
              const Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else
              IconButton(
                tooltip: l10n.commonRefresh,
                onPressed: widget.onRefresh,
                icon: const Icon(Icons.refresh),
              ),
            IconButton(
              tooltip: l10n.annotationEditorRemoveSource,
              onPressed: widget.onRemove,
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
        subtitle:
            widget.state.error == null ? null : _ErrorText(widget.state.error!),
        trailing: AnimatedRotation(
          turns: _expanded ? 0.25 : 0,
          duration: Prefs().eInkMode
              ? Duration.zero
              : const Duration(milliseconds: 200),
          child: const Icon(Icons.chevron_right),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          if (widget.provider == AnnotationEditorProvider.ai &&
              widget.result.commentary != null)
            _AiAnalysis(commentary: widget.result.commentary!)
          else if (widget.result.markdown?.isNotEmpty == true)
            StyledMarkdown(data: widget.result.markdown!)
          else if (widget.result.translation?.isNotEmpty == true)
            Align(
              alignment: Alignment.centerLeft,
              child: SelectableText(widget.result.translation!),
            ),
          if (widget.result.metadata['detectedLanguage'] case final language?)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(l10n.annotationEditorDetectedLanguage(language)),
              ),
            ),
          if (widget.provider == AnnotationEditorProvider.googleTranslate)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () async {
                  final status = await GoogleTranslateAppService()
                      .translate(widget.selectedText);
                  if (context.mounted &&
                      status == GoogleTranslateAppStatus.failed) {
                    AnxToast.show(l10n.googleTranslateAppLaunchFailed);
                  }
                },
                icon: const Icon(Icons.open_in_new),
                label: Text(l10n.annotationEditorOpenGoogleTranslate),
              ),
            ),
          if (widget.provider == AnnotationEditorProvider.ldoce)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => launchUrl(
                  Uri.parse(widget.result.metadata['url'] ??
                      'https://www.ldoceonline.com/'),
                  mode: LaunchMode.externalApplication,
                ),
                icon: const Icon(Icons.open_in_new),
                label: Text(l10n.annotationEditorOpenLdoce),
              ),
            ),
        ],
      ),
    );
  }
}

class _AiAnalysis extends StatelessWidget {
  final AnnotationEditorCommentary commentary;

  const _AiAnalysis({required this.commentary});

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final section in <(String, String?, bool)>[
          (
            l10n.annotationEditorSectionTranslation,
            commentary.translation,
            false
          ),
          if (commentary.chunks?.isNotEmpty == true)
            (l10n.annotationEditorSectionChunks, '', true),
          (
            l10n.annotationEditorSectionNotes,
            commentary.translationNotes,
            false
          ),
          (l10n.annotationEditorSectionGrammar, commentary.grammar, false),
          (l10n.annotationEditorSectionUsage, commentary.usage, false),
        ])
          if (section.$2?.isNotEmpty == true || section.$3) ...[
            Text(section.$1, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            if (section.$3)
              _AiChunks(chunks: commentary.chunks!)
            else
              StyledMarkdown(data: section.$2!),
            const SizedBox(height: 12),
          ],
      ],
    );
  }
}

class _AiChunks extends StatelessWidget {
  final List<AiChunk> chunks;

  const _AiChunks({required this.chunks});

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final chunk in chunks) ...[
            Text.rich(TextSpan(
              style: Theme.of(context).textTheme.bodyMedium,
              children: [
                TextSpan(
                  text: chunk.canonicalForm,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                if (chunk.surfaceForm?.isNotEmpty == true &&
                    chunk.surfaceForm != chunk.canonicalForm)
                  TextSpan(
                    text: ' (${chunk.surfaceForm})',
                    style: const TextStyle(fontStyle: FontStyle.italic),
                  ),
                TextSpan(text: ' — ${chunk.meaning}'),
              ],
            )),
            for (final example in chunk.examples ?? const <String>[])
              Padding(
                padding: const EdgeInsets.only(left: 12, top: 2),
                child: Text('• $example'),
              ),
            const SizedBox(height: 8),
          ],
        ],
      );
}

class _ChatMessage extends StatelessWidget {
  final AnnotationEditorMessage message;

  const _ChatMessage({required this.message});

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            message.role == 'assistant'
                ? l10n.annotationEditorRoleAi
                : l10n.annotationEditorRoleYou,
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
