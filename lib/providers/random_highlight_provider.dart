import 'dart:math';

import 'package:anx_reader/service/sync/annotation_catalog.dart';
import 'package:anx_reader/service/sync/annotation_read_model.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'random_highlight_provider.g.dart';

class RandomHighlightData {
  const RandomHighlightData({
    required this.note,
    required this.book,
  });

  final AnnotationUiModel note;
  final AnnotationBookUiModel book;
}

@riverpod
class RandomHighlight extends _$RandomHighlight {
  @override
  Future<RandomHighlightData?> build() async {
    return _load();
  }

  Future<RandomHighlightData?> _load() async {
    final books = await canonicalAnnotationCatalog.readAll();
    final candidates = [
      for (final book in books)
        for (final note in book.annotations)
          if (note.motivation == AnnotationMotivation.selection)
            RandomHighlightData(note: note, book: book),
    ];
    if (candidates.isEmpty) return null;
    return candidates[Random().nextInt(candidates.length)];
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = AsyncValue.data(await _load());
  }
}
