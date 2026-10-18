"""Gemini's reading of one stored score, for the analyst.

The drawer keeps showing the reasons exactly as the customer was told them. This is a second, separate
section: Gemini reads the stored document and says why the engine landed where it did. These tests pin
what it is given (the facts, never the phone's app list), what it may say (only the row's codes and
numbers), and what the console does when Gemini is off, slow or wrong.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from types import SimpleNamespace
from typing import Any

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from api import insight  # noqa: E402
from api.risk_mw import genai_client  # noqa: E402


def _reason(code: str, weight: float, en: str = "", bn: str = "") -> dict[str, Any]:
    return {"code": code, "weight": weight, "text_en": en or f"{code} text", "text_bn": bn or f"{code} টেক্সট"}


def score_doc(**outputs: Any) -> dict[str, Any]:
    """The hold the user pasted on 2026-10-18 (be977224…): App Safety CAUTION, a scam call, unfamiliar behaviour."""
    out = {
        "decision": "hold", "band": "critical", "risk_score": 0.95,
        "reasons": [
            _reason("APP_SAFETY_CAUTION", 0.59, "A suspicious app was found on your phone. Check the phone safety page."),
            _reason("SCAM_CONVERSATION", 0.95, "The ongoing conversation shows signs of a scam. It is safer not to proceed now."),
            _reason("ATO_BEHAVIOUR_MISMATCH", 0.76, "For your safety we want to confirm it is you."),
        ],
        "actions": [{"type": "hold_transaction", "params": {"minutes": 60, "intervention_id": "iv-07764ddaa313552e"}},
                    {"type": "trusted_contact_check", "params": {"expires_in_minutes": 10, "contact_uid": "rafiq"}}],
        "signal_sources": {"call_active": "demo", "screen_share": "none", "caller_in_contacts": "none", "sim_swap": "none"},
        "identity_source": "demo", "model_version": "rules+session-hgb-0.2",
        "payee_score_before": 0.0, "payee_score_with_this_transfer": 0.0013, "payee_moved_feature": "hops_to_recent_sim_swap",
        "warning": {"status": "ready", "warning": {"lines": [
            {"role": "A", "text_en": "Stop for a moment; don't send the money.", "text_bn": "একটু থামুন, টাকা পাঠাবেন না।"}]}},
    }
    out.update(outputs)
    return {
        "id": "be977224-1f95-4d7e-ad67-e8d1f4c7bebb", "kind": "score", "uid": "rina", "at": "2026-10-18T05:59:10+00:00",
        "model_version": "rules+session-hgb-0.2",
        "inputs": {
            "user_id": "rina", "session_id": "sess_b5522d10",
            "txn": {"to_account": "acct_rafiq", "is_new_payee": False, "amount_bdt": 255.0, "type": "send_money"},
            "demo_flags": {"call_active": True, "caller_in_contacts": False, "screen_share": False, "sim_swap": False,
                           "app_safety_verdict": "CAUTION", "inbound_mule_score": 0.0013, "scam_score": 0.95},
            "app_safety": {"verdict": "CAUTION", "risk_score": 0.781, "source": "check", "resolution": "UNINSTALL_AND_RECHECK", "findings_dropped": 0,
                           "valid_until": "2026-10-18T06:00:10+00:00", "attestation": "basic",
                           "findings": [
                               {"scope": "app", "severity": "high", "package": "com.examplewallet.customerapp.devb", "signal": "NFC_RELAY_CAPABLE"},
                               {"scope": "app", "severity": "high", "package": "com.examplewallet.customerapp.devb", "signal": "BRAND_IMPERSONATION"},
                               {"scope": "device", "severity": "low", "package": "device", "signal": "DEV_OPTIONS_ON"},
                               {"scope": "app", "severity": "low", "package": "com.android.chrome", "signal": "LOAN_APP_DATA_HARVEST"},
                           ]},
        },
        "outputs": out,
    }


def good_answer(**override: Any) -> dict[str, Any]:
    answer = {
        "summary_en": "Held because a scam call was under way; at 0.95 it set the score and asked for the hold.",
        "summary_bn": "প্রতারণার কল চলছিল বলে টাকা আটকে রাখা হয়েছে; ০.৯৫ ওজনে এটিই স্কোর ঠিক করেছে।",
        "drivers": [
            {"code": "SCAM_CONVERSATION", "reading_en": "Set the score at 0.95 and asked for the hold.",
             "reading_bn": "০.৯৫ ওজনে স্কোর ঠিক করেছে এবং আটকে রাখতে চেয়েছে।"},
            {"code": "ATO_BEHAVIOUR_MISMATCH", "reading_en": "At 0.76 the behaviour alone would only ask for a step-up.",
             "reading_bn": "০.৭৬ ওজনে শুধু আচরণ হলে স্টেপ-আপ চাইত।"},
            {"code": "APP_SAFETY_CAUTION", "reading_en": "Capped at 0.59; it never changes a decision by itself.",
             "reading_bn": "০.৫৯-এ সীমিত; নিজে কোনো সিদ্ধান্ত বদলায় না।"},
        ],
        "next_checks": [{"en": "Check whether the call flag came from the demo panel.", "bn": "কলের ফ্ল্যাগ ডেমো প্যানেল থেকে এসেছে কি না দেখুন।"}],
        "caveat_en": "The call state was set from the demo panel, not measured on the phone.",
        "caveat_bn": "কলের অবস্থা ডেমো প্যানেল থেকে বসানো, ফোনে মাপা নয়।",
    }
    answer.update(override)
    return answer


class FakeGemini:
    """Stands in for genai_client.call: records every prompt and answers from a queue."""

    def __init__(self, *answers: Any) -> None:
        self.answers = list(answers)
        self.prompts: list[tuple[str, str]] = []

    def __call__(self, system: str, contents: str) -> Any:
        self.prompts.append((system, contents))
        answer = self.answers.pop(0)
        if isinstance(answer, BaseException):
            raise answer
        return SimpleNamespace(parsed=insight.Answer.model_validate(answer), text=json.dumps(answer), model_id="gemini-test",
                               cost_usd=0.0012, latency_ms=850.0, tokens_in=1800, tokens_out=400)


@pytest.fixture(autouse=True)
def _fresh_cache() -> None:
    insight.forget()


# --- what Gemini is given ----------------------------------------------------------------------------------------------

def test_the_basis_names_the_reason_that_set_the_score() -> None:
    basis = insight.basis(score_doc())
    assert basis["risk_score"] == 0.95
    assert basis["score_set_by"] == ["SCAM_CONVERSATION"]
    assert basis["score_from_model"] is False


def test_the_basis_says_when_no_reason_reaches_the_score() -> None:
    """risk = max(weights, model score): a score above every weight came from the session model."""
    basis = insight.basis(score_doc(risk_score=0.97))
    assert basis["score_set_by"] == []
    assert basis["score_from_model"] is True


def test_each_reason_says_what_it_asks_for() -> None:
    by_code = {r["code"]: r for r in insight.basis(score_doc())["reasons"]}
    assert by_code["SCAM_CONVERSATION"]["asks_for"] == "hold"
    assert by_code["APP_SAFETY_CAUTION"]["asks_for"] == "allow"
    # The behaviour model asks for a step-up below 0.85 and a hold from it.
    assert by_code["ATO_BEHAVIOUR_MISMATCH"]["asks_for"] == "step_up"
    assert insight.basis(score_doc(reasons=[_reason("ATO_BEHAVIOUR_MISMATCH", 0.9)]))["reasons"][0]["asks_for"] == "hold"


def test_the_basis_names_the_reasons_whose_ask_is_the_decision() -> None:
    assert insight.basis(score_doc())["decision_matches"] == ["SCAM_CONVERSATION"]


def test_the_basis_says_which_signals_the_demo_panel_set() -> None:
    basis = insight.basis(score_doc())
    assert basis["signals"]["call_active"] == {"value": True, "source": "demo"}
    # risk-mw stores the fused flag (the stronger of the demo panel and its live classifier) without saying which.
    assert basis["signals"]["scam_score"] == {"value": 0.95, "source": "unrecorded"}
    assert "screen_share" not in basis["signals"]  # off and unmeasured: says nothing


def test_the_basis_never_carries_the_phones_app_list() -> None:
    basis = insight.basis(score_doc())
    flat = json.dumps(basis, ensure_ascii=False)
    assert "com." not in flat and "examplewallet" not in flat and "chrome" not in flat
    assert basis["app_safety"]["findings"] == {"NFC_RELAY_CAPABLE": "high", "BRAND_IMPERSONATION": "high",
                                               "DEV_OPTIONS_ON": "low", "LOAN_APP_DATA_HARVEST": "low"}
    assert basis["app_safety"]["apps_flagged"] == 2
    assert basis["app_safety"]["resolution"] == "UNINSTALL_AND_RECHECK"


def test_the_basis_keeps_what_the_customer_was_told() -> None:
    basis = insight.basis(score_doc())
    told = {r["code"]: r["told_customer_en"] for r in basis["reasons"]}
    assert told["SCAM_CONVERSATION"].startswith("The ongoing conversation shows signs of a scam")
    assert basis["warning_said_en"] == ["Stop for a moment; don't send the money."]


def test_the_prompt_is_built_from_the_basis_alone() -> None:
    system, contents = insight.prompt(insight.basis(score_doc()))
    assert "SCAM_CONVERSATION" in contents and "0.95" in contents
    assert "com.examplewallet" not in contents and "sess_b5522d10" not in contents and "iv-07764ddaa313552e" not in contents
    # The engine's own arithmetic is in the instructions, so the reading cannot invent a sum.
    assert "largest" in system and "not a sum" in system


# --- what Gemini may say ------------------------------------------------------------------------------------------------

def _problems(**override: Any) -> list[str]:
    return insight.check(insight.Answer.model_validate(good_answer(**override)), insight.basis(score_doc()))


def test_a_grounded_answer_passes() -> None:
    assert _problems() == []


def test_a_code_the_row_does_not_have_is_refused() -> None:
    drivers = good_answer()["drivers"] + [{"code": "SIM_CHANGED_24H", "reading_en": "SIM swap.", "reading_bn": "সিম বদল।"}]
    assert any("SIM_CHANGED_24H" in p for p in _problems(drivers=drivers))


def test_every_reason_needs_a_reading() -> None:
    assert any("APP_SAFETY_CAUTION" in p for p in _problems(drivers=good_answer()["drivers"][:2]))


def test_a_number_the_row_does_not_have_is_refused() -> None:
    assert any("0.42" in p for p in _problems(summary_en="Held at a risk of 0.42."))
    assert any("৪২" in p for p in _problems(summary_bn="ঝুঁকি ০.৪২-এ আটকে রাখা হয়েছে।"))


def test_numbers_in_either_script_or_as_percent_pass() -> None:
    assert _problems(summary_en="Held: the scam call scored 95% and the hold lasts 60 minutes; ৳255 was the amount.") == []
    assert _problems(summary_bn="প্রতারণার কল ০.৯৫, আটকে রাখা ৬০ মিনিট, টাকা ৳২৫৫।") == []


def test_small_counts_pass() -> None:
    assert _problems(summary_en="Three reasons fired; 2 of them ask for less than a hold.") == []


def test_old_brand_names_are_refused() -> None:
    assert _problems(summary_en="Bhorosha held it.") != []
    assert _problems(caveat_bn="আপা বলেছে।") != []


def test_an_app_package_name_is_refused() -> None:
    assert any("package" in p for p in _problems(caveat_en="The app com.examplewallet.customerapp.devb looks fake."))


def test_empty_text_is_refused() -> None:
    assert _problems(summary_bn=" ") != []


# --- explain(): one call, cached, and every way it can fail ------------------------------------------------------------

def test_one_call_answers_and_the_second_open_is_cached() -> None:
    gemini = FakeGemini(good_answer())
    first = insight.explain("doc-1", score_doc(), generate=gemini)
    second = insight.explain("doc-1", score_doc(), generate=gemini)
    assert len(gemini.prompts) == 1
    assert first["insight"]["summary_en"].startswith("Held because")
    assert first["cached"] is False and second["cached"] is True
    assert first["model_id"] == "gemini-test" and first["prompt_version"] == insight.PROMPT_VERSION


def test_drivers_come_back_in_the_rows_weight_order_with_the_stored_weight() -> None:
    result = insight.explain("doc-1", score_doc(), generate=FakeGemini(good_answer()))
    drivers = result["insight"]["drivers"]
    assert [d["code"] for d in drivers] == ["SCAM_CONVERSATION", "ATO_BEHAVIOUR_MISMATCH", "APP_SAFETY_CAUTION"]
    assert [d["weight"] for d in drivers] == [0.95, 0.76, 0.59]  # from the stored row, never from Gemini


def test_a_wrong_answer_is_retried_once_with_what_was_wrong() -> None:
    gemini = FakeGemini(good_answer(summary_en="Held at a risk of 0.42."), good_answer())
    result = insight.explain("doc-1", score_doc(), generate=gemini)
    assert len(gemini.prompts) == 2
    assert "0.42" in gemini.prompts[1][1]
    assert result["retried"] is True and result["insight"]["summary_en"].startswith("Held because")


def test_two_wrong_answers_are_not_shown_and_are_asked_again_only_later() -> None:
    bad = good_answer(summary_en="Held at a risk of 0.42.")
    with pytest.raises(insight.InsightUnavailable) as caught:
        insight.explain("doc-1", score_doc(), generate=FakeGemini(bad, bad))
    assert caught.value.code == "invalid"
    gemini = FakeGemini(good_answer())
    with pytest.raises(insight.InsightUnavailable):
        insight.explain("doc-1", score_doc(), generate=gemini)  # at once: not asked again
    insight._failed["doc-1"] = 0.0  # FAILED_TTL_S later
    assert insight.explain("doc-1", score_doc(), generate=gemini)["insight"]["summary_en"].startswith("Held because")
    assert len(gemini.prompts) == 1


def test_a_row_that_is_not_a_score_is_not_sent() -> None:
    gemini = FakeGemini()
    with pytest.raises(insight.InsightUnavailable) as caught:
        insight.explain("doc-2", {**score_doc(), "kind": "appsafety"}, generate=gemini)
    assert caught.value.code == "not_a_score" and gemini.prompts == []


def test_a_score_where_nothing_fired_is_not_sent() -> None:
    gemini = FakeGemini()
    with pytest.raises(insight.InsightUnavailable) as caught:
        insight.explain("doc-3", score_doc(decision="allow", band="low", risk_score=0.0, reasons=[]), generate=gemini)
    assert caught.value.code == "nothing_fired" and gemini.prompts == []


@pytest.mark.parametrize(("error", "code"), [
    (genai_client.GenAIDisabled("off"), "genai_disabled"),
    (genai_client.SpendCapReached("cap"), "spend_cap"),
    (TimeoutError("slow"), "timeout"),
    (RuntimeError("boom"), "genai_error"),
])
def test_gemini_failures_become_a_reason_code(error: BaseException, code: str) -> None:
    with pytest.raises(insight.InsightUnavailable) as caught:
        insight.explain("doc-4", score_doc(), generate=FakeGemini(error))
    assert caught.value.code == code
    assert "boom" not in str(caught.value.code)


def test_the_cache_is_bounded() -> None:
    for i in range(insight.CACHE_SIZE + 5):
        insight.explain(f"doc-{i}", score_doc(), generate=FakeGemini(good_answer()))
    assert len(insight._cache) == insight.CACHE_SIZE


# --- found on real rows (19 stored scores, 2026-10-18) -----------------------------------------------------------------

def test_a_behaviour_reason_never_asks_for_more_than_the_stored_decision() -> None:
    """dad90847: ATO 0.85 is a rounded score under 0.85, so it asked for a step-up, as the stored decision shows."""
    doc = score_doc(decision="step_up", risk_score=0.999,
                    reasons=[_reason("ATO_BEHAVIOUR_MISMATCH", 0.85), _reason("COACHING_SUSPECTED", 0.999)])
    by_code = {r["code"]: r["asks_for"] for r in insight.basis(doc)["reasons"]}
    assert by_code == {"ATO_BEHAVIOUR_MISMATCH": "step_up", "COACHING_SUSPECTED": "step_up"}


def test_a_coaching_reason_alone_is_what_asked_for_a_stricter_decision() -> None:
    doc = score_doc(decision="hold", risk_score=0.7, reasons=[_reason("COACHING_SUSPECTED", 0.7)])
    facts = insight.basis(doc)
    assert facts["reasons"][0]["asks_for"] == "hold"
    assert facts["decision_matches"] == ["COACHING_SUSPECTED"]


def test_english_writes_latin_digits() -> None:
    assert any("Bangla digits" in p for p in _problems(summary_en="Held at a risk of ০.৯৫."))


def test_bangla_writes_bangla_digits() -> None:
    assert any("Latin digits" in p for p in _problems(summary_bn="ঝুঁকি 0.95-এ আটকে রাখা হয়েছে।"))
    sim = score_doc(reasons=[_reason("SIM_CHANGED_24H", 0.85)], risk_score=0.85)
    answer = good_answer(summary_bn="SIM_CHANGED_24H ০.৮৫ ওজনে আটকে রেখেছে।", drivers=[
        {"code": "SIM_CHANGED_24H", "reading_en": "Set the score at 0.85.", "reading_bn": "০.৮৫ ওজনে স্কোর ঠিক করেছে।"}])
    assert insight.check(insight.Answer.model_validate(answer), insight.basis(sim)) == []  # a code keeps its own digits


def test_a_code_is_written_whole_and_only_if_the_row_has_it() -> None:
    assert any("SCAM_কনভার্সেশন" in p for p in _problems(summary_bn="SCAM_কনভার্সেশন ০.৯৫ স্কোর ঠিক করেছে।"))
    assert any("কল_অ্যাক্টিভ" in p for p in _problems(caveat_bn="কল_অ্যাক্টিভ ডেমো থেকে।"))
    assert any("MODEL_RISK" in p for p in _problems(summary_en="MODEL_RISK set the score at 0.95."))


def test_a_fact_rounded_to_two_places_passes() -> None:
    """be977224: the phone's App Safety risk is 0.781; "0.78" is that number, "0.79" is not."""
    assert _problems(caveat_en="The phone's own check said CAUTION at 0.78.") == []
    assert any("0.79" in p for p in _problems(caveat_en="The phone's own check said CAUTION at 0.79."))
    assert any("0.8" in p for p in _problems(caveat_en="The phone's own check said CAUTION at 0.8."))


def test_an_account_id_keeps_its_latin_digits_in_bangla() -> None:
    """baf0eaab: "acct_01288-এর মিউল স্কোর দেখুন" is the account's name, not a number written in the wrong script."""
    doc = score_doc()
    doc["inputs"]["txn"]["to_account"] = "acct_01288"
    checks = [{"en": "Open acct_01288's page for its mule score.", "bn": "acct_01288-এর পাতায় মিউল স্কোর দেখুন।"}]
    answer = insight.Answer.model_validate(good_answer(next_checks=checks))
    assert insight.check(answer, insight.basis(doc)) == []
    # An account the row does not have is an invented one.
    assert insight.check(answer, insight.basis(score_doc())) != []


def test_a_name_the_facts_carry_may_be_written() -> None:
    """59e3d0ae: an App Safety finding (NFC_RELAY_CAPABLE) or resolution is a fact, not an invented reason code."""
    checks = [{"en": "Look at the NFC_RELAY_CAPABLE finding.", "bn": "NFC_RELAY_CAPABLE ফাইন্ডিংটি দেখুন।"}]
    assert _problems(next_checks=checks) == []
    assert any("SMS_ROLE_TAKEOVER" in p for p in _problems(caveat_en="The SMS_ROLE_TAKEOVER finding matters."))


def test_a_short_account_id_is_a_name_not_a_latin_number() -> None:
    """e3704403 pays account "a1": "a1-কে পাঠানো ৳ ৫০০" writes the id as stored and the amount in Bangla digits."""
    doc = score_doc()
    doc["inputs"]["txn"].update(to_account="a1", amount_bdt=500.0)
    checks = [{"en": "Open a1's page for its mule score.", "bn": "a1-কে পাঠানো ৳ ৫০০ নিয়ে প্রাপকের পাতা দেখুন।"}]
    assert insight.check(insight.Answer.model_validate(good_answer(next_checks=checks)), insight.basis(doc)) == []


def test_the_reading_uses_the_workhorse_model() -> None:
    """Chosen on 19 real rows x 2: 3.8 Flash had no retries and read signals together; Flash-Lite said weights "add"."""
    assert insight.ROLE == "workhorse"


def test_a_whole_amount_is_given_without_decimals() -> None:
    """The stored 255.0 came back as "৳ 14.0"-style amounts 13 times in 36 readings; the facts now say 255."""
    amount = insight.basis(score_doc())["txn"]["amount_bdt"]
    assert amount == 255 and isinstance(amount, int)


def test_bangla_says_the_decision_in_bangla() -> None:
    assert any("hold" in p for p in _problems(summary_bn="পেমেন্টটি আটকে রাখা বা hold করা হয়েছে; ০.৯৫।"))
    assert any("allow" in p for p in _problems(caveat_bn="এটি ছেড়ে দেওয়া বা allow চেয়েছে।"))



# --- review of 235ff24 ---------------------------------------------------------------------------------------------

def test_a_mule_score_equal_to_the_payee_models_came_from_risk_mw() -> None:
    """risk-mw folds the payee model's score into inbound_mule_score (max wins) before the row is stored."""
    assert insight.basis(score_doc())["signals"]["inbound_mule_score"]["source"] == "payee model"
    doc = score_doc()
    doc["inputs"]["demo_flags"]["inbound_mule_score"] = 0.9
    assert insight.basis(doc)["signals"]["inbound_mule_score"]["source"] == "unrecorded"


def test_a_verdict_equal_to_the_phones_report_came_from_the_phone() -> None:
    assert insight.basis(score_doc())["signals"]["app_safety_verdict"]["source"] == "phone report"
    doc = score_doc()
    doc["inputs"]["app_safety"] = None
    assert insight.basis(doc)["signals"]["app_safety_verdict"]["source"] == "unrecorded"


def test_coaching_on_a_call_asks_for_a_hold() -> None:
    """explain.required_action: coaching at 0.60+ during a call is hold_and_callback (the US-3 demo case)."""
    doc = score_doc(reasons=[_reason("SCAM_CONVERSATION", 0.95), _reason("COACHING_SUSPECTED", 0.8)])
    facts = insight.basis(doc)
    assert {r["code"]: r["asks_for"] for r in facts["reasons"]}["COACHING_SUSPECTED"] == "hold"
    assert facts["decision_matches"] == ["SCAM_CONVERSATION", "COACHING_SUSPECTED"]


def test_coaching_with_strong_behaviour_asks_for_a_hold_even_off_a_call() -> None:
    doc = score_doc(risk_score=0.9, reasons=[_reason("ATO_BEHAVIOUR_MISMATCH", 0.9), _reason("COACHING_SUSPECTED", 0.7)])
    doc["inputs"]["demo_flags"]["call_active"] = False
    assert {r["code"]: r["asks_for"] for r in insight.basis(doc)["reasons"]}["COACHING_SUSPECTED"] == "hold"


def test_weak_behaviour_never_asks_for_a_hold() -> None:
    doc = score_doc(risk_score=0.8, reasons=[_reason("ATO_BEHAVIOUR_MISMATCH", 0.7), _reason("COACHING_SUSPECTED", 0.8)])
    by_code = {r["code"]: r["asks_for"] for r in insight.basis(doc)["reasons"]}
    assert by_code == {"ATO_BEHAVIOUR_MISMATCH": "step_up", "COACHING_SUSPECTED": "hold"}


def test_a_rounded_behaviour_score_never_asks_above_a_delay() -> None:
    doc = score_doc(decision="delay", risk_score=0.85, reasons=[_reason("ATO_BEHAVIOUR_MISMATCH", 0.85), _reason("NEW_PAYEE_ABOVE_P95", 0.6)])
    doc["inputs"]["demo_flags"]["call_active"] = False
    assert {r["code"]: r["asks_for"] for r in insight.basis(doc)["reasons"]}["ATO_BEHAVIOUR_MISMATCH"] == "step_up"


def test_two_opens_of_a_row_gemini_gets_wrong_make_two_calls_not_four() -> None:
    import threading

    bad = good_answer(summary_en="Held at a risk of 0.42.")
    gemini = FakeGemini(bad, bad, bad, bad)
    errors: list[str] = []

    def open_row() -> None:
        try:
            insight.explain("doc-race", score_doc(), generate=gemini)
        except insight.InsightUnavailable as exc:
            errors.append(exc.code)

    threads = [threading.Thread(target=open_row) for _ in range(2)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    assert errors == ["invalid", "invalid"]
    assert len(gemini.prompts) == 2  # the second open waited and read the remembered failure


def test_a_reading_that_failed_the_check_is_not_asked_again_at_once() -> None:
    bad = good_answer(summary_en="Held at a risk of 0.42.")
    with pytest.raises(insight.InsightUnavailable):
        insight.explain("doc-bad", score_doc(), generate=FakeGemini(bad, bad))
    gemini = FakeGemini(good_answer())
    with pytest.raises(insight.InsightUnavailable) as caught:
        insight.explain("doc-bad", score_doc(), generate=gemini)
    assert caught.value.code == "invalid" and gemini.prompts == []


def test_a_slow_answer_can_be_asked_again() -> None:
    with pytest.raises(insight.InsightUnavailable):
        insight.explain("doc-slow", score_doc(), generate=FakeGemini(TimeoutError("slow")))
    assert insight.explain("doc-slow", score_doc(), generate=FakeGemini(good_answer()))["cached"] is False


@pytest.mark.parametrize("change", [
    lambda d: d["outputs"].update(risk_score="0.95"),
    lambda d: d["outputs"]["reasons"][0].update(weight="high"),
    lambda d: d["outputs"].update(decision=["hold"]),
    lambda d: d["outputs"].update(warning="ready"),
    lambda d: d["outputs"]["actions"][0].update(params=["minutes", 60]),
    lambda d: d["inputs"].update(demo_flags="on"),
    lambda d: d["inputs"].update(txn=None),
])
def test_an_odd_document_is_unreadable_not_a_500(change: Any) -> None:
    doc = score_doc()
    change(doc)
    gemini = FakeGemini(good_answer())
    try:
        insight.explain("doc-odd", doc, generate=gemini)
    except insight.InsightUnavailable as exc:
        assert exc.code in {"unreadable", "invalid"}


def test_a_code_with_a_bangla_ending_is_still_the_code() -> None:
    assert _problems(summary_bn="SCAM_CONVERSATIONএর ওজন ০.৯৫।") == []


def test_percent_in_words_is_a_percent() -> None:
    assert _problems(summary_en="The scam call scored 95 percent.") == []
    assert _problems(summary_bn="স্ক্যাম স্কোর ৯৫ শতাংশ।") == []


def test_a_list_of_weights_is_not_read_as_one_number() -> None:
    assert _problems(summary_en="Weights 0.95,0.76 and 0.59.") == []


def test_the_model_version_lends_no_numbers() -> None:
    assert any("0.2" in p for p in _problems(summary_en="The payee's mule score was 0.2."))


def test_bangla_spelling_of_an_english_decision_word_is_refused() -> None:
    assert any("হোল্ড" in p for p in _problems(summary_bn="এটি হোল্ড চেয়েছে; ০.৯৫।"))


def test_an_old_brand_word_is_quoted_back() -> None:
    assert any("ভরসা" in p for p in _problems(caveat_bn="এর উপর ভরসা করা যায় না।"))


def test_an_app_safety_verdict_in_capitals_is_a_name_not_a_decision_word() -> None:
    """223467b1: "অ্যাপ সেফটি BLOCK দিয়েছে" names the verdict; "এটি hold চেয়েছে" is the decision in English."""
    assert _problems(caveat_bn="ফোনের অ্যাপ সেফটি রিপোর্ট BLOCK দিয়েছে।") == []
    assert any("hold" in p for p in _problems(caveat_bn="এটি hold চেয়েছে।"))
    assert any("Hold" in p for p in _problems(caveat_bn="Hold চেয়েছে।"))
