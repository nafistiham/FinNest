import json
import re

import pytest
from fake_llm import FakeLLM, call, done, draft
from fastapi.testclient import TestClient
from test_orchestrator import NO_MIN, good_draft

from case_zero.app import create_app
from case_zero.config import DEMO_SEED

SCRIPT = [call("path_between", source="acct_rina", target=DEMO_SEED), call("neighbours", acct_id=DEMO_SEED, hops=1), done("Ring found.")]


def events_of(text: str) -> list[dict]:
    return [json.loads(line[6:]) for line in text.splitlines() if line.startswith("data: ")]


@pytest.fixture()
def client(world):
    return TestClient(create_app(settings=NO_MIN, world=world, llm=FakeLLM(SCRIPT + [draft(good_draft())]), admin_token="t"))


def test_health(client):
    body = client.get("/health").json()
    assert body["ok"] is True and body["llm_ready"] is True


def test_seeds_have_no_labels(client):
    seeds = client.get("/api/seeds").json()
    assert seeds[0]["seed"] == DEMO_SEED
    assert "ring_id" not in json.dumps(seeds) and "role" not in json.dumps(seeds)


def test_investigate_streams_events_and_stores_case(client):
    resp = client.post("/api/investigate", json={"seed": DEMO_SEED})
    assert resp.status_code == 200 and resp.headers["content-type"].startswith("text/event-stream")
    events = events_of(resp.text)
    assert events[0]["type"] == "run_started" and events[-1]["type"] == "done"
    case_id = events[0]["case_id"]
    assert re.fullmatch(r"CZ-[A-Z2-7]{10}", case_id)
    assert client.get(f"/api/cases/{case_id}").json()["action"] == "freeze"
    contract = client.get(f"/api/cases/{case_id}/contract").json()
    assert contract["acct_id"] == DEMO_SEED and "acct_01070" in contract["ring"]


def test_unknown_case_404(client):
    assert client.get("/api/cases/CZ-9999").status_code == 404


def test_investigate_without_llm_is_503(world, monkeypatch):
    for var in ("GOOGLE_API_KEY", "GEMINI_API_KEY", "CASE_ZERO_PROJECT_ID", "GOOGLE_CLOUD_PROJECT"):
        monkeypatch.delenv(var, raising=False)
    c = TestClient(create_app(settings=NO_MIN, world=world, llm=None))
    assert c.get("/health").json()["llm_ready"] is False
    assert c.post("/api/investigate", json={"seed": DEMO_SEED}).status_code == 503


def test_payee_risk_after_case_and_approval(client):
    case_id = events_of(client.post("/api/investigate", json={"seed": DEMO_SEED}).text)[0]["case_id"]
    payees = {p["acct_id"]: p for p in client.get("/api/payee-risk").json()["payees"]}
    assert set(payees) == {"acct_01070", "acct_01870"}
    assert all(p["status"] == "suspected" and p["case_id"] == case_id for p in payees.values())
    assert client.post(f"/api/cases/{case_id}/approve", headers={"X-Admin-Token": "t"}).status_code == 200
    payees = {p["acct_id"]: p for p in client.get("/api/payee-risk").json()["payees"]}
    assert payees["acct_01070"]["status"] == "confirmed"   # own score in the critical band at the case time
    assert payees["acct_01870"]["status"] == "suspected"   # low score: hold, never auto-decline


def test_console_is_served(client):
    html = client.get("/").text
    assert "Case Zero" in html and "cytoscape" in html
