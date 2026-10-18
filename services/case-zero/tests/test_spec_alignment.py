"""Alignment with the Case Zero spec diagrams: bands, wall clock, below-floor note, Bangla dates, tokens, events and polling."""

import asyncio
import dataclasses
import re
import time
from pathlib import Path

import httpx
from fake_llm import FakeLLM, draft
from test_orchestrator import NO_MIN, SCRIPT, good_draft, run

from case_zero.app import create_app
from case_zero.config import DEMO_AS_OF, DEMO_SEED, Settings
from case_zero.ledger import Ledger
from case_zero.policy import BAND_THRESHOLDS, band_for, floor_action
from case_zero.validator import validate

RISK_MW_SETTINGS = Path(__file__).resolve().parents[2] / "risk-mw" / "app" / "settings.py"


# Diagram 6: floors come from the platform's bands -------------------------------------------------
def test_band_thresholds_are_risk_mws():
    src = RISK_MW_SETTINGS.read_text()
    theirs = {name: float(re.search(rf"band_{name}: float = ([0-9.]+)", src)[1]) for name in ("critical", "high", "medium")}
    assert BAND_THRESHOLDS == theirs


def test_band_maps_to_the_floor():
    assert [band_for(p) for p in (0.9, 0.7, 0.4, 0.1)] == ["critical", "high", "medium", "low"]
    assert [floor_action(p) for p in (0.9, 0.7, 0.4, 0.1)] == ["freeze", "edd", "monitor", "close_no_action"]


def test_score_output_and_report_carry_the_band(world):
    assert Ledger(world, DEMO_SEED, DEMO_AS_OF).prefetch_score()["data"]["band"] == "critical"  # 0.87
    report, _ = run(world, SCRIPT + [draft(good_draft())])
    assert report.band == "critical"


# Diagram 2: 90 s wall clock, then failed ----------------------------------------------------------
def test_default_wall_clock_is_90_seconds_with_room_for_the_writer():
    s = Settings()
    assert s.run_timeout_s == 90.0
    assert s.run_timeout_s - s.investigator_timeout_s >= 30.0


def test_a_case_that_runs_out_of_time_ends_failed_on_time(world):
    from case_zero.orchestrator import run_investigation
    tight = dataclasses.replace(NO_MIN, run_timeout_s=1.0, investigator_timeout_s=0.6, llm_turn_timeout_s=0.6, writer_timeout_s=0.5)

    async def emit(_):
        return None
    started = time.monotonic()
    report = asyncio.run(run_investigation(world, FakeLLM([], delay_s=5.0), DEMO_SEED, DEMO_AS_OF, emit, "CZ-T", settings=tight))
    assert time.monotonic() - started < tight.run_timeout_s + 0.5
    assert report.status == "failed"


# Diagram 6: a below-floor proposal is noted for a human -------------------------------------------
def test_below_floor_proposal_is_noted_for_review(world):
    report, _ = run(world, SCRIPT + [draft(good_draft(proposed_action="close_no_action"))])
    assert report.action == "freeze"
    assert "close_no_action" in report.review_note and "freeze" in report.review_note


def test_no_review_note_when_the_proposal_is_at_the_floor(world):
    report, _ = run(world, SCRIPT + [draft(good_draft())])
    assert report.review_note is None


# Diagram 8: Bangla dates as YYYY-MM-DD, and dates must come from the tools ---------------------------
def _ledger(world):
    led = Ledger(world, DEMO_SEED, DEMO_AS_OF)
    led.prefetch_score()
    led.call("path_between", source="acct_rina", target=DEMO_SEED)
    led.call("neighbours", acct_id=DEMO_SEED, hops=1)
    return led


def _codes(d, led):
    return {(v.code, v.field) for v in validate(d, led)}


def test_bangla_dates_in_yyyy_mm_dd_pass(world):
    led = _ledger(world)
    d = good_draft(narrative_en=good_draft().narrative_en + " On 2026-11-10.", narrative_bn=good_draft().narrative_bn + " ২০২৬-১১-১০ তারিখে।")
    assert not {c for c in _codes(d, led) if c[0] in ("date_format", "unknown_date")}


def test_bangla_month_name_dates_are_rejected(world):
    led = _ledger(world)
    for bad in ("১০ নভেম্বর", "নভেম্বর ১০", "10/11/2026", "১০-১১-২০২৬"):
        d = good_draft(narrative_bn=good_draft().narrative_bn + f" {bad} তারিখে।")
        assert ("date_format", "narrative_bn") in _codes(d, led), bad


def test_a_date_no_tool_returned_is_rejected(world):
    led = _ledger(world)
    d = good_draft(narrative_en=good_draft().narrative_en + " On 2026-10-01.", narrative_bn=good_draft().narrative_bn + " ২০২৬-১০-০১ তারিখে।")
    assert ("unknown_date", "narrative_bn") in _codes(d, led) and ("unknown_date", "narrative_en") in _codes(d, led)


def test_writer_is_told_to_use_yyyy_mm_dd():
    from case_zero import prompts
    assert "YYYY-MM-DD" in prompts.WRITER_SYSTEM


# FR-7: tokens and model per case in the eval -----------------------------------------------------
def test_eval_records_tokens_and_model_per_case(world):
    from eval.run_eval import agent_pred, summarise
    seed = {"seed": DEMO_SEED, "as_of": DEMO_AS_OF}
    _, info = asyncio.run(agent_pred(world, FakeLLM(SCRIPT + [draft(good_draft())]), seed, 0))
    assert info["tokens_in"] > 0 and info["tokens_out"] > 0 and info["model"] == "fake-model"
    ok = dict(recovered=True, precision=1.0, recall=1.0, flagged=True, first_pass_ok=True, seconds=10.0, cost_usd=0.02, status="done", tokens_in=1000, tokens_out=200)
    rows = [{"ring_id": "r1", "tuning": False, "methods": {"case_zero": ok}}, {"ring_id": "r2", "tuning": False, "methods": {"case_zero": ok}}]
    s = summarise(rows, "case_zero")
    assert s["tokens_in_total"] == 2000 and s["tokens_out_total"] == 400


# Diagrams 4 and 5: GET events (EventSource) with a polling fallback ---------------------------------
def _app(world, script):
    return create_app(settings=NO_MIN, world=world, llm=FakeLLM(script))


async def _start_stream_poll(app, body):
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
        started = await c.post("/api/investigations", json=body)
        info = started.json()
        stream = (await c.get(info["stream_url"])).text
        status = (await c.get(info["status_url"])).json()
        partial = (await c.get(info["status_url"], params={"since": 2})).json()
        resumed = (await c.get(info["stream_url"], headers={"Last-Event-ID": "0"})).text
        return started, info, stream, status, partial, resumed


def test_start_then_stream_then_poll(world):
    started, info, stream, status, partial, resumed = asyncio.run(_start_stream_poll(_app(world, SCRIPT + [draft(good_draft())]), {"acct_id": DEMO_SEED}))
    assert started.status_code == 202 and info["status"] in ("queued", "running")
    assert info["stream_url"] == f"/api/investigations/{info['case_id']}/events" and info["status_url"] == f"/api/investigations/{info['case_id']}"
    assert "id: 0\nevent: run_started" in stream and "event: tool_result" in stream and stream.rstrip().endswith('"done", "case_id": "%s", "status": "done"}' % info["case_id"])
    assert status["status"] == "done" and status["report"]["action"] == "freeze" and status["next"] == len(status["events"])
    assert partial["events"] == status["events"][2:]
    assert "id: 0\n" not in resumed and "id: 1\n" in resumed  # EventSource reconnect resumes after Last-Event-ID


def test_unknown_investigation_is_404(world):
    async def go():
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=_app(world, [])), base_url="http://t") as c:
            return (await c.get("/api/investigations/CZ-9999")).status_code, (await c.get("/api/investigations/CZ-9999/events")).status_code
    assert asyncio.run(go()) == (404, 404)


def test_investigation_status_is_failed_when_the_run_crashes(world, monkeypatch):
    import case_zero.app as app_mod

    async def boom(*a, **kw):
        raise RuntimeError("graph unavailable")
    monkeypatch.setattr(app_mod, "run_investigation", boom)
    _, info, stream, status, _, _ = asyncio.run(_start_stream_poll(_app(world, []), {"seed": DEMO_SEED}))
    assert status["status"] == "failed" and "event: error" in stream


# Diagram 4: console uses EventSource, falls back to 1 s polling, and visited nodes glow -------------
def test_console_streams_with_eventsource_polls_on_failure_and_glows():
    html = (Path(__file__).resolve().parents[1] / "static" / "index.html").read_text()
    assert "new EventSource(" in html and "/api/investigations" in html
    assert "status_url" in html and "1000" in html  # poll every second
    assert "node.visited" in html and "node.active" in html
