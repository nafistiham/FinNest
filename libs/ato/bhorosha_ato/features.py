"""Raw touch events -> feature rows, in blocks matching the dataset reality.

Split by block on purpose: the swipe and pressure blocks can be computed from real public data
today, the PIN and IMU blocks cannot until the HMOG archive lands. Keeping them separate means
the eval can say which numbers came from a real signal and which from a generated one, and it
means a dataset that records geometry but no pressure stays usable instead of being thrown away
over one absent column.

Two things in here are easy to get wrong and expensive to notice later.

UNITS. Every number returned is in the unit `schema.py` declares for that feature: ms, px,
px/ms, rad. Timestamps therefore arrive as `t_ms` and stay in milliseconds the whole way
through. A seconds-for-milliseconds slip raises nothing - it trains, scores, and reports a
plausible wrong EER.

ABSENT IS NOT ZERO. A tap really does travel zero pixels; a one-sample stroke has no velocity
at all. Those are different facts, so anything unmeasurable is carried as `None` inside this
module and only becomes a number at the block boundary, where it takes that feature's declared
`missing` value. Returning 0.0 for "no data" would teach the owner model that she sometimes
swipes at zero velocity, and then a genuinely slow session would look like her.
"""

from __future__ import annotations

import math
import statistics
from enum import Enum
from typing import Mapping, Sequence

from bhorosha_ato.datasets import KEYCODE_DEL, NON_KEY_ID
from bhorosha_ato.schema import FEATURES, Block, names_for, to_vector

# One raw touch sample. `x`/`y` in device pixels, `t_ms` in milliseconds since an arbitrary
# origin (only differences are ever used, so the epoch does not matter). `pressure` is optional:
# HMOG and Flutter's PointerEvent both carry it, Touchalytics-style CSV exports often do not.
Event = Mapping[str, float]

# One stroke: the samples between a touch-down and the matching touch-up, in time order. A tap
# is a stroke too - it just has no displacement.
Stroke = Sequence[Event]

# `size` is the contact area of the touch point. It rides on the same samples as the geometry -
# `bhorosha_ato.datasets` reads TouchEvent.Contact_size into every sample under this key - and it
# is the signal that replaces pressure on HMOG's handsets, where Pressure is a constant 1.0.
# Dropping it while building samples is exactly how the size block came back empty once; the key
# is named here so there is one spelling for the reader and the extractor to agree on.
X, Y, T_MS, PRESSURE, SIZE = "x", "y", "t_ms", "pressure", "size"


class Granularity(str, Enum):
    """What one feature row is allowed to describe.

    An enum rather than a boolean, because `per_stroke=False` at a call site tells a reader
    nothing about what the row then is, and the two options are not opposites of one concept -
    they are two different units of analysis that different datasets force on us.

    PER_STROKE - one row per touch-down/touch-up. This is how Touchalytics and FETA are
    organised and the unit the Touchalytics paper itself classifies on, so it is the only
    granularity those datasets can be read at without inventing session boundaries they do not
    record.

    PER_SESSION - one row per session, aggregated across its strokes. This is what HMOG's
    100 users x 24 sessions give us, and what `model.py` and `eval/ato_eval.py` currently
    assume: one score per session.

    A str-valued enum so a run config or a JSON report can carry the choice verbatim instead of
    a bare `True` that nobody can interpret six months later.
    """

    PER_STROKE = "per_stroke"
    PER_SESSION = "per_session"


# --- block plumbing --------------------------------------------------------
# Feature names are written out below for readability, but every block is checked against
# schema.names_for() before it leaves this module. That check is the point: rename a feature in
# schema.py and without it this module would quietly stop filling that column, `to_vector` would
# substitute `missing` on every row, and the model would train happily on a constant.


# Every feature's declared stand-in, read from the schema so this module never invents one.
MISSING: dict[str, float] = {f.name: f.missing for f in FEATURES}


def _finalise(block: Block, values: Mapping[str, float | None]) -> dict[str, float]:
    """Check a block covers exactly its schema names, then turn `None` into `missing`."""
    expected = set(names_for(block=block))
    if set(values) != expected:
        wrong = sorted(set(values) ^ expected)
        raise KeyError(f"{block} block does not match schema.names_for({block!r}): {wrong}")
    return {
        name: (MISSING[name] if value is None else float(value))
        for name, value in values.items()
    }


# --- scalar helpers --------------------------------------------------------


def _percentile(values: Sequence[float], q: float) -> float:
    """Linear interpolation between the two nearest order statistics.

    numpy.percentile's default method, deliberately: the eval harness and any notebook that
    recomputes these from the same samples will then agree with us exactly rather than
    differing by one quantisation step and looking like a feature bug.
    """
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    pos = (len(ordered) - 1) * q
    low, high = math.floor(pos), math.ceil(pos)
    if low == high:
        return ordered[low]
    return ordered[low] * (high - pos) + ordered[high] * (pos - low)


def _median_or_none(values: Sequence[float | None]) -> float | None:
    """Median of whatever was actually measured, or None if nothing was."""
    present = [v for v in values if v is not None]
    return statistics.median(present) if present else None


# An IQR needs enough order statistics to mean anything. Below four values the 25th and 75th
# percentiles are interpolations between two or three numbers, so the "spread" is mostly an
# artefact of where the interpolation landed - a session of two strokes would report a
# consistency it never demonstrated.
MIN_IQR_SAMPLES = 4


def _iqr_or_none(values: Sequence[float | None]) -> float | None:
    """Interquartile range of whatever was measured, or None if too little was.

    IQR, not standard deviation, everywhere an `_iqr` feature appears. A session is a few dozen
    strokes and a handful of them are not gestures at all - an accidental edge swipe, a fling, a
    stroke clipped by the activity changing. One of those moves a deviation further than the gap
    between two people, so a deviation would measure how often the digitiser misbehaved rather
    than how consistent the person is. That is the same reason the central values in this module
    are medians rather than means.

    How consistent somebody is, is as personal as their average - which is why the spread is
    kept at all rather than collapsing each distribution to its centre.
    """
    present = [v for v in values if v is not None]
    if len(present) < MIN_IQR_SAMPLES:
        return None
    return _percentile(present, 0.75) - _percentile(present, 0.25)


def _circular_mean_or_none(angles: Sequence[float | None]) -> float | None:
    """Mean direction of a set of angles, in radians, via the summed unit vectors.

    A plain median is wrong for a direction. Two nearly identical rightward-and-slightly-up
    swipes can be recorded as +3.10 and -3.10 rad, and their median is 0.0 - a rightward
    direction that neither of them had. atan2 of the summed unit vectors has no such seam.

    Returns None when the directions cancel (a session of equal up and down swipes has no mean
    direction), because atan2(0, 0) is 0.0 and would read as "rightward".
    """
    present = [a for a in angles if a is not None]
    if not present:
        return None
    sin_sum = sum(math.sin(a) for a in present)
    cos_sum = sum(math.cos(a) for a in present)
    if math.hypot(sin_sum, cos_sum) < 1e-9:
        return None
    return math.atan2(sin_sum, cos_sum)


def _xyt(event: Event) -> tuple[float, float, float]:
    """Pull x, y, t_ms off one sample, refusing to guess at a malformed one.

    A raw event missing a coordinate is a reader bug, not a session with no data: defaulting it
    to 0.0 would put a phantom stroke at the top-left corner of the screen.
    """
    try:
        return float(event[X]), float(event[Y]), float(event[T_MS])
    except KeyError as exc:
        raise KeyError(f"touch event needs {X!r}, {Y!r} and {T_MS!r}; got {sorted(event)}") from exc


# --- swipe block (12) ------------------------------------------------------


def _stroke_swipe(stroke: Stroke) -> dict[str, float | None]:
    """The 12 swipe features for ONE stroke, with None wherever the stroke cannot support one.

    What is and is not measurable, and why each line is drawn where it is:

    - positions need one sample. The first sample is where the finger genuinely landed.
    - duration and path length need two. A single sample has no span; calling it 0 ms would
      drag the session median towards zero every time the digitiser drops samples mid-stroke.
    - direction needs a net displacement. A tap, and a loop that returns to its start, have no
      direction at all, and atan2(0, 0) would silently report "rightward".
    - mean velocity needs a positive duration. Every sample sharing one timestamp (a batched
      or clock-truncated export) is the division-by-zero case.
    - the velocity percentiles need at least one segment with a positive dt. Segments with a
      repeated timestamp still count towards path length - the finger did move - but they
      cannot yield a rate.
    - acceleration needs two instantaneous velocities at distinct times.

    A tap with two or more samples and a real duration is a different case from all of these:
    its velocities are 0.0 px/ms, and that is a measurement, not a gap.
    """
    duration: float | None = None
    length: float | None = None
    angle: float | None = None
    v_mean: float | None = None
    v_p20: float | None = None
    v_p50: float | None = None
    v_p80: float | None = None
    accel: float | None = None

    start_x = start_y = end_x = end_y = None
    if stroke:
        start_x, start_y, _ = _xyt(stroke[0])
        end_x, end_y, _ = _xyt(stroke[-1])

    if len(stroke) >= 2:
        samples = [_xyt(e) for e in stroke]
        t_first, t_last = samples[0][2], samples[-1][2]
        duration = t_last - t_first

        length = 0.0
        velocities: list[float] = []
        midpoints: list[float] = []
        for (x0, y0, t0), (x1, y1, t1) in zip(samples, samples[1:]):
            step = math.hypot(x1 - x0, y1 - y0)
            length += step
            dt = t1 - t0
            if dt > 0.0:
                velocities.append(step / dt)
                midpoints.append((t0 + t1) / 2.0)

        dx, dy = samples[-1][0] - samples[0][0], samples[-1][1] - samples[0][1]
        if math.hypot(dx, dy) > 0.0:
            # Screen coordinates: y grows downward, so an upward swipe is a negative angle.
            # That matches synth.POPULATION's -1.40 rad for the usual bottom-to-top scroll.
            angle = math.atan2(dy, dx)

        if duration > 0.0:
            v_mean = length / duration

        if velocities:
            v_p20 = _percentile(velocities, 0.20)
            v_p50 = _percentile(velocities, 0.50)
            v_p80 = _percentile(velocities, 0.80)

        if len(velocities) >= 2 and midpoints[-1] > midpoints[0]:
            # Time-weighted mean of the per-segment acceleration. That average telescopes
            # exactly to (last velocity - first) / (time between them), so it is immune to
            # non-uniform sampling - a mean of raw dv/dt ratios is not, and would be dominated
            # by whichever segment happened to be shortest.
            accel = (velocities[-1] - velocities[0]) / (midpoints[-1] - midpoints[0])

    return {
        "swipe_duration_ms": duration,
        "swipe_start_x": start_x,
        "swipe_start_y": start_y,
        "swipe_end_x": end_x,
        "swipe_end_y": end_y,
        "swipe_angle_rad": angle,
        "swipe_length_px": length,
        "swipe_v_mean": v_mean,
        "swipe_v_p20": v_p20,
        "swipe_v_p50": v_p50,
        "swipe_v_p80": v_p80,
        "swipe_accel_mean": accel,
    }


def _aggregate_swipe(strokes: Sequence[Stroke]) -> dict[str, float | None]:
    """Collapse many strokes into one row: median per feature, circular mean for the angle.

    MEDIAN, not mean. A session is a few dozen strokes and a handful of them are not gestures
    at all - an accidental edge swipe, a fling that scrolls 1500 px, a stroke clipped by the
    activity changing. One of those moves a mean by more than the difference between two people,
    so an owner model fitted on means would reject her own next session the first time she
    flings a list. The median ignores it. It is also what the touch-biometrics literature does
    with per-stroke distributions, and it keeps the two granularities consistent: the median of
    a single stroke is that stroke, so a PER_STROKE row and a one-stroke PER_SESSION row are
    the same numbers rather than two slightly different definitions.

    The angle is the exception - see `_circular_mean_or_none` for the seam a median falls into.
    """
    per_stroke = [_stroke_swipe(s) for s in strokes]
    aggregated: dict[str, float | None] = {}
    for name in names_for(block="swipe"):
        column = [row[name] for row in per_stroke]
        aggregated[name] = (
            _circular_mean_or_none(column) if name == "swipe_angle_rad"
            else _median_or_none(column)
        )
    return aggregated


def swipe_features(strokes: Sequence[Stroke]) -> dict[str, float]:
    """The 12 swipe features for one session's strokes.

    `strokes` is a sequence of strokes, each a time-ordered sequence of samples carrying `x`,
    `y` and `t_ms` (and optionally `pressure`, which this block ignores - see
    `pressure_features`). A session normally holds many strokes, so every feature here is an
    aggregate across them: the median, or the circular mean for the direction. See
    `_aggregate_swipe` for why the median.

    For one row per stroke, pass a single-stroke list - or use `touch_rows` with
    `Granularity.PER_STROKE`, which does exactly that.

    Computable from real public data today (Touchalytics, FETA, BrainRun, and Flutter's
    PointerEvent stream live).
    """
    return _finalise("swipe", _aggregate_swipe(strokes))


# --- pressure block (2) ----------------------------------------------------


def _stroke_pressure(stroke: Stroke) -> dict[str, float | None]:
    """Mean and peak contact pressure within one stroke, or None if it was never recorded.

    Samples without a `pressure` key are skipped rather than read as 0.0: a dataset with
    geometry and no pressure must produce `missing`, otherwise the owner model learns that she
    presses with zero force and every real device then looks like an impostor.
    """
    readings = [float(e[PRESSURE]) for e in stroke if PRESSURE in e]
    if not readings:
        return {"pressure_mean": None, "pressure_max": None}
    return {
        "pressure_mean": statistics.fmean(readings),
        "pressure_max": max(readings),
    }


def pressure_features(strokes: Sequence[Stroke]) -> dict[str, float]:
    """The 2 pressure features for one session's strokes.

    A separate function from `swipe_features` because the two signals do not travel together:
    HMOG and Flutter give pressure, several touch-biometric CSV exports give geometry only, and
    a caller with no pressure should be able to build a row without faking a column.

    Both features are the MEDIAN over the strokes of that stroke's own statistic. For
    `pressure_max` that is a deliberate reading of "max": the peak within a stroke is a stable
    trait of how someone presses, whereas the maximum over a whole session is whichever single
    sample spiked hardest - one noisy sample would define the feature, and it would drift upward
    with session length instead of describing the person.
    """
    per_stroke = [_stroke_pressure(s) for s in strokes]
    return _finalise("pressure", {
        name: _median_or_none([row[name] for row in per_stroke])
        for name in names_for(block="pressure")
    })


# --- contact size block (3) ------------------------------------------------


def _stroke_sizes(stroke: Stroke) -> list[float]:
    """Every recorded contact area within one stroke, in sample order.

    A sample whose `size` key is absent, or present and None, is skipped rather than read as
    0.0 - the same rule as pressure. The reader writes None when Contact_size is blank, so both
    shapes have to be tolerated or a single blank cell would become a zero-area touch.
    """
    return [float(event[SIZE]) for event in stroke if event.get(SIZE) is not None]


def has_contact_size(strokes: Sequence[Stroke]) -> bool:
    """Whether any sample anywhere in these strokes actually recorded a contact area.

    Exposed because `extract.record_from_session` has to say whether the size block was measured
    or substituted, and that cannot be read back off the finished block: `size_mean`'s declared
    missing value is 0.0, which is also a legal (if tiny) area.
    """
    return any(_stroke_sizes(stroke) for stroke in strokes)


def size_features(strokes: Sequence[Stroke]) -> dict[str, float]:
    """The 3 contact-area features for one session's strokes.

    This block is the replacement for pressure, not an addition to it. Across all 800 HMOG
    writing sessions Pressure is exactly 1.0 - one distinct value, because those 2014 handsets
    have no pressure sensor and Android returns a constant - so the pressure block carries no
    information at all on this dataset. Contact size, which the reader parses off the same
    column family, genuinely varies between people; Touchalytics lists "area covered" among its
    useful features for the same reason.

    Shaped like `pressure_features`: each stroke contributes its own mean and peak, and the
    session takes the MEDIAN of those, so one stroke that smeared across the digitiser cannot
    define the session. `size_iqr` is the spread of the per-stroke means - see `_iqr_or_none`
    for why an interquartile range rather than a deviation.
    """
    per_stroke = [readings for stroke in strokes if (readings := _stroke_sizes(stroke))]
    means = [statistics.fmean(readings) for readings in per_stroke]
    peaks = [max(readings) for readings in per_stroke]
    return _finalise("size", {
        "size_mean": _median_or_none(means),
        "size_max": _median_or_none(peaks),
        "size_iqr": _iqr_or_none(means),
    })


# --- blocked on HMOG's internal layout -------------------------------------


# HMOG's typing sessions are FREE TEXT, not four-digit PIN entry, and the schema's
# pin_hold_1..4 / pin_flight_1..3 are positional slots for a PIN. There is no fourth digit in a
# paragraph of prose, so the slots are filled with quantiles of the session's own hold and
# flight distributions instead of with positions.
#
# That is a real change of meaning and it is safe for exactly one reason: the dataset is only
# ever used to MEASURE separability, never to train a model that serves a real user. Every user
# goes through the same transform, so the EER it produces is a fair comparison. A production
# model is fitted on that person's own four-digit entries, where the positions are real.
# Anything that ever trains on both at once would be comparing different quantities.
HOLD_QUANTILES = (0.20, 0.40, 0.60, 0.80)
FLIGHT_QUANTILES = (0.25, 0.50, 0.75)

# A four-key window is the nearest analogue to a PIN entry inside free text. Session-wide entry
# time would otherwise just measure how long the task was.
PIN_LENGTH = 4

PRESS_DOWN, PRESS_UP = 0, 1


def _keystrokes(key_events: Sequence[dict]) -> tuple[list[float], list[float], list[float]]:
    """Hold times, flight times and four-key entry spans, in milliseconds.

    Pairs each down with the next up for the same key. Rows are ordered by Systime in the
    archive but their relative timestamps are not monotonic, so this sorts by press time before
    pairing - otherwise a hold can come out negative and poison the distribution.
    """
    events: list[tuple[float, int, int]] = []
    for row in key_events:
        t = _num(row.get("PressTime"))
        press = _num(row.get("PressType"))
        key = _num(row.get("KeyID"))
        if t is None or press is None or key is None or int(key) == NON_KEY_ID:
            continue
        events.append((t, int(press), int(key)))
    events.sort()

    holds: list[float] = []
    presses: list[tuple[float, float]] = []  # (down, up) per keystroke
    pending: dict[int, float] = {}
    for t, press, key in events:
        if press == PRESS_DOWN:
            pending[key] = t
        elif press == PRESS_UP and key in pending:
            down = pending.pop(key)
            if t >= down:
                holds.append(t - down)
                presses.append((down, t))

    presses.sort()
    flights = [
        presses[i + 1][0] - presses[i][1]
        for i in range(len(presses) - 1)
        if presses[i + 1][0] >= presses[i][1]
    ]
    spans = [
        presses[i + PIN_LENGTH - 1][1] - presses[i][0]
        for i in range(len(presses) - PIN_LENGTH + 1)
    ]
    return holds, flights, spans


def _num(raw: object) -> float | None:
    if raw in (None, ""):
        return None
    try:
        return float(raw)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return None


def pin_features(key_events: Sequence[dict], taps: Sequence[dict] = ()) -> dict[str, float]:
    """The 11 typing features: hold, flight, entry span, corrections, tap offset and pressure.

    The coaching signal lives here - stretched holds and dead gaps are what being talked through
    a payment looks like.

    `taps` are OneFingerTouchEvent rows, which is where the coordinates and pressure live;
    KeyPressEvent carries neither. Tap offset is the mean distance from the session's own tap
    centroid, not from a key centre: the archive does not ship the keyboard layout, so a true
    offset is not computable. It still measures consistency of placement, which is the property
    the feature exists for, and the substitution is recorded rather than hidden.
    """
    holds, flights, spans = _keystrokes(key_events)

    values: dict[str, float | None] = {}
    for i, q in enumerate(HOLD_QUANTILES, start=1):
        values[f"pin_hold_{i}_ms"] = _percentile(holds, q) if holds else None
    for i, q in enumerate(FLIGHT_QUANTILES, start=1):
        values[f"pin_flight_{i}_ms"] = _percentile(flights, q) if flights else None
    values["pin_total_entry_ms"] = _percentile(spans, 0.5) if spans else None

    # Per 100 keystrokes, so a long session does not look like a correction-prone typist.
    values["pin_backspaces"] = (
        100.0 * sum(1 for r in key_events
                    if _num(r.get("KeyID")) == KEYCODE_DEL
                    and _num(r.get("PressType")) == PRESS_DOWN) / len(holds)
        if holds else None
    )

    points = [(x, y) for r in taps
              if (x := _num(r.get("X"))) is not None and (y := _num(r.get("Y"))) is not None]
    if points:
        cx = sum(p[0] for p in points) / len(points)
        cy = sum(p[1] for p in points) / len(points)
        values["pin_tap_offset_mean_px"] = _median_or_none(
            [math.hypot(x - cx, y - cy) for x, y in points]
        )
    else:
        values["pin_tap_offset_mean_px"] = None

    values["pin_pressure_mean"] = _median_or_none([_num(r.get("Pressure")) for r in taps])
    return _finalise("pin", values)


# --- tap geometry block (6) ------------------------------------------------


def tap_points(taps: Sequence[dict]) -> list[tuple[float, float, float | None]]:
    """OneFingerTouchEvent rows -> (x, y, contact size) for every tap that has coordinates.

    A row without a usable X or Y is dropped: it cannot contribute to a placement statistic and
    defaulting it to the origin would drag the centroid into the corner of the screen. Size is
    carried as None when that row's Contact_size is blank, because `tap_size_med` must not
    average a blank cell in as a zero-area tap.

    These rows are a DIFFERENT SHAPE from the touch samples `size_features` reads. Taps are raw
    archive rows with string values under archive column names ("X", "Y", "Contact_size");
    stroke samples are reader-normalised dicts with floats under "x", "y", "size". Reading one
    with the other's keys yields an empty block rather than an error, so the two never share a
    parser.
    """
    points: list[tuple[float, float, float | None]] = []
    for row in taps:
        x, y = _num(row.get("X")), _num(row.get("Y"))
        if x is None or y is None:
            continue
        points.append((x, y, _num(row.get("Contact_size"))))
    return points


def tap_geometry(taps: Sequence[dict]) -> dict[str, float]:
    """The 6 tap-placement features for one session's OneFingerTouchEvent rows.

    `pin_tap_offset_mean_px` was already the single most discriminative feature in the schema by
    a wide margin, and it reduced every tap in a session to one mean distance. This block keeps
    the SPREAD of placement as well - how tightly her taps cluster, and separately how far they
    scatter along each axis - which is a different fact about a person from where their centre
    is, and the one that moved the measured EER most.

    Offsets are distances from the session's own tap centroid, not from a key centre: the
    archive does not ship the keyboard layout, so a true offset is not computable. The same
    substitution `pin_features` makes, and recorded here for the same reason.

    `tap_size_med` comes from these rows' own Contact_size column. It is NOT the stroke samples'
    size - taps and strokes are separate event tables in the archive and a session can have one
    without the other - so this block reads taps only and `size_features` reads strokes only.

    `tap_count` is a plain count, left unnormalised on purpose: how many discrete taps a task
    took is itself behavioural, and there is no session length to divide by that would not just
    reintroduce the task type.
    """
    points = tap_points(taps)
    if not points:
        # Every feature unmeasured, including the count: `_finalise` substitutes each one's
        # declared missing value, and `extract` records the block as absent beside the row.
        return _finalise("tap", {name: None for name in names_for(block="tap")})

    xs = [x for x, _, _ in points]
    ys = [y for _, y, _ in points]
    cx, cy = statistics.fmean(xs), statistics.fmean(ys)
    offsets = [math.hypot(x - cx, y - cy) for x, y, _ in points]
    sizes = [size for _, _, size in points if size is not None]

    return _finalise("tap", {
        "tap_offset_med": _median_or_none(offsets),
        "tap_offset_iqr": _iqr_or_none(offsets),
        "tap_x_iqr": _iqr_or_none(xs),
        "tap_y_iqr": _iqr_or_none(ys),
        "tap_size_med": _median_or_none(sizes),
        "tap_count": float(len(points)),
    })


IMU_WINDOW_MS = 1000.0  # half-width, so a 2 s window centred on each touch


def _magnitudes(rows: Sequence[dict], spans: Sequence[tuple[float, float]]) -> list[float]:
    """Vector norms of the samples falling inside any window."""
    out: list[float] = []
    for row in rows:
        t = _num(row.get("EventTime"))
        if t is None:
            continue
        if spans and not any(lo <= t <= hi for lo, hi in spans):
            continue
        x, y, z = _num(row.get("X")), _num(row.get("Y")), _num(row.get("Z"))
        if x is None or y is None or z is None:
            continue
        out.append(math.sqrt(x * x + y * y + z * z))
    return out


def imu_features(
    accel: Sequence[dict], gyro: Sequence[dict], anchors: Sequence[float] = ()
) -> dict[str, float]:
    """The 5 motion/grip features: accelerometer and gyroscope magnitude, and dominant tilt.

    Windowed on the touches rather than computed over the whole session, because a walking
    session's statistics are otherwise dominated by gait rather than by how the phone is held.
    With no anchors the whole session is used.

    Timestamps must already be in milliseconds. The reader normalises them, because the archive
    stores accelerometer time in nanoseconds and touch time in milliseconds - a factor of a
    million that would make every window either empty or the entire session.
    """
    spans = [(t - IMU_WINDOW_MS, t + IMU_WINDOW_MS) for t in anchors]

    accel_mag = _magnitudes(accel, spans)
    gyro_mag = _magnitudes(gyro, spans)

    values: dict[str, float | None] = {
        "imu_accel_mag_mean": _mean_or_none(accel_mag),
        "imu_accel_mag_std": _std_or_none(accel_mag),
        "imu_gyro_mag_mean": _mean_or_none(gyro_mag),
        "imu_gyro_mag_std": _std_or_none(gyro_mag),
        "imu_tilt_dominant_rad": _tilt_or_none(accel, spans),
    }
    return _finalise("imu", values)


def _mean_or_none(values: Sequence[float]) -> float | None:
    return sum(values) / len(values) if values else None


def _std_or_none(values: Sequence[float]) -> float | None:
    if len(values) < 2:
        return None
    mean = sum(values) / len(values)
    return math.sqrt(sum((v - mean) ** 2 for v in values) / len(values))


def _tilt_or_none(accel: Sequence[dict], spans: Sequence[tuple[float, float]]) -> float | None:
    """Angle between the mean acceleration vector and the device's z axis.

    Gravity dominates the mean, so this reports how far from flat the phone is held - a grip
    proxy that survives being talked through a payment, which is why it sits with identity
    rather than with tempo.
    """
    xs, ys, zs = [], [], []
    for row in accel:
        t = _num(row.get("EventTime"))
        if t is None or (spans and not any(lo <= t <= hi for lo, hi in spans)):
            continue
        x, y, z = _num(row.get("X")), _num(row.get("Y")), _num(row.get("Z"))
        if x is None or y is None or z is None:
            continue
        xs.append(x); ys.append(y); zs.append(z)
    if not xs:
        return None
    mx, my, mz = (sum(v) / len(v) for v in (xs, ys, zs))
    return math.atan2(math.hypot(mx, my), mz)


def session_row(
    swipe: Mapping[str, float] | None = None,
    pressure: Mapping[str, float] | None = None,
    pin: Mapping[str, float] | None = None,
    size: Mapping[str, float] | None = None,
    tap: Mapping[str, float] | None = None,
    imu: Mapping[str, float] | None = None,
) -> tuple[float, ...]:
    """Assemble one wire-order feature vector from whichever blocks the caller has.

    Every block is optional, and an absent one is filled with each of its features' declared
    `missing` value by `schema.to_vector` rather than being dropped, so the vector is the full
    schema length whatever the source. That is what lets a geometry-only dataset and a full HMOG
    session go through the same model.

    One keyword per block rather than one merged dict, because the keyword is what makes the
    guard below possible: a caller who has no taps writes nothing, and cannot accidentally
    declare an empty block present.

    Order comes from `schema.to_vector` and nowhere else. `behaviour.features` crosses the wire
    as a bare tuple of floats, so nothing downstream can notice two features swapping places.
    """
    row: dict[str, float] = {}
    for block, values in (("swipe", swipe), ("pressure", pressure), ("pin", pin),
                          ("size", size), ("tap", tap), ("imu", imu)):
        if values is None:
            continue
        # A block dict handed in under the wrong keyword is otherwise invisible: to_vector
        # accepts any valid feature name, so pressure values passed as `pin=` would land in the
        # vector, in the right slots, and the caller would never learn the pin block was empty.
        stray = set(values) - set(names_for(block=block))  # type: ignore[arg-type]
        if stray:
            raise KeyError(f"not {block} features: {sorted(stray)}")
        row.update({name: float(v) for name, v in values.items()})
    return to_vector(row)


def touch_rows(
    strokes: Sequence[Stroke],
    granularity: Granularity = Granularity.PER_SESSION,
) -> list[tuple[float, ...]]:
    """One session's strokes -> feature rows, at the granularity the caller asks for.

    `Granularity.PER_SESSION` returns exactly one row aggregated over all the strokes - what
    HMOG's 24-sessions-per-user structure and `model.py` assume. `Granularity.PER_STROKE`
    returns one row per stroke, which is how Touchalytics and FETA are organised and the unit
    the Touchalytics paper classifies on.

    Both return full schema-length vectors; the PIN, tap and IMU blocks are filled with their
    declared `missing` values, because touch samples cannot supply them whichever way the rows
    are cut - tap geometry needs the separate OneFingerTouchEvent table, which this function is
    never handed.

    The size block IS supplied here, but only when the samples actually carry a contact area:
    it rides on the same touch stream as the geometry (HMOG's Contact_size, Flutter's
    PointerEvent radius), so a caller with sizes should not have to assemble the row by hand to
    get them, and a caller without them must not have zero-area touches invented.

    A per-stroke row is just a one-stroke session, so the two paths share one definition of
    every feature instead of drifting apart - the median of a single value is that value.
    """
    groups = [strokes] if granularity is Granularity.PER_SESSION else [[s] for s in strokes]
    return [
        session_row(
            swipe=swipe_features(group),
            pressure=pressure_features(group),
            size=size_features(group) if has_contact_size(group) else None,
        )
        for group in groups
    ]
