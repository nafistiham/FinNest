"""Scam-conversation classifier (spec US-2, FR-3): schema, guardrails, hysteresis, gating."""

import pytest

from app import scam, tactic_cards
from app.settings import Settings

CARE = "আমি বিকাশ কাস্টমার কেয়ার থেকে বলছি, আপনার একাউন্ট আজ বন্ধ হয়ে যাবে"
ASK_OTP = "আপনার ফোনে একটা কোড গেছে, কোডটা এখনই বলুন"
THREAT = "আপনার একাউন্ট আজ বন্ধ হয়ে যাবে"


def soft(conf, quote=THREAT):
    """One verified tactic and no ask: no rule fires, so the model's score and the hysteresis decide."""
    return scam.ScamExtraction(tactics=[{"tactic": "URGENCY_THREAT", "quote": quote}], verdict="SCAM", confidence=conf)


def asks_code(conf, quote=ASK_OTP):
    return scam.ScamExtraction(tactics=[{"tactic": "CREDENTIAL_REQUEST", "quote": quote}], claimed_identity="bank_mfs_staff", ask="otp",
                               scam_type="otp_pin_harvest", verdict="SCAM", confidence=conf)


@pytest.fixture
def model(monkeypatch):
    queue = []

    def fake(turns, settings, cards):
        item = queue.pop(0)
        if isinstance(item, Exception):
            raise item
        return item
    monkeypatch.setattr(scam, "_model_extraction", fake)
    return queue


def turn(client, session, text, ts, **extra):
    body = {"session_id": session, "turns": [{"speaker": "caller", "text": text, "ts": ts}], **extra}
    resp = client.post("/v1/scam/turn", json=body)
    assert resp.status_code == 200, resp.text
    return resp.json()


def test_two_turns_at_0_7_raise_the_alert(client, model):
    model += [soft(0.75), soft(0.8)]
    assert turn(client, "s1", THREAT, 1.0)["rolling_score"] < 0.7
    assert turn(client, "s1", THREAT, 9.0)["rolling_score"] >= 0.7


def test_one_turn_at_0_9_alerts_at_once(client, model):
    model += [soft(0.95)]
    assert turn(client, "s2", THREAT, 1.0)["rolling_score"] >= 0.9


def test_turns_minutes_apart_still_meet(client, model):
    """The 60 s window is gone (P0 item 1): the hysteresis runs over the call's evidence, however far apart the turns are."""
    model += [soft(0.75), soft(0.8)]
    turn(client, "s3", THREAT, 0.0)
    assert turn(client, "s3", THREAT, 190.0)["rolling_score"] >= 0.7


def test_help_line_without_a_secret_is_capped(client, model):
    model += [soft(0.95, quote=CARE), asks_code(0.95)]
    capped = turn(client, "s4", CARE, 1.0, caller_number="+880 16247")
    assert capped["confidence"] <= 0.4 and capped["rolling_score"] <= 0.4
    asked = turn(client, "s5", ASK_OTP, 1.0, caller_number="16247")
    assert asked["confidence"] >= 0.9 and asked["rolling_score"] >= 0.9  # asking for a secret is never what a real help line does


def test_quote_must_be_the_callers_words(client, model):
    model += [asks_code(0.95, quote="words nobody said")]
    out = turn(client, "s6", ASK_OTP, 1.0)
    assert out["evidence_quote"] == ASK_OTP and out["confidence"] < 0.7 and out["rolling_score"] < 0.7 and out["rule_hits"] == []


def test_model_failure_is_uncertain(client, model):
    model += [ValueError("bad json")]
    out = turn(client, "s7", ASK_OTP, 1.0)
    assert out["scam_type"] == "uncertain" and out["rolling_score"] < 0.7 and out["recommended_action"] == "none"


def test_conversation_alone_only_warns(client, model):
    model += [asks_code(0.95), asks_code(0.95)]
    assert turn(client, "s8", ASK_OTP, 1.0)["recommended_action"] == "warn"
    assert turn(client, "s9", ASK_OTP, 1.0, pending_action="pin_reset")["recommended_action"] == "hold_and_warn"


def test_risk_score_reads_the_sessions_scam_score(client, model, score_body):
    model += [asks_code(0.95)]
    turn(client, "call-1", ASK_OTP, 1.0)
    body = {**score_body, "session_id": "call-1", "txn": {"type": "pin_reset"}}
    out = client.post("/v1/risk/score", json=body).json()
    assert out["decision"] == "hold" and "SCAM_CONVERSATION" in {r["code"] for r in out["reasons"]}


def test_offline_stub_goes_through_the_same_guardrails(client):
    out = turn(client, "s10", CARE, 1.0, caller_number="16247")  # no Gemini in tests: the keyword stub answers
    assert out["confidence"] <= 0.4
    out = turn(client, "s11", ASK_OTP, 1.0)
    assert out["requested_secret"] == "otp" and out["evidence_quote"] == ASK_OTP


def test_prompt_has_bangla_and_banglish_examples_with_benign_lookalikes():
    """The few-shots now live in the example bank and reach the model in the cached prefix (P0 item 3)."""
    p = tactic_cards.load(Settings()).prefix()
    assert p.count("EXAMPLE ") >= 16 and p.count('"verdict": "SAFE"') >= 4
    assert "কোড" in p and "code ta" in p.lower()
    for label in ("fake_customer_care", "otp_pin_harvest", "lottery_prize", "wrong_send_refund", "job_loan_fee", "relative_impersonation", "UNCERTAIN", "SAFE"):
        assert label in p, label


BANK_LINE = "09612016247"  # the bank's own long-format line, as an operator adds it to RISK_MW_HELP_LINES


@pytest.mark.parametrize("configured", [BANK_LINE, "+8809612016247", "8809612016247", "+880 9612-016247"])
@pytest.mark.parametrize("caller_id", [BANK_LINE, "+880 9612-016247", "+8809612016247", "8809612016247", "09612-016247"])
def test_the_banks_long_number_matches_in_its_880_and_0_forms(configured, caller_id):
    from app.settings import Settings

    settings = Settings(help_lines=("16247", "16167", configured))
    assert scam.is_help_line(caller_id, settings)
    assert scam.is_help_line("+880 16247", settings) and scam.is_help_line("16247", settings)
    assert not scam.is_help_line("01700-000101", settings) and not scam.is_help_line("+8801700000101", settings)
