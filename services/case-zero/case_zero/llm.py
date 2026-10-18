"""The one place Case Zero talks to Gemini.

Model IDs and prices come from risk-mw/config/models.yaml by role (the single source of
truth). Gemini 3.8 Flash ignores sampling parameters, so we send none and set thinking to LOW.
Automatic function calling is off: the orchestrator runs every tool through the ledger itself.
"""

from __future__ import annotations

import asyncio
import json
import os
import time
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

import yaml
from google import genai
from google.genai import errors as genai_errors
from google.genai import types
from pydantic import BaseModel

from case_zero.budget import SpendLedger

TOKENS_PER_MILLION = 1_000_000
MAX_OUTPUT_TOKENS = 6000      # default cap per call (thinking + answer); the case writer has its own, larger one
DEFAULT_CAP_USD = 1.40
RETRY_CODES = frozenset({429, 503})  # rate limited, overloaded: worth a short wait
BACKOFF_S = (2.0, 5.0)               # waits before the second and third attempt
MIN_ATTEMPT_S = 5.0                  # a retry needs this much of the call's time budget left after its wait


@dataclass(frozen=True)
class ModelRole:
    name: str
    id: str
    input_usd_per_m: float
    output_usd_per_m: float


@dataclass(frozen=True)
class FunctionCall:
    id: str | None
    name: str
    args: dict


@dataclass(frozen=True)
class LLMTurn:
    text: str
    function_calls: tuple[FunctionCall, ...]
    parsed: BaseModel | None
    tokens_in: int
    tokens_out: int
    model_id: str
    latency_ms: float
    raw_content: types.Content | None = None


class LLM(Protocol):
    role: ModelRole

    async def chat(self, system: str, contents: list, tools: list[dict] | None, schema: type[BaseModel] | None, timeout_s: float,
                   max_output_tokens: int | None = None) -> LLMTurn: ...


def load_role(models_yaml: Path, name: str) -> ModelRole:
    spec = yaml.safe_load(models_yaml.read_text(encoding="utf-8"))["roles"][name]
    return ModelRole(name=name, id=str(spec["id"]), input_usd_per_m=float(spec["input_usd_per_m"]), output_usd_per_m=float(spec["output_usd_per_m"]))


def model_family(model_id: str) -> str:
    """The publisher ("meta/llama-x" -> meta) or the name's stem ("gemini-3.8-flash" -> gemini)."""
    return model_id.split("/", 1)[0] if "/" in model_id else model_id.split("-", 1)[0]


def spend_ledger_from_env() -> SpendLedger:
    """The one spend cap every run on this machine shares (server, eval, judge)."""
    spend_file = Path(os.environ.get("CASE_ZERO_SPEND_FILE", Path(__file__).resolve().parent.parent / ".spend.json"))
    return SpendLedger(spend_file, float(os.environ.get("CASE_ZERO_BUDGET_USD", DEFAULT_CAP_USD)))


def select_backend(env: Mapping[str, str]) -> tuple[str, str]:
    """Vertex whenever CASE_ZERO_PROJECT_ID is set (the team runs Vertex-only; a stray key must not win).
    CASE_ZERO_BACKEND=vertex|api_key forces a choice."""
    key = env.get("GOOGLE_API_KEY") or env.get("GEMINI_API_KEY") or ""
    project = env.get("CASE_ZERO_PROJECT_ID") or ""
    fallback_project = project or env.get("GOOGLE_CLOUD_PROJECT") or ""
    forced = (env.get("CASE_ZERO_BACKEND") or "").strip().lower()
    if forced == "api_key":
        return ("api_key", key) if key else ("none", "")
    if forced == "vertex" or project:
        return ("vertex", fallback_project) if fallback_project else ("none", "")
    if key:
        return ("api_key", key)
    return ("vertex", fallback_project) if fallback_project else ("none", "")


def estimate_tokens(system: str, contents: list, tools: list[dict] | None) -> int:
    """A generous input-token count for holding spend: UTF-8 bytes / 4 (a Bangla letter is 3 bytes)."""
    parts = [system, json.dumps(tools or [])] + [c.model_dump_json(exclude_none=True) if hasattr(c, "model_dump_json") else str(c) for c in contents]
    return sum(len(p.encode()) for p in parts) // 4 + 1


def cost_usd(tokens_in: int, tokens_out: int, role: ModelRole) -> float:
    return round((tokens_in * role.input_usd_per_m + tokens_out * role.output_usd_per_m) / TOKENS_PER_MILLION, 6)


def parse_response(resp: types.GenerateContentResponse, model_id: str, latency_ms: float, schema: type[BaseModel] | None) -> LLMTurn:
    content = resp.candidates[0].content if resp.candidates else None
    parts = (content.parts or []) if content else []
    calls = tuple(FunctionCall(id=p.function_call.id, name=p.function_call.name, args=dict(p.function_call.args or {})) for p in parts if p.function_call)
    text = "".join(p.text for p in parts if p.text and not p.thought)
    usage = resp.usage_metadata
    tokens_in = (usage.prompt_token_count or 0) if usage else 0
    tokens_out = ((usage.candidates_token_count or 0) + (usage.thoughts_token_count or 0)) if usage else 0
    parsed = schema.model_validate_json(text) if schema and text else None
    return LLMTurn(text=text, function_calls=calls, parsed=parsed, tokens_in=tokens_in, tokens_out=tokens_out, model_id=model_id, latency_ms=latency_ms, raw_content=content)


class GeminiLLM:
    def __init__(self, client: genai.Client | None, role: ModelRole, thinking_level: str = "low", budget: SpendLedger | None = None,
                 backoff_s: tuple[float, ...] = BACKOFF_S, min_attempt_s: float = MIN_ATTEMPT_S) -> None:
        self.client = client
        self.role = role
        self.budget = budget
        self.backoff_s, self.min_attempt_s = backoff_s, min_attempt_s
        self.thinking_level = types.ThinkingLevel(thinking_level.upper())

    @classmethod
    def from_env(cls, models_yaml: Path, role_name: str = "workhorse", thinking_level: str = "low") -> "GeminiLLM":
        backend, value = select_backend(os.environ)
        if backend == "api_key":
            client = genai.Client(api_key=value)
        elif backend == "vertex":
            client = genai.Client(vertexai=True, project=value, location=os.environ.get("CASE_ZERO_LOCATION", "global"))
        else:
            raise RuntimeError("No Gemini credentials: set GOOGLE_API_KEY, or CASE_ZERO_PROJECT_ID for Vertex AI")
        return cls(client, load_role(models_yaml, role_name), thinking_level, spend_ledger_from_env())

    def build_config(self, system: str, tools: list[dict] | None, schema: type[BaseModel] | None, max_output_tokens: int | None = None) -> types.GenerateContentConfig:
        declarations = [types.FunctionDeclaration(name=t["name"], description=t["description"], parameters_json_schema=t["parameters"]) for t in tools or []]
        return types.GenerateContentConfig(
            system_instruction=system,
            thinking_config=types.ThinkingConfig(thinking_level=self.thinking_level),
            tools=[types.Tool(function_declarations=declarations)] if declarations else None,
            automatic_function_calling=types.AutomaticFunctionCallingConfig(disable=True),
            max_output_tokens=max_output_tokens or MAX_OUTPUT_TOKENS,
            response_mime_type="application/json" if schema else None,
            response_json_schema=schema.model_json_schema() if schema else None,
        )

    async def chat(self, system: str, contents: list, tools: list[dict] | None, schema: type[BaseModel] | None, timeout_s: float,
                   max_output_tokens: int | None = None) -> LLMTurn:
        """One Gemini call; a 429 or 503 is retried after a short wait while the call's time budget allows."""
        deadline = time.monotonic() + timeout_s
        waits = (0.0, *self.backoff_s)
        for attempt, wait in enumerate(waits):
            if wait:
                await asyncio.sleep(wait)
            try:
                return await self._once(system, contents, tools, schema, deadline - time.monotonic(), max_output_tokens)
            except genai_errors.APIError as exc:
                last = attempt + 1 >= len(waits)
                if exc.code not in RETRY_CODES or last or deadline - time.monotonic() < waits[attempt + 1] + self.min_attempt_s:
                    raise
        raise AssertionError("unreachable")

    async def _once(self, system: str, contents: list, tools: list[dict] | None, schema: type[BaseModel] | None, timeout_s: float,
                    max_output_tokens: int | None = None) -> LLMTurn:
        config = self.build_config(system, tools, schema, max_output_tokens)
        worst = cost_usd(estimate_tokens(system, contents, tools), config.max_output_tokens, self.role)  # this call's prompt and output cap
        held = self.budget.reserve(worst) if self.budget is not None else 0.0
        started = time.perf_counter()
        try:
            resp = await asyncio.wait_for(self.client.aio.models.generate_content(model=self.role.id, contents=contents, config=config), timeout=timeout_s)
            usage = resp.usage_metadata
            tokens_out = ((usage.candidates_token_count or 0) + (usage.thoughts_token_count or 0)) if usage else 0
            cost = cost_usd((usage.prompt_token_count or 0) if usage else 0, tokens_out, self.role)
        except genai_errors.APIError:
            if self.budget is not None:  # an error reply is not billed
                self.budget.settle(held, 0.0)
            raise
        except BaseException:
            if self.budget is not None:  # timed out, cancelled or unreadable: the server may still bill it, so its worst case
                self.budget.settle(held, worst)
            raise
        if self.budget is not None:  # settle before parsing: an unparseable reply was still billed
            self.budget.settle(held, cost)
        return parse_response(resp, self.role.id, (time.perf_counter() - started) * 1000, schema)
