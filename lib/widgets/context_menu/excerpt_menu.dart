import 'dart:io';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/constants/note_annotations.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/main.dart';
import 'package:anx_reader/page/reading_page.dart';
import 'package:anx_reader/page/book_player/selection_persistence_session.dart';
import 'package:anx_reader/service/dictionary/external_dictionary.dart';
import 'package:anx_reader/service/sync/annotation_repository.dart';
import 'package:anx_reader/service/sync/annotation_catalog.dart';
import 'package:anx_reader/service/tts/tts_handler.dart';
import 'package:anx_reader/service/translate/google_translate_app.dart';
import 'package:anx_reader/utils/env_var.dart';
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
  final String annoCfi;
  final String annoContent;
  final String? chapter;
  final String? annotationContext;
  final String? lookupContext;
  final String? initialType;
  final String? initialColor;
  final SelectionPersistenceSession persistenceSession;
  final Function() onClose;
  final bool footnote;
  final BoxDecoration decoration;
  final Function() toggleTranslationMenu;
  final void Function({bool? show}) toggleReaderNoteMenu;
  final Future<void> Function(String? personalNote) openReaderNoteMenu;
  final Axis axis;
  final bool reverse;

  const ExcerptMenu({
    super.key,
    required this.annoCfi,
    required this.annoContent,
    this.chapter,
    this.annotationContext,
    this.lookupContext,
    this.initialType,
    this.initialColor,
    required this.persistenceSession,
    required this.onClose,
    required this.footnote,
    required this.decoration,
    required this.toggleTranslationMenu,
    required this.toggleReaderNoteMenu,
    required this.openReaderNoteMenu,
    required this.axis,
    required this.reverse,
  });

  @override
  ExcerptMenuState createState() => ExcerptMenuState();
}

class ExcerptMenuState extends State<ExcerptMenu> {
  bool deleteConfirm = false;
  String? _currentPersonalNote;
  late String annoType;
  late String annoColor;

  @override
  initState() {
    super.initState();
    annoType = widget.initialType ?? Prefs().annotationType;
    annoColor = (widget.initialColor ?? Prefs().annotationColor)
        .replaceFirst(RegExp(r'^#'), '');
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
      if (!mounted || annotation == null) return;
      setState(() {
        _currentPersonalNote = annotation.effectivePersonalNote?.content;
        annoType = annotation.localPresentation?.style.name ?? annoType;
        annoColor = annotation.localPresentation?.color ?? annoColor;
      });
      if (!widget.footnote && _currentPersonalNote?.isNotEmpty == true) {
        await widget.openReaderNoteMenu(_currentPersonalNote);
      }
    } catch (_) {
      // Canonical state may refresh concurrently; keep current UI defaults.
    }
  }

  Future<SelectionAnnotationHandle> _createOrResolve(
      SelectionSnapshot snapshot) async {
    final result = await annotationRepository
        .createAnnotation(_canonicalCreation(snapshot));
    return SelectionAnnotationHandle(ref: result.ref);
  }

  CanonicalSelectionCreation _canonicalCreation(SelectionSnapshot snapshot) {
    final player = epubPlayerKey.currentState!;
    return CanonicalSelectionCreation(
      book: player.book,
      selectedText: snapshot.selectedText,
      epubCfi: snapshot.selector,
      chapter:
          snapshot.chapter.isEmpty ? player.chapterTitle : snapshot.chapter,
      context: snapshot.annotationContext,
    );
  }

  Future<void> savePersonalNote(String value) async {
    await widget.persistenceSession.persistWithFirstSave(
      createAndSave: (snapshot) async {
        final mutation =
            await annotationRepository.createAnnotationWithPersonalNote(
                _canonicalCreation(snapshot), value);
        return SelectionFirstSaveResult(
            SelectionAnnotationHandle(ref: mutation.ref), mutation);
      },
      save: (ref) => annotationRepository.setPersonalNote(ref, value),
    );
    _currentPersonalNote = value.trim();
    await epubPlayerKey.currentState!.refreshAnnotations();
  }

  Future<void> saveTranslation(String value) async {
    await widget.persistenceSession.persistWithFirstSave(
      createAndSave: (snapshot) async {
        final mutation =
            await annotationRepository.createAnnotationWithTranslation(
                _canonicalCreation(snapshot), value);
        return SelectionFirstSaveResult(
            SelectionAnnotationHandle(ref: mutation.ref), mutation);
      },
      save: (ref) => annotationRepository.saveTranslation(ref, value),
    );
    await epubPlayerKey.currentState!.refreshAnnotations();
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

  Icon deleteIcon() {
    return deleteConfirm
        ? const Icon(
            EvaIcons.close_circle,
            color: Colors.red,
          )
        : const Icon(Icons.delete);
  }

  Future<void> deleteHandler() async {
    if (deleteConfirm) {
      final handle = await widget.persistenceSession.ensureAnnotation(
        _createOrResolve,
      );
      await annotationRepository.tombstoneAnnotation(handle.ref);
      await epubPlayerKey.currentState!.refreshAnnotations();
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
    await epubPlayerKey.currentState!.refreshAnnotations();
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
    await epubPlayerKey.currentState!.refreshAnnotations();
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
        await launchUrl(
          Uri.parse('https://www.bing.com/search?q=${widget.annoContent}'),
          mode: LaunchMode.externalApplication,
        );
        break;
      case _SecondarySelectionAction.narrate:
        final playerState = epubPlayerKey.currentState;
        if (playerState == null) return;
        await audioHandler.stop();
        await TtsHandler().init(
          () => playerState.initTts(fromCfi: widget.annoCfi),
          playerState.ttsNext,
          playerState.ttsPrev,
        );
        await audioHandler.play();
        break;
      case _SecondarySelectionAction.share:
        if (!context.mounted) return;
        ExcerptShareService.showShareExcerpt(
          context: context,
          bookTitle: epubPlayerKey.currentState!.book.title,
          author: epubPlayerKey.currentState!.book.author,
          excerpt: widget.annoContent,
          chapter: epubPlayerKey.currentState!.chapterTitle,
        );
        break;
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
          if (EnvVar.enableAIFeature)
            IconAndText(
              compact: true,
              onTap: () {
                widget.onClose();
                final key = readingPageKey.currentState;
                if (key != null) {
                  key.showAiChat(
                    content: widget.annoContent,
                    sendImmediate: false,
                  );
                  key.aiChatKey.currentState?.inputController.text =
                      widget.annoContent;
                }
              },
              icon: const Icon(EvaIcons.message_circle_outline),
              text: L10n.of(context).navBarAI,
            ),
          // External Android dictionary
          if (Platform.isAndroid)
            IconAndText(
              compact: true,
              onTap: () async {
                widget.onClose();
                final result = await ExternalDictionaryService()
                    .lookup(widget.annoContent);
                if (!context.mounted) return;
                switch (result) {
                  case DictionaryLookupStatus.noHandlers:
                    AnxToast.show(
                      L10n.of(context).dictionaryNoCompatibleApp,
                    );
                  case DictionaryLookupStatus.failed:
                    AnxToast.show(L10n.of(context).dictionaryLaunchFailed);
                  case DictionaryLookupStatus.unsupported:
                  case DictionaryLookupStatus.launched:
                    break;
                }
              },
              icon: const Icon(Icons.menu_book),
              text: L10n.of(context).contextMenuDictionary,
            ),
          // Official Google Translate Android app
          if (Platform.isAndroid)
            IconAndText(
              compact: true,
              onTap: () async {
                widget.onClose();
                final result = await GoogleTranslateAppService()
                    .translate(widget.annoContent);
                if (!context.mounted) return;
                switch (result) {
                  case GoogleTranslateAppStatus.notInstalled:
                    AnxToast.show(
                      L10n.of(context).googleTranslateAppNotInstalled,
                    );
                  case GoogleTranslateAppStatus.failed:
                    AnxToast.show(
                      L10n.of(context).googleTranslateAppLaunchFailed,
                    );
                  case GoogleTranslateAppStatus.unsupported:
                  case GoogleTranslateAppStatus.clipboardFallback:
                  case GoogleTranslateAppStatus.launched:
                    break;
                }
              },
              icon: const Icon(Icons.g_translate),
              text: L10n.of(context).contextMenuGoogleTranslate,
            ),
          IconAndText(
            compact: true,
            onTap: widget.toggleTranslationMenu,
            icon: const Icon(Icons.translate),
            text: L10n.of(context).contextMenuTranslate,
          ),
          if (!widget.footnote)
            IconAndText(
              compact: true,
              onTap: () async {
                await widget.openReaderNoteMenu(_currentPersonalNote);
              },
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
