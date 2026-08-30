import 'package:anx_reader/service/sync/annotation_catalog.dart';
import 'package:anx_reader/service/sync/annotation_read_model.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'search_note_group.freezed.dart';

@freezed
abstract class SearchNoteGroup with _$SearchNoteGroup {
  const factory SearchNoteGroup({
    required AnnotationBookUiModel book,
    required List<AnnotationUiModel> notes,
  }) = _SearchNoteGroup;
}
