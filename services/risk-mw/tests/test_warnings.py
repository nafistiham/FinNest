"""Apa's warnings are planned by code, phrased by Flash-Lite and checked by code; no fixed line anywhere.

Every model call here is a fake (composer._model_text). The Bangla lines are a non-native draft used as test data.
"""

import json
import time

import pytest

from app import warnings
from app.ledger import Evidence, Ledger
from app.warnings import composer, planner, validator

QUOTE = "আপনার ফোনে একটা কোড গেছে সেটা এখনই বলুন"
CALLER = (QUOTE, "আমি ব্যাংকের হেড অফিস থেকে বলছি, আপনার একাউন্ট বন্ধ হয়ে যাবে")


def _ledger(**over) -> Ledger:
    base = dict(tactics={"CREDENTIAL_REQUEST": Evidence("CREDENTIAL_REQUEST", QUOTE, 2),
                         "AUTHORITY_IMPERSONATION": Evidence("AUTHORITY_IMPERSONATION", CALLER[1], 0),
                         "URGENCY_THREAT": Evidence("URGENCY_THREAT", "বন্ধ হয়ে যাবে", 0)},
                claimed_identity="bank_mfs_staff", asks=("otp",))
    return Ledger(**{**base, **over})


def _plan(**over) -> planner.Plan:
    args = dict(ledger=_ledger(), pending_action="pin_reset", band="likely", address="রহিমা")
    return warnings.plan(**{**args, **over})


# --- the planner ------------------------------------------------------------------------------------------------------


def test_the_plan_holds_facts_from_the_ledger_and_never_the_callers_words():
    p = _plan()
    assert p.tactics == ("CREDENTIAL_REQUEST", "AUTHORITY_IMPERSONATION") and p.ask == "otp" and p.identity == "bank_mfs_staff"
    assert (p.pending_action, p.band, p.address, p.simple, p.index) == ("pin_reset", "likely", "রহিমা", False, 0)
    prompt = p.to_prompt()
    assert all(quote not in prompt for quote in (*CALLER, "বন্ধ হয়ে যাবে")) and "হেড অফিস" not in prompt
    assert json.loads(prompt)["identity_class"] == "bank_mfs_staff"
    assert p.known == frozenset({"CREDENTIAL_REQUEST", "AUTHORITY_IMPERSONATION", "URGENCY_THREAT", "otp"})


def test_the_plan_takes_the_most_dangerous_ask_and_at_most_two_tactics():
    ledger = _ledger(tactics={t: Evidence(t, "x", 0) for t in ("SECRECY_ISOLATION", "PAYMENT_REDIRECTION", "URGENCY_THREAT",
                                                                 "CREDENTIAL_REQUEST")}, asks=("secrecy", "send_money", "pin"))
    p = warnings.plan(ledger, "send_money", "almost_certain")
    assert p.ask == "pin" and p.tactics == ("CREDENTIAL_REQUEST", "PAYMENT_REDIRECTION")
    assert warnings.plan(Ledger(), None, "possible").tactics == () and warnings.plan(Ledger(), None, "possible").ask == "none"


def test_code_chooses_the_action_and_the_safe_path():
    assert _plan().action == "dont_tell_code" and _plan().safe_path == "call_bank"
    money = warnings.plan(_ledger(asks=()), "send_money", "likely")
    assert money.action == "dont_send"
    relative = warnings.plan(_ledger(claimed_identity="relative", asks=()), None, "likely")
    assert relative.action == "hang_up" and relative.safe_path == "talk_family"
    assert warnings.plan(Ledger(), "pin_reset", "possible").action == "pause"
    assert warnings.plan(_ledger(), None, "likely", simple=True).safe_path == "talk_family"


@pytest.mark.parametrize("address", ["Rahima", "রহিমা 01711", "রহিমা৫", "এক দুই তিন চার", "র" * 30, "", "  "])
def test_an_address_that_is_not_a_short_bangla_name_is_dropped(address):
    assert _plan(address=address).address is None


def test_an_unknown_band_understates_and_the_index_is_never_negative():
    assert _plan(band="90%").band == "possible" and _plan(index=-3).index == 0 and _plan(index=2).index == 2
    assert json.loads(_plan(index=2).to_prompt())["warning_number"] == 3


def test_the_plan_names_certainty_in_words_never_a_number():
    facts = json.loads(_plan(band="almost_certain").to_prompt())
    certainty = json.dumps(facts["certainty"], ensure_ascii=False)
    assert facts["certainty"]["bn"] == "প্রায় নিশ্চিত প্রতারণা" and not any(ch.isdigit() for ch in certainty)


def test_the_warning_key_moves_with_what_apa_tells_her_to_do_not_with_any_pending_action():
    """The key a prepared warning is kept under (P0 item 6): the ledger, the band, and the instruction the plan chooses."""
    code_ask, no_ask = _ledger(), _ledger(asks=(), tactics={"AUTHORITY_IMPERSONATION": Evidence("AUTHORITY_IMPERSONATION", CALLER[1], 0)})
    assert warnings.key(code_ask, None, "likely") == warnings.key(code_ask, "send_money", "likely") == warnings.key(code_ask, "pin_reset", "likely")
    assert warnings.key(no_ask, None, "likely") != warnings.key(no_ask, "send_money", "likely")
    assert warnings.key(code_ask, None, "likely") != warnings.key(code_ask, None, "almost_certain") != warnings.key(no_ask, None, "almost_certain")


# --- the validator: the report's eight rules --------------------------------------------------------------------------

GOOD = {
    "A": ("রহিমা, একটু থামুন — কোডটা কাউকে বলবেন না।", "Rahima, stop for a moment: don't tell anyone the code."),
    "T": ("ফোনে আপনার মেসেজে আসা কোডটা চাওয়া হচ্ছে।", "The code that came in your message is being asked for on the phone."),
    "R": ("আসল ব্যাংক বা ফিননেস্ট কখনো ফোনে এই কোড চায় না।", "A real bank, or FinNest, never asks for this code on the phone."),
    "X": ("কলটা কেটে দিন, তারপর অ্যাপের ‘ফিননেস্টে কল করুন’ বোতাম চাপুন।", "Hang up, then press the app's 'Call FinNest' button."),
}


def _check(role, text, plan=None, caller=CALLER):
    plan = plan or _plan()
    return validator.validate(role, text, plan, caller, address=plan.address)


@pytest.mark.parametrize("role", list(GOOD))
def test_the_example_lines_pass_every_rule(role):
    assert _check(role, GOOD[role][0]) == validator.Check(True, None)
    assert validator.validate_en(role, GOOD[role][1]) == validator.Check(True, None)


@pytest.mark.parametrize(("role", "text", "rule"), [
    ("A", "রহিমা, একটু থামুন", "shape"),                                                         # no ।
    ("A", "কোডটা কাউকে বলবেন না?", "shape"),                                                      # only । ends a sentence
    ("A", "রহিমা একটু থামুন এখন কোডটা কাউকে কোনোভাবেই কখনোই বলবেন না কিন্তু।", "shape"),           # over A's ten words
    ("A", "ওটিপি কাউকে বলবেন না।", "shape"),                                                      # spoken as letters: ও-টি-পি
    ("Q", "কলটা কেটে দিন।", "shape"),                                                             # not one of A|T|R|X
    ("A", "OTP কাউকে বলবেন না।", "script"),
    ("A", "কোডটা कभी বলবেন না।", "script"),
    ("A", "৫ মিনিট পরে কলটা কেটে দিন।", "number"),
    ("A", "পাঁচ মিনিট পরে কলটা কেটে দিন।", "number"),
    ("X", "দশ হাজার টাকা পাঠাবেন না।", "number"),
    ("A", "এক ঘণ্টা কলটা কেটে রাখুন।", "number"),
    ("A", "পুলিশ বলছে, কলটা কেটে দিন।", "tip_off"),
    ("A", "পুলিসের কথা মতো কলটা কেটে দিন।", "tip_off"),                                            # one letter off, with a suffix
    ("A", "সিস্টেমে ধরা পড়েছে, কলটা কেটে দিন।", "tip_off"),
    ("T", "এটা একটা চক্রের কাজ।", "tip_off"),
    ("T", "এআই বলছে এটা প্রতারণা।", "tip_off"),
    ("A", "করিম সাহেব, কলটা কেটে দিন।", "name"),
    ("R", "বিকাশ কখনো ফোনে কোড চায় না।", "name"),
    ("A", "আপনার ফোনে একটা কোড গেছে, কাউকে বলবেন না।", "parrot"),                                # four tokens from a caller turn
    ("A", "পিনটা কাউকে বলবেন না।", "ledger"),                                                     # the ask was the OTP
    ("T", "পুরস্কারের কথা বলে কোড চাওয়া হচ্ছে।", "ledger"),                                         # no prize bait in the ledger
    ("T", "এটা প্রায় নিশ্চিত প্রতারণা।", "ledger"),                                                 # the band is only "likely"
    ("X", "টাকা পাঠাবেন না, কলটা কেটে দিন।", "ledger"),                                            # nothing about money is pending
    ("X", "এই নম্বরে কল করুন।", "action"),                                                        # "call this number" fails
    ("A", "কোডটা বলে দিন।", "action"),
    ("X", "লিংকে চাপ দিয়ে ভেরিফাই করুন।", "action"),
    ("X", "পরিবারকে জানাবেন না, কলটা কেটে দিন।", "action"),
    ("A", "ফোনে কোড চাওয়া হচ্ছে।", "action"),                                                    # A and X must carry an action
])
def test_each_rule_rejects_its_line(role, text, rule):
    assert _check(role, text) == validator.Check(False, rule)


def test_the_name_rule_allows_only_the_chosen_address():
    assert _check("A", "করিম ভাই, একটু থামুন।", _plan(address="করিম ভাই")).ok
    assert _check("A", "করিম ভাই, একটু থামুন।", _plan(address="রহিমা")) == validator.Check(False, "name")


def test_short_everyday_words_are_not_mistaken_for_tip_off_words():
    """Edit distance one turns এআই into এই (this) and মামলা into মামা; short terms match only exactly."""
    assert _check("A", "এই কলটা কেটে দিন।").ok and _check("T", "ফোনে মামা পরিচয়ে কোড চাওয়া হচ্ছে।", _plan()).rule != "tip_off"


def test_an_identity_word_must_match_the_ledgers_class():
    relative = _plan(ledger=_ledger(claimed_identity="relative"))
    assert _check("R", GOOD["R"][0], relative) == validator.Check(False, "ledger")
    vague = _plan(ledger=_ledger(claimed_identity="unknown"))
    assert _check("R", GOOD["R"][0], vague).ok  # "a real bank never asks" is the default rule for a secret


def test_money_words_need_a_send_in_the_plan():
    send = _plan(pending_action="send_money", ledger=_ledger(asks=()))
    assert _check("X", "টাকা পাঠাবেন না, কলটা কেটে দিন।", send).ok


@pytest.mark.parametrize(("text", "rule"), [
    ("", "en:shape"), ("Hang up and call 16247 now.", "en:number"), ("Wait two hours before you send.", "en:number"),
    ("The police are investigating this ring.", "en:tip_off"), ("Our system flagged this call.", "en:tip_off"),
    ("Call this number to check.", "en:action"), ("bKash never asks for your code.", "en:name"),
])
def test_the_english_rendering_is_checked_too(text, rule):
    assert validator.validate_en("A", text) == validator.Check(False, rule)


@pytest.mark.parametrize("action", planner.ACTION_IDS)
def test_the_action_words_the_plan_hands_the_model_pass_the_validator(action):
    """The fixed action vocabulary must itself be speakable, or every warning that uses it would be dropped."""
    send = _plan(pending_action="send_money", ledger=_ledger(asks=("otp", "send_money"),
                 tactics={**_ledger().tactics, "PAYMENT_REDIRECTION": Evidence("PAYMENT_REDIRECTION", "টাকা পাঠান", 1)}))
    if action == "dont_change_pin":   # its words name the PIN change, so only a PIN-reset plan may speak them
        send = planner.plan(Ledger(), "pin_reset", "likely")
    elif action == "open_safety":     # the app's phone-safety page, only when App Safety found something
        send = planner.plan(Ledger(), "send_money", "likely", phone=("REMOTE_CONTROL",))
    bn, en = send.words(action)
    assert _check("X", bn + "।", send) == validator.Check(True, None) and validator.validate_en("X", en).ok


def test_the_validator_runs_in_under_five_ms_a_line():
    turns = CALLER * 10
    started = time.perf_counter()
    for _ in range(50):
        for role, (bn, en) in GOOD.items():
            _check(role, bn, caller=turns)
            validator.validate_en(role, en)
    assert (time.perf_counter() - started) * 1000 / (50 * len(GOOD)) < 5.0


def test_the_validator_extends_apas_checks():
    from app import apa

    assert apa.TIP_OFF_WORDS.search("মামলা") and _check("T", "মামলা হয়ে যাবে বলে কোড চাওয়া হচ্ছে।").rule == "tip_off"
    assert _check("A", "acct_80661 কে টাকা পাঠাবেন না।").rule in ("script", "number")


# --- the composer: streamed A|T|R|X from Flash-Lite, validated line by line, repaired without editing a word -------------


# --- review findings (W): instructions judged clause by clause, glued punctuation, compound numbers, more tip-off words ----

HARMFUL = [
    "কোডটা বলে দিন, তারপর কলটা কেটে দিন।",               # tell the code, then hang up
    "ও-টি-পি দিন, তারপর কলটা কেটে দিন।",
    "টাকা পাঠিয়ে দিন, তারপর কলটা কেটে দিন।",
    "পরিবারের কারও সাথে কথা বলে নিন, আর কোডটা বলুন।",
    "পরিবারকে কোডটা বলুন।",
    "রহিমা, একটু থামুন — কোডটা কাউকে বলবেন।",            # the plan's own A line with its না dropped
    "টাকা পাঠাবেন, তারপর কলটা কেটে দিন।",
    "অফিসে যাবেন, তারপর কলটা কেটে দিন।",
    "একটু থামুন, অ্যাপটা খুলতে হবে।",
]


@pytest.mark.parametrize("text", HARMFUL)
def test_an_instruction_is_judged_in_its_own_clause_and_a_dropped_na_is_caught(text):
    p = _plan(pending_action="send_money")
    assert validator.validate("X", text, p, CALLER, address=p.address) == validator.Check(False, "action")


@pytest.mark.parametrize("text", [GOOD["A"][0], GOOD["X"][0], "কলটা কেটে দিন আর ফিননেস্টের বোতাম চাপুন।",
                                  "কলটা কেটে দেবেন, তারপর পরিবারের কারও সাথে কথা বলে নিন।", "কলটা কেটে দিতে হবে।"])
def test_the_allowed_actions_still_pass_in_their_everyday_forms(text):
    p = _plan(pending_action="send_money")
    assert validator.validate("X", text, p, CALLER, address=p.address) == validator.Check(True, None)


def test_secret_information_is_the_credential_not_the_secrecy_tactic():
    """First real run: the model called the code 'গোপন তথ্য' (secret information), which the lexicon read as SECRECY_ISOLATION."""
    p = _plan(pending_action="send_money")  # an OTP ask, no secrecy tactic
    assert _check("T", "ফোনে এই গোপন তথ্যগুলো চাওয়া হচ্ছে।", plan=p) == validator.Check(True, None)
    assert _check("R", "আসল ব্যাংক কখনো ফোনে গোপন তথ্য চায় না।", plan=p) == validator.Check(True, None)
    assert _check("T", "এই কথা গোপন রাখতে বলা হচ্ছে।", plan=p).rule == "ledger"  # keeping it secret is still the tactic
    assert _check("X", "গোপন তথ্যগুলো দিয়ে দিন, তারপর কলটা কেটে দিন।", plan=p).rule == "action"
    no_secret = _plan(ledger=_ledger(asks=(), tactics={"URGENCY_THREAT": Evidence("URGENCY_THREAT", "বন্ধ হয়ে যাবে", 0)}))
    assert _check("T", "ফোনে গোপন তথ্য চাওয়া হচ্ছে।", plan=no_secret).rule == "ledger"


def test_punctuation_glued_between_words_does_not_hide_a_parroted_run():
    assert _check("T", "আপনার-একাউন্ট বন্ধ-হয়ে যাবে বলা হচ্ছে।").rule == "parrot"


@pytest.mark.parametrize("text", ["ফোনে পাঁচশো টাকা চাওয়া হচ্ছে।", "ফোনে দুইশো টাকা চাওয়া হচ্ছে।", "ফোনে দশহাজার টাকা চাওয়া হচ্ছে।",
                                  "ফোনে ফাইভ হান্ড্রেড টাকা চাওয়া হচ্ছে।"])
def test_compound_and_transliterated_numbers_are_numbers(text):
    assert _check("T", text, plan=_plan(pending_action="send_money")).rule == "number"


@pytest.mark.parametrize("text", ["গোয়েন্দা বিভাগকে জানানো হয়েছে।", "কলটা র‍্যাবকে জানানো হয়েছে।"])
def test_detective_and_rab_tip_off_the_caller(text):
    assert _check("T", text).rule == "tip_off"


@pytest.mark.parametrize("text", ["The detective branch has been told.", "An officer is arresting you."])
def test_detective_and_arrest_tip_off_in_english_too(text):
    assert validator.validate_en("T", text).rule == "en:tip_off"


def _text(lines: dict) -> str:
    return "".join(f"{role}| {bn} || {en}\n" for role, (bn, en) in lines.items())


class FakeModel:
    """composer._model_text stand-in: each call pops the next reply (text, an exception, or a list of chunks and exceptions)."""

    def __init__(self, *replies):
        self.replies, self.calls = list(replies), []

    def __call__(self, contents, settings, temperature, timeout_s, spend=None):
        self.calls.append({"contents": contents, "temperature": temperature, "timeout_s": timeout_s})
        reply = self.replies.pop(0) if self.replies else ""
        if isinstance(reply, Exception):
            raise reply
        chunks = [reply[i:i + 7] for i in range(0, len(reply), 7)] if isinstance(reply, str) else reply

        def stream():
            for chunk in chunks:
                if isinstance(chunk, Exception):
                    raise chunk
                yield chunk
        return stream()


@pytest.fixture
def model(monkeypatch):
    def install(*replies):
        fake = FakeModel(*replies)
        monkeypatch.setattr(composer, "_model_text", fake)
        return fake
    return install


def _generate(**over):
    from app.settings import get_settings

    args = dict(plan=_plan(), caller_turns=CALLER, settings=get_settings(), last_good=None)
    return warnings.generate(**{**args, **over})


def test_lines_are_parsed_as_they_stream_whatever_the_chunking():
    text = "Here you go:\n" + _text(GOOD) + "```"
    chunks = [text[i:i + 3] for i in range(0, len(text), 3)]
    assert list(composer.parse(chunks)) == [(role, bn, en) for role, (bn, en) in GOOD.items()]
    assert list(composer.parse(["A| কলটা কেটে দিন।"])) == [("A", "কলটা কেটে দিন।", "")]


def _untagged(lines: dict) -> str:
    return "".join(f"{bn} || {en}\n" for bn, en in lines.values())


def test_lines_the_model_wrote_without_their_tags_take_their_role_from_the_order():
    """First real run (2026-10-17): Flash-Lite wrote 'একটু থামুন। || Stop for a moment.' with no 'A|', so every line was ignored."""
    assert list(composer.parse([_untagged(GOOD)])) == [(role, bn, en) for role, (bn, en) in GOOD.items()]
    mixed = "Here are the lines:\n" + "A| " + " || ".join(GOOD["A"]) + "\n" + _untagged({k: GOOD[k] for k in "TRX"})
    assert [r for r, _, _ in composer.parse([mixed])] == ["A", "T", "R", "X"]  # a preamble without " || " counts for nothing
    assert list(composer.parse([" || ".join(GOOD["X"]) + "\n"], order=("X",))) == [("X", *GOOD["X"])]  # a regeneration's one line


def test_an_untagged_reply_still_becomes_the_whole_warning(model):
    model(_untagged(GOOD))
    assert [l.role for l in _generate().lines] == ["A", "T", "R", "X"]


def test_a_regeneration_without_its_tag_fills_the_line_it_asked_for(model):
    model(_text({**GOOD, "A": ("কোডটা বলে দিন।", "Say the code.")}), " || ".join(GOOD["A"]) + "\n")
    w = _generate()
    assert w.regenerated == ("A",) and w.lines[0] == warnings.WarningLine("A", *GOOD["A"])


def test_four_good_lines_become_the_warning_in_order(model):
    fake = model(_text(dict(reversed(GOOD.items()))))
    w = _generate()
    assert [line.role for line in w.lines] == ["A", "T", "R", "X"] and w.dropped == () and w.regenerated == ()
    assert w.script_bn == " ".join(bn for bn, _ in GOOD.values()) and w.script_en == " ".join(en for _, en in GOOD.values())
    assert len(fake.calls) == 1 and fake.calls[0]["temperature"] is None  # default temperature, so wording varies
    assert w.timings_ms["first_line_ms"] <= w.timings_ms["total_ms"] and w.timings_ms["validate_max_ms"] < 5


def test_the_model_reads_the_plan_and_never_the_transcript(model):
    fake = model(_text(GOOD))
    _generate()
    contents = fake.calls[0]["contents"]
    assert _plan().to_prompt() in contents and all(turn not in contents for turn in CALLER)


def test_a_failed_t_or_r_is_dropped_and_the_rest_stands(model):
    model(_text({**GOOD, "T": ("পুলিশ আপনার কোড চাইছে।", "The police want your code.")}))
    w = _generate()
    assert [line.role for line in w.lines] == ["A", "R", "X"] and w.dropped == (("T", "tip_off"),) and w.regenerated == ()


def test_a_failed_a_is_replaced_by_the_last_validated_one_from_this_call(model):
    fake = model(_text({**GOOD, "A": ("এই নম্বরে কল করুন।", "Call this number.")}))
    earlier = warnings.WarningLine("A", "রহিমা, একটু থামুন।", "Rahima, stop for a moment.")
    w = _generate(last_good={"A": earlier})
    assert w.lines[0] == earlier and w.reused == ("A",) and w.dropped == (("A", "action"),) and len(fake.calls) == 1


def test_without_a_last_good_line_a_failed_a_gets_one_regeneration_at_temperature_zero(model):
    fake = model(_text({**GOOD, "A": ("কোডটা বলে দিন।", "Say the code.")}), "A| " + " || ".join(GOOD["A"]) + "\n")
    w = _generate()
    assert w.regenerated == ("A",) and w.lines[0] == warnings.WarningLine("A", *GOOD["A"])
    assert len(fake.calls) == 2 and fake.calls[1]["temperature"] == 0 and "only the A line" in fake.calls[1]["contents"]


def test_a_last_good_line_that_no_longer_fits_the_plan_is_not_reused(model):
    fake = model(_text({**GOOD, "A": ("কোডটা বলে দিন।", "Say the code.")}), "A| " + " || ".join(GOOD["A"]) + "\n")
    stale = warnings.WarningLine("A", "পিনটা কাউকে বলবেন না।", "Don't tell anyone the PIN.")  # the ask is the OTP now
    w = _generate(last_good=[stale])
    assert w.regenerated == ("A",) and w.reused == () and len(fake.calls) == 2


def test_when_neither_a_nor_x_validates_the_answer_is_the_floor(model):
    bad = {"A": ("এই নম্বরে কল করুন।", "Call this number."), "X": ("কোডটা বলে দিন।", "Say the code.")}
    model(_text({**GOOD, **bad}), "A| এই নম্বরে কল করুন। || Call this number.\n", "")
    w = _generate()
    assert w.lines == () and w.script_bn == "" and set(w.regenerated) <= {"A", "X"}  # T and R never stand alone


def test_gemini_off_is_the_floor_unless_the_call_already_had_good_lines():
    w = _generate()  # the test environment has Gemini off
    assert w.lines == () and w.regenerated == ()
    a, x = warnings.WarningLine("A", *GOOD["A"]), warnings.WarningLine("X", *GOOD["X"])
    assert _generate(last_good=[a, x]).lines == (a, x)


def test_a_stream_that_breaks_keeps_what_validated_and_repairs_the_rest(model):
    text = _text({"A": GOOD["A"], "T": GOOD["T"]})
    model([text, TimeoutError("cut")], "X| " + " || ".join(GOOD["X"]) + "\n")
    w = _generate()
    assert [line.role for line in w.lines] == ["A", "T", "X"] and w.regenerated == ("X",)


def test_a_line_without_its_english_fails(model):
    model("A| " + GOOD["A"][0] + "\n" + _text({k: GOOD[k] for k in "TRX"}), "")
    w = _generate()
    assert ("A", "en:shape") in w.dropped and [line.role for line in w.lines] == ["T", "R", "X"]


def test_code_never_edits_or_assembles_a_word(model):
    """Every line Apa would speak is, character for character, a line the model wrote or one validated earlier in the call."""
    written = {**GOOD, "T": ("পুলিশ আপনার কোড চাইছে।", "The police want your code.")}
    model(_text(written))
    for line in _generate().lines:
        assert (line.text_bn, line.text_en) == written[line.role]


# --- stream(): the same lines, handed over as each one is ready (the cold path speaks A while T, R and X are written) ----


def _stream(**over):
    from app.settings import get_settings

    args = dict(plan=_plan(), caller_turns=CALLER, settings=get_settings(), last_good=None)
    return warnings.stream(**{**args, **over})


def test_the_stream_hands_over_the_a_line_before_the_model_has_written_the_rest(model):
    written = []

    def chunks():
        for role, (bn, en) in GOOD.items():
            written.append(role)
            yield f"{role}| {bn} || {en}\n"
    model(chunks())
    assert next(iter(_stream())) == warnings.WarningLine("A", *GOOD["A"]) and written == ["A"]


EARLIER_A = warnings.WarningLine("A", "রহিমা, একটু থামুন।", "Rahima, stop for a moment.")


@pytest.mark.parametrize(("replies", "last_good"), [
    ((_text(dict(reversed(GOOD.items()))),), None),                                                     # X first: still A, T, R, X
    ((_text({**GOOD, "T": ("পুলিশ আপনার কোড চাইছে।", "The police want your code.")}),), None),         # a dropped T
    ((_text({**GOOD, "A": ("এই নম্বরে কল করুন।", "Call this number.")}),), [EARLIER_A]),               # A reused, still first
    ((_text({**GOOD, "A": ("কোডটা বলে দিন।", "Say the code.")}), "A| " + " || ".join(GOOD["A"]) + "\n"), None),  # A regenerated
    ((_text({**GOOD, "A": ("এই নম্বরে কল করুন।", "Call this number."), "X": ("কোডটা বলে দিন।", "Say the code.")}),
      "A| এই নম্বরে কল করুন। || Call this number.\n", ""), None),                                     # the floor: nothing at all
    (("A| " + GOOD["A"][0] + "\n" + _text({k: GOOD[k] for k in "TRX"}), ""), None),                   # A lost: T, R, X
])
def test_the_stream_gives_exactly_generates_lines_in_their_order(model, replies, last_good):
    model(*replies)
    expected = _generate(last_good=last_good).lines
    model(*replies)
    assert tuple(_stream(last_good=last_good)) == expected


def test_a_role_that_already_failed_is_not_taken_from_a_repeat_so_stream_and_generate_agree(model):
    bad_t = ("পুলিশ আপনার কোড চাইছে।", "The police want your code.")
    reply = _text({"A": GOOD["A"], "T": bad_t, "R": GOOD["R"]}) + _text({"T": GOOD["T"], "X": GOOD["X"]})
    model(reply)
    expected = _generate().lines
    model(reply)
    assert [l.role for l in expected] == ["A", "R", "X"] and tuple(_stream()) == expected


def test_the_composer_uses_the_volume_role_at_minimal_thinking(monkeypatch):
    from types import SimpleNamespace

    from app import genai_client
    from app.settings import Settings

    seen = []

    class Models:
        def generate_content_stream(self, model, contents, config):
            seen.append((model, contents, config))
            usage = SimpleNamespace(prompt_token_count=400, candidates_token_count=120, thoughts_token_count=0)
            part = SimpleNamespace(text=_text(GOOD), thought=None)
            yield SimpleNamespace(candidates=[SimpleNamespace(content=SimpleNamespace(parts=[part]))], usage_metadata=usage)

    monkeypatch.setattr(genai_client, "_client", lambda location=None: SimpleNamespace(models=Models()))
    genai_client.LEDGER.reset()
    try:
        w = warnings.generate(_plan(), CALLER, Settings(genai_enabled=True, gemini_api_key="test-key"))
    finally:
        spent = genai_client.LEDGER.spent()
        genai_client.LEDGER.reset()
    model_id, contents, config = seen[0]
    assert model_id == genai_client.roles()["volume"].id == "gemini-3.5-flash-lite"
    assert config.thinking_config.thinking_level.value == "MINIMAL" and config.temperature is None
    assert config.system_instruction == composer.system_prompt(Settings()) and len(w.lines) == 4 and spent > 0 and w.cost_usd == pytest.approx(spent)


# --- /v1/intervene and /v1/apa/why answer with the generated warning ----------------------------------------------------

HOLD = {"user_id": "rina", "trigger": "SCAM_CONVERSATION", "txn": {"type": "pin_reset"}, "session_id": "call-1"}
SCRIPT_BN = " ".join(bn for bn, _ in GOOD.values())


def _call(session_id="call-1", ledger=None, band="likely", address="রহিমা"):
    """A call the detector has scored (its session document carries the ledger and the band) and the address she chose."""
    from app import state

    state.store().set("scam_sessions", session_id, {"uid": "demo", "ledger": (ledger or _ledger()).to_doc(), "band": band,
                                                     "rolling": 0.8, "updated_at": time.time()})
    state.store().set("users", "rina", {"apa_address": address} if address else {})


def _intervene(client, **over):
    resp = client.post("/v1/intervene", json={**HOLD, **over})
    assert resp.status_code == 200, resp.text
    return resp.json()


def test_intervene_without_gemini_is_the_floor_earcon_vibration_and_no_words(client):
    _call()
    out = _intervene(client)
    assert (out["script_bn"], out["script_en"], out["lines"], out["audio_asset_id"], out["warning_id"]) == ("", "", [], None, None)
    assert out["earcon"] is True and out["vibrate"] is True and out["speak_on_device"] is False and out["intervene"] is True
    assert out["ledger_hash"] == warnings.key(_ledger(), "pin_reset", "likely") and out["ui"] == "fullscreen"
    assert {a["type"] for a in out["actions"]} == {"freeze_pin_reset", "trusted_contact_check"}


def test_intervene_answers_with_the_generated_validated_text(client, model):
    from app import apa
    from app.settings import get_settings

    _call()
    fake = model(_text(GOOD))
    out = _intervene(client, transcript_snippet=QUOTE)
    assert [line["role"] for line in out["lines"]] == ["A", "T", "R", "X"] and out["script_bn"] == SCRIPT_BN
    assert out["script_en"] == " ".join(en for _, en in GOOD.values()) and out["audio_asset_id"] is None
    assert out["speak_on_device"] is True and out["warning_id"].startswith("w-") and out["earcon"] and out["vibrate"]
    assert all(apa.verify_why(line["text_bn"], line["token"], get_settings()) for line in out["lines"])
    contents = fake.calls[0]["contents"]
    assert QUOTE not in contents and "রহিমা" in contents and '"ask": "otp"' in contents


def test_a_line_that_parrots_the_callers_last_words_is_dropped(client, model):
    _call()
    snippet = "ফোনে আপনার মেসেজে আসা কোডটা এখনই বলুন"
    model(_text(GOOD))
    out = _intervene(client, transcript_snippet=snippet)
    assert [line["role"] for line in out["lines"]] == ["A", "R", "X"]  # T shared four words with the snippet


def test_a_refused_gemini_quota_never_calls_the_model_and_never_fails_the_hold(client, model, monkeypatch):
    from app import ratelimit

    _call()
    fake = model(_text(GOOD))
    monkeypatch.setattr(ratelimit, "admit", lambda request, buckets: False)
    out = _intervene(client)
    assert fake.calls == [] and out["lines"] == [] and out["earcon"] is True


def test_the_same_evidence_reuses_the_warning_without_a_model_call(client, model):
    _call()
    fake = model(_text(GOOD))
    first, second = _intervene(client), _intervene(client)
    assert len(fake.calls) == 1 and second["warning_id"] == first["warning_id"]
    assert [line["text_bn"] for line in second["lines"]] == [line["text_bn"] for line in first["lines"]]


def test_new_evidence_writes_a_new_warning_and_a_failed_a_falls_back_to_the_calls_last_good_one(client, model):
    _call()
    fake = model(_text(GOOD), _text({**GOOD, "A": ("কোডটা বলে দিন।", "Say the code.")}))
    first = _intervene(client)
    more = _ledger(tactics={**_ledger().tactics, "SECRECY_ISOLATION": Evidence("SECRECY_ISOLATION", "কাউকে বলবেন না", 3)})
    _call(ledger=more, band="almost_certain")
    second = _intervene(client)
    assert second["warning_id"] != first["warning_id"] and second["ledger_hash"] != first["ledger_hash"]
    assert second["lines"][0]["text_bn"] == GOOD["A"][0] and len(fake.calls) == 2  # reused, not regenerated
    assert '"warning_number": 2' in fake.calls[1]["contents"]


def test_the_warning_is_kept_on_the_hold_for_the_trusted_contact(client, model):
    from app import state

    state.store().set("interventions", "iv-1", {"id": "iv-1", "user_id": "rina", "session_id": "call-1", "status": "held"})
    _call()
    model(_text(GOOD))
    out = _intervene(client, session_id=None, intervention_id="iv-1")
    kept = state.store().get("interventions", "iv-1")["apa_warning"]
    assert kept["warning_id"] == out["warning_id"] and [line["text_bn"] for line in kept["lines"]] == list(bn for bn, _ in GOOD.values())


def test_another_users_hold_is_not_read_or_written(client, model):
    from app import state

    state.store().set("interventions", "iv-2", {"id": "iv-2", "user_id": "someone-else", "session_id": "call-1", "status": "held"})
    _call()
    model(_text(GOOD))
    out = _intervene(client, session_id=None, intervention_id="iv-2")
    assert out["lines"] == [] or out["ledger_hash"] == warnings.key(Ledger(), "pin_reset", "possible")
    assert "apa_warning" not in state.store().get("interventions", "iv-2")


def test_apa_why_is_the_composer_with_a_token_for_each_line(client, model):
    from app import apa
    from app.settings import get_settings

    _call()
    model(_text(GOOD))
    resp = client.post("/v1/apa/why", json={"user_id": "rina", "trigger": "SCAM_CONVERSATION", "session_id": "call-1", "pending_action": "pin_reset"})
    out = resp.json()
    assert resp.status_code == 200 and [line["role"] for line in out["lines"]] == ["A", "T", "R", "X"]
    assert out["explanation_bn"] == SCRIPT_BN and all(apa.verify_why(line["text_bn"], line["token"], get_settings()) for line in out["lines"])


def test_apa_why_spends_no_gemini_quota_when_the_warning_needs_no_model_call(client, model, monkeypatch):
    """Review finding (W): the route spent a slot before compose(); unchanged evidence then hit 429 with nothing to call."""
    from app import ratelimit

    _call()
    model(_text(GOOD))
    body = {"user_id": "rina", "trigger": "SCAM_CONVERSATION", "session_id": "call-1", "pending_action": "pin_reset"}
    first = client.post("/v1/apa/why", json=body)
    spent = []
    monkeypatch.setattr(ratelimit, "spend_all", lambda request, buckets: spent.append(buckets) or ("genai",))
    monkeypatch.setattr(ratelimit, "admit", lambda request, buckets: spent.append(buckets) or False)
    again = client.post("/v1/apa/why", json=body)
    assert first.status_code == again.status_code == 200 and again.json()["lines"] == first.json()["lines"] and spent == []


def test_apa_turn_says_no_fixed_words(client):
    """/v1/apa/turn is the conversation stub: until Apa's conversation is built it answers with no words at all."""
    out = client.post("/v1/apa/turn", json={"user_id": "rina", "text_bn": "আমি কি টাকা পাঠাবো?"}).json()
    assert out == {"reply_bn": "", "reply_en": "", "tool_calls": []}


def test_apa_why_without_gemini_says_nothing(client):
    out = client.post("/v1/apa/why", json={"user_id": "rina", "trigger": "SCAM_CONVERSATION"}).json()
    assert out == {"explanation_bn": None, "explanation_en": None, "token": None, "expires_at": None, "lines": []}


def test_no_fixed_line_or_recorded_clip_is_left():
    from pathlib import Path

    from app import apa

    assert not any(hasattr(apa, name) for name in ("FIXED", "GENERIC", "fixed_line", "FixedLine", "explain"))
    service = Path(__file__).resolve().parent.parent
    for gone in ("assets/apa_audio", "scripts/export_apa_assets.py", "docs/apa_audio_assets.md"):
        assert not (service / gone).exists(), gone
