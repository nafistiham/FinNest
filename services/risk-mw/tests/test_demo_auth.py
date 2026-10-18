"""The demo control routes (FR-6) sign in like every other route. With RISK_MW_AUTH_REQUIRED=true and demo mode on,
an anonymous PUT /v1/demo/state/rina {app_safety_verdict: BLOCK} answered 200 and rina's next send scored block."""

import pytest

from app import auth, state
from app.settings import Settings, get_settings

STATE = "/v1/demo/state/rina"
SIGNED_IN = {"Authorization": "Bearer operator"}


@pytest.fixture
def auth_on(client, monkeypatch):
    """Auth required and demo mode on; a bearer token's text is its uid."""
    monkeypatch.setattr(auth, "_verify_firebase_token", lambda token: token)
    settings = {"auth_required": True, "demo_mode": True}
    client.app.dependency_overrides[get_settings] = lambda: Settings(**settings)
    yield settings
    client.app.dependency_overrides.pop(get_settings, None)


@pytest.mark.parametrize("method", ["GET", "PUT", "DELETE"])
def test_the_demo_routes_need_a_signed_in_caller_when_auth_is_on(client, auth_on, method):
    body = {"json": {"app_safety_verdict": "BLOCK"}} if method == "PUT" else {}
    assert client.request(method, STATE, **body).status_code == 401
    assert state.store().get("demo_state", "rina") == {}
    assert client.request(method, STATE, headers=SIGNED_IN, **body).status_code == 200


def test_an_anonymous_caller_cannot_turn_someone_elses_send_into_a_block(client, auth_on, score_body):
    assert client.put(STATE, json={"app_safety_verdict": "BLOCK"}).status_code == 401
    resp = client.post("/v1/risk/score", json=score_body, headers={"Authorization": "Bearer rina"})
    assert resp.status_code == 200 and resp.json()["decision"] == "allow"


def test_the_demo_routes_stay_off_outside_demo_mode_even_when_signed_in(client, auth_on):
    auth_on["demo_mode"] = False
    assert client.get(STATE).status_code == client.get(STATE, headers=SIGNED_IN).status_code == 404
    assert client.put(STATE, json={"sim_swap": True}, headers=SIGNED_IN).status_code == 404
