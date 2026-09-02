import 'dart:async';

import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/page/book_player/pdf_reading_position.dart';
import 'package:anx_reader/providers/book_list.dart';
import 'package:anx_reader/providers/current_reading.dart';
import 'package:anx_reader/service/sync/annotation_sync_runtime.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';

class PdfPlayer extends ConsumerStatefulWidget {
  const PdfPlayer({
    super.key,
    required this.book,
    this.initialPosition,
    required this.showOrHideAppBarAndBottomBar,
  });

  final Book book;
  final String? initialPosition;
  final void Function(bool show) showOrHideAppBarAndBottomBar;

  @override
  ConsumerState<PdfPlayer> createState() => PdfPlayerState();
}

class PdfPlayerState extends ConsumerState<PdfPlayer> {
  final PdfViewerController controller = PdfViewerController();
  Timer? _saveDebounce;
  late final int _initialPageNumber;
  int _currentPageNumber = 1;
  int _pageCount = 0;

  @override
  void initState() {
    super.initState();
    _initialPageNumber = decodePdfReadingPosition(
          widget.initialPosition ?? widget.book.lastReadPosition,
        ) ??
        1;
    _currentPageNumber = _initialPageNumber;
  }

  Future<void> nextPage() => _goToRelativePage(1);

  Future<void> prevPage() => _goToRelativePage(-1);

  Future<void> _goToRelativePage(int delta) async {
    if (!controller.isReady || _pageCount < 1) return;
    final next = (_currentPageNumber + delta).clamp(1, _pageCount);
    if (next == _currentPageNumber) return;
    await controller.goToPage(pageNumber: next);
  }

  void _onViewerReady(PdfDocument document, PdfViewerController value) {
    _pageCount = document.pages.length;
    _currentPageNumber = value.pageNumber ??
        _initialPageNumber.clamp(1, _pageCount < 1 ? 1 : _pageCount);
    _publishReadingState();
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
    unawaited(saveReadingProgress());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PdfViewer.file(
      widget.book.fileFullPath,
      controller: controller,
      initialPageNumber: _initialPageNumber,
      useProgressiveLoading: true,
      params: PdfViewerParams(
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
        onViewerReady: _onViewerReady,
        onPageChanged: _onPageChanged,
        onGeneralTap: _onGeneralTap,
        loadingBannerBuilder: _buildLoadingBanner,
        errorBannerBuilder: _buildErrorBanner,
      ),
    );
  }
}
