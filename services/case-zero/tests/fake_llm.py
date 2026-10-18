"""A scripted LLM for orchestrator and API tests: returns the queued turns in order."""

from __future__ import annotations

import asyncio

from case_zero.llm import FunctionCall, LLMTurn, ModelRole

ROLE = ModelRole(name="workhorse", id="fake-model", input_usd_per_m=0.75, output_usd_per_m=3.75)


def call(name: str, **args) -> LLMTurn:
    return LLMTurn(text="", function_calls=(FunctionCall(id=f"fc_{name}", name=name, args=args),), parsed=None, tokens_in=100, tokens_out=20, model_id=ROLE.id, latency_ms=5.0)


def done(text: str = "Investigation complete.") -> LLMTurn:
    return LLMTurn(text=text, function_calls=(), parsed=None, tokens_in=100, tokens_out=20, model_id=ROLE.id, latency_ms=5.0)


def draft(model) -> LLMTurn:
    return LLMTurn(text=model.model_dump_json(), function_calls=(), parsed=model, tokens_in=300, tokens_out=200, model_id=ROLE.id, latency_ms=5.0)


class FakeLLM:
    role = ROLE

    def __init__(self, script: list, delay_s: float = 0.0) -> None:
        self.script = list(script)
        self.delay_s = delay_s
        self.calls: list[dict] = []

    async def chat(self, system, contents, tools, schema, timeout_s, max_output_tokens=None):
        self.calls.append({"system": system, "contents": list(contents), "tools": tools, "schema": schema, "max_output_tokens": max_output_tokens})
        if self.delay_s:
            await asyncio.wait_for(asyncio.sleep(self.delay_s), timeout=timeout_s)
        if not self.script:
            return done()
        turn = self.script.pop(0)
        if isinstance(turn, Exception):
            raise turn
        return turn
