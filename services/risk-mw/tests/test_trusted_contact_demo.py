"""In demo mode (auth off, the caller named by X-Demo-User), which the app and the portal run against today.

The app has no persona for the contact and sends the signed-in persona on approve/decline, so in demo mode anyone may
decide; the answer and the audit row say whether it was the named contact (`contact_verified`). With auth on only the
contact may (tests/test_trusted_contact.py).
"""

from __future__ import annotations

PATH = "/v1/actions/trusted-contact"


def _demo(uid: str) -> dict[str, str]:
    return {"X-Demo-User": uid}


def _create(client, requester: str = "rina", contact: str = "rafiq", intervention_id: str = "int_local_1") -> str:
    created = client.post(PATH, json={"intervention_id": intervention_id, "contact_uid": contact}, headers=_demo(requester))
    assert created.status_code == 200, created.text
    return created.json()["request_id"]


def test_the_named_contact_decides_and_is_verified(client):
    request_id = _create(client)
    approved = client.post(f"{PATH}/{request_id}/approve", headers=_demo("rafiq"))
    assert approved.status_code == 200
    assert approved.json() == {"request_id": request_id, "status": "approved", "decided_by": "rafiq", "contact_verified": True}


def test_someone_else_may_decide_in_demo_mode_and_the_answer_says_so(client, monkeypatch):
    rows: list[tuple[str, str, dict]] = []
    monkeypatch.setattr("app.audit.record", lambda kind, uid, inputs, outputs, ms: rows.append((kind, uid, outputs)) or "id")
    request_id = _create(client)

    approved = client.post(f"{PATH}/{request_id}/approve", headers=_demo("rina"))  # the app's signed-in persona
    assert approved.status_code == 200, approved.text
    assert approved.json() == {"request_id": request_id, "status": "approved", "decided_by": "rina", "contact_verified": False}
    decided = [r for r in rows if r[0] == "trusted_contact_decision"]
    assert decided and decided[0][1] == "rina" and decided[0][2]["contact_verified"] is False


def test_a_later_call_returns_how_it_was_settled(client):
    request_id = _create(client)
    client.post(f"{PATH}/{request_id}/decline", headers=_demo("portal-analyst"))
    again = client.post(f"{PATH}/{request_id}/approve", headers=_demo("rafiq")).json()
    assert (again["status"], again["decided_by"], again["contact_verified"]) == ("declined", "portal-analyst", False)


def test_demo_mode_accepts_a_client_side_intervention_id(client):
    """The app sends its own local record id, which the server never issued. Outside demo mode that is 404."""
    _create(client, intervention_id="int_never_seen")


def test_demo_mode_still_refuses_another_callers_intervention(client):
    body = {"user_id": "rahima", "trigger": "call_active", "txn": {"type": "pin_reset"}}
    intervention_id = client.post("/v1/intervene", json=body, headers=_demo("rahima")).json()["intervention_id"]
    resp = client.post(PATH, json={"intervention_id": intervention_id, "contact_uid": "rafiq"}, headers=_demo("rina"))
    assert resp.status_code == 403


def test_demo_mode_still_refuses_naming_yourself(client):
    resp = client.post(PATH, json={"intervention_id": "int_local_2", "contact_uid": "rina"}, headers=_demo("rina"))
    assert resp.status_code == 422
