"""/v1/risk/signals and /v1/risk/score."""

from __future__ import annotations

import logging
import time
from datetime import UTC, datetime, timedelta
from typing import Annotated

from fastapi import APIRouter, BackgroundTasks, Depends

from app import appsafety_engine, ato, audit, device_signals, interventions, mule, personas, prerender, scam, session_model, sessions, state
from app.auth import require_user
from app.clock import scenario_now
from app.contracts import DemoFlags, Reason, ScoreRequest, ScoreResponse, SignalsRequest, SignalsResponse
from app.identity import bind_identity
from app.payee import PayeeScreen
from app.rules import RuleHit, decide, evaluate, model_hit, money_lock_hit
from app.settings import Settings, get_settings
from app.warnings import signals

router = APIRouter(prefix="/v1/risk", tags=["risk"])
log = logging.getLogger(__name__)

VERDICT_RANK = {"SAFE": 0, "CAUTION": 1, "BLOCK": 2}
PIN_FREEZE = "pin_freeze"  # pin_freeze/{uid}: {until, reason_codes, reasons} of the pin_reset hold that froze it


def _now() -> datetime:
    return datetime.now(UTC)


def _p95_amount_for(user_id: str, user: dict, settings: Settings) -> float:
    """Per-user p95 send amount: users/{uid}.p95_send_bdt (the seed loader's field), else the persona table that mirrors it
    (app.personas), else the default."""
    value = user.get("p95_send_bdt")
    return float(value) if isinstance(value, int | float) and value > 0 else personas.p95_amount_for(user_id, settings)


def _merge_flags(sent: DemoFlags, stored: dict) -> DemoFlags:
    """demo_state/{uid} and the request's flags combine to the more severe of each (spec FR-6)."""
    if not stored:
        return sent
    panel = DemoFlags(**{k: v for k, v in stored.items() if k in DemoFlags.model_fields})
    return DemoFlags(
        sim_swap=sent.sim_swap or panel.sim_swap,
        call_active=sent.call_active or panel.call_active,
        screen_share=sent.screen_share or panel.screen_share,
        caller_in_contacts=sent.caller_in_contacts and (panel.caller_in_contacts or not panel.call_active),
        app_safety_verdict=max(sent.app_safety_verdict, panel.app_safety_verdict, key=VERDICT_RANK.__getitem__),
        inbound_mule_score=max(sent.inbound_mule_score, panel.inbound_mule_score),
        scam_score=max(sent.scam_score, panel.scam_score),
    )


def _documents(body: ScoreRequest, settings: Settings, uid: str) -> dict[str, dict]:
    """Every document this score reads, fetched together (spec section 6): one round trip rather than one per document.

    "scam" is the call's window that belongs to this account (scam.session_keys: the session id is the client's own);
    "warning" is Apa's warning prepared for this call (app.prerender), which a hold carries.
    """
    keys = {
        "warning": prerender.doc_key(body.session_id, uid),
        "user": ("users", body.user_id),
        **dict(zip(("scam", "scam_own"), scam.session_keys(body.session_id, uid), strict=True)),
        **({"demo": ("demo_state", body.user_id)} if settings.demo_mode else {}),
        **({"lock": ("money_lock", body.user_id)} if body.txn.type == "send_money" else {}),
        **({"freeze": (PIN_FREEZE, body.user_id)} if body.txn.type == "pin_reset" else {}),
    }
    docs = dict(zip(keys, state.get_many(tuple(keys.values())), strict=True))
    docs["scam"] = scam.own_session((docs["scam"], docs.pop("scam_own")), uid)
    return docs


def _with_demo_state(body: ScoreRequest, stored: dict) -> ScoreRequest:
    """demo_state/{uid} merged into the request's flags; empty outside demo mode, where it is not read."""
    merged = _merge_flags(body.demo_flags, stored)
    return body if merged == body.demo_flags else body.model_copy(update={"demo_flags": merged})


def _with_model_signals(body: ScoreRequest, payee: PayeeScreen | None) -> ScoreRequest:
    """Fuse the payee's mule score with this transfer with whatever the demo panel set (max wins); returns a new request."""
    fused = max(body.demo_flags.inbound_mule_score, payee.rule_score if payee else 0.0)
    if fused == body.demo_flags.inbound_mule_score:
        return body
    return body.model_copy(update={"demo_flags": body.demo_flags.model_copy(update={"inbound_mule_score": round(fused, 4)})})


def _behaviour_hits(body: ScoreRequest, session: sessions.SessionState | None) -> tuple:
    """The behaviour identity and coaching hits, or none when this caller's session signalled no features.

    call_active reaches explain.required_action, which is what turns a suspected-coaching session on a live call
    from a step-up into a hold - the case US-3 and the demo both turn on.
    """
    if session is None or not session.features:
        return ()
    return ato.behaviour_hits(body.user_id, session.features, in_call=body.demo_flags.call_active)


def _with_scam_session(body: ScoreRequest, session: dict) -> ScoreRequest:
    """The live call's scam risk (this account's scam_sessions call, over its whole evidence) joins the flags; max wins."""
    live = scam.session_score_of(session)
    if live <= body.demo_flags.scam_score:
        return body
    return body.model_copy(update={"demo_flags": body.demo_flags.model_copy(update={"scam_score": live})})


def _pin_freeze_hits(doc: dict) -> tuple[RuleHit, ...]:
    """freeze_pin_reset(60 min): inside the freeze, a pin_reset is held again with the reasons of the hold that froze it,
    so the app and Apa say the same thing (spec section 2). Empty once the freeze has run out."""
    until = doc.get("until")
    if not until or datetime.fromisoformat(until) <= datetime.now(UTC):
        return ()
    if (iid := doc.get("intervention_id")) and state.store().get("interventions", iid).get("status") == "released":
        return ()  # her trusted contact approved the hold that froze it: the freeze has done its job
    return tuple(RuleHit(Reason(**r), "hold") for r in doc.get("reasons", []))


def _record_pin_freeze(user_id: str, hits: tuple[RuleHit, ...], settings: Settings, iid: str | None = None) -> None:
    until = datetime.now(UTC) + timedelta(minutes=settings.pin_reset_freeze_minutes)
    reasons = [h.reason.model_dump() for h in hits]  # a list of maps: Firestore stores it as is
    state.store().set(PIN_FREEZE, user_id, {"until": until.isoformat(), "reason_codes": [r["code"] for r in reasons], "reasons": reasons,
                                            "intervention_id": iid})


def _device_age_days(first_seen_at: datetime | None) -> float | None:
    """Days since this app install first saw the device (spec section 3); a time without a zone is UTC, one in the future is today."""
    if first_seen_at is None:
        return None
    seen = first_seen_at if first_seen_at.tzinfo else first_seen_at.replace(tzinfo=UTC)
    return round(max((datetime.now(UTC) - seen).total_seconds() / 86400, 0.0), 2)


def _block_facts(uid: str) -> tuple[str, ...]:
    """What the App Safety Check found, for the block overlay's wording; a failed lookup costs the words, never the block."""
    try:
        return signals.phone_facts(uid)
    except Exception as exc:  # noqa: BLE001
        log.warning("app-safety facts not read for the block reason: %s", exc.__class__.__name__)
        return ()


def _model_signals(session: sessions.SessionState | None) -> dict:
    """What the session model reads from this caller's last /signals post. The live fields (call state, screen capture)
    reach it through the fused flags instead, which honour RISK_MW_LIVE_SIGNAL_FRESH_S."""
    if session is None:
        return {}
    posted = session.signals
    live = {"call_state", "screen_capture", "screen_recording"}
    return {**{k: v for k, v in posted.signals.model_dump().items() if k not in live}, "rooted": posted.device.rooted,
            "sim_changed_at": posted.device.sim_changed_at, "device_age_days": _device_age_days(posted.device.first_seen_at)}


@router.post("/signals", response_model=SignalsResponse)
def store_signals(
    body: SignalsRequest,
    uid: Annotated[str, Depends(require_user)],
    settings: Annotated[Settings, Depends(get_settings)],
    background: BackgroundTasks,
) -> SignalsResponse:
    started = time.perf_counter()
    # Held against (caller uid, session id), because /score carries none of this and the two calls are joined only
    # by that pair. See app.sessions for what this store is and is not.
    sessions.remember(uid, body, _now(), settings)
    # A call from a caller not in contacts has started: Apa's C0 pair, once per call, after the response (it waits on Gemini).
    if body.signals.call_state == "OFFHOOK" and body.signals.caller_in_contacts is not True and settings.call_start_pair_enabled:
        background.add_task(prerender.call_start_pair, body.session_id, uid, settings)
    audit.record("signals", uid, body.model_dump(mode="json"), {"stored": True}, (time.perf_counter() - started) * 1000)
    return SignalsResponse(stored=True)


@router.post("/score", response_model=ScoreResponse)
def score(
    body: ScoreRequest,
    uid: Annotated[str, Depends(require_user)],
    settings: Annotated[Settings, Depends(get_settings)],
    background: BackgroundTasks,
) -> ScoreResponse:
    started = time.perf_counter()
    # Scoring identity: the signed-in uid; body.user_id may differ only in demo mode, and then says so.
    identity = bind_identity("score", body.user_id, uid, settings)
    now = _now()
    session = sessions.recall(uid, body.session_id, now, settings)
    docs = _documents(body, settings, uid)
    user = docs["user"]
    flagged = _with_demo_state(body, docs.get("demo", {}))
    # What the phone itself posted joins the demo panel's flags; the answer names which was simulated.
    fused_flags, signal_sources = device_signals.fuse(flagged.demo_flags, device_signals.derive(session, now, settings))
    signals = _model_signals(session)
    # The payee at the server's scenario clock, before and with this transfer from the bound customer's account.
    payee = mule.screen_payee(body.txn, identity.user_id, scenario_now(settings))
    enriched = _with_scam_session(_with_model_signals(flagged.model_copy(update={"demo_flags": fused_flags}), payee), docs["scam"])
    # The latest App Safety Check verdict for this caller (US-1 S3): keyed on the authenticated uid, the same
    # identity /v1/appsafety/check stored it under, never on body.user_id. The stronger of the stored verdict and the
    # demo panel's flag wins, like the mule fuse.
    # The phone's own copy of that check counts only while it is valid (D3, D4): a stale or out-of-mode copy is dropped
    # here, before the fuse and the rules see it, and kept in the audit with the reason.
    ignored = appsafety_engine.stale_reason(body.app_safety, now, settings, uid) if body.app_safety is not None else None
    if ignored is not None:
        log.info("score uid=%s ignores the phone's app_safety: %s", uid, ignored)
        enriched = enriched.model_copy(update={"app_safety": None})
    enriched = appsafety_engine.with_latest_verdict(enriched, uid, settings)
    if enriched.app_safety is not None:  # what the phone reported, for FNA's warning after this score (never the verdict)
        appsafety_engine.remember_carried(uid, enriched.app_safety, settings)
    p95 = _p95_amount_for(identity.user_id, user, settings)
    stored = appsafety_engine.latest_verdict(uid)
    hits = evaluate(enriched, p95, settings, payee, stored_app_safety_risk=stored[1] if stored and stored[0] == "CAUTION" else None,
                    app_safety_facts=_block_facts(uid) if enriched.demo_flags.app_safety_verdict == "BLOCK" else ())
    if body.txn.type == "send_money" and interventions.money_lock_holds(docs["lock"], body.txn.amount_bdt, user):
        hits = (*hits, money_lock_hit())
    # Behaviour arrives as rule hits, not a score: decide() takes the decision and every
    # customer-visible reason from hits alone (see app.ato).
    hits += _behaviour_hits(enriched, session)
    live_holds = tuple(h for h in hits if h.decision == "hold")
    if body.txn.type == "pin_reset":
        hits += tuple(h for h in _pin_freeze_hits(docs["freeze"]) if h.reason.code not in {x.reason.code for x in hits})
    model_score = session_model.predict(enriched, signals, p95)
    # The session model speaks when no rule asks for more than an allow: an allow-only reason (APP_SAFETY_CAUTION) must
    # not silence it, or a suspicious app would turn the model's step-up into an allow.
    if all(h.decision == "allow" for h in hits) and model_score >= settings.band_high:
        hits = (*hits, model_hit(model_score))
    result = decide(enriched, hits, model_score, f"rules+{session_model.model_version()}", settings, payee)
    result = result.model_copy(update={"identity_source": identity.identity_source, "signal_sources": signal_sources})
    iid = None
    if result.decision in interventions.STATUS_FOR:
        iid = interventions.hold_id(body, result)
        result = interventions.with_intervention_id(result, iid, user.get("trusted_contact_uid"))
        background.add_task(interventions.record, body, result, iid, settings)  # after the response: keeps scoring fast
    if any(a.type == "freeze_pin_reset" for a in result.actions) and live_holds:  # a hold kept by the freeze alone never extends it
        background.add_task(_record_pin_freeze, body.user_id, live_holds, settings, iid)
    if result.decision == "hold":  # Apa's warning for this call: fresh, stale, the call-start pair, or none (go cold)
        warning = prerender.for_hold(body.session_id, uid, prerender.hold_hash(docs["scam"], body.txn.type), doc=docs["warning"])
        result = result.model_copy(update={"warning": warning})
    inputs = enriched.model_dump()
    if ignored is not None:
        inputs["app_safety_ignored"] = {"reason": ignored, "sent": body.app_safety.model_dump()}
    audit.record("score", uid, inputs, result.model_dump(), (time.perf_counter() - started) * 1000)
    return result
