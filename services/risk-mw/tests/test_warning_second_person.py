"""FNA's warning speaks to the customer as "you", never about her (2026-10-18).

Live on risk-mw-00021-tln a delay with NEW_PAYEE_ABOVE_P95 and APP_SAFETY_CAUTION (phone fact REMOTE_CONTROL) got the
English lines "An app on her phone can see and control her screen." and "FinNest never asks anyone to see or control her
screen." The Bangla said আপনার. Both English lines are the plan's own REMOTE_CONTROL gloss and rule, word for word: the
facts, and the instruction around them, named the customer in the third person, and the model copied them.

These tests pin the fix: the instruction says every line speaks to the customer directly, the facts the plan hands the
model say "you", and the validator drops a line that still names her in the third person, so the repair policy treats it
like any other failed line.
"""

from __future__ import annotations

import re

import pytest

from app import warnings
from app.ledger import Ledger
from app.settings import Settings, get_settings
from app.warnings import composer, planner
from app.warnings.validator import validate, validate_en

LIVE_T = "An app on her phone can see and control her screen."
LIVE_R = "FinNest never asks anyone to see or control her screen."
GENDERED = re.compile(r"\b(she|her|hers|herself|he|him|his|himself)\b", re.IGNORECASE)


def _plan(pending="send_money", **facts):
    return planner.plan(Ledger(), pending, "likely", **facts)


# --- the instruction and the facts ------------------------------------------------------------------------------------


def test_the_prompt_says_every_line_speaks_to_the_customer_directly():
    text = composer.system_prompt(Settings())
    assert "speaks to the customer directly" in text
    assert "আপনি" in text and "আপনার" in text and '"you"' in text and '"your"' in text


def test_the_prompt_never_names_the_customer_in_the_third_person():
    """Outside the rule that lists the pronouns it bans, the instruction calls her "the customer", so it has no "her" for
    the model to copy. NOT_HER_PATTERN is a fact's code, not a word."""
    text = composer.system_prompt(Settings())
    rest = "\n\n".join(p for p in text.split("\n\n") if "third person" not in p)
    assert not GENDERED.search(rest), GENDERED.findall(rest)


FACT_TEXTS = [(f"{name}:{fact}", text.format(brand="FinNest"))
              for name, table in (("tactic", planner.TACTIC_GLOSS), ("phone", planner.PHONE_GLOSS), ("phone_rule", planner.PHONE_RULE),
                                  ("behaviour", planner.BEHAVIOUR_GLOSS), ("hold", planner.HOLD_GLOSS), ("hold_rule", planner.HOLD_RULE))
              for fact, text in table.items()]


@pytest.mark.parametrize("name, text", FACT_TEXTS)
def test_every_fact_the_plan_hands_the_model_says_you(name, text):
    assert not GENDERED.search(text), (name, text)
    assert not re.search(r"\btheir\b", text), (name, text)


def test_the_live_facts_now_read_in_the_second_person():
    phone = _plan(phone=("REMOTE_CONTROL",)).facts()["phone"][0]
    assert phone["means"] == "an app on your phone can see and control your screen"
    assert phone["rule"] == "FinNest never asks anyone to see or control your screen"


def test_the_mule_gloss_names_the_receiving_account_and_nobody_paying_it():
    """Real Gemini, 2026-10-18 (scripts/warning_phone_matrix.py, three rounds): "the account you are paying" came back as a
    relative clause ("যে অ্যাকাউন্টে টাকা দিচ্ছেন, সেটি ...") of 13 to 16 words, over line T's 12, in 4 of 6 PAYEE_MULE
    warnings. "The account she is paying" was never rendered at all: every line was the example's 11 words, প্রাপকের
    অ্যাকাউন্টটা (the receiving account). The receiving account needs no pronoun."""
    gloss = planner.HOLD_GLOSS["PAYEE_MULE"]
    assert "the receiving account" in gloss and not re.search(r"\b(you|your)\b", gloss)


# --- the validator: English ----------------------------------------------------------------------------------------------


@pytest.mark.parametrize("text", [
    LIVE_T,
    LIVE_R,
    "She is on a phone call while doing this.",
    "The SIM for his phone number was changed recently.",
    "Someone may be telling him what to press.",
    "Hers is the first payment to this person.",
    "An app on their phone can read their messages.",
    "The customer's SIM was changed recently.",
    "The user is changing the PIN during a phone call.",
])
def test_an_english_line_that_names_the_customer_in_the_third_person_fails(text):
    assert validate_en("T", text).rule == "en:person"


@pytest.mark.parametrize("text", [
    "An app on your phone can see and control your screen.",
    "FinNest never asks anyone to see or control your screen.",
    "FinNest never asks anyone for their PIN.",                       # the generic "their" after anyone
    "Someone on the call may see your screen.",
    "The caller is asking for the code that came in your message.",
    "Don't tell anyone the code, even if they say they are from the bank.",   # "they" is the caller
    "A real bank never asks for this code; they never need it.",      # "they" is the bank
    "Other apps on this phone can see the screen, so check them there.",
    "Press the app's button to reach the customer care team.",
    "Hang up, then press the app's 'Call FinNest' button.",
])
def test_legitimate_english_wording_still_passes(text):
    assert validate_en("T", text).ok, validate_en("T", text).rule


# --- the validator: Bangla -----------------------------------------------------------------------------------------------


@pytest.mark.parametrize("line, facts", [
    ("ওনার ফোনের কোনো অ্যাপ স্ক্রিন দেখতে ও চালাতে পারে।", {"phone": ("REMOTE_CONTROL",)}),
    ("তাঁর ফোনের কোনো অ্যাপ স্ক্রিন দেখতে ও চালাতে পারে।", {"phone": ("REMOTE_CONTROL",)}),
    ("তার স্ক্রিন অন্য কেউ দেখতে পারে।", {"phone": ("SCREEN_CAPTURE",)}),
    ("উনার মেসেজ একটি অ্যাপ পড়তে পারে।", {"phone": ("READS_MESSAGES",)}),
    ("তাঁর নম্বরের সিমটা সম্প্রতি বদলানো হয়েছে।", {"hold": ("SIM_CHANGED",)}),
])
def test_a_bangla_line_that_gives_her_phone_to_a_third_person_fails(line, facts):
    assert validate("T", line, _plan(**facts), ()).rule == "person"


@pytest.mark.parametrize("role, line, facts", [
    ("T", "আপনার ফোনের কোনো অ্যাপ স্ক্রিন দেখতে ও চালাতে পারে।", {"phone": ("REMOTE_CONTROL",)}),
    ("X", "টাকা পাঠাবেন না, তার পর অ্যাপের ‘ফিননেস্টে কল করুন’ বোতাম চাপুন।", {}),   # তার পর: after that
    ("A", "তার আগে একটু থামুন।", {}),                                                  # তার আগে: before that
    ("T", "এঁকে আগে কখনো টাকা পাঠাননি, আর অঙ্কটাও স্বাভাবিকের চেয়ে বেশি।", {"hold": ("NEW_PAYEE_LARGE",)}),
])
def test_legitimate_bangla_wording_still_passes(role, line, facts):
    assert validate(role, line, _plan(**facts), ()).ok, validate(role, line, _plan(**facts), ()).rule


# --- the repair policy ---------------------------------------------------------------------------------------------------


class _Model:
    """composer._model_text stand-in: each call returns the next reply."""

    def __init__(self, *replies):
        self.replies, self.calls = list(replies), []

    def __call__(self, contents, settings, temperature, timeout_s, spend=None):
        self.calls.append({"contents": contents, "temperature": temperature})
        return iter([self.replies.pop(0) if self.replies else ""])


def _example() -> dict[str, tuple[str, str]]:
    marker = "Example, for a plan with the phone fact REMOTE_CONTROL"
    block = composer.system_prompt(get_settings()).split(marker, 1)[1].split("\n\nExample", 1)[0]
    return {role: (bn, en) for role, bn, en in composer.parse([block], order=("A", "T", "R", "X"))}


def _text(lines: dict) -> str:
    return "".join(f"{role}| {bn} || {en}\n" for role, (bn, en) in lines.items())


def _generate(monkeypatch, *replies):
    fake = _Model(*replies)
    monkeypatch.setattr(composer, "_model_text", fake)
    return warnings.generate(_plan(phone=("REMOTE_CONTROL",)), (), get_settings()), fake


def test_the_live_t_and_r_are_dropped_and_the_warning_keeps_its_actions(monkeypatch):
    good = _example()
    lines = {**good, "T": (good["T"][0], LIVE_T), "R": (good["R"][0], LIVE_R)}
    w, _ = _generate(monkeypatch, _text(lines))
    assert [line.role for line in w.lines] == ["A", "X"]
    assert w.dropped == (("T", "en:person"), ("R", "en:person"))


def test_a_third_person_a_gets_its_one_regeneration(monkeypatch):
    good = _example()
    bad_a = (good["A"][0], "Stop for a moment; she should not send the money now.")
    w, fake = _generate(monkeypatch, _text({**good, "A": bad_a}), "A| " + " || ".join(good["A"]) + "\n")
    assert w.regenerated == ("A",) and ("A", "en:person") in w.dropped
    assert w.lines[0].text_en == good["A"][1] and fake.calls[1]["temperature"] == 0


def test_a_third_person_bangla_t_is_dropped(monkeypatch):
    good = _example()
    bad_t = ("ওনার ফোনের কোনো অ্যাপ স্ক্রিন দেখতে ও চালাতে পারে।", "An app on your phone can see and control the screen.")
    w, _ = _generate(monkeypatch, _text({**good, "T": bad_t}))
    assert [line.role for line in w.lines] == ["A", "R", "X"] and w.dropped == (("T", "person"),)
