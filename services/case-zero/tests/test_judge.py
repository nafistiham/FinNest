"""The narrative judge (spec US-4 and US-5): OCBC rubric 1-5 plus English/Bangla consistency, and the five eval gates."""

import asyncio

from fake_llm import ROLE, FakeLLM, done, draft
from test_orchestrator import SCRIPT, good_draft, run

from case_zero.llm import LLMTurn
from eval.judge import JUDGE_SHA, JudgeScore, judge_case, judge_input

SCORES = JudgeScore(evidence=5, consistency=4, clarity=4, actionability=3, en_bn_consistency=5,
                    mismatches=[], unsupported_claims=["acct_01870 role is asserted without a cash-out"], rationale="Grounded, but the next step is vague.")


def _parsed(model) -> LLMTurn:
    return LLMTurn(text=model.model_dump_json(), function_calls=(), parsed=model, tokens_in=4000, tokens_out=300, model_id=ROLE.id, latency_ms=5.0)


def _report(world):
    report, _ = run(world, SCRIPT + [draft(good_draft())])
    return report


def test_judge_sees_the_case_and_its_cited_evidence_and_no_labels(world):
    report = _report(world)
    text = judge_input(report, report._ledger)
    assert report.draft.narrative_en in text and report.draft.narrative_bn in text
    assert "tc_01" in text and "tc_02" in text and "path_between" in text  # the cited tool outputs
    assert "ring_" not in text and '"role":' not in text and "benign" not in text
    assert len(text) < 24_000


def test_judge_returns_the_five_scores(world):
    out = asyncio.run(judge_case(FakeLLM([_parsed(SCORES)]), _report(world), timeout_s=5))
    assert (out["evidence"], out["consistency"], out["clarity"], out["actionability"], out["en_bn_consistency"]) == (5, 4, 4, 3, 5)
    assert out["unsupported_claims"] and out["judge_model"] == "fake-model" and out["judge_cost_usd"] > 0


def test_a_bad_judge_reply_is_recorded_not_raised(world):
    out = asyncio.run(judge_case(FakeLLM([done("not json")]), _report(world), timeout_s=5))
    assert "judge_error" in out and "evidence" not in out


def test_judge_prompt_is_hashed_and_names_the_rubric():
    from eval import judge
    assert len(JUDGE_SHA) == 12
    for word in ("evidence", "consistency", "clarity", "actionability", "Bangla"):
        assert word in judge.JUDGE_SYSTEM


def test_eval_runs_the_judge_when_given_one(world):
    from case_zero.config import DEMO_AS_OF, DEMO_SEED
    from eval.run_eval import agent_pred
    _, info = asyncio.run(agent_pred(world, FakeLLM(SCRIPT + [draft(good_draft())]), {"seed": DEMO_SEED, "as_of": DEMO_AS_OF}, 0, judge_llm=FakeLLM([_parsed(SCORES)])))
    assert info["judge"]["actionability"] == 3


def _row(ring_id, **m):
    return {"ring_id": ring_id, "tuning": False, "methods": {"case_zero": m}}


def test_summary_has_judge_means_and_the_five_gates():
    from eval.run_eval import gates, summarise
    judged = {"evidence": 5, "consistency": 4, "clarity": 4, "actionability": 4, "en_bn_consistency": 5}
    ok = dict(recovered=True, precision=1.0, recall=1.0, flagged=True, first_pass_ok=True, seconds=20.0, cost_usd=0.03, status="done", action="freeze", judge=judged)
    benign = dict(ok, recovered=False, precision=0.0, recall=0.0, flagged=False, action="close_no_action")
    rows = [_row("r1", **ok), _row("r2", **ok), _row(None, **benign), _row(None, **dict(benign, judge={"judge_error": "timeout"}))]
    s = summarise(rows, "case_zero")
    assert s["judge_means"] == {"evidence": 5.0, "consistency": 4.0, "clarity": 4.0, "actionability": 4.0, "en_bn_consistency": 5.0} and s["judge_n"] == 3
    g = gates(s)
    assert g == {"G1_recovery": True, "G2_benign_closed": True, "G3_validator": True, "G4_latency_cost": True, "G5_judge": True}
    s_bad = summarise([_row("r1", **dict(ok, seconds=75.0, judge=dict(judged, clarity=3)))] , "case_zero")
    g_bad = gates(s_bad)
    assert g_bad["G4_latency_cost"] is False and g_bad["G5_judge"] is False


def test_case_seconds_exclude_the_judge_and_the_judge_has_its_own(world):
    from case_zero.config import DEMO_AS_OF, DEMO_SEED
    from eval.run_eval import agent_pred
    slow_judge = FakeLLM([_parsed(SCORES)], delay_s=0.6)
    _, info = asyncio.run(agent_pred(world, FakeLLM(SCRIPT + [draft(good_draft())]), {"seed": DEMO_SEED, "as_of": DEMO_AS_OF}, 0, judge_llm=slow_judge))
    assert info["seconds"] < 0.6 and info["judge"]["judge_seconds"] >= 0.6
