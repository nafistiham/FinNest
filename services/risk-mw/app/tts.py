"""Live Gemini TTS for Apa (spec US-3 S2, FR-4, section 6 TTS; P0 item 8: two engines, one voice).

speak() streams 24 kHz mono 16-bit PCM from the first engine that is served: the `tts` role in config/models.yaml, then
`tts_fallback`, both in the same voice with the same urgent style. An engine that answers "model not found" (404, or a 400
naming the model) moves the call to the other one and is skipped for the rest of the process, because a Preview model can
vanish and a 2.5 model can retire mid-judging. Each engine streams first and falls back to one generate_content call when
it refuses to stream. Anything that stops it raises before the first chunk: RateLimited on a 429, so the caller drops to
the next rung at once, or Unavailable (off, over the spend cap, no engine served, failing). The route speaks only text
/v1/apa/intervene or /v1/apa/why signed (app.apa.verify_why); speakable() then checks Apa's rules once more.

Spend: every call reserves RESERVE_USD against an in-process cap (RISK_MW_TTS_BUDGET_USD, per instance, reset on restart)
and records its billed cost, at the prices of the engine that spoke, after.

Quota: a few requests a minute per model. Each engine is paced on its own (tts_requests_per_min, tts_fallback_requests_per_min,
counted here), so a request that would
be refused is never sent: an engine at its pace is skipped for the other one, in the same voice. A 429 or a 500/503 before
any audio moves the same text to the other engine, and an engine that answered 429 rests for RATE_LIMIT_QUIET_S.
RateLimited means both engines are spent; the phone then plays its own pre-rendered Gemini clip. Finished audio is kept in
a small LRU cache, because the same warning repeats.
"""

from __future__ import annotations

import json
import logging
import re
import struct
import threading
import time
import unicodedata
from collections import OrderedDict, deque
from collections.abc import Iterator
from dataclasses import dataclass, field
from typing import Any

from app import apa, genai_client
from app.settings import Settings

log = logging.getLogger(__name__)

# The agreed delivery, copied from scripts/render_apa_audio.py STYLES["urgent"] so live and pre-rendered Apa sound alike.
URGENT_STYLE = ("Say this urgently, at a quick, natural Dhaka speaking pace, like a protective older sister who has just caught "
                "her younger sister about to be cheated on a phone call. Alert, clear and serious, stressing the warning words, "
                "no long pauses and not panicked: ")
ENGINE_ROLES = ("tts", "tts_fallback")  # primary first; scripts/tts_engine_smoke.py and a native ear decide which is which
RATE, CHANNELS, SAMPLE_BYTES = 24000, 1, 2
RESERVE_USD = 0.01             # worst case for a 240-character line (about 20 s of audio at 25 audio tokens a second)
RATE_LIMIT_QUIET_S = 20.0
PACE_WINDOW_S = 60.0           # tts_requests_per_min counts requests in this sliding window, per engine
RETRY_ON_OTHER_ENGINE = frozenset({429, 500, 503})  # before any audio: the other engine (its own quota) speaks instead
STREAM_REFUSED = frozenset({400, 404, 405, 501})
UNKNOWN_LENGTH = 0xFFFFFFFF    # the usual RIFF and data size for a WAV whose length is not known when the header goes out
MIN_BANGLA_SHARE = 0.7         # of letters: room for an "OTP" or a "PIN", none for an English script


class Unavailable(RuntimeError):
    """No live audio for this line; the caller keeps what it already has."""


class RateLimited(Unavailable):
    """A 429: drop to the next rung now (nothing here waits or retries). `quota` is the quota the 429 named, if any."""

    def __init__(self, message: str, quota: str | None = None) -> None:
        super().__init__(message)
        self.quota = quota


# --- what Apa may say --------------------------------------------------------------------------------


def _is_bangla(ch: str) -> bool:
    return unicodedata.name(ch, "").startswith("BENGALI ")


def speakable(text: str, max_chars: int = apa.WHY_MAX_CHARS) -> bool:
    """Apa's own rules for explanations (app.apa), plus: it must be Bangla, so the endpoint is not a general voice.
    `max_chars` is apa.WARNING_MAX_CHARS for a whole warning, spoken in one request."""
    if not text.strip() or len(text) > max_chars:
        return False
    if any(p.search(text) for p in (apa.DIGITS, apa.IDS, apa.DURATION_WORDS, apa.TIP_OFF_WORDS)) or any(ch.isdigit() for ch in text):
        return False  # isdigit: digits of any script, not only the Latin and Bangla ones apa.DIGITS knows
    letters = [ch for ch in text if ch.isalpha() or unicodedata.category(ch).startswith("M")]  # Bangla vowel signs are marks
    return bool(letters) and sum(map(_is_bangla, letters)) / len(letters) >= MIN_BANGLA_SHARE


# --- spend, cache, back-off --------------------------------------------------------------------------


@dataclass
class SpendCap:
    """Per-instance spend: reserve the worst case before a call, settle with the billed cost after."""

    spent_usd: float = 0.0
    held_usd: float = 0.0
    calls: int = 0
    _lock: threading.Lock = field(default_factory=threading.Lock, repr=False)

    def reserve(self, usd: float, cap_usd: float) -> None:
        with self._lock:
            if self.spent_usd + self.held_usd + usd > cap_usd:
                raise Unavailable(f"tts spend cap reached: ${self.spent_usd:.4f} spent of ${cap_usd:.2f}")
            self.held_usd += usd

    def settle(self, reserved: float, cost: float) -> None:
        with self._lock:
            self.held_usd = round(max(0.0, self.held_usd - reserved), 6)
            self.spent_usd = round(self.spent_usd + cost, 6)
            if cost:
                self.calls += 1  # billed calls


class AudioCache:
    def __init__(self) -> None:
        self._items: OrderedDict[tuple[str, str], bytes] = OrderedDict()
        self._lock = threading.Lock()

    def get(self, key: tuple[str, str]) -> bytes | None:
        with self._lock:
            if key in self._items:
                self._items.move_to_end(key)
            return self._items.get(key)

    def put(self, key: tuple[str, str], pcm: bytes, max_items: int) -> None:
        with self._lock:
            self._items[key] = pcm
            self._items.move_to_end(key)
            while len(self._items) > max(0, max_items):
                self._items.popitem(last=False)


@dataclass
class _Backend:
    quiet: dict[str, float] = field(default_factory=dict)  # engine id -> clock time before which it is not called (after a 429)
    quota: str | None = None       # what the last 429 named
    sent_at: dict[str, deque] = field(default_factory=dict)  # engine id -> when its requests in the pace window were sent
    lock: threading.Lock = field(default_factory=threading.Lock, repr=False)
    stream_refused: set[str] = field(default_factory=set)  # models that refused a stream while a single call worked
    missing: set[str] = field(default_factory=set)         # models that answered "not found": skipped for the process


LEDGER, CACHE, _backend = SpendCap(), AudioCache(), _Backend()
_clock = time.monotonic  # one clock for rest and pace (tests move it)


def pace(engine: genai_client.ModelRole, settings: Settings) -> int:
    """Requests a minute this engine may be sent: each model has its own quota."""
    return settings.tts_fallback_requests_per_min if engine.name == "tts_fallback" else settings.tts_requests_per_min


def _admit(engine: genai_client.ModelRole, settings: Settings) -> bool:
    """True, and counted, when this engine has room under its pace for one more request now; False, and nothing sent, when not."""
    engine_id, now = engine.id, _clock()
    with _backend.lock:
        if _backend.quiet.get(engine_id, 0.0) > now:
            return False
        sent = _backend.sent_at.setdefault(engine_id, deque())
        while sent and sent[0] <= now - PACE_WINDOW_S:
            sent.popleft()
        if len(sent) >= pace(engine, settings):
            return False
        sent.append(now)
        return True


def reserve_usd(text_bn: str) -> float:
    """RESERVE_USD for each started 240 characters: a whole warning reserves as much as the lines it joins."""
    return RESERVE_USD * max(1, -(-len(text_bn) // 240))


def reset() -> None:
    """Forget spend, cached audio, back-off and missing engines (tests)."""
    global LEDGER, CACHE, _backend
    LEDGER, CACHE, _backend = SpendCap(), AudioCache(), _Backend()


# --- the engines -------------------------------------------------------------------------------------


def engines() -> tuple[genai_client.ModelRole, ...]:
    """The configured TTS engines, primary first; a fallback that is absent or the same model leaves one."""
    roles, found = genai_client.roles(), []
    for name in ENGINE_ROLES:
        role = roles.get(name)
        if role is not None and all(role.id != other.id for other in found):
            found.append(role)
    return tuple(found)


def model_missing(exc: Any, model_id: str) -> bool:
    """404, or a 400 that names the model: this engine is not served here (retired, not enabled, or the wrong endpoint)."""
    return exc.code == 404 or (exc.code == 400 and model_id in str(exc))


def quota_name(exc: Any) -> str | None:
    """The quota a 429 names (its QuotaFailure detail, else the message), so the right increase can be asked for."""
    error = exc.details.get("error") if isinstance(exc.details, dict) else None
    for detail in (error.get("details") if isinstance(error, dict) else None) or ():
        for violation in (detail.get("violations") if isinstance(detail, dict) else None) or ():
            name = violation.get("quotaMetric") or violation.get("quotaId") if isinstance(violation, dict) else None
            if name:
                return str(name)
    found = re.search(r"[\w.-]+\.googleapis\.com/\w+", exc.message or "")
    return found.group(0) if found else None


# The style mode belongs to the model, not to the role it is configured under: swapping the two role blocks must never
# make a verbatim engine read the English direction aloud. Only the Gemini 2.x TTS models take it before the text; any
# other model, including one not known here, gets it in speech_metadata (fail closed: nothing extra is spoken).
PROMPT_STYLE_MODELS = re.compile(r"^gemini-2\.")


def contents(model_id: str, text_bn: str, style: str = URGENT_STYLE) -> Any:
    """What to send for one line. An engine marked `tts_style: metadata` (3.8 TTS) reads its text as a verbatim transcript,
    so the delivery goes in speech_metadata.style, where it cannot be read aloud; the others take it before the text, as
    the pre-rendered clips were made."""
    if PROMPT_STYLE_MODELS.match(model_id):
        return style + text_bn
    from google.genai import types

    part = types.Part(text=text_bn, speech_metadata=types.SpeechMetadata(style=style.rstrip(": ")))
    return [types.Content(role="user", parts=[part])]


# --- the model call ----------------------------------------------------------------------------------


def _stream(engine: genai_client.ModelRole, body: Any, config: Any) -> Iterator[Any]:
    return genai_client._client(engine.location).models.generate_content_stream(model=engine.id, contents=body, config=config)


def _once(engine: genai_client.ModelRole, body: Any, config: Any) -> Any:
    return genai_client._client(engine.location).models.generate_content(model=engine.id, contents=body, config=config)


def _config(settings: Settings) -> Any:
    from google.genai import types

    voice = types.VoiceConfig(prebuilt_voice_config=types.PrebuiltVoiceConfig(voice_name=settings.tts_voice))
    return types.GenerateContentConfig(response_modalities=["AUDIO"], speech_config=types.SpeechConfig(voice_config=voice),
                                       http_options=genai_client.http_options(settings.tts_timeout_s))


def _responses(engine: genai_client.ModelRole, body: Any, config: Any) -> Iterator[Any]:
    """Gemini's streamed responses, or one whole response when this engine refuses to stream."""
    from google.genai import errors

    if engine.id not in _backend.stream_refused:
        started = False
        try:
            for response in _stream(engine, body, config):
                started = True
                yield response
            return
        except errors.APIError as exc:
            if started or exc.code not in STREAM_REFUSED:
                raise
            # a refused stream and a missing model can both answer 400 or 404 here; the single call tells them apart
            log.warning("tts stream refused by %s (%s); one generate_content call instead", engine.id, exc.code)
    response = _once(engine, body, config)
    _backend.stream_refused.add(engine.id)
    yield response


def streams(model_id: str) -> bool:
    """False once this engine has refused a stream in this process; it is then asked for one whole response."""
    return model_id not in _backend.stream_refused


def responses(engine: genai_client.ModelRole, text_bn: str, settings: Settings) -> Iterator[Any]:
    """One engine's responses for text_bn in Apa's voice and urgent style, streamed or whole. No fallback, cap or cache:
    speak() adds those, and scripts/tts_engine_smoke.py times each engine on its own."""
    return _responses(engine, contents(engine.id, text_bn), _config(settings))


def audio(response: Any) -> Iterator[bytes]:
    """The PCM in one response."""
    for candidate in getattr(response, "candidates", None) or ():
        content = getattr(candidate, "content", None)
        for part in getattr(content, "parts", None) or ():
            blob = getattr(part, "inline_data", None)
            if blob is not None and blob.data:
                yield blob.data


def speak(text_bn: str, settings: Settings) -> Iterator[bytes]:
    """Stream PCM for text_bn from the first engine that is served and has room under its pace. Raises before any audio:
    RateLimited when both engines are spent (at their pace, resting after a 429, or answering 429 now), Unavailable when TTS
    is off, over the cap, without a served engine or failing."""
    from google.genai import errors

    if not settings.tts_enabled:
        raise Unavailable("RISK_MW_TTS_ENABLED is false")
    try:
        genai_client.select_backend(settings)
    except genai_client.GenAIDisabled as exc:
        raise Unavailable(str(exc)) from exc
    order = [engine for engine in engines() if engine.id not in _backend.missing]
    if not order:
        raise Unavailable(f"no tts engine is served here ({', '.join(sorted(_backend.missing))} not found)")
    ledger, reserved = LEDGER, reserve_usd(text_bn)
    ledger.reserve(reserved, settings.tts_budget_usd)
    charged, usage, sent, first_ms, started = reserved, None, 0, None, time.perf_counter()
    engine, answered, spent, failure = order[0], None, [], None  # spent: engines that had no room or said 429
    try:
        for engine in order:
            if not _admit(engine, settings):
                spent.append(engine.id)
                log.info(json.dumps({"task": "apa_why_tts", "model_id": engine.id, "paced": True}))
                continue
            try:
                for response in responses(engine, text_bn, settings):
                    answered, usage = engine, getattr(response, "usage_metadata", None) or usage
                    for pcm in audio(response):
                        first_ms = first_ms if first_ms is not None else (time.perf_counter() - started) * 1000
                        sent += len(pcm)
                        yield pcm
                break
            except errors.APIError as exc:
                if answered is not None:
                    raise
                if exc.code == 429:
                    _backend.quiet[engine.id], _backend.quota = _clock() + RATE_LIMIT_QUIET_S, quota_name(exc)
                    spent.append(engine.id)
                    log.warning(json.dumps({"task": "apa_why_tts", "model_id": engine.id, "error": 429, "quota": _backend.quota}))
                    continue
                if exc.code in RETRY_ON_OTHER_ENGINE:
                    failure = f"gemini tts {exc.code} on {engine.id}"
                    log.warning("tts engine %s answered %s; the other engine speaks this one", engine.id, exc.code)
                    continue
                if not model_missing(exc, engine.id):
                    raise
                _backend.missing.add(engine.id)
                log.warning("tts engine %s answered %s: not served, so the other engine speaks for the rest of this process",
                            engine.id, exc.code)
        if answered is None:
            charged = 0.0  # nothing came back: not billed
            if spent:
                raise RateLimited(f"tts spent on {', '.join(spent)}; the phone plays its own clip", _backend.quota)
            if failure:
                raise Unavailable(failure)
            if all(e.id in _backend.missing for e in order):
                raise Unavailable(f"no tts engine is served here ({', '.join(sorted(_backend.missing))} not found)")
            raise Unavailable(f"tts returned no audio from {engine.id}")  # served, but an empty stream: not an availability problem
        tokens_in, tokens_out = genai_client.billed_tokens(usage) if usage is not None else (0, 0)
        if tokens_in or tokens_out:  # no usage reported: the reserve stays charged
            charged = genai_client.cost_usd(answered, tokens_in, tokens_out)
        log.info(json.dumps({"task": "apa_why_tts", "engine": answered.name, "model_id": answered.id, "tokens_in": tokens_in,
                             "tokens_out": tokens_out, "cost_usd": charged, "first_audio_ms": round(first_ms or 0.0, 1),
                             "latency_ms": round((time.perf_counter() - started) * 1000, 1), "audio_s": round(sent / (RATE * SAMPLE_BYTES), 2),
                             "streamed": streams(answered.id)}))
        if not sent:
            raise Unavailable("tts returned no audio")
    except errors.APIError as exc:
        if not sent:
            charged = 0.0  # refused before any audio: not billed
        raise Unavailable(f"gemini tts {exc.code} on {engine.id}") from exc
    except Unavailable:
        raise
    except Exception as exc:  # timeouts and dropped connections: the server may still bill, so the reserve stays charged
        raise Unavailable(f"gemini tts failed: {exc.__class__.__name__}") from exc
    finally:
        ledger.settle(reserved, charged)


# --- what the route streams --------------------------------------------------------------------------


def wav_header(data_bytes: int | None = None) -> bytes:
    """A 44-byte PCM WAV header; without a length it uses UNKNOWN_LENGTH, as a live stream must."""
    data_size = UNKNOWN_LENGTH if data_bytes is None else data_bytes
    riff_size = UNKNOWN_LENGTH if data_bytes is None else 36 + data_bytes
    return struct.pack("<4sI4s4sIHHIIHH4sI", b"RIFF", riff_size, b"WAVE", b"fmt ", 16, 1, CHANNELS, RATE,
                       RATE * CHANNELS * SAMPLE_BYTES, CHANNELS * SAMPLE_BYTES, SAMPLE_BYTES * 8, b"data", data_size)


@dataclass(frozen=True)
class Audio:
    """One line's PCM: `first` is already in hand, so a caller can still answer 204 before it; `rest` streams the remainder."""

    first: bytes
    rest: Iterator[bytes]
    total_bytes: int | None  # known on a cache hit
    cached: bool


def _spoken_and_cached(key: tuple[str, str], text_bn: str, settings: Settings) -> Iterator[bytes]:
    parts: list[bytes] = []
    for pcm in speak(text_bn, settings):
        parts.append(pcm)
        yield pcm
    CACHE.put(key, b"".join(parts), settings.tts_cache_size)  # only a stream that finished is kept


def say(text_bn: str, settings: Settings) -> Audio:
    """Apa's audio for text_bn, from the cache or live. Raises Unavailable (or RateLimited) when there is none; check
    speakable() first."""
    key = (settings.tts_voice, text_bn)
    hit = CACHE.get(key)
    if hit is not None:
        return Audio(first=hit, rest=iter(()), total_bytes=len(hit), cached=True)
    chunks = _spoken_and_cached(key, text_bn, settings)
    return Audio(first=next(chunks), rest=chunks, total_bytes=None, cached=False)
