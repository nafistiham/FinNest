"""Graph tool functions for the Case Zero investigator agent.

Every function takes the bundle and plain arguments and returns a JSON-serialisable dict.
`as_of` is an ISO timestamp (schema.TS_FORMAT); nothing after it is visible, so the agent
cannot peek into the future and the scorer's temporal masking has the same semantics.
"""

from __future__ import annotations

from collections import deque
from datetime import timedelta

from bhorosha_graph.bundle import GraphBundle
from bhorosha_graph.features import CONFIRMATION_LAG_DAYS, FRAUD_ROLES, confirmed_before, confirmed_fraud
from bhorosha_synth import schema as s

DEFAULT_MAX_HOPS = 5


def _visible(txn: dict, as_of: str | None) -> bool:
    return as_of is None or txn["ts"] <= as_of


def _edges_from(bundle: GraphBundle, acct_id: str, as_of: str | None) -> tuple[dict, ...]:
    return tuple(t for t in bundle.txns_by_acct.get(acct_id, ()) if t["from_acct"] == acct_id and _visible(t, as_of))


def _edges_to(bundle: GraphBundle, acct_id: str, as_of: str | None) -> tuple[dict, ...]:
    return tuple(t for t in bundle.txns_by_acct.get(acct_id, ()) if t["to_acct"] == acct_id and _visible(t, as_of))


def _account_summary(bundle: GraphBundle, acct_id: str) -> dict:
    a = bundle.accounts.get(acct_id, {})
    return {"acct_id": acct_id, "kind": a.get("kind"), "district": a.get("district"), "opened_at": a.get("opened_at"), "owner_segment": a.get("owner_segment")}


def neighbours(bundle: GraphBundle, acct_id: str, hops: int = 1, as_of: str | None = None, limit: int = 50) -> dict:
    """Money-flow counterparties within `hops` transfers, with per-counterparty totals.

    The walk follows money both ways, so each row names the transfer that first linked `via` to the
    counterparty (the earliest out of `via`, else the earliest into it): `txn_id`, and `from_acct` ->
    `to_acct` for the way the money went. `via` alone does not say which side sent it.
    """
    frontier, seen, rows = {acct_id}, {acct_id}, []
    for depth in range(1, hops + 1):
        next_frontier = set()
        for node in sorted(frontier):
            for t in _edges_from(bundle, node, as_of) + _edges_to(bundle, node, as_of):
                other = t["to_acct"] if t["from_acct"] == node else t["from_acct"]
                if other in seen:
                    continue
                seen.add(other)
                next_frontier.add(other)
                rows.append({**_account_summary(bundle, other), "hops": depth, "via": node, "first_ts": t["ts"], "txn_type": t["type"], "amount_bdt": t["amount_bdt"],
                             "txn_id": t["txn_id"], "from_acct": t["from_acct"], "to_acct": t["to_acct"]})
        frontier = next_frontier
    return {"acct_id": acct_id, "as_of": as_of, "neighbours": rows[:limit], "truncated": len(rows) > limit}


def path_between(bundle: GraphBundle, source: str, target: str, max_hops: int = DEFAULT_MAX_HOPS, as_of: str | None = None) -> dict:
    """Shortest time-ordered money path source -> target (each hop later than the previous)."""
    queue = deque([(source, "", ())])
    best: dict[str, int] = {source: 0}
    while queue:
        node, after_ts, trail = queue.popleft()
        if len(trail) >= max_hops:
            continue
        for t in _edges_from(bundle, node, as_of):
            if t["ts"] < after_ts:
                continue
            dest = t["to_acct"]
            if dest == target:
                path_txns = trail + (t,)
                return {"found": True, "hops": len(path_txns), "path": [source] + [x["to_acct"] for x in path_txns], "txn_ids": [x["txn_id"] for x in path_txns],
                        "steps": [{"txn_id": x["txn_id"], "ts": x["ts"], "type": x["type"], "amount_bdt": x["amount_bdt"], "from": x["from_acct"], "to": x["to_acct"]} for x in path_txns]}
            if best.get(dest, max_hops + 1) > len(trail) + 1:
                best = {**best, dest: len(trail) + 1}
                queue.append((dest, t["ts"], trail + (t,)))
    return {"found": False, "hops": 0, "path": [], "txn_ids": [], "steps": []}


def shared_entities(bundle: GraphBundle, acct_ids: list[str]) -> dict:
    """Devices, SIMs, onboarding agents, NIDs or phones shared by two or more of the accounts."""
    holders: dict[str, set[str]] = {}
    for acct in acct_ids:
        for entity in bundle.links.neighbors(acct) if acct in bundle.links else ():
            holders = {**holders, entity: holders.get(entity, set()) | {acct}}
    shared = [{"kind": entity.split(":", 1)[0], "entity": entity, "acct_ids": sorted(accts)} for entity, accts in holders.items() if len(accts) >= 2]
    return {"acct_ids": list(acct_ids), "shared": sorted(shared, key=lambda e: (-len(e["acct_ids"]), e["entity"]))}


def velocity_stats(bundle: GraphBundle, acct_id: str, window_hours: int = 24, as_of: str | None = None) -> dict:
    end = as_of or (bundle.txns_by_acct.get(acct_id, ({"ts": "9999"},))[-1]["ts"])
    start = s.format_ts(s.parse_ts(end) - timedelta(hours=window_hours)) if end != "9999" else ""
    inbound = [t for t in _edges_to(bundle, acct_id, end) if t["ts"] >= start]
    outbound = [t for t in _edges_from(bundle, acct_id, end) if t["ts"] >= start]
    lifetime = bundle.txns_by_acct.get(acct_id, ())
    first_ts = lifetime[0]["ts"] if lifetime else None
    visible = [t for t in lifetime if _visible(t, end)]
    return {
        "acct_id": acct_id, "window_hours": window_hours, "as_of": end,
        "in_count": len(inbound), "in_total_bdt": round(sum(t["amount_bdt"] for t in inbound), 2),
        "out_count": len(outbound), "out_total_bdt": round(sum(t["amount_bdt"] for t in outbound), 2),
        "distinct_senders": len({t["from_acct"] for t in inbound}), "distinct_receivers": len({t["to_acct"] for t in outbound}),
        "lifetime_txn_count": len(visible), "first_txn_ts": first_ts,
        "pass_through_ratio": round(sum(t["amount_bdt"] for t in outbound) / sum(t["amount_bdt"] for t in inbound), 3) if inbound else None,
    }


def agent_till_stats(bundle: GraphBundle, agent_id: str, as_of: str | None = None) -> dict:
    till = f"acct_till_{agent_id}"
    cash_in = [t for t in _edges_from(bundle, till, as_of) if t["type"] == "cash_in"]
    cash_out = [t for t in _edges_to(bundle, till, as_of) if t["type"] == "cash_out"]
    counterparties = {t["to_acct"] for t in cash_in} | {t["from_acct"] for t in cash_out}
    repeat = {}
    for t in cash_in + cash_out:
        other = t["to_acct"] if t["type"] == "cash_in" else t["from_acct"]
        repeat = {**repeat, other: repeat.get(other, 0) + 1}
    return {
        "agent_id": agent_id, "till_acct": till, "district": bundle.agents.get(agent_id, {}).get("district"), "as_of": as_of,
        "cash_in_count": len(cash_in), "cash_in_total_bdt": round(sum(t["amount_bdt"] for t in cash_in), 2),
        "cash_out_count": len(cash_out), "cash_out_total_bdt": round(sum(t["amount_bdt"] for t in cash_out), 2),
        "distinct_counterparties": len(counterparties),
        "top_repeat_counterparties": sorted(({"acct_id": k, "count": v} for k, v in repeat.items()), key=lambda r: (-r["count"], r["acct_id"]))[:5],
        "max_single_bdt": max((t["amount_bdt"] for t in cash_in + cash_out), default=0.0),
    }


def kyc_dupe_check(bundle: GraphBundle, acct_id: str) -> dict:
    def shared(kind: str) -> list[str]:
        out: set[str] = set()
        for entity in bundle.links.neighbors(acct_id) if acct_id in bundle.links else ():
            if entity.startswith(f"{kind}:"):
                out |= {n for n in bundle.links.neighbors(entity) if n != acct_id}
        return sorted(out)

    return {"acct_id": acct_id, "nid_shared_with": shared("nid"), "phone_shared_with": shared("phone"), "device_shared_with": shared("device"), "sim_shared_with": shared("sim")}


def known_fraud_proximity(bundle: GraphBundle, acct_id: str, as_of: str | None = None, max_hops: int = 2) -> dict:
    """Distance (in money-flow hops, either direction) to accounts analysts had confirmed as fraud by `as_of`.

    Confirmation lags the first bad event by CONFIRMATION_LAG_DAYS, the same rule the scorer's
    features use, so a ring that is still cashing out does not count as known. A hit carries no
    ring id or role: labels are ground truth for evaluation and must never reach a model.
    """
    confirmed = {a: l for a, l in confirmed_fraud(bundle, as_of).items() if a != acct_id}
    cutoff = None if as_of is None else confirmed_before(as_of)
    frontier, seen, hits = {acct_id}, {acct_id}, []
    for depth in range(1, max_hops + 1):
        next_frontier = set()
        for node in sorted(frontier):
            for t in _edges_from(bundle, node, as_of) + _edges_to(bundle, node, as_of):
                other = t["to_acct"] if t["from_acct"] == node else t["from_acct"]
                if other in seen:
                    continue
                seen.add(other)
                next_frontier.add(other)
                if other in confirmed:
                    hits.append({"acct_id": other, "hops": depth, "confirmed_before": cutoff})
        frontier = next_frontier
    return {
        "acct_id": acct_id,
        "as_of": as_of,
        "confirmation_lag_days": CONFIRMATION_LAG_DAYS,
        "min_hops": min((h["hops"] for h in hits), default=None),
        "hits": sorted(hits, key=lambda h: (h["hops"], h["acct_id"])),
    }
