import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/log.dart';

/// In-memory timings for the smoke report (`hold_to_audio_ms` and friends).
/// Values are milliseconds; names are snake_case metric ids.
class MetricsLog {
  final Map<String, List<int>> _values = {};

  void record(String name, int valueMs) {
    _values.putIfAbsent(name, () => []).add(valueMs);
    Log.i('metrics', '$name=$valueMs');
  }

  /// Every recorded value, by metric name, oldest first. Unmodifiable copy.
  Map<String, List<int>> get all => {
    for (final e in _values.entries) e.key: List.unmodifiable(e.value),
  };

  /// Most recent value for [name], or null when never recorded.
  int? last(String name) {
    final list = _values[name];
    return list == null || list.isEmpty ? null : list.last;
  }

  void clear() => _values.clear();
}

/// Metric names used by this feature.
abstract final class Metrics {
  /// First audible Apa frame minus the `ScoreResponse` arrival (target 300 ms).
  static const holdToAudioMs = 'hold_to_audio_ms';
}

final metricsLogProvider = Provider<MetricsLog>((ref) => MetricsLog());
