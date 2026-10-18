"""The one place that talks to Gemini (spec US-4).

- Model IDs come from config/models.yaml by *role*; no route names a model string.
- Backend: Gemini Developer API with an API key when one is present (spends the prepaid
  Gemini credit), otherwise Vertex AI with project + region (spends the Cloud welcome
  credit). Forced with RISK_MW_GENAI_BACKEND=api_key|vertex.
- Every call returns parsed structured output plus token usage, cost and latency, and logs
  one JSON line: {task, model_id, tokens_in, tokens_out, cost_usd, reserved_usd, latency_ms}.
- Spend is capped per instance: a call reserves its worst case before it is sent and
  is admitted only if that still fits under the cap, then settles at its real cost.
"""

from __future__ import annotations

import contextvars
import hashlib
import itertools
import json
import logging
import threading
import time
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path
from typing import Any, Literal, TypeVar

import httpx
import yaml
from pydantic import BaseModel

from app.settings import Settings, get_settings

log = logging.getLogger("genai")
T = TypeVar("T", bound=BaseModel)
TOKENS_PER_MILLION = 1_000_000
CACHED_INPUT_SHARE = 0.10  # implicitly cached input tokens are billed at 10% of the input price
CAP_TOLERANCE_USD = 1e-9  # float noise: 0.001 + 0.0005 must fit a 0.0015 cap


class GenAIDisabled(RuntimeError):
    """Raised when RISK_MW_GENAI_ENABLED is false; callers fall back to stubs."""


class SpendCapReached(GenAIDisabled):
    """The call's worst case does not fit under the spend cap; a GenAIDisabled, so every caller already falls back."""


# Why a route answered from its stub, as a fixed code a client and the audit row can read. Never the
# exception text: that can carry upstream detail. The detail goes to the server log.
FALLBACK_GENAI_DISABLED = "genai_disabled"
FALLBACK_SPEND_CAP = "spend_cap"
FALLBACK_TIMEOUT = "timeout"
FALLBACK_GENAI_ERROR = "genai_error"
FALLBACK_CODES = (FALLBACK_GENAI_DISABLED, FALLBACK_SPEND_CAP, FALLBACK_TIMEOUT, FALLBACK_GENAI_ERROR)


def fallback_code(exc: BaseException) -> str:
    if isinstance(exc, SpendCapReached):
        return FALLBACK_SPEND_CAP
    if isinstance(exc, GenAIDisabled):
        return FALLBACK_GENAI_DISABLED
    if isinstance(exc, TimeoutError | httpx.TimeoutException):
        return FALLBACK_TIMEOUT
    return FALLBACK_GENAI_ERROR


class SpendLedger:
    """Gemini cost for this instance: settled spend plus the worst case of the calls in flight.

    Not durable: a restart starts again from zero. A call reserves its worst case before it is sent and is admitted
    only while settled + reserved + that worst case stays within the cap, so concurrent calls cannot pass the cap
    together; afterwards it settles at its real cost, or releases the reservation if it failed.
    """

    def __init__(self) -> None:
        self._spent = 0.0
        self._reserved: dict[str, float] = {}
        self._tokens = itertools.count(1)
        self._lock = threading.Lock()

    def reserve(self, max_usd: float, cap_usd: float) -> str | None:
        """A token for a call that may cost up to `max_usd`, or None when it would not fit under `cap_usd`."""
        if max_usd < 0:
            raise ValueError(f"a reservation cannot be negative: {max_usd}")
        with self._lock:
            if self._spent + sum(self._reserved.values()) + max_usd > cap_usd + CAP_TOLERANCE_USD:
                return None
            token = str(next(self._tokens))
            self._reserved = {**self._reserved, token: max_usd}
            return token

    def settle(self, token: str, actual_usd: float) -> float:
        """Replace the reservation with what the call really cost; returns the settled spend."""
        with self._lock:
            self._reserved = self._without(token)
            self._spent += actual_usd
            return self._spent

    def release(self, token: str) -> None:
        """Drop the reservation of a call that failed; nothing is spent."""
        with self._lock:
            self._reserved = self._without(token)

    def _without(self, token: str) -> dict[str, float]:
        if token not in self._reserved:
            raise KeyError(f"no open reservation {token!r}")
        return {k: v for k, v in self._reserved.items() if k != token}

    def add(self, usd: float) -> float:
        with self._lock:
            self._spent += usd
            return self._spent

    def spent(self) -> float:
        with self._lock:
            return self._spent

    def reserved(self) -> float:
        with self._lock:
            return sum(self._reserved.values())

    def reset(self) -> None:
        with self._lock:
            self._spent = 0.0
            self._reserved = {}


LEDGER = SpendLedger()


def fits(worst_usd: float, settings: Settings) -> None:
    """Raise SpendCapReached when a call that may cost `worst_usd` would not fit under the cap now (a check, no reservation)."""
    if LEDGER.spent() + LEDGER.reserved() + worst_usd > settings.genai_budget_usd + CAP_TOLERANCE_USD:
        raise SpendCapReached(f"spend cap of ${settings.genai_budget_usd:.2f} reached on this instance (this call could cost up to ${worst_usd:.4f})")


class Spend:
    """One call's reservation, taken before its request leaves: settle() at the billed cost, or fail() when it
    raised, which counts its worst case once it was sent (it may have been billed) and nothing before. Closes once."""

    def __init__(self, worst_usd: float, settings: Settings) -> None:
        self.worst_usd, self.sent = worst_usd, False
        token = LEDGER.reserve(worst_usd, settings.genai_budget_usd)
        if token is None:
            raise SpendCapReached(f"spend cap of ${settings.genai_budget_usd:.2f} reached on this instance (this call could cost up to ${worst_usd:.4f})")
        self._ledger, self._token = LEDGER, token

    def settle(self, actual_usd: float) -> float:
        token, self._token = self._token, None
        return self._ledger.settle(token, actual_usd) if token else self._ledger.spent()

    def fail(self, already_usd: float = 0.0) -> float:
        """`already_usd`: what was billed before the request left (a prefix cache this call made)."""
        return self.settle(max(self.worst_usd, already_usd) if self.sent else already_usd)


@dataclass(frozen=True)
class ModelRole:
    name: str
    id: str
    input_usd_per_m: float
    output_usd_per_m: float
    location: str | None = None   # an endpoint the model needs (the 3.8 TTS Preview is served at "global" only); None: genai_location
    tts_style: str | None = None  # TTS roles: "metadata" (speech_metadata.style, text read verbatim) or "prompt" (style before the text)
    cache_storage_usd_per_m_hour: float = 1.0  # explicit context cache storage, per million cached tokens per hour


@dataclass(frozen=True)
class CallResult:
    text: str
    parsed: Any
    model_id: str
    tokens_in: int
    tokens_out: int
    cost_usd: float
    latency_ms: float
    tokens_cached: int = 0  # of tokens_in, billed at CACHED_INPUT_SHARE of the input price


def load_roles(path: Path) -> dict[str, ModelRole]:
    raw = yaml.safe_load(path.read_text(encoding="utf-8"))
    roles = raw.get("roles") if isinstance(raw, dict) else None
    if not isinstance(roles, dict) or not roles:
        raise ValueError(f"{path}: expected a non-empty 'roles' mapping")
    return {
        name: ModelRole(name=name, id=str(spec["id"]), input_usd_per_m=float(spec["input_usd_per_m"]), output_usd_per_m=float(spec["output_usd_per_m"]),
                        location=spec.get("location"), tts_style=spec.get("tts_style"))
        for name, spec in roles.items()
    }


@lru_cache(maxsize=1)
def roles() -> dict[str, ModelRole]:
    return load_roles(get_settings().models_config_path)


ResolvedBackend = Literal["api_key", "vertex"]


def select_backend(settings: Settings) -> ResolvedBackend:
    """Decide which Gemini backend to use, or raise GenAIDisabled with the reason."""
    if not settings.genai_enabled:
        raise GenAIDisabled("RISK_MW_GENAI_ENABLED is false")
    has_key, has_project = bool(settings.gemini_api_key), bool(settings.project_id)
    if settings.genai_backend == "api_key":
        if not has_key:
            raise GenAIDisabled("RISK_MW_GENAI_BACKEND=api_key but GOOGLE_API_KEY is not set")
        return "api_key"
    if settings.genai_backend == "vertex":
        if not has_project:
            raise GenAIDisabled("RISK_MW_GENAI_BACKEND=vertex but RISK_MW_PROJECT_ID is not set")
        return "vertex"
    if has_key:
        return "api_key"
    if has_project:
        return "vertex"
    raise GenAIDisabled("no GOOGLE_API_KEY and no RISK_MW_PROJECT_ID; Gemini calls are off")


def _client(location: str | None = None):
    """One cached client per backend and location: building one loads credentials, and its first call fetches a token."""
    settings: Settings = get_settings()
    backend = select_backend(settings)
    return _cached_client(backend, settings.project_id, location or settings.genai_location, settings.gemini_api_key)


@lru_cache(maxsize=8)
def _cached_client(backend: str, project_id: str, location: str, api_key: str):
    from google import genai

    if backend == "api_key":
        log.info("gemini backend: developer api (api key)")
        return genai.Client(api_key=api_key)
    log.info("gemini backend: vertex ai project=%s location=%s", project_id, location)
    return genai.Client(vertexai=True, project=project_id, location=location, credentials=_credentials())


@lru_cache(maxsize=1)
def _credentials():
    import google.auth

    credentials, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
    return credentials


def warm_up() -> bool:
    """Build the client and fetch the first access token at start-up, with no model call, so the first live
    scam turn is not the slow one (5.9 s against a 4 s timeout). False when Gemini is off or the warm-up failed."""
    try:
        backend = select_backend(get_settings())
        _client()
        if backend == "vertex":
            from google.auth.transport.requests import Request

            _credentials().refresh(Request())
    except GenAIDisabled:
        return False
    except Exception as exc:  # noqa: BLE001 - a cold first call is better than a service that will not start
        log.warning("gemini warm-up failed: %s", exc)
        return False
    return True


def billed_tokens(usage: Any) -> tuple[int, int]:
    """Input and output tokens as billed; thinking tokens are output tokens."""
    tokens_in = int(getattr(usage, "prompt_token_count", 0) or 0)
    tokens_out = int(getattr(usage, "candidates_token_count", 0) or 0) + int(getattr(usage, "thoughts_token_count", 0) or 0)
    return tokens_in, tokens_out


def cached_tokens(usage: Any) -> int:
    """Input tokens served from the implicit cache (a subset of prompt_token_count); 0 when none are reported."""
    tokens_in = int(getattr(usage, "prompt_token_count", 0) or 0)
    return max(0, min(int(getattr(usage, "cached_content_token_count", 0) or 0), tokens_in))


def cost_usd(role: ModelRole, tokens_in: int, tokens_out: int, tokens_cached: int = 0) -> float:
    """tokens_in includes tokens_cached; those are charged at CACHED_INPUT_SHARE, so a cached prefix is not overstated."""
    cached = max(0, min(tokens_cached, tokens_in))
    input_usd = ((tokens_in - cached) + cached * CACHED_INPUT_SHARE) * role.input_usd_per_m
    return round((input_usd + tokens_out * role.output_usd_per_m) / TOKENS_PER_MILLION, 6)


# Vertex reads X-Server-Timeout as its own deadline and answered 504 DEADLINE_EXCEEDED after about 2.3 s when it was 4,
# on calls that finish in 2-3 s without it. The server gets a generous deadline; the client's timeout still bounds the wait.
SERVER_TIMEOUT_S = 60


def http_options(timeout_s: float) -> Any:
    from google.genai import types

    return types.HttpOptions(timeout=int(timeout_s * 1000), headers={"X-Server-Timeout": str(SERVER_TIMEOUT_S)})


RETRY_CODES = frozenset({429, 500, 503})  # rate limited, a one-off internal error, overloaded: worth one more short try
# The eval's role limiter backs off and meters every 429 itself (a 0.4 s sleep in here would sit inside the turn's measured
# latency, unseen); it sets this to the codes this module may still retry.
RETRY_CODES_VAR: contextvars.ContextVar[frozenset[int]] = contextvars.ContextVar("genai_retry_codes", default=RETRY_CODES)
RETRY_WAITS_S = (0.4, 1.2)
MIN_ATTEMPT_S = 1.0                  # a retry needs this much of the timeout left after its wait


def _generate_with_retry(model_id: str, contents: Any, config: Any, timeout_s: float | None) -> Any:
    """Up to three attempts on 429, 500 or 503, all inside timeout_s: each attempt's HTTP timeout is the time left
    (a fresh full one let a 4 s call take 6.9 s), and a retry is made only while its wait plus MIN_ATTEMPT_S fits."""
    from google.genai import errors, types

    deadline = time.monotonic() + timeout_s if timeout_s else None
    for attempt, wait in enumerate((0.0, *RETRY_WAITS_S)):
        if wait:
            time.sleep(wait)
        if deadline is not None:
            left = round(deadline - time.monotonic(), 3) if attempt else timeout_s
            config = (config or types.GenerateContentConfig()).model_copy(update={"http_options": http_options(left)})
        try:
            return _client().models.generate_content(model=model_id, contents=contents, config=config)
        except errors.APIError as exc:
            next_wait = RETRY_WAITS_S[attempt] if attempt < len(RETRY_WAITS_S) else None
            if exc.code not in RETRY_CODES_VAR.get() or next_wait is None:
                raise
            if deadline is not None and deadline - time.monotonic() < next_wait + MIN_ATTEMPT_S:
                raise
            log.warning("gemini %s, retrying after %.1f s", exc.code, next_wait)
    raise AssertionError("unreachable")


# --- the long system prefix as explicit cached content ------------------------------------------------------------------

PREFIX_CACHE_MIN_CHARS = 8000  # about 2k tokens or more; a shorter system prompt is sent inline
PREFIX_CACHE_RENEW_S = 120     # made again this long before its TTL ends, so no read meets an expired cache
PREFIX_CACHE_RETRY_S = 600     # after a failed create, reads go inline for this long before the next try


@dataclass(frozen=True)
class _PrefixCache:
    name: str
    expires_at: float


_PREFIX_CACHES: dict[tuple[str, str], _PrefixCache | float] = {}  # (model id, prefix sha1) -> the cache, or when to try again
_PREFIX_LOCK = threading.Lock()


def forget_prefix_caches() -> None:
    with _PREFIX_LOCK:
        _PREFIX_CACHES.clear()


def _prefix_key(role: ModelRole, system: str) -> tuple[str, str]:
    return role.id, hashlib.sha1(system.encode()).hexdigest()


def _prefix_fresh(entry: _PrefixCache | float | None, now: float) -> bool:
    return isinstance(entry, _PrefixCache) and entry.expires_at - PREFIX_CACHE_RENEW_S > now


def prefix_storage_worst_usd(role: ModelRole, system: str | None, settings: Settings) -> float:
    """The most prefix_cache can charge this read: the storage of a cache it would make now (one token a byte, for the
    whole TTL); 0.0 when it would make none (short prompt, setting off, a fresh cache, or inline after a failed create)."""
    if not system or not settings.genai_prefix_cache or len(system) < PREFIX_CACHE_MIN_CHARS:
        return 0.0
    with _PREFIX_LOCK:
        entry, now = _PREFIX_CACHES.get(_prefix_key(role, system)), time.time()
        if _prefix_fresh(entry, now) or (isinstance(entry, float) and entry > now):
            return 0.0
    ttl = settings.genai_prefix_cache_ttl_s
    return _utf8_bytes(system) * ttl / 3600 * role.cache_storage_usd_per_m_hour / TOKENS_PER_MILLION


def prefix_cache(role: ModelRole, system: str | None, settings: Settings) -> tuple[str | None, float]:
    """(the cached content holding `system`, the storage cost to charge now). The cache is made once per model and prefix and
    lives genai_prefix_cache_ttl_s; the read that makes it carries its storage for that whole time. (None, 0.0) for a short
    prompt, with the setting off, or after a failed create (logged; reads go inline for PREFIX_CACHE_RETRY_S)."""
    if not system or not settings.genai_prefix_cache or len(system) < PREFIX_CACHE_MIN_CHARS:
        return None, 0.0
    key, ttl = _prefix_key(role, system), settings.genai_prefix_cache_ttl_s
    with _PREFIX_LOCK:  # held across the create, so parallel first reads make one cache, not one each
        entry, now = _PREFIX_CACHES.get(key), time.time()
        if _prefix_fresh(entry, now):
            return entry.name, 0.0
        if isinstance(entry, float) and entry > now:
            return None, 0.0
        from google.genai import types

        try:
            made = _client().caches.create(model=role.id, config=types.CreateCachedContentConfig(
                system_instruction=system, ttl=f"{ttl}s", display_name=f"risk-mw-{key[1][:12]}"))
        except Exception as exc:  # noqa: BLE001 - a read without the cache still works, at the uncached price
            log.warning("prefix cache not made for %s: %s", role.id, exc.__class__.__name__)
            _PREFIX_CACHES[key] = now + PREFIX_CACHE_RETRY_S
            return None, 0.0
        tokens = int(getattr(getattr(made, "usage_metadata", None), "total_token_count", 0) or 0) or len(system) // 3
        _PREFIX_CACHES[key] = _PrefixCache(made.name, now + ttl)
        log.info(json.dumps({"task": "prefix_cache", "model_id": role.id, "cache": made.name, "tokens": tokens, "ttl_s": ttl}))
        return made.name, round(tokens * ttl / 3600 * role.cache_storage_usd_per_m_hour / TOKENS_PER_MILLION, 6)


def _forget_prefix(role: ModelRole, system: str) -> None:
    with _PREFIX_LOCK:
        _PREFIX_CACHES.pop(_prefix_key(role, system), None)


def cache_gone(exc: Exception) -> bool:
    """Vertex answered that the cached content does not exist (expired early or deleted)."""
    return getattr(exc, "code", None) in (400, 403, 404) and "cache" in str(exc).lower()


def generate_with_prefix(role: ModelRole, contents: Any, config: Any, system: str | None, cached: str | None,
                         timeout_s: float | None) -> Any:
    """One generate call with the prefix in its cache (or inline); a cache that is gone is forgotten and the read goes inline."""
    try:
        return _generate_with_retry(role.id, contents, config, timeout_s)
    except Exception as exc:
        if not cached or not cache_gone(exc):
            raise
        log.warning("prefix cache %s is gone; reading inline", cached)
        _forget_prefix(role, system or "")
        return _generate_with_retry(role.id, contents, config.model_copy(update={"cached_content": None, "system_instruction": system}),
                                    timeout_s)


def _utf8_bytes(text: str) -> int:
    return len(text.encode("utf-8"))


def _input_bytes(contents: Any) -> int:
    """Bytes of what a call sends: text as UTF-8, inline data (audio) as itself, and the SDK's Content, Part and lists
    walked (the detector sends a Content of one part per turn; speech sends audio bytes)."""
    if contents is None:
        return 0
    if isinstance(contents, str):
        return _utf8_bytes(contents)
    if isinstance(contents, bytes | bytearray):
        return len(contents)
    if isinstance(contents, list | tuple):
        return sum(_input_bytes(c) for c in contents)
    if isinstance(contents, dict):
        return _utf8_bytes(json.dumps(contents, ensure_ascii=False, default=str))
    parts = getattr(contents, "parts", None)
    if parts is not None:  # a types.Content
        return _input_bytes(list(parts))
    text, inline = getattr(contents, "text", None), getattr(contents, "inline_data", None)
    if text is not None or inline is not None:  # a types.Part
        return _input_bytes(text) + _input_bytes(getattr(inline, "data", None))
    dump = getattr(contents, "model_dump_json", None)
    return _utf8_bytes(dump()) if dump else _utf8_bytes(str(contents))


def _schema_bytes(schema: type[BaseModel] | dict | None) -> int:
    if schema is None:
        return 0
    return _utf8_bytes(json.dumps(schema if isinstance(schema, dict) else schema.model_json_schema()))


def worst_case_usd(role: ModelRole, contents: Any, system: str | None, schema: type[BaseModel] | dict | None, max_output_tokens: int) -> float:
    """The most a call can cost: every byte of the prompt (response schema included) counted as a token, which bounds
    even a byte-fallback tokenizer on Bangla (three bytes a letter) and on audio, plus the whole output allowance."""
    input_tokens = _input_bytes(contents) + _utf8_bytes(system or "") + _schema_bytes(schema)
    return (input_tokens * role.input_usd_per_m + max_output_tokens * role.output_usd_per_m) / TOKENS_PER_MILLION


def warm_client() -> None:
    """Build the client (and, on Vertex, resolve Application Default Credentials) without calling a model."""
    _client()


def reserved_read(task: str, role_name: str, contents: Any, schema: type[T] | dict | None = None, system: str | None = None,
                  timeout_s: float | None = None, thinking_level: str | None = None, max_output_tokens: int | None = None,
                  include_thoughts: bool = False) -> tuple[Any, CallResult]:
    """One generate call inside its reservation: (the raw response, its CallResult). call() and v4's second read use it.

    The reservation is the prompt's worst case (worst_case_usd), the whole output allowance and the storage of a prefix
    cache this read may make. A call that fails before the request leaves (no client) pays only what it already caused
    (a cache it made); one that fails after it was sent may still be billed, so it counts at its worst case.
    """
    settings = get_settings()
    select_backend(settings)
    from google.genai import types

    role = roles()[role_name]
    output_cap = max_output_tokens or settings.genai_max_output_tokens
    spend = Spend(worst_case_usd(role, contents, system, schema, output_cap) + prefix_storage_worst_usd(role, system, settings), settings)
    storage_usd = 0.0
    try:
        _client()  # no client, no request: nothing below this line has left the process yet
        cached, storage_usd = prefix_cache(role, system, settings)
        level = types.ThinkingLevel(thinking_level.upper()) if thinking_level else None
        config = types.GenerateContentConfig(
            system_instruction=None if cached else system,
            cached_content=cached,
            response_mime_type="application/json" if schema else None,
            response_schema=schema,
            http_options=http_options(timeout_s) if timeout_s else None,
            thinking_config=types.ThinkingConfig(thinking_level=level, include_thoughts=True) if include_thoughts
            else (types.ThinkingConfig(thinking_level=level) if level else None),
            max_output_tokens=output_cap,
        )
        started, spend.sent = time.perf_counter(), True
        response = generate_with_prefix(role, contents, config, system, cached, timeout_s)
        tokens_in, tokens_out = billed_tokens(response.usage_metadata)
        tokens_cached = cached_tokens(response.usage_metadata)
    except BaseException:
        spend.fail(storage_usd)
        raise
    latency_ms = (time.perf_counter() - started) * 1000
    result = CallResult(
        text=response.text or "",
        parsed=response.parsed if schema else None,
        model_id=role.id,
        tokens_in=tokens_in,
        tokens_out=tokens_out,
        cost_usd=round(cost_usd(role, tokens_in, tokens_out, tokens_cached) + storage_usd, 6),
        latency_ms=round(latency_ms, 1),
        tokens_cached=tokens_cached,
    )
    spent = spend.settle(result.cost_usd)
    candidates = getattr(response, "candidates", None) or []
    finish = str(getattr(candidates[0], "finish_reason", "") or "") if candidates else ""
    log.info(json.dumps({"task": task, "model_id": role.id, "tokens_in": tokens_in, "tokens_out": tokens_out, "tokens_cached": tokens_cached,
                         "cost_usd": result.cost_usd, "reserved_usd": round(spend.worst_usd, 6), "latency_ms": result.latency_ms,
                         "spent_usd": round(spent, 6), "finish_reason": finish}))
    return response, result


def call(task: str, role_name: str, contents: Any, schema: type[T] | dict | None = None, system: str | None = None,
         timeout_s: float | None = None, thinking_level: str | None = None, max_output_tokens: int | None = None) -> CallResult:
    """Run one structured Gemini call. Raises GenAIDisabled when no backend is configured, and SpendCapReached (a
    GenAIDisabled) when the call's worst case would pass the spend cap (see reserved_read).

    `thinking_level` ("minimal" | "low" | "medium" | "high") is the Gemini 3.x knob; Flash-Lite accepts "minimal",
    3.8 Flash does not. `timeout_s` bounds the whole call, retries included. `max_output_tokens` caps the output side
    (thinking tokens count against it too, so never set it under a few hundred); left out, RISK_MW_GENAI_MAX_OUTPUT_TOKENS
    applies, so every call has a bounded worst case to reserve.
    """
    return reserved_read(task, role_name, contents, schema, system, timeout_s, thinking_level, max_output_tokens)[1]
