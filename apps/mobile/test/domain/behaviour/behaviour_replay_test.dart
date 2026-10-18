import 'package:bhorosha/domain/behaviour/behaviour_replay.dart';
import 'package:bhorosha/domain/behaviour/feature_names.dart';
import 'package:flutter_test/flutter_test.dart';

// Every feature a distinct non-zero value, so a changed one is visible.
final base = [for (var i = 0; i < FeatureNames.count; i++) i + 1.0];

double v(List<double> xs, String name) => xs[FeatureNames.indexOf(name)];

/// The wire names whose value differs between [a] and [b].
Set<String> changedNames(List<double> a, List<double> b) => {
  for (var i = 0; i < FeatureNames.count; i++)
    if (a[i] != b[i]) FeatureNames.wire[i],
};

/// The server's morphology (identity model) names, `schema.py` signal.
const morphology = {
  'swipe_start_x',
  'swipe_start_y',
  'swipe_end_x',
  'swipe_end_y',
  'swipe_angle_rad',
  'swipe_length_px',
  'pressure_mean',
  'pin_tap_offset_mean_px',
  'pin_pressure_mean',
  'size_mean',
  'size_max',
  'size_iqr',
  'tap_offset_med',
  'tap_offset_iqr',
  'tap_x_iqr',
  'tap_y_iqr',
  'tap_size_med',
  'tap_count',
  'imu_accel_mag_mean',
  'imu_accel_mag_std',
  'imu_gyro_mag_mean',
  'imu_gyro_mag_std',
  'imu_tilt_dominant_rad',
};

void main() {
  group('tapPattern', () {
    final out = BehaviourReplay.tapPattern(base);

    test('changes exactly the tap and PIN-tap morphology block', () {
      expect(changedNames(base, out), {
        'pin_tap_offset_mean_px',
        'tap_offset_med',
        'tap_offset_iqr',
        'tap_x_iqr',
        'tap_y_iqr',
        'pressure_mean',
        'pin_pressure_mean',
        'size_mean',
        'size_max',
        'size_iqr',
        'tap_size_med',
      });
    });

    test('offsets ×3, pressure and size ×0.6', () {
      for (final n in BehaviourReplay.tapOffsetNames) {
        expect(v(out, n), closeTo(v(base, n) * 3, 1e-9), reason: n);
      }
      for (final n in BehaviourReplay.contactNames) {
        expect(v(out, n), closeTo(v(base, n) * 0.6, 1e-9), reason: n);
      }
    });

    test('stays inside the morphology block (pressure_max is tempo)', () {
      expect(morphology.containsAll(changedNames(base, out)), isTrue);
      expect(v(out, 'pressure_max'), v(base, 'pressure_max'));
    });
  });

  group('shaking', () {
    final out = BehaviourReplay.shaking(base);

    test('changes exactly the IMU block', () {
      expect(changedNames(base, out), {
        'imu_accel_mag_std',
        'imu_gyro_mag_std',
        'imu_accel_mag_mean',
        'imu_tilt_dominant_rad',
      });
      expect(changedNames(base, out), BehaviourReplay.imuNames.toSet());
    });

    test('std ×4, accel mean +1.5, tilt +0.6; gyro mean kept', () {
      expect(
        v(out, 'imu_accel_mag_std'),
        closeTo(v(base, 'imu_accel_mag_std') * 4, 1e-9),
      );
      expect(
        v(out, 'imu_gyro_mag_std'),
        closeTo(v(base, 'imu_gyro_mag_std') * 4, 1e-9),
      );
      expect(
        v(out, 'imu_accel_mag_mean'),
        closeTo(v(base, 'imu_accel_mag_mean') + 1.5, 1e-9),
      );
      expect(
        v(out, 'imu_tilt_dominant_rad'),
        closeTo(v(base, 'imu_tilt_dominant_rad') + 0.6, 1e-9),
      );
      expect(v(out, 'imu_gyro_mag_mean'), v(base, 'imu_gyro_mag_mean'));
    });

    test('a missing IMU reading stays missing', () {
      final zeros = List<double>.filled(FeatureNames.count, 0);
      expect(BehaviourReplay.shaking(zeros), zeros);
    });
  });

  group('coached', () {
    final out = BehaviourReplay.coached(base);

    test('changes exactly the tempo block, mirroring synth.coach', () {
      expect(changedNames(base, out), {
        'pin_hold_1_ms',
        'pin_hold_2_ms',
        'pin_hold_3_ms',
        'pin_hold_4_ms',
        'pin_flight_1_ms',
        'pin_flight_2_ms',
        'pin_flight_3_ms',
        'pin_total_entry_ms',
        'pin_backspaces',
        'swipe_duration_ms',
        'swipe_v_mean',
        'swipe_v_p20',
        'swipe_v_p50',
        'swipe_v_p80',
        'swipe_accel_mean',
      });
      expect(changedNames(base, out), BehaviourReplay.coachedNames.toSet());
    });

    test('the morphology is untouched (the same hand on the same phone)', () {
      expect(changedNames(base, out).intersection(morphology), isEmpty);
    });

    test('holds ×2.0, flights ×2.2, entry ×2.2 + 8 s, backspaces +2, swipe '
        'duration ×1.8, swipe speed ×0.55', () {
      for (final n in BehaviourReplay.holdNames) {
        expect(v(out, n), closeTo(v(base, n) * 2.0, 1e-9), reason: n);
      }
      for (final n in BehaviourReplay.flightNames) {
        expect(v(out, n), closeTo(v(base, n) * 2.2, 1e-9), reason: n);
      }
      expect(
        v(out, 'pin_total_entry_ms'),
        closeTo(v(base, 'pin_total_entry_ms') * 2.2 + 8000, 1e-9),
      );
      expect(
        v(out, 'pin_backspaces'),
        closeTo(v(base, 'pin_backspaces') + 2, 1e-9),
      );
      expect(
        v(out, 'swipe_duration_ms'),
        closeTo(v(base, 'swipe_duration_ms') * 1.8, 1e-9),
      );
      for (final n in BehaviourReplay.swipeSpeedNames) {
        expect(v(out, n), closeTo(v(base, n) * 0.55, 1e-9), reason: n);
      }
    });

    test('zero backspaces is a real count: +2 still lands', () {
      final zeros = List<double>.filled(FeatureNames.count, 0);
      final changed = changedNames(zeros, BehaviourReplay.coached(zeros));
      expect(changed, {'pin_backspaces'});
    });
  });

  group('stranger', () {
    test('is tap pattern and shaking together', () {
      final out = BehaviourReplay.stranger(base);
      expect(out, BehaviourReplay.shaking(BehaviourReplay.tapPattern(base)));
      expect(changedNames(base, out), {
        ...BehaviourReplay.tapOffsetNames,
        ...BehaviourReplay.contactNames,
        ...BehaviourReplay.imuNames,
      });
      expect(morphology.containsAll(changedNames(base, out)), isTrue);
    });

    test('missing features (0.0) stay missing', () {
      final zeros = List<double>.filled(FeatureNames.count, 0);
      expect(BehaviourReplay.stranger(zeros), zeros);
    });
  });

  test('every perturbed name is on the wire', () {
    for (final n in [
      ...BehaviourReplay.tapOffsetNames,
      ...BehaviourReplay.contactNames,
      ...BehaviourReplay.imuNames,
      ...BehaviourReplay.coachedNames,
    ]) {
      expect(FeatureNames.indexOf(n), isNonNegative, reason: n);
    }
  });

  test('the input is not modified and a wrong length is refused', () {
    final copy = List<double>.of(base);
    for (final f in [
      BehaviourReplay.stranger,
      BehaviourReplay.tapPattern,
      BehaviourReplay.shaking,
      BehaviourReplay.coached,
    ]) {
      f(base);
      expect(base, copy);
      expect(() => f(List.filled(39, 1)), throwsArgumentError);
    }
  });
}
