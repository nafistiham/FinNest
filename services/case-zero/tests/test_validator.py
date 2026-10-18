import importlib.util
import sys

import pytest

from case_zero import PROJECT_DIR
from case_zero.ledger import Ledger
from case_zero.schemas import CaseDraft, CaseReport, to_contract
from case_zero.validator import normalise_amounts, redact, validate

AFTER = "2026-11-10T16:00:00"


@pytest.fixture()
def ledger(world):
    led = Ledger(world, "acct_01070", AFTER)
    led.prefetch_score()
    led.call("path_between", source="acct_rina", target="acct_till_AG-0192")  # tc_01
    return led


def draft(**over):
    base = dict(
        typology="otp_takeover_cashout",
        members=[{"acct_id": "acct_01070", "role": "mule_L1", "evidence": ["tc_01"]}],
        excluded=[], red_flags=[{"code": "RF03", "text": "Tk 7,900 moved on within minutes", "evidence": ["tc_01"]}],
        timeline=[{"ts": "2026-11-10T14:13:00", "text": "Rina sends Tk 7,900", "evidence": ["tc_01"]}],
        proposed_action="freeze",
        narrative_en="acct_rina sent Tk 7,900 to acct_01070 at 14:13; acct_01870 cashed out Tk 1,850 at acct_till_AG-0192.",
        narrative_bn="acct_rina ১৪:১৩-এ acct_01070-এ ৭,৯০০ টাকা পাঠান; acct_01870 acct_till_AG-0192-এ ১,৮৫০ টাকা ক্যাশ আউট করে।",
        limitations="",
    )
    return CaseDraft(**{**base, **over})


def test_amount_forms_normalise():
    for text in ("Tk 7,900", "৳৭,৯০০", "৭৯০০ টাকা", "7900.0", "7.9k"):
        assert normalise_amounts(text) == {7900}, text


def test_ids_times_and_years_are_not_amounts():
    assert normalise_amounts("acct_01070 at 14:13 on 2026-11-10, 3 hops, 2026") == set()


def test_clean_draft_passes(ledger):
    assert validate(draft(), ledger) == []


def test_unknown_id_rejected(ledger):
    v = validate(draft(narrative_en="acct_09999 received Tk 7,900."), ledger)
    assert any(x.code == "unknown_id" and "acct_09999" in x.detail for x in v)


def test_unknown_amount_rejected(ledger):
    v = validate(draft(narrative_en="acct_rina lost Tk 9,999 to acct_01070."), ledger)
    assert any(x.code == "unknown_amount" and "9999" in x.detail for x in v)


def test_citation_must_exist(ledger):
    v = validate(draft(red_flags=[{"code": "RF03", "text": "fast", "evidence": ["tc_99"]}]), ledger)
    assert any(x.code == "missing_citation" for x in v)


def test_member_must_appear_in_cited_call(ledger):
    v = validate(draft(members=[{"acct_id": "acct_01070", "role": "mule_L1", "evidence": ["tc_00"]}, {"acct_id": "acct_01341", "role": "controller", "evidence": ["tc_01"]}]), ledger)
    assert any(x.code == "member_not_in_citation" and "acct_01341" in x.detail for x in v)


def test_en_bn_same_ids_and_amounts(ledger):
    v = validate(draft(narrative_bn="acct_rina ৭,৯০০ টাকা পাঠান।"), ledger)
    assert any(x.code == "en_bn_mismatch" for x in v)


def test_unknown_time_rejected(ledger):
    v = validate(draft(narrative_en="acct_rina sent Tk 7,900 to acct_01070 at 13:59.", narrative_bn="acct_rina ১৩:৫৯-এ acct_01070-এ ৭,৯০০ টাকা পাঠান।"), ledger)
    assert any(x.code == "unknown_time" for x in v)


def test_redact_removes_offending_sentences(ledger):
    bad = draft(narrative_en="acct_rina sent Tk 7,900 to acct_01070. acct_09999 got Tk 9,999.")
    fixed = redact(bad, validate(bad, ledger))
    assert "acct_09999" not in fixed.narrative_en and "acct_01070" in fixed.narrative_en
    assert "removed" in fixed.limitations


def test_to_contract_matches_risk_mw(ledger):
    spec = importlib.util.spec_from_file_location("risk_contracts", PROJECT_DIR / "services" / "risk-mw" / "app" / "contracts.py")
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod  # pydantic resolves postponed annotations through sys.modules
    spec.loader.exec_module(mod)
    report = CaseReport(case_id="CZ-0001", seed="acct_01070", as_of=AFTER, status="done", draft=draft(), model_score=0.87, top_reasons=[],
                        action="freeze", floor_action="freeze", escalated=False, validation={"first_pass": [], "final": [], "retried": False},
                        model_version="mule-lgbm-0.1+gemini-3.8-flash", cost={}, tool_calls=1)
    contract = mod.CaseReport(**to_contract(report, ledger))
    assert contract.ring == ("acct_01070",) and contract.confidence == 0.87 and contract.recommended_action == "freeze"
    assert contract.evidence[0].row_id.startswith("txn_")
