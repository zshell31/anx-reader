import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';

class _Document extends Fake implements PdfDocument {
  late final PdfPage page = _Page(this);
  @override
  String get sourceName => 'selection-tap-test';
  @override
  List<PdfPage> get pages => [page];
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
  _Page(this.document);
  @override
  final PdfDocument document;
  @override
  int get pageNumber => 1;
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

void main() {
  testWidgets('tap preserves selection and shows actions; outside clears both',
      (tester) async {
    final document = _Document();
    final controller = PdfViewerController();
    await tester.pumpWidget(MaterialApp(
      home: PdfViewer(
        PdfDocumentRefDirect(document),
        controller: controller,
        params: PdfViewerParams(
          textSelectionParams:
              const PdfTextSelectionParams(showContextMenuAutomatically: false),
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
        .center;
    final local = controller.textSelectionDelegate.doc2local
        .offsetToLocal(viewerContext, docPoint)!;
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
