import 'package:anx_reader/constants/note_annotations.dart';
import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/service/sync/annotation_read_model.dart';
import 'package:anx_reader/utils/time_to_human.dart';
import 'package:anx_reader/widgets/common/container/filled_container.dart';
import 'package:flutter/material.dart';

class BookNoteTile extends StatelessWidget {
  const BookNoteTile({
    super.key,
    required this.note,
    this.onTap,
    this.onLongPress,
    this.trailing,
    this.backgroundColor,
    this.margin = const EdgeInsets.only(bottom: 8),
  });

  final AnnotationUiModel note;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Widget? trailing;
  final Color? backgroundColor;
  final EdgeInsetsGeometry margin;

  Icon _buildIcon(Color color, AnnotationPresentation presentation) {
    if (note.motivation == AnnotationMotivation.bookmark) {
      return Icon(Icons.bookmark, color: color);
    }
    final style = presentation.style.name;
    final match = notesType.where((option) => option.type == style);
    if (match.isNotEmpty) {
      return Icon(match.first.icon, color: color);
    }
    return Icon(Icons.bookmark, color: color);
  }

  @override
  Widget build(BuildContext context) {
    final prefs = Prefs();
    final presentation = note.effectivePresentation(
      defaultStyle: prefs.annotationType,
      defaultColor: prefs.annotationColor,
    );
    final iconColor = Color(
      int.tryParse(
            '0xaa${note.motivation == AnnotationMotivation.bookmark ? '555555' : presentation.color}',
          ) ??
          0xaa555555,
    );
    final infoStyle = const TextStyle(
      fontSize: 14,
      color: Colors.grey,
    );

    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      onSecondaryTap: onLongPress,
      behavior: HitTestBehavior.opaque,
      child: FilledContainer(
        color: backgroundColor,
        padding: const EdgeInsets.all(8.0),
        margin: margin,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 10, right: 10, top: 10),
              child: _buildIcon(iconColor, presentation),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    note.selectedText,
                    style: const TextStyle(
                      fontSize: 16,
                    ),
                  ),
                  if (note.effectivePersonalNote?.content?.isNotEmpty == true)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(height: 4),
                        IntrinsicHeight(
                          child: Row(
                            children: [
                              const VerticalDivider(
                                thickness: 3,
                              ),
                              Expanded(
                                child: Text(
                                  note.effectivePersonalNote!.content!,
                                  style: infoStyle.copyWith(
                                    color: Colors.grey.shade600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 4),
                      ],
                    ),
                  Divider(
                    indent: 4,
                    height: 3,
                    color: Colors.grey.shade300,
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          note.chapter ?? '',
                          style: infoStyle,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        timeToHuman(note.createdAt),
                        style: infoStyle,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}
