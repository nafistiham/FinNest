"""/v1/apa/warning/{session_id}, /v1/apa/clips/{clip_id}, /v1/apa/warning/stream: Apa's prepared warning.

The phone fetches the warning prepared for its call (C0, C1) and caches its clips, so a hold plays local audio; the stream is
the cold path (C2) when nothing fresh is on the phone. Everything is per call and per account. docs/apa_warning_contract.md is
the phone's side of this.
"""

from __future__ import annotations

import json
import time
from collections.abc import Iterator
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Response, status
from fastapi.responses import StreamingResponse

from app import audit, prerender
from app.auth import require_user
from app.contracts import ApaWarning, ApaWarningStreamRequest
from app.ratelimit import GENAI_QUOTA
from app.settings import Settings, get_settings

router = APIRouter(prefix="/v1/apa", tags=["apa"])

NDJSON = "application/x-ndjson"
CLIP_CACHE = f"private, max-age={prerender.CLIP_TTL_S}, immutable"  # a clip id is never reused for other audio


@router.get("/warning/{session_id}", response_model=ApaWarning, responses={204: {"description": "Nothing prepared for this call yet."}})
def latest_warning(session_id: str, uid: Annotated[str, Depends(require_user)]) -> ApaWarning | Response:
    """The latest warning prepared for this call of this account: its ledger hash, stage, lines and clip ids. Polled during a
    risky call, so it reads one document and writes nothing (no audit row)."""
    prepared = prerender.latest(session_id, uid)
    return prepared.contract() if prepared else Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get("/clips/{clip_id}", response_class=Response, responses={
    200: {"content": {"audio/ogg": {}, "audio/wav": {}}, "description": "One line's audio: OGG Opus, or WAV 24 kHz mono 16-bit."},
    404: {"description": "No such clip, expired, or (with auth on) another account's."},
})
def clip_audio(clip_id: str, uid: Annotated[str, Depends(require_user)], settings: Annotated[Settings, Depends(get_settings)]) -> Response:
    found = prerender.clip(clip_id, uid if settings.auth_required else None)
    if found is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "no such clip")
    audio, mime = found
    return Response(content=audio, media_type=mime, headers={"Cache-Control": CLIP_CACHE})


def _ndjson(records: Iterator[dict], uid: str, body: ApaWarningStreamRequest, started: float) -> Iterator[bytes]:
    final: dict = {}
    for record in records:
        final = record
        yield (json.dumps(record, ensure_ascii=False) + "\n").encode()
    audit.record("apa_warning_stream", uid, body.model_dump(), final, (time.perf_counter() - started) * 1000)


@router.post("/warning/stream", response_class=StreamingResponse, dependencies=[Depends(GENAI_QUOTA)], responses={
    200: {"content": {NDJSON: {}}, "description": "One ApaLine per line as it validates and is rendered (clip_id null and "
                                                  "speak_on_device true when TTS is rate-limited or off), then a final "
                                                  "{done, earcon, vibrate, lines, warning_id, ledger_hash}. lines 0: the floor."},
})
def warning_stream(
    body: ApaWarningStreamRequest,
    uid: Annotated[str, Depends(require_user)],
    settings: Annotated[Settings, Depends(get_settings)],
) -> StreamingResponse:
    """The cold path (C2): a hold with no fresh warning on the phone. A fresh prepared warning is sent as it is."""
    started = time.perf_counter()
    records = prerender.cold_stream(body.session_id, uid, body.pending_action, settings, body.skip_roles)
    return StreamingResponse(_ndjson(records, uid, body, started), media_type=NDJSON, headers={"Cache-Control": "no-store"})
