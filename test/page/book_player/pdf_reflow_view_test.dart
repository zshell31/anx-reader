import 'package:anx_reader/page/book_player/pdf_reflow_view.dart';
import 'package:anx_reader/page/book_player/pdf_text_blocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('loads the anchored page and translates only built blocks',
      (tester) async {
    final loadedPages = <int>[];
    final translatedBlocks = <String>[];
    final pageChanges = <int>[];
    var taps = 0;
    final loader = PdfTextBlockPageLoader(loadPageText: (page) async {
      loadedPages.add(page);
      return PdfPageTextSource(
        pageNumber: page,
        fullText: List.generate(
          30,
          (index) => 'Page $page paragraph $index.',
        ).join('\n\n'),
      );
    });
    final controller = PageController(initialPage: 1);
    addTearDown(controller.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PdfReflowView(
          pageCount: 3,
          pageController: controller,
          blockLoader: loader,
          translateBlock: (block, context) async {
            translatedBlocks.add(block.text);
            expect(context, contains('Page ${block.pageNumber} paragraph 0.'));
            return 'Translation: ${block.text}';
          },
          onPageChanged: pageChanges.add,
          onTap: () => taps++,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Page 2'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(taps, 1);
    await tester.tap(find.text('Page 2 paragraph 0.'));
    await tester.pumpAndSettle();
    expect(taps, 2);
    await tester.longPress(find.text('Page 2 paragraph 0.'));
    await tester.pumpAndSettle();
    expect(taps, 2, reason: 'selecting text must not toggle the menu');
    final selection =
        tester.state<SelectableRegionState>(find.byType(SelectableRegion));
    expect(
        selection.contextMenuButtonItems,
        contains(isA<ContextMenuButtonItem>()
            .having((item) => item.type, 'type', ContextMenuButtonType.copy)));
    selection.clearSelection();
    expect(loadedPages, [2]);
    expect(find.text('Page 2'), findsOneWidget);
    expect(find.text('Translation: Page 2 paragraph 0.'), findsOneWidget);
    expect(translatedBlocks, isNotEmpty);
    expect(translatedBlocks.length, lessThan(30),
        reason: 'off-screen blocks must remain untranslated');

    controller.jumpToPage(0);
    await tester.pumpAndSettle();

    expect(pageChanges, contains(1));
    expect(loadedPages, [2, 1]);
    expect(find.text('Page 1'), findsOneWidget);
  });
}
