import 'package:anx_reader/page/book_player/pdf_text_blocks.dart';
import 'package:flutter/material.dart';

typedef PdfTextBlockTranslator = Future<String> Function(
  PdfTextBlock block,
  String contextText,
);

class PdfReflowView extends StatelessWidget {
  const PdfReflowView({
    super.key,
    required this.pageCount,
    required this.pageController,
    required this.blockLoader,
    required this.translateBlock,
    required this.onPageChanged,
    required this.onTap,
  });

  final int pageCount;
  final PageController pageController;
  final PdfTextBlockPageLoader blockLoader;
  final PdfTextBlockTranslator translateBlock;
  final ValueChanged<int> onPageChanged;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: onTap,
      child: PageView.builder(
        controller: pageController,
        itemCount: pageCount,
        onPageChanged: (index) => onPageChanged(index + 1),
        itemBuilder: (context, index) => _PdfReflowPage(
          key: ValueKey(index + 1),
          pageNumber: index + 1,
          blockLoader: blockLoader,
          translateBlock: translateBlock,
          onTap: onTap,
        ),
      ),
    );
  }
}

class _PdfReflowPage extends StatefulWidget {
  const _PdfReflowPage({
    super.key,
    required this.pageNumber,
    required this.blockLoader,
    required this.translateBlock,
    required this.onTap,
  });

  final int pageNumber;
  final PdfTextBlockPageLoader blockLoader;
  final PdfTextBlockTranslator translateBlock;
  final VoidCallback onTap;

  @override
  State<_PdfReflowPage> createState() => _PdfReflowPageState();
}

class _PdfReflowPageState extends State<_PdfReflowPage> {
  late Future<List<PdfTextBlock>> _blocks;

  @override
  void initState() {
    super.initState();
    _blocks = widget.blockLoader.loadPage(widget.pageNumber);
  }

  void _retry() {
    setState(() {
      _blocks = widget.blockLoader.loadPage(widget.pageNumber);
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<PdfTextBlock>>(
      future: _blocks,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _ReflowStatus(
            icon: Icons.error_outline,
            message: snapshot.error.toString(),
            action: IconButton(
              tooltip: 'Retry',
              onPressed: _retry,
              icon: const Icon(Icons.refresh),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final blocks = snapshot.data!;
        if (blocks.isEmpty) {
          return const _ReflowStatus(
            icon: Icons.image_outlined,
            message: 'Selectable text is unavailable on this PDF page.',
          );
        }
        final contextText = blocks.map((block) => block.text).join('\n\n');
        return SelectionArea(
          // Handle ordinary taps inside SelectionArea so its selection gesture
          // does not swallow the reader menu action. Long presses still select.
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: widget.onTap,
            child: LayoutBuilder(builder: (context, constraints) {
              final margin = constraints.maxWidth > 800
                  ? (constraints.maxWidth - 752) / 2
                  : 24.0;
              return ListView.builder(
                padding: EdgeInsets.fromLTRB(margin, 32, margin, 64),
                itemCount: blocks.length + 1,
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Text(
                        'Page ${widget.pageNumber}',
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                    );
                  }
                  final block = blocks[index - 1];
                  return _BilingualBlock(
                    key: ValueKey('${block.pageNumber}:${block.blockIndex}'),
                    block: block,
                    contextText: contextText,
                    translateBlock: widget.translateBlock,
                  );
                },
              );
            }),
          ),
        );
      },
    );
  }
}

class _BilingualBlock extends StatefulWidget {
  const _BilingualBlock({
    super.key,
    required this.block,
    required this.contextText,
    required this.translateBlock,
  });

  final PdfTextBlock block;
  final String contextText;
  final PdfTextBlockTranslator translateBlock;

  @override
  State<_BilingualBlock> createState() => _BilingualBlockState();
}

class _BilingualBlockState extends State<_BilingualBlock> {
  late Future<String> _translation;

  @override
  void initState() {
    super.initState();
    _translation = widget.translateBlock(widget.block, widget.contextText);
  }

  void _retry() {
    setState(() {
      _translation = widget.translateBlock(widget.block, widget.contextText);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 36),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: colors.outlineVariant)),
        ),
        child: Padding(
          padding: const EdgeInsets.only(left: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.block.text,
                textAlign: TextAlign.justify,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      fontSize: 22,
                      height: 1.65,
                    ),
              ),
              const SizedBox(height: 16),
              FutureBuilder<String>(
                future: _translation,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return Row(
                      children: [
                        Expanded(
                          child: Text(
                            snapshot.error.toString(),
                            style: TextStyle(color: colors.error),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Retry',
                          onPressed: _retry,
                          icon: const Icon(Icons.refresh),
                        ),
                      ],
                    );
                  }
                  if (!snapshot.hasData) {
                    return const Align(
                      alignment: Alignment.centerLeft,
                      child: SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    );
                  }
                  return Text(
                    snapshot.data!,
                    textAlign: TextAlign.justify,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: colors.onSurfaceVariant,
                          fontSize: 22,
                          height: 1.65,
                        ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReflowStatus extends StatelessWidget {
  const _ReflowStatus({
    required this.icon,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 36),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            if (action != null) action!,
          ],
        ),
      ),
    );
  }
}
