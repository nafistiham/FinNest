import 'dart:collection';

import 'behaviour_sample.dart';

/// A rolling buffer of IMU samples, kept for [keep] relative to the newest.
///
/// Send money starts it so that the ±1 s windows around the first PIN touch
/// already have history behind them.
final class ImuWindow {
  ImuWindow({this.keep = const Duration(seconds: 30)});

  final Duration keep;
  final Queue<ImuSample> _samples = Queue<ImuSample>();
  int? _newestMs;

  /// Every retained sample, oldest first.
  List<ImuSample> get all => List.unmodifiable(_samples);

  int get length => _samples.length;

  void add(ImuSample s) {
    _samples.addLast(s);
    final newest = _newestMs;
    _newestMs = newest == null || s.tMs > newest ? s.tMs : newest;
    final cutoff = _newestMs! - keep.inMilliseconds;
    while (_samples.isNotEmpty && _samples.first.tMs < cutoff) {
      _samples.removeFirst();
    }
  }

  /// Samples with `|s.tMs - tMs| <= halfWindowMs`, oldest first.
  List<ImuSample> around(int tMs, {int halfWindowMs = 1000}) {
    final lo = tMs - halfWindowMs;
    final hi = tMs + halfWindowMs;
    return List.unmodifiable(_samples.where((s) => s.tMs >= lo && s.tMs <= hi));
  }

  void clear() {
    _samples.clear();
    _newestMs = null;
  }
}
