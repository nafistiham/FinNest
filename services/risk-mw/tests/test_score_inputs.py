"""Score inputs: demo_state/{uid} (FR-6), per-user p95 from users/{uid}, and the demo control route."""

from app import state


def _score(client, body):
    resp = client.post("/v1/risk/score", json=body)
    assert resp.status_code == 200, resp.text
    return resp.json()


def _codes(out):
    return {r["code"] for r in out["reasons"]}


def test_demo_state_drives_the_flags_without_the_app_sending_them(client, score_body):
    state.store().set("demo_state", "rina", {"call_active": True, "caller_in_contacts": False})
    out = _score(client, {**score_body, "txn": {"type": "pin_reset"}})
    assert out["decision"] == "hold" and "CALL_ACTIVE_NON_CONTACT" in _codes(out)


def test_demo_state_and_request_flags_merge_to_the_more_severe(client, score_body):
    state.store().set("demo_state", "rina", {"sim_swap": True, "app_safety_verdict": "CAUTION", "scam_score": 0.2})
    body = {**score_body, "demo_flags": {"app_safety_verdict": "BLOCK", "scam_score": 0.1}}
    out = _score(client, body)
    assert out["decision"] == "block" and {"SIM_CHANGED_24H", "APP_SAFETY_BLOCK"} <= _codes(out)


def test_users_p95_sets_the_new_payee_threshold(client, score_body):
    body = {**score_body, "txn": {"type": "send_money", "amount_bdt": 3000, "to_account": "acct_new", "is_new_payee": True}}
    assert _score(client, body)["decision"] == "allow"  # default p95 is 5000
    state.store().set("users", "rina", {"p95_send_bdt": 2000})  # the field name the seed loader writes
    out = _score(client, body)
    assert out["decision"] == "delay" and "NEW_PAYEE_ABOVE_P95" in _codes(out)


def test_demo_control_route_sets_and_reads_demo_state(client, score_body):
    put = client.put("/v1/demo/state/rina", json={"call_active": True, "sim_swap": True})
    assert put.status_code == 200 and put.json()["call_active"] is True
    assert client.get("/v1/demo/state/rina").json()["sim_swap"] is True
    out = _score(client, {**score_body, "txn": {"type": "pin_reset"}})
    assert {"CALL_ACTIVE_NON_CONTACT", "SIM_CHANGED_24H"} <= _codes(out)
    assert client.delete("/v1/demo/state/rina").status_code == 200
    assert _score(client, {**score_body, "txn": {"type": "pin_reset"}})["decision"] == "allow"


def test_demo_control_rejects_unknown_flags(client):
    assert client.put("/v1/demo/state/rina", json={"teleport": True}).status_code == 422


def test_firestore_store_reads_and_merges_documents():
    class Doc:
        def __init__(self, data):
            self.data = data
            self.exists = data is not None

        def to_dict(self):
            return self.data

    class Ref:
        def __init__(self, db, path):
            self.db, self.path = db, path

        def get(self):
            return Doc(self.db.get(self.path))

        def set(self, data, merge=False):
            self.db[self.path] = {**(self.db.get(self.path) or {}), **data} if merge else dict(data)

        def delete(self):
            self.db.pop(self.path, None)

    class Coll:
        def __init__(self, db, name):
            self.db, self.name = db, name

        def document(self, doc_id):
            return Ref(self.db, f"{self.name}/{doc_id}")

    class FakeClient:
        def __init__(self):
            self.db = {}

        def collection(self, name):
            return Coll(self.db, name)

    fs = state.FirestoreStore(FakeClient())
    assert fs.get("users", "x") == {}
    fs.set("users", "x", {"a": 1})
    fs.merge("users", "x", {"b": 2})
    assert fs.get("users", "x") == {"a": 1, "b": 2}
    fs.delete("users", "x")
    assert fs.get("users", "x") == {}


# --- freeze_pin_reset(60 min) is enforced (spec section 2) -----------------------------------------------------------

PIN_RESET = {"user_id": "rina", "session_id": "call-1", "txn": {"type": "pin_reset"}}
ON_A_CALL = {"call_active": True, "caller_in_contacts": False}


def _held_on_a_call(client) -> dict:
    out = _score(client, {**PIN_RESET, "demo_flags": ON_A_CALL})
    assert out["decision"] == "hold" and out["actions"][0]["type"] == "freeze_pin_reset"
    return out


def test_a_pin_reset_held_on_a_call_stays_frozen_after_the_call(client):
    """'Hang up and try again': the retry, in the same session or a new one, is held with the original reasons, so Apa
    plays the same fixed line (no new reason code)."""
    first = _held_on_a_call(client)
    for session in ("call-1", "after-the-call"):
        again = _score(client, {**PIN_RESET, "session_id": session})
        assert again["decision"] == "hold" and again["reasons"] == first["reasons"]
        assert [a["type"] for a in again["actions"]] == ["freeze_pin_reset", "trusted_contact_check"]


def test_the_freeze_lasts_its_minutes_and_a_retry_does_not_extend_it(client):
    from datetime import UTC, datetime, timedelta

    _held_on_a_call(client)
    frozen = state.store().get("pin_freeze", "rina")
    until = datetime.fromisoformat(frozen["until"])
    assert timedelta(minutes=59) < until - datetime.now(UTC) <= timedelta(minutes=60)
    assert frozen["reason_codes"] == ["CALL_ACTIVE_NON_CONTACT"]
    _score(client, {**PIN_RESET, "session_id": "retry"})
    assert state.store().get("pin_freeze", "rina")["until"] == frozen["until"]
    state.store().merge("pin_freeze", "rina", {"until": (datetime.now(UTC) - timedelta(seconds=1)).isoformat()})
    assert _score(client, {**PIN_RESET, "session_id": "an-hour-later"})["decision"] == "allow"


def test_the_freeze_holds_only_that_users_pin_resets(client, score_body):
    _held_on_a_call(client)
    assert _score(client, score_body)["decision"] == "allow"  # her sends are not frozen
    assert _score(client, {**PIN_RESET, "user_id": "karim"})["decision"] == "allow"


def test_the_freeze_is_read_with_the_scores_other_documents(client, monkeypatch):
    asked = []
    many = state.get_many
    monkeypatch.setattr(state, "get_many", lambda keys: asked.append(tuple(keys)) or many(keys))
    _score(client, PIN_RESET)
    assert len(asked) == 1 and ("pin_freeze", "rina") in asked[0]


def test_the_trusted_contacts_approval_lifts_the_freeze_it_answered(client):
    """F1 x F2: the freeze re-held a PIN reset the daughter had already approved, and the re-hold mapped onto the released
    intervention, so the answer said hold while the record said released. Her approval now lifts that freeze."""
    state.store().set("users", "rina", {"trusted_contact_uid": "rafiq"})
    held = _held_on_a_call(client)
    iid = held["actions"][0]["params"]["intervention_id"]
    rid = client.post("/v1/actions/trusted-contact", json={"intervention_id": iid}).json()["request_id"]
    assert client.post(f"/v1/actions/trusted-contact/{rid}/approve").json()["status"] == "approved"
    assert state.store().get("interventions", iid)["status"] == "released"
    assert _score(client, {**PIN_RESET, "session_id": "after-approval"})["decision"] == "allow"


def test_a_declined_hold_keeps_its_freeze(client):
    state.store().set("users", "rina", {"trusted_contact_uid": "rafiq"})
    held = _held_on_a_call(client)
    rid = client.post("/v1/actions/trusted-contact", json={"intervention_id": held["actions"][0]["params"]["intervention_id"]}).json()["request_id"]
    assert client.post(f"/v1/actions/trusted-contact/{rid}/decline").json()["status"] == "declined"
    assert _score(client, {**PIN_RESET, "session_id": "after-decline"})["decision"] == "hold"
