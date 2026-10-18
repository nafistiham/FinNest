"""Acceptance tests for the synthetic world: determinism, personas, rings and file layout."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from bhorosha_synth import schema
from bhorosha_synth.generate import generate_world, write_world
from bhorosha_synth.world import World

SEED = 42


@pytest.fixture(scope="module")
def world() -> World:
    return generate_world(schema.WorldConfig(seed=SEED))


@pytest.fixture(scope="module")
def out_dir(tmp_path_factory, world) -> Path:
    path = tmp_path_factory.mktemp("seed")
    write_world(world, path)
    return path


def _ids(rows: tuple[dict, ...], key: str) -> set[str]:
    return {r[key] for r in rows}


def test_generation_is_deterministic():
    a = generate_world(schema.WorldConfig(seed=SEED))
    b = generate_world(schema.WorldConfig(seed=SEED))
    assert a.checksum() == b.checksum()
    assert a.checksum() != generate_world(schema.WorldConfig(seed=SEED + 1)).checksum()


def test_nine_files_are_written(out_dir):
    names = {p.name for p in out_dir.glob("*.jsonl")}
    assert names == set(schema.FILE_NAMES)
    assert all(p.stat().st_size > 0 for p in out_dir.glob("*.jsonl"))
    for line in (out_dir / "transactions.jsonl").read_text(encoding="utf-8").splitlines()[:5]:
        json.loads(line)


def test_no_balance_after_columns(world):
    forbidden = {"balance_after", "balance_from_after", "balance_to_after", "newbalanceOrig", "newbalanceDest"}
    assert not forbidden & set(world.transactions[0].keys())


def test_transactions_have_paysim_style_type_and_amount(world):
    txn = world.transactions[0]
    assert txn["type"] in schema.TXN_TYPES
    assert txn["amount_bdt"] > 0


def test_every_transaction_references_known_accounts(world):
    accounts = _ids(world.accounts, "acct_id")
    for txn in world.transactions:
        assert txn["from_acct"] in accounts, txn
        assert txn["to_acct"] in accounts, txn


def test_personas_exist(world):
    accounts = _ids(world.accounts, "acct_id")
    for acct in (schema.RINA_ACCT, schema.RAFIQ_ACCT, schema.RAHIMA_ACCT, schema.COLLUDING_TILL_ACCT, schema.LEGIT_MERCHANT_ACCT):
        assert acct in accounts, acct


def test_rina_sends_monthly_to_rafiq(world):
    sends = [t for t in world.transactions if t["from_acct"] == schema.RINA_ACCT and t["to_acct"] == schema.RAFIQ_ACCT and t["type"] == "send_money"]
    assert sends, "Rina's monthly transfer to Rafiq is missing"
    assert all(abs(t["amount_bdt"] - schema.RINA_MONTHLY_SEND_BDT) < 1 for t in sends)


def test_labels_cover_six_typologies_with_roles(world):
    typologies = {l["typology"] for l in world.labels}
    assert typologies == set(schema.TYPOLOGIES)
    roles = {l["role"] for l in world.labels}
    assert {"victim", "mule_L1", "mule_L2", "cashout_agent"} <= roles
    assert roles <= set(schema.ROLES)


def test_demo_ring_is_traceable_within_120_minutes(world):
    """Rina's takeover -> L1 mule -> L2 mules -> colluding till, 2-5 hops, inside 120 simulated minutes."""
    demo = [l for l in world.labels if l["ring_id"] == schema.DEMO_RING_ID]
    assert any(l["acct_id"] == schema.RINA_ACCT and l["role"] == "victim" for l in demo)
    assert any(l["acct_id"] == schema.COLLUDING_TILL_ACCT and l["role"] == "cashout_agent" for l in demo)
    ring_txns = sorted((t for t in world.transactions if t.get("ring_id") == schema.DEMO_RING_ID), key=lambda t: t["ts"])
    assert ring_txns
    span_minutes = (schema.parse_ts(ring_txns[-1]["ts"]) - schema.parse_ts(ring_txns[0]["ts"])).total_seconds() / 60
    assert span_minutes <= 120
    hops = schema.hop_count(ring_txns, schema.RINA_ACCT, schema.COLLUDING_TILL_ACCT)
    assert 2 <= hops <= 5


def test_sim_swaps_cover_rina_and_one_benign_new_phone(world):
    swaps = [e for e in world.sim_events if e["event"] == "swap"]
    assert len(swaps) == 1 + world.config.rings_per_typology  # one per takeover ring plus the benign replacement
    assert {schema.RINA_ACCT, schema.BENIGN_SIM_SWAP_ACCT} <= {e["acct_id"] for e in swaps}


def test_purchased_mule_cluster_shares_device_and_onboarding_agent(world):
    cluster = [l for l in world.labels if l["ring_id"] == "ring_cluster_0" and l["role"] == "purchased_mule"]
    assert len(cluster) >= 4
    accts = {l["acct_id"] for l in cluster}
    holders: dict[str, set[str]] = {}
    for d in world.device_links:
        if d["acct_id"] in accts:
            holders = {**holders, d["device_id"]: holders.get(d["device_id"], set()) | {d["acct_id"]}}
    assert any(len(h) == len(accts) for h in holders.values()), "purchased mules must share one device"
    onboarding = {a["onboarding_agent_id"] for a in world.accounts if a["acct_id"] in accts}
    assert len(onboarding) == 1


def test_world_size_is_small_enough_for_cloud_run(world):
    assert len(world.customers) <= 5000
    assert len(world.transactions) <= 50000
