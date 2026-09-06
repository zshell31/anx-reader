import 'dart:typed_data';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/page/book_player/pdf_crop_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';

class _Page extends Fake implements PdfPage {
  @override
  double get width => 100;
  @override
  double get height => 200;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #render)
      return Future<PdfImage?>.value(PdfImage.createFromBgraData(
          Uint8List(100 * 200 * 4),
          width: 100,
          height: 200));
    return super.noSuchMethod(invocation);
  }
}

void main() {
  for (final apply in [true, false]) {
    testWidgets('manual crop ${apply ? 'applies' : 'cancels'} a moved frame',
        (tester) async {
      Rect? result;
      const initial = Rect.fromLTRB(.1, .1, .9, .9);
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        locale: const Locale('en'),
        home: Builder(
            builder: (context) => TextButton(
                onPressed: () async {
                  result = await Navigator.of(context).push<Rect>(
                      MaterialPageRoute(
                          builder: (_) => PdfCropEditor(
                              page: _Page(), initialCrop: initial)));
                },
                child: const Text('Open'))),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open'));
      await tester.pump();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      await tester.drag(
          find.byKey(const ValueKey('crop-move')), const Offset(10, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.text(apply ? 'Apply' : 'Cancel'));
      await tester.pumpAndSettle();
      if (apply) {
        expect(result, isNotNull);
        expect(result!.left, greaterThan(initial.left));
      } else {
        expect(result, isNull);
      }
    });
  }
}
