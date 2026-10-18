"""Apa's warning reads what risk-mw already verified about the phone and how it is being used (2026-10-17).

FinNest no longer listens to calls, so a hold's warning had no call tactics to describe. App Safety's stored result for
the customer and the behaviour model's last scored session become closed-set facts in the plan; Gemini
phrases them after the hold, off the scoring path, and the validator lets a fact's words through only when the plan
holds that fact. No app name, package, score or feature value reaches the model.
"""

from __future__ import annotations

import re
import time

import pytest

from app import appsafety_engine, ato
from app import warnings as apa_warnings
from app.contracts import AppSafetyResponse, Finding
from app.ledger import Ledger
from app.settings import Settings
from app.warnings import composer, planner, signals
from app.warnings.validator import validate, validate_en

RAT = "com.anydesk.anydeskandroid"  # conftest's fresh_state clears App Safety results and behaviour sessions per test


def _finding(signal: str, severity: str = "high", package: str = RAT, scope: str = "app") -> Finding:
    return Finding(package=package, signal=signal, severity=severity, evidence="e", explanation_bn="ব্যাখ্যা",
                   explanation_en="why", scope=scope)


def _checked(uid: str, *findings: Finding, attestation: str = "none", verdict: str = "BLOCK") -> None:
    """Her latest App Safety result, stored the way POST /v1/appsafety/check stores it."""
    response = AppSafetyResponse(verdict=verdict, risk_score=0.9, findings=findings, recommended_action="UNINSTALL",
                                 apps_to_uninstall=(), user_message_bn="", user_message_en="", simulated_verdict=False,
                                 attestation=attestation)
    appsafety_engine.remember_verdict(uid, verdict, 0.9, app_count=40, flagged=frozenset(f.package for f in findings),
                                      attestation=attestation, settings=Settings(), response=response)


def _scored(user_id: str, *, not_her: bool = False, coached: bool = False, blocks: tuple[str, ...] = (),
            cold_start: bool = False, at: float | None = None) -> None:
    """Her last behaviour session, as app.ato records it when it scores one."""
    ato.remember_evidence(user_id, ato.BehaviourEvidence(
        ato_score=0.91 if not_her else 0.1, coaching_score=0.75 if coached else 0.1, not_her=not_her, coached=coached,
        blocks=blocks, cold_start=cold_start, at=time.monotonic() if at is None else at))


# --- the phone: App Safety's stored result ---------------------------------------------------------------------------


def test_no_safety_check_means_no_phone_facts():
    assert signals.phone_facts("rina") == ()


def test_the_two_most_dangerous_findings_become_phone_facts():
    _checked("rina", _finding("NOTIFICATION_LISTENER"), _finding("KNOWN_RAT"),
             _finding("CLIENT_TAMPERED", "critical", package="com.finnest.app", scope="device"), attestation="tampered")
    assert signals.phone_facts("rina") == ("REMOTE_CONTROL", "MODIFIED_APP")


def test_low_and_medium_findings_are_not_phone_facts():
    _checked("rina", _finding("OVERLAY_CAPABLE", "medium"), _finding("SIDELOADED_DATA_REACH", "low"), verdict="CAUTION")
    assert signals.phone_facts("rina") == ()


@pytest.mark.parametrize(("finding", "attestation", "fact"), [
    (None, "virtual", "UNSAFE_PHONE"),                       # an emulator
    ("DEVICE_ROOTED", "none", "UNSAFE_PHONE"),
    ("SMS_ROLE_TAKEOVER", "none", "READS_MESSAGES"),
    ("INTEGRITY_CAPTURING", "none", "SCREEN_CAPTURE"),
    ("SIDELOADED_ACCESSIBILITY", "none", "REMOTE_CONTROL"),
    ("BRAND_IMPERSONATION", "none", "FAKE_APP"),
    ("LOAN_APP_DATA_HARVEST", "none", "FAKE_LOAN_APP"),
])
def test_each_kind_of_finding_has_its_fact(finding, attestation, fact):
    _checked("rina", *((_finding(finding),) if finding else ()), attestation=attestation)
    assert signals.phone_facts("rina") == (fact,)


def test_another_customers_check_is_not_hers():
    _checked("rahima", _finding("KNOWN_RAT"))
    assert signals.phone_facts("rina") == ()


# --- how the phone is being used: the behaviour model's last session ------------------------------------------------


def test_no_scored_session_means_no_behaviour_facts():
    assert signals.behaviour_facts("rina", Settings()) == ()


def test_a_stranger_on_her_phone_is_not_her_with_what_differs_first():
    _scored("rina", not_her=True, blocks=("swipe", "imu", "swipe", "pin"))
    assert signals.behaviour_facts("rina", Settings()) == ("NOT_HER_PATTERN", "SWIPE", "HOLDING")


def test_coaching_is_its_own_fact():
    _scored("rina", coached=True, blocks=("swipe",))
    assert signals.behaviour_facts("rina", Settings()) == ("COACHED_PATTERN",)


def test_a_clean_session_a_stale_one_or_a_cold_start_one_says_nothing_about_her_usual():
    _scored("rina")
    assert signals.behaviour_facts("rina", Settings()) == ()
    _scored("rina", not_her=True, blocks=("swipe",), at=time.monotonic() - 3600)
    assert signals.behaviour_facts("rina", Settings(behaviour_evidence_ttl_s=900)) == ()
    _scored("rina", not_her=True, coached=True, blocks=("swipe",), cold_start=True)   # no model of her own: no "usual"
    assert signals.behaviour_facts("rina", Settings()) == ("COACHED_PATTERN",)


# --- the plan --------------------------------------------------------------------------------------------------------


def test_phone_and_behaviour_facts_reach_the_plan_glossed_with_no_app_name():
    p = planner.plan(Ledger(), "send_money", "possible", phone=("REMOTE_CONTROL", "NOPE"), behaviour=("NOT_HER_PATTERN", "SWIPE"))
    facts = p.facts()
    assert facts["phone"] == [{"fact": "REMOTE_CONTROL", "means": planner.PHONE_GLOSS["REMOTE_CONTROL"],
                               "rule": planner.phone_rule("REMOTE_CONTROL", "FinNest")}]
    assert [b["fact"] for b in facts["behaviour"]] == ["NOT_HER_PATTERN", "SWIPE"]
    assert p.action == "dont_send"
    assert "anydesk" not in p.to_prompt().lower() and not re.search(r"\d\.\d", p.to_prompt())


def test_a_call_plan_without_these_facts_reads_and_hashes_as_before():
    ledger = Ledger()
    p = planner.plan(ledger, "send_money", "possible")
    assert "phone" not in p.facts() and "behaviour" not in p.facts()
    assert planner.key(ledger, "send_money", "possible") == planner.key(ledger, "send_money", "possible", phone=(), behaviour=())
    with_phone = planner.key(ledger, "send_money", "possible", phone=("REMOTE_CONTROL",))
    assert with_phone != planner.key(ledger, "send_money", "possible")
    assert with_phone != planner.key(ledger, "send_money", "possible", phone=("READS_MESSAGES",))
    assert planner.key(ledger, "send_money", "possible", behaviour=("NOT_HER_PATTERN",)) != planner.key(ledger, "send_money", "possible")


SCREEN_LINE = "আপনার ফোনের কোনো অ্যাপ স্ক্রিন দেখতে ও চালাতে পারে।"
CODE_LINE = "আপনার ফোনের কোনো অ্যাপ মেসেজে আসা কোড পড়তে পারে।"


def test_a_fact_licenses_its_own_words_and_no_others():
    screen = planner.plan(Ledger(), "send_money", "possible", phone=("REMOTE_CONTROL",))
    messages = planner.plan(Ledger(), "send_money", "possible", phone=("READS_MESSAGES",))
    bare = planner.plan(Ledger(), "send_money", "possible")
    assert validate("T", SCREEN_LINE, screen, ()).ok
    assert validate("T", SCREEN_LINE, bare, ()).rule == "ledger"
    assert validate("T", SCREEN_LINE, messages, ()).rule == "ledger"
    assert validate("T", CODE_LINE, messages, ()).ok
    assert validate("T", CODE_LINE, screen, ()).rule == "ledger"


# --- the composer's instruction --------------------------------------------------------------------------------------


def _example(prompt: str, marker: str) -> dict[str, tuple[str, str]]:
    # This example only: read to the end, the dict kept the LAST example's lines, so these tests checked whichever example
    # came last (a SIM_CHANGED PIN-reset example after them failed the behaviour plan, 2026-10-18).
    block = prompt.split(marker, 1)[1].split("\n\nExample", 1)[0]
    return {role: (bn, en) for role, bn, en in composer.parse([block], order=("A", "T", "R", "X"))}


def test_the_system_prompt_no_longer_assumes_a_call_and_its_phone_example_validates():
    settings = Settings()
    text = composer.system_prompt(settings)
    assert "A phone call is going on" not in text and "phone facts" in text
    lines = _example(text, "Example, for a plan with the phone fact REMOTE_CONTROL")
    assert set(lines) == {"A", "T", "R", "X"}
    p = planner.plan(Ledger(), "send_money", "possible", phone=("REMOTE_CONTROL",))
    for role, (bn, en) in lines.items():
        assert validate(role, bn, p, ()).ok, (role, bn, validate(role, bn, p, ()).rule)
        assert validate_en(role, en).ok, (role, en)


def test_the_behaviour_example_validates_and_line_r_has_its_own_guidance():
    """Live on 2026-10-17 a behaviour warning's R line said "a real bank never blocks this way of working": the call-style
    rule line has nothing true to say about how a phone is used, so behaviour facts get their own R guidance and example."""
    settings = Settings()
    text = composer.system_prompt(settings)
    assert "For behaviour facts, line R" in text and "never say a bank blocks" in text
    lines = _example(text, "Example, for a plan with the behaviour fact NOT_HER_PATTERN")
    assert set(lines) == {"A", "T", "R", "X"}
    p = planner.plan(Ledger(), "send_money", "possible", behaviour=("NOT_HER_PATTERN", "SWIPE"))
    for role, (bn, en) in lines.items():
        assert validate(role, bn, p, ()).ok, (role, bn, validate(role, bn, p, ()).rule)
        assert validate_en(role, en).ok, (role, en)
    assert settings.brand_bn in lines["R"][0]   # the rule names FinNest checking, not a bank's habit


# --- compose(): what /v1/intervene and /v1/apa/why call --------------------------------------------------------------


@pytest.fixture
def captured(monkeypatch):
    plans = []

    def fake_generate(p, caller_turns, settings, last_good=None, offline=False):
        plans.append(p)
        return composer.Warning()
    monkeypatch.setattr(apa_warnings, "generate", fake_generate)
    return plans


def test_compose_writes_from_her_phone_and_behaviour_facts(captured):
    _checked("rina", _finding("KNOWN_RAT"))
    _scored("rina", not_her=True, blocks=("swipe",))
    out = apa_warnings.compose("rina", "rina", None, "send_money", Settings())
    assert captured[0].phone == ("REMOTE_CONTROL",) and captured[0].behaviour == ("NOT_HER_PATTERN", "SWIPE")
    assert out.ledger_hash != planner.key(Ledger(), "send_money", "possible")


def test_compose_with_nothing_found_is_unchanged(captured):
    out = apa_warnings.compose("rina", "rina", None, "send_money", Settings())
    assert captured[0].phone == () and captured[0].behaviour == ()
    assert out.ledger_hash == planner.key(Ledger(), "send_money", "possible")


def test_a_broken_signal_store_costs_the_facts_never_the_warning(captured, monkeypatch):
    def broken(*args, **kwargs):
        raise RuntimeError("store down")
    monkeypatch.setattr(signals, "phone_facts", broken)
    monkeypatch.setattr(signals, "behaviour_facts", broken)
    apa_warnings.compose("rina", "rina", None, "send_money", Settings())
    assert captured[0].phone == () and captured[0].behaviour == ()


# --- the phone's own report, when the server has none (2026-10-18) ---------------------------------
# The score carries the phone's copy of its App Safety Check. The server keeps that copy apart from its own verdicts
# (a client never writes the server's standing verdict), and FNA's warning reads it when the server has nothing as strong:
# after a restart, on another instance, or once the server's own entry expired.

from datetime import UTC, datetime, timedelta  # noqa: E402

from app.contracts import AppSafetyContext  # noqa: E402

AS_RINA = {"X-Demo-User": "rina"}  # the uid the app scores, checks and is warned under


def _reported(verdict: str = "CAUTION", *pairs: tuple[str, str], attestation: str = "none", **extra) -> AppSafetyContext:
    return AppSafetyContext.model_validate({
        "verdict": verdict, "risk_score": 0.6, "attestation": attestation,
        "findings": [{"package": RAT, "signal": s, "severity": sev} for s, sev in pairs], **extra})


def test_facts_from_maps_signals_and_attestation_most_dangerous_first():
    pairs = [("NOTIFICATION_LISTENER", "critical"), ("KNOWN_RAT", "high"), ("OVERLAY_ABILITY", "critical"), ("SMS_ROLE_TAKEOVER", "low")]
    assert signals.facts_from(pairs, "tampered") == ("REMOTE_CONTROL", "MODIFIED_APP")
    assert signals.facts_from([("SMS_ROLE_TAKEOVER", "medium")], "none") == ()
    assert signals.facts_from([], "virtual") == ("UNSAFE_PHONE",)


def test_phone_facts_survive_a_restart(client, score_body):
    body = {**score_body, "app_safety": {"verdict": "CAUTION", "risk_score": 0.5,
                                         "findings": [{"package": RAT, "signal": "SIDELOADED_ACCESSIBILITY", "severity": "high"}]}}
    assert appsafety_engine.remembered("rina") is None   # this instance never ran her check (a restart, another instance)
    assert client.post("/v1/risk/score", json=body, headers=AS_RINA).status_code == 200
    assert signals.phone_facts("rina") == ("REMOTE_CONTROL",)


def test_the_server_check_wins_over_the_phone_copy():
    _checked("rina", _finding("KNOWN_RAT"))
    appsafety_engine.remember_carried("rina", _reported("BLOCK", ("LOAN_APP_DATA_HARVEST", "high")))
    assert signals.phone_facts("rina") == ("REMOTE_CONTROL",)


def test_a_stronger_phone_report_explains_itself():
    _checked("rina", verdict="SAFE")
    appsafety_engine.remember_carried("rina", _reported("CAUTION", ("SMS_ROLE_TAKEOVER", "high")))
    assert signals.phone_facts("rina") == ("READS_MESSAGES",)


def test_an_expired_phone_copy_gives_no_facts():
    past = (datetime.now(UTC) - timedelta(minutes=1)).isoformat()
    appsafety_engine.remember_carried("rina", _reported("BLOCK", ("KNOWN_RAT", "high"), valid_until=past))
    assert appsafety_engine.carried_for("rina") is None and signals.phone_facts("rina") == ()


def test_an_undated_phone_copy_lasts_the_servers_ttl(monkeypatch):
    appsafety_engine.remember_carried("rina", _reported("CAUTION", ("KNOWN_RAT", "high")))
    assert appsafety_engine.carried_for("rina") is not None
    later = time.monotonic() + Settings().appsafety_verdict_ttl_s + 1
    monkeypatch.setattr(appsafety_engine.time, "monotonic", lambda: later)
    assert appsafety_engine.carried_for("rina") is None


def test_a_far_future_valid_until_is_capped_at_a_day(monkeypatch):
    far = (datetime.now(UTC) + timedelta(days=30)).isoformat()
    appsafety_engine.remember_carried("rina", _reported("BLOCK", ("KNOWN_RAT", "high"), valid_until=far))
    later = time.monotonic() + Settings().appsafety_block_ttl_s + 1
    monkeypatch.setattr(appsafety_engine.time, "monotonic", lambda: later)
    assert appsafety_engine.carried_for("rina") is None


def test_a_later_safe_report_replaces_the_risky_one():
    appsafety_engine.remember_carried("rina", _reported("CAUTION", ("KNOWN_RAT", "high")))
    appsafety_engine.remember_carried("rina", _reported("SAFE"))
    assert signals.phone_facts("rina") == ()


def test_a_stale_report_is_not_remembered(client, score_body):
    past = (datetime.now(UTC) - timedelta(minutes=1)).isoformat()
    body = {**score_body, "app_safety": {"verdict": "BLOCK", "valid_until": past,
                                         "findings": [{"package": RAT, "signal": "KNOWN_RAT", "severity": "high"}]}}
    assert client.post("/v1/risk/score", json=body, headers=AS_RINA).status_code == 200
    assert appsafety_engine.carried_for("rina") is None


def test_the_phone_store_keeps_only_the_newest(monkeypatch):
    monkeypatch.setattr(appsafety_engine, "_CARRIED_LIMIT", 2)
    for uid in ("a", "b", "c"):
        appsafety_engine.remember_carried(uid, _reported("CAUTION", ("KNOWN_RAT", "high")))
    assert appsafety_engine.carried_for("a") is None and appsafety_engine.carried_for("c") is not None


def test_the_phone_report_never_becomes_the_servers_verdict(client, score_body):
    appsafety_engine.remember_carried("rina", _reported("BLOCK", ("KNOWN_RAT", "high")))
    assert appsafety_engine.latest_verdict("rina") is None
    assert appsafety_engine.latest_for("rina").known is False
    out = client.post("/v1/risk/score", json=score_body, headers=AS_RINA).json()   # no block on this score: nothing to fuse
    assert out["decision"] == "allow"


def test_compose_writes_from_the_phone_report_when_the_server_has_none(captured):
    appsafety_engine.remember_carried("rina", _reported("BLOCK", ("SMS_ROLE_TAKEOVER", "critical"), ("KNOWN_RAT", "high")))
    apa_warnings.compose("rina", "rina", None, "send_money", Settings())
    assert captured[0].phone == ("REMOTE_CONTROL", "READS_MESSAGES")


# Final review, Important 3: the phone's report is client data on a single instance; the store keeps only what the
# warning needs (the verdict and the closed-set facts), never the packages or strings the phone sent.

def test_the_phone_store_keeps_no_client_text():
    long_package = "com." + "x" * 250
    ctx = AppSafetyContext.model_validate({"verdict": "BLOCK", "risk_score": 0.9, "apps_to_uninstall": [long_package],
                                           "findings": [{"package": long_package, "signal": "KNOWN_RAT", "severity": "high"}]})
    appsafety_engine.remember_carried("rina", ctx)
    entry = appsafety_engine.carried_for("rina")
    assert entry.verdict == "BLOCK" and entry.facts == ("REMOTE_CONTROL",)
    assert long_package not in repr(appsafety_engine._CARRIED["rina"])
