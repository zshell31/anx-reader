import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/models/current_reading_state.dart';
import 'package:anx_reader/providers/current_reading.dart';
import 'package:anx_reader/widgets/reading_page/pdf_progress_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('PDF progress previews a page and navigates on slider release',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(currentReadingProvider.notifier).start(CurrentReadingState(
          book: Book.mock(),
          chapterCurrentPage: 1,
          chapterTotalPages: 20,
        ));
    final destinations = <int>[];
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        home: Scaffold(
          body: PdfProgressWidget(onGoToPage: (page) async {
            destinations.add(page);
            container
                .read(currentReadingProvider.notifier)
                .update(chapterCurrentPage: page);
          }),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('1 / 20'), findsOneWidget);
    expect(find.text('5.00'), findsOneWidget);
    expect(
        tester
            .widget<IconButton>(
                find.widgetWithIcon(IconButton, Icons.arrow_back))
            .onPressed,
        isNull);

    final slider = find.byType(Slider);
    final rect = tester.getRect(slider);
    final gesture =
        await tester.startGesture(Offset(rect.left + 24, rect.center.dy));
    await gesture.moveTo(Offset(rect.right - 24, rect.center.dy));
    await tester.pump();
    expect(destinations, isEmpty);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(destinations, [20]);
    expect(find.text('20 / 20'), findsOneWidget);
    expect(find.text('100.00'), findsOneWidget);
    expect(
        tester
            .widget<IconButton>(
                find.widgetWithIcon(IconButton, Icons.arrow_forward))
            .onPressed,
        isNull);

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    expect(destinations, [20, 19]);
    expect(find.text('19 / 20'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
