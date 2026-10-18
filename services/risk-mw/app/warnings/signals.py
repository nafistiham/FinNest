"""What risk-mw already verified about her phone and how it is being used, as closed-set facts for Apa's warning.

FinNest no longer listens to calls (2026-10-17), so a hold's warning has no call tactics to describe. Three things the
server already knows take their place, read at /v1/intervene, after the hold, never on the scoring path:

- her phone: the latest App Safety Check result for this uid (`app.appsafety_engine`; the phone only collects,
  POST /v1/appsafety/check decides and keeps the answer), its high and critical findings and its attestation;
- how the phone is being used: the behaviour model's last scored session for this user (`app.ato`), whether it
  is unlike her usual or looks coached, and which feature groups pushed it;
- why the app held it: the reasons /v1/risk/score recorded on the hold (interventions/{id}.reason_codes), or the trigger
  the app named when the server has no record of the hold (2026-10-18).

Only codes leave this module (planner.PHONE_FACTS, planner.BEHAVIOUR_FACTS, planner.HOLD_FACTS): no app name, package,
account, amount, score or value.
"""

from __future__ import annotations

from collections.abc import Iterable

from app import appsafety_engine, apa, ato
from app.settings import Settings
from app.warnings.planner import BEHAVIOUR_FACTS, HOLD_FACTS, PHONE_FACTS

MAX_PHONE_FACTS = 2
MAX_BEHAVIOUR_GROUPS = 2
MAX_HOLD_FACTS = 2
# app.rules reason codes -> the fact Apa may state. The others (a scam conversation the server no longer hears, the
# session model, App Safety's own block, her Money Lock) have no fact of their own here.
REASON_FACT = {"DEST_MULE_RISK": "PAYEE_MULE", "SIM_CHANGED_24H": "SIM_CHANGED", "CALL_ACTIVE_NON_CONTACT": "CALL_ON",
               "NEW_PAYEE_ABOVE_P95": "NEW_PAYEE_LARGE"}
SEVERE = frozenset({"high", "critical"})
# App Safety's finding signals (bhorosha_app_safety_check.schema) -> the fact Apa may state. Signals not listed here
# (overlay ability, hidden icons, developer options, ...) are reasons for the verdict but not something to say aloud.
SIGNAL_FACT = {"KNOWN_RAT": "REMOTE_CONTROL", "SIDELOADED_ACCESSIBILITY": "REMOTE_CONTROL", "INTEGRITY_CONTROLLING": "REMOTE_CONTROL",
               "CLIENT_TAMPERED": "MODIFIED_APP", "INTEGRITY_CAPTURING": "SCREEN_CAPTURE",
               "SMS_ROLE_TAKEOVER": "READS_MESSAGES", "NOTIFICATION_LISTENER": "READS_MESSAGES",
               "BRAND_IMPERSONATION": "FAKE_APP", "LOAN_APP_DATA_HARVEST": "FAKE_LOAN_APP",
               "DEVICE_ROOTED": "UNSAFE_PHONE", "DEVICE_INTEGRITY_FAILED": "UNSAFE_PHONE"}
# What the server concluded about the client itself (AppSafetyResponse.attestation).
ATTESTATION_FACT = {"tampered": "MODIFIED_APP", "virtual": "UNSAFE_PHONE"}
# bhorosha_ato.schema blocks -> what a person would notice.
BLOCK_FACT = {"swipe": "SWIPE", "tap": "TOUCH", "pressure": "TOUCH", "size": "TOUCH", "pin": "TYPING", "keyrank": "TYPING",
              "imu": "HOLDING"}


def facts_from(findings: Iterable[tuple[str, str]], attestation: str) -> tuple[str, ...]:
    """The phone facts in (signal, severity) findings and an attestation, most dangerous first, at most MAX_PHONE_FACTS.
    Only high and critical findings with a mapped signal count; the rest are reasons for a verdict, not words to say."""
    found = {ATTESTATION_FACT[attestation]} if attestation in ATTESTATION_FACT else set()
    for signal, severity in findings:
        if severity in SEVERE and signal in SIGNAL_FACT:
            found.add(SIGNAL_FACT[signal])
    return tuple(f for f in PHONE_FACTS if f in found)[:MAX_PHONE_FACTS]


def phone_facts(uid: str) -> tuple[str, ...]:
    """Her phone's facts, most dangerous first; () when nothing valid is known.

    The server's own App Safety result explains the verdict unless the phone reported a stronger one with its last score
    : after a restart, on another instance or once the server's entry expired, the phone's report is
    what made the hold, so it is what the warning describes."""
    entry = appsafety_engine.remembered(uid)
    reported = appsafety_engine.carried_for(uid)
    rank = appsafety_engine.VERDICT_RANK
    if entry is not None and (reported is None or rank[entry.verdict] >= rank[reported.verdict]):
        findings = entry.response.findings if entry.response is not None else ()
        return facts_from(((f.signal, f.severity) for f in findings), entry.attestation)
    return reported.facts if reported is not None else ()


def hold_facts(reason_codes: Iterable[str] | None, trigger: str | None = None) -> tuple[str, ...]:
    """Why the hold was made, most telling first, at most MAX_HOLD_FACTS: the reasons the server recorded on the hold, else
    the trigger the app named (old names map through app.apa.reason_code; the app lower-cases a code it has no name for,
    "dest_mule_risk"). The server's record wins: the trigger is the app's choice of one reason, the record is every one."""
    codes = [str(c) for c in reason_codes or ()] or ([trigger] if trigger else [])
    found = {REASON_FACT.get(apa.reason_code(code).upper()) for code in codes}
    return tuple(f for f in HOLD_FACTS if f in found)[:MAX_HOLD_FACTS]


def behaviour_facts(user_id: str, settings: Settings) -> tuple[str, ...]:
    """What her last scored session showed: unlike her usual (only against a model of her own) with the groups that
    differed most, and coaching. () for a clean, missing or stale session."""
    evidence = ato.latest_evidence(user_id, settings.behaviour_evidence_ttl_s)
    if evidence is None:
        return ()
    out: list[str] = []
    if evidence.not_her and not evidence.cold_start:
        out.append("NOT_HER_PATTERN")
        groups = dict.fromkeys(BLOCK_FACT[b] for b in evidence.blocks if b in BLOCK_FACT)
        out.extend(list(groups)[:MAX_BEHAVIOUR_GROUPS])
    if evidence.coached:
        out.append("COACHED_PATTERN")
    return tuple(f for f in out if f in BEHAVIOUR_FACTS)
