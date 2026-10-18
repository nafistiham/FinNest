/// The 55 behaviour features in **wire order**.
///
/// Mirrors `libs/ato/bhorosha_ato/schema.py` `FEATURES`
/// (the size and tap blocks were added later, the retrained model added the 16
/// [keyRank] names; `test/fixtures/ato_schema_names.json` is the server's
/// `artefacts.json` `schema_names`, checked by `schema_contract_test.dart`). The risk-api
/// receives `behaviour.features` as a bare list of floats, so this order is
/// the contract; change it and the trained model lies. The server's
/// `behaviour_hits` ignores any vector whose length is not exactly [count].
abstract final class FeatureNames {
  static const int count = 55;

  static const List<String> wire = [
    // swipe kinematics (12)
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
    // contact pressure (2)
    'pressure_mean',
    'pressure_max',
    // PIN pad keystroke dynamics (11)
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
    // contact area (3)
    'size_mean',
    'size_max',
    'size_iqr',
    // tap geometry (6)
    'tap_offset_med',
    'tap_offset_iqr',
    'tap_x_iqr',
    'tap_y_iqr',
    'tap_size_med',
    'tap_count',
    // motion / grip (5)
    'imu_accel_mag_mean',
    'imu_accel_mag_std',
    'imu_gyro_mag_mean',
    'imu_gyro_mag_std',
    'imu_tilt_dominant_rad',
    // text keystroke ranks (16): never measured on the PIN surface
    ...keyRank,
  ];

  /// The 16 `keyrank_*` names, last on the wire. The app types no text, so
  /// they are always the schema's missing value, 0.0.
  static const List<String> keyRank = [
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

  /// Position of [name] on the wire, or -1.
  static int indexOf(String name) => wire.indexOf(name);
}
