"""Every route answers with a schema-valid body and the latency header (spec US-1)."""

from app import contracts as c
from app import state


def _post(client, path, body):
    resp = client.post(path, json=body)
    assert resp.status_code == 200, resp.text
    assert "X-Processing-Time-Ms" in resp.headers
    return resp.json()


def test_openapi_lists_every_route(client):
    paths = client.get("/openapi.json").json()["paths"]
    expected = {
        "/v1/risk/signals",
        "/v1/risk/score",
        "/v1/appsafety/check",
        "/v1/intervene",
        "/v1/scam/turn",
        "/v1/apa/turn",
        "/v1/actions/trusted-contact",
        "/v1/actions/trusted-contact/{request_id}/approve",
        "/v1/actions/trusted-contact/{request_id}/decline",
        "/v1/investigate",
        "/v1/investigations/{case_id}",
        "/v1/investigations/{case_id}/events",
        "/health",
        "/v1/mule/score/{acct_id}",
        "/v1/mule/demo-ring",
    }
    assert expected <= set(paths)


def test_signals(client):
    body = {"session_id": "s1", "signals": {"call_state": "OFFHOOK"}, "behaviour": {"features": [0.1, 0.2]}}
    assert c.SignalsResponse(**_post(client, "/v1/risk/signals", body)).stored is True


def test_score_is_schema_valid_and_names_its_model(client, score_body):
    out = c.ScoreResponse(**_post(client, "/v1/risk/score", score_body))
    assert out.model_version.startswith("rules+session-hgb")  # Replaced the stub model


def test_appsafety(client):
    body = {"installed_apps": [{"package": "com.example.loan", "has_accessibility_service": True}]}
    out = c.AppSafetyResponse(**_post(client, "/v1/appsafety/check", body))
    assert out.simulated_verdict is True


def test_intervene(client):
    body = {"user_id": "rina", "trigger": "call_active", "txn": {"type": "pin_reset"}}
    out = c.InterveneResponse(**_post(client, "/v1/intervene", body))
    # no fixed line; with Gemini off nothing validates, so the hold is the floor (earcon and vibration, no words)
    assert (out.script_bn, out.lines, out.audio_asset_id) == ("", (), None) and out.earcon and out.vibrate and out.actions


def test_scam_turn(client):
    body = {"session_id": "s1", "turns": [{"speaker": "caller", "text": "আপনার একাউন্ট বন্ধ হয়ে যাবে, কোডটা বলুন", "ts": 1.0}]}
    c.ScamTurnResponse(**_post(client, "/v1/scam/turn", body))


def test_apa_turn(client):
    c.ApaTurnResponse(**_post(client, "/v1/apa/turn", {"user_id": "rina", "text_bn": "আমি কি টাকা পাঠাবো?"}))


def test_trusted_contact_lifecycle(client):
    state.store().set("users", "rina", {"trusted_contact_uid": "daughter"})
    held = _post(client, "/v1/risk/score", {"user_id": "rina", "session_id": "s1", "txn": {"type": "pin_reset"}, "demo_flags": {"sim_swap": True}})
    iid = next(a["params"]["intervention_id"] for a in held["actions"] if a["type"] == "trusted_contact_check")
    created = c.TrustedContactResponse(**_post(client, "/v1/actions/trusted-contact", {"intervention_id": iid, "contact_uid": "daughter"}))
    approved = client.post(f"/v1/actions/trusted-contact/{created.request_id}/approve").json()
    assert c.TrustedContactDecision(**approved).status == "approved"
    assert client.post("/v1/actions/trusted-contact/does-not-exist/decline").status_code == 404


def test_investigate_lifecycle(client):
    created = c.InvestigateResponse(**_post(client, "/v1/investigate", {"acct_id": "acct_mule_1"}))
    report = client.get(f"/v1/investigations/{created.case_id}")
    assert report.status_code == 200
    c.CaseReport(**report.json())
    events = client.get(f"/v1/investigations/{created.case_id}/events")
    assert events.status_code == 200
    assert events.headers["content-type"].startswith("text/event-stream")
    assert "data:" in events.text


def test_validation_rejects_unknown_fields(client, score_body):
    bad = {**score_body, "surprise": 1}
    assert client.post("/v1/risk/score", json=bad).status_code == 422
