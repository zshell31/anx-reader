import 'package:anx_reader/service/sync/annotation_catalog.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'current_notes_detail.freezed.dart';

@freezed
abstract class CurrentNotesDetail with _$CurrentNotesDetail {
  const factory CurrentNotesDetail({
    required AnnotationBookUiModel book,
  }) = _CurrentNotesDetail;
}
