"""Per-IP rate limits behind Cloud Run, non-blocking tools, backend choice and start-up checks."""

import asyncio
import os
import time

import pytest
from fastapi.testclient import TestClient
from fake_llm import FakeLLM, draft
from test_orchestrator import NO_MIN, SCRIPT, good_draft, run

from case_zero.app import create_app, client_ip

UNKNOWN = {"seed": "acct_99999"}


def _client(world, script=(), **kw):
    return TestClient(create_app(settings=NO_MIN, world=world, llm=FakeLLM(list(script)), **kw))


# 1. Rate limit on Cloud Run ------------------------------------------------------------------------
def test_client_ip_uses_the_hop_cloud_run_appends():
    assert client_ip({"x-forwarded-for": "203.0.113.9"}, "169.254.1.1") == "203.0.113.9"
    assert client_ip({"x-forwarded-for": "6.6.6.6, 203.0.113.9"}, "169.254.1.1") == "203.0.113.9"  # a caller-set first hop is ignored
    assert client_ip({}, "10.0.0.1") == "10.0.0.1"


def test_per_ip_limit_separates_real_callers_behind_the_proxy(world):
    c = _client(world, per_ip_limit=2)
    a = {"X-Forwarded-For": "203.0.113.1"}
    b = {"X-Forwarded-For": "203.0.113.2"}
    codes = [c.post("/api/investigate", json=UNKNOWN, headers=h).status_code for h in (a, a, a, b)]
    assert codes == [200, 200, 429, 200]


def test_a_spoofed_first_hop_does_not_bypass_the_limit(world):
    c = _client(world, per_ip_limit=1)
    assert c.post("/api/investigate", json=UNKNOWN, headers={"X-Forwarded-For": "1.1.1.1, 203.0.113.7"}).status_code == 200
    assert c.post("/api/investigate", json=UNKNOWN, headers={"X-Forwarded-For": "2.2.2.2, 203.0.113.7"}).status_code == 429


def test_idle_callers_are_pruned(world):
    import case_zero.app as app_mod
    clock = [1000.0]
    app = create_app(settings=NO_MIN, world=world, llm=FakeLLM([]), per_ip_limit=5, clock=lambda: clock[0])
    c = TestClient(app)
    for i in range(20):
        c.post("/api/investigate", json=UNKNOWN, headers={"X-Forwarded-For": f"203.0.113.{i}"})
    clock[0] += app_mod.PER_IP_WINDOW_S + 1
    c.post("/api/investigate", json=UNKNOWN, headers={"X-Forwarded-For": "198.51.100.1"})
    assert app.state.rate_keys() == 1


# 2. Tool work off the event loop -------------------------------------------------------------------
def test_slow_tools_do_not_block_the_event_loop(world, monkeypatch):
    import case_zero.ledger as ledger_mod
    real = ledger_mod.run_tool

    def slow(*a, **kw):
        time.sleep(0.3)
        return real(*a, **kw)

    monkeypatch.setattr(ledger_mod, "run_tool", slow)

    async def go():
        ticks = 0
        done = asyncio.Event()

        async def ticker():
            nonlocal ticks
            while not done.is_set():
                ticks += 1
                await asyncio.sleep(0.01)

        t = asyncio.create_task(ticker())
        from case_zero.orchestrator import run_investigation
        from case_zero.config import DEMO_AS_OF, DEMO_SEED

        async def emit(_):
            return None
        await run_investigation(world, FakeLLM(SCRIPT + [draft(good_draft())]), DEMO_SEED, DEMO_AS_OF, emit, "CZ-T", settings=NO_MIN)
        done.set()
        await t
        return ticks

    assert asyncio.run(go()) >= 40  # two slow tools = 0.6 s blocked; the ticker must keep running through them


# 3. Vertex preferred over a stray key --------------------------------------------------------------
def test_vertex_wins_when_a_project_is_set():
    from case_zero.llm import select_backend
    assert select_backend({"GOOGLE_API_KEY": "k", "CASE_ZERO_PROJECT_ID": "p"}) == ("vertex", "p")
    assert select_backend({"CASE_ZERO_BACKEND": "api_key", "GOOGLE_API_KEY": "k", "CASE_ZERO_PROJECT_ID": "p"}) == ("api_key", "k")
    assert select_backend({"GOOGLE_API_KEY": "k"}) == ("api_key", "k")


# Quick ones ----------------------------------------------------------------------------------------
def test_keyerror_inside_a_real_tool_is_not_called_unknown(world, monkeypatch):
    import case_zero.ledger as ledger_mod
    from case_zero.config import DEMO_AS_OF, DEMO_SEED
    from case_zero.ledger import Ledger

    def broken(*a, **kw):
        raise KeyError("missing_field")

    monkeypatch.setattr(ledger_mod, "run_tool", broken)
    out = Ledger(world, DEMO_SEED, DEMO_AS_OF).call("velocity_stats", acct_id=DEMO_SEED)
    assert out["ok"] is False and "unknown tool" not in out["error"] and "missing_field" in out["error"]
    monkeypatch.undo()
    assert "unknown tool" in Ledger(world, DEMO_SEED, DEMO_AS_OF).call("no_such_tool")["error"]


def test_unknown_seed_case_can_be_fetched_after_done(world):
    from test_app import events_of
    c = _client(world)
    case_id = events_of(c.post("/api/investigate", json=UNKNOWN).text)[-1]["case_id"]
    assert c.get(f"/api/cases/{case_id}").status_code == 200
    assert c.get(f"/api/cases/{case_id}/contract").json()["acct_id"] == "acct_99999"


def test_test_tools_are_not_in_the_production_requirements():
    from pathlib import Path
    here = Path(__file__).resolve().parent.parent
    prod = (here / "requirements.txt").read_text()
    dev = (here / "requirements-dev.txt").read_text()
    assert "pytest" not in prod and "faker" not in prod
    assert "-r requirements.txt" in dev and "pytest" in dev and "faker" in dev


def test_gemini_client_is_built_at_startup_not_import(world, monkeypatch):
    import case_zero.app as app_mod
    built = []
    monkeypatch.setattr(app_mod, "_llm_from_env", lambda settings: built.append(1) or FakeLLM([]))
    app = app_mod.create_app(settings=NO_MIN, world=world)
    assert built == []

    async def start():
        async with app.router.lifespan_context(app):
            return app.state.llm
    assert asyncio.run(start()) is not None and built == [1]
