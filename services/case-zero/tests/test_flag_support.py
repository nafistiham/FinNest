"""Flag support and the degraded status: a flag counts only through a call that shows it, and a done contract keeps
the shape risk-mw accepted before the degraded status existed."""

from test_orchestrator import good_draft
from test_case_honesty import BENIGN, EXCLUDED, _benign_script, flag

from case_zero.schemas import CaseDraft, RedFlag


# 1. The recorded demo draft must not lose every red flag: an unsupported flag first goes back to the writer with
#    the reason (sharing the one retry), and an agent-based flag may name the agent a cited call's output shows.
def _demo():
    import dataclasses
    import json
    from pathlib import Path
    from fake_llm import call, done
    from case_zero.config import Settings
    # The 2026-10-16 recording these cases were written against; the served replay was re-recorded on 2026-10-17.
    events = [json.loads(line) for line in (Path(__file__).resolve().parent / "fixtures" / "replay_2026-10-16.jsonl").read_text(encoding="utf-8").splitlines()]
    report = next(e for e in events if e["type"] == "report")["report"]
    script = [call(e["name"], **e["args"]) for e in events if e["type"] == "tool_call"] + [done("notes")]
    return report, script, CaseDraft.model_validate(report["draft"]), dataclasses.replace(Settings(), min_tool_calls=0)


def test_the_demo_draft_in_a_single_pass_keeps_its_onboarding_agent_flag(world):
    from fake_llm import draft
    from test_orchestrator import run
    from case_zero.schemas import to_contract
    recorded, script, demo, settings = _demo()
    report, events = run(world, script + [draft(demo)], seed=recorded["seed"], settings=settings)   # the retry gets no usable reply
    assert report.status == "done" and report.validation["first_pass"] == [] and report.action == "freeze"
    assert [f.code for f in report.draft.red_flags] == ["RF07"]   # names AG-0014, which tc_07 (shared_entities over members) shows
    assert any(v["code"] == "unsupported_flag" for v in report.validation["flag_feedback"])
    assert to_contract(report, report._ledger)["status"] == "done"


def test_a_writer_that_names_the_accounts_on_retry_keeps_its_flags(world):
    from fake_llm import FakeLLM, draft
    from test_orchestrator import run
    recorded, script, demo, settings = _demo()
    texts = {"RF04": "acct_rina's SIM was swapped just before she paid acct_01070", "RF01": "acct_01070 passed the money on within minutes",
             "RF02": "acct_01070 split the money across four accounts", "RF12": "acct_01070 has a high model score with matching reasons"}
    named = demo.model_copy(update={"red_flags": [f.model_copy(update={"text": texts.get(f.code, f.text)}) for f in demo.red_flags]})
    report, events = run(world, script + [draft(demo), draft(named)], seed=recorded["seed"], settings=settings)
    assert [f.code for f in report.draft.red_flags] == ["RF04", "RF01", "RF02", "RF07", "RF12"] and report.validation["flags_dropped"] == []
    assert report.status == "done" and report.validation["retried"] is True and report.validation["first_pass"] == []
    first = next(e for e in events if e["type"] == "validator" and e["attempt"] == 1)
    assert {v["code"] for v in first["violations"]} == {"unsupported_flag"} and first["pass"] is False


def test_the_retry_feedback_says_why_a_flag_is_unsupported(world):
    from fake_llm import FakeLLM, draft
    from test_orchestrator import NO_MIN, SCRIPT
    import asyncio
    from case_zero.config import DEMO_AS_OF, DEMO_SEED
    from case_zero.orchestrator import run_investigation
    unnamed = good_draft(red_flags=[{"code": "RF02", "text": "money fanned out within minutes", "evidence": ["tc_02"]}])
    llm = FakeLLM(SCRIPT + [draft(unnamed), draft(good_draft())])

    async def emit(_):
        return None
    report = asyncio.run(run_investigation(world, llm, DEMO_SEED, DEMO_AS_OF, emit, "CZ-0001", settings=NO_MIN))
    feedback = llm.calls[-1]["contents"][-1].parts[0].text
    assert "unsupported_flag" in feedback and "names no account" in feedback and "neighbours or velocity_stats" in feedback
    assert report.status == "done" and [f.code for f in report.draft.red_flags] == ["RF02"]


def test_an_agent_flag_counts_through_an_agent_id_a_cited_call_shows(world):
    from case_zero.config import DEMO_AS_OF, DEMO_SEED
    from case_zero.ledger import Ledger
    from case_zero.validator import flag_supported
    led = Ledger(world, DEMO_SEED, DEMO_AS_OF)
    led.prefetch_score()
    led.call("shared_entities", acct_ids=["acct_01070", "acct_01341", "acct_01870", "acct_00036", "acct_01288", "acct_01635"])   # tc_01: onboarding_agent:AG-0014
    case = {"acct_01070", "acct_01635"}
    assert flag_supported(flag("RF07", "Mule accounts share the same onboarding agent AG-0014.", "tc_01"), led, case)
    assert not flag_supported(flag("RF07", "Mule accounts share the same onboarding agent AG-0099.", "tc_01"), led, case)   # not in the output
    assert not flag_supported(flag("RF07", "Mule accounts share the same onboarding agent AG-0014.", "tc_01"), led, {"acct_09001"})   # not this case's accounts
    assert not flag_supported(flag("RF06", "Mule accounts share the same onboarding agent AG-0014.", "tc_01"), led, case)   # only agent-based codes


# 2. RF16 (an instruction in a tool output) says nothing about the account, so it never raises the action
def test_rf16_on_a_benign_seed_does_not_escalate(world):
    from fake_llm import draft
    from test_orchestrator import run
    from case_zero.config import Settings
    d = CaseDraft(typology="none", members=[], excluded=[], timeline=[], proposed_action="monitor", limitations="",
                  red_flags=[RedFlag(code="RF16", text=f"{BENIGN} shows no suspicious pattern.", evidence=["tc_01"])],
                  narrative_en=f"{BENIGN} shows no suspicious pattern.", narrative_bn=f"{BENIGN}-এ কোনো সন্দেহজনক প্যাটার্ন নেই।")
    report, _ = run(world, _benign_script() + [draft(d)], seed=BENIGN, settings=Settings())
    assert report.model_score == 0.0 and report.status == "done" and report.action == "close_no_action" and not report.escalated


# 3. The second citation check reads what the writer wrote, not the limitation lines code appended
def test_a_code_appended_limitation_does_not_fail_the_second_check(world):
    from fake_llm import draft
    from google.genai import errors as genai_errors
    from test_orchestrator import SCRIPT, run
    from case_zero.schemas import to_contract
    err = genai_errors.ServerError(503, {"error": {"message": "unavailable", "status": "UNAVAILABLE"}})
    unnamed = good_draft(red_flags=[*good_draft().red_flags, {"code": "RF12", "text": "high model score", "evidence": ["tc_00"]}])
    report, _ = run(world, SCRIPT + [err, draft(unnamed)])
    assert "503" in report.draft.limitations and report.status == "done" and report.action == "freeze"
    assert to_contract(report, report._ledger)["status"] == "done" and report.validation["post_gate"] == []


# 4. A done contract is exactly the shape risk-mw accepted before the degraded status, so Case Zero can deploy first
OLD_CASE_REPORT = '''
from typing import Literal
from pydantic import BaseModel, ConfigDict, Field


class Strict(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)


class Evidence(Strict):
    row_id: str
    claim: str


class CaseReport(Strict):
    case_id: str
    acct_id: str
    status: Literal["queued", "running", "done", "failed"]
    summary_en: str
    summary_bn: str
    evidence: tuple[Evidence, ...]
    ring: tuple[str, ...]
    confidence: float = Field(ge=0, le=1)
    recommended_action: str
    model_version: str
    redacted: bool = False  # optional: validation failed twice, so unsupported sentences were removed
'''   # risk-mw app/contracts.py at d33f1e1


def test_a_done_contract_validates_against_the_original_risk_mw_contract(world):
    from fake_llm import draft
    from test_orchestrator import SCRIPT, run
    from case_zero.schemas import to_contract
    old = {}
    exec(OLD_CASE_REPORT, old)   # noqa: S102 - a fixed copy of the old model
    report, _ = run(world, SCRIPT + [draft(good_draft(limitations="The till was not checked."))])
    contract = to_contract(report, report._ledger)
    assert report.status == "done" and not {"validation_errors", "limitations", "redacted"} & set(contract)
    assert old["CaseReport"](**contract).status == "done"


# 5. An excluded till is named by its account id or as "till AG-xxxx", never by the bare agent id
def test_an_excluded_till_does_not_strip_its_agent_as_an_onboarding_agent():
    from case_zero.gate import strip_accusations
    d = good_draft(narrative_en="acct_01070 and acct_01870 were both onboarded by agent AG-0014. acct_01870 cashed out at acct_till_AG-0014. Cash left through till ag-0014.",
                   red_flags=[{"code": "RF07", "text": "acct_01070 and acct_01870 share onboarding agent AG-0014", "evidence": ["tc_01"]}])
    out, notes = strip_accusations(d, {"acct_till_AG-0014"})
    assert out.narrative_en == "acct_01070 and acct_01870 were both onboarded by agent AG-0014." and [f.code for f in out.red_flags] == ["RF07"]
    assert len(notes) == 2


# 6. Sentences: "A Bangla", abbreviations are not sentence ends, and paragraph breaks survive
def test_stripping_keeps_abbreviations_and_paragraphs():
    from case_zero.gate import strip_accusations
    d = good_draft(narrative_en=f"acct_rina sent Tk. 7,900 to acct_01070 at 14:13. {EXCLUDED} took approx. Tk. 1,850 from it.\n\nacct_01070 forwarded Tk 1,850 to acct_01870.",
                   narrative_bn=f"acct_rina ১৪:১৩-এ acct_01070-এ ৭,৯০০ টাকা পাঠান। {EXCLUDED} ১,৮৫০ টাকা নেয়।\n\nacct_01070 acct_01870-এ ১,৮৫০ টাকা পাঠায়।")
    out, notes = strip_accusations(d, {EXCLUDED})
    assert out.narrative_en == "acct_rina sent Tk. 7,900 to acct_01070 at 14:13.\n\nacct_01070 forwarded Tk 1,850 to acct_01870."
    assert out.narrative_bn == "acct_rina ১৪:১৩-এ acct_01070-এ ৭,৯০০ টাকা পাঠান।\n\nacct_01070 acct_01870-এ ১,৮৫০ টাকা পাঠায়।"
    assert "A Bangla narrative sentence removed" in " ".join(notes) and "An English narrative sentence removed" in " ".join(notes)


# 7. The console shows the status a case leaves with
def test_the_report_carries_its_exported_status_for_the_console():
    from pathlib import Path
    from case_zero.schemas import CaseReport
    r = CaseReport(case_id="CZ-0001", seed="acct_01070", as_of="2026-11-10T14:35:00", status="failed_after_retry", draft=good_draft(), model_score=0.87,
                   top_reasons=[], action="freeze", floor_action="freeze", escalated=False, validation={}, model_version="m", cost={}, tool_calls=1)
    assert r.model_dump()["exported_status"] == "degraded"
    assert "r.exported_status" in (Path(__file__).resolve().parents[1] / "static" / "index.html").read_text(encoding="utf-8")
