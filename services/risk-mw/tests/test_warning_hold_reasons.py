"""FNA's warning says why the app held the payment when nothing else is known (2026-10-18).

With speech to text off (2026-10-17), most holds have no call tactics, no App Safety phone facts and no behaviour facts:
the demo's DEST_MULE_RISK hold (Rina paying acct_01070), SIM_CHANGED_24H holds, NEW_PAYEE_ABOVE_P95 delays. On real
Gemini such a plan got empty lines (scripts/warning_phone_matrix.py "NOTHING/send", 2026-10-18): T "প্রতারণার মতো লাগছে।"
and R "আসল ব্যাংক বা অফিস কখনো এমন কথা বলে না।" (a real bank or office never says such things), about nothing.

The hold's own reasons become closed-set hold facts, each with a gloss for line T and a true rule for line R, read at
/v1/intervene from the hold's record (or the trigger the app named), never on the scoring path. Only codes reach the
model: no account id, amount, score or name.
"""

from __future__ import annotations

import re

import pytest

from app import state
from app import warnings as apa_warnings
from app.ledger import Ledger
from app.settings import Settings
from app.warnings import composer, planner, signals
from app.warnings.validator import validate, validate_en


def _plan(pending="send_money", hold=(), **extra):
    return planner.plan(extra.pop("ledger", Ledger()), pending, "likely", hold=hold, **extra)


# --- the facts -------------------------------------------------------------------------------------------------------


def test_every_hold_fact_has_a_gloss_and_a_rule_and_the_plan_carries_them():
    assert set(planner.HOLD_GLOSS) == set(planner.HOLD_RULE) == set(planner.HOLD_FACTS)
    assert {"PAYEE_MULE", "SIM_CHANGED", "NEW_PAYEE_LARGE", "CALL_ON"} <= set(planner.HOLD_FACTS)
    hold = _plan(hold=("PAYEE_MULE", "NEW_PAYEE_LARGE")).facts()["hold"]
    assert [f["fact"] for f in hold] == ["PAYEE_MULE", "NEW_PAYEE_LARGE"]
    assert all(f["means"] and f["rule"] for f in hold)
    assert "FinNest" in hold[0]["rule"] and "{" not in hold[0]["rule"]


def test_a_plan_without_hold_facts_reads_and_hashes_as_before():
    ledger = Ledger()
    assert "hold" not in _plan().facts()
    assert planner.key(ledger, "send_money", "likely") == planner.key(ledger, "send_money", "likely", hold=())
    mule = planner.key(ledger, "send_money", "likely", hold=("PAYEE_MULE",))
    assert mule != planner.key(ledger, "send_money", "likely")
    assert mule != planner.key(ledger, "send_money", "likely", hold=("SIM_CHANGED",))


def test_an_unknown_hold_code_is_dropped():
    assert _plan(hold=("DEST_MULE_RISK", "NOPE", "PAYEE_MULE")).hold == ("PAYEE_MULE",)


@pytest.mark.parametrize("extra", [
    {"ledger": Ledger(asks=("otp",))},             # a caller's request pasted into the assistant
    {"phone": ("REMOTE_CONTROL",)},                # App Safety found something
    {"behaviour": ("NOT_HER_PATTERN",)},           # the behaviour model did
])
def test_hold_facts_speak_only_when_nothing_else_is_known(extra):
    """The call's, the phone's and the behaviour model's facts already have their own T and R; a call's plan and key stay
    as they were, so a pre-rendered call warning still matches its hold."""
    ledger = extra.get("ledger", Ledger())
    p = _plan(hold=("PAYEE_MULE",), **dict(extra))
    assert p.hold == () and "hold" not in p.facts()
    rest = {k: v for k, v in extra.items() if k != "ledger"}
    assert (planner.key(ledger, "send_money", "likely", hold=("PAYEE_MULE",), **rest)
            == planner.key(ledger, "send_money", "likely", **rest))


def test_a_hold_fact_keeps_the_call_button_as_the_safe_path():
    assert _plan(hold=("SIM_CHANGED",)).safe_path == planner.CALL_BANK
    assert _plan(hold=("SIM_CHANGED",), simple=True).safe_path == "talk_family"


def test_a_call_that_is_on_makes_hang_up_the_action_unless_money_is_waiting():
    assert _plan("pin_reset", hold=("CALL_ON",)).action == "hang_up"
    assert _plan("pin_reset").action == "pause"
    assert _plan("send_money", hold=("CALL_ON",)).action == "dont_send"
    assert (planner.key(Ledger(), "pin_reset", "likely", hold=("CALL_ON",))
            != planner.key(Ledger(), "pin_reset", "likely", hold=("SIM_CHANGED",)))


def test_the_prompt_names_no_account_amount_score_or_person():
    p = _plan(hold=("PAYEE_MULE", "NEW_PAYEE_LARGE"))
    text = p.to_prompt()
    # warning_number is the plan's only number; no amount (three or more digits) and no score (a decimal)
    assert not re.search(r"\d{3,}|\d\.\d", text) and "acct" not in text.lower() and "score" not in text.lower()
    assert "Rina" not in text and "রিনা" not in text


# Words the model copies from a gloss or a rule into its English rendering, which the validator then drops (see
# tests/test_warning_phone_prompt.py): tip-offs, and "mule", "case" and "stolen" in the hold's own vocabulary.
BANNED_EN = re.compile(r"\b(record\w*|system|install\w*|download\w*|police|score\w*|store|detect\w*|ai|mule\w*|case\w*|"
                       r"fraudster|criminal|stolen|ring)\b", re.IGNORECASE)


@pytest.mark.parametrize("fact", planner.HOLD_FACTS)
def test_no_hold_gloss_or_rule_invites_a_banned_word(fact):
    for text in (planner.HOLD_GLOSS[fact], planner.hold_rule(fact, "FinNest")):
        assert not BANNED_EN.search(text), (fact, text)
        assert validate_en("T", text[0].upper() + text[1:] + ".").ok, (fact, text)


@pytest.mark.parametrize("fact", planner.HOLD_FACTS)
def test_every_hold_rule_fits_line_r(fact):
    assert len(planner.hold_rule(fact, "FinNest").split()) <= 12


NEW_PAYEE_LINE = "এটা নতুন প্রাপকের কাছে আপনার স্বাভাবিকের চেয়ে বেশি টাকা।"


def test_a_first_large_payment_licenses_the_new_payee_words_and_nothing_else_does():
    """The delay's own fact is a send to a new payee; the pending action is send_money, so without the fact a line
    naming a new payee is not in the plan."""
    assert validate("T", NEW_PAYEE_LINE, _plan(hold=("NEW_PAYEE_LARGE",)), ()).ok
    assert validate("T", NEW_PAYEE_LINE, _plan(hold=("PAYEE_MULE",)), ()).rule == "ledger"
    assert validate("T", NEW_PAYEE_LINE, _plan(), ()).rule == "ledger"


# --- where they come from: the hold's reasons at /v1/intervene -------------------------------------------------------


@pytest.mark.parametrize(("codes", "trigger", "facts"), [
    (["DEST_MULE_RISK"], "dest_mule_risk", ("PAYEE_MULE",)),
    (["SIM_CHANGED_24H"], "sim_swap", ("SIM_CHANGED",)),
    (["NEW_PAYEE_ABOVE_P95"], "new_payee_high_amount", ("NEW_PAYEE_LARGE",)),
    (["CALL_ACTIVE_NON_CONTACT"], "call_active", ("CALL_ON",)),
    (["NEW_PAYEE_ABOVE_P95", "DEST_MULE_RISK"], "dest_mule_risk", ("PAYEE_MULE", "NEW_PAYEE_LARGE")),   # most telling first
    (["SCAM_CONVERSATION", "MODEL_RISK"], "scam_conversation", ()),   # reasons with no fact of their own
])
def test_the_holds_recorded_reasons_become_hold_facts(codes, trigger, facts):
    assert signals.hold_facts(codes, trigger) == facts


def test_at_most_two_hold_facts():
    codes = ["NEW_PAYEE_ABOVE_P95", "SIM_CHANGED_24H", "DEST_MULE_RISK", "CALL_ACTIVE_NON_CONTACT"]
    assert len(signals.hold_facts(codes, None)) == signals.MAX_HOLD_FACTS == 2


@pytest.mark.parametrize(("trigger", "facts"), [
    ("dest_mule_risk", ("PAYEE_MULE",)),           # the app lower-cases a reason code it has no trigger name for
    ("DEST_MULE_RISK", ("PAYEE_MULE",)),
    ("mule", ("PAYEE_MULE",)),                     # app.apa.LEGACY_TRIGGERS
    ("sim_swap", ("SIM_CHANGED",)),
    ("new_payee_high_amount", ("NEW_PAYEE_LARGE",)),
    ("call_active", ("CALL_ON",)),
    ("generic", ()),
    ("", ()),
])
def test_without_a_record_the_trigger_names_the_reason(trigger, facts):
    """The app sends no intervention or txn id until its request flag is on, so the trigger is all the server has."""
    assert signals.hold_facts(None, trigger) == facts
    assert signals.hold_facts([], trigger) == facts


def test_the_servers_record_wins_over_the_trigger():
    assert signals.hold_facts(["DEST_MULE_RISK"], "sim_swap") == ("PAYEE_MULE",)


@pytest.fixture
def captured(monkeypatch):
    plans = []

    def fake_generate(p, caller_turns, settings, last_good=None, offline=False):
        plans.append(p)
        return composer.Warning()
    monkeypatch.setattr(apa_warnings, "generate", fake_generate)
    return plans


def test_compose_writes_from_the_hold_facts(captured):
    out = apa_warnings.compose("rina", "rina", None, "send_money", Settings(), hold=("PAYEE_MULE",))
    assert captured[0].hold == ("PAYEE_MULE",)
    assert out.ledger_hash == planner.key(Ledger(), "send_money", "possible", hold=("PAYEE_MULE",))


HELD = {"id": "iv-mule", "user_id": "rina", "session_id": None, "decision": "hold", "status": "held",
        "txn": {"type": "send_money", "amount_bdt": 7900, "to_account": "acct_01070"}, "reason_codes": ["DEST_MULE_RISK"],
        "top_reason": "DEST_MULE_RISK", "action_types": ["trusted_contact_check"]}


def test_intervene_reads_the_holds_reasons_from_its_record(client, captured):
    state.store().set("interventions", "iv-mule", dict(HELD))
    body = {"user_id": "rina", "trigger": "generic", "intervention_id": "iv-mule",
            "txn": {"type": "send_money", "amount_bdt": 7900, "to_account": "acct_01070"}}
    assert client.post("/v1/intervene", json=body).status_code == 200
    assert captured[-1].hold == ("PAYEE_MULE",)
    assert "acct_01070" not in captured[-1].to_prompt() and "7900" not in captured[-1].to_prompt()


def test_intervene_without_a_record_reads_the_trigger(client, captured):
    body = {"user_id": "rina", "trigger": "sim_swap", "txn": {"type": "pin_reset"}}
    assert client.post("/v1/intervene", json=body).status_code == 200
    assert captured[-1].hold == ("SIM_CHANGED",)


def test_apa_why_reads_the_holds_reasons_too(client, captured):
    state.store().set("interventions", "iv-mule", dict(HELD))
    body = {"user_id": "rina", "trigger": "generic", "intervention_id": "iv-mule"}
    assert client.post("/v1/apa/why", json=body).status_code == 200
    assert captured[-1].hold == ("PAYEE_MULE",)


# --- the composer's instruction --------------------------------------------------------------------------------------


def test_the_prompt_guides_lines_t_and_r_for_hold_facts():
    text = composer.system_prompt(Settings())
    assert "hold facts" in text
    assert "the first hold fact's" in text
    assert "never say the receiving account" in text.lower() or "never say that the receiving account" in text.lower()


def _example(prompt: str, marker: str) -> dict[str, tuple[str, str]]:
    block = prompt.split(marker, 1)[1].split("\n\nExample", 1)[0]   # this example only, not the ones after it
    return {role: (bn, en) for role, bn, en in composer.parse([block], order=("A", "T", "R", "X"))}


@pytest.mark.parametrize("marker, pending, hold", [
    ("Example, for a plan with the hold fact PAYEE_MULE", "send_money", ("PAYEE_MULE",)),
    ("Example, for a plan with the hold fact SIM_CHANGED", "pin_reset", ("SIM_CHANGED",)),
    ("Example, for a plan with the hold fact CALL_ON", "pin_reset", ("CALL_ON",)),
    ("Example, for a plan with the hold fact NEW_PAYEE_LARGE", "send_money", ("NEW_PAYEE_LARGE",)),
])
def test_each_hold_example_validates_against_its_own_plan(marker, pending, hold):
    settings = Settings()
    lines = _example(composer.system_prompt(settings), marker)
    assert set(lines) == {"A", "T", "R", "X"}
    p = _plan(pending, hold=hold)
    for role, (bn, en) in lines.items():
        assert validate(role, bn, p, ()).ok, (role, bn, validate(role, bn, p, ()).rule)
        assert validate_en(role, en).ok, (role, en)
    assert settings.brand_bn in lines["R"][0]                  # the rule is FinNest's own
    assert settings.call_button_bn in lines["X"][0]            # and the safe path is the app's call button


def test_the_call_example_hangs_up_where_the_sim_example_only_stops():
    """Live on 2026-10-18 a CALL_ON PIN-reset warning said "don't change the PIN" in A and X and never "hang up", the
    plan's primary action: the only PIN-reset examples stopped. The two hold examples show both."""
    text = composer.system_prompt(Settings())
    call = _example(text, "Example, for a plan with the hold fact CALL_ON")
    sim = _example(text, "Example, for a plan with the hold fact SIM_CHANGED")
    assert all("কলটা কেটে দিন" in call[role][0] for role in ("A", "X"))
    assert not any("কলটা কেটে দিন" in sim[role][0] for role in ("A", "X"))


def test_a_plan_with_no_facts_at_all_says_the_app_is_checking():
    """Live on 2026-10-18 a hold with no facts ("NOTHING/send") still got R lines about nothing ("FinNest never creates
    such a situation"): with nothing known, T says the app paused it to check and R that FinNest checks first."""
    text = composer.system_prompt(Settings())
    assert "no tactics, ask, phone facts, behaviour facts or hold facts" in text
    assert "checks first when something looks unusual" in text


def test_the_first_large_payment_keeps_both_its_facts_in_a_short_line():
    """Live on 2026-10-18 one T line ran "first payment to this person" and "more than she usually sends" together into
    "the first time such a large amount is sent to anyone", which is not what the rule found; a gloss in two full clauses
    made T lines too long for their 12 words (2 of 3 dropped). A short gloss and a worked example keep both facts."""
    gloss = planner.HOLD_GLOSS["NEW_PAYEE_LARGE"]
    assert "first payment to this person" in gloss and "more than you usually send" in gloss and len(gloss.split()) <= 12
    t = _example(composer.system_prompt(Settings()), "Example, for a plan with the hold fact NEW_PAYEE_LARGE")["T"][0]
    assert "আগে কখনো" in t and "স্বাভাবিকের চেয়ে বেশি" in t   # never before, and more than usual
