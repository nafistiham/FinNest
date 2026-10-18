"""Fraud typology injection (spec 03 FR-2). Six typologies; the first ring of the first typology is
the demo ring that cashes out Rina's stolen money at the colluding till.

Each injector is a pure function of (rng, population, config, allocated accounts) and returns
an Injection. Allocation happens before background generation so dormant mules stay dormant.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import timedelta

import numpy as np

from bhorosha_synth import schema as s
from bhorosha_synth.attempts import attempt_row
from bhorosha_synth.background import _txn
from bhorosha_synth.population import (PHONE_MODELS, PHONE_WEIGHTS, Population, _pick, account_id, customer_id, device_id,
                                       sim_id, stable_hash)

Rows = tuple[dict, ...]


@dataclass(frozen=True)
class Injection:
    transactions: Rows
    labels: Rows
    sim_events: Rows = ()
    device_links: Rows = ()
    sim_activation_overrides: tuple[tuple[str, str], ...] = ()  # (acct_id, activated_at)
    # Only the call-centre campaign opens accounts and writes refusals; the six demo typologies leave these empty.
    customers: Rows = ()
    accounts: Rows = ()
    sims: Rows = ()
    devices: Rows = ()
    held_attempts: Rows = ()


@dataclass(frozen=True)
class Allocation:
    takeover: tuple[tuple[str, ...], ...]          # per ring: (victim, L1, L2 x4, controller)
    purchased: tuple[tuple[str, ...], ...]         # per ring: (controller, mule x5, victim x8)
    ledger_leak: tuple[tuple[str, ...], ...]       # per ring: (victim x6, mule x2)
    round_trip: tuple[tuple[str, ...], ...]        # per ring: (a, b, c)
    fan: tuple[tuple[str, ...], ...]               # per ring: (hub, sender x15, out x6)
    dormant: tuple[tuple[str, ...], ...]           # per ring: (mule x4)
    dormant_accts: frozenset[str] = field(default_factory=frozenset)
    forced_payments: tuple[tuple[str, str, int], ...] = ()


def _label(acct_id: str, ring_id: str, role: str, typology: str, first_bad_ts: str) -> dict:
    return {"acct_id": acct_id, "ring_id": ring_id, "role": role, "typology": typology, "first_bad_ts": first_bad_ts}


def _at(pop: Population, day: int, hour: int, minute: int) -> str:
    return s.format_ts(pop.window_start + timedelta(days=day, hours=hour, minutes=minute))


def _pool(pop: Population) -> tuple[str, ...]:
    """Ordinary customer accounts (no personas), sorted for determinism."""
    return tuple(sorted(a["acct_id"] for a in pop.accounts if a["kind"] == "customer" and a["owner_id"].startswith("cust_0")))


def _cluster_candidates(pop: Population, size: int, exclude: frozenset[str]) -> tuple[str, ...]:
    """`size` accounts sharing district and onboarding agent, the largest such group."""
    groups: dict[tuple[str, str], tuple[str, ...]] = {}
    for a in sorted(pop.accounts, key=lambda a: a["acct_id"]):
        if a["kind"] != "customer" or a["acct_id"] in exclude or not a["owner_id"].startswith("cust_0"):
            continue
        key = (a["district"], a["onboarding_agent_id"])
        groups = {**groups, key: groups.get(key, ()) + (a["acct_id"],)}
    best = max(groups.values(), key=lambda g: (len(g), g[0]))
    if len(best) < size:
        raise ValueError(f"no onboarding-agent group with {size} accounts; raise customers in WorldConfig")
    return best[:size]


def allocate(rng: np.random.Generator, pop: Population, cfg: s.WorldConfig) -> Allocation:
    pool = list(_pool(pop))
    order = [pool[int(i)] for i in rng.permutation(len(pool))]
    cursor = 0

    def take(n: int) -> tuple[str, ...]:
        nonlocal cursor
        chunk = tuple(order[cursor:cursor + n])
        cursor += n
        if len(chunk) < n:
            raise ValueError("not enough customer accounts for typology allocation")
        return chunk

    n = cfg.rings_per_typology
    takeover = tuple(((s.RINA_ACCT,) if i == 0 else take(1)) + take(6) for i in range(n))
    purchased = []
    for _ in range(n):
        controller, victims = take(1), take(8)
        used = frozenset(a for ring in (takeover + tuple(purchased)) for a in ring) | frozenset(order[:cursor])
        mules = _cluster_candidates(pop, 5, used)
        purchased.append(controller + mules + victims)
    purchased_t = tuple(purchased)
    ledger = tuple(take(8) for _ in range(n))
    round_trip = tuple(take(3) for _ in range(n))
    fan = tuple(take(22) for _ in range(n))
    dormant = tuple(take(4) for _ in range(n))
    dormant_accts = frozenset(a for ring in purchased_t for a in ring[1:6]) | frozenset(a for ring in dormant for a in ring)
    forced = tuple((victim, s.LEGIT_MERCHANT_ACCT, 2 + i % 4) for ring in ledger for i, victim in enumerate(ring[:6]))
    return Allocation(takeover, purchased_t, ledger, round_trip, fan, dormant, dormant_accts, forced)


RING_DAY_FIRST = 8
RING_DAY_TAIL = 6


def _ring_day(rng: np.random.Generator, cfg: s.WorldConfig, ring_no: int) -> int:
    """Start day for ring `ring_no`: rings are stratified across the window so each typology is seen early, mid and late."""
    lo, hi = RING_DAY_FIRST, cfg.days - RING_DAY_TAIL
    width = (hi - lo) / max(cfg.rings_per_typology, 1)
    return int(lo + width * ring_no + rng.integers(0, max(int(width), 1)))


def _random_agent(rng: np.random.Generator, pop: Population) -> str:
    agents = tuple(sorted(a["agent_id"] for a in pop.agents if a["agent_id"] != s.COLLUDING_AGENT_ID))
    return agents[int(rng.integers(0, len(agents)))]


def inject_takeover(rng: np.random.Generator, pop: Population, cfg: s.WorldConfig, ring: tuple[str, ...], ring_no: int, demo: bool) -> Injection:
    victim, l1, l2s, controller = ring[0], ring[1], ring[2:6], ring[6]
    ring_id = s.DEMO_RING_ID if demo else f"ring_otp_{ring_no}"
    agent = s.COLLUDING_AGENT_ID if demo or rng.random() < 0.5 else _random_agent(rng, pop)
    t0 = _at(pop, s.DEMO_TAKEOVER_DAY, 14, 2) if demo else _at(pop, _ring_day(rng, cfg, ring_no), int(rng.integers(10, 20)), int(rng.integers(0, 60)))
    drain = 7900.0 if demo else float(rng.integers(4000, 12000))
    old_sim = next(x["sim_id"] for x in pop.sims if x["acct_id"] == victim)
    attacker_device = f"dev_attacker_{ring_id}"
    share = round((drain - 500.0) / len(l2s) / 10) * 10
    txns = [
        _txn(s.add_minutes(t0, 11), "send_money", drain, victim, l1, "app", device_id=attacker_device, ring_id=ring_id),
        _txn(s.add_minutes(t0, 18), "send_money", 400.0, l1, controller, "app", ring_id=ring_id),
    ]
    for i, l2 in enumerate(l2s):
        txns.append(_txn(s.add_minutes(t0, 25 + 2 * i), "send_money", share, l1, l2, "app", ring_id=ring_id))
        txns.append(_txn(s.add_minutes(t0, 40 + 15 * i), "cash_out", share, l2, f"acct_till_{agent}", "agent", agent_id=agent, ring_id=ring_id))
    labels = (
        _label(victim, ring_id, "victim", "otp_takeover_cashout", t0),
        _label(l1, ring_id, "mule_L1", "otp_takeover_cashout", t0),
        *(_label(l2, ring_id, "mule_L2", "otp_takeover_cashout", t0) for l2 in l2s),
        _label(controller, ring_id, "controller", "otp_takeover_cashout", t0),
    ) + ((_label(f"acct_till_{agent}", ring_id, "cashout_agent", "otp_takeover_cashout", t0),) if agent == s.COLLUDING_AGENT_ID else ())
    return Injection(
        transactions=tuple(txns),
        labels=labels,
        sim_events=({"event": "swap", "acct_id": victim, "sim_id": old_sim, "ts": t0, "new_sim_id": f"sim_swapped_{ring_id}"},),
        device_links=({"acct_id": victim, "device_id": attacker_device, "first_seen": s.add_minutes(t0, 3), "is_primary": False},),
    )


def inject_purchased_cluster(rng: np.random.Generator, pop: Population, cfg: s.WorldConfig, ring: tuple[str, ...], ring_no: int) -> Injection:
    controller, mules, victims = ring[0], ring[1:6], ring[6:]
    ring_id = f"ring_cluster_{ring_no}"
    activation = s.format_ts(pop.window_start - timedelta(days=40 + 5 * ring_no, hours=-10))
    shared_device = f"dev_cluster_{ring_id}"
    day0 = _ring_day(rng, cfg, ring_no)
    t_fan = _at(pop, day0, 19, 0)
    t_go = _at(pop, day0 + 1, 13, 0)
    txns = [_txn(s.add_minutes(t_fan, 7 * i), "send_money", float(rng.integers(2000, 6000)), v, controller, "app", ring_id=ring_id) for i, v in enumerate(victims)]
    agents = (s.COLLUDING_AGENT_ID,) + tuple(_random_agent(rng, pop) for _ in mules[1:])
    for i, (mule, agent) in enumerate(zip(mules, agents, strict=True)):
        amount = float(rng.integers(3000, 6000))
        txns.append(_txn(s.add_minutes(t_go, 4 * i), "send_money", amount, controller, mule, "app", ring_id=ring_id))
        txns.append(_txn(s.add_minutes(t_go, 35 + 17 * i), "cash_out", amount, mule, f"acct_till_{agent}", "agent", agent_id=agent, ring_id=ring_id))
    labels = (
        _label(controller, ring_id, "controller", "purchased_mule_cluster", t_fan),
        *(_label(m, ring_id, "purchased_mule", "purchased_mule_cluster", t_go) for m in mules),
        *(_label(v, ring_id, "victim", "purchased_mule_cluster", t_fan) for v in victims),
        _label(s.COLLUDING_TILL_ACCT, ring_id, "cashout_agent", "purchased_mule_cluster", t_go),
    )
    return Injection(
        transactions=tuple(txns),
        labels=labels,
        device_links=tuple({"acct_id": m, "device_id": shared_device, "first_seen": activation, "is_primary": False} for m in mules),
        sim_activation_overrides=tuple((m, activation) for m in mules),
    )


def inject_ledger_leak(rng: np.random.Generator, pop: Population, cfg: s.WorldConfig, ring: tuple[str, ...], ring_no: int) -> Injection:
    victims, mules = ring[:6], ring[6:8]
    ring_id = f"ring_leak_{ring_no}"
    day0 = _ring_day(rng, cfg, ring_no)
    txns, labels = [], []
    for i, victim in enumerate(victims):
        t0 = _at(pop, day0 + i % 4, int(rng.integers(11, 19)), int(rng.integers(0, 60)))
        mule = mules[i % 2]
        amount = float(rng.integers(3000, 9000))
        agent = _random_agent(rng, pop)
        txns.append(_txn(s.add_minutes(t0, 9), "send_money", amount, victim, mule, "app", ring_id=ring_id))
        txns.append(_txn(s.add_minutes(t0, 9 + int(rng.integers(40, 170))), "cash_out", amount, mule, f"acct_till_{agent}", "agent", agent_id=agent, ring_id=ring_id))
        labels.append(_label(victim, ring_id, "victim", "ledger_leak_targeting", t0))
    labels.extend(_label(m, ring_id, "mule_L1", "ledger_leak_targeting", _at(pop, day0, 11, 0)) for m in mules)
    return Injection(tuple(txns), tuple(labels))


def inject_round_tripping(rng: np.random.Generator, pop: Population, cfg: s.WorldConfig, ring: tuple[str, ...], ring_no: int) -> Injection:
    a, b, c = ring
    ring_id = f"ring_roundtrip_{ring_no}"
    till = s.COLLUDING_TILL_ACCT if ring_no == 0 else f"acct_till_{_random_agent(rng, pop)}"
    agent_id = till.removeprefix("acct_till_")
    day0 = _ring_day(rng, cfg, ring_no)
    txns = []
    for day in range(day0, min(day0 + 15, cfg.days)):
        base = _at(pop, day, 20, int(rng.integers(0, 30)))
        first, second = (a, b) if day % 2 == 0 else (c, a)
        amount = float(rng.integers(44000, 50001))
        txns.append(_txn(base, "cash_in", amount, till, first, "agent", agent_id=agent_id, ring_id=ring_id))
        txns.append(_txn(s.add_minutes(base, 6), "send_money", amount - 500.0, first, second, "ussd", ring_id=ring_id))
        txns.append(_txn(s.add_minutes(base, 14), "cash_out", amount - 1000.0, second, till, "agent", agent_id=agent_id, ring_id=ring_id))
    t0 = _at(pop, day0, 20, 0)
    labels = tuple(_label(x, ring_id, "mule_L1", "agent_round_tripping", t0) for x in (a, b, c)) + (_label(till, ring_id, "cashout_agent", "agent_round_tripping", t0),)
    return Injection(tuple(txns), labels)


def inject_fan(rng: np.random.Generator, pop: Population, cfg: s.WorldConfig, ring: tuple[str, ...], ring_no: int) -> Injection:
    hub, senders, outs = ring[0], ring[1:16], ring[16:22]
    ring_id = f"ring_fan_{ring_no}"
    t0 = _at(pop, _ring_day(rng, cfg, ring_no), 9, 0)
    txns = [_txn(s.add_minutes(t0, 12 * i), "send_money", float(rng.integers(1000, 4000)), v, hub, "app", ring_id=ring_id) for i, v in enumerate(senders)]
    total = sum(t["amount_bdt"] for t in txns)
    share = round(total / len(outs) / 10) * 10 - 10
    for i, out in enumerate(outs):
        agent = _random_agent(rng, pop)
        txns.append(_txn(s.add_minutes(t0, 240 + 9 * i), "send_money", share, hub, out, "app", ring_id=ring_id))
        txns.append(_txn(s.add_minutes(t0, 330 + 25 * i), "cash_out", share, out, f"acct_till_{agent}", "agent", agent_id=agent, ring_id=ring_id))
    labels = (_label(hub, ring_id, "controller", "fan_in_fan_out", t0),) + tuple(_label(v, ring_id, "victim", "fan_in_fan_out", t0) for v in senders) + tuple(_label(o, ring_id, "mule_L2", "fan_in_fan_out", t0) for o in outs)
    return Injection(tuple(txns), labels)


def inject_dormant(rng: np.random.Generator, pop: Population, cfg: s.WorldConfig, ring: tuple[str, ...], ring_no: int) -> Injection:
    ring_id = f"ring_dormant_{ring_no}"
    pool = _pool(pop)
    day0 = _ring_day(rng, cfg, ring_no)
    txns, labels = [], []
    for i, mule in enumerate(ring):
        t0 = _at(pop, day0, 10 + i * 2, int(rng.integers(0, 60)))
        total = 0.0
        for j in range(3):
            victim = pool[int(rng.integers(0, len(pool)))]
            amount = float(rng.integers(2000, 5000))
            total += amount
            txns.append(_txn(s.add_minutes(t0, 15 * j), "send_money", amount, victim, mule, "app", ring_id=ring_id))
            labels.append(_label(victim, ring_id, "victim", "dormant_then_active", t0))
        agent = _random_agent(rng, pop)
        txns.append(_txn(s.add_minutes(t0, 75), "cash_out", total, mule, f"acct_till_{agent}", "agent", agent_id=agent, ring_id=ring_id))
        labels.append(_label(mule, ring_id, "mule_L1", "dormant_then_active", t0))
    return Injection(tuple(txns), tuple(labels))


def inject_all(rng: np.random.Generator, pop: Population, cfg: s.WorldConfig, alloc: Allocation) -> tuple[Injection, ...]:
    return (
        *(inject_takeover(rng, pop, cfg, ring, i, demo=i == 0) for i, ring in enumerate(alloc.takeover)),
        *(inject_purchased_cluster(rng, pop, cfg, ring, i) for i, ring in enumerate(alloc.purchased)),
        *(inject_ledger_leak(rng, pop, cfg, ring, i) for i, ring in enumerate(alloc.ledger_leak)),
        *(inject_round_tripping(rng, pop, cfg, ring, i) for i, ring in enumerate(alloc.round_trip)),
        *(inject_fan(rng, pop, cfg, ring, i) for i, ring in enumerate(alloc.fan)),
        *(inject_dormant(rng, pop, cfg, ring, i) for i, ring in enumerate(alloc.dormant)),
    )


# --- callcentre_campaign: only in the campaign world, on its own rng stream -------------------------------
# One call centre, one district, ninety minutes: thirty victims are talked into paying three to five fresh payees
# opened by one onboarding agent on one SIM-activation day; most attempts are held, the allowed money is cashed out at
# one till within two hours. Spec 08 section 3; "thirty attempts, nineteen held" is the video's scenario.
CALLCENTRE_VICTIMS = 30
CALLCENTRE_SPAN_MIN = 90
CALLCENTRE_HELD = 19  # 63% held
CALLCENTRE_PAYEES = (3, 5)  # inclusive
CALLCENTRE_CASHOUT_MIN = (30, 120)  # minutes from the transfer to its cash-out, inclusive
CALLCENTRE_SIM_LEAD_DAYS = (5, 12)  # the payees' SIMs activate this many days before the campaign, inclusive
CALLCENTRE_MIN_DISTRICT_POOL = 60  # a district needs this many unallocated customers to host a campaign
CALLCENTRE_AMOUNT_BDT = (3000, 9000)  # inclusive, rounded to tens
CALLCENTRE_START_HOUR = (10, 14)  # the first call lands in this hour range, inclusive
CALLCENTRE_ID_BASE = 100  # payee i of campaign n is customer number cfg.customers + 100 * (n + 1) + i
CALLCENTRE_PAYEE_NAMES: tuple[tuple[str, str], ...] = (
    ("সাইফুল ইসলাম", "M"), ("জাহিদ হাসান", "M"), ("নাসরিন আক্তার", "F"), ("রুবেল মিয়া", "M"), ("শাহানা পারভীন", "F"),
)


def allocated_accounts(alloc: Allocation) -> frozenset[str]:
    """Every account the six demo typologies hold, so a campaign never picks one as a victim."""
    return frozenset(a for group in (alloc.takeover, alloc.purchased, alloc.ledger_leak, alloc.round_trip, alloc.fan, alloc.dormant)
                     for ring in group for a in ring)


def allocate_callcentre(rng: np.random.Generator, pop: Population, taken: frozenset[str], campaigns: int) -> tuple[tuple[str, tuple[str, ...]], ...]:
    """(district, thirty victims) per campaign: a district with enough unallocated customers, victims without replacement."""
    district_of = {a["acct_id"]: a["district"] for a in pop.accounts}
    used = frozenset(taken)
    plans = []
    for _ in range(campaigns):
        by_district: dict[str, tuple[str, ...]] = {}
        for acct in _pool(pop):
            if acct not in used:
                by_district = {**by_district, district_of[acct]: by_district.get(district_of[acct], ()) + (acct,)}
        candidates = tuple(sorted(d for d, accts in by_district.items() if len(accts) >= CALLCENTRE_MIN_DISTRICT_POOL))
        if not candidates:
            raise ValueError("no district can host a call-centre campaign; raise customers in WorldConfig")
        district = candidates[int(rng.integers(0, len(candidates)))]
        pool = by_district[district]
        victims = tuple(pool[int(i)] for i in rng.choice(len(pool), CALLCENTRE_VICTIMS, replace=False))
        used = used | frozenset(victims)
        plans.append((district, victims))
    return tuple(plans)


def _district_agents(pop: Population, district: str) -> tuple[dict, ...]:
    """The district's agents other than the colluding one (every honest agent when the district has none)."""
    honest = tuple(sorted((a for a in pop.agents if a["agent_id"] != s.COLLUDING_AGENT_ID), key=lambda a: a["agent_id"]))
    return tuple(a for a in honest if a["district"] == district) or honest


def _callcentre_payees(rng: np.random.Generator, pop: Population, cfg: s.WorldConfig, district: str, campaign_no: int, day: int) -> Injection:
    """Three to five new customers with accounts, SIMs activated on one day, devices; payees 0 and 1 share the
    controller's phone. Every row has the shape of its population table; ids come from the population's helpers."""
    ring_id = f"ring_callcentre_{campaign_no}"
    agents = _district_agents(pop, district)
    agent = agents[int(rng.integers(0, len(agents)))]["agent_id"]
    k = int(rng.integers(CALLCENTRE_PAYEES[0], CALLCENTRE_PAYEES[1] + 1))
    activation_day = day - int(rng.integers(CALLCENTRE_SIM_LEAD_DAYS[0], CALLCENTRE_SIM_LEAD_DAYS[1] + 1))
    customers, accounts, sims, events, devices, links = [], [], [], [], [], []
    for i in range(k):
        cust = customer_id(cfg.customers + CALLCENTRE_ID_BASE * (campaign_no + 1) + i)
        acct = account_id(cust)
        opened = _at(pop, activation_day, 9, int(rng.integers(0, 60)))
        name, gender = CALLCENTRE_PAYEE_NAMES[(campaign_no + i) % len(CALLCENTRE_PAYEE_NAMES)]
        customers.append({"cust_id": cust, "name": name, "gender": gender, "age": int(rng.integers(19, 40)), "district": district, "segment": "trader",
                          "nid_hash": stable_hash("nid", "campaign", campaign_no, i, cfg.seed), "phone_hash": stable_hash("ph", "campaign", campaign_no, i, cfg.seed),
                          "onboarding_agent_id": agent, "created_at": opened, "persona": None})
        accounts.append({"acct_id": acct, "owner_id": cust, "kind": "customer", "district": district, "opened_at": opened, "onboarding_agent_id": agent, "status": "active"})
        sim = sim_id(acct, cfg.seed)
        sims.append({"sim_id": sim, "acct_id": acct, "imsi_hash": stable_hash("imsi", "campaign", campaign_no, i, cfg.seed), "activated_at": opened, "active": True})
        events.append({"event": "activate", "acct_id": acct, "sim_id": sim, "ts": opened, "new_sim_id": None})
        device = f"dev_controller_{ring_id}" if i < 2 else device_id(acct, cfg.seed)
        if i != 1:  # payee 1 reuses payee 0's phone, which already has its devices row
            devices.append({"device_id": device, "model": _pick(rng, PHONE_MODELS, PHONE_WEIGHTS), "os": f"Android {int(rng.integers(11, 15))}", "first_seen": opened})
        links.append({"acct_id": acct, "device_id": device, "first_seen": opened, "is_primary": True})
    return Injection(transactions=(), labels=(), sim_events=tuple(events), device_links=tuple(links), customers=tuple(customers),
                     accounts=tuple(accounts), sims=tuple(sims), devices=tuple(devices))


def inject_callcentre(rng: np.random.Generator, pop: Population, cfg: s.WorldConfig, district: str, victims: tuple[str, ...], campaign_no: int, day: int) -> Injection:
    ring_id = f"ring_callcentre_{campaign_no}"
    opened = _callcentre_payees(rng, pop, cfg, district, campaign_no, day)
    payees = tuple(a["acct_id"] for a in opened.accounts)
    victim_device = {l["acct_id"]: l["device_id"] for l in pop.device_links if l["is_primary"]}
    t0 = _at(pop, day, int(rng.integers(CALLCENTRE_START_HOUR[0], CALLCENTRE_START_HOUR[1] + 1)), int(rng.integers(0, 60)))
    offsets = np.sort(rng.uniform(0, CALLCENTRE_SPAN_MIN, CALLCENTRE_VICTIMS))
    perm = rng.permutation(CALLCENTRE_VICTIMS)
    amounts = tuple(float(10 * round(int(rng.integers(CALLCENTRE_AMOUNT_BDT[0], CALLCENTRE_AMOUNT_BDT[1] + 1)) / 10)) for _ in victims)
    held = frozenset(int(i) for i in rng.choice(CALLCENTRE_VICTIMS, CALLCENTRE_HELD, replace=False))
    agents = _district_agents(pop, district)
    till = agents[int(rng.integers(0, len(agents)))]
    txns, holds = [], []
    for i, victim in enumerate(victims):
        ts, payee = s.add_minutes(t0, float(offsets[i])), payees[int(perm[i]) % len(payees)]
        if i in held:
            holds.append(attempt_row(ts, victim, payee, amounts[i], "send_money", "app", "hold", None, ring_id))
            continue
        txns.append(_txn(ts, "send_money", amounts[i], victim, payee, "app", device_id=victim_device.get(victim), ring_id=ring_id))
        lag = int(rng.integers(CALLCENTRE_CASHOUT_MIN[0], CALLCENTRE_CASHOUT_MIN[1] + 1))
        txns.append(_txn(s.add_minutes(ts, lag), "cash_out", amounts[i], payee, till["acct_id"], "agent", agent_id=till["agent_id"], ring_id=ring_id))
    labels = (tuple(_label(v, ring_id, "victim", s.CAMPAIGN_TYPOLOGY, t0) for v in victims)
              + tuple(_label(p, ring_id, "mule_L1", s.CAMPAIGN_TYPOLOGY, t0) for p in payees))
    return Injection(transactions=tuple(txns), labels=labels, sim_events=opened.sim_events, device_links=opened.device_links, customers=opened.customers,
                     accounts=opened.accounts, sims=opened.sims, devices=opened.devices, held_attempts=tuple(holds))


def inject_campaigns(pop: Population, cfg: s.WorldConfig, taken: frozenset[str], campaign: s.CampaignConfig) -> tuple[Injection, ...]:
    """Every campaign on its own stream, default_rng([seed, CAMPAIGN_STREAM]): the main stream never sees a draw."""
    rng = np.random.default_rng([cfg.seed, s.CAMPAIGN_STREAM])
    plans = allocate_callcentre(rng, pop, taken, campaign.campaigns)
    return tuple(inject_callcentre(rng, pop, cfg, district, victims, n, day)
                 for n, ((district, victims), day) in enumerate(zip(plans, campaign.days, strict=True)))
