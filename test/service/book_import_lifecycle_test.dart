import 'dart:async';
import 'dart:io';

import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/main.dart';
import 'package:anx_reader/service/book.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('picker result opens import after the launching page is disposed',
      (tester) async {
    final picked = Completer<List<File>?>();
    final visible = ValueNotifier(true);
    addTearDown(visible.dispose);
    BuildContext? oldContext;
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        navigatorKey: navigatorKey,
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: visible,
            builder: (context, show, _) => show
                ? Builder(builder: (context) {
                    oldContext = context;
                    return TextButton(
                      onPressed: () =>
                          importBooksFromPicker(context, () => picked.future),
                      child: const Text('Pick'),
                    );
                  })
                : const Text('Rebuilt bookshelf'),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pick'));
    visible.value = false;
    await tester.pumpAndSettle();
    expect(oldContext!.mounted, isFalse);
    picked.complete([]);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Rebuilt bookshelf'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('cancelled picker does not show an import dialog',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
      navigatorKey: navigatorKey,
      home: Builder(
          builder: (context) => TextButton(
                onPressed: () =>
                    importBooksFromPicker(context, () async => null),
                child: const Text('Pick'),
              )),
    )));
    await tester.tap(find.text('Pick'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
