"""Membership gate: the writer proposes members; code keeps only those it can link to the ring."""

from test_orchestrator import SCRIPT, good_draft, run
from fake_llm import draft

from case_zero.gate import apply_gate, check_members
from case_zero.tools import _score_neighbours
from eval.metrics import score_case

UNLINKED = "acct_00643"  # a counterparty the demo tools show (tc_02) with no tie to the ring


def _distractors(world, r):
    return {c["acct_id"] for c in _score_neighbours(world, r["as_of"], r["seed"], 3, 0.5, 50)["candidates"]}


def test_gate_strips_high_scoring_bystanders_on_the_dev_world(dev, dev_rings):
    recovered, rings = 0, 0
    for rid, r in dev_rings.items():
        if rid == "ring_demo_otp":
            continue
        res = check_members(dev, r["seed"], r["as_of"], r["truth"] | _distractors(dev, r))
        recovered += score_case(set(res.kept), r["truth"], r["victims"])["recovered"]
        rings += 1
    assert rings == 17 and recovered >= 15


def test_gate_always_keeps_the_seed(dev, dev_rings):
    r = dev_rings["ring_fan_0"]
    assert r["seed"] in check_members(dev, r["seed"], r["as_of"], []).kept


def test_gate_keeps_a_round_trip_till_and_says_why(dev, dev_rings):
    r = dev_rings["ring_roundtrip_1"]
    res = check_members(dev, r["seed"], r["as_of"], r["truth"])
    till = next(a for a in r["truth"] if a.startswith("acct_till_"))
    assert res.kept[till] == "round-trip till"


def test_gate_drops_a_customer_with_no_link(dev, dev_rings):
    r = dev_rings["ring_otp_1"]
    res = check_members(dev, r["seed"], r["as_of"], r["truth"] | {UNLINKED})
    assert UNLINKED in res.dropped and UNLINKED not in res.kept


def test_apply_gate_moves_dropped_members_to_excluded(world):
    d = good_draft(members=[*good_draft().members, {"acct_id": UNLINKED, "role": "mule_L2", "evidence": ["tc_02"]}])
    gated, info = apply_gate(world, "acct_01070", "2026-11-10T14:35:00", d)
    assert [m.acct_id for m in gated.members] == ["acct_rina", "acct_01070", "acct_01870"]  # victims and linked members stay
    moved = next(e for e in gated.excluded if e.acct_id == UNLINKED)
    assert moved.reason.startswith("Code check") and moved.evidence == ["tc_02"]
    assert UNLINKED in gated.limitations and info["dropped"] == {UNLINKED: "no money, identity or pattern link to the ring"}


def test_orchestrator_applies_the_gate(world):
    d = good_draft(members=[*good_draft().members, {"acct_id": UNLINKED, "role": "mule_L2", "evidence": ["tc_02"]}])
    report, _ = run(world, SCRIPT + [draft(d)])
    assert UNLINKED not in {m.acct_id for m in report.draft.members}
    assert UNLINKED in report.validation["gate"]["dropped"]
