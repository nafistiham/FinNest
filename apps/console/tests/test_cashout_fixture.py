"""The cash-out view's fixture must be what the radar's cash-out rules produce today, and carry no answer key.

fixtures/cashout.json is the only thing the cash-out view and its two API routes read. If it drifts from the rules,
the console shows yesterday's flags quietly; if a detector section carries a label, the console would be showing the
rules the answer they are judged against. Only `evaluation` may know who was a mule. The fresh build replays the
rules at every midnight of the campaign world once (a few seconds) and is shared.
"""

from __future__ import annotations

import json
import math
import re
import sys
from pathlib import Path
from typing import Any

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from tools import build_cashout as bco  # noqa: E402

OFFSET = re.compile(r"T\d\d:\d\d:\d\d\+06:00$")
DATE = re.compile(r"\d{4}-\d{2}-\d{2}")
DETECTOR = ("source", "config", "tills", "days", "candidates", "not_flagged", "clusters", "events")
GROUND_TRUTH_KEYS = ("ring_id", "rings", "label", "labels", "labelled", "role", "roles", "typology", "is_fraud",
                     "outcome", "confirmed_at", "lead_days", "right", "true", "false")
KINDS = {"seed", "candidate", "ordinary"}
OUTCOMES = {"mule", "not_mule"}


# eval/results/ is not committed. Without cashout.json a fresh build has no `evaluation` block, so only the
# detector half can be compared; run libs/radar/eval/cashout_eval.py to check the whole file.
NEEDS_EVAL = pytest.mark.skipif(not bco.EVAL_JSON.exists(), reason="eval/results/cashout.json is absent; run libs/radar/eval/cashout_eval.py")


def _checked(payload: dict) -> dict:
    out = bco.comparable(payload)
    if not bco.EVAL_JSON.exists():
        out = {k: v for k, v in out.items() if k != "evaluation"}
        out["source"] = {k: v for k, v in out["source"].items() if k != "eval_sha256"}
    return out


@pytest.fixture(scope="module")
def fresh() -> dict:
    return bco.build()


@pytest.fixture(scope="module")
def committed() -> dict:
    assert bco.FIXTURE.exists(), "fixtures/cashout.json is missing; run tools/build_cashout.py"
    return json.loads(bco.FIXTURE.read_text(encoding="utf-8"))


def _keys(value: Any) -> set[str]:
    if isinstance(value, dict):
        return set(value) | {k for item in value.values() for k in _keys(item)}
    if isinstance(value, list):
        return {k for item in value for k in _keys(item)}
    return set()


# --- the committed file is the build ---------------------------------------------------------------

def test_committed_fixture_equals_a_fresh_build(fresh: dict, committed: dict) -> None:
    assert _checked(committed) == _checked(fresh), "fixtures/cashout.json is stale; run tools/build_cashout.py"


@NEEDS_EVAL
def test_a_rebuild_is_byte_identical_apart_from_generated_at(fresh: dict) -> None:
    pinned = {**fresh, "generated_at": json.loads(bco.FIXTURE.read_text(encoding="utf-8"))["generated_at"]}
    assert bco.serialize(pinned) == bco.FIXTURE.read_text(encoding="utf-8")


@NEEDS_EVAL
def test_check_mode_reports_current(capsys: pytest.CaptureFixture[str]) -> None:
    assert bco.main(["--check"]) == 0
    assert "current" in capsys.readouterr().out


# --- no answer key -----------------------------------------------------------------------------------

def test_detector_sections_carry_no_label_ring_or_truth_field(committed: dict) -> None:
    for section in DETECTOR:
        keys = _keys(committed[section])
        assert not {k for k in keys if k.startswith("truth_")}, section
        assert not keys & set(GROUND_TRUTH_KEYS), (section, keys & set(GROUND_TRUTH_KEYS))
    text = json.dumps({k: committed[k] for k in DETECTOR})
    for word in ("truth_", '"ring_', "ring_id", '"typology"', '"labelled"', '"outcome"', "not_yet_known"):
        assert word not in text, word


def test_only_evaluation_knows_the_outcome_of_each_candidate(committed: dict) -> None:
    rows = committed["evaluation"]["candidates"]
    assert {(r["acct"], r["filter"]) for r in rows} == {(c["acct"], c["filter"]) for c in committed["candidates"]}
    assert {r["outcome"] for r in rows} <= OUTCOMES
    assert all(r["outcome"] != "mule" or r["labelled"] == "mule" for r in rows)


def test_outcome_is_mule_for_every_labelled_ring_member_whatever_its_confirmation_date() -> None:
    assert bco.outcome("mule") == "mule"
    assert bco.outcome("victim") == "not_mule"
    assert bco.outcome("unlabelled") == "not_mule"


def test_the_outcomes_agree_with_the_evaluations_precision(committed: dict) -> None:
    """The console counts a candidate true exactly as cashout_eval does: a labelled non-victim ring member, even one
    confirmed after the world's last day (its confirmation and lead stay beside the outcome)."""
    rows = committed["evaluation"]["candidates"]
    last = committed["days"][-1]["as_of"]
    for name, measured in committed["evaluation"]["measures"]["filters"].items():
        mine = [r for r in rows if r["filter"] == name]
        assert sum(r["outcome"] == "mule" for r in mine) == measured["candidates"]["true"], name
    for r in rows:
        assert (r["outcome"] == "mule") == (r["labelled"] == "mule"), r["acct"]
        assert (r["confirmed_at"] is not None) == (r["outcome"] == "mule"), r["acct"]
        assert (r["lead_days"] is not None) == (r["outcome"] == "mule"), r["acct"]
    late = [r for r in rows if r["outcome"] == "mule" and r["confirmed_at"] > last]
    assert late, "the campaign world has no true candidate confirmed after its last day"


# --- the shape the view draws ------------------------------------------------------------------------

def test_every_till_has_coordinates(committed: dict) -> None:
    tills = committed["tills"]
    assert len(tills) == 40 and len({t["id"] for t in tills}) == 40
    for till in tills:
        assert math.isfinite(till["lat"]) and -90 <= till["lat"] <= 90, till["id"]
        assert math.isfinite(till["lon"]) and -180 <= till["lon"] <= 180, till["id"]
    known = {t["id"] for t in tills}
    named = {f["id"] for day in committed["days"] for f in day["till_flags"]}
    named |= {e["till"] for rows in committed["events"].values() for e in rows}
    named |= {till for c in committed["clusters"] for till in c["tills"]}
    assert named <= known


def test_every_flag_is_at_or_below_the_threshold_in_the_config(committed: dict) -> None:
    config = committed["config"]
    flags = [f for day in committed["days"] for f in day["till_flags"]]
    assert flags, "the campaign world flags no till on any day"
    for flag in flags:
        assert flag["p_value"] <= config["TILL_REUSE_P_THRESHOLD"], flag
        assert len(flag["seed_accounts"]) >= config["TILL_REUSE_MIN_SEEDS"], flag
    for cluster in committed["clusters"]:
        assert cluster["p_value"] <= config["CLUSTER_P_THRESHOLD"], cluster["cluster_id"]
        assert cluster["observed"] >= config["CLUSTER_MIN_CASHOUTS"], cluster["cluster_id"]


def test_the_config_is_the_one_the_evaluation_ran_with(committed: dict) -> None:
    evaluated = {k: v for k, v in committed["evaluation"]["config"].items() if k != "HORIZON_DAYS"}
    assert committed["config"] == evaluated


def test_one_day_per_daily_run(committed: dict) -> None:
    days, measures = committed["days"], committed["evaluation"]["measures"]
    dates = [d["date"] for d in days]
    assert dates == sorted(set(dates)) and all(DATE.fullmatch(d) for d in dates)
    assert len(days) == measures["days_run"]
    assert all(d["as_of"] == f"{d['date']}T00:00:00+06:00" for d in days)
    assert sum(bool(d["till_flags"]) for d in days) == measures["till_flags"]["days_with_a_flag"]


def test_events_are_kept_only_for_days_with_a_flag_or_a_cluster(committed: dict) -> None:
    busy = {d["date"] for d in committed["days"] if d["till_flags"] or d["clusters"]}
    assert busy and set(committed["events"]) == busy
    for date, rows in committed["events"].items():
        assert rows and {e["kind"] for e in rows} <= KINDS, date
        assert [(e["ts"], e["txn_id"]) for e in rows] == sorted((e["ts"], e["txn_id"]) for e in rows), date
        assert len({e["txn_id"] for e in rows}) == len(rows), date


def test_a_days_events_hold_what_its_flags_and_candidates_rest_on(committed: dict) -> None:
    candidates = committed["candidates"]
    for day in (d for d in committed["days"] if d["date"] in committed["events"]):
        rows = committed["events"][day["date"]]
        assert all(e["ts"] <= day["as_of"] for e in rows), day["date"]
        for flag in day["till_flags"]:
            seeded = {e["acct"] for e in rows if e["till"] == flag["id"] and e["kind"] == "seed"}
            assert seeded == set(flag["seed_accounts"]), (day["date"], flag["id"])
        for lead in (c for c in candidates if c["first_day"] == day["date"]):
            assert any(e["acct"] == lead["acct"] and e["ts"] == lead["ts"] and e["kind"] == "candidate" for e in rows)


def test_candidates_and_held_back_counts_agree_with_the_evaluation(committed: dict) -> None:
    filters = committed["evaluation"]["measures"]["filters"]
    for name, measured in filters.items():
        named = [c for c in committed["candidates"] if c["filter"] == name]
        assert len(named) == measured["candidates"]["total"], name
        assert committed["not_flagged"][name]["accounts"] == measured["held_back"]["accounts"], name
        assert sum(committed["not_flagged"][name]["by_reason"].values()) == measured["held_back"]["accounts"], name
    for candidate in committed["candidates"]:
        assert candidate["days"][0] == candidate["first_day"] and candidate["days"] == sorted(candidate["days"])


def test_pass_through_share_is_cashed_out_over_received(committed: dict) -> None:
    assert committed["candidates"], "the campaign world names no candidate"
    for c in committed["candidates"]:
        if c["received_bdt"]:
            assert c["pass_through_share"] == pytest.approx(c["cashed_out_bdt"] / c["received_bdt"]), c["acct"]
        else:
            assert c["pass_through_share"] is None, c["acct"]


def test_clusters_are_replayed_and_drawable(committed: dict) -> None:
    clusters, measures = committed["clusters"], committed["evaluation"]["measures"]
    replayed = [c for c in clusters if c["mode"] == "replay"]
    assert len(replayed) == measures["replayed_clusters"]["clusters"]
    assert len([c for c in clusters if c["mode"] == "live"]) == measures["live_clusters"]
    listed = {(c, d["date"]) for d in committed["days"] for c in d["clusters"]}
    for cluster in clusters:
        assert cluster["seed_cashouts"], cluster["cluster_id"]
        assert cluster["observed"] == len(cluster["seed_cashouts"]) + len(cluster["other_cashouts"])
        for row in cluster["seed_cashouts"] + cluster["other_cashouts"]:
            assert math.isfinite(row["lat"]) and math.isfinite(row["lon"]) and OFFSET.search(row["ts"])
            assert cluster["window_start"] <= row["ts"] <= cluster["window_end"]
        assert {(cluster["cluster_id"], d) for d in cluster["days"]} <= listed


def test_every_radar_timestamp_leaves_with_the_dhaka_offset(committed: dict) -> None:
    stamps = [d["as_of"] for d in committed["days"]]
    stamps += [f[k] for d in committed["days"] for f in d["till_flags"] for k in ("first_seen_ts", "last_seed_ts")]
    stamps += [c["ts"] for c in committed["candidates"]]
    stamps += [e["ts"] for rows in committed["events"].values() for e in rows]
    for c in committed["clusters"]:
        stamps += [c["opened_at"], c["window_start"], c["window_end"]]
    stamps += [t["opened"] for t in committed["tills"] if t["opened"] is not None]
    stamps += [r["confirmed_at"] for r in committed["evaluation"]["candidates"] if r["confirmed_at"]]
    assert stamps and all(OFFSET.search(ts) for ts in stamps)


def test_inputs_are_recorded(committed: dict) -> None:
    source = committed["source"]
    assert source["synthetic"] is True
    assert source["seed_checksum"] == committed["evaluation"]["seed_checksum"]
    assert {"transactions.jsonl", "agents.jsonl", "labels.jsonl"} <= set(source["input_checksums"])
    assert source["eval_sha256"] and len(source["eval_sha256"]) == 64


@NEEDS_EVAL
def test_measures_and_caveat_are_copied(committed: dict) -> None:
    report = json.loads(bco.EVAL_JSON.read_text(encoding="utf-8"))
    world = next(w for w in report["worlds"] if w["world"] == "seed_campaign")
    measures = committed["evaluation"]["measures"]
    assert measures["filters"] == world["summary"]["filters"]
    assert measures["till_flags"] == world["summary"]["till_flags"]
    assert committed["evaluation"]["caveat"] == report["caveat"]
