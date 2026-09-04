import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/page/book_player/epub_player.dart';
import 'package:anx_reader/page/book_player/pdf_player.dart';
import 'package:anx_reader/widgets/reading_page/widgets/book_toc.dart';
import 'package:anx_reader/widgets/reading_page/widgets/bookmark.dart';
import 'package:flutter/material.dart';

class TocWidget extends StatefulWidget {
  const TocWidget({
    super.key,
    required this.epubPlayerKey,
    this.pdfPlayerKey,
    this.isPdf = false,
    required this.hideAppBarAndBottomBar,
    required this.closeDrawer,
  });

  final GlobalKey<EpubPlayerState> epubPlayerKey;
  final GlobalKey<PdfPlayerState>? pdfPlayerKey;
  final bool isPdf;
  final Function hideAppBarAndBottomBar;
  final VoidCallback closeDrawer;

  @override
  State<TocWidget> createState() => _TocWidgetState();
}

class _TocWidgetState extends State<TocWidget>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: widget.isPdf ? 1 : 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TabBar(
          controller: _tabController,
          tabs: [
            Tab(text: L10n.of(context).readingContents),
            if (!widget.isPdf) Tab(text: L10n.of(context).readingBookmark),
          ],
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: TabBarView(
              controller: _tabController,
              children: [
                buildBookToc(),
                if (!widget.isPdf) buildBookmarkList(),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget buildBookmarkList() {
    return BookmarkWidget(
      epubPlayerKey: widget.epubPlayerKey,
      onNavigate: () {
        widget.hideAppBarAndBottomBar(false);
        widget.closeDrawer();
      },
    );
  }

  BookToc buildBookToc() {
    if (widget.isPdf) {
      return BookToc(
        currentHref: () =>
            widget.pdfPlayerKey?.currentState?.currentOutlineHref ?? '',
        currentProgress: () {
          final state = widget.pdfPlayerKey?.currentState;
          return state == null
              ? ''
              : '${state.currentPageNumber} / ${state.pageCount}';
        },
        onNavigate: (item) =>
            widget.pdfPlayerKey?.currentState?.goToOutline(item.href),
        hideAppBarAndBottomBar: widget.hideAppBarAndBottomBar,
        closeDrawer: widget.closeDrawer,
      );
    }
    return BookToc(
      epubPlayerKey: widget.epubPlayerKey,
      hideAppBarAndBottomBar: widget.hideAppBarAndBottomBar,
      closeDrawer: widget.closeDrawer,
    );
  }
}
