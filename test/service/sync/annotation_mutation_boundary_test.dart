import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('production semantic mutation call sites do not bypass repository', () {
    const semanticCallSites = [
      'lib/widgets/context_menu/context_menu.dart',
      'lib/widgets/context_menu/excerpt_menu.dart',
      'lib/widgets/context_menu/reader_note_menu.dart',
      'lib/providers/book_notes.dart',
      'lib/providers/bookmark.dart',
    ];
    final forbidden = RegExp(
      r'''bookNoteDao\.(save|updateBookNoteById|deleteBookNoteById)|\.(insert|update|delete)\(\s*['"]tb_notes['"]''',
    );

    for (final path in semanticCallSites) {
      final source = File(path).readAsStringSync();
      expect(forbidden.hasMatch(source), isFalse, reason: path);
      expect(source, contains('annotationRepository'), reason: path);
    }
  });
}
