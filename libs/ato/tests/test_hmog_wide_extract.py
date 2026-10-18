"""The standalone v3 extractor, run end to end over a fabricated nested-zip archive.

bhorosha_ato/hmog_wide_extract.py runs ONCE, over a 6.13 GB archive that is not
redistributable and is not on this machine. v1 of that extractor shipped four bugs and v2
shipped one, and every single one of them produced plausible-looking wrong numbers rather than
an error - a dead pressure column, a dropped Contact_size, a scroll block that has never parsed
anything. There is no second run to catch that in, so the per-key arithmetic is pinned here
against values computed by hand, over an archive with the real nesting and the real headerless
column order.

The fixture deliberately contains every shape that can corrupt the ordering feature:

    key typed twice        a (29), holds 90 and 110        -> median 100.0
    key typed once         b (30), hold 100                -> median 100.0, ties with a
    key typed three times  c (31), holds 180, 200, 260     -> median 200.0
    space                  62, holds 40 and 60             -> median 50.0
    unmatched DOWN         d (32), down with no up         -> no hold, count 0
    unmatched UP           e (33), up with no down         -> no hold, count 0
    not a key at all       KeyID -1, a full down/up pair   -> ignored entirely
    non-canonical key      7 (KEYCODE_0), one pair         -> totals only, no named column
    never typed            z (54), del (67), 20 others     -> count 0, no median, no rank

so the ranked population is exactly {space, a, b, c}, n = 4, and with ties sharing a midrank and
the Weibull r/(n+1) normalisation the four ranks are hand-computable:

    space  position 1          -> 1 / 5   = 0.2
    a      positions 2 and 3   -> 2.5 / 5 = 0.5     (exact tie with b)
    b      positions 2 and 3   -> 2.5 / 5 = 0.5
    c      position 4          -> 4 / 5   = 0.8

A second user types one key only, which is the n = 1 edge: its rank is 1/2 = 0.5, not 1.0 and
not 0.0 - the property the whole encoding rests on.
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import zipfile
from pathlib import Path

import pytest

from bhorosha_ato import extract

V3_PATH = Path(__file__).resolve().parents[1] / "bhorosha_ato" / "hmog_wide_extract.py"


def _load_v3():
    """Import the standalone script by path.

    It must not import the rest of bhorosha_ato - it is copied alone to the machine that holds
    the archive - so it is loaded by path, as a standalone file. Loading it by path is also the
    only way this test proves the file that will actually be copied and run.
    """
    spec = importlib.util.spec_from_file_location("hmog_extract_v3", V3_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


v3 = _load_v3()


# --- the fabricated archive ------------------------------------------------

def _activity_csv(task_id: int) -> str:
    """Headerless, TaskID in its real position (9th of 10), as in test_datasets.py."""
    return f"x,100669,1,0,1,0,1,{1 if task_id % 2 else 2},{task_id},1\n"


def _keypress_csv(events: list[tuple[int, int, int]]) -> str:
    """events are (PressTime_ms, PressType, KeyID).

    Column order is the FILE's, not data_description.pdf's: Systime, PressTime, ActivityID,
    PressType, KeyID, Phone_orientation. Systime is deliberately written in reverse order of
    PressTime, because the extractor is supposed to sort on PressTime and reading the file in
    its stored order would pair the wrong events.
    """
    lines = []
    for index, (press_time, press_type, key_id) in enumerate(events):
        systime = 1_700_000_000 - index
        lines.append(f"{systime},{press_time},100669091000001,{press_type},{key_id},0")
    return "\n".join(lines) + ("\n" if lines else "")


DOWN, UP = 0, 1

# The session described in the module docstring.
WRITING_EVENTS: list[tuple[int, int, int]] = [
    (1000, DOWN, 29), (1090, UP, 29),        # a: hold 90
    (2000, DOWN, 29), (2110, UP, 29),        # a: hold 110   -> median 100.0
    (3000, DOWN, 30), (3100, UP, 30),        # b: hold 100   -> median 100.0, ties with a
    (4000, DOWN, 31), (4180, UP, 31),        # c: hold 180
    (5000, DOWN, 31), (5200, UP, 31),        # c: hold 200
    (6000, DOWN, 31), (6260, UP, 31),        # c: hold 260   -> median 200.0
    (7000, DOWN, 62), (7040, UP, 62),        # space: hold 40
    (8000, DOWN, 62), (8060, UP, 62),        # space: hold 60 -> median 50.0
    (9000, DOWN, 32),                        # d: unmatched down
    (9500, UP, 33),                          # e: unmatched up
    (9600, DOWN, -1), (9700, UP, -1),        # not a key: the suggestion strip or text area
    (9800, DOWN, 7), (9850, UP, 7),          # KEYCODE_0: counted in the totals, not named
]

# User two: one key, pressed once. n = 1.
SINGLE_KEY_EVENTS: list[tuple[int, int, int]] = [(500, DOWN, 29), (570, UP, 29)]


# A ScrollEvent.csv to put in one session. Its real column order is unknown - no module in this
# repo declares it - so the extractor must not parse it, only sample it for the manifest.
SCROLL_CSV = (
    "1396395534261,2739159,100669091000001,1,0,-3.5,12.0,0.0215,0\r\n"
    "1396395534299,2739197,100669091000001,1,0,-1.0,8.0,0.0218,0\r\n"
)


def _inner_zip(
    path: Path, user: str, sessions: dict[int, tuple[int, str]], scroll_in: int | None = None
) -> bytes:
    """One user's zip: {session_number: (task_id, keypress_csv)}, with the real directory names.

    The other event files are written empty, which is not a convenience: KeyPressEvent.csv is
    0 bytes in every reading session of the real archive and TouchEvent is near-empty in the
    writing ones, so a row built from one file alone is the normal case, not a degenerate one.
    `scroll_in` names the one session that gets a ScrollEvent.csv - most sessions have none, and
    the extractor has to survive both.
    """
    with zipfile.ZipFile(path, "w") as z:
        for number, (task_id, keypress) in sorted(sessions.items()):
            base = f"{user}/{user}_session_{number}/"
            z.writestr(base, "")
            z.writestr(base + "Activity.csv", _activity_csv(task_id))
            z.writestr(base + "TouchEvent.csv", "")
            z.writestr(base + "KeyPressEvent.csv", keypress)
            z.writestr(base + "OneFingerTouchEvent.csv", "")
            z.writestr(base + "Accelerometer.csv", "")
            z.writestr(base + "Gyroscope.csv", "")
            if number == scroll_in:
                z.writestr(base + "ScrollEvent.csv", SCROLL_CSV)
    return path.read_bytes()


@pytest.fixture(scope="module")
def archive(tmp_path_factory) -> Path:
    """The archive's real shape: per-user zips inside public_dataset/, plus the PDF."""
    directory = tmp_path_factory.mktemp("v3")
    users = {
        # reading first, so the extractor's session ordering is exercised, and the writing
        # session carries every hand-computed case.
        "100669": {1: (1, ""), 2: (3, _keypress_csv(WRITING_EVENTS))},
        "151985": {1: (3, _keypress_csv(SINGLE_KEY_EVENTS))},
    }
    path = directory / "hmog_dataset.zip"
    with zipfile.ZipFile(path, "w") as z:
        z.writestr("public_dataset/", "")
        for user, sessions in users.items():
            blob = _inner_zip(directory / f"{user}.zip", user, sessions,
                              scroll_in=2 if user == "100669" else None)
            z.writestr(f"public_dataset/{user}.zip", blob)
        z.writestr("public_dataset/data_description.pdf", b"%PDF-1.4 stand-in")
    return path


@pytest.fixture(scope="module")
def run(archive, tmp_path_factory) -> tuple[list[dict], dict, Path]:
    """Run the extractor end to end once; return (rows, manifest, table path)."""
    out = tmp_path_factory.mktemp("v3out") / "hmog_features_v3.jsonl"
    manifest = v3.main(archive=str(archive), out_path=str(out))
    rows = [json.loads(line) for line in out.read_text().splitlines() if line.strip()]
    return rows, manifest, out


@pytest.fixture(scope="module")
def writing(run) -> dict:
    rows, _, _ = run
    return next(r for r in rows if r["user"] == "100669" and r["task"] == "writing")


@pytest.fixture(scope="module")
def reading(run) -> dict:
    rows, _, _ = run
    return next(r for r in rows if r["user"] == "100669" and r["task"] == "reading")


# --- the rows themselves ---------------------------------------------------

def test_every_session_becomes_one_row(run):
    rows, _, _ = run
    assert [(r["user"], r["session"], r["task"], r["posture"]) for r in rows] == [
        ("100669", "100669_session_1", "reading", "sit"),
        ("100669", "100669_session_2", "writing", "sit"),
        ("151985", "151985_session_1", "writing", "sit"),
    ]


# --- per-key counts, hand-computed ----------------------------------------

def test_per_key_counts_are_the_completed_pairs(writing):
    values = writing["values"]
    assert values["keyhold_a_count"] == 2.0
    assert values["keyhold_b_count"] == 1.0          # typed exactly once
    assert values["keyhold_c_count"] == 3.0
    assert values["keyhold_space_count"] == 2.0


def test_an_unmatched_down_produces_no_hold(writing):
    """d was pressed and the session ended. One dangling DOWN, no pair, and it is reported."""
    assert writing["values"]["keyhold_d_count"] == 0.0
    assert writing["values"]["keyhold_unmatched_down"] == 1.0


def test_an_unmatched_up_produces_no_hold(writing):
    """e was released with no DOWN on record - a session can begin mid-press."""
    assert writing["values"]["keyhold_e_count"] == 0.0
    assert writing["values"]["keyhold_unmatched_up"] == 1.0


def test_a_non_key_touch_never_becomes_a_hold_time(writing):
    """KeyID -1 is the suggestion strip or the text area, and it arrives as a full down/up pair.

    Counting it would add a phantom key to the ranked population and shift every rank in the
    session, which is the kind of error that reads as a weak feature rather than as a bug.
    """
    values = writing["values"]
    assert values["keyhold_nonkey_events"] == 2.0
    assert values["keyhold_keys_present"] == 4.0          # space, a, b, c - nothing else
    assert values["keyhold_keys_all"] == 5.0              # plus keycode 7, which is not -1
    assert all(code != -1 for code, _, _ in writing["keyhold_codes"])


def test_a_key_never_typed_has_a_zero_count_and_nothing_else(writing):
    """The trap this feature set lives or dies on.

    Every `missing` in bhorosha_ato.schema is 0.0, which is also a legal measurement, so a rank
    written as 0.0 would read as "her fastest key". The count is written (0.0, unambiguous - a
    count is not a hold time) and the median and rank are ABSENT from the object, so there is no
    zero to misread in the file at all.
    """
    values = writing["values"]
    for name in ("z", "del", "f", "q"):
        assert values[f"keyhold_{name}_count"] == 0.0
        assert f"keyhold_{name}_median_ms" not in values
        assert f"keyhold_{name}_rank" not in values


def test_a_count_exists_for_all_28_canonical_keys_in_every_row(run):
    """Including the reading sessions, where she typed nothing: the per-key presence mask has no
    holes, so a consumer never has to distinguish "absent column" from "absent key"."""
    rows, _, _ = run
    names = [f"keyhold_{name}_count" for name, _ in v3.CANONICAL_KEYS]
    assert len(names) == 28
    for row in rows:
        assert all(name in row["values"] for name in names)


# --- the medians -----------------------------------------------------------

def test_per_key_medians_are_hand_computable(writing):
    values = writing["values"]
    assert values["keyhold_a_median_ms"] == 100.0        # median(90, 110)
    assert values["keyhold_b_median_ms"] == 100.0        # the single hold
    assert values["keyhold_c_median_ms"] == 200.0        # median(180, 200, 260)
    assert values["keyhold_space_median_ms"] == 50.0     # median(40, 60)


def test_press_time_is_read_in_milliseconds_not_divided(writing):
    """Accelerometer and Gyroscope EventTime are nanoseconds and are divided by 1e6;
    KeyPressEvent PressTime is already milliseconds and must not be. A hold of 90 ms arriving
    as 0.00009 would make every per-key median tiny and every rank still look fine."""
    assert v3.TIME_DIVISOR.get("KeyPressEvent.csv", 1.0) == 1.0
    assert writing["values"]["keyhold_a_median_ms"] == 100.0


# --- the ranks, which are the point ---------------------------------------

def test_ranks_are_the_hand_computed_weibull_positions(writing):
    """n = 4 present keys; positions by ascending median; r/(n+1)."""
    values = writing["values"]
    assert values["keyhold_space_rank"] == pytest.approx(0.2)    # 1 / 5
    assert values["keyhold_c_rank"] == pytest.approx(0.8)        # 4 / 5
    assert values["keyhold_keys_present"] == 4.0


def test_exact_ties_share_a_midrank(writing):
    """a and b both median 100.0. They occupy positions 2 and 3, so both get 2.5 / 5 = 0.5.

    Deterministic, and deliberately not broken by keycode: two keys with the same median have no
    order to measure, and ordering them by keycode would make a coin flip look like a
    measurement while still being stable across users.
    """
    values = writing["values"]
    assert values["keyhold_a_rank"] == pytest.approx(0.5)
    assert values["keyhold_b_rank"] == pytest.approx(0.5)
    assert values["keyhold_a_rank"] == values["keyhold_b_rank"]


def test_ranks_order_the_keys_by_how_long_she_dwells(writing):
    values = writing["values"]
    ordered = sorted(
        ("space", "a", "b", "c"), key=lambda name: values[f"keyhold_{name}_rank"]
    )
    assert ordered[0] == "space" and ordered[-1] == "c"


def test_no_rank_can_ever_be_zero_or_one(run):
    """The property the absence encoding depends on: r/(n+1) lies strictly inside (0, 1), so a
    0.0 that a reader substituted for a gap is not a value any measurement can produce."""
    rows, _, _ = run
    ranks = [
        value for row in rows for name, value in row["values"].items()
        if name.endswith("_rank") and name.startswith("keyhold_")
    ]
    assert ranks                                    # the test would be vacuous otherwise
    assert all(0.0 < value < 1.0 for value in ranks)


def test_a_single_key_session_ranks_it_in_the_middle_not_at_an_edge(run):
    """n = 1 -> 1 / 2. Were it normalised (r-1)/(n-1) this would be 0.0 or a division by zero."""
    rows, _, _ = run
    row = next(r for r in rows if r["user"] == "151985")
    assert row["values"]["keyhold_keys_present"] == 1.0
    assert row["values"]["keyhold_a_count"] == 1.0
    assert row["values"]["keyhold_a_median_ms"] == 70.0
    assert row["values"]["keyhold_a_rank"] == pytest.approx(0.5)


def test_every_rank_has_a_nonzero_count_beside_it(run):
    """The contract a consumer is told to rely on: gate on `_count`, then read `_rank`."""
    rows, _, _ = run
    for row in rows:
        for name, value in row["values"].items():
            if name.startswith("keyhold_") and name.endswith("_rank"):
                key = name[len("keyhold_"):-len("_rank")]
                assert row["values"][f"keyhold_{key}_count"] > 0.0


def test_ranks_are_reproducible_from_the_row_alone(writing):
    """A consumer must be able to recompute the ranks from the emitted medians - that is why the
    ranked population is the canonical keys in this session and nothing wider."""
    values = writing["values"]
    medians = {
        name: values[f"keyhold_{name}_median_ms"]
        for name, _ in v3.CANONICAL_KEYS
        if values[f"keyhold_{name}_count"] > 0
    }
    codes = {name: code for name, code in v3.CANONICAL_KEYS}
    recomputed = v3._midranks({codes[name]: value for name, value in medians.items()})
    for name, code in codes.items():
        if name in medians:
            assert values[f"keyhold_{name}_rank"] == pytest.approx(recomputed[code])


# --- session-level totals --------------------------------------------------

def test_session_totals_count_canonical_and_non_canonical_separately(writing):
    """Keycode 7 is KEYCODE_0, outside the canonical 28. It must appear in the totals and the
    raw dump but never in the ranked population, or a session that typed digits would have its
    ranks computed over a set the row cannot describe."""
    values = writing["values"]
    assert values["keyhold_pairs_canon"] == 8.0      # 2 + 1 + 3 + 2
    assert values["keyhold_pairs_total"] == 9.0      # plus the one on keycode 7
    assert values["keyhold_keys_all"] == 5.0
    assert values["keyhold_rows"] == 22.0 == float(len(WRITING_EVENTS))


def test_the_raw_keycode_dump_is_complete_and_sorted(writing):
    """The insurance policy: if the canonical keycode mapping is wrong, this is what makes the
    run salvageable without a second pass over 6 GB."""
    assert writing["keyhold_codes"] == [
        [7, 1, 50.0],
        [29, 2, 100.0],
        [30, 1, 100.0],
        [31, 3, 200.0],
        [62, 2, 50.0],
    ]


def test_a_session_with_no_typing_is_all_zeros_and_no_ranks(reading):
    """1598 of the v2 table's 2398 rows carry no keystrokes - only the 800 writing sessions do.
    KeyPressEvent.csv is 0 bytes there, which is normal, not an error."""
    values = reading["values"]
    assert values["keyhold_keys_present"] == 0.0
    assert values["keyhold_pairs_total"] == 0.0
    assert values["keyhold_rows"] == 0.0
    assert reading["keyhold_codes"] == []
    assert not any(name.endswith(("_rank", "_median_ms")) for name in values
                   if name.startswith("keyhold_"))


def test_blocks_present_records_the_keyhold_block(writing, reading):
    """Recorded the way v2 records its blocks: beside the values, not inside them."""
    assert writing["blocks_present"]["keyhold"] is True
    assert reading["blocks_present"]["keyhold"] is False


# --- nothing from v2 regressed --------------------------------------------

def test_every_v2_column_name_is_still_produced_by_the_same_code(writing):
    """v2 dropped Contact_size once and reported an empty headline feature as measured. The
    guard is name-level: the four v2 blocks a typing-only fixture can reach must all still be
    there, computed by functions this file did not touch."""
    values = writing["values"]
    for name in ("pin_hold_1_ms", "pin_hold_4_ms", "pin_backspaces", "key_1_hold_ms",
                 "key_distinct", "key_hold_iqr", "scroll_count"):
        assert name in values, name


def test_the_v2_pin_block_sees_exactly_the_same_pairs_as_the_v3_block(writing):
    """Two blocks parsing the same file with different rules would be a silent inconsistency.
    v3's keyhold pairing is pin_block's rule verbatim, so the pair counts must agree."""
    pin = v3.pin_block(
        v3.rows(_keypress_csv(WRITING_EVENTS).encode(), "KeyPressEvent.csv"), []
    )
    holds, _ = v3.key_events(v3.rows(_keypress_csv(WRITING_EVENTS).encode(), "KeyPressEvent.csv"))
    assert sum(len(v) for v in holds.values()) == 9
    assert pin["pin_hold_1_ms"] is not None          # the v2 block still measures something


def test_v2_per_key_slots_are_by_press_count_not_by_name(writing):
    """key_1_hold_ms is whichever key she pressed MOST - c, with three pairs - which is exactly
    why it is not comparable across sessions and why the keyhold block exists."""
    assert writing["values"]["key_1_hold_ms"] == 200.0
    assert writing["values"]["key_distinct"] == 5.0


# --- the manifest and the guards it has to satisfy -------------------------

def test_the_manifest_carries_everything_the_reader_demands(run):
    _, manifest, table = run
    required = {
        "dataset", "source", "table", "table_sha256", "table_bytes", "rows", "schema_length",
        "schema_names", "rows_per_user", "rows_per_task", "extractor_version", "generated_at",
    }
    assert required <= set(manifest)
    assert manifest["extractor_version"] == 3
    assert manifest["rows"] == 3
    assert manifest["rows_per_user"] == {"100669": 2, "151985": 1}
    assert manifest["schema_length"] == len(manifest["schema_names"])
    assert manifest["table"] == table.name
    assert manifest["table_bytes"] == table.stat().st_size
    assert manifest["table_sha256"] == hashlib.sha256(table.read_bytes()).hexdigest()
    assert json.loads(Path(str(table) + ".manifest.json").read_text()) == manifest


def test_rows_per_task_names_every_task_including_the_empty_one(run):
    """extract._counts builds this map over all three tasks and compares it for equality, so a
    task with no rows has to be present as a zero or the table is rejected as stale."""
    _, manifest, _ = run
    assert manifest["rows_per_task"] == {"reading": 1, "writing": 2, "map": 0}


def test_the_manifest_lists_the_new_columns(run):
    _, manifest, _ = run
    names = set(manifest["schema_names"])
    assert {"keyhold_a_count", "keyhold_a_median_ms", "keyhold_a_rank",
            "keyhold_keys_present", "keyhold_pairs_total"} <= names
    # Counts for all 28 keys are always written, so all 28 names are always in the manifest.
    assert sum(1 for name in names if name.endswith("_count")
               and name.startswith("keyhold_")) == 28


def test_the_same_archive_gives_a_byte_identical_table(archive, tmp_path):
    """Determinism, run rather than asserted about: no set iteration, no dict ordering, no
    randomness. Only the manifest's timestamps differ between runs."""
    first = tmp_path / "a" / "t.jsonl"
    second = tmp_path / "b" / "t.jsonl"
    for path in (first, second):
        path.parent.mkdir(parents=True, exist_ok=True)
    one = v3.main(archive=str(archive), out_path=str(first))
    two = v3.main(archive=str(archive), out_path=str(second))
    assert first.read_bytes() == second.read_bytes()
    assert one["table_sha256"] == two["table_sha256"]
    volatile = {"generated_at", "elapsed_seconds", "source", "table", "table_bytes"}
    assert {k: v for k, v in one.items() if k not in volatile} == \
           {k: v for k, v in two.items() if k not in volatile}


# --- what the local reader does with a v3 table ---------------------------

def test_the_new_columns_do_not_break_read_wide_table(run, tmp_path):
    """The 94 new names must be carried and ignored, not fatal: `read_wide_table` deliberately
    does not require the manifest's names to match the schema, because the wide table exists to
    carry candidates the schema has no column for.

    Two things are adjusted to get there, and both are the subject of the next two tests rather
    than hidden here: the manifest version is forced to 2, because extract.py reads versions 1
    and 2 and nothing else, and the "keyhold" key is dropped from blocks_present, because
    SessionRecord demands that map equal the schema's block set exactly.
    """
    rows, manifest, _ = run
    table = tmp_path / "compat" / "hmog_features_v3.jsonl"
    table.parent.mkdir(parents=True, exist_ok=True)
    adjusted = []
    for row in rows:
        row = dict(row)
        row["blocks_present"] = {
            name: flag for name, flag in row["blocks_present"].items() if name in extract.BLOCKS
        }
        adjusted.append(row)
    table.write_text("".join(json.dumps(r, sort_keys=True) + "\n" for r in adjusted))
    patched = dict(manifest)
    patched.update({
        "extractor_version": extract.WIDE_EXTRACTOR_VERSION,
        "table": table.name,
        "table_bytes": table.stat().st_size,
        "table_sha256": hashlib.sha256(table.read_bytes()).hexdigest(),
    })
    extract.manifest_path(table).write_text(json.dumps(patched, indent=2))

    records = extract.read_wide_table(table)
    assert [r.key for r in records] == [
        "100669/100669_session_1", "100669/100669_session_2", "151985/151985_session_1"
    ]
    assert all(len(r.features) == len(extract.FEATURES) for r in records)


def test_the_keyhold_block_is_not_yet_a_schema_block(run):
    """A factual record of the gap, not a complaint: the row carries one block key the local
    schema does not declare, so `extract._record_from_wide_row` hands SessionRecord a seven-key
    map where it requires exactly six. Teaching extract.py about the key (or projecting the
    writer's map onto `BLOCKS`) is one line, and it has to land with the version-3 reader.
    """
    rows, _, _ = run
    extra = set(rows[0]["blocks_present"]) - set(extract.BLOCKS)
    assert extra == {"keyhold"}


def test_version_three_is_not_readable_until_extract_py_is_taught_it(run):
    """Deliberately loud rather than silently mislabelled as a v2 table: the row contract
    changed. `read_any_table` dispatches on the manifest's version and knows 1 and 2."""
    _, manifest, _ = run
    assert manifest["extractor_version"] not in (
        extract.EXTRACTOR_VERSION, extract.WIDE_EXTRACTOR_VERSION
    )


# --- the scroll block, kept broken on purpose -----------------------------

def test_the_dead_scroll_block_is_unchanged_even_with_a_scroll_file_present(writing):
    """v2's `COLUMNS` has no ScrollEvent.csv entry, so its reader raises KeyError, the caller
    swallows it, and the block sees an empty list - `scroll_count` is 0.0 in all 2398 v2 rows.
    Fixing it would mean guessing the file's column order, and a guessed layout yields plausible
    wrong numbers; changing `scroll_count` would silently redefine a shipped column. So the
    session here HAS a ScrollEvent.csv and the block still reports nothing."""
    assert writing["values"]["scroll_count"] == 0.0
    assert not any(name.startswith("scroll_d") or name.startswith("scroll_size")
                   for name in writing["values"])


def test_the_manifest_samples_the_scroll_file_so_v4_can_parse_it(run):
    """One raw line and the field-count histogram, recorded instead of parsed. That is the whole
    cost of making the dead block fixable without a second pass over 6 GB."""
    _, manifest, _ = run
    assert manifest["scroll_sample_row"] == SCROLL_CSV.splitlines()[0].strip()
    assert manifest["scroll_field_counts"] == {"9": 2}


def test_a_missing_scroll_file_is_not_an_error(reading):
    """Most sessions have no ScrollEvent.csv at all, and the sampling must not raise - a crash
    here would end an hour-long extraction run with no table written."""
    assert reading["values"]["scroll_count"] == 0.0


# --- the keycode set ------------------------------------------------------

def test_the_canonical_key_set_is_the_26_letters_space_and_backspace(run):
    names = [name for name, _ in v3.CANONICAL_KEYS]
    assert names[:26] == [chr(ord("a") + i) for i in range(26)]
    assert names[26:] == ["space", "del"]
    codes = dict(v3.CANONICAL_KEYS)
    assert codes["a"] == 29 and codes["z"] == 54      # AOSP KEYCODE_A..KEYCODE_Z, contiguous
    assert codes["space"] == 62                       # AOSP KEYCODE_SPACE
    assert codes["del"] == v3.KEYCODE_DEL == 67       # pinned in bhorosha_ato.datasets


def test_the_non_key_sentinel_matches_the_repo(run):
    """-1 and 67 are the two keycodes bhorosha_ato.datasets pins against real rows. If these
    ever diverge, the standalone copy is the one that is wrong."""
    from bhorosha_ato import datasets

    assert v3.NON_KEY_ID == datasets.NON_KEY_ID
    assert v3.KEYCODE_DEL == datasets.KEYCODE_DEL
