import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:anx_reader/service/sync/annotation_read_model.dart';

part 'bookmark.freezed.dart';

@freezed
abstract class BookmarkModel with _$BookmarkModel {
  const factory BookmarkModel({
    AnnotationRef? ref,
    required int bookId,
    required String content,
    required String cfi,
    required String chapter,
    double? percentage,
    DateTime? createTime,
    required DateTime updateTime,
  }) = _BookmarkModel;
}
