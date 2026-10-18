"""The Case Zero case file: one investigation as an analyst reads it.

The watch-list row showed three sentences; Case Zero's report holds the decision and who made which part of it, every
member with its role and the calls that prove it, the red flags, the timeline, the look-alikes it ruled out, both
narratives, the model's reasons, the checks code ran and what the run cost. `casezero.case_file` shapes that from
Case Zero's own report and events; the recorded run in the repo is the fixture, so these tests need no network.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from api import casezero  # noqa: E402
from api.main import app  # noqa: E402

REPLAY = ROOT.parents[1] / "services" / "case-zero" / "static" / "replay" / "demo.jsonl"


@pytest.fixture(scope="module")
def anonymous() -> TestClient:
    return TestClient(app)


@pytest.fixture(scope="module")
def client(anonymous: TestClient) -> TestClient:
    """A signed-in operator, as in test_router.py."""
    response = anonymous.post("/v1/auth/login", json={"username": "admin", "password": "finnest-local-dev"})
    assert response.status_code == 200, response.text
    signed_in = TestClient(app)
    signed_in.headers["Authorization"] = f"Bearer {response.json()['token']}"
    return signed_in


@pytest.fixture(scope="module")
def recorded() -> tuple[dict, list[dict]]:
    events = [json.loads(line) for line in REPLAY.read_text(encoding="utf-8").splitlines() if line.strip()]
    return next(e for e in events if e["type"] == "report")["report"], events


def test_the_recorded_run_reads_as_a_full_case_file(recorded):
    report, events = recorded
    f = casezero.case_file(report, events, source="recorded")
    assert (f["case_id"], f["seed"], f["source"], f["status"]) == (report["case_id"], "acct_01070", "recorded", "done")
    d = f["decision"]
    assert (d["action"], d["floor_action"], d["proposed_action"], d["band"]) == ("freeze", "freeze", "freeze", "critical")
    assert d["model_score"] == report["model_score"] and d["escalated"] is False
    assert f["typology"] == report["draft"]["typology"]
    roles = {m["acct_id"]: m["role"] for m in f["members"]}
    assert roles["acct_rina"] == "victim" and roles["acct_01070"] == "mule_L1" and len(roles) == 7
    assert {x["acct_id"] for x in f["excluded"]} >= {"acct_merchant_MR-0006"}
    assert [r["code"] for r in f["red_flags"]] == [r["code"] for r in report["draft"]["red_flags"]]
    assert all(r["meaning"]["en"] and r["meaning"]["bn"] for r in f["red_flags"])
    assert f["timeline"] and all(t["ts"] and t["text"] for t in f["timeline"])
    assert f["narrative"]["en"] and f["narrative"]["bn"]
    assert f["model_reasons"] and {"feature", "contribution"} <= set(f["model_reasons"][0])


def test_every_cited_call_names_the_tool_that_ran():
    events = [{"type": "tool_call", "call_id": "tc_01", "name": "neighbours", "args": {"acct_id": "acct_01070", "hops": 1}},
              {"type": "tool_call", "call_id": "tc_02", "name": "shared_entities", "args": {"acct_ids": ["a", "b"]}}]
    report = {"case_id": "CZ-TEST", "seed": "acct_01070", "draft": {"red_flags": [{"code": "RF07", "text": "x", "evidence": ["tc_00", "tc_02", "tc_09"]}]}}
    f = casezero.case_file(report, events, source="live")
    assert f["red_flags"][0]["evidence"] == [{"call_id": "tc_00", "tool": "seed_brief"}, {"call_id": "tc_02", "tool": "shared_entities"},
                                             {"call_id": "tc_09", "tool": None}]
    assert [c["call_id"] for c in f["calls"]] == ["tc_00", "tc_01", "tc_02"] and f["calls"][1]["args"] == {"acct_id": "acct_01070", "hops": 1}


def test_the_checks_and_the_run_are_reported(recorded):
    report, events = recorded
    f = casezero.case_file(report, events, source="recorded")
    c = f["checks"]
    assert c["citations_passed_first_time"] is True and c["retried"] is False
    assert c["members_kept"] == len(report["validation"]["gate"]["kept"]) and c["moved_to_excluded"] == []
    r = f["run"]
    assert r["tool_calls"] == sum(1 for e in events if e["type"] == "tool_call") and r["model"] == "gemini-3.8-flash"
    assert r["cost_usd"] == report["cost"]["cost_usd"] and r["seconds"] == next(e["_t"] for e in events if e["type"] == "done")


def test_a_case_with_no_events_or_draft_still_reads():
    f = casezero.case_file({"case_id": "CZ-BARE", "status": "failed"}, [], source="live")
    assert f["case_id"] == "CZ-BARE" and f["members"] == [] and f["red_flags"] == [] and f["narrative"] == {"en": "", "bn": ""}
    assert f["decision"]["action"] is None and f["run"]["seconds"] is None


# --- routes ---------------------------------------------------------------------------------------------------------


def test_the_live_case_file_route(client: TestClient, recorded, monkeypatch):
    report, events = recorded
    monkeypatch.setattr(casezero, "case", lambda case_id: {**report, "case_id": case_id})
    monkeypatch.setattr(casezero, "events", lambda case_id: events)
    body = client.get("/v1/admin/casezero/case/CZ-LIVE0001/file").json()
    assert body["case_id"] == "CZ-LIVE0001" and body["source"] == "live" and body["members"]


def test_a_case_case_zero_no_longer_holds_is_a_404(client: TestClient, monkeypatch):
    def gone(case_id):
        raise casezero.CaseNotFound(case_id)
    monkeypatch.setattr(casezero, "case", gone)
    response = client.get("/v1/admin/casezero/case/CZ-GONE00001/file")
    assert response.status_code == 404 and "redeploy" in response.json()["detail"]


def test_the_recorded_case_file_route(client: TestClient, recorded, monkeypatch):
    _, events = recorded
    monkeypatch.setattr(casezero, "replay", lambda: events)
    body = client.get("/v1/admin/casezero/replay/file").json()
    assert body["source"] == "recorded" and body["case_id"] == events[0]["case_id"] and body["calls"]


def test_the_case_file_routes_need_a_token(anonymous: TestClient):
    assert anonymous.get("/v1/admin/casezero/replay/file").status_code == 401
    assert anonymous.get("/v1/admin/casezero/case/CZ-X/file").status_code == 401
