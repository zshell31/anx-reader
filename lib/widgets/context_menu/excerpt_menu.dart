import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/constants/note_annotations.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/main.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/page/book_player/annotation_editor/annotation_editor.dart';
import 'package:anx_reader/page/book_player/annotation_editor/annotation_editor_draft.dart';
import 'package:anx_reader/page/book_player/selection_persistence_session.dart';
import 'package:anx_reader/service/dictionary/external_dictionary.dart';
import 'package:anx_reader/service/annotation_enrichment/openai_audio_service.dart';
import 'package:anx_reader/service/sync/annotation_repository.dart';
import 'package:anx_reader/service/sync/annotation_catalog.dart';
import 'package:anx_reader/utils/toast/common.dart';
import 'package:anx_reader/widgets/book_share/excerpt_share_service.dart';
import 'package:anx_reader/widgets/common/axis_flex.dart';
import 'package:anx_reader/widgets/icon_and_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:icons_plus/icons_plus.dart';
import 'package:url_launcher/url_launcher.dart';

enum _SecondarySelectionAction { copy, search, narrate, share }

class ExcerptMenu extends StatefulWidget {
  final Book book;
  final String annoCfi;
  final String annoContent;
  final String? chapter;
  final String? annotationContext;
  final String? lookupContext;
  final String? initialType;
  final String? initialColor;
  final SelectionPersistenceSession persistenceSession;
  final Function() onClose;
  final Future<bool> Function() prepareExternalAction;
  final bool footnote;
  final BoxDecoration decoration;
  final Future<bool> Function() prepareInternalAction;
  final Axis axis;
  final bool reverse;
  final Future<void> Function() refreshAnnotations;
  final Future<void> Function()? narrateSelection;
  final Future<void> Function()? onNewAnnotationSaved;

  const ExcerptMenu({
    super.key,
    required this.book,
    required this.annoCfi,
    required this.annoContent,
    this.chapter,
    this.annotationContext,
    this.lookupContext,
    this.initialType,
    this.initialColor,
    required this.persistenceSession,
    required this.onClose,
    required this.prepareExternalAction,
    required this.footnote,
    required this.decoration,
    required this.prepareInternalAction,
    required this.axis,
    required this.reverse,
    required this.refreshAnnotations,
    this.narrateSelection,
    this.onNewAnnotationSaved,
  });

  @override
  ExcerptMenuState createState() => ExcerptMenuState();
}

class ExcerptMenuState extends State<ExcerptMenu> {
  bool deleteConfirm = false;
  late String annoType;
  late String annoColor;
  Set<AnnotationEditorProvider> _completedProviders = const {};
  late bool _existingAnnotationLoaded;

  @override
  initState() {
    super.initState();
    annoType = widget.initialType ?? Prefs().annotationType;
    annoColor = (widget.initialColor ?? Prefs().annotationColor)
        .replaceFirst(RegExp(r'^#'), '');
    _existingAnnotationLoaded =
        !widget.persistenceSession.hasPersistedAnnotation;
    _initializeExistingAnnotation();
  }

  Future<void> _initializeExistingAnnotation() async {
    final ref = widget.persistenceSession.annotationRef;
    if (ref == null) return;
    try {
      final book =
          await canonicalAnnotationCatalog.readBook(ref.bookFingerprint);
      final annotation =
          book?.annotations.where((value) => value.ref == ref).firstOrNull;
      if (!mounted) return;
      if (annotation == null) {
        setState(() => _existingAnnotationLoaded = true);
        return;
      }
      final draft = AnnotationEditorDraft.forAnnotation(
        selection: widget.persistenceSession.snapshot,
        bookTitle: book?.title ?? '',
        annotation: annotation,
      );
      setState(() {
        annoType = annotation.localPresentation?.style.name ?? annoType;
        annoColor = annotation.localPresentation?.color ?? annoColor;
        _completedProviders = Set.unmodifiable(draft.sourceResults.keys);
        _existingAnnotationLoaded = true;
      });
    } catch (_) {
      // Canonical state may refresh concurrently; keep current UI defaults.
      if (mounted) setState(() => _existingAnnotationLoaded = true);
    }
  }

  bool _showProviderAction(AnnotationEditorProvider provider) =>
      _existingAnnotationLoaded &&
      !_completedProviders.contains(provider) &&
      (provider != AnnotationEditorProvider.audio ||
          selectedAiProviderSupportsOpenAiAudio());

  Future<SelectionAnnotationHandle> _createOrResolve(
      SelectionSnapshot snapshot) async {
    final result = await annotationRepository
        .createAnnotation(_canonicalCreation(snapshot));
    return SelectionAnnotationHandle(ref: result);
  }

  CanonicalSelectionCreation _canonicalCreation(SelectionSnapshot snapshot) {
    final pdfTarget = snapshot.pdfTarget;
    if (pdfTarget != null) {
      return CanonicalSelectionCreation.pdf(
        book: widget.book,
        selectedText: snapshot.selectedText,
        target: pdfTarget,
        chapter: snapshot.chapter,
        context: snapshot.annotationContext,
      );
    }
    return CanonicalSelectionCreation(
      book: widget.book,
      selectedText: snapshot.selectedText,
      epubCfi: snapshot.selector,
      chapter: snapshot.chapter,
      context: snapshot.annotationContext,
    );
  }

  Future<void> _openEditor({
    AnnotationEditorProvider? initialProvider,
    bool focusPersonalNote = false,
  }) async {
    final modalContext = navigatorKey.currentContext;
    if (modalContext == null) return;
    final wasNew = widget.persistenceSession.annotationRef == null;
    final session = widget.persistenceSession;
    if (!await widget.prepareInternalAction()) return;
    if (!modalContext.mounted) return;
    try {
      final outcome = await showAnnotationEditor(
        context: modalContext,
        book: widget.book,
        session: session,
        initialProvider: initialProvider,
        focusPersonalNote: focusPersonalNote,
      );
      if (outcome == AnnotationEditorOutcome.saved ||
          outcome == AnnotationEditorOutcome.deleted) {
        await widget.refreshAnnotations();
      }
      if (wasNew && outcome == AnnotationEditorOutcome.saved) {
        await widget.onNewAnnotationSaved?.call();
      }
    } catch (error) {
      if (modalContext.mounted) AnxToast.show(error.toString());
    }
  }

  Future<void> _persistNote({String? color, String? type}) async {
    final resolvedType = type ?? annoType;
    final resolvedColor = color ?? annoColor;

    final handle = await widget.persistenceSession.ensureAnnotation(
      _createOrResolve,
    );
    await annotationRepository.updatePresentation(
        handle.ref, resolvedType, resolvedColor);
    if (mounted) {
      setState(() {
        annoType = resolvedType;
        annoColor = resolvedColor;
      });
    } else {
      annoType = resolvedType;
      annoColor = resolvedColor;
    }
  }

  Future<void> _openDictionary() async {
    final dictionary = ExternalDictionaryService();
    if (!dictionary.isSupported) {
      await _openEditor(initialProvider: AnnotationEditorProvider.ldoce);
      return;
    }
    if (!await widget.prepareExternalAction()) return;
    final result = await dictionary.lookup(widget.annoContent);
    if (!mounted) return;
    switch (result) {
      case DictionaryLookupStatus.noHandlers:
        AnxToast.show(L10n.of(context).dictionaryNoCompatibleApp);
      case DictionaryLookupStatus.failed:
        AnxToast.show(L10n.of(context).dictionaryLaunchFailed);
      case DictionaryLookupStatus.unsupported:
      case DictionaryLookupStatus.launched:
        break;
    }
  }

  Icon deleteIcon() {
    return deleteConfirm
        ? const Icon(
            EvaIcons.close_circle,
            color: Colors.red,
          )
        : const Icon(Icons.delete);
  }

  Future<void> deleteHandler() async {
    final ref = widget.persistenceSession.annotationRef;
    if (ref == null) {
      widget.onClose();
      return;
    }
    if (deleteConfirm) {
      await annotationRepository.tombstoneAnnotation(ref);
      await widget.refreshAnnotations();
      widget.onClose();
    } else {
      setState(() {
        deleteConfirm = true;
      });
    }
  }

  Future<void> onColorSelected(String color, {bool close = true}) async {
    Prefs().annotationColor = color;
    if (mounted) {
      setState(() {
        annoColor = color;
      });
    } else {
      annoColor = color;
    }
    await _persistNote(color: color);
    await widget.refreshAnnotations();
    if (close) {
      widget.onClose();
    }
  }

  Future<void> onTypeSelected(String type) async {
    Prefs().annotationType = type;
    if (mounted) {
      setState(() {
        annoType = type;
      });
    } else {
      annoType = type;
    }
    await _persistNote(type: type);
    await widget.refreshAnnotations();
  }

  Widget iconButton({required Icon icon, required Function() onPressed}) {
    return IconButton(
      padding: const EdgeInsets.all(2),
      constraints: const BoxConstraints(),
      style: const ButtonStyle(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      icon: icon,
      onPressed: onPressed,
    );
  }

  Widget colorButton(String color) {
    return iconButton(
      icon: Icon(
        Icons.circle,
        color: Color(int.parse('0x88$color')),
      ),
      onPressed: () {
        onColorSelected(color);
      },
    );
  }

  Widget typeButton(String type, IconData icon) {
    return iconButton(
      icon: Icon(icon,
          color: annoType == type ? Color(int.parse('0xff$annoColor')) : null),
      onPressed: () {
        onTypeSelected(type);
      },
    );
  }

  Future<void> _runSecondaryAction(
      BuildContext context, _SecondarySelectionAction action) async {
    switch (action) {
      case _SecondarySelectionAction.copy:
        await Clipboard.setData(ClipboardData(text: widget.annoContent));
        if (context.mounted) {
          AnxToast.show(L10n.of(context).notesPageCopied);
        }
        break;
      case _SecondarySelectionAction.search:
        if (!await widget.prepareExternalAction()) return;
        await launchUrl(
          Uri.parse('https://www.bing.com/search?q=${widget.annoContent}'),
          mode: LaunchMode.externalApplication,
        );
        return;
      case _SecondarySelectionAction.narrate:
        final narrateSelection = widget.narrateSelection;
        if (narrateSelection == null) return;
        await narrateSelection();
        break;
      case _SecondarySelectionAction.share:
        if (!context.mounted) return;
        if (!await widget.prepareExternalAction()) return;
        if (!context.mounted) return;
        await ExcerptShareService.showShareExcerpt(
          context: context,
          bookTitle: widget.book.title,
          author: widget.book.author,
          excerpt: widget.annoContent,
          chapter: widget.chapter ?? '',
        );
        return;
    }
    widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    Widget annotationMenu = Container(
      padding: const EdgeInsets.all(6),
      decoration: widget.decoration,
      child: AxisFlex(
        axis: widget.axis,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.persistenceSession.hasPersistedAnnotation)
            iconButton(
              onPressed: deleteHandler,
              icon: deleteIcon(),
            ),
          for (final type in notesType) typeButton(type.type, type.icon),
          for (String color in notesColors) colorButton(color),
        ],
      ),
    );

    Widget operatorMenu = Container(
      // width: 48,
      decoration: widget.decoration,
      child: AxisFlex(
        axis: widget.axis,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.persistenceSession.hasPersistedAnnotation)
            IconAndText(
              compact: true,
              onTap: () => _openEditor(focusPersonalNote: true),
              icon: const Icon(EvaIcons.edit_2_outline),
              text: L10n.of(context).annotationEditorEditTitle,
            ),
          if (_showProviderAction(AnnotationEditorProvider.ai))
            IconAndText(
              compact: true,
              onTap: () => _openEditor(
                initialProvider: AnnotationEditorProvider.ai,
              ),
              icon: const Icon(EvaIcons.message_circle_outline),
              text: L10n.of(context).navBarAI,
            ),
          IconAndText(
            compact: true,
            onTap: _openDictionary,
            icon: const Icon(Icons.menu_book),
            text: L10n.of(context).contextMenuDictionary,
          ),
          if (_showProviderAction(AnnotationEditorProvider.googleTranslate))
            IconAndText(
              compact: true,
              onTap: () => _openEditor(
                initialProvider: AnnotationEditorProvider.googleTranslate,
              ),
              icon: const Icon(Icons.g_translate),
              text: L10n.of(context).contextMenuGoogleTranslate,
            ),
          if (_showProviderAction(AnnotationEditorProvider.audio))
            IconAndText(
              compact: true,
              onTap: () => _openEditor(
                initialProvider: AnnotationEditorProvider.audio,
              ),
              icon: const Icon(Icons.volume_up_outlined),
              text: 'Озвучить / Audio',
            ),
          if (!widget.persistenceSession.hasPersistedAnnotation &&
              !widget.footnote)
            IconAndText(
              compact: true,
              onTap: () => _openEditor(focusPersonalNote: true),
              icon: const Icon(EvaIcons.edit_2_outline),
              text: L10n.of(context).contextMenuWriteIdea,
            ),
          PopupMenuButton<_SecondarySelectionAction>(
            tooltip: MaterialLocalizations.of(context).moreButtonTooltip,
            icon: const Icon(Icons.more_horiz),
            onSelected: (action) => _runSecondaryAction(context, action),
            itemBuilder: (context) => [
              PopupMenuItem(
                value: _SecondarySelectionAction.copy,
                child: Text(L10n.of(context).contextMenuCopy),
              ),
              PopupMenuItem(
                value: _SecondarySelectionAction.search,
                child: Text(L10n.of(context).contextMenuSearch),
              ),
              if (widget.narrateSelection != null)
                PopupMenuItem(
                  value: _SecondarySelectionAction.narrate,
                  child: Text(L10n.of(context).contextMenuNarrate),
                ),
              PopupMenuItem(
                value: _SecondarySelectionAction.share,
                child: Text(L10n.of(context).contextMenuShare),
              ),
            ],
          ),
        ],
      ),
    );

    return Expanded(
      child: AxisFlex(
        reverse: widget.reverse,
        axis: flipAxis(widget.axis),
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AxisFlex(
            axis: flipAxis(widget.axis),
            reverse: widget.reverse,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SingleChildScrollView(
                  scrollDirection: widget.axis, child: operatorMenu),
              const SizedBox.square(dimension: 10),
              if (!widget.footnote)
                SingleChildScrollView(
                  scrollDirection: widget.axis,
                  child: annotationMenu,
                ),
            ],
          ),
        ],
      ),
    );
  }
}
