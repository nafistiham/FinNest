"""Actions with RISK_MW_AUTH_REQUIRED=true: who may ask a trusted contact, who may answer, and what a request can
release (spec US-4). Token verification is stubbed so a token's text is the caller's uid."""

import pytest

from dataclasses import replace
from datetime import UTC, datetime

from app import auth, notify, state
from app.routers import actions
from app.settings import get_settings

HELD_RESET = {"user_id": "rina", "session_id": "call-9", "txn": {"type": "pin_reset", "txn_id": "t-reset-1"},
              "demo_flags": {"call_active": True, "caller_in_contacts": False}}
BLOCKED_SEND = {"user_id": "rina", "session_id": "s3", "txn": {"type": "send_money", "amount_bdt": 900, "to_account": "acct_y", "txn_id": "t-block-1"},
                "demo_flags": {"app_safety_verdict": "BLOCK"}}


@pytest.fixture
def auth_on(monkeypatch):
    monkeypatch.setenv("RISK_MW_AUTH_REQUIRED", "true")
    get_settings.cache_clear()
    monkeypatch.setattr(auth, "_verify_firebase_token", lambda token: token)
    yield
    monkeypatch.undo()
    get_settings.cache_clear()


@pytest.fixture
def pushes(monkeypatch):
    sent = []
    monkeypatch.setattr(notify, "send", lambda token, data, title, body: sent.append({"token": token, **data}) or "sent")
    return sent


@pytest.fixture
def family():
    state.store().set("users", "rina", {"trusted_contact_uid": "rafiq"})
    state.store().set("users", "rafiq", {"fcm_token": "tok-rafiq"})
    state.store().set("users", "mallory", {"fcm_token": "tok-mallory", "trusted_contact_uid": "mallory2"})


def as_(uid):
    return {"Authorization": f"Bearer {uid}"}


def _hold(client, body=HELD_RESET, uid="rina"):
    out = client.post("/v1/risk/score", json=body, headers=as_(uid))
    assert out.status_code == 200, out.text
    return next(a["params"]["intervention_id"] for a in out.json()["actions"] if "intervention_id" in a["params"])


def _ask(client, iid, uid="rina", contact=None):
    return client.post("/v1/actions/trusted-contact", json={"intervention_id": iid, **({"contact_uid": contact} if contact else {})},
                       headers=as_(uid))


def _txn(key="t-reset-1"):
    return state.store().get("transactions", key).get("status")


def test_the_owner_asks_the_contact_on_file_and_only_that_contact_can_release(client, auth_on, family, pushes):
    iid = _hold(client)
    created = _ask(client, iid)
    assert created.status_code == 200, created.text
    rid = created.json()["request_id"]
    assert [p["token"] for p in pushes] == ["tok-rafiq"]
    assert client.post(f"/v1/actions/trusted-contact/{rid}/approve", headers=as_("rina")).status_code == 403
    assert client.post(f"/v1/actions/trusted-contact/{rid}/approve", headers=as_("mallory")).status_code == 403
    assert _txn() == "held"
    assert client.post(f"/v1/actions/trusted-contact/{rid}/approve", headers=as_("rafiq")).json()["status"] == "approved"
    assert _txn() == "released"


def test_the_customer_cannot_name_herself_as_the_contact(client, auth_on, family, pushes):
    iid = _hold(client)
    resp = _ask(client, iid, contact="rina")
    assert resp.status_code == 422 and pushes == []  # Naming yourself is a 422
    assert actions.STORE.pending() == () and _txn() == "held"


def test_the_customer_cannot_name_another_account_as_the_contact(client, auth_on, family, pushes):
    iid = _hold(client)
    assert _ask(client, iid, contact="mallory").status_code == 403 and pushes == []
    assert _ask(client, iid, contact="rafiq").status_code == 200  # naming the contact on file is fine


def test_another_user_cannot_ask_about_someone_elses_hold(client, auth_on, family, pushes):
    iid = _hold(client)
    assert _ask(client, iid, uid="mallory").status_code == 403
    assert _ask(client, iid, uid="mallory", contact="rafiq").status_code == 403
    assert _ask(client, iid, uid="mallory", contact="mallory").status_code == 422  # naming herself is refused first
    assert pushes == [] and _txn() == "held"


def test_a_contact_on_file_equal_to_the_owner_is_refused(client, auth_on, pushes):
    state.store().set("users", "rina", {"trusted_contact_uid": "rina", "fcm_token": "tok-rina"})
    iid = _hold(client)
    assert _ask(client, iid).status_code == 422 and pushes == []


def test_a_block_cannot_be_released_by_a_trusted_contact(client, auth_on, family, pushes):
    iid = _hold(client, BLOCKED_SEND)
    assert state.store().get("interventions", iid)["status"] == "blocked"
    resp = _ask(client, iid)
    assert resp.status_code == 409 and pushes == [] and _txn("t-block-1") == "blocked"


def test_a_money_lock_hold_offers_no_trusted_contact(client, auth_on, family, pushes, score_body):
    assert client.post("/v1/actions/money-lock", json={"user_id": "rina", "minutes": 60}, headers=as_("rina")).status_code == 200
    out = client.post("/v1/risk/score", json={**score_body, "txn": {**score_body["txn"], "txn_id": "t-lock-1"}}, headers=as_("rina")).json()
    assert out["decision"] == "hold" and "trusted_contact_check" not in {a["type"] for a in out["actions"]}
    iid = next(a["params"]["intervention_id"] for a in out["actions"])
    assert _ask(client, iid).status_code == 409 and pushes == [] and _txn("t-lock-1") == "held"


def test_an_unknown_intervention_is_not_found(client, auth_on, family, pushes):
    assert _ask(client, "iv-made-up").status_code == 404 and pushes == []


def test_with_auth_off_any_caller_may_ask_but_only_the_contact_on_file(client, family, pushes):
    iid = _hold(client)
    assert client.post("/v1/actions/trusted-contact", json={"intervention_id": iid, "contact_uid": "mallory"}).status_code == 403
    assert client.post("/v1/actions/trusted-contact", json={"intervention_id": iid}, headers={"X-Demo-User": "demo"}).status_code == 200


def test_another_user_reusing_a_txn_id_cannot_re_point_or_release_it(client, auth_on, family, pushes):
    """transactions/{txnId} is keyed by the app's txn_id: the first owner keeps it. Mallory's own hold on the same id gets
    no transaction, so her own contact's approval releases nothing of Rina's."""
    rina_iid = _hold(client, {**HELD_RESET, "txn": {"type": "pin_reset", "txn_id": "t-9"}})
    assert state.store().get("transactions", "t-9") | {"updated_at": None} == {
        "status": "held", "intervention_id": rina_iid, "user_id": "rina", "updated_at": None}
    mallory_body = {**HELD_RESET, "user_id": "mallory", "session_id": "m-1", "txn": {"type": "pin_reset", "txn_id": "t-9"}}
    mallory_iid = _hold(client, mallory_body, uid="mallory")
    assert state.store().get("transactions", "t-9")["intervention_id"] == rina_iid
    state.store().set("users", "mallory2", {"fcm_token": "tok-m2"})
    rid = _ask(client, mallory_iid, uid="mallory").json()["request_id"]
    assert client.post(f"/v1/actions/trusted-contact/{rid}/approve", headers=as_("mallory2")).json()["status"] == "approved"
    assert state.store().get("interventions", mallory_iid)["status"] == "released"
    assert _txn("t-9") == "held" and state.store().get("interventions", rina_iid)["status"] == "held"


def test_with_auth_on_a_user_can_only_score_for_herself(client, auth_on, family, pushes):
    out = client.post("/v1/risk/score", json=HELD_RESET, headers=as_("mallory"))
    assert out.status_code == 403 and "contact_uid" not in out.text
    assert state.store().get("transactions", "t-reset-1") == {}


def test_only_the_owner_can_lock_or_unlock_her_money(client, auth_on, family, pushes, score_body, monkeypatch):
    from app.routers import actions

    rows = []
    monkeypatch.setattr(actions.audit, "record", lambda kind, uid, inputs, outputs, ms: rows.append((kind, uid)) or "a1")
    lock = {"user_id": "rina", "minutes": 600}
    assert client.post("/v1/actions/money-lock", json=lock, headers=as_("mallory")).status_code == 403
    assert state.store().get("money_lock", "rina") == {}
    assert client.post("/v1/actions/money-lock", json=lock, headers=as_("rina")).status_code == 200
    assert client.delete("/v1/actions/money-lock/rina", headers=as_("mallory")).status_code == 403
    held = client.post("/v1/risk/score", json=score_body, headers=as_("rina")).json()
    assert held["decision"] == "hold" and "MONEY_LOCK_ACTIVE" in {r["code"] for r in held["reasons"]}
    assert client.delete("/v1/actions/money-lock/rina", headers=as_("rina")).json()["locked"] is False
    assert [r for r in rows if r[0].startswith("money")] == [("money_lock", "rina"), ("money_unlock", "rina")]


def test_with_auth_off_money_lock_stays_open_for_the_demo(client):
    assert client.post("/v1/actions/money-lock", json={"user_id": "rina", "minutes": 5}, headers={"X-Demo-User": "demo"}).status_code == 200
    assert client.delete("/v1/actions/money-lock/rina").status_code == 200


OPERATOR = {"X-Operator-Token": "op-secret"}


@pytest.fixture
def operator_token(monkeypatch):
    monkeypatch.setenv("RISK_MW_OPERATOR_TOKEN", "op-secret")
    get_settings.cache_clear()
    yield
    monkeypatch.delenv("RISK_MW_OPERATOR_TOKEN")
    get_settings.cache_clear()


def _overdue_request(client):
    iid = _hold(client)
    rid = _ask(client, iid).json()["request_id"]
    item = actions.STORE.get(rid)
    actions.STORE.add(replace(item, expires_at=datetime(2020, 1, 1, tzinfo=UTC)), datetime.now(UTC))
    return rid


def test_with_auth_on_only_the_operator_can_sweep(client, auth_on, operator_token, family, pushes):
    rid = _overdue_request(client)
    assert client.post("/v1/actions/trusted-contact/sweep", headers=as_("mallory")).status_code == 403
    assert client.post("/v1/actions/trusted-contact/sweep").status_code == 403
    assert client.post("/v1/actions/trusted-contact/sweep", headers={"X-Operator-Token": "guess"}).status_code == 403
    assert len(pushes) == 1  # nothing was swept
    out = client.post("/v1/actions/trusted-contact/sweep", headers=OPERATOR).json()
    assert out == {"checked": 1, "expired": [rid], "expired_count": 1}


def test_with_auth_on_and_no_operator_token_set_nobody_can_sweep(client, auth_on, family, pushes):
    _overdue_request(client)
    assert client.post("/v1/actions/trusted-contact/sweep", headers=as_("rina")).status_code == 403
    assert client.post("/v1/actions/trusted-contact/sweep", headers={"X-Operator-Token": ""}).status_code == 403


def test_in_demo_mode_the_sweep_gives_counts_but_no_request_ids(client, family, pushes):
    _overdue_request(client)
    out = client.post("/v1/actions/trusted-contact/sweep").json()
    assert out == {"checked": 1, "expired": [], "expired_count": 1}


def test_with_auth_on_only_the_owner_and_the_contact_can_read_a_request(client, auth_on, family, pushes):
    rid = _ask(client, _hold(client)).json()["request_id"]
    assert client.get(f"/v1/actions/trusted-contact/{rid}", headers=as_("mallory")).status_code == 403
    assert client.get(f"/v1/actions/trusted-contact/{rid}", headers=as_("rina")).json()["contact_uid"] == "rafiq"
    assert client.get(f"/v1/actions/trusted-contact/{rid}", headers=as_("rafiq")).status_code == 200
