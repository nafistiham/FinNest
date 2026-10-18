"""The detector's decisive reasoning, in code. It reads the evidence ledger, never the model's raw text.

- norm table (from the tactic cards): a claimed identity asking for what that identity never asks for is a scam;
- credential rule: a verified OTP, PIN or password ask from a number that is not a verified help line is a scam;
- courier-code rule: any caller asking for a code to be read out or sent is a scam, whatever the story;
- two distinct verified tactics anywhere in the call raise the certainty band by one;
- meta-talk (the app, "the system", AI, Bhorosha's approval) and an injection attempt raise risk and count as a second signal.

Gemini's own risk can only raise the result above this floor, never lower it, and the help-line cap still applies unless a
secret was asked or a rule settled the call. The certainty bands are defined here and nowhere else.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

from app.ledger import Ledger, normalise
from app.tactic_cards import Cards

LIKELY_FROM = 0.7          # band boundaries: below is "possible", from here "likely" (the old two-turn alert)
ALMOST_CERTAIN_FROM = 0.9  # from here "almost_certain" (the old one-turn alert)
STRONG = 0.95              # a rule that settles the call: straight to the strong warning
LIKELY = 0.8               # where raising the band lands a "possible" call
META_FLOOR = 0.6           # meta-talk or an injection attempt alone: visible, below the alert
HELP_LINE_CAP = 0.4

CREDENTIAL_ASKS = ("otp", "pin", "password")
CODE_ASKS = ("otp",)  # the ledger files every code the caller wants read out, typed or sent as otp

CREDENTIAL_ASK = "CREDENTIAL_ASK"
COURIER_CODE = "COURIER_CODE"
TWO_TACTICS = "TWO_TACTICS"
META_TALK = "META_TALK"
INJECTION_ATTEMPT = "INJECTION_ATTEMPT"

# Talk about the protection itself. Matched on ledger.normalise() text (lower-case). The Bangla terms are a non-native draft
# (native_check: pending). The bank's name alone is not meta-talk: a genuine Bhorosha agent says it, and ভরসা is also the everyday
# word for trust; "approved by Bhorosha" or "the app's warning" is. So is "the system" invoked to explain a lock, an update or a
# code, unlike the system as a record ("our system shows a payment"); and "ignore" aimed at a warning, an alert or instructions,
# unlike "ignore the earlier SMS". A job title ("assistant manager") is not talk about AI.
_PROTECTOR = r"(finnest|ফিননেস্ট|bhorosha|ভরসা|\bapp\b|অ্যাপ)"  # the bank by either name (renamed FinNest)
_APPROVAL = r"(approv|অনুমোদ|verified|ভেরিফাইড|যাচাই করা|warning|ওয়ার্নিং|সতর্ক|alert|এলার্ট)"
_SYSTEM = r"(\bsystem\b|সিস্টেম)"
_SYSTEM_DOES = r"(lock|লক|block|ব্লক|update|আপডেট|upgrade|error|এরর|glitch|approv|অনুমোদ|verif|ভেরিফাই|যাচাই|suspend|code|কোড|otp|ওটিপি)"
_IGNORE = r"(\bignore\b|ইগনোর|উপেক্ষা)"
_IGNORED = r"(instruction|ইনস্ট্রাকশন|নির্দেশ|warning|ওয়ার্নিং|সতর্ক|alert|এলার্ট|notification|নোটিফিকেশন|\bapp\b|অ্যাপ)"
META_PATTERNS = (
    re.compile(rf"{_PROTECTOR}.{{0,40}}{_APPROVAL}|{_APPROVAL}.{{0,40}}{_PROTECTOR}"),
    re.compile(rf"{_SYSTEM}.{{0,30}}{_SYSTEM_DOES}|{_SYSTEM_DOES}.{{0,30}}{_SYSTEM}"),
    re.compile(r"\bartificial intelligence\b|\bai (assistant|system|model|bot)\b|এআই|\bchat ?bot\b|চ্যাটবট"),
    re.compile(r"bank[- ]?approved|approved by (the )?bank|ব্যাংক[- ]?অনুমোদিত|ব্যাংকের অনুমোদিত"),
    re.compile(rf"{_IGNORE}.{{0,30}}{_IGNORED}|{_IGNORED}.{{0,30}}{_IGNORE}"),
)


def meta_talk(text: str) -> bool:
    said = normalise(text)
    return any(p.search(said) for p in META_PATTERNS)


@dataclass(frozen=True)
class Outcome:
    floor: float               # the least the call's risk can be, whatever the model says
    hits: tuple[str, ...]      # rule ids, for the audit trail and the response
    tier_up: bool              # two distinct signals: the risk moves up one band
    secret_asked: bool         # a verified otp/pin/password ask: the help-line cap no longer protects the call

    @property
    def beats_help_line(self) -> bool:
        """A verified secret ask, or any rule that settles the call (the norm table, the courier code): caller ID can be
        spoofed, and no genuine help line makes these asks, so the help-line cap protects none of them."""
        return self.secret_asked or self.floor >= STRONG


def evaluate(ledger: Ledger, cards: Cards, help_line: bool) -> Outcome:
    hits: list[str] = []
    for ask in ledger.asks:
        rule = cards.norm_contradiction(ledger.claimed_identity, ask)
        if rule and rule not in hits:
            hits.append(rule)
    secret = any(a in CREDENTIAL_ASKS for a in ledger.asks)
    if secret and not help_line:
        hits.append(CREDENTIAL_ASK)
    if any(a in CODE_ASKS for a in ledger.asks):
        hits.append(COURIER_CODE)
    floor = STRONG if hits else 0.0
    meta = [f for f in (META_TALK, INJECTION_ATTEMPT) if f in ledger.flags]
    if len(ledger.tactics) >= 2:
        hits.append(TWO_TACTICS)
    if meta:
        hits += meta
        floor = max(floor, META_FLOOR)
    return Outcome(floor, tuple(hits), len(ledger.tactics) + (1 if meta else 0) >= 2, secret)


def certainty_band(risk: float) -> str:
    if risk >= ALMOST_CERTAIN_FROM:
        return "almost_certain"
    return "likely" if risk >= LIKELY_FROM else "possible"


def tier_up(risk: float) -> float:
    band = certainty_band(risk)
    return risk if band == "almost_certain" else max(risk, STRONG if band == "likely" else LIKELY)


def combine(model_risk: float, outcome: Outcome, help_line: bool) -> float:
    """The call's risk: the model's (already through its own guards and the hysteresis) can only raise the rules' floor."""
    risk = max(model_risk, outcome.floor)
    if outcome.tier_up:
        risk = tier_up(risk)
    if help_line and not outcome.beats_help_line:
        risk = min(risk, HELP_LINE_CAP)
    return round(risk, 3)
