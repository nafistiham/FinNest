"""Case Zero honesty: flag codes from a fixed catalogue, benign seeds stay closed, and the citation check says what it
guarantees."""

from typing import get_args

import pytest
from pydantic import ValidationError
from test_orchestrator import good_draft

from case_zero import prompts
from case_zero.schemas import CaseDraft, FlagCode, RedFlag


# RF6: red flags are a closed set of codes ---------------------------------------------------------------
def test_an_invented_red_flag_code_is_rejected_at_parse_time():
    with pytest.raises(ValidationError):
        RedFlag(code="RF99", text="No suspicious pattern was found.", evidence=["tc_01"])
    reply = good_draft().model_dump_json().replace('"RF02"', '"RF99"')   # the writer's JSON, as Gemini returns it
    with pytest.raises(ValidationError):
        CaseDraft.model_validate_json(reply)


def test_flag_codes_are_exactly_the_writers_catalogue():
    assert set(get_args(FlagCode)) == set(prompts.RED_FLAGS)


def test_the_schema_gemini_fills_lists_only_catalogue_codes():
    code = CaseDraft.model_json_schema()["$defs"]["RedFlag"]["properties"]["code"]
    assert sorted(code["enum"]) == sorted(prompts.RED_FLAGS)


# RF6: a flag counts only when it cites a call of a tool that can show it, for an account it names -------
BENIGN = "acct_09001"   # "Customer with a new phone": model score 0.0 at the demo time


@pytest.fixture()
def benign_ledger(world):
    from case_zero.config import DEMO_AS_OF
    from case_zero.ledger import Ledger
    led = Ledger(world, BENIGN, DEMO_AS_OF)
    led.prefetch_score()                                   # tc_00 seed_brief
    led.call("get_account", acct_id=BENIGN)                # tc_01 the account profile
    led.call("velocity_stats", acct_id=BENIGN)             # tc_02
    led.call("velocity_stats", acct_id="acct_01070")       # tc_03 another account
    led.call("agent_till_stats", agent_id="AG-0192")       # tc_04
    return led


def flag(code, text, *evidence):
    return RedFlag(code=code, text=text, evidence=list(evidence))


def test_rf03_cited_to_an_account_profile_call_does_not_count(benign_ledger):
    from case_zero.policy import escalation_flags
    assert escalation_flags([flag("RF03", f"{BENIGN} cashed out right after receipt", "tc_01")], benign_ledger) == 0


def test_rf03_cited_to_a_velocity_call_for_the_named_account_counts(benign_ledger):
    from case_zero.policy import escalation_flags
    assert escalation_flags([flag("RF03", f"{BENIGN} cashed out right after receipt", "tc_02")], benign_ledger) == 1


def test_the_fitting_call_must_be_for_an_account_the_flag_names(benign_ledger):
    from case_zero.policy import escalation_flags
    assert escalation_flags([flag("RF03", f"{BENIGN} cashed out right after receipt", "tc_03")], benign_ledger) == 0   # velocity of acct_01070
    assert escalation_flags([flag("RF03", "money was cashed out right after receipt", "tc_02")], benign_ledger) == 0   # names no account


def test_a_till_named_by_account_or_agent_id_matches_agent_till_stats(benign_ledger):
    from case_zero.policy import escalation_flags
    assert escalation_flags([flag("RF09", "acct_till_AG-0192 has repeat counterparties", "tc_04")], benign_ledger) == 1
    assert escalation_flags([flag("RF09", "AG-0192's till has repeat counterparties", "tc_04")], benign_ledger) == 1


def test_the_score_flag_never_counts_even_when_cited_to_tc_00(benign_ledger):
    from case_zero.policy import escalation_flags
    assert escalation_flags([flag("RF12", f"{BENIGN} has a high model score", "tc_00")], benign_ledger) == 0


def test_every_catalogue_code_names_real_tools():
    from case_zero.tools import KNOWN_TOOLS, SEED_BRIEF
    from case_zero.validator import FLAG_EVIDENCE
    assert set(FLAG_EVIDENCE) == set(prompts.RED_FLAGS)
    assert all(tools and tools <= KNOWN_TOOLS | {SEED_BRIEF} for tools in FLAG_EVIDENCE.values())
    assert FLAG_EVIDENCE["RF16"] == KNOWN_TOOLS | {SEED_BRIEF}   # an instruction can hide in any tool's output


def test_the_validator_drops_unsupported_flags_and_says_so(benign_ledger):
    from case_zero.validator import drop_unsupported_flags
    d = good_draft(red_flags=[flag("RF03", f"{BENIGN} cashed out right after receipt", "tc_01"), flag("RF01", f"{BENIGN} passed money straight on", "tc_02")])
    kept, notes = drop_unsupported_flags(d, benign_ledger)
    assert [f.code for f in kept.red_flags] == ["RF01"] and len(notes) == 1
    assert notes[0] in kept.limitations and "RF03" in notes[0] and "velocity_stats" in notes[0]


def test_nothing_to_drop_leaves_the_draft_unchanged(benign_ledger):
    from case_zero.validator import drop_unsupported_flags
    d = good_draft(red_flags=[flag("RF01", f"{BENIGN} passed money straight on", "tc_02")])
    assert drop_unsupported_flags(d, benign_ledger) == (d, [])


def _benign_script():
    from fake_llm import call, done
    return [call("get_account", acct_id=BENIGN), call("velocity_stats", acct_id=BENIGN), call("neighbours", acct_id=BENIGN, hops=1),
            call("kyc_dupe_check", acct_id=BENIGN), done("Nothing suspicious.")]


def _benign_draft(code: str) -> CaseDraft:
    return CaseDraft.model_construct(
        typology="none", members=[], excluded=[], timeline=[], proposed_action="monitor", limitations="",
        red_flags=[RedFlag.model_construct(code=code, text="No suspicious pattern was found.", evidence=["tc_01"])],   # tc_01: the profile
        narrative_en=f"{BENIGN} shows no suspicious pattern.", narrative_bn=f"{BENIGN}-এ কোনো সন্দেহজনক প্যাটার্ন নেই।")


def test_the_benign_reproduction_with_rf99_stays_closed(world):
    """The reproduction: production settings, score 0.0, RF99 cited to the profile call, monitor proposed."""
    from fake_llm import done
    from test_orchestrator import run
    from case_zero.config import Settings
    reply = _benign_draft("RF99").model_dump_json()
    report, _ = run(world, _benign_script() + [done(reply), done(reply)], seed=BENIGN, settings=Settings())
    assert report.model_score == 0.0 and report.action == "close_no_action" and not report.escalated


def test_the_benign_reproduction_with_a_catalogue_code_stays_closed(world):
    """Gemini's schema now forces a catalogue code; one cited to the profile call is dropped, not counted."""
    from fake_llm import draft
    from test_orchestrator import run
    from case_zero.config import Settings
    report, _ = run(world, _benign_script() + [draft(CaseDraft.model_validate_json(_benign_draft("RF01").model_dump_json()))], seed=BENIGN, settings=Settings())
    assert report.status == "done" and report.action == "close_no_action" and not report.escalated
    assert report.draft.red_flags == [] and "Red flag RF01 removed" in report.draft.limitations


def test_the_writer_is_told_which_call_each_flag_needs():
    from case_zero.validator import ALL_TOOLS, FLAG_EVIDENCE
    assert "names the account" in prompts.WRITER_SYSTEM
    catalogue = prompts.WRITER_SYSTEM.split("Red flag codes: ", 1)[1].split("; ")
    for code, tools in FLAG_EVIDENCE.items():
        line = next(part for part in catalogue if part.startswith(code + " "))
        assert ("any tool" in line) if tools == ALL_TOOLS else all(t in line for t in tools), code


# RF9: once the code check excludes an account, nothing outside excluded and limitations accuses it ------
EXCLUDED = "acct_00643"   # in tc_02 (neighbours of acct_01070) with no tie to this incident; the gate drops it


def _accusing_draft(**over) -> CaseDraft:
    base = good_draft()
    return good_draft(**{
        "members": [*base.members, {"acct_id": EXCLUDED, "role": "mule_L2", "evidence": ["tc_02"]}],
        "red_flags": [*base.red_flags, {"code": "RF01", "text": f"acct_01070 passed money straight on to mule {EXCLUDED}", "evidence": ["tc_02"]}],
        "timeline": [*base.timeline, {"ts": "2026-11-10T14:13:00", "text": f"{EXCLUDED} joins the ring", "evidence": ["tc_02"]}],
        "narrative_en": base.narrative_en + f" {EXCLUDED} is a second-layer mule.",
        "narrative_bn": base.narrative_bn + f" {EXCLUDED} একটি দ্বিতীয় স্তরের মিউল।",
        **over})


def _mentions_outside_excluded_and_limitations(report, acct: str) -> list[str]:
    d = report.draft
    texts = {"narrative_en": d.narrative_en, "narrative_bn": d.narrative_bn, "members": " ".join(m.acct_id for m in d.members),
             "red_flags": " ".join(f.text for f in d.red_flags), "timeline": " ".join(t.text for t in d.timeline)}
    return [k for k, v in texts.items() if acct in v]


def test_the_acct_00643_reproduction_is_not_accused_after_the_gate(world):
    from fake_llm import draft
    from test_orchestrator import SCRIPT, run
    from case_zero.schemas import to_contract
    report, _ = run(world, SCRIPT + [draft(_accusing_draft())])
    assert EXCLUDED in report.validation["gate"]["dropped"] and report.status == "done"
    assert _mentions_outside_excluded_and_limitations(report, EXCLUDED) == []
    assert EXCLUDED in {x.acct_id for x in report.draft.excluded}
    contract = to_contract(report, report._ledger)
    assert EXCLUDED not in contract["summary_en"] + contract["summary_bn"] + " ".join(e["claim"] for e in contract["evidence"]) + " ".join(contract["ring"])
    removed = [line for line in report.draft.limitations.split(". ") if "removed" in line and EXCLUDED in line]
    assert len(removed) == 4   # one line per removed accusation: the flag, the timeline entry, one sentence in each language


def test_a_removed_flag_does_not_raise_the_action(world):
    from fake_llm import call, done, draft
    from test_orchestrator import run
    script = [call("path_between", source="acct_rina", target="acct_01070"), call("neighbours", acct_id="acct_01070", hops=1), done("Ring found.")]
    d = _accusing_draft(members=[{"acct_id": "acct_rina", "role": "victim", "evidence": ["tc_01"]}, {"acct_id": "acct_01070", "role": "mule_L1", "evidence": ["tc_01"]},
                                 {"acct_id": EXCLUDED, "role": "mule_L2", "evidence": ["tc_02"]}],
                        red_flags=[{"code": "RF01", "text": f"acct_01070 passed money straight on to mule {EXCLUDED}", "evidence": ["tc_02"]}],
                        narrative_en=f"acct_rina sent Tk 7,900 to acct_01070 at 14:13. acct_01070 passed money on to mule {EXCLUDED}.",
                        narrative_bn=f"acct_rina ১৪:১৩-এ acct_01070-এ ৭,৯০০ টাকা পাঠান। acct_01070 মিউল {EXCLUDED}-এ টাকা পাঠায়।",
                        proposed_action="monitor")
    report, _ = run(world, script + [draft(d)], seed="acct_rina")
    assert report.floor_action == "close_no_action" and EXCLUDED in report.validation["gate"]["dropped"]
    assert report.action == "close_no_action" and not report.escalated and report.draft.red_flags == []


def test_a_report_with_nothing_to_strip_is_byte_identical(world):
    from fake_llm import draft
    from test_orchestrator import SCRIPT, run
    from case_zero.gate import strip_accusations
    assert strip_accusations(good_draft(), {EXCLUDED}) == (good_draft(), [])
    report, events = run(world, SCRIPT + [draft(good_draft())])
    assert report.draft.model_dump_json() == good_draft().model_dump_json()
    assert [e["attempt"] for e in events if e["type"] == "validator"] == [1]   # nothing changed, so no second check


def test_the_post_gate_report_is_validated_and_a_failure_is_degraded(world):
    from fake_llm import draft
    from test_orchestrator import SCRIPT, run
    split = _accusing_draft(narrative_en=f"acct_rina sent Tk 7,900 to acct_01070 at 14:13. acct_01070 forwarded Tk 1,850 to acct_01870 and {EXCLUDED}.",
                            narrative_bn=f"acct_rina ১৪:১৩-এ acct_01070-এ ৭,৯০০ টাকা পাঠান। acct_01070 acct_01870-এ ১,৮৫০ টাকা পাঠায়। {EXCLUDED}-ও টাকা পায়।")
    report, events = run(world, SCRIPT + [draft(split)])
    post = [e for e in events if e["type"] == "validator" and e["attempt"] == "post_gate"]
    assert post and post[0]["pass"] is False and any(v["code"] == "en_bn_mismatch" for v in post[0]["violations"])
    assert report.status == "failed_after_retry" and any(v["code"] == "en_bn_mismatch" for v in report.validation["final"])
    assert report.validation["post_gate"] == report.validation["final"]


# RF12: a case that failed the citation check after the retry leaves as degraded (or failed), never done ----
MISMATCH = dict(narrative_bn="acct_rina ১৪:১৩-এ acct_01070-এ ৭,৯০০ টাকা পাঠান।")   # the Bangla leaves out acct_01870 and Tk 1,850


def _risk_mw_case_report():
    from test_writer_spend_and_contract import _contract_module
    return _contract_module().CaseReport


def test_a_forced_en_bn_mismatch_exports_degraded_with_its_errors(world):
    from fake_llm import draft
    from test_orchestrator import SCRIPT, run
    from case_zero.schemas import to_contract
    report, events = run(world, SCRIPT + [draft(good_draft(**MISMATCH)), draft(good_draft(**MISMATCH))])
    assert report.status == "failed_after_retry"
    contract = to_contract(report, report._ledger)
    assert (contract["status"], contract["redacted"]) == ("degraded", True)
    assert any(e.startswith("en_bn_mismatch") for e in contract["validation_errors"]) and contract["limitations"] == report.draft.limitations
    assert _risk_mw_case_report()(**contract).status == "degraded"
    assert events[-1] == {"type": "done", "case_id": "CZ-0001", "status": "degraded"}


def test_a_clean_case_is_done_and_never_redacted(world):
    from fake_llm import draft
    from test_orchestrator import SCRIPT, run
    from case_zero.schemas import to_contract
    report, events = run(world, SCRIPT + [draft(good_draft())])
    contract = to_contract(report, report._ledger)
    assert contract["status"] == "done" and not {"redacted", "validation_errors", "limitations"} & set(contract)   # review 4: sent only when degraded
    assert events[-1]["status"] == "done"


def test_exported_statuses_and_the_decided_ones():
    from case_zero.schemas import DECIDED_STATUSES, exported_status
    assert {s: exported_status(s) for s in ("done", "failed_after_retry", "failed")} == {"done": "done", "failed_after_retry": "degraded", "failed": "failed"}
    assert exported_status("degraded") == "degraded" and DECIDED_STATUSES == frozenset({"done", "degraded"})


def test_the_service_finishes_a_degraded_run_and_says_so(world):
    from fake_llm import FakeLLM, draft
    from fastapi.testclient import TestClient
    from test_app import events_of
    from test_orchestrator import NO_MIN, SCRIPT
    from case_zero.app import FINAL, create_app
    from case_zero.config import DEMO_SEED
    assert "degraded" in FINAL
    client = TestClient(create_app(settings=NO_MIN, world=world, llm=FakeLLM(SCRIPT + [draft(good_draft(**MISMATCH))] * 2)))
    events = events_of(client.post("/api/investigate", json={"seed": DEMO_SEED}).text)   # the stream ends: degraded is a final state
    case_id = events[0]["case_id"]
    assert events[-1] == {"type": "done", "case_id": case_id, "status": "degraded"}
    assert client.get(f"/api/investigations/{case_id}").json()["status"] == "degraded"
    assert client.get(f"/api/cases/{case_id}/contract").json()["status"] == "degraded"


# RF12 in the eval: G3 counts a degraded case as not done, and the summary says how many there were ---------
def _eval_rows(*statuses):
    m = dict(recovered=True, precision=1.0, recall=1.0, flagged=True, first_pass_ok=True, seconds=10.0, cost_usd=0.02, action="freeze")
    return [{"ring_id": f"r{i}", "seed": f"acct_{i}", "tuning": False, "methods": {"case_zero": {**m, "status": s}}} for i, s in enumerate(statuses)]


def test_g3_counts_a_degraded_case_as_not_done():
    from eval.run_eval import gates, summarise
    mixed = summarise(_eval_rows("done", "failed_after_retry"), "case_zero")
    assert mixed["degraded"] == 1 and mixed["exported_statuses"] == {"done": 1, "degraded": 1}
    assert gates(mixed)["G3_validator"] is False
    assert gates(summarise(_eval_rows("done", "done"), "case_zero"))["G3_validator"] is True


def test_the_eval_summary_says_how_many_cases_were_degraded():
    from eval.run_eval import summarise, to_markdown
    s = {**summarise(_eval_rows("done", "failed_after_retry"), "case_zero"), "skipped_budget": 0, "skipped_tuning": 0}
    text = to_markdown({"prompt_sha": "p", "model": "m", "note": "n.", "summary": {"case_zero": s}})
    assert "1 degraded" in text


def test_the_eval_records_what_code_removed(world):
    import asyncio
    from fake_llm import FakeLLM, draft
    from test_orchestrator import NO_MIN, SCRIPT
    from case_zero.config import DEMO_AS_OF, DEMO_SEED
    from eval.run_eval import agent_pred
    _, info = asyncio.run(agent_pred(world, FakeLLM(SCRIPT + [draft(_accusing_draft())]), {"seed": DEMO_SEED, "as_of": DEMO_AS_OF}, 0, settings=NO_MIN))
    assert info["exported_status"] == "done" and info["accusations_removed"] == 4 and info["flags_dropped"] == 0


# Say what the check guarantees, and call it a citation check ----------------------------
def test_the_eval_summary_calls_it_a_citation_check():
    from eval.run_eval import gates, summarise, to_markdown
    s = {**summarise(_eval_rows("done"), "case_zero"), "skipped_budget": 0, "skipped_tuning": 0}
    text = to_markdown({"prompt_sha": "p", "model": "m", "note": "n.", "summary": {"case_zero": s}, "gates": gates(s)})
    assert "citation check passed first time 1/1" in text and "G3_citation_check pass" in text and "validator" not in text
