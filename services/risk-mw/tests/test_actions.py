"""Actions (spec FR-5, US-4): interventions/{id}, transactions/{txnId}.status, trusted contact with FCM, Money Lock."""

import threading
import time
from datetime import UTC, datetime, timedelta

import pytest

from app import notify, state
from app.routers import actions
from app.settings import get_settings

HELD_RESET = {"user_id": "rina", "session_id": "call-9", "txn": {"type": "pin_reset", "txn_id": "t-reset-1"},
              "demo_flags": {"call_active": True, "caller_in_contacts": False}}
NEW_PAYEE = {"user_id": "rina", "session_id": "s2", "txn": {"type": "send_money", "amount_bdt": 9000, "to_account": "acct_x", "is_new_payee": True, "txn_id": "t-send-1"},
             "demo_flags": {}}


def _score(client, body):
    resp = client.post("/v1/risk/score", json=body)
    assert resp.status_code == 200, resp.text
    return resp.json()


def _intervention_id(out):
    return next(a["params"]["intervention_id"] for a in out["actions"] if "intervention_id" in a["params"])


def _label(out, code):
    """The rule reason's own label, from the score response: the push's reason when Apa has no validated warning."""
    return next(r["text_bn"] for r in out["reasons"] if r["code"] == code)


@pytest.fixture
def pushes(monkeypatch):
    sent = []
    monkeypatch.setattr(notify, "send", lambda token, data, title, body: sent.append({"token": token, **data}) or "sent")
    return sent


@pytest.fixture
def rafiq_on_file():
    """The contact is always the one on file (a contact_uid in the body must match it); tests/test_actions_security.py has the rest."""
    state.store().set("users", "rina", {"trusted_contact_uid": "rafiq"})


def test_a_hold_writes_the_intervention_and_the_transaction(client):
    out = _score(client, HELD_RESET)
    iid = _intervention_id(out)
    doc = state.store().get("interventions", iid)
    assert doc["status"] == "held" and doc["decision"] == "hold" and doc["user_id"] == "rina"
    assert "CALL_ACTIVE_NON_CONTACT" in doc["reason_codes"] and "freeze_pin_reset" in doc["action_types"]
    assert state.store().get("transactions", "t-reset-1")["status"] == "held"


def test_scoring_the_same_request_twice_is_idempotent(client):
    assert _intervention_id(_score(client, HELD_RESET)) == _intervention_id(_score(client, HELD_RESET))


def test_a_delay_runs_for_an_hour(client):
    iid = _intervention_id(_score(client, NEW_PAYEE))
    doc = state.store().get("interventions", iid)
    until = datetime.fromisoformat(doc["until"])
    assert doc["status"] == "delayed" and timedelta(minutes=59) < until - datetime.now(UTC) <= timedelta(minutes=60)


def test_an_allowed_payment_records_nothing(client, score_body):
    out = _score(client, {**score_body, "txn": {**score_body["txn"], "txn_id": "t-ok"}})
    assert out["decision"] == "allow" and state.store().get("transactions", "t-ok") == {}


def test_trusted_contact_push_carries_the_deep_link(client, pushes, rafiq_on_file):
    state.store().set("users", "rafiq", {"fcm_token": "tok-rafiq"})
    out = _score(client, HELD_RESET)
    iid = _intervention_id(out)
    created = client.post("/v1/actions/trusted-contact", json={"intervention_id": iid, "contact_uid": "rafiq"}).json()
    assert pushes == [{"token": "tok-rafiq", "type": "trusted_contact", "request_id": created["request_id"], "intervention_id": iid,
                       "deep_link": f"bhorosha://approve/{created['request_id']}", "amount_bdt": "0",
                       "reason_bn": _label(out, "CALL_ACTIVE_NON_CONTACT")}]
    status = client.get(f"/v1/actions/trusted-contact/{created['request_id']}").json()
    assert status["status"] == "pending" and status["push"] == "sent"


def test_the_push_names_the_amount_and_the_top_reason_but_no_account(client, pushes, rafiq_on_file):
    state.store().set("users", "rafiq", {"fcm_token": "tok-rafiq"})
    out = _score(client, {**NEW_PAYEE, "demo_flags": {"scam_score": 0.95}})
    assert [r["code"] for r in out["reasons"]] == ["NEW_PAYEE_ABOVE_P95", "SCAM_CONVERSATION"]  # the second one weighs more
    client.post("/v1/actions/trusted-contact", json={"intervention_id": _intervention_id(out), "contact_uid": "rafiq"})
    data = {k: v for k, v in pushes[0].items() if k != "token"}
    assert data["amount_bdt"] == "9000" and data["reason_bn"] == _label(out, "SCAM_CONVERSATION")
    assert all(isinstance(v, str) for v in data.values())  # FCM data values are strings
    assert not any("acct_x" in v for v in data.values())


WARNING = {"lines": [{"role": "A", "text_bn": "রহিমা, একটু থামুন — কোডটা কাউকে বলবেন না।"},
                     {"role": "T", "text_bn": "ফোনে আপনার মেসেজে আসা কোডটা চাওয়া হচ্ছে।"},
                     {"role": "X", "text_bn": "কলটা কেটে দিন, তারপর অ্যাপের ‘ফিননেস্টে কল করুন’ বোতাম চাপুন।"}]}


def test_the_push_reason_is_apas_validated_warning_for_the_hold_never_a_fixed_sentence():
    assert actions.reason_bn({"apa_warning": WARNING, "top_reason_bn": "label"}) == WARNING["lines"][1]["text_bn"]  # what is happening
    no_t = {"lines": [WARNING["lines"][0], WARNING["lines"][2]]}
    assert actions.reason_bn({"apa_warning": no_t}) == " ".join(line["text_bn"] for line in no_t["lines"])
    assert actions.reason_bn({"top_reason_bn": "নতুন একজন প্রাপকের কাছে বড় অঙ্কের টাকা পাঠানো হচ্ছে।"}).startswith("নতুন")
    assert actions.reason_bn({}) == ""  # nothing validated and no label: no sentence is made up


def test_the_push_after_a_generated_warning_carries_its_line(client, pushes, rafiq_on_file, monkeypatch):
    from app.ledger import Evidence, Ledger
    from app.warnings import composer

    state.store().set("users", "rafiq", {"fcm_token": "tok-rafiq"})
    out = _score(client, HELD_RESET)
    ledger = Ledger(tactics={"CREDENTIAL_REQUEST": Evidence("CREDENTIAL_REQUEST", "কোডটা বলুন", 0)}, claimed_identity="bank_mfs_staff", asks=("otp",))
    state.store().set("scam_sessions", "call-9", {"uid": "demo", "ledger": ledger.to_doc(), "band": "likely", "updated_at": time.time()})
    state.store().merge("users", "rina", {"apa_address": "রহিমা"})
    text = "".join(f"{line['role']}| {line['text_bn']} || Stop.\n" for line in WARNING["lines"])
    monkeypatch.setattr(composer, "_model_text", lambda *args, **kwargs: iter([text]))
    held = client.post("/v1/intervene", json={"user_id": "rina", "trigger": "CALL_ACTIVE_NON_CONTACT", "txn": HELD_RESET["txn"]}).json()
    assert [line["role"] for line in held["lines"]] == ["A", "T", "X"]
    client.post("/v1/actions/trusted-contact", json={"intervention_id": _intervention_id(out), "contact_uid": "rafiq"})
    assert pushes[0]["reason_bn"] == WARNING["lines"][1]["text_bn"]


def test_a_long_reason_is_cut_at_a_sentence():
    text = actions.reason_bn({"top_reason_bn": "এটা একটা লম্বা বাক্য। " * 30})
    assert len(text) <= actions.REASON_MAX_CHARS and text.endswith("।")


def test_amounts_are_plain_strings():
    assert [actions.amount_text(x) for x in (9000.0, 1500000.0, 250.5, 0.0)] == ["9000", "1500000", "250.5", "0"]


def test_no_token_means_no_push_but_the_request_stands(client, pushes):
    state.store().set("users", "rina", {"trusted_contact_uid": "nobody"})
    iid = _intervention_id(_score(client, HELD_RESET))
    created = client.post("/v1/actions/trusted-contact", json={"intervention_id": iid, "contact_uid": "nobody"}).json()
    assert pushes == [] and client.get(f"/v1/actions/trusted-contact/{created['request_id']}").json()["push"] == "no_token"


def test_creating_twice_for_the_same_hold_reuses_the_request(client, pushes, rafiq_on_file):
    iid = _intervention_id(_score(client, HELD_RESET))
    a = client.post("/v1/actions/trusted-contact", json={"intervention_id": iid, "contact_uid": "rafiq"}).json()
    b = client.post("/v1/actions/trusted-contact", json={"intervention_id": iid, "contact_uid": "rafiq"}).json()
    assert a["request_id"] == b["request_id"]


def test_approve_releases_and_decline_cancels(client, pushes, rafiq_on_file):
    iid = _intervention_id(_score(client, HELD_RESET))
    rid = client.post("/v1/actions/trusted-contact", json={"intervention_id": iid, "contact_uid": "rafiq"}).json()["request_id"]
    assert client.post(f"/v1/actions/trusted-contact/{rid}/approve").json()["status"] == "approved"
    assert state.store().get("interventions", iid)["status"] == "released" and state.store().get("transactions", "t-reset-1")["status"] == "released"
    iid2 = _intervention_id(_score(client, NEW_PAYEE))
    rid2 = client.post("/v1/actions/trusted-contact", json={"intervention_id": iid2, "contact_uid": "rafiq"}).json()["request_id"]
    assert client.post(f"/v1/actions/trusted-contact/{rid2}/decline").json()["status"] == "declined"
    assert state.store().get("interventions", iid2)["status"] == "cancelled" and state.store().get("transactions", "t-send-1")["status"] == "cancelled"


def test_no_answer_in_ten_minutes_keeps_the_hold(client, pushes, rafiq_on_file, monkeypatch):
    iid = _intervention_id(_score(client, HELD_RESET))
    rid = client.post("/v1/actions/trusted-contact", json={"intervention_id": iid, "contact_uid": "rafiq"}).json()["request_id"]
    monkeypatch.setattr(actions, "_now", lambda: actions.STORE.get(rid).expires_at + timedelta(seconds=1))
    # a late tap decides nothing: the request expires and the hold stays, for an analyst (test_trusted_contact_expiry.py)
    assert client.post(f"/v1/actions/trusted-contact/{rid}/approve").json()["status"] == "expired"
    assert state.store().get("interventions", iid)["status"] == "analyst_review" and state.store().get("transactions", "t-reset-1")["status"] == "held"


def test_money_lock_holds_sends_until_unlocked(client, score_body):
    assert client.post("/v1/actions/money-lock", json={"user_id": "rina", "minutes": 120}).json()["locked"] is True
    out = _score(client, score_body)
    assert out["decision"] == "hold" and "MONEY_LOCK_ACTIVE" in {r["code"] for r in out["reasons"]}
    assert client.delete("/v1/actions/money-lock/rina").json()["locked"] is False
    assert _score(client, score_body)["decision"] == "allow"


def test_a_retry_never_re_holds_a_released_payment(client, pushes, rafiq_on_file):
    iid = _intervention_id(_score(client, HELD_RESET))
    rid = client.post("/v1/actions/trusted-contact", json={"intervention_id": iid, "contact_uid": "rafiq"}).json()["request_id"]
    client.post(f"/v1/actions/trusted-contact/{rid}/approve")
    _score(client, HELD_RESET)  # the app retries the same request
    assert state.store().get("interventions", iid)["status"] == "released" and state.store().get("transactions", "t-reset-1")["status"] == "released"


def test_the_trusted_contact_defaults_to_the_one_on_file(client, pushes):
    state.store().set("users", "rina", {"trusted_contact_uid": "rafiq"})
    state.store().set("users", "rafiq", {"fcm_token": "tok-rafiq"})
    out = _score(client, HELD_RESET)
    assert next(a for a in out["actions"] if a["type"] == "trusted_contact_check")["params"]["contact_uid"] == "rafiq"
    created = client.post("/v1/actions/trusted-contact", json={"intervention_id": _intervention_id(out)})
    assert created.status_code == 200, created.text
    status = client.get(f"/v1/actions/trusted-contact/{created.json()['request_id']}").json()
    assert status["contact_uid"] == "rafiq" and pushes[0]["token"] == "tok-rafiq"


def test_no_trusted_contact_on_file_is_a_clear_error(client):
    iid = _intervention_id(_score(client, HELD_RESET))
    resp = client.post("/v1/actions/trusted-contact", json={"intervention_id": iid})
    assert resp.status_code == 422 and "trusted contact" in resp.json()["detail"]


def test_approve_and_decline_at_once_settle_one_way(client, pushes, rafiq_on_file, monkeypatch):
    """Spec US-4 'one atomic update each': two taps racing both read 'pending', yet only one decides and both are told the same."""
    iid = _intervention_id(_score(client, HELD_RESET))
    rid = client.post("/v1/actions/trusted-contact", json={"intervention_id": iid}).json()["request_id"]
    slow = state.MemoryStore.get

    def slow_get(self, collection, doc_id):
        doc = slow(self, collection, doc_id)
        time.sleep(0.03)  # every read waits on the network, so both taps see 'pending' unless the update is atomic
        return doc

    monkeypatch.setattr(state.MemoryStore, "get", slow_get)
    gate, answers = threading.Barrier(2), {}

    def tap(route):
        gate.wait()
        answers[route.__name__] = route(rid, "rafiq", get_settings(), datetime.now(UTC)).status

    threads = [threading.Thread(target=tap, args=(r,)) for r in (actions.approve, actions.decline)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    monkeypatch.undo()
    iv, txn = state.store().get("interventions", iid)["status"], state.store().get("transactions", "t-reset-1")["status"]
    assert iv == txn and iv in ("released", "cancelled")
    told = {"released": "approved", "cancelled": "declined"}[iv]
    assert answers == {"approve": told, "decline": told}


def test_every_decision_is_audited_with_who_answered(client, pushes, rafiq_on_file, monkeypatch):
    rows = []
    monkeypatch.setattr(actions.audit, "record", lambda kind, uid, inputs, outputs, ms: rows.append((kind, uid, inputs, outputs)) or "a1")
    iid = _intervention_id(_score(client, HELD_RESET))
    rid = client.post("/v1/actions/trusted-contact", json={"intervention_id": iid}, headers={"X-Demo-User": "rina"}).json()["request_id"]
    client.post(f"/v1/actions/trusted-contact/{rid}/approve", headers={"X-Demo-User": "rafiq"})
    decided = [r for r in rows if r[0] == "trusted_contact_decision"]
    assert decided == [("trusted_contact_decision", "rafiq",
                        {"request_id": rid, "verdict": "approved", "contact_uid": "rafiq", "requester_uid": "rina", "intervention_id": iid},
                        {"request_id": rid, "status": "approved", "decided_by": "rafiq", "contact_verified": True, "won": True,
                         "hold": "released"})]
    assert [r[:2] for r in rows if r[0] == "trusted_contact_create"] == [("trusted_contact_create", "rina")]
    assert actions.STORE.get(rid).decided_by == "rafiq"


SIM_RESET = {"user_id": "rina", "session_id": "app-s", "txn": {"type": "pin_reset"}, "demo_flags": {"sim_swap": True}}
SCAM_RESET = {**SIM_RESET, "demo_flags": {"sim_swap": True, "call_active": True, "caller_in_contacts": False, "scam_score": 0.95}}


def test_a_later_different_hold_in_the_same_session_is_a_new_intervention(client, pushes, rafiq_on_file):
    """No txn_id (the spec's flows send none): a retry of the same hold keeps its id, but a later hold for other reasons gets
    its own intervention, transaction and trusted-contact request instead of inheriting an earlier approval."""
    first = _score(client, SIM_RESET)
    iid = _intervention_id(first)
    rid = client.post("/v1/actions/trusted-contact", json={"intervention_id": iid}).json()["request_id"]
    assert client.post(f"/v1/actions/trusted-contact/{rid}/approve").json()["status"] == "approved"
    assert _intervention_id(_score(client, SIM_RESET)) == iid  # the app retries the released request: still released
    assert state.store().get("interventions", iid)["status"] == "released"
    later = _score(client, SCAM_RESET)
    later_iid = _intervention_id(later)
    assert later["decision"] == "hold" and later_iid != iid and _intervention_id(_score(client, SCAM_RESET)) == later_iid
    doc = state.store().get("interventions", later_iid)
    assert doc["status"] == "held" and "CALL_ACTIVE_NON_CONTACT" in doc["reason_codes"]
    assert state.store().get("transactions", doc["txn_key"])["status"] == "held"
    again = client.post("/v1/actions/trusted-contact", json={"intervention_id": later_iid}).json()["request_id"]
    assert again != rid and client.get(f"/v1/actions/trusted-contact/{again}").json()["status"] == "pending"


def _send(client, score_body, amount):
    out = _score(client, {**score_body, "txn": {**score_body["txn"], "amount_bdt": amount}})
    return out["decision"], "MONEY_LOCK_ACTIVE" in {r["code"] for r in out["reasons"]}


def test_money_lock_on_a_sub_balance_holds_only_sends_that_dip_into_it(client, score_body):
    """Spec section 2: Money Lock on a sub-balance. Rina keeps 8,000 of her 10,000 BDT locked and still pays for groceries."""
    state.store().set("users", "rina", {"balance_bdt": 10000})
    out = client.post("/v1/actions/money-lock", json={"user_id": "rina", "minutes": 600, "locked_bdt": 8000}).json()
    assert out["locked"] is True and out["locked_bdt"] == 8000
    assert _send(client, score_body, 500) == ("allow", False)
    assert _send(client, score_body, 2000) == ("allow", False)  # exactly down to the locked part
    assert _send(client, score_body, 3000) == ("hold", True)


def test_a_sub_balance_lock_with_no_balance_known_holds_every_send(client, score_body):
    client.post("/v1/actions/money-lock", json={"user_id": "rina", "minutes": 600, "locked_bdt": 8000})
    assert _send(client, score_body, 50) == ("hold", True)


def test_a_whole_balance_lock_holds_every_send(client, score_body):
    state.store().set("users", "rina", {"balance_bdt": 10000})
    client.post("/v1/actions/money-lock", json={"user_id": "rina", "minutes": 600})
    assert _send(client, score_body, 50) == ("hold", True)


def test_lock_and_unlock_are_recorded_like_an_intervention(client):
    client.post("/v1/actions/money-lock", json={"user_id": "rina", "minutes": 60, "locked_bdt": 5000}, headers={"X-Demo-User": "rina"})
    iid = state.store().get("money_lock", "rina")["intervention_id"]
    doc = state.store().get("interventions", iid)
    assert doc | {"until": None, "created_at": None, "updated_at": None} == {
        "id": iid, "user_id": "rina", "kind": "money_lock", "decision": "money_lock", "status": "locked", "locked_bdt": 5000,
        "set_by": "rina", "until": None, "created_at": None, "updated_at": None}
    client.delete("/v1/actions/money-lock/rina", headers={"X-Demo-User": "rina"})
    doc = state.store().get("interventions", iid)
    assert doc["status"] == "unlocked" and doc["unlocked_by"] == "rina"
