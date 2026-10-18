import 'package:flutter/services.dart';

/// Named haptic moments so screens do not pick intensities ad hoc.
/// No haptic on scroll, plain navigation or screen
/// open; Android suppresses all of them when touch feedback is off.
abstract class Haptics {
  const Haptics();

  /// Numpad digit and backspace, segmented controls, preset pick.
  Future<void> key();

  /// Recipient row select, quick amount, operator chip.
  Future<void> selection();

  /// Bottom-sheet open (Apa, demo panel), new-number panel open.
  Future<void> light();

  /// Result done (end of the check draw), cash-in confirmed.
  Future<void> success();

  /// Overlay entrance, delay banner, verdict turned BLOCK, amount over max,
  /// long-press clear.
  Future<void> warning();

  /// Wrong PIN, PIN lockout start.
  Future<void> error();
}

class SystemHaptics extends Haptics {
  const SystemHaptics();
  @override
  Future<void> key() => HapticFeedback.selectionClick();
  @override
  Future<void> selection() => HapticFeedback.selectionClick();
  @override
  Future<void> light() => HapticFeedback.lightImpact();
  @override
  Future<void> success() => HapticFeedback.heavyImpact();
  @override
  Future<void> warning() => HapticFeedback.mediumImpact();
  @override
  Future<void> error() => HapticFeedback.vibrate();
}

class NoHaptics extends Haptics {
  const NoHaptics();
  @override
  Future<void> key() async {}
  @override
  Future<void> selection() async {}
  @override
  Future<void> light() async {}
  @override
  Future<void> success() async {}
  @override
  Future<void> warning() async {}
  @override
  Future<void> error() async {}
}
