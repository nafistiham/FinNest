"""/v1/mule/score/{acct_id} and /v1/mule/demo-ring — the mule scorer exposed to the app and the investigator."""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, status

from app import mule
from app.auth import require_user
from app.clock import scenario_now
from app.contracts import MuleScoreResponse
from app.settings import Settings, get_settings

router = APIRouter(prefix="/v1/mule", tags=["mule"])


@router.get("/score/{acct_id}", response_model=MuleScoreResponse)
def score(acct_id: str, uid: Annotated[str, Depends(require_user)], settings: Annotated[Settings, Depends(get_settings)]) -> MuleScoreResponse:
    """The account's score on the evidence before the server's scenario clock (`as_of` in the answer); a caller cannot pick the time."""
    loaded = mule.model()
    if loaded is None:
        return MuleScoreResponse(acct_id=acct_id, known=False, probability=0.0, reasons=(), model_version="off", as_of=None)
    return MuleScoreResponse(**loaded.score_at(acct_id, scenario_now(settings)))


@router.get("/demo-ring", response_model=dict[str, list[str]])
def demo_ring(uid: Annotated[str, Depends(require_user)]) -> dict[str, list[str]]:
    loaded = mule.model()
    if loaded is None:
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, "mule scorer artefacts are not loaded")
    return loaded.demo_ring()
