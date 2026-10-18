import time
from datetime import timedelta

from bhorosha_synth import schema as s

from case_zero.config import DEMO_AS_OF, DEMO_SEED


def test_lagged_proximity_hides_own_ring(world):
    out = world.known_fraud_proximity(DEMO_SEED, DEMO_AS_OF)
    demo_ring = {l["acct_id"] for l in world.bundle.labels if l["ring_id"] == "ring_demo_otp"}
    assert not ({h["acct_id"] for h in out["hits"]} & demo_ring)
    assert all(set(h) == {"acct_id", "hops", "confirmed_before"} for h in out["hits"])  # no ring id or role reaches the agent


def test_lagged_proximity_keeps_old_rings(world):
    # a takeover ring: its L2 mules are one money hop from the L1, so they must show once confirmed
    l1 = next(l for l in sorted(world.bundle.labels, key=lambda l: l["first_bad_ts"]) if l["role"] == "mule_L1" and l["typology"] == "otp_takeover_cashout" and l["ring_id"] != "ring_demo_otp")
    as_of = s.format_ts(s.parse_ts(l1["first_bad_ts"]) + timedelta(days=5))
    out = world.known_fraud_proximity(l1["acct_id"], as_of)
    ring = {l["acct_id"] for l in world.bundle.labels if l["ring_id"] == l1["ring_id"]}
    assert {h["acct_id"] for h in out["hits"]} & ring


def test_score_at_is_time_aware(world):
    l2 = world.score_at("acct_01288", DEMO_AS_OF)
    l1 = world.score_at(DEMO_SEED, DEMO_AS_OF)
    assert l2["probability"] < 0.5
    assert l1["probability"] > 0.8
    assert l1["as_of"] == DEMO_AS_OF
    assert len(l1["reasons"]) == 10


def test_score_at_caches_features(world):
    world.score_at(DEMO_SEED, DEMO_AS_OF)
    t0 = time.perf_counter()
    world.score_at("acct_01870", DEMO_AS_OF)
    assert (time.perf_counter() - t0) * 1000 < 50


def test_account_lookup(world):
    assert world.account("acct_rina")["kind"] == "customer"
    assert world.account("acct_does_not_exist") is None
