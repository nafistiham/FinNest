"""Trusted-contact expiry (spec US-4 S1c): no answer in 10 minutes keeps the hold and sends it to analyst review.

The request expires at expires_at, exactly once, as decided for the whole service; the spec's single re-prompt
before that is not built (it would need a nudge inside the window, and FCM is not configured yet).
"""

from datetime import UTC, datetime, timedelta

import pytest

from app import interventions, notify, state
from app.routers import actions
from app.settings import get_settings

HELD_RESET = {"user_id": "rina", "session_id": "call-9", "txn": {"type": "pin_reset", "txn_id": "t-reset-1"},
              "demo_flags": {"call_active": True, "caller_in_contacts": False}}
OTHER_RESET = {**HELD_RESET, "session_id": "call-10", "txn": {"type": "pin_reset", "txn_id": "t-reset-2"}}
NEW_PAYEE = {"user_id": "rina", "session_id": "s2", "txn": {"type": "send_money", "amount_bdt": 9000, "to_account": "acct_x", "is_new_payee": True, "txn_id": "t-send-1"},
             "demo_flags": {}}
WINDOW = timedelta(minutes=10)
TICK = timedelta(seconds=1)


class Clock:
    def __init__(self) -> None:
        self.now = datetime(2026, 10, 16, 9, 0, tzinfo=UTC)

    def advance(self, delta: timedelta) -> None:
        self.now += delta


@pytest.fixture
def clock(client):
    c = Clock()
    client.app.dependency_overrides[actions.clock] = lambda: c.now
    yield c
    client.app.dependency_overrides.pop(actions.clock, None)


@pytest.fixture
def pushes(monkeypatch):
    sent = []
    monkeypatch.setattr(notify, "send", lambda token, data, title, body: sent.append(data) or "sent")
    return sent


@pytest.fixture
def operator(monkeypatch):
    """The scheduler's operator token: the only caller the sweep tells which requests it touched."""
    monkeypatch.setenv("RISK_MW_OPERATOR_TOKEN", "op-secret")
    get_settings.cache_clear()
    yield {"X-Operator-Token": "op-secret"}
    monkeypatch.delenv("RISK_MW_OPERATOR_TOKEN")
    get_settings.cache_clear()


def _ask(client, body=HELD_RESET, contact="rafiq"):
    """Rina asks her trusted contact; the contact is always the one on file, so asking someone else means changing it first."""
    state.store().merge("users", "rina", {"trusted_contact_uid": contact})
    state.store().set("users", contact, {"fcm_token": f"tok-{contact}"})
    out = client.post("/v1/risk/score", json=body).json()
    iid = next(a["params"]["intervention_id"] for a in out["actions"] if "intervention_id" in a["params"])
    created = client.post("/v1/actions/trusted-contact", json={"intervention_id": iid, "contact_uid": contact})
    assert created.status_code == 200, created.text
    return iid, created.json()["request_id"], created.json()


def _status(client, rid):
    return client.get(f"/v1/actions/trusted-contact/{rid}").json()


def _answer(client, rid, decision):
    return client.post(f"/v1/actions/trusted-contact/{rid}/{decision}").json()["status"]


def _held(iid, txn="t-reset-1"):
    return state.store().get("interventions", iid)["status"], state.store().get("transactions", txn)["status"]


def test_the_window_runs_on_the_injected_clock(client, clock, pushes):
    _, _, created = _ask(client)
    assert datetime.fromisoformat(created["expires_at"]) == clock.now + WINDOW


def test_silence_past_the_window_expires_and_sends_the_hold_to_an_analyst(client, clock, pushes):
    iid, rid, _ = _ask(client)
    clock.advance(WINDOW - TICK)
    assert _status(client, rid)["status"] == "pending" and _held(iid) == ("held", "held")
    clock.advance(2 * TICK)
    status = _status(client, rid)
    assert status["status"] == "expired" and status["decided_by"] is None and len(pushes) == 1
    assert _held(iid) == ("analyst_review", "held")  # the payment stays held; only an analyst can end it now


def test_the_request_records_its_push_result(client, clock, pushes):
    _, rid, _ = _ask(client)
    assert _status(client, rid)["push"] == "sent"
    state.store().merge("users", "rina", {"trusted_contact_uid": "nabil"})  # a contact with no FCM token yet
    out = client.post("/v1/risk/score", json=NEW_PAYEE).json()
    iid = next(a["params"]["intervention_id"] for a in out["actions"] if "intervention_id" in a["params"])
    third = client.post("/v1/actions/trusted-contact", json={"intervention_id": iid}).json()["request_id"]
    assert _status(client, third)["push"] == "no_token" and len(pushes) == 1


def test_a_late_answer_after_the_expiry_changes_nothing(client, clock, pushes):
    iid, rid, _ = _ask(client)
    clock.advance(WINDOW + TICK)
    assert _answer(client, rid, "approve") == "expired"  # this tap is what finds the expiry
    assert _answer(client, rid, "decline") == "expired"
    assert _held(iid) == ("analyst_review", "held") and len(pushes) == 1


def test_a_tap_inside_the_window_decides(client, clock, pushes):
    iid, rid, _ = _ask(client)
    clock.advance(WINDOW - TICK)
    assert _answer(client, rid, "approve") == "approved"
    assert _held(iid) == ("released", "released")


def test_asking_again_reuses_the_request_and_never_reopens_it(client, clock, pushes):
    iid, rid, created = _ask(client)
    again = client.post("/v1/actions/trusted-contact", json={"intervention_id": iid}).json()
    assert again == {"request_id": rid, "expires_at": created["expires_at"]} and len(pushes) == 1
    clock.advance(WINDOW + TICK)
    late = client.post("/v1/actions/trusted-contact", json={"intervention_id": iid}).json()
    assert late["request_id"] == rid and _status(client, rid)["status"] == "expired" and len(pushes) == 1


def test_the_sweep_expires_overdue_requests(client, clock, pushes, operator):
    assert "/v1/actions/trusted-contact/sweep" in client.get("/openapi.json").json()["paths"]
    a_iid, a, _ = _ask(client, HELD_RESET)
    b_iid, b, _ = _ask(client, NEW_PAYEE)
    clock.advance(timedelta(minutes=9))
    _, c, _ = _ask(client, OTHER_RESET, contact="mitu")
    clock.advance(timedelta(minutes=1) + TICK)  # a and b are overdue, c is not
    sweep = "/v1/actions/trusted-contact/sweep"
    first = client.post(sweep, headers=operator).json()
    assert first["checked"] == 3 and sorted(first["expired"]) == sorted([a, b]) and first["expired_count"] == 2
    assert _held(a_iid) == ("analyst_review", "held") and _held(b_iid, "t-send-1") == ("analyst_review", "delayed")
    assert client.post(sweep, headers=operator).json() == {"checked": 1, "expired": [], "expired_count": 0}  # only c is left
    clock.advance(WINDOW)
    assert client.post(sweep, headers=operator).json() == {"checked": 1, "expired": [c], "expired_count": 1}
    assert client.post(sweep, headers=operator).json() == {"checked": 0, "expired": [], "expired_count": 0}


def test_answers_are_never_overwritten(client, clock, pushes):
    """Once one contact's answer settles the hold, the other open request closes as that outcome: it is never re-prompted,
    and a later tap there is told what happened to the payment, not 'declined'."""
    iid, rid, _ = _ask(client)
    _, other, _ = _ask(client, contact="mitu")  # a second contact was asked about the same hold
    assert _answer(client, rid, "approve") == "approved"
    assert _status(client, other)["status"] == "approved"
    clock.advance(timedelta(hours=1))
    assert _status(client, rid)["status"] == "approved"
    assert client.post("/v1/actions/trusted-contact/sweep").json()["checked"] == 0
    assert len(pushes) == 2  # the two first asks; nobody was re-prompted
    assert _answer(client, other, "decline") == "approved"
    assert _held(iid) == ("released", "released")  # never turned back into a review


def test_a_decline_or_silence_closes_the_other_requests_the_same_way(client, clock, pushes):
    iid, rid, _ = _ask(client)
    _, other, _ = _ask(client, contact="mitu")
    assert _answer(client, other, "decline") == "declined"
    assert _status(client, rid)["status"] == "declined" and _answer(client, rid, "approve") == "declined"
    assert _held(iid) == ("cancelled", "cancelled")
    b_iid, b, _ = _ask(client, NEW_PAYEE, contact="rafiq")
    clock.advance(timedelta(minutes=5))
    _, b2, _ = _ask(client, NEW_PAYEE, contact="mitu")
    clock.advance(timedelta(minutes=5) + TICK)
    assert _status(client, b)["status"] == "expired" and _held(b_iid, "t-send-1") == ("analyst_review", "delayed")
    assert _status(client, b2)["status"] == "expired" and len(pushes) == 4


def test_a_retry_keeps_the_hold_in_analyst_review(client, clock, pushes):
    iid, rid, _ = _ask(client)
    clock.advance(WINDOW + TICK)
    _status(client, rid)
    client.post("/v1/risk/score", json=HELD_RESET)  # the app retries the same request
    assert _held(iid) == ("analyst_review", "held")


def test_analyst_review_is_final_for_the_trusted_contact_path(client, clock, pushes):
    """Silence sent the hold to an analyst: a second contact's request that was still open cannot release or cancel it, and
    nobody can ask again. (Leaving analyst review is an analyst's route, which this service does not have yet.)"""
    iid, rid, _ = _ask(client)
    clock.advance(timedelta(minutes=9))
    _, other, _ = _ask(client, contact="mitu")  # the contact on file changed while the first request was open
    clock.advance(timedelta(minutes=1) + TICK)
    assert _status(client, rid)["status"] == "expired" and _held(iid) == ("analyst_review", "held")
    assert _answer(client, other, "approve") == "expired"
    assert _answer(client, other, "decline") == "expired"
    assert _held(iid) == ("analyst_review", "held")
    state.store().merge("users", "rina", {"trusted_contact_uid": "nabil"})
    assert client.post("/v1/actions/trusted-contact", json={"intervention_id": iid}).status_code == 409
    for outcome in ("released", "cancelled"):
        interventions.settle(iid, outcome)
    assert _held(iid) == ("analyst_review", "held")


def test_the_stores_find_pending_requests():
    mem = state.MemoryStore()
    mem.set("trusted_contact", "a", {"status": "pending"})
    mem.set("trusted_contact", "b", {"status": "approved"})
    mem.set("interventions", "c", {"status": "pending"})
    assert mem.where("trusted_contact", "status", "pending") == [{"status": "pending"}]

    class Snap:
        def __init__(self, data):
            self._data = data

        def to_dict(self):
            return self._data

    class Coll:
        def __init__(self, calls):
            self.calls = calls

        def where(self, *, filter):  # noqa: A002 - the Firestore keyword
            self.calls.append((filter.field_path, filter.op_string, filter.value))
            return self

        def stream(self):
            return iter([Snap({"status": "pending", "request_id": "a"})])

    class FakeClient:
        def __init__(self):
            self.calls = []

        def collection(self, name):
            self.calls.append(name)
            return Coll(self.calls)

    fake = FakeClient()
    assert state.FirestoreStore(fake).where("trusted_contact", "status", "pending") == [{"status": "pending", "request_id": "a"}]
    assert fake.calls == ["trusted_contact", ("status", "==", "pending")]


def test_the_firestore_transaction_reads_and_writes_through_the_transaction(monkeypatch):
    """state.transaction on Firestore: every read carries the transaction and every write goes through it (one commit)."""
    import google.cloud.firestore as firestore

    monkeypatch.setattr(firestore, "transactional", lambda fn: fn)  # the real decorator begins, retries and commits

    class Snap:
        exists = True

        def __init__(self, data):
            self._data = data

        def to_dict(self):
            return self._data

    class Doc:
        def __init__(self, path, log):
            self.path, self.log = path, log

        def get(self, transaction=None):
            self.log.append(("get", self.path, transaction))
            return Snap({"status": "held"})

    class Coll:
        def __init__(self, name, log):
            self.name, self.log = name, log

        def document(self, doc_id):
            return Doc(f"{self.name}/{doc_id}", self.log)

    class Tx:
        def __init__(self, log):
            self.log = log

        def set(self, ref, data, merge=False):
            self.log.append(("set", ref.path, data, merge))

    class FakeClient:
        def __init__(self):
            self.log = []

        def collection(self, name):
            return Coll(name, self.log)

        def transaction(self):
            self.tx = Tx(self.log)
            return self.tx

    fake = FakeClient()

    def body(tx):
        doc = tx.get("interventions", "iv-1")
        tx.merge("interventions", "iv-1", {"status": "released"})
        tx.set("audit", "a-1", {"seen": doc["status"]})
        return doc["status"]

    assert state.FirestoreStore(fake).run(body) == "held"
    assert fake.log == [("get", "interventions/iv-1", fake.tx), ("set", "interventions/iv-1", {"status": "released"}, True),
                        ("set", "audit/a-1", {"seen": "held"}, False)]
