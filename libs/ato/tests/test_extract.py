"""The extraction pass and the HMOG eval path, driven by a fake feature table.

No archive is involved and none is faked. The archive needs a licence acceptance that cannot be
scripted, and `bhorosha_ato.datasets.iter_hmog_sessions` is still a stub because nobody has seen
the column layout - so what can be tested now is everything on this side of the table: the
record and manifest contract, the refusal when the reader is absent, and the evaluation that
reads the table. Those have to be right before the archive lands, not after.

The fake table is shaped like HMOG rather than like a convenient matrix: per user, reading and
map-navigation sessions carrying no PIN block at all, and writing sessions carrying everything.
That shape is the point. A table of uniform rows would let every one of these tests pass while
the real thing silently fed reading sessions to the coaching model.
"""

from __future__ import annotations

import json
import random
from pathlib import Path

import pytest

from bhorosha_ato import extract, synth
from bhorosha_ato.extract import SessionRecord, StaleTableError
from bhorosha_ato.model import MIN_ENROLMENT_SESSIONS
from bhorosha_ato.schema import FEATURES, INDEX, NAMES, from_vector, to_vector
from eval.ato_eval import (
    EER_MEASURED,
    EER_WITHIN_BAND,
    _hmog_split,
    COACHED_ON_HMOG,
    HMOG_CAVEAT,
    MEASURED_HMOG,
    NOT_RUN,
    _markdown,
    evaluate_hmog,
    main,
)

# Deliberately tiny, like test_eval.py: none of these assertions is about statistical strength.
# Per user: 3 reading + 3 map = 6 identity sessions, which is exactly ENROL + HOLDOUT, and 4
# writing sessions, which splits 2/2 for the coaching model. ENROL stays at or above
# MIN_ENROLMENT_SESSIONS so the model under test is the per-user one the report claims.
# WRITING is 8, as in the real archive: identity is measured on the writing sessions, so the
# fixture has to supply ENROL + HOLDOUT of them.
USERS, PER_IDENTITY_TASK, WRITING = 3, 3, 8
ENROL, HOLDOUT, SEED = 4, 2, 30

PIN_FEATURES = tuple(f.name for f in FEATURES if f.block == "pin")


def _blocks(**overrides) -> dict:
    """Every schema block present unless overridden.

    Derived from extract.BLOCKS rather than written out: two blocks were added to the schema
    later and every hand-written four-key dict in these fixtures broke at once.
    """
    blocks = {name: True for name in extract.BLOCKS}
    blocks.update(overrides)
    return blocks


def _without_pin(row: tuple[float, ...]) -> tuple[float, ...]:
    """The same row with the PIN block replaced by its declared `missing` substitutes.

    What a HMOG reading or map-navigation session actually looks like: there is no typing in it,
    so eleven of the the schema's columns are substitutes. `to_vector` fills in whatever is left out.
    """
    return to_vector({
        name: value for name, value in from_vector(row).items() if name not in PIN_FEATURES
    })


def _fake_records(users: int = USERS, seed: int = SEED) -> list[SessionRecord]:
    """A table the extractor could have written, with HMOG's task structure.

    Values come from `synth` so users are separable and an EER can be computed at all; the
    fixture is about which task carries which block, not about the numbers. Session ids restart
    at `session_0` for every user on purpose - HMOG numbers sessions within a user, and that is
    what makes `SessionRecord.key` necessary.
    """
    rng = random.Random(seed)
    records: list[SessionRecord] = []
    for index in range(users):
        profile = synth.user_profile(rng)
        user = f"u{index:03d}"
        session = 0
        for task in ("reading", "map"):
            for _ in range(PER_IDENTITY_TASK):
                records.append(SessionRecord(
                    user=user,
                    session=f"session_{session}",
                    task=task,
                    features=_without_pin(synth.genuine_row(profile, rng)),
                    # No typing in a reading or map session, so no PIN block.
                    blocks_present=_blocks(pin=False),
                ))
                session += 1
        for _ in range(WRITING):
            records.append(SessionRecord(
                user=user,
                session=f"session_{session}",
                task="writing",
                features=synth.genuine_row(profile, rng),
                blocks_present=_blocks(),
            ))
            session += 1
    return records


def _write(records: list[SessionRecord], directory: Path) -> Path:
    table = directory / "hmog_features.jsonl"
    extract.write_table(records, table, dataset="hmog", source="fake://no-archive")
    return table


@pytest.fixture(scope="module")
def table(tmp_path_factory) -> Path:
    return _write(_fake_records(), tmp_path_factory.mktemp("extract"))


@pytest.fixture(scope="module")
def report(table: Path) -> dict:
    return evaluate_hmog(table, ENROL, HOLDOUT, SEED)


# --- the table and its manifest --------------------------------------------

def test_the_manifest_round_trips(table):
    manifest = extract.read_manifest(table)
    assert manifest.dataset == "hmog"
    assert manifest.rows == USERS * (2 * PER_IDENTITY_TASK + WRITING)
    assert manifest.rows_per_user == {f"u{i:03d}": 2 * PER_IDENTITY_TASK + WRITING
                                      for i in range(USERS)}
    assert manifest.rows_per_task == {
        "reading": USERS * PER_IDENTITY_TASK,
        "writing": USERS * WRITING,
        "map": USERS * PER_IDENTITY_TASK,
    }
    assert manifest.schema_length == len(FEATURES)
    assert manifest.schema_names == NAMES
    assert extract.read_table(table) == _fake_records()


def test_the_manifest_lives_beside_the_table_under_its_own_name(table):
    assert extract.manifest_path(table) == table.with_name(table.name + ".manifest.json")
    assert extract.manifest_path(table).exists()


def test_a_truncated_table_is_refused_rather_than_read_short(tmp_path):
    """A truncated table still parses line by line, and an eval over it still prints a number."""
    table = _write(_fake_records(), tmp_path)
    lines = table.read_text(encoding="utf-8").splitlines(keepends=True)
    table.write_text("".join(lines[:-4]), encoding="utf-8")
    with pytest.raises(StaleTableError, match="manifest checksum"):
        extract.read_table(table)


def test_a_stale_manifest_is_detected(tmp_path):
    """The manifest left behind by an earlier, larger extraction must not be trusted."""
    table = _write(_fake_records(), tmp_path)
    path = extract.manifest_path(table)
    stale = json.loads(path.read_text(encoding="utf-8"))
    stale["rows"] = stale["rows"] + 100
    stale["table_sha256"] = extract._sha256(table)  # checksum still right; the counts are not
    path.write_text(json.dumps(stale), encoding="utf-8")
    with pytest.raises(StaleTableError, match="manifest says"):
        extract.read_table(table)


def test_a_table_extracted_against_a_different_feature_order_is_refused(tmp_path):
    """The one failure schema.py exists to prevent: positions are the wire format."""
    table = _write(_fake_records(), tmp_path)
    path = extract.manifest_path(table)
    manifest = json.loads(path.read_text(encoding="utf-8"))
    manifest["schema_names"] = list(reversed(manifest["schema_names"]))
    path.write_text(json.dumps(manifest), encoding="utf-8")
    with pytest.raises(StaleTableError, match="different feature order"):
        extract.read_table(table)


def test_a_table_without_a_manifest_is_refused(tmp_path):
    table = _write(_fake_records(), tmp_path)
    extract.manifest_path(table).unlink()
    with pytest.raises(StaleTableError, match="no manifest"):
        extract.read_table(table)


def test_a_table_that_is_simply_absent_says_to_run_the_extractor(tmp_path):
    with pytest.raises(FileNotFoundError, match="bhorosha_ato.extract"):
        extract.read_table(tmp_path / "nothing.jsonl")


def test_block_presence_survives_the_round_trip_and_a_zero_stays_readable(table):
    """Without this record a substituted 0.0 and a measured 0.0 are the same number."""
    records = extract.read_table(table)
    reading = next(r for r in records if r.task == "reading")
    writing = next(r for r in records if r.task == "writing")

    assert reading.blocks_present == _blocks(pin=False)
    assert writing.blocks_present["pin"] is True
    # The PIN columns of a reading session are the schema's substitute, and the value alone
    # cannot say so: every declared missing value is 0.0, which is also a legal measurement.
    for name in PIN_FEATURES:
        assert reading.features[INDEX[name]] == FEATURES[INDEX[name]].missing
        assert reading.measured(name) is False
        assert writing.measured(name) is True
    assert reading.measured("swipe_length_px") is True


def test_a_record_that_does_not_match_the_schema_never_reaches_the_table():
    rng = random.Random(SEED)
    row = synth.genuine_row(synth.user_profile(rng), rng)
    blocks = _blocks()
    with pytest.raises(ValueError, match=f"{len(extract.FEATURES)} features"):
        SessionRecord(user="u", session="s", task="reading", features=row[:-1], blocks_present=blocks)
    with pytest.raises(ValueError, match="unknown task"):
        SessionRecord(user="u", session="s", task="scrolling", features=row, blocks_present=blocks)
    with pytest.raises(ValueError, match="every schema block"):
        SessionRecord(user="u", session="s", task="reading", features=row,
                      blocks_present={"swipe": True})


def test_a_duplicated_session_is_refused_at_write_time(tmp_path):
    """A table appended to twice could put one session in both train and test."""
    records = _fake_records()
    with pytest.raises(ValueError, match="duplicate session"):
        extract.write_table(records + records[:1], tmp_path / "t.jsonl",
                            dataset="hmog", source="fake://no-archive")


def test_an_unknown_task_spelling_is_refused_rather_than_bucketed():
    assert extract.normalise_task("Map-Navigation") == "map"
    assert extract.normalise_task("READ") == "reading"
    with pytest.raises(ValueError, match="unknown HMOG session task"):
        extract.normalise_task("scrolling")


def test_a_session_without_its_task_cannot_become_a_record():
    with pytest.raises(KeyError, match="task"):
        extract.record_from_session({"user": "u", "session": "s"})


def test_extraction_refuses_without_an_archive_and_a_reader(tmp_path):
    """No reader is invented, so the pass has to say what is missing and how to fix it."""
    message = extract.refuse_hmog(tmp_path)
    assert "iter_hmog_sessions" in message
    assert "To unblock it" in message
    with pytest.raises(SystemExit) as exit_info:
        extract.main(["--dataset", "hmog", "--data-dir", str(tmp_path),
                      "--out", str(tmp_path / "t.jsonl"), "--users", "u001"])
    assert "To unblock it" in str(exit_info.value)
    assert not (tmp_path / "t.jsonl").exists()


# --- the hmog evaluation ----------------------------------------------------

def test_identity_is_measured_on_the_writing_sessions_only(report, table):
    """Writing is the only task where all 14 morphology features are recorded, and measurement
    on the real archive says so: reading+map gives 0.1818 EER against writing's 0.1165, and
    mixing all three is worst at 0.2233 because the model starts separating tasks rather than
    people. Task is held fixed for the same reason posture is.
    """
    by_key = {r.key: r for r in extract.read_table(table)}
    assert report["split"]["identity_tasks"] == ["writing"]
    for user in report["per_user"]:
        assert set(user["tasks"]) == {"writing"}
        for key in user["train_session_ids"] + user["test_session_ids"]:
            assert by_key[key].task == "writing"


def test_coaching_is_measured_on_the_writing_sessions(report):
    assert report["split"]["coaching_tasks"] == ["writing"]
    assert report["split"]["coaching_users"] == USERS
    # Half of each user's writing sessions per side, doubled because every genuine row is
    # matched by a coached copy.
    assert report["split"]["coaching_train_sessions"] == 2 * USERS * (WRITING // 2)
    assert report["split"]["coaching_test_sessions"] == 2 * USERS * (WRITING - WRITING // 2)


def test_train_and_test_sessions_never_intersect(report):
    """The most common way these results get overstated; model.Split's docstring says so."""
    train = {u["user"]: set(u["train_session_ids"]) for u in report["per_user"]}
    test = {u["user"]: set(u["test_session_ids"]) for u in report["per_user"]}
    for user in train:
        assert len(train[user]) == ENROL
        assert len(test[user]) == HOLDOUT
        assert not train[user] & test[user]
        # Impostor sessions are other users' held-out ones, so a subject's training session
        # must never appear in any other user's test set either.
        for other in train:
            if other != user:
                assert not train[user] & test[other]
    assert len(set().union(*train.values()) & set().union(*test.values())) == 0


def test_session_ids_are_the_real_ones_and_qualified_by_user(report, table):
    keys = {r.key for r in extract.read_table(table)}
    for user in report["per_user"]:
        for key in user["train_session_ids"] + user["test_session_ids"]:
            assert key in keys
            assert key.startswith(user["user"] + "/")


def test_identity_and_coaching_metrics_carry_different_sources(report):
    """Identity was measured on HMOG; coaching's coached side can never be."""
    identity = report["metrics"]["identity_eer_mean"]["source"]
    coached = report["metrics"]["coached_detection_rate"]["source"]
    assert identity == MEASURED_HMOG
    assert "MEASURED" in identity
    assert coached == COACHED_ON_HMOG
    assert coached != identity
    assert "GENERATED" in coached
    assert "no public coached dataset exists" in coached
    for metric in report["metrics"].values():
        assert set(metric) == {"value", "target", "status", "source"}
        assert metric["source"]


def test_a_suspiciously_low_eer_is_still_a_finding(report):
    """Published SOTA on HMOG is around 3.6%; beating it points at a session leak."""
    eer = report["metrics"]["identity_eer_mean"]
    assert eer["status"] in {"suspect", EER_WITHIN_BAND, EER_MEASURED}
    assert report["metrics"]["identity_eer_std"]["value"] >= 0.0
    assert str(report["targets"]["eer_range"][0]) in HMOG_CAVEAT


def test_nothing_is_substituted_now_identity_reads_the_writing_sessions(report):
    """The reason identity moved to the writing task.

    Two of the fourteen morphology features live in the PIN block. Reading and map sessions
    carry no typing, so measuring identity there meant the model read twelve of fourteen.
    Writing sessions carry all four blocks, so nothing is substituted - and the substitution
    machinery stays in place, reporting an empty list rather than being removed, because the
    day a block does go missing the report has to say so.
    """
    assert report["blocks_present"]["identity_sessions"]["pin"] == 1.0
    assert report["blocks_present"]["identity_sessions"]["swipe"] == 1.0
    assert report["blocks_present"]["coaching_sessions"]["pin"] == 1.0
    assert report["identity_features_substituted"] == []
    assert report["caveat"].startswith(HMOG_CAVEAT)
    for name in report["identity_features_substituted"]:
        assert name in report["caveat"]


def test_the_report_records_which_table_it_read(report, table):
    manifest = extract.read_manifest(table)
    assert report["table"] == str(table)
    assert report["table_manifest"]["table_sha256"] == manifest.table_sha256
    assert report["table_manifest"]["rows"] == manifest.rows


def test_the_split_and_the_excluded_users_are_both_recorded(report):
    split = report["split"]
    assert split["train_sessions_per_user"] == ENROL
    assert split["holdout_sessions_per_user"] == HOLDOUT
    assert split["impostor_users_per_subject"] == USERS - 1
    assert split["impostor_sessions_per_subject"] == (USERS - 1) * HOLDOUT
    assert split["excluded_users"] == {"identity": {}, "coaching": {}}
    # Writing gives 8 sessions per user and the split uses ENROL + HOLDOUT of them; the rest
    # are left on the table rather than quietly folded into either side.
    assert split["unused_identity_sessions"] == (WRITING - ENROL - HOLDOUT) * USERS
    assert "never train anything" in split["note"]
    for user in report["per_user"]:
        assert user["per_user_model"] is True
        assert user["impostor_sessions"] == (USERS - 1) * HOLDOUT


def test_the_same_seed_reproduces_the_same_split_and_numbers(table):
    """Reruns have to match exactly, and the seed has to be what decides the split - not the
    order the extractor happened to walk the archive in."""
    again = evaluate_hmog(table, ENROL, HOLDOUT, SEED)
    assert again["per_user"] == evaluate_hmog(table, ENROL, HOLDOUT, SEED)["per_user"]
    other = evaluate_hmog(table, ENROL, HOLDOUT, SEED + 1)
    assert other["per_user"][0]["train_session_ids"] != again["per_user"][0]["train_session_ids"]


def test_a_split_that_does_not_fit_the_dataset_is_an_error_not_a_smaller_run(table):
    with pytest.raises(ValueError, match="at least 2 users"):
        evaluate_hmog(table, ENROL + HOLDOUT + 1, HOLDOUT, SEED)
    with pytest.raises(ValueError, match="MIN_ENROLMENT_SESSIONS"):
        evaluate_hmog(table, MIN_ENROLMENT_SESSIONS - 1, HOLDOUT, SEED)
    with pytest.raises(ValueError, match="holdout"):
        evaluate_hmog(table, ENROL, 0, SEED)


def test_users_can_be_capped_without_changing_how_a_user_is_measured(table):
    capped = evaluate_hmog(table, ENROL, HOLDOUT, SEED, users=2)
    assert capped["users"] == 2
    assert capped["split"]["impostor_users_per_subject"] == 1


def test_the_markdown_table_renders_for_the_hmog_report(report):
    lines = _markdown(report).splitlines()
    rows = [line for line in lines if line.startswith("|")]
    assert rows[0].startswith("| Metric | Value | Target | Status | Source |")
    assert len(rows) == 2 + len(report["metrics"]) + 1
    assert all(row.count("|") == 6 for row in rows)
    assert "MEASURED" in "\n".join(rows)
    assert report["caveat"] in "\n".join(lines)


# --- the command line -------------------------------------------------------

def test_a_missing_table_exits_with_the_command_that_writes_it(tmp_path):
    missing = tmp_path / "nothing.jsonl"
    with pytest.raises(SystemExit) as exit_info:
        main(["--dataset", "hmog", "--table", str(missing)])
    message = str(exit_info.value)
    assert str(missing) in message
    assert "python -m bhorosha_ato.extract" in message
    assert "To unblock it" in message
    assert "--dataset synthetic" in message


def test_a_stale_table_exits_rather_than_evaluating_it(tmp_path):
    table = _write(_fake_records(), tmp_path)
    table.write_text(table.read_text(encoding="utf-8").split("\n", 1)[1], encoding="utf-8")
    with pytest.raises(SystemExit, match="manifest"):
        main(["--dataset", "hmog", "--table", str(table), "--out", str(tmp_path / "o.json")])


def test_another_datasets_table_is_refused(tmp_path):
    """Every metric from this path is labelled as measured on HMOG."""
    table = tmp_path / "other.jsonl"
    extract.write_table(_fake_records(), table, dataset="bbmas", source="fake://no-archive")
    with pytest.raises(StaleTableError, match="not hmog"):
        evaluate_hmog(table, ENROL, HOLDOUT, SEED)


def test_main_writes_both_artefacts_for_hmog(tmp_path):
    table = _write(_fake_records(), tmp_path)
    out = tmp_path / "results" / "ato_hmog.json"
    assert main(["--dataset", "hmog", "--table", str(table), "--enrol", str(ENROL),
                 "--holdout", str(HOLDOUT), "--seed", str(SEED), "--out", str(out)]) == 0
    written = json.loads(out.read_text(encoding="utf-8"))
    assert written["dataset"] == "hmog"
    assert written["source"] == MEASURED_HMOG
    assert written["metrics"]["judge_faithfulness"]["status"] == NOT_RUN
    assert out.with_suffix(".md").read_text(encoding="utf-8").startswith("| Metric |")


def test_the_hmog_run_does_not_overwrite_the_generated_report(tmp_path, monkeypatch):
    """Two reports with different sources under one filename is the mix-up every label here
    exists to prevent."""
    table = _write(_fake_records(), tmp_path)
    monkeypatch.chdir(tmp_path)
    assert main(["--dataset", "hmog", "--table", str(table), "--enrol", str(ENROL),
                 "--holdout", str(HOLDOUT)]) == 0
    assert (tmp_path / "eval" / "results" / "ato_hmog.json").exists()
    assert not (tmp_path / "eval" / "results" / "ato.json").exists()


# --- posture, the confound found in data_description.pdf -------------------

def test_posture_survives_the_table_round_trip():
    """It is the field the identity split stratifies on, so losing it in serialisation would
    reintroduce the confound with nothing to show that anything had changed."""
    rec = extract.SessionRecord(
        user="100669", session="100669_session_1", task="reading",
        features=tuple(0.0 for _ in extract.FEATURES),
        blocks_present=_blocks(),
        posture="walk",
    )
    assert extract.SessionRecord.from_dict(rec.as_dict()).posture == "walk"


def test_a_table_written_before_posture_existed_still_loads():
    raw = {
        "user": "100669", "session": "s1", "task": "reading",
        "features": [0.0] * len(extract.FEATURES),
        "blocks_present": {b: True for b in extract.BLOCKS},
    }
    assert extract.SessionRecord.from_dict(raw).posture == "unknown"


def test_an_unknown_posture_is_rejected():
    with pytest.raises(ValueError, match="unknown posture"):
        extract.SessionRecord(
            user="u", session="s", task="reading",
            features=tuple(0.0 for _ in extract.FEATURES),
            blocks_present=_blocks(),
            posture="standing on one leg",
        )


def test_the_split_keeps_the_same_posture_mix_on_both_sides():
    """Unstratified, a split can train on sitting and test on walking. The touch-dynamics
    literature puts the EER penalty for that near 86%, which reads as the model failing when
    it is really the protocol."""
    sessions = [
        extract.SessionRecord(
            user="100669", session=f"s{i}", task="reading",
            features=tuple(float(i) for _ in extract.FEATURES),
            blocks_present=_blocks(),
            posture="sit" if i % 2 else "walk",
        )
        for i in range(16)
    ]
    train, test = _hmog_split(sessions, 10, 6, random.Random(30))

    def mix(rs):
        out = {}
        for r in rs:
            out[r.posture] = out.get(r.posture, 0) + 1
        return out

    assert mix(train) == {"sit": 5, "walk": 5}
    assert mix(test) == {"sit": 3, "walk": 3}
    assert not ({r.session for r in train} & {r.session for r in test})


# --- the WIDE, name-keyed table (extractor version 2) ----------------------
#
# Two table formats exist on disk and they are not interchangeable. Version 1 rows carry a
# POSITIONAL `features` vector in this schema's order; version 2 rows carry a NAMED `values`
# mapping of 80 candidate features, written while the feature set was still being chosen. The
# tests below are mostly about the seams between them, because a row read with the wrong loader
# produces a full-length vector of plausible nonsense rather than an error.

WIDE_VALUES = {
    # recognised by the current schema
    "swipe_duration_ms": 530.5,
    "swipe_v_mean": 0.279,
    "pressure_mean": 1.0,
    "size_mean": 0.0232,
    "size_max": 0.0255,
    "size_iqr": 0.0029,
    "tap_offset_med": 178.25,
    "tap_offset_iqr": 80.47,
    "tap_x_iqr": 130.0,
    "tap_y_iqr": 22.5,
    "tap_size_med": 0.0235,
    "tap_count": 19.0,
    # carried by the wide table, no column in this schema - must be dropped, not raise
    "swipe_duration_ms_iqr": 324.0,
    "swipe_count": 194.0,
    "key_1_hold_ms": 95.0,
    "imu_accel_x_mean": -0.4,
    "scroll_count": 0.0,
}

# What the v2 writer records: it predates the size and tap blocks, so four keys where the schema
# now has six.
WIDE_BLOCKS = ("swipe", "pressure", "pin", "imu")


def _wide_row(user: str, session: str, task: str, values: dict, **blocks) -> dict:
    present = {name: True for name in WIDE_BLOCKS}
    present["pin"] = task == "writing"
    present.update(blocks)
    return {
        "user": user,
        "session": session,
        "task_id": 7,
        "task": task,
        "posture": "sit",
        "values": dict(values),
        "blocks_present": present,
    }


def _wide_rows() -> list[dict]:
    """Three rows: a writing session with everything, a reading session with no typing, and a
    session that recorded no taps at all - which is the case where assuming the tap block
    present would report six substituted zeros as measurements."""
    no_taps = {k: v for k, v in WIDE_VALUES.items() if not k.startswith("tap_")}
    return [
        _wide_row("u1", "u1_session_1", "writing", WIDE_VALUES),
        _wide_row("u1", "u1_session_2", "reading", WIDE_VALUES),
        _wide_row("u2", "u2_session_1", "map", no_taps),
    ]


def _write_wide(
    rows: list[dict],
    directory: Path,
    *,
    version: int = extract.WIDE_EXTRACTOR_VERSION,
    names: list[str] | None = None,
    with_manifest: bool = True,
    append_after_manifest: str = "",
    name: str = "hmog_features_v2.jsonl",
) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    table = directory / name
    table.write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")
    if names is None:
        names = sorted({
            name for row in rows
            for name in (row.get("values") if isinstance(row.get("values"), dict) else {})
        })
    if with_manifest:
        per_user: dict[str, int] = {}
        per_task = {task: 0 for task in extract.TASKS}
        for row in rows:
            per_user[row["user"]] = per_user.get(row["user"], 0) + 1
            per_task[row["task"]] += 1
        extract.manifest_path(table).write_text(json.dumps({
            "dataset": "hmog",
            "source": "fake://no-archive",
            "table": table.name,
            "table_sha256": extract._sha256(table),
            "table_bytes": table.stat().st_size,
            "rows": len(rows),
            "schema_length": len(names),
            "schema_names": names,
            "rows_per_user": dict(sorted(per_user.items())),
            "rows_per_task": per_task,
            "extractor_version": version,
            "generated_at": "2026-10-16T00:00:00+00:00",
        }, indent=2), encoding="utf-8")
    if append_after_manifest:
        with table.open("a", encoding="utf-8") as handle:
            handle.write(append_after_manifest)
    return table


@pytest.fixture
def wide_table(tmp_path) -> Path:
    return _write_wide(_wide_rows(), tmp_path)


def test_the_wide_table_loads_into_records_against_the_current_schema(wide_table):
    records = extract.read_wide_table(wide_table)
    assert [r.key for r in records] == ["u1/u1_session_1", "u1/u1_session_2", "u2/u2_session_1"]
    assert [r.task for r in records] == ["writing", "reading", "map"]
    assert all(len(r.features) == len(FEATURES) for r in records)
    assert all(r.posture == "sit" for r in records)


def test_a_wide_row_lands_every_recognised_name_in_its_schema_slot(wide_table):
    record = extract.read_wide_table(wide_table)[0]
    for name, value in WIDE_VALUES.items():
        if name in NAMES:
            assert record.features[INDEX[name]] == pytest.approx(value), name


def test_the_nine_new_features_actually_arrive_from_the_wide_table(wide_table):
    """The point of the loader. These are the columns nothing filled before."""
    record = extract.read_wide_table(wide_table)[0]
    values = from_vector(record.features)
    assert values["size_mean"] == pytest.approx(0.0232)
    assert values["tap_count"] == 19.0
    for name in (*extract.names_for(block="size"), *extract.names_for(block="tap")):
        assert record.measured(name), name


def test_names_the_schema_does_not_declare_are_dropped_not_fatal(wide_table):
    """The wide table carries 80 candidates on purpose; most have no column here."""
    extras = {name for name in WIDE_VALUES if name not in NAMES}
    assert extras, "the fixture must exercise the drop"
    record = extract.read_wide_table(wide_table)[0]
    assert len(record.features) == len(FEATURES)


def test_schema_names_absent_from_a_wide_row_take_their_declared_missing_value(wide_table):
    """to_vector supplies them, so the loader never invents a stand-in of its own."""
    record = extract.read_wide_table(wide_table)[0]
    for feature in FEATURES:
        if feature.name not in WIDE_VALUES:
            assert record.features[INDEX[feature.name]] == feature.missing, feature.name


def test_the_blocks_the_wide_writer_recorded_are_believed(wide_table):
    writing, reading, _ = extract.read_wide_table(wide_table)
    assert writing.blocks_present["pin"] is True
    assert reading.blocks_present["pin"] is False      # no typing in a reading session
    assert reading.blocks_present["swipe"] is True


def test_size_and_tap_presence_is_derived_from_the_values_not_assumed(wide_table):
    """The wide table's blocks_present has four keys and the schema has six. Assuming present
    would report six substituted zeros as measurements for a session that recorded no taps;
    assuming absent would throw away the columns this table does carry."""
    records = extract.read_wide_table(wide_table)
    assert set(records[0].blocks_present) == set(extract.BLOCKS)
    assert records[0].blocks_present["size"] is True
    assert records[0].blocks_present["tap"] is True

    no_taps = records[-1]
    assert no_taps.blocks_present["size"] is True
    assert no_taps.blocks_present["tap"] is False
    assert no_taps.features[INDEX["tap_count"]] == 0.0
    assert not no_taps.measured("tap_count")


def test_a_wide_table_without_a_manifest_is_refused(tmp_path):
    table = _write_wide(_wide_rows(), tmp_path, with_manifest=False)
    with pytest.raises(StaleTableError, match="no manifest"):
        extract.read_wide_table(table)


def test_a_truncated_wide_table_is_refused_rather_than_read_short(tmp_path):
    table = _write_wide(_wide_rows(), tmp_path)
    kept = table.read_text(encoding="utf-8").splitlines()[:2]
    table.write_text("\n".join(kept) + "\n", encoding="utf-8")
    with pytest.raises(StaleTableError, match="checksum"):
        extract.read_wide_table(table)


def test_a_wide_table_grown_after_its_manifest_is_refused(tmp_path):
    """The interrupted-rerun case: last run's manifest beside this run's longer table."""
    extra = json.dumps(_wide_row("u3", "u3_session_1", "writing", WIDE_VALUES)) + "\n"
    table = _write_wide(_wide_rows(), tmp_path, append_after_manifest=extra)
    with pytest.raises(StaleTableError, match="checksum"):
        extract.read_wide_table(table)


def test_a_wide_table_that_is_simply_absent_says_where_it_comes_from(tmp_path):
    with pytest.raises(FileNotFoundError, match="hmog_wide_extract"):
        extract.read_wide_table(tmp_path / "nothing.jsonl")


def test_the_two_table_formats_refuse_each_others_files(tmp_path, table):
    """Neither loader may guess. A positional row read as named - or the reverse - yields a
    full-length vector of plausible nonsense and no error anywhere downstream."""
    wide = _write_wide(_wide_rows(), tmp_path)
    with pytest.raises(StaleTableError, match="read_wide_table reads version"):
        extract.read_wide_table(
            _write_wide(_wide_rows(), tmp_path / "v1", version=extract.EXTRACTOR_VERSION)
        )
    # read_table refuses the wide table on whichever guard fires first - its 80-name manifest
    # trips the positional feature-order check before the version check is reached. Either way
    # it refuses, which is the property that matters.
    with pytest.raises(StaleTableError):
        extract.read_table(wide)
    # With a manifest that does claim this schema's exact order, the version guard is what stops
    # it - so a future wide table written against 39 names cannot sneak through read_table.
    aligned = _write_wide(_wide_rows(), tmp_path / "aligned", names=list(NAMES))
    with pytest.raises(StaleTableError, match="extractor version 2"):
        extract.read_table(aligned)
    # And the version 1 table still loads through its own loader, unchanged.
    assert extract.read_table(table)


def test_a_wide_table_for_some_other_feature_set_is_refused(tmp_path):
    rows = [_wide_row("u1", "u1_session_1", "writing", {"keystroke_entropy": 1.0})]
    table = _write_wide(rows, tmp_path)
    with pytest.raises(StaleTableError, match="none of the"):
        extract.read_wide_table(table)


def test_a_wide_row_missing_its_task_or_values_is_refused(tmp_path):
    rows = _wide_rows()
    del rows[1]["values"]
    table = _write_wide([rows[0], rows[1]], tmp_path, names=sorted(WIDE_VALUES))
    with pytest.raises(StaleTableError, match="missing"):
        extract.read_wide_table(table)


def test_a_positional_values_vector_in_a_wide_row_is_refused(tmp_path):
    """The one shape that would otherwise be read as an empty mapping and pass silently."""
    rows = _wide_rows()
    rows[0]["values"] = [0.0] * len(FEATURES)
    table = _write_wide([rows[0]], tmp_path, names=sorted(WIDE_VALUES))
    with pytest.raises(StaleTableError, match="positional vector"):
        extract.read_wide_table(table)


# --- record_from_session fills every block the session carries -------------


def _touch(x: float, y: float, t_ms: float, size: float | None = 0.3) -> dict:
    sample = {"x": x, "y": y, "t_ms": t_ms, "pressure": 1.0}
    if size is not None:
        sample["size"] = size
    return sample


def _session(**overrides) -> dict:
    session = {
        "user": "u1",
        "session": "u1_session_1",
        "task": "writing",
        "posture": "sit",
        "strokes": [[_touch(0.0, 0.0, 0.0, 0.1 * i), _touch(10.0, 0.0, 10.0, 0.1 * i)]
                    for i in range(1, 6)],
        "key_events": [],
        "taps": [{"X": str(10.0 * i), "Y": "0", "Contact_size": "0.25", "Pressure": "1.0"}
                 for i in range(4)],
        "accel": [{"EventTime": "0", "X": "0", "Y": "0", "Z": "9.81"}],
        "gyro": [],
    }
    session.update(overrides)
    return session


def test_an_extraction_run_fills_the_size_and_tap_blocks():
    record = extract.record_from_session(_session())
    values = from_vector(record.features)

    assert record.blocks_present["size"] is True
    assert record.blocks_present["tap"] is True
    assert values["size_mean"] > 0.0
    assert values["size_iqr"] > 0.0
    assert values["tap_count"] == 4.0
    assert values["tap_x_iqr"] > 0.0
    assert values["tap_size_med"] == pytest.approx(0.25)
    for name in (*extract.names_for(block="size"), *extract.names_for(block="tap")):
        assert record.measured(name), name


def test_block_presence_covers_every_schema_block_and_never_over_claims():
    record = extract.record_from_session(_session())
    assert set(record.blocks_present) == set(extract.BLOCKS)
    assert record.blocks_present["pin"] is False       # no key events in this session
    assert record.blocks_present["imu"] is True


def test_geometry_without_contact_size_reports_the_size_block_absent():
    """`bool(strokes)` is the wrong question for this block: Contact_size can be blank where the
    geometry is recorded, and this is the bug that made the whole block come back empty."""
    strokes = [[_touch(0.0, 0.0, 0.0, None), _touch(10.0, 0.0, 10.0, None)]]
    record = extract.record_from_session(_session(strokes=strokes))
    assert record.blocks_present["swipe"] is True
    assert record.blocks_present["size"] is False
    assert record.features[INDEX["size_mean"]] == 0.0
    assert not record.measured("size_mean")


def test_a_session_with_no_taps_reports_the_tap_block_absent():
    record = extract.record_from_session(_session(taps=[]))
    assert record.blocks_present["tap"] is False
    assert record.features[INDEX["tap_count"]] == 0.0


def test_taps_also_feed_the_pin_blocks_coordinates_and_pressure():
    """KeyPressEvent carries neither, so without the tap table two PIN columns are substitutes."""
    keys = []
    for i in range(6):
        keys += [{"PressTime": str(100 * i), "PressType": "0", "KeyID": "65"},
                 {"PressTime": str(100 * i + 50), "PressType": "1", "KeyID": "65"}]
    record = extract.record_from_session(_session(key_events=keys))
    values = from_vector(record.features)
    assert record.blocks_present["pin"] is True
    assert values["pin_hold_1_ms"] == pytest.approx(50.0)
    assert values["pin_tap_offset_mean_px"] > 0.0
    assert values["pin_pressure_mean"] == pytest.approx(1.0)


def test_the_readers_session_dataclass_is_accepted_as_well_as_a_dict():
    """`iter_hmog_sessions` yields an HmogSession, the tests hand in dicts; the field names
    already agree, so both go through one path instead of one of them raising mid-archive."""
    from bhorosha_ato.datasets import HmogSession

    plain = _session()
    typed = HmogSession(
        user=plain["user"], session=plain["session"], task_id=7,
        task="writing", posture="sit",
        strokes=plain["strokes"], key_events=[], taps=plain["taps"],
        accel=plain["accel"], gyro=[],
    )
    assert extract.record_from_session(typed) == extract.record_from_session(plain)


# --- the shared reader dispatch -------------------------------------------

def test_read_any_table_picks_the_wide_reader_for_a_version_2_table(wide_table):
    """Both real callers - the trainer and the eval harness - were written against
    `read_table` alone, so both were dead on the only real extraction we have."""
    assert extract.read_any_table(wide_table) == extract.read_wide_table(wide_table)


def test_read_any_table_picks_the_positional_reader_for_a_version_1_table(table):
    assert extract.read_any_table(table) == extract.read_table(table)


def test_an_unknown_extractor_version_names_what_it_found_and_what_it_can_read(wide_table):
    """A caller facing this has to know which extractor to re-run, so the version it found
    and the versions it can read both have to be in the message."""
    manifest = extract.manifest_path(wide_table)
    payload = json.loads(manifest.read_text(encoding="utf-8"))
    payload["extractor_version"] = 99
    manifest.write_text(json.dumps(payload), encoding="utf-8")

    with pytest.raises(extract.StaleTableError) as info:
        extract.read_any_table(wide_table)
    message = str(info.value)
    assert "99" in message
    assert "read_table" in message and "read_wide_table" in message
    assert str(extract.WIDE_EXTRACTOR_VERSION) in message


def test_the_dispatch_is_not_a_filename_guess(tmp_path):
    """A version 2 table named like a version 1 one must still read as version 2. The
    filename is not evidence, and sniffing it was the obvious wrong implementation."""
    misleading = _write_wide(_wide_rows(), tmp_path, name="hmog_features.jsonl")
    assert len(extract.read_any_table(misleading)) == len(_wide_rows())


# --- version 3: the same row contract, more candidate columns ---------------

def test_a_version_3_table_reads_through_the_wide_loader(tmp_path):
    """v3 adds per-key hold-time columns and keeps the row contract, so it shares the loader.
    What must stay loud is the version 1 boundary, where rows are positional."""
    table = _write_wide(_wide_rows(), tmp_path, version=3)
    assert extract.read_any_table(table) == extract.read_wide_table(table)


def test_the_positional_boundary_is_still_refused(table):
    """The guard that matters: reading positional rows with the name-keyed loader would
    train on the wrong columns, which is the mistake the version number exists to catch."""
    with pytest.raises(extract.StaleTableError):
        extract.read_wide_table(table)


def test_a_block_the_schema_does_not_declare_is_dropped_not_fatal(tmp_path):
    """A wide table exists to carry more than the schema declares, and extra COLUMNS are
    tolerated - but SessionRecord requires its block keys to match BLOCKS exactly, so a writer
    announcing a candidate block (v3 announces `keyhold`) was fatal while its columns were fine.
    Nothing is lost: a candidate block's presence rides in its own columns."""
    rows = _wide_rows()
    for row in rows:
        row["blocks_present"] = {**row.get("blocks_present", {}), "keyhold": True}
    table = _write_wide(rows, tmp_path, version=3)

    records = extract.read_wide_table(table)
    assert records, "the rows must still load"
    for record in records:
        assert set(record.blocks_present) == set(extract.BLOCKS)
        assert "keyhold" not in record.blocks_present


# --- per-key hold ORDER, derived from keyhold_codes ------------------------

def test_ranks_are_derived_from_the_raw_codes_with_ties_sharing_a_midrank():
    """Hand-computed. 'e' and 't' share a median, so they share the mean of the two positions
    they occupy rather than being ordered by codepoint - a tie has no order to measure."""
    codes = [[32, 5, 40.0], [101, 4, 100.0], [116, 3, 100.0], [97, 2, 200.0]]
    out = extract.keyrank_values(codes)

    assert out == {
        "keyrank_space": 1 / 5,          # fastest of n=4
        "keyrank_e": 2.5 / 5,            # tied 2nd/3rd -> midrank 2.5
        "keyrank_t": 2.5 / 5,
        "keyrank_a": 4 / 5,              # slowest
    }


def test_a_real_rank_can_never_be_zero_or_one():
    """The whole reason 0.0 is a safe `missing` for this block: r/(n+1) is strictly inside
    (0, 1), so a substituted zero is detectable instead of reading as her fastest key."""
    for n in range(1, len(extract.KEYRANK_KEYS) + 1):
        codes = [[code, 1, float(i)] for i, (code, _) in enumerate(extract.KEYRANK_KEYS[:n])]
        values = extract.keyrank_values(codes)
        assert len(values) == n
        for name, rank in values.items():
            assert 0.0 < rank < 1.0, (n, name, rank)


def test_a_key_that_was_never_pressed_gets_no_column_at_all():
    out = extract.keyrank_values([[32, 3, 50.0]])
    assert out == {"keyrank_space": 0.5}
    assert "keyrank_e" not in out


def test_codes_outside_the_declared_set_do_not_get_ranked_but_do_not_break_it():
    """Writing sessions carry 23-41 distinct codepoints; only the declared ones are columns,
    and the rank must be over the declared keys alone or it could not be re-derived from a row."""
    out = extract.keyrank_values([[32, 2, 10.0], [55, 9, 20.0], [101, 2, 30.0]])
    assert set(out) == {"keyrank_space", "keyrank_e"}
    assert out["keyrank_space"] == 1 / 3 and out["keyrank_e"] == 2 / 3


def test_a_zero_press_count_is_not_a_measurement():
    """`keyhold_<key>_count` of 0 is how the extractor says she pressed nothing, and a median
    sitting beside it is meaningless rather than fast."""
    assert extract.keyrank_values([[32, 0, 0.0], [101, 2, 90.0]]) == {"keyrank_e": 0.5}


@pytest.mark.parametrize("codes", [
    None, [], "nonsense", 42,
    [[32, 1]],                     # too short
    [[32, 1, 2, 3]],               # too long
    [["x", 1, 2.0]],               # codepoint is not a number
    [[32, "many", 3.0]],           # press count is not a number
    [[32, 1, "fast"]],             # median is not a number
    [[None, None, None]],
])
def test_a_missing_or_malformed_dump_yields_no_ranks_rather_than_guesses(codes):
    assert extract.keyrank_values(codes) == {}


def test_one_malformed_entry_costs_that_key_and_not_the_whole_row():
    """The conversions were unguarded once, so a single non-numeric field anywhere in a
    2398-row table raised out of read_wide_table and took the entire read down with it."""
    out = extract.keyrank_values([["x", 1, 2.0], [32, 3, 50.0], [101, "many", 9.0],
                                  [97, 2, 80.0]])
    assert out == {"keyrank_space": 1 / 3, "keyrank_a": 2 / 3}
