"""Legitimate activity: salaries, Rina's monthly send, cash in/out, payments, recharges, P2P,
plus hard benign look-alikes (wedding cash-outs, hospital fan-in, new phone, travel)."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta

import numpy as np

from bhorosha_synth import schema as s
from bhorosha_synth.population import TELCO_ACCT, Population

Rows = tuple[dict, ...]

SALARY_SEGMENTS = ("garment_worker", "service_holder")
RECHARGE_AMOUNTS = (20.0, 30.0, 50.0, 100.0, 200.0, 500.0)
HOUR_WEIGHTS = np.array([0.2, 0.1, 0.05, 0.05, 0.05, 0.2, 0.6, 1.2, 2.0, 2.6, 2.8, 2.8, 2.4, 2.2, 2.4, 2.6, 2.8, 3.0, 3.2, 3.0, 2.6, 2.0, 1.2, 0.6])
TYPE_WEIGHTS = {"cash_in": 0.18, "cash_out": 0.27, "send_money": 0.25, "payment": 0.18, "recharge": 0.12}
PAYDAY_CASHOUT_DAYS = 2  # a payday cash-out falls on payday or the day after
WEDDING_DAY = 20
HOSPITAL_DAY = 9
# Benign-burst truth for the campaign world (bursts.jsonl). A row or attempt belongs to a burst when start <= ts < end,
# its type is in `types`, and acct_ids is empty or holds its from or to account. The types are what each generator
# below writes: a payday is salaries, cash-outs and the payments of that day (Rina's monthly send is a payday send);
# the wedding is cash-outs only; the hospital is the relatives' transfers and the patient's cash-out.
PAYDAY_TYPES = ("salary", "cash_out", "send_money")
WEDDING_TYPES = ("cash_out",)
HOSPITAL_TYPES = ("send_money", "cash_out")


@dataclass(frozen=True)
class BackgroundPlan:
    dormant_accts: frozenset[str]
    forced_merchant_payments: tuple[tuple[str, str, int], ...]  # (acct_id, merchant_acct, day_offset)


def _ts(rng: np.random.Generator, start: datetime, day: int, hour: int | None = None, minute: int | None = None) -> str:
    h = int(rng.choice(24, p=HOUR_WEIGHTS / HOUR_WEIGHTS.sum())) if hour is None else hour
    m = int(rng.integers(0, 60)) if minute is None else minute
    return s.format_ts(start + timedelta(days=day, hours=h, minutes=m, seconds=int(rng.integers(0, 60))))


def _amount(rng: np.random.Generator, kind: str) -> float:
    if kind == "recharge":
        return float(rng.choice(RECHARGE_AMOUNTS))
    lognormal = {"cash_in": (7.6, 0.6), "cash_out": (7.9, 0.7), "send_money": (7.4, 0.8), "payment": (6.2, 0.9)}[kind]
    value = float(np.exp(rng.normal(*lognormal)))
    return float(min(max(round(value / 10) * 10, 50.0), 25000.0))


def _txn(ts: str, kind: str, amount: float, from_acct: str, to_acct: str, channel: str, agent_id: str | None = None, device_id: str | None = None, ring_id: str | None = None) -> dict:
    return {"ts": ts, "type": kind, "amount_bdt": round(amount, 2), "from_acct": from_acct, "to_acct": to_acct, "channel": channel, "status": "ok", "agent_id": agent_id, "device_id": device_id, "ring_id": ring_id}


def _index(pop: Population) -> tuple[dict[str, dict], dict[str, tuple[str, ...]], dict[str, str], tuple[str, ...], dict[str, str]]:
    cust_by_id = {c["cust_id"]: c for c in pop.customers}
    acct_by_owner = {a["owner_id"]: a["acct_id"] for a in pop.accounts if a["kind"] == "customer"}
    tills_by_district: dict[str, tuple[str, ...]] = {}
    for a in pop.agents:
        tills_by_district = {**tills_by_district, a["district"]: tills_by_district.get(a["district"], ()) + (a["agent_id"],)}
    merchant_accts = tuple(m["acct_id"] for m in pop.merchants)
    device_by_acct = {l["acct_id"]: l["device_id"] for l in pop.device_links if l["is_primary"]}
    return cust_by_id, tills_by_district, acct_by_owner, merchant_accts, device_by_acct


def _contacts(rng: np.random.Generator, pop: Population, acct_by_owner: dict[str, str]) -> dict[str, tuple[str, ...]]:
    """Two to three regular P2P counterparties per customer, mostly in the same district."""
    by_district: dict[str, list[str]] = {}
    for c in pop.customers:
        by_district.setdefault(c["district"], []).append(acct_by_owner[c["cust_id"]])
    all_accts = [acct_by_owner[c["cust_id"]] for c in pop.customers]
    contacts = {}
    for c in pop.customers:
        pool = by_district[c["district"]] if rng.random() < 0.7 else all_accts
        picks = tuple(pool[int(i)] for i in rng.choice(len(pool), size=min(3, len(pool)), replace=False))
        contacts[acct_by_owner[c["cust_id"]]] = tuple(p for p in picks if p != acct_by_owner[c["cust_id"]])
    # Rina's transfers to Rafiq are scripted (monthly Tk 5,000); her random P2P goes elsewhere.
    contacts[s.RINA_ACCT] = tuple(p for p in contacts.get(s.RINA_ACCT, ()) if p != s.RAFIQ_ACCT)
    return contacts


def _customer_activity(rng: np.random.Generator, pop: Population, cfg: s.WorldConfig, plan: BackgroundPlan) -> list[dict]:
    cust_by_id, tills_by_district, acct_by_owner, merchant_accts, device_by_acct = _index(pop)
    contacts = _contacts(rng, pop, acct_by_owner)
    all_tills = tuple(a["agent_id"] for a in pop.agents)
    kinds, weights = tuple(TYPE_WEIGHTS), np.array(tuple(TYPE_WEIGHTS.values()))
    txns: list[dict] = []
    for c in pop.customers:
        acct = acct_by_owner[c["cust_id"]]
        if acct in plan.dormant_accts:
            continue
        device = device_by_acct.get(acct)
        local_agents = tills_by_district.get(c["district"], all_tills)
        if c["segment"] in SALARY_SEGMENTS:
            salary = s.RINA_SALARY_BDT if acct == s.RINA_ACCT else float(rng.integers(12500, 15001))
            for payday in s.PAYDAY_OFFSETS:
                txns.append(_txn(_ts(rng, pop.window_start, payday, 10, int(rng.integers(0, 50))), "salary", salary, s.PAYROLL_ACCT, acct, "app"))
                # payday cash-out at a local agent within two days: the benign spike the scorer must learn to ignore
                agent = local_agents[int(rng.integers(0, len(local_agents)))]
                txns.append(_txn(_ts(rng, pop.window_start, payday + int(rng.integers(0, 2))), "cash_out", float(rng.integers(3000, 9000)), acct, f"acct_till_{agent}", "agent", agent_id=agent))
        n = int(rng.poisson(cfg.daily_txn_rate * cfg.days))
        for _ in range(n):
            kind = kinds[int(rng.choice(len(kinds), p=weights / weights.sum()))]
            day = int(rng.integers(0, cfg.days))
            agent = local_agents[int(rng.integers(0, len(local_agents)))]
            if kind == "cash_in":
                txns.append(_txn(_ts(rng, pop.window_start, day), kind, _amount(rng, kind), f"acct_till_{agent}", acct, "agent", agent_id=agent))
            elif kind == "cash_out":
                txns.append(_txn(_ts(rng, pop.window_start, day), kind, _amount(rng, kind), acct, f"acct_till_{agent}", "agent", agent_id=agent))
            elif kind == "send_money" and contacts.get(acct):
                to = contacts[acct][int(rng.integers(0, len(contacts[acct])))]
                txns.append(_txn(_ts(rng, pop.window_start, day), kind, _amount(rng, kind), acct, to, "app" if rng.random() < 0.8 else "ussd", device_id=device))
            elif kind == "payment":
                txns.append(_txn(_ts(rng, pop.window_start, day), kind, _amount(rng, kind), acct, merchant_accts[int(rng.integers(0, len(merchant_accts)))], "app", device_id=device))
            elif kind == "recharge":
                txns.append(_txn(_ts(rng, pop.window_start, day), kind, _amount(rng, kind), acct, TELCO_ACCT, "app", device_id=device))
    return txns


def _personas(rng: np.random.Generator, pop: Population, cfg: s.WorldConfig) -> list[dict]:
    start = pop.window_start
    rina_device = next(l["device_id"] for l in pop.device_links if l["acct_id"] == s.RINA_ACCT)
    txns = [
        *(_txn(_ts(rng, start, payday, 12, 30), "send_money", s.RINA_MONTHLY_SEND_BDT, s.RINA_ACCT, s.RAFIQ_ACCT, "app", device_id=rina_device) for payday in s.PAYDAY_OFFSETS),
        _txn(_ts(rng, start, 2, 11, 5), "payment", 320.0, s.RINA_ACCT, s.LEGIT_MERCHANT_ACCT, "app", device_id=rina_device),
        _txn(_ts(rng, start, 15, 18, 40), "recharge", 100.0, s.RINA_ACCT, TELCO_ACCT, "app", device_id=rina_device),
    ]
    for day in (3, 10, 17, 24):  # Rahima: weekly agent cash-outs in Bhola
        txns.append(_txn(_ts(rng, start, day, 10, int(rng.integers(0, 59))), "cash_out", 1500.0, s.RAHIMA_ACCT, "acct_till_AG-0020", "agent", agent_id="AG-0020"))
        txns.append(_txn(_ts(rng, start, day - 1, 16, int(rng.integers(0, 59))), "send_money", 1800.0, s.RAFIQ_ACCT, s.RAHIMA_ACCT, "app"))
    return txns


def _at(start: datetime, day: int, hour: int = 0) -> str:
    return s.format_ts(start + timedelta(days=day, hours=hour))


def _bursts(start: datetime, groom: str, patient: str) -> Rows:
    """The four benign bursts as truth rows; no rng draws, so the world is unchanged by asking for them."""
    paydays = tuple({"burst_id": f"payday_{n}", "kind": "payday", "start": _at(start, day), "end": _at(start, day + PAYDAY_CASHOUT_DAYS),
                     "acct_ids": [], "types": list(PAYDAY_TYPES)} for n, day in enumerate(s.PAYDAY_OFFSETS, 1))
    return paydays + (
        {"burst_id": "wedding", "kind": "wedding", "start": _at(start, WEDDING_DAY), "end": _at(start, WEDDING_DAY + 1),
         "acct_ids": [groom], "types": list(WEDDING_TYPES)},
        {"burst_id": "hospital", "kind": "hospital", "start": _at(start, HOSPITAL_DAY, 21), "end": _at(start, HOSPITAL_DAY + 1, 9),
         "acct_ids": [patient], "types": list(HOSPITAL_TYPES)},
    )


def _hard_negatives(rng: np.random.Generator, pop: Population) -> tuple[list[dict], list[dict], list[dict], Rows]:
    """Benign look-alikes. Returns (transactions, sim_events, device_links, burst truth rows)."""
    start = pop.window_start
    customer_accts = tuple(a["acct_id"] for a in pop.accounts if a["kind"] == "customer" and a["owner_id"].startswith("cust_0"))
    pick = lambda: customer_accts[int(rng.integers(0, len(customer_accts)))]  # noqa: E731
    txns: list[dict] = []
    # Wedding: three large cash-outs in a day at two agents
    groom = pick()
    for hour, agent in ((10, "AG-0005"), (13, "AG-0005"), (16, "AG-0006")):
        txns.append(_txn(_ts(rng, start, WEDDING_DAY, hour), "cash_out", 20000.0, groom, f"acct_till_{agent}", "agent", agent_id=agent))
    # Hospital: six relatives send to one account within an hour, then one cash-out
    patient = pick()
    for i in range(6):
        txns.append(_txn(_ts(rng, start, HOSPITAL_DAY, 21, 5 + i * 8), "send_money", float(rng.integers(2000, 5001)), pick(), patient, "app"))
    txns.append(_txn(_ts(rng, start, HOSPITAL_DAY + 1, 8, 15), "cash_out", 18000.0, patient, "acct_till_AG-0002", "agent", agent_id="AG-0002"))
    # New phone: benign SIM replacement and new device, behaviour unchanged
    swap_ts = _ts(rng, start, 12, 11, 20)
    new_sim = "sim_benign_replacement"
    sim_events = [{"event": "swap", "acct_id": s.BENIGN_SIM_SWAP_ACCT, "sim_id": next(x["sim_id"] for x in pop.sims if x["acct_id"] == s.BENIGN_SIM_SWAP_ACCT), "ts": swap_ts, "new_sim_id": new_sim}]
    device_links = [{"acct_id": s.BENIGN_SIM_SWAP_ACCT, "device_id": "dev_benign_newphone", "first_seen": s.add_minutes(swap_ts, 25), "is_primary": True}]
    txns.append(_txn(s.add_minutes(swap_ts, 180), "recharge", 100.0, s.BENIGN_SIM_SWAP_ACCT, TELCO_ACCT, "app", device_id="dev_benign_newphone"))
    txns.append(_txn(s.add_minutes(swap_ts, 1500), "send_money", 1200.0, s.BENIGN_SIM_SWAP_ACCT, pick(), "app", device_id="dev_benign_newphone"))
    # Travel: one customer transacts in another district for three days
    traveller = pick()
    for day in (16, 17, 18):
        txns.append(_txn(_ts(rng, start, day), "cash_out", 2500.0, traveller, "acct_till_AG-0030", "agent", agent_id="AG-0030"))
    return txns, sim_events, device_links, _bursts(start, groom, patient)


def build_background(rng: np.random.Generator, pop: Population, cfg: s.WorldConfig, plan: BackgroundPlan) -> tuple[Rows, Rows, Rows, Rows]:
    """Return (transactions, extra sim_events, extra device_links, benign-burst truth rows) for all legitimate activity."""
    txns = _customer_activity(rng, pop, cfg, plan) + _personas(rng, pop, cfg)
    for acct, merchant_acct, day in plan.forced_merchant_payments:
        txns.append(_txn(_ts(rng, pop.window_start, day), "payment", float(rng.integers(300, 2500)), acct, merchant_acct, "app"))
    negatives, sim_events, device_links, bursts = _hard_negatives(rng, pop)
    return tuple(txns + negatives), tuple(sim_events), tuple(device_links), bursts
