import 'dart:math' as math;

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/page/book_player/pdf_reading_position.dart';
import 'package:anx_reader/page/book_player/selection_persistence_session.dart';
import 'package:anx_reader/service/sync/annotation_selectors.dart';
import 'package:anx_reader/widgets/context_menu/excerpt_menu.dart';
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

class PdfSelectionActionMenu extends StatefulWidget {
  const PdfSelectionActionMenu({
    super.key,
    required this.book,
    required this.selection,
    required this.primaryAnchor,
    required this.secondaryAnchor,
    required this.dismissContextMenu,
    required this.refreshAnnotations,
  });

  final Book book;
  final PdfTextSelectionDelegate selection;
  final Offset primaryAnchor;
  final Offset? secondaryAnchor;
  final VoidCallback dismissContextMenu;
  final Future<void> Function() refreshAnnotations;

  @override
  State<PdfSelectionActionMenu> createState() => _PdfSelectionActionMenuState();
}

class _PdfSelectionActionMenuState extends State<PdfSelectionActionMenu> {
  late final Future<_PdfSelectionMenuData?> _data = _loadData();

  Future<_PdfSelectionMenuData?> _loadData() async {
    final ranges = await widget.selection.getSelectedTextRanges();
    if (ranges.length != 1) return null;
    final range = ranges.single;
    final target = PdfAnnotationTarget.fromPageText(
      page: range.pageNumber,
      pageText: range.pageText.fullText,
      start: range.start,
      end: range.end,
    );
    final context = '${target.prefix}${target.exact}${target.suffix}';
    return _PdfSelectionMenuData(
      target: target,
      context: context,
      session: SelectionPersistenceSession(
        SelectionSnapshot(
          selectedText: target.exact,
          annotationContext: context,
          lookupContext: context,
          chapter: 'Page ${target.page}',
          selector: encodePdfReadingPosition(target.page),
          pdfTarget: target,
        ),
      ),
    );
  }

  void _close() => widget.dismissContextMenu();

  Future<bool> _prepareAction() async {
    widget.dismissContextMenu();
    return mounted;
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topLeft,
      child: FutureBuilder<_PdfSelectionMenuData?>(
        future: _data,
        builder: (context, snapshot) {
          final data = snapshot.data;
          if (data == null) return const SizedBox.shrink();
          final colors = Theme.of(context).colorScheme;
          final decoration = BoxDecoration(
            color: Prefs().eInkMode ? Colors.white : colors.secondaryContainer,
            borderRadius: BorderRadius.circular(10),
            boxShadow: [
              if (Prefs().eInkMode)
                const BoxShadow(color: Colors.black, spreadRadius: 1)
              else
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.1),
                  spreadRadius: 5,
                  blurRadius: 7,
                  offset: const Offset(0, 3),
                ),
            ],
          );
          return CustomSingleChildLayout(
            delegate: _PdfSelectionMenuLayout(
              primaryAnchor: widget.primaryAnchor,
              secondaryAnchor: widget.secondaryAnchor,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ExcerptMenu(
                  book: widget.book,
                  annoCfi: encodePdfReadingPosition(data.target.page),
                  annoContent: data.target.exact,
                  chapter: 'Page ${data.target.page}',
                  annotationContext: data.context,
                  lookupContext: data.context,
                  persistenceSession: data.session,
                  onClose: _close,
                  prepareExternalAction: _prepareAction,
                  footnote: false,
                  decoration: decoration,
                  prepareInternalAction: _prepareAction,
                  axis: Axis.horizontal,
                  reverse: false,
                  refreshAnnotations: widget.refreshAnnotations,
                  onNewAnnotationSaved: () async {
                    await widget.selection.clearTextSelection();
                    widget.dismissContextMenu();
                  },
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _PdfSelectionMenuData {
  const _PdfSelectionMenuData({
    required this.target,
    required this.context,
    required this.session,
  });

  final PdfAnnotationTarget target;
  final String context;
  final SelectionPersistenceSession session;
}

class _PdfSelectionMenuLayout extends SingleChildLayoutDelegate {
  const _PdfSelectionMenuLayout({
    required this.primaryAnchor,
    required this.secondaryAnchor,
  });

  final Offset primaryAnchor;
  final Offset? secondaryAnchor;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return BoxConstraints.loose(Size(
      math.max(0, math.min(350, constraints.maxWidth - 32)),
      math.max(0, math.min(300, constraints.maxHeight - 32)),
    ));
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    const margin = 16.0;
    const gap = 12.0;
    final other = secondaryAnchor ?? primaryAnchor;
    final selection = Rect.fromPoints(primaryAnchor, other);
    final left = (selection.center.dx - childSize.width / 2).clamp(
      margin,
      math.max(margin, size.width - childSize.width - margin),
    );
    final above = selection.top - childSize.height - gap;
    final below = selection.bottom + gap;
    final top = (above >= margin ? above : below).clamp(
      margin,
      math.max(margin, size.height - childSize.height - margin),
    );
    return Offset(left.toDouble(), top.toDouble());
  }

  @override
  bool shouldRelayout(covariant _PdfSelectionMenuLayout oldDelegate) =>
      oldDelegate.primaryAnchor != primaryAnchor ||
      oldDelegate.secondaryAnchor != secondaryAnchor;
}
