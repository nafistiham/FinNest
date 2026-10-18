"""The eval harness, exercised on generated sessions.

These tests are about the report, not about the models - `test_model.py` covers those. What
matters here is that nothing can leave this harness unlabelled or unsplit, that a suspiciously
good EER is flagged rather than celebrated, and that asking for a dataset nobody has yet fails
with instructions instead of a traceback.
"""

from __future__ import annotations

import json
import random

import numpy as np
import pytest

from bhorosha_ato import extract
from bhorosha_ato.model import (
    EER_LEAK_SUSPICION,
    MIN_ENROLMENT_SESSIONS,
    equal_error_rate,
)
from bhorosha_ato.schema import KEYRANK_KEYS, NAMES
from eval.ato_eval import (
    CAVEAT,
    COACHING_THRESHOLD,
    GENERATED,
    HMOG_ENROL,
    HMOG_HOLDOUT,
    IDENTITY_TASK_NAMES,
    MEASURED_HMOG,
    NOT_POOLABLE,
    NOT_RUN,
    POOLED_BOOTSTRAP_RESAMPLES,
    POOLED_HMOG,
    TARGETS,
    _READABLE_VERSIONS,
    _bootstrap_pooled_eer,
    _eer_distribution,
    EER_MEASURED,
    EER_SUSPECT,
    EER_WITHIN_BAND,
    _eer_status,
    _interval_qualified_status,
    _swept_eer,
    _hmog_split,
    _markdown,
    _measured,
    _posture_mix,
    _read_hmog_table,
    evaluate_hmog,
    evaluate_synthetic,
    main,
)

# Deliberately tiny: the suite has to stay fast, and none of these assertions are about
# statistical strength. `enrol` stays at or above MIN_ENROLMENT_SESSIONS so the models under
# test are the per-user ones the report claims to measure.
USERS, ENROL, HOLDOUT, SEED = 3, 6, 4, 30


@pytest.fixture(scope="module")
def report() -> dict:
    return evaluate_synthetic(USERS, ENROL, HOLDOUT, SEED)


def test_report_has_every_metric_the_targets_name(report):
    reported = set(report["metrics"])
    assert reported == {
        "identity_eer_mean",
        "identity_eer_std",
        "coached_detection_rate",
        "coached_false_positive_rate",
        "score_p50_ms",
        "score_p95_ms",
        "explanation_validator_pass_rate",
        "judge_faithfulness",
    }
    assert set(report) >= {"dataset", "source", "seed", "split", "metrics", "per_user", "caveat"}


def test_every_number_is_labelled_with_where_it_came_from(report):
    """The one failure this report cannot survive is a generated number read as a measured one."""
    for name, metric in report["metrics"].items():
        assert set(metric) == {"value", "target", "status", "source"}, name
        assert metric["source"], name
    assert report["dataset"] == "synthetic"
    assert "NOT a dataset result" in report["source"]
    for name in ("identity_eer_mean", "score_p95_ms"):
        assert report["metrics"][name]["source"] == GENERATED


def test_coached_metrics_say_they_can_never_be_measured(report):
    """No public dataset records a coached payment, so these stay synthetic even after HMOG."""
    for name in ("coached_detection_rate", "coached_false_positive_rate"):
        assert "no public coached dataset" in report["metrics"][name]["source"], name
    assert "no public dataset records a coached payment" in CAVEAT


def test_the_split_is_recorded_in_full(report):
    """An EER without its split is not a result, and model.Split's docstring says why."""
    split = report["split"]
    assert split["train_sessions_per_user"] == ENROL
    assert split["holdout_sessions_per_user"] == HOLDOUT
    assert split["impostor_users_per_subject"] == USERS - 1
    assert split["impostor_sessions_per_subject"] == (USERS - 1) * HOLDOUT
    assert "never train anything" in split["note"]
    for user in report["per_user"]:
        assert user["train_sessions"] == ENROL
        assert user["test_sessions"] == HOLDOUT
        assert user["impostor_users"] == USERS - 1
        assert user["per_user_model"] is True


def test_an_eer_below_the_leak_threshold_is_suspect_not_pass():
    # The leak floor is the one real gate here, and it still fails.
    assert _eer_status(EER_LEAK_SUSPICION - 0.001) == EER_SUSPECT
    assert _eer_status(0.0) == EER_SUSPECT
    assert _eer_status(0.05) == EER_WITHIN_BAND
    # Above the ceiling is a MEASUREMENT, not a failure: the band assumes keystroke timing in
    # the identity model and the spec's own second acceptance scenario forbids it. See the note
    # on TARGETS["eer_range"].
    assert _eer_status(TARGETS["eer_range"][1] + 0.01) == EER_MEASURED
    assert _eer_status(TARGETS["eer_range"][1] + 0.01) != "fail"


def test_the_generated_runs_low_eer_is_never_reported_as_a_pass(report):
    """Generated users are further apart than real ones, so this run should land in SUSPECT."""
    eer = report["metrics"]["identity_eer_mean"]
    if eer["value"] < EER_LEAK_SUSPICION:
        assert eer["status"] == "suspect"
    else:
        assert eer["status"] in {EER_WITHIN_BAND, EER_MEASURED}


def test_judge_is_reported_as_not_run_rather_than_omitted(report):
    judge = report["metrics"]["judge_faithfulness"]
    assert judge["value"] is None
    assert judge["status"] == NOT_RUN


def test_latency_is_reported_in_milliseconds(report):
    p50 = report["metrics"]["score_p50_ms"]["value"]
    p95 = report["metrics"]["score_p95_ms"]["value"]
    assert 0.0 < p50 <= p95 < TARGETS["score_p95_ms_max"]


def test_the_same_seed_reproduces_the_same_numbers(report):
    """Latency is wall-clock and will differ; everything derived from the RNG must not."""
    again = evaluate_synthetic(USERS, ENROL, HOLDOUT, SEED)
    assert again["per_user"] == report["per_user"]
    for name in ("identity_eer_mean", "coached_detection_rate", "coached_false_positive_rate"):
        assert again["metrics"][name]["value"] == report["metrics"][name]["value"], name


def test_markdown_renders_one_clean_table(report):
    """It is pasted into the proposal PDF, so the table has to be well formed on its own."""
    lines = _markdown(report).splitlines()
    table = [line for line in lines if line.startswith("|")]
    assert table[0].startswith("| Metric | Value | Target | Status | Source |")
    assert table[1] == "|---|---|---|---|---|"
    assert len(table) == 2 + len(report["metrics"]) + 1  # header, rule, metrics, split
    assert all(row.count("|") == 6 for row in table)
    assert any(row.startswith("| Split |") for row in table)
    assert "SUSPECT" in "\n".join(table) or "PASS" in "\n".join(table)
    assert CAVEAT in "\n".join(lines)


def test_too_few_users_is_an_error_not_an_eer_without_impostors():
    with pytest.raises(ValueError):
        evaluate_synthetic(1, ENROL, HOLDOUT, SEED)


def test_enrolment_below_the_cold_start_floor_is_refused():
    """train_ato would silently fall back to a global model; reporting that as per-user lies."""
    with pytest.raises(ValueError, match="MIN_ENROLMENT_SESSIONS"):
        evaluate_synthetic(USERS, MIN_ENROLMENT_SESSIONS - 1, HOLDOUT, SEED)


@pytest.mark.parametrize("dataset", ["hmog", "bbmas"])
def test_a_dataset_nobody_has_yet_fails_with_instructions(dataset):
    with pytest.raises(SystemExit) as exit_info:
        main(["--dataset", dataset, "--users", str(USERS)])
    message = str(exit_info.value)
    assert "bhorosha_ato.datasets" in message
    assert "--dataset synthetic" in message
    assert "To unblock it" in message


def test_judge_flag_refuses_rather_than_reporting_a_score_it_did_not_measure():
    with pytest.raises(SystemExit, match="explain"):
        main(["--judge", "--users", str(USERS)])


def test_main_writes_both_artefacts(tmp_path):
    out = tmp_path / "results" / "ato.json"
    assert main(["--users", str(USERS), "--enrol", str(ENROL), "--holdout", str(HOLDOUT),
                 "--seed", str(SEED), "--out", str(out)]) == 0

    written = json.loads(out.read_text(encoding="utf-8"))
    assert written["seed"] == SEED
    assert written["eval_seconds"] >= 0.0
    assert written["generated_at"]
    assert out.with_suffix(".md").read_text(encoding="utf-8").startswith("| Metric |")


# ---------------------------------------------------------------------------
# Which loader reads the hmog table, and what the report says the sessions were
# ---------------------------------------------------------------------------
#
# Two extracted tables exist on disk and neither supersedes the other: version 1 rows carry a
# positional feature vector, version 2 rows carry a name-keyed mapping of 80 candidates. The
# manifest decides. These tests exist because the two plausible shortcuts - dispatch on the
# filename, or try one loader and fall back on exception - both turn "this table is corrupt"
# into "read it with the other reader", and that produces a number from the wrong rows instead
# of an error.


def _write_table(tmp_path, rows, *, extractor_version, dataset="hmog", schema_names=None):
    """A table and a manifest that agrees with it, for whichever extractor version."""
    tmp_path.mkdir(parents=True, exist_ok=True)
    table = tmp_path / "features.jsonl"
    table.write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")
    # Counted by extract itself, not re-derived here: rows_per_task carries a key for every
    # HMOG task including the zeros, and a hand-rolled Counter omits them and trips the
    # manifest guard for a reason that has nothing to do with what is under test.
    per_user, per_task = extract._counts([
        extract.SessionRecord.from_dict(row) if "features" in row
        else extract._record_from_wide_row(row, 1)
        for row in rows
    ])
    names = NAMES if schema_names is None else schema_names
    manifest = extract.Manifest(
        dataset=dataset,
        source="test",
        table=table.name,
        table_sha256=extract._sha256(table),
        table_bytes=table.stat().st_size,
        rows=len(rows),
        schema_length=len(names),
        schema_names=tuple(names),
        rows_per_user=dict(per_user),
        rows_per_task=dict(per_task),
        extractor_version=extractor_version,
        generated_at="2026-10-16T00:00:00+00:00",
    )
    extract.manifest_path(table).write_text(
        json.dumps(manifest.as_dict(), indent=2) + "\n", encoding="utf-8"
    )
    return table


def _v1_row(user, session):
    return {
        "user": user,
        "session": session,
        "task": "writing",
        "features": [0.5] * len(NAMES),
        "blocks_present": {block: True for block in extract.BLOCKS},
        "posture": "sit",
    }


def _v2_row(user, session):
    """A WIDE row: features keyed by NAME, plus candidates this schema has no column for."""
    return {
        "user": user,
        "session": session,
        "task": "writing",
        "values": {name: 0.5 for name in NAMES} | {"candidate_not_in_schema": 1.0},
        "blocks_present": {block: True for block in extract.BLOCKS},
        "posture": "sit",
    }


def test_the_manifest_version_picks_the_loader_not_the_filename(tmp_path):
    """Same filename, different extractor version: each has to reach its own reader."""
    v1 = _write_table(tmp_path / "one", [_v1_row("u1", "s1")], extractor_version=1)
    v2 = _write_table(
        tmp_path / "two",
        [_v2_row("u1", "s1")],
        extractor_version=2,
        schema_names=list(NAMES) + ["candidate_not_in_schema"],
    )

    records_v1, manifest_v1 = _read_hmog_table(v1)
    records_v2, manifest_v2 = _read_hmog_table(v2)

    assert manifest_v1.extractor_version == extract.EXTRACTOR_VERSION
    assert manifest_v2.extractor_version == extract.WIDE_EXTRACTOR_VERSION
    # Both project onto the current schema, so the records are indistinguishable downstream -
    # which is the whole point of having two readers rather than two eval paths.
    assert len(records_v1) == len(records_v2) == 1
    assert len(records_v1[0].features) == len(records_v2[0].features) == len(NAMES)
    assert records_v2[0].features == records_v1[0].features


def test_a_wide_table_is_not_read_by_the_positional_loader(tmp_path):
    """The failure this dispatch prevents: v2 rows have no `features` key at all."""
    v2 = _write_table(
        tmp_path,
        [_v2_row("u1", "s1")],
        extractor_version=2,
        schema_names=list(NAMES) + ["candidate_not_in_schema"],
    )
    # Dispatching correctly succeeds where the other loader would not. Asserted through the
    # behaviour rather than against a lookup table: the dispatch now lives in
    # extract.read_any_table, because a second copy here drifted and left the harness refusing a
    # version the reader already understood.
    assert _read_hmog_table(v2)[0]
    with pytest.raises(Exception):
        extract.read_table(v2)


def test_an_unreadable_version_names_the_version_and_both_readers(tmp_path):
    """No silent fallback: a third format is refused, saying what it found and what is read."""
    table = _write_table(tmp_path, [_v1_row("u1", "s1")], extractor_version=99)
    with pytest.raises(extract.StaleTableError) as exit_info:
        _read_hmog_table(table)
    message = str(exit_info.value)
    assert "99" in message
    assert str(extract.EXTRACTOR_VERSION) in message
    assert str(extract.WIDE_EXTRACTOR_VERSION) in message
    assert "read_table" in message and "read_wide_table" in message


def test_the_positional_version_is_never_also_a_wide_version():
    """Overlap would make the dispatch ambiguous and the guard unable to fire."""
    assert extract.EXTRACTOR_VERSION not in extract.WIDE_EXTRACTOR_VERSIONS


def _fixture_table(tmp_path, version: int):
    """A table of the shape extractor `version` actually writes, with its manifest.

    Version 1 rows are POSITIONAL (`features`); versions 2 and 3 are the WIDE, name-keyed shape
    (`values` plus candidates the schema has no column for), and version 3 adds the
    `keyhold_codes` dump the per-key hold ranks are derived from and announces a `keyhold` block
    the schema does not declare - which was fatal in the reader once. Checked against
    bhorosha_ato.extract rather than taken on trust: `_record_from_wide_row` reads no version
    number, so what makes a row version 3 rather than version 2 is only those extra columns,
    and a row carrying them is a real version 3 fixture.
    """
    if version == extract.EXTRACTOR_VERSION:
        return _write_table(tmp_path, [_v1_row("u1", "s1")], extractor_version=version)
    rows = [_v2_row("u1", "s1")]
    if version == max(extract.WIDE_EXTRACTOR_VERSIONS):
        rows[0] = rows[0] | {
            # [codepoint, pairs, median_ms] per key pressed, which is what version 3 dumps.
            "keyhold_codes": [
                [code, 4, 80.0 + position] for position, (code, _) in enumerate(KEYRANK_KEYS)
            ],
            "blocks_present": rows[0]["blocks_present"] | {"keyhold": True},
        }
    return _write_table(
        tmp_path,
        rows,
        extractor_version=version,
        schema_names=list(NAMES) + ["candidate_not_in_schema"],
    )


@pytest.mark.parametrize("version", _READABLE_VERSIONS)
def test_every_version_the_harness_declares_readable_is_actually_read(tmp_path, version):
    """What `_READABLE_VERSIONS` claims, checked by READING a table of each version.

    The test this replaced iterated `(EXTRACTOR_VERSION, *WIDE_EXTRACTOR_VERSIONS)` and
    asserted each was in `_READABLE_VERSIONS` - which is defined as exactly that tuple, so it
    could not fail and guarded nothing. The drift it was written for is real: the harness once
    kept its own copy of the dispatch, so when the reader learned version 3 the harness went on
    refusing it and the only table carrying the per-key hold order could not be evaluated. What
    catches that is a fixture table of each declared version going through `_read_hmog_table`
    and coming back as records against the current schema, which is what this does.
    """
    table = _fixture_table(tmp_path, version)

    records, manifest = _read_hmog_table(table)

    assert manifest.extractor_version == version
    assert len(records) == 1
    # Whatever the on-disk shape, what comes back is a record against the current schema.
    assert len(records[0].features) == len(NAMES)
    assert set(records[0].blocks_present) == set(extract.BLOCKS)
    if version == max(extract.WIDE_EXTRACTOR_VERSIONS):
        # The columns that make version 3 version 3: derived from `keyhold_codes`, so presence
        # here is proof the harness read the v3-only payload and not just the v2 subset.
        assert records[0].blocks_present["keyrank"] is True
        ranks = [records[0].features[NAMES.index(f"keyrank_{s}")] for _, s in KEYRANK_KEYS]
        assert all(0.0 < r < 1.0 for r in ranks), ranks


def test_a_version_the_harness_does_not_declare_is_refused_not_guessed(tmp_path):
    """The other direction: `_READABLE_VERSIONS` must not understate what gets read either.

    Without this a reader that quietly accepted anything would satisfy the test above while the
    declared set said otherwise - and an unknown format read by some loader anyway is how a
    table of substituted zeros becomes a confident EER.
    """
    undeclared = max(_READABLE_VERSIONS) + 1
    # A table whose ROWS a loader could parse, so the only thing standing between it and being
    # read is the version guard. A deliberately malformed row would fail this test for the
    # wrong reason - a parse error rather than a refusal.
    table = _fixture_table(tmp_path, undeclared)

    with pytest.raises(extract.StaleTableError) as refusal:
        _read_hmog_table(table)
    assert str(undeclared) in str(refusal.value)


def test_every_label_names_the_sessions_the_split_actually_used():
    """The drift this file is cleaning up: prose naming sessions the split never touched.

    Identity moved to writing-only because it was MEASURED better there (0.1165 against 0.1818
    for reading+map), but the labels kept saying reading and map-navigation. Asserting the
    labels are DERIVED from extract.IDENTITY_TASKS is what stops it happening a third time.
    """
    assert extract.IDENTITY_TASKS == ("writing",)
    assert IDENTITY_TASK_NAMES == " + ".join(extract.IDENTITY_TASKS)
    assert MEASURED_HMOG == f"MEASURED on HMOG {IDENTITY_TASK_NAMES} sessions"
    for task in set(extract.TASKS) - set(extract.IDENTITY_TASKS):
        assert task not in MEASURED_HMOG, task


def test_the_hmog_split_defaults_fit_inside_one_task(tmp_path):
    """8 sessions per task, so 5 + 3 is the whole of a user's identity sessions - not 10 + 6."""
    assert HMOG_ENROL + HMOG_HOLDOUT == 8
    assert HMOG_ENROL >= MIN_ENROLMENT_SESSIONS


# ---------------------------------------------------------------------------
# The split delivers what the report says it delivered
# ---------------------------------------------------------------------------
#
# The regression these cover: `_hmog_split` used to allocate a ROUNDED quota per posture, so 4
# sitting + 4 walking sessions asked for 5 enrolment returned round(2.5) + round(2.5) = 2 + 2 =
# 4 - banker's rounding - while split["train_sessions_per_user"] went on printing the requested
# 5. Every model was fitted on 4 sessions and the report said 5, and because enrolment size
# dominates this metric that is a materially different EER (0.1588 at 4, 0.0897 at 5).


class _FakeSession:
    """Only the two attributes `_hmog_split` reads. A real SessionRecord needs 39 features."""

    def __init__(self, posture: str, index: int) -> None:
        self.posture = posture
        self.key = f"{posture}{index}"

    def __repr__(self) -> str:
        return self.key


def _sessions(**counts: int) -> list[_FakeSession]:
    return [_FakeSession(p, i) for p, n in counts.items() for i in range(n)]


# The posture shape HMOG's writing task actually has, measured off the v2 table: every one of
# the 100 users records 4 sitting and 4 walking writing sessions.
HMOG_POSTURE_SHAPE = {"sit": 4, "walk": 4}


def test_the_split_delivers_exactly_what_was_asked_for():
    """The banker's-rounding regression, pinned on the real posture shape."""
    train, test = _hmog_split(
        _sessions(**HMOG_POSTURE_SHAPE), HMOG_ENROL, HMOG_HOLDOUT, random.Random(30)
    )
    assert len(train) == HMOG_ENROL == 5
    assert len(test) == HMOG_HOLDOUT == 3
    # 5 + 3 of 8, so nothing is left over - the old version stranded one session per user.
    assert len(train) + len(test) == sum(HMOG_POSTURE_SHAPE.values())


@pytest.mark.parametrize("sit,walk", [(4, 4), (8, 0), (7, 1), (6, 2), (2, 6), (5, 5), (9, 3)])
def test_exact_counts_and_disjointness_whatever_the_posture_shape(sit, walk):
    """Exactness must not depend on the postures dividing evenly - that was the whole bug."""
    sessions = _sessions(sit=sit, walk=walk)
    train, test = _hmog_split(sessions, HMOG_ENROL, HMOG_HOLDOUT, random.Random(30))
    assert len(train) == HMOG_ENROL
    assert len(test) == HMOG_HOLDOUT
    assert not {s.key for s in train} & {s.key for s in test}
    # No session invented and none duplicated across the two sides.
    assert len({s.key for s in train + test}) == HMOG_ENROL + HMOG_HOLDOUT


def test_neither_side_is_single_posture_when_both_postures_are_available():
    """An unstratified shuffle once reported a falsely good 0.0710 by training on one posture."""
    train, test = _hmog_split(
        _sessions(**HMOG_POSTURE_SHAPE), HMOG_ENROL, HMOG_HOLDOUT, random.Random(30)
    )
    assert len(_posture_mix(train)) == 2, _posture_mix(train)
    assert len(_posture_mix(test)) == 2, _posture_mix(test)
    # 5 cannot split evenly across two equal postures, so 3 + 2 one way and 1 + 2 the other is
    # the expected asymmetry; what matters is that every posture count is non-zero.
    assert sorted(_posture_mix(train).values()) == [2, 3]
    assert sorted(_posture_mix(test).values()) == [1, 2]


def test_a_single_posture_user_is_split_rather_than_refused():
    """Nothing can be mixed if the user only ever sat, and that must not raise or drop them."""
    train, test = _hmog_split(_sessions(sit=8), HMOG_ENROL, HMOG_HOLDOUT, random.Random(30))
    assert len(train) == HMOG_ENROL and len(test) == HMOG_HOLDOUT
    assert set(_posture_mix(train)) == {"sit"}


def test_a_user_short_of_the_split_comes_back_short_not_padded():
    """The caller's eligibility check excludes these; the split must not invent sessions."""
    train, test = _hmog_split(_sessions(sit=2, walk=2), HMOG_ENROL, HMOG_HOLDOUT,
                              random.Random(30))
    assert len(train) + len(test) == 4


def test_the_same_seed_gives_the_same_split_and_a_different_seed_does_not():
    """Reproducible from the seed alone, which is what makes a reported EER checkable."""
    shape = HMOG_POSTURE_SHAPE
    first = _hmog_split(_sessions(**shape), HMOG_ENROL, HMOG_HOLDOUT, random.Random(30))
    same = _hmog_split(_sessions(**shape), HMOG_ENROL, HMOG_HOLDOUT, random.Random(30))
    other = _hmog_split(_sessions(**shape), HMOG_ENROL, HMOG_HOLDOUT, random.Random(31))
    assert [s.key for s in first[0]] == [s.key for s in same[0]]
    assert [s.key for s in first[1]] == [s.key for s in same[1]]
    assert [s.key for s in first[0]] != [s.key for s in other[0]]


def test_measured_reports_one_value_when_uniform_and_the_set_when_not():
    """The report must never print a target in place of what happened."""
    assert _measured([5, 5, 5]) == 5
    assert _measured([4, 5, 4]) == [4, 5]
    assert _measured([3]) == 3


# ---------------------------------------------------------------------------
# Two identity EERs, and the reader can see they disagree
# ---------------------------------------------------------------------------
#
# The per-user mean is an average of EERs each measured from `holdout` genuine scores - 3 on
# HMOG - so it can only take a handful of values per user and 28 of 100 users land at exactly
# 0.0 because the quantisation permits it. On the real table the mean PASSES at 0.0869 while
# the median is 0.0168, below EER_LEAK_SUSPICION, and the pooled sweep over all 300 genuine
# and 29,700 impostor scores FAILS at 0.1192. Both are reported; these pin that.


def test_the_distribution_exposes_a_mixture_rather_than_summarising_it():
    """A mean that sits where almost no user actually is has to be visibly a mixture."""
    # Half the users at 0, half near 0.3: the mean lands in the empty middle.
    eers = [0.0] * 50 + [0.3] * 50
    d = _eer_distribution(eers)
    assert d["users"] == 100
    assert d["mean"] == 0.15
    assert d["at_zero"] == 50
    assert d["below_leak_suspicion"] == 50
    assert d["leak_suspicion_threshold"] == EER_LEAK_SUSPICION
    # The mean is nowhere near either mode, which is the whole point of publishing the shape.
    assert d["min"] == 0.0 and d["max"] == 0.3
    assert d["q1"] == 0.0 and d["q3"] == 0.3


def test_the_distribution_counts_exact_zeros_separately_from_merely_small():
    """0.0 is what quantisation ALLOWS, not evidence the model is perfect for that user."""
    d = _eer_distribution([0.0, 0.0, 0.0001, 0.02, 0.2])
    assert d["at_zero"] == 2
    assert d["below_leak_suspicion"] == 4      # the two zeros, 0.0001 and 0.02
    assert d["median"] == 0.0001


def test_the_distribution_reports_the_median_beside_the_mean():
    """The disagreement the coordinator found: median below the floor, mean above it."""
    d = _eer_distribution([0.0] * 60 + [0.3] * 40)
    assert d["median"] < EER_LEAK_SUSPICION < d["mean"]


def test_the_distribution_survives_too_few_users_for_quartiles():
    """It must not raise on a tiny run; the optional figures come back as None or empty."""
    d = _eer_distribution([0.1])
    assert d["users"] == 1 and d["median"] == 0.1 and d["std"] == 0.0
    assert d["q1"] is None and d["q3"] is None and d["deciles"] == []


def test_a_pooled_eer_below_the_leak_floor_is_suspect_not_pass():
    """The better estimator gets no exemption: too-good pooled is still a leak signal."""
    assert _eer_status(EER_LEAK_SUSPICION - 0.001) == EER_SUSPECT
    assert _eer_status(0.0) == EER_SUSPECT
    # And the band above it behaves as for any other EER: in-band is in-band, and above the
    # ceiling is a measurement rather than a failure.
    assert _eer_status(0.05) == EER_WITHIN_BAND
    assert _eer_status(TARGETS["eer_range"][1] + 0.01) == EER_MEASURED


def test_the_pooled_eer_says_it_is_pooled_and_the_mean_keeps_its_own_label():
    """A reader must not be able to mistake one estimator for the other.

    identity_eer_mean deliberately keeps the unchanged MEASURED_HMOG source - it is an existing
    reported number - so the whole distinction has to be carried by the pooled metric's source.
    """
    assert POOLED_HMOG != MEASURED_HMOG
    assert "POOLED" in POOLED_HMOG
    assert "ONE ROC" in POOLED_HMOG
    # Still says which sessions it was measured on, derived from IDENTITY_TASKS.
    assert MEASURED_HMOG in POOLED_HMOG
    # And the refusal path names what is missing rather than printing a number anyway.
    assert "anchored_on_reference" in NOT_POOLABLE
    assert "do not mean the same thing" in NOT_POOLABLE


def test_the_markdown_can_label_the_pooled_eer():
    """_markdown indexes labels by metric name, so a new metric without one is a KeyError."""
    report = {
        "users": 2,
        "coaching_threshold": COACHING_THRESHOLD,
        "dataset": "hmog",
        "seed": 30,
        "caveat": "c",
        "metrics": {
            "identity_eer_pooled": {
                "value": 0.1192, "target": "0.03-0.1", "status": "fail", "source": POOLED_HMOG,
            },
            "identity_eer_mean": {
                "value": 0.0869, "target": "0.03-0.1", "status": "pass",
                "source": MEASURED_HMOG,
            },
        },
        "split": {
            "train_sessions_per_user": 5, "holdout_sessions_per_user": 3,
            "impostor_users_per_subject": 1, "impostor_sessions_per_subject": 3,
        },
    }
    table = [line for line in _markdown(report).splitlines() if line.startswith("|")]
    assert any("POOLED" in row for row in table)
    assert any("mean of per-user" in row for row in table)
    assert all(row.count("|") == 6 for row in table)


def test_a_run_that_cannot_anchor_declines_to_pool_rather_than_pooling_anyway(tmp_path):
    """The precondition is real, so the refusal has to be real too.

    Below model.MIN_REFERENCE_SESSIONS there is no population reference to anchor against, so
    every per-user model falls back to quantiles of its own margins and the scores stop sharing
    a scale. Measured on the full table, the same scores pool to 0.1853 unanchored against
    0.1192 anchored - so a pooled number from this path is not a noisier estimate of the same
    quantity, it is a different quantity wearing its name. It must come back NOT RUN.
    """
    rng = random.Random(30)
    rows = [
        {
            "user": f"u{user}",
            "session": f"u{user}_session_{session}",
            "task": "writing",
            "values": {name: rng.gauss(user, 0.5) for name in NAMES},
            "blocks_present": {block: True for block in extract.BLOCKS},
            "posture": "sit" if session % 2 else "walk",
        }
        for user in range(3)
        for session in range(8)
    ]
    table = _write_table(tmp_path, rows, extractor_version=2)

    report = evaluate_hmog(table, enrol=MIN_ENROLMENT_SESSIONS, holdout=2, seed=30)

    pooled = report["metrics"]["identity_eer_pooled"]
    assert pooled["value"] is None
    assert pooled["status"] == NOT_RUN
    assert pooled["source"] == NOT_POOLABLE
    assert report["identity_eer_pooled_detail"]["pooled"] is False
    assert report["identity_eer_pooled_detail"]["models_population_anchored"] == 0
    # No point estimate means no interval either: an interval around a number that was refused
    # would be the refused number arriving by the back door.
    assert report["identity_eer_pooled_interval"] is None
    # The per-user EER is unaffected - it only ever depended on within-user ranking.
    assert report["metrics"]["identity_eer_mean"]["value"] is not None
    # And the caveat says the pooled figure is missing instead of quietly omitting it.
    assert "NOT reported" in report["caveat"]


def test_unused_identity_sessions_is_always_present_even_at_zero(tmp_path):
    """An absent key and a zero are indistinguishable to a reader, and that is how a
    regression hides: this field reaching 0 is the proof the split used every session."""
    rng = random.Random(31)
    rows = [
        {
            "user": f"u{user}",
            "session": f"u{user}_session_{session}",
            "task": "writing",
            "values": {name: rng.gauss(user, 0.5) for name in NAMES},
            "blocks_present": {block: True for block in extract.BLOCKS},
            "posture": "sit" if session % 2 else "walk",
        }
        for user in range(3)
        for session in range(8)
    ]
    table = _write_table(tmp_path, rows, extractor_version=2)
    # 4 + 4 consumes all 8 of each user's sessions, so nothing may be left over.
    report = evaluate_hmog(table, enrol=4, holdout=4, seed=30)
    assert "unused_identity_sessions" in report["split"]
    assert report["split"]["unused_identity_sessions"] == 0
    # And it is still present (and non-zero) when the split genuinely cannot use everything.
    partial = evaluate_hmog(table, enrol=MIN_ENROLMENT_SESSIONS, holdout=2, seed=30)
    assert partial["split"]["unused_identity_sessions"] == 3 * (8 - MIN_ENROLMENT_SESSIONS - 2)


# ---------------------------------------------------------------------------
# The pooled EER carries an interval, and the status is honest about it
# ---------------------------------------------------------------------------
#
# The problem these pin: 0.0797 against a 0.03-0.10 band was reported with no interval
# at all, and the pooled figure rests on `holdout` genuine scores per user - 300 on the real
# table - so sampling error is large enough to decide whether the band is met. Measured on the
# real table at seed 30 the 95% user-bootstrap interval is 0.0605-0.0967 (SE 0.0094), so it
# does NOT cross the ceiling - but that is a measurement the harness has to keep making, not a
# sentence the report gets to assert once.


def _poolable_rows(users: int = 6, sessions: int = 8, seed: int = 30) -> list[dict]:
    """Enough users that every per-user model can anchor on a population reference.

    The other users' enrolment sessions have to reach model.MIN_REFERENCE_SESSIONS or train_ato
    takes the quantile fallback and the harness declines to pool at all - which is what
    test_a_run_that_cannot_anchor... covers. 6 users at enrol 5 gives 25 reference sessions
    against the 20 required.

    The users OVERLAP deliberately (mean spacing 0.5 of a shared sd of 1.0). The other fixtures
    here space them a full sd apart, which makes every user trivially separable: measured, that
    pools to an EER of exactly 0.0 and every resample agrees, so the interval comes back
    0.0000-0.0000 with a standard error of 0 and a bootstrap that did nothing would pass.
    At this spacing it pools to 0.1667 with a 95% interval of 0.1111-0.2167, which is a real
    interval around a real estimate.
    """
    rng = random.Random(seed)
    return [
        {
            "user": f"u{user}",
            "session": f"u{user}_session_{session}",
            "task": "writing",
            "values": {name: rng.gauss(user * 0.5, 1.0) for name in NAMES},
            "blocks_present": {block: True for block in extract.BLOCKS},
            "posture": "sit" if session % 2 else "walk",
        }
        for user in range(users)
        for session in range(sessions)
    ]


@pytest.fixture(scope="module")
def pooled_report(tmp_path_factory) -> dict:
    table = _write_table(
        tmp_path_factory.mktemp("poolable"), _poolable_rows(), extractor_version=2
    )
    return evaluate_hmog(table, enrol=5, holdout=3, seed=30)


def _pooled_scores(clusters: list[tuple[list[float], list[float]]]) -> float:
    """The pooled EER of these clusters, by the same sweep the bootstrap uses."""
    return _swept_eer(
        np.asarray([s for genuine, _ in clusters for s in genuine], dtype=float),
        np.asarray([s for _, impostor in clusters for s in impostor], dtype=float),
    )


def test_the_pooled_eer_is_reported_with_an_interval_not_on_its_own(pooled_report):
    """A point estimate against a bound, with nothing saying how precise it is, is not a result."""
    assert pooled_report["identity_eer_pooled_detail"]["pooled"] is True
    interval = pooled_report["identity_eer_pooled_interval"]
    assert interval is not None
    # Named so the bounds cannot be mistaken for the estimate, and the estimate is repeated
    # inside the block so the pairing needs no eye.
    assert interval["point_estimate"] == pooled_report["metrics"]["identity_eer_pooled"]["value"]
    assert interval["ci95_low"] <= interval["point_estimate"] <= interval["ci95_high"]
    assert interval["confidence"] == 0.95
    assert interval["resamples"] == POOLED_BOOTSTRAP_RESAMPLES
    # Resampled over USERS, and it says so - the whole difference between an honest interval
    # and one narrowed by treating one user's correlated scores as independent draws.
    assert interval["resample_unit"] == "user"
    assert interval["users_resampled"] == pooled_report["users"]
    assert "correlated" in interval["method"]
    # A real interval around a real estimate, not a degenerate one: a bootstrap that resampled
    # nothing would come back with both bounds on the point estimate and an SE of zero.
    assert interval["std_error"] > 0.0
    assert interval["ci95_low"] < interval["ci95_high"]


def test_the_metric_shape_other_readers_render_is_unchanged_by_the_interval(pooled_report):
    """The interval sits BESIDE the metric: eval/run.py renders metric dicts column by
    column, so widening Metric would have made every metric carry a field belonging to one."""
    for name, metric in pooled_report["metrics"].items():
        assert set(metric) == {"value", "target", "status", "source"}, name
    # And `status` keeps its four-value vocabulary, which _markdown and the shared summary print
    # verbatim; the qualification lives in a field of its own.
    assert pooled_report["metrics"]["identity_eer_pooled"]["status"] in {
        # The vocabulary other readers render. "measured" replaced "fail" for the EER:
        # see the note on TARGETS["eer_range"] for why the ceiling is not a gate.
        EER_SUSPECT, EER_WITHIN_BAND, EER_MEASURED, NOT_RUN,
    }


def test_the_status_is_qualified_by_the_interval_rather_than_left_bare(pooled_report):
    """A bare PASS whose interval crosses the bound overstates the run, and has to say so."""
    interval = pooled_report["identity_eer_pooled_interval"]
    point_status = pooled_report["metrics"]["identity_eer_pooled"]["status"]
    assert interval["status_qualified"].startswith(point_status)
    crosses = (interval["interval_crosses_target_ceiling"]
               or interval["interval_crosses_leak_suspicion_floor"])
    assert interval["interval_agrees_with_point_status"] is not crosses
    if crosses:
        assert "ONLY" in interval["status_qualified"]
    else:
        # The ceiling is reported, never used to qualify. Which of the three relationships
        # holds depends on the interval, so what is asserted is that one of them is stated and
        # that the sentence carries no verdict about the band.
        qualified = interval["status_qualified"]
        assert any(phrase in qualified for phrase in (
            "lies inside the spec's", "lies wholly above the spec's", "spans the spec's",
        )), qualified
        assert "ONLY" not in qualified
        assert "reported rather than gated on" in qualified
    # And the prose caveat - the part eval/run.py's summary renders verbatim - carries it too,
    # with the seed, so a reader of the summary alone still sees the interval.
    assert f"{interval['ci95_low']:.4f}-{interval['ci95_high']:.4f}" in pooled_report["caveat"]
    assert f"seed {pooled_report['seed']}" in pooled_report["caveat"]


@pytest.mark.parametrize(
    "point,low,high,expect",
    [
        # A pass whose interval reaches past the ceiling is a pass at the point estimate only.
        # Spanning the ceiling is reported, not a qualification - the band is not a gate.
        (0.0797, 0.06, 0.11, ("within band", "spans the spec's 0.1 ceiling")),
        # An interval that stays inside the band says so; only the leak floor qualifies.
        (0.0797, 0.06, 0.09, ("within band", "lies inside the spec's")),
        # Reaching below the floor is a different finding: a leak signal, not a missed bound.
        # Reaching below the leak floor IS a qualification, and the only one.
        (0.0797, 0.02, 0.09, ("leak cannot be ruled out", "leak-suspicion floor")),
        (0.0797, 0.02, 0.12, ("leak cannot be ruled out", "leak-suspicion floor")),
        # And honest in the other direction too: a fail whose interval lies wholly above the
        # band has not "crossed" anything, so it must not be hedged into a maybe-pass.
        (0.1667, 0.1111, 0.2167, ("measured", "lies wholly above the spec's")),
        (0.1667, 0.09, 0.2167, ("measured", "spans the spec's 0.1 ceiling")),
    ],
)
def test_the_qualified_status_names_which_bound_the_interval_crosses(point, low, high, expect):
    """"The interval overlaps the bound" is several different findings, and one of them is a leak
    signal rather than a missed target. Which one has to be in the text."""
    qualified = _interval_qualified_status(point, low, high)
    assert qualified.startswith(_eer_status(point))
    for fragment in expect:
        assert fragment in qualified, qualified


def test_the_interval_is_reproducible_from_the_report_seed():
    """Seeded like everything else here: a headline interval nobody can reproduce is no better
    than no interval, and `Date.now`-style entropy would make one command disagree with itself."""
    clusters = [([0.1 * u, 0.1 * u + 0.05], [0.4, 0.5, 0.6, 0.7]) for u in range(8)]
    point = _pooled_scores(clusters)
    first = _bootstrap_pooled_eer(clusters, point, 30, resamples=200)
    again = _bootstrap_pooled_eer(clusters, point, 30, resamples=200)
    other = _bootstrap_pooled_eer(clusters, point, 31, resamples=200)
    assert first == again
    assert first["seed"] == 30 and other["seed"] == 31
    # A different seed is a different draw, and must still be a deterministic one.
    assert other == _bootstrap_pooled_eer(clusters, point, 31, resamples=200)


def test_resampling_users_gives_a_wider_interval_than_resampling_scores_would():
    """Why the unit is the user: scores from one person move together.

    The same scores regrouped so that every score is its own cluster is what score-level
    resampling amounts to, and it reports a narrower interval over identical data. Measured on
    the real table the understatement is 0.0633-0.0933 (SE 0.0081) against the user-level
    0.0605-0.0967 (SE 0.0094); here only the direction is asserted, which is a property of the
    clustering rather than of this fixture's numbers.
    """
    rng = random.Random(30)
    # Users who are wholly separable or wholly not - the correlation the clustering exists to
    # respect: a user whose model sits badly contributes three bad scores, not one.
    clusters = [
        ([0.9, 0.95, 0.92] if user % 3 == 0 else [0.1, 0.15, 0.12],
         [rng.uniform(0.4, 0.8) for _ in range(12)])
        for user in range(12)
    ]
    singletons = [
        ([genuine], [impostor])
        for cluster_genuine, cluster_impostors in clusters
        for genuine, impostor in zip(cluster_genuine, cluster_impostors, strict=False)
    ]

    clustered = _bootstrap_pooled_eer(
        clusters, _pooled_scores(clusters), 30, resamples=500
    )
    unclustered = _bootstrap_pooled_eer(
        singletons, _pooled_scores(singletons), 30, resamples=500
    )

    # Measured on this fixture the clustered standard error is 0.13-0.14 against 0.078-0.082 at
    # seeds 29/30/31/42 - a factor of about 1.7 - so a margin is asserted rather than a bare
    # inequality: the two arms come out within 0.0001 of each other the moment the clustering is
    # dropped, and a strict > would then be deciding the test on noise.
    assert clustered["std_error"] > 1.25 * unclustered["std_error"]


def test_the_bootstrap_refuses_an_interval_that_is_not_around_the_reported_number():
    """The fast sweep exists for speed, so it is checked against the estimator that produced the
    headline figure: an interval drawn around a different quantity is worse than none."""
    clusters = [([0.2, 0.3], [0.5, 0.6, 0.7]) for _ in range(4)]
    with pytest.raises(AssertionError) as mismatch:
        _bootstrap_pooled_eer(clusters, 0.42, 30, resamples=10)
    assert "model.equal_error_rate" in str(mismatch.value)


@pytest.mark.parametrize("seed", [1, 2, 3])
def test_the_fast_sweep_is_the_same_estimator_as_model_equal_error_rate(seed):
    """Not approximately the same: the same threshold grid, the same tie-break, the same number.

    Measured on the real pooled sample the two agree to 3e-17, and the reference implementation
    costs 0.29s a call against 1.6ms - which is the only reason there are two.
    """
    rng = random.Random(seed)
    genuine = [rng.gauss(0.3, 0.2) for _ in range(40)]
    impostor = [rng.gauss(0.7, 0.2) for _ in range(400)]
    # Exact ties included deliberately: a sweep's tie-break is where two implementations part.
    genuine += impostor[:5]
    reference, _ = equal_error_rate(genuine, impostor)
    swept = _swept_eer(np.asarray(genuine, dtype=float), np.asarray(impostor, dtype=float))
    assert swept == pytest.approx(reference, abs=1e-12)
