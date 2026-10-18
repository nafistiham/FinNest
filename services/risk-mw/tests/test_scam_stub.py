"""The scam fallback asserts only what it knows.

A probe sentence: "Never share your OTP or PIN; we will never ask for it." got confidence 0.85, requested_secret otp and
hold_and_warn, because any secret word counted as a request for it. A secret now counts only with a request verb in
the same sentence that no negation cancels, and every fallback answer says it is one.
"""

from __future__ import annotations

import pytest

import httpx

from app import audit, genai_client, scam_stub
from app.contracts import ScamTurnRequest, ScamTurnResponse

FALLBACK = genai_client.FALLBACK_GENAI_DISABLED


def _request(*caller_lines: str) -> ScamTurnRequest:
    return ScamTurnRequest(session_id="s", turns=tuple({"speaker": "caller", "text": line, "ts": float(i)} for i, line in enumerate(caller_lines)))


def _stub(*caller_lines: str) -> ScamTurnResponse:
    return scam_stub.classify(_request(*caller_lines), FALLBACK)


# --- a request for a secret, in Bangla and English -------------------------------------------------


@pytest.mark.parametrize(("line", "secret"), [
    ("আপনার একাউন্ট বন্ধ হয়ে যাবে, এখনই ওটিপি কোডটা বলুন", "otp"),
    ("আপনার পিন নম্বরটা দিন", "pin"),
    ("ওটিপিটা বলুন, না হলে একাউন্ট বন্ধ হয়ে যাবে", "otp"),
    ("Please tell me the OTP you just received", "otp"),
    ("What is your PIN?", "pin"),
    ("Sir, your password, please share it with me", "password"),
    ("We never call customers, so read me the code now", "otp"),
    ("If you don't give me the OTP your account will be blocked", "otp"),
    # না after an imperative coaxes, it does not refuse (review): "do tell me, please"
    ("ওটিপিটা বলুন না", "otp"),
    ("কোডটা দিন না প্লিজ", "otp"),
    ("পিনটা বলেন না একটু", "pin"),
    # obligation forms
    ("আপনার ওটিপিটা বলতে হবে", "otp"),
    ("পিন নম্বর দিতে হবে", "pin"),
    ("কোডটা জানাবেন", "otp"),
    # Banglish
    ("otp ta bolen", "otp"),
    ("pin ta den", "pin"),
    ("otp ta den na please", "otp"),
    # English
    ("I need your OTP", "otp"),
    ("Please confirm the OTP", "otp"),
])
def test_a_secret_asked_for_is_a_request(line, secret):
    out = _stub(line)
    assert out.requested_secret == secret
    assert out.recommended_action == "hold_and_warn"
    assert out.confidence == out.rolling_score == scam_stub.CONFIDENCE_SECRET


# --- the same words as advice ----------------------------------------------------------------------


@pytest.mark.parametrize("line", [
    "Never share your OTP or PIN; we will never ask for it.",
    "Don't give your password to anyone.",
    "Do not tell anyone your PIN.",
    "কখনো কাউকে ওটিপি বলবেন না।",
    "আপনার পিন কাউকে দিবেন না",
    "পিন শেয়ার করবেন না",
    "Your OTP is 4821.",
    "আমরা কখনো আপনার পিন চাই না",
    "ওটিপি দেবেন না",
    "কোড কাউকে পাঠাবেন না",
    "আপনাকে ওটিপি বলতে হবে না",
    "otp kauke diben na",
    "You never need to confirm your OTP",
    "We don't need your PIN",
])
def test_a_secret_named_without_a_request_is_not_one(line):
    out = _stub(line)
    assert out.requested_secret == "none"
    assert out.recommended_action in {"none", "warn"}
    assert out.confidence < scam_stub.CONFIDENCE_SECRET


def test_the_probe_sentence_is_benign():
    out = _stub("Never share your OTP or PIN; we will never ask for it.")
    assert (out.requested_secret, out.recommended_action, out.scam_type) == ("none", "none", "benign")


def test_a_secret_and_a_verb_in_different_turns_are_not_a_request():
    assert _stub("আপনার ওটিপি এসেছে", "এখন আমার কথা শুনুন").requested_secret == "none"


# --- pressure and authority are kept ---------------------------------------------------------------


def test_pressure_alone_warns():
    out = _stub("আপনার একাউন্ট এখনই বন্ধ হয়ে যাবে")
    assert (out.requested_secret, out.recommended_action, out.urgency) == ("none", "warn", "medium")
    assert out.confidence == scam_stub.CONFIDENCE_PRESSURE


def test_authority_alone_is_labelled_but_not_acted_on():
    out = _stub("I am calling from the head office")
    assert (out.scam_type, out.recommended_action) == ("fake_customer_care", "none")


def test_a_request_under_pressure_is_urgent():
    assert _stub("আপনার একাউন্ট বন্ধ হয়ে যাবে, এখনই ওটিপি কোডটা বলুন").urgency == "high"


def test_the_evidence_is_the_turn_that_asked():
    out = _stub("ওটিপি কোডটা বলুন", "হ্যালো?")
    assert out.evidence_quote == "ওটিপি কোডটা বলুন"


def test_without_a_request_the_evidence_is_the_last_caller_turn():
    assert _stub("হ্যালো", "আমি ব্যাংক থেকে বলছি").evidence_quote == "আমি ব্যাংক থেকে বলছি"


def test_user_turns_are_not_classified():
    body = ScamTurnRequest(session_id="s", turns=({"speaker": "user", "text": "আমার পিন বলুন?", "ts": 0.0},))
    assert scam_stub.classify(body, FALLBACK).requested_secret == "none"


# --- the fallback is visible -----------------------------------------------------------------------


def test_every_stub_answer_is_marked_as_the_fallback():
    out = _stub("What is your PIN?")
    assert out.model_version == scam_stub.STUB_MODEL_VERSION == "stub-fallback"
    assert out.fallback_reason == FALLBACK


def test_the_route_says_why_it_fell_back(client):
    out = client.post("/v1/scam/turn", json={"session_id": "s", "turns": [{"speaker": "caller", "text": "কোডটা বলুন", "ts": 1}]}).json()
    assert (out["model_version"], out["fallback_reason"]) == ("stub-fallback", "genai_disabled")


@pytest.mark.parametrize(("error", "code"), [
    (genai_client.GenAIDisabled("RISK_MW_GENAI_ENABLED is false"), "genai_disabled"),
    (genai_client.SpendCapReached("spend cap of $5.00 reached"), "spend_cap"),
    (TimeoutError("deadline"), "timeout"),
    (httpx.ReadTimeout("read timed out"), "timeout"),
    (RuntimeError("upstream said: secret-ish detail"), "genai_error"),
    (ValueError("model returned no parsed ScamClassification"), "genai_error"),
])
def test_the_fallback_reason_is_a_fixed_code_never_the_error_text(client, monkeypatch, error, code):
    def broken(*args, **kwargs):
        raise error

    monkeypatch.setattr(genai_client, "call", broken)
    out = client.post("/v1/scam/turn", json={"session_id": "s", "turns": [{"speaker": "caller", "text": "hello", "ts": 1}]}).json()
    assert (out["model_version"], out["fallback_reason"]) == ("stub-fallback", code)
    assert code in genai_client.FALLBACK_CODES


def test_a_gemini_answer_names_its_model_and_no_fallback(client, monkeypatch):
    """Under the detector Gemini fills the evidence checklist (a Vertex dict schema); the provenance is added by code."""
    seen = {}
    ask = "কোডটা বলুন"
    answer = {"tactics": [{"tactic": "CREDENTIAL_REQUEST", "quote": ask, "turn": 0}], "claimed_identity": "bank_mfs_staff", "ask": "otp",
              "scam_type": "none", "verdict": "SCAM", "confidence": 0.9, "injection_attempt": False}

    def gemini(task, role_name, contents, schema=None, system=None, **kwargs):
        seen["schema"] = schema
        return genai_client.CallResult(text="", parsed=answer, model_id="gemini-3.5-flash-lite", tokens_in=1, tokens_out=1, cost_usd=0.0, latency_ms=1.0)

    monkeypatch.setattr(genai_client, "call", gemini)
    out = client.post("/v1/scam/turn", json={"session_id": "s", "turns": [{"speaker": "caller", "text": ask, "ts": 1}]}).json()
    assert out["model_version"] == genai_client.roles()["volume"].id == "gemini-3.5-flash-lite" and out["fallback_reason"] is None
    assert out["requested_secret"] == "otp"
    assert not {"model_version", "fallback_reason"} & set(seen["schema"]["properties"])  # Gemini fills the evidence, never the provenance


def test_the_audit_row_carries_the_provenance(client, monkeypatch):
    rows = []
    monkeypatch.setattr(audit, "record", lambda kind, uid, inputs, outputs, ms: rows.append((kind, outputs)) or "audit-id")
    client.post("/v1/scam/turn", json={"session_id": "s", "turns": [{"speaker": "caller", "text": "hello", "ts": 1}]})
    kind, outputs = rows[-1]
    assert kind == "scam_turn" and outputs["model_version"] == "stub-fallback" and outputs["fallback_reason"]


# --- the detector's offline stand-in uses this rule too ---------------------------------------------------------------


@pytest.mark.parametrize(("line", "asks"), [
    ("Don't share your OTP with anyone.", None),  # a bank's warning, not a request
    ("আপনার ওটিপি কাউকে শেয়ার করবেন না।", None),
    ("পিন নম্বরটা কাউকে দেবেন না।", None),
    ("কোডটা বলুন না, তাড়াতাড়ি।", "otp"),  # coaxing না is still a request
    ("Please tell me the OTP now.", "otp"),
    ("If you don't give me the code your account will be blocked.", "otp"),
])
def test_the_detectors_stub_asks_only_when_the_caller_asks(line, asks):
    from app import scam
    from app.contracts import Turn

    raw = scam._stub_extraction((Turn(speaker="caller", text=line, ts=0.0),))
    assert ("CREDENTIAL_REQUEST" in {t.tactic for t in raw.tactics}) == (asks is not None)
    assert raw.ask == (asks or "none")
