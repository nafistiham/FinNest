"""/v1/appsafety/check - the App Safety Check (rules, permission classifier, Play Integrity, Gemini triage).

The route is deliberately thin: `app.appsafety_engine.check` does the work and `bhorosha_app_safety_check` holds the logic.
"""

from __future__ import annotations

import time
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query, Request, status

from app import appsafety_engine, audit, ratelimit
from app.auth import require_user
from app.contracts import AppSafetyLatest, AppSafetyRequest, AppSafetyResponse, DemoIntegrityRequest, DemoIntegrityResponse
from app.ratelimit import enforce
from app.settings import Settings, get_settings

router = APIRouter(prefix="/v1/appsafety", tags=["appsafety"])


# Under the default quota only. The Gemini quota (the caller's 30/min and the 90/min every caller shares) is spent inside
# the engine, right before the model call, and only when the check has something to triage: a clean phone, which is
# most of them at login and before every transfer, costs no Gemini slot (review finding 2026-10-16: four judges clicking
# through clean demos used to drain the shared bucket and 429 the next /v1/scam/turn). Out of quota, the check still
# answers, from the rules, never 429.
@router.post("/check", response_model=AppSafetyResponse)
def check(
    body: AppSafetyRequest,
    request: Request,
    uid: Annotated[str, Depends(require_user)],
    settings: Annotated[Settings, Depends(get_settings)],
) -> AppSafetyResponse:
    started = time.perf_counter()
    result = appsafety_engine.check(body, uid, settings, admit=lambda: ratelimit.admit(request, ratelimit.GENAI_BUCKETS))
    audit.record("appsafety", uid, body.model_dump(), result.model_dump(), (time.perf_counter() - started) * 1000)
    return result


@router.post("/demo-token", response_model=DemoIntegrityResponse, dependencies=[Depends(enforce("default"))])
def demo_token(
    body: DemoIntegrityRequest,
    uid: Annotated[str, Depends(require_user)],
    settings: Annotated[Settings, Depends(get_settings)],
) -> DemoIntegrityResponse:
    """Demo mode only. The app's demo panel asks for a signed synthetic Play Integrity verdict bound to the exact bundle it
    will send next; outside demo mode the route does not exist for callers (404), so the secret never leaves the server."""
    if not settings.demo_mode:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "not available outside demo mode")
    return appsafety_engine.mint_demo_token(body, settings)


@router.get("/latest/{target_uid}", response_model=AppSafetyLatest, dependencies=[Depends(enforce("default"))])
def latest(
    target_uid: str,
    uid: Annotated[str, Depends(require_user)],
    settings: Annotated[Settings, Depends(get_settings)],
    include_phone: Annotated[bool, Query(description="Case Zero: fall back to the phone's last valid report (source phone)")] = False,
) -> AppSafetyLatest:
    """The verdict this service currently holds for a uid: what /v1/risk/score will act on. For Case Zero and the
    fraud desk to fold the phone's state into a consolidated decision without re-running the check.

    Once Firebase auth is required, a customer may read only their own verdict; service callers named in
    RISK_MW_APPSAFETY_LATEST_READERS may read any. In demo mode every caller is a demo persona and may read any."""
    if settings.auth_required and uid != target_uid and uid not in settings.appsafety_latest_readers:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "not allowed to read another customer's app-safety verdict")
    return appsafety_engine.latest_for(target_uid, include_phone=include_phone, settings=settings)
