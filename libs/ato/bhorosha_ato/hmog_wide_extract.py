"""Standalone HMOG extractor v3 - v2's wide table PLUS the per-key hold ORDER. One run.

No pip, no dependencies beyond the Python standard library, and no import from the rest of
bhorosha_ato: the file can be copied alone to any machine (for example a notebook VM next to
the archive) and run there. It reads the 6 GB archive once and writes two small files:

    python hmog_wide_extract.py <hmog_dataset.zip> [<out.jsonl>]

    hmog_features_v3.jsonl                   a WIDE feature table, one row per session
    hmog_features_v3.jsonl.manifest.json     checksums, row counts and the feature names

Download both. Nothing else from the archive is needed afterwards.

WHY v3 EXISTS
-------------
Identity EER on the v2 table is 0.1192 pooled against a 0.03-0.10 target. Published HMOG SOTA
is 0.036 and gets there with keystroke TIMING, which this project deliberately assigns to the
coaching model so the identity and coaching scores stay independent. Identity is
therefore structurally handicapped, and no reshuffling of v2's eighty columns closes that gap -
measured: sweeping nu moved EER by nothing, dropping features made it monotonically worse.

The one untried idea, recorded in bhorosha_ato/model.py: the RANK ORDER of per-key hold times.
Which keys a person dwells on relative to her other keys is identity-bearing, and an ordering
is invariant to BOTH scale and variance - multiply every hold time by a constant, or make them
noisier, and the ranking survives. That matters because coercion was measured to do exactly
those two things: a 1.6-2.5x stretch WITH high variance, which is why "scale-free" quantile
ratios failed (they halved EER to 5.8% but took coached-session recognition from 88.3% to 0.0%).
An ordering is the one timing-derived quantity that is plausibly coercion-invariant, so it can
go to identity without stealing the coaching signal.

ABSOLUTE per-key hold times are NOT invariant and were already rejected by measurement (1.1%
still-her on coached sessions). They are emitted anyway, and so is a raw per-keycode dump, for
one reason: this is a once-only pass over a 6 GB archive, and the next question has to be
answerable without a second one. That is why v2 carries eighty candidates, and v3 keeps all of
them - every v2 column is produced here with its v2 meaning, unchanged.

HOW ABSENCE IS REPRESENTED - read this before using any rank
------------------------------------------------------------
A key the user never typed has no hold time and therefore no rank. Every `missing` value in
bhorosha_ato/schema.py is 0.0, and 0.0 is also a LEGAL measurement, so a rank written as 0.0
would read as "she holds this key the shortest of all" rather than "no data" - which would
quietly corrupt the very feature this file exists to test. Three things keep those apart:

1. `keyhold_<name>_count` is ALWAYS emitted for all 28 canonical keys, including 0.0. A count
   is not a hold time, so 0.0 here is unambiguous: she completed no press on that key. This
   column is the presence mask, per key, inside the row.
2. `keyhold_<name>_median_ms` and `keyhold_<name>_rank` are emitted ONLY when that count is
   non-zero. They are absent from the JSON object otherwise - never present-and-zero.
3. Ranks are normalised as the Weibull plotting position r/(n+1), the same convention
   model.py already uses for order statistics. For n keys present the rank of the fastest is
   1/(n+1) and of the slowest n/(n+1), so a real rank is always strictly inside (0, 1).
   **0.0 and 1.0 are structurally impossible as measurements.** A reader that fills a gap with
   schema.py's 0.0 substitute therefore produces a value no measurement can produce.

How a consumer MUST use this: gate on the count.

    if row["values"]["keyhold_e_count"] > 0:        # only then are the next two meaningful
        rank   = row["values"]["keyhold_e_rank"]
        median = row["values"]["keyhold_e_median_ms"]

Never `row["values"].get("keyhold_e_rank", 0.0)`, and never let schema.to_vector substitute a
rank: 0.0 sorts below every real rank, so it reads as her fastest key. The equivalent rule for
the medians is the same count gate and there it is the ONLY guard - a median of 0.0 ms is a
legal measurement, because PressTime is integer milliseconds and a down and its up can share a
timestamp. Ranks are self-checking; medians are not.

Also note `keyhold_keys_present`, the number of canonical keys this session has a rank for. It
is the n in r/(n+1), so a consumer can verify any rank arithmetic from the row alone, and 0 says
the session has no typing at all - as 1598 of the v2 table's 2398 rows do not: only the 800
writing sessions carry keystrokes, measured, not assumed.

RANKING RULES, stated so they are reproducible
----------------------------------------------
* Ranked quantity: the MEDIAN hold time of that key in that session. Not the mean - one
  interrupted keypress moves a mean more than the gap between two people.
* Direction: ascending. Rank near 0 is a key she releases quickly, near 1 one she dwells on.
* Population: the canonical keys present in THIS session, nothing else. Not a global key list
  (most sessions would be mostly absent) and not the non-canonical keycodes (then a rank could
  not be re-derived from the row's own medians, and checkability is the point here).
* Ties: keys whose medians are EXACTLY equal share the mean of the positions they occupy -
  a midrank. Two keys at the same median have no order to measure, and breaking the tie by
  keycode would dress a coin flip up as a measurement. Exact float equality on the medians is
  deterministic for a given input, and the sort key is (median, keycode), a total order, so the
  grouping cannot depend on dict or set iteration order.
* Minimum count: none applied. A key pressed once gets a rank from a one-sample median, which
  is noisy. That filter is a modelling choice, so it is left to the consumer - `_count` and
  `_median_ms` are both in the row, so ranks can be recomputed locally over any subset without
  touching the archive again.

WHAT IS CARRIED RAW, AND WHY
----------------------------
`keyhold_codes` on each row is `[[keycode, pairs, median_ms], ...]` for EVERY keycode with a
completed press, sorted by keycode - including the ones outside the canonical 28 (digits,
punctuation, enter). Real writing sessions carry 23-41 distinct keycodes (median 29, measured on
the v2 table's `key_distinct`), so it costs about 500 bytes a row. It is the insurance policy:
if the canonical key set turns out to be wrong, or the next question wants a different
normalisation, the answer is in the table rather than behind another 6 GB pass.

FORMAT AND UNITS - the things that fail silently
------------------------------------------------
KeyPressEvent.csv has NO header, and its columns by POSITION are Systime, PressTime,
ActivityID, PressType, KeyID, Phone_orientation. data_description.pdf prints PressType before
ActivityID; the file does not agree with the document and bhorosha_ato/datasets.py says so
explicitly ("the third field is plainly an ActivityID"). The file wins.

PressTime is in MILLISECONDS here. Accelerometer and Gyroscope EventTime are NANOSECONDS, a
factor of 1e6 away, and that confusion has already caused one wrong table. Only the motion
files are divided (TIME_DIVISOR below); key and touch times are left alone.

KeyID is an Android keycode and is -1 when the touch was not a key at all - the suggestion strip
or the text area. Those rows are counted (`keyhold_nonkey_events`) and then discarded; they must
never become hold times.

v3 vs v2, exhaustively
----------------------
* every v2 column is still produced, by the same code, with the same meaning (v2 dropped
  Contact_size once and reported an empty headline feature as measured; nothing here regresses);
* plus 84 per-key columns (28 keys x count/median/rank), 10 session-level `keyhold_*` columns
  and the raw `keyhold_codes` list;
* plus "keyhold" in `blocks_present`;
* 174 distinct column names in the manifest where v2 had 80, and about 9 MB where v2 was 4.9;
* `rows_per_task` now names all three tasks, zeros included, which is what
  bhorosha_ato.extract._counts compares against;
* rows are written with sorted keys, so the same archive gives a byte-identical table;
* EXTRACTOR_VERSION is 3. bhorosha_ato/extract.py reads versions 1, 2 and 3 by manifest and
  refuses any other version - deliberately loud, because the row contract changes with it.
"""

import csv, datetime, hashlib, io, json, math, os, re, statistics, sys, time, zipfile

# Defaults for a run from the directory that holds the archive; both can be passed on the
# command line instead.
ARCHIVE = "hmog_dataset.zip"
OUT = "hmog_features_v3.jsonl"

# Only every Nth motion sample is read. The sensors run at roughly 220 Hz and these features are
# magnitude statistics, so 44 Hz carries the same information for a fifth of the parsing cost -
# and motion files are the overwhelming bulk of the archive.
IMU_STRIDE = 5
IMU_WINDOW_MS = 1000.0          # half-width: a 2 s window centred on each touch
PIN_LENGTH = 4
NON_KEY_ID, KEYCODE_DEL = -1, 67
ACTION_DOWN, ACTION_UP, ACTION_MOVE = {0, 5}, {1, 6}, {2}
PRESS_DOWN, PRESS_UP = 0, 1
# Must be an int: bhorosha_ato.extract.Manifest.from_dict coerces it with int().
EXTRACTOR_VERSION = 3

# The canonical key set for the ordering feature: 26 letters, space, backspace.
#
# NON_KEY_ID and KEYCODE_DEL above are the two keycodes bhorosha_ato/datasets.py already pins
# (-1 and 67), copied rather than reinvented. The letters and space are not in that module, so
# they come from the Android KeyEvent constants: KEYCODE_A is 29 and A-Z are contiguous through
# KEYCODE_Z at 54, KEYCODE_SPACE is 62. KEYCODE_DEL being 67 is the corroboration that these
# KeyID values really are AOSP keycodes and not some remapping - 67 is only KEYCODE_DEL in that
# table, and datasets.py pinned it against real rows.
#
# If that assumption were still wrong, every per-key column would come back empty and the run
# would be wasted - which is why `keyhold_codes` carries the raw per-keycode counts for every
# session, canonical or not. The sanity check after the run is one line: the top keycodes in
# `keyhold_codes` across writing sessions should be 62 (space), 33 (e), 48 (t), 29 (a).
KEYCODE_A, KEYCODE_SPACE = 29, 62
CANONICAL_KEYS = tuple(
    (chr(ord("a") + i), KEYCODE_A + i) for i in range(26)
) + (("space", KEYCODE_SPACE), ("del", KEYCODE_DEL))
CANONICAL_BY_CODE = {code: name for name, code in CANONICAL_KEYS}

USER_MEMBER = re.compile(r"^public_dataset/(\d+)\.zip$")
SESSION_DIR = re.compile(r"^\d+/(\d+)_session_(\d+)/$")

COLUMNS = {
    "Activity.csv": ("ID", "SubjectID", "Session_number", "Start_time", "End_time",
                     "Relative_Start_time", "Relative_End_time", "Gesture_scenario",
                     "TaskID", "ContentID"),
    "TouchEvent.csv": ("Systime", "EventTime", "ActivityID", "Pointer_count", "PointerID",
                       "ActionID", "X", "Y", "Pressure", "Contact_size", "Phone_orientation"),
    "KeyPressEvent.csv": ("Systime", "PressTime", "ActivityID", "PressType", "KeyID",
                          "Phone_orientation"),
    "OneFingerTouchEvent.csv": ("Systime", "PressTime", "ActivityID", "TapID", "Tap_type",
                                "Action_type", "X", "Y", "Pressure", "Contact_size",
                                "Phone_orientation"),
    "Accelerometer.csv": ("Systime", "EventTime", "ActivityID", "X", "Y", "Z",
                          "Phone_orientation"),
    "Gyroscope.csv": ("Systime", "EventTime", "ActivityID", "X", "Y", "Z", "Phone_orientation"),
}
# Motion time is nanoseconds; touch and key time are milliseconds. Undocumented, verified.
TIME_DIVISOR = {"Accelerometer.csv": 1e6, "Gyroscope.csv": 1e6}

TASKS = ("reading", "writing", "map")
TASK_BY_ID = {i: TASKS[((i - 1) // 2) % 3] for i in range(1, 25)}
POSTURE_BY_ID = {i: ("sit" if i % 2 else "walk") for i in range(1, 25)}

MISSING = 0.0


def num(v):
    if v in (None, ""):
        return None
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def rows(blob, filename, stride=1):
    if not blob.strip():
        return []
    names = COLUMNS[filename]
    div = TIME_DIVISOR.get(filename, 1.0)
    out = []
    for i, fields in enumerate(csv.reader(io.StringIO(blob.decode("utf-8", "replace"), newline=""))):
        if stride > 1 and i % stride:
            continue
        if len(fields) != len(names):
            continue
        row = dict(zip(names, fields))
        if div != 1.0:
            t = num(row.get("EventTime"))
            if t is not None:
                row["EventTime"] = t / div
        out.append(row)
    return out


def pct(vals, q):
    if not vals:
        return None
    s = sorted(vals)
    if len(s) == 1:
        return s[0]
    pos = q * (len(s) - 1)
    lo = int(math.floor(pos))
    hi = min(lo + 1, len(s) - 1)
    return s[lo] + (s[hi] - s[lo]) * (pos - lo)


def med(vals):
    vals = [v for v in vals if v is not None]
    return statistics.median(vals) if vals else None


def strokes_from_touch(touch):
    out, cur = [], []
    for r in touch:
        a, t = num(r.get("ActionID")), num(r.get("EventTime"))
        x, y = num(r.get("X")), num(r.get("Y"))
        if None in (a, t, x, y):
            continue
        # Contact_size is kept here, which v1 did not do - it parsed the column into the row
        # and then dropped it when building the sample, so size_block had nothing to read.
        # It matters because Pressure is a dead constant on these handsets and size is not.
        s = {"x": x, "y": y, "t": t, "p": num(r.get("Pressure")),
             "size": num(r.get("Contact_size"))}
        code = int(a)
        if code in ACTION_DOWN:
            if len(cur) > 1:
                out.append(cur)
            cur = [s]
        elif code in ACTION_MOVE and cur:
            cur.append(s)
        elif code in ACTION_UP and cur:
            cur.append(s); out.append(cur); cur = []
    if len(cur) > 1:
        out.append(cur)
    return out


def one_stroke(st):
    """Per-stroke values. None where the stroke cannot support the measurement."""
    d = {}
    d["swipe_start_x"], d["swipe_start_y"] = st[0]["x"], st[0]["y"]
    d["swipe_end_x"], d["swipe_end_y"] = st[-1]["x"], st[-1]["y"]
    dur = st[-1]["t"] - st[0]["t"]
    d["swipe_duration_ms"] = dur if dur > 0 else None
    dx, dy = st[-1]["x"] - st[0]["x"], st[-1]["y"] - st[0]["y"]
    d["swipe_angle_rad"] = math.atan2(dy, dx) if (dx or dy) else None
    length = sum(math.hypot(b["x"] - a["x"], b["y"] - a["y"]) for a, b in zip(st, st[1:]))
    d["swipe_length_px"] = length
    d["swipe_v_mean"] = (length / dur) if dur > 0 else None
    vs, mids = [], []
    for a, b in zip(st, st[1:]):
        dt = b["t"] - a["t"]
        if dt > 0:
            vs.append(math.hypot(b["x"] - a["x"], b["y"] - a["y"]) / dt)
            mids.append((a["t"] + b["t"]) / 2)
    for q, name in ((0.2, "swipe_v_p20"), (0.5, "swipe_v_p50"), (0.8, "swipe_v_p80")):
        d[name] = pct(vs, q)
    d["swipe_accel_mean"] = ((vs[-1] - vs[0]) / (mids[-1] - mids[0])
                             if len(vs) > 1 and mids[-1] > mids[0] else None)
    ps = [s["p"] for s in st if s["p"] is not None]
    d["pressure_mean"] = statistics.fmean(ps) if ps else None
    d["pressure_max"] = max(ps) if ps else None
    return d


def spread(vals):
    """Interquartile range: how consistent, rather than how much.

    Chosen over standard deviation because one clipped stroke or an accidental edge swipe moves
    a deviation more than the gap between two people, which is the same reason the central
    values here are medians.
    """
    vals = [v for v in vals if v is not None]
    if len(vals) < 4:
        return None
    return pct(vals, 0.75) - pct(vals, 0.25)


def size_block(sts):
    """Contact area, which v1 parsed into every sample and then never used.

    This is the replacement for the pressure features: the handsets report pressure as a
    constant 1.0, while contact size genuinely varies between people. The Touchalytics work
    lists "area covered" among its useful features for the same reason.
    """
    per = []
    for st in sts:
        vals = [s["size"] for s in st if s.get("size") is not None]
        if vals:
            per.append((statistics.fmean(vals), max(vals)))
    if not per:
        return {}
    means = [p[0] for p in per]
    return {
        "size_mean": med(means),
        "size_max": med([p[1] for p in per]),
        "size_iqr": spread(means),
    }


def swipe_block(sts):
    """Medians across strokes. A mean would let one fling outweigh the gap between two people.
    Angle uses a circular mean: a median of directions lands in the +/-pi seam, where two
    leftward swipes at +3.10 and -3.10 average to 0.0, which is rightward."""
    if not sts:
        return {}
    per = [one_stroke(s) for s in sts]
    out = {}
    for name in ("swipe_duration_ms", "swipe_start_x", "swipe_start_y", "swipe_end_x",
                 "swipe_end_y", "swipe_length_px", "swipe_v_mean", "swipe_v_p20",
                 "swipe_v_p50", "swipe_v_p80", "swipe_accel_mean", "pressure_mean",
                 "pressure_max"):
        out[name] = med([p.get(name) for p in per])
    # The spread of each per-stroke quantity, alongside its centre. v1 kept only the centre.
    for name in ("swipe_duration_ms", "swipe_length_px", "swipe_v_mean", "swipe_v_p50",
                 "swipe_start_x", "swipe_start_y", "swipe_end_x", "swipe_end_y"):
        out[name + "_iqr"] = spread([p.get(name) for p in per])
    out["swipe_count"] = float(len(per))

    angs = [p["swipe_angle_rad"] for p in per if p.get("swipe_angle_rad") is not None]
    if angs:
        sx = sum(math.cos(a) for a in angs); sy = sum(math.sin(a) for a in angs)
        out["swipe_angle_rad"] = math.atan2(sy, sx) if (abs(sx) + abs(sy)) > 1e-9 else None
    return out


def key_events(keys):
    """KeyPressEvent rows -> (holds by keycode, diagnostics).

    The pairing rule is deliberately the SAME one `pin_block` uses, so the two blocks can never
    disagree about how many presses a session contained:

    * KeyID == -1 is not a key and is dropped (counted as `nonkey`);
    * events are sorted by (PressTime, PressType, KeyID), so at an identical timestamp the DOWN
      sorts before the UP and a 0 ms hold is recorded rather than the UP being orphaned;
    * a DOWN while the same key is already pending replaces it - Android key auto-repeat emits
      repeated DOWNs - and the replaced one is counted as unmatched;
    * an UP with no pending DOWN is counted and dropped (`unmatched_up`): the session can begin
      mid-press.

    Rows are sorted rather than trusted in file order because the file is Systime-ordered and
    PressTime is not guaranteed to be.

    There is deliberately NO "negative hold" counter, because sorting by time makes a negative
    hold unobservable: an UP timestamped before its DOWN sorts first, finds nothing pending, and
    is counted as an unmatched UP, leaving the DOWN unmatched too. The `t >= dn` guard below is
    kept anyway to mirror `pin_block` exactly, and anything it ever caught would be counted as
    an unmatched UP. A column that is zero by construction is how an earlier extractor got a dead
    pressure feature and a dead scroll block, so one is not added here.
    """
    ev, diag = [], {"nonkey": 0, "unparsed": 0, "other_presstype": 0,
                    "unmatched_down": 0, "unmatched_up": 0}
    for r in keys:
        t, p, k = num(r.get("PressTime")), num(r.get("PressType")), num(r.get("KeyID"))
        if None in (t, p, k):
            diag["unparsed"] += 1
            continue
        if int(k) == NON_KEY_ID:
            diag["nonkey"] += 1
            continue
        ev.append((t, int(p), int(k)))
    ev.sort()

    holds, pend = {}, {}
    for t, p, k in ev:
        if p == PRESS_DOWN:
            if k in pend:
                diag["unmatched_down"] += 1
            pend[k] = t
        elif p == PRESS_UP:
            if k in pend:
                dn = pend.pop(k)
                if t >= dn:
                    holds.setdefault(k, []).append(t - dn)
                else:
                    diag["unmatched_up"] += 1      # unreachable after the sort; see above
            else:
                diag["unmatched_up"] += 1
        else:
            diag["other_presstype"] += 1
    diag["unmatched_down"] += len(pend)
    return holds, diag


def pin_block(keys, taps):
    """Positional PIN slots filled from quantiles: HMOG types free text, so there is no fourth
    digit. Same transform for every subject, so the comparison stays fair."""
    ev = []
    for r in keys:
        t, p, k = num(r.get("PressTime")), num(r.get("PressType")), num(r.get("KeyID"))
        if None in (t, p, k) or int(k) == NON_KEY_ID:
            continue
        ev.append((t, int(p), int(k)))
    ev.sort()                                  # rows are Systime-ordered; press time is not
    holds, pairs, pend = [], [], {}
    for t, p, k in ev:
        if p == PRESS_DOWN:
            pend[k] = t
        elif p == PRESS_UP and k in pend:
            dn = pend.pop(k)
            if t >= dn:
                holds.append(t - dn); pairs.append((dn, t))
    pairs.sort()
    flights = [pairs[i + 1][0] - pairs[i][1] for i in range(len(pairs) - 1)
               if pairs[i + 1][0] >= pairs[i][1]]
    spans = [pairs[i + PIN_LENGTH - 1][1] - pairs[i][0]
             for i in range(len(pairs) - PIN_LENGTH + 1)]
    out = {}
    for i, q in enumerate((0.2, 0.4, 0.6, 0.8), 1):
        out[f"pin_hold_{i}_ms"] = pct(holds, q)
    for i, q in enumerate((0.25, 0.5, 0.75), 1):
        out[f"pin_flight_{i}_ms"] = pct(flights, q)
    out["pin_total_entry_ms"] = pct(spans, 0.5)
    dels = sum(1 for r in keys if num(r.get("KeyID")) == KEYCODE_DEL
               and num(r.get("PressType")) == PRESS_DOWN)
    out["pin_backspaces"] = (100.0 * dels / len(holds)) if holds else None
    pts = [(num(r.get("X")), num(r.get("Y"))) for r in taps]
    pts = [(x, y) for x, y in pts if x is not None and y is not None]
    if pts:
        cx = statistics.fmean(p[0] for p in pts); cy = statistics.fmean(p[1] for p in pts)
        out["pin_tap_offset_mean_px"] = med([math.hypot(x - cx, y - cy) for x, y in pts])
    out["pin_pressure_mean"] = med([num(r.get("Pressure")) for r in taps])
    return out


# The ten keycodes that carry the most presses across the archive are resolved per session
# rather than fixed here, so a session that used a different set still produces a dense row.
PER_KEY_SLOTS = 10


def per_key_block(keys):
    """v2's per-key block, unchanged, kept so no v2 column regresses.

    It ranks the ten busiest keycodes by PRESS COUNT and reports their hold medians in those
    slots, which is not the same thing as v3's `keyhold_*` block: slot 1 is whichever key she
    pressed most, so `key_1_hold_ms` is not comparable across sessions that typed different
    text. That is precisely the weakness `keyhold_*` fixes by naming the key. Both are here
    because dropping a v2 column would invalidate every measurement already made against it.
    """
    ev = []
    for r in keys:
        t, p, k = num(r.get("PressTime")), num(r.get("PressType")), num(r.get("KeyID"))
        if None in (t, p, k) or int(k) == NON_KEY_ID:
            continue
        ev.append((t, int(p), int(k)))
    ev.sort()
    holds = {}
    pend = {}
    for t, p, k in ev:
        if p == PRESS_DOWN:
            pend[k] = t
        elif p == PRESS_UP and k in pend:
            dn = pend.pop(k)
            if t >= dn:
                holds.setdefault(k, []).append(t - dn)
    if not holds:
        return {}

    ranked = sorted(holds, key=lambda k: -len(holds[k]))[:PER_KEY_SLOTS]
    out = {}
    medians = []
    for slot, key in enumerate(ranked, 1):
        m = med(holds[key])
        out[f"key_{slot}_hold_ms"] = m
        medians.append(m)
    # Normalised shape: each slot against the session's own middle hold, so the profile of
    # which keys are slow survives a session typed slowly throughout.
    centre = med(medians)
    if centre:
        for slot, m in enumerate(medians, 1):
            out[f"key_{slot}_hold_ratio"] = m / centre
    out["key_hold_iqr"] = spread(medians)
    out["key_distinct"] = float(len(holds))
    return out


def _midranks(medians):
    """{keycode: normalised rank} for {keycode: median hold}, ties sharing a midrank.

    Normalisation is r/(n+1) - the Weibull plotting position, as in model.py's order-statistic
    anchors - so every real rank lies strictly inside (0, 1) and neither 0.0 nor 1.0 can be a
    measurement. That is what stops schema.py's 0.0 `missing` substitute from being read as
    "her fastest key".

    Determinism: the sort key is (median, keycode), a total order over distinct keys, and tie
    groups are formed by exact float equality on the medians. No set or dict iteration order is
    involved.
    """
    order = sorted(medians, key=lambda code: (medians[code], code))
    n = len(order)
    out, i = {}, 0
    while i < n:
        j = i
        while j + 1 < n and medians[order[j + 1]] == medians[order[i]]:
            j += 1
        # Positions are 1-based, so the tie group spans i+1 .. j+1 and shares their mean.
        mid = ((i + 1) + (j + 1)) / 2.0
        for code in order[i:j + 1]:
            out[code] = mid / (n + 1.0)
        i = j + 1
    return out


def keyhold_block(keys):
    """The ordering feature: per-key hold counts, medians, and the RANK of each median.

    Returns (values, codes, present). `codes` is the raw per-keycode dump that goes on the row
    beside `values`; `present` is what `blocks_present["keyhold"]` records.

    Absence is NOT a zero. `_count` is emitted for all 28 canonical keys always (a count of 0 is
    an honest measurement - she pressed nothing), while `_median_ms` and `_rank` are emitted
    only where that count is non-zero. See the module docstring for the rule a consumer has to
    follow, and why a substituted 0.0 rank is detectable but a substituted 0.0 median is not.
    """
    holds, diag = key_events(keys)
    canon = {code: hs for code, hs in sorted(holds.items()) if code in CANONICAL_BY_CODE}
    medians = {code: float(med(hs)) for code, hs in canon.items()}
    ranks = _midranks(medians)

    out = {}
    # Always, for every canonical key, present or not: this is the per-key presence mask.
    for name, code in CANONICAL_KEYS:
        out[f"keyhold_{name}_count"] = float(len(holds.get(code, ())))
    # Only where there is something to report. Absent beats zero - see the docstring.
    for code in medians:
        name = CANONICAL_BY_CODE[code]
        out[f"keyhold_{name}_median_ms"] = medians[code]
        out[f"keyhold_{name}_rank"] = ranks[code]

    # Session level, all ten of these always written - every one is a count, and a count of 0 is
    # a measurement rather than a gap.
    out["keyhold_keys_present"] = float(len(medians))   # canonical keys ranked: the n in r/(n+1)
    out["keyhold_pairs_canon"] = float(sum(len(hs) for hs in canon.values()))
    out["keyhold_pairs_total"] = float(sum(len(hs) for hs in holds.values()))   # canonical or not
    out["keyhold_keys_all"] = float(len(holds))         # distinct keycodes, canonical or not
    out["keyhold_rows"] = float(len(keys))              # KeyPressEvent rows that parsed at all
    # Diagnostics, so a quiet parsing failure shows up as a number rather than as a feature set
    # that merely looks thin - which is how the dead pressure column survived v1.
    out["keyhold_nonkey_events"] = float(diag["nonkey"])            # KeyID == -1
    out["keyhold_unparsed_rows"] = float(diag["unparsed"])          # no time/type/keycode
    out["keyhold_other_presstype"] = float(diag["other_presstype"])  # PressType not 0 or 1
    out["keyhold_unmatched_down"] = float(diag["unmatched_down"])
    out["keyhold_unmatched_up"] = float(diag["unmatched_up"])

    codes = [[code, len(holds[code]), float(med(holds[code]))] for code in sorted(holds)]
    return out, codes, bool(medians)


def tap_block(taps):
    """Where her taps land, beyond v1's single mean distance from the centroid."""
    pts = [(num(r.get("X")), num(r.get("Y")), num(r.get("Contact_size"))) for r in taps]
    pts = [(x, y, s) for x, y, s in pts if x is not None and y is not None]
    if not pts:
        return {}
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    cx, cy = statistics.fmean(xs), statistics.fmean(ys)
    dists = [math.hypot(x - cx, y - cy) for x, y, _ in pts]
    sizes = [s for _, _, s in pts if s is not None]
    return {
        "tap_offset_med": med(dists),
        "tap_offset_iqr": spread(dists),
        "tap_x_iqr": spread(xs),
        "tap_y_iqr": spread(ys),
        "tap_size_med": med(sizes) if sizes else None,
        "tap_count": float(len(pts)),
    }


def scroll_block(rows):
    """ScrollEvent, as v2 wrote it. Kept bug-for-bug ON PURPOSE.

    `COLUMNS` has no "ScrollEvent.csv" entry, so the caller's reader raises KeyError, swallows
    it, and hands this function an empty list every time. The measured consequence is visible in
    the v2 manifest: of the five scroll names only `scroll_count` appears at all, and it is 0.0
    in all 2398 rows. So this block has never measured anything.

    It is not fixed here because the fix would mean guessing ScrollEvent.csv's column order,
    and a guessed layout produces plausible wrong numbers rather than an error - the exact
    failure mode this extractor exists to avoid. Instead the manifest records one raw sample
    line and the field-count histogram, which is enough to write the real layout down for v4
    without another pass over the archive. Changing `scroll_count` to a real number here would
    also silently change the meaning of a column v2 already shipped.
    """
    dx = [num(r.get("Distance_X")) for r in rows]
    dy = [num(r.get("Distance_Y")) for r in rows]
    sz = [num(r.get("Current_size")) for r in rows]
    out = {
        "scroll_dx_med": med(dx), "scroll_dy_med": med(dy),
        "scroll_dy_iqr": spread([v for v in dy if v is not None]),
        "scroll_size_med": med(sz),
        "scroll_count": float(len([v for v in dy if v is not None])),
    }
    return {k: v for k, v in out.items() if v is not None}


def imu_block(accel, gyro, anchors):
    """Windowed on the touches: a walking session's statistics are otherwise gait, not grip."""
    spans = [(t - IMU_WINDOW_MS, t + IMU_WINDOW_MS) for t in anchors]

    def mags(rs):
        out = []
        for r in rs:
            t = num(r.get("EventTime"))
            if t is None or (spans and not any(lo <= t <= hi for lo, hi in spans)):
                continue
            x, y, z = num(r.get("X")), num(r.get("Y")), num(r.get("Z"))
            if None in (x, y, z):
                continue
            out.append((math.sqrt(x * x + y * y + z * z), x, y, z))
        return out

    a, g = mags(accel), mags(gyro)
    out = {}
    out["imu_accel_mag_mean"] = statistics.fmean(v[0] for v in a) if a else None
    out["imu_accel_mag_std"] = statistics.pstdev([v[0] for v in a]) if len(a) > 1 else None
    out["imu_gyro_mag_mean"] = statistics.fmean(v[0] for v in g) if g else None
    out["imu_gyro_mag_std"] = statistics.pstdev([v[0] for v in g]) if len(g) > 1 else None
    if a:
        mx = statistics.fmean(v[1] for v in a); my = statistics.fmean(v[2] for v in a)
        mz = statistics.fmean(v[3] for v in a)
        out["imu_tilt_dominant_rad"] = math.atan2(math.hypot(mx, my), mz)
        # Per-axis, not only the magnitude: how the phone is tilted is directional, and a
        # magnitude collapses three numbers into one and loses the orientation entirely.
        for axis, idx in (("x", 1), ("y", 2), ("z", 3)):
            vals = [v[idx] for v in a]
            out[f"imu_accel_{axis}_mean"] = statistics.fmean(vals)
            out[f"imu_accel_{axis}_iqr"] = spread(vals)
    if g:
        for axis, idx in (("x", 1), ("y", 2), ("z", 3)):
            out[f"imu_gyro_{axis}_iqr"] = spread([v[idx] for v in g])
    return out


def main(archive=ARCHIVE, out_path=OUT, limit_users=None):
    if not os.path.exists(archive):
        sys.exit(f"archive not found: {archive}")
    started = time.time()
    # What ScrollEvent.csv actually looks like, recorded once for v4 rather than parsed now.
    scroll_sample, scroll_fields = None, {}
    with zipfile.ZipFile(archive) as outer:
        users = sorted(m.group(1) for n in outer.namelist() if (m := USER_MEMBER.match(n)))
        if limit_users:
            users = users[:limit_users]
        print(f"hmog_extract v{EXTRACTOR_VERSION}: {len(users)} users -> {out_path}", flush=True)
        written = 0
        per_user, per_task = {}, {task: 0 for task in TASKS}
        seen_names = set()
        with open(out_path, "w") as fh:
            for idx, uid in enumerate(users, 1):
                blob = outer.read(f"public_dataset/{uid}.zip")
                with zipfile.ZipFile(io.BytesIO(blob)) as inner:
                    dirs = sorted(
                        (m.group(0) for n in inner.namelist() if (m := SESSION_DIR.match(n))),
                        key=lambda d: int(d.rstrip("/").rsplit("_", 1)[1]))
                    for d in dirs:
                        def rd(fn, stride=1):
                            try:
                                return rows(inner.read(d + fn), fn, stride)
                            except KeyError:
                                return []
                        act = rd("Activity.csv")
                        tid = next((int(v) for r in act
                                    if (v := num(r.get("TaskID"))) is not None), None)
                        if tid not in TASK_BY_ID:
                            continue
                        sts = strokes_from_touch(rd("TouchEvent.csv"))
                        anchors = [s[0]["t"] for s in sts]
                        keys_rows = rd("KeyPressEvent.csv")
                        taps_rows = rd("OneFingerTouchEvent.csv")
                        vals = {}
                        vals.update(swipe_block(sts))
                        vals.update(size_block(sts))
                        vals.update(pin_block(keys_rows, taps_rows))
                        vals.update(per_key_block(keys_rows))
                        keyhold, keyhold_codes, keyhold_present = keyhold_block(keys_rows)
                        vals.update(keyhold)
                        vals.update(tap_block(taps_rows))
                        vals.update(scroll_block(rd("ScrollEvent.csv")))
                        vals.update(imu_block(rd("Accelerometer.csv", IMU_STRIDE),
                                              rd("Gyroscope.csv", IMU_STRIDE), anchors))
                        for name in vals:
                            seen_names.add(name)

                        # One unparsed ScrollEvent line, kept for the manifest only. Reading the
                        # member costs nothing next to the motion files and it is the only way
                        # the dead scroll block above becomes fixable without a second pass.
                        try:
                            raw_scroll = inner.read(d + "ScrollEvent.csv")
                        except KeyError:
                            raw_scroll = b""
                        for line in raw_scroll.decode("utf-8", "replace").splitlines():
                            if line.strip():
                                count = str(len(line.split(",")))
                                scroll_fields[count] = scroll_fields.get(count, 0) + 1
                                if scroll_sample is None:
                                    scroll_sample = line.strip()

                        present = {
                            "swipe": bool(sts),
                            "pressure": vals.get("pressure_mean") is not None,
                            "pin": vals.get("pin_hold_1_ms") is not None,
                            "imu": vals.get("imu_accel_mag_mean") is not None,
                            # New in v3. True when at least one canonical key has a completed
                            # press, which is exactly when the `_median_ms` and `_rank` columns
                            # exist. False says the session has no typing - it does NOT say the
                            # counts are missing, those are always written.
                            "keyhold": keyhold_present,
                        }
                        rec = {
                            "user": uid,
                            "session": d.rstrip("/").rsplit("/", 1)[-1],
                            "task_id": tid,
                            "task": TASK_BY_ID[tid],
                            "posture": POSTURE_BY_ID[tid],
                            # Stored as a mapping, not a positional vector: the name list is
                            # not frozen while the set is still being chosen, and a positional
                            # row would silently shift the day one feature is added.
                            "values": {k: float(v) for k, v in vals.items() if v is not None},
                            "blocks_present": present,
                            # [[keycode, pairs, median_ms], ...] for every keycode pressed,
                            # canonical or not, sorted by keycode. The insurance policy.
                            "keyhold_codes": keyhold_codes,
                        }
                        # sort_keys so the same archive gives a byte-identical table: it pins
                        # the output against dict insertion order, which is the one thing a
                        # later refactor of the blocks above could change invisibly.
                        fh.write(json.dumps(rec, sort_keys=True) + "\n")
                        written += 1
                        per_user[uid] = per_user.get(uid, 0) + 1
                        per_task[rec["task"]] = per_task.get(rec["task"], 0) + 1
                # Sparse by design: one line per user, not per session. This run takes the
                # better part of an hour and 2400 lines of progress is not progress.
                print(f"[{idx}/{len(users)}] {uid}: {per_user.get(uid, 0)} sessions "
                      f"({written} total, {time.time()-started:.0f}s)", flush=True)

    digest = hashlib.sha256()
    with open(out_path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            digest.update(chunk)
    manifest = {
        "dataset": "hmog",
        "source": os.path.abspath(archive),
        "source_bytes": os.path.getsize(archive),
        "table": os.path.basename(out_path),
        "table_sha256": digest.hexdigest(),
        "table_bytes": os.path.getsize(out_path),
        "rows": written,
        "schema_length": len(seen_names),
        "schema_names": sorted(seen_names),
        "rows_per_user": dict(sorted(per_user.items())),
        # Every task key, zeros included. bhorosha_ato.extract._counts builds this map over all
        # three tasks, and its comparison is an equality: a task that happened to produce no
        # rows would be an absent key here and the table would be rejected as stale.
        "rows_per_task": per_task,
        "imu_stride": IMU_STRIDE,
        "extractor_version": EXTRACTOR_VERSION,
        "generated_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "elapsed_seconds": round(time.time() - started, 1),
        # Not read by anything; see scroll_block's docstring. One line of the file nobody has
        # ever parsed, so its column order can be written down without re-reading 6 GB.
        "scroll_sample_row": scroll_sample,
        "scroll_field_counts": dict(sorted(scroll_fields.items())),
    }
    # Sibling name is <table>.manifest.json - appended, not substituted. bhorosha_ato.extract's
    # reader looks for exactly that, and a near-miss here costs a whole re-run of the archive.
    mpath = out_path + ".manifest.json"
    with open(mpath, "w") as fh:
        json.dump(manifest, fh, indent=2)
    print(f"\nrows:    {written}")
    print(f"users:   {len(per_user)}  per task: {per_task}")
    print(f"columns: {len(seen_names)} distinct feature names")
    print(f"table:   {out_path} ({os.path.getsize(out_path)/1e6:.1f} MB)")
    print(f"manifest: {mpath}")
    print("download BOTH files; the manifest is what makes a truncated table detectable")
    return manifest


if __name__ == "__main__":
    main(*sys.argv[1:3])
