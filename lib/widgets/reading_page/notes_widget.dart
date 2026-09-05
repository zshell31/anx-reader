import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/widgets/book_notes/book_notes_list.dart';
import 'package:anx_reader/widgets/reading_page/widget_title.dart';
import 'package:anx_reader/service/sync/annotation_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:anx_reader/providers/book_notes.dart';

import 'package:anx_reader/models/book.dart';

class ReadingNotes extends ConsumerStatefulWidget {
  const ReadingNotes({super.key, required this.book});

  final Book book;

  @override
  ConsumerState<ReadingNotes> createState() => _ReadingNotesState();
}

class _ReadingNotesState extends ConsumerState<ReadingNotes> {
  final _searchController = TextEditingController();

  void _searchChanged() {
    ref
        .read(bookNotesControllerProvider(
          canonicalMd5Fingerprint(widget.book.md5),
        ).notifier)
        .clearSelection();
    setState(() {});
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      height: MediaQuery.of(context).size.height - 300,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          widgetTitle(L10n.of(context).navBarNotes, null),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: TextField(
              controller: _searchController,
              onChanged: (_) => _searchChanged(),
              decoration: InputDecoration(
                hintText: L10n.of(context).notesSearchHint,
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchController.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: MaterialLocalizations.of(context)
                            .deleteButtonTooltip,
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          _searchChanged();
                        },
                      ),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          Expanded(
            child: BookNotesList(
              fingerprint: canonicalMd5Fingerprint(widget.book.md5),
              reading: true,
              searchQuery: _searchController.text,
            ),
          ),
        ],
      ),
    );
  }
}
