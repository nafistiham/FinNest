"""Gemini 429 (rate limit) and 503 (overloaded) are retried with a short back-off, inside the call's time budget."""

import asyncio
import time
from types import SimpleNamespace

import pytest
from google.genai import errors, types

from case_zero.budget import SpendLedger
from case_zero.llm import GeminiLLM, ModelRole

ROLE = ModelRole(name="workhorse", id="gemini-3.8-flash", input_usd_per_m=0.75, output_usd_per_m=3.75)
OK = types.GenerateContentResponse(
    candidates=[types.Candidate(content=types.Content(role="model", parts=[types.Part(text="ok")]))],
    usage_metadata=types.GenerateContentResponseUsageMetadata(prompt_token_count=1000, candidates_token_count=100, thoughts_token_count=0),
)


def scripted(outcomes: list, calls: list):
    async def generate_content(model, contents, config):
        calls.append(model)
        outcome = outcomes.pop(0)
        if isinstance(outcome, Exception):
            raise outcome
        return outcome
    return SimpleNamespace(aio=SimpleNamespace(models=SimpleNamespace(generate_content=generate_content)))


def err(code: int) -> errors.APIError:
    return errors.APIError(code, {"error": {"message": f"status {code}"}})


def llm(outcomes, calls, tmp_path, backoff=(0.01, 0.01)):
    return GeminiLLM(scripted(outcomes, calls), ROLE, budget=SpendLedger(tmp_path / "spend.json", cap_usd=5.0), backoff_s=backoff)


def test_429_is_retried_then_succeeds(tmp_path):
    calls = []
    turn = asyncio.run(llm([err(429), OK], calls, tmp_path).chat("s", [], None, None, 10.0))
    assert turn.text == "ok" and len(calls) == 2


def test_503_is_retried_twice(tmp_path):
    calls = []
    turn = asyncio.run(llm([err(503), err(503), OK], calls, tmp_path).chat("s", [], None, None, 10.0))
    assert turn.text == "ok" and len(calls) == 3


def test_gives_up_after_the_back_offs(tmp_path):
    calls = []
    with pytest.raises(errors.APIError) as exc:
        asyncio.run(llm([err(429), err(429), err(429)], calls, tmp_path).chat("s", [], None, None, 10.0))
    assert exc.value.code == 429 and len(calls) == 3


def test_other_errors_are_not_retried(tmp_path):
    calls = []
    with pytest.raises(errors.APIError):
        asyncio.run(llm([err(400), OK], calls, tmp_path).chat("s", [], None, None, 10.0))
    assert len(calls) == 1


def test_no_retry_when_the_back_off_would_pass_the_time_budget(tmp_path):
    calls = []
    started = time.monotonic()
    with pytest.raises(errors.APIError):
        asyncio.run(llm([err(429), OK], calls, tmp_path, backoff=(3.0,)).chat("s", [], None, None, 1.0))
    assert len(calls) == 1 and time.monotonic() - started < 0.5
