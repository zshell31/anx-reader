import 'package:flutter/widgets.dart';

bool shouldRefitPdfViewport(Size viewSize, Size? oldViewSize) =>
    oldViewSize != null && (viewSize.width - oldViewSize.width).abs() > 0.5;
