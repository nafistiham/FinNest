"""Gemini's reading of one stored score, for the analyst.

The drawer shows the reasons exactly as the customer was told them, and that stays: those sentences
are fixed text in risk-mw, written for a customer, and reproducing them word for word is the point of
an audit trail. What they cannot do is tell an analyst why the engine landed where it did - which
signal set the score, which one asked for the hold, which were forced from the demo panel, and what
to look at next. This module asks Gemini that, once per document.

Four rules keep the reading honest:

* Gemini gets facts, not the document. `basis()` keeps what explains the score (codes, weights, what
  each code asks for, where each signal came from) and drops what does not: session and
  intervention ids, and the phone's app list, which is summarised to signals and counts with no
  package names.
* The engine's arithmetic is given, not guessed. The score is the largest single weight (or the
  session model's score), never a sum; the decision is the strictest thing any reason asked for.
  `basis()` works out which reason set the score and which reasons ask for the stored decision, so
  the reading cannot invent either.
* What comes back is checked before it is shown (`check()`): only the row's codes, every reason
  read once, only numbers the row or the engine's rules contain, no package names, no old brand
  names. A failing answer is retried once with what was wrong; a second failure is not shown.
* It never decides anything. The stored decision stands; this explains it.

Documents never change once written, so a reading is cached per document id for the life of the
process. Gemini is reached through risk-mw's own client (vendored with the rule engine), so model
ids, prices and the spend cap stay in risk-mw/config/models.yaml and app/genai_client.py.
"""

from __future__ import annotations

import json
import logging
import os
import re
import threading
import time
from collections import OrderedDict
from datetime import datetime, timezone
from typing import Any, Callable

from pydantic import BaseModel, Field, ValidationError

from api.risk_mw import genai_client, get_settings

log = logging.getLogger("insight")

PROMPT_VERSION = "insight-4"
# gemini-3.8-flash per risk-mw/config/models.yaml. On 19 stored scores x 2 (2026-10-18) it needed no retries and read
# the signals together; Flash-Lite needed 3 retries in 38, said weights "add", and wrote stiffer Bangla. About $0.0035
# and 6 s a reading (12 s worst), once per document: the drawer shows a skeleton meanwhile.
ROLE = "workhorse"
THINKING = "low"
TIMEOUT_S = 40.0           # 3.8 Flash took up to 19 s on real rows and passed 25 s twice in 38
MAX_OUTPUT_TOKENS = 3000   # thinking counts against it
CACHE_SIZE = 256
MAX_WARNING_LINES = 4

DECISION_RANK = {"allow": 0, "step_up": 1, "delay": 2, "hold": 3, "block": 4}

# What each reason code measures and what it asks the engine for, from risk-mw's app/rules.py,
# app/ato.py and bhorosha_ato/explain.py. Static knowledge about the rules, not a re-run of them.
CODE_GUIDE: dict[str, tuple[str, str]] = {
    "CALL_ACTIVE_NON_CONTACT": ("a PIN reset while the customer is on a call with a number not in her contacts; fixed weight 0.90", "hold"),
    "SIM_CHANGED_24H": ("the SIM for her number changed in the last 24 hours; fixed weight 0.85", "hold"),
    "NEW_PAYEE_ABOVE_P95": ("a first payment to a new payee, above her own 95th-percentile amount; fixed weight 0.60", "delay"),
    "APP_SAFETY_BLOCK": ("the App Safety check (the phone's report or risk-mw's own check) said BLOCK; fixed weight 0.95", "block"),
    "APP_SAFETY_CAUTION": ("the App Safety check said CAUTION: worth a look, not a block; its weight is the check's risk, "
                           "capped at 0.59 so an allowed payment never reads high, and it never changes a decision by itself", "allow"),
    "DEST_MULE_RISK": ("the receiving account's mule score is above 0.80; its weight is that score", "hold"),
    "SCREEN_SHARE_ACTIVE": ("her screen is being shared; fixed weight 0.50", "step_up"),
    "SCAM_CONVERSATION": ("the scam classifier scored the ongoing conversation at 0.70 or more during a PIN reset, new payee "
                          "or send; its weight is that score", "hold"),
    "ATO_BEHAVIOUR_MISMATCH": ("the behaviour model says this session does not look like her usual use; its weight is the "
                               "model's score; it asks for a step-up from 0.60 and a hold from 0.85", "step_up"),
    "ATO_BEHAVIOUR_MISMATCH_COLD_START": ("the same behaviour check from the global stand-in model, because she has not "
                                          "enrolled enough sessions yet; step-up from 0.60, hold from 0.85", "step_up"),
    "COACHING_SUSPECTED": ("the coaching model thinks someone is talking her through this (0.60 or more); it asks for a "
                           "hold during a call or when the behaviour score is 0.85 or more, otherwise a step-up", "step_up"),
    "MODEL_RISK": ("the session model alone; it can never hold money, only ask for a passkey step-up", "step_up"),
    "MONEY_LOCK_ACTIVE": ("she locked her money herself (Money Lock); fixed weight 0.70", "hold"),
}
ATO_HOLD = 0.85
BEHAVIOUR_CODES = frozenset({"ATO_BEHAVIOUR_MISMATCH", "ATO_BEHAVIOUR_MISMATCH_COLD_START"})
VARIABLE_CODES = BEHAVIOUR_CODES | {"COACHING_SUSPECTED"}
# Demo flags at these values say nothing about the case.
FLAG_DEFAULTS: dict[str, Any] = {"call_active": False, "caller_in_contacts": False, "screen_share": False,
                                 "sim_swap": False, "app_safety_verdict": "SAFE", "inbound_mule_score": 0.0, "scam_score": 0.0}


class InsightUnavailable(RuntimeError):
    """No reading for this document, with a fixed code the drawer can word. Never upstream text."""

    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


class Driver(BaseModel):
    code: str
    reading_en: str
    reading_bn: str


class Check(BaseModel):
    en: str
    bn: str


class Answer(BaseModel):
    """The shape Gemini must answer in (its response schema)."""

    summary_en: str = Field(description="One or two sentences: why the engine reached this decision and score.")
    summary_bn: str = Field(description="The same in plain Bangla, numbers in Bangla digits.")
    drivers: list[Driver] = Field(description="One entry per reason code in the facts, no others.")
    next_checks: list[Check] = Field(description="One to three concrete things the analyst can verify.")
    caveat_en: str = Field(description="What this row cannot tell, e.g. signals set from the demo panel.")
    caveat_bn: str


# --- the facts ---------------------------------------------------------------------------------------------------------

def _whole(value: Any) -> Any:
    """255.0 as 255: a stored float otherwise comes back as "৳ 255.0"."""
    return int(value) if isinstance(value, float) and value.is_integer() else value


def _asks(reasons: list[dict[str, Any]], decision: Any, call_active: Any) -> None:
    """What each reason asked for, from risk-mw's rules and bhorosha_ato.explain.required_action with the stored flags.

    Coaching asks for a hold during a call or when the behaviour score reaches 0.85, otherwise a step-up. The row stores
    behaviour scores rounded to three places, so a stored 0.85 may be 0.8496: that one boundary is read off the stored
    decision. And as the decision is the strictest ask, a behaviour or coaching reason never asked for more than it.
    This reads the stored decision; it never makes one.
    """
    rank = DECISION_RANK.get(decision) if isinstance(decision, str) else None
    decided_hold = rank is not None and rank >= DECISION_RANK["hold"]

    def strong(weight: float | None) -> bool:
        return weight is not None and (weight > ATO_HOLD or (weight == ATO_HOLD and decided_hold))

    behaviour = max((r["weight"] for r in reasons if r["code"] in BEHAVIOUR_CODES and r["weight"] is not None), default=None)
    for r in reasons:
        code = r["code"]
        if code in BEHAVIOUR_CODES:
            r["asks_for"] = "hold" if strong(r["weight"]) else "step_up"
        elif code == "COACHING_SUSPECTED":
            r["asks_for"] = "hold" if call_active is True or strong(behaviour) else "step_up"
        else:
            guide = CODE_GUIDE.get(code)
            r["asks_for"] = guide[1] if guide else None
        if code in VARIABLE_CODES and rank is not None and DECISION_RANK[r["asks_for"]] > rank:
            r["asks_for"] = "step_up"


def _num(value: Any) -> float | None:
    """A stored number, or None when it is absent; anything else is a document this reading cannot use."""
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, int | float):
        raise ValueError(f"not a number: {value!r}")
    return float(value)


def _source(key: str, value: Any, recorded: Any, inputs: dict[str, Any], outputs: dict[str, Any]) -> str:
    """Where a stored flag came from. risk-mw stores the flags after folding in its own data (the payee model's mule
    score, the App Safety verdict, its live scam classifier: the stronger value wins), and records the source only for
    the four device signals. The rest is matched against what the row does record, or said to be unrecorded."""
    if recorded not in (None, "none"):
        return str(recorded)
    if key == "inbound_mule_score":
        payee = outputs.get("payee_score_with_this_transfer")
        payee = outputs.get("payee_score_before") if payee is None else payee
        if isinstance(payee, int | float) and value == round(payee, 4):
            return "payee model"
    if key == "app_safety_verdict":
        report = inputs.get("app_safety")
        if isinstance(report, dict) and report.get("verdict") == value:
            return "phone report"
    return "unrecorded"


def _app_safety(report: dict[str, Any] | None) -> dict[str, Any] | None:
    """The phone's report as signals and counts. Package names are personal data and explain nothing here."""
    if not isinstance(report, dict):
        return None
    rank = {"low": 0, "medium": 1, "high": 2, "critical": 3}
    findings: dict[str, str] = {}
    apps: set[str] = set()
    for finding in report.get("findings") or []:
        if not isinstance(finding, dict) or not finding.get("signal"):
            continue
        signal, severity = str(finding["signal"]), str(finding.get("severity") or "low")
        if rank.get(severity, 0) >= rank.get(findings.get(signal, ""), -1):
            findings[signal] = severity
        if finding.get("scope") == "app" and finding.get("package"):
            apps.add(str(finding["package"]))
    out = {key: report[key] for key in ("verdict", "risk_score", "source", "resolution", "attestation", "findings_dropped")
           if report.get(key) is not None}
    return {**out, "findings": findings, "apps_flagged": len(apps)}


def basis(doc: dict[str, Any]) -> dict[str, Any]:
    """What Gemini is told about one score document: the facts that explain it, and nothing that identifies more.

    Raises ValueError, TypeError or AttributeError on a document not in the stored shape; explain() reads those as
    `unreadable` rather than a 500.
    """
    inputs, outputs = doc.get("inputs") or {}, doc.get("outputs") or {}
    txn, flags = inputs.get("txn") or {}, inputs.get("demo_flags") or {}
    sources = outputs.get("signal_sources") or {}
    if not all(isinstance(part, dict) for part in (inputs, outputs, txn, flags, sources)):
        raise ValueError("a section of the document is not a mapping")
    risk = _num(outputs.get("risk_score"))
    reasons = [
        {"code": str(r["code"]), "weight": _num(r.get("weight")), "asks_for": None,
         "meaning": CODE_GUIDE.get(str(r["code"]), ("not in this console's guide", None))[0],
         "told_customer_en": r.get("text_en")}
        for r in outputs.get("reasons") or [] if isinstance(r, dict) and r.get("code")
    ]
    reasons.sort(key=lambda r: -(r["weight"] or 0.0))
    top = max((r["weight"] for r in reasons if r["weight"] is not None), default=0.0)
    decision = outputs.get("decision")
    if decision is not None and not isinstance(decision, str):
        raise ValueError(f"decision is not a word: {decision!r}")
    _asks(reasons, decision, flags.get("call_active"))

    signals: dict[str, Any] = {}
    for key in sorted(set(flags) | set(sources)):
        value, recorded = flags.get(key), sources.get(key)
        if value == FLAG_DEFAULTS.get(key, None) and recorded in (None, "none"):
            continue
        signals[key] = {"value": value, "source": _source(key, value, recorded, inputs, outputs)}

    lines = (((outputs.get("warning") or {}).get("warning") or {}).get("lines")) or []
    settings = get_settings()
    out: dict[str, Any] = {
        "decision": decision,
        "band": outputs.get("band"),
        "risk_score": risk,
        "score_set_by": [r["code"] for r in reasons if risk is not None and r["weight"] == risk],
        "score_from_model": risk is not None and risk > top,
        "decision_matches": [r["code"] for r in reasons if r["asks_for"] == decision],
        "band_thresholds": {"medium": settings.band_medium, "high": settings.band_high, "critical": settings.band_critical},
        "reasons": reasons,
        "signals": signals,
        "txn": {k: _whole(txn.get(k)) for k in ("type", "amount_bdt", "is_new_payee", "to_account") if txn.get(k) is not None},
        "actions": [{"type": a.get("type"), **{k: v for k, v in (a.get("params") or {}).items() if k in ("minutes", "expires_in_minutes")}}
                    for a in outputs.get("actions") or [] if isinstance(a, dict)],
        "warning_said_en": [line.get("text_en") for line in lines if isinstance(line, dict) and line.get("text_en")][:MAX_WARNING_LINES],
    }
    payee = {k: outputs.get(k) for k in ("payee_score_before", "payee_score_with_this_transfer", "payee_moved_feature")
             if outputs.get(k) is not None}
    if payee:
        out["payee"] = payee
    phone = _app_safety(inputs.get("app_safety"))
    if phone:
        out["app_safety"] = phone
    return out


SYSTEM = """You help a fraud-operations analyst at FinNest, a Bangladeshi digital bank, read one decision its risk \
engine has already made and stored. The analyst sees this; the customer never does. You explain the stored decision; \
you never change it, second-guess it or recommend overriding it.

How the engine works (exact, do not contradict it):
- Each reason code is one rule or model that fired. Its weight is fixed by the rule or equals a model's score.
- risk_score is the largest single weight among the reasons, or the session model's score if that is higher \
(score_from_model). It is not a sum or an average of the weights. score_set_by names the reason that set it.
- The decision is the strictest thing any reason asks for (allow < step-up < delay < hold < block). Each reason's \
asks_for is what it asked for; decision_matches names the reasons whose ask equals the stored decision. Allow is the \
default when nothing asks for more: never say a reason "set" an allow.
- The band comes from risk_score and band_thresholds.
- APP_SAFETY_CAUTION raises the score but never changes a decision by itself.
- Where each signal came from (signals.*.source): "device" was measured on the phone; "demo" was set from the app's \
demo panel; "payee model" is risk-mw's own mule model for the receiving account; "phone report" is the App Safety \
report the phone sent with this payment; "unrecorded" is the stronger of what the demo panel set and what risk-mw knew \
itself (for the scam score, its live classifier on the call), and the row does not record which. Never say an \
"unrecorded" signal came from the demo panel; say the row does not record its source.

Write:
- summary: one or two sentences on why this decision and this score, naming the reason that set the score and the \
reasons that asked for the decision.
- drivers: one entry for every reason code in the facts, no other codes. For each, what it means in this case and how \
much it mattered: did it set the score, did it ask for the decision, or did it only add to the picture? Say how it \
combines with the others when that matters (a scam call with unfamiliar behaviour suggests someone is guiding her).
- next_checks: one to three things the analyst can verify, each tied to this row's reasons, and each in one of these \
places: the other rows of the same session in this audit log (scam turns, signal bundles, App Safety checks, the \
assistant's warnings); the customer's account page (her usual amounts and payees); the receiving account's page (its \
mule score and ring); the App Safety section of this drawer (only if the facts have app_safety); Case Zero, to open an \
investigation on the receiving account. Never tell anyone to call, text or pay a number.
- caveat: what this row cannot tell, chiefly which signals were set from the demo panel and which have no recorded \
source. If every signal was measured, say so.

Rules:
- Use only the facts given. Every number you write must appear in the facts (weights, scores, thresholds, amounts, \
minutes); you may also write small counts. Do not round a weight to a different number. Write a whole amount without \
decimals (৳ 14, not ৳ 14.0). Weights never add up: never say a reason "added" weight or "added to" the score.
- Name no app, package or company other than FinNest. Do not guess who is behind it or call anyone a fraudster.
- Reason codes: write them whole, exactly as given, in Latin letters (SCAM_CONVERSATION), in both languages. Never \
translate, transliterate or split a code. Write decisions and bands as words, not codes.
- Never write a field name from the facts (sim_swap, scam_score, inbound_mule_score, send_money, app_safety_verdict, \
call_active): say what it is in words (the SIM swap, the scam score, the payee's mule score, the payment, the App \
Safety verdict, the call). In Bangla too: সিম বদল, স্ক্যাম স্কোর, প্রাপকের মিউল স্কোর, টাকা পাঠানো, অ্যাপ সেফটির রায়, কল।
- English: plain sentences, analyst register, Latin digits (0.95, ৳ 255).
- Bangla: simple, natural চলিত Bangla with the same meaning as the English, Bangla digits (০.৯৫, ৳ ২৫৫), and no English \
words other than reason codes and account ids (not "আটকে রাখা বা hold"). Use these words, \
as the console does: risk score = রিস্ক স্কোর; weight = ওজন; band = ব্যান্ড, with low = কম, medium = মাঝারি, high = বেশি, \
critical = গুরুতর; allow = ছেড়ে দেওয়া; step-up = স্টেপ-আপ; delay = দেরি করানো; hold = আটকে রাখা; block = ব্লক; payee = \
প্রাপক; mule = মিউল; session = সেশন; demo panel = ডেমো প্যানেল; App Safety = অ্যাপ সেফটি; scam classifier = স্ক্যাম \
ক্লাসিফায়ার; behaviour model = আচরণ মডেল; coaching = কোচিং. Do not write সমালোচনামূলক for critical.
- The bank is FinNest (ফিননেস্ট). Never write Bhorosha, ভরসা, Apa or আপা.
- Keep it short: summary under 45 words, each driver under 35 words, each check under 25 words."""


def prompt(facts: dict[str, Any]) -> tuple[str, str]:
    contents = ("Explain this stored decision. Facts (JSON):\n" + json.dumps(facts, ensure_ascii=False, indent=1, default=str))
    return SYSTEM, contents


def gemini(system: str, contents: str, task: str = "console_insight", timeout_s: float = TIMEOUT_S) -> Any:
    """One structured call through risk-mw's client: role-pinned model, retries, and the per-instance spend cap.
    Readings and the start-up warm-up both come through here, so the warm-up is the same request shape."""
    return genai_client.call(task, ROLE, contents, schema=Answer, system=system, timeout_s=timeout_s,
                             thinking_level=THINKING, max_output_tokens=MAX_OUTPUT_TOKENS)


# --- the check ---------------------------------------------------------------------------------------------------------

BN_DIGITS = str.maketrans("০১২৩৪৫৬৭৮৯", "0123456789")
TO_BN = str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")
CODE_TOKEN = re.compile(r"\b[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+\b")
JOINED = re.compile(r"[A-Za-z0-9\u0980-\u09FF]+(?:_[A-Za-z0-9\u0980-\u09FF]+)+")  # anything joined by underscores
BANGLA_LETTER = re.compile(r"[\u0980-\u09E5\u09F0-\u09FF]")
BANGLA_DIGIT = re.compile(r"[০-৯]")
LATIN_DIGIT = re.compile(r"[0-9]")
DECISION_WORD = re.compile(r"\b(?:[Aa]llow(?:ed)?|[Ss]tep[-_ ]?up|[Dd]elay(?:ed)?|[Hh]old|[Hh]eld|[Bb]lock(?:ed)?)\b")  # not BLOCK: a verdict
LATIN_NAME = re.compile(r"[A-Za-z0-9_]*[A-Za-z][A-Za-z0-9_]*")  # any Latin word, ids included
LATIN_ID = re.compile(r"[A-Za-z0-9_]*(?:[A-Za-z][A-Za-z0-9_]*\d|\d[A-Za-z0-9_]*[A-Za-z])[A-Za-z0-9_]*")  # a1, acct_01288, P95
NUMBER = re.compile(r"\d+(?:\.\d+)?%?")
# A number with its unit, in the text Gemini wrote: "95%", "95 %", "95 percent", "৯৫ শতাংশ" are all a percent.
NUMBER_UNIT = re.compile(r"(\d+(?:\.\d+)?)(\s*(?:%|percent\b|per cent\b|শতাংশ))?")
# Digit-group commas only (95,000; 5,00,000), so a list like "0.95,0.76" stays two numbers.
GROUP_COMMA = re.compile(r"(?<=\d),(?=\d{2,3}(?!\d))")
CODE_WITH_ENDING = re.compile(r"([A-Za-z0-9_]*[A-Za-z0-9])([\u0980-\u09FF]+)")  # SCAM_CONVERSATIONএর
# Decision words spelt out in Bangla letters; the console's own words are আটকে রাখা, ছেড়ে দেওয়া, দেরি করানো (ব্লক and
# স্টেপ-আপ are the console's words too, so they pass).
BN_DECISION_WORD = re.compile(r"হোল্ড|অ্যালাউ|এলাউ|ডিলে")
PACKAGE = re.compile(r"\b[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*){2,}\b", re.I)
# Real brand names are kept only so the detector can recognise them: a reading that names another provider
# (or the bank's retired codename) is rejected, never shown.
OLD_NAMES = re.compile(r"bhorosha|ভরসা|\bapa\b|(?<![ঀ-৿])আপা(?:র|কে|য়)?(?![ঀ-৿])|\bbkash\b|\bnagad\b", re.I)
SMALL_COUNT = 10
LIMITS = {"summary": 420, "reading": 320, "check": 240, "caveat": 320}


def _numbers_in(value: Any, out: set[float]) -> set[float]:
    if isinstance(value, bool):
        return out
    if isinstance(value, int | float):
        out.add(round(float(value), 6))
    elif isinstance(value, str):
        for token in NUMBER.findall(CODE_TOKEN.sub(" ", value.translate(BN_DIGITS))):
            out.add(round(float(token.rstrip("%")), 6))
    elif isinstance(value, dict):
        for item in value.values():
            _numbers_in(item, out)
    elif isinstance(value, list | tuple):
        for item in value:
            _numbers_in(item, out)
    return out


def _allowed_numbers(facts: dict[str, Any]) -> set[float]:
    allowed = _numbers_in(facts, set())
    for code in {r["code"] for r in facts.get("reasons", [])}:
        _numbers_in(CODE_GUIDE.get(code, ("",))[0], allowed)
    allowed |= {float(n) for n in range(SMALL_COUNT + 1)}
    return allowed


def _stray_numbers(text: str, allowed: set[float]) -> list[str]:
    stray = []
    plain = CODE_TOKEN.sub(" ", GROUP_COMMA.sub("", LATIN_ID.sub(" ", text.translate(BN_DIGITS))))
    for number, unit in NUMBER_UNIT.findall(plain):
        token = number + ("%" if unit else "")
        value = round(float(number), 6)
        ok = value in allowed or (bool(unit) and round(value / 100, 6) in allowed)
        places = len(number.partition(".")[2])
        if not ok and places >= 2:  # 0.78 for a stored 0.781 is that number; 0.8 is not (one place reaches too far)
            ok = any(round(a, places) == value for a in allowed)
        if not ok:
            stray.append(token)
    return stray


def check(answer: Answer, facts: dict[str, Any]) -> list[str]:
    """Everything wrong with an answer, as sentences Gemini can act on. Empty means it may be shown."""
    problems: list[str] = []
    codes = [r["code"] for r in facts.get("reasons", [])]
    given = [d.code for d in answer.drivers]
    for code in given:
        if code not in codes:
            problems.append(f"drivers names {code}, which is not a reason code in the facts; use only {codes}")
    for code in codes:
        if given.count(code) != 1:
            problems.append(f"drivers must read {code} exactly once (found {given.count(code)})")
    if not 1 <= len(answer.next_checks) <= 3:
        problems.append(f"next_checks must have one to three items (found {len(answer.next_checks)})")

    texts: list[tuple[str, str, int]] = [
        ("summary_en", answer.summary_en, LIMITS["summary"]), ("summary_bn", answer.summary_bn, LIMITS["summary"]),
        ("caveat_en", answer.caveat_en, LIMITS["caveat"]), ("caveat_bn", answer.caveat_bn, LIMITS["caveat"]),
    ]
    for d in answer.drivers:
        texts += [(f"{d.code} reading_en", d.reading_en, LIMITS["reading"]), (f"{d.code} reading_bn", d.reading_bn, LIMITS["reading"])]
    for i, c in enumerate(answer.next_checks, 1):
        texts += [(f"next_checks {i} en", c.en, LIMITS["check"]), (f"next_checks {i} bn", c.bn, LIMITS["check"])]

    allowed = _allowed_numbers(facts)
    names = set(JOINED.findall(json.dumps(facts, ensure_ascii=False, default=str)))  # finding signals, resolutions: facts too
    for where, text, limit in texts:
        if not text.strip():
            problems.append(f"{where} is empty")
            continue
        if len(text) > limit:
            problems.append(f"{where} is too long ({len(text)} characters, at most {limit})")
        for token in _stray_numbers(text, allowed):
            shown = token.translate(TO_BN) if where.endswith("bn") else token  # in the script Gemini wrote it in
            problems.append(f"{where} writes {shown}, a number that is not in the facts")
        bangla = where.endswith("bn")
        if not bangla and BANGLA_DIGIT.search(text):
            problems.append(f"{where} uses Bangla digits; English text writes numbers in Latin digits (0.95)")
        if bangla and LATIN_DIGIT.search(LATIN_NAME.sub(" ", text)):  # an id like a1 or acct_01288 keeps its digits
            problems.append(f"{where} uses Latin digits; Bangla text writes numbers in Bangla digits (০.৯৫)")
        if bangla:
            for word in DECISION_WORD.findall(CODE_TOKEN.sub(" ", text)) + BN_DECISION_WORD.findall(text):
                problems.append(f"{where} writes the decision word {word}; say it as the console does (আটকে রাখা, ছেড়ে "
                                "দেওয়া, দেরি করানো, স্টেপ-আপ, ব্লক)")
        for token in JOINED.findall(text):
            ending = CODE_WITH_ENDING.fullmatch(token)
            token = ending.group(1) if ending else token  # a Bangla case ending on a whole code is still the code
            if BANGLA_LETTER.search(token):
                problems.append(f"{where} writes {token}; keep a reason code whole, in Latin letters, or say it in words")
            elif token.isupper() and token not in codes and token not in names:
                problems.append(f"{where} names {token}, which is not a reason code in this row")
            elif not token.isupper() and token not in names:  # acct_01288 when the row pays acct_rafiq
                problems.append(f"{where} names {token}, which is not in the facts")
        if PACKAGE.search(text):
            problems.append(f"{where} names an app package; name no app")
        if (old := OLD_NAMES.search(text)) is not None:
            problems.append(f"{where} writes {old.group(0)}, a word the brand does not use (Bhorosha, ভরসা, Apa, আপা and "
                            "other providers' names); the bank is FinNest (ফিননেস্ট), and for trust say বিশ্বাস")
    return problems


# --- explain -----------------------------------------------------------------------------------------------------------

FAILED_TTL_S = 600         # an answer that failed the check twice is not asked for again for this long

_cache: OrderedDict[str, dict[str, Any]] = OrderedDict()
_failed: OrderedDict[str, float] = OrderedDict()  # doc id -> when it may be asked again
_guard = threading.Lock()
_inflight: dict[str, threading.Lock] = {}


def forget() -> None:
    with _guard:
        _cache.clear()
        _failed.clear()
        _inflight.clear()


def _failed_recently(doc_id: str) -> bool:
    with _guard:
        until = _failed.get(doc_id)
        if until is not None and until <= time.monotonic():
            _failed.pop(doc_id, None)
            return False
        return until is not None


def _remember_failure(doc_id: str) -> None:
    with _guard:
        _failed[doc_id] = time.monotonic() + FAILED_TTL_S
        _failed.move_to_end(doc_id)
        while len(_failed) > CACHE_SIZE:
            _failed.popitem(last=False)


def _cached(doc_id: str) -> dict[str, Any] | None:
    with _guard:
        hit = _cache.get(doc_id)
        if hit is not None:
            _cache.move_to_end(doc_id)
        return hit


def _remember(doc_id: str, result: dict[str, Any]) -> None:
    with _guard:
        _cache[doc_id] = result
        _cache.move_to_end(doc_id)
        while len(_cache) > CACHE_SIZE:
            _cache.popitem(last=False)


def _parse(result: Any) -> Answer | None:
    if isinstance(result.parsed, Answer):
        return result.parsed
    try:
        return Answer.model_validate_json(result.text or "")
    except ValidationError:
        return None


def _shape(answer: Answer, facts: dict[str, Any]) -> dict[str, Any]:
    """The reading as the drawer shows it: drivers in the row's weight order, each with the stored weight."""
    by_code = {d.code: d for d in answer.drivers}
    drivers = [{"code": r["code"], "weight": r["weight"], "reading_en": by_code[r["code"]].reading_en,
                "reading_bn": by_code[r["code"]].reading_bn} for r in facts["reasons"]]
    return {"summary_en": answer.summary_en, "summary_bn": answer.summary_bn, "drivers": drivers,
            "next_checks": [c.model_dump() for c in answer.next_checks],
            "caveat_en": answer.caveat_en, "caveat_bn": answer.caveat_bn}


def explain(doc_id: str, doc: dict[str, Any], generate: Callable[[str, str], Any] | None = None) -> dict[str, Any]:
    """Gemini's reading of one stored score, checked, cached per document. Raises InsightUnavailable with a code."""
    hit = _cached(doc_id)
    if hit is not None:
        return {**hit, "cached": True}
    if doc.get("kind") != "score":
        raise InsightUnavailable("not_a_score")
    try:
        facts = basis(doc)
    except (TypeError, ValueError, AttributeError, KeyError) as exc:
        raise InsightUnavailable("unreadable") from exc
    if not facts["reasons"]:
        raise InsightUnavailable("nothing_fired")
    if _failed_recently(doc_id):
        raise InsightUnavailable("invalid")

    with _guard:
        lock = _inflight.setdefault(doc_id, threading.Lock())
    try:
        with lock:  # opens of the same row while one is asking wait for it and read what it left
            hit = _cached(doc_id)
            if hit is not None:
                return {**hit, "cached": True}
            if _failed_recently(doc_id):
                raise InsightUnavailable("invalid")
            try:
                result = _ask(doc_id, facts, generate or gemini)
            except InsightUnavailable as exc:
                if exc.code == "invalid":  # wrong twice: asking again now would most likely be wrong again, and costs
                    _remember_failure(doc_id)
                raise
            _remember(doc_id, result)  # inside the lock, so a waiting open finds it
            return {**result, "cached": False}
    finally:
        with _guard:
            if _inflight.get(doc_id) is lock:
                _inflight.pop(doc_id, None)


def _ask(doc_id: str, facts: dict[str, Any], generate: Callable[[str, str], Any]) -> dict[str, Any]:
    system, contents = prompt(facts)
    cost, latency, model_id = 0.0, 0.0, None
    for attempt in range(2):
        started = time.perf_counter()
        try:
            result = generate(system, contents)
        except Exception as exc:  # noqa: BLE001 - every upstream failure becomes one fixed code
            code = genai_client.fallback_code(exc)
            # The drawer gets the fixed code; the log gets the cause, which is what the first live timeout lacked.
            log.warning("insight %s: %s after %.1f s on attempt %d (%s: %s)", doc_id, code, time.perf_counter() - started,
                        attempt + 1, type(exc).__name__, str(exc)[:200])
            raise InsightUnavailable(code) from exc
        cost += float(getattr(result, "cost_usd", 0.0) or 0.0)
        latency += float(getattr(result, "latency_ms", 0.0) or 0.0)
        model_id = getattr(result, "model_id", None)
        answer = _parse(result)
        problems = ["the answer did not match the schema"] if answer is None else check(answer, facts)
        if not problems:
            return {"insight": _shape(answer, facts), "model_id": model_id, "prompt_version": PROMPT_VERSION,
                    "cost_usd": round(cost, 6), "latency_ms": round(latency, 1), "retried": attempt > 0,
                    "at": datetime.now(timezone.utc).isoformat(timespec="seconds")}
        log.info("insight %s: attempt %d failed the check: %s", doc_id, attempt + 1, "; ".join(problems)[:300])
        contents = (prompt(facts)[1] + "\n\nYour previous answer could not be shown. Fix exactly these problems and answer "
                    "again in full:\n- " + "\n- ".join(problems))
    raise InsightUnavailable("invalid")


# --- start-up ----------------------------------------------------------------------------------------------------------

WARM_UP_ENV = "FINNEST_ADMIN_GEMINI_WARM_UP_CALL"
WARM_UP_TIMEOUT_S = 90.0

# A held score in the shape risk-mw stores, for the start-up warm-up only: never a customer, never read from the audit
# trail, never cached as anyone's reading. Three reasons, signals from more than one source and a phone report, so the
# warm-up request is the size and shape of a real reading.
SAMPLE_DOC: dict[str, Any] = {
    "kind": "score",
    "inputs": {
        "txn": {"type": "send_money", "amount_bdt": 5000.0, "is_new_payee": False, "to_account": "acct_sample"},
        "demo_flags": {"call_active": True, "caller_in_contacts": False, "screen_share": False, "sim_swap": False,
                       "app_safety_verdict": "CAUTION", "inbound_mule_score": 0.02, "scam_score": 0.9},
        "app_safety": {"verdict": "CAUTION", "risk_score": 0.7, "source": "check", "resolution": "UNINSTALL_AND_RECHECK",
                       "attestation": "device", "findings_dropped": 0,
                       "findings": [{"scope": "app", "severity": "high", "package": "com.example.sample", "signal": "SCREEN_CAPTURE"},
                                    {"scope": "device", "severity": "low", "package": "device", "signal": "DEV_OPTIONS_ON"}]},
    },
    "outputs": {
        "decision": "hold", "band": "critical", "risk_score": 0.9,
        "reasons": [
            {"code": "SCAM_CONVERSATION", "weight": 0.9,
             "text_en": "The ongoing conversation shows signs of a scam. It is safer not to proceed now."},
            {"code": "ATO_BEHAVIOUR_MISMATCH", "weight": 0.7,
             "text_en": "We would like to confirm it is really you before this goes through."},
            {"code": "APP_SAFETY_CAUTION", "weight": 0.59,
             "text_en": "A suspicious app was found on your phone. Check the phone safety page."},
        ],
        "actions": [{"type": "hold_transaction", "params": {"minutes": 60}}],
        "signal_sources": {"call_active": "demo", "caller_in_contacts": "none", "screen_share": "none", "sim_swap": "none"},
        "payee_score_before": 0.02, "payee_score_with_this_transfer": 0.02,
    },
}


def warm_up(call: bool = False) -> bool:
    """Make the first reading after a deploy a warm one. Never raises; False when Gemini is off or the warm-up failed.

    A fresh instance's first model call is several times slower than the rest. One risk-mw revision's took 6.2 s
    against about 1.5 s; one console revision's first reading passed its 40 s timeout where later ones took 8.5 s; and
    on the next, after a tiny "say OK" warm-up, the first reading still took 23.2 s and the next 4.0 s for the same
    output. So the client and its first token are built now (risk-mw's genai_client.warm_up),
    and with `call` the warm-up is a full reading of SAMPLE_DOC: the same prompt, schema and limits as a real one
    (about $0.004 per start, counted in the spend ledger). Its answer is checked only to log how it went.
    """
    if not genai_client.warm_up():
        return False
    if not call:
        return True
    started = time.perf_counter()
    try:
        facts = basis(SAMPLE_DOC)
        system, contents = prompt(facts)
        result = gemini(system, contents, task="console_insight_warm_up", timeout_s=WARM_UP_TIMEOUT_S)
        answer = _parse(result) if result is not None else None
        problems = check(answer, facts) if answer is not None else ["no parsed answer"]
    except Exception as exc:  # noqa: BLE001 - a failed warm-up only means the first reading pays for it
        log.warning("Gemini warm-up reading failed after %.1f s (%s: %s)", time.perf_counter() - started, type(exc).__name__,
                    str(exc)[:200])
        return False
    log.info("Gemini warm-up reading done in %.1f s (%s)", time.perf_counter() - started,
             "passes the check" if not problems else f"{len(problems)} check problems")
    return True


def warm_up_from_env() -> bool:
    """The console's start-up hook: FINNEST_ADMIN_GEMINI_WARM_UP_CALL=true adds the model call (scripts/deploy.sh sets it)."""
    return warm_up(call=os.environ.get(WARM_UP_ENV, "").strip().lower() in {"1", "true", "yes"})


__all__ = ["Answer", "InsightUnavailable", "basis", "check", "explain", "forget", "gemini", "prompt", "warm_up",
           "warm_up_from_env"]
