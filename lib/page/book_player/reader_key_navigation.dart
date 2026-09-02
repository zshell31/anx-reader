import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

KeyEventResult handleVolumePageKey({
  required bool enabled,
  required PhysicalKeyboardKey physicalKey,
  required void Function() previousPage,
  required void Function() nextPage,
}) {
  if (!enabled) return KeyEventResult.ignored;
  if (physicalKey == PhysicalKeyboardKey.audioVolumeUp) {
    previousPage();
    return KeyEventResult.handled;
  }
  if (physicalKey == PhysicalKeyboardKey.audioVolumeDown) {
    nextPage();
    return KeyEventResult.handled;
  }
  return KeyEventResult.ignored;
}
