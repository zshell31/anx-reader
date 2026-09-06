import 'package:anx_reader/page/book_player/epub_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final buildBeforeRemoval in [false, true]) {
    testWidgets('removes selection overlay with mounted=$buildBeforeRemoval',
        (tester) async {
      final overlayKey = GlobalKey<OverlayState>();
      await tester.pumpWidget(MaterialApp(home: Overlay(key: overlayKey)));
      final player = EpubPlayerState();
      final entry = OverlayEntry(
        builder: (_) => const Center(child: Text('Selection actions')),
      );
      player.contextMenuEntry = entry;
      player.contextMenuSelectionSessionGeneration = 10;
      overlayKey.currentState!.insert(entry);
      if (buildBeforeRemoval) await tester.pump();
      expect(entry.mounted, buildBeforeRemoval);

      player.removeOverlay(selectionSessionGeneration: 10);
      player.removeOverlay(selectionSessionGeneration: 10);
      await tester.pump();

      expect(find.text('Selection actions'), findsNothing);
      expect(player.contextMenuEntry, isNull);
      expect(player.contextMenuSelectionSessionGeneration, isNull);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('stale removal preserves the replacement overlay',
      (tester) async {
    final overlayKey = GlobalKey<OverlayState>();
    await tester.pumpWidget(MaterialApp(home: Overlay(key: overlayKey)));
    final player = EpubPlayerState();
    final entry = OverlayEntry(
      builder: (_) => const Center(child: Text('New selection actions')),
    );
    player.contextMenuEntry = entry;
    player.contextMenuSelectionSessionGeneration = 11;
    overlayKey.currentState!.insert(entry);

    player.removeOverlay(selectionSessionGeneration: 10);
    await tester.pump();
    expect(find.text('New selection actions'), findsOneWidget);
    expect(player.contextMenuEntry, same(entry));

    player.removeOverlay(selectionSessionGeneration: 11);
    await tester.pump();
    expect(find.text('New selection actions'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
