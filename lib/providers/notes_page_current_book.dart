import 'package:anx_reader/models/current_notes_detail.dart';
import 'package:anx_reader/service/sync/annotation_catalog.dart';
import 'package:anx_reader/providers/notes_statistics.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'notes_page_current_book.g.dart';

@riverpod
class NotesPageCurrentBook extends _$NotesPageCurrentBook {
  @override
  Future<CurrentNotesDetail> build() async {
    final idAndNotes = await ref.watch(bookIdAndNotesProvider.future);

    if (idAndNotes.isEmpty) {
      throw StateError('No canonical annotations');
    }
    return CurrentNotesDetail(book: idAndNotes.first.book);
  }

  void setData(AnnotationBookUiModel book) {
    state = AsyncValue.data(CurrentNotesDetail(book: book));
  }
}
