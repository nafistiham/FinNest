"""The feature contract is the one thing worth testing before any model exists.

`behaviour.features` crosses the wire as a bare tuple of floats, so a drift in length or order
cannot be caught at runtime by the risk-mw — only here.
"""

from __future__ import annotations

import pytest

from bhorosha_ato import schema


def test_the_feature_count_and_the_room_left_to_grow():
    assert len(schema.FEATURES) == 55
    # The contract caps the tuple at 64, and 55 of those are now spent. Worth watching: the next
    # per-key family would not fit, so one would have to replace rather than extend.
    assert len(schema.FEATURES) <= schema.MAX_WIRE_LENGTH


def test_names_are_unique_and_index_matches_order():
    assert len(set(schema.NAMES)) == len(schema.NAMES)
    for i, feature in enumerate(schema.FEATURES):
        assert schema.INDEX[feature.name] == i


def test_blocks_sum_to_the_whole():
    """The sum is the assertion that matters: a feature in no block, or in a block nobody
    counts, is a feature the presence flags cannot speak for."""
    blocks = ("swipe", "pressure", "pin", "size", "tap", "imu", "keyrank")
    counts = {b: len(schema.names_for(block=b)) for b in blocks}
    assert counts == {"swipe": 12, "pressure": 2, "pin": 11, "size": 3, "tap": 6, "imu": 5,
                      "keyrank": 16}
    assert sum(counts.values()) == len(schema.FEATURES)
    assert len(schema.KEYRANK_KEYS) == counts["keyrank"]


def test_hmog_supplies_every_feature():
    """Why HMOG is the dataset: it is the only source with touch, keystroke latency,
    pressure and IMU together, so no feature here depends on a second dataset."""
    assert schema.names_for(source="hmog") == schema.NAMES


def test_round_trip_preserves_order():
    row = {name: float(i) for i, name in enumerate(schema.NAMES)}
    assert schema.from_vector(schema.to_vector(row)) == row


def test_missing_features_fall_back_to_declared_defaults():
    vector = schema.to_vector({"swipe_duration_ms": 420.0})
    assert len(vector) == len(schema.FEATURES)
    assert vector[schema.INDEX["swipe_duration_ms"]] == 420.0
    assert vector[schema.INDEX["pin_hold_1_ms"]] == 0.0


def test_unknown_feature_name_is_an_error_not_a_silent_drop():
    with pytest.raises(KeyError):
        schema.to_vector({"swipe_duration_ms": 1.0, "swipe_duration": 2.0})  # typo


def test_wrong_length_vector_is_rejected():
    with pytest.raises(ValueError):
        schema.from_vector([0.0] * (len(schema.FEATURES) - 1))


def test_identity_and_tempo_partition_the_features():
    """Identity reads morphology, coaching reads tempo, and nothing is in both.

    If these ever overlap, the two scores stop being independent and the coached-session
    requirement becomes impossible: a coached session would raise the identity score too.
    """
    identity = set(schema.IDENTITY_FEATURES)
    tempo = set(schema.TEMPO_FEATURES)
    assert identity & tempo == set()
    assert identity | tempo == set(schema.NAMES)


def test_identity_cannot_see_the_features_coercion_distorts():
    """Hold and flight times, entry time, retries and swipe speed are all tempo.

    Coercion stretches exactly these, so identity must not be allowed to read them - that is
    the whole reason for the split.
    """
    distorted_by_coaching = {
        "pin_hold_1_ms", "pin_hold_2_ms", "pin_hold_3_ms", "pin_hold_4_ms",
        "pin_flight_1_ms", "pin_flight_2_ms", "pin_flight_3_ms",
        "pin_total_entry_ms", "pin_backspaces", "swipe_v_mean",
    }
    assert distorted_by_coaching.isdisjoint(schema.IDENTITY_FEATURES)


def test_grip_and_pressure_stay_with_identity():
    """What does not change under coercion: the same hand on the same phone."""
    for name in ("imu_tilt_dominant_rad", "imu_gyro_mag_mean", "pressure_mean",
                 "pin_tap_offset_mean_px"):
        assert name in schema.IDENTITY_FEATURES
