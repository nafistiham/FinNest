import asyncio
import dataclasses

from fake_llm import FakeLLM, call, done, draft

from case_zero.config import DEMO_AS_OF, DEMO_SEED, Settings
from case_zero.orchestrator import run_investigation
from case_zero.schemas import CaseDraft


def good_draft(**over) -> CaseDraft:
    base = dict(
        typology="otp_takeover_cashout",
        members=[{"acct_id": "acct_rina", "role": "victim", "evidence": ["tc_01"]},
                 {"acct_id": "acct_01070", "role": "mule_L1", "evidence": ["tc_01"]},
                 {"acct_id": "acct_01870", "role": "mule_L2", "evidence": ["tc_02"]}],
        excluded=[],
        red_flags=[{"code": "RF02", "text": "acct_01070 fanned Tk 7,900 out within minutes", "evidence": ["tc_01", "tc_02"]}],
        timeline=[{"ts": "2026-11-10T14:13:00", "text": "acct_rina sends Tk 7,900 to acct_01070", "evidence": ["tc_01"]}],
        proposed_action="freeze",
        narrative_en="acct_rina sent Tk 7,900 to acct_01070 at 14:13. acct_01070 forwarded Tk 1,850 to acct_01870.",
        narrative_bn="acct_rina ১৪:১৩-এ acct_01070-এ ৭,৯০০ টাকা পাঠান। acct_01070 acct_01870-এ ১,৮৫০ টাকা পাঠায়।",
        limitations="",
    )
    return CaseDraft(**{**base, **over})


SCRIPT = [call("path_between", source="acct_rina", target=DEMO_SEED), call("neighbours", acct_id=DEMO_SEED, hops=1), done("Ring found.")]
NO_MIN = dataclasses.replace(Settings(), min_tool_calls=0)  # scripted tests below exercise other behaviour with short scripts


def run(world, script, seed=DEMO_SEED, settings=NO_MIN, **kw):
    events = []

    async def emit(e):
        events.append(e)

    report = asyncio.run(run_investigation(world, FakeLLM(script), seed, DEMO_AS_OF, emit, "CZ-0001", settings=settings, **kw))
    return report, events


def test_happy_path_emits_events_and_report(world):
    report, events = run(world, SCRIPT + [draft(good_draft())])
    kinds = [e["type"] for e in events]
    assert kinds[:2] == ["run_started", "score"]
    assert kinds.count("tool_call") == 2 and kinds.count("tool_result") == 2
    assert kinds[-5:] == ["draft", "validator", "gate", "report", "done"]
    assert "usage" in kinds
    assert events[kinds.index("validator")]["pass"] is True
    assert report.status == "done" and report.action == "freeze" and report.tool_calls == 2
    tool_result = events[kinds.index("tool_result")]
    assert tool_result["call_id"] == "tc_01" and tool_result["graph_delta"]["edges"]


def test_model_score_is_copied_not_generated(world):
    report, events = run(world, SCRIPT + [draft(good_draft(proposed_action="close_no_action"))])
    score_event = next(e for e in events if e["type"] == "score")
    assert report.model_score == score_event["data"]["probability"] > 0.8
    assert report.action == "freeze" and report.floor_action == "freeze"


def test_budget_stops_tool_loop(world):
    settings = dataclasses.replace(Settings(), max_tool_calls=3, min_tool_calls=0)
    script = [call("get_account", acct_id=DEMO_SEED) for _ in range(3)] + [draft(good_draft(members=[{"acct_id": "acct_01070", "role": "mule_L1", "evidence": ["tc_01"]}], red_flags=[], timeline=[], narrative_en="acct_01070 is under review.", narrative_bn="acct_01070 পর্যালোচনাধীন।"))]
    report, events = run(world, script, settings=settings)
    assert report.tool_calls == 3 and report.status == "done"  # the writer got the draft, not a leftover tool turn
    assert "tool budget" in report.draft.limitations


def test_retry_fixes_violation(world):
    bad = good_draft(narrative_en="acct_rina sent Tk 9,999 to acct_01070 at 14:13.", narrative_bn="acct_rina ১৪:১৩-এ acct_01070-এ ৯,৯৯৯ টাকা পাঠান।")
    report, events = run(world, SCRIPT + [draft(bad), draft(good_draft())])
    validators = [e for e in events if e["type"] == "validator"]
    assert [v["pass"] for v in validators] == [False, True]
    assert any(v["code"] == "unknown_amount" for v in validators[0]["violations"])
    assert report.status == "done" and report.validation["retried"] is True


def test_second_failure_redacts(world):
    bad = good_draft(narrative_en="acct_rina sent Tk 7,900 to acct_01070. acct_09999 got Tk 9,999.", narrative_bn="acct_rina acct_01070-এ ৭,৯০০ টাকা পাঠান। acct_09999 ৯,৯৯৯ টাকা পায়।")
    report, events = run(world, SCRIPT + [draft(bad), draft(bad)])
    assert report.status == "failed_after_retry"
    assert "acct_09999" not in report.draft.narrative_en
    assert events[-1]["type"] == "done"


def test_fault_inject_forces_one_rejection(world):
    report, events = run(world, SCRIPT + [draft(good_draft()), draft(good_draft())], fault_inject=True)
    validators = [e for e in events if e["type"] == "validator"]
    assert [v["pass"] for v in validators] == [False, True]
    assert validators[0]["fault_injected"] is True
    assert report.status == "done"


def test_unknown_seed_closes_cleanly(world):
    report, events = run(world, [], seed="acct_does_not_exist")
    assert report.action == "close_no_action" and report.status == "done"
    assert "not found" in report.draft.limitations
    assert events[-1]["type"] == "done"


def test_writer_garbage_never_crashes(world):
    from fake_llm import done as text_turn
    report, events = run(world, SCRIPT + [text_turn("not json"), text_turn("still not json")])
    assert report.status == "failed"
    assert report.action == "freeze"  # the score floor still applies
    assert events[-1]["type"] == "done"


def test_limitation_not_repeated_when_writer_already_says_it(world):
    settings = dataclasses.replace(Settings(), max_tool_calls=3, min_tool_calls=0)
    said = good_draft(members=[{"acct_id": "acct_01070", "role": "mule_L1", "evidence": ["tc_01"]}], red_flags=[], timeline=[],
                      narrative_en="acct_01070 is under review.", narrative_bn="acct_01070 পর্যালোচনাধীন।", limitations="Tool budget of 3 calls reached.")
    report, _ = run(world, [call("get_account", acct_id=DEMO_SEED) for _ in range(3)] + [draft(said)], settings=settings)
    assert report.status == "done"
    assert report.draft.limitations.lower().count("tool budget of 3 calls reached") == 1


def test_agent_cannot_finish_without_investigating(world):
    # first reply tries to conclude with no tool calls; code sends it back until the minimum is met
    script = [done("Looks like a mule."), call("path_between", source="acct_rina", target=DEMO_SEED), call("neighbours", acct_id=DEMO_SEED, hops=1),
              call("get_account", acct_id=DEMO_SEED), call("velocity_stats", acct_id=DEMO_SEED), done("Ring found."), draft(good_draft())]
    report, events = run(world, script, settings=Settings())
    assert report.tool_calls >= 4 and report.status == "done"
    assert [e["type"] for e in events].count("tool_result") >= 4


def test_one_slow_turn_does_not_end_the_investigation(world):
    import asyncio as aio
    script = [aio.TimeoutError(), call("path_between", source="acct_rina", target=DEMO_SEED), call("neighbours", acct_id=DEMO_SEED, hops=1), done(), draft(good_draft())]
    report, _ = run(world, script)
    assert report.tool_calls == 2 and report.status == "done"


def test_timing_budget_is_consistent():  # the spec's 90 s wall clock; the writer always keeps at least 30 s of it
    s = Settings()
    assert s.run_timeout_s == 90 and s.llm_turn_timeout_s <= 60
    assert s.run_timeout_s - s.investigator_timeout_s >= 30 and s.writer_timeout_s >= 30
