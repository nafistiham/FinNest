import 'package:bhorosha/domain/behaviour/feature_names.dart';
import 'package:flutter_test/flutter_test.dart';

/// Copied literally from `libs/ato/bhorosha_ato/schema.py` FEATURES on
/// origin/main (then the 16 key ranks).
const schemaPyOrder = <String>[
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
  'pressure_mean',
  'pressure_max',
  'pin_hold_1_ms',
  'pin_hold_2_ms',
  'pin_hold_3_ms',
  'pin_hold_4_ms',
  'pin_flight_1_ms',
  'pin_flight_2_ms',
  'pin_flight_3_ms',
  'pin_total_entry_ms',
  'pin_backspaces',
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
  'keyrank_bksp',
  'keyrank_space',
  'keyrank_period',
  'keyrank_a',
  'keyrank_c',
  'keyrank_d',
  'keyrank_e',
  'keyrank_h',
  'keyrank_i',
  'keyrank_l',
  'keyrank_n',
  'keyrank_o',
  'keyrank_r',
  'keyrank_s',
  'keyrank_t',
  'keyrank_u',
];

void main() {
  test('wire order has 55 unique names matching schema.py', () {
    expect(schemaPyOrder, hasLength(55));
    expect(FeatureNames.count, 55);
    expect(FeatureNames.wire, hasLength(55));
    expect(FeatureNames.wire.toSet(), hasLength(55));
    expect(FeatureNames.wire, orderedEquals(schemaPyOrder));
  });

  test('keyRank is the 16-name tail of the wire', () {
    expect(FeatureNames.keyRank, hasLength(16));
    expect(FeatureNames.wire.sublist(39), orderedEquals(FeatureNames.keyRank));
  });

  test('indexOf follows the wire order', () {
    expect(FeatureNames.indexOf('swipe_duration_ms'), 0);
    expect(FeatureNames.indexOf('pin_hold_1_ms'), 14);
    expect(FeatureNames.indexOf('pin_pressure_mean'), 24);
    expect(FeatureNames.indexOf('size_mean'), 25);
    expect(FeatureNames.indexOf('tap_offset_med'), 28);
    expect(FeatureNames.indexOf('tap_count'), 33);
    expect(FeatureNames.indexOf('imu_accel_mag_mean'), 34);
    expect(FeatureNames.indexOf('imu_tilt_dominant_rad'), 38);
    expect(FeatureNames.indexOf('keyrank_bksp'), 39);
    expect(FeatureNames.indexOf('keyrank_u'), 54);
    expect(FeatureNames.indexOf('nope'), -1);
  });
}
