"""GraphBundle: the money-flow graph, the entity-link graph and lookups, built once and pickled.

Loads at Cloud Run start-up in well under 20 s for the small world (spec FR-4).
"""

from __future__ import annotations

import json
import pickle
from dataclasses import dataclass
from pathlib import Path

import networkx as nx

from bhorosha_synth import schema as s
from bhorosha_synth.world import World

Rows = tuple[dict, ...]
MONEY_TYPES = frozenset({"cash_in", "cash_out", "send_money", "payment", "salary", "recharge"})


@dataclass(frozen=True)
class GraphBundle:
    flow: nx.MultiDiGraph            # account -> account, one edge per transaction (txn_id, ts, type, amount)
    links: nx.Graph                  # account <-> device / sim / onboarding_agent / nid / phone
    accounts: dict[str, dict]        # acct_id -> account row (+ owner customer fields when present)
    agents: dict[str, dict]          # agent_id -> agent row
    labels: Rows
    txns_by_acct: dict[str, tuple[dict, ...]]  # every transaction touching the account, time-sorted
    sim_events: Rows = ()
    device_links: Rows = ()
    sims: Rows = ()

    @property
    def known_fraud(self) -> tuple[dict, ...]:
        return tuple(l for l in self.labels if l["role"] != "victim")


def _entity_links(world: World) -> nx.Graph:
    g = nx.Graph()
    customers = {c["cust_id"]: c for c in world.customers}
    for a in world.accounts:
        g.add_node(a["acct_id"], kind="account")
        if a.get("onboarding_agent_id"):
            g.add_edge(a["acct_id"], f"onboarding_agent:{a['onboarding_agent_id']}", kind="onboarding_agent")
        owner = customers.get(a["owner_id"])
        if owner:
            g.add_edge(a["acct_id"], f"nid:{owner['nid_hash']}", kind="nid")
            g.add_edge(a["acct_id"], f"phone:{owner['phone_hash']}", kind="phone")
    for link in world.device_links:
        g.add_edge(link["acct_id"], f"device:{link['device_id']}", kind="device", first_seen=link["first_seen"])
    for sim in world.sims:
        g.add_edge(sim["acct_id"], f"sim:{sim['sim_id']}", kind="sim", activated_at=sim["activated_at"])
    return g


def _flow(world: World) -> tuple[nx.MultiDiGraph, dict[str, tuple[dict, ...]]]:
    g = nx.MultiDiGraph()
    by_acct: dict[str, list[dict]] = {}
    for t in world.transactions:
        g.add_edge(t["from_acct"], t["to_acct"], key=t["txn_id"], ts=t["ts"], type=t["type"], amount=t["amount_bdt"], agent_id=t["agent_id"])
        by_acct.setdefault(t["from_acct"], []).append(t)
        by_acct.setdefault(t["to_acct"], []).append(t)
    return g, {k: tuple(sorted(v, key=lambda t: t["ts"])) for k, v in by_acct.items()}


def build_bundle(world: World) -> GraphBundle:
    customers = {c["cust_id"]: c for c in world.customers}
    accounts = {a["acct_id"]: {**a, **{f"owner_{k}": v for k, v in customers.get(a["owner_id"], {}).items() if k in ("name", "district", "segment", "age", "created_at")}} for a in world.accounts}
    flow, txns_by_acct = _flow(world)
    return GraphBundle(
        flow=flow, links=_entity_links(world), accounts=accounts, agents={a["agent_id"]: a for a in world.agents}, labels=world.labels,
        txns_by_acct=txns_by_acct, sim_events=world.sim_events, device_links=world.device_links, sims=world.sims,
    )


def load_world_tables(seed_dir: Path) -> World:
    def rows(name: str) -> Rows:
        with (seed_dir / name).open(encoding="utf-8") as handle:
            return tuple(json.loads(line) for line in handle if line.strip())

    config_path = seed_dir / "config.json"
    raw = json.loads(config_path.read_text(encoding="utf-8")) if config_path.exists() else {}
    config = s.WorldConfig(**{k: v for k, v in raw.items() if k not in ("checksum", "campaign")})
    # The campaign world names its campaigns in config.json and adds attempts.jsonl and bursts.jsonl.
    campaign = s.CampaignConfig(campaigns=raw["campaign"]["campaigns"]) if "campaign" in raw else None
    extra = {"campaign": campaign, "attempts": rows("attempts.jsonl"), "bursts": rows("bursts.jsonl")} if campaign is not None else {}
    return World(
        config=config,
        customers=rows("customers.jsonl"), accounts=rows("accounts.jsonl"), sims=rows("sims.jsonl"), sim_events=rows("sim_events.jsonl"),
        devices=rows("devices.jsonl"), device_links=rows("device_links.jsonl"), agents=rows("agents.jsonl"), merchants=rows("merchants.jsonl"),
        transactions=rows("transactions.jsonl"), labels=rows("labels.jsonl"), **extra,
    )


def save_bundle(bundle: GraphBundle, path: Path) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as handle:
        pickle.dump(bundle, handle, protocol=pickle.HIGHEST_PROTOCOL)
    return path


def load_bundle(path: Path) -> GraphBundle:
    with path.open("rb") as handle:
        bundle = pickle.load(handle)  # noqa: S301 - artefact produced by this package, not user input
    if not isinstance(bundle, GraphBundle):
        raise TypeError(f"{path} is not a GraphBundle")
    return bundle
