"""The separate campaign world (`--campaigns`), written beside the demo seed and never over it."""

from __future__ import annotations

import json
import re
from collections import Counter
from pathlib import Path

import pytest

from bhorosha_graph.bundle import load_world_tables
from bhorosha_synth import schema as s
from bhorosha_synth.generate import generate_world, main, write_world
from bhorosha_synth.typologies import (CALLCENTRE_CASHOUT_MIN, CALLCENTRE_HELD, CALLCENTRE_PAYEES, CALLCENTRE_SPAN_MIN,
                                       CALLCENTRE_VICTIMS)
from bhorosha_synth.world import World

SEED = 42
DEMO_SEED_DIR = Path(__file__).resolve().parents[3] / "data" / "seed"
CAMPAIGN_IDS = tuple(f"ring_callcentre_{n}" for n in range(len(s.CAMPAIGN_DAYS)))


@pytest.fixture(scope="module")
def demo() -> World:
    return generate_world(s.WorldConfig(seed=SEED))


@pytest.fixture(scope="module")
def world() -> World:
    return generate_world(s.WorldConfig(seed=SEED), s.CampaignConfig())


@pytest.fixture(scope="module")
def free() -> World:
    return generate_world(s.WorldConfig(seed=SEED), s.CampaignConfig(campaigns=0))


def _ring_rows(rows, ring_id: str) -> list[dict]:
    return [r for r in rows if r.get("ring_id") == ring_id or r.get("truth_campaign") == ring_id]


@pytest.mark.skipif(not (DEMO_SEED_DIR / "CHECKSUM").exists(), reason="data/seed is absent")
def test_the_default_command_still_writes_the_committed_demo_seed_byte_for_byte(tmp_path):
    out = tmp_path / "seed"
    assert main(["--seed", str(SEED), "--out", str(out)]) == 0
    written = sorted(p.name for p in out.iterdir())
    assert written == sorted(p.name for p in DEMO_SEED_DIR.iterdir())
    for name in written:
        assert (out / name).read_bytes() == (DEMO_SEED_DIR / name).read_bytes(), name


def test_campaign_world_adds_two_files_and_a_campaign_block_and_is_reproducible(tmp_path, world):
    out = tmp_path / "seed_campaign"
    assert main(["--seed", str(SEED), "--campaigns", "3", "--out", str(out)]) == 0
    assert {p.name for p in out.glob("*.jsonl")} == set(s.FILE_NAMES + s.CAMPAIGN_FILE_NAMES)
    config = json.loads((out / "config.json").read_text(encoding="utf-8"))
    assert config["campaign"] == {"campaigns": 3, "days": list(s.CAMPAIGN_DAYS)}
    assert (out / "CHECKSUM").read_text(encoding="utf-8").strip() == world.checksum() == config["checksum"]
    assert generate_world(s.WorldConfig(seed=SEED), s.CampaignConfig()).checksum() == world.checksum()
    assert load_world_tables(out).checksum() == world.checksum()


def test_campaign_world_refuses_to_write_over_a_demo_seed_and_never_reaches_the_cloud(tmp_path):
    import load_seed

    demo_dir = tmp_path / "seed"
    assert main(["--seed", str(SEED), "--out", str(demo_dir)]) == 0
    before = {p.name: p.read_bytes() for p in demo_dir.iterdir()}
    assert main(["--seed", str(SEED), "--campaigns", "3", "--out", str(demo_dir)]) == 2
    assert {p.name: p.read_bytes() for p in demo_dir.iterdir()} == before
    campaign_dir = tmp_path / "seed_campaign"
    assert main(["--seed", str(SEED), "--campaigns", "1", "--out", str(campaign_dir)]) == 0
    with pytest.raises(SystemExit, match="offline only"):
        load_seed.main(["--seed-dir", str(campaign_dir), "--target", "bigquery"])
    assert load_seed.main(["--seed-dir", str(campaign_dir), "--target", "local"]) == 0


def test_campaign_free_world_is_the_demo_world_plus_attempts_and_bursts(demo, free):
    for name, rows in demo.tables().items():
        assert free.tables()[name] == rows, name
    assert free.attempts and free.bursts
    assert not [l for l in free.labels if l["typology"] == s.CAMPAIGN_TYPOLOGY]


def test_campaigns_draw_on_their_own_stream_so_every_demo_row_survives(demo, world):
    for name, rows in demo.tables().items():
        if name == "transactions.jsonl":
            strip = lambda r: json.dumps({k: v for k, v in r.items() if k != "txn_id"}, sort_keys=True)  # noqa: E731
            assert Counter(map(strip, rows)) - Counter(map(strip, world.transactions)) == Counter()
        else:
            have = {json.dumps(r, sort_keys=True, ensure_ascii=False) for r in world.tables()[name]}
            assert all(json.dumps(r, sort_keys=True, ensure_ascii=False) in have for r in rows), name


def test_old_rings_held_retries_are_identical_with_or_without_campaigns(world, free):
    def key(a: dict) -> tuple:
        return a["ts"], a["from_acct"], a["to_acct"], a["amount_bdt"], a["truth_campaign"]

    old = [key(a) for a in world.attempts if a["decision"] == "hold" and a["truth_campaign"] not in CAMPAIGN_IDS]
    assert old and old == [key(a) for a in free.attempts if a["decision"] == "hold"]


def test_attempts_and_ledger_agree(world):
    payments = [t for t in world.transactions if t["type"] in s.ATTEMPT_TYPES]
    allowed = [a for a in world.attempts if a["decision"] == "allow"]
    assert len(allowed) == len(payments)
    assert Counter(a["txn_id"] for a in allowed) == Counter(t["txn_id"] for t in payments)
    assert all(a["txn_id"] is None for a in world.attempts if a["decision"] != "allow")
    assert {a["type"] for a in world.attempts} == set(s.ATTEMPT_TYPES)
    assert {a["decision"] for a in world.attempts} == {"allow", "hold"} and set(s.DECISIONS) >= {"allow", "hold"}
    assert all(tuple(a) == s.ATTEMPT_FIELDS for a in world.attempts)
    assert len({a["attempt_id"] for a in world.attempts}) == len(world.attempts)
    assert [a["ts"] for a in world.attempts] == sorted(a["ts"] for a in world.attempts)
    assert not [k for a in world.attempts[:1] for k in a if k.startswith("truth_") and k != "truth_campaign"]


def test_every_ledger_ring_payment_carries_its_ring_as_truth_and_benign_ones_carry_none(world):
    ring_of = {t["txn_id"]: t["ring_id"] for t in world.transactions}
    for a in world.attempts:
        if a["txn_id"] is not None:
            assert a["truth_campaign"] == ring_of[a["txn_id"]], a


def test_some_ring_shows_a_held_attempt_then_its_allowed_retry_and_the_demo_ring_none(world):
    holds = [a for a in world.attempts if a["decision"] == "hold" and a["truth_campaign"] not in CAMPAIGN_IDS]
    assert holds and not [a for a in holds if a["truth_campaign"] == s.DEMO_RING_ID]
    for held in holds:
        twin = [a for a in world.attempts if a["decision"] == "allow" and a["truth_campaign"] == held["truth_campaign"]
                and (a["from_acct"], a["to_acct"], a["amount_bdt"]) == (held["from_acct"], held["to_acct"], held["amount_bdt"])]
        lead = (s.parse_ts(twin[0]["ts"]) - s.parse_ts(held["ts"])).total_seconds() / 60
        assert 3 <= lead <= 8


@pytest.mark.parametrize("ring_id", CAMPAIGN_IDS)
def test_each_campaign_is_thirty_victims_of_one_district_paying_three_to_five_fresh_payees(world, demo, ring_id):
    labels = [l for l in world.labels if l["ring_id"] == ring_id]
    assert {l["typology"] for l in labels} == {s.CAMPAIGN_TYPOLOGY}
    victims = {l["acct_id"] for l in labels if l["role"] == "victim"}
    payees = {l["acct_id"] for l in labels if l["role"] == "mule_L1"}
    assert len(victims) == CALLCENTRE_VICTIMS and CALLCENTRE_PAYEES[0] <= len(payees) <= CALLCENTRE_PAYEES[1]
    attempts = _ring_rows(world.attempts, ring_id)
    assert len(attempts) == CALLCENTRE_VICTIMS and {a["from_acct"] for a in attempts} == victims
    assert {a["to_acct"] for a in attempts} <= payees
    assert Counter(a["decision"] for a in attempts) == {"hold": CALLCENTRE_HELD, "allow": CALLCENTRE_VICTIMS - CALLCENTRE_HELD}
    span = (s.parse_ts(attempts[-1]["ts"]) - s.parse_ts(attempts[0]["ts"])).total_seconds() / 60
    assert span <= CALLCENTRE_SPAN_MIN
    accounts = {a["acct_id"]: a for a in world.accounts}
    assert len({accounts[v]["district"] for v in victims | payees}) == 1
    assert len({accounts[p]["onboarding_agent_id"] for p in payees}) == 1
    assert accounts[next(iter(payees))]["onboarding_agent_id"] != s.COLLUDING_AGENT_ID
    assert not payees & {a["acct_id"] for a in demo.accounts}
    sims = [x for x in world.sims if x["acct_id"] in payees]
    assert len(sims) == len(payees) and len({x["activated_at"][:10] for x in sims}) == 1
    assert {e["acct_id"] for e in world.sim_events if e["event"] == "activate"} >= payees


@pytest.mark.parametrize("ring_id", CAMPAIGN_IDS)
def test_each_campaigns_allowed_money_is_cashed_out_at_one_till_as_ledger_outcomes_only(world, ring_id):
    ledger = _ring_rows(world.transactions, ring_id)
    transfers = sorted((t for t in ledger if t["type"] == "send_money"), key=lambda t: t["ts"])
    cashouts = [t for t in ledger if t["type"] == "cash_out"]
    assert len(transfers) == len(cashouts) == CALLCENTRE_VICTIMS - CALLCENTRE_HELD
    assert len({t["agent_id"] for t in cashouts}) == 1
    till = next(a for a in world.agents if a["agent_id"] == cashouts[0]["agent_id"])
    assert {t["to_acct"] for t in cashouts} == {till["acct_id"]} and till["agent_id"] != s.COLLUDING_AGENT_ID
    for transfer in transfers:
        out = [c for c in cashouts if c["from_acct"] == transfer["to_acct"] and c["amount_bdt"] == transfer["amount_bdt"]]
        gaps = [(s.parse_ts(c["ts"]) - s.parse_ts(transfer["ts"])).total_seconds() / 60 for c in out]
        assert any(CALLCENTRE_CASHOUT_MIN[0] <= g <= CALLCENTRE_CASHOUT_MIN[1] for g in gaps)
    assert not [a for a in world.attempts if a["truth_campaign"] == ring_id and a["type"] == "cash_out"]


def test_campaigns_fall_on_their_days_one_in_the_test_week_and_every_device_has_a_row(world):
    start = s.parse_ts(world.config.start_date + "T00:00:00")
    days = [(s.parse_ts(_ring_rows(world.attempts, r)[0]["ts"]) - start).days for r in CAMPAIGN_IDS]
    assert tuple(days) == s.CAMPAIGN_DAYS and any(28 <= d <= 34 for d in days)
    devices = {d["device_id"] for d in world.devices}
    payees = {l["acct_id"] for l in world.labels if l["typology"] == s.CAMPAIGN_TYPOLOGY and l["role"] == "mule_L1"}
    linked = [d for d in world.device_links if d["acct_id"] in payees]
    assert linked and all(d["device_id"] in devices for d in linked)
    shared = Counter(d["device_id"] for d in linked)
    assert max(shared.values()) >= 2  # the controller's phone runs two payees in every campaign


def test_campaign_ids_stay_symbolic(world, demo):
    new = {a["acct_id"] for a in world.accounts} - {a["acct_id"] for a in demo.accounts}
    assert new and all(re.fullmatch(r"acct_\d{5}", a) for a in new)
    assert not [a for a in new if re.search(r"01\d{9}", a)]


def test_bursts_name_the_four_benign_scenarios_and_each_matches_the_ledger(world):
    bursts = {b["burst_id"]: b for b in world.bursts}
    assert set(bursts) == {"payday_1", "payday_2", "wedding", "hospital"}
    assert all(tuple(b) == s.BURST_FIELDS for b in world.bursts)

    def members(burst: dict, rows) -> list[dict]:
        return [r for r in rows if burst["start"] <= r["ts"] < burst["end"] and r["type"] in burst["types"]
                and (not burst["acct_ids"] or r["from_acct"] in burst["acct_ids"] or r["to_acct"] in burst["acct_ids"])]

    for burst in world.bursts:
        assert members(burst, world.transactions), burst["burst_id"]
    hospital = members(bursts["hospital"], world.attempts)
    assert len(hospital) == 6 and {a["to_acct"] for a in hospital} == set(bursts["hospital"]["acct_ids"])
    assert bursts["wedding"]["types"] == ["cash_out"] and len(members(bursts["wedding"], world.transactions)) == 3
    assert not set(bursts["wedding"]["types"]) & set(s.ATTEMPT_TYPES)
