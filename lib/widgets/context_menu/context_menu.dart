import 'dart:math' as math;

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/page/reading_page.dart';
import 'package:anx_reader/page/book_player/selection_persistence_session.dart';
import 'package:anx_reader/service/sync/annotation_read_model.dart';
import 'package:anx_reader/widgets/common/axis_flex.dart';
import 'package:anx_reader/widgets/context_menu/excerpt_menu.dart';
import 'package:anx_reader/widgets/context_menu/reader_note_menu.dart';
import 'package:anx_reader/widgets/context_menu/translation_menu.dart';
import 'package:flutter/material.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';

Future<void> showContextMenu(
    BuildContext context,
    double left,
    double top,
    double right,
    double bottom,
    String annoContent,
    String annoCfi,
    bool footnote,
    Axis axis,
    {String? chapter,
    String? annotationContext,
    String? lookupContext,
    int? selectionSessionGeneration,
    AnnotationRef? annotationRef,
    String? annotationType,
    String? annotationColor}) async {
  final playerKey = epubPlayerKey.currentState;
  if (playerKey == null) return;
  if (selectionSessionGeneration != null &&
      !playerKey.isSelectionSessionCurrent(selectionSessionGeneration)) {
    return;
  }

  if (!context.mounted) return;

  final renderBox =
      epubPlayerKey.currentContext?.findRenderObject() as RenderBox?;
  final renderBoxSize = renderBox?.size;

  final mediaQuery = MediaQuery.of(context);
  final double screenHeight = renderBoxSize?.height ?? mediaQuery.size.height;
  final double screenWidth = renderBoxSize?.width ?? mediaQuery.size.width;
  final double keyboardInset = mediaQuery.viewInsets.bottom;

  final Offset localToGlobal =
      renderBox?.localToGlobal(Offset.zero) ?? Offset.zero;

  final viewportRect = Rect.fromLTWH(
    localToGlobal.dx,
    localToGlobal.dy,
    screenWidth,
    screenHeight,
  );

  final selectionRect = Rect.fromLTRB(
    localToGlobal.dx + left * screenWidth,
    localToGlobal.dy + top * screenHeight,
    localToGlobal.dx + right * screenWidth,
    localToGlobal.dy + bottom * screenHeight,
  );

  const double horizontalMargin = 16;
  const double verticalMargin = 16;
  const double gap = 12;

  final double maxMenuWidth =
      math.min(350, math.max(120, screenWidth - horizontalMargin * 2));
  final double effectiveHeight = math.max(0, screenHeight - keyboardInset);
  final double maxHeightCandidate = effectiveHeight - verticalMargin * 2;
  final double rawMaxHeight = math.min(
    footnote ? 350 : 550,
    math.max(200, maxHeightCandidate),
  );
  final double maxMenuHeight = math.max(
    0,
    math.min(rawMaxHeight, maxHeightCandidate),
  );

  final menuConstraints = BoxConstraints(
    maxWidth: maxMenuWidth,
    maxHeight: maxMenuHeight,
  );

  final initialPlacement = _resolveMenuPlacement(
    axis: axis,
    selectionRect: selectionRect,
    viewportRect: viewportRect,
    menuSize: Size(maxMenuWidth, maxMenuHeight),
    horizontalMargin: horizontalMargin,
    verticalMargin: verticalMargin,
    gap: gap,
    bottomInset: keyboardInset,
  );

  playerKey.removeOverlay();
  if (selectionSessionGeneration != null &&
      !playerKey.isSelectionSessionCurrent(selectionSessionGeneration)) {
    return;
  }

  void onClose() {
    if (selectionSessionGeneration != null) {
      playerKey.hideSelectionActions(selectionSessionGeneration);
    } else {
      playerKey.removeOverlay();
    }
  }

  Future<bool> prepareExternalAction() async {
    if (selectionSessionGeneration != null) {
      return playerKey.prepareSelectionForExternalAction(
        selectionSessionGeneration,
      );
    }
    playerKey.removeOverlay();
    return true;
  }

  final decoration = BoxDecoration(
    color: Prefs().eInkMode
        ? Colors.white
        : Theme.of(context).colorScheme.secondaryContainer,
    borderRadius: BorderRadius.circular(10),
    boxShadow: [
      if (!Prefs().eInkMode)
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.1),
          spreadRadius: 5,
          blurRadius: 7,
          offset: const Offset(0, 3),
        ),
      if (Prefs().eInkMode)
        const BoxShadow(
          color: Colors.black,
          spreadRadius: 1,
          blurRadius: 0,
        ),
    ],
  );

  playerKey.contextMenuEntry = OverlayEntry(builder: (context) {
    return _ContextMenuOverlay(
      axis: axis,
      selectionRect: selectionRect,
      viewportRect: viewportRect,
      annoContent: annoContent,
      annoCfi: annoCfi,
      footnote: footnote,
      chapter: chapter,
      annotationContext: annotationContext,
      lookupContext: lookupContext,
      annotationRef: annotationRef,
      annotationType: annotationType,
      annotationColor: annotationColor,
      decoration: decoration,
      onClose: onClose,
      prepareExternalAction: prepareExternalAction,
      menuConstraints: menuConstraints,
      initialPlacement: initialPlacement,
      showTranslationDefault: Prefs().autoTranslateSelection,
      horizontalMargin: horizontalMargin,
      verticalMargin: verticalMargin,
      gap: gap,
      initialBottomInset: keyboardInset,
    );
  });

  playerKey.contextMenuSelectionSessionGeneration = selectionSessionGeneration;
  Overlay.of(context).insert(playerKey.contextMenuEntry!);
}

class _MenuPlacement {
  const _MenuPlacement({required this.offset, required this.shouldReverse});

  final Offset offset;
  final bool shouldReverse;
}

double _clampWithin(double value, double min, double max) {
  if (min > max) {
    return min;
  }
  return value.clamp(min, max);
}

_MenuPlacement _resolveMenuPlacement({
  required Axis axis,
  required Rect selectionRect,
  required Rect viewportRect,
  required Size menuSize,
  required double horizontalMargin,
  required double verticalMargin,
  required double gap,
  required double bottomInset,
}) {
  final double menuWidth = menuSize.width;
  final double menuHeight = menuSize.height;

  final double clampedViewportBottom =
      math.max(viewportRect.top, viewportRect.bottom - bottomInset);

  if (axis == Axis.horizontal) {
    final double spaceAbove = selectionRect.top - viewportRect.top;
    final double spaceBelow = clampedViewportBottom - selectionRect.bottom;
    final bool placeBelow =
        (spaceBelow >= menuHeight + gap) || (spaceBelow >= spaceAbove);

    final double minTop = viewportRect.top + verticalMargin;
    final double maxTop = clampedViewportBottom - menuHeight - verticalMargin;
    double desiredTop = placeBelow
        ? selectionRect.bottom + gap
        : selectionRect.top - menuHeight - gap;
    desiredTop = _clampWithin(desiredTop, minTop, maxTop);

    final double minLeft = viewportRect.left + horizontalMargin;
    final double maxLeft = viewportRect.right - menuWidth - horizontalMargin;
    double desiredLeft = selectionRect.center.dx - menuWidth / 2;
    desiredLeft = _clampWithin(desiredLeft, minLeft, maxLeft);

    return _MenuPlacement(
      offset: Offset(desiredLeft, desiredTop),
      shouldReverse: !placeBelow,
    );
  }

  final double spaceLeft = selectionRect.left - viewportRect.left;
  final double spaceRight = viewportRect.right - selectionRect.right;
  final bool placeRight =
      (spaceRight >= menuWidth + gap) || (spaceRight >= spaceLeft);

  final double minLeft = viewportRect.left + horizontalMargin;
  final double maxLeft = viewportRect.right - menuWidth - horizontalMargin;
  double desiredLeft = placeRight
      ? selectionRect.right + gap
      : selectionRect.left - menuWidth - gap;
  desiredLeft = _clampWithin(desiredLeft, minLeft, maxLeft);

  final double minTop = viewportRect.top + verticalMargin;
  final double maxTop = clampedViewportBottom - menuHeight - verticalMargin;
  double desiredTop = selectionRect.center.dy - menuHeight / 2;
  desiredTop = _clampWithin(desiredTop, minTop, maxTop);

  return _MenuPlacement(
    offset: Offset(desiredLeft, desiredTop),
    shouldReverse: !placeRight,
  );
}

class _ContextMenuOverlay extends StatefulWidget {
  const _ContextMenuOverlay({
    required this.axis,
    required this.selectionRect,
    required this.viewportRect,
    required this.annoContent,
    required this.annoCfi,
    required this.footnote,
    this.chapter,
    this.annotationContext,
    this.lookupContext,
    this.annotationRef,
    this.annotationType,
    this.annotationColor,
    required this.decoration,
    required this.onClose,
    required this.prepareExternalAction,
    required this.menuConstraints,
    required this.initialPlacement,
    required this.showTranslationDefault,
    required this.horizontalMargin,
    required this.verticalMargin,
    required this.gap,
    required this.initialBottomInset,
  });

  final Axis axis;
  final Rect selectionRect;
  final Rect viewportRect;
  final String annoContent;
  final String annoCfi;
  final bool footnote;
  final String? chapter;
  final String? annotationContext;
  final String? lookupContext;
  final AnnotationRef? annotationRef;
  final String? annotationType;
  final String? annotationColor;
  final BoxDecoration decoration;
  final VoidCallback onClose;
  final Future<bool> Function() prepareExternalAction;
  final BoxConstraints menuConstraints;
  final _MenuPlacement initialPlacement;
  final bool showTranslationDefault;
  final double horizontalMargin;
  final double verticalMargin;
  final double gap;
  final double initialBottomInset;

  @override
  State<_ContextMenuOverlay> createState() => _ContextMenuOverlayState();
}

class _ContextMenuOverlayState extends State<_ContextMenuOverlay>
    with WidgetsBindingObserver {
  final GlobalKey _menuKey = GlobalKey();
  final GlobalKey<ExcerptMenuState> _excerptMenuKey =
      GlobalKey<ExcerptMenuState>();
  final GlobalKey<ReaderNoteMenuState> _readerNoteMenuKey =
      GlobalKey<ReaderNoteMenuState>();

  late Offset _position;
  late bool _reverse;
  late bool _showTranslationMenu;
  bool _showReaderNoteMenu = false;
  bool _waitingForFirstMeasurement = true;
  late BoxConstraints _menuConstraints;
  late double _bottomInset;
  late final SelectionPersistenceSession _persistenceSession;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _position = widget.initialPlacement.offset;
    _reverse = widget.initialPlacement.shouldReverse;
    _showTranslationMenu = widget.showTranslationDefault;
    _persistenceSession = SelectionPersistenceSession(
      SelectionSnapshot(
        selectedText: widget.annoContent,
        annotationContext: widget.annotationContext,
        lookupContext: widget.lookupContext,
        chapter: widget.chapter ?? '',
        selector: widget.annoCfi,
      ),
      existingAnnotation: widget.annotationRef == null
          ? null
          : SelectionAnnotationHandle(ref: widget.annotationRef!),
    );
    _bottomInset = widget.initialBottomInset;
    _menuConstraints = _buildConstraints(widget.initialBottomInset);
    _scheduleRecalculate();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  BoxConstraints _buildConstraints(double bottomInset) {
    final original = widget.menuConstraints;
    final double availableHeight = math.max(
      0,
      widget.viewportRect.height - bottomInset - widget.verticalMargin * 2,
    );

    double maxHeight;
    if (original.hasBoundedHeight) {
      maxHeight = math.min(original.maxHeight, availableHeight);
    } else {
      maxHeight = availableHeight;
    }
    maxHeight = math.max(0, maxHeight);

    final double minHeight = math.min(original.minHeight, maxHeight);

    return BoxConstraints(
      minWidth: original.minWidth,
      maxWidth: original.maxWidth,
      minHeight: minHeight,
      maxHeight: maxHeight,
    );
  }

  void _scheduleRecalculate({Duration delay = Duration.zero}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (delay == Duration.zero) {
        _updatePlacement();
      } else {
        Future.delayed(delay, () {
          if (!mounted) return;
          _updatePlacement();
        });
      }
    });
  }

  @override
  void didChangeMetrics() {
    if (!mounted) return;
    _scheduleRecalculate();
  }

  void _updatePlacement() {
    final renderBox = _menuKey.currentContext?.findRenderObject() as RenderBox?;
    final double currentBottomInset = MediaQuery.of(context).viewInsets.bottom;
    final newConstraints = _buildConstraints(currentBottomInset);

    if (renderBox == null) {
      final bool needsStateUpdate =
          (_bottomInset - currentBottomInset).abs() > 0.5 ||
              _menuConstraints.maxHeight != newConstraints.maxHeight;

      if (needsStateUpdate) {
        setState(() {
          _bottomInset = currentBottomInset;
          _menuConstraints = newConstraints;
        });
      }
      return;
    }

    final size = renderBox.size;
    final placement = _resolveMenuPlacement(
      axis: widget.axis,
      selectionRect: widget.selectionRect,
      viewportRect: widget.viewportRect,
      menuSize: size,
      horizontalMargin: widget.horizontalMargin,
      verticalMargin: widget.verticalMargin,
      gap: widget.gap,
      bottomInset: currentBottomInset,
    );

    final bool positionChanged =
        (_position.dx - placement.offset.dx).abs() > 0.5 ||
            (_position.dy - placement.offset.dy).abs() > 0.5;

    final bool bottomInsetChanged =
        (_bottomInset - currentBottomInset).abs() > 0.5;

    final bool constraintsChanged =
        _menuConstraints.maxHeight != newConstraints.maxHeight;

    final bool shouldUpdate = _waitingForFirstMeasurement ||
        positionChanged ||
        _reverse != placement.shouldReverse ||
        bottomInsetChanged ||
        constraintsChanged;

    if (shouldUpdate) {
      setState(() {
        _position = placement.offset;
        _reverse = placement.shouldReverse;
        _bottomInset = currentBottomInset;
        _menuConstraints = newConstraints;
        _waitingForFirstMeasurement = false;
      });
    }
  }

  void _toggleReaderNoteMenu({bool? show}) {
    final target = show ?? !_showReaderNoteMenu;
    setState(() {
      _showReaderNoteMenu = target;
    });
    _scheduleRecalculate(
      delay: _showReaderNoteMenu
          ? const Duration(milliseconds: 300)
          : Duration.zero,
    );
  }

  Future<void> _openReaderNoteMenu(String? personalNote) async {
    _toggleReaderNoteMenu(show: true);
    if (_readerNoteMenuKey.currentState == null) {
      await Future.delayed(const Duration(milliseconds: 50));
    }
    await _readerNoteMenuKey.currentState?.showNoteDialog(personalNote);
    _scheduleRecalculate(delay: const Duration(milliseconds: 300));
  }

  void _handleReaderNoteVisibilityChange(bool visible) {
    if (_showReaderNoteMenu == visible) {
      return;
    }
    setState(() {
      _showReaderNoteMenu = visible;
    });
    _scheduleRecalculate(
      delay: visible ? const Duration(milliseconds: 300) : Duration.zero,
    );
  }

  void _handleReaderNoteSizeChanged() {
    _scheduleRecalculate();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: _position.dx,
      top: _position.dy,
      child: PointerInterceptor(
        child: Stack(
          children: [
            GestureDetector(
              onTap: widget.onClose,
              child: IgnorePointer(
                ignoring: _waitingForFirstMeasurement,
                child: Opacity(
                  opacity: _waitingForFirstMeasurement ? 0 : 1,
                  child: Container(
                    key: _menuKey,
                    color: Colors.transparent,
                    constraints: _menuConstraints,
                    child: AxisFlex(
                      axis: flipAxis(widget.axis),
                      reverse: _reverse,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AxisFlex(
                          axis: flipAxis(widget.axis),
                          reverse: _reverse,
                          children: [
                            AxisFlex(
                              axis: widget.axis,
                              children: [
                                ExcerptMenu(
                                  key: _excerptMenuKey,
                                  annoCfi: widget.annoCfi,
                                  annoContent: widget.annoContent,
                                  chapter: widget.chapter,
                                  annotationContext: widget.annotationContext,
                                  lookupContext: widget.lookupContext,
                                  initialType: widget.annotationType,
                                  initialColor: widget.annotationColor,
                                  persistenceSession: _persistenceSession,
                                  onClose: widget.onClose,
                                  prepareExternalAction:
                                      widget.prepareExternalAction,
                                  footnote: widget.footnote,
                                  decoration: widget.decoration,
                                  toggleReaderNoteMenu: _toggleReaderNoteMenu,
                                  openReaderNoteMenu: _openReaderNoteMenu,
                                  axis: widget.axis,
                                  reverse: _reverse,
                                ),
                              ],
                            ),
                          ],
                        ),
                        if (_showReaderNoteMenu) ...[
                          const SizedBox.square(dimension: 10),
                          AxisFlex(
                            axis: widget.axis,
                            children: [
                              ReaderNoteMenu(
                                key: _readerNoteMenuKey,
                                initialValue: null,
                                decoration: widget.decoration,
                                axis: widget.axis,
                                onVisibilityChange:
                                    _handleReaderNoteVisibilityChange,
                                onSizeChanged: _handleReaderNoteSizeChanged,
                                onSave: (value) async {
                                  await _excerptMenuKey.currentState
                                      ?.savePersonalNote(value);
                                },
                              ),
                            ],
                          ),
                        ],
                        if (_showTranslationMenu) ...[
                          const SizedBox.square(dimension: 10),
                          AxisFlex(
                            axis: widget.axis,
                            children: [
                              TranslationMenu(
                                content: widget.annoContent,
                                decoration: widget.decoration,
                                axis: widget.axis,
                                lookupContext: widget.lookupContext,
                                onSave: (translation) async {
                                  await _excerptMenuKey.currentState
                                      ?.saveTranslation(translation);
                                },
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
