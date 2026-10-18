"""Regression tests: redaction on retry failures, label isolation, as_of handling, input checks, citation checks and gates."""

import asyncio
import json

import httpx
import pytest
from fake_llm import ROLE, FakeLLM, call, done, draft
from google.genai import errors
from test_orchestrator import NO_MIN, SCRIPT, good_draft, run

from case_zero.app import create_app
from case_zero.budget import BudgetExceeded
from case_zero.config import DEMO_AS_OF, DEMO_SEED
from case_zero.ledger import Ledger
from case_zero.llm import FunctionCall, LLMTurn
from case_zero.policy import escalation_flags
from case_zero.validator import _clocks, normalise_amounts, redact, validate
from eval.seeds import benign_seeds, ring_seeds

BAD = dict(narrative_en="acct_rina sent Tk 9,999 to acct_01070 at 14:13.", narrative_bn="acct_rina ১৪:১৩-এ acct_01070-এ ৯,৯৯৯ টাকা পাঠান।")
LEAK_WORDS = ("ring_", "benign", "attacker", "cluster", '"role"')


# C1 ---------------------------------------------------------------------------------------------
def test_retry_timeout_redacts_first_draft(world):
    report, _ = run(world, SCRIPT + [draft(good_draft(**BAD)), asyncio.TimeoutError()])
    assert report.status == "failed_after_retry" and "9,999" not in report.draft.narrative_en


def test_retry_invalid_json_redacts_first_draft(world):
    report, _ = run(world, SCRIPT + [draft(good_draft(**BAD)), done("not json")])
    assert report.status == "failed_after_retry" and "9,999" not in report.draft.narrative_en


def test_fault_inject_then_timeout_never_shows_injected_fact(world):
    report, _ = run(world, SCRIPT + [draft(good_draft()), asyncio.TimeoutError()], fault_inject=True)
    assert "12,345" not in report.draft.narrative_en and "১২,৩৪৫" not in report.draft.narrative_bn


# C2 + M6 ------------------------------------------------------------------------------------------
def _all_tools(led: Ledger, seed: str) -> list[str]:
    near = led.call("neighbours", acct_id=seed, hops=2)
    others = [n["acct_id"] for n in (near["data"] or {}).get("neighbours", [])][:4]
    outs = [near, led.call("get_account", acct_id=seed), led.call("score", acct_id=seed), led.call("velocity_stats", acct_id=seed),
            led.call("shared_entities", acct_ids=[seed, *others]), led.call("kyc_dupe_check", acct_id=seed),
            led.call("known_fraud_proximity", acct_id=seed, max_hops=3), led.call("agent_till_stats", agent_id="AG-0192"),
            led.call("score_neighbours", acct_id=seed, hops=3, min_score=0.2), led.call("dormant_cohort", acct_id=seed),
            led.call("common_point_of_compromise", acct_id=seed), led.prefetch_score()]
    if others:
        outs.append(led.call("path_between", source=seed, target=others[0]))
    return [json.dumps(o) for o in outs]


def test_no_labels_reach_any_tool_for_any_eval_seed(world):
    ring_ids = {l["ring_id"] for l in world.bundle.labels}
    for s in ring_seeds(world) + benign_seeds(world, n=10):
        for text in _all_tools(Ledger(world, s["seed"], s["as_of"], max_calls=20), s["seed"]):
            assert not any(r in text for r in ring_ids), s["seed"]
            assert not any(w in text for w in LEAK_WORDS), (s["seed"], [w for w in LEAK_WORDS if w in text])


def test_persona_alias_round_trips(world):
    led = Ledger(world, "acct_09001", DEMO_AS_OF)
    out = led.call("get_account", acct_id="acct_09001")
    assert out["data"]["found"] is True and out["data"]["acct_id"] == "acct_09001"
    assert "acct_09001" in led.ids and not any("benign" in i for i in led.ids)


def test_identity_links_respect_as_of(world):
    links = world.entity_links("acct_rina", "2024-01-01T00:00:00")
    assert links == set()
    assert world.entity_links("acct_rina", DEMO_AS_OF)


def test_eval_as_of_never_confirms_the_ring_under_test(world):
    from datetime import timedelta

    from bhorosha_synth import schema as sc
    for s in ring_seeds(world):
        cutoff = sc.format_ts(sc.parse_ts(s["as_of"]) - timedelta(days=world.lag_days))
        # an account may be known from an EARLIER case (e.g. a till shared by several rings); that is real analyst knowledge
        prior = {l["acct_id"] for l in world.bundle.labels if l["ring_id"] != s["ring_id"] and l["role"] != "victim" and l["first_bad_ts"] < cutoff}
        hits = {h["acct_id"] for h in world.known_fraud_proximity(s["seed"], s["as_of"], 3)["hits"]}
        assert not ((hits & s["truth"]) - prior), s["ring_id"]
        assert s["truth"], s["ring_id"]


# I1 + M4 -----------------------------------------------------------------------------------------
def test_unparseable_as_of_fails_without_calling_gemini(world):
    llm = FakeLLM([])
    events = []

    async def emit(e):
        events.append(e)

    from case_zero.orchestrator import run_investigation
    report = asyncio.run(run_investigation(world, llm, DEMO_SEED, "2026-11-10T14:35", emit, "CZ-0001"))
    assert report.status == "failed" and "score" in report.draft.limitations and llm.calls == []


def test_seed_without_activity_closes_without_gemini(world):
    llm = FakeLLM([])

    async def emit(e):
        return None

    from case_zero.orchestrator import run_investigation
    report = asyncio.run(run_investigation(world, llm, DEMO_SEED, "2026-10-07T00:00:00", emit, "CZ-0001"))
    assert report.action == "close_no_action" and "no activity" in report.draft.limitations and llm.calls == []


@pytest.mark.parametrize("body", [{"seed": DEMO_SEED, "as_of": "2026-11-10T14:35"}, {"seed": DEMO_SEED, "as_of": "2026-11-10T14:35:00+06:00"},
                                  {"seed": DEMO_SEED, "as_of": "2027-01-01T00:00:00"}, {"seed": "x" * 100}, {"seed": "acct_01070; drop"}])
def test_bad_inputs_are_422(world, body):
    from fastapi.testclient import TestClient
    assert TestClient(create_app(settings=NO_MIN, world=world, llm=FakeLLM([]))).post("/api/investigate", json=body).status_code == 422


# I2 + I3 -----------------------------------------------------------------------------------------
@pytest.fixture()
def led(world):
    led = Ledger(world, DEMO_SEED, "2026-11-10T16:00:00", max_calls=20)
    led.prefetch_score()
    led.call("path_between", source="acct_rina", target="acct_till_AG-0192")
    led.call("velocity_stats", acct_id="acct_till_AG-0192", window_hours=720)
    return led


def test_entity_ids_and_hex_are_not_amounts():
    assert normalise_amounts("share device dev_1561687cdf1de790 and sim_f5e1c743c7024362, device:1a2b3c4d5e6f") == set()


def test_counts_from_tools_are_accepted(led):
    n = led.entry("tc_02")["data"]["lifetime_txn_count"]
    assert n >= 100
    d = good_draft(members=[{"acct_id": "acct_01070", "role": "mule_L1", "evidence": ["tc_01"]}], red_flags=[], timeline=[],
                   narrative_en=f"acct_till_AG-0192 handled {n} transactions.", narrative_bn=f"acct_till_AG-0192 {n}টি লেনদেন করেছে।")
    assert not [v for v in validate(d, led) if v.code == "unknown_amount"]


def test_twelve_hour_clock_and_bangla_thousands():
    assert _clocks("at 2:13 pm") == {"14:13"} and _clocks("at 2:13 am") == {"02:13"}
    assert normalise_amounts("৭ হাজার ৯০০ টাকা") == {7900}


def test_timeline_ts_reasons_limitations_and_stamps_are_checked(led):
    d = good_draft(
        members=[{"acct_id": "acct_01070", "role": "mule_L1", "evidence": ["tc_01"]}], red_flags=[],
        timeline=[{"ts": "2026-11-10T03:03:00", "text": "acct_rina sends Tk 7,900", "evidence": ["tc_01"]}],
        excluded=[{"acct_id": "acct_01070", "reason": "Tk 55,555 from acct_77777 at 03:03", "evidence": ["tc_01"]}],
        narrative_en="acct_rina sent Tk 7,900 at 2026-11-10T14:59:00.", narrative_bn="acct_rina 2026-11-10T14:59:00-এ ৭,৯০০ টাকা পাঠান।",
        limitations="acct_88888 also received Tk 4,444.")
    v = validate(d, led)
    fields = {(x.code, x.field) for x in v}
    assert ("unknown_time", "timeline_ts") in fields
    assert ("unknown_amount", "excluded") in fields and ("unknown_id", "excluded") in fields
    assert ("unknown_id", "limitations") in fields and ("unknown_amount", "limitations") in fields
    assert ("unknown_time", "narrative_en") in fields


def test_uncited_items_are_redacted(led):
    d = good_draft(red_flags=[{"code": "RF08", "text": "close to fraud", "evidence": []}])
    assert redact(d, validate(d, led)).red_flags == []


# I4 + M2 -----------------------------------------------------------------------------------------
def test_api_error_in_tool_loop_still_writes_a_case(world):
    simple = good_draft(members=[{"acct_id": "acct_01070", "role": "mule_L1", "evidence": ["tc_01"]}], red_flags=[], timeline=[],
                        narrative_en="acct_rina sent Tk 7,900 to acct_01070.", narrative_bn="acct_rina acct_01070-এ ৭,৯০০ টাকা পাঠান।")
    report, events = run(world, [call("path_between", source="acct_rina", target=DEMO_SEED), errors.APIError(503, {"error": {"message": "unavailable"}}), draft(simple)])
    assert report.status == "done" and "Gemini" in report.draft.limitations and events[-1]["type"] == "done"


def test_api_error_in_writer_fails_cleanly(world):
    err = errors.APIError(429, {"error": {"message": "quota"}})
    report, events = run(world, SCRIPT + [err, err])
    assert report.status == "failed" and events[-1]["type"] == "done"


def test_budget_exceeded_stops_cleanly(world):
    report, events = run(world, [BudgetExceeded("cap"), BudgetExceeded("cap")])
    assert report.status == "failed" and "spend cap" in report.draft.limitations and events[-1]["type"] == "done"


def test_tool_argument_named_name_does_not_crash(world):
    weird = LLMTurn(text="", function_calls=(FunctionCall(id="x", name="get_account", args={"acct_id": DEMO_SEED, "name": "x"}),), parsed=None,
                    tokens_in=1, tokens_out=1, model_id=ROLE.id, latency_ms=1.0)
    report, events = run(world, [weird, done(), draft(good_draft(members=[{"acct_id": "acct_01070", "role": "mule_L1", "evidence": ["tc_00"]}], red_flags=[], timeline=[], narrative_en="acct_01070 is under review.", narrative_bn="acct_01070 পর্যালোচনাধীন।"))])
    assert events[-1]["type"] == "done" and any(e["type"] == "tool_result" and not e["ok"] for e in events)


# M3 ----------------------------------------------------------------------------------------------
def test_score_flag_does_not_count_for_escalation(led):   # A counted flag also cites a fitting call for an account it names
    d = good_draft(red_flags=[{"code": "RF12", "text": "acct_01070 has a high score", "evidence": ["tc_00"]},
                              {"code": "RF01", "text": "acct_rina's money passed straight through to acct_till_AG-0192", "evidence": ["tc_01"]}])
    assert escalation_flags(d.red_flags, led) == 1


# I5 + I6 -----------------------------------------------------------------------------------------
def _client(world, script, **kw):
    from fastapi.testclient import TestClient
    return TestClient(create_app(settings=NO_MIN, world=world, llm=FakeLLM(script), **kw))


def test_approve_needs_admin_token(world):
    c = _client(world, SCRIPT + [draft(good_draft())], admin_token="s3cret")
    from test_app import events_of
    case_id = events_of(c.post("/api/investigate", json={"seed": DEMO_SEED}).text)[0]["case_id"]
    assert c.post(f"/api/cases/{case_id}/approve").status_code == 403
    assert c.post(f"/api/cases/{case_id}/approve", headers={"X-Admin-Token": "wrong"}).status_code == 403
    assert c.post(f"/api/cases/{case_id}/approve", headers={"X-Admin-Token": "s3cret"}).status_code == 200


def test_per_ip_limit(world):
    c = _client(world, [], per_ip_limit=2)
    codes = [c.post("/api/investigate", json={"seed": "acct_99999"}).status_code for _ in range(3)]
    assert codes == [200, 200, 429]


def test_concurrency_gate_is_atomic(world):
    app = create_app(settings=NO_MIN, world=world, llm=FakeLLM(SCRIPT + [draft(good_draft())] + SCRIPT + [draft(good_draft())], delay_s=0.3), max_concurrent=1)

    async def go():
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as client:
            return await asyncio.gather(*(client.post("/api/investigate", json={"seed": DEMO_SEED}) for _ in range(2)))

    codes = sorted(r.status_code for r in asyncio.run(go()))
    assert codes == [200, 429]
