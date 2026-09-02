import 'dart:async';
import 'dart:ui' as ui;

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/page/book_player/annotation_editor/annotation_editor.dart';
import 'package:anx_reader/page/book_player/pdf_reading_position.dart';
import 'package:anx_reader/page/book_player/pdf_reflow_view.dart';
import 'package:anx_reader/page/book_player/pdf_text_blocks.dart';
import 'package:anx_reader/page/book_player/selection_persistence_session.dart';
import 'package:anx_reader/providers/book_list.dart';
import 'package:anx_reader/providers/current_reading.dart';
import 'package:anx_reader/service/sync/annotation_read_model.dart';
import 'package:anx_reader/service/sync/annotation_selectors.dart';
import 'package:anx_reader/service/sync/annotation_sync_runtime.dart';
import 'package:anx_reader/service/translate/full_text_translation_cache_service.dart';
import 'package:anx_reader/utils/toast/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';

class PdfPlayer extends ConsumerStatefulWidget {
  const PdfPlayer({
    super.key,
    required this.book,
    this.initialPosition,
    required this.showOrHideAppBarAndBottomBar,
    required this.onReadingModeChanged,
  });

  final Book book;
  final String? initialPosition;
  final void Function(bool show) showOrHideAppBarAndBottomBar;
  final ValueChanged<bool> onReadingModeChanged;

  @override
  ConsumerState<PdfPlayer> createState() => PdfPlayerState();
}

class PdfPlayerState extends ConsumerState<PdfPlayer> {
  final PdfViewerController controller = PdfViewerController();
  Timer? _saveDebounce;
  late final int _initialPageNumber;
  int _currentPageNumber = 1;
  int _pageCount = 0;
  int _annotationGeneration = 0;
  Map<int, List<_PdfRenderedAnnotation>> _renderedAnnotations = const {};
  late final PdfTextBlockPageLoader _textBlockLoader;
  PageController? _reflowPageController;
  bool _reflowMode = false;

  @override
  void initState() {
    super.initState();
    _initialPageNumber = decodePdfReadingPosition(
          widget.initialPosition ?? widget.book.lastReadPosition,
        ) ??
        1;
    _currentPageNumber = _initialPageNumber;
    _textBlockLoader = PdfTextBlockPageLoader(loadPageText: _loadPageText);
  }

  Future<void> nextPage() => _goToRelativePage(1);

  Future<void> prevPage() => _goToRelativePage(-1);

  Future<void> zoomIn() async {
    if (!controller.isReady) return;
    await controller.zoomUp();
  }

  Future<void> zoomOut() async {
    if (!controller.isReady) return;
    await controller.zoomDown();
  }

  Future<void> _goToRelativePage(int delta) async {
    if (_pageCount < 1) return;
    final next = (_currentPageNumber + delta).clamp(1, _pageCount);
    if (next == _currentPageNumber) return;
    if (_reflowMode) {
      await _reflowPageController?.animateToPage(
        next - 1,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
      return;
    }
    if (!controller.isReady) return;
    await controller.goToPage(pageNumber: next);
  }

  void toggleReadingMode() {
    if (_pageCount < 1) return;
    if (_reflowMode) {
      setState(() => _reflowMode = false);
      widget.onReadingModeChanged(false);
      unawaited(controller.goToPage(pageNumber: _currentPageNumber));
      return;
    }
    _reflowPageController?.dispose();
    _reflowPageController = PageController(initialPage: _currentPageNumber - 1);
    setState(() => _reflowMode = true);
    widget.onReadingModeChanged(true);
  }

  Future<PdfPageTextSource> _loadPageText(int pageNumber) async {
    final source = await controller.useDocument((pdf) async {
      if (pageNumber > pdf.pages.length) {
        throw RangeError.range(
          pageNumber,
          1,
          pdf.pages.length,
          'pageNumber',
        );
      }
      final pageText = await pdf.pages[pageNumber - 1].loadStructuredText();
      return PdfPageTextSource(
        pageNumber: pageNumber,
        fullText: pageText.fullText,
      );
    });
    if (source == null) {
      throw StateError('The PDF document is not ready');
    }
    return source;
  }

  Future<String> _translateBlock(
    PdfTextBlock block,
    String contextText,
  ) {
    final preferences = Prefs();
    return fullTextTranslationCoordinator.translate(
      text: block.text,
      contextText: contextText,
      book: widget.book,
      service: preferences.fullTextTranslateService,
      from: preferences.fullTextTranslateFrom,
      to: preferences.fullTextTranslateTo,
    );
  }

  void _onViewerReady(PdfDocument document, PdfViewerController value) {
    _pageCount = document.pages.length;
    _currentPageNumber = value.pageNumber ??
        _initialPageNumber.clamp(1, _pageCount < 1 ? 1 : _pageCount);
    _publishReadingState();
    unawaited(refreshAnnotations());
  }

  Future<void> _openSelectionEditor(
    PdfTextSelectionDelegate selection,
    VoidCallback dismissContextMenu,
  ) async {
    final ranges = await selection.getSelectedTextRanges();
    dismissContextMenu();
    if (!mounted) return;
    if (ranges.length != 1) {
      AnxToast.show('Select text on a single PDF page to annotate it.');
      return;
    }
    final range = ranges.single;
    final target = PdfAnnotationTarget.fromPageText(
      page: range.pageNumber,
      pageText: range.pageText.fullText,
      start: range.start,
      end: range.end,
    );
    final contextText = '${target.prefix}${target.exact}${target.suffix}';
    final session = SelectionPersistenceSession(
      SelectionSnapshot(
        selectedText: target.exact,
        annotationContext: contextText,
        lookupContext: contextText,
        chapter: 'Page ${target.page}',
        selector: encodePdfReadingPosition(target.page),
        pdfTarget: target,
      ),
    );
    final outcome = await showAnnotationEditor(
      context: context,
      book: widget.book,
      session: session,
    );
    if (outcome == AnnotationEditorOutcome.saved) {
      await selection.clearTextSelection();
      await refreshAnnotations();
    }
  }

  Widget? _buildContextMenu(
    BuildContext context,
    PdfViewerContextMenuBuilderParams params,
  ) {
    final items = <ContextMenuButtonItem>[
      if (params.textSelectionDelegate.isCopyAllowed &&
          params.textSelectionDelegate.hasSelectedText)
        ContextMenuButtonItem(
          onPressed: params.textSelectionDelegate.copyTextSelection,
          type: ContextMenuButtonType.copy,
        ),
      if (params.textSelectionDelegate.hasSelectedText)
        ContextMenuButtonItem(
          label: L10n.of(context).annotationEditorNewTitle,
          onPressed: () => unawaited(_openSelectionEditor(
            params.textSelectionDelegate,
            params.dismissContextMenu,
          )),
        ),
      if (params.isTextSelectionEnabled &&
          !params.textSelectionDelegate.isSelectingAllText)
        ContextMenuButtonItem(
          onPressed: params.textSelectionDelegate.selectAllText,
          type: ContextMenuButtonType.selectAll,
        ),
    ];
    if (items.isEmpty) return null;
    return Align(
      alignment: Alignment.topLeft,
      child: AdaptiveTextSelectionToolbar.buttonItems(
        anchors: TextSelectionToolbarAnchors(
          primaryAnchor: params.anchorA,
          secondaryAnchor: params.anchorB,
        ),
        buttonItems: items,
      ),
    );
  }

  Future<void> refreshAnnotations() async {
    if (!controller.isReady || widget.book.md5 == null) return;
    final generation = ++_annotationGeneration;
    final sharedState = annotationSyncRuntime.sharedState;
    final document = await sharedState.annotationDocument(widget.book.md5!);
    final presentations = await sharedState.annotationPresentations();
    final models = document == null
        ? const <AnnotationUiModel>[]
        : CanonicalAnnotationReadAdapter(
            presentations: presentations,
            localBookAvailable: (_) => true,
          ).read(document);
    final resolved = <int, List<_PdfRenderedAnnotation>>{};
    await controller.useDocument((pdf) async {
      for (final model in models) {
        final target = model.pdfTarget;
        if (target == null ||
            model.renderingCapability != AnnotationCapability.available ||
            target.page > pdf.pages.length) {
          continue;
        }
        final pageText = await pdf.pages[target.page - 1].loadStructuredText();
        final match = target.resolve(pageText.fullText);
        if (match == null) continue;
        final range = PdfPageTextRange(
          pageText: pageText,
          start: match.start,
          end: match.end,
        );
        (resolved[target.page] ??= []).add(
          _PdfRenderedAnnotation(model: model, range: range),
        );
      }
    });
    if (!mounted || generation != _annotationGeneration) return;
    _renderedAnnotations = resolved;
    controller.invalidate();
  }

  void _paintAnnotations(ui.Canvas canvas, Rect pageRect, PdfPage page) {
    for (final annotation
        in _renderedAnnotations[page.pageNumber] ?? const []) {
      final presentation = annotation.model.effectivePresentation(
        defaultStyle: Prefs().annotationType,
        defaultColor: Prefs().annotationColor,
      );
      final colorValue =
          int.tryParse(presentation.color, radix: 16) ?? 0x66ccff;
      final color = Color(0xff000000 | colorValue);
      for (final fragment
          in annotation.range.enumerateFragmentBoundingRects()) {
        final rect = fragment.bounds.toRectInDocument(
          page: page,
          pageRect: pageRect,
        );
        if (presentation.style == AnnotationPresentationStyle.underline) {
          canvas.drawLine(
            rect.bottomLeft,
            rect.bottomRight,
            Paint()
              ..color = color
              ..strokeWidth = 2,
          );
        } else {
          canvas.drawRect(rect, Paint()..color = color.withValues(alpha: 0.35));
        }
      }
    }
  }

  void _onPageChanged(int? pageNumber) {
    if (pageNumber == null || pageNumber == _currentPageNumber) return;
    _currentPageNumber = pageNumber;
    _publishReadingState();
    _saveDebounce?.cancel();
    _saveDebounce = Timer(
      const Duration(milliseconds: 500),
      () => unawaited(saveReadingProgress()),
    );
  }

  void _publishReadingState() {
    if (_pageCount < 1) return;
    final position = encodePdfReadingPosition(_currentPageNumber);
    final percentage = pdfReadingPercentage(_currentPageNumber, _pageCount);
    ref.read(currentReadingProvider.notifier).update(
          cfi: position,
          percentage: percentage,
          chapterCurrentPage: _currentPageNumber,
          chapterTotalPages: _pageCount,
        );
  }

  Future<void> saveReadingProgress() async {
    if (_pageCount < 1 || widget.initialPosition != null) return;
    final position = encodePdfReadingPosition(_currentPageNumber);
    final percentage = pdfReadingPercentage(_currentPageNumber, _pageCount);
    if (widget.book.lastReadPosition == position &&
        widget.book.readingPercentage == percentage) {
      return;
    }
    widget.book.lastReadPosition = position;
    widget.book.readingPercentage = percentage;
    await bookDao.updateBook(widget.book);
    await annotationSyncRuntime.recordReadingProgress(widget.book);
    if (mounted) {
      ref.read(bookListProvider.notifier).refresh();
    }
  }

  bool _onGeneralTap(
    BuildContext context,
    PdfViewerController value,
    PdfViewerGeneralTapHandlerDetails details,
  ) {
    if (details.type == PdfViewerGeneralTapType.tap &&
        details.tapOn != PdfViewerPart.selectedText) {
      widget.showOrHideAppBarAndBottomBar(true);
    }
    return false;
  }

  Widget _buildLoadingBanner(
    BuildContext context,
    int bytesDownloaded,
    int? totalBytes,
  ) {
    return Center(
      child: CircularProgressIndicator(
        value: totalBytes == null || totalBytes == 0
            ? null
            : bytesDownloaded / totalBytes,
      ),
    );
  }

  Widget _buildErrorBanner(
    BuildContext context,
    Object error,
    StackTrace? stackTrace,
    PdfDocumentRef documentRef,
  ) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              size: 40,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 12),
            Text(
              error.toString(),
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    _reflowPageController?.dispose();
    unawaited(saveReadingProgress());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Offstage(
          offstage: _reflowMode,
          child: PdfViewer.file(
            widget.book.fileFullPath,
            controller: controller,
            initialPageNumber: _initialPageNumber,
            useProgressiveLoading: true,
            params: PdfViewerParams(
              backgroundColor:
                  Theme.of(context).colorScheme.surfaceContainerHighest,
              panEnabled: true,
              scaleEnabled: true,
              onViewerReady: _onViewerReady,
              onPageChanged: _onPageChanged,
              onGeneralTap: _onGeneralTap,
              buildContextMenu: _buildContextMenu,
              pagePaintCallbacks: [_paintAnnotations],
              loadingBannerBuilder: _buildLoadingBanner,
              errorBannerBuilder: _buildErrorBanner,
            ),
          ),
        ),
        if (_reflowMode)
          Positioned.fill(
            child: ColoredBox(
              color: Theme.of(context).colorScheme.surface,
              child: PdfReflowView(
                pageCount: _pageCount,
                pageController: _reflowPageController!,
                blockLoader: _textBlockLoader,
                translateBlock: _translateBlock,
                onPageChanged: _onPageChanged,
                onTap: () => widget.showOrHideAppBarAndBottomBar(true),
              ),
            ),
          ),
      ],
    );
  }
}

class _PdfRenderedAnnotation {
  const _PdfRenderedAnnotation({required this.model, required this.range});

  final AnnotationUiModel model;
  final PdfPageTextRange range;
}
