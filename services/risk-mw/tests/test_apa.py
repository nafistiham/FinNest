"""Apa's guard rails (spec US-3, FR-4): no fixed line for any reason, the hold card's layout per reason, the why token.

Her words are generated per call (tests/test_warnings.py); here Gemini is off, so every hold is the floor: no words.
"""

import hashlib
import hmac
import time

import pytest

from app import apa
from app.contracts import ScoreRequest
from app.rules import evaluate, model_hit, money_lock_hit
from app.settings import Settings, get_settings

TEXT = "রহিমা, একটু থামুন — কোডটা কাউকে বলবেন না।"


def _all_rule_codes() -> set[str]:
    req = ScoreRequest(user_id="u", session_id="s", txn={"type": "pin_reset", "amount_bdt": 99999, "is_new_payee": True},
                       demo_flags={"sim_swap": True, "call_active": True, "screen_share": True, "app_safety_verdict": "BLOCK",
                                   "inbound_mule_score": 0.95, "scam_score": 0.95})
    send = req.model_copy(update={"txn": req.txn.model_copy(update={"type": "send_money"})})
    hits = evaluate(req, 1000.0, get_settings()) + evaluate(send, 1000.0, get_settings()) + (money_lock_hit(), model_hit(0.9))
    return {h.reason.code for h in hits}


def _behaviour_codes() -> set[str]:
    """Every code the Behaviour (ATO) adapter can put on a score: identity, coaching, and the cold-start identity variant."""
    from bhorosha_ato.explain import as_behaviour_hits, explain

    from app import ato

    hits = as_behaviour_hits(explain(0.95, 0.95, [], call=None, in_call=True), 0.95, 0.95)
    codes = {h.code for h in hits}
    return codes | {c + ato.COLD_START_SUFFIX for c in codes & ato.IDENTITY_CODES}


def test_every_reason_code_has_a_card_layout_and_only_delays_and_step_ups_are_banners():
    codes = _all_rule_codes() | _behaviour_codes()
    assert len(_all_rule_codes()) == 9 and {"ATO_BEHAVIOUR_MISMATCH_COLD_START", "COACHING_SUSPECTED"} <= codes
    banners = {c for c in codes if apa.ui_for(c) == "banner"}
    assert banners == {"NEW_PAYEE_ABOVE_P95", "MODEL_RISK", "ATO_BEHAVIOUR_MISMATCH", "ATO_BEHAVIOUR_MISMATCH_COLD_START"}
    assert apa.ui_for("generic") == apa.ui_for("SOMETHING_NEW") == "banner"


@pytest.mark.parametrize("trigger", sorted({"generic", "call_active", "COACHING_SUSPECTED", "DEST_MULE_RISK", "NEW_PAYEE_ABOVE_P95",
                                            "SIM_CHANGED_24H", "SCAM_CONVERSATION", "MONEY_LOCK_ACTIVE"}))
def test_no_reason_has_a_fixed_line_without_gemini_every_hold_is_the_floor(client, trigger):
    out = client.post("/v1/intervene", json={"user_id": "rina", "trigger": trigger, "txn": {"type": "send_money"}}).json()
    assert (out["script_bn"], out["script_en"], out["audio_asset_id"], out["lines"]) == ("", "", None, [])
    assert out["earcon"] is True and out["vibrate"] is True and out["ui"] == apa.ui_for(trigger)


def test_old_trigger_names_still_choose_the_card(client):
    out = client.post("/v1/intervene", json={"user_id": "rina", "trigger": "call_active", "txn": {"type": "pin_reset"}}).json()
    assert out["ui"] == "fullscreen" and apa.reason_code("call_active") == "CALL_ACTIVE_NON_CONTACT"
    delayed = client.post("/v1/intervene", json={"user_id": "rina", "trigger": "NEW_PAYEE_ABOVE_P95", "txn": {"type": "send_money"}}).json()
    assert delayed["ui"] == "banner"


def test_the_floor_answers_at_once(client):
    """With nothing to say, the hold's card and earcon must not wait on anything."""
    started = time.perf_counter()
    client.post("/v1/intervene", json={"user_id": "rina", "trigger": "SCAM_CONVERSATION", "txn": {"type": "pin_reset"}})
    assert time.perf_counter() - started < 0.3


def test_apa_never_speaks_a_duration_the_checks_catch_it():
    for text in ("এক ঘণ্টা পরে পাঠান", "দুই ঘন্টা", "Send it in 1 hour.", "পাঁচ মিনিট"):
        assert apa.DURATION_WORDS.search(text) or apa.DIGITS.search(text), text


def test_a_why_token_is_bound_to_its_text_its_expiry_and_the_secret():
    settings, now = Settings(apa_token_secret="one", apa_token_ttl_s=300), time.time()
    token, expires = apa.sign_why(TEXT, settings, now)
    assert apa.verify_why(TEXT, token, settings, now + 299) and expires.timestamp() == int(now) + 300
    assert not apa.verify_why(TEXT + " ", token, settings, now)                     # other text
    assert not apa.verify_why(TEXT, token, settings, now + 301)                     # expired
    assert not apa.verify_why(TEXT, token, Settings(apa_token_secret="two"), now)  # another secret
    expiry, mac = token.split(".")
    assert not apa.verify_why(TEXT, f"{int(expiry) + 3600}.{mac}", settings, now)   # a stretched expiry
    for junk in (None, "", "abc", f"{expiry}.", f".{mac}", f"{expiry}x.{mac}", f"{expiry}.{mac[:-1]}"):
        assert not apa.verify_why(TEXT, junk, settings, now), junk


def test_without_a_configured_secret_tokens_use_a_random_key_of_this_process():
    settings, now = Settings(apa_token_secret=""), time.time()
    token, _ = apa.sign_why(TEXT, settings, now)
    expiry, mac = token.split(".")
    assert apa.verify_why(TEXT, token, settings, now) and len(apa._PROCESS_SECRET) == 32
    assert mac != hmac.new(b"", f"apa-why|{expiry}|{TEXT}".encode(), hashlib.sha256).hexdigest()  # never an empty key
