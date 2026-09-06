import 'dart:async';
import 'package:anx_reader/page/book_player/pdf_crop.dart';
import 'package:anx_reader/page/book_player/pdf_crop_viewport.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';

class _Document extends Fake implements PdfDocument {
  _Document({this.count = 1});
  final int count;
  PdfPage get page => pages.first;
  @override
  String get sourceName => 'selection-tap-test';
  @override
  late final List<PdfPage> pages = List.generate(count, (i) => _Page(this, i + 1));
  @override
  PdfPermissions? get permissions => null;
  @override
  bool get isEncrypted => false;
  @override
  Stream<PdfDocumentEvent> get events => const Stream.empty();
  @override
  Future<void> dispose() async {}
  @override
  Future<void> loadPagesProgressively<T>({
    PdfPageLoadingCallback<T>? onPageLoadProgress,
    T? data,
    Duration loadUnitDuration = const Duration(milliseconds: 250),
  }) async {}
}

class _Token extends Fake implements PdfPageRenderCancellationToken {
  @override
  bool get isCanceled => false;
  @override
  void cancel() {}
}

class _Page extends Fake implements PdfPage {
  _Page(this.document, this.pageNumber);
  @override
  final PdfDocument document;
  @override
  final int pageNumber;
  @override
  double get width => 400;
  @override
  double get height => 600;
  @override
  bool get isLoaded => true;
  @override
  PdfPageRotation get rotation => PdfPageRotation.none;
  @override
  PdfPageRenderCancellationToken createCancellationToken() => _Token();
  @override
  Future<PdfPageRawText> loadText() async => PdfPageRawText('hello', [
        for (var i = 0; i < 5; i++) PdfRect(50 + i * 12, 550, 60 + i * 12, 530),
      ]);
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #render) return Future<PdfImage?>.value();
    if (invocation.memberName == #loadLinks) return Future.value(<PdfLink>[]);
    return super.noSuchMethod(invocation);
  }
}

class _ProgressiveDocument extends _Document {
  final updates = StreamController<PdfDocumentEvent>.broadcast();
  @override
  Stream<PdfDocumentEvent> get events => updates.stream;
}

class _PlaceholderPage extends _Page {
  _PlaceholderPage(super.document, super.pageNumber);
  @override
  bool get isLoaded => false;
  @override
  Future<PdfPageRawText> loadText() async => PdfPageRawText('', []);
}

void main() {
  test('automatic crop waits for progressive page text before caching bounds', () async {
    final document = _ProgressiveDocument();
    final loaded = document.page;
    final placeholder = _PlaceholderPage(document, 1);
    document.pages[0] = placeholder;
    var completed = false;
    final pending = loadAutomaticPdfCrop(placeholder).then((crop) {
      completed = true;
      return crop;
    });
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    document.pages[0] = loaded;
    document.updates.add(PdfDocumentPageStatusChangedEvent(document,
      changes: {1: PdfPageStatusChange.modified(page: loaded)}));
    final crop = await pending;
    expect(crop.left, greaterThan(0));
    expect(crop.right, lessThan(1));
    await document.updates.close();
  });

  testWidgets('automatic crop loaded after viewer ready updates geometry', (tester) async {
    final controller = PdfViewerController();
    var crop = const Rect.fromLTWH(0, 0, 1, 1);
    await tester.pumpWidget(MaterialApp(home: PdfViewer(
      PdfDocumentRefDirect(_Document(count: 3)), controller: controller,
      params: PdfViewerParams(layoutPages: (pages, _) => layoutCroppedPdfPages(
        [for (final p in pages) Size(p.width, p.height)], (_) => crop)),
    )));
    await tester.pumpAndSettle();
    final before = controller.layout.pageLayouts.first;
    crop = const Rect.fromLTRB(.15, 0, .85, 1);
    controller.invalidate();
    await tester.pumpAndSettle();
    expect(controller.layout.pageLayouts.first.width, greaterThan(before.width));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('cropped pages turn both ways and keep hit coordinates and zoom', (tester) async {
    final document = _Document(count: 3);
    final controller = PdfViewerController();
    await tester.pumpWidget(MaterialApp(home: PdfViewer(PdfDocumentRefDirect(document), controller: controller,
      params: PdfViewerParams(
        layoutPages: (pages, _) => layoutCroppedPdfPages([for (final p in pages) Size(p.width, p.height)], (i) => i == 1 ? const Rect.fromLTRB(.05,.2,.95,.8) : const Rect.fromLTRB(.1,.1,.9,.9)),
        normalizeMatrix: (matrix, size, layout, value) {
          if (value == null || !value.isReady) return matrix;
          final crop = constrainPdfCropViewport(center: matrix.calcPosition(size), zoom: matrix.zoom, viewSize: size, crop: Offset.zero & layout.documentSize, documentHeight: layout.documentSize.height);
          return value.calcMatrixFor(crop.center, zoom: crop.zoom, viewSize: size);
        },
      ))));
    await tester.pumpAndSettle();
    final zoom = controller.currentZoom;
    for (final pageNumber in [2, 3, 2, 1]) {
      await controller.goToPage(pageNumber: pageNumber, duration: Duration.zero);
      await tester.pumpAndSettle();
      expect(controller.pageNumber, pageNumber);
      expect(controller.currentZoom, closeTo(zoom, .00001));
      final visible = controller.layout.visiblePageRects[pageNumber - 1];
      final hit = controller.getPdfPageHitTestResult(visible.topCenter + const Offset(0, 1), useDocumentLayoutCoordinates: true);
      expect(hit?.page.pageNumber, pageNumber);
      final frame = controller.value.calcVisibleRect(controller.viewSize);
      expect(frame.left, greaterThanOrEqualTo(-.00001));
      expect(frame.right, lessThanOrEqualTo(controller.layout.documentSize.width + .00001));
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  for (final cropped in [false, true]) {
    testWidgets('selection spans pages with different margins (crop: $cropped)', (tester) async {
      final document = _Document(count: 2);
      final controller = PdfViewerController();
      await tester.pumpWidget(MaterialApp(home: PdfViewer(
        PdfDocumentRefDirect(document), controller: controller,
        params: PdfViewerParams(layoutPages: cropped
          ? (pages, _) => layoutCroppedPdfPages(
              [for (final p in pages) Size(p.width, p.height)],
              (i) => i == 0 ? const Rect.fromLTRB(.1, 0, .9, 1)
                  : const Rect.fromLTRB(.05, 0, .95, 1)) : null),
      )));
      await tester.pumpAndSettle();
      final first = await document.pages[0].loadStructuredText();
      final second = await document.pages[1].loadStructuredText();
      await controller.textSelectionDelegate.setTextSelectionPointRange(
        PdfTextSelectionRange.fromPoints(
          PdfTextSelectionPoint(first, 2), PdfTextSelectionPoint(second, 2)));
      await tester.pumpAndSettle();
      final ranges = await controller.textSelectionDelegate.getSelectedTextRanges();
      expect(ranges.map((r) => r.pageText.pageNumber), [1, 2]);
      expect(ranges.map((r) => r.text), ['llo', 'hel']);
      expect(await controller.textSelectionDelegate.getSelectedText(), 'llohel');
      await controller.goToPage(pageNumber: 2, duration: Duration.zero);
      await tester.pumpAndSettle();
      expect(await controller.textSelectionDelegate.getSelectedText(), 'llohel');
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets(
        'tap preserves selection and shows actions; outside clears both (crop: $cropped)',
        (tester) async {
      final document = _Document();
      final controller = PdfViewerController();
      await tester.pumpWidget(MaterialApp(
        home: PdfViewer(
          PdfDocumentRefDirect(document),
          controller: controller,
          params: PdfViewerParams(
            layoutPages: cropped
                ? (pages, params) => layoutCroppedPdfPages(
                    [for (final page in pages) Size(page.width, page.height)],
                    (_) => const Rect.fromLTRB(.1, .04, .9, .9))
                : null,
            textSelectionParams: const PdfTextSelectionParams(
                showContextMenuAutomatically: false),
            buildContextMenu: (context, params) => const Align(
              alignment: Alignment.topLeft,
              child: Text('Selection actions', key: ValueKey('actions')),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(controller.isReady, isTrue);
      final text = await document.page.loadStructuredText();
      await controller.textSelectionDelegate.setTextSelectionPointRange(
        PdfTextSelectionRange.fromPoints(
          PdfTextSelectionPoint(text, 0),
          PdfTextSelectionPoint(text, 4),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('actions')), findsNothing);
      final viewerContext = tester.element(find.byType(PdfViewer));
      final docPoint = controller
          .calcRectForRectInsidePage(
            pageNumber: 1,
            rect: const PdfRect(50, 550, 110, 530),
          )
          .topCenter;
      final local = controller.textSelectionDelegate.doc2local
              .offsetToLocal(viewerContext, docPoint)! -
          const Offset(0, 9);
      await tester.tapAt(tester.getTopLeft(find.byType(PdfViewer)) + local);
      await tester.pumpAndSettle();
      expect(controller.textSelectionDelegate.hasSelectedText, isTrue);
      expect(find.byKey(const ValueKey('actions')), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tapAt(tester.getTopLeft(find.byType(PdfViewer)) + local);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(controller.textSelectionDelegate.hasSelectedText, isTrue);
      expect(find.byKey(const ValueKey('actions')), findsOneWidget);
      await tester.tapAt(tester.getCenter(find.byType(PdfViewer)));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(controller.textSelectionDelegate.hasSelectedText, isFalse);
      expect(find.byKey(const ValueKey('actions')), findsNothing);
      // Saved annotations restore their range and explicitly request the same UI.
      await controller.textSelectionDelegate.setTextSelectionPointRange(
        PdfTextSelectionRange.fromPoints(
          PdfTextSelectionPoint(text, 0),
          PdfTextSelectionPoint(text, 4),
        ),
      );
      controller.showSelectionMenu(docPoint);
      await tester.pumpAndSettle();
      expect(controller.textSelectionDelegate.hasSelectedText, isTrue);
      expect(find.byKey(const ValueKey('actions')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
  }
}
