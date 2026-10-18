"""GET /v1/appsafety/latest/{uid} for Case Zero (2026-10-18).

Case Zero's device_safety tool could not see the phone's App Safety report, for two reasons found live on 2026-10-18:
- the route answered only from this instance's own checks, so a BLOCK the phone sent with its score read as
  `known: false`;
- Case Zero asks by account id ("acct_rina") while the app checks and scores under the persona uid ("rina"), so even a
  real check was missed.

`?include_phone=true` (Case Zero's call; the app's own fallback never passes it, so the app never reads its own report
back) falls back to the phone's last valid report, labelled `source: "phone"`. Either id finds the persona. Every answer
carries the closed-set phone facts behind the verdict.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta

from app import appsafety_engine
from app.contracts import AppSafetyContext, AppSafetyResponse, Finding
from app.settings import Settings

CASE_ZERO = {"X-Demo-User": "case-zero"}


def _latest(client, uid, include_phone=False):
    resp = client.get(f"/v1/appsafety/latest/{uid}", params={"include_phone": "true"} if include_phone else None, headers=CASE_ZERO)
    assert resp.status_code == 200, resp.text
    return resp.json()


def _phone(uid, verdict="BLOCK", signal="KNOWN_RAT", severity="high", **extra):
    appsafety_engine.remember_carried(uid, AppSafetyContext.model_validate({
        "verdict": verdict, "risk_score": 0.9, "findings": [{"package": "com.x", "signal": signal, "severity": severity}], **extra}))


def _server(uid, verdict="CAUTION", signal="SMS_ROLE_TAKEOVER", severity="high"):
    finding = Finding(package="com.y", signal=signal, severity=severity, evidence="e", explanation_bn="ব্যাখ্যা", explanation_en="why")
    response = AppSafetyResponse(verdict=verdict, risk_score=0.6, findings=(finding,), recommended_action="UNINSTALL",
                                 apps_to_uninstall=("com.y",), user_message_bn="", user_message_en="", simulated_verdict=False)
    appsafety_engine.remember_verdict(uid, verdict, 0.6, app_count=40, flagged=frozenset({"com.y"}), attestation="none",
                                      settings=Settings(), response=response)


def test_the_phones_report_is_shown_only_when_asked(client):
    _phone("rina")
    assert _latest(client, "rina")["known"] is False   # the app's own fallback: unchanged, never its own report back
    out = _latest(client, "rina", include_phone=True)
    assert (out["known"], out["verdict"], out["source"], out["facts"]) == (True, "BLOCK", "phone", ["REMOTE_CONTROL"])
    assert out["flagged_packages"] == [] and out["risk_score"] == 0.9


def test_an_account_id_finds_the_persona_and_back(client):
    _server("rina")
    out = _latest(client, "acct_rina")
    assert (out["uid"], out["known"], out["verdict"], out["source"]) == ("acct_rina", True, "CAUTION", "server")
    assert out["facts"] == ["READS_MESSAGES"] and out["flagged_packages"] == ["com.y"]
    appsafety_engine.forget_verdicts()
    _server("acct_rina", "BLOCK")
    assert _latest(client, "rina")["verdict"] == "BLOCK"


def test_an_unknown_account_is_still_unknown(client):
    _phone("rina")
    out = _latest(client, "acct_01070", include_phone=True)   # a mule account: no persona, no phone
    assert out["known"] is False and out["source"] == "server" and out["facts"] == []


def test_the_stronger_report_is_the_one_shown(client):
    _server("rina", "CAUTION")
    _phone("rina", "BLOCK")
    assert (_latest(client, "acct_rina", include_phone=True)["source"], _latest(client, "acct_rina", include_phone=True)["verdict"]) == ("phone", "BLOCK")
    appsafety_engine.forget_carried()
    _server("rina", "BLOCK")
    _phone("rina", "BLOCK", signal="LOAN_APP_DATA_HARVEST")
    out = _latest(client, "acct_rina", include_phone=True)
    assert (out["source"], out["facts"]) == ("server", ["READS_MESSAGES"])   # a tie goes to the server's own check


def test_an_expired_phone_report_is_not_shown(client):
    _phone("rina", valid_until=(datetime.now(UTC) - timedelta(minutes=1)).isoformat())
    assert _latest(client, "acct_rina", include_phone=True)["known"] is False


def test_a_score_from_the_app_reaches_case_zero_by_account_id(client, score_body):
    body = {**score_body, "app_safety": {"verdict": "BLOCK", "risk_score": 0.95,
                                         "findings": [{"package": "com.x", "signal": "SMS_ROLE_TAKEOVER", "severity": "critical"}]}}
    assert client.post("/v1/risk/score", json=body, headers={"X-Demo-User": "rina"}).status_code == 200
    out = _latest(client, "acct_rina", include_phone=True)
    assert (out["known"], out["verdict"], out["source"], out["facts"]) == (True, "BLOCK", "phone", ["READS_MESSAGES"])
