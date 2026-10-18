"""Generate the synthetic FinNest world, or the separate campaign world for the Campaign Radar.

    python -m bhorosha_synth.generate --seed 42 --out ../../data/seed                      # the demo seed
    python -m bhorosha_synth.generate --seed 42 --campaigns 3 --out ../../data/seed-campaign   # the campaign world
    python -m bhorosha_synth.generate --seed 42 --campaigns 0 --out /tmp/campaign_free     # its campaign-free replay

The campaign world is the demo world plus three call-centre campaigns, attempts.jsonl and bursts.jsonl. It never
writes over the demo seed: the campaigns draw on their own rng stream, so without --campaigns the output is the
demo seed byte for byte.
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import asdict, replace
from pathlib import Path

import numpy as np
from faker import Faker

from bhorosha_synth import schema as s
from bhorosha_synth.attempts import build_attempts, held_retries
from bhorosha_synth.background import BackgroundPlan, build_background
from bhorosha_synth.population import build_population
from bhorosha_synth.typologies import Injection, allocate, allocated_accounts, inject_all, inject_campaigns
from bhorosha_synth.world import World

Rows = tuple[dict, ...]
CHECKSUM_FILE = "CHECKSUM"
CONFIG_FILE = "config.json"


def _with_ids(txns: tuple[dict, ...]) -> Rows:
    ordered = sorted(txns, key=lambda t: (t["ts"], t["from_acct"], t["to_acct"], t["amount_bdt"]))
    return tuple({"txn_id": f"txn_{i:06d}", **t} for i, t in enumerate(ordered))


def _apply_sim_overrides(sims: Rows, overrides: tuple[tuple[str, str], ...]) -> Rows:
    by_acct = dict(overrides)
    return tuple({**sim, "activated_at": by_acct.get(sim["acct_id"], sim["activated_at"])} for sim in sims)


def _sorted_rows(rows: tuple[dict, ...], *keys: str) -> Rows:
    return tuple(sorted(rows, key=lambda r: tuple(str(r[k]) for k in keys)))


def _each(injections: tuple[Injection, ...], field: str) -> Rows:
    return tuple(row for inj in injections for row in getattr(inj, field))


def generate_world(cfg: s.WorldConfig, campaign: s.CampaignConfig | None = None) -> World:
    """The demo world, or with `campaign` the campaign world (campaigns=0: the campaign-free replay)."""
    rng = np.random.default_rng(cfg.seed)
    Faker.seed(cfg.seed)
    faker = Faker("bn_BD")
    pop = build_population(rng, faker, cfg)
    alloc = allocate(rng, pop, cfg)
    bg_txns, bg_sim_events, bg_links, bursts = build_background(rng, pop, cfg, BackgroundPlan(alloc.dormant_accts, alloc.forced_payments))
    injections: tuple[Injection, ...] = inject_all(rng, pop, cfg, alloc)
    if campaign is not None:  # after the main stream is spent, on its own stream
        taken = allocated_accounts(alloc) | frozenset(l["acct_id"] for l in _each(injections, "labels"))
        injections = injections + inject_campaigns(pop, cfg, taken, campaign)
    txns = _with_ids(bg_txns + _each(injections, "transactions"))
    labels = _sorted_rows(_each(injections, "labels"), "ring_id", "role", "acct_id")
    sims = _apply_sim_overrides(pop.sims + _each(injections, "sims"), tuple(o for inj in injections for o in inj.sim_activation_overrides))
    world = World(
        config=cfg,
        customers=pop.customers + _each(injections, "customers"),
        accounts=pop.accounts + _each(injections, "accounts"),
        sims=sims,
        sim_events=_sorted_rows(pop.sim_events + bg_sim_events + _each(injections, "sim_events"), "ts", "acct_id"),
        devices=pop.devices + _each(injections, "devices"),
        device_links=_sorted_rows(pop.device_links + bg_links + _each(injections, "device_links"), "first_seen", "acct_id", "device_id"),
        agents=pop.agents,
        merchants=pop.merchants,
        transactions=txns,
        labels=labels,
    )
    if campaign is None:
        return world
    holds = _each(injections, "held_attempts") + held_retries(cfg.seed, txns, labels)
    return replace(world, campaign=campaign, attempts=build_attempts(txns, holds), bursts=bursts)


def holds_demo_seed(out_dir: Path) -> bool:
    """True when out_dir already holds a world written without --campaigns (the demo seed)."""
    config = out_dir / CONFIG_FILE
    return config.exists() and "campaign" not in json.loads(config.read_text(encoding="utf-8"))


def write_world(world: World, out_dir: Path) -> str:
    out_dir.mkdir(parents=True, exist_ok=True)
    for name, rows in world.tables().items():
        with (out_dir / name).open("w", encoding="utf-8") as handle:
            for row in rows:
                handle.write(json.dumps(row, ensure_ascii=False) + "\n")
    checksum = world.checksum()
    campaign = {"campaign": world.campaign.as_config()} if world.campaign is not None else {}
    (out_dir / CHECKSUM_FILE).write_text(checksum + "\n", encoding="utf-8")
    (out_dir / CONFIG_FILE).write_text(json.dumps({**asdict(world.config), **campaign, "checksum": checksum}, indent=2) + "\n", encoding="utf-8")
    return checksum


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--seed", type=int, default=s.WorldConfig.seed)
    parser.add_argument("--out", type=Path, default=Path("seed"))
    parser.add_argument("--customers", type=int, default=s.WorldConfig.customers)
    parser.add_argument("--rings-per-typology", type=int, default=s.WorldConfig.rings_per_typology)
    parser.add_argument("--campaigns", type=int, default=None,
                        help=f"write the campaign world (0 to {len(s.CAMPAIGN_DAYS)} call-centre campaigns, plus attempts.jsonl and bursts.jsonl); never point --out at the demo seed")
    args = parser.parse_args(argv)
    if args.campaigns is not None and holds_demo_seed(args.out):
        print(f"refusing to write the campaign world over the demo seed in {args.out}; pass another --out", file=sys.stderr)
        return 2
    cfg = s.WorldConfig(seed=args.seed, customers=args.customers, rings_per_typology=args.rings_per_typology)
    world = generate_world(cfg, None if args.campaigns is None else s.CampaignConfig(campaigns=args.campaigns))
    checksum = write_world(world, args.out)
    counts = {name: len(rows) for name, rows in world.tables().items()}
    print(json.dumps({"out": str(args.out), "checksum": checksum, "counts": counts}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
