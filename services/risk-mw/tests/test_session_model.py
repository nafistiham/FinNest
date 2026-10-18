"""Session risk model (spec: a small model over about 20 features, fused as max(rules, model))."""

import random

from bhorosha_ato import synth

from app import session_model
from app.contracts import ScoreRequest

QUIET = ScoreRequest(user_id="rina", session_id="q", txn={"type": "send_money", "amount_bdt": 500, "is_new_payee": False})
RISKY = ScoreRequest(user_id="rina", session_id="r", txn={"type": "send_money", "amount_bdt": 15000, "is_new_payee": True},
                     demo_flags={"call_active": True, "screen_share": True, "inbound_mule_score": 0.6, "scam_score": 0.6})
RISKY_SIGNALS = {"call_state": "OFFHOOK", "accessibility_services": ["com.remote.helper"], "obscured_touch": True, "subscription_changed_hours": 30.0}


def test_twenty_one_named_features():
    names = session_model.FEATURES
    assert len(names) == 21 and len(set(names)) == 21 and "device_age_days" in names  # spec section 3: device age joined the 20
    assert len(session_model.features(QUIET, {}, 5000.0)) == 21


def test_the_shipped_model_loads_and_ranks_risky_above_quiet():
    quiet = session_model.predict(QUIET, {}, 5000.0)
    risky = session_model.predict(RISKY, RISKY_SIGNALS, 5000.0)
    assert 0.0 <= quiet < 0.2 < 0.6 < risky <= 1.0
    assert session_model.model_version().startswith("session-hgb")


def test_signals_are_stored_per_session(client):
    body = {"session_id": "call-5", "signals": {"call_state": "OFFHOOK", "screen_capture": True}}
    assert client.post("/v1/risk/signals", json=body, headers={"X-Demo-User": "rina"}).json()["stored"] is True
    from datetime import UTC, datetime

    from app import sessions
    from app.settings import get_settings
    kept = sessions.recall("rina", "call-5", datetime.now(UTC), get_settings())
    assert kept.signals.signals.call_state == "OFFHOOK" and kept.signals.signals.screen_capture is True


def test_an_off_hook_call_from_the_signals_drives_the_call_rule(client, score_body):
    client.post("/v1/risk/signals", json={"session_id": "s1", "signals": {"call_state": "OFFHOOK"}})
    out = client.post("/v1/risk/score", json={**score_body, "txn": {"type": "pin_reset"}}).json()
    assert out["decision"] == "hold" and "CALL_ACTIVE_NON_CONTACT" in {r["code"] for r in out["reasons"]}


def test_the_model_alone_can_only_step_up(client, score_body, monkeypatch):
    monkeypatch.setattr(session_model, "predict", lambda *a, **k: 0.9)
    out = client.post("/v1/risk/score", json=score_body).json()
    assert out["decision"] == "step_up" and out["risk_score"] == 0.9 and "MODEL_RISK" in {r["code"] for r in out["reasons"]}
    assert out["model_version"].startswith("rules+session-hgb")


def test_a_quiet_payment_stays_allowed_with_the_real_model(client, score_body):
    out = client.post("/v1/risk/score", json=score_body).json()
    assert out["decision"] == "allow" and out["risk_score"] < 0.3


def _wire_row() -> list[float]:
    """One session in the behaviour wire layout (bhorosha_ato.schema.FEATURES): swipe ms and px, PIN timings, IMU."""
    rng = random.Random(3)
    return list(synth.genuine_rows(synth.user_profile(rng), 1, rng)[0])


def test_the_session_model_does_not_read_the_behaviour_vector():
    """Behaviour belongs to the behaviour model (app.ato). Its vector starts with swipe duration in ms and the
    swipe's x position in px, which this model must not take for hesitation and seconds on screen."""
    assert session_model.features(QUIET, {"behaviour": _wire_row()}, 5000.0) == session_model.features(QUIET, {}, 5000.0)


def test_signalling_behaviour_leaves_the_session_score_unchanged(client, score_body):
    without = client.post("/v1/risk/score", json={**score_body, "session_id": "no-behaviour"}).json()
    client.post("/v1/risk/signals", json={"session_id": "with-behaviour", "behaviour": {"features": _wire_row()}})
    with_vector = client.post("/v1/risk/score", json={**score_body, "session_id": "with-behaviour"}).json()
    assert with_vector["risk_score"] == without["risk_score"] and with_vector["band"] == without["band"]
