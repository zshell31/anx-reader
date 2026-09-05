import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/page/book_player/annotation_editor/annotation_editor.dart';
import 'package:anx_reader/page/book_player/pdf_annotation_interaction.dart';
import 'package:anx_reader/page/book_player/pdf_edge_tap.dart';
import 'package:anx_reader/page/book_player/pdf_outline.dart';
import 'package:anx_reader/page/book_player/pdf_reading_position.dart';
import 'package:anx_reader/page/book_player/pdf_reflow_view.dart';
import 'package:anx_reader/page/book_player/pdf_selection_action_menu.dart';
import 'package:anx_reader/page/book_player/pdf_selection_handle.dart';
import 'package:anx_reader/page/book_player/pdf_text_blocks.dart';
import 'package:anx_reader/page/book_player/pdf_viewport.dart';
import 'package:anx_reader/page/book_player/pdf_word_selection.dart';
import 'package:anx_reader/page/book_player/selection_persistence_session.dart';
import 'package:anx_reader/providers/book_list.dart';
import 'package:anx_reader/providers/book_toc.dart';
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
  late final double? _initialPageOffsetRatio;
  int _currentPageNumber = 1;
  int _pageCount = 0;
  int _annotationGeneration = 0;
  Map<int, List<_PdfRenderedAnnotation>> _renderedAnnotations = const {};
  late final PdfTextBlockPageLoader _textBlockLoader;
  PageController? _reflowPageController;
  bool _reflowMode = false;
  bool _annotationEditorOpen = false;
  Map<String, PdfDest> _outlineDestinations = const {};
  int _viewportGeneration = 0;
  int _wordSelectionGeneration = 0;

  @override
  void initState() {
    super.initState();
    _initialPageNumber = decodePdfReadingPosition(
          widget.initialPosition ?? widget.book.lastReadPosition,
        ) ??
        1;
    _initialPageOffsetRatio = decodePdfReadingOffset(
      widget.initialPosition ?? widget.book.lastReadPosition,
    );
    _currentPageNumber = _initialPageNumber;
    _textBlockLoader = PdfTextBlockPageLoader(loadPageText: _loadPageText);
    ref.read(bookTocProvider.notifier).setToc(const []);
  }

  Future<void> nextPage() => _goToRelativePage(1);

  Future<void> prevPage() => _goToRelativePage(-1);

  PdfDest? outlineDestination(String href) => _outlineDestinations[href];

  int get currentPageNumber => _currentPageNumber;
  int get pageCount => _pageCount;

  String get currentOutlineHref {
    String current = '';
    var currentPage = 0;
    for (final entry in _outlineDestinations.entries) {
      final page = entry.value.pageNumber;
      if (page <= _currentPageNumber && page >= currentPage) {
        current = entry.key;
        currentPage = page;
      }
    }
    return current;
  }

  Future<void> goToOutline(String href) async {
    final destination = _outlineDestinations[href];
    if (destination == null) return;
    if (_reflowMode) {
      await _reflowPageController?.animateToPage(
        destination.pageNumber - 1,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
      return;
    }
    if (controller.isReady) {
      await controller.goToDest(destination);
    }
  }

  Future<void> goToAnnotation(PdfAnnotationTarget target) async {
    if (_reflowMode) {
      await _reflowPageController?.animateToPage(
        target.page - 1,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
      return;
    }
    await _goToPageOffset(target.page, target.pageOffsetRatio);
  }

  Future<void> _goToPageOffset(int pageNumber, double? offsetRatio) async {
    if (!controller.isReady || pageNumber < 1 || pageNumber > _pageCount) {
      return;
    }
    if (offsetRatio == null) {
      await controller.goToPage(pageNumber: pageNumber);
      return;
    }
    final pageRect = controller.layout.pageLayouts[pageNumber - 1];
    final anchorY = math.min(120.0, controller.viewSize.height / 3);
    final focusY = pageRect.top +
        pageRect.height * offsetRatio.clamp(0, 1) +
        (controller.viewSize.height / 2 - anchorY) / controller.currentZoom;
    controller.value = controller.calcMatrixFor(
      Offset(pageRect.center.dx, focusY),
    );
  }

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

  Future<Size?> _loadPageSize(int pageNumber) async =>
      await controller.useDocument<Size?>((pdf) {
        if (pageNumber < 1 || pageNumber > pdf.pages.length) return null;
        final page = pdf.pages[pageNumber - 1];
        return Size(page.width, page.height);
      });

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
    unawaited(_loadOutline(document));
    if (_initialPageOffsetRatio != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_goToPageOffset(
          _initialPageNumber.clamp(1, _pageCount),
          _initialPageOffsetRatio,
        ));
      });
    }
  }

  void _onViewSizeChanged(
    Size viewSize,
    Size? oldViewSize,
    PdfViewerController value,
  ) {
    if (_pageCount < 1 || !shouldRefitPdfViewport(viewSize, oldViewSize)) {
      return;
    }
    final generation = ++_viewportGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _viewportGeneration || !value.isReady) {
        return;
      }
      final page = _currentPageNumber.clamp(1, _pageCount);
      final matrix = value.calcMatrixFitWidthForPage(pageNumber: page);
      if (matrix != null) value.value = matrix;
    });
  }

  Future<void> _loadOutline(PdfDocument document) async {
    final outline = await document.loadOutline();
    if (!mounted) return;
    final toc = buildPdfOutlineToc(outline, document.pages.length);
    _outlineDestinations = toc.destinations;
    ref.read(bookTocProvider.notifier).setToc(toc.items);
  }

  Widget? _buildContextMenu(
    BuildContext context,
    PdfViewerContextMenuBuilderParams params,
  ) {
    if (!params.textSelectionDelegate.isCopyAllowed ||
        !params.textSelectionDelegate.hasSelectedText) {
      return null;
    }
    return PdfSelectionActionMenu(
      book: widget.book,
      selection: params.textSelectionDelegate,
      primaryAnchor: params.anchorA,
      secondaryAnchor: params.anchorB,
      dismissContextMenu: params.dismissContextMenu,
      refreshAnnotations: refreshAnnotations,
      loadPageSize: _loadPageSize,
      resolvePageOffset: _resolvePageOffset,
    );
  }

  double? _resolvePageOffset(PdfPageTextRange range) {
    if (!controller.isReady ||
        range.pageNumber < 1 ||
        range.pageNumber > controller.layout.pageLayouts.length) {
      return null;
    }
    final pageRect = controller.layout.pageLayouts[range.pageNumber - 1];
    if (pageRect.height <= 0) return null;
    final selectionRect = controller.calcRectForRectInsidePage(
      pageNumber: range.pageNumber,
      rect: range.bounds,
    );
    return ((selectionRect.top - pageRect.top) / pageRect.height).clamp(0, 1);
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
      final renderable = models.where((model) {
        final target = model.pdfTarget;
        return target != null &&
            model.renderingCapability == AnnotationCapability.available &&
            target.page <= pdf.pages.length;
      });
      final resolutions = await resolvePdfAnnotationsByPage(
        annotations: renderable,
        targetFor: (model) => model.pdfTarget,
        loadPageText: (pageNumber) =>
            pdf.pages[pageNumber - 1].loadStructuredText(),
        fullTextFor: (pageText) => pageText.fullText,
      );
      for (final resolution in resolutions) {
        final model = resolution.annotation;
        final range = PdfPageTextRange(
          pageText: resolution.pageText,
          start: resolution.match.start,
          end: resolution.match.end,
        );
        (resolved[resolution.target.page] ??= []).add(
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
    final interactionGeneration = ++_wordSelectionGeneration;
    if (details.type == PdfViewerGeneralTapType.tap &&
        details.tapOn != PdfViewerPart.selectedText &&
        value.textSelectionDelegate.hasSelectedText) {
      // Match EPUB: the first outside tap belongs to the active selection. It
      // only dismisses that selection and must not turn a page or show chrome.
      unawaited(value.textSelectionDelegate.clearTextSelection());
      return true;
    }
    if (details.type == PdfViewerGeneralTapType.tap) {
      final hit = hitTestPdfAnnotations(
        position: details.documentPosition,
        annotations: _renderedAnnotations.values.expand((value) => value),
        rectsFor: (annotation) sync* {
          for (final fragment
              in annotation.range.enumerateFragmentBoundingRects()) {
            yield controller
                .calcRectForRectInsidePage(
                  pageNumber: annotation.range.pageNumber,
                  rect: fragment.bounds,
                )
                .inflate(2);
          }
        },
      );
      if (hit.kind == PdfAnnotationHitKind.unique) {
        unawaited(_openRenderedAnnotationEditor(hit.annotation!));
        return true;
      }
      if (hit.kind == PdfAnnotationHitKind.ambiguous) return true;
    }
    if (details.type == PdfViewerGeneralTapType.longPress &&
        details.tapOn == PdfViewerPart.nonSelectedText) {
      unawaited(_selectTouchedPdfWord(
        details.documentPosition,
        interactionGeneration,
      ));
      return true;
    }
    if (details.type != PdfViewerGeneralTapType.tap ||
        details.tapOn == PdfViewerPart.selectedText) {
      return false;
    }
    final edgeAction = pdfEdgeTapAction(
      x: details.localPosition.dx,
      viewWidth: controller.viewSize.width,
    );
    switch (edgeAction) {
      case PdfEdgeTapAction.previousPage:
        unawaited(prevPage());
        return true;
      case PdfEdgeTapAction.nextPage:
        unawaited(nextPage());
        return true;
      case null:
        widget.showOrHideAppBarAndBottomBar(true);
        return false;
    }
  }

  Future<void> _selectTouchedPdfWord(
    Offset documentPosition,
    int interactionGeneration,
  ) async {
    if (!controller.isReady) return;
    final range =
        await controller.useDocument<PdfTextSelectionRange?>((pdf) async {
      final layouts = controller.layout.pageLayouts;
      for (var index = 0; index < layouts.length; index++) {
        final pageRect = layouts[index];
        if (!pageRect.contains(documentPosition)) continue;
        final page = pdf.pages[index];
        final pageText = await page.loadStructuredText();
        final point = documentPosition
            .translate(-pageRect.left, -pageRect.top)
            .toPdfPoint(page: page, scaledPageSize: pageRect.size);
        final characterIndex = findPdfCharacterIndex(pageText, point);
        if (characterIndex == null) return null;
        final word = pdfWordRangeAt(pageText.fullText, characterIndex);
        if (word == null) return null;
        return PdfTextSelectionRange.fromPoints(
          PdfTextSelectionPoint(pageText, word.start),
          PdfTextSelectionPoint(pageText, word.end - 1),
        );
      }
      return null;
    });
    if (!mounted ||
        interactionGeneration != _wordSelectionGeneration ||
        range == null) {
      return;
    }

    // Let pdfrx establish its normal touch handles/menu state, then replace its
    // paragraph-sized fragment with the actual word range.
    await controller.textSelectionDelegate.selectWord(documentPosition);
    if (!mounted || interactionGeneration != _wordSelectionGeneration) return;
    await controller.textSelectionDelegate.setTextSelectionPointRange(range);
  }

  Future<void> _openRenderedAnnotationEditor(
    _PdfRenderedAnnotation annotation,
  ) async {
    if (_annotationEditorOpen || !mounted) return;
    _annotationEditorOpen = true;
    final model = annotation.model;
    final target = model.pdfTarget!;
    final contextText = model.annotationContext ??
        '${target.prefix}${target.exact}${target.suffix}';
    final session = SelectionPersistenceSession(
      SelectionSnapshot(
        selectedText:
            model.selectedText.isEmpty ? target.exact : model.selectedText,
        annotationContext: contextText,
        lookupContext: contextText,
        chapter: model.chapter ?? 'Page ${target.page}',
        selector: encodePdfReadingPosition(target.page),
        pdfTarget: target,
      ),
      existingAnnotation: SelectionAnnotationHandle(ref: model.ref),
    );
    try {
      final outcome = await showAnnotationEditor(
        context: context,
        book: widget.book,
        session: session,
      );
      if (outcome == AnnotationEditorOutcome.saved ||
          outcome == AnnotationEditorOutcome.deleted) {
        await refreshAnnotations();
      }
    } catch (error) {
      if (mounted) AnxToast.show(error.toString());
    } finally {
      _annotationEditorOpen = false;
    }
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
              onViewSizeChanged: _onViewSizeChanged,
              onPageChanged: _onPageChanged,
              onGeneralTap: _onGeneralTap,
              buildContextMenu: _buildContextMenu,
              textSelectionParams: const PdfTextSelectionParams(
                buildSelectionHandle: buildPdfSelectionHandle,
              ),
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
