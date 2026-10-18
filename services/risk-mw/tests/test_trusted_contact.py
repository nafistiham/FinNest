"""Only the named contact decides a trusted-contact request, and a request needs a real intervention.

The earlier bug: approve/decline never read the caller, and create accepted any intervention id. These run with
auth on (the Firebase check faked to "the token is the uid", as the probe does) unless they say otherwise.
"""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta
from threading import Barrier

import pytest

from app import interventions
from app.routers import actions

PATH = "/v1/actions/trusted-contact"
RACERS = 8


def _bearer(uid: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {uid}"}


def _intervention(client, uid: str, headers: dict[str, str] | None = None) -> str:
    body = {"user_id": uid, "trigger": "call_active", "txn": {"type": "pin_reset"}}
    resp = client.post("/v1/intervene", json=body, headers=headers or _bearer(uid))
    assert resp.status_code == 200, resp.text
    return resp.json()["intervention_id"]


def _request(client, requester: str = "rina", contact: str = "rafiq") -> str:
    intervention_id = _intervention(client, requester)
    resp = client.post(PATH, json={"intervention_id": intervention_id, "contact_uid": contact}, headers=_bearer(requester))
    assert resp.status_code == 200, resp.text
    return resp.json()["request_id"]


def _decide(client, request_id: str, verb: str, uid: str):
    return client.post(f"{PATH}/{request_id}/{verb}", headers=_bearer(uid))


@pytest.fixture(autouse=True)
def _auth(auth_on):
    yield


# --- who may decide ------------------------------------------------------------------------------------------------


def test_wrong_user_cannot_approve(client):
    request_id = _request(client)
    resp = _decide(client, request_id, "approve", "unrelated-user")
    assert resp.status_code == 403
    assert actions.STORE.get(request_id).status == "pending"


def test_wrong_user_cannot_decline(client):
    request_id = _request(client)
    assert _decide(client, request_id, "decline", "unrelated-user").status_code == 403


def test_the_requester_cannot_approve_her_own_request(client):
    request_id = _request(client)
    assert _decide(client, request_id, "approve", "rina").status_code == 403


def test_named_contact_decides_once_and_the_second_call_returns_the_settled_state(client):
    request_id = _request(client)
    first = _decide(client, request_id, "approve", "rafiq")
    assert first.status_code == 200, first.text
    assert first.json() == {"request_id": request_id, "status": "approved", "decided_by": "rafiq", "contact_verified": True}

    second = _decide(client, request_id, "decline", "rafiq")
    assert second.status_code == 200
    assert second.json()["status"] == "approved"
    assert second.json()["decided_by"] == "rafiq"


def test_unknown_request_is_404_and_audited(client, monkeypatch):
    rows: list[tuple[str, str, dict, dict]] = []
    monkeypatch.setattr("app.audit.record", lambda kind, uid, inputs, outputs, ms: rows.append((kind, uid, inputs, outputs)) or "id")
    assert _decide(client, "does-not-exist", "approve", "rafiq").status_code == 404
    denied = [r for r in rows if r[0] == "trusted_contact_denied"]
    assert denied and denied[0][1] == "rafiq"
    assert denied[0][2]["request_id"] == "does-not-exist"
    assert denied[0][3]["status_code"] == 404


def test_an_expired_request_cannot_be_approved(client, monkeypatch):
    request_id = _request(client)
    later = actions.STORE.get(request_id).expires_at + timedelta(seconds=1)
    monkeypatch.setattr(actions, "_now", lambda: later)
    resp = _decide(client, request_id, "approve", "rafiq")
    assert resp.status_code == 200
    assert resp.json()["status"] == "expired"
    assert resp.json()["decided_by"] is None
    assert actions.STORE.get(request_id).status == "expired"


def test_concurrent_approve_and_decline_leave_exactly_one_outcome(client):
    request_id = _request(client)
    barrier = Barrier(RACERS)

    def race(index: int) -> str:
        barrier.wait(timeout=10)
        verb = "approve" if index % 2 == 0 else "decline"
        resp = _decide(client, request_id, verb, "rafiq")
        assert resp.status_code == 200, resp.text
        return resp.json()["status"]

    with ThreadPoolExecutor(max_workers=RACERS) as pool:
        outcomes = set(pool.map(race, range(RACERS)))
    assert len(outcomes) == 1
    assert outcomes <= {"approved", "declined"}
    assert actions.STORE.get(request_id).status in outcomes


def test_the_store_lets_exactly_one_settlement_win():
    """The lock itself, without HTTP in the way: many threads, one winner."""
    now = datetime.now(UTC)
    store = actions.RequestStore()
    store.add(actions.ContactRequest("r1", "i1", "rina", "rafiq", now + timedelta(minutes=10), "pending"), now)
    barrier = Barrier(RACERS)

    def race(index: int) -> actions.Settlement:
        barrier.wait(timeout=10)
        return store.settle("r1", "approved" if index % 2 == 0 else "declined", "rafiq", now)

    with ThreadPoolExecutor(max_workers=RACERS) as pool:
        settlements = list(pool.map(race, range(RACERS)))
    assert sum(s.won for s in settlements) == 1
    assert len({s.request.status for s in settlements}) == 1


def test_every_decision_is_audited_with_the_deciding_uid(client, monkeypatch):
    request_id = _request(client)
    rows: list[tuple[str, str, dict, dict]] = []
    monkeypatch.setattr("app.audit.record", lambda kind, uid, inputs, outputs, ms: rows.append((kind, uid, inputs, outputs)) or "id")

    _decide(client, request_id, "approve", "unrelated-user")
    _decide(client, request_id, "approve", "rafiq")

    denied = [r for r in rows if r[0] == "trusted_contact_denied"]
    decided = [r for r in rows if r[0] == "trusted_contact_decision"]
    assert denied and denied[0][1] == "unrelated-user"
    assert decided and decided[0][1] == "rafiq"
    assert decided[0][3]["decided_by"] == "rafiq"
    assert decided[0][3]["status"] == "approved"


# --- who may ask ---------------------------------------------------------------------------------------------------


def test_create_records_the_requester(client):
    request_id = _request(client)
    assert actions.STORE.get(request_id).requester_uid == "rina"


def test_create_with_an_unknown_intervention_is_404(client):
    resp = client.post(PATH, json={"intervention_id": "nonexistent", "contact_uid": "rafiq"}, headers=_bearer("rina"))
    assert resp.status_code == 404


def test_create_with_someone_elses_intervention_is_403(client):
    intervention_id = _intervention(client, "rahima")
    resp = client.post(PATH, json={"intervention_id": intervention_id, "contact_uid": "rafiq"}, headers=_bearer("rina"))
    assert resp.status_code == 403


def test_the_contact_must_not_be_the_requester(client):
    intervention_id = _intervention(client, "rina")
    resp = client.post(PATH, json={"intervention_id": intervention_id, "contact_uid": "rina"}, headers=_bearer("rina"))
    assert resp.status_code == 422


def test_intervene_returns_an_intervention_owned_by_the_caller(client):
    intervention_id = _intervention(client, "rina")
    stored = interventions.STORE.get(intervention_id)
    assert stored is not None and stored.owner_uid == "rina"
