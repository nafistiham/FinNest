"""Scoring identity is the authenticated uid; session state is keyed by (uid, session_id) with a TTL.

The earlier bug: /v1/risk/score scored whatever body.user_id said and read session features by session id alone, so
another signed-in user could overwrite Rina's features or score as another customer.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from unittest.mock import patch

import pytest

from app import sessions
from app.contracts import SignalsRequest
from app.routers import risk

SESSION = "review-session"
PIN_RESET = {"type": "pin_reset"}


def _bearer(uid: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {uid}"}


def _signal(client, headers: dict[str, str], features: list[float], session_id: str = SESSION) -> None:
    resp = client.post("/v1/risk/signals", json={"session_id": session_id, "behaviour": {"features": features}}, headers=headers)
    assert resp.status_code == 200, resp.text


def _score(client, headers: dict[str, str], user_id: str, session_id: str = SESSION):
    return client.post("/v1/risk/score", json={"user_id": user_id, "session_id": session_id, "txn": PIN_RESET}, headers=headers)


def _recorded_audit(monkeypatch) -> list[tuple[str, str, dict, dict]]:
    rows: list[tuple[str, str, dict, dict]] = []
    monkeypatch.setattr("app.audit.record", lambda kind, uid, inputs, outputs, ms: rows.append((kind, uid, inputs, outputs)) or "id")
    return rows


# --- auth on: the body cannot name someone else ---------------------------------------------------------------------


def test_mismatched_user_id_is_403_with_auth_on(client, auth_on, monkeypatch):
    rows = _recorded_audit(monkeypatch)
    resp = _score(client, _bearer("rina"), "another-customer")
    assert resp.status_code == 403
    mismatch = [r for r in rows if r[0] == "identity_mismatch"]
    assert mismatch and mismatch[0][1] == "rina"
    assert mismatch[0][2]["claimed_user_id"] == "another-customer"


def test_matching_user_id_is_scored_and_marked_verified(client, auth_on):
    resp = _score(client, _bearer("rina"), "rina")
    assert resp.status_code == 200, resp.text
    assert resp.json()["identity_source"] == "verified"


def test_a_cross_user_session_post_does_not_change_rinas_features(client, auth_on):
    _signal(client, _bearer("rina"), [1.0])
    _signal(client, _bearer("unrelated-user"), [9.0])
    with patch("app.ato.behaviour_hits", return_value=()) as model:
        assert _score(client, _bearer("rina"), "rina").status_code == 200
    assert model.call_args.args == ("rina", (1.0,))


def test_the_other_users_post_is_a_new_session_for_him(client, auth_on):
    _signal(client, _bearer("rina"), [1.0])
    _signal(client, _bearer("unrelated-user"), [9.0])
    with patch("app.ato.behaviour_hits", return_value=()) as model:
        assert _score(client, _bearer("unrelated-user"), "unrelated-user").status_code == 200
    assert model.call_args.args == ("unrelated-user", (9.0,))


def test_intervene_refuses_a_mismatched_user_id_with_auth_on(client, auth_on):
    body = {"user_id": "another-customer", "trigger": "call_active", "txn": PIN_RESET}
    assert client.post("/v1/intervene", json=body, headers=_bearer("rina")).status_code == 403


def test_apa_turn_refuses_a_mismatched_user_id_with_auth_on(client, auth_on):
    body = {"user_id": "another-customer", "text_bn": "আমি কি টাকা পাঠাবো?"}
    assert client.post("/v1/apa/turn", json=body, headers=_bearer("rina")).status_code == 403


# --- demo mode: the persona picker keeps working, and says it is a demo ---------------------------------------------


def test_demo_mode_scores_the_apps_persona_id_and_marks_it(client, monkeypatch):
    rows = _recorded_audit(monkeypatch)
    resp = _score(client, {"X-Demo-User": "rina"}, "acct_rina")
    assert resp.status_code == 200, resp.text
    assert resp.json()["identity_source"] == "demo"
    scored = [r for r in rows if r[0] == "score"]
    assert scored and scored[0][3]["identity_source"] == "demo"


def test_demo_mode_without_a_header_still_answers(client):
    resp = _score(client, {}, "acct_rina")
    assert resp.status_code == 200, resp.text
    assert resp.json()["identity_source"] == "demo"


def test_demo_mode_sessions_are_namespaced_by_the_demo_user(client):
    _signal(client, {"X-Demo-User": "rina"}, [1.0])
    _signal(client, {"X-Demo-User": "someone-else"}, [9.0])
    with patch("app.ato.behaviour_hits", return_value=()) as model:
        assert _score(client, {"X-Demo-User": "rina"}, "acct_rina").status_code == 200
    assert model.call_args.args == ("acct_rina", (1.0,))


def test_demo_mode_intervene_is_marked(client):
    body = {"user_id": "acct_rina", "trigger": "call_active", "txn": PIN_RESET}
    resp = client.post("/v1/intervene", json=body, headers={"X-Demo-User": "rina"})
    assert resp.status_code == 200, resp.text
    assert resp.json()["identity_source"] == "demo"


# --- the store: bounded, with a TTL ---------------------------------------------------------------------------------


def test_session_features_expire_after_the_ttl(client, monkeypatch):
    start = datetime(2026, 11, 10, 14, 0, tzinfo=UTC)
    monkeypatch.setattr(risk, "_now", lambda: start)
    _signal(client, {"X-Demo-User": "rina"}, [1.0])

    monkeypatch.setattr(risk, "_now", lambda: start + timedelta(minutes=29))
    with patch("app.ato.behaviour_hits", return_value=()) as model:
        _score(client, {"X-Demo-User": "rina"}, "rina")
    assert model.called

    monkeypatch.setattr(risk, "_now", lambda: start + timedelta(minutes=31))
    with patch("app.ato.behaviour_hits", return_value=()) as model:
        _score(client, {"X-Demo-User": "rina"}, "rina")
    assert not model.called


@pytest.fixture
def store() -> sessions.SessionStore:
    return sessions.SessionStore()


def _state(session_id: str, at: datetime) -> sessions.SessionState:
    return sessions.SessionState(SignalsRequest(session_id=session_id), at)


def test_the_store_is_bounded(store):
    now = datetime.now(UTC)
    for index in range(3):
        store.put(("rina", f"s{index}"), _state(f"s{index}", now), limit=2, ttl_s=60)
    assert store.get(("rina", "s0"), now, ttl_s=60) is None
    assert store.get(("rina", "s2"), now, ttl_s=60) is not None


def test_the_store_keys_on_uid_and_session(store):
    now = datetime.now(UTC)
    store.put(("rina", "s"), _state("s", now), limit=8, ttl_s=60)
    assert store.get(("rafiq", "s"), now, ttl_s=60) is None
    assert store.get(("rina", "s"), now, ttl_s=60) is not None


def test_the_store_drops_an_expired_entry(store):
    then = datetime.now(UTC)
    store.put(("rina", "s"), _state("s", then), limit=8, ttl_s=60)
    assert store.get(("rina", "s"), then + timedelta(seconds=61), ttl_s=60) is None
    assert store.get(("rina", "s"), then, ttl_s=60) is None  # gone, not merely hidden
