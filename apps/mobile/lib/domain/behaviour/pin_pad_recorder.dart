import 'behaviour_sample.dart';

/// Records PIN pad keystroke dynamics without ever learning the PIN.
///
/// `keyIndex` exists only to pair a touch-down with its touch-up when two
/// fingers overlap; it is never stored and never appears in [keys]. Positions
/// are in physical pixels, pressure 0..1, size is the touch major radius in
/// physical pixels (0.0 when unknown), timestamps in milliseconds.
final class PinPadRecorder {
  final Map<int, _PendingPress> _pending = <int, _PendingPress>{};
  final List<KeyEvent> _keys = <KeyEvent>[];

  /// Completed presses and backspaces, in completion order.
  List<KeyEvent> get keys => List.unmodifiable(_keys);

  void keyDown(
    int keyIndex,
    Point2 p,
    double pressure,
    int tMs, {
    double size = 0.0,
  }) {
    _pending[keyIndex] = _PendingPress(tMs, p, pressure, size);
  }

  /// Closes the press opened by [keyDown] for the same `keyIndex`; an up with
  /// no matching down is ignored.
  void keyUp(int keyIndex, int tMs) {
    final down = _pending.remove(keyIndex);
    if (down == null) return;
    _keys.add(
      KeyEvent(
        downMs: down.tMs,
        upMs: tMs < down.tMs ? down.tMs : tMs,
        position: down.p,
        pressure: down.pressure,
        size: down.size,
      ),
    );
  }

  /// A correction. Only the fact and the moment are kept.
  void backspace(int tMs) {
    _keys.add(
      KeyEvent(
        downMs: tMs,
        upMs: tMs,
        position: Point2.zero,
        pressure: 0,
        isBackspace: true,
      ),
    );
  }

  void reset() {
    _pending.clear();
    _keys.clear();
  }
}

final class _PendingPress {
  const _PendingPress(this.tMs, this.p, this.pressure, this.size);

  final int tMs;
  final Point2 p;
  final double pressure;
  final double size;
}
