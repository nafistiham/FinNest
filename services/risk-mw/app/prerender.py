"""Apa's warning, written and rendered before the hold needs it (server side).

A cold warning cannot start in 300 ms: Flash-Lite needs about a second for line A and TTS about another before the first
sample. The evidence that triggers a hold builds up over several turns, so the warning is written ahead of it:
- C0, the call-start pair: when a call from a caller not in contacts starts, an A+X pair (attention, action; no tactic yet).
- C1, the speculative refresh: once the call's risk reaches pre-arm (below the hold) and the ledger's hash changes, the warning
  is written again from the ledger, debounced and capped per call, and only lines whose text changed are rendered again.
- C2, the cold path at the hold, when nothing fresh is ready: lines go out as each one validates and is rendered.
Speculation is silent (nothing plays before the hold), so it tells a listening caller nothing.

The words come only from the composer (app.warnings: plan, generate) and the voice only from app.tts (speak); both belong to
other builders and are looked up at call time. There is no recorded line and no cross-call cache: a clip belongs to one call
of one account. Documents are Firestore-safe and bounded: apa_warnings/{key} keeps the latest warning (at most four lines) and
the call's counters, apa_clips/{clip_id} one clip under CLIP_MAX_BYTES.
"""

from __future__ import annotations

import contextvars
import hashlib
import importlib
import io
import json
import logging
import re
import secrets
import queue
import struct
import threading
import time
from collections.abc import Iterable, Iterator, Mapping, Sequence
from dataclasses import dataclass, field, replace
from datetime import UTC, datetime, timedelta
from typing import Any, Literal, get_args

from app.contracts import ApaLine, ApaWarning, HoldWarning, TxnType
from app.ledger import Ledger
from app.settings import Settings
from app.state import get_many, store, transaction

log = logging.getLogger(__name__)

WARNINGS, CLIPS = "apa_warnings", "apa_clips"
ROLES = ("A", "T", "R", "X")
PAIR = ("A", "X")              # C0: attention and action; there is no tactic to name yet
CALL_START_BAND = "possible"   # the lowest certainty band: C0 is written before there is any evidence
CLIP_MAX_BYTES = 700_000       # under Firestore's 1 MiB document; an Opus sentence is about 10-20 KB, WAV about 48 KB a second
CLIP_TTL_S = 6 * 3600          # expire_at on each clip, for a Firestore TTL policy; clip() refuses an expired one as well
PENDING_S = 30.0               # a claimed generation that has not finished by then no longer blocks the same evidence
PCM_RATE = 24000               # what tts.speak yields: 24 kHz mono 16-bit PCM
CLIP_ID = re.compile(r"[A-Za-z0-9_-]{16,64}")

Stage = Literal["C0", "C1", "C2"]
STAGES = ("C0", "C1", "C2")


@dataclass(frozen=True)
class PreparedLine:
    role: str
    text_bn: str
    text_en: str
    clip_id: str | None
    speak_on_device: bool


@dataclass(frozen=True)
class PreparedWarning:
    warning_id: str
    session_id: str
    ledger_hash: str
    stage: Stage
    lines: tuple[PreparedLine, ...]
    created_at: float
    gen_ms: float
    render_ms: dict[str, float] = field(default_factory=dict)

    def to_doc(self) -> dict[str, Any]:
        """Firestore-safe: the lines are a list of maps, render_ms a map of numbers."""
        return {"warning_id": self.warning_id, "session_id": self.session_id, "ledger_hash": self.ledger_hash, "stage": self.stage,
                "lines": [{"role": l.role, "text_bn": l.text_bn, "text_en": l.text_en, "clip_id": l.clip_id,
                           "speak_on_device": l.speak_on_device} for l in self.lines],
                "created_at": self.created_at, "gen_ms": self.gen_ms, "render_ms": dict(self.render_ms)}

    @classmethod
    def from_doc(cls, doc: Mapping[str, Any] | None) -> PreparedWarning | None:
        if not doc or not doc.get("lines"):
            return None
        try:
            lines = tuple(PreparedLine(str(l["role"]), str(l["text_bn"]), str(l.get("text_en", "")), l.get("clip_id"),
                                       bool(l.get("speak_on_device"))) for l in doc["lines"])
            if doc["stage"] not in STAGES or any(l.role not in ROLES for l in lines):
                raise ValueError("unknown stage or role")
            return cls(str(doc["warning_id"]), str(doc["session_id"]), str(doc["ledger_hash"]), doc["stage"], lines,
                       float(doc.get("created_at", 0.0)), float(doc.get("gen_ms", 0.0)),
                       {str(k): float(v) for k, v in (doc.get("render_ms") or {}).items()})
        except (KeyError, TypeError, ValueError) as exc:
            log.warning("unreadable prepared warning: %s", exc.__class__.__name__)
            return None

    def contract(self) -> ApaWarning:
        return ApaWarning(warning_id=self.warning_id, session_id=self.session_id, ledger_hash=self.ledger_hash, stage=self.stage,
                          lines=tuple(ApaLine(role=l.role, text_bn=l.text_bn, text_en=l.text_en, clip_id=l.clip_id,
                                              speak_on_device=l.speak_on_device) for l in self.lines),
                          created_at=self.created_at, gen_ms=self.gen_ms, render_ms=self.render_ms)


def doc_key(session_id: str, uid: str | None = None) -> tuple[str, str]:
    """Where a call's warning lives. The session id is the client's own, so the key binds it to the account (as
    scam.session_keys does) and hashes both, which also keeps a '/' in a session id out of a Firestore path."""
    return WARNINGS, hashlib.sha256(f"{uid or ''}\x00{session_id}".encode()).hexdigest()[:40]


def _module(name: str) -> Any:
    """Another builder's module (app.warnings, app.tts, app.scam), looked up at call time, so a late merge or a test fake wins."""
    return importlib.import_module(f"app.{name}")


def _composer_and_voice() -> Any:
    """app.warnings, after checking app.tts is there too: both must exist before a generation is claimed."""
    _module("tts")
    return _module("warnings")

TXN_TYPES = get_args(TxnType)


# --- the call's evidence ---------------------------------------------------------------------------------------------


def session_state_of(doc: Mapping[str, Any]) -> Any:
    """The call's ledger, risk and band from its scam_sessions document, read by the detector (one reader, so the hold and
    the pre-render hash the same band)."""
    return _module("scam").session_state_of(dict(doc or {}))


def session_state(session_id: str, uid: str | None = None) -> Any:
    scam = _module("scam")
    return session_state_of(scam.own_session(get_many(scam.session_keys(session_id, uid)), uid))


def hold_hash(scam_doc: Mapping[str, Any] | None, pending_action: str | None) -> str:
    """The hash the hold compares with the prepared warning's: the call's ledger, the held action and the certainty band."""
    view = session_state_of(scam_doc or {})
    return _module("warnings").key(view.ledger, pending_action, view.band)


def _caller_words(ledger: Ledger, given: Sequence[Any] | None) -> tuple[Any, ...]:
    """What the composer checks its lines against: the caller turns the caller of prerender passed, else the caller's own
    words the ledger verified (its quotes)."""
    return tuple(given) if given else tuple(e.quote for e in ledger.tactics.values())


# --- claims: one generation at a time per call, debounced and capped ---------------------------------------------------


def _claim(key: tuple[str, str], uid: str | None, session_id: str, stage: Stage, ledger_hash: str, now: float,
           settings: Settings) -> tuple[int, PreparedWarning | None] | None:
    """Reserve a generation for this call, atomically, or None when it is not due. C0 once per call; C1 only for evidence
    not already written or being written, after the debounce and under the cap; C2 (the hold) always."""
    def body(tx):
        doc = tx.get(*key)
        prepared = PreparedWarning.from_doc(doc.get("warning"))
        last = float(doc.get("last_gen_at", float("-inf")))
        pending = doc.get("pending_hash") if now - last < PENDING_S else None
        refreshes = int(doc.get("refreshes", 0))
        if stage == "C0" and doc.get("seq"):
            return None
        if stage == "C1" and (ledger_hash in (prepared.ledger_hash if prepared else None, pending)
                              or now - last < settings.prearm_debounce_s or refreshes >= settings.prearm_max_per_call):
            return None
        seq = int(doc.get("seq", 0)) + 1
        tx.set(*key, {**doc, "uid": uid, "session_id": session_id, "seq": seq, "pending_hash": ledger_hash, "last_gen_at": now,
                      "refreshes": refreshes + (stage == "C1"), "updated_at": time.time()})
        return seq, prepared

    return transaction(body)


def _release(key: tuple[str, str], seq: int) -> None:
    """A generation that kept nothing frees its evidence, so the next turn may try again once the debounce has passed."""
    def body(tx):
        doc = tx.get(*key)
        if doc.get("seq") == seq and doc.get("pending_hash") is not None:
            tx.merge(*key, {"pending_hash": None})

    try:
        transaction(body)
    except Exception as exc:  # noqa: BLE001 - the pending mark expires by itself after PENDING_S
        log.warning("apa warning claim not released: %s", exc.__class__.__name__)


def _commit(key: tuple[str, str], seq: int, warning: PreparedWarning) -> list[str] | None:
    """Keep this warning unless a newer generation was kept meanwhile. Returns the clip ids nothing refers to any more, or
    None when this one was discarded."""
    def body(tx):
        doc = tx.get(*key)
        if int(doc.get("committed_seq", 0)) >= seq:
            return None
        old = PreparedWarning.from_doc(doc.get("warning"))
        tx.set(*key, {**doc, "warning": warning.to_doc(), "committed_seq": seq, "updated_at": time.time(),
                      "pending_hash": None if doc.get("seq") == seq else doc.get("pending_hash")})
        keep = {l.clip_id for l in warning.lines}
        return [l.clip_id for l in (old.lines if old else ()) if l.clip_id and l.clip_id not in keep]

    return transaction(body)


# --- clips -----------------------------------------------------------------------------------------------------------


def wav(pcm: bytes, rate: int = PCM_RATE) -> bytes:
    return struct.pack("<4sI4s4sIHHIIHH4sI", b"RIFF", 36 + len(pcm), b"WAVE", b"fmt ", 16, 1, 1, rate, rate * 2, 2, 16, b"data",
                       len(pcm)) + pcm


def encode(pcm: bytes, settings: Settings, rate: int = PCM_RATE) -> tuple[bytes, str]:
    """16-bit mono PCM as OGG Opus (about a tenth of WAV, for a slow rural link) when soundfile can write it, else WAV."""
    pcm = pcm[: len(pcm) - len(pcm) % 2]
    if settings.clip_format == "ogg_opus":
        try:
            import numpy as np
            import soundfile as sf

            buf = io.BytesIO()
            sf.write(buf, np.frombuffer(pcm, dtype="<i2"), rate, format="OGG", subtype="OPUS")
            return buf.getvalue(), "audio/ogg"
        except Exception as exc:  # noqa: BLE001 - no soundfile, or a libsndfile without Opus: WAV still plays everywhere
            log.warning("ogg opus encode failed, clip stored as wav: %s", exc.__class__.__name__)
    return wav(pcm, rate), "audio/wav"


def _put_clip(audio: bytes, mime: str, uid: str | None, session_id: str) -> str:
    clip_id, now = secrets.token_urlsafe(18), datetime.now(UTC)
    store().set(CLIPS, clip_id, {"uid": uid, "session_id": session_id, "mime": mime, "audio": audio, "bytes": len(audio),
                                 "created_at": now.timestamp(), "expire_at": now + timedelta(seconds=CLIP_TTL_S)})
    return clip_id


def _delete_clips(clip_ids: Iterable[str]) -> None:
    for clip_id in clip_ids:
        try:
            store().delete(CLIPS, clip_id)
        except Exception as exc:  # noqa: BLE001 - an orphan clip expires with its TTL
            log.warning("apa clip not deleted: %s", exc.__class__.__name__)


def clip(clip_id: str, uid: str | None = None) -> tuple[bytes, str] | None:
    """A clip's audio and mime type; with a uid, only that account's clip. None when unknown, someone else's or expired."""
    if not clip_id or not CLIP_ID.fullmatch(clip_id):
        return None
    doc = store().get(CLIPS, clip_id)
    if not doc or (uid is not None and doc.get("uid") != uid):
        return None
    expire = doc.get("expire_at")
    if isinstance(expire, datetime) and expire <= datetime.now(UTC):
        return None
    return bytes(doc["audio"]), str(doc.get("mime") or "application/octet-stream")


class _Renderer:
    """Renders lines one at a time (sequential: the TTS quota is a few requests a minute). A line whose text already has a
    clip in this call reuses it. The first failure (a 429, TTS off or over its cap, an error) stops rendering for this pass
    at once, without pacing, and every line left goes to the phone as text with speak_on_device."""

    def __init__(self, previous: Sequence[PreparedLine], uid: str | None, session_id: str, settings: Settings) -> None:
        self.reuse = {l.text_bn: l.clip_id for l in previous if l.clip_id}
        self.uid, self.session_id, self.settings = uid, session_id, settings
        self.blocked = False
        self.render_ms: dict[str, float] = {}
        self.created: list[str] = []

    def line(self, line: Any) -> PreparedLine:
        role, text_bn, text_en = str(line.role), str(line.text_bn), str(getattr(line, "text_en", "") or "")
        clip_id = self.reuse.get(text_bn)
        if clip_id is None and not self.blocked and self.settings.prerender_audio:  # off: audio waits for the warning
            clip_id = self._render(role, text_bn)
        return PreparedLine(role, text_bn, text_en, clip_id, clip_id is None)

    def _render(self, role: str, text_bn: str) -> str | None:
        tts = _module("tts")
        expected = tuple(e for e in (getattr(tts, "RateLimited", None), getattr(tts, "Unavailable", None)) if isinstance(e, type))
        started = time.perf_counter()
        try:
            pcm = b"".join(tts.speak(text_bn, self.settings))
        except Exception as exc:  # noqa: BLE001 - every failure drops to the next rung: the phone speaks the text
            self.blocked = True
            log.log(logging.INFO if isinstance(exc, expected) else logging.WARNING, "apa clip not rendered (%s): %s",
                    exc.__class__.__name__, exc)
            return None
        finally:
            self.render_ms[role] = round((time.perf_counter() - started) * 1000, 1)
        if not pcm:
            return None
        audio, mime = encode(pcm, self.settings, int(getattr(tts, "RATE", PCM_RATE)))
        if len(audio) > CLIP_MAX_BYTES:
            log.warning("apa clip of %d bytes is over the document limit; the phone speaks the line", len(audio))
            return None
        try:
            clip_id = _put_clip(audio, mime, self.uid, self.session_id)
        except Exception as exc:  # noqa: BLE001 - no clip, the phone speaks the line
            log.warning("apa clip not stored: %s", exc.__class__.__name__)
            return None
        self.created.append(clip_id)
        self.reuse[text_bn] = clip_id
        return clip_id


# --- composing ---------------------------------------------------------------------------------------------------------


def _valid(lines: Iterable[Any] | None, roles: Sequence[str] = ROLES) -> Iterator[Any]:
    """The composer's lines in its order, only the roles asked for, each once and never empty. Words are never edited here."""
    seen: set[str] = set()
    for line in lines or ():
        role = getattr(line, "role", None)
        if role in roles and role not in seen and str(getattr(line, "text_bn", "") or "").strip():
            seen.add(role)
            yield line


def _last_good(warnings: Any, previous: PreparedWarning | None) -> Any:
    """The call's last validated lines, for the composer's repair policy (a failed A or X is replaced by the last good one)."""
    if previous is None:
        return None
    try:  # the lines themselves: generate() and stream() take last_good as WarningLines (or a {role: line} mapping)
        return tuple(warnings.WarningLine(l.role, l.text_bn, l.text_en) for l in previous.lines)
    except Exception as exc:  # noqa: BLE001 - the composer then regenerates instead of reusing
        log.warning("last good warning not passed to the composer: %s", exc.__class__.__name__)
        return None


def _composed(warnings: Any, plan: Any, caller_words: tuple[Any, ...], settings: Settings, last_good: Any) -> Iterator[Any]:
    """The validated lines as each one validates: the composer's per-line stream when it has one (warnings.stream, with
    generate's arguments), otherwise generate()'s lines once it returns."""
    stream = getattr(warnings, "stream", None)
    if callable(stream):
        yield from stream(plan, caller_words, settings, last_good=last_good)
    else:
        yield from warnings.generate(plan, caller_words, settings, last_good=last_good).lines


def _ahead(lines: Iterator[Any]) -> Iterator[Any]:
    """The composer's lines pulled on their own thread into a queue: the composer's deadline keeps running while a generator
    is suspended, so rendering a line in the consumer used to cost the stream its last lines (review finding, P and W)."""
    handed: queue.Queue = queue.Queue()
    end = object()

    def pump() -> None:
        try:
            for line in lines:
                handed.put(line)
        except Exception as exc:  # noqa: BLE001 - handed to the reader, which ends the stream with its final record
            handed.put(exc)
        finally:
            handed.put(end)
    threading.Thread(target=contextvars.copy_context().run, args=(pump,), name="apa-cold-composer", daemon=True).start()
    while (item := handed.get()) is not end:
        if isinstance(item, Exception):
            raise item
        yield item


def _log(prepared: PreparedWarning) -> None:
    log.info(json.dumps({"task": "apa_prerender", "stage": prepared.stage, "warning_id": prepared.warning_id,
                         "ledger_hash": prepared.ledger_hash, "lines": len(prepared.lines),
                         "clips": sum(1 for l in prepared.lines if l.clip_id), "gen_ms": prepared.gen_ms, "render_ms": prepared.render_ms}))


def _prepare(key: tuple[str, str], claim: tuple[int, PreparedWarning | None], *, uid: str | None, session_id: str, stage: Stage,
             ledger: Ledger, pending_action: str | None, band: str | None, ledger_hash: str, settings: Settings, now: float,
             caller_turns: Sequence[Any] | None, address: str | None, roles: Sequence[str] = ROLES,
             simple: bool = False) -> PreparedWarning | None:
    seq, previous = claim
    renderer = _Renderer(previous.lines if previous else (), uid, session_id, settings)
    try:
        warnings = _module("warnings")
        plan = warnings.plan(ledger, pending_action, band, address=address, simple=simple, index=seq - 1)
        started = time.perf_counter()
        background = settings.model_copy(update={"warning_timeout_s": settings.prearm_timeout_s})  # off the hold path: more time
        made = warnings.generate(plan, _caller_words(ledger, caller_turns), background, last_good=_last_good(warnings, previous))
        gen_ms = round((time.perf_counter() - started) * 1000, 1)
        chosen = list(_valid(made.lines, roles))
        if not chosen:  # no validated text: nothing to keep, and the hold falls to the next rung
            log.info("apa %s: the composer returned no validated line", stage)
            _release(key, seq)
            return None
        lines = tuple(renderer.line(line) for line in chosen)
        prepared = PreparedWarning(secrets.token_hex(8), session_id, ledger_hash, stage, lines, now, gen_ms, renderer.render_ms)
        unused = _commit(key, seq, prepared)
    except Exception as exc:  # noqa: BLE001 - speculation must never break the turn or the call that asked for it
        log.warning("apa %s not prepared: %s", stage, exc.__class__.__name__)
        _release(key, seq)
        _delete_clips(renderer.created)
        return None
    if unused is None:  # a newer warning was kept while this one was written
        _delete_clips(renderer.created)
        return None
    _delete_clips(unused)
    _log(prepared)
    return prepared


class Trailing:
    """One timer per call, for a material change that lands inside the debounce: when the debounce ends the newest refresh
    owed for that call runs once, from the call as it stands then (the live run on 2026-10-17 met a code ask 1.3 s after the
    previous turn, no later turn, and a hold that found only the older warning). In process, like the single instance."""

    def __init__(self) -> None:
        self._timers: dict[tuple[str, str], threading.Timer] = {}
        self._latest: dict[tuple[str, str], Any] = {}
        self._lock = threading.Lock()

    def schedule(self, key: tuple[str, str], delay: float, fn: Any) -> bool:
        """Owe `fn` to this call after `delay`; a call already waiting keeps its timer and runs the newest fn. True when a
        timer was started."""
        with self._lock:
            self._latest[key] = fn
            if key in self._timers:
                return False
            timer = threading.Timer(delay, self._fire, args=(key,))
            timer.daemon = True
            self._timers[key] = timer
        timer.start()
        return True

    def _fire(self, key: tuple[str, str]) -> None:
        with self._lock:
            self._timers.pop(key, None)
            fn = self._latest.pop(key, None)
        try:
            if fn is not None:
                fn()
        except Exception as exc:  # noqa: BLE001 - a refresh that cannot run leaves the hold its colder rungs
            log.warning("apa trailing refresh failed: %s", exc.__class__.__name__)


TRAILING = Trailing()


def _debounce_left(key: tuple[str, str], ledger_hash: str, now: float, settings: Settings) -> float | None:
    """Seconds until a refresh for this evidence is due, when only the debounce stands in its way: new evidence (not the
    prepared warning's, not one being written) and the cap not reached. None when nothing is owed."""
    doc = store().get(*key)
    prepared = PreparedWarning.from_doc(doc.get("warning"))
    last = float(doc.get("last_gen_at", float("-inf")))
    pending = doc.get("pending_hash") if now - last < PENDING_S else None
    if ledger_hash in (prepared.ledger_hash if prepared else None, pending) or int(doc.get("refreshes", 0)) >= settings.prearm_max_per_call:
        return None
    left = settings.prearm_debounce_s - (now - last)
    return left if left > 0 else None


def _trailing_refresh(session_id: str, uid: str | None, pending_action: str | None, settings: Settings,
                      caller_turns: Sequence[Any] | None, address: str | None, simple: bool) -> PreparedWarning | None:
    return maybe_prearm(session_id, uid, session_state(session_id, uid), pending_action, settings, caller_turns=caller_turns,
                        address=address, simple=simple)


def maybe_prearm(session_id: str, uid: str | None, state: Any, pending_action: str | None, settings: Settings,
                 now: float | None = None, *, caller_turns: Sequence[Any] | None = None, address: str | None = None,
                 simple: bool = False) -> PreparedWarning | None:
    """C1, after every scam turn (call it from a background task: it waits on the composer and TTS). Writes the warning again
    when the call's risk has reached prearm_risk and the ledger's hash differs from the latest prepared one, at most
    prearm_max_per_call times a call and prearm_debounce_s apart; a change inside the debounce is owed one trailing refresh
    when it ends (TRAILING). None when nothing was due now or nothing could be kept."""
    now = time.time() if now is None else now
    try:
        if float(state.risk) < settings.prearm_risk:
            return None
        ledger_hash = _module("warnings").key(state.ledger, pending_action, state.band)
        _composer_and_voice()
        key = doc_key(session_id, uid)
        claim = _claim(key, uid, session_id, "C1", ledger_hash, now, settings)
        if claim is None and (left := _debounce_left(key, ledger_hash, now, settings)) is not None:
            TRAILING.schedule(key, left, lambda: _trailing_refresh(session_id, uid, pending_action, settings, caller_turns, address, simple))
    except Exception as exc:  # noqa: BLE001 - see _prepare
        log.warning("apa C1 not claimed: %s", exc.__class__.__name__)
        return None
    if claim is None:
        return None
    return _prepare(key, claim, uid=uid, session_id=session_id, stage="C1", ledger=state.ledger, pending_action=pending_action,
                    band=state.band, ledger_hash=ledger_hash, settings=settings, now=now, caller_turns=caller_turns, address=address,
                    simple=simple)


def after_turn(session_id: str, uid: str | None, pending_action: str | None, settings: Settings,
               caller_turns: Sequence[str] | None = None, now: float | None = None) -> PreparedWarning | None:
    """/v1/scam/turn's background task: the call as the detector just stored it and her profile (users/{uid}: the address she
    chose, simple mode), then maybe_prearm. A pending action that is not a transaction type is dropped: it would reach the
    composer's plan. Never raises; a pre-arm that cannot run leaves the hold its colder rungs."""
    try:
        view = session_state(session_id, uid)
        address, simple = profile(uid)
    except Exception as exc:  # noqa: BLE001 - see _prepare
        log.warning("apa pre-arm skipped: %s", exc.__class__.__name__)
        return None
    pending = pending_action if pending_action in TXN_TYPES else None
    return maybe_prearm(session_id, uid, view, pending, settings, now=now, caller_turns=caller_turns, address=address, simple=simple)


def profile(uid: str | None) -> tuple[str | None, bool]:
    """What every stage writes for her: the form of address she chose and simple mode (users/{uid}), as compose() reads them."""
    doc = store().get("users", uid) if uid else {}
    return doc.get("apa_address"), bool(doc.get("apa_simple_mode"))


def call_start_pair(session_id: str, uid: str | None, settings: Settings, address: str | None = None,
                    now: float | None = None) -> PreparedWarning | None:
    """C0, once per call, when a call from a caller not in contacts starts: an A+X pair from an empty ledger, ready about
    3-5 s into the call, for a hold that fires before any transcript evidence (on transaction or behaviour signals)."""
    if not settings.call_start_pair_enabled:
        return None
    now = time.time() if now is None else now
    ledger = Ledger()
    ledger_hash = ledger.hash(None, CALL_START_BAND)
    try:
        chosen, simple = profile(uid)
        address = address or chosen
        _composer_and_voice()
        key = doc_key(session_id, uid)
        claim = _claim(key, uid, session_id, "C0", ledger_hash, now, settings)
    except Exception as exc:  # noqa: BLE001 - see _prepare
        log.warning("apa C0 not claimed: %s", exc.__class__.__name__)
        return None
    if claim is None:
        return None
    return _prepare(key, claim, uid=uid, session_id=session_id, stage="C0", ledger=ledger, pending_action=None, band=CALL_START_BAND,
                    ledger_hash=ledger_hash, settings=settings, now=now, caller_turns=None, address=address, roles=PAIR, simple=simple)


# --- what the phone reads ------------------------------------------------------------------------------------------------


def latest(session_id: str, uid: str | None = None) -> PreparedWarning | None:
    try:
        return PreparedWarning.from_doc(store().get(*doc_key(session_id, uid)).get("warning"))
    except Exception as exc:  # noqa: BLE001 - no warning is an answer the phone handles
        log.warning("apa warning not read: %s", exc.__class__.__name__)
        return None


def for_hold(session_id: str, uid: str | None, ledger_hash: str, doc: Mapping[str, Any] | None = None) -> HoldWarning:
    """What the hold response carries. fresh: the prepared hash matches the call's now, every line plays from the phone;
    stale: the evidence moved on, its A line (attention stays valid) plays while the rest streams; call_start: only the C0
    pair; none: nothing prepared, go cold. doc: the warning document when the caller already read it (doc_key)."""
    nothing = HoldWarning(status="none", stream_rest=True)
    try:
        doc = store().get(*doc_key(session_id, uid)) if doc is None else doc
        prepared = PreparedWarning.from_doc(doc.get("warning"))
        if prepared is None:
            return nothing
        if prepared.stage == "C0":
            status, kept = "call_start", prepared.lines
        elif prepared.ledger_hash == ledger_hash:
            status, kept = "fresh", prepared.lines
        else:
            status, kept = "stale", tuple(l for l in prepared.lines if l.role == "A")
        if not kept:
            return nothing
        return HoldWarning(status=status, warning=replace(prepared, lines=kept).contract(),
                           speak_on_device=any(l.speak_on_device for l in kept), stream_rest=status != "fresh")
    except Exception as exc:  # noqa: BLE001 - a hold never fails over its warning
        log.warning("apa warning not read at the hold: %s", exc.__class__.__name__)
        return nothing


def _keep_cold(key: tuple[str, str], seq: int, session_id: str, ledger_hash: str, kept: Mapping[str, PreparedLine],
               renderer: _Renderer, now: float, started: float) -> str | None:
    """Store what the cold path produced as the call's latest warning (C2); never raises, since it runs as the stream closes."""
    try:
        if not kept:
            _release(key, seq)
            return None
        cold = PreparedWarning(secrets.token_hex(8), session_id, ledger_hash, "C2", tuple(kept.values()), now,
                               round((time.perf_counter() - started) * 1000, 1), renderer.render_ms)
        unused = _commit(key, seq, cold)
        _delete_clips(renderer.created if unused is None else unused)
        if unused is None:
            return None
        _log(cold)
        return cold.warning_id
    except Exception as exc:  # noqa: BLE001 - the lines already went out; only the record of them is lost
        log.warning("apa cold warning not kept: %s", exc.__class__.__name__)
        return None


def _record(line: PreparedLine) -> dict[str, Any]:
    return ApaLine(role=line.role, text_bn=line.text_bn, text_en=line.text_en, clip_id=line.clip_id,
                   speak_on_device=line.speak_on_device).model_dump()


def cold_stream(session_id: str, uid: str | None, pending_action: str | None, settings: Settings, skip_roles: Sequence[str] = (),
                now: float | None = None, caller_turns: Sequence[Any] | None = None) -> Iterator[dict[str, Any]]:
    """C2, POST /v1/apa/warning/stream: one ApaLine record per line as it validates and is rendered (a 429 sends it with
    speak_on_device and no clip), then {"done": true, "earcon": true, "vibrate": true, "lines": n, ...}. A fresh prepared
    warning is sent as it is, without writing again. No validated text at all: only the final record, the silent floor.
    skip_roles: lines the phone already has (stale: A; call_start: A and X); they are kept, not sent, and only when the
    prepared warning had them. The composer runs on its own thread, so rendering a line never runs down its deadline."""
    now = time.time() if now is None else now
    skip, sent, warning_id, ledger_hash = set(skip_roles), 0, None, None
    try:
        view = session_state(session_id, uid)
        ledger_hash = _module("warnings").key(view.ledger, pending_action, view.band)
        key = doc_key(session_id, uid)
        prepared = PreparedWarning.from_doc(store().get(*key).get("warning"))
        skip &= {l.role for l in prepared.lines} if prepared else set()  # a C0 pair without X leaves X to send
        if prepared and prepared.stage != "C0" and prepared.ledger_hash == ledger_hash:
            for line in prepared.lines:
                if line.role not in skip:
                    sent += 1
                    yield _record(line)
            warning_id = prepared.warning_id
        else:
            warnings = _composer_and_voice()
            seq, previous = _claim(key, uid, session_id, "C2", ledger_hash, now, settings)
            have = {l.role: l for l in (previous.lines if previous else ())}
            renderer = _Renderer(previous.lines if previous else (), uid, session_id, settings)
            kept: dict[str, PreparedLine] = {}
            started = time.perf_counter()
            try:
                address, simple = profile(uid)
                plan = warnings.plan(view.ledger, pending_action, view.band, address=address, simple=simple, index=seq - 1)
                for line in _ahead(_valid(_composed(warnings, plan, _caller_words(view.ledger, caller_turns), settings,
                                                    _last_good(warnings, previous)))):
                    if line.role in skip:
                        kept[line.role] = have.get(line.role) or PreparedLine(line.role, line.text_bn, getattr(line, "text_en", ""), None, True)
                        continue
                    kept[line.role] = renderer.line(line)
                    sent += 1
                    yield _record(kept[line.role])
            finally:  # also when the phone hangs up mid-stream: what was sent is what the call now has
                warning_id = _keep_cold(key, seq, session_id, ledger_hash, kept, renderer, now, started)
    except Exception as exc:  # noqa: BLE001 - the stream always ends with its final record; the earcon still fires
        log.warning("apa cold stream cut: %s", exc.__class__.__name__)
    yield {"done": True, "earcon": True, "vibrate": True, "lines": sent, "warning_id": warning_id, "ledger_hash": ledger_hash}
