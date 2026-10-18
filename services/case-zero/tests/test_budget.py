import asyncio
from types import SimpleNamespace

import pytest
from google.genai import types

from case_zero.budget import BudgetExceeded, SpendLedger
from case_zero.llm import GeminiLLM, ModelRole

ROLE = ModelRole(name="workhorse", id="gemini-3.8-flash", input_usd_per_m=0.75, output_usd_per_m=3.75)


def stub_client(calls: list):
    async def generate_content(model, contents, config):
        calls.append(model)
        return types.GenerateContentResponse(
            candidates=[types.Candidate(content=types.Content(role="model", parts=[types.Part(text="ok")]))],
            usage_metadata=types.GenerateContentResponseUsageMetadata(prompt_token_count=10_000, candidates_token_count=1_000, thoughts_token_count=1_000),
        )
    return SimpleNamespace(aio=SimpleNamespace(models=SimpleNamespace(generate_content=generate_content)))


def test_check_raises_when_cap_would_be_exceeded(tmp_path):
    ledger = SpendLedger(tmp_path / "spend.json", cap_usd=0.10)
    ledger.record(0.08)
    ledger.check(0.02)
    with pytest.raises(BudgetExceeded):
        ledger.check(0.03)


def test_spend_persists_across_instances(tmp_path):
    SpendLedger(tmp_path / "spend.json", cap_usd=1.0).record(0.25)
    again = SpendLedger(tmp_path / "spend.json", cap_usd=1.0)
    assert again.spent() == pytest.approx(0.25) and again.calls() == 1


def test_chat_refuses_before_calling_when_budget_is_spent(tmp_path):
    ledger = SpendLedger(tmp_path / "spend.json", cap_usd=0.05)
    ledger.record(0.04)
    calls = []
    llm = GeminiLLM(stub_client(calls), ROLE, budget=ledger)
    with pytest.raises(BudgetExceeded):
        asyncio.run(llm.chat("s", [], None, None, 5))
    assert calls == []


def test_chat_records_actual_cost(tmp_path):
    ledger = SpendLedger(tmp_path / "spend.json", cap_usd=1.0)
    llm = GeminiLLM(stub_client([]), ROLE, budget=ledger)
    asyncio.run(llm.chat("s", [], None, None, 5))
    assert ledger.spent() == pytest.approx((10_000 * 0.75 + 2_000 * 3.75) / 1_000_000)


def test_output_tokens_are_bounded():
    cfg = GeminiLLM(None, ROLE).build_config("s", None, None)
    assert cfg.max_output_tokens is not None and cfg.max_output_tokens <= 8192


def test_cost_is_recorded_even_when_the_reply_is_not_valid_json(tmp_path):
    from pydantic import ValidationError

    from case_zero.schemas import CaseDraft

    ledger = SpendLedger(tmp_path / "spend.json", cap_usd=1.0)
    llm = GeminiLLM(stub_client([]), ROLE, budget=ledger)  # stub replies "ok", which is not a CaseDraft
    with pytest.raises(ValidationError):
        asyncio.run(llm.chat("s", [], None, CaseDraft, 5))
    assert ledger.spent() > 0


def test_timed_out_calls_are_charged_conservatively(tmp_path):
    async def slow(model, contents, config):
        await asyncio.sleep(1)
    client = SimpleNamespace(aio=SimpleNamespace(models=SimpleNamespace(generate_content=slow)))
    ledger = SpendLedger(tmp_path / "spend.json", cap_usd=1.0)
    llm = GeminiLLM(client, ROLE, budget=ledger)
    with pytest.raises(asyncio.TimeoutError):
        asyncio.run(llm.chat("s", [], None, None, 0.05))
    assert ledger.spent() > 0  # the server may still finish and bill a request we stopped waiting for
