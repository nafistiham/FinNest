"""The feature contract. Order here IS the wire format — change it and old models lie.

`SignalsRequest.behaviour.features` in the risk-mw is a bare `tuple[float, ...]`: positions,
no names, no units. Nothing validates that position 7 is the same quantity the model was
trained on, so this module is the only place the order is allowed to live.

Every feature carries a `source`. HMOG supplies all thirty — touch, keystroke latency,
pressure and IMU together — which is why it was chosen and why the EER target is written
against it. `synthetic_only` marks what no dataset can supply: there is no public recording of
a person being coached through a payment, so those labels are generated and the eval has to say
so rather than pooling them with measured numbers.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Literal

Source = Literal["hmog", "synthetic_only"]
Block = Literal["swipe", "pressure", "pin", "imu", "size", "tap", "keyrank"]

# Which question a feature is allowed to answer.
#
# This split is forced by the requirements, not a preference. The coached-session scenario
# requires that a coached session still scores as the owner while the coaching score goes high.
# Two scores built from overlapping features cannot disagree like that: stretch the PIN timings
# by several seconds and an identity model trained on them will of course call it a stranger.
#
# So identity reads MORPHOLOGY - the geometry of a swipe, how hard she presses, where her taps
# land relative to the key centre, how she holds the phone. Coercion does not change any of
# that; it is the same hand on the same device. Coaching reads TEMPO - hold and flight times,
# dead gaps, retries, how fast she swipes - which is exactly what being talked through a
# payment distorts.
#
# The cost is real and worth stating: keystroke hold and flight times are strong identity
# features in the literature, and this hands them to the coaching model instead. We trade some
# identity accuracy for two scores that are actually independent.
Signal = Literal["morphology", "tempo"]


@dataclass(frozen=True, slots=True)
class Feature:
    name: str
    unit: str
    block: Block
    source: Source
    signal: Signal
    missing: float  # substituted when the signal is unavailable - see the note below


# Codepoint -> column suffix, for the per-key hold-order features below.
#
# HMOG's KeyPressEvent.KeyID is the CHARACTER CODEPOINT, not an Android keycode. That was
# established by measurement after the keycode reading produced empty columns: across 800
# writing sessions the busiest ids are 32, -5, 101, 116, 111, 105 - space, the IME's delete
# constant, then e, t, o, i, which is English letter frequency exactly. Android's KEYCODE_A is
# 29 and would have put 'a' nowhere near the top.
#
# These sixteen are the ids present in EVERY one of those 800 sessions, so the rank vector is
# dense and no session needs a substituted value. Selection was on presence alone - never on a
# label or a timing - so it cannot have overfitted to identity. Codepoints and suffixes live
# together here because a drift between them would silently rank the wrong key.
KEYRANK_KEYS: tuple[tuple[int, str], ...] = (
    (-5, "bksp"), (32, "space"), (46, "period"),
    (97, "a"), (99, "c"), (100, "d"), (101, "e"), (104, "h"), (105, "i"), (108, "l"),
    (110, "n"), (111, "o"), (114, "r"), (115, "s"), (116, "t"), (117, "u"),
)

# --- the features, in wire order -------------------------------------------
# Derived from Touchalytics / HMOG practice; see the research note, Key Question 2.
FEATURES: tuple[Feature, ...] = (
    # swipe kinematics (12)
    Feature("swipe_duration_ms", "ms", "swipe", "hmog", "tempo", 0.0),
    Feature("swipe_start_x", "px", "swipe", "hmog", "morphology", 0.0),
    Feature("swipe_start_y", "px", "swipe", "hmog", "morphology", 0.0),
    Feature("swipe_end_x", "px", "swipe", "hmog", "morphology", 0.0),
    Feature("swipe_end_y", "px", "swipe", "hmog", "morphology", 0.0),
    Feature("swipe_angle_rad", "rad", "swipe", "hmog", "morphology", 0.0),
    Feature("swipe_length_px", "px", "swipe", "hmog", "morphology", 0.0),
    Feature("swipe_v_mean", "px/ms", "swipe", "hmog", "tempo", 0.0),
    Feature("swipe_v_p20", "px/ms", "swipe", "hmog", "tempo", 0.0),
    Feature("swipe_v_p50", "px/ms", "swipe", "hmog", "tempo", 0.0),
    Feature("swipe_v_p80", "px/ms", "swipe", "hmog", "tempo", 0.0),
    Feature("swipe_accel_mean", "px/ms2", "swipe", "hmog", "tempo", 0.0),
    # contact pressure (2) — HMOG records it; Flutter PointerEvent supplies it live
    Feature("pressure_mean", "norm", "pressure", "hmog", "morphology", 0.0),
    Feature("pressure_max", "norm", "pressure", "hmog", "tempo", 0.0),
    # PIN pad keystroke dynamics (11) — the coaching signal lives here
    Feature("pin_hold_1_ms", "ms", "pin", "hmog", "tempo", 0.0),
    Feature("pin_hold_2_ms", "ms", "pin", "hmog", "tempo", 0.0),
    Feature("pin_hold_3_ms", "ms", "pin", "hmog", "tempo", 0.0),
    Feature("pin_hold_4_ms", "ms", "pin", "hmog", "tempo", 0.0),
    Feature("pin_flight_1_ms", "ms", "pin", "hmog", "tempo", 0.0),
    Feature("pin_flight_2_ms", "ms", "pin", "hmog", "tempo", 0.0),
    Feature("pin_flight_3_ms", "ms", "pin", "hmog", "tempo", 0.0),
    Feature("pin_total_entry_ms", "ms", "pin", "hmog", "tempo", 0.0),
    Feature("pin_backspaces", "count", "pin", "hmog", "tempo", 0.0),
    Feature("pin_tap_offset_mean_px", "px", "pin", "hmog", "morphology", 0.0),
    Feature("pin_pressure_mean", "norm", "pin", "hmog", "morphology", 0.0),
    # contact area (3) - the replacement for pressure, which is a dead column on HMOG's
    # handsets: across all 800 writing sessions Pressure is exactly 1.0, one distinct value,
    # because those 2014 devices have no pressure sensor. Contact size does vary, and adding it
    # moved EER from 0.1512 to 0.1442 over 100 users.
    Feature("size_mean", "norm", "size", "hmog", "morphology", 0.0),
    Feature("size_max", "norm", "size", "hmog", "morphology", 0.0),
    Feature("size_iqr", "norm", "size", "hmog", "morphology", 0.0),
    # tap geometry (6) - the strongest block measured. pin_tap_offset_mean_px was already the
    # single most discriminative feature by a wide margin (F-ratio 3.97 against 2.06 for the
    # next), and it reduced every tap to one mean. Keeping the spread of placement as well took
    # EER to 0.1242, and together with size to 0.1172 - a fifth off the shipped number, with the
    # coached-session recognition rate RISING from 85.0% to 88.7% rather than falling.
    Feature("tap_offset_med", "px", "tap", "hmog", "morphology", 0.0),
    Feature("tap_offset_iqr", "px", "tap", "hmog", "morphology", 0.0),
    Feature("tap_x_iqr", "px", "tap", "hmog", "morphology", 0.0),
    Feature("tap_y_iqr", "px", "tap", "hmog", "morphology", 0.0),
    Feature("tap_size_med", "norm", "tap", "hmog", "morphology", 0.0),
    Feature("tap_count", "count", "tap", "hmog", "morphology", 0.0),
    # motion / grip (5) — HMOG samples accelerometer and gyroscope at 100 Hz
    Feature("imu_accel_mag_mean", "m/s2", "imu", "hmog", "morphology", 0.0),
    Feature("imu_accel_mag_std", "m/s2", "imu", "hmog", "morphology", 0.0),
    Feature("imu_gyro_mag_mean", "rad/s", "imu", "hmog", "morphology", 0.0),
    Feature("imu_gyro_mag_std", "rad/s", "imu", "hmog", "morphology", 0.0),
    Feature("imu_tilt_dominant_rad", "rad", "imu", "hmog", "morphology", 0.0),
) + tuple(
    # Per-key hold-time ORDER (16). Which keys she dwells on relative to her own other keys.
    #
    # This is the one timing-derived quantity that is allowed to answer the identity question,
    # and the reason is arithmetic rather than empirical: a rank cannot see a scale change.
    # Coaching was measured to stretch hold times 1.6-2.5x with raised variance, and absolute
    # per-key holds were rejected because of it (1.1% still-her on coached sessions). Under a
    # pure stretch the rank agreement with her uncoached session is exactly 1.000000, verified,
    # so only the variance half of coaching can touch this - and it has to roughly double her
    # own natural session-to-session variability before the order stops being hers.
    #
    # Measured on 800 HMOG writing sessions: her own sessions agree at 0.566 Spearman, different
    # people at 0.149, and agreement with the population's own ordering is only 0.314 - so this
    # is the person and not merely English letter frequency. Added to the identity features it
    # moved a like-for-like pooled EER from 0.1893 to 0.1634; the absolute medians moved it the
    # wrong way, to 0.2120, which is the earlier rejection reproduced.
    #
    # WHAT THIS BLOCK DOES NOT DO, so nobody quotes the gain as a product number. These keys are
    # the ones a person presses when typing PROSE. FinNest's typing surface is an amount and a
    # PIN, which is digits, so NONE of them appear at serving time: `keyrank_values` returns
    # nothing, all sixteen take the 0.0 below, and the per-user model - fitted with the block
    # always present - scores a vector it never saw. The pooled EER of 0.0797 is therefore a
    # result on HMOG free text, and the product-realistic number is the 0.1192 measured without
    # this block, which FAILS the 0.03-0.10 target.
    #
    # Ranking the ten digits instead is the obvious repair and cannot be validated on this
    # dataset: HMOG writing sessions carry 430 digit presses in total across all 800 sessions, a
    # mean of 0.37 distinct digits per session, and no session presses all ten. So the transfer
    # to a 4-digit PIN is unmeasured, and must not be assumed from the numbers above.
    #
    # WHY 0.0 IS A SAFE `missing` HERE, uniquely among these features. Ranks are the Weibull
    # plotting position r/(n+1), so a real rank lies STRICTLY inside (0, 1): the fastest of n
    # keys is 1/(n+1) and the slowest n/(n+1). 0.0 is therefore structurally impossible as a
    # measurement, and a substituted zero is detectable rather than plausible - which is not
    # true of any other feature in this schema, where 0.0 is a legal reading. Nothing may
    # replace this with (r-1)/(n-1), which emits 0.0 for the fastest key and divides by zero at
    # n == 1.
    Feature(f"keyrank_{suffix}", "rank", "keyrank", "hmog", "morphology", 0.0)
    for _codepoint, suffix in KEYRANK_KEYS
)

# The risk-mw contract caps `behaviour.features` at 64, leaving room to grow.
MAX_WIRE_LENGTH = 64

# Why every `missing` is 0.0, and why "absent" and "measured zero" look identical on the wire.
#
# This is a real ambiguity, not an oversight: a tap's swipe_v_mean of 0.0 px/ms is a measurement,
# and a single-sample stroke's velocity is unknown, yet both serialise as 0.0 and the model cannot
# tell them apart.
#
# NaN would express it and is not available. `behaviour.features` crosses the wire as JSON inside
# SignalsRequest, and NaN is not valid JSON - it would be a serialisation failure at the edge
# rather than a cleaner signal. Nor can the frozen contract carry a parallel presence mask.
#
# So presence is recorded beside the vector rather than inside it: the extraction table written by
# `bhorosha_ato.extract` carries which schema blocks were actually present per row, which is where
# training and evaluation need it. Within a session, `features.py` keeps the distinction internally
# (None until the block boundary) so an absent value never votes on an aggregate - that is the part
# that would actually bias a feature. Do not "fix" this by putting NaN on the wire.

NAMES: tuple[str, ...] = tuple(f.name for f in FEATURES)
INDEX: dict[str, int] = {f.name: i for i, f in enumerate(FEATURES)}

# Identity is read from morphology only, coaching from tempo only. See `Signal` above.
IDENTITY_FEATURES: tuple[str, ...] = tuple(f.name for f in FEATURES if f.signal == "morphology")
TEMPO_FEATURES: tuple[str, ...] = tuple(f.name for f in FEATURES if f.signal == "tempo")
IDENTITY_INDEX: tuple[int, ...] = tuple(INDEX[n] for n in IDENTITY_FEATURES)


def project(rows: list[tuple[float, ...]], names: tuple[str, ...]) -> list[list[float]]:
    """Keep only the named columns, in the order given."""
    idx = [INDEX[n] for n in names]
    return [[row[i] for i in idx] for row in rows]


def names_for(block: Block | None = None, source: Source | None = None) -> tuple[str, ...]:
    """Feature names filtered by block and/or by which dataset can produce them."""
    return tuple(
        f.name for f in FEATURES
        if (block is None or f.block == block) and (source is None or f.source == source)
    )


def to_vector(row: dict[str, float]) -> tuple[float, ...]:
    """Dict -> wire order, substituting each feature's declared missing value.

    Unknown keys are a programming error, not something to silently drop: a typo in a feature
    name would otherwise shift nothing and look fine while training on a zero column.
    """
    unknown = set(row) - set(INDEX)
    if unknown:
        raise KeyError(f"not features in this schema: {sorted(unknown)}")
    return tuple(float(row.get(f.name, f.missing)) for f in FEATURES)


def from_vector(vector: tuple[float, ...] | list[float]) -> dict[str, float]:
    """Wire order -> dict. Rejects a wrong-length vector rather than zip-truncating it."""
    if len(vector) != len(FEATURES):
        raise ValueError(f"expected {len(FEATURES)} features, got {len(vector)}")
    return dict(zip(NAMES, (float(v) for v in vector), strict=True))
