import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:flutter/material.dart';

/// Pending feedback without a continuously ticking animation on e-ink screens.
class RequestProgressIndicator extends StatelessWidget {
  const RequestProgressIndicator({super.key, this.strokeWidth = 4, this.color});

  final double strokeWidth;
  final Color? color;

  @override
  Widget build(BuildContext context) => Prefs().eInkMode
      ? Icon(Icons.hourglass_empty, size: 18, color: color)
      : CircularProgressIndicator(strokeWidth: strokeWidth, color: color);
}

class RequestLinearProgressIndicator extends StatelessWidget {
  const RequestLinearProgressIndicator({super.key});

  @override
  Widget build(BuildContext context) => Prefs().eInkMode
      ? const SizedBox(height: 4)
      : const LinearProgressIndicator();
}
