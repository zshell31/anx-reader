import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/page/book_player/pdf_crop.dart';
import 'package:anx_reader/page/book_player/pdf_crop_viewport.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'automatic cropping keeps all text and leaves vertical margins unchanged',
      () {
    expect(
        automaticPdfCrop(
            [const Rect.fromLTRB(100, 50, 900, 1500)], const Size(1000, 1600)),
        const Rect.fromLTRB(.085, 0, .915, 1));
    expect(automaticPdfCrop([], const Size(1000, 1600)),
        const Rect.fromLTWH(0, 0, 1, 1));
  });
  test('manual handles cannot invert the frame or move it off the page', () {
    const rect = Rect.fromLTRB(.1, .2, .9, .8);
    final resized =
        adjustPdfCrop(rect, const Offset(2, 2), const Offset(-1, -1));
    expect(resized.width, closeTo(.1, .0001));
    expect(resized.height, closeTo(.1, .0001));
    final moved = adjustPdfCrop(rect, const Offset(-2, 2), Offset.zero);
    expect(moved.left, closeTo(0, .000001));
    expect(moved.top, closeTo(.4, .000001));
    expect(moved.right, closeTo(.8, .000001));
    expect(moved.bottom, closeTo(1, .000001));
  });
  test(
      'cropped page geometry preserves original coordinates and removes vertical gaps',
      () {
    final layout = layoutCroppedPdfPages(
        [const Size(100, 200), const Size(200, 400)],
        (_) => const Rect.fromLTRB(.1, .25, .9, .75));
    expect(layout.visiblePageRects[0], const Rect.fromLTWH(0, 0, 200, 250));
    expect(layout.visiblePageRects[1].top, 258);
    expect(layout.pageLayouts[0], const Rect.fromLTWH(-25, -125, 250, 500));
    expect(layout.documentSize, const Size(200, 508));
  });
  test(
      'zoom never reveals removed margins and zoomed panning stays inside crop',
      () {
    final fit = constrainPdfCropViewport(
        center: const Offset(-100, 500),
        zoom: .5,
        viewSize: const Size(800, 600),
        crop: const Rect.fromLTWH(0, 0, 800, 2000),
        documentHeight: 2000);
    expect(fit.zoom, 1);
    expect(fit.center.dx, 400);
    final zoomed = constrainPdfCropViewport(
        center: const Offset(1000, 5000),
        zoom: 2,
        viewSize: const Size(800, 600),
        crop: const Rect.fromLTWH(0, 0, 800, 2000),
        documentHeight: 2000);
    expect(zoomed.center, const Offset(600, 1850));
  });
  test('book-specific mode and manual frame survive preferences reload',
      () async {
    SharedPreferences.setMockInitialValues({});
    await Prefs().initPrefs();
    const settings = PdfCropSettings(
        mode: PdfCropMode.manual, manual: Rect.fromLTRB(.1, .2, .9, .8));
    Prefs().setPdfCropSettings(10, settings);
    await Prefs().initPrefs();
    expect(Prefs().getPdfCropSettings(10).toMap(), settings.toMap());
    expect(Prefs().getPdfCropSettings(11).mode, PdfCropMode.off);
    Prefs().setPdfCropSettings(
        10, PdfCropSettings(mode: PdfCropMode.off, manual: settings.manual));
    expect(Prefs().getPdfCropSettings(10).manual, settings.manual);
  });
  test('invalid stored rectangles fall back to usable frame', () {
    final settings = PdfCropSettings.fromMap({
      'mode': 'manual',
      'rect': [.9, 0, .1, 1]
    });
    expect(settings.manual.width, greaterThan(.1));
  });
}
