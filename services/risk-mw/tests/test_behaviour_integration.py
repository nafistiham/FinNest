"""Behaviour (app.ato) inside the score path: the session store, the call signal and Apa.

Reuses the artefacts test_risk_route_behaviour.py trains on generated sessions for one owner.
"""

from __future__ import annotations

from test_risk_route_behaviour import _codes, _score, _signal, trained, wired  # noqa: F401 - fixtures

from datetime import UTC, datetime

from app import sessions, state
from app.settings import get_settings


def test_the_whole_behaviour_vector_is_kept_with_the_session(client, trained, wired):
    _signal(client, "s-full", trained["stranger_row"])
    kept = sessions.recall("rina", "s-full", datetime.now(UTC), get_settings())
    assert kept is not None and kept.features == tuple(trained["stranger_row"])


def test_another_callers_behaviour_on_the_same_session_id_never_reaches_her_score(client, score_body, trained, wired):
    """Sessions are keyed by (caller uid, session id), so a stranger's post under her session id is his own session."""
    client.post("/v1/risk/signals", json={"session_id": score_body["session_id"], "behaviour": {"features": list(trained["stranger_row"])}},
                headers={"X-Demo-User": "mallory"})
    assert not any(code.startswith("ATO_BEHAVIOUR_MISMATCH") for code in _codes(_score(client, score_body)))
    _signal(client, score_body["session_id"], trained["stranger_row"])
    assert any(code.startswith("ATO_BEHAVIOUR_MISMATCH") for code in _codes(_score(client, score_body)))


def test_an_off_hook_call_from_the_phone_holds_a_coached_session(client, score_body, trained, wired):
    """The live call can come from the phone's own call state, not only from the demo panel."""
    client.post("/v1/risk/signals", json={"session_id": score_body["session_id"], "signals": {"call_state": "OFFHOOK"},
                                          "behaviour": {"features": list(trained["coached_row"])}}, headers={"X-Demo-User": "rina"})
    result = _score(client, {**score_body, "demo_flags": {"caller_in_contacts": True}})
    assert "COACHING_SUSPECTED" in _codes(result) and result["decision"] == "hold"


def test_a_behaviour_hold_is_recorded_as_an_intervention(client, score_body, trained, wired):
    _signal(client, score_body["session_id"], trained["coached_row"])
    result = _score(client, {**score_body, "demo_flags": {"call_active": True, "caller_in_contacts": True}})
    iid = result["actions"][0]["params"]["intervention_id"]
    assert result["decision"] == "hold" and state.store().get("interventions", iid)["status"] == "held"
