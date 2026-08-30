import 'package:anx_reader/service/sync/annotation_read_model.dart';

/// Ephemeral Foliate payload. It is renderer data, not a persistence model.
class FoliateAnnotationDto {
  final String id;
  final String value;
  final String type;
  final String color;
  final String note;

  const FoliateAnnotationDto({
    required this.id,
    required this.value,
    required this.type,
    required this.color,
    required this.note,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'renderKey': id,
        'value': value,
        'type': type,
        'color': color.startsWith('#') ? color : '#$color',
        'note': note.replaceAll('\n', ' '),
      };
}

class FoliateAnnotationAdapter {
  final AnnotationPresentationStyle defaultStyle;
  final String defaultColor;

  const FoliateAnnotationAdapter({
    required this.defaultStyle,
    required this.defaultColor,
  });

  List<FoliateAnnotationDto> adapt(Iterable<AnnotationUiModel> annotations) =>
      List.unmodifiable([
        for (final annotation in annotations)
          if (!annotation.isTombstoned &&
              annotation.renderingCapability ==
                  AnnotationCapability.available &&
              annotation.epubCfi != null)
            _adaptOne(annotation),
      ]);

  FoliateAnnotationDto _adaptOne(AnnotationUiModel annotation) {
    if (annotation.motivation == AnnotationMotivation.bookmark) {
      return FoliateAnnotationDto(
        id: annotation.ref.annotationId,
        value: annotation.epubCfi!,
        type: 'bookmark',
        color: '#000000',
        note: annotation.selectedText,
      );
    }
    final presentation = annotation.effectivePresentation(
      defaultStyle: defaultStyle.name,
      defaultColor: defaultColor,
    );
    return FoliateAnnotationDto(
      id: annotation.ref.annotationId,
      value: annotation.epubCfi!,
      type: presentation.style.name,
      color: presentation.color,
      note: annotation.selectedText,
    );
  }
}
