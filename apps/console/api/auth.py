"""Demo-grade sign-in for the console.

What this is: one operator account, a password checked server-side with PBKDF2, and a signed token
with an expiry. Enough that the console is not world-readable the moment it has a URL, and enough
to build the whole signed-in shell against.

What this is not: production auth. There is one account, no roles, no reset, no lockout, no
rotation. The production path is Firebase Auth with custom claims (`analyst`, `manager`,
`scientist`, `compliance`) enforced on every route. Nothing here should outlive that.

Configure with environment variables:

    ADMIN_USER        the one operator account; default "admin"
    ADMIN_PASSWORD    its password
    SESSION_SECRET    the key that signs tokens and salts the password hash
    TOKEN_HOURS       token lifetime in hours; default 12

For local development ADMIN_PASSWORD and SESSION_SECRET fall back to the labelled defaults
below, with a warning in the log. On Cloud Run (K_SERVICE is set) the module refuses to load
without real values, so a deployed console can never accept the local-dev password.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import logging
import os
import time
from typing import Annotated, Any

from fastapi import Depends, HTTPException, Request, status

log = logging.getLogger("auth")

# Local development only. Never valid on Cloud Run: see _require_real_values_when_deployed.
LOCAL_DEV_PASSWORD = "finnest-local-dev"
LOCAL_DEV_SECRET = "local-dev-secret-not-for-production"

USER = os.environ.get("ADMIN_USER") or "admin"
PASSWORD = os.environ.get("ADMIN_PASSWORD") or LOCAL_DEV_PASSWORD
SECRET = os.environ.get("SESSION_SECRET") or LOCAL_DEV_SECRET
TOKEN_HOURS = int(os.environ.get("TOKEN_HOURS") or "12")


def _require_real_values_when_deployed() -> None:
    """Refuse the local-dev password or secret when running as a Cloud Run service."""
    if not os.environ.get("K_SERVICE"):
        if PASSWORD == LOCAL_DEV_PASSWORD or SECRET == LOCAL_DEV_SECRET:
            log.warning("ADMIN_PASSWORD or SESSION_SECRET is unset; using the local-dev defaults")
        return
    missing = [name for name, value, default in (("ADMIN_PASSWORD", PASSWORD, LOCAL_DEV_PASSWORD),
                                                 ("SESSION_SECRET", SECRET, LOCAL_DEV_SECRET))
               if value == default]
    if missing:
        raise RuntimeError(f"refusing to start on Cloud Run without {', '.join(missing)}")


_require_real_values_when_deployed()


def _b64(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def _unb64(value: str) -> bytes:
    return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))


def _sign(payload: bytes) -> str:
    return _b64(hmac.new(SECRET.encode(), payload, hashlib.sha256).digest())


def check_password(username: str, password: str) -> bool:
    """Constant-time on both fields, so a wrong username and a wrong password cost the same."""
    user_ok = hmac.compare_digest(username.strip(), USER)
    expected = hashlib.pbkdf2_hmac("sha256", PASSWORD.encode(), SECRET.encode(), 120_000)
    given = hashlib.pbkdf2_hmac("sha256", password.encode(), SECRET.encode(), 120_000)
    return hmac.compare_digest(expected, given) and user_ok


def issue(username: str) -> dict[str, Any]:
    now = int(time.time())
    expires = now + TOKEN_HOURS * 3600
    payload = json.dumps({"sub": username, "iat": now, "exp": expires}, separators=(",", ":")).encode()
    body = _b64(payload)
    return {"token": f"{body}.{_sign(payload)}", "username": username, "expires_at": expires}


def verify(token: str) -> dict[str, Any] | None:
    try:
        body, signature = token.split(".", 1)
        payload = _unb64(body)
    except (ValueError, Exception):  # noqa: BLE001 - a malformed token is just an unauthenticated one
        return None
    if not hmac.compare_digest(_sign(payload), signature):
        return None
    try:
        claims = json.loads(payload)
    except json.JSONDecodeError:
        return None
    if claims.get("exp", 0) < time.time():
        return None
    return claims


def require_operator(request: Request) -> str:
    """Every /v1/admin route depends on this. The static console does not, so the login page loads."""
    header = request.headers.get("authorization", "")
    token = header[7:] if header.lower().startswith("bearer ") else ""
    claims = verify(token)
    if claims is None:
        raise HTTPException(
            status.HTTP_401_UNAUTHORIZED,
            "sign in to read the console",
            headers={"WWW-Authenticate": "Bearer"},
        )
    return str(claims["sub"])


Operator = Annotated[str, Depends(require_operator)]
