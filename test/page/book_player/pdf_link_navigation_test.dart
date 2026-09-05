import 'dart:ui' show PointerDeviceKind;

import 'package:anx_reader/page/book_player/pdf_link_navigation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';

class _Document extends Fake implements PdfDocument {
  late final List<PdfPage> _pages = [_Page(this, 1), _Page(this, 2)];
  @override
  String get sourceName => 'internal-link-test';
  @override
  List<PdfPage> get pages => _pages;
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
    if (invocation.memberName == #loadLinks) {
      return Future.value(pageNumber == 1
          ? [
              const PdfLink([PdfRect(10, 550, 110, 530)],
                  dest: PdfDest(2, PdfDestCommand.fit, null))
            ]
          : <PdfLink>[]);
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  testWidgets('internal link navigates before ordinary page tap handling',
      (tester) async {
    final controller = PdfViewerController();
    var ordinaryTaps = 0;
    await tester.pumpWidget(MaterialApp(
      home: PdfViewer(
        PdfDocumentRefDirect(_Document()),
        controller: controller,
        params: PdfViewerParams(
          linkHandlerParams: pdfInternalLinkHandler(controller),
          onGeneralTap: (_, __, ___) {
            ordinaryTaps++;
            return true;
          },
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(controller.pageNumber, 1);
    final viewer = find.byType(PdfViewer);
    final context = tester.element(viewer);
    final documentPoint = controller
        .calcRectForRectInsidePage(
          pageNumber: 1,
          rect: const PdfRect(10, 550, 110, 530),
        )
        .center;
    final local = controller.textSelectionDelegate.doc2local
        .offsetToLocal(context, documentPoint)!;
    final tapPosition = tester.getTopLeft(viewer) + local;
    // The fake page has no bitmap to paint. Hover loads its links through the
    // viewer's hit testing, as painting a real page normally does.
    final mouse =
        await tester.createGesture(kind: PointerDeviceKind.mouse, pointer: 7);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tapPosition);
    await tester.pumpAndSettle();
    await tester.tapAt(tapPosition);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(controller.pageNumber, 2);
    expect(ordinaryTaps, 0);
    expect(tester.takeException(), isNull);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
