import 'package:anx_reader/models/toc_item.dart';
import 'package:pdfrx/pdfrx.dart';

class PdfOutlineToc {
  const PdfOutlineToc({required this.items, required this.destinations});

  final List<TocItem> items;
  final Map<String, PdfDest> destinations;
}

PdfOutlineToc buildPdfOutlineToc(
  List<PdfOutlineNode> outline,
  int pageCount,
) {
  final destinations = <String, PdfDest>{};

  List<TocItem> convert(List<PdfOutlineNode> nodes, List<int> parentPath) {
    return [
      for (var index = 0; index < nodes.length; index++)
        () {
          final node = nodes[index];
          final path = [...parentPath, index];
          final id = 'pdf-outline-${path.join('-')}';
          final dest = node.dest;
          if (dest != null) destinations[id] = dest;
          final page = dest?.pageNumber.clamp(1, pageCount) ?? 0;
          return TocItem(
            id: id,
            href: id,
            label: node.title.trim().isEmpty ? 'Page $page' : node.title,
            subitems: convert(node.children, path),
            level: path.length - 1,
            startPage: page,
            startPercentage:
                pageCount < 1 || page < 1 ? 0 : (page - 1) / pageCount,
          );
        }(),
    ];
  }

  return PdfOutlineToc(
    items: convert(outline, const []),
    destinations: Map.unmodifiable(destinations),
  );
}
