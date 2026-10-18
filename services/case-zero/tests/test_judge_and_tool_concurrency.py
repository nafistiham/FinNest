"""Bands, eval snapshots, trusted hops, one run per stream, concurrent tool calls and the eval judge."""

import argparse
import asyncio
import json
from types import SimpleNamespace

from test_orchestrator import good_draft

from case_zero.config import DEMO_AS_OF, DEMO_SEED, Settings


def _timed_rows(seconds):
    ok = dict(recovered=True, precision=1.0, recall=1.0, flagged=True, first_pass_ok=True, cost_usd=0.02, status="done")
    return [{"ring_id": f"r{i}", "tuning": False, "methods": {"case_zero": {**ok, "seconds": s}}} for i, s in enumerate(seconds)]


# 1. "confirmed" follows the critical band ---------------------------------------------------------
class _FixedScores:
    def __init__(self, scores: dict[str, float]) -> None:
        self.scores = scores

    def score_at(self, acct_id: str, as_of: str) -> dict:
        return {"probability": self.scores[acct_id]}


def _approved_payees(scores: dict[str, float]) -> dict[str, str]:
    from case_zero.export import decision, payee_risk
    report = SimpleNamespace(status="done", seed=DEMO_SEED, action="freeze", draft=good_draft(), as_of=DEMO_AS_OF)
    out = payee_risk({"CZ-0001": decision("CZ-0001", report)}, {"CZ-0001"}, _FixedScores(scores))
    return {p["acct_id"]: p["status"] for p in out["payees"]}


def test_confirmed_needs_the_critical_band():
    # 0.84 is the high band (hold, never auto-decline); 0.85 is critical
    assert _approved_payees({"acct_01070": 0.84, "acct_01870": 0.85}) == {"acct_01070": "suspected", "acct_01870": "confirmed"}


def test_confirmed_moves_with_the_bands(monkeypatch):
    import case_zero.policy as policy
    monkeypatch.setitem(policy.BAND_THRESHOLDS, "critical", 0.90)
    assert _approved_payees({"acct_01070": 0.89, "acct_01870": 0.90}) == {"acct_01070": "suspected", "acct_01870": "confirmed"}


# 3. The eval results record the settings they ran with ---------------------------------------------
def _baselines_args(**over) -> argparse.Namespace:
    base = dict(baselines_only=True, judge=False, limit=1, concurrency=1, rerun=set(), only=set(), skip_tuning=False, world_dir="")
    return argparse.Namespace(**{**base, **over})


def test_results_snapshot_the_settings(world, monkeypatch):
    import eval.run_eval as run_eval
    monkeypatch.setattr(run_eval.World, "load", classmethod(lambda cls, path: world))
    result = asyncio.run(run_eval.main(_baselines_args()))
    s = Settings()
    assert result["settings"]["max_tool_calls"] == s.max_tool_calls and result["settings"]["run_timeout_s"] == s.run_timeout_s
    assert result["settings"]["models_yaml"] == "services/risk-mw/config/models.yaml"   # relative: no local paths in committed results
    assert "/Users/" not in str(result["settings"])


def test_a_rerun_with_other_settings_keeps_both():
    from eval.run_eval import apply_rerun
    base = {"rows": _timed_rows([10.0]), "settings": {"max_tool_calls": 15}}
    fresh = {"rows": [], "settings": {"max_tool_calls": 12}}
    merged = apply_rerun(base, fresh, set(), "test")
    assert merged["settings"] == {"max_tool_calls": 15} and merged["rerun_settings"] == {"max_tool_calls": 12}


# 6. p95 is nearest-rank ----------------------------------------------------------------------------
def test_p95_is_nearest_rank():
    from eval.run_eval import summarise
    twenty = summarise(_timed_rows([float(i) for i in range(1, 21)]), "case_zero")
    assert twenty["seconds_p95"] == 19.0   # ceil(0.95 * 20) = 19th value, not the slowest case
    assert summarise(_timed_rows([float(i) for i in range(1, 28)]), "case_zero")["seconds_p95"] == 26.0   # n = 27: 26th
    assert summarise(_timed_rows([5.0]), "case_zero")["seconds_p95"] == 5.0


# 7. seed_brief is code's tc_00, not a tool the model can call ---------------------------------------
def test_seed_brief_is_not_a_tool_the_model_can_call(world):
    from case_zero.ledger import Ledger
    from case_zero.tools import KNOWN_TOOLS
    assert "seed_brief" not in KNOWN_TOOLS
    ledger = Ledger(world, DEMO_SEED, DEMO_AS_OF)
    assert ledger.prefetch_score()["ok"] is True and ledger.entries[0]["name"] == "seed_brief"
    out = ledger.call("seed_brief", acct_id=DEMO_SEED)
    assert out["ok"] is False and "unknown tool seed_brief" in out["error"]


# 4. Trusted X-Forwarded-For hops are configurable ---------------------------------------------------
def test_client_ip_counts_trusted_hops_from_the_right():
    from case_zero.app import client_ip
    xff = {"x-forwarded-for": "6.6.6.6, 203.0.113.9, 130.211.0.1"}   # forged, real client, a load balancer
    assert client_ip(xff, "169.254.1.1") == "130.211.0.1"                 # default: run.app appends one hop
    assert client_ip(xff, "169.254.1.1", trusted_hops=2) == "203.0.113.9"
    assert client_ip(xff, "10.0.0.1", trusted_hops=0) == "10.0.0.1"      # no proxy: the header is the caller's
    assert client_ip({"x-forwarded-for": "203.0.113.9"}, "10.0.0.1", trusted_hops=2) == "10.0.0.1"   # fewer hops than proxies: not trusted


def test_trusted_hops_come_from_the_environment(world, monkeypatch):
    from fastapi.testclient import TestClient
    from fake_llm import FakeLLM
    from test_orchestrator import NO_MIN
    from case_zero.app import create_app
    monkeypatch.setenv("CASE_ZERO_TRUSTED_HOPS", "2")
    c = TestClient(create_app(settings=NO_MIN, world=world, llm=FakeLLM([]), per_ip_limit=1))
    lb = "130.211.0.1"
    codes = [c.post("/api/investigate", json={"seed": "acct_99999"}, headers={"X-Forwarded-For": f"{ip}, {lb}"}).status_code
             for ip in ("203.0.113.1", "203.0.113.1", "203.0.113.2")]
    assert codes == [200, 429, 200]   # each caller behind the load balancer has its own limit


def test_deploy_script_documents_the_hop_assumption():
    from pathlib import Path
    deploy = (Path(__file__).resolve().parents[1] / "deploy.sh").read_text()
    assert "CASE_ZERO_TRUSTED_HOPS" in deploy and "X-Forwarded-For" in deploy


# 5 and 9. One _Run for both routes; a busy rejection does not use up the caller's quota --------------
def _ip(addr: str) -> dict:
    return {"X-Forwarded-For": addr}


async def _until_final(c, case_id: str) -> dict:
    for _ in range(200):
        status = (await c.get(f"/api/investigations/{case_id}")).json()
        if status["status"] in ("done", "failed"):
            return status
        await asyncio.sleep(0.01)
    raise AssertionError(f"{case_id} never finished")


def test_busy_rejections_do_not_use_the_per_ip_quota(world, monkeypatch):
    import httpx
    import case_zero.app as app_mod
    from fake_llm import FakeLLM
    from test_orchestrator import NO_MIN

    async def go():
        release = asyncio.Event()

        async def held(*a, **kw):
            await release.wait()
            raise RuntimeError("released")
        monkeypatch.setattr(app_mod, "run_investigation", held)
        app = app_mod.create_app(settings=NO_MIN, world=world, llm=FakeLLM([]), max_concurrent=1, per_ip_limit=2)
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
            first = (await c.post("/api/investigations", json={"seed": DEMO_SEED}, headers=_ip("203.0.113.1"))).json()
            busy = [await c.post("/api/investigations", json={"seed": DEMO_SEED}, headers=_ip("203.0.113.2")) for _ in range(3)]
            release.set()
            await _until_final(c, first["case_id"])
            after = await c.post("/api/investigations", json={"seed": DEMO_SEED}, headers=_ip("203.0.113.2"))
            return busy, after
    busy, after = asyncio.run(go())
    assert [r.status_code for r in busy] == [429, 429, 429] and all("busy" in r.json()["detail"] for r in busy)
    assert after.status_code == 202


def test_one_request_stream_is_the_same_run_the_poll_routes_serve(world):
    from fastapi.testclient import TestClient
    from fake_llm import FakeLLM, draft
    from test_app import events_of
    from test_orchestrator import NO_MIN, SCRIPT
    from case_zero.app import create_app
    c = TestClient(create_app(settings=NO_MIN, world=world, llm=FakeLLM(SCRIPT + [draft(good_draft())])))
    streamed = events_of(c.post("/api/investigate", json={"seed": DEMO_SEED}).text)
    case_id = streamed[0]["case_id"]
    status = c.get(f"/api/investigations/{case_id}").json()
    assert status["status"] == "done" and status["report"]["action"] == "freeze"
    assert status["events"] == streamed and streamed[-1] == {"type": "done", "case_id": case_id, "status": "done"}
    replay = c.get(f"/api/investigations/{case_id}/events").text
    assert events_of(replay) == streamed


async def _post_and_leave_after_first_event(app, body: dict) -> None:
    """Raw ASGI: read the first streamed event, then disconnect like a closed browser tab."""
    first = asyncio.Event()
    sent_body = False

    async def receive():
        nonlocal sent_body
        if not sent_body:
            sent_body = True
            return {"type": "http.request", "body": json.dumps(body).encode(), "more_body": False}
        await first.wait()
        return {"type": "http.disconnect"}

    async def send(message):
        if message["type"] == "http.response.body" and b"event: " in message.get("body", b""):
            first.set()

    scope = {"type": "http", "asgi": {"version": "3.0"}, "http_version": "1.1", "method": "POST", "scheme": "http", "path": "/api/investigate",
             "raw_path": b"/api/investigate", "query_string": b"", "root_path": "", "headers": [(b"content-type", b"application/json"), (b"host", b"t")],
             "client": ("203.0.113.5", 1234), "server": ("t", 80)}
    await app(scope, receive, send)


# Leaving the stream used to cancel the run; that was reversed, because a Gemini call already sent
# may still be billed. test_spend_and_durability checks that the case now finishes, is stored and frees its slot.


# 2. A turn's tool calls run at once, numbered in the model's order -----------------------------------
def _turn_with(*calls):
    from case_zero.llm import FunctionCall, LLMTurn
    fcs = tuple(FunctionCall(id=f"fc_{i}", name=name, args=args) for i, (name, args) in enumerate(calls))
    return LLMTurn(text="", function_calls=fcs, parsed=None, tokens_in=100, tokens_out=20, model_id="fake-model", latency_ms=5.0)


PARALLEL_TURN = (("velocity_stats", {"acct_id": DEMO_SEED}), ("neighbours", {"acct_id": DEMO_SEED, "hops": 1}), ("kyc_dupe_check", {"acct_id": DEMO_SEED}))


def _slow_tools(monkeypatch, delays: dict[str, float]):
    import threading
    import time as time_mod
    import case_zero.ledger as ledger_mod
    real, lock, state = ledger_mod.run_tool, threading.Lock(), {"now": 0, "max": 0}

    def slow(world, name, as_of, args):
        with lock:
            state["now"] += 1
            state["max"] = max(state["max"], state["now"])
        time_mod.sleep(delays.get(name, 0.0))
        with lock:
            state["now"] -= 1
        return real(world, name, as_of, args)
    monkeypatch.setattr(ledger_mod, "run_tool", slow)
    return state


def test_a_turns_tool_calls_run_concurrently(world, monkeypatch):
    from fake_llm import done, draft
    from test_orchestrator import run
    state = _slow_tools(monkeypatch, {name: 0.2 for name, _ in PARALLEL_TURN})
    report, _ = run(world, [_turn_with(*PARALLEL_TURN), done("Ring found."), draft(good_draft())])
    assert report.tool_calls == 3 and state["max"] == 3


def test_concurrent_calls_keep_the_models_order(world, monkeypatch):
    from fake_llm import FakeLLM, done, draft
    from test_orchestrator import NO_MIN
    from case_zero.orchestrator import run_investigation
    _slow_tools(monkeypatch, {"velocity_stats": 0.3, "neighbours": 0.1, "kyc_dupe_check": 0.0})   # the first finishes last
    llm = FakeLLM([_turn_with(*PARALLEL_TURN), done("Ring found."), draft(good_draft())])
    events = []

    async def emit(e):
        events.append(e)
    report = asyncio.run(run_investigation(world, llm, DEMO_SEED, DEMO_AS_OF, emit, "CZ-0001", settings=NO_MIN))
    names = [name for name, _ in PARALLEL_TURN]
    ledger = report._ledger
    assert [(e["call_id"], e["name"]) for e in ledger.entries[1:]] == [("tc_01", names[0]), ("tc_02", names[1]), ("tc_03", names[2])]
    calls = [e for e in events if e["type"] == "tool_call"]
    results = [e for e in events if e["type"] == "tool_result"]
    assert [(e["call_id"], e["name"]) for e in calls] == [(e["call_id"], e["name"]) for e in results] == [("tc_01", names[0]), ("tc_02", names[1]), ("tc_03", names[2])]
    assert [e["args"] for e in results] == [args for _, args in PARALLEL_TURN]   # the console labels each result with its own args
    replies = llm.calls[1]["contents"][-1].parts
    assert [(p.function_response.id, p.function_response.name, p.function_response.response["call_id"]) for p in replies] == [("fc_0", names[0], "tc_01"), ("fc_1", names[1], "tc_02"), ("fc_2", names[2], "tc_03")]


def test_calls_past_the_budget_in_one_turn_are_refused_in_order(world):
    import dataclasses
    from fake_llm import done, draft
    from test_orchestrator import NO_MIN, run
    report, events = run(world, [_turn_with(*PARALLEL_TURN), done(), draft(good_draft())], settings=dataclasses.replace(NO_MIN, max_tool_calls=2))
    results = [e for e in events if e["type"] == "tool_result"]
    assert [e["call_id"] for e in results] == ["tc_01", "tc_02", None] and results[2]["error"] == "tool budget exhausted"
    assert report.tool_calls == 2


def test_console_labels_each_result_with_its_own_args():
    from pathlib import Path
    html = (Path(__file__).resolve().parents[1] / "static" / "index.html").read_text()
    assert "e.args ?? lastArgs" in html   # results of one turn arrive after all its calls; old replays have no args


# 8. The judge is a different model from the agent (review: a Gemini judge, opt-out of the open-model path) --
JUDGE_ROLE = "reasoning"
JUDGE_JSON = {"evidence": 5, "consistency": 4, "clarity": 4, "actionability": 3, "en_bn_consistency": 4,
              "mismatches": [], "unsupported_claims": [], "rationale": "Grounded."}


def test_the_default_judge_is_another_gemini_model():
    from case_zero.llm import load_role
    from eval.run_eval import parse_args
    yaml_path = Settings().models_yaml
    agent, judge = load_role(yaml_path, Settings().model_role), load_role(yaml_path, parse_args(["--judge"]).judge_role)
    assert judge.name == "reasoning" and judge.id.startswith("gemini-") and judge.id != agent.id


def test_models_yaml_has_no_open_model_judge():
    import yaml
    roles = yaml.safe_load(Settings().models_yaml.read_text())["roles"]
    assert "judge_cross_family" not in roles and not any("provider" in spec for spec in roles.values())


def test_model_family():
    from case_zero.llm import model_family
    assert model_family("gemini-3.8-flash") == model_family("gemini-3.1-pro-preview") == "gemini"


def test_eval_builds_the_judge_from_its_role(world, monkeypatch):
    import eval.run_eval as run_eval
    from fake_llm import ROLE
    from case_zero.llm import load_role
    built = []
    budget = SimpleNamespace(cap_usd=1.0, spent=lambda: 0.0)

    def from_env(cls, yaml_path, role="workhorse", thinking_level="low"):
        built.append(role)
        return SimpleNamespace(role=ROLE if role == "workhorse" else load_role(yaml_path, role), budget=budget)
    monkeypatch.setattr(run_eval.World, "load", classmethod(lambda cls, path: world))
    monkeypatch.setattr(run_eval.GeminiLLM, "from_env", classmethod(from_env))
    args = _baselines_args(baselines_only=False, judge=True, only={"no-such-ring"}, judge_role=JUDGE_ROLE)
    result = asyncio.run(run_eval.main(args))
    assert built == ["workhorse", JUDGE_ROLE] and result["judge_model"] == load_role(Settings().models_yaml, JUDGE_ROLE).id


def _judged_result(judge_model: str) -> dict:
    from eval.run_eval import summarise
    rows = _timed_rows([10.0, 20.0])
    for r in rows:
        r["methods"]["case_zero"]["judge"] = {**JUDGE_JSON}
    return {"prompt_sha": "p", "model": "gemini-3.8-flash", "judge_model": judge_model, "judge_sha": "j", "note": "n.",
            "summary": {"case_zero": {**summarise(rows, "case_zero"), "skipped_budget": 0, "skipped_tuning": 0}}}


def test_markdown_says_how_the_judge_relates_to_the_agent():
    from eval.run_eval import to_markdown
    assert "the same model as the agent, so self-preference bias is possible" in to_markdown(_judged_result("gemini-3.8-flash"))
    pro = to_markdown(_judged_result("gemini-3.1-pro-preview"))
    assert "a different model from the agent (gemini-3.8-flash), though both are gemini, so some self-preference bias is still possible" in pro
    assert "different model family" in to_markdown(_judged_result("claude-x"))


def test_device_safety_runs_alongside_the_turns_other_calls(world, monkeypatch):
    """Merge check (the device_safety tool on main): a slow risk-mw answer overlaps the turn's other calls and keeps its tc_NN."""
    import io
    import time as time_mod
    from fake_llm import done, draft
    from test_orchestrator import run
    import case_zero.ledger as ledger_mod
    from case_zero import tools
    spans: dict[str, tuple[float, float]] = {}

    class _Resp(io.BytesIO):
        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

    def slow_urlopen(req, timeout):
        started = time_mod.perf_counter()
        time_mod.sleep(0.2)
        spans["device_safety"] = (started, time_mod.perf_counter())
        return _Resp(json.dumps({"known": True, "verdict": "BLOCK", "risk_score": 0.9, "flagged_packages": [], "attestation": "none"}).encode())
    real = ledger_mod.run_tool

    def timed(world_, name, as_of, args):
        if name != "velocity_stats":
            return real(world_, name, as_of, args)
        started = time_mod.perf_counter()
        time_mod.sleep(0.2)
        out = real(world_, name, as_of, args)
        spans[name] = (started, time_mod.perf_counter())
        return out
    monkeypatch.setattr(tools, "RISK_MW_URL", "https://risk-mw.example")
    monkeypatch.setattr(tools.urllib.request, "urlopen", slow_urlopen)
    monkeypatch.setattr(ledger_mod, "run_tool", timed)
    turn = _turn_with(("device_safety", {"acct_id": DEMO_SEED}), ("velocity_stats", {"acct_id": DEMO_SEED}))
    report, events = run(world, [turn, done("Ring found."), draft(good_draft())])
    assert [(e["call_id"], e["name"]) for e in events if e["type"] == "tool_result"] == [("tc_01", "device_safety"), ("tc_02", "velocity_stats")]
    (a0, a1), (b0, b1) = spans["device_safety"], spans["velocity_stats"]
    assert a0 < b1 and b0 < a1   # the two calls overlapped
    assert report._ledger.entry("tc_01")["data"]["verdict"] == "BLOCK"
