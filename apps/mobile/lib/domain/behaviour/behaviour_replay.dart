/// The behaviour demo replays: the owner's
/// vector changed in exactly one of the blocks the server models. Pure Dart.
///
/// The server splits the 55 features by what they measure
/// (`libs/ato/bhorosha_ato/schema.py`): **morphology** (the hand and the
/// grip: tap offsets, contact pressure and size, swipe geometry, IMU) feeds
/// the identity model, which answers `ATO_BEHAVIOUR_MISMATCH`; **tempo**
/// (holds, flights, dead gaps, backspaces, swipe speed) feeds the coaching
/// model, which answers `COACHING_SUSPECTED`. Each replay below touches one
/// of those blocks and leaves every other feature exactly as it was.
library;

import 'package:bhorosha/domain/behaviour/feature_names.dart';

abstract final class BehaviourReplay {
  // --- Tap pattern (morphology) ----------------------------------------------

  /// Taps land three times further from the key centres, and spread wider.
  static const double tapOffsetFactor = 3;

  /// A lighter, smaller fingertip.
  static const double contactFactor = 0.6;

  /// Distance from the key centre and the spread of the tap positions.
  static const List<String> tapOffsetNames = [
    'pin_tap_offset_mean_px',
    'tap_offset_med',
    'tap_offset_iqr',
    'tap_x_iqr',
    'tap_y_iqr',
  ];

  /// Contact pressure and size (morphology only: `pressure_max` is a tempo
  /// feature on the server and stays).
  static const List<String> contactNames = [
    'pressure_mean',
    'pin_pressure_mean',
    'size_mean',
    'size_max',
    'size_iqr',
    'tap_size_med',
  ];

  // --- Shaking hand, unusual grip (morphology) --------------------------------

  /// A shakier hand: the IMU spread ×4.
  static const double imuStdFactor = 4;

  /// The phone held differently: more acceleration on average (m/s²) ...
  static const double imuAccelMeanShift = 1.5;

  /// ... and tilted at another angle (rad).
  static const double imuTiltShift = 0.6;

  /// The IMU spread.
  static const List<String> imuStdNames = [
    'imu_accel_mag_std',
    'imu_gyro_mag_std',
  ];

  /// Every feature [shaking] changes.
  static const List<String> imuNames = [
    ...imuStdNames,
    'imu_accel_mag_mean',
    'imu_tilt_dominant_rad',
  ];

  // --- Coached (tempo, mirrors `synth.coach`) ---------------------------------

  /// Each digit pressed longer.
  static const double holdFactor = 2.0;

  /// Longer pauses between digits.
  static const double flightFactor = 2.2;

  /// The whole entry: stretched, plus dead time waiting for instructions.
  static const double entryFactor = 2.2;

  /// The dead gaps added to the entry time (ms).
  static const double deadGapMs = 8000;

  /// Backspaces added (a digit typed wrong and corrected).
  static const double extraBackspaces = 2;

  /// A slower swipe.
  static const double swipeDurationFactor = 1.8;

  /// Swipe velocity and acceleration drop.
  static const double swipeSpeedFactor = 0.55;

  static const List<String> holdNames = [
    'pin_hold_1_ms',
    'pin_hold_2_ms',
    'pin_hold_3_ms',
    'pin_hold_4_ms',
  ];

  static const List<String> flightNames = [
    'pin_flight_1_ms',
    'pin_flight_2_ms',
    'pin_flight_3_ms',
  ];

  static const List<String> swipeSpeedNames = [
    'swipe_v_mean',
    'swipe_v_p20',
    'swipe_v_p50',
    'swipe_v_p80',
    'swipe_accel_mean',
  ];

  /// Every feature [coached] changes.
  static const List<String> coachedNames = [
    ...holdNames,
    ...flightNames,
    'pin_total_entry_ms',
    'pin_backspaces',
    'swipe_duration_ms',
    ...swipeSpeedNames,
  ];

  // --- Replays ----------------------------------------------------------------

  /// "ট্যাপের ধরন বদলে গেছে": [tapOffsetNames] × [tapOffsetFactor] and
  /// [contactNames] × [contactFactor]; nothing else. A new list.
  static List<double> tapPattern(List<double> base) {
    final out = _copy(base);
    _scale(out, tapOffsetNames, tapOffsetFactor);
    _scale(out, contactNames, contactFactor);
    return out;
  }

  /// "হাত কাঁপছে, ফোন অন্যভাবে ধরা": [imuStdNames] × [imuStdFactor],
  /// `imu_accel_mag_mean` + [imuAccelMeanShift] and `imu_tilt_dominant_rad`
  /// + [imuTiltShift]; nothing else. A missing reading (0.0) stays missing.
  /// A new list.
  static List<double> shaking(List<double> base) {
    final out = _copy(base);
    _scale(out, imuStdNames, imuStdFactor);
    _shift(out, 'imu_accel_mag_mean', imuAccelMeanShift);
    _shift(out, 'imu_tilt_dominant_rad', imuTiltShift);
    return out;
  }

  /// "অন্য কেউ ফোন চালাচ্ছে": a stranger's hand, i.e. [tapPattern] and
  /// [shaking] together. A new list.
  static List<double> stranger(List<double> base) => shaking(tapPattern(base));

  /// "কেউ বলে দিচ্ছে": the owner's own hand, slowed and hesitant
  /// (`synth.coach`): holds × [holdFactor], flights × [flightFactor], entry
  /// × [entryFactor] + [deadGapMs], backspaces + [extraBackspaces], swipe
  /// duration × [swipeDurationFactor], swipe speed × [swipeSpeedFactor].
  /// The morphology (tap, pressure, size, IMU) is untouched. A new list.
  static List<double> coached(List<double> base) {
    final out = _copy(base);
    _scale(out, holdNames, holdFactor);
    _scale(out, flightNames, flightFactor);
    _scale(out, const ['pin_total_entry_ms'], entryFactor);
    _shift(out, 'pin_total_entry_ms', deadGapMs);
    _shift(out, 'pin_backspaces', extraBackspaces, always: true);
    _scale(out, const ['swipe_duration_ms'], swipeDurationFactor);
    _scale(out, swipeSpeedNames, swipeSpeedFactor);
    return out;
  }

  static List<double> _copy(List<double> base) {
    if (base.length != FeatureNames.count) {
      throw ArgumentError.value(
        base.length,
        'base.length',
        'expected ${FeatureNames.count} features',
      );
    }
    return List<double>.of(base);
  }

  static void _scale(List<double> out, List<String> names, double factor) {
    for (final n in names) {
      final i = FeatureNames.indexOf(n);
      out[i] = out[i] * factor;
    }
  }

  /// Adds [by] to [name]; a missing reading (the schema's 0.0) stays
  /// missing unless [always] (a count such as backspaces, where 0 is real).
  static void _shift(
    List<double> out,
    String name,
    double by, {
    bool always = false,
  }) {
    final i = FeatureNames.indexOf(name);
    if (out[i] == 0 && !always) return;
    out[i] = out[i] + by;
  }
}
