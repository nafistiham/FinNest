import 'dart:math' as math;

import 'package:bhorosha/domain/behaviour/behaviour_sample.dart';
import 'package:bhorosha/domain/behaviour/feature_extractor.dart';
import 'package:bhorosha/domain/behaviour/feature_names.dart';
import 'package:flutter_test/flutter_test.dart';

double f(List<double> v, String name) => v[FeatureNames.indexOf(name)];

StrokePoint sp(
  double x,
  double y,
  int tMs, [
  double pressure = 1.0,
  double size = 0.0,
]) => StrokePoint(tMs: tMs, p: Point2(x, y), pressure: pressure, size: size);

KeyEvent press(
  int down,
  int up,
  Point2 at, [
  double pressure = 1.0,
  double size = 0.0,
]) => KeyEvent(
  downMs: down,
  upMs: up,
  position: at,
  pressure: pressure,
  size: size,
);

/// [horizontalSwipe]'s geometry with one contact size per point.
Stroke sizedSwipe(List<double> sizes) => Stroke([
  for (var i = 0; i < 5; i++) sp(25.0 * i, 0, 25 * i, 1.0, sizes[i]),
]);

/// Four sized strokes with horizontalSwipe's geometry. Per-stroke means
/// 12, 8, 20, 16 and peaks 20, 8, 20, 24:
///   size_mean = median(8, 12, 16, 20) = 14
///   size_max  = median(8, 20, 20, 24) = 20
///   size_iqr  = p75 - p25 = (16*.75 + 20*.25) - (8*.25 + 12*.75) = 17 - 11 = 6
final sizedStrokes = [
  sizedSwipe([10, 10, 10, 10, 20]),
  sizedSwipe([8, 8, 8, 8, 8]),
  sizedSwipe([20, 20, 20, 20, 20]),
  sizedSwipe([14, 14, 14, 14, 24]),
];

/// scriptedPin's timings with distinct positions and sizes for the tap block.
/// xs 0, 100, 200, 500 and ys 0, 0, 400, 400 -> centroid (200, 200).
/// Offsets 200*sqrt2, 100*sqrt5, 200, 100*sqrt13; sorted
/// 200 < 100*sqrt5 < 200*sqrt2 < 100*sqrt13.
/// Sizes 10, 14, 12, 30 -> median 13.
final sizedPin = <KeyEvent>[
  press(1000, 1120, const Point2(0, 0), 0.5, 10),
  press(1300, 1400, const Point2(100, 0), 0.7, 14),
  press(1650, 1800, const Point2(200, 400), 0.6, 12),
  press(2000, 2090, const Point2(500, 400), 0.6, 30),
];
final sqrt5 = math.sqrt(5);
final sqrt13 = math.sqrt(13);
// numpy-linear: p25 at pos 0.75, p75 at pos 2.25 of 4 sorted values.
final sizedPinOffsetMed = (100 * sqrt5 + 200 * math.sqrt2) / 2;
final sizedPinOffsetIqr =
    (200 * math.sqrt2 * 0.75 + 100 * sqrt13 * 0.25) -
    (200 * 0.25 + 100 * sqrt5 * 0.75);

const backspaceAt700 = KeyEvent(
  downMs: 700,
  upMs: 700,
  position: Point2.zero,
  pressure: 0,
  isBackspace: true,
);

/// Four presses on the corners of a 200 px square: holds 120/100/150/90,
/// flights 180/250/200, total 1090, centroid (200, 200), offsets 100*sqrt2
/// (all equal, so median == mean); pressures 0.5/0.7/0.6/0.6 -> median 0.6.
final scriptedPin = <KeyEvent>[
  press(1000, 1120, const Point2(100, 100), 0.5),
  press(1300, 1400, const Point2(300, 100), 0.7),
  press(1650, 1800, const Point2(100, 300), 0.6),
  press(2000, 2090, const Point2(300, 300), 0.6),
];

/// (0,0) -> (100,0) over 100 ms, five evenly spaced points.
final horizontalSwipe = Stroke([
  sp(0, 0, 0),
  sp(25, 0, 25),
  sp(50, 0, 50),
  sp(75, 0, 75),
  sp(100, 0, 100),
]);

void expectAllFinite(List<double> v) {
  expect(v, hasLength(FeatureNames.count));
  for (var i = 0; i < v.length; i++) {
    expect(v[i].isFinite, isTrue, reason: '${FeatureNames.wire[i]} = ${v[i]}');
  }
}

void main() {
  test('empty sample gives exactly 55 zeros', () {
    final v = FeatureExtractor.build(BehaviourSample.empty);
    expect(v, hasLength(55));
    expect(v, everyElement(0.0));
    expect(FeatureExtractor.build(BehaviourSample()), everyElement(0.0));
  });

  group('PIN block', () {
    test('scripted 4-digit entry gives exact holds, flights and total', () {
      final v = FeatureExtractor.build(BehaviourSample(keys: scriptedPin));
      expectAllFinite(v);
      expect(f(v, 'pin_hold_1_ms'), 120);
      expect(f(v, 'pin_hold_2_ms'), 100);
      expect(f(v, 'pin_hold_3_ms'), 150);
      expect(f(v, 'pin_hold_4_ms'), 90);
      expect(f(v, 'pin_flight_1_ms'), 180);
      expect(f(v, 'pin_flight_2_ms'), 250);
      expect(f(v, 'pin_flight_3_ms'), 200);
      expect(f(v, 'pin_total_entry_ms'), 1090);
      expect(f(v, 'pin_backspaces'), 0);
      expect(f(v, 'pin_tap_offset_mean_px'), closeTo(100 * math.sqrt2, 1e-9));
      expect(f(v, 'pin_pressure_mean'), closeTo(0.6, 1e-12));
    });

    test('presses are ordered by touch-down, not by list order', () {
      final shuffled = [
        scriptedPin[2],
        scriptedPin[0],
        scriptedPin[3],
        scriptedPin[1],
      ];
      final v = FeatureExtractor.build(BehaviourSample(keys: shuffled));
      expect(f(v, 'pin_hold_1_ms'), 120);
      expect(f(v, 'pin_flight_3_ms'), 200);
      expect(f(v, 'pin_total_entry_ms'), 1090);
    });

    test('backspaces are a raw count and do not fill digit slots', () {
      final keys = [backspaceAt700, ...scriptedPin, backspaceAt700];
      final v = FeatureExtractor.build(BehaviourSample(keys: keys));
      expect(f(v, 'pin_backspaces'), 2);
      expect(f(v, 'pin_hold_1_ms'), 120);
      expect(f(v, 'pin_total_entry_ms'), 1090);
      // Backspace position/pressure never enter the morphology features.
      expect(f(v, 'pin_tap_offset_mean_px'), closeTo(100 * math.sqrt2, 1e-9));
      expect(f(v, 'pin_pressure_mean'), closeTo(0.6, 1e-12));
    });

    test('fewer than four presses leaves the missing slots at 0.0', () {
      final v = FeatureExtractor.build(
        BehaviourSample(keys: scriptedPin.sublist(0, 2)),
      );
      expectAllFinite(v);
      expect(f(v, 'pin_hold_1_ms'), 120);
      expect(f(v, 'pin_hold_2_ms'), 100);
      expect(f(v, 'pin_hold_3_ms'), 0);
      expect(f(v, 'pin_hold_4_ms'), 0);
      expect(f(v, 'pin_flight_1_ms'), 180);
      expect(f(v, 'pin_flight_2_ms'), 0);
      expect(f(v, 'pin_flight_3_ms'), 0);
      expect(f(v, 'pin_total_entry_ms'), 0);
      expect(f(v, 'pin_tap_offset_mean_px'), 100);
      expect(f(v, 'pin_pressure_mean'), closeTo(0.6, 1e-12));
    });

    test('more than four presses: the first four fill the slots', () {
      final keys = [...scriptedPin, press(2500, 2600, const Point2(200, 200))];
      final v = FeatureExtractor.build(BehaviourSample(keys: keys));
      expect(f(v, 'pin_hold_4_ms'), 90);
      expect(f(v, 'pin_total_entry_ms'), 1090);
    });

    test('tap offset and pressure are medians over presses (features.py)', () {
      // Centroid (100, 0); distances 100, 100, 100, 300 -> median 100,
      // mean 150. Pressures 0.1, 0.2, 0.3, 1.0 -> median 0.25, mean 0.4.
      final keys = [
        press(1000, 1100, const Point2(0, 0), 0.1),
        press(1200, 1300, const Point2(0, 0), 0.2),
        press(1400, 1500, const Point2(0, 0), 0.3),
        press(1600, 1700, const Point2(400, 0), 1.0),
      ];
      final v = FeatureExtractor.build(BehaviourSample(keys: keys));
      expect(f(v, 'pin_tap_offset_mean_px'), closeTo(100, 1e-9));
      expect(f(v, 'pin_pressure_mean'), closeTo(0.25, 1e-12));
    });

    test('only backspaces: nothing measurable but the count', () {
      final v = FeatureExtractor.build(BehaviourSample(keys: [backspaceAt700]));
      expectAllFinite(v);
      expect(f(v, 'pin_backspaces'), 1);
      expect(f(v, 'pin_tap_offset_mean_px'), 0);
      expect(f(v, 'pin_pressure_mean'), 0);
    });
  });

  group('swipe block', () {
    test('straight horizontal swipe', () {
      final v = FeatureExtractor.build(
        BehaviourSample(strokes: [horizontalSwipe]),
      );
      expectAllFinite(v);
      expect(f(v, 'swipe_duration_ms'), 100);
      expect(f(v, 'swipe_start_x'), 0);
      expect(f(v, 'swipe_start_y'), 0);
      expect(f(v, 'swipe_end_x'), 100);
      expect(f(v, 'swipe_end_y'), 0);
      expect(f(v, 'swipe_angle_rad'), 0);
      expect(f(v, 'swipe_length_px'), 100);
      expect(f(v, 'swipe_v_mean'), 1.0);
      expect(f(v, 'swipe_v_p20'), 1.0);
      expect(f(v, 'swipe_v_p50'), 1.0);
      expect(f(v, 'swipe_v_p80'), 1.0);
      expect(f(v, 'swipe_accel_mean'), 0);
    });

    test('diagonal swipe angle is atan2(dy, dx) with y down', () {
      final stroke = Stroke([sp(10, 10, 0), sp(40, 50, 50)]);
      final v = FeatureExtractor.build(BehaviourSample(strokes: [stroke]));
      expectAllFinite(v);
      expect(f(v, 'swipe_angle_rad'), closeTo(math.atan2(40, 30), 1e-12));
      expect(f(v, 'swipe_length_px'), 50);
      expect(f(v, 'swipe_v_mean'), 1.0);
      // One segment: p20/p50/p80 all equal it; acceleration needs two.
      expect(f(v, 'swipe_v_p50'), 1.0);
      expect(f(v, 'swipe_accel_mean'), 0);

      final up = Stroke([sp(0, 100, 0), sp(0, 0, 50)]);
      final vu = FeatureExtractor.build(BehaviourSample(strokes: [up]));
      expect(f(vu, 'swipe_angle_rad'), closeTo(-math.pi / 2, 1e-12));
    });

    test('velocity percentiles interpolate linearly and accel telescopes', () {
      // Segment speeds 1, 2, 3, 4 px/ms, one ms each.
      final stroke = Stroke([
        sp(0, 0, 0),
        sp(1, 0, 1),
        sp(3, 0, 2),
        sp(6, 0, 3),
        sp(10, 0, 4),
      ]);
      final v = FeatureExtractor.build(BehaviourSample(strokes: [stroke]));
      expect(f(v, 'swipe_v_mean'), 2.5);
      expect(f(v, 'swipe_v_p20'), closeTo(1.6, 1e-12));
      expect(f(v, 'swipe_v_p50'), closeTo(2.5, 1e-12));
      expect(f(v, 'swipe_v_p80'), closeTo(3.4, 1e-12));
      // (4 - 1) / (3.5 - 0.5)
      expect(f(v, 'swipe_accel_mean'), closeTo(1.0, 1e-12));
    });

    test('many strokes: median per feature, circular mean for the angle', () {
      final right = horizontalSwipe; // length 100, 100 ms, angle 0
      final down = Stroke([sp(0, 0, 0), sp(0, 200, 100)]); // 200, angle pi/2
      final v = FeatureExtractor.build(BehaviourSample(strokes: [right, down]));
      expect(f(v, 'swipe_length_px'), 150);
      expect(f(v, 'swipe_v_mean'), 1.5);
      expect(f(v, 'swipe_angle_rad'), closeTo(math.pi / 4, 1e-12));

      // A median would also have given 150 here; three strokes show it ignores
      // the outlier.
      final fling = Stroke([sp(0, 0, 0), sp(1500, 0, 100)]);
      final v3 = FeatureExtractor.build(
        BehaviourSample(strokes: [right, down, fling]),
      );
      expect(f(v3, 'swipe_length_px'), 200);
    });

    test('opposite directions cancel to an unmeasurable angle (0.0)', () {
      final right = Stroke([sp(0, 0, 0), sp(100, 0, 10)]);
      final left = Stroke([sp(100, 0, 0), sp(0, 0, 10)]);
      final v = FeatureExtractor.build(BehaviourSample(strokes: [right, left]));
      expectAllFinite(v);
      expect(f(v, 'swipe_angle_rad'), 0);
    });

    test('one-point stroke and zero-duration stroke never produce NaN', () {
      final single = Stroke([sp(40, 60, 0, 0.3)]);
      final v = FeatureExtractor.build(BehaviourSample(strokes: [single]));
      expectAllFinite(v);
      expect(f(v, 'swipe_start_x'), 40);
      expect(f(v, 'swipe_end_y'), 60);
      expect(f(v, 'swipe_duration_ms'), 0);
      expect(f(v, 'swipe_length_px'), 0);
      expect(f(v, 'swipe_v_mean'), 0);
      expect(f(v, 'pressure_mean'), closeTo(0.3, 1e-12));

      final sameInstant = Stroke([sp(0, 0, 5), sp(10, 0, 5)]);
      final vz = FeatureExtractor.build(
        BehaviourSample(strokes: [sameInstant]),
      );
      expectAllFinite(vz);
      expect(f(vz, 'swipe_length_px'), 10);
      expect(f(vz, 'swipe_v_mean'), 0);

      final empty = Stroke(const []);
      expectAllFinite(
        FeatureExtractor.build(BehaviourSample(strokes: [empty])),
      );
    });

    test('a one-point stroke does not vote on the aggregates', () {
      final v = FeatureExtractor.build(
        BehaviourSample(
          strokes: [
            horizontalSwipe,
            Stroke([sp(5, 5, 0)]),
          ],
        ),
      );
      expect(f(v, 'swipe_length_px'), 100);
      expect(f(v, 'swipe_v_mean'), 1.0);
      expect(f(v, 'swipe_start_x'), 2.5);
    });
  });

  group('pressure block', () {
    test('per-stroke mean and max, median across strokes', () {
      final a = Stroke([sp(0, 0, 0, 0.2), sp(1, 0, 1, 0.4), sp(2, 0, 2, 0.9)]);
      final b = Stroke([sp(0, 0, 0, 0.6), sp(1, 0, 1, 0.6)]);
      final c = Stroke([sp(0, 0, 0, 0.1)]);
      final v = FeatureExtractor.build(BehaviourSample(strokes: [a, b, c]));
      expect(f(v, 'pressure_mean'), closeTo(0.5, 1e-12));
      expect(f(v, 'pressure_max'), closeTo(0.6, 1e-12));
    });
  });

  group('size block', () {
    test('median of per-stroke means/peaks, IQR of the means', () {
      final v = FeatureExtractor.build(BehaviourSample(strokes: sizedStrokes));
      expectAllFinite(v);
      expect(f(v, 'size_mean'), closeTo(14, 1e-12));
      expect(f(v, 'size_max'), closeTo(20, 1e-12));
      expect(f(v, 'size_iqr'), closeTo(6, 1e-12));
    });

    test('unsized strokes do not vote; fewer than 4 sized -> IQR 0.0', () {
      final v = FeatureExtractor.build(
        BehaviourSample(
          strokes: [horizontalSwipe, ...sizedStrokes.sublist(0, 3)],
        ),
      );
      // means 12, 8, 20 -> median 12; peaks 20, 8, 20 -> median 20.
      expect(f(v, 'size_mean'), closeTo(12, 1e-12));
      expect(f(v, 'size_max'), closeTo(20, 1e-12));
      expect(f(v, 'size_iqr'), 0);
    });

    test('a zero-size sample inside a stroke is skipped, not averaged', () {
      final v = FeatureExtractor.build(
        BehaviourSample(
          strokes: [
            sizedSwipe([0, 0, 0, 10, 20]),
          ],
        ),
      );
      expect(f(v, 'size_mean'), closeTo(15, 1e-12));
      expect(f(v, 'size_max'), closeTo(20, 1e-12));
    });

    test('PIN press sizes never feed the size block', () {
      final v = FeatureExtractor.build(BehaviourSample(keys: sizedPin));
      expect(f(v, 'size_mean'), 0);
      expect(f(v, 'size_max'), 0);
      expect(f(v, 'size_iqr'), 0);
    });
  });

  group('tap block', () {
    test('placement median/IQR around the mean centroid, size, count', () {
      final v = FeatureExtractor.build(BehaviourSample(keys: sizedPin));
      expectAllFinite(v);
      expect(f(v, 'tap_offset_med'), closeTo(sizedPinOffsetMed, 1e-9));
      expect(f(v, 'tap_offset_iqr'), closeTo(sizedPinOffsetIqr, 1e-9));
      // xs 0,100,200,500: p25 75, p75 275. ys 0,0,400,400: p25 0, p75 400.
      expect(f(v, 'tap_x_iqr'), closeTo(200, 1e-9));
      expect(f(v, 'tap_y_iqr'), closeTo(400, 1e-9));
      expect(f(v, 'tap_size_med'), closeTo(13, 1e-12));
      expect(f(v, 'tap_count'), 4);
      // Same definition as the PIN block's offset (features.py 509 vs 579).
      expect(f(v, 'pin_tap_offset_mean_px'), closeTo(sizedPinOffsetMed, 1e-9));
    });

    test('scripted square: zero offset spread, unsized taps -> size 0.0', () {
      final v = FeatureExtractor.build(BehaviourSample(keys: scriptedPin));
      expect(f(v, 'tap_offset_med'), closeTo(100 * math.sqrt2, 1e-9));
      expect(f(v, 'tap_offset_iqr'), closeTo(0, 1e-9));
      expect(f(v, 'tap_x_iqr'), closeTo(200, 1e-9));
      expect(f(v, 'tap_y_iqr'), closeTo(200, 1e-9));
      expect(f(v, 'tap_size_med'), 0);
      expect(f(v, 'tap_count'), 4);
    });

    test('backspaces are not taps; fewer than 4 taps -> IQRs 0.0', () {
      final keys = [backspaceAt700, ...sizedPin.sublist(0, 3), backspaceAt700];
      final v = FeatureExtractor.build(BehaviourSample(keys: keys));
      expectAllFinite(v);
      expect(f(v, 'tap_count'), 3);
      expect(f(v, 'tap_offset_iqr'), 0);
      expect(f(v, 'tap_x_iqr'), 0);
      expect(f(v, 'tap_y_iqr'), 0);
      // Sizes 10, 14, 12 -> median 12.
      expect(f(v, 'tap_size_med'), closeTo(12, 1e-12));
    });

    test('only backspaces: the whole block, count included, is 0.0', () {
      final v = FeatureExtractor.build(BehaviourSample(keys: [backspaceAt700]));
      for (final name in [
        'tap_offset_med',
        'tap_offset_iqr',
        'tap_x_iqr',
        'tap_y_iqr',
        'tap_size_med',
        'tap_count',
      ]) {
        expect(f(v, name), 0, reason: name);
      }
    });

    test('stroke sizes never feed tap_size_med', () {
      final v = FeatureExtractor.build(BehaviourSample(strokes: sizedStrokes));
      expect(f(v, 'tap_size_med'), 0);
      expect(f(v, 'tap_count'), 0);
    });
  });

  group('IMU block', () {
    const samples = <ImuSample>[
      ImuSample(tMs: 4500, ax: 3, ay: 0, az: 0, gx: 0, gy: 0, gz: 1),
      ImuSample(tMs: 5000, ax: 0, ay: 4, az: 0, gx: 0, gy: 0, gz: 2),
      ImuSample(tMs: 5500, ax: 0, ay: 0, az: 5, gx: 0, gy: 0, gz: 3),
      // Outside ±1000 ms of the press at 5000.
      ImuSample(tMs: 2000, ax: 100, ay: 0, az: 0, gx: 50, gy: 0, gz: 0),
    ];

    test('windowed magnitudes, population std and tilt by hand', () {
      final v = FeatureExtractor.build(
        BehaviourSample(keys: [press(5000, 5100, Point2.zero)], imu: samples),
      );
      expectAllFinite(v);
      // |a| = 3, 4, 5 -> mean 4, population std sqrt(2/3)
      expect(f(v, 'imu_accel_mag_mean'), closeTo(4, 1e-12));
      expect(f(v, 'imu_accel_mag_std'), closeTo(math.sqrt(2 / 3), 1e-12));
      // |g| = 1, 2, 3 -> mean 2, population std sqrt(2/3)
      expect(f(v, 'imu_gyro_mag_mean'), closeTo(2, 1e-12));
      expect(f(v, 'imu_gyro_mag_std'), closeTo(math.sqrt(2 / 3), 1e-12));
      // mean vector (1, 4/3, 5/3): hypot(1, 4/3) = 5/3 -> atan2(5/3, 5/3)
      expect(f(v, 'imu_tilt_dominant_rad'), closeTo(math.pi / 4, 1e-12));
    });

    test('overlapping windows count a sample once', () {
      final v = FeatureExtractor.build(
        BehaviourSample(
          keys: [
            press(4600, 4700, Point2.zero),
            press(5400, 5500, Point2.zero),
          ],
          imu: samples,
        ),
      );
      expect(f(v, 'imu_accel_mag_mean'), closeTo(4, 1e-12));
      expect(f(v, 'imu_accel_mag_std'), closeTo(math.sqrt(2 / 3), 1e-12));
    });

    test('window edges are inclusive', () {
      final v = FeatureExtractor.build(
        BehaviourSample(keys: [press(3000, 3100, Point2.zero)], imu: samples),
      );
      // Only t=2000 (edge) qualifies: |a| = 100, one sample so std is 0.0.
      expect(f(v, 'imu_accel_mag_mean'), 100);
      expect(f(v, 'imu_accel_mag_std'), 0);
      expect(f(v, 'imu_gyro_mag_mean'), 50);
      expect(f(v, 'imu_tilt_dominant_rad'), closeTo(math.pi / 2, 1e-12));
    });

    test('no presses: whole buffer, as features.py with no anchors', () {
      final v = FeatureExtractor.build(BehaviourSample(imu: samples));
      expect(f(v, 'imu_accel_mag_mean'), closeTo((3 + 4 + 5 + 100) / 4, 1e-12));
    });

    test('presses but no samples in range: zeros, no NaN', () {
      final v = FeatureExtractor.build(
        BehaviourSample(keys: [press(90000, 90100, Point2.zero)], imu: samples),
      );
      expectAllFinite(v);
      expect(f(v, 'imu_accel_mag_mean'), 0);
      expect(f(v, 'imu_tilt_dominant_rad'), 0);
    });

    test('flat phone has zero tilt', () {
      const flat = ImuSample(
        tMs: 0,
        ax: 0,
        ay: 0,
        az: 9.81,
        gx: 0,
        gy: 0,
        gz: 0,
      );
      final v = FeatureExtractor.build(BehaviourSample(imu: const [flat]));
      expect(f(v, 'imu_tilt_dominant_rad'), 0);
      expect(f(v, 'imu_accel_mag_mean'), closeTo(9.81, 1e-12));
    });
  });

  test('a full sample fills every block in wire order', () {
    final v = FeatureExtractor.build(
      BehaviourSample(
        keys: sizedPin,
        strokes: sizedStrokes,
        imu: [
          const ImuSample(
            tMs: 1000,
            ax: 0,
            ay: 0,
            az: 9.81,
            gx: 0,
            gy: 0,
            gz: 0.1,
          ),
          const ImuSample(
            tMs: 1500,
            ax: 0,
            ay: 0,
            az: 9.81,
            gx: 0,
            gy: 0,
            gz: 0.1,
          ),
        ],
      ),
    );
    expectAllFinite(v);
    expect(v, hasLength(55));
    // Key-rank block: never measured on the PIN surface, always 0.0.
    expect(v.sublist(39), hasLength(16));
    expect(v.sublist(39), everyElement(0.0));
    // Old 30 slots: same pinned numbers as before the size/tap blocks.
    expect(v[0], 100); // swipe_duration_ms
    expect(v[6], 100); // swipe_length_px
    expect(v[12], 1.0); // pressure_mean
    expect(v[14], 120); // pin_hold_1_ms
    expect(v[21], 1090); // pin_total_entry_ms
    expect(v[22], 0); // pin_backspaces
    expect(v[24], closeTo(0.6, 1e-12)); // pin_pressure_mean
    // New size block (25..27).
    expect(v[25], closeTo(14, 1e-12)); // size_mean
    expect(v[26], closeTo(20, 1e-12)); // size_max
    expect(v[27], closeTo(6, 1e-12)); // size_iqr
    // New tap block (28..33).
    expect(v[28], closeTo(sizedPinOffsetMed, 1e-9)); // tap_offset_med
    expect(v[29], closeTo(sizedPinOffsetIqr, 1e-9)); // tap_offset_iqr
    expect(v[30], closeTo(200, 1e-9)); // tap_x_iqr
    expect(v[31], closeTo(400, 1e-9)); // tap_y_iqr
    expect(v[32], closeTo(13, 1e-12)); // tap_size_med
    expect(v[33], 4); // tap_count
    // IMU block moved from 25..29 to 34..38.
    expect(v[34], closeTo(9.81, 1e-12)); // imu_accel_mag_mean
    expect(v[36], closeTo(0.1, 1e-12)); // imu_gyro_mag_mean
    expect(v[38], 0); // imu_tilt_dominant_rad
  });
}
