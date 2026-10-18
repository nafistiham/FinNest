"""/v1/scam/transcribe and /v1/scam/live: caller speech to the transcript turn /v1/scam/turn takes (spec US-5).

- POST /v1/scam/transcribe (file mode): one recorded utterance in, one turn out. 503 unless
  RISK_MW_TRANSCRIPTION_ENABLED=true and Gemini is on.
- WS /v1/scam/live (live bridge): the app streams 16 kHz 16-bit mono PCM as binary frames and gets each finished
  caller utterance back as a JSON turn; a text frame "end" closes it. Closed unless
  RISK_MW_LIVE_TRANSCRIPTION_ENABLED=true and Gemini is on, and capped by the session time and byte limits.
Both are off by default and in deploy.sh since 2026-10-17 (FinNest does not listen to phone calls), so the transcript-first
path drives the demo with no code change.
"""

from __future__ import annotations

import asyncio
import base64
import binascii
import json
import logging
import math
import time
from contextlib import AsyncExitStack
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, WebSocket, status
from starlette.websockets import WebSocketState

from app import audit, genai_client, speech
from app.auth import require_user
from app.ratelimit import GENAI_QUOTA
from app.contracts import TranscribeRequest, Turn
from app.settings import Settings, get_settings

log = logging.getLogger(__name__)
router = APIRouter(prefix="/v1/scam", tags=["speech"])

FALLBACK = "use the transcript-first path"
REJECTED_STATUS = {speech.AudioTooLarge: 413, speech.UnsupportedAudioType: 415, speech.EmptyAudio: 422}
MAX_B64_CHARS = 4 * math.ceil(speech.MAX_AUDIO_BYTES / 3)


@router.post("/transcribe", response_model=Turn, dependencies=[Depends(GENAI_QUOTA)])
def transcribe(
    body: TranscribeRequest,
    uid: Annotated[str, Depends(require_user)],
    settings: Annotated[Settings, Depends(get_settings)],
) -> Turn:
    started = time.perf_counter()
    if not settings.transcription_enabled:
        raise HTTPException(503, f"speech transcription is off (RISK_MW_TRANSCRIPTION_ENABLED); {FALLBACK}")
    if len(body.audio_b64) > MAX_B64_CHARS:
        raise HTTPException(413, f"audio is over the {speech.MAX_AUDIO_BYTES} byte limit")
    try:
        audio = base64.b64decode(body.audio_b64, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise HTTPException(422, "audio_b64 is not valid base64") from exc
    try:
        result = speech.transcribe_call(audio, body.mime_type, settings)
    except speech.AudioRejected as exc:
        raise HTTPException(REJECTED_STATUS.get(type(exc), 422), str(exc)) from exc
    except genai_client.GenAIDisabled as exc:
        raise HTTPException(503, f"speech transcription needs Gemini ({exc}); {FALLBACK}") from exc
    except Exception as exc:  # noqa: BLE001 - a failed or slow transcription is the app's cue to fall back, never a 500
        log.warning("transcription failed: %s", exc.__class__.__name__)
        raise HTTPException(502, f"transcription failed; {FALLBACK}") from exc
    turn = Turn(speaker="caller", text=result.text, ts=body.ts if body.ts is not None else round(time.time(), 3))
    audit.record("scam_transcribe", uid, {"session_id": body.session_id, "mime_type": body.mime_type, "audio_bytes": len(audio)},
                 {**turn.model_dump(), "model_id": result.model_id, "cost_usd": result.cost_usd}, (time.perf_counter() - started) * 1000)
    return turn


# --- live bridge ---------------------------------------------------------------------------------------


def live_factory() -> speech.LiveFactory:
    """The Gemini Live client behind the bridge; tests swap in a fake through dependency_overrides."""
    return speech.gemini_live


def _is_end(text: str) -> bool:
    try:
        data = json.loads(text)
    except ValueError:
        data = text.strip()
    return data == "end" or (isinstance(data, dict) and data.get("type") == "end")


ENDED_BY_APP = "ended by the app"
LIVE_QUIET_AFTER_TURN_S = 1.5  # once a final transcription has come back after "end", this much quiet closes the bridge


async def _relay(websocket: WebSocket, transcriber: speech.LiveTranscriber, settings: Settings, stats: dict[str, int]) -> tuple[int, str]:
    """Audio in, turns out, until the app ends the stream or hangs up, or a limit is hit. Returns the close code and reason."""

    async def audio_in() -> tuple[int, str]:
        while True:
            message = await websocket.receive()
            if message["type"] == "websocket.disconnect":
                return status.WS_1000_NORMAL_CLOSURE, "the app hung up"
            chunk = message.get("bytes")
            if chunk is None:
                if _is_end(message.get("text") or ""):
                    return status.WS_1000_NORMAL_CLOSURE, ENDED_BY_APP
                continue
            if stats["audio_bytes"] + len(chunk) > settings.live_max_bytes:
                return status.WS_1009_MESSAGE_TOO_BIG, f"session byte limit reached; {FALLBACK}"
            stats["audio_bytes"] += len(chunk)
            await transcriber.send_audio(chunk)

    new_turn = asyncio.Event()

    async def turns_out() -> tuple[int, str]:
        async for text in transcriber.transcripts():
            await websocket.send_json(Turn(speaker="caller", text=text, ts=round(time.time(), 3)).model_dump())
            stats["turns"] += 1
            new_turn.set()
        return status.WS_1000_NORMAL_CLOSURE, "transcription ended"

    async def drain(reader: asyncio.Task) -> None:
        """After the app ends the stream: ask Live for the last transcription and relay what comes, within live_drain_s."""
        await transcriber.end_audio()
        loop = asyncio.get_running_loop()
        deadline, heard = loop.time() + settings.live_drain_s, False
        while not reader.done() and (left := deadline - loop.time()) > 0:
            new_turn.clear()
            try:
                await asyncio.wait_for(new_turn.wait(), timeout=min(left, LIVE_QUIET_AFTER_TURN_S) if heard else left)
            except TimeoutError:
                return
            heard = True

    reader = asyncio.create_task(turns_out())
    tasks = [asyncio.create_task(audio_in()), reader]
    try:
        done, _ = await asyncio.wait(tasks, timeout=settings.live_max_session_s, return_when=asyncio.FIRST_COMPLETED)
        if done and tasks[0] in done and not tasks[0].exception() and tasks[0].result()[1] == ENDED_BY_APP:
            await drain(reader)
    finally:
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
    if not done:
        return status.WS_1008_POLICY_VIOLATION, f"session time limit reached; {FALLBACK}"
    return next(iter(done)).result()


@router.websocket("/live")
async def live(
    websocket: WebSocket,
    uid: Annotated[str, Depends(require_user)],
    settings: Annotated[Settings, Depends(get_settings)],
    factory: Annotated[speech.LiveFactory, Depends(live_factory)],
    session_id: str = "",
) -> None:
    if not settings.live_transcription_enabled:
        await websocket.close(code=status.WS_1008_POLICY_VIOLATION, reason=f"live transcription is off; {FALLBACK}")
        return
    started, stats = time.perf_counter(), {"audio_bytes": 0, "turns": 0}
    async with AsyncExitStack() as stack:
        try:
            transcriber = await stack.enter_async_context(factory(settings))
        except genai_client.GenAIDisabled:
            await websocket.close(code=status.WS_1013_TRY_AGAIN_LATER, reason=f"live transcription needs Gemini; {FALLBACK}")
            return
        except Exception as exc:  # noqa: BLE001 - Live unreachable: refuse, the app falls back
            log.warning("live session failed to open: %s", exc.__class__.__name__)
            await websocket.close(code=status.WS_1013_TRY_AGAIN_LATER, reason=f"live transcription unavailable; {FALLBACK}")
            return
        await websocket.accept()
        try:
            code, reason = await _relay(websocket, transcriber, settings, stats)
        except Exception as exc:  # noqa: BLE001 - a broken Live session ends the bridge, never the service
            log.warning("live bridge failed: %s", exc.__class__.__name__)
            code, reason = status.WS_1011_INTERNAL_ERROR, f"transcription failed; {FALLBACK}"
        if websocket.client_state == WebSocketState.CONNECTED:
            await websocket.close(code=code, reason=reason)
        cost = float(getattr(transcriber, "cost_usd", 0.0))
    audit.record("scam_live", uid, {"session_id": session_id}, {**stats, "close": reason, "cost_usd": cost}, (time.perf_counter() - started) * 1000)
