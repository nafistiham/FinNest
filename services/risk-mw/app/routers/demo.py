"""/v1/demo/state/{uid}: the demo control panel's flags (spec FR-6), demo mode only, for a signed-in caller when auth is on.

The video is recorded on an emulator, so call state, SIM swap, screen share and the rest come from
`demo_state/{uid}` instead of the phone. The app may write Firestore directly; this route does the same
for the web demo and for runs without Firestore.
"""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, status

from app import state
from app.auth import require_user
from app.contracts import DemoFlags
from app.settings import Settings, get_settings

router = APIRouter(prefix="/v1/demo", tags=["demo"])
COLLECTION = "demo_state"


def _demo_only(settings: Annotated[Settings, Depends(get_settings)]) -> None:
    if not settings.demo_mode:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "demo controls are off")


# Demo mode first (404 when off), then a signed-in caller like every other route: with auth on, an anonymous PUT
# could otherwise set any user's flags and turn their sends into blocks.
GUARDS = [Depends(_demo_only), Depends(require_user)]


@router.get("/state/{uid}", response_model=DemoFlags, dependencies=GUARDS)
def get_state(uid: str) -> DemoFlags:
    return DemoFlags(**state.store().get(COLLECTION, uid))


@router.put("/state/{uid}", response_model=DemoFlags, dependencies=GUARDS)
def put_state(uid: str, body: DemoFlags) -> DemoFlags:
    state.store().set(COLLECTION, uid, body.model_dump())
    return body


@router.delete("/state/{uid}", dependencies=GUARDS)
def clear_state(uid: str) -> dict[str, bool]:
    state.store().delete(COLLECTION, uid)
    state.store().delete("pin_freeze", uid)  # risk.PIN_FREEZE: a cleared panel starts the next take unfrozen
    return {"cleared": True}
