"""FNA's T line for the App Safety phone fact SCREEN_CAPTURE fits line T's 12 words (2026-10-18).

Real Gemini (scripts/warning_phone_matrix.py, three rounds on gemini-3.5-flash-lite) dropped the SCREEN_CAPTURE/send_money
T line for shape in 3 of 3 warnings with the second-person glosses, and in 1 of 3 on main: 13 and 14 Bangla words, such as
"আপনার ফোনের কোনো কিছু স্ক্রিন শেয়ার করছে, তাই অন্য কেউ তা দেখতে পারে।". The model renders the plan's gloss word for word,
and the gloss had two clauses, "something on your phone is sharing your screen, so someone else may see it": the first
alone is already 7 to 9 Bangla words. Line R says the rest ("FinNest never asks you to share your screen with anyone").

These tests pin a gloss of one short clause that still says what App Safety found: the screen is being shared.
"""

from __future__ import annotations

import re

import pytest

from app.ledger import Ledger
from app.warnings import planner
from app.warnings.validator import validate, validate_en

LIVE_T = ["আপনার ফোনের কোনো কিছু স্ক্রিন শেয়ার করছে, তাই অন্য কেউ তা দেখতে পারে।",
          "আপনার ফোনের কোনো কিছু স্ক্রিন দেখাচ্ছে, তাই অন্য কেউ তা দেখতে পেতে পারে।",
          "আপনার ফোনের কোনো কিছু স্ক্রিন শেয়ার করে দিচ্ছে, তাই অন্য কেউ তা দেখতে পারে।"]
# A line that says only the first clause, as Gemini wrote it for SCREEN_CAPTURE/pin_reset in the same run.
ONE_CLAUSE_T = "আপনার ফোনের কোনো কিছু আপনার স্ক্রিন অন্য কারও সাথে শেয়ার করছে।"


def _means(pending="send_money") -> str:
    """What the model reads for this fact: the phone fact's gloss in the plan's own facts."""
    phone = planner.plan(Ledger(), pending, "likely", phone=("SCREEN_CAPTURE",)).facts()["phone"]
    assert [f["fact"] for f in phone] == ["SCREEN_CAPTURE"]
    return phone[0]["means"]


def test_the_screen_capture_gloss_is_one_clause():
    """A second clause ("so someone else may see it") is the one the model renders past the cap."""
    means = _means()
    assert not re.search(r"[,;:—]|\b(so|and|because|which|while)\b", means), means


def test_the_screen_capture_gloss_is_short():
    """REMOTE_CONTROL's 11-word gloss gives 9 or 10 Bangla words with its own example; with no example, SCREEN_CAPTURE's
    gloss gets the room of a short line T, not the cap."""
    assert len(_means().split()) <= 10, _means()


def test_the_screen_capture_gloss_still_says_what_app_safety_found():
    """App Safety saw the screen being captured (INTEGRITY_CAPTURING). The warning may not say recording (a tip-off word)
    and never that money was taken: it says the screen is being shared, to "you"."""
    means = _means()
    assert "sharing" in means and "your screen" in means, means
    assert not re.search(r"\b(record\w*|stole\w*|steal\w*|took|money|watch\w*|hack\w*)\b", means, re.IGNORECASE), means
    assert validate_en("T", means[0].upper() + means[1:] + ".").ok


@pytest.mark.parametrize("line", LIVE_T)
def test_the_live_two_clause_lines_are_over_the_cap(line):
    plan = planner.plan(Ledger(), "send_money", "likely", phone=("SCREEN_CAPTURE",))
    assert validate("T", line, plan, ()).rule == "shape"


@pytest.mark.parametrize("pending", ["send_money", "pin_reset"])
def test_a_one_clause_screen_capture_line_is_kept(pending):
    """The screen words are allowed only with a screen fact in the plan; this line fits and passes every rule."""
    plan = planner.plan(Ledger(), pending, "likely", phone=("SCREEN_CAPTURE",))
    assert validate("T", ONE_CLAUSE_T, plan, ()).ok, validate("T", ONE_CLAUSE_T, plan, ()).rule
