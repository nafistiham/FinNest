"""Firebase ID-token verification (FR-1). Bypassed when RISK_MW_AUTH_REQUIRED=false."""

from __future__ import annotations

import logging
from typing import Annotated

from fastapi import Depends, Header, HTTPException, status

from app.settings import Settings, get_settings

log = logging.getLogger(__name__)
DEMO_USER = "demo"


def _verify_firebase_token(token: str) -> str:
    try:
        import firebase_admin
        from firebase_admin import auth as fb_auth

        if not firebase_admin._apps:  # noqa: SLF001 - documented idempotent init check
            firebase_admin.initialize_app()
        return str(fb_auth.verify_id_token(token)["uid"])
    except Exception as exc:  # noqa: BLE001 - any failure is an auth failure to the caller
        log.warning("firebase token rejected: %s", exc.__class__.__name__)
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "invalid or expired Firebase ID token") from exc


def require_user(
    settings: Annotated[Settings, Depends(get_settings)],
    authorization: Annotated[str | None, Header()] = None,
    x_demo_user: Annotated[str | None, Header()] = None,
) -> str:
    """Return the caller's uid. In demo mode, trust the X-Demo-User header (or 'demo')."""
    if not settings.auth_required:
        return x_demo_user or DEMO_USER
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "missing bearer token")
    return _verify_firebase_token(authorization.split(" ", 1)[1].strip())
