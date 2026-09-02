import 'dart:io';

import 'package:anx_reader/page/book_player/reader_key_navigation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';

void main() {
  test('volume up uses the supplied format-aware previous-page path', () {
    var previousCalls = 0;
    var nextCalls = 0;

    final result = handleVolumePageKey(
      enabled: true,
      physicalKey: PhysicalKeyboardKey.audioVolumeUp,
      previousPage: () => previousCalls++,
      nextPage: () => nextCalls++,
    );

    expect(result, KeyEventResult.handled);
    expect(previousCalls, 1);
    expect(nextCalls, 0);
  });

  test('volume down uses the supplied format-aware next-page path', () {
    var previousCalls = 0;
    var nextCalls = 0;

    final result = handleVolumePageKey(
      enabled: true,
      physicalKey: PhysicalKeyboardKey.audioVolumeDown,
      previousPage: () => previousCalls++,
      nextPage: () => nextCalls++,
    );

    expect(result, KeyEventResult.handled);
    expect(previousCalls, 0);
    expect(nextCalls, 1);
  });

  test('the same callbacks preserve EPUB navigation behavior', () {
    final epubPages = <String>[];

    handleVolumePageKey(
      enabled: true,
      physicalKey: PhysicalKeyboardKey.audioVolumeUp,
      previousPage: () => epubPages.add('previous'),
      nextPage: () => epubPages.add('next'),
    );
    handleVolumePageKey(
      enabled: true,
      physicalKey: PhysicalKeyboardKey.audioVolumeDown,
      previousPage: () => epubPages.add('previous'),
      nextPage: () => epubPages.add('next'),
    );

    expect(epubPages, ['previous', 'next']);
  });

  test('disabled volume navigation leaves keys unhandled', () {
    var calls = 0;
    final result = handleVolumePageKey(
      enabled: false,
      physicalKey: PhysicalKeyboardKey.audioVolumeUp,
      previousPage: () => calls++,
      nextPage: () => calls++,
    );

    expect(result, KeyEventResult.ignored);
    expect(calls, 0);
  });

  test('ReadingPage supplies its PDF and EPUB aware navigation methods', () {
    final source = File('lib/page/reading_page.dart').readAsStringSync();

    expect(
      source,
      contains('previousPage: _previousPage'),
    );
    expect(source, contains('nextPage: _nextPage'));
    expect(
      source,
      contains('pdfPlayerKey.currentState?.prevPage()'),
    );
    expect(
      source,
      contains('epubPlayerKey.currentState?.prevPage()'),
    );
    expect(
      source,
      contains('pdfPlayerKey.currentState?.nextPage()'),
    );
    expect(
      source,
      contains('epubPlayerKey.currentState?.nextPage()'),
    );
  });
}
