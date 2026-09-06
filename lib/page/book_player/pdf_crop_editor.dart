import 'dart:ui' as ui;
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/page/book_player/pdf_crop.dart';
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

class PdfCropEditor extends StatefulWidget {
  const PdfCropEditor(
      {super.key, required this.page, required this.initialCrop});
  final PdfPage page;
  final Rect initialCrop;
  @override
  State<PdfCropEditor> createState() => _PdfCropEditorState();
}

class _PdfCropEditorState extends State<PdfCropEditor> {
  late Rect _crop = widget.initialCrop;
  ui.Image? _image;
  bool _failed = false;
  @override
  void initState() {
    super.initState();
    _render();
  }

  Future<void> _render() async {
    try {
      final scale = 1600 / widget.page.height;
      final rendered = await widget.page
          .render(fullWidth: widget.page.width * scale, fullHeight: 1600);
      if (rendered == null) throw StateError('Empty PDF preview');
      ui.Image image;
      try {
        image = await rendered.createImage();
      } finally {
        rendered.dispose();
      }
      if (!mounted) {
        image.dispose();
        return;
      }
      setState(() => _image = image);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.pdfCropManual), actions: [
        TextButton(
            onPressed:
                _image == null ? null : () => Navigator.pop(context, _crop),
            child: Text(l10n.pdfCropApply)),
      ]),
      body: Column(children: [
        Padding(
            padding: const EdgeInsets.all(12), child: Text(l10n.pdfCropHelp)),
        Expanded(
            child: Padding(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: AspectRatio(
                    aspectRatio: widget.page.width / widget.page.height,
                    child: LayoutBuilder(builder: (context, constraints) {
                      if (_failed) {
                        return Center(child: Text(l10n.pdfCropPreviewFailed));
                      }
                      if (_image == null) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      final size = constraints.biggest;
                      final rect = Rect.fromLTRB(
                          _crop.left * size.width,
                          _crop.top * size.height,
                          _crop.right * size.width,
                          _crop.bottom * size.height);
                      void drag(DragUpdateDetails details, Offset handle) =>
                          setState(() {
                            _crop = adjustPdfCrop(
                                _crop,
                                Offset(details.delta.dx / size.width,
                                    details.delta.dy / size.height),
                                handle);
                          });
                      return Stack(clipBehavior: Clip.none, children: [
                        Positioned.fill(
                            child: RawImage(image: _image, fit: BoxFit.fill)),
                        Positioned.fill(
                            child: IgnorePointer(
                                child:
                                    CustomPaint(painter: _CropPainter(rect)))),
                        Positioned.fromRect(
                            rect: rect,
                            child: GestureDetector(
                                key: const ValueKey('crop-move'),
                                behavior: HitTestBehavior.opaque,
                                onPanUpdate: (d) => drag(d, Offset.zero),
                                child: const SizedBox.expand())),
                        for (final handle in const [
                          Offset(-1, -1),
                          Offset(0, -1),
                          Offset(1, -1),
                          Offset(-1, 0),
                          Offset(1, 0),
                          Offset(-1, 1),
                          Offset(0, 1),
                          Offset(1, 1)
                        ])
                          Positioned(
                              left: rect.left +
                                  (handle.dx + 1) / 2 * rect.width -
                                  22,
                              top: rect.top +
                                  (handle.dy + 1) / 2 * rect.height -
                                  22,
                              child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onPanUpdate: (d) => drag(d, handle),
                                  child: SizedBox.square(
                                      dimension: 44,
                                      child: Center(
                                          child: Container(
                                              width: 14,
                                              height: 14,
                                              decoration: BoxDecoration(
                                                  color: Colors.white,
                                                  border: Border.all(
                                                      color: Colors.blue,
                                                      width: 2))))))),
                      ]);
                    }),
                  ),
                ))),
        SafeArea(
            top: false,
            child: TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(l10n.pdfCropCancel))),
      ]),
    );
  }
}

class _CropPainter extends CustomPainter {
  const _CropPainter(this.rect);
  final Rect rect;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(
        Path.combine(PathOperation.difference,
            Path()..addRect(Offset.zero & size), Path()..addRect(rect)),
        Paint()..color = Colors.black54);
    canvas.drawRect(
        rect,
        Paint()
          ..color = Colors.blue
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(_CropPainter oldDelegate) => oldDelegate.rect != rect;
}
