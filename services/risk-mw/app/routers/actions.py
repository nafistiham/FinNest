"""/v1/actions: the trusted-contact check (spec US-4, US-6; who may call what) and Money Lock.

Trusted contact:
- create: the caller is the requester. The intervention is one the service opened for her (/v1/intervene returns its
  id) or a hold of hers (/v1/risk/score names it in the trusted_contact_check action): unknown 404, someone else's 403.
  In demo mode an id the server never issued (the app's local record id) is accepted and the audit row says
  `intervention_verified: false`. Only a hold or delay that offered the check can be asked about (409). The contact is
  the one on users/{owner}.trusted_contact_uid when there is one (a contact_uid naming anyone else is a 403), else the
  body's contact_uid; never the requester herself (422). Asking twice for the same hold and contact reuses one request.
  The contact gets an FCM push with bhorosha://approve/{id}, the amount and the reason.
- approve / decline: with auth on, only the uid named as contact_uid (403 for anyone else). In demo mode anyone may
  decide, because the app has no persona for the contact and sends the signed-in one; the answer and the audit row
  then say `contact_verified: false`.
- One transition under one lock: pending -> approved | declined | expired, never two winners. Every later call
  returns the settled state, who settled it and whether that was the contact. Every create and decision, refused or
  not (unknown ids included), writes an audit row.
- The hold follows the answer (spec FR-5): approving releases the held transaction and declining cancels it; the
  hold's other requests close the same way. Silence past expires_at expires the request and sends the hold to analyst
  review, which no later answer changes, and the transaction stays held. Overdue requests are handled when anything
  looks at them, and by /sweep for a scheduler (with auth on, only with the operator token).
- The store is bounded: settled and expired requests go before pending ones, and no requester holds more than
  app.bounded.PER_OWNER_LIMIT, so one caller cannot push another's pending request out.

Requests live in an in-process store until the Firestore `interventions` collection is wired (README "One instance, on
purpose"); holds, transactions and Money Lock live in app.state (Firestore or memory).

Money Lock: with auth on only the owner locks or unlocks, optionally on a sub-balance (locked_bdt), recorded in
interventions/{id}.
"""

from __future__ import annotations

import hashlib
import hmac
import threading
import time
from collections import OrderedDict
from dataclasses import dataclass, replace
from datetime import UTC, datetime, timedelta
from http import HTTPStatus
from typing import Annotated, Any, Literal, NoReturn

from fastapi import APIRouter, Depends, Header, HTTPException, status

from app import audit, bounded, interventions, notify, state
from app.auth import require_user
from app.contracts import (
    MoneyLockRequest,
    MoneyLockStatus,
    TrustedContactDecision,
    TrustedContactRequest,
    TrustedContactResponse,
    TrustedContactState,
    TrustedContactSweep,
)
from app.identity import identity_source, is_demo
from app.settings import Settings, get_settings

router = APIRouter(prefix="/v1/actions", tags=["actions"])

Status = Literal["approved", "declined", "expired", "pending"]
Verdict = Literal["approved", "declined"]
PENDING: Status = "pending"
EXPIRED: Status = "expired"
REQUEST_LIMIT = 2048  # a request lives ten minutes; app.bounded says what is dropped first past this
UNKNOWN_REQUEST = "unknown trusted-contact request"
OUTCOME = {"approved": "released", "declined": "cancelled"}  # what the contact's answer does to the hold
PUSH_BODY = "আপনার আপনজনের একটি লেনদেন আটকে রাখা হয়েছে। অ্যাপ খুলে অনুমোদন দিন বা বাতিল করুন।"
REASON_MAX_CHARS = 200


@dataclass(frozen=True)
class ContactRequest:
    request_id: str
    intervention_id: str
    requester_uid: str
    contact_uid: str
    expires_at: datetime
    status: Status
    decided_by: str | None = None
    intervention_verified: bool = True
    contact_verified: bool | None = None  # whether decided_by is contact_uid; None until someone decides
    hold_id: str | None = None  # The interventions/{id} hold this request settles; None for an unlinked intervention
    push: str = "disabled"  # How the contact's push went ("sent", "no_token", "disabled", "error")


@dataclass(frozen=True)
class Settlement:
    request: ContactRequest
    won: bool  # True only for the one call that moved the request out of pending


def _requester_of(_key: str, item: ContactRequest) -> str:
    return item.requester_uid


def _settled_or_expired(item: ContactRequest, now: datetime) -> bool:
    return item.status != PENDING or now > item.expires_at


class RequestStore:
    """Each change replaces a record with a new frozen one; settle() is the only transition, under one lock."""

    def __init__(self, limit: int = REQUEST_LIMIT) -> None:
        self._limit = limit
        self._items: OrderedDict[str, ContactRequest] = OrderedDict()
        self._lock = threading.Lock()

    def add(self, item: ContactRequest, now: datetime) -> ContactRequest:
        with self._lock:
            self._items[item.request_id] = item
            bounded.make_room(
                self._items, item.request_id, owner_of=_requester_of, limit=self._limit,
                is_stale=lambda other: _settled_or_expired(other, now),
            )
        return item

    def get(self, request_id: str) -> ContactRequest | None:
        with self._lock:
            return self._items.get(request_id)

    def pending(self) -> tuple[ContactRequest, ...]:
        with self._lock:
            return tuple(item for item in self._items.values() if item.status == PENDING)

    def settle(
        self, request_id: str, verdict: Verdict, decided_by: str, now: datetime, *, contact_verified: bool = True,
    ) -> Settlement | None:
        """Move a pending request to `verdict` (or to expired once past expires_at); a settled one is returned as is."""
        with self._lock:
            current = self._items.get(request_id)
            if current is None:
                return None
            if current.status != PENDING:
                return Settlement(current, won=False)
            updated = (
                replace(current, status=EXPIRED)
                if now > current.expires_at
                else replace(current, status=verdict, decided_by=decided_by, contact_verified=contact_verified)
            )
            self._items[request_id] = updated
            return Settlement(updated, won=True)

    def expire(self, request_id: str, now: datetime) -> Settlement | None:
        """Expire a pending request whose window has passed; anything else is returned as is (won=False)."""
        with self._lock:
            current = self._items.get(request_id)
            if current is None:
                return None
            if current.status != PENDING or now <= current.expires_at:
                return Settlement(current, won=False)
            updated = replace(current, status=EXPIRED)
            self._items[request_id] = updated
            return Settlement(updated, won=True)

    def close_others(self, hold_id: str, request_id: str, verdict: Status, now: datetime) -> tuple[str, ...]:
        """Once a hold has ended, its other pending requests settle the same way: a later tap on them decides nothing."""
        closed = []
        with self._lock:
            for key, item in self._items.items():
                if item.hold_id == hold_id and key != request_id and item.status == PENDING:
                    self._items[key] = replace(item, status=EXPIRED if now > item.expires_at else verdict)
                    closed.append(key)
        return tuple(closed)

    def clear(self) -> None:
        """For tests."""
        with self._lock:
            self._items.clear()


STORE = RequestStore()


def _now() -> datetime:
    return datetime.now(UTC)


def clock() -> datetime:
    """Now, as a dependency, so tests move time instead of sleeping (and _now can be patched for the store)."""
    return _now()


Now = Annotated[datetime, Depends(clock)]


def _elapsed_ms(started: float) -> float:
    return (time.perf_counter() - started) * 1000


def _refuse(kind: str, uid: str, inputs: dict[str, Any], code: int, detail: str, started: float) -> NoReturn:
    audit.record(kind, uid, inputs, {"status_code": code, "detail": detail}, _elapsed_ms(started))
    raise HTTPException(code, detail)


def _request_id(intervention_id: str, contact_uid: str) -> str:
    return "tc-" + hashlib.sha1(f"{intervention_id}|{contact_uid}".encode()).hexdigest()[:16]


def reason_bn(iv: dict) -> str:
    """Why the hold happened, for the contact: Apa's latest validated warning for this hold (its T line, which says what is
    happening, else the whole warning), else the top rule reason's own label; never a fixed sentence. Cut at a sentence."""
    lines = [line for line in (iv.get("apa_warning") or {}).get("lines") or () if isinstance(line, dict)]
    tactic = next((line.get("text_bn") for line in lines if line.get("role") == "T"), None)
    text = str(tactic or " ".join(str(line.get("text_bn", "")) for line in lines) or iv.get("top_reason_bn") or "")
    if len(text) <= REASON_MAX_CHARS:
        return text
    cut = text[:REASON_MAX_CHARS]
    return cut[: cut.rfind("।") + 1] or cut


def amount_text(amount: float) -> str:
    """FCM data values are strings: 9000.0 -> '9000', 250.5 -> '250.5'."""
    return f"{amount:.2f}".rstrip("0").rstrip(".")


def push_title(settings: Settings) -> str:
    """The contact's push title: the bank's name as the app shows it, then "approval needed"."""
    return f"{settings.brand_bn}: অনুমোদন দরকার"


def _push(request_id: str, intervention_id: str, hold: dict, contact_uid: str, settings: Settings) -> str:
    """The contact's data message (sequence diagram: deep_link, amount_bdt, reason_bn); never the receiving account."""
    token = state.store().get("users", contact_uid).get("fcm_token")
    if not token:
        return "no_token"
    amount = float((hold.get("txn") or {}).get("amount_bdt") or 0)
    data = {"type": "trusted_contact", "request_id": request_id, "intervention_id": intervention_id,
            "deep_link": f"bhorosha://approve/{request_id}", "amount_bdt": amount_text(amount), "reason_bn": reason_bn(hold)}
    return notify.send(token, data, push_title(settings), PUSH_BODY)


def _link(item: ContactRequest) -> None:
    """interventions/{hold}.trusted_contact, so the requester's card counts down from a snapshot."""
    if item.hold_id:
        link = {"request_id": item.request_id, "contact_uid": item.contact_uid, "expires_at": item.expires_at.isoformat()}
        state.store().merge("interventions", item.hold_id, {"trusted_contact": link})


@dataclass(frozen=True)
class _Target:
    owner_uid: str  # whose intervention it is
    hold_id: str | None  # the hold it settles
    hold: dict  # interventions/{hold_id} as read; {} without one
    verified: bool  # False only for a demo-mode id the server never issued


def _target(body: TrustedContactRequest, uid: str, settings: Settings, started: float) -> _Target:
    """The intervention the request names: one /v1/intervene opened for this caller, or a hold of hers from /v1/risk/score."""
    inputs = body.model_dump()
    opened = interventions.STORE.get(body.intervention_id)
    if opened is not None:
        if opened.owner_uid != uid:
            _refuse("trusted_contact_refused", uid, inputs, status.HTTP_403_FORBIDDEN, "this intervention belongs to another customer", started)
        hold = state.store().get("interventions", opened.hold_id) if opened.hold_id else {}
        return _Target(uid, opened.hold_id if hold else None, hold, True)
    hold = state.store().get("interventions", body.intervention_id)
    if hold.get("txn") is not None or hold.get("decision"):  # a hold /v1/risk/score recorded
        owner = str(hold.get("user_id") or "")
        if owner != uid and not is_demo(settings):
            _refuse("trusted_contact_refused", uid, inputs, status.HTTP_403_FORBIDDEN, "this intervention belongs to another customer", started)
        return _Target(owner, body.intervention_id, hold, owner == uid)
    if is_demo(settings):
        return _Target(uid, None, {}, False)
    _refuse("trusted_contact_refused", uid, inputs, status.HTTP_404_NOT_FOUND, "unknown intervention", started)


def _contact(body: TrustedContactRequest, target: _Target, uid: str, started: float) -> str:
    """users/{owner}.trusted_contact_uid when there is one (the body may only name that one), else the body's contact."""
    inputs = body.model_dump()
    on_file = state.store().get("users", target.owner_uid).get("trusted_contact_uid")
    if on_file and body.contact_uid and body.contact_uid != on_file:
        _refuse("trusted_contact_refused", uid, inputs, status.HTTP_403_FORBIDDEN, "contact_uid is not the trusted contact on file", started)
    contact = body.contact_uid or on_file
    if not contact:
        _refuse("trusted_contact_refused", uid, inputs, HTTPStatus.UNPROCESSABLE_ENTITY, f"no trusted contact on file for {target.owner_uid}", started)
    if contact in (uid, target.owner_uid):
        _refuse("trusted_contact_refused", uid, inputs, HTTPStatus.UNPROCESSABLE_ENTITY,
                "contact_uid must be someone other than the requester", started)
    return contact


@router.post("/trusted-contact", response_model=TrustedContactResponse)
def create(
    body: TrustedContactRequest,
    uid: Annotated[str, Depends(require_user)],
    settings: Annotated[Settings, Depends(get_settings)],
    now: Now,
) -> TrustedContactResponse:
    started = time.perf_counter()
    if body.contact_uid == uid:
        _refuse(
            "trusted_contact_refused", uid, body.model_dump(), HTTPStatus.UNPROCESSABLE_ENTITY,
            "contact_uid must be someone other than the requester", started,
        )
    target = _target(body, uid, settings, started)
    contact = _contact(body, target, uid, started)
    request_id = _request_id(body.intervention_id, contact)
    existing = _expire(STORE.get(request_id), now)
    if existing is not None:  # asking again reuses the request
        result = TrustedContactResponse(request_id=request_id, expires_at=existing.expires_at.isoformat())
        audit.record("trusted_contact_create", uid, body.model_dump(), {**result.model_dump(), "reused": True}, _elapsed_ms(started))
        return result
    if target.hold and (refusal := interventions.contact_check_refusal(target.hold)):
        _refuse("trusted_contact_refused", uid, body.model_dump(), status.HTTP_409_CONFLICT, refusal, started)
    expires_at = now + timedelta(minutes=settings.trusted_contact_expiry_minutes)
    push = _push(request_id, body.intervention_id, target.hold, contact, settings)
    item = STORE.add(ContactRequest(
        request_id, body.intervention_id, uid, contact, expires_at, PENDING, intervention_verified=target.verified,
        hold_id=target.hold_id, push=push,
    ), now)
    _link(item)
    result = TrustedContactResponse(request_id=item.request_id, expires_at=expires_at.isoformat())
    outputs = {**result.model_dump(), "intervention_verified": target.verified, "identity_source": identity_source(settings),
               "push": push, "hold_id": target.hold_id}
    audit.record("trusted_contact_create", uid, body.model_dump(), outputs, _elapsed_ms(started))
    return result


def _settle_hold(request: ContactRequest, now: datetime) -> str | None:
    """The hold follows a request that just settled: released or cancelled with the contact's answer, analyst review after
    silence (the transaction stays held). Its other open requests close the same way. Returns the hold's status."""
    if not request.hold_id:
        return None
    outcome = OUTCOME.get(request.status, interventions.REVIEW)
    ended = state.transaction(lambda tx: interventions.settle_in(tx, request.hold_id, tx.get("interventions", request.hold_id), outcome))
    STORE.close_others(request.hold_id, request.request_id, request.status, now)
    return ended


def _expire(item: ContactRequest | None, now: datetime) -> ContactRequest | None:
    """A pending request past its window expires, and its hold goes to analyst review; anything else comes back as is."""
    if item is None:
        return None
    settled = STORE.expire(item.request_id, now)
    if settled is None:
        return item
    if settled.won:
        ended = _settle_hold(settled.request, now)
        audit.record("trusted_contact_expired", "system", {"request_id": item.request_id},
                     {"status": EXPIRED, "intervention_id": item.intervention_id, "hold": ended}, 0.0)
    return settled.request


def _decide(request_id: str, verdict: Verdict, uid: str, settings: Settings, now: datetime) -> TrustedContactDecision:
    started = time.perf_counter()
    item = STORE.get(request_id)
    if item is None:
        _refuse(
            "trusted_contact_denied", uid, {"request_id": request_id, "verdict": verdict},
            status.HTTP_404_NOT_FOUND, UNKNOWN_REQUEST, started,
        )
    inputs = {
        "request_id": request_id, "verdict": verdict, "contact_uid": item.contact_uid,
        "requester_uid": item.requester_uid, "intervention_id": item.intervention_id,
    }
    contact_verified = uid == item.contact_uid
    if not contact_verified and not is_demo(settings):
        _refuse(
            "trusted_contact_denied", uid, inputs, status.HTTP_403_FORBIDDEN,
            "only the named trusted contact can decide this request", started,
        )
    settled = STORE.settle(request_id, verdict, uid, now, contact_verified=contact_verified)
    if settled is None:  # dropped from the store between the read above and now
        _refuse("trusted_contact_denied", uid, inputs, status.HTTP_404_NOT_FOUND, UNKNOWN_REQUEST, started)
    request = settled.request
    hold = _settle_hold(request, now) if settled.won else None
    result = TrustedContactDecision(
        request_id=request_id, status=request.status, decided_by=request.decided_by,
        contact_verified=request.contact_verified,
    )
    audit.record("trusted_contact_decision", uid, inputs, {**result.model_dump(), "won": settled.won, "hold": hold}, _elapsed_ms(started))
    return result


@router.get("/trusted-contact/{request_id}", response_model=TrustedContactState)
def get_request(
    request_id: str, uid: Annotated[str, Depends(require_user)], settings: Annotated[Settings, Depends(get_settings)], now: Now
) -> TrustedContactState:
    """The request as the requester and her contact see it; an overdue one expires here (its hold to analyst review)."""
    item = STORE.get(request_id)
    if item is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, UNKNOWN_REQUEST)
    if not is_demo(settings) and uid not in (item.requester_uid, item.contact_uid):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "only the requester and her trusted contact can read this request")
    item = _expire(item, now) or item
    return TrustedContactState(request_id=item.request_id, intervention_id=item.intervention_id, contact_uid=item.contact_uid,
                               status=item.status, expires_at=item.expires_at.isoformat(), push=item.push,
                               decided_by=item.decided_by, contact_verified=item.contact_verified)


@router.post("/trusted-contact/{request_id}/approve", response_model=TrustedContactDecision)
def approve(
    request_id: str,
    uid: Annotated[str, Depends(require_user)],
    settings: Annotated[Settings, Depends(get_settings)],
    now: Now,
) -> TrustedContactDecision:
    return _decide(request_id, "approved", uid, settings, now)


@router.post("/trusted-contact/{request_id}/decline", response_model=TrustedContactDecision)
def decline(
    request_id: str,
    uid: Annotated[str, Depends(require_user)],
    settings: Annotated[Settings, Depends(get_settings)],
    now: Now,
) -> TrustedContactDecision:
    return _decide(request_id, "declined", uid, settings, now)


@router.post("/trusted-contact/sweep", response_model=TrustedContactSweep)
def sweep(
    settings: Annotated[Settings, Depends(get_settings)], now: Now, x_operator_token: Annotated[str | None, Header()] = None
) -> TrustedContactSweep:
    """For a scheduler: what a status check does, for every pending request at once. Safe to call at any time. With auth on
    only the operator token (settings.operator_token) may call it; only the operator is told which requests it touched."""
    started = time.perf_counter()
    operator = bool(settings.operator_token) and hmac.compare_digest((x_operator_token or "").encode(), settings.operator_token.encode())
    if settings.auth_required and not operator:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "the sweep needs the scheduler's operator token")
    pending = STORE.pending()
    after = [_expire(item, now) for item in pending]
    expired = tuple(a.request_id for a in after if a is not None and a.status == EXPIRED)
    out = TrustedContactSweep(checked=len(pending), expired=expired if operator else (), expired_count=len(expired))
    audit.record("trusted_contact_sweep", "operator" if operator else "demo", {}, out.model_dump(mode="json"), _elapsed_ms(started))
    return out


def _own_money(user_id: str, uid: str, settings: Settings) -> None:
    """With auth on only the account owner locks or unlocks her money; in demo mode any caller may."""
    if settings.auth_required and uid != user_id:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "only the account owner can lock or unlock her money")


@router.post("/money-lock", response_model=MoneyLockStatus)
def lock(
    body: MoneyLockRequest, uid: Annotated[str, Depends(require_user)], settings: Annotated[Settings, Depends(get_settings)]
) -> MoneyLockStatus:
    started = time.perf_counter()
    _own_money(body.user_id, uid, settings)
    now = datetime.now(UTC)
    until = (now + timedelta(minutes=body.minutes)).isoformat()
    iid = "ml-" + hashlib.sha1(f"{body.user_id}|{now.isoformat()}".encode()).hexdigest()[:16]
    previous = state.store().get("money_lock", body.user_id).get("intervention_id")
    if previous:  # a new lock replaces the one still on file
        state.store().merge("interventions", previous, {"status": "replaced", "updated_at": now.isoformat()})
    # FR-5: the lock is visible in interventions/{id} like any other action, not only in money_lock/{uid}.
    state.store().set("interventions", iid, {"id": iid, "user_id": body.user_id, "kind": "money_lock", "decision": "money_lock",
                                             "status": "locked", "locked_bdt": body.locked_bdt, "until": until, "set_by": uid,
                                             "created_at": now.isoformat(), "updated_at": now.isoformat()})
    state.store().set("money_lock", body.user_id, {"until": until, "set_by": uid, "locked_bdt": body.locked_bdt, "intervention_id": iid})
    out = MoneyLockStatus(user_id=body.user_id, locked=True, until=until, locked_bdt=body.locked_bdt)
    audit.record("money_lock", uid, body.model_dump(), out.model_dump(), (time.perf_counter() - started) * 1000)
    return out


@router.delete("/money-lock/{user_id}", response_model=MoneyLockStatus)
def unlock(user_id: str, uid: Annotated[str, Depends(require_user)], settings: Annotated[Settings, Depends(get_settings)]) -> MoneyLockStatus:
    started = time.perf_counter()
    _own_money(user_id, uid, settings)
    iid = state.store().get("money_lock", user_id).get("intervention_id")
    if iid:
        state.store().merge("interventions", iid, {"status": "unlocked", "unlocked_by": uid, "updated_at": datetime.now(UTC).isoformat()})
    state.store().delete("money_lock", user_id)
    out = MoneyLockStatus(user_id=user_id, locked=False)
    audit.record("money_unlock", uid, {"user_id": user_id}, out.model_dump(), (time.perf_counter() - started) * 1000)
    return out
