"""Pattern tools: coordinated dormant wake-ups and common point of compromise."""

import pytest

from case_zero.ledger import Ledger
from case_zero.tools import run_tool
from eval.seeds import benign_seeds

DORMANT = ("ring_dormant_0", "ring_dormant_1", "ring_dormant_2")


@pytest.mark.parametrize("ring_id", DORMANT)
def test_dormant_cohort_finds_the_accounts_that_woke_with_the_seed(dev, dev_rings, ring_id):
    r = dev_rings[ring_id]
    out = run_tool(dev, "dormant_cohort", r["as_of"], {"acct_id": r["seed"]})
    assert out["seed_wake"] is not None
    assert {c["acct_id"] for c in out["cohort"]} == r["truth"] - {r["seed"]}


def test_dormant_cohort_rows_carry_citable_facts(dev, dev_rings):
    r = dev_rings["ring_dormant_0"]
    row = run_tool(dev, "dormant_cohort", r["as_of"], {"acct_id": r["seed"]})["cohort"][0]
    assert {"acct_id", "quiet_days", "inbound_count", "inbound_bdt", "outbound_bdt", "first_in", "last_out", "txn_ids"} <= row.keys()
    assert row["quiet_days"] >= 14 and row["outbound_bdt"] >= 0.8 * row["inbound_bdt"]


def test_dormant_cohort_is_empty_before_the_wake(dev, dev_rings):
    r = dev_rings["ring_dormant_0"]
    before = r["as_of"][:10] + "T00:00:00"
    out = run_tool(dev, "dormant_cohort", before, {"acct_id": r["seed"]})
    assert out["seed_wake"] is None and out["cohort"] == []


def test_dormant_cohort_never_fires_for_benign_look_alikes(dev):
    for b in benign_seeds(dev, n=10):
        out = run_tool(dev, "dormant_cohort", b["as_of"], {"acct_id": b["seed"]})
        assert out["cohort"] == [], b["seed"]


def test_dormant_cohort_goes_through_the_ledger(dev, dev_rings):
    r = dev_rings["ring_dormant_1"]
    led = Ledger(dev, r["seed"], r["as_of"])
    out = led.call("dormant_cohort", acct_id=r["seed"])
    assert out["call_id"] == "tc_01" and (r["truth"] - {r["seed"]}) <= led.ids


LEAK = ("ring_leak_0", "ring_leak_1", "ring_leak_2")


@pytest.mark.parametrize("ring_id", LEAK)
def test_common_point_of_compromise_finds_the_sibling_mule(dev, dev_rings, ring_id):
    r = dev_rings[ring_id]
    out = run_tool(dev, "common_point_of_compromise", r["as_of"], {"acct_id": r["seed"]})
    assert out["common_points"] and out["common_points"][0]["lift"] >= 3
    assert {a["acct_id"] for a in out["linked_accounts"]} == r["truth"] - {r["seed"]}


def test_common_point_rows_carry_citable_transfers(dev, dev_rings):
    r = dev_rings["ring_leak_0"]
    linked = run_tool(dev, "common_point_of_compromise", r["as_of"], {"acct_id": r["seed"]})["linked_accounts"][0]
    assert len(linked["compromised_payers"]) >= 2
    assert all({"txn_id", "from_acct", "amount_bdt", "ts", "via_point"} <= t.keys() for t in linked["transfers"])


def test_common_point_never_links_accounts_for_benign_look_alikes(dev):
    for b in benign_seeds(dev, n=10):
        out = run_tool(dev, "common_point_of_compromise", b["as_of"], {"acct_id": b["seed"]})
        assert out["linked_accounts"] == [], b["seed"]


def test_common_point_ignores_transfers_after_as_of(dev, dev_rings):
    r = dev_rings["ring_leak_1"]
    early = min(l["first_bad_ts"] for l in dev.bundle.labels if l["ring_id"] == "ring_leak_1")
    out = run_tool(dev, "common_point_of_compromise", early, {"acct_id": r["seed"]})
    assert all(t["ts"] <= early for a in out["linked_accounts"] for t in a["transfers"])
    assert not (r["truth"] - {r["seed"]}) & {a["acct_id"] for a in out["linked_accounts"]}


def test_pattern_tools_draw_edges_from_the_seed(dev, dev_rings):
    r = dev_rings["ring_dormant_0"]
    edges = Ledger(dev, r["seed"], r["as_of"]).call("dormant_cohort", acct_id=r["seed"])["graph_delta"]["edges"]
    assert {e["target"] for e in edges} == r["truth"] - {r["seed"]} and all(e["source"] == r["seed"] and e["kind"] == "pattern" for e in edges)
    r = dev_rings["ring_leak_0"]
    edges = Ledger(dev, r["seed"], r["as_of"]).call("common_point_of_compromise", acct_id=r["seed"])["graph_delta"]["edges"]
    assert any(e["kind"] == "pattern" and e["target"] in r["truth"] for e in edges)


def test_seed_brief_carries_pattern_leads_when_code_finds_them(dev, dev_rings):
    r = dev_rings["ring_dormant_2"]
    leads = Ledger(dev, r["seed"], r["as_of"]).prefetch_score()["data"]["pattern_leads"]
    assert {c["acct_id"] for c in leads["dormant_cohort"]} == r["truth"] - {r["seed"]}
    r = dev_rings["ring_leak_2"]
    leads = Ledger(dev, r["seed"], r["as_of"]).prefetch_score()["data"]["pattern_leads"]
    assert {a["acct_id"] for a in leads["common_point_linked"]} == r["truth"] - {r["seed"]}


def test_seed_brief_has_no_pattern_leads_for_benign_look_alikes(dev):
    for b in benign_seeds(dev, n=10):
        assert Ledger(dev, b["seed"], b["as_of"]).prefetch_score()["data"]["pattern_leads"] == {}, b["seed"]
