"""/v1/intervene, /v1/scam/turn, /v1/apa/turn, /v1/apa/why, /v1/apa/why-audio.

Gemini-backed when RISK_MW_GENAI_ENABLED=true; otherwise deterministic stubs that keep the
app and the video working. Apa's words are generated for the call by app.warnings; there is no fixed
line, and when no line validates the hold is the floor: earcon, vibration and the card, with no words.
"""

from __future__ import annotations

import logging
import time
from collections.abc import Iterator, Mapping
from itertools import chain
from typing import Annotated

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Request, Response, status
from fastapi.responses import StreamingResponse

from app import apa, audit, interventions, prerender, ratelimit, scam, state, tts, warnings
from app.auth import require_user
from app.identity import BoundIdentity, bind_identity
from app.contracts import (
    Action,
    ApaLine,
    ApaTurnRequest,
    ApaTurnResponse,
    ApaWhyAudioRequest,
    ApaWhyRequest,
    ApaWhyResponse,
    InterveneRequest,
    InterveneResponse,
    ScamTurnRequest,
    ScamTurnResponse,
)
from app.ratelimit import GENAI_QUOTA
from app.settings import Settings, get_settings

log = logging.getLogger(__name__)
router = APIRouter(prefix="/v1", tags=["intervention"])

INTERVENE_COOLDOWN_S = 300


def _hold(user_id: str, intervention_id: str | None, txn_id: str | None = None) -> tuple[str | None, dict]:
    """Her own hold: the intervention named, or the one transactions/{txn_id} points to; (None, {}) for anyone else's."""
    try:
        iid = intervention_id or (state.store().get("transactions", txn_id).get("intervention_id") if txn_id else None)
        doc = state.store().get("interventions", iid) if iid else {}
    except Exception as exc:  # noqa: BLE001 - a store that fails mid-hold costs the hold's link, never the answer
        log.warning("hold not read for apa's warning: %s", exc.__class__.__name__)
        return None, {}
    return (iid, doc) if doc.get("user_id") == user_id else (None, {})


def _signed(lines: tuple[warnings.WarningLine, ...], settings: Settings, clips: Mapping[str, str] | None = None) -> tuple[ApaLine, ...]:
    """Each validated line with its own token, so /v1/apa/why-audio can speak that line and nothing else, and its pre-rendered
    clip when the warning was prepared before the hold (else the phone speaks it)."""
    out = []
    for line in lines:
        token, expires = apa.sign_why(line.text_bn, settings) if tts.speakable(line.text_bn) else (None, None)
        clip = (clips or {}).get(line.role)
        out.append(ApaLine(role=line.role, text_bn=line.text_bn, text_en=line.text_en, token=token,
                           expires_at=expires.isoformat() if expires else None, clip_id=clip, speak_on_device=clip is None))
    return tuple(out)


def _own(route: str, body_user: str, uid: str, settings: Settings) -> BoundIdentity:
    """Her address, her call and her hold are hers alone: with auth on, a body user_id naming anyone else is a 403 and an
    audit row (app.identity); in demo mode the body's user_id is taken at its word and the answer says so."""
    return bind_identity(route, body_user, uid, settings)


@router.post("/intervene", response_model=InterveneResponse)
def intervene(
    body: InterveneRequest,
    request: Request,
    uid: Annotated[str, Depends(require_user)],
    settings: Annotated[Settings, Depends(get_settings)],
) -> InterveneResponse:
    """Apa's warning for this hold, written for this call from validated evidence, with the card and the actions. With no
    call, phone or behaviour facts it says why the hold was made: the reasons recorded on the hold, else the trigger.

    The text is the validated lines joined, with audio_token: the phone asks /v1/apa/why-audio for the whole warning once, in
    Apa's Gemini voice (no audio is rendered before the warning is given); the same evidence again reuses the warning without
    a model call. With no validated text the answer is the floor: earcon and
    vibration, no words. The Gemini quota is spent only when the model is called, and a refusal never fails the hold.
    """
    started = time.perf_counter()
    identity = _own("intervene", body.user_id, uid, settings)  # 403 if a verified caller names another
    iid, held = _hold(identity.user_id, body.intervention_id, body.txn.txn_id)
    out = warnings.compose(uid, identity.user_id, body.session_id or held.get("session_id"), body.txn.type, settings, intervention_id=iid,
                           snippet=body.transcript_snippet, admit=lambda: ratelimit.admit(request, ratelimit.GENAI_BUCKETS),
                           hold=warnings.hold_facts(held.get("reason_codes"), body.trigger))
    lines = _signed(out.warning.lines, settings, out.clips)
    actions = (
        Action(type="freeze_pin_reset", params={"minutes": settings.pin_reset_freeze_minutes})
        if body.txn.type == "pin_reset"
        else Action(type="delay_new_payee", params={"minutes": settings.new_payee_delay_minutes}),
        Action(type="trusted_contact_check", params={"expires_in_minutes": settings.trusted_contact_expiry_minutes}),
    )
    # Owned by the caller: the id a trusted-contact request names. It carries her hold, so the contact's answer settles it.
    opened = interventions.STORE.open(uid, body.trigger, hold_id=iid)
    whole = out.warning.script_bn
    audio = apa.sign_why(whole, settings) if whole and tts.speakable(whole, apa.WARNING_MAX_CHARS) else None
    result = InterveneResponse(intervene=True, script_bn=out.warning.script_bn, script_en=out.warning.script_en, audio_asset_id=None,
                               ui=apa.ui_for(body.trigger), actions=actions, cooldown_s=INTERVENE_COOLDOWN_S, lines=lines, earcon=True,
                               vibrate=True, speak_on_device=any(l.speak_on_device for l in lines), warning_id=out.warning_id, ledger_hash=out.ledger_hash,
                               intervention_id=opened.intervention_id, identity_source=identity.identity_source,
                               audio_token=audio[0] if audio else None, audio_expires_at=audio[1].isoformat() if audio else None)
    w = out.warning
    trace = {"dropped": [{"role": r, "rule": why} for r, why in w.dropped], "regenerated": w.regenerated, "reused": w.reused,
             "cached": out.cached, "timings_ms": dict(w.timings_ms)}  # maps, not nested arrays: the audit row is a Firestore document
    audit.record("intervene", uid, body.model_dump(), {**result.model_dump(), **trace}, (time.perf_counter() - started) * 1000)
    return result


@router.post("/apa/why", response_model=ApaWhyResponse)
def apa_why(
    body: ApaWhyRequest,
    request: Request,
    uid: Annotated[str, Depends(require_user)],
    settings: Annotated[Settings, Depends(get_settings)],
) -> ApaWhyResponse:
    """Apa's warning from the composer, on demand (a refresh while the call goes on, or the app asking again). Each line has its
    own token for /v1/apa/why-audio; the joined text has one too when it is short enough to speak whole."""
    started = time.perf_counter()
    identity = _own("apa_why", body.user_id, uid, settings)
    iid, held = _hold(identity.user_id, body.intervention_id)
    pending = body.pending_action or (held.get("txn") or {}).get("type")
    out = warnings.compose(uid, identity.user_id, body.session_id or held.get("session_id"), pending, settings, intervention_id=iid,
                           snippet=body.transcript_snippet, admit=lambda: ratelimit.admit(request, ratelimit.GENAI_BUCKETS),
                           hold=warnings.hold_facts(held.get("reason_codes"), body.trigger))
    result = ApaWhyResponse()
    if out.warning.lines:
        text_bn = out.warning.script_bn
        signed = apa.sign_why(text_bn, settings) if tts.speakable(text_bn, apa.WARNING_MAX_CHARS) else None
        result = ApaWhyResponse(explanation_bn=text_bn, explanation_en=out.warning.script_en, token=signed[0] if signed else None,
                                expires_at=signed[1].isoformat() if signed else None, lines=_signed(out.warning.lines, settings, out.clips))
    audit.record("apa_why", uid, body.model_dump(), result.model_dump(), (time.perf_counter() - started) * 1000)
    return result


@router.post("/scam/turn", response_model=ScamTurnResponse, dependencies=[Depends(GENAI_QUOTA)])
def scam_turn(
    body: ScamTurnRequest,
    background: BackgroundTasks,
    uid: Annotated[str, Depends(require_user)],
    settings: Annotated[Settings, Depends(get_settings)],
) -> ScamTurnResponse:
    started = time.perf_counter()
    result = scam.score_turn(body, settings, uid)
    # After the answer: Apa's warning for this evidence is written and rendered before any hold (P0 item 6, C1).
    background.add_task(prerender.after_turn, body.session_id, uid, body.pending_action, settings,
                        caller_turns=tuple(t.text for t in body.turns if t.speaker == "caller"))
    audit.record("scam_turn", uid, body.model_dump(), result.model_dump(), (time.perf_counter() - started) * 1000)
    return result


@router.post("/apa/turn", response_model=ApaTurnResponse)
def apa_turn(
    body: ApaTurnRequest,
    uid: Annotated[str, Depends(require_user)],
    settings: Annotated[Settings, Depends(get_settings)],
) -> ApaTurnResponse:
    started = time.perf_counter()
    identity = _own("apa_turn", body.user_id, uid, settings)
    # Apa's conversation is not built yet. Until it is, this stub says nothing: Apa has no fixed words (owner, 2026-10-17).
    result = ApaTurnResponse(reply_bn="", reply_en="", tool_calls=())
    outputs = {**result.model_dump(), "identity_source": identity.identity_source}
    audit.record("apa_turn", uid, body.model_dump(), outputs, (time.perf_counter() - started) * 1000)
    return result


WAV = "audio/wav"


def _quiet(rest: Iterator[bytes]) -> Iterator[bytes]:
    """A stream that fails after the first chunk just ends; the app has already played what it got."""
    try:
        yield from rest
    except Exception as exc:  # noqa: BLE001 - headers are sent, so there is no status left to change
        log.warning("why-audio stream cut: %s", exc.__class__.__name__)


@router.post("/apa/why-audio", status_code=200, response_class=StreamingResponse, dependencies=[Depends(GENAI_QUOTA)], responses={
    200: {"content": {WAV: {}}, "description": "WAV, 24 kHz mono 16-bit PCM, streamed. A live stream's header has RIFF and data sizes "
                                                "0xFFFFFFFF (length unknown); a cached line's header has the exact sizes."},
    204: {"description": "No live audio (TTS off, over its spend cap, rate-limited or failing): the phone speaks the text itself."},
    403: {"description": "token is missing, expired, or was not issued with this exact text_bn (by /v1/intervene or /v1/apa/why)."},
    422: {"description": "text_bn is not a line Apa may speak."},
})
def apa_why_audio(
    body: ApaWhyAudioRequest,
    uid: Annotated[str, Depends(require_user)],
    settings: Annotated[Settings, Depends(get_settings)],
) -> Response:
    """Speak one of Apa's validated lines (US-3 S2). The reply starts only once the first audio is in hand;
    a failure before it is still a 204.

    Only text this server validated and signed (a line from /v1/intervene or /v1/apa/why) is spoken: Apa's voice must not
    say whatever a caller sends (a vishing line, say).
    """
    started = time.perf_counter()
    if not apa.verify_why(body.text_bn, body.token, settings):
        audit.record("apa_why_audio", uid, body.model_dump(), {"status": 403}, (time.perf_counter() - started) * 1000)
        raise HTTPException(status.HTTP_403_FORBIDDEN, "text_bn needs the unexpired token issued with it")
    if not tts.speakable(body.text_bn, apa.WARNING_MAX_CHARS):  # a line, or a whole warning the server signed
        raise HTTPException(422, "text_bn is not a line Apa may speak")
    try:
        audio = tts.say(body.text_bn, settings)
    except tts.Unavailable as exc:
        log.info("why-audio unavailable: %s", exc)
        audit.record("apa_why_audio", uid, body.model_dump(), {"status": 204, "reason": str(exc)}, (time.perf_counter() - started) * 1000)
        return Response(status_code=status.HTTP_204_NO_CONTENT)
    audit.record("apa_why_audio", uid, body.model_dump(), {"status": 200, "cached": audio.cached}, (time.perf_counter() - started) * 1000)
    return StreamingResponse(chain((tts.wav_header(audio.total_bytes), audio.first), _quiet(audio.rest)), media_type=WAV)
