"""The incident view's fixture must be what the radar produces today, and must carry no answer key.

fixtures/campaigns.json is the only thing the Incidents view and its two API routes read. If it
drifts from the radar, the console shows yesterday's incidents quietly; if an attempt in it carries a
label, the console would be showing the detector the answer it is being judged against. These tests
make both of those loud. The fresh build runs the radar once (a few seconds) and is shared.
"""

from __future__ import annotations

import json
import re
import sys
from collections import Counter
from pathlib import Path
from types import SimpleNamespace

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from tools import build_campaigns as bc  # noqa: E402

OFFSET = re.compile(r"[+-]\d\d:\d\d$")
GROUND_TRUTH_KEYS = ("ring_id", "label", "labels", "role", "typology", "is_fraud")


# eval/results/ is not committed. Without campaign.json a fresh build has no `evaluation` block, so only the
# detector half can be compared; run libs/radar/eval/radar_eval.py to check the whole file.
NEEDS_EVAL = pytest.mark.skipif(not bc.EVAL_JSON.exists(), reason="eval/results/campaign.json is absent; run libs/radar/eval/radar_eval.py")


def _checked(payload: dict) -> dict:
    out = bc.comparable(payload)
    if not bc.EVAL_JSON.exists():
        out = {k: v for k, v in out.items() if k != "evaluation"}
        out["source"] = {k: v for k, v in out["source"].items() if k != "eval_sha256"}
    return out


@pytest.fixture(scope="module")
def fresh() -> dict:
    return bc.build()


@pytest.fixture(scope="module")
def committed() -> dict:
    assert bc.FIXTURE.exists(), "fixtures/campaigns.json is missing; run tools/build_campaigns.py"
    return json.loads(bc.FIXTURE.read_text(encoding="utf-8"))


# --- the committed file is the build ---------------------------------------------------------------

def test_committed_fixture_equals_a_fresh_build(fresh: dict, committed: dict) -> None:
    assert _checked(committed) == _checked(fresh), "fixtures/campaigns.json is stale; run tools/build_campaigns.py"


@NEEDS_EVAL
def test_a_rebuild_is_byte_identical_apart_from_generated_at(fresh: dict) -> None:
    pinned = {**fresh, "generated_at": json.loads(bc.FIXTURE.read_text(encoding="utf-8"))["generated_at"]}
    assert bc.serialize(pinned) == bc.FIXTURE.read_text(encoding="utf-8")


@NEEDS_EVAL
def test_check_mode_reports_current(capsys: pytest.CaptureFixture[str]) -> None:
    assert bc.main(["--check"]) == 0
    assert "current" in capsys.readouterr().out


# --- no answer key -----------------------------------------------------------------------------------

def test_no_attempt_carries_truth_ring_or_label_fields(committed: dict) -> None:
    assert committed["attempts"], "the fixture holds no attempts"
    for attempt in committed["attempts"]:
        for key in attempt:
            assert not key.startswith("truth_"), (attempt["attempt_id"], key)
            assert key not in GROUND_TRUTH_KEYS, (attempt["attempt_id"], key)


def test_ground_truth_lives_only_under_evaluation(committed: dict) -> None:
    """Incidents, firings, campaigns and attempts are detector output; only `evaluation` is scored."""
    detector = json.dumps({k: committed[k] for k in ("incidents", "firings", "campaigns", "attempts")})
    for word in ("truth_", '"ring_id"', "incident_class", '"label', '"role"', '"typology"'):
        assert word not in detector, word


# --- adapter rules -----------------------------------------------------------------------------------

def test_every_radar_timestamp_leaves_with_the_dhaka_offset(committed: dict) -> None:
    stamps = [a["ts"] for a in committed["attempts"]]
    stamps += [f["run_ts"] for f in committed["firings"]]
    for incident in committed["incidents"]:
        stamps += [incident["opened_at"], incident["last_fired_at"], *incident["firing_runs"]]
    for campaign in committed["campaigns"]:
        stamps += [campaign["opened_at"], campaign["as_of"]]
    for row in committed["evaluation"]["campaigns"]:
        stamps += [row["flag_ts"], row["tenth_ts"]]
    assert stamps and all(OFFSET.search(ts) for ts in stamps)
    assert all(ts.endswith("+06:00") for ts in stamps if ts is not None and "T" in ts)


def test_with_offset_appends_dhaka_only_to_naive_stamps() -> None:
    assert bc.with_offset("2026-11-06T14:30:00") == "2026-11-06T14:30:00+06:00"
    assert bc.with_offset("2026-10-17T10:49:34+00:00") == "2026-10-17T10:49:34+00:00"
    assert bc.with_offset("2026-10-17T10:49:34Z") == "2026-10-17T10:49:34Z"
    assert bc.with_offset(None) is None


def test_joins_are_closed(committed: dict) -> None:
    """Every id the view joins on resolves inside the fixture; nothing points outside it."""
    attempts = {a["attempt_id"] for a in committed["attempts"]}
    incidents = {i["incident_id"] for i in committed["incidents"]}
    for incident in committed["incidents"]:
        assert set(incident["attempt_ids"]) <= attempts, incident["incident_id"]
    for campaign in committed["campaigns"]:
        assert set(campaign["incident_ids"]) <= incidents, campaign["campaign_id"]
        assert set(campaign["attempt_ids"]) <= attempts, campaign["campaign_id"]
        for source, target, _entity in campaign["evidence"]:
            assert {source, target} <= attempts
    runs = {(i["key"], i["cell"], run) for i in committed["incidents"] for run in i["firing_runs"]}
    assert committed["firings"] and all((f["key"], f["cell"], f["run_ts"]) in runs for f in committed["firings"])


def test_attempts_are_ordered_by_time_then_id(committed: dict) -> None:
    keys = [(a["ts"], a["attempt_id"]) for a in committed["attempts"]]
    assert keys == sorted(keys)


def test_shared_entities_group_payee_links_by_entity() -> None:
    campaign = SimpleNamespace(
        payees=("p1", "p2", "p3"),
        evidence=(("a2", "a1", "payee_sim_day:2026-10-25"),),
        payee_links=(
            {"payee": "p1", "entity": "onboarding_agent:AG-1", "kind": "onboarding_agent"},
            {"payee": "p2", "entity": "onboarding_agent:AG-1", "kind": "onboarding_agent"},
            {"payee": "p1", "entity": "sim_day:2026-10-25", "kind": "sim_day"},
            {"payee": "p3", "entity": "sim_day:2026-10-25", "kind": "sim_day"},
            {"payee": "p3", "entity": "device:d9", "kind": "device"},
        ),
    )
    assert bc.shared_entities(campaign) == [
        {"entity": "payee_onboarding_agent:AG-1", "kind": "payee_onboarding_agent", "payees": ["p1", "p2"], "in_evidence": False},
        {"entity": "payee_sim_day:2026-10-25", "kind": "payee_sim_day", "payees": ["p1", "p3"], "in_evidence": True},
    ]


def test_a_snapshot_contained_in_a_later_one_is_superseded() -> None:
    early = SimpleNamespace(campaign_id="camp_a", as_of="2026-10-19T15:15:00", attempt_ids=("x", "y"))
    late = SimpleNamespace(campaign_id="camp_b", as_of="2026-10-19T17:45:00", attempt_ids=("w", "x", "y"))
    other = SimpleNamespace(campaign_id="camp_c", as_of="2026-10-19T18:00:00", attempt_ids=("z", "y"))
    assert bc.superseded_by(early, (early, late, other)) == "camp_b"
    assert bc.superseded_by(late, (early, late, other)) is None
    assert bc.superseded_by(other, (early, late, other)) is None


# --- what the view is built to show -----------------------------------------------------------------

def test_the_three_campaigns_join_to_their_evaluation(committed: dict) -> None:
    campaigns = {c["campaign_id"]: c for c in committed["campaigns"]}
    matched = [row for row in committed["evaluation"]["campaigns"] if row["detected_campaign_id"]]
    assert len(matched) == 3
    for row in matched:
        campaign = campaigns[row["detected_campaign_id"]]
        assert campaign["superseded_by"] is None, "money must join the current snapshot"
        assert campaign["held"] > 0 and campaign["evidence"]
    over = [row for row in matched if row["payee_overreach"]]
    assert len(over) == 1 and committed["evaluation"]["payee_note"]


def test_incident_classes_are_eval_only_and_agree_with_campaign_json(committed: dict) -> None:
    evaluation = committed["evaluation"]
    rows = evaluation["incidents"]
    assert {r["incident_id"] for r in rows} == {i["incident_id"] for i in committed["incidents"]}
    assert dict(Counter(r["incident_class"] for r in rows)) == evaluation["incident_classes"]


@NEEDS_EVAL
def test_measures_are_copied_with_their_status(committed: dict) -> None:
    source = json.loads(bc.EVAL_JSON.read_text(encoding="utf-8"))
    measures = committed["evaluation"]["measures"]
    assert set(measures) == set(source["measures"])
    for name, row in measures.items():
        assert row["status"] == source["measures"][name]["status"]
        assert row["value"] == source["measures"][name]["value"]
    assert committed["evaluation"]["caveat"] == source["caveat"]


def test_inputs_are_recorded(committed: dict) -> None:
    source = committed["source"]
    assert source["synthetic"] is True
    assert source["seed_checksum"]
    assert "attempts.jsonl" in source["input_checksums"]
    assert source["eval_sha256"] and len(source["eval_sha256"]) == 64
