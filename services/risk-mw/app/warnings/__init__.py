"""Apa's generated warnings: code plans, Flash-Lite phrases, code checks. There is no fixed line.

`plan()` turns the evidence ledger into facts, `generate()` streams and validates A|T|R|X from them, and `validate()` is the
deterministic gate. When nothing validates, the floor is an earcon, vibration and the hold card, with no words.

`compose()` is what the routes call: it reads the call's ledger and band from the detector's session document, what risk-mw
already verified about her phone and its use (app.warnings.signals: App Safety's latest result, the behaviour model's last
session), why the hold was made (the route reads it with signals.hold_facts), her chosen address from users/{uid}, and
the call's own memory in apa_warnings/{key} (the lines validated so far, for the repair policy, and the latest warning
with its ledger hash, so the same evidence is never written twice). A new warning is kept there and on the hold
(interventions/{id}.apa_warning), where the trusted contact's push takes its reason from.
"""

from __future__ import annotations

import hashlib
import logging
import time
from collections.abc import Callable, Iterable, Mapping
from dataclasses import dataclass, field

from app import scam, state
from app.ledger import Ledger
from app.settings import Settings
from app.warnings import composer, signals
from app.warnings.composer import Warning, WarningLine, generate, stream
from app.warnings.planner import BANDS, Plan, key, plan
from app.warnings.signals import hold_facts
from app.warnings.validator import Check, validate, validate_en

__all__ = ["COLLECTION", "CallFacts", "Check", "Composed", "Plan", "Warning", "WarningLine", "call_facts", "compose", "generate", "hold_facts",
           "key", "plan", "stream", "validate", "validate_en"]

log = logging.getLogger(__name__)
COLLECTION = "apa_warnings"


@dataclass(frozen=True)
class CallFacts:
    ledger: Ledger
    band: str
    caller_turns: tuple[str, ...]  # for the parroting check only: never shown to the model


@dataclass(frozen=True)
class Composed:
    plan: Plan
    warning: Warning
    ledger_hash: str
    warning_id: str | None = None  # None on the floor
    cached: bool = False
    clips: Mapping[str, str] = field(default_factory=dict)  # role -> pre-rendered clip id (app.prerender), when there is one


def _turn_text(turn: object) -> str:
    return str(turn.get("text", "")) if isinstance(turn, Mapping) else str(turn or "")


def call_facts(session_id: str | None, uid: str | None, snippet: str | None = None) -> CallFacts:
    """The call's verified evidence and certainty, and the caller's words the line must not parrot (the ledger's quotes,
    any caller turns the session keeps, and the snippet the app sent)."""
    doc = scam.own_session(state.get_many(scam.session_keys(session_id, uid)), uid) if session_id else {}
    view = scam.session_state_of(doc)  # the detector's reader, as the hold and the pre-render use: one hash for one call
    turns = [e.quote for e in view.ledger.tactics.values()] + [_turn_text(t) for t in doc.get("caller_turns") or ()] + [snippet or ""]
    return CallFacts(view.ledger, view.band if doc else "possible", tuple(t for t in turns if t.strip()))


def _key(uid: str, user_id: str, call: str) -> str:
    return "aw-" + hashlib.sha1(f"{uid}|{user_id}|{call}".encode()).hexdigest()[:16]


def _doc(lines: Iterable[WarningLine]) -> list[dict]:
    return [{"role": line.role, "text_bn": line.text_bn, "text_en": line.text_en} for line in lines]


def _lines(docs: Iterable[Mapping]) -> tuple[WarningLine, ...]:
    return tuple(WarningLine(str(d.get("role")), str(d.get("text_bn", "")), str(d.get("text_en", ""))) for d in docs if isinstance(d, Mapping))


def _link(intervention_id: str | None, user_id: str, entry: dict) -> None:
    """interventions/{id}.apa_warning, only on her own hold."""
    if intervention_id and state.store().get("interventions", intervention_id).get("user_id") == user_id:
        state.store().merge("interventions", intervention_id, {"apa_warning": entry})


def _remember(key: str, memory: dict, entry: dict, lines: tuple[WarningLine, ...], meta: dict) -> None:
    last_good = {**(memory.get("last_good") or {}), **{d["role"]: d for d in _doc(lines)}}
    state.store().merge(COLLECTION, key, {**meta, "count": int(memory.get("count", 0)) + 1, "last_good": last_good, "latest": entry,
                                          "updated_at": time.time()})


def _prepared(session_id: str | None, uid: str, ledger_hash: str, p: Plan, caller_turns: tuple[str, ...]) -> object | None:
    """The warning app.prerender prepared for this call, when it was written from this very evidence and every line still
    passes: the hold has already played it, so the card says the same words, with no second model call."""
    if not session_id:
        return None
    from app import prerender  # prerender looks app.warnings up at call time; importing it here keeps the two apart

    got = prerender.latest(session_id, uid)
    if got is None or got.stage == "C0" or got.ledger_hash != ledger_hash or not got.lines:
        return None
    return got if all(composer.check(l.role, l.text_bn, l.text_en, p, caller_turns).ok for l in got.lines) else None


def _signals(uid: str, user_id: str, settings: Settings) -> tuple[tuple[str, ...], tuple[str, ...]]:
    """Her phone's facts and her usage's facts; a store that fails costs the facts, never the warning."""
    try:
        phone = signals.phone_facts(uid)
    except Exception as exc:  # noqa: BLE001
        log.warning("phone facts not read for apa's warning: %s", exc.__class__.__name__)
        phone = ()
    try:
        behaviour = signals.behaviour_facts(user_id, settings)
    except Exception as exc:  # noqa: BLE001
        log.warning("behaviour facts not read for apa's warning: %s", exc.__class__.__name__)
        behaviour = ()
    return phone, behaviour


def compose(uid: str, user_id: str, session_id: str | None, pending_action: str | None, settings: Settings,
            intervention_id: str | None = None, snippet: str | None = None, admit: Callable[[], bool] | None = None,
            hold: tuple[str, ...] = ()) -> Composed:
    """Apa's warning for this moment of the call. `admit` is asked before the model is called (the Gemini quota); refused,
    the warning comes from the call's last good lines or is the floor. `hold` is why the hold was made (hold_facts), said
    only when nothing else is known. A store that fails costs the memory, never the answer."""
    call = session_id or intervention_id
    slot = _key(uid, user_id, call) if call else None
    try:
        facts, profile = call_facts(session_id, uid, snippet), state.store().get("users", user_id)
        memory = state.store().get(COLLECTION, slot) if slot else {}
    except Exception as exc:  # noqa: BLE001 - a store that fails mid-hold leaves a plan with no evidence, never a 500
        log.warning("apa warning context not read: %s", exc.__class__.__name__)
        facts, profile, memory, slot = CallFacts(Ledger(), "possible", (snippet,) if snippet else ()), {}, {}, None
    count = int(memory.get("count", 0))
    phone, behaviour = _signals(uid, user_id, settings)
    p = plan(facts.ledger, pending_action, facts.band, address=profile.get("apa_address"), simple=bool(profile.get("apa_simple_mode")),
             index=count, phone=phone, behaviour=behaviour, hold=hold)
    ledger_hash = key(facts.ledger, pending_action, facts.band, phone, behaviour, hold)
    meta = {"uid": uid, "user_id": user_id, "session_id": session_id}
    if (ready := _prepared(session_id, uid, ledger_hash, p, facts.caller_turns)) is not None:
        lines = tuple(WarningLine(l.role, l.text_bn, l.text_en) for l in ready.lines)
        entry = {"warning_id": ready.warning_id, "ledger_hash": ledger_hash, "lines": _doc(lines), "at": time.time()}
        if slot:
            _store(lambda: (_remember(slot, memory, entry, lines, meta), _link(intervention_id, user_id, entry)))
        return Composed(p, Warning(lines=lines, reused=tuple(l.role for l in lines)), ledger_hash, ready.warning_id, True,
                        clips={l.role: l.clip_id for l in ready.lines if l.clip_id})
    latest = memory.get("latest") or {}
    lines = _lines(latest.get("lines") or ()) if latest.get("ledger_hash") == ledger_hash else ()
    # The same evidence was already written for: reuse it, if it still passes (her chosen address may have changed since).
    if lines and all(composer.check(line.role, line.text_bn, line.text_en, p, facts.caller_turns).ok for line in lines):
        _store(lambda: _link(intervention_id, user_id, latest))
        return Composed(p, Warning(lines=lines, reused=tuple(line.role for line in lines)), ledger_hash, latest.get("warning_id"), True)
    offline = admit is not None and not admit()
    warning = generate(p, facts.caller_turns, settings, last_good=_lines((memory.get("last_good") or {}).values()), offline=offline)
    if not warning.lines or not slot:
        return Composed(p, warning, ledger_hash)
    warning_id = "w-" + hashlib.sha1(f"{slot}|{ledger_hash}|{count}".encode()).hexdigest()[:16]
    entry = {"warning_id": warning_id, "ledger_hash": ledger_hash, "lines": _doc(warning.lines), "at": time.time()}
    _store(lambda: (_remember(slot, memory, entry, warning.lines, meta), _link(intervention_id, user_id, entry)))
    return Composed(p, warning, ledger_hash, warning_id)


def _store(write: Callable[[], object]) -> None:
    try:
        write()
    except Exception as exc:  # noqa: BLE001 - the warning still goes out; only the call's memory is lost
        log.warning("apa warning not stored: %s", exc.__class__.__name__)
