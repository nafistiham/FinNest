"""FNA's warning when the App Safety Check found something (2026-10-18).

A real-Gemini run of the 2026-10-17 prompt over every phone fact (7 facts x send/PIN reset, plus mixed plans) dropped lines
in 7 of 19 warnings, and kept lines that said the wrong thing:
- "রেকর্ড" in the screen-capture gloss is a tip-off word, so that fact's T and R lines were always dropped;
- a PIN-reset hold had no words for "don't change the PIN", so the model invented "পিন ঠিক করার কাজটা বন্ধ রাখুন";
- R lines claimed what a bank does not do ("the bank never lets another app read your messages"), said nothing
  ("FinNest makes sure."), or borrowed the behaviour rule with no behaviour fact in the plan;
- every X line pointed at the call button, although the next step for a risky app is the app's own phone-safety page.
These tests pin the fixes: a rule per phone fact, glosses without banned words, the PIN words, and the phone-safety path.
"""

from __future__ import annotations

import re

import pytest

from app.ledger import Ledger
from app.settings import Settings
from app.warnings import composer, planner
from app.warnings.validator import validate, validate_en


def _plan(pending="send_money", phone=(), behaviour=()):
    return planner.plan(Ledger(), pending, "likely", phone=phone, behaviour=behaviour)


def test_every_phone_fact_has_a_rule_and_the_plan_carries_it():
    assert set(planner.PHONE_RULE) == set(planner.PHONE_FACTS)
    phone = _plan(phone=("READS_MESSAGES", "REMOTE_CONTROL")).facts()["phone"]
    assert [f["fact"] for f in phone] == ["READS_MESSAGES", "REMOTE_CONTROL"]
    assert all(f["means"] and f["rule"] for f in phone)
    assert "FinNest" in phone[0]["rule"] and "{" not in phone[0]["rule"]


# Words the model copies from a gloss or a rule into its English rendering, which the validator then drops: "recording"
# and "system" are tip-offs, and "Store" is one letter from "score" (live, 2026-10-18: every "Play Store" line dropped).
BANNED_EN = re.compile(r"\b(record\w*|system|install\w*|download\w*|police|score\w*|store|detect\w*|ai|protection\w*)\b",
                       re.IGNORECASE)


@pytest.mark.parametrize("fact", planner.PHONE_FACTS)
def test_no_gloss_or_rule_invites_a_banned_word(fact):
    for text in (planner.PHONE_GLOSS[fact], planner.phone_rule(fact, "FinNest")):
        assert not BANNED_EN.search(text), (fact, text)
        assert validate_en("T", text[0].upper() + text[1:] + ".").ok, (fact, text)   # the validator's own bans, fuzzy ones too


@pytest.mark.parametrize("fact", planner.PHONE_FACTS)
def test_every_rule_fits_line_r(fact):
    # Line R holds at most 12 Bangla words; a rule of more than 12 English words rarely fits (FAKE_APP's 15 never did).
    assert len(planner.phone_rule(fact, "FinNest").split()) <= 12


def test_a_phone_plan_points_at_phone_safety_and_the_others_at_the_call_button():
    phone = _plan(phone=("FAKE_APP",))
    assert phone.safe_path == planner.OPEN_SAFETY
    words = phone.facts()["safe_path"]
    assert "ফোনের নিরাপত্তা" in words["bn"] and "Phone safety" in words["en"]
    assert _plan().safe_path == planner.CALL_BANK
    assert _plan(behaviour=("NOT_HER_PATTERN",)).safe_path == planner.CALL_BANK


SAFETY_X = "টাকা পাঠাবেন না, তারপর অ্যাপের ‘ফোনের নিরাপত্তা’ পাতাটা দেখে নিন।"


def test_opening_phone_safety_is_an_action_only_with_phone_facts():
    assert validate("X", SAFETY_X, _plan(phone=("REMOTE_CONTROL",)), ()).ok
    assert validate("X", SAFETY_X, _plan(), ()).rule == "action"
    assert validate_en("X", "Don't send the money, then open 'Phone safety' in the app.").ok


@pytest.mark.parametrize("line", [
    "টাকা পাঠাবেন না, তারপর এই লিংকে ফোনের নিরাপত্তা দেখে নিন।",
    "টাকা পাঠাবেন না, তারপর এই নম্বরে ফোনের নিরাপত্তা দেখে নিন।",
    "টাকা পাঠাবেন না, তারপর নতুন অ্যাপ নামিয়ে ফোনের নিরাপত্তা দেখে নিন।",
])
def test_phone_safety_never_covers_a_link_a_number_or_another_app(line):
    assert not validate("X", line, _plan(phone=("REMOTE_CONTROL",)), ()).ok


PIN_A = "একটু থামুন, এখন পিন বদল করবেন না।"


def test_dont_change_the_pin_is_allowed_on_a_pin_reset_hold_only():
    assert validate("A", PIN_A, _plan("pin_reset", phone=("REMOTE_CONTROL",)), ()).ok
    assert validate("A", PIN_A, _plan("send_money", phone=("REMOTE_CONTROL",)), ()).rule == "ledger"
    assert validate_en("A", "Stop for a moment; don't change the PIN now.").ok


def test_the_prompt_guides_line_r_and_the_new_actions():
    text = composer.system_prompt(Settings())
    assert "the first phone fact's rule" in text
    assert "only when the plan has behaviour facts and no phone facts" in text
    assert "এখন পিন বদল করবেন না" in text and "ফোনের নিরাপত্তা" in text
    assert "outside this app" in text   # opening the app's own page is allowed; opening anything else is not


def _example(prompt: str, marker: str) -> dict[str, tuple[str, str]]:
    block = prompt.split(marker, 1)[1].split("\n\nExample", 1)[0]   # this example only, not the ones after it
    return {role: (bn, en) for role, bn, en in composer.parse([block], order=("A", "T", "R", "X"))}


@pytest.mark.parametrize("marker, pending, phone", [
    ("Example, for a plan with the phone fact REMOTE_CONTROL", "send_money", ("REMOTE_CONTROL",)),
    ("Example, for a plan with the phone fact READS_MESSAGES", "pin_reset", ("READS_MESSAGES",)),
])
def test_each_phone_example_validates_against_its_own_plan(marker, pending, phone):
    lines = _example(composer.system_prompt(Settings()), marker)
    assert set(lines) == {"A", "T", "R", "X"}
    p = _plan(pending, phone=phone)
    for role, (bn, en) in lines.items():
        assert validate(role, bn, p, ()).ok, (role, bn, validate(role, bn, p, ()).rule)
        assert validate_en(role, en).ok, (role, en)
    assert "ফোনের নিরাপত্তা" in lines["X"][0]


# --- final review fixes (2026-10-18) ----------------------------------------------------------------------------------
# Critical 1: the phone-safety action matched any instruction whose clause named নিরাপত্তা and অ্যাপ/ফোন, so "turn off
# phone safety" or "install an app for phone safety" passed on any plan with phone facts. Only the fixed words count now.

@pytest.mark.parametrize("line", [
    "ফোনের নিরাপত্তা বন্ধ করে নিন।",
    "ফোনের নিরাপত্তার জন্য অ্যাপ ইনস্টল করে নিন।",
    "ফোনের নিরাপত্তা দেখতে স্ক্রিন শেয়ার করে নিন।",
    "যিনি ফোন করেছেন তাকে দিয়ে ফোনের নিরাপত্তা দেখে নিন।",
    "ওয়েবসাইটে ফোনের নিরাপত্তা খুলুন।",
    "অন্য অ্যাপে ফোনের নিরাপত্তা দেখে নিন।",
    "ফোনের নিরাপত্তার জন্য ফোনটা রিসেট করে নিন।",
    "ফোনের নিরাপত্তার জন্য অ্যাপটা মুছে নিন।",
])
@pytest.mark.parametrize("role", ["A", "X"])
def test_phone_safety_covers_only_its_own_words(line, role):
    assert not validate(role, line, _plan(phone=("REMOTE_CONTROL",)), ()).ok


@pytest.mark.parametrize("line", [
    "টাকা পাঠাবেন না, তারপর অ্যাপের ‘ফোনের নিরাপত্তা’ পাতাটা দেখে নিন।",
    "এখন অ্যাপের ‘ফোনের নিরাপত্তা’ পাতাটা খুলুন।",
    "টাকা পাঠাবেন না, তারপর অ্যাপে ফোনের নিরাপত্তা দেখে নিন।",
])
def test_the_phone_safety_words_still_pass(line):
    assert validate("X", line, _plan(phone=("REMOTE_CONTROL",)), ()).ok


@pytest.mark.parametrize("text, ok", [
    ("Don't send the money, then open 'Phone safety' in the app.", True),
    ("Your phone's safety settings are switched off.", True),
    ("Turn off phone safety.", False),
    ("Open phone safety on the website.", False),
    ("Share your screen to check phone safety.", False),
    ("Open phone safety in another app.", False),
])
def test_the_english_rendering_of_phone_safety_is_checked_too(text, ok):
    assert validate_en("X", text).ok is ok


# Important 4: with a caller's request in the plan (pasted into the assistant), the call's rule and the call button stay;
# phone facts take line R and the safe path only when they are all there is.

def _asked(**phone):
    ledger = Ledger(asks=("otp",))
    return planner.plan(ledger, "send_money", "likely", **phone)


def test_a_code_request_keeps_the_call_button_even_with_phone_facts():
    assert _asked(phone=("FAKE_LOAN_APP",)).safe_path == planner.CALL_BANK
    assert _asked().safe_path == planner.CALL_BANK
    assert _plan(phone=("FAKE_LOAN_APP",)).safe_path == planner.OPEN_SAFETY


def test_the_prompt_gives_line_r_to_phone_facts_only_without_a_request():
    text = composer.system_prompt(Settings())
    assert "the plan has phone facts and no tactics or ask" in text
