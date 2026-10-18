"""Whose request is this.

With auth on, the uid from the verified Firebase token is the only identity: a body user_id naming anyone else is a
403 and an audit row. With auth off (demo mode) the caller is whoever X-Demo-User says, the body user_id is taken at
its word (the app's persona picker sends ids such as "acct_rina"), and every answer that depends on it says
`identity_source: "demo"` so nobody mistakes a persona picker for a sign-in.
"""

from __future__ import annotations

from dataclasses import dataclass

from fastapi import HTTPException, status

from app import audit
from app.contracts import IdentitySource
from app.settings import Settings

VERIFIED: IdentitySource = "verified"
DEMO: IdentitySource = "demo"
MISMATCH_DETAIL = "user_id must be the signed-in user"


@dataclass(frozen=True)
class BoundIdentity:
    user_id: str  # the customer the request acts for: the signed-in uid, or in demo mode the body's user_id
    caller_uid: str  # who called: the session namespace and the audit row's uid
    identity_source: IdentitySource


def identity_source(settings: Settings) -> IdentitySource:
    return VERIFIED if settings.auth_required else DEMO


def is_demo(settings: Settings) -> bool:
    return identity_source(settings) == DEMO


def bind_identity(route: str, claimed_user_id: str, uid: str, settings: Settings) -> BoundIdentity:
    """The identity a request may act for, or 403 (audited) when a verified caller names someone else."""
    source = identity_source(settings)
    if source == VERIFIED and claimed_user_id != uid:
        audit.record(
            "identity_mismatch", uid, {"route": route, "claimed_user_id": claimed_user_id},
            {"status_code": status.HTTP_403_FORBIDDEN, "detail": MISMATCH_DETAIL}, 0.0,
        )
        raise HTTPException(status.HTTP_403_FORBIDDEN, MISMATCH_DETAIL)
    return BoundIdentity(user_id=claimed_user_id if source == DEMO else uid, caller_uid=uid, identity_source=source)
