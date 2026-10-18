"""The detector's reasoning variants: which structure buys accuracy is measured, not assumed.

scam.py's one model read goes through extract(settings.scam_variant, ...); eval/intervention_eval.py replays the held-out and
adversarial calls through each variant and eval/variant_table.py picks the winner: v3 on 2026-10-17, now the default.
- v1: the evidence-first schema on the volume role (Flash-Lite) at thinking "minimal".
- v2: v1 plus a short `check` field generated just before `verdict`: who claims to be whom, what is asked, which norm it breaks.
- v3: v1 at thinking "low".
- v4: v1, and a borderline read (UNCERTAIN, or confidence in [0.5, 0.9]) gets a second read on the workhorse role (3.8 Flash) at
  thinking "low", set explicitly because that model rejects "minimal" and would bill "medium"; its thought summaries are logged.
  In production it runs in the background (on_escalation) and its verdict replaces the risk when it lands.
- v5: v1, and a borderline read gets two more samples at the default temperature; the verdict is the majority of the three.
"""

from __future__ import annotations

import contextvars
import json
import logging
import threading
import time
from collections import Counter
from collections.abc import Callable, Iterator
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from dataclasses import dataclass, fields
from functools import lru_cache
from typing import Any

from pydantic import BaseModel, ConfigDict, Field, create_model

from app import genai_client
from app.settings import Settings, get_settings

log = logging.getLogger(__name__)

VARIANTS = ("v1", "v2", "v3", "v4", "v5")
DEFAULT_VARIANT = "v3"  # the comparison's winner (2026-10-17); an unknown setting falls back to it
BORDERLINE = (0.5, 0.9)           # confidence band, inclusive, where a second opinion can change the outcome
SAMPLES = 3                       # v5: the first read and two more
ESCALATION_ROLE, ESCALATION_THINKING, ESCALATION_TASK = "workhorse", "low", "scam_escalation"
ESCALATION_TIMEOUT_S = 10.0       # off the hot path in production; the synchronous read keeps settings.scam_timeout_s
THOUGHTS_MAX = 2000               # characters of thought summary kept for the audit log
CHECK_DESCRIPTION = ("One short sentence (about 60 tokens), written before the verdict: who claims to be whom, what they ask for, "
                     "and which norm that request breaks (for example: bank or wallet staff never ask for an OTP or a PIN).")

Call = Callable[..., Any]
Schema = type[BaseModel] | dict  # a pydantic model, or a Vertex dict schema built at call time


@dataclass(frozen=True)
class VariantResult:
    extraction: dict
    latency_ms: float      # the synchronous path: what the caller's turn waits for (v4's second read is not on it)
    cost_usd: float        # every read that finished, the escalation included
    escalated: bool
    escalation: dict | None


DETECTOR_ROLE = "volume"  # the role every synchronous read of a turn uses (v4's second read is off the turn's path)

_RECORDER: contextvars.ContextVar[list[VariantResult] | None] = contextvars.ContextVar("scam_variant_results", default=None)
_DEFERRED: contextvars.ContextVar[list | None] = contextvars.ContextVar("scam_variant_deferred", default=None)


@contextmanager
def recording() -> Iterator[list[VariantResult]]:
    """Collect every VariantResult extract() returns in this context: the eval sees escalations through scam.score_turn."""
    results: list[VariantResult] = []
    token = _RECORDER.set(results)
    try:
        yield results
    finally:
        _RECORDER.reset(token)


@contextmanager
def synchronous_escalations() -> Iterator[None]:
    """For the eval: v4's second read runs before extract returns (so its cost and latency belong to the turn) and its
    on_escalation callback is held until this context exits, after the turn has answered: production's order without the
    thread, and the eval reports whether the verdict would have landed before the next caller turn."""
    pending: list[tuple[Callable[[dict], None], dict]] = []
    token = _DEFERRED.set(pending)
    try:
        yield
    finally:
        _DEFERRED.reset(token)
        for on_escalation, esc in pending:
            _land(on_escalation, esc)


def _land(on_escalation: Callable[[dict], None], esc: dict) -> None:
    try:
        on_escalation(esc)
    except Exception:  # noqa: BLE001 - a failed landing must never surface in the call
        log.exception("scam escalation callback failed")


def borderline(extraction: dict) -> bool:
    if extraction.get("verdict") == "UNCERTAIN":
        return True
    try:
        confidence = float(extraction.get("confidence"))
    except (TypeError, ValueError):
        return False
    return BORDERLINE[0] <= confidence <= BORDERLINE[1]


@lru_cache(maxsize=16)
def checked_schema(schema: type[BaseModel]) -> type[BaseModel]:
    """v2's schema: the same fields in the same order with `check` just before `verdict` (last when there is none). The order
    is pinned with propertyOrdering, the order Vertex generates in, so the check is written before the verdict it informs."""
    check = (str, Field(description=CHECK_DESCRIPTION))
    fields: dict[str, Any] = {}
    for name, info in schema.model_fields.items():
        if name == "verdict":
            fields["check"] = check
        fields[name] = (info.annotation, info)
    fields.setdefault("check", check)
    config = dict(schema.model_config)
    extra = config.get("json_schema_extra")
    config["json_schema_extra"] = {**(extra if isinstance(extra, dict) else {}), "propertyOrdering": list(fields)}
    return create_model(f"{schema.__name__}Checked", __config__=ConfigDict(**config), __doc__=schema.__doc__, **fields)


def _ms(result: Any) -> float:
    return float(getattr(result, "latency_ms", 0.0) or 0.0)


def _usd(result: Any) -> float:
    return float(getattr(result, "cost_usd", 0.0) or 0.0)


def checked(schema: Schema) -> Schema:
    """checked_schema() for either form: a pydantic model, or a Vertex dict schema (the detector's, whose scam_type enum comes
    from the live card set), where `check` goes into the properties and just before `verdict` in propertyOrdering."""
    if not isinstance(schema, dict):
        return checked_schema(schema)
    order = [name for name in schema.get("propertyOrdering", list(schema.get("properties", {}))) if name != "check"]
    order.insert(order.index("verdict") if "verdict" in order else len(order), "check")
    return {**schema, "properties": {**schema.get("properties", {}), "check": {"type": "STRING", "description": CHECK_DESCRIPTION}},
            "required": [*(r for r in schema.get("required", ()) if r != "check"), "check"], "propertyOrdering": order}


def _read(call: Call, schema: Schema, prefix: str, transcript_part: Any, *, task: str, role: str, thinking: str,
          timeout_s: float) -> tuple[dict, Any]:
    result = call(task, role, transcript_part, schema=schema, system=prefix, timeout_s=timeout_s, thinking_level=thinking)
    if isinstance(schema, dict):  # a dict schema parses to a dict (or only the text comes back)
        return (dict(result.parsed) if isinstance(result.parsed, dict) else json.loads(result.text)), result
    parsed = result.parsed if isinstance(result.parsed, schema) else schema.model_validate_json(result.text)
    return parsed.model_dump(mode="json"), result


def extract(variant: str, *, prefix: str, transcript_part: Any, schema: Schema, settings: Settings, call: Call | None = None,
            escalation_call: Call | None = None, on_escalation: Callable[[dict], None] | None = None) -> VariantResult:
    """One model read of the call so far under `variant`. prefix is the static, cacheable part (rules, cards, examples), sent as
    the system instruction so implicit caching can serve it; transcript_part is the call (a string or the SDK's contents);
    schema is a pydantic model or a Vertex dict schema. A failed first read raises, as the
    single read did before, so the detector keeps its own fallback.

    call defaults to genai_client.call, resolved at call time (a patched genai_client.call is the one used); escalation_call,
    v4's second read, defaults to call_with_thoughts. With on_escalation (production), v4 answers with the first read at once
    and hands the second read to on_escalation from a background thread when it lands: the callback is where the detector
    replaces the risk. Under synchronous_escalations() (the eval) the second read runs here and the callback lands after the turn.
    Without on_escalation the second read runs here and, when it succeeds, its extraction replaces the first in the result.
    """
    call = call or genai_client.call
    if variant not in VARIANTS:
        log.warning("unknown scam_variant %r; using %s", variant, DEFAULT_VARIANT)
        variant = DEFAULT_VARIANT
    read_schema = checked(schema) if variant == "v2" else schema
    thinking = "low" if variant == "v3" else "minimal"
    extraction, first = _read(call, read_schema, prefix, transcript_part, task="scam_turn", role=DETECTOR_ROLE, thinking=thinking,
                              timeout_s=settings.scam_timeout_s)
    result = VariantResult(extraction, _ms(first), round(_usd(first), 6), False, None)
    if variant == "v4" and borderline(extraction):
        second = escalation_call or call_with_thoughts
        result = _escalate(second, schema, prefix, transcript_part, extraction, first, on_escalation)
    elif variant == "v5" and borderline(extraction):
        result = _vote(call, schema, prefix, transcript_part, settings, extraction, first)
    recorder = _RECORDER.get()
    if recorder is not None:
        recorder.append(result)
    return result


def _trigger(stage1: dict) -> str:
    return "uncertain" if stage1.get("verdict") == "UNCERTAIN" else "confidence"


def _second_read(call: Call, schema: type[BaseModel], prefix: str, transcript_part: str, stage1: dict) -> dict:
    out = {"kind": "second_read", "role": ESCALATION_ROLE, "thinking_level": ESCALATION_THINKING, "trigger": _trigger(stage1),
           "background": True, "stage1": stage1, "extraction": None, "verdict": None, "changed": False, "latency_ms": 0.0,
           "cost_usd": 0.0, "thoughts": "", "error": None}
    started = time.perf_counter()
    try:
        extraction, res = _read(call, schema, prefix, transcript_part, task=ESCALATION_TASK, role=ESCALATION_ROLE,
                                thinking=ESCALATION_THINKING, timeout_s=ESCALATION_TIMEOUT_S)
    except Exception as exc:  # noqa: BLE001 - a failed second opinion leaves the first standing
        out.update(error=exc.__class__.__name__, latency_ms=round((time.perf_counter() - started) * 1000, 1))
        log.warning("scam escalation failed, the first read stands: %s", exc.__class__.__name__)
        return out
    thoughts = str(getattr(res, "thoughts", "") or "")[:THOUGHTS_MAX]
    out.update(extraction=extraction, verdict=extraction.get("verdict"), changed=extraction.get("verdict") != stage1.get("verdict"),
               latency_ms=_ms(res), cost_usd=round(_usd(res), 6), thoughts=thoughts)
    log.info(json.dumps({"task": ESCALATION_TASK, "trigger": out["trigger"], "stage1_verdict": stage1.get("verdict"),
                         "verdict": out["verdict"], "latency_ms": out["latency_ms"], "thoughts": thoughts}, ensure_ascii=False))
    return out


def _escalate(call: Call, schema: type[BaseModel], prefix: str, transcript_part: str, stage1: dict, first: Any,
              on_escalation: Callable[[dict], None] | None) -> VariantResult:
    deferred = _DEFERRED.get()
    if on_escalation is not None and deferred is not None:
        esc = _second_read(call, schema, prefix, transcript_part, stage1)
        deferred.append((on_escalation, esc))
        return VariantResult(stage1, _ms(first), round(_usd(first) + esc["cost_usd"], 6), True, esc)
    if on_escalation is not None:
        def land() -> None:  # _second_read never raises
            _land(on_escalation, _second_read(call, schema, prefix, transcript_part, stage1))
        threading.Thread(target=contextvars.copy_context().run, args=(land,), name="scam-escalation", daemon=True).start()
        pending = {"kind": "second_read", "pending": True, "background": True, "trigger": _trigger(stage1)}
        return VariantResult(stage1, _ms(first), round(_usd(first), 6), True, pending)
    esc = _second_read(call, schema, prefix, transcript_part, stage1)
    final = esc["extraction"] if esc["extraction"] is not None else stage1
    return VariantResult(final, _ms(first), round(_usd(first) + esc["cost_usd"], 6), True, esc)


def _vote(call: Call, schema: type[BaseModel], prefix: str, transcript_part: str, settings: Settings, stage1: dict,
          first: Any) -> VariantResult:
    """Self-consistency: two more samples in parallel; the majority verdict wins and the agreement is kept as a confidence proxy
    (Gemini 3.x returns no logprobs). Without a majority, the UNCERTAIN sample if there is one, else the first read."""
    def sample() -> tuple[dict, Any]:
        return _read(call, schema, prefix, transcript_part, task="scam_turn_sample", role=DETECTOR_ROLE, thinking="minimal",
                     timeout_s=settings.scam_timeout_s)

    block = time.perf_counter()
    with ThreadPoolExecutor(max_workers=SAMPLES - 1, thread_name_prefix="scam-sample") as pool:
        futures = [pool.submit(contextvars.copy_context().run, sample) for _ in range(SAMPLES - 1)]
    block_ms = round((time.perf_counter() - block) * 1000, 1)  # with any queueing: the eval takes it out, then adds latency_ms
    samples, extra, errors = [stage1], [], []
    for future in futures:
        try:
            extraction, res = future.result()
        except Exception as exc:  # noqa: BLE001 - a failed sample is left out of the vote
            errors.append(exc.__class__.__name__)
            continue
        samples.append(extraction)
        extra.append(res)
    votes = Counter(s.get("verdict") for s in samples)
    top, count = votes.most_common(1)[0]
    majority = top if count * 2 > len(samples) else None
    chosen = next((s for s in samples if s.get("verdict") == (majority or "UNCERTAIN")), stage1)
    extra_ms, extra_usd = max((_ms(r) for r in extra), default=0.0), sum(_usd(r) for r in extra)
    esc = {"kind": "self_consistency", "background": False, "samples": len(samples), "votes": dict(votes), "majority": majority,
           "agreement": round(count / len(samples), 3), "latency_ms": extra_ms, "wall_ms": block_ms, "cost_usd": round(extra_usd, 6),
           "errors": errors, "changed": chosen.get("verdict") != stage1.get("verdict")}
    return VariantResult(chosen, round(_ms(first) + extra_ms, 1), round(_usd(first) + extra_usd, 6), True, esc)


# --- v4's second read: genai_client.call with thought summaries -------------------------------------


@dataclass(frozen=True)
class ReadWithThoughts(genai_client.CallResult):
    thoughts: str = ""


def _thought_text(response: Any) -> str:
    candidates = getattr(response, "candidates", None) or []
    parts = (getattr(getattr(candidates[0], "content", None), "parts", None) or []) if candidates else []
    return "\n".join(p.text for p in parts if getattr(p, "thought", False) and getattr(p, "text", None))


def call_with_thoughts(task: str, role_name: str, contents: str, schema: type[BaseModel] | None = None, system: str | None = None,
                       timeout_s: float | None = None, thinking_level: str | None = None,
                       max_output_tokens: int | None = None) -> ReadWithThoughts:
    """genai_client.call with thought summaries requested (include_thoughts), for v4's audited second read: the same guards (a
    configured backend, the spend reservation, retries inside timeout_s), cached-token pricing and one JSON log line."""
    response, result = genai_client.reserved_read(task, role_name, contents, schema, system, timeout_s, thinking_level, max_output_tokens,
                                                  include_thoughts=True)
    thoughts = _thought_text(response)
    log.info(json.dumps({"task": task, "thoughts_chars": len(thoughts)}))
    return ReadWithThoughts(**{f.name: getattr(result, f.name) for f in fields(genai_client.CallResult)}, thoughts=thoughts)
