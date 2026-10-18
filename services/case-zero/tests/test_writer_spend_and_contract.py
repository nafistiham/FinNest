"""The writer's own output cap, reserve-then-settle spend, contract evidence with real row ids only, and the
result file written under the spec's name (investigator.json)."""

import asyncio
import json
from types import SimpleNamespace

import pytest
from fake_llm import FakeLLM, draft
from google.genai import errors, types
from test_orchestrator import NO_MIN, SCRIPT, good_draft, run

from case_zero.budget import BudgetExceeded, SpendLedger
from case_zero.config import DEMO_AS_OF, DEMO_SEED, Settings
from case_zero.llm import MAX_OUTPUT_TOKENS, GeminiLLM, ModelRole, cost_usd

OLD_FIXED_RESERVE_USD = 0.04   # what every call used to hold, and what a timeout used to cost

ROLE = ModelRole(name="workhorse", id="gemini-3.8-flash", input_usd_per_m=0.75, output_usd_per_m=3.75)
OK = types.GenerateContentResponse(
    candidates=[types.Candidate(content=types.Content(role="model", parts=[types.Part(text="ok")]))],
    usage_metadata=types.GenerateContentResponseUsageMetadata(prompt_token_count=1000, candidates_token_count=100, thoughts_token_count=0),
)


def _client(generate):
    return SimpleNamespace(aio=SimpleNamespace(models=SimpleNamespace(generate_content=generate)))


# 1. The case writer has its own, larger output cap -----------------------------------------------------
def test_writer_gets_its_own_larger_output_cap(world):
    llm = FakeLLM(SCRIPT + [draft(good_draft())])

    async def emit(_):
        return None
    from case_zero.orchestrator import run_investigation
    asyncio.run(run_investigation(world, llm, DEMO_SEED, DEMO_AS_OF, emit, "CZ-0001", settings=NO_MIN))
    writer = [c for c in llm.calls if c["schema"] is not None]
    investigator = [c for c in llm.calls if c["schema"] is None]
    assert Settings().writer_max_output_tokens > MAX_OUTPUT_TOKENS
    assert writer and all(c["max_output_tokens"] == Settings().writer_max_output_tokens for c in writer)
    assert investigator and all(c["max_output_tokens"] is None for c in investigator)   # tool turns keep the default


def test_the_cap_reaches_gemini():
    llm = GeminiLLM(None, ROLE)
    assert llm.build_config("s", None, None).max_output_tokens == MAX_OUTPUT_TOKENS
    assert llm.build_config("s", None, None, max_output_tokens=16_384).max_output_tokens == 16_384


# 2. Reserve, then settle, under one lock ------------------------------------------------------------
def test_concurrent_calls_cannot_all_pass_the_cap(tmp_path):
    calls = []

    async def slow(model, contents, config):
        calls.append(model)
        await asyncio.sleep(0.05)
        return OK
    budget = SpendLedger(tmp_path / "spend.json", cap_usd=0.05)   # room for two small holds (~$0.0225 each), not three
    llm = GeminiLLM(_client(slow), ROLE, budget=budget)

    async def go():
        return await asyncio.gather(*(llm.chat("s", [], None, None, 5) for _ in range(3)), return_exceptions=True)
    outcomes = asyncio.run(go())
    assert len(calls) == 2 and sum(isinstance(o, BudgetExceeded) for o in outcomes) == 1
    assert budget.held() == 0 and budget.spent() == pytest.approx(2 * cost_usd(1000, 100, ROLE))


def test_a_hold_is_released_and_the_real_cost_recorded(tmp_path):
    async def ok(model, contents, config):
        return OK
    budget = SpendLedger(tmp_path / "spend.json", cap_usd=1.0)
    asyncio.run(GeminiLLM(_client(ok), ROLE, budget=budget).chat("s", [], None, None, 5))
    assert budget.held() == 0 and budget.spent() == pytest.approx(cost_usd(1000, 100, ROLE)) and budget.calls() == 1


def test_a_timeout_settles_to_the_calls_own_estimate(tmp_path):
    async def slow(model, contents, config):
        await asyncio.sleep(1)
    budget = SpendLedger(tmp_path / "spend.json", cap_usd=1.0)
    with pytest.raises(asyncio.TimeoutError):
        asyncio.run(GeminiLLM(_client(slow), ROLE, budget=budget).chat("s", [], None, None, 0.05))
    assert budget.held() == 0
    assert cost_usd(1, MAX_OUTPUT_TOKENS, ROLE) <= budget.spent() < OLD_FIXED_RESERVE_USD   # a one-word prompt is not charged as a 20k-token one


def test_an_error_reply_is_not_charged(tmp_path):
    async def bad(model, contents, config):
        raise errors.APIError(400, {"error": {"message": "bad request"}})
    budget = SpendLedger(tmp_path / "spend.json", cap_usd=1.0)
    with pytest.raises(errors.APIError):
        asyncio.run(GeminiLLM(_client(bad), ROLE, budget=budget).chat("s", [], None, None, 5))
    assert budget.held() == 0 and budget.spent() == 0


def test_the_writers_larger_cap_is_held_in_full(tmp_path):
    calls = []

    async def ok(model, contents, config):
        calls.append(config.max_output_tokens)
        return OK
    budget = SpendLedger(tmp_path / "spend.json", cap_usd=0.05)   # 16k output tokens cost about $0.06
    llm = GeminiLLM(_client(ok), ROLE, budget=budget)
    with pytest.raises(BudgetExceeded):
        asyncio.run(llm.chat("s", [], None, None, 5, max_output_tokens=16_384))
    asyncio.run(llm.chat("s", [], None, None, 5))
    assert calls == [MAX_OUTPUT_TOKENS]


def test_ledgers_on_one_file_share_holds(tmp_path):
    a, b = SpendLedger(tmp_path / "spend.json", cap_usd=0.10), SpendLedger(tmp_path / "spend.json", cap_usd=0.10)   # agent and judge in one eval
    a.reserve(0.06)
    with pytest.raises(BudgetExceeded):
        b.reserve(0.06)
    a.settle(0.06, 0.01)
    b.reserve(0.06)
    assert a.spent() == pytest.approx(0.01) and b.held() == pytest.approx(0.06)


# 3. Contract evidence: real row ids only --------------------------------------------------------------
def _contract_module():
    import importlib.util
    import sys
    from pathlib import Path
    path = Path(__file__).resolve().parents[2] / "risk-mw" / "app" / "contracts.py"
    spec = importlib.util.spec_from_file_location("risk_contracts_pr4", path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod
    spec.loader.exec_module(mod)
    return mod


def _report_with_flags(world, flags, status="done"):
    from case_zero.ledger import Ledger
    from case_zero.schemas import CaseReport
    ledger = Ledger(world, DEMO_SEED, DEMO_AS_OF)
    ledger.prefetch_score()
    ledger.call("path_between", source="acct_rina", target=DEMO_SEED)   # tc_01: has txn ids
    ledger.call("kyc_dupe_check", acct_id=DEMO_SEED)                    # tc_02: no txn ids
    report = CaseReport(case_id="CZ-0001", seed=DEMO_SEED, as_of=DEMO_AS_OF, status=status, draft=good_draft(red_flags=flags), model_score=0.87,
                        top_reasons=[], action="freeze", floor_action="freeze", escalated=False, validation={"first_pass": [], "final": [], "retried": False},
                        model_version="m", cost={}, tool_calls=2)
    return report, ledger


def test_contract_evidence_has_only_real_row_ids(world):
    from case_zero.schemas import to_contract
    flags = [{"code": "RF02", "text": "money moved on", "evidence": ["tc_01"]},
             {"code": "RF05", "text": "shared identity", "evidence": ["tc_02"]},
             {"code": "RF12", "text": "high model score", "evidence": []}]
    report, ledger = _report_with_flags(world, flags)
    contract = to_contract(report, ledger)
    assert [e["claim"] for e in contract["evidence"]] == ["money moved on"]   # flags without a transaction are dropped
    assert all(e["row_id"].startswith("txn_") for e in contract["evidence"])
    assert _contract_module().CaseReport(**contract).evidence[0].row_id.startswith("txn_")


def test_contract_keeps_a_redacted_case_apart_from_a_failed_one(world):
    from case_zero.schemas import to_contract
    flags = [{"code": "RF02", "text": "money moved on", "evidence": ["tc_01"]}]
    retried, ledger = _report_with_flags(world, flags, status="failed_after_retry")
    failed, _ = _report_with_flags(world, flags, status="failed")
    assert to_contract(retried, ledger)["status"] == "degraded" and to_contract(failed, ledger)["status"] == "failed"   # Never done
    assert to_contract(retried, ledger)["evidence"]   # the redacted case still reaches risk-mw


# 4. The spec's eval/results/investigator.json -----------------------------------------------------------
def _result():
    from test_judge_and_tool_concurrency import _judged_result
    return _judged_result("openai/gpt-oss-120b-maas")


def test_results_are_also_written_under_the_specs_name(tmp_path):
    from eval.run_eval import write_results
    out = tmp_path / "case_zero.json"
    write_results(_result(), out)
    assert (tmp_path / "investigator.json").read_bytes() == out.read_bytes() and (tmp_path / "case_zero.md").exists()


def test_other_result_files_do_not_overwrite_the_specs_one(tmp_path):
    from eval.run_eval import write_results
    write_results(_result(), tmp_path / "case_zero_dev.json")
    assert not (tmp_path / "investigator.json").exists()
