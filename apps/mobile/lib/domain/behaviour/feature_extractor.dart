import 'dart:math' as math;

import 'behaviour_sample.dart';
import 'feature_names.dart';

/// Turns one [BehaviourSample] into the 55-float wire vector.
///
/// Numerically mirrors `libs/ato/bhorosha_ato/features.py`: medians across
/// strokes (circular mean for the angle), velocity percentiles with linear
/// interpolation, time-weighted acceleration, population std for the IMU.
/// Anything unmeasurable is carried as `null` until the end and only then
/// becomes the schema's `missing` value, 0.0; the output is always exactly
/// [FeatureNames.count] finite doubles.
///
/// The 16 key-rank features ([FeatureNames.keyRank]) are always absent: the
/// PIN surface types no text, so they go out as 0.0. Stated limit: the model
/// was trained on sessions where that block was measured, so on the app it
/// scores a shape it never saw (all-zero key ranks); the other 39 carry the
/// signal.
abstract final class FeatureExtractor {
  /// Half-width of the IMU window around each PIN touch-down
  /// (features.py `IMU_WINDOW_MS`).
  static const int imuHalfWindowMs = 1000;

  static const int _pinLength = 4;

  static List<double> build(BehaviourSample s) {
    final values = <String, double?>{
      ..._swipeBlock(s.strokes),
      ..._pressureBlock(s.strokes),
      ..._pinBlock(s.keys),
      ..._sizeBlock(s.strokes),
      ..._tapBlock(s.keys),
      ..._imuBlock(s.imu, s.keys),
      ..._keyRankBlock(),
    };
    assert(
      values.length == FeatureNames.count &&
          FeatureNames.wire.every(values.containsKey),
      'feature blocks must cover exactly FeatureNames.wire',
    );
    return List<double>.generate(
      FeatureNames.count,
      (i) => _finite(values[FeatureNames.wire[i]]),
      growable: false,
    );
  }

  // --- key-rank block (16): not measured on the PIN surface ---

  static Map<String, double?> _keyRankBlock() => {
    for (final name in FeatureNames.keyRank) name: null,
  };

  // --- swipe block (12): features.py `_stroke_swipe` / `_aggregate_swipe` ---

  static Map<String, double?> _swipeBlock(List<Stroke> strokes) {
    final perStroke = strokes.map(_strokeSwipe).toList(growable: false);
    const names = [
      'swipe_duration_ms',
      'swipe_start_x',
      'swipe_start_y',
      'swipe_end_x',
      'swipe_end_y',
      'swipe_angle_rad',
      'swipe_length_px',
      'swipe_v_mean',
      'swipe_v_p20',
      'swipe_v_p50',
      'swipe_v_p80',
      'swipe_accel_mean',
    ];
    return {
      for (final name in names)
        name: name == 'swipe_angle_rad'
            ? _circularMeanOrNull(perStroke.map((r) => r[name]))
            : _medianOrNull(perStroke.map((r) => r[name])),
    };
  }

  static Map<String, double?> _strokeSwipe(Stroke stroke) {
    final pts = stroke.points;
    double? duration;
    double? length;
    double? angle;
    double? vMean;
    double? vP20;
    double? vP50;
    double? vP80;
    double? accel;
    double? startX;
    double? startY;
    double? endX;
    double? endY;

    if (pts.isNotEmpty) {
      startX = pts.first.p.x;
      startY = pts.first.p.y;
      endX = pts.last.p.x;
      endY = pts.last.p.y;
    }

    if (pts.length >= 2) {
      duration = (pts.last.tMs - pts.first.tMs).toDouble();

      var path = 0.0;
      final velocities = <double>[];
      final midpoints = <double>[];
      for (var i = 0; i + 1 < pts.length; i++) {
        final a = pts[i];
        final b = pts[i + 1];
        final step = a.p.distanceTo(b.p);
        path += step;
        final dt = (b.tMs - a.tMs).toDouble();
        if (dt > 0.0) {
          velocities.add(step / dt);
          midpoints.add((a.tMs + b.tMs) / 2.0);
        }
      }
      length = path;

      final dx = pts.last.p.x - pts.first.p.x;
      final dy = pts.last.p.y - pts.first.p.y;
      if (_hypot(dx, dy) > 0.0) {
        // Screen coordinates: y grows downward, so an upward swipe is a
        // negative angle (features.py keeps the same convention).
        angle = math.atan2(dy, dx);
      }

      if (duration > 0.0) vMean = length / duration;

      if (velocities.isNotEmpty) {
        vP20 = _percentile(velocities, 0.20);
        vP50 = _percentile(velocities, 0.50);
        vP80 = _percentile(velocities, 0.80);
      }

      if (velocities.length >= 2 && midpoints.last > midpoints.first) {
        // Time-weighted mean of per-segment acceleration telescopes to this.
        accel =
            (velocities.last - velocities.first) /
            (midpoints.last - midpoints.first);
      }
    }

    return {
      'swipe_duration_ms': duration,
      'swipe_start_x': startX,
      'swipe_start_y': startY,
      'swipe_end_x': endX,
      'swipe_end_y': endY,
      'swipe_angle_rad': angle,
      'swipe_length_px': length,
      'swipe_v_mean': vMean,
      'swipe_v_p20': vP20,
      'swipe_v_p50': vP50,
      'swipe_v_p80': vP80,
      'swipe_accel_mean': accel,
    };
  }

  // --- pressure block (2): features.py `_stroke_pressure` ------------------

  static Map<String, double?> _pressureBlock(List<Stroke> strokes) {
    final means = <double?>[];
    final maxes = <double?>[];
    for (final stroke in strokes) {
      if (stroke.points.isEmpty) {
        means.add(null);
        maxes.add(null);
        continue;
      }
      var sum = 0.0;
      var max = double.negativeInfinity;
      for (final pt in stroke.points) {
        sum += pt.pressure;
        if (pt.pressure > max) max = pt.pressure;
      }
      means.add(sum / stroke.points.length);
      maxes.add(max);
    }
    // Median over strokes of each stroke's own statistic, as features.py.
    return {
      'pressure_mean': _medianOrNull(means),
      'pressure_max': _medianOrNull(maxes),
    };
  }

  // --- PIN block (11) --------------------------------------------------------
  //
  // features.py `pin_features` reads HMOG *free text*, so it fills the hold
  // and flight slots with quantiles and reports backspaces per 100
  // keystrokes (features.py lines 421-426). The phone has a real four-digit
  // entry, so the slots are positional here, as the schema intends:
  //   hold_i   = up_i - down_i                (i = 1..4)
  //   flight_j = down_{j+1} - up_j            (j = 1..3)
  //   total    = up_4 - down_1
  // and `pin_backspaces` is the RAW count of backspace events for this entry,
  // not per-100: a single PIN attempt has at most a handful of keystrokes and
  // the per-100 scaling would turn one correction into 25.0.
  //
  // Presses are the non-backspace keys sorted by touch-down. If there are
  // more than four (a correction followed by re-entry), the FIRST four fill
  // the slots; with fewer than four, every slot that needs a missing press is
  // unmeasurable (0.0). Tap offset and pressure use all presses (median).

  static Map<String, double?> _pinBlock(List<KeyEvent> keys) {
    final presses = keys.where((k) => !k.isBackspace).toList()
      ..sort((a, b) => a.downMs.compareTo(b.downMs));
    final backspaces = keys.where((k) => k.isBackspace).length;

    final values = <String, double?>{};
    for (var i = 0; i < _pinLength; i++) {
      values['pin_hold_${i + 1}_ms'] = i < presses.length
          ? presses[i].holdMs.toDouble()
          : null;
    }
    for (var j = 0; j < _pinLength - 1; j++) {
      values['pin_flight_${j + 1}_ms'] = j + 1 < presses.length
          ? (presses[j + 1].downMs - presses[j].upMs).toDouble()
          : null;
    }
    values['pin_total_entry_ms'] = presses.length >= _pinLength
        ? (presses[_pinLength - 1].upMs - presses[0].downMs).toDouble()
        : null;
    values['pin_backspaces'] = backspaces.toDouble();

    // Tap offset is the distance of each press from the session's own tap
    // centroid, and both it and the pressure are the MEDIAN over presses,
    // exactly as features.py `pin_features` does (`_median_or_none`): the
    // server model was fitted with the Python extractor, so byte-level parity
    // wins over the "mean" in the feature names.
    if (presses.isEmpty) {
      values['pin_tap_offset_mean_px'] = null;
      values['pin_pressure_mean'] = null;
    } else {
      var cx = 0.0;
      var cy = 0.0;
      for (final k in presses) {
        cx += k.position.x;
        cy += k.position.y;
      }
      final centroid = Point2(cx / presses.length, cy / presses.length);
      values['pin_tap_offset_mean_px'] = _medianOrNull(
        presses.map((k) => k.position.distanceTo(centroid)),
      );
      values['pin_pressure_mean'] = _medianOrNull(
        presses.map((k) => k.pressure),
      );
    }
    return values;
  }

  // --- size block (3): features.py `_stroke_sizes` / `size_features` -------
  //
  // Matches origin/main features.py lines 356-363 and 376-398:
  //   - reads STROKES only (the swipe samples), never PIN presses
  //     (features.py 558-560: "size_features reads strokes only");
  //   - per stroke, the recorded sizes; a stroke with none is dropped (391);
  //   - size_mean = median over strokes of each stroke's MEAN size (395);
  //   - size_max  = median over strokes of each stroke's PEAK size (396);
  //   - size_iqr  = IQR (p75 - p25, numpy-linear percentiles) of the
  //     per-stroke means, only with >= 4 sized strokes (`MIN_IQR_SAMPLES`,
  //     123-146), else missing.
  // Ambiguity resolved: features.py skips a sample whose `size` is absent or
  // None. Flutter has no "absent", only `radiusMajor == 0.0` on devices that
  // do not report it, so a non-positive (or non-finite) size is treated as
  // absent rather than as a zero-area touch.

  static bool _hasSize(double size) => size.isFinite && size > 0.0;

  static Map<String, double?> _sizeBlock(List<Stroke> strokes) {
    final means = <double>[];
    final peaks = <double>[];
    for (final stroke in strokes) {
      final readings = stroke.points
          .map((pt) => pt.size)
          .where(_hasSize)
          .toList(growable: false);
      if (readings.isEmpty) continue;
      means.add(_meanOrNull(readings)!);
      peaks.add(readings.reduce(math.max));
    }
    return {
      'size_mean': _medianOrNull(means),
      'size_max': _medianOrNull(peaks),
      'size_iqr': _iqrOrNull(means),
    };
  }

  // --- tap block (6): features.py `tap_points` / `tap_geometry` -------------
  //
  // Matches origin/main features.py lines 522-542 and 545-585:
  //   - "taps" are HMOG OneFingerTouchEvent rows, i.e. discrete taps on the
  //     keyboard; the phone's analogue is the PIN presses, so taps = the
  //     non-backspace [KeyEvent]s (the same set `pin_tap_offset_mean_px`
  //     already uses). Backspaces carry no meaningful position. Strokes are
  //     never read here (558-560).
  //   - offsets are distances from the taps' own MEAN centroid (574-575), not
  //     from a key centre - the same substitution `pin_features` makes;
  //   - tap_offset_med = median offset (579; numerically equal to
  //     pin_tap_offset_mean_px);
  //   - tap_offset_iqr / tap_x_iqr / tap_y_iqr = IQR of the offsets / raw x /
  //     raw y (580-582), each needing >= 4 taps (`MIN_IQR_SAMPLES`), else
  //     missing;
  //   - tap_size_med = median of the taps' sizes that were recorded (576,
  //     583); a non-positive size is "not reported" (see the size block);
  //   - tap_count = number of taps as a plain unnormalised float (584); with
  //     no taps the whole block, count included, is missing = 0.0 (567-570).
  // Ambiguity: an HMOG OneFingerTouchEvent table may hold several rows per
  // physical tap (Action_type), and the server counts rows. The phone records
  // one KeyEvent per press, so tap_count here is presses, which is the
  // meaningful reading for a four-digit PIN.

  static Map<String, double?> _tapBlock(List<KeyEvent> keys) {
    final taps = keys.where((k) => !k.isBackspace).toList(growable: false);
    if (taps.isEmpty) {
      return const {
        'tap_offset_med': null,
        'tap_offset_iqr': null,
        'tap_x_iqr': null,
        'tap_y_iqr': null,
        'tap_size_med': null,
        'tap_count': null,
      };
    }
    final xs = taps.map((k) => k.position.x).toList(growable: false);
    final ys = taps.map((k) => k.position.y).toList(growable: false);
    final centroid = Point2(_meanOrNull(xs)!, _meanOrNull(ys)!);
    final offsets = taps
        .map((k) => k.position.distanceTo(centroid))
        .toList(growable: false);
    return {
      'tap_offset_med': _medianOrNull(offsets),
      'tap_offset_iqr': _iqrOrNull(offsets),
      'tap_x_iqr': _iqrOrNull(xs),
      'tap_y_iqr': _iqrOrNull(ys),
      'tap_size_med': _medianOrNull(taps.map((k) => k.size).where(_hasSize)),
      'tap_count': taps.length.toDouble(),
    };
  }

  // --- IMU block (5): features.py `imu_features` -----------------------------

  static Map<String, double?> _imuBlock(
    List<ImuSample> imu,
    List<KeyEvent> keys,
  ) {
    // ±1000 ms around each press touch-down. A sample inside several
    // overlapping windows is counted once (one pass over the buffer, so the
    // union needs no explicit dedupe). With no presses the whole buffer is
    // used, as features.py does with no anchors.
    final anchors = keys.where((k) => !k.isBackspace).map((k) => k.downMs);
    final spans = anchors
        .map((t) => (t - imuHalfWindowMs, t + imuHalfWindowMs))
        .toList(growable: false);
    final windowed = spans.isEmpty
        ? imu
        : imu
              .where((s) => spans.any((w) => w.$1 <= s.tMs && s.tMs <= w.$2))
              .toList(growable: false);

    final accelMag = windowed.map((s) => s.accelMagnitude).toList();
    final gyroMag = windowed.map((s) => s.gyroMagnitude).toList();

    double? tilt;
    if (windowed.isNotEmpty) {
      var mx = 0.0;
      var my = 0.0;
      var mz = 0.0;
      for (final s in windowed) {
        mx += s.ax;
        my += s.ay;
        mz += s.az;
      }
      final n = windowed.length;
      tilt = math.atan2(_hypot(mx / n, my / n), mz / n);
    }

    return {
      'imu_accel_mag_mean': _meanOrNull(accelMag),
      'imu_accel_mag_std': _populationStdOrNull(accelMag),
      'imu_gyro_mag_mean': _meanOrNull(gyroMag),
      'imu_gyro_mag_std': _populationStdOrNull(gyroMag),
      'imu_tilt_dominant_rad': tilt,
    };
  }

  // --- scalar helpers --------------------------------------------------------

  static double _finite(double? v) =>
      v == null || v.isNaN || v.isInfinite ? 0.0 : v;

  static double _hypot(double a, double b) => math.sqrt(a * a + b * b);

  /// Linear interpolation between the two nearest order statistics
  /// (numpy's default, features.py `_percentile`). `values` must be non-empty.
  static double _percentile(List<double> values, double q) {
    final ordered = [...values]..sort();
    if (ordered.length == 1) return ordered[0];
    final pos = (ordered.length - 1) * q;
    final low = pos.floor();
    final high = pos.ceil();
    if (low == high) return ordered[low];
    return ordered[low] * (high - pos) + ordered[high] * (pos - low);
  }

  /// Median of whatever was measured (`statistics.median`), or null.
  static double? _medianOrNull(Iterable<double?> values) {
    final present = values.whereType<double>().toList()..sort();
    if (present.isEmpty) return null;
    final n = present.length;
    if (n.isOdd) return present[n ~/ 2];
    return (present[n ~/ 2 - 1] + present[n ~/ 2]) / 2.0;
  }

  /// features.py `MIN_IQR_SAMPLES`: below four values an IQR is mostly an
  /// artefact of where the interpolation landed.
  static const int _minIqrSamples = 4;

  /// p75 - p25 with numpy-linear percentiles (features.py `_iqr_or_none`),
  /// or null with fewer than [_minIqrSamples] values.
  static double? _iqrOrNull(List<double> values) {
    if (values.length < _minIqrSamples) return null;
    return _percentile(values, 0.75) - _percentile(values, 0.25);
  }

  /// atan2 of the summed unit vectors; null when nothing was measured or
  /// the directions cancel (atan2(0, 0) would read as "rightward").
  static double? _circularMeanOrNull(Iterable<double?> angles) {
    final present = angles.whereType<double>();
    if (present.isEmpty) return null;
    var sinSum = 0.0;
    var cosSum = 0.0;
    for (final a in present) {
      sinSum += math.sin(a);
      cosSum += math.cos(a);
    }
    if (_hypot(sinSum, cosSum) < 1e-9) return null;
    return math.atan2(sinSum, cosSum);
  }

  static double? _meanOrNull(List<double> values) {
    if (values.isEmpty) return null;
    var sum = 0.0;
    for (final v in values) {
      sum += v;
    }
    return sum / values.length;
  }

  /// Population standard deviation; needs at least two samples.
  static double? _populationStdOrNull(List<double> values) {
    if (values.length < 2) return null;
    final mean = _meanOrNull(values)!;
    var sq = 0.0;
    for (final v in values) {
      sq += (v - mean) * (v - mean);
    }
    return math.sqrt(sq / values.length);
  }
}
