import 'package:anx_reader/constants/note_annotations.dart';
import 'package:anx_reader/service/sync/annotation_catalog.dart';
import 'package:anx_reader/service/sync/annotation_read_model.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'book_notes_state.freezed.dart';

enum NotesSortField { createdTime, cfi }

enum SortDirection { asc, desc }

@freezed
abstract class NotesSortMode with _$NotesSortMode {
  const factory NotesSortMode({
    required NotesSortField field,
    required SortDirection direction,
  }) = _NotesSortMode;

  const NotesSortMode._();

  NotesSortMode toggleDirection() {
    return copyWith(
      direction: direction == SortDirection.asc
          ? SortDirection.desc
          : SortDirection.asc,
    );
  }

  NotesSortMode changeField(NotesSortField newField) {
    if (field == newField) {
      return toggleDirection();
    }
    return copyWith(field: newField);
  }
}

@freezed
abstract class BookNotesState with _$BookNotesState {
  const BookNotesState._();

  const factory BookNotesState({
    required AnnotationBookUiModel book,
    required List<AnnotationUiModel> allAnnotations,
    required List<AnnotationUiModel> visibleAnnotations,
    required NotesSortMode viewSortMode,
    required NotesSortMode exportSortMode,
    required bool showBookmarks,
    required Set<String> enabledTypeColors,
    required Set<String> selectedAnnotationIds,
  }) = _BookNotesState;

  int get totalNotes => allAnnotations.length;

  bool get isSelecting => selectedAnnotationIds.isNotEmpty;

  List<AnnotationUiModel> get selectedAnnotations => allAnnotations
      .where((annotation) =>
          selectedAnnotationIds.contains(annotation.ref.annotationId))
      .toList();

  bool get showAllNotes => visibleAnnotations.length == allAnnotations.length;
}

extension NoteFilterDefaults on BookNotesState {
  static Set<String> initialTypeColorSelection() {
    final Set<String> values = {};
    for (final type in notesType) {
      for (final color in notesColors) {
        values.add('${type.type}#$color');
      }
    }
    return values;
  }
}
