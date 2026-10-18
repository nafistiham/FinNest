"""P0 and 7 over HTTP: GET /v1/apa/warning/{session_id}, GET /v1/apa/clips/{clip_id}, the cold path
POST /v1/apa/warning/stream, the hold's ScoreResponse.warning and the C0 pair at call start from /v1/risk/signals.
The composer and the voice are the fakes from test_prerender: no model is called."""

import json

import pytest
import time

from test_actions_security import as_, auth_on  # noqa: F401 - fixture
from test_prerender import AUTH, CRED, FOUR, A, CallState, R, T, X, fakes, lines  # noqa: F401 - fixture

from app import prerender, scam, state
from app.ledger import Ledger
from app.warnings.planner import key as warning_key
from app.settings import Settings


@pytest.fixture(autouse=True)
def prerender_audio_on(monkeypatch):
    """These routes test the per-line clips the pre-render makes when RISK_MW_PRERENDER_AUDIO is on (off by default: the
    whole warning is spoken once when it is given, tests/test_apa_voice_at_warning.py)."""
    from app.settings import get_settings

    monkeypatch.setenv("RISK_MW_PRERENDER_AUDIO", "true")
    get_settings.cache_clear()
    yield
    get_settings.cache_clear()

HOLD = {"user_id": "rina", "session_id": "call-20", "txn": {"type": "send_money", "amount_bdt": 500, "to_account": "acct_x"},
        "demo_flags": {"call_active": True, "scam_score": 0.9}}


def _ndjson(resp):
    return [json.loads(line) for line in resp.text.splitlines() if line.strip()]


def _call(session_id, ledger, band="likely", uid="demo"):
    """The detector's scam_sessions document for this call, as the interfaces file describes it."""
    key = scam.session_keys(session_id, uid)[0]
    state.store().set(*key, {"uid": uid, "ledger": ledger.to_doc(), "band": band, "risk": 0.8, "rolling": 0.8, "turns": [],
                             "updated_at": time.time()})


def _prearm(session_id, ledger=AUTH, uid="demo", band="likely", pending="send_money"):
    return prerender.maybe_prearm(session_id, uid, CallState(ledger, 0.8, band), pending, Settings(prerender_audio=True), now=time.time())


def _stream(client, session_id="call-10", **body):
    resp = client.post("/v1/apa/warning/stream", json={"session_id": session_id, "pending_action": "send_money", **body})
    assert resp.status_code == 200, resp.text
    assert resp.headers["content-type"].startswith("application/x-ndjson")
    return _ndjson(resp)


def test_the_routes_are_published(client):
    paths = client.get("/openapi.json").json()["paths"]
    assert {"/v1/apa/warning/{session_id}", "/v1/apa/clips/{clip_id}", "/v1/apa/warning/stream"} <= set(paths)


# --- the prepared warning and its clips ----------------------------------------------------------------------------


def test_no_warning_yet_is_204(client, fakes):
    assert client.get("/v1/apa/warning/call-9").status_code == 204


def test_the_latest_warning_and_its_clips(client, fakes):
    got = _prearm("call-9")
    body = client.get("/v1/apa/warning/call-9").json()
    assert body["ledger_hash"] == got.ledger_hash and body["stage"] == "C1" and body["warning_id"] == got.warning_id
    assert [(l["role"], l["clip_id"]) for l in body["lines"]] == [(l.role, l.clip_id) for l in got.lines]
    clip = client.get(f"/v1/apa/clips/{got.lines[0].clip_id}")
    assert clip.status_code == 200 and clip.headers["content-type"] == "audio/ogg" and clip.content[:4] == b"OggS"
    assert "private" in clip.headers["cache-control"]
    assert client.get("/v1/apa/clips/no-such-clip-id-here").status_code == 404


def test_another_account_reads_neither_the_warning_nor_its_clips(client, fakes, auth_on):
    got = _prearm("call-9", uid="rina")
    assert client.get("/v1/apa/warning/call-9", headers=as_("rina")).status_code == 200
    assert client.get(f"/v1/apa/clips/{got.lines[0].clip_id}", headers=as_("rina")).status_code == 200
    assert client.get("/v1/apa/warning/call-9", headers=as_("mallory")).status_code == 204
    assert client.get(f"/v1/apa/clips/{got.lines[0].clip_id}", headers=as_("mallory")).status_code == 404
    assert client.get("/v1/apa/warning/call-9").status_code == 401


# --- C2, the cold path ---------------------------------------------------------------------------------------------


def test_the_cold_stream_sends_each_line_with_its_clip_then_done(client, fakes):
    records = _stream(client)
    *sent, done = records
    assert [r["role"] for r in sent] == ["A", "T", "R", "X"] and all(r["clip_id"] and not r["speak_on_device"] for r in sent)
    kept = prerender.latest("call-10", "demo")
    assert done == {"done": True, "earcon": True, "vibrate": True, "lines": 4, "warning_id": kept.warning_id,
                    "ledger_hash": warning_key(Ledger(), "send_money", scam.certainty_band(0.0))}
    assert kept.stage == "C2" and client.get(f"/v1/apa/clips/{sent[0]['clip_id']}").status_code == 200


def test_a_rate_limited_cold_line_is_spoken_on_the_phone(client, fakes):
    _, voice = fakes
    voice.limit_on = {A}
    *sent, done = _stream(client)
    assert all(r["clip_id"] is None and r["speak_on_device"] for r in sent) and done["lines"] == 4
    assert voice.spoken == [A]


def test_no_validated_text_is_the_silent_floor(client, fakes):
    composer, _ = fakes
    composer.queue = [()]
    assert _stream(client) == [{"done": True, "earcon": True, "vibrate": True, "lines": 0, "warning_id": None,
                                "ledger_hash": warning_key(Ledger(), "send_money", scam.certainty_band(0.0))}]
    assert prerender.latest("call-10", "demo") is None


def test_a_failing_composer_still_ends_with_the_floor(client, fakes):
    composer, _ = fakes
    composer.fail = RuntimeError("boom")
    assert _stream(client)[-1]["done"] is True


def test_the_cold_stream_reads_the_calls_ledger(client, fakes):
    composer, _ = fakes
    _call("call-11", CRED)
    _stream(client, "call-11")
    assert (composer.plans[-1]["ledger"], composer.plans[-1]["band"]) == (CRED, "likely")


def test_the_cold_stream_skips_what_the_phone_already_played(client, fakes):
    _, voice = fakes
    _call("call-12", CRED)
    stale = _prearm("call-12", AUTH)
    *sent, _ = _stream(client, "call-12", skip_roles=["A"])
    assert [r["role"] for r in sent] == ["T", "R", "X"] and A not in voice.spoken[len(FOUR):]
    kept = prerender.latest("call-12", "demo")
    assert kept.lines[0] == stale.lines[0] and kept.ledger_hash == warning_key(CRED, "send_money", "likely")


def test_a_fresh_prerender_is_streamed_without_writing_again(client, fakes):
    composer, voice = fakes
    _call("call-13", AUTH)
    got = _prearm("call-13", AUTH)
    *sent, done = _stream(client, "call-13")
    assert [r["clip_id"] for r in sent] == [l.clip_id for l in got.lines] and done["warning_id"] == got.warning_id
    assert len(composer.generated) == 1 and len(voice.spoken) == 4


# --- the hold --------------------------------------------------------------------------------------------------------


def test_the_hold_carries_the_fresh_prerender(client, fakes):
    _call("call-20", CRED)
    got = _prearm("call-20", CRED)
    out = client.post("/v1/risk/score", json=HOLD).json()
    assert out["decision"] == "hold"
    warning = out["warning"]
    assert (warning["status"], warning["earcon"], warning["vibrate"], warning["stream_rest"]) == ("fresh", True, True, False)
    assert [l["clip_id"] for l in warning["warning"]["lines"]] == [l.clip_id for l in got.lines]


def test_a_hold_after_new_evidence_offers_the_stale_attention_line(client, fakes):
    _call("call-20", CRED)
    _prearm("call-20", AUTH)
    warning = client.post("/v1/risk/score", json=HOLD).json()["warning"]
    assert warning["status"] == "stale" and [l["role"] for l in warning["warning"]["lines"]] == ["A"] and warning["stream_rest"]


def test_a_warning_armed_before_the_money_screen_is_fresh_at_the_send_hold(client, fakes):
    """During a call the phone sends turns with no pending action; the hold is a send (review finding, P). A code ask gets the
    same warning either way (don't say the code), so the prepared warning is fresh at the hold."""
    _call("call-20", CRED)
    got = _prearm("call-20", CRED, pending=None)
    warning = client.post("/v1/risk/score", json=HOLD).json()["warning"]
    assert warning["status"] == "fresh" and warning["warning"]["warning_id"] == got.warning_id


def test_a_send_hold_that_changes_apas_instruction_is_stale(client, fakes):
    """With no ask yet, the warning said 'hang up'; a held send makes it 'don't send the money': not the same warning."""
    _call("call-20", AUTH)
    _prearm("call-20", AUTH, pending=None)
    warning = client.post("/v1/risk/score", json=HOLD).json()["warning"]
    assert warning["status"] == "stale"


def test_a_hold_with_nothing_prepared_says_go_cold(client):
    warning = client.post("/v1/risk/score", json=HOLD).json()["warning"]
    assert warning == {"status": "none", "warning": None, "earcon": True, "vibrate": True, "speak_on_device": False, "stream_rest": True}


def test_an_allowed_payment_carries_no_warning(client, score_body):
    out = client.post("/v1/risk/score", json=score_body).json()
    assert out["decision"] == "allow" and out["warning"] is None


# --- C0 at call start --------------------------------------------------------------------------------------------------


def test_a_call_from_an_unknown_caller_prepares_the_pair(client, fakes):
    assert client.post("/v1/risk/signals", json={"session_id": "call-30", "signals": {"call_state": "OFFHOOK"}}).status_code == 200
    got = prerender.latest("call-30", "demo")
    assert got.stage == "C0" and [l.role for l in got.lines] == ["A", "X"]


def test_no_pair_for_a_contact_or_an_idle_phone(client, fakes):
    composer, _ = fakes
    client.post("/v1/risk/signals", json={"session_id": "call-31", "signals": {"call_state": "OFFHOOK", "caller_in_contacts": True}})
    client.post("/v1/risk/signals", json={"session_id": "call-32", "signals": {"call_state": "IDLE"}})
    assert composer.generated == [] and prerender.latest("call-31", "demo") is None and prerender.latest("call-32", "demo") is None
