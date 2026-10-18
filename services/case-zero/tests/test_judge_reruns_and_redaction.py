"""Judge reruns, failure isolation, holds released on bad replies, redacted contracts and trusted-hop defaults."""

import argparse
import asyncio
from types import SimpleNamespace

import pytest
from fake_llm import ROLE, FakeLLM, done, draft
from google.genai import types
from test_orchestrator import SCRIPT, good_draft, run

from case_zero.budget import SpendLedger
from case_zero.config import DEMO_AS_OF, DEMO_SEED
from case_zero.llm import GeminiLLM, ModelRole

GEMINI = ModelRole(name="workhorse", id="gemini-3.8-flash", input_usd_per_m=0.75, output_usd_per_m=3.75)
SCORES = {"evidence": 5, "consistency": 4, "clarity": 4, "actionability": 4, "en_bn_consistency": 4, "mismatches": [], "unsupported_claims": [], "rationale": "ok"}


def _client(generate):
    return SimpleNamespace(aio=SimpleNamespace(models=SimpleNamespace(generate_content=generate)))


def _args(**over) -> argparse.Namespace:
    base = dict(baselines_only=False, judge=False, limit=1, concurrency=2, rerun=set(), only=set(), skip_tuning=False, world_dir="", judge_role="reasoning")
    return argparse.Namespace(**{**base, **over})


def _row(key: str, judge_model: str | None) -> dict:
    m = dict(recovered=True, precision=1.0, recall=1.0, flagged=True, first_pass_ok=True, seconds=10.0, cost_usd=0.02, status="done", action="freeze")
    if judge_model:
        m["judge"] = {**SCORES, "judge_model": judge_model}
    return {"ring_id": key, "seed": f"acct_{key}", "tuning": False, "methods": {"case_zero": m, "case_zero_ungated": dict(recovered=True, precision=1.0, recall=1.0, flagged=True)}}


# 1. The judge is recorded per row, and judges are never mixed ----------------------------------------
def test_every_judged_row_names_its_judge_even_on_error(world):
    from eval.run_eval import agent_pred
    _, info = asyncio.run(agent_pred(world, FakeLLM(SCRIPT + [draft(good_draft())]), {"seed": DEMO_SEED, "as_of": DEMO_AS_OF}, 0, judge_llm=FakeLLM([done("not json")])))
    assert "judge_error" in info["judge"] and info["judge"]["judge_model"] == ROLE.id


def test_a_rerun_judged_by_another_model_is_refused():
    from eval.run_eval import apply_rerun
    base = {"rows": [_row("r1", "gemini-3.8-flash"), _row("r2", "gemini-3.8-flash")], "judge_model": "gemini-3.8-flash", "note": ""}
    fresh = {"rows": [_row("r2", "gemini-3.1-pro-preview")], "judge_model": "gemini-3.1-pro-preview"}
    with pytest.raises(ValueError, match="gemini-3.8-flash.*gemini-3.1-pro-preview|gemini-3.1-pro-preview.*gemini-3.8-flash"):
        apply_rerun(base, fresh, {"r2"}, "test")


def test_a_rerun_with_the_same_judge_merges():
    from eval.run_eval import apply_rerun
    base = {"rows": [_row("r1", "gemini-3.8-flash"), _row("r2", "gemini-3.8-flash")], "judge_model": "gemini-3.8-flash", "note": ""}
    merged = apply_rerun(base, {"rows": [_row("r2", "gemini-3.8-flash")], "judge_model": "gemini-3.8-flash"}, {"r2"}, "test")
    assert merged["rows"][1]["methods"]["case_zero"]["rerun"] is True and merged["summary"]["case_zero"]["judge_models"] == ["gemini-3.8-flash"]


def test_mixed_judges_fail_g5():
    from eval.run_eval import gates, summarise
    s = summarise([_row("r1", "gemini-3.8-flash"), _row("r2", "gemini-3.1-pro-preview")], "case_zero")
    assert s["judge_models"] == ["gemini-3.1-pro-preview", "gemini-3.8-flash"] and gates(s)["G5_judge"] is False
    assert gates(summarise([_row("r1", "gemini-3.8-flash")], "case_zero"))["G5_judge"] is True


# 2. A judge failure never fails the eval, and one case's error does not lose the run ------------------
def test_judge_case_never_raises(world):
    from eval.judge import judge_case
    report, _ = run(world, SCRIPT + [draft(good_draft())])

    class Broken:
        role = GEMINI

        async def chat(self, *a, **kw):
            raise RuntimeError("could not load default credentials")
    out = asyncio.run(judge_case(Broken(), report, timeout_s=5))
    assert out["judge_error"].startswith("RuntimeError") and out["judge_model"] == GEMINI.id


def test_one_failing_case_is_recorded_and_the_rest_still_run(world, monkeypatch):
    import eval.run_eval as run_eval
    from eval.seeds import ring_seeds
    rings = [s["ring_id"] for s in ring_seeds(world)][:3]
    budget = SimpleNamespace(cap_usd=5.0, spent=lambda: 0.0)
    monkeypatch.setattr(run_eval.World, "load", classmethod(lambda cls, path: world))
    monkeypatch.setattr(run_eval.GeminiLLM, "from_env", classmethod(lambda cls, *a, **kw: SimpleNamespace(role=ROLE, budget=budget)))

    async def agent_pred(world_, llm, seed, i, judge_llm=None, settings=None):
        if seed["ring_id"] == rings[1]:
            raise RuntimeError("boom")
        return set(), {"action": "close_no_action", "status": "done", "first_pass_ok": True, "seconds": 1.0, "cost_usd": 0.01, "proposed": [], "tokens_in": 0, "tokens_out": 0}
    monkeypatch.setattr(run_eval, "agent_pred", agent_pred)
    result = asyncio.run(run_eval.main(_args(only=set(rings), limit=3)))
    by_ring = {r["ring_id"]: r["methods"].get("case_zero", {}) for r in result["rows"] if r["ring_id"] in rings}
    assert by_ring[rings[1]] == {"skipped": "error", "error": "RuntimeError: boom"}
    assert by_ring[rings[0]]["status"] == "done" and by_ring[rings[2]]["status"] == "done"
    assert result["summary"]["case_zero"]["skipped_error"] == 1


# 3. Every path releases the spend hold ---------------------------------------------------------------
def test_a_bad_json_reply_releases_the_hold(tmp_path):
    from pydantic import ValidationError
    from case_zero.schemas import CaseDraft
    ok = types.GenerateContentResponse(candidates=[types.Candidate(content=types.Content(role="model", parts=[types.Part(text="not json")]))],
                                       usage_metadata=types.GenerateContentResponseUsageMetadata(prompt_token_count=100, candidates_token_count=10))

    async def generate(model, contents, config):
        return ok
    budget = SpendLedger(tmp_path / "spend.json", cap_usd=1.0)
    with pytest.raises(ValidationError):
        asyncio.run(GeminiLLM(_client(generate), GEMINI, budget=budget).chat("s", [], None, CaseDraft, 5))
    assert budget.held() == 0 and budget.spent() > 0


def test_a_malformed_reply_releases_the_hold(tmp_path):
    async def generate(model, contents, config):
        return SimpleNamespace(candidates=None)   # no usage_metadata at all
    budget = SpendLedger(tmp_path / "spend.json", cap_usd=1.0)
    with pytest.raises(AttributeError):
        asyncio.run(GeminiLLM(_client(generate), GEMINI, budget=budget).chat("s", [], None, None, 5))
    assert budget.held() == 0 and budget.spent() > 0   # billed as its worst case: we cannot tell what it cost


# 5. A redacted case is told apart in the contract ----------------------------------------------------
def _contracts():
    from test_writer_spend_and_contract import _contract_module
    return _contract_module()


def test_contract_flags_a_redacted_case(world):
    from case_zero.schemas import to_contract
    from test_writer_spend_and_contract import _report_with_flags
    flags = [{"code": "RF02", "text": "money moved on", "evidence": ["tc_01"]}]
    redacted, ledger = _report_with_flags(world, flags, status="failed_after_retry")
    clean, _ = _report_with_flags(world, flags, status="done")
    a, b = to_contract(redacted, ledger), to_contract(clean, ledger)
    assert (a["status"], a["redacted"]) == ("degraded", True) and (b["status"], b.get("redacted", False)) == ("done", False)   # Never done and redacted
    assert _contracts().CaseReport(**a).redacted is True


def test_redacted_is_optional_in_risk_mws_contract(world):
    from case_zero.schemas import to_contract
    from test_writer_spend_and_contract import _report_with_flags
    report, ledger = _report_with_flags(world, [{"code": "RF02", "text": "money moved on", "evidence": ["tc_01"]}])
    older = {k: v for k, v in to_contract(report, ledger).items() if k != "redacted"}   # what an older producer sends
    assert _contracts().CaseReport(**older).redacted is False


# 6. An empty CASE_ZERO_TRUSTED_HOPS means the default ---------------------------------------------------
def test_empty_trusted_hops_is_the_default(world, monkeypatch):
    from fastapi.testclient import TestClient
    from test_orchestrator import NO_MIN
    from case_zero.app import create_app
    monkeypatch.setenv("CASE_ZERO_TRUSTED_HOPS", "")
    c = TestClient(create_app(settings=NO_MIN, world=world, llm=FakeLLM([]), per_ip_limit=1))
    codes = [c.post("/api/investigate", json={"seed": "acct_99999"}, headers={"X-Forwarded-For": h}).status_code for h in ("1.1.1.1, 203.0.113.7", "2.2.2.2, 203.0.113.7")]
    assert codes == [200, 429]   # the last hop, as on run.app


# 7. With two hops, the run.app URL must be closed -------------------------------------------------------
@pytest.mark.parametrize("name", ["deploy.sh", ".env.example"])
def test_docs_say_to_close_run_app_behind_a_load_balancer(name):
    from pathlib import Path
    text = (Path(__file__).resolve().parents[1] / name).read_text()
    assert "internal-and-cloud-load-balancing" in text


# 8. The snapshot records the settings that change the numbers ------------------------------------------
def test_snapshot_records_concurrency_and_the_judge_role(world, monkeypatch):
    import eval.run_eval as run_eval
    from case_zero.llm import load_role
    budget = SimpleNamespace(cap_usd=1.0, spent=lambda: 0.0)

    def from_env(cls, yaml_path, role="workhorse", thinking_level="low"):
        return SimpleNamespace(role=ROLE if role == "workhorse" else load_role(yaml_path, role), budget=budget)
    monkeypatch.setattr(run_eval.World, "load", classmethod(lambda cls, path: world))
    monkeypatch.setattr(run_eval.GeminiLLM, "from_env", classmethod(from_env))
    judged = asyncio.run(run_eval.main(_args(judge=True, only={"no-such-ring"}, concurrency=1)))
    assert judged["settings"]["concurrency"] == 1 and judged["settings"]["judge_role"] == "reasoning"
    plain = asyncio.run(run_eval.main(_args(only={"no-such-ring"})))
    assert plain["settings"]["concurrency"] == 2 and plain["settings"]["judge_role"] is None
