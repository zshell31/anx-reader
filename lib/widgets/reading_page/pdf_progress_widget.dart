import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/providers/current_reading.dart';
import 'package:anx_reader/widgets/reading_page/progress_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class PdfProgressWidget extends ConsumerStatefulWidget {
  const PdfProgressWidget({super.key, required this.onGoToPage});

  final Future<void> Function(int page) onGoToPage;

  @override
  ConsumerState<PdfProgressWidget> createState() => _PdfProgressWidgetState();
}

class _PdfProgressWidgetState extends ConsumerState<PdfProgressWidget> {
  double? _dragPage;

  @override
  Widget build(BuildContext context) {
    final reading = ref.watch(currentReadingProvider);
    final pageCount = reading.chapterTotalPages ?? 0;
    final currentPage = pageCount < 1
        ? 1
        : (reading.chapterCurrentPage ?? 1).clamp(1, pageCount);
    final page = (_dragPage ?? currentPage.toDouble()).round();
    final l10n = L10n.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 10),
          Text(
            l10n.readingPageReadingInfoBookProgress,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const Divider(),
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: currentPage > 1
                    ? () => widget.onGoToPage(currentPage - 1)
                    : null,
              ),
              Expanded(
                child: Slider(
                  min: 1,
                  max: pageCount > 1 ? pageCount.toDouble() : 2,
                  value: page.toDouble(),
                  label: '$page',
                  onChanged: pageCount > 1
                      ? (value) => setState(() => _dragPage = value)
                      : null,
                  onChangeEnd: pageCount > 1
                      ? (value) async {
                          await widget.onGoToPage(value.round());
                          if (mounted) setState(() => _dragPage = null);
                        }
                      : null,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.arrow_forward),
                onPressed: currentPage < pageCount
                    ? () => widget.onGoToPage(currentPage + 1)
                    : null,
              ),
            ],
          ),
          Row(
            children: [
              ProgressDisplay(
                mainText: pageCount < 1 ? '—' : '$page / $pageCount',
                subText: l10n.readingPageCurrentPage,
              ),
              ProgressDisplay(
                mainText: pageCount < 1
                    ? '0.00'
                    : (page / pageCount * 100).toStringAsFixed(2),
                subText: '%',
              ),
            ],
          ),
          const SizedBox(height: 10),
        ],
      ),
    );
  }
}
