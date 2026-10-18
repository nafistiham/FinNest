"""Rules (FR-2): deterministic decisions before any model runs."""


def _score(client, score_body, **flags):
    body = {**score_body, "demo_flags": {**score_body["demo_flags"], **flags}}
    resp = client.post("/v1/risk/score", json=body)
    assert resp.status_code == 200, resp.text
    return resp.json()


def _codes(out):
    return {r["code"] for r in out["reasons"]}


def test_quiet_transfer_is_allowed(client, score_body):
    out = _score(client, score_body)
    assert out["decision"] == "allow"
    assert out["band"] == "low"
    assert out["actions"] == []


def test_pin_reset_during_unknown_call_is_held(client, score_body):
    body = {**score_body, "txn": {"type": "pin_reset"}}
    out = _score(client, body, call_active=True, caller_in_contacts=False)
    assert out["decision"] == "hold"
    assert "CALL_ACTIVE_NON_CONTACT" in _codes(out)
    assert any(a["type"] == "freeze_pin_reset" for a in out["actions"])
    assert any(a["type"] == "trusted_contact_check" for a in out["actions"])


def test_pin_reset_during_call_with_contact_is_not_held_by_that_rule(client, score_body):
    body = {**score_body, "txn": {"type": "pin_reset"}}
    out = _score(client, body, call_active=True, caller_in_contacts=True)
    assert "CALL_ACTIVE_NON_CONTACT" not in _codes(out)


def test_sim_swap_holds_with_two_reasons_when_combined(client, score_body):
    body = {**score_body, "txn": {"type": "pin_reset"}}
    out = _score(client, body, call_active=True, sim_swap=True)
    assert out["decision"] == "hold"
    assert {"CALL_ACTIVE_NON_CONTACT", "SIM_CHANGED_24H"} <= _codes(out)
    assert len(out["reasons"]) >= 2


def test_new_payee_above_p95_is_delayed(client, score_body):
    body = {**score_body, "txn": {"type": "send_money", "amount_bdt": 20000, "to_account": "acct_new", "is_new_payee": True}}
    out = _score(client, body)
    assert out["decision"] == "delay"
    assert "NEW_PAYEE_ABOVE_P95" in _codes(out)
    assert any(a["type"] == "delay_new_payee" for a in out["actions"])


def test_new_payee_below_p95_is_allowed(client, score_body):
    body = {**score_body, "txn": {"type": "send_money", "amount_bdt": 1000, "to_account": "acct_new", "is_new_payee": True}}
    assert _score(client, body)["decision"] == "allow"


def test_app_safety_block_blocks(client, score_body):
    out = _score(client, score_body, app_safety_verdict="BLOCK")
    assert out["decision"] == "block"
    assert "APP_SAFETY_BLOCK" in _codes(out)


def test_mule_destination_is_held(client, score_body):
    out = _score(client, score_body, inbound_mule_score=0.9)
    assert out["decision"] == "hold"
    assert "DEST_MULE_RISK" in _codes(out)


def test_block_outranks_hold(client, score_body):
    out = _score(client, score_body, app_safety_verdict="BLOCK", inbound_mule_score=0.95)
    assert out["decision"] == "block"


def test_risk_score_is_max_of_rule_weights(client, score_body):
    out = _score(client, score_body, inbound_mule_score=0.9)
    assert out["risk_score"] == max(r["weight"] for r in out["reasons"])
    assert out["band"] in {"high", "critical"}
