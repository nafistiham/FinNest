"""Genuine and coached session generators.

A module rather than a test fixture, for two reasons.

No public dataset records a person being talked through a payment by a scammer, so the coaching
model has to be trained on generated sessions. That is a real limitation and belongs somewhere a
reader will find it.

It also unblocks the work: generated sessions let the models, SHAP, the explainer and the eval be
built and tested before the HMOG archive arrives.
"""

from __future__ import annotations

import random

from bhorosha_ato.schema import FEATURES, from_vector, project, to_vector

# Population-level mean and standard deviation per feature. Plausible rather than measured:
# these exist so the pipeline can run before HMOG lands, and they are replaced by real
# enrolment sessions the moment it does.
POPULATION: dict[str, tuple[float, float]] = {
    "swipe_duration_ms": (320.0, 90.0),
    "swipe_start_x": (180.0, 60.0),
    "swipe_start_y": (520.0, 110.0),
    "swipe_end_x": (200.0, 70.0),
    "swipe_end_y": (300.0, 120.0),
    "swipe_angle_rad": (-1.40, 0.50),
    "swipe_length_px": (260.0, 80.0),
    "swipe_v_mean": (0.95, 0.25),
    "swipe_v_p20": (0.35, 0.12),
    "swipe_v_p50": (0.90, 0.22),
    "swipe_v_p80": (1.50, 0.35),
    # Centred on zero, not positive: a real stroke accelerates out of the touch-down and
    # decelerates into the lift, so the net first-to-last change is near nothing. A positive mean
    # would make every generated swipe accelerate the whole way, and the generated-versus-HMOG
    # comparison would then diverge on this feature for a reason that has nothing to do with the
    # model. Allowed to go negative - it is excluded from NON_NEGATIVE.
    "swipe_accel_mean": (0.0, 0.0030),
    "pressure_mean": (0.52, 0.09),
    "pressure_max": (0.78, 0.10),
    "pin_hold_1_ms": (95.0, 18.0),
    "pin_hold_2_ms": (92.0, 17.0),
    "pin_hold_3_ms": (97.0, 19.0),
    "pin_hold_4_ms": (94.0, 18.0),
    "pin_flight_1_ms": (180.0, 45.0),
    "pin_flight_2_ms": (172.0, 42.0),
    "pin_flight_3_ms": (188.0, 48.0),
    "pin_total_entry_ms": (1450.0, 280.0),
    "pin_backspaces": (0.10, 0.30),
    "pin_tap_offset_mean_px": (6.50, 2.00),
    "pin_pressure_mean": (0.55, 0.08),
    # These nine are MEASURED, not plausible-looking: means and deviations taken from the 800
    # real HMOG writing sessions. The thirty above are still invented, and replacing them the
    # same way is the obvious next cleanup.
    "size_mean": (0.0248, 0.0019),
    "size_max": (0.0266, 0.0022),
    "size_iqr": (0.0020, 0.0008),
    "tap_offset_med": (331.2842, 62.6430),
    "tap_offset_iqr": (175.3768, 90.3655),
    "tap_x_iqr": (548.6856, 150.7769),
    "tap_y_iqr": (283.0609, 19.9833),
    "tap_size_med": (0.0238, 0.0013),
    "tap_count": (2961.0950, 833.7888),
    "imu_accel_mag_mean": (9.90, 0.25),
    "imu_accel_mag_std": (0.35, 0.10),
    "imu_gyro_mag_mean": (0.080, 0.030),
    "imu_gyro_mag_std": (0.060, 0.020),
    "imu_tilt_dominant_rad": (0.42, 0.08),
}

# Features that cannot be negative, whatever the draw.
NON_NEGATIVE = frozenset(
    name for name in POPULATION
    if name not in {"swipe_angle_rad", "swipe_accel_mean"}
)

# The six tempo features the coaching model is allowed to see - a deliberately narrow slice of
# schema.TEMPO_FEATURES. Coaching is about hesitation and pauses, and keeping the set small
# stops it from rediscovering identity through the back door.
COACHING_FEATURES: tuple[str, ...] = (
    "pin_flight_1_ms",
    "pin_flight_2_ms",
    "pin_flight_3_ms",
    "pin_total_entry_ms",
    "pin_backspaces",
    "swipe_v_mean",
)

# Grip is held constant by the coach rule: same person, same phone.
GRIP_FEATURES: tuple[str, ...] = tuple(f.name for f in FEATURES if f.block == "imu")


def user_profile(rng: random.Random, spread: float = 0.6) -> dict[str, tuple[float, float]]:
    """One person's own mean and standard deviation per feature.

    Each user sits at an offset from the population mean, and their own sessions vary less than
    the population does - which is the entire premise of behavioural biometrics. `spread`
    controls how far apart users are; the within-user deviation is deliberately a fraction of
    the population's, so a per-user model has something to learn.
    """
    profile: dict[str, tuple[float, float]] = {}
    for name, (mean, std) in POPULATION.items():
        own_mean = rng.gauss(mean, std * spread)
        if name in NON_NEGATIVE:
            own_mean = max(own_mean, 0.0)
        profile[name] = (own_mean, std * 0.45)
    return profile


def genuine_row(profile: dict[str, tuple[float, float]], rng: random.Random) -> tuple[float, ...]:
    """One session from this user, behaving normally."""
    row: dict[str, float] = {}
    for name, (mean, std) in profile.items():
        value = rng.gauss(mean, std)
        if name in NON_NEGATIVE:
            value = max(value, 0.0)
        row[name] = value
    row["pin_backspaces"] = float(round(row["pin_backspaces"]))
    return to_vector(row)


def genuine_rows(
    profile: dict[str, tuple[float, float]], n: int, rng: random.Random
) -> list[tuple[float, ...]]:
    return [genuine_row(profile, rng) for _ in range(n)]


def coach(row: tuple[float, ...], rng: random.Random) -> tuple[float, ...]:
    """Turn one genuine session into a coached one.

    The five rules from the research note:

    1. hold and flight times stretch by 1.6-2.5x, with more variance
    2. one to three dead gaps of 4-15 s land between PIN digits or before Confirm
    3. one or two backspaces or retries appear
    4. pressure variance rises and swipe velocity drops 30-40%
    5. the IMU grip features are left exactly as they were

    Rule 5 is the point of the whole exercise. It is the same person on the same phone, so the
    one-class model should still recognise her while the coaching score rises. The gap between
    those two numbers is what the demo shows, and `test_coached_session_is_still_her` pins it.
    """
    before = from_vector(row)
    after = dict(before)

    stretch = rng.uniform(1.6, 2.5)
    for name in ("pin_hold_1_ms", "pin_hold_2_ms", "pin_hold_3_ms", "pin_hold_4_ms",
                 "pin_flight_1_ms", "pin_flight_2_ms", "pin_flight_3_ms"):
        after[name] = before[name] * stretch * rng.uniform(0.85, 1.15)

    dead_time_ms = sum(rng.uniform(4_000.0, 15_000.0) for _ in range(rng.randint(1, 3)))
    gap_target = rng.choice(["pin_flight_1_ms", "pin_flight_2_ms", "pin_flight_3_ms"])
    after[gap_target] += dead_time_ms

    after["pin_backspaces"] = before["pin_backspaces"] + float(rng.randint(1, 2))

    after["pressure_max"] = min(before["pressure_max"] * rng.uniform(1.10, 1.30), 1.0)
    slowdown = rng.uniform(0.60, 0.70)
    for name in ("swipe_v_mean", "swipe_v_p20", "swipe_v_p50", "swipe_v_p80"):
        after[name] = before[name] * slowdown

    # Entry time has to agree with the stretched components plus the dead time, otherwise the
    # coaching model could separate the classes on an arithmetic inconsistency we introduced
    # rather than on the hesitation itself.
    after["pin_total_entry_ms"] = (
        sum(after[f"pin_hold_{i}_ms"] for i in (1, 2, 3, 4))
        + sum(after[f"pin_flight_{i}_ms"] for i in (1, 2, 3))
        + (before["pin_total_entry_ms"] - sum(before[f"pin_hold_{i}_ms"] for i in (1, 2, 3, 4))
           - sum(before[f"pin_flight_{i}_ms"] for i in (1, 2, 3)))
    )

    for name in GRIP_FEATURES:
        after[name] = before[name]

    return to_vector(after)


def coached_rows(
    rows: list[tuple[float, ...]], rng: random.Random
) -> list[tuple[float, ...]]:
    return [coach(row, rng) for row in rows]


def coaching_matrix(rows: list[tuple[float, ...]]) -> list[list[float]]:
    """Project sessions onto the six features the coaching model may use."""
    return project(rows, COACHING_FEATURES)
