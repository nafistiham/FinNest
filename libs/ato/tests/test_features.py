"""Hand-built strokes with arithmetic that can be checked on paper.

Every number asserted here is derived by hand in the test, not copied from a run. A feature
extractor is the one place in the pipeline where a wrong answer still looks completely normal:
there is no exception, no NaN, no shape mismatch - just a plausible EER computed from the wrong
quantity. So the tests are deliberately about units, about absent-versus-zero, and about the
degenerate strokes a real digitiser produces every day (taps, dropped samples, repeated
timestamps) rather than about end-to-end plumbing.
"""

from __future__ import annotations

import math

import pytest

from bhorosha_ato import features, schema
from bhorosha_ato.features import Granularity


def event(x: float, y: float, t_ms: float, pressure: float | None = None) -> dict:
    e = {"x": x, "y": y, "t_ms": t_ms}
    if pressure is not None:
        e["pressure"] = pressure
    return e


# A straight rightward swipe: 100 px in 100 ms, sampled every 20 ms at a constant 1 px/ms.
# Chosen so velocity, duration and length are all exact in binary floating point.
STRAIGHT = [event(100.0 + 20.0 * i, 200.0, 1000.0 + 20.0 * i) for i in range(6)]


# --- the straight swipe, every number by hand ------------------------------


def test_straight_swipe_has_the_velocity_and_angle_we_can_compute_by_hand():
    row = features.swipe_features([STRAIGHT])

    assert row["swipe_duration_ms"] == 100.0           # 1100 - 1000
    assert row["swipe_start_x"] == 100.0
    assert row["swipe_start_y"] == 200.0
    assert row["swipe_end_x"] == 200.0                 # 100 + 5 * 20
    assert row["swipe_end_y"] == 200.0
    assert row["swipe_length_px"] == 100.0             # 5 segments of 20 px
    assert row["swipe_v_mean"] == pytest.approx(1.0)   # 100 px / 100 ms, in px/ms
    assert row["swipe_v_p20"] == pytest.approx(1.0)    # every segment is 20 px / 20 ms
    assert row["swipe_v_p50"] == pytest.approx(1.0)
    assert row["swipe_v_p80"] == pytest.approx(1.0)
    assert row["swipe_accel_mean"] == pytest.approx(0.0)  # constant speed


def test_units_are_milliseconds_and_pixels_per_millisecond_not_seconds():
    """The same geometry over a 10x longer time must be 10x slower, not 1000x.

    A seconds-for-milliseconds slip is invisible downstream, so pin it here: the only thing
    that distinguishes px/ms from px/s is the ratio between two runs.
    """
    slow = [event(100.0 + 20.0 * i, 200.0, 1000.0 + 200.0 * i) for i in range(6)]
    fast = features.swipe_features([STRAIGHT])
    slower = features.swipe_features([slow])

    assert slower["swipe_duration_ms"] == 1000.0
    assert slower["swipe_v_mean"] == pytest.approx(fast["swipe_v_mean"] / 10.0)
    assert slower["swipe_v_mean"] == pytest.approx(0.1)


def test_angle_uses_atan2_over_all_four_quadrants():
    """Four strokes of the same length in four directions, from one origin.

    Screen coordinates, so y grows downward: an upward swipe is negative. A quadrant-blind
    arctan would collapse right/left and up/down onto the same two answers.
    """
    origin = (300.0, 400.0)
    cases = {
        (+100.0, 0.0): 0.0,                # right
        (0.0, +100.0): math.pi / 2,        # down the screen
        (-100.0, 0.0): math.pi,            # left
        (0.0, -100.0): -math.pi / 2,       # up the screen
    }
    for (dx, dy), expected in cases.items():
        stroke = [
            event(origin[0], origin[1], 0.0),
            event(origin[0] + dx / 2, origin[1] + dy / 2, 50.0),
            event(origin[0] + dx, origin[1] + dy, 100.0),
        ]
        angle = features.swipe_features([stroke])["swipe_angle_rad"]
        assert angle == pytest.approx(expected), (dx, dy)
        assert -math.pi <= angle <= math.pi


def test_a_diagonal_swipe_has_the_pythagorean_length():
    stroke = [event(0.0, 0.0, 0.0), event(30.0, 40.0, 50.0)]
    row = features.swipe_features([stroke])
    assert row["swipe_length_px"] == pytest.approx(50.0)       # 3-4-5
    assert row["swipe_v_mean"] == pytest.approx(1.0)           # 50 px / 50 ms
    assert row["swipe_angle_rad"] == pytest.approx(math.atan2(40.0, 30.0))


def test_acceleration_is_px_per_ms_squared_from_a_known_speed_up():
    """Three samples: 10 px in 10 ms then 30 px in 10 ms, so 1 -> 3 px/ms.

    Segment midpoints are at t=5 and t=15, so the time-weighted mean acceleration is
    (3 - 1) / (15 - 5) = 0.2 px/ms2.
    """
    stroke = [event(0.0, 0.0, 0.0), event(10.0, 0.0, 10.0), event(40.0, 0.0, 20.0)]
    row = features.swipe_features([stroke])
    assert row["swipe_v_p20"] == pytest.approx(1.4)   # p20 of [1.0, 3.0] interpolated
    assert row["swipe_v_p80"] == pytest.approx(2.6)
    assert row["swipe_accel_mean"] == pytest.approx(0.2)


def test_velocity_percentiles_order_and_interpolate():
    """Four segments at 1, 2, 3, 4 px/ms over 10 ms each, so the percentiles are checkable."""
    xs = [0.0, 10.0, 30.0, 60.0, 100.0]
    stroke = [event(x, 0.0, 10.0 * i) for i, x in enumerate(xs)]
    row = features.swipe_features([stroke])
    # linear interpolation over [1,2,3,4]: p20 -> 1.6, p50 -> 2.5, p80 -> 3.4
    assert row["swipe_v_p20"] == pytest.approx(1.6)
    assert row["swipe_v_p50"] == pytest.approx(2.5)
    assert row["swipe_v_p80"] == pytest.approx(3.4)
    assert row["swipe_v_p20"] < row["swipe_v_p50"] < row["swipe_v_p80"]
    assert row["swipe_v_mean"] == pytest.approx(100.0 / 40.0)  # path / duration, not mean of v


# --- the degenerate strokes a real digitiser produces ----------------------


def test_a_tap_has_a_real_duration_and_a_truly_zero_velocity_but_no_direction():
    """A tap is not missing data - it is a measured zero, except for its direction.

    Three samples at the same point over 80 ms: the path length really is 0 px and the speed
    really is 0 px/ms. The direction, though, does not exist, and atan2(0, 0) would report
    0.0 rad - a confident "rightward" that would pollute the owner's angle profile.
    """
    tap = [event(150.0, 600.0, t) for t in (0.0, 40.0, 80.0)]
    row = features.swipe_features([tap])

    assert row["swipe_duration_ms"] == 80.0
    assert row["swipe_length_px"] == 0.0
    assert row["swipe_v_mean"] == 0.0
    assert row["swipe_v_p50"] == 0.0
    assert row["swipe_accel_mean"] == 0.0
    assert row["swipe_start_x"] == 150.0 and row["swipe_end_x"] == 150.0
    assert row["swipe_angle_rad"] == schema.FEATURES[schema.INDEX["swipe_angle_rad"]].missing


def test_a_single_event_stroke_yields_a_position_but_no_span_or_rate():
    """One sample is where the finger landed, and nothing else.

    Reporting 0 ms / 0 px for a clipped stroke would drag the session median towards zero every
    time the digitiser drops samples, which is a feature that tracks the hardware, not the user.
    """
    row = features.swipe_features([[event(42.0, 99.0, 500.0)]])

    assert row["swipe_start_x"] == 42.0
    assert row["swipe_start_y"] == 99.0
    assert row["swipe_end_x"] == 42.0
    assert row["swipe_end_y"] == 99.0
    for name in ("swipe_duration_ms", "swipe_length_px", "swipe_v_mean", "swipe_v_p20",
                 "swipe_v_p50", "swipe_v_p80", "swipe_accel_mean", "swipe_angle_rad"):
        assert row[name] == schema.FEATURES[schema.INDEX[name]].missing, name


def test_an_empty_stroke_list_is_all_missing_and_never_raises():
    row = features.swipe_features([])
    assert set(row) == set(schema.names_for(block="swipe"))
    for name, value in row.items():
        assert value == schema.FEATURES[schema.INDEX[name]].missing, name


def test_duplicate_timestamps_do_not_divide_by_zero():
    """Every sample at t = 7: a batched or clock-truncated export.

    Displacement is real, duration is a genuine 0 ms span, and no rate can be derived from it.
    Path length still counts the movement - the finger did move - but velocity must be missing
    rather than an infinity or a zero.
    """
    stroke = [event(0.0, 0.0, 7.0), event(10.0, 0.0, 7.0), event(30.0, 0.0, 7.0)]
    row = features.swipe_features([stroke])

    assert row["swipe_duration_ms"] == 0.0
    assert row["swipe_length_px"] == 30.0
    assert row["swipe_angle_rad"] == pytest.approx(0.0)  # measured: a rightward displacement
    for name in ("swipe_v_mean", "swipe_v_p20", "swipe_v_p50", "swipe_v_p80",
                 "swipe_accel_mean"):
        assert row[name] == schema.FEATURES[schema.INDEX[name]].missing, name
        assert math.isfinite(row[name])


def test_one_repeated_timestamp_mid_stroke_is_skipped_not_fatal():
    """A duplicated sample in the middle still leaves two usable segments.

    Segments: 10 px/10 ms, then 20 px/0 ms (unusable), then 30 px/10 ms. Path length is the
    full 60 px and the duration the full 20 ms, so v_mean is 3.0 px/ms, while the percentiles
    see only the two measurable rates, 1.0 and 3.0.
    """
    stroke = [
        event(0.0, 0.0, 0.0),
        event(10.0, 0.0, 10.0),
        event(30.0, 0.0, 10.0),
        event(60.0, 0.0, 20.0),
    ]
    row = features.swipe_features([stroke])
    assert row["swipe_length_px"] == 60.0
    assert row["swipe_duration_ms"] == 20.0
    assert row["swipe_v_mean"] == pytest.approx(3.0)
    assert row["swipe_v_p50"] == pytest.approx(2.0)   # median of [1.0, 3.0]


def test_a_loop_back_to_the_start_has_length_but_no_direction():
    stroke = [event(0.0, 0.0, 0.0), event(50.0, 0.0, 50.0), event(0.0, 0.0, 100.0)]
    row = features.swipe_features([stroke])
    assert row["swipe_length_px"] == 100.0
    assert row["swipe_angle_rad"] == schema.FEATURES[schema.INDEX["swipe_angle_rad"]].missing


def test_a_malformed_event_raises_instead_of_landing_at_the_screen_corner():
    with pytest.raises(KeyError):
        features.swipe_features([[{"x": 1.0, "t_ms": 0.0}, {"x": 2.0, "t_ms": 1.0}]])


# --- aggregation across strokes --------------------------------------------


def test_the_session_aggregate_is_the_median_so_one_fling_cannot_move_it():
    """Three ordinary 100 px swipes and one 1500 px fling.

    The median length stays at 100; a mean would read 450 px and describe nobody.
    """
    ordinary = [[event(0.0, 0.0, 0.0), event(100.0, 0.0, 100.0)] for _ in range(3)]
    fling = [event(0.0, 0.0, 0.0), event(1500.0, 0.0, 100.0)]
    row = features.swipe_features([*ordinary, fling])
    assert row["swipe_length_px"] == 100.0
    assert row["swipe_v_mean"] == pytest.approx(1.0)


def test_strokes_that_cannot_supply_a_feature_do_not_vote_on_it():
    """A clipped single-sample stroke must not pull the session duration down.

    It carries no duration at all, so the median is taken over the strokes that do - otherwise
    the feature would drift with the dropped-sample rate of the handset.
    """
    good = [[event(0.0, 0.0, 0.0), event(100.0, 0.0, 100.0)] for _ in range(2)]
    clipped = [event(0.0, 0.0, 0.0)]
    row = features.swipe_features([*good, clipped])
    assert row["swipe_duration_ms"] == 100.0
    assert row["swipe_v_mean"] == pytest.approx(1.0)


def test_the_session_angle_does_not_fall_into_the_plus_minus_pi_seam():
    """Two near-identical leftward swipes recorded at +3.10 and -3.10 rad.

    Their median is 0.0 - rightward, the exact opposite. The circular mean lands next to pi,
    where both strokes actually were.
    """
    def leftish(dy: float) -> list[dict]:
        # dx strongly negative, dy tiny: angle sits just either side of +/- pi.
        return [event(500.0, 500.0, 0.0), event(400.0, 500.0 + dy, 100.0)]

    row = features.swipe_features([leftish(+4.0), leftish(-4.0)])
    assert abs(row["swipe_angle_rad"]) == pytest.approx(math.pi, abs=1e-6)


def test_cancelling_directions_report_missing_rather_than_rightward():
    up = [event(0.0, 100.0, 0.0), event(0.0, 0.0, 100.0)]
    down = [event(0.0, 0.0, 0.0), event(0.0, 100.0, 100.0)]
    row = features.swipe_features([up, down])
    assert row["swipe_angle_rad"] == schema.FEATURES[schema.INDEX["swipe_angle_rad"]].missing


# --- pressure block --------------------------------------------------------


def test_pressure_is_the_median_of_the_per_stroke_mean_and_peak():
    """Two strokes, each with hand-checkable pressure samples.

    Stroke A: 0.4, 0.6 -> mean 0.5, peak 0.6. Stroke B: 0.5, 0.9 -> mean 0.7, peak 0.9.
    Medians of two values are their midpoints: 0.6 and 0.75.
    """
    a = [event(0.0, 0.0, 0.0, 0.4), event(10.0, 0.0, 10.0, 0.6)]
    b = [event(0.0, 0.0, 0.0, 0.5), event(10.0, 0.0, 10.0, 0.9)]
    row = features.pressure_features([a, b])
    assert row["pressure_mean"] == pytest.approx(0.6)
    assert row["pressure_max"] == pytest.approx(0.75)


def test_a_session_peak_spike_cannot_define_pressure_max():
    """One stroke spikes to 1.0; the typical per-stroke peak is 0.6.

    A max over the whole session would report 1.0 and would creep upward with session length.
    """
    normal = [[event(0.0, 0.0, 0.0, 0.5), event(10.0, 0.0, 10.0, 0.6)] for _ in range(4)]
    spike = [event(0.0, 0.0, 0.0, 0.5), event(10.0, 0.0, 10.0, 1.0)]
    row = features.pressure_features([*normal, spike])
    assert row["pressure_max"] == pytest.approx(0.6)


def test_geometry_without_pressure_is_missing_not_zero_pressure():
    """A dataset with no pressure column must not teach the model she presses with zero force."""
    row = features.pressure_features([STRAIGHT])
    for name in schema.names_for(block="pressure"):
        assert row[name] == schema.FEATURES[schema.INDEX[name]].missing, name


def test_partially_recorded_pressure_uses_the_samples_that_exist():
    stroke = [event(0.0, 0.0, 0.0), event(10.0, 0.0, 10.0, 0.8), event(20.0, 0.0, 20.0)]
    row = features.pressure_features([stroke])
    assert row["pressure_mean"] == pytest.approx(0.8)
    assert row["pressure_max"] == pytest.approx(0.8)


def test_the_swipe_block_ignores_pressure_and_the_pressure_block_ignores_geometry():
    """The split exists so one absent signal cannot take the other down with it."""
    with_pressure = [event(x, 0.0, 10.0 * i, 0.5) for i, x in enumerate((0.0, 50.0, 100.0))]
    without = [event(x, 0.0, 10.0 * i) for i, x in enumerate((0.0, 50.0, 100.0))]
    assert features.swipe_features([with_pressure]) == features.swipe_features([without])


# --- assembly and granularity ----------------------------------------------


def test_session_row_is_always_schema_length_whatever_the_caller_has():
    swipe = features.swipe_features([STRAIGHT])
    assert len(features.session_row()) == len(schema.FEATURES)
    assert len(features.session_row(swipe=swipe)) == len(schema.FEATURES)
    assert len(features.session_row(swipe=swipe, pressure=features.pressure_features([]))) == len(schema.FEATURES)


def test_session_row_puts_every_value_in_its_schema_slot():
    swipe = features.swipe_features([STRAIGHT])
    row = features.session_row(swipe=swipe)
    for name, value in swipe.items():
        assert row[schema.INDEX[name]] == value, name
    # And the round trip through the schema agrees, so order came from to_vector.
    assert schema.from_vector(row)["swipe_v_mean"] == pytest.approx(1.0)


def test_absent_blocks_land_on_the_declared_missing_value_not_a_stray_zero():
    """Checked against each Feature's own `missing`, not against the literal 0.0.

    Every `missing` happens to be 0.0 today. Asserting 0.0 would pass by coincidence and keep
    passing if the schema changed one of them, which is exactly the drift this guards.
    """
    row = features.session_row(swipe=features.swipe_features([STRAIGHT]))
    for feature in schema.FEATURES:
        if feature.block in ("pin", "imu"):
            assert row[schema.INDEX[feature.name]] == feature.missing, feature.name


def test_a_block_handed_in_under_the_wrong_keyword_is_rejected():
    """to_vector accepts any valid feature name, so only this check catches the swap."""
    with pytest.raises(KeyError):
        features.session_row(pin=features.pressure_features([STRAIGHT]))


def test_both_granularities_return_full_length_vectors():
    strokes = [STRAIGHT, [event(0.0, 0.0, 0.0), event(0.0, 60.0, 30.0)], [event(5.0, 5.0, 0.0)]]

    per_session = features.touch_rows(strokes, Granularity.PER_SESSION)
    per_stroke = features.touch_rows(strokes, Granularity.PER_STROKE)

    assert len(per_session) == 1
    assert len(per_stroke) == len(strokes)
    for row in (*per_session, *per_stroke):
        assert len(row) == len(schema.FEATURES)
        assert all(math.isfinite(v) for v in row)


def test_per_stroke_rows_still_fill_the_unavailable_blocks_with_missing():
    rows = features.touch_rows([STRAIGHT, STRAIGHT], Granularity.PER_STROKE)
    for row in rows:
        for feature in schema.FEATURES:
            if feature.block in ("pin", "imu"):
                assert row[schema.INDEX[feature.name]] == feature.missing, feature.name


def test_a_per_stroke_row_equals_a_one_stroke_session_row():
    """The two granularities must share one definition of every feature, not drift apart."""
    stroke = [event(0.0, 0.0, 0.0), event(30.0, 40.0, 50.0, 0.7)]
    assert features.touch_rows([stroke], Granularity.PER_STROKE) == features.touch_rows(
        [stroke], Granularity.PER_SESSION
    )


def test_the_default_granularity_is_one_row_per_session():
    """model.py and the eval score one row per session, so that is the safe default."""
    assert features.touch_rows([STRAIGHT, STRAIGHT]) == features.touch_rows(
        [STRAIGHT, STRAIGHT], Granularity.PER_SESSION
    )
    assert len(features.touch_rows([STRAIGHT, STRAIGHT])) == 1


def test_granularity_is_a_named_enum_that_survives_a_config_round_trip():
    assert Granularity("per_stroke") is Granularity.PER_STROKE
    assert Granularity.PER_SESSION.value == "per_session"


# --- the blocks that are honestly not written yet --------------------------



def test_every_name_this_module_emits_exists_in_the_schema():
    """No feature name is invented here; the schema is the only source of truth for them."""
    emitted = set(features.swipe_features([STRAIGHT])) | set(features.pressure_features([]))
    assert emitted <= set(schema.NAMES)
    assert emitted == set(schema.names_for(block="swipe")) | set(
        schema.names_for(block="pressure")
    )


def test_the_touch_blocks_cover_exactly_fourteen_of_the_thirty_features():
    assert len(features.swipe_features([])) == 12
    assert len(features.pressure_features([])) == 2


def test_unmeasurable_is_routed_through_the_declared_missing_not_a_hardcoded_zero(monkeypatch):
    """Every `missing` in the schema is 0.0 today, so the assertions above cannot tell a
    declared stand-in from a stray zero. Swap the declared values for a sentinel and the
    difference becomes visible: a single-sample stroke must report the sentinel.

    This is the test that would fail if someone replaced `None` with `0.0` inside the extractor
    for convenience - which is the mistake that teaches the owner model she swipes at zero
    velocity.
    """
    sentinel = -999.0
    monkeypatch.setattr(
        features, "MISSING", {name: sentinel for name in schema.NAMES}, raising=True
    )
    row = features.swipe_features([[event(42.0, 99.0, 500.0)]])

    assert row["swipe_start_x"] == 42.0            # measured, so untouched
    assert row["swipe_duration_ms"] == sentinel    # unmeasurable, so the declared stand-in
    assert row["swipe_v_mean"] == sentinel
    assert features.pressure_features([STRAIGHT])["pressure_mean"] == sentinel


def test_no_strokes_at_all_produces_no_per_stroke_rows_and_one_session_row():
    """An empty session is not an error: the session row is all-missing, 30 long."""
    assert features.touch_rows([], Granularity.PER_STROKE) == []
    rows = features.touch_rows([], Granularity.PER_SESSION)
    assert len(rows) == 1 and len(rows[0]) == len(schema.FEATURES)
    assert rows[0] == tuple(f.missing for f in schema.FEATURES)


# --- PIN / typing block ----------------------------------------------------
#
# These replace the stub guard that used to assert pin_features and imu_features raised.
# The layout is known now, so the thing worth guarding is the arithmetic.

def _key(t: float, press: int, key: int) -> dict:
    return {"PressTime": str(t), "PressType": str(press), "KeyID": str(key)}


def test_hold_times_are_up_minus_down_per_key():
    holds, flights, spans = features._keystrokes([
        _key(100, 0, 65), _key(190, 1, 65),      # hold 90
        _key(300, 0, 66), _key(410, 1, 66),      # hold 110, flight 300-190=110
    ])
    assert holds == [90.0, 110.0]
    assert flights == [110.0]
    assert spans == []          # fewer than PIN_LENGTH keystrokes


def test_four_key_span_is_the_pin_analogue():
    events = []
    for i in range(5):
        events += [_key(1000 * i, 0, 65 + i), _key(1000 * i + 100, 1, 65 + i)]
    _, _, spans = features._keystrokes(events)
    # first span: key0 down at 0 -> key3 up at 3100
    assert spans[0] == 3100.0
    assert len(spans) == 2


def test_non_key_touches_are_excluded():
    """KeyID -1 is the suggestion strip or the text area, not a keystroke."""
    holds, _, _ = features._keystrokes([
        _key(100, 0, -1), _key(190, 1, -1),
        _key(300, 0, 70), _key(360, 1, 70),
    ])
    assert holds == [60.0]


def test_rows_are_sorted_before_pairing():
    """The archive orders rows by Systime, and the relative timestamps are not monotonic -
    an unsorted pairing can produce a negative hold and poison the whole distribution."""
    holds, _, _ = features._keystrokes([
        _key(190, 1, 65), _key(100, 0, 65),      # arrives up-then-down
    ])
    assert holds == [90.0]


def test_backspaces_are_rated_per_hundred_keystrokes():
    """A count would just measure session length."""
    events = []
    for i in range(10):
        events += [_key(100 * i, 0, 65), _key(100 * i + 50, 1, 65)]
    events += [_key(5000, 0, 67), _key(5050, 1, 67)]      # one KEYCODE_DEL
    row = features.pin_features(events)
    assert row["pin_backspaces"] == pytest.approx(100.0 / 11, abs=0.5)


def test_tap_offset_is_distance_from_the_session_centroid():
    """Not from a key centre: the archive ships no keyboard layout."""
    taps = [{"X": "0", "Y": "0", "Pressure": "0.4"},
            {"X": "10", "Y": "0", "Pressure": "0.6"}]
    row = features.pin_features([], taps=taps)
    assert row["pin_tap_offset_mean_px"] == pytest.approx(5.0)
    assert row["pin_pressure_mean"] == pytest.approx(0.5)


def test_no_keystrokes_leaves_the_block_missing_not_zero():
    row = features.pin_features([], taps=[])
    assert row["pin_hold_1_ms"] == features.MISSING["pin_hold_1_ms"]


# --- IMU block -------------------------------------------------------------

def _imu(t: float, x: float, y: float, z: float) -> dict:
    return {"EventTime": str(t), "X": str(x), "Y": str(y), "Z": str(z)}


def test_magnitude_is_the_vector_norm():
    row = features.imu_features([_imu(0, 3, 4, 0)], gyro=[], anchors=[])
    assert row["imu_accel_mag_mean"] == pytest.approx(5.0)


def test_a_flat_phone_has_zero_tilt_and_an_edge_on_phone_has_a_right_angle():
    flat = features.imu_features([_imu(0, 0, 0, 9.81)], [], [])
    edge = features.imu_features([_imu(0, 9.81, 0, 0)], [], [])
    assert flat["imu_tilt_dominant_rad"] == pytest.approx(0.0)
    assert edge["imu_tilt_dominant_rad"] == pytest.approx(math.pi / 2)


def test_windows_exclude_samples_away_from_the_touches():
    """Walking sessions are otherwise dominated by gait rather than grip."""
    rows = [_imu(0, 3, 4, 0), _imu(60_000, 30, 40, 0)]      # second sample a minute later
    windowed = features.imu_features(rows, [], anchors=[0.0])
    whole = features.imu_features(rows, [], anchors=[])
    assert windowed["imu_accel_mag_mean"] == pytest.approx(5.0)
    assert whole["imu_accel_mag_mean"] == pytest.approx(27.5)


def test_one_sample_has_a_mean_but_no_deviation():
    row = features.imu_features([_imu(0, 3, 4, 0)], [], [])
    assert row["imu_accel_mag_mean"] == pytest.approx(5.0)
    assert row["imu_accel_mag_std"] == features.MISSING["imu_accel_mag_std"]


# --- contact size block ----------------------------------------------------
#
# The block that silently came back empty once. The standalone extractor parsed Contact_size
# into every row and then dropped it while building the sample, so `size_features` had nothing
# to read and all three columns were substituted zeros - with no error anywhere. These tests are
# shaped around that failure: they assert real numbers, and they assert the absent case reports
# the declared stand-in rather than a zero area.


def sized(x: float, y: float, t_ms: float, size: float | None) -> dict:
    e = {"x": x, "y": y, "t_ms": t_ms}
    if size is not None:
        e["size"] = size
    return e


# Four strokes whose per-stroke means are 0.2, 0.4, 0.6, 0.8 - four because an IQR below
# MIN_IQR_SAMPLES is an artefact of the interpolation rather than a spread.
SIZED_STROKES = [
    [sized(0.0, 0.0, 0.0, 0.1), sized(10.0, 0.0, 10.0, 0.3)],   # mean 0.2, peak 0.3
    [sized(0.0, 0.0, 0.0, 0.4)],                                 # mean 0.4, peak 0.4
    [sized(0.0, 0.0, 0.0, 0.6)],
    [sized(0.0, 0.0, 0.0, 0.8)],
]


def test_size_is_the_median_of_the_per_stroke_mean_and_peak():
    row = features.size_features(SIZED_STROKES)
    # per-stroke means 0.2 0.4 0.6 0.8 -> median 0.5; peaks 0.3 0.4 0.6 0.8 -> median 0.5
    assert row["size_mean"] == pytest.approx(0.5)
    assert row["size_max"] == pytest.approx(0.5)


def test_size_iqr_is_the_interquartile_range_of_the_per_stroke_means():
    """By hand, numpy's default interpolation over 0.2 0.4 0.6 0.8:
    p75 = 0.6 + 0.25*(0.8-0.6) = 0.65, p25 = 0.2 + 0.75*(0.4-0.2) = 0.35, so 0.30."""
    assert features.size_features(SIZED_STROKES)["size_iqr"] == pytest.approx(0.30)


def test_size_iqr_needs_enough_strokes_to_be_a_spread_at_all():
    """Three strokes do not have quartiles, they have an interpolation artefact."""
    row = features.size_features(SIZED_STROKES[:3])
    assert row["size_mean"] == pytest.approx(0.4)                 # still measurable
    assert row["size_iqr"] == features.MISSING["size_iqr"]


def test_a_spread_of_zero_is_a_measurement_not_a_gap():
    """Four identical strokes genuinely have no spread, which is different from no data."""
    same = [[sized(0.0, 0.0, 0.0, 0.5)] for _ in range(4)]
    assert features.size_features(same)["size_iqr"] == 0.0


def test_geometry_without_contact_size_is_missing_not_a_zero_area_touch():
    """The whole-block version of the bug: samples built without their size.

    A zero contact area would teach the owner model that she sometimes touches the glass with no
    finger at all, and then every real device would look like an impostor.
    """
    row = features.size_features([STRAIGHT, STRAIGHT])
    for name in schema.names_for(block="size"):
        assert row[name] == features.MISSING[name], name


def test_a_blank_contact_size_cell_is_skipped_not_read_as_zero():
    """The reader writes None when Contact_size is empty, so both shapes reach this module."""
    stroke = [sized(0.0, 0.0, 0.0, 0.4), sized(1.0, 0.0, 10.0, None),
              {"x": 2.0, "y": 0.0, "t_ms": 20.0, "size": None}]
    assert features.size_features([stroke])["size_mean"] == pytest.approx(0.4)


def test_size_is_routed_through_the_declared_missing_not_a_hardcoded_zero(monkeypatch):
    sentinel = -999.0
    monkeypatch.setattr(
        features, "MISSING", {name: sentinel for name in schema.NAMES}, raising=True
    )
    row = features.size_features([[sized(0.0, 0.0, 0.0, 0.5)]])
    assert row["size_mean"] == pytest.approx(0.5)      # measured
    assert row["size_iqr"] == sentinel                 # one stroke has no spread


def test_has_contact_size_distinguishes_an_absent_column_from_a_recorded_one():
    """What `extract` asks before it declares the block present: the finished block cannot be
    asked, because size_mean's declared missing value is 0.0 and so is a legal tiny area."""
    assert features.has_contact_size(SIZED_STROKES) is True
    assert features.has_contact_size([STRAIGHT]) is False
    assert features.has_contact_size([]) is False


# --- tap geometry block ----------------------------------------------------


def _tap(x: float, y: float, size: float | None = None, pressure: float | None = None) -> dict:
    """One OneFingerTouchEvent row, with the archive's column names and string values."""
    row = {"X": str(x), "Y": str(y)}
    if size is not None:
        row["Contact_size"] = str(size)
    if pressure is not None:
        row["Pressure"] = str(pressure)
    return row


# Four taps along a line at x = 0, 10, 20, 30, y = 0. Centroid x = 15, so the distances are
# 15, 5, 5, 15 - every number below is checkable on paper.
TAPS = [_tap(0.0, 0.0, 0.2), _tap(10.0, 0.0, 0.4), _tap(20.0, 0.0, 0.6), _tap(30.0, 0.0, 0.8)]


def test_tap_offset_is_the_median_distance_from_the_session_centroid():
    row = features.tap_geometry(TAPS)
    assert row["tap_offset_med"] == pytest.approx(10.0)      # median of 15 5 5 15
    assert row["tap_count"] == 4.0


def test_tap_spreads_are_interquartile_ranges_per_axis():
    """x = 0 10 20 30: p75 = 22.5, p25 = 7.5, so 15. y is constant, so its spread is a real 0."""
    row = features.tap_geometry(TAPS)
    assert row["tap_x_iqr"] == pytest.approx(15.0)
    assert row["tap_y_iqr"] == 0.0
    # distances 5 5 15 15: p75 = 15, p25 = 5
    assert row["tap_offset_iqr"] == pytest.approx(10.0)


def test_tap_size_comes_from_the_tap_rows_own_contact_size_column():
    """Not from the stroke samples. Tap rows and stroke samples are different shapes, and a
    session can carry one table without the other."""
    assert features.tap_geometry(TAPS)["tap_size_med"] == pytest.approx(0.5)  # median .2 .4 .6 .8


def test_tap_rows_and_stroke_samples_are_not_interchangeable():
    """Reading one with the other's keys yields an empty block rather than an error, so this is
    pinned: the two parsers must never be merged."""
    assert features.tap_points(SIZED_STROKES[1]) == []      # stroke samples have no X / Y
    assert features.size_features([TAPS]) == features.size_features([])  # taps have no "size"


def test_taps_without_coordinates_cannot_place_a_phantom_tap_at_the_origin():
    row = features.tap_geometry([{"Contact_size": "0.5"}, {"X": "", "Y": "10"}])
    for name in schema.names_for(block="tap"):
        assert row[name] == features.MISSING[name], name


def test_no_taps_at_all_leaves_the_whole_block_missing_including_the_count():
    row = features.tap_geometry([])
    assert row["tap_count"] == features.MISSING["tap_count"]
    assert row["tap_offset_med"] == features.MISSING["tap_offset_med"]


def test_a_tap_row_with_no_recorded_size_still_yields_its_placement():
    """Placement and area are separate signals; losing one must not lose the other."""
    row = features.tap_geometry([_tap(0.0, 0.0), _tap(10.0, 0.0),
                                 _tap(20.0, 0.0), _tap(30.0, 0.0)])
    assert row["tap_offset_med"] == pytest.approx(10.0)
    assert row["tap_size_med"] == features.MISSING["tap_size_med"]


def test_tap_geometry_is_routed_through_the_declared_missing(monkeypatch):
    sentinel = -999.0
    monkeypatch.setattr(
        features, "MISSING", {name: sentinel for name in schema.NAMES}, raising=True
    )
    row = features.tap_geometry([_tap(0.0, 0.0), _tap(10.0, 0.0)])
    assert row["tap_offset_med"] == pytest.approx(5.0)   # measured
    assert row["tap_offset_iqr"] == sentinel             # two taps have no quartiles


# --- the new blocks inside session_row -------------------------------------


def test_session_row_places_the_size_and_tap_blocks_in_their_schema_slots():
    size = features.size_features(SIZED_STROKES)
    tap = features.tap_geometry(TAPS)
    row = features.session_row(size=size, tap=tap)

    assert len(row) == len(schema.FEATURES)
    for block in (size, tap):
        for name, value in block.items():
            assert row[schema.INDEX[name]] == value, name
    assert schema.from_vector(row)["tap_count"] == 4.0


def test_the_size_and_tap_blocks_are_absent_unless_the_caller_passes_them():
    """The nine columns the schema grew. Before they were computed anywhere, every one of them
    was the substitute below on every row - which is the regression this guards."""
    row = features.session_row(swipe=features.swipe_features([STRAIGHT]))
    for feature in schema.FEATURES:
        if feature.block in ("size", "tap"):
            assert row[schema.INDEX[feature.name]] == feature.missing, feature.name


def test_the_new_blocks_are_rejected_under_the_wrong_keyword():
    """to_vector accepts any valid feature name, so only the keyword guard catches the swap."""
    with pytest.raises(KeyError, match="not tap features"):
        features.session_row(tap=features.size_features(SIZED_STROKES))
    with pytest.raises(KeyError, match="not size features"):
        features.session_row(size=features.tap_geometry(TAPS))
    with pytest.raises(KeyError, match="not swipe features"):
        features.session_row(swipe=features.tap_geometry(TAPS))


def test_the_two_new_blocks_cover_exactly_nine_features():
    assert len(features.size_features([])) == 3
    assert len(features.tap_geometry([])) == 6
    emitted = set(features.size_features([])) | set(features.tap_geometry([]))
    assert emitted == set(schema.names_for(block="size")) | set(schema.names_for(block="tap"))
    assert emitted <= set(schema.NAMES)


def test_touch_rows_fill_the_size_block_when_the_samples_carry_an_area():
    """The live path: Flutter's PointerEvent carries a radius, so a runtime row should not emit
    a substitute for a signal it actually has."""
    with_size = features.touch_rows(SIZED_STROKES, Granularity.PER_SESSION)[0]
    without = features.touch_rows([STRAIGHT, STRAIGHT], Granularity.PER_SESSION)[0]

    assert with_size[schema.INDEX["size_mean"]] == pytest.approx(0.5)
    for name in schema.names_for(block="size"):
        assert without[schema.INDEX[name]] == features.MISSING[name], name
    # Tap geometry needs the separate OneFingerTouchEvent table, which touch_rows never sees.
    for name in schema.names_for(block="tap"):
        assert with_size[schema.INDEX[name]] == features.MISSING[name], name
