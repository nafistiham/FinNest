"""App Safety evidence is cited for what it is.

Seen live (case-zero-00008-2hp, CZ-LZCT7YDP2E, seed acct_01070 at 2026-11-10T14:35:00): device_safety(acct_rina)
returned a CAUTION that the customer's phone reported, with the fact REMOTE_CONTROL. The writer raised RF04 "acct_rina
shows remote control compromise on device safety check" and wrote "victim acct_rina was compromised via remote control"
at 14:13. That overclaims three ways: a CAUTION is not a compromise, the phone's own report is not the bank's check, and
a verdict about the phone now says nothing about the phone at 14:13. Code now holds a red flag, timeline entry or
narrative sentence about such a verdict to what the phone reported.
"""

import asyncio
import dataclasses
import io
import json

import pytest
from fake_llm import FakeLLM, call, done, draft as turn

from case_zero import prompts, tools
from case_zero.config import Settings
from case_zero.ledger import Ledger
from case_zero.orchestrator import run_investigation
from case_zero.schemas import CaseDraft
from case_zero.validator import redact, validate

SEED, AS_OF = "acct_01070", "2026-11-10T14:35:00"
PHONE_CAUTION = {"known": True, "verdict": "CAUTION", "risk_score": 0.5, "flagged_packages": [], "attestation": "none",
                 "source": "phone", "facts": ["REMOTE_CONTROL"]}
SERVER_CAUTION = {**PHONE_CAUTION, "source": "server"}
SERVER_BLOCK = {**PHONE_CAUTION, "verdict": "BLOCK", "risk_score": 0.95, "source": "server"}
SAFE_PHONE = {**PHONE_CAUTION, "verdict": "SAFE", "risk_score": 0.0, "facts": []}
GOOD_EN = "acct_rina's phone reported an app that can control the screen (CAUTION)"
GOOD_BN = "acct_rina-এর ফোন জানিয়েছে, তাতে স্ক্রিন নিয়ন্ত্রণ করতে পারে এমন একটি অ্যাপ আছে (CAUTION)"
# No fact in the bank-check example: with none listed (a medium finding), Gemini copied "an app that can control the screen"
# from an earlier version of this example in both end-to-end runs (2026-10-18).
GOOD_SERVER_EN = "the App Safety Check found a risky app on acct_rina's phone (CAUTION)"
# In Bangla too: with the English one alone, an end-to-end run pasted it into narrative_bn as it was (2026-10-18).
GOOD_SERVER_BN = "App Safety Check acct_rina-এর ফোনে একটি ঝুঁকিপূর্ণ অ্যাপ পেয়েছে (CAUTION)"
LIVE_RF04 = "acct_rina shows remote control compromise on device safety check"
LIVE_NARRATIVE = "victim acct_rina was compromised via remote control at 14:13."


class _Resp(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


@pytest.fixture()
def risk_mw(monkeypatch):
    """A fake risk-mw /v1/appsafety/latest that answers `answer[0]` for every account."""
    answer = [PHONE_CAUTION]
    monkeypatch.setattr(tools, "RISK_MW_URL", "https://risk-mw.example")
    monkeypatch.setattr(tools.urllib.request, "urlopen", lambda req, timeout: _Resp(json.dumps({"uid": "acct_rina", **answer[0]}).encode()))
    return answer


def ledger_with(world, verdict: dict, answer: list) -> Ledger:
    answer[0] = verdict
    led = Ledger(world, SEED, AS_OF)
    led.prefetch_score()                                                # tc_00 seed_brief
    led.call("path_between", source="acct_rina", target=SEED)          # tc_01 Tk 7,900 at 14:13
    led.call("device_safety", acct_id="acct_rina")                     # tc_02 the App Safety verdict
    led.call("score", acct_id="acct_rina")                             # tc_03 the victim's own score (a SIM-swap reason)
    return led


@pytest.fixture()
def phone(world, risk_mw):
    return ledger_with(world, PHONE_CAUTION, risk_mw)


def case(**over) -> CaseDraft:
    base = dict(
        typology="otp_takeover_cashout",
        members=[{"acct_id": "acct_rina", "role": "victim", "evidence": ["tc_01"]}, {"acct_id": SEED, "role": "mule_L1", "evidence": ["tc_01"]}],
        excluded=[], red_flags=[], timeline=[{"ts": "2026-11-10T14:13:00", "text": "acct_rina sends Tk 7,900 to acct_01070", "evidence": ["tc_01"]}],
        proposed_action="freeze",
        narrative_en="acct_rina sent Tk 7,900 to acct_01070 at 14:13.",
        narrative_bn="acct_rina ১৪:১৩-এ acct_01070-এ ৭,৯০০ টাকা পাঠান।",
        limitations="",
    )
    return CaseDraft(**{**base, **over})


def rf04(text: str, *evidence: str) -> dict:
    return {"code": "RF04", "text": text, "evidence": list(evidence or ["tc_02"])}


def overclaims(d: CaseDraft, led) -> list:
    return [v for v in validate(d, led) if v.code == "app_safety_overclaim"]


# The live case -----------------------------------------------------------------------------------------------------
def test_the_live_rf04_is_rejected_with_how_to_say_it(phone):
    found = overclaims(case(red_flags=[rf04(LIVE_RF04)]), phone)
    assert [v.field for v in found] == ["red_flags"]
    assert LIVE_RF04 in found[0].detail and "tc_02" in found[0].detail
    assert "reported" in found[0].detail and f'"{GOOD_EN}"' in found[0].detail   # the retry is told what to write


def test_the_live_narrative_sentence_is_rejected(phone):
    d = case(narrative_en=f"acct_rina sent Tk 7,900 to acct_01070 at 14:13. {LIVE_NARRATIVE}")
    found = overclaims(d, phone)
    assert [v.field for v in found] == ["narrative_en"] and LIVE_NARRATIVE in found[0].detail


def test_what_the_phone_reported_passes(phone):
    d = case(red_flags=[rf04(GOOD_EN)],
             narrative_en=f"acct_rina sent Tk 7,900 to acct_01070 at 14:13. {GOOD_EN}.",
             narrative_bn=f"acct_rina ১৪:১৩-এ acct_01070-এ ৭,৯০০ টাকা পাঠান। {GOOD_BN}।")
    assert validate(d, phone) == []


def test_found_on_her_phone_also_qualifies(phone):
    d = case(red_flags=[rf04("an app that can control the screen was found on acct_rina's phone (CAUTION)")])
    assert overclaims(d, phone) == []


# What counts as overclaiming -----------------------------------------------------------------------------------------
@pytest.mark.parametrize("text", [
    "acct_rina's phone reported a remote-control app; the account was hacked",
    "acct_rina's phone reported a remote-control app and was taken over",
    "acct_rina's phone reported a remote-control app, an account takeover",
    "acct_rina's phone was remotely controlled, as it reported (CAUTION)",
])
def test_compromise_words_are_rejected_even_when_attributed(phone, text):
    assert len(overclaims(case(red_flags=[rf04(text)]), phone)) == 1


def test_a_phone_report_must_be_attributed_to_the_phone(phone):
    found = overclaims(case(red_flags=[rf04("acct_rina's device has a remote control app (CAUTION)")]), phone)
    assert len(found) == 1 and "phone" in found[0].detail


def test_a_phone_report_carries_no_time(phone):
    bad = case(narrative_en=f"acct_rina sent Tk 7,900 to acct_01070. At 14:13 acct_rina's phone reported a remote-control app.")
    assert [v.field for v in overclaims(bad, phone)] == ["narrative_en"]
    ok = case(narrative_en=f"acct_rina sent Tk 7,900 to acct_01070 at 14:13; her phone reported an app that can control the screen (CAUTION).")
    assert overclaims(ok, phone) == []   # the time belongs to the transfer clause, not to the phone's report


@pytest.mark.parametrize("verdict,sentence", [   # end-to-end runs, 2026-10-18: the device risk as the reason the money moved
    (SERVER_CAUTION, "Because the funds were taken following remote access device risk and immediately dispersed through a classic mule tree, an immediate freeze is proposed."),
    (SERVER_CAUTION, "দূরবর্তী নিয়ন্ত্রণ ঝুঁকি এবং দ্রুত অর্থ বিভাজনের কারণে অ্যাকাউন্টগুলো অবিলম্বে freeze করার প্রস্তাব করা হলো।"),
    (PHONE_CAUTION, "acct_rina's phone reported an app that can control the screen (CAUTION) before she sent the money."),
])
def test_a_verdict_about_the_phone_now_puts_no_order_or_cause_on_a_transfer(world, risk_mw, verdict, sentence):
    led = ledger_with(world, verdict, risk_mw)
    field = "narrative_bn" if "অ" in sentence else "narrative_en"
    found = overclaims(case(**{field: f"{getattr(case(), field)} {sentence}"}), led)
    assert [v.field for v in found] == [field] and "no order or cause" in found[0].detail


@pytest.mark.parametrize("sentence", [
    # console end-to-end run, 2026-10-18: the narrative named no SIM swap, so the compromise can only be the phone's CAUTION
    "Due to active compromise indicators and rapid fund dispersal, freezing the involved accounts is proposed.",
    "victim acct_rina was compromised at 14:13.",
])
def test_a_compromise_word_with_no_other_basis_rests_on_the_phone_report(phone, sentence):
    d = case(narrative_en=f"acct_rina sent Tk 7,900 to acct_01070 at 14:13. {sentence}")
    found = overclaims(d, phone)
    assert [v.field for v in found] == ["narrative_en"] and "compromised, hacked or taken over" in found[0].detail


@pytest.mark.parametrize("sentence", [
    "Funds moved within minutes of the takeover that followed acct_rina's SIM swap.",
    "acct_01070's controller took over the forwarding of the money.",   # names only an account with no App Safety verdict
])
def test_a_compromise_word_with_its_own_basis_or_account_is_untouched(phone, sentence):
    assert overclaims(case(narrative_en=f"acct_rina sent Tk 7,900 to acct_01070 at 14:13. {sentence}"), phone) == []


def test_order_words_elsewhere_are_untouched(phone):
    d = case(narrative_en="acct_rina sent Tk 7,900 to acct_01070 at 14:13. acct_01070 moved the money on right after it arrived. "
                          "acct_rina's phone reported an app that can control the screen (CAUTION).")
    assert overclaims(d, phone) == []


def test_a_timeline_entry_cannot_rest_on_the_phone_report(phone):
    d = case(timeline=[{"ts": "2026-11-10T14:13:00", "text": GOOD_EN, "evidence": ["tc_02"]}])
    found = overclaims(d, phone)
    assert [v.field for v in found] == ["timeline"] and "no time" in found[0].detail


def test_a_red_flag_resting_only_on_the_phone_report_is_held_to_it_whatever_it_mentions(phone):
    assert len(overclaims(case(red_flags=[rf04("acct_rina was hacked")]), phone)) == 1


def test_bangla_overclaims_are_rejected(phone):
    for bn in ("acct_rina ১৪:১৩-এ acct_01070-এ ৭,৯০০ টাকা পাঠান। রিমোট কন্ট্রোলের মাধ্যমে acct_rina-এর অ্যাকাউন্ট হ্যাক করা হয়।",
               "acct_rina ১৪:১৩-এ acct_01070-এ ৭,৯০০ টাকা পাঠান। acct_rina-এর ফোন রিমোট কন্ট্রোলের মাধ্যমে আপস করা হয়েছিল।",
               # "বার্তা" for messages, as Gemini wrote it in a live run with READS_MESSAGES
               "acct_rina ১৪:১৩-এ acct_01070-এ ৭,৯০০ টাকা পাঠান। বার্তা পড়ার মতো একটি অ্যাপ দিয়ে acct_rina-এর অ্যাকাউন্ট হ্যাক করা হয়।"):
        assert [v.field for v in overclaims(case(narrative_bn=bn), phone)] == ["narrative_bn"], bn


# What stays allowed --------------------------------------------------------------------------------------------------
def test_a_sim_swap_takeover_resting_on_the_score_is_not_touched(phone):
    d = case(red_flags=[rf04("acct_rina had a recent SIM swap: a takeover signal", "tc_03")],
             narrative_en="acct_rina was taken over after a SIM swap and sent Tk 7,900 to acct_01070 at 14:13.")
    assert overclaims(d, phone) == []


def test_a_safe_phone_report_changes_nothing(world, risk_mw):
    """The app sends a SAFE report with every score, so Rina's ordinary state is a SAFE from
    her phone. A SAFE has nothing to overclaim and must not switch the check on."""
    led = ledger_with(world, SAFE_PHONE, risk_mw)
    d = case(red_flags=[rf04("acct_rina's phone showed no risky app on the safety check (SAFE)")],
             narrative_en="acct_rina sent Tk 7,900 to acct_01070 at 14:13. acct_rina's phone showed no risky app on the safety check (SAFE).")
    assert overclaims(d, led) == []


@pytest.mark.parametrize("field,sentence", [
    ("narrative_bn", "অ্যাকাউন্টটি নিরাপত্তার জন্য ফ্রিজ করা হয়েছে।"),                    # frozen for safety
    ("narrative_en", "Funds were moved in a block of five transfers at 14:20:00."),
    ("narrative_en", "The account should be handled with caution."),
    ("narrative_en", "acct_rina's money left in a block of transfers at 14:13."),           # names her, but "block" is not BLOCK
])
def test_an_ordinary_word_is_not_app_safety(phone, field, sentence):
    """Block, caution, screen and নিরাপত্তা are ordinary words; alone they do not make a sentence about the
    phone's report, so it is not sent back (and then removed, which can also split the two narratives)."""
    d = case(**{field: f"{getattr(case(), field)} {sentence}"})
    assert overclaims(d, phone) == []


def test_a_sentence_naming_no_account_is_still_held_to_a_specific_app_safety_word(phone):
    d = case(narrative_en="acct_rina sent Tk 7,900 to acct_01070 at 14:13. The victim's phone was compromised via remote control.")
    assert [v.field for v in overclaims(d, phone)] == ["narrative_en"]


def test_the_common_point_of_compromise_is_not_a_compromise_word(phone):
    d = case(narrative_en="common_point_of_compromise found no shared merchant for acct_rina, whose phone reported an app that can control the screen (CAUTION).")
    assert overclaims(d, phone) == []


def test_limitations_may_say_what_the_report_is_not(phone):
    d = case(limitations="acct_rina's App Safety CAUTION was reported by her phone; it describes the phone now and is not proof of a compromise.")
    assert overclaims(d, phone) == []


def test_a_bank_checked_block_may_support_a_takeover(world, risk_mw):
    led = ledger_with(world, SERVER_BLOCK, risk_mw)
    assert overclaims(case(red_flags=[rf04("acct_rina's phone was compromised by a remote-control app (BLOCK)")]), led) == []


def test_a_bank_checked_caution_needs_no_phone_attribution_but_is_still_no_compromise(world, risk_mw):
    led = ledger_with(world, SERVER_CAUTION, risk_mw)
    assert overclaims(case(red_flags=[rf04("the App Safety Check found an app that can control the screen on acct_rina's device (CAUTION)")]), led) == []
    assert len(overclaims(case(red_flags=[rf04(LIVE_RF04)]), led)) == 1


@pytest.mark.parametrize("verdict,text", [
    (SERVER_CAUTION, "acct_rina's phone reported com.google.chromeremotedesktop (CAUTION)"),   # live, 2026-10-18 e2e run
    (SERVER_BLOCK, "acct_rina's phone reported an app that can control the screen (BLOCK)"),
])
def test_the_banks_own_check_is_not_called_the_phones_report(world, risk_mw, verdict, text):
    """In the end-to-end run the writer copied the phone example for a CAUTION the bank's own check found: "the phone
    reported" is as wrong there as "the bank checked" is for a phone's report."""
    led = ledger_with(world, verdict, risk_mw)
    found = overclaims(case(red_flags=[rf04(text)]), led)
    assert len(found) == 1 and "not a report from the phone" in found[0].detail and "the App Safety Check found" in found[0].detail
    assert overclaims(case(narrative_en=f"acct_rina sent Tk 7,900 to acct_01070 at 14:13. {text}."), led) != []


def test_no_check_on_record_changes_nothing(world, risk_mw):
    led = ledger_with(world, {"known": False}, risk_mw)
    assert overclaims(case(red_flags=[rf04(LIVE_RF04)], narrative_en=LIVE_NARRATIVE), led) == []


# The repair path: one retry with the feedback, then code removes what still overclaims ---------------------------------
def test_redaction_removes_the_overclaims_and_keeps_the_rest(phone):
    d = case(red_flags=[rf04(LIVE_RF04), {"code": "RF01", "text": "acct_01070 moved Tk 7,900 on within minutes", "evidence": ["tc_01"]}],
             narrative_en=f"acct_rina sent Tk 7,900 to acct_01070 at 14:13. {LIVE_NARRATIVE}")
    fixed = redact(d, validate(d, phone))
    assert [f.code for f in fixed.red_flags] == ["RF01"]
    assert fixed.narrative_en == "acct_rina sent Tk 7,900 to acct_01070 at 14:13."
    assert overclaims(fixed, phone) == []


SCRIPT = [call("path_between", source="acct_rina", target=SEED), call("device_safety", acct_id="acct_rina"), done("acct_rina's phone reported REMOTE_CONTROL (tc_02).")]
NO_MIN = dataclasses.replace(Settings(), min_tool_calls=0)


def investigate(world, script):
    events = []

    async def emit(e):
        events.append(e)

    return asyncio.run(run_investigation(world, FakeLLM(script), SEED, AS_OF, emit, "CZ-0001", settings=NO_MIN)), events


def test_the_writer_is_sent_back_once_and_a_qualified_retry_is_done(world, risk_mw):
    bad = case(red_flags=[rf04(LIVE_RF04)])
    llm_script = SCRIPT + [turn(bad), turn(case(red_flags=[rf04(GOOD_EN)]))]
    report, events = investigate(world, llm_script)
    validators = [e for e in events if e["type"] == "validator"]
    assert [v["pass"] for v in validators][:2] == [False, True]
    assert any(v["code"] == "app_safety_overclaim" for v in validators[0]["violations"])
    assert report.status == "done" and [f.text for f in report.draft.red_flags] == [GOOD_EN]


def test_an_overclaim_that_survives_the_retry_is_removed(world, risk_mw):
    bad = case(red_flags=[rf04(LIVE_RF04)], narrative_en=f"acct_rina sent Tk 7,900 to acct_01070 at 14:13. {LIVE_NARRATIVE}")
    report, _ = investigate(world, SCRIPT + [turn(bad), turn(bad)])
    assert report.status == "failed_after_retry"
    assert report.draft.red_flags == [] and "compromised" not in report.draft.narrative_en


# The prompts ---------------------------------------------------------------------------------------------------------
def test_the_writer_is_shown_the_qualified_rf04_in_both_languages_and_both_pass_the_check(phone):
    assert f'"{GOOD_EN}"' in prompts.WRITER_SYSTEM and f'"{GOOD_BN}"' in prompts.WRITER_SYSTEM
    d = case(red_flags=[rf04(GOOD_EN)], narrative_en=f"acct_rina sent Tk 7,900 to acct_01070 at 14:13. {GOOD_EN}.",
             narrative_bn=f"acct_rina ১৪:১৩-এ acct_01070-এ ৭,৯০০ টাকা পাঠান। {GOOD_BN}।")
    assert validate(d, phone) == []


def test_the_writer_is_shown_how_to_cite_the_banks_own_check_and_it_passes(world, risk_mw):
    led = ledger_with(world, SERVER_CAUTION, risk_mw)
    assert f'"{GOOD_SERVER_EN}"' in prompts.WRITER_SYSTEM and "source \"server\"" in prompts.INVESTIGATOR_SYSTEM
    assert "control the screen on" not in prompts.WRITER_SYSTEM and "Name only what the verdict lists" in prompts.WRITER_SYSTEM
    assert f'"{GOOD_SERVER_BN}"' in prompts.WRITER_SYSTEM
    assert validate(case(red_flags=[rf04(GOOD_SERVER_EN)], narrative_en=f"acct_rina sent Tk 7,900 to acct_01070 at 14:13. {GOOD_SERVER_EN}.",
                         narrative_bn=f"acct_rina ১৪:১৩-এ acct_01070-এ ৭,৯০০ টাকা পাঠান। {GOOD_SERVER_BN}।"), led) == []


def test_the_investigator_is_told_a_caution_or_phone_report_is_no_compromise():
    text = prompts.INVESTIGATOR_SYSTEM
    assert "CAUTION" in text and "compromised" in text and GOOD_EN in text
    assert "Bhorosha" not in text and "FinNest" in text


def test_the_tool_says_a_caution_or_phone_report_is_no_compromise():
    spec = next(t for t in tools.TOOL_SPECS if t["name"] == "device_safety")
    assert "CAUTION" in spec["description"] and "compromise" in spec["description"]
