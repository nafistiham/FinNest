"""Interventions: the holds /v1/risk/score records (spec FR-5) and the ids /v1/intervene opens.

Holds. A hold, delay or block from /v1/risk/score becomes interventions/{id} (Firestore or memory). Its id is derived
from what was held (hold_id): the request with its txn_id, or, without one, the request plus the decision and reasons.
Scoring the same request again is idempotent, so a released, cancelled or analyst-review intervention is never re-held
by a retry, while a later, different hold gets an intervention of its own. Only a held or delayed intervention can be
settled: released, cancelled and analyst review are final for the trusted-contact path (leaving analyst review needs an
analyst route, which this service does not have). Money Lock lives in money_lock/{uid}, optionally on a sub-balance
(locked_bdt), and each lock is also recorded as interventions/{ml-...}.

Opened interventions. /v1/intervene opens one per call and returns its id; /v1/actions/trusted-contact accepts an id
opened for the same caller, or a hold of hers. In process memory, bounded, like the other single-instance stores (see
README "One instance, on purpose"); an opened intervention names the hold it answers (hold_id) when there is one, so a
trusted contact's answer settles that hold. When the store is full, interventions older than the hold they belong to go
first, and no uid holds more than app.bounded.PER_OWNER_LIMIT of them.
"""

from __future__ import annotations

import hashlib
import logging
import threading
import uuid
from collections import OrderedDict
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

from app import bounded, state
from app.contracts import Action, ScoreRequest, ScoreResponse
from app.settings import Settings

log = logging.getLogger(__name__)
STATUS_FOR = {"hold": "held", "delay": "delayed", "block": "blocked"}
OPEN = ("held", "delayed")  # what a trusted contact can still release or cancel
FINAL = ("released", "cancelled")
REVIEW = "analyst_review"  # the trusted contact never answered: the hold stays until an analyst decides, whoever answers later
CONTACT_CHECK = "trusted_contact_check"
MONEY_LOCK_CODE = "MONEY_LOCK_ACTIVE"  # rules.money_lock_hit: the customer's own lock, which only she lifts


def intervention_id(req: ScoreRequest) -> str:
    """The request's own id: the hold's id when the request carries a txn_id (see hold_id)."""
    t = req.txn
    key = "|".join(str(x) for x in (req.user_id, req.session_id, t.type, t.to_account, t.amount_bdt, t.txn_id))
    return "iv-" + hashlib.sha1(key.encode()).hexdigest()[:16]


def hold_id(req: ScoreRequest, result: ScoreResponse) -> str:
    """The intervention for this hold. A txn_id names the payment, so every hold on it is one intervention. Without one,
    two pin resets in a session look alike, so the decision and reasons tell a later, different hold from a retry."""
    iid = intervention_id(req)
    if req.txn.txn_id:
        return iid
    held = "|".join((iid, result.decision, *sorted({r.code for r in result.reasons})))
    return "iv-" + hashlib.sha1(held.encode()).hexdigest()[:16]


def txn_key(req: ScoreRequest, iid: str) -> str:
    return req.txn.txn_id or iid


def with_intervention_id(result: ScoreResponse, iid: str, contact_uid: str | None = None) -> ScoreResponse:
    """The app learns the intervention id (and who the trusted contact is) through the actions' params; the response contract is frozen.
    A Money Lock hold offers no trusted-contact check: her own lock is lifted by unlocking it, not by someone else's approval."""
    locked = any(r.code == MONEY_LOCK_CODE for r in result.reasons)

    def params(a: Action) -> dict:
        extra = {"contact_uid": contact_uid} if contact_uid and a.type == CONTACT_CHECK else {}
        return {**a.params, "intervention_id": iid, **extra}
    actions = tuple(Action(type=a.type, params=params(a)) for a in result.actions if not (locked and a.type == CONTACT_CHECK))
    return result.model_copy(update={"actions": actions})


def contact_check_refusal(doc: dict) -> str | None:
    """Why this intervention cannot get a trusted-contact request, or None when it can: only a hold or delay that offered
    the check, never a block, a Money Lock hold, analyst review or one already released or cancelled."""
    if doc.get("status") not in OPEN:
        return f"the intervention is {doc.get('status') or 'unknown'}; only a hold or a delay can go to a trusted contact"
    if CONTACT_CHECK not in (doc.get("action_types") or ()):
        return "the intervention did not offer a trusted-contact check"
    if MONEY_LOCK_CODE in (doc.get("reason_codes") or ()):
        return "a Money Lock hold ends when its owner unlocks, not by a trusted contact"
    return None


def record(req: ScoreRequest, result: ScoreResponse, iid: str, settings: Settings) -> None:
    if result.decision in STATUS_FOR:
        state.transaction(lambda tx: _record_in(tx, req, result, iid, settings))


def _record_in(tx: state.Tx, req: ScoreRequest, result: ScoreResponse, iid: str, settings: Settings) -> None:
    """transactions/{txnId} belongs to the user who first wrote it: another user's hold on the same txn_id keeps no
    transaction (txn_key None), so it can neither re-point nor settle someone else's payment."""
    status = STATUS_FOR[result.decision]
    existing = tx.get("interventions", iid)
    if existing.get("status") in (*FINAL, REVIEW):
        return
    key: str | None = txn_key(req, iid)
    owner = tx.get("transactions", key).get("user_id", req.user_id)
    if owner != req.user_id:
        log.warning("transactions/%s belongs to another user; intervention %s keeps no transaction", key, iid)
        key = None
    now = datetime.now(UTC)
    minutes = settings.new_payee_delay_minutes if result.decision == "delay" else settings.pin_reset_freeze_minutes
    until = None if result.decision == "block" else (now + timedelta(minutes=minutes)).isoformat()
    top = max(result.reasons, key=lambda r: r.weight, default=None)  # the trusted contact's push says this one
    tx.merge("interventions", iid, {
        "id": iid, "user_id": req.user_id, "session_id": req.session_id, "txn": req.txn.model_dump(), "txn_key": key,
        "decision": result.decision, "status": status, "risk_score": result.risk_score, "band": result.band,
        "reason_codes": [r.code for r in result.reasons], "top_reason": top.code if top else None,
        "top_reason_bn": top.text_bn if top else None,  # the push's reason when Apa has no validated warning for this hold
        "action_types": [a.type for a in result.actions],
        "until": until, "created_at": existing.get("created_at", now.isoformat()), "updated_at": now.isoformat(),
    })
    if key:
        tx.merge("transactions", key, {"status": status, "intervention_id": iid, "user_id": req.user_id, "updated_at": now.isoformat()})


def settle(iid: str, outcome: str) -> None:
    """settle_in() as an atomic update of its own."""
    state.transaction(lambda tx: settle_in(tx, iid, tx.get("interventions", iid), outcome))


def settle_in(tx: state.Tx, iid: str, doc: dict, outcome: str) -> str | None:
    """A trusted contact's answer ('released' or 'cancelled', mirrored on the transaction), or REVIEW after silence, which
    leaves the transaction held, written inside the caller's transaction after its reads (doc is interventions/{iid} as read
    there). Only a held or delayed intervention changes: released, cancelled and analyst review never do (nor a block).
    Returns the status the intervention ends in."""
    if doc.get("status") not in OPEN:
        return doc.get("status")
    key = doc.get("txn_key") if outcome in FINAL else None
    txn = tx.get("transactions", key) if key else {}
    now = datetime.now(UTC).isoformat()
    tx.merge("interventions", iid, {"status": outcome, "updated_at": now})
    # Only the transaction this hold still stands for, and only its owner's: never one another user or a later hold re-pointed.
    if key and txn.get("user_id", doc.get("user_id")) == doc.get("user_id") and txn.get("intervention_id", iid) == iid:
        tx.merge("transactions", key, {"status": outcome, "updated_at": now})
    return outcome


def money_lock_holds(doc: dict, amount_bdt: float, user: dict) -> bool:
    """Whether the customer's Money Lock (money_lock/{uid}, already read) holds this send. A whole-balance lock holds every send;
    a sub-balance lock (locked_bdt) holds only a send that would dip into the locked part, which needs her balance from
    users/{uid}.balance_bdt: with no balance known, every send is held, as for a whole-balance lock."""
    if not money_lock_until_of(doc):
        return False
    locked, balance = doc.get("locked_bdt"), user.get("balance_bdt")
    if not isinstance(locked, int | float) or not isinstance(balance, int | float):
        return True
    return balance - amount_bdt < locked


def money_lock_until(user_id: str) -> datetime | None:
    return money_lock_until_of(state.store().get("money_lock", user_id))


def money_lock_until_of(doc: dict) -> datetime | None:
    """money_lock_until() for a money_lock document already read; None when unlocked or expired."""
    until = doc.get("until")
    if not until:
        return None
    moment = datetime.fromisoformat(until)
    return moment if moment > datetime.now(UTC) else None


# --- opened interventions ---------------------------------------------------------------------------------

INTERVENTION_LIMIT = 2048  # a request id arrives within minutes of its intervention
STALE_AFTER = timedelta(hours=1)  # the longest hold an intervention backs (freeze / delay: 60 minutes)
ID_PREFIX = "int_"


@dataclass(frozen=True)
class Intervention:
    intervention_id: str
    owner_uid: str
    trigger: str
    created_at: datetime
    hold_id: str | None = None  # The interventions/{id} hold this answers, settled by a trusted contact's answer


def _owner_of(_key: str, item: Intervention) -> str:
    return item.owner_uid


class InterventionStore:
    """Bounded, thread-safe map of intervention id to its frozen record."""

    def __init__(self, limit: int = INTERVENTION_LIMIT) -> None:
        self._limit = limit
        self._items: OrderedDict[str, Intervention] = OrderedDict()
        self._lock = threading.Lock()

    def open(self, owner_uid: str, trigger: str, *, now: datetime | None = None, hold_id: str | None = None) -> Intervention:
        at = now or datetime.now(UTC)
        item = Intervention(f"{ID_PREFIX}{uuid.uuid4().hex}", owner_uid, trigger, at, hold_id)
        with self._lock:
            self._items[item.intervention_id] = item
            bounded.make_room(
                self._items, item.intervention_id, owner_of=_owner_of, limit=self._limit,
                is_stale=lambda other: at - other.created_at > STALE_AFTER,
            )
        return item

    def get(self, intervention_id: str) -> Intervention | None:
        with self._lock:
            return self._items.get(intervention_id)

    def clear(self) -> None:
        """For tests."""
        with self._lock:
            self._items.clear()


STORE = InterventionStore()
