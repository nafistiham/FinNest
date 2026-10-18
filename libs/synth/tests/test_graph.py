"""Graph tool functions for the investigator agent, each under 50 ms."""

from __future__ import annotations

import time

import pytest

from bhorosha_graph.bundle import GraphBundle, build_bundle, load_bundle, save_bundle
from bhorosha_graph import tools
from bhorosha_synth import schema as s
from bhorosha_synth.generate import generate_world

AS_OF_END = "2026-11-10T23:59:00"


@pytest.fixture(scope="module")
def bundle() -> GraphBundle:
    return build_bundle(generate_world(s.WorldConfig(seed=42)))


@pytest.fixture(scope="module")
def demo(bundle) -> dict[str, list[str]]:
    by_role: dict[str, list[str]] = {}
    for label in bundle.labels:
        if label["ring_id"] == s.DEMO_RING_ID:
            by_role.setdefault(label["role"], []).append(label["acct_id"])
    return by_role


def _timed(fn, *args, **kwargs):
    started = time.perf_counter()
    out = fn(*args, **kwargs)
    return out, (time.perf_counter() - started) * 1000


def test_neighbours_of_rina_include_rafiq_and_the_l1_mule(bundle, demo):
    out, ms = _timed(tools.neighbours, bundle, s.RINA_ACCT, hops=1, as_of=AS_OF_END)
    counterparties = {n["acct_id"] for n in out["neighbours"]}
    assert s.RAFIQ_ACCT in counterparties
    assert demo["mule_L1"][0] in counterparties
    assert ms < 50


def test_neighbours_say_which_way_the_money_went(bundle, demo):
    """The walk follows money both ways, so each row names its transfer's sender and receiver."""
    l1 = demo["mule_L1"][0]
    out = tools.neighbours(bundle, l1, hops=2, as_of=AS_OF_END)
    rina = next(n for n in out["neighbours"] if n["acct_id"] == s.RINA_ACCT)
    assert (rina["from_acct"], rina["to_acct"]) == (s.RINA_ACCT, l1)   # inbound to the seed: Rina sent it
    txns = {t["txn_id"]: t for touching in bundle.txns_by_acct.values() for t in touching}
    for n in out["neighbours"]:
        t = txns[n["txn_id"]]
        assert (n["from_acct"], n["to_acct"]) == (t["from_acct"], t["to_acct"])
        assert {n["from_acct"], n["to_acct"]} == {n["via"], n["acct_id"]}   # via stays for older callers
        assert (n["first_ts"], n["txn_type"], n["amount_bdt"]) == (t["ts"], t["type"], t["amount_bdt"])
    assert {n["to_acct"] for n in out["neighbours"] if n["from_acct"] == l1}   # and outbound rows point away from it


def test_neighbours_respect_as_of(bundle, demo):
    before = tools.neighbours(bundle, s.RINA_ACCT, hops=1, as_of="2026-11-10T14:00:00")
    assert demo["mule_L1"][0] not in {n["acct_id"] for n in before["neighbours"]}


def test_path_between_rina_and_colluding_till(bundle):
    out, ms = _timed(tools.path_between, bundle, s.RINA_ACCT, s.COLLUDING_TILL_ACCT, max_hops=5, as_of=AS_OF_END)
    assert out["found"] is True
    assert 2 <= out["hops"] <= 5
    assert out["path"][0] == s.RINA_ACCT and out["path"][-1] == s.COLLUDING_TILL_ACCT
    assert len(out["txn_ids"]) == out["hops"]
    assert ms < 50


def test_path_between_unrelated_accounts_is_not_found(bundle):
    out = tools.path_between(bundle, s.RAHIMA_ACCT, s.COLLUDING_TILL_ACCT, max_hops=2, as_of="2026-10-15T00:00:00")
    assert out["found"] is False


def test_shared_entities_for_purchased_cluster(bundle):
    mules = sorted(l["acct_id"] for l in bundle.labels if l["role"] == "purchased_mule" and l["ring_id"] == "ring_cluster_0")
    out, ms = _timed(tools.shared_entities, bundle, mules)
    shared_devices = [e for e in out["shared"] if e["kind"] == "device" and set(e["acct_ids"]) == set(mules)]
    shared_agents = [e for e in out["shared"] if e["kind"] == "onboarding_agent" and set(e["acct_ids"]) == set(mules)]
    assert shared_devices and shared_agents
    assert ms < 50


def test_velocity_stats_for_l1_mule(bundle, demo):
    l1 = demo["mule_L1"][0]
    out, ms = _timed(tools.velocity_stats, bundle, l1, window_hours=2, as_of="2026-11-10T15:00:00")
    assert out["in_count"] >= 1 and out["out_count"] >= 5
    assert out["in_total_bdt"] >= 7900
    assert ms < 50


def test_agent_till_stats_show_round_tripping(bundle):
    out, ms = _timed(tools.agent_till_stats, bundle, s.COLLUDING_AGENT_ID, as_of=AS_OF_END)
    assert out["cash_in_count"] >= 10 and out["cash_out_count"] >= 10
    assert out["cash_in_total_bdt"] > 400_000
    assert out["distinct_counterparties"] >= 5
    assert ms < 50


def test_kyc_dupe_check_is_clean_for_rina(bundle):
    out, ms = _timed(tools.kyc_dupe_check, bundle, s.RINA_ACCT)
    assert out["nid_shared_with"] == [] and out["phone_shared_with"] == []
    assert ms < 50


def test_known_fraud_proximity_from_l2_mule_to_flagged_till(bundle, demo):
    l2 = demo["mule_L2"][0]
    out, ms = _timed(tools.known_fraud_proximity, bundle, l2, as_of=AS_OF_END, max_hops=2)
    assert out["min_hops"] == 1
    assert s.COLLUDING_TILL_ACCT in {h["acct_id"] for h in out["hits"]}
    assert ms < 50


def test_known_fraud_only_counts_labels_confirmed_before_as_of(bundle):
    out = tools.known_fraud_proximity(bundle, s.RINA_ACCT, as_of="2026-10-13T00:00:00", max_hops=2)
    assert out["hits"] == []


def test_bundle_pickle_round_trip(bundle, tmp_path):
    path = save_bundle(bundle, tmp_path / "graph.pkl")
    started = time.perf_counter()
    loaded = load_bundle(path)
    assert (time.perf_counter() - started) < 20
    assert loaded.flow.number_of_nodes() == bundle.flow.number_of_nodes()
    assert tools.path_between(loaded, s.RINA_ACCT, s.COLLUDING_TILL_ACCT, max_hops=5, as_of=AS_OF_END)["found"]


# --- confirmation lag and label hygiene -----------------------------------------------------------


def test_confirmed_fraud_needs_the_lag_to_have_passed(bundle):
    from datetime import timedelta

    from bhorosha_graph.features import CONFIRMATION_LAG_DAYS, confirmed_fraud

    label = next(l for l in bundle.known_fraud if l["role"] == "mule_L1")
    first_bad = s.parse_ts(label["first_bad_ts"])
    exactly = s.format_ts(first_bad + timedelta(days=CONFIRMATION_LAG_DAYS))
    just_after = s.format_ts(first_bad + timedelta(days=CONFIRMATION_LAG_DAYS, seconds=1))
    assert label["acct_id"] not in confirmed_fraud(bundle, exactly)
    assert label["acct_id"] in confirmed_fraud(bundle, just_after)
    assert label["acct_id"] in confirmed_fraud(bundle, None)  # no time reference: no lag to apply


def test_a_ring_is_not_confirmed_fraud_while_it_is_still_cashing_out(bundle, demo):
    """At 14:35 on the takeover day the demo ring is minutes old: nobody has confirmed it."""
    during = "2026-11-10T14:35:00"
    for member in demo["mule_L2"]:
        out = tools.known_fraud_proximity(bundle, member, as_of=during, max_hops=2)
        in_ring = {h["acct_id"] for h in out["hits"]} & {a for accts in demo.values() for a in accts}
        assert in_ring == set(), f"{member} sees its own ring as already confirmed: {in_ring}"


def test_known_fraud_proximity_never_returns_labels(bundle, demo):
    out = tools.known_fraud_proximity(bundle, demo["mule_L2"][0], as_of=AS_OF_END, max_hops=2)
    assert out["hits"], "the fixture should have at least one confirmed neighbour at the end of the world"
    for hit in out["hits"]:
        assert set(hit) == {"acct_id", "hops", "confirmed_before"}
    assert out["confirmation_lag_days"] == 3
