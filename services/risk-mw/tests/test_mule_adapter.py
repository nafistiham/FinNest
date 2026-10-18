"""Mule scorer adapter: the risk-mw scores receiving accounts with the real mule model (spec FR-2).

The payee is scored at the server's scenario clock, never at the end of the world, and twice: on the
evidence so far and with the transfer being screened landed. DEST_MULE_RISK fires on the second.
"""

from __future__ import annotations

import json

import pytest
from bhorosha_synth import schema as s

from app import clock, mule
from app.routers import risk as risk_router
from app.settings import get_settings

DEMO_PAYEE = "acct_01070"
DEMO_TRANSFER = {"type": "send_money", "amount_bdt": 7900, "to_account": DEMO_PAYEE, "is_new_payee": True}
BEFORE_DEMO_TRANSFER = 0.0002  # score_at strictly before Rina's transfer lands
WITH_DEMO_TRANSFER = 0.9082  # score_at one second after it
LEAD_BN = "এই নম্বরে টাকা পাঠালে ঝুঁকি বাড়ে কারণ"


def _l1_mule(client) -> str:
    return client.get("/v1/mule/demo-ring").json()["mule_L1"][0]


def _mule_reason(out: dict) -> dict | None:
    return next((r for r in out["reasons"] if r["code"] == "DEST_MULE_RISK"), None)


def _rina_pays_the_demo_payee(client, score_body) -> dict:
    resp = client.post("/v1/risk/score", json={**score_body, "user_id": s.RINA_ACCT, "txn": DEMO_TRANSFER})
    assert resp.status_code == 200, resp.text
    return resp.json()


@pytest.fixture
def scenario_at(monkeypatch):
    """Move the server's scenario clock for one test (settings are cached, so the cache is cleared both ways)."""

    def move(ts: str) -> None:
        monkeypatch.setenv("RISK_MW_SCENARIO_NOW", ts)
        get_settings.cache_clear()

    yield move
    get_settings.cache_clear()  # monkeypatch restores the variable after this; nothing reads settings in between


def test_the_demo_payee_is_the_ring_mule_l1(client):
    assert _l1_mule(client) == DEMO_PAYEE


def test_the_demo_payee_scores_low_strictly_before_the_demo_transfer():
    assert mule.model().screen_transfer(DEMO_PAYEE, clock.DEMO_SCENARIO_NOW)["before"]["probability"] == BEFORE_DEMO_TRANSFER
    assert mule.inbound_mule_score(DEMO_PAYEE, clock.DEMO_SCENARIO_NOW) == BEFORE_DEMO_TRANSFER  # kept: probe scripts patch it


@pytest.mark.parametrize(("user_id", "account"), [
    (s.RINA_ACCT, s.RINA_ACCT), ("rina", s.RINA_ACCT), ("rafiq", s.RAFIQ_ACCT), ("rahima", s.RAHIMA_ACCT),
    ("sumon", s.BENIGN_SIM_SWAP_ACCT), ("nobody", None), ("", None),
])
def test_the_payer_is_an_account_or_a_persona_uid(user_id, account):
    assert mule.resolve_payer_account(user_id) == account


def test_a_persona_uid_pays_from_its_account(client, score_body):
    by_uid = client.post("/v1/risk/score", json={**score_body, "user_id": "rina", "txn": DEMO_TRANSFER}).json()
    by_account = _rina_pays_the_demo_payee(client, score_body)
    keys = ("decision", "risk_score", "payee_score_before", "payee_score_with_this_transfer", "payee_moved_feature")
    assert {k: by_uid[k] for k in keys} == {k: by_account[k] for k in keys}
    assert by_uid["payee_score_with_this_transfer"] == WITH_DEMO_TRANSFER


def test_with_auth_on_the_payer_is_the_signed_in_uid(client, score_body, auth_on):
    resp = client.post("/v1/risk/score", json={**score_body, "user_id": "rina", "txn": DEMO_TRANSFER}, headers={"Authorization": "Bearer rina"})
    assert resp.status_code == 200, resp.text
    out = resp.json()
    assert out["identity_source"] == "verified"
    assert out["payee_score_with_this_transfer"] == WITH_DEMO_TRANSFER and out["decision"] == "hold"


def test_the_payer_comes_from_the_bound_identity_not_the_raw_body(client, score_body, monkeypatch):
    """The body names nobody we know; the bound identity is Rina's, and the transfer is screened from her account."""
    from app.identity import BoundIdentity

    monkeypatch.setattr(risk_router, "bind_identity", lambda route, claimed, uid, settings: BoundIdentity("rina", uid, "demo"))
    out = client.post("/v1/risk/score", json={**score_body, "user_id": "nobody", "txn": DEMO_TRANSFER}).json()
    assert out["payee_score_with_this_transfer"] == WITH_DEMO_TRANSFER


def test_persona_accounts_come_from_the_persona_table(monkeypatch, tmp_path):
    """One source for uid -> account (config/personas.json): a persona added there pays from its account."""
    table = {"personas": [{"uid": "tania", "acct_id": s.RAFIQ_ACCT, "p95_send_bdt": 1000}]}
    path = tmp_path / "personas.json"
    path.write_text(json.dumps(table), encoding="utf-8")
    monkeypatch.setenv("RISK_MW_PERSONAS_PATH", str(path))
    get_settings.cache_clear()
    try:
        assert mule.resolve_payer_account("tania") == s.RAFIQ_ACCT
        assert mule.resolve_payer_account("rina") is None  # not in this table, and not an account id
    finally:
        monkeypatch.delenv("RISK_MW_PERSONAS_PATH")
        get_settings.cache_clear()


def test_an_unknown_payer_gets_the_payee_score_before_only(client, score_body):
    out = client.post("/v1/risk/score", json={**score_body, "user_id": "nobody", "txn": DEMO_TRANSFER}).json()
    assert out["payee_score_before"] == BEFORE_DEMO_TRANSFER
    assert out["payee_score_with_this_transfer"] is None  # not screened: there is no paying account to send from
    assert _mule_reason(out) is None


def test_the_demo_transfer_is_held_on_the_score_with_the_transfer(client, score_body):
    out = _rina_pays_the_demo_payee(client, score_body)
    assert out["payee_score_before"] == BEFORE_DEMO_TRANSFER
    assert out["payee_score_with_this_transfer"] == WITH_DEMO_TRANSFER > get_settings().mule_hold_threshold
    assert out["payee_score_as_of"] == clock.DEMO_SCENARIO_NOW
    assert out["payee_moved_feature"] == "hops_to_recent_sim_swap"
    assert out["decision"] == "hold"
    reason = _mule_reason(out)
    assert reason["weight"] == round(WITH_DEMO_TRANSFER, 3)
    assert reason["text_bn"].startswith(LEAD_BN) and "সিম" in reason["text_bn"]
    assert "SIM" in reason["text_en"]


def test_a_small_transfer_to_the_same_payee_is_not_held_by_the_mule_rule(client, score_body):
    body = {**score_body, "user_id": s.RINA_ACCT, "txn": {**DEMO_TRANSFER, "amount_bdt": 500}}
    out = client.post("/v1/risk/score", json=body).json()
    assert out["payee_score_before"] == BEFORE_DEMO_TRANSFER
    assert out["payee_score_with_this_transfer"] < get_settings().mule_hold_threshold
    assert _mule_reason(out) is None


def test_adding_a_payee_moves_no_money_and_scores_the_evidence_so_far(client, score_body):
    body = {**score_body, "user_id": s.RINA_ACCT, "txn": {"type": "new_payee", "to_account": DEMO_PAYEE, "is_new_payee": True}}
    out = client.post("/v1/risk/score", json=body).json()
    assert out["payee_score_before"] == out["payee_score_with_this_transfer"] == BEFORE_DEMO_TRANSFER
    assert _mule_reason(out) is None


def test_an_unknown_payee_carries_no_payee_scores(client, score_body):
    out = client.post("/v1/risk/score", json=score_body).json()
    assert out["payee_score_before"] is None and out["payee_score_with_this_transfer"] is None


@pytest.mark.parametrize("where", ["body", "txn"])
def test_the_request_body_cannot_set_the_time(client, score_body, where):
    late = "2026-11-11T00:00:00"
    body = {**score_body, "as_of": late} if where == "body" else {**score_body, "txn": {**score_body["txn"], "as_of": late}}
    assert client.post("/v1/risk/score", json=body).status_code == 422


def test_the_mule_route_answers_at_the_scenario_clock_whatever_time_is_asked_for(client):
    body = client.get(f"/v1/mule/score/{DEMO_PAYEE}", params={"as_of": "2026-11-11T00:00:00"}).json()
    assert body["as_of"] == clock.DEMO_SCENARIO_NOW
    assert body["probability"] == BEFORE_DEMO_TRANSFER


def test_a_judge_at_1412_sees_the_low_number_and_why_the_hold_still_fires(client, score_body, scenario_at):
    scenario_at("2026-11-10T14:12:00")
    console = client.get(f"/v1/mule/score/{DEMO_PAYEE}").json()
    assert (console["as_of"], console["probability"]) == ("2026-11-10T14:12:00", BEFORE_DEMO_TRANSFER)
    out = _rina_pays_the_demo_payee(client, score_body)
    assert out["payee_score_as_of"] == "2026-11-10T14:12:00"
    assert out["payee_score_before"] == BEFORE_DEMO_TRANSFER
    assert out["payee_score_with_this_transfer"] > get_settings().mule_hold_threshold
    assert out["decision"] == "hold" and _mule_reason(out)["text_bn"].startswith(LEAD_BN)


def test_mule_score_route_returns_probability_and_reasons(client):
    acct = _l1_mule(client)
    resp = client.get(f"/v1/mule/score/{acct}")
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["known"] is True
    assert 0 <= body["probability"] <= 1
    assert len(body["reasons"]) == 10
    assert body["model_version"].startswith("mule-lgbm")


def test_unknown_account_scores_zero(client):
    body = client.get("/v1/mule/score/acct_nobody").json()
    assert body["known"] is False and body["probability"] == 0.0


def test_transfer_to_rafiq_is_not_flagged_by_the_model(client, score_body):
    body = {**score_body, "txn": {"type": "send_money", "amount_bdt": 500, "to_account": s.RAFIQ_ACCT, "is_new_payee": False}}
    out = client.post("/v1/risk/score", json=body).json()
    assert "DEST_MULE_RISK" not in {r["code"] for r in out["reasons"]}


def test_demo_flag_still_overrides_when_model_is_quiet(client, score_body):
    body = {**score_body, "txn": {"type": "send_money", "amount_bdt": 500, "to_account": s.RAFIQ_ACCT}, "demo_flags": {"inbound_mule_score": 0.95}}
    out = client.post("/v1/risk/score", json=body).json()
    reason = _mule_reason(out)
    assert reason is not None and reason["text_bn"].startswith(LEAD_BN)
    assert "SIM" not in reason["text_en"]  # the panel's number establishes a score, nothing about anyone's SIM
