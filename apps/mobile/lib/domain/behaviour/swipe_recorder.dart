import 'behaviour_sample.dart';

/// Records the payee-list scroll on Send money as strokes.
///
/// Positions in physical pixels, pressure 0..1, size the touch major radius in
/// physical pixels (0.0 when unknown), timestamps in milliseconds.
/// A stroke that ends with fewer than two points is kept: the extractor
/// reports what it can (the landing position) and nothing else.
final class SwipeRecorder {
  List<StrokePoint>? _current;
  final List<Stroke> _strokes = <Stroke>[];

  /// Finished strokes, in order.
  List<Stroke> get strokes => List.unmodifiable(_strokes);

  /// True between [start] and [end].
  bool get isActive => _current != null;

  void start(Point2 p, double pressure, int tMs, {double size = 0.0}) {
    // A start while a stroke is open closes the open one first, so a dropped
    // pointer-up never merges two gestures.
    _flush();
    _current = <StrokePoint>[
      StrokePoint(tMs: tMs, p: p, pressure: pressure, size: size),
    ];
  }

  void move(Point2 p, double pressure, int tMs, {double size = 0.0}) {
    _current?.add(StrokePoint(tMs: tMs, p: p, pressure: pressure, size: size));
  }

  void end(Point2 p, double pressure, int tMs, {double size = 0.0}) {
    final current = _current;
    if (current == null) return;
    current.add(StrokePoint(tMs: tMs, p: p, pressure: pressure, size: size));
    _flush();
  }

  void reset() {
    _current = null;
    _strokes.clear();
  }

  void _flush() {
    final current = _current;
    if (current != null) {
      _strokes.add(Stroke(current));
      _current = null;
    }
  }
}
