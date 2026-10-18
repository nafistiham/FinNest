"""Two pattern tools that reach ring members money hops and shared identities cannot.

Both read only events at or before `as_of`. Thresholds were chosen on the seed-7 dev world
(`eval/dev_world.py`), never on the scored seed-42 world.

dormant_cohort: bought accounts are often switched on together. An account "wakes" when it has been
quiet - never sent money since opening at least QUIET_DAYS ago, or sent nothing for USED_QUIET_DAYS
after earlier use (people who use their account often pause for a few weeks) - and then receives
MIN_INBOUND or more transfers and passes at least PASS_THROUGH of the total straight out. The cohort is every other customer that woke within
COHORT_HOURS of the seed.

common_point_of_compromise: when one leaked ledger feeds a ring, the victims share a place they all
paid before the theft. Find a counterparty most of the seed's recent senders had paid (and far more
often than chance), then other payers of that point who recently sent money to an account that
cashed it straight out. Two or more such payers into one account make it a linked account.
"""

from __future__ import annotations

import math
from collections import defaultdict
from datetime import timedelta

from bhorosha_synth import schema as s

from case_zero.world import World, real_id

QUIET_DAYS = 14
USED_QUIET_DAYS = 30
MIN_INBOUND = 2
PASS_THROUGH = 0.8
BURST_HOURS = 6
COHORT_HOURS = 12
SENDER_DAYS = 7
HISTORY_DAYS = 30
CASHOUT_HOURS = 4
MIN_LIFT = 3.0
MIN_LINKED_PAYERS = 2
MAX_TXN_IDS = 6


def _txns(world: World, acct: str, as_of: str) -> list[dict]:
    return [t for t in world.bundle.txns_by_acct.get(acct, ()) if t["ts"] <= as_of]


def _shift(ts: str, **delta) -> str:
    return s.format_ts(s.parse_ts(ts) + timedelta(**delta))


def wake(world: World, acct: str, as_of: str) -> dict | None:
    """The account's most recent wake before `as_of`, or None."""
    txns = _txns(world, acct, as_of)
    opened = world.bundle.accounts.get(acct, {}).get("opened_at") or "0000-01-01T00:00:00"
    inbound = [t for t in txns if t["to_acct"] == acct and t["type"] == "send_money"]
    for i in range(len(inbound) - 1, -1, -1):
        first = inbound[i]["ts"]
        burst = [t for t in inbound[i:] if t["ts"] <= _shift(first, hours=BURST_HOURS)]
        if len(burst) < MIN_INBOUND:
            continue
        if i > 0 and inbound[i - 1]["ts"] >= _shift(first, hours=-BURST_HOURS):
            continue  # not the start of the burst
        earlier_out = [t["ts"] for t in txns if t["from_acct"] == acct and t["ts"] < first]
        quiet_since = max(earlier_out, default=opened)
        quiet_days = (s.parse_ts(first) - s.parse_ts(max(quiet_since, opened))).days
        out = [t for t in txns if t["from_acct"] == acct and first <= t["ts"] <= _shift(burst[-1]["ts"], hours=BURST_HOURS)]
        in_bdt, out_bdt = sum(t["amount_bdt"] for t in burst), sum(t["amount_bdt"] for t in out)
        if quiet_days >= (USED_QUIET_DAYS if earlier_out else QUIET_DAYS) and out and out_bdt >= PASS_THROUGH * in_bdt:
            return {"acct_id": acct, "quiet_days": quiet_days, "used_before": bool(earlier_out), "inbound_count": len(burst), "inbound_bdt": in_bdt, "outbound_bdt": out_bdt,
                    "first_in": first, "last_out": out[-1]["ts"], "txn_ids": [t["txn_id"] for t in (burst + out)][:MAX_TXN_IDS]}
    return None


def dormant_cohort(world: World, as_of: str, acct_id: str) -> dict:
    seed = real_id(acct_id)
    base = {"acct_id": seed, "as_of": as_of, "quiet_days_unused": QUIET_DAYS, "quiet_days_after_use": USED_QUIET_DAYS, "window_hours": COHORT_HOURS}
    seed_wake = wake(world, seed, as_of)
    if seed_wake is None:
        return {**base, "seed_wake": None, "cohort": [], "checked": 0}
    lo, hi = _shift(seed_wake["first_in"], hours=-COHORT_HOURS), _shift(seed_wake["first_in"], hours=COHORT_HOURS)
    customers = [a for a, row in world.bundle.accounts.items() if row.get("kind") == "customer" and a != seed]
    cohort = []
    for acct in customers:
        if not any(lo <= t["ts"] <= hi for t in world.bundle.txns_by_acct.get(acct, ())):
            continue
        w = wake(world, acct, as_of)
        if w and lo <= w["first_in"] <= hi:
            cohort.append(w)
    return {**base, "seed_wake": seed_wake, "cohort": sorted(cohort, key=lambda r: r["first_in"]), "checked": len(customers)}


def common_point_of_compromise(world: World, as_of: str, acct_id: str) -> dict:
    seed = real_id(acct_id)
    since, history = _shift(as_of, days=-SENDER_DAYS), _shift(as_of, days=-HISTORY_DAYS)
    senders = sorted({t["from_acct"] for t in _txns(world, seed, as_of) if t["to_acct"] == seed and t["type"] == "send_money" and t["ts"] >= since})
    base = {"acct_id": seed, "as_of": as_of, "sender_days": SENDER_DAYS, "history_days": HISTORY_DAYS, "senders": senders}
    if len(senders) < 2:
        return {**base, "common_points": [], "linked_accounts": []}
    paid: dict[str, set[str]] = defaultdict(set)
    for v in senders:
        for t in _txns(world, v, as_of):
            if t["from_acct"] == v and t["to_acct"] != seed and t["ts"] >= history and t["type"] in ("payment", "send_money"):
                paid[t["to_acct"]].add(v)
    active = sum(1 for a, row in world.bundle.accounts.items() if row.get("kind") == "customer" and any(history <= t["ts"] <= as_of for t in world.bundle.txns_by_acct.get(a, ())))
    need = max(2, math.ceil(len(senders) / 2))
    points = []
    for point, who in paid.items():
        if len(who) < need:
            continue
        payers = {t["from_acct"] for t in _txns(world, point, as_of) if t["to_acct"] == point and t["ts"] >= history}
        lift = len(who) / max(len(senders) * len(payers) / max(active, 1), 1e-9)
        if lift >= MIN_LIFT:
            points.append({"acct_id": point, "kind": world.bundle.accounts.get(point, {}).get("kind"), "senders_paid": len(who), "of_senders": len(senders),
                           "payers_in_window": len(payers), "lift": round(lift, 1), "_payers": payers})
    hits: dict[str, dict[str, dict]] = defaultdict(dict)
    for point in points:
        for payer in sorted(point["_payers"] - {seed}):
            paid_at = min(t["ts"] for t in _txns(world, payer, as_of) if t["to_acct"] == point["acct_id"] and t["ts"] >= history)
            for t in _txns(world, payer, as_of):
                if t["from_acct"] != payer or t["type"] != "send_money" or t["ts"] < since or t["ts"] <= paid_at or t["to_acct"] in (seed, point["acct_id"]):
                    continue
                rx = t["to_acct"]
                if world.bundle.accounts.get(rx, {}).get("kind") != "customer":
                    continue
                out = sum(x["amount_bdt"] for x in _txns(world, rx, as_of) if x["from_acct"] == rx and t["ts"] <= x["ts"] <= _shift(t["ts"], hours=CASHOUT_HOURS))
                if out >= PASS_THROUGH * t["amount_bdt"]:
                    hits[rx].setdefault(payer, {"txn_id": t["txn_id"], "from_acct": payer, "amount_bdt": t["amount_bdt"], "ts": t["ts"], "via_point": point["acct_id"]})
    linked = [{"acct_id": rx, "compromised_payers": sorted(by), "transfers": sorted(by.values(), key=lambda x: x["ts"])[:MAX_TXN_IDS]}
              for rx, by in hits.items() if len(by) >= MIN_LINKED_PAYERS]
    return {**base, "common_points": [{k: v for k, v in p.items() if not k.startswith("_")} for p in sorted(points, key=lambda p: -p["lift"])],
            "linked_accounts": sorted(linked, key=lambda r: (-len(r["compromised_payers"]), r["acct_id"]))}
