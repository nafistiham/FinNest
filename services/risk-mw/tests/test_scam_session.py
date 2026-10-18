"""scam_sessions/{id}: the call's evidence and score as Firestore stores them (spec US-2, FR-3)."""

import logging
import time
import typing

import pytest
from google.api_core.exceptions import InvalidArgument, ServiceUnavailable

from app import scam, state
from app.contracts import TxnType

THREAT = "আপনার একাউন্ট আজ বন্ধ হয়ে যাবে, এখনই ঠিক করতে হবে"


def verdict(conf):
    """One verified tactic and no ask: no rule fires, so these tests see the model's score and the hysteresis alone."""
    return scam.ScamExtraction(tactics=[{"tactic": "URGENCY_THREAT", "quote": "আজ বন্ধ হয়ে যাবে"}], verdict="SCAM", confidence=conf)


@pytest.fixture
def model(monkeypatch):
    queue = []
    monkeypatch.setattr(scam, "_model_extraction", lambda turns, settings, cards: queue.pop(0))
    return queue


def _nested_array(value) -> bool:
    if isinstance(value, dict):
        return any(_nested_array(v) for v in value.values())
    if isinstance(value, list | tuple):
        return any(isinstance(v, list | tuple) or _nested_array(v) for v in value)
    return False


class FirestoreLike:
    """A Firestore client fake that keeps Firestore's data rule the memory store does not: an array cannot directly
    contain another array (the server answers 400 InvalidArgument). Wrapped in the real state.FirestoreStore."""

    def __init__(self):
        self.docs = {}

    def collection(self, name):
        return _Collection(self, name)


class FirestoreLikeStore(state.FirestoreStore):
    """The real FirestoreStore over the fake client; a transaction body runs against the same rule-checking fake."""

    def run(self, fn):
        return fn(self)


class _Collection:
    def __init__(self, db, name):
        self.db, self.name = db, name

    def document(self, doc_id):
        return _Ref(self.db, (self.name, doc_id))


class _Snap:
    def __init__(self, data):
        self.data, self.exists = data, data is not None

    def to_dict(self):
        return self.data


class _Ref:
    def __init__(self, db, path):
        self.db, self.path = db, path

    def get(self):
        return _Snap(self.db.docs.get(self.path))

    def set(self, data, merge=False):
        if _nested_array(data):
            raise InvalidArgument("Cannot convert an array value in an array value.")
        self.db.docs[self.path] = {**(self.db.docs.get(self.path) or {}), **data} if merge else dict(data)

    def delete(self):
        self.db.docs.pop(self.path, None)


@pytest.fixture
def firestore(monkeypatch):
    fs = FirestoreLikeStore(FirestoreLike())
    monkeypatch.setattr(state, "store", lambda: fs)
    return fs


def turn(client, session, text, ts, speaker="caller", as_user=None, **extra):
    body = {"session_id": session, "turns": [{"speaker": speaker, "text": text, "ts": ts}], **extra}
    resp = client.post("/v1/scam/turn", json=body, headers={"X-Demo-User": as_user} if as_user else {})
    assert resp.status_code == 200, resp.text
    return resp.json()


def score(client, session, txn_type="pin_reset", as_user=None):
    body = {"user_id": as_user or "rina", "session_id": session, "txn": {"type": txn_type}}
    resp = client.post("/v1/risk/score", json=body, headers={"X-Demo-User": as_user} if as_user else {})
    assert resp.status_code == 200, resp.text
    return resp.json()


def _codes(out):
    return {r["code"] for r in out["reasons"]}


def test_the_fake_rejects_what_firestore_rejects(firestore):
    with pytest.raises(InvalidArgument):
        firestore.set("scam_sessions", "x", {"turns": [[1.0, 0.5]]})
    firestore.set("scam_sessions", "x", {"turns": [{"ts": 1.0, "c": 0.5}]})


def test_a_call_scored_on_firestore_reaches_the_pin_reset_score(client, model, firestore):
    """Two caller turns at 0.75 and 0.8 meet the hysteresis; the call must be a document Firestore accepts."""
    model += [verdict(0.75), verdict(0.8)]
    assert turn(client, "call-fs", THREAT, 1.0)["rolling_score"] < 0.7
    assert turn(client, "call-fs", THREAT, 9.0)["rolling_score"] == 0.8
    out = score(client, "call-fs")
    assert out["decision"] == "hold" and "SCAM_CONVERSATION" in {r["code"] for r in out["reasons"]}


def test_an_older_list_of_pairs_window_is_still_read(client, model):
    """A window written as [ts, c] pairs (the memory store accepted them) still counts towards the hysteresis."""
    state.store().set("scam_sessions", "call-old", {"turns": [[1.0, 0.75]], "rolling": 0.69, "updated_at": time.time()})
    model += [verdict(0.8)]
    assert turn(client, "call-old", THREAT, 9.0)["rolling_score"] == 0.8


class BrokenStore(state.MemoryStore):
    def set(self, collection, doc_id, data):
        raise ServiceUnavailable("firestore is down")


def test_a_failed_session_write_scores_the_turn_alone(client, model, monkeypatch, caplog):
    """A store failure costs the stored evidence, not the call: no 500, the turn's own score (hysteresis still applies), a log line."""
    broken = BrokenStore()
    monkeypatch.setattr(state, "store", lambda: broken)
    model += [verdict(0.85), verdict(0.95)]
    with caplog.at_level(logging.WARNING, logger="app.scam"):
        alone = turn(client, "call-down", THREAT, 1.0)
        assert alone["rolling_score"] == 0.69 and alone["recommended_action"] == "none"  # one turn below 0.9 never alerts
        assert turn(client, "call-down", THREAT, 9.0, pending_action="pin_reset")["rolling_score"] == 0.95
    assert any("scam session" in r.getMessage() and "ServiceUnavailable" in r.getMessage() for r in caplog.records)


# --- hysteresis counts each caller turn once -------------------------------------------------------------------------

REPLY = "আচ্ছা, দেখছি"


def turns(client, session, *spoken, **extra):
    """Post the call so far, [(speaker, text, ts), ...], as the app does after each turn."""
    body = {"session_id": session, "turns": [{"speaker": s, "text": t, "ts": ts} for s, t, ts in spoken], **extra}
    resp = client.post("/v1/scam/turn", json=body)
    assert resp.status_code == 200, resp.text
    return resp.json()


def test_the_victims_reply_does_not_count_the_callers_turn_again(client, model):
    """One caller line at 0.85 is below the alert; posting the call again after the victim answers must not make it two."""
    model += [verdict(0.85), verdict(0.85), verdict(0.85)]
    said = [("caller", THREAT, 24.0)]
    assert turns(client, "call-r", *said)["rolling_score"] == 0.69
    said.append(("user", REPLY, 30.0))
    after_reply = turns(client, "call-r", *said, pending_action="pin_reset")
    assert after_reply["rolling_score"] == 0.69 and after_reply["recommended_action"] == "none"
    assert "SCAM_CONVERSATION" not in {r["code"] for r in score(client, "call-r")["reasons"]}
    said.append(("caller", THREAT, 36.0))
    assert turns(client, "call-r", *said)["rolling_score"] == 0.85  # a second caller turn does count


def test_a_caller_turn_first_posted_with_the_reply_counts_once(client, model):
    """An app that posts only after the victim answers still gets one point per caller turn."""
    model += [verdict(0.85), verdict(0.85), verdict(0.85)]
    said = [("caller", THREAT, 0.0), ("user", REPLY, 6.0)]
    assert turns(client, "call-u", *said)["rolling_score"] == 0.69
    assert turns(client, "call-u", *said)["rolling_score"] == 0.69  # a retry of the same request
    said += [("caller", THREAT, 12.0), ("user", REPLY, 18.0)]
    assert turns(client, "call-u", *said)["rolling_score"] == 0.85


def test_a_request_with_no_caller_turn_adds_no_point(client, model):
    model += [verdict(0.95)]
    assert turns(client, "call-n", ("user", "হ্যালো?", 0.0))["rolling_score"] == 0.0


def test_the_demo_replay_detects_on_a_caller_turn(client):
    """The transcript-first replay posts after every turn, the victim's too; detection must land on a caller's words."""
    from app import demo_replay

    def post(path, body):
        resp = client.post(path, json=body)
        assert resp.status_code == 200, resp.text
        return resp.json()

    for script in demo_replay.load_scripts():
        out = demo_replay.replay(post, script)
        if out["detected_turn"] is not None:
            assert out["timeline"][out["detected_turn"]]["speaker"] == "caller", script["id"]


# --- one stray ts cannot freeze or wipe the call; a session belongs to the account that scored it ----------------------

HELLO = "হ্যালো"
FAR_FUTURE = 1e12


def test_a_far_future_turn_cannot_freeze_or_wipe_a_call_clock_call(client, model):
    """Transcript-first turns run on the call's clock (0, 6, 12 ...). One turn stamped far ahead, by mistake (a server-clock
    fallback turn) or on purpose, is one more point of the call: with no time window it cannot push the real turns out."""
    model += [verdict(0.85), verdict(0.85), verdict(0.05), verdict(0.85), verdict(0.85)]
    turn(client, "call-7", THREAT, 0.0)
    assert turn(client, "call-7", THREAT, 6.0)["rolling_score"] == 0.85
    assert turn(client, "call-7", HELLO, FAR_FUTURE)["rolling_score"] == 0.85
    turn(client, "call-7", THREAT, 12.0)
    later = turn(client, "call-7", THREAT, 18.0, pending_action="pin_reset")
    assert later["rolling_score"] == 0.85 and later["recommended_action"] == "hold_and_warn"
    assert "SCAM_CONVERSATION" in _codes(score(client, "call-7"))


def test_a_far_future_turn_does_not_wipe_a_server_clock_window(client, model):
    """The live bridge and file transcription stamp the server's clock: a far-future ts lands on 'now' and the call's
    real turns of the last minute still count."""
    model += [verdict(0.85), verdict(0.85), verdict(0.05)]
    now = time.time()
    turn(client, "call-8", THREAT, now - 10)
    assert turn(client, "call-8", THREAT, now - 4)["rolling_score"] == 0.85
    assert turn(client, "call-8", HELLO, FAR_FUTURE)["rolling_score"] == 0.85
    assert "SCAM_CONVERSATION" in _codes(score(client, "call-8"))


def test_another_account_on_the_same_session_id_gets_a_fresh_call(client, model):
    """scam_sessions is keyed by a client-made session id: another account that knows it neither wipes nor raises the
    victim's call, and never reads it."""
    model += [verdict(0.85), verdict(0.85), verdict(0.05), verdict(0.95)]
    turn(client, "call-9", THREAT, 0.0, as_user="rina")
    assert turn(client, "call-9", THREAT, 6.0, as_user="rina")["rolling_score"] == 0.85
    assert turn(client, "call-9", HELLO, FAR_FUTURE, as_user="mallory")["rolling_score"] < 0.7
    assert "SCAM_CONVERSATION" in _codes(score(client, "call-9", as_user="rina"))
    assert "SCAM_CONVERSATION" not in _codes(score(client, "call-9", as_user="mallory"))
    assert turn(client, "call-9", THREAT, 12.0, as_user="mallory")["rolling_score"] == 0.95  # her own call, not rina's
    assert scam.session_score("call-9", "rina") == 0.85


def test_a_clamped_caller_turn_still_counts_once(client, model):
    """The clamped turn keeps its own ts as its identity: a retry, or the victim's reply after it, adds no second point."""
    model += [verdict(0.85), verdict(0.85), verdict(0.85)]
    said = [("caller", THREAT, FAR_FUTURE)]
    assert turns(client, "call-c", *said)["rolling_score"] == 0.69
    assert turns(client, "call-c", *said)["rolling_score"] == 0.69
    said.append(("user", REPLY, FAR_FUTURE + 6))
    assert turns(client, "call-c", *said, pending_action="pin_reset")["recommended_action"] == "none"


# --- transactional gating: what /v1/scam/turn recommends is what /v1/risk/score does ---------------------------------

@pytest.mark.parametrize("pending", typing.get_args(TxnType))
def test_a_scam_call_holds_every_transactional_trigger_the_classifier_warns_of(client, model, pending):
    """Spec US-2: a scam score at or above 0.70 with a pending pin_reset, new_payee or send_money holds (SCAM_CONVERSATION)."""
    model += [verdict(0.85), verdict(0.85)]
    turn(client, f"call-{pending}", THREAT, 0.0)
    told = turn(client, f"call-{pending}", THREAT, 6.0, pending_action=pending)
    assert told["rolling_score"] == 0.85 and told["recommended_action"] == "hold_and_warn"
    out = score(client, f"call-{pending}", txn_type=pending)
    assert out["decision"] == "hold" and "SCAM_CONVERSATION" in _codes(out)


@pytest.mark.parametrize("pending", [None, "cash_out", "balance_check"])
def test_without_an_action_the_score_can_hold_the_classifier_only_warns(client, model, pending):
    """The conversation alone never freezes; nor does an action /v1/risk/score cannot be asked about."""
    model += [verdict(0.95)]
    assert turn(client, "call-w", THREAT, 0.0, pending_action=pending)["recommended_action"] == "warn"
