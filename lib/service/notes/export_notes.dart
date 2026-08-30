import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/main.dart';
import 'package:anx_reader/service/sync/annotation_catalog.dart';
import 'package:anx_reader/service/sync/annotation_read_model.dart';
import 'package:anx_reader/utils/convert_string_to_uint8list.dart';
import 'package:anx_reader/utils/save_file_to_download.dart';
import 'package:csv/csv.dart';
import 'package:fast_gbk/fast_gbk.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:anx_reader/utils/toast/common.dart';

enum ExportType { copy, md, txt, csv }

Future<void> exportNotes(
  AnnotationBookUiModel book,
  List<AnnotationUiModel> notesList,
  ExportType exportType, {
  bool mergeChapterHeadings = false,
}) async {
  BuildContext context = navigatorKey.currentContext!;
  if (notesList.isEmpty) {
    return;
  }
  final copiedMessage = L10n.of(context).notesPageCopied;
  final exportedToMessage = L10n.of(context).notesPageExportedTo;

  final groups = _groupNotesByChapter(notesList, mergeChapterHeadings);

  switch (exportType) {
    case ExportType.copy:
      var notes = '${book.title}\n\t${book.author}\n\n';
      notes += groups.map(_formatPlainGroup).join('\n\n');

      await Clipboard.setData(ClipboardData(text: notes));
      AnxToast.show(copiedMessage);
      break;

    case ExportType.md:
      var notes = '# ${book.title}\n\n *${book.author}*\n\n';
      notes += groups.map(_formatMarkdownGroup).join('');

      String? filePath = await saveFileToDownload(
          bytes: convertStringToUint8List(notes),
          fileName: '${book.title.replaceAll('\n', ' ')}.md',
          mimeType: 'text/markdown');

      if (filePath != null) {
        AnxToast.show('$exportedToMessage $filePath');
      }
      break;

    case ExportType.txt:
      var notes = groups.map(_formatPlainGroup).join('\n\n');
      String? filePath = await saveFileToDownload(
          bytes: convertStringToUint8List(notes),
          fileName: '${book.title}.txt',
          mimeType: 'text/plain');
      if (filePath != null) {
        AnxToast.show('$exportedToMessage $filePath');
      }
      break;

    case ExportType.csv:
      final list = canonicalNotesCsvRows(book, notesList);

      final string = const ListToCsvConverter().convert(list);

      String? filePath = await saveFileToDownload(
          bytes: Uint8List.fromList(gbk.encode(string)),
          fileName: '${book.title}.csv',
          mimeType: 'text/csv');
      if (filePath != null) {
        AnxToast.show('$exportedToMessage $filePath');
      }
      break;
  }
}

List<List<dynamic>> canonicalNotesCsvRows(
  AnnotationBookUiModel book,
  List<AnnotationUiModel> notes,
) =>
    [
      [
        'Book',
        'Author',
        'Chapter',
        'Content',
        'Context',
        'Reader Note',
        'Motivation',
        'Presentation',
        'Color',
        'Create Time',
        'Update Time'
      ],
      for (final note in notes)
        [
          book.title,
          book.author,
          note.chapter ?? '',
          note.selectedText,
          note.annotationContext,
          note.effectivePersonalNote?.content,
          note.motivation.name,
          note.localPresentation?.style.name ?? '',
          note.localPresentation == null
              ? ''
              : '#${note.localPresentation!.color}',
          note.createdAt.toIso8601String(),
          note.updatedAt.toIso8601String(),
        ],
    ];

class _ChapterGroup {
  final String chapter;
  final List<AnnotationUiModel> notes;

  _ChapterGroup(this.chapter, this.notes);
}

List<_ChapterGroup> _groupNotesByChapter(
    List<AnnotationUiModel> notes, bool mergeChapters) {
  if (!mergeChapters) {
    return notes
        .map((note) => _ChapterGroup(note.chapter ?? '', [note]))
        .toList();
  }

  final groups = <_ChapterGroup>[];
  if (notes.isEmpty) return groups;

  String currentChapter = notes.first.chapter ?? '';
  List<AnnotationUiModel> currentNotes = [];

  void pushGroup() {
    groups.add(_ChapterGroup(
        currentChapter, List<AnnotationUiModel>.from(currentNotes)));
  }

  for (final note in notes) {
    if (currentNotes.isEmpty) {
      currentChapter = note.chapter ?? '';
      currentNotes.add(note);
      continue;
    }

    if ((note.chapter ?? '') == currentChapter) {
      currentNotes.add(note);
    } else {
      pushGroup();
      currentChapter = note.chapter ?? '';
      currentNotes = [note];
    }
  }

  if (currentNotes.isNotEmpty) {
    pushGroup();
  }

  return groups;
}

String _formatPlainGroup(_ChapterGroup group) {
  final buffer = StringBuffer();
  if (group.chapter.isNotEmpty) {
    buffer.writeln(group.chapter);
  }
  for (final note in group.notes) {
    if (note.selectedText.isNotEmpty) {
      buffer.writeln('\t${note.selectedText}');
    }
    if (note.annotationContext?.isNotEmpty == true) {
      buffer.writeln('\t${note.annotationContext}');
    }
    if (note.effectivePersonalNote?.content?.isNotEmpty == true) {
      buffer.writeln('\t\t${note.effectivePersonalNote!.content}');
    }
    buffer.writeln();
  }
  return buffer.toString().trim();
}

String _formatMarkdownGroup(_ChapterGroup group) {
  final buffer = StringBuffer();
  buffer.writeln('## ${group.chapter}\n');
  for (final note in group.notes) {
    if (note.selectedText.isNotEmpty) {
      buffer.writeln('> ${note.selectedText}\n');
    }
    if (note.annotationContext?.isNotEmpty == true) {
      buffer.writeln('_${note.annotationContext}_\n');
    }
    if (note.effectivePersonalNote?.content?.isNotEmpty == true) {
      buffer.writeln('${note.effectivePersonalNote!.content}\n');
    }
    buffer.writeln();
  }
  return buffer.toString();
}
