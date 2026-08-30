import 'package:anx_reader/constants/note_annotations.dart';
import 'package:anx_reader/enums/hint_key.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/models/book_notes_state.dart';
import 'package:anx_reader/page/reading_page.dart';
import 'package:anx_reader/providers/book_notes.dart';
import 'package:anx_reader/service/book.dart';
import 'package:anx_reader/service/sync/annotation_catalog.dart';
import 'package:anx_reader/service/sync/annotation_read_model.dart';
import 'package:anx_reader/widgets/book_notes/book_note_tile.dart';
import 'package:anx_reader/widgets/book_share/excerpt_share_service.dart';
import 'package:anx_reader/widgets/delete_confirm.dart';
import 'package:anx_reader/widgets/hint/hint_banner.dart';
import 'package:anx_reader/widgets/tips/notes_tips.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:icons_plus/icons_plus.dart';
import 'package:sticky_headers/sticky_headers.dart';

class BookNotesList extends ConsumerWidget {
  const BookNotesList({
    super.key,
    required this.fingerprint,
    required this.reading,
    this.exportNotes,
  });

  final String fingerprint;
  final bool reading;
  final void Function(BuildContext context, AnnotationBookUiModel book,
      {List<AnnotationUiModel>? notes})? exportNotes;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notesAsync = ref.watch(bookNotesControllerProvider(fingerprint));
    return notesAsync.when(
      data: (state) => _buildContent(context, ref, state),
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (error, stack) => Padding(
        padding: const EdgeInsets.all(16),
        child: Text('Error: $error'),
      ),
    );
  }

  Widget _buildContent(
      BuildContext context, WidgetRef ref, BookNotesState state) {
    return Column(
      children: [
        StickyHeader(
          header: _header(context, ref, state),
          content: state.visibleAnnotations.isEmpty
              ? const Column(
                  children: [
                    Divider(),
                    NotesTips(),
                  ],
                )
              : Column(
                  children: [
                    HintBanner(
                      icon: const Icon(Icons.info_outline),
                      hintKey: HintKey.bookNotesOperations,
                      margin: const EdgeInsets.only(bottom: 10),
                      child: Text(L10n.of(context).bookNotesOperationsHint),
                    ),
                    ...state.visibleAnnotations.map(
                      (bookNote) => _slidableNote(
                        context,
                        ref,
                        bookNote,
                        _bookNoteItem(context, ref, state, bookNote),
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _header(BuildContext context, WidgetRef ref, BookNotesState state) {
    final notifier =
        ref.read(bookNotesControllerProvider(fingerprint).notifier);
    final buttonColor = Theme.of(context).colorScheme.primary;
    if (state.isSelecting) {
      final allSelected = state.selectedAnnotationIds.length ==
              state.visibleAnnotations.length &&
          state.visibleAnnotations.isNotEmpty;
      return Row(
        children: [
          IconButton(
            onPressed: () {
              if (allSelected) {
                notifier.clearSelection();
              } else {
                notifier.selectAllVisible();
              }
            },
            icon: Icon(
              allSelected ? EvaIcons.checkmark_circle : Icons.circle_outlined,
              color: buttonColor,
            ),
          ),
          const Spacer(),
          DeleteConfirm(
            delete: () async {
              await notifier.deleteAnnotations(state.selectedAnnotations);
              if (reading) {
                final player = epubPlayerKey.currentState;
                if (player != null) {
                  await player.refreshAnnotations();
                }
              }
            },
            deleteIcon: Icon(EvaIcons.trash_2, color: buttonColor),
            confirmIcon: const Icon(EvaIcons.close_circle, color: Colors.red),
          ),
          if (!reading && exportNotes != null)
            IconButton(
              onPressed: () {
                final selected =
                    notifier.annotationsForExport(selectedOnly: true);
                exportNotes!.call(context, state.book, notes: selected);
              },
              icon: Icon(Icons.ios_share, color: buttonColor),
            ),
        ],
      );
    }

    return Row(
      children: [
        const Spacer(),
        IconButton(
          onPressed: () => _showFilterSheet(context, ref),
          icon: Icon(
            state.showAllNotes ? EvaIcons.funnel_outline : EvaIcons.funnel,
          ),
        ),
      ],
    );
  }

  void _showFilterSheet(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return Consumer(
          builder: (context, ref, _) {
            final asyncState =
                ref.watch(bookNotesControllerProvider(fingerprint));
            return asyncState.when(
              data: (state) => Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _sortButton(
                          context: context,
                          label: L10n.of(context).notesPageSortTime,
                          field: NotesSortField.createdTime,
                          current: state.viewSortMode,
                          onPressed: () => ref
                              .read(bookNotesControllerProvider(fingerprint)
                                  .notifier)
                              .toggleViewSort(NotesSortField.createdTime),
                        ),
                        _sortButton(
                          context: context,
                          label: L10n.of(context).notesPageSortChapter,
                          field: NotesSortField.cfi,
                          current: state.viewSortMode,
                          onPressed: () => ref
                              .read(bookNotesControllerProvider(fingerprint)
                                  .notifier)
                              .toggleViewSort(NotesSortField.cfi),
                        ),
                        const Spacer(),
                      ],
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => ref
                                .read(
                                  bookNotesControllerProvider(fingerprint)
                                      .notifier,
                                )
                                .toggleShowBookmarks(),
                            icon: Icon(
                              state.showBookmarks
                                  ? EvaIcons.bookmark
                                  : EvaIcons.bookmark_outline,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            label: Text(L10n.of(context).noteListShowBookmark),
                          ),
                        ),
                      ],
                    ),
                    for (final type in notesType)
                      _filterRow(context, ref, state, type),
                    const Divider(),
                    Row(
                      children: [
                        ElevatedButton(
                          onPressed: () => ref
                              .read(bookNotesControllerProvider(fingerprint)
                                  .notifier)
                              .resetFilters(),
                          child: Text(L10n.of(context).notesPageFilterReset),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor:
                                  Theme.of(context).colorScheme.primary,
                              foregroundColor:
                                  Theme.of(context).colorScheme.onPrimary,
                            ),
                            onPressed: Navigator.of(context).pop,
                            child: Text(L10n.of(context).notesPageViewAllNNotes(
                                state.visibleAnnotations.length)),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              loading: () => const SizedBox(
                height: 160,
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (error, stack) => Padding(
                padding: const EdgeInsets.all(16),
                child: Text('Error: $error'),
              ),
            );
          },
        );
      },
    );
  }

  Widget _sortButton({
    required BuildContext context,
    required String label,
    required NotesSortField field,
    required NotesSortMode current,
    required VoidCallback onPressed,
  }) {
    final isActive = current.field == field;

    final buttonChild = Row(
      children: [
        Text(label),
        if (isActive)
          Icon(
            current.direction == SortDirection.asc
                ? EvaIcons.arrow_up
                : EvaIcons.arrow_down,
          ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: isActive
          ? FilledButton(onPressed: onPressed, child: buttonChild)
          : OutlinedButton(onPressed: onPressed, child: buttonChild),
    );
  }

  Widget _filterRow(
    BuildContext context,
    WidgetRef ref,
    BookNotesState state,
    NoteTypeOption type,
  ) {
    final notifier =
        ref.read(bookNotesControllerProvider(fingerprint).notifier);

    Widget colorButton(String color) {
      final key = '${type.type}#$color';
      final selected = state.enabledTypeColors.contains(key);
      return IconButton(
        onPressed: () => notifier.toggleTypeColor(type.type, color),
        icon: Icon(
          selected ? EvaIcons.checkmark_circle_2 : Icons.circle,
          color: Color(int.parse('0x99$color')),
        ),
        iconSize: 35,
      );
    }

    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Row(
        children: [
          IconButton(
            onPressed: () => notifier.toggleTypeColors(type.type),
            icon: Icon(type.icon),
          ),
          const Spacer(),
          for (final color in notesColors) colorButton(color),
        ],
      ),
    );
  }

  Widget _bookNoteItem(
    BuildContext context,
    WidgetRef ref,
    BookNotesState state,
    AnnotationUiModel bookNote,
  ) {
    final notifier =
        ref.read(bookNotesControllerProvider(fingerprint).notifier);
    final cfi = bookNote.epubCfi;
    final localBook = state.book.localBook;
    final canNavigate =
        bookNote.navigationCapability == AnnotationCapability.available &&
            cfi != null &&
            localBook != null;
    return BookNoteTile(
      note: bookNote,
      onTap: state.isSelecting
          ? () => notifier.toggleSelection(bookNote)
          : !canNavigate
              ? null
              : () {
                  if (reading) {
                    epubPlayerKey.currentState?.goToCfi(cfi);
                  } else {
                    pushToReadingPage(ref, context, localBook, cfi: cfi);
                  }
                },
      onLongPress: () {
        notifier.toggleSelection(bookNote);
      },
      trailing: state.isSelecting
          ? IconButton(
              onPressed: () => notifier.toggleSelection(bookNote),
              icon: Icon(
                state.selectedAnnotationIds.contains(bookNote.ref.annotationId)
                    ? EvaIcons.checkmark_circle
                    : Icons.circle_outlined,
                color: Theme.of(context).colorScheme.primary,
              ),
            )
          : null,
    );
  }

  Widget _slidableNote(
    BuildContext context,
    WidgetRef ref,
    AnnotationUiModel bookNote,
    Widget child,
  ) {
    return Slidable(
      key: ValueKey(bookNote.ref.annotationId),
      startActionPane: _actionPane(context, ref, bookNote),
      endActionPane: _actionPane(context, ref, bookNote),
      child: child,
    );
  }

  ActionPane _actionPane(
      BuildContext context, WidgetRef ref, AnnotationUiModel bookNote) {
    return ActionPane(
      motion: const StretchMotion(),
      children: [
        SlidableAction(
          onPressed: (context) {
            ExcerptShareService.showShareExcerpt(
              context: context,
              bookTitle: stateBook(ref)?.title ?? '',
              author: stateBook(ref)?.author ?? '',
              excerpt: bookNote.selectedText,
              chapter: bookNote.chapter ?? '',
            );
          },
          icon: Icons.share,
          label: L10n.of(context).readingPageShareShare,
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        ),
        SlidableAction(
          onPressed: (context) => _editBookNote(context, ref, bookNote),
          icon: Icons.edit,
          label: L10n.of(context).commonEdit,
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        ),
      ],
    );
  }

  AnnotationBookUiModel? stateBook(WidgetRef ref) =>
      ref.read(bookNotesControllerProvider(fingerprint)).valueOrNull?.book;

  void _editBookNote(
      BuildContext context, WidgetRef ref, AnnotationUiModel bookNote) {
    final isBookmark = bookNote.motivation == AnnotationMotivation.bookmark;
    String currentType = bookNote.localPresentation?.style.name ?? 'highlight';
    String currentColor =
        bookNote.localPresentation?.color ?? notesColors.first;
    String? currentNote = bookNote.effectivePersonalNote?.content;

    final noteController = TextEditingController(text: currentNote);

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 8, bottom: 16),
                      // The excerpt is selected source text, not commentary.
                      // Editing it alone would invalidate its CFI/context.
                      child: Text(
                        bookNote.selectedText,
                        style: const TextStyle(fontSize: 16),
                      ),
                    ),
                    if (!isBookmark)
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            Row(
                              children: notesType.map((type) {
                                return IconButton(
                                  icon: Icon(
                                    type.icon,
                                    color: currentType == type.type
                                        ? Theme.of(context).colorScheme.primary
                                        : Colors.grey,
                                  ),
                                  onPressed: () {
                                    setState(() {
                                      currentType = type.type;
                                    });
                                  },
                                );
                              }).toList(),
                            ),
                            Row(
                              children: notesColors.map((color) {
                                return IconButton(
                                  icon: Icon(
                                    currentColor == color
                                        ? EvaIcons.checkmark_circle_2
                                        : Icons.circle,
                                    color: Color(int.parse('0x99$color')),
                                    size: 30,
                                  ),
                                  onPressed: () {
                                    setState(() {
                                      currentColor = color;
                                    });
                                  },
                                );
                              }).toList(),
                            ),
                          ],
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: TextField(
                        controller: noteController,
                        decoration: InputDecoration(
                          border: const OutlineInputBorder(),
                          hintText: L10n.of(context).contextMenuAddNoteTips,
                        ),
                        maxLines: 3,
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(L10n.of(context).commonCancel),
                ),
                TextButton(
                  onPressed: () async {
                    Navigator.of(context).pop();
                    await ref
                        .read(bookNotesControllerProvider(fingerprint).notifier)
                        .updateAnnotation(
                          bookNote.ref,
                          personalNote: noteController.text.trim(),
                          type: isBookmark ? null : currentType,
                          color: isBookmark ? null : currentColor,
                        );
                  },
                  child: Text(L10n.of(context).commonSave),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
