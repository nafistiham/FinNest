"""Leakage-safe account features at a cutoff.

Every value is computed from events strictly before `cutoff`. Labels are used only for the
`hops_to_known_fraud` family, and only rings whose first bad event is older than
`confirmation_lag_days` count as "known" (an analyst would have confirmed them by then).
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import timedelta
from statistics import median

from bhorosha_graph.bundle import GraphBundle
from bhorosha_synth import schema as s

FRAUD_ROLES = frozenset({"mule_L1", "mule_L2", "cashout_agent", "purchased_mule", "controller"})
SCORED_KINDS = frozenset({"customer", "agent_till"})
CONFIRMATION_LAG_DAYS = 3
NO_FRAUD_HOPS = 3
NO_FORWARD_MINUTES = 9999.0
PASS_THROUGH_CAP = 5.0
NETWORK_FEATURES = frozenset({
    "shared_device_accts", "same_day_activation_peers", "onboarding_cluster_size", "hops_to_known_fraud", "known_fraud_within_2_hops", "sim_swap_7d", "new_device_7d",
    "hops_to_recent_sim_swap", "inbound_from_recent_swap_7d",
})
SWAP_RECENCY_HOURS = 24


def _minutes(a: str, b: str) -> float:
    return (s.parse_ts(b) - s.parse_ts(a)).total_seconds() / 60


def _days(a: str, b: str) -> float:
    return (s.parse_ts(b) - s.parse_ts(a)).total_seconds() / 86400


def _max_in_window(timestamps: list[str], minutes: float) -> int:
    best, start = 0, 0
    for end in range(len(timestamps)):
        while _minutes(timestamps[start], timestamps[end]) > minutes:
            start += 1
        best = max(best, end - start + 1)
    return best


def _window_block(acct: str, inbound: list[dict], outbound: list[dict], since: str, suffix: str) -> dict:
    """Velocity / pass-through / cash-out shape of one lookback window; keys carry `suffix` (7d or 30d)."""
    ins = [t for t in inbound if t["ts"] >= since]
    outs = [t for t in outbound if t["ts"] >= since]
    in_total, out_total = sum(t["amount_bdt"] for t in ins), sum(t["amount_bdt"] for t in outs)
    forwards = []
    for t in ins:
        later = [o for o in outs if o["ts"] >= t["ts"]]
        if later:
            forwards.append(_minutes(t["ts"], later[0]["ts"]))
    cash_outs = [t for t in outs if t["type"] == "cash_out"]
    salary = [t for t in ins if t["type"] == "salary"]
    non_salary_in = in_total - sum(t["amount_bdt"] for t in salary)
    by_agent: dict[str, float] = {}
    for t in cash_outs:
        by_agent = {**by_agent, t["agent_id"]: by_agent.get(t["agent_id"], 0.0) + t["amount_bdt"]}
    cash_in_tills = {(t["agent_id"], t["ts"]) for t in ins if t["type"] == "cash_in"}
    round_trips = sum(1 for t in cash_outs for agent, ts in cash_in_tills if agent == t["agent_id"] and 0 <= _minutes(ts, t["ts"]) <= 60)
    return {
        f"in_count_{suffix}": len(ins), f"out_count_{suffix}": len(outs), f"in_total_{suffix}": round(in_total, 2), f"out_total_{suffix}": round(out_total, 2),
        f"distinct_senders_{suffix}": len({t["from_acct"] for t in ins}), f"distinct_receivers_{suffix}": len({t["to_acct"] for t in outs}),
        f"pass_through_ratio_{suffix}": round(min(out_total / in_total, PASS_THROUGH_CAP), 3) if in_total else 0.0,
        f"non_salary_pass_through_{suffix}": round(min(out_total / non_salary_in, PASS_THROUGH_CAP), 3) if non_salary_in > 0 else 0.0,
        f"median_forward_minutes_{suffix}": round(median(forwards), 1) if forwards else NO_FORWARD_MINUTES,
        f"min_forward_minutes_{suffix}": round(min(forwards), 1) if forwards else NO_FORWARD_MINUTES,
        f"max_in_per_hour_{suffix}": _max_in_window([t["ts"] for t in ins], 60), f"max_out_per_3h_{suffix}": _max_in_window([t["ts"] for t in outs], 180),
        f"cash_out_share_{suffix}": round(sum(t["amount_bdt"] for t in cash_outs) / out_total, 3) if out_total else 0.0,
        f"cash_out_count_{suffix}": len(cash_outs), f"agent_concentration_{suffix}": round(max(by_agent.values()) / sum(by_agent.values()), 3) if by_agent else 0.0,
        f"round_trip_count_{suffix}": round_trips, f"max_txn_amount_{suffix}": max((t["amount_bdt"] for t in ins + outs), default=0.0),
        f"salary_in_count_{suffix}": len(salary), f"salary_share_of_in_{suffix}": round(sum(t["amount_bdt"] for t in salary) / in_total, 3) if in_total else 0.0,
        f"p2p_in_count_{suffix}": sum(1 for t in ins if t["type"] == "send_money"),
        f"merchant_payment_count_{suffix}": sum(1 for t in outs if t["type"] == "payment"),
    }


def _velocity(acct: str, txns: tuple[dict, ...], cutoff: str, week_ago: str, month_ago: str) -> dict:
    inbound = [t for t in txns if t["to_acct"] == acct]
    outbound = [t for t in txns if t["from_acct"] == acct]
    return {**_window_block(acct, inbound, outbound, week_ago, "7d"), **_window_block(acct, inbound, outbound, month_ago, "30d")}


def _dormancy(account: dict, txns: tuple[dict, ...], cutoff: str, week_ago: str) -> dict:
    stamps = [t["ts"] for t in txns]
    before_week = [ts for ts in stamps if ts < week_ago]
    in_week = [ts for ts in stamps if ts >= week_ago]
    gap = _days(before_week[-1], in_week[0]) if before_week and in_week else (_days(account["opened_at"], in_week[0]) if in_week and not before_week else 0.0)
    return {
        "account_age_days": round(_days(account["opened_at"], cutoff), 1),
        "days_since_first_txn": round(_days(stamps[0], cutoff), 1) if stamps else -1.0,
        "days_since_last_txn": round(_days(stamps[-1], cutoff), 1) if stamps else -1.0,
        "dormant_gap_days": round(gap, 1),
        "active_days_30d": len({ts[:10] for ts in stamps if _days(ts, cutoff) <= 30}),
    }


def _entity_index(bundle: GraphBundle, cutoff: str) -> tuple[dict[str, frozenset[str]], dict[str, str], dict[str, str]]:
    """device -> accounts linked before cutoff; acct -> sim activation date; acct -> onboarding agent.

    The device map is gathered in a local dict and frozen once: copying it per link was quadratic in the links, and
    this now runs on every payee screen.
    """
    accounts_by_device: dict[str, set[str]] = {}
    for link in bundle.device_links:
        if link["first_seen"] < cutoff:
            accounts_by_device.setdefault(link["device_id"], set()).add(link["acct_id"])
    holders = {device: frozenset(accounts) for device, accounts in accounts_by_device.items()}
    activation = {sim["acct_id"]: sim["activated_at"][:10] for sim in bundle.sims}
    onboarding = {acct_id: a.get("onboarding_agent_id") for acct_id, a in bundle.accounts.items()}
    return holders, activation, onboarding


def _entity(acct: str, bundle: GraphBundle, cutoff: str, week_ago: str, holders: dict[str, frozenset[str]], activation: dict[str, str], onboarding: dict[str, str]) -> dict:
    my_links = [l for l in bundle.device_links if l["acct_id"] == acct and l["first_seen"] < cutoff]
    peers: frozenset[str] = frozenset()
    for link in my_links:
        peers = peers | (holders.get(link["device_id"], frozenset()) - {acct})
    same_day = sum(1 for p in peers if activation.get(p) == activation.get(acct))
    cluster = sum(1 for p in peers if onboarding.get(p) == onboarding.get(acct))
    swaps = sum(1 for e in bundle.sim_events if e["acct_id"] == acct and e["event"] == "swap" and week_ago <= e["ts"] < cutoff)
    new_devices = sum(1 for l in my_links if l["first_seen"] >= week_ago and not l["is_primary"])
    return {"shared_device_accts": len(peers), "same_day_activation_peers": same_day, "onboarding_cluster_size": cluster, "sim_swap_7d": swaps, "new_device_7d": new_devices}


def confirmed_before(as_of: str, lag_days: int = CONFIRMATION_LAG_DAYS) -> str:
    """The instant before which a first bad event must fall for an analyst to have confirmed it by `as_of`."""
    return s.format_ts(s.parse_ts(as_of) - timedelta(days=lag_days))


def confirmed_fraud(bundle: GraphBundle, as_of: str | None, lag_days: int = CONFIRMATION_LAG_DAYS) -> dict[str, dict]:
    """Fraud accounts an analyst would have confirmed by `as_of`, keyed by account id.

    Fraud is not known the moment it starts: it is confirmed `lag_days` after its first bad event.
    The scorer's features and the investigator's graph tools both use this one definition, so a
    ring that is still cashing out is never already "confirmed" to either of them. `as_of=None`
    means no time reference and so no lag: every labelled fraud account.
    """
    limit = None if as_of is None else confirmed_before(as_of, lag_days)
    return {l["acct_id"]: l for l in bundle.labels if l["role"] in FRAUD_ROLES and (limit is None or l["first_bad_ts"] < limit)}


def _known_fraud(bundle: GraphBundle, cutoff: str, lag_days: int) -> frozenset[str]:
    return frozenset(confirmed_fraud(bundle, cutoff, lag_days))


def _proximity(acct: str, bundle: GraphBundle, cutoff: str, known: frozenset[str], swapped: dict[str, tuple[str, ...]], week_ago: str) -> dict:
    """Hops (either direction) to confirmed fraud, and upstream hops to an account with a recent SIM swap."""
    frontier, seen, hits, min_hops = {acct}, {acct}, 0, NO_FRAUD_HOPS
    for depth in (1, 2):
        next_frontier = set()
        for node in frontier:
            for t in bundle.txns_by_acct.get(node, ()):
                if t["ts"] >= cutoff:
                    continue
                other = t["to_acct"] if t["from_acct"] == node else t["from_acct"]
                if other in seen:
                    continue
                seen.add(other)
                next_frontier.add(other)
                if other in known:
                    hits += 1
                    min_hops = min(min_hops, depth)
        frontier = next_frontier
    # Money received from an account whose SIM was swapped in the previous 24 h (the takeover signature), up to two hops upstream
    def swapped_before(sender: str, ts: str) -> bool:
        return any(0 <= _minutes(swap_ts, ts) <= SWAP_RECENCY_HOURS * 60 for swap_ts in swapped.get(sender, ()))

    inbound = [t for t in bundle.txns_by_acct.get(acct, ()) if t["to_acct"] == acct and t["ts"] < cutoff]
    direct = sum(1 for t in inbound if t["ts"] >= week_ago and swapped_before(t["from_acct"], t["ts"]))
    swap_hops = 0 if any(week_ago <= swap_ts < cutoff for swap_ts in swapped.get(acct, ())) else NO_FRAUD_HOPS
    if direct and swap_hops > 1:
        swap_hops = 1
    elif swap_hops > 2:
        for t in inbound:
            upstream = [u for u in bundle.txns_by_acct.get(t["from_acct"], ()) if u["to_acct"] == t["from_acct"] and u["ts"] < t["ts"]]
            if any(swapped_before(u["from_acct"], u["ts"]) for u in upstream):
                swap_hops = 2
                break
    return {"hops_to_known_fraud": min_hops, "known_fraud_within_2_hops": hits, "hops_to_recent_sim_swap": swap_hops, "inbound_from_recent_swap_7d": direct}


@dataclass(frozen=True)
class FeatureContext:
    """What every account's row at one cutoff shares, derived once.

    Built from the entity tables only (device links, SIMs, accounts, labels, SIM events), never from the
    transactions, so it stays valid for a copy of the bundle that only adds transactions (the transfer being
    screened, scorer.with_transfer).
    """

    cutoff: str
    week_ago: str
    month_ago: str
    holders: dict[str, frozenset[str]]
    activation: dict[str, str]
    onboarding: dict[str, str]
    known: frozenset[str]
    swapped: dict[str, tuple[str, ...]]


def feature_context(bundle: GraphBundle, cutoff: str, confirmation_lag_days: int = CONFIRMATION_LAG_DAYS) -> FeatureContext:
    holders, activation, onboarding = _entity_index(bundle, cutoff)
    swapped: dict[str, tuple[str, ...]] = {}
    for e in bundle.sim_events:
        if e["event"] == "swap" and e["ts"] < cutoff:
            swapped = {**swapped, e["acct_id"]: swapped.get(e["acct_id"], ()) + (e["ts"],)}
    return FeatureContext(
        cutoff=cutoff,
        week_ago=s.format_ts(s.parse_ts(cutoff) - timedelta(days=7)),
        month_ago=s.format_ts(s.parse_ts(cutoff) - timedelta(days=30)),
        holders=holders, activation=activation, onboarding=onboarding,
        known=_known_fraud(bundle, cutoff, confirmation_lag_days),
        swapped=swapped,
    )


def _row(bundle: GraphBundle, acct_id: str, account: dict, ctx: FeatureContext) -> dict:
    txns = tuple(t for t in bundle.txns_by_acct.get(acct_id, ()) if t["ts"] < ctx.cutoff)
    return {
        "acct_id": acct_id, "cutoff": ctx.cutoff, "kind_is_till": int(account["kind"] == "agent_till"),
        **_velocity(acct_id, txns, ctx.cutoff, ctx.week_ago, ctx.month_ago),
        **_dormancy(account, txns, ctx.cutoff, ctx.week_ago),
        **_entity(acct_id, bundle, ctx.cutoff, ctx.week_ago, ctx.holders, ctx.activation, ctx.onboarding),
        **_proximity(acct_id, bundle, ctx.cutoff, ctx.known, ctx.swapped, ctx.week_ago),
    }


def compute_features(bundle: GraphBundle, cutoff: str, confirmation_lag_days: int = CONFIRMATION_LAG_DAYS) -> tuple[dict, ...]:
    """One row per customer / agent-till account, using only events before `cutoff`."""
    ctx = feature_context(bundle, cutoff, confirmation_lag_days)
    return tuple(_row(bundle, acct_id, account, ctx) for acct_id, account in sorted(bundle.accounts.items()) if account["kind"] in SCORED_KINDS)


def account_features(bundle: GraphBundle, acct_id: str, ctx: FeatureContext) -> dict | None:
    """One account's row, equal to its row in compute_features at ctx.cutoff; None for an account that is not scored.

    A few milliseconds against about a second for the whole table, which is what a per-request screen needs.
    """
    account = bundle.accounts.get(acct_id)
    if account is None or account["kind"] not in SCORED_KINDS:
        return None
    return _row(bundle, acct_id, account, ctx)


def feature_names(rows: tuple[dict, ...]) -> tuple[str, ...]:
    return tuple(k for k in rows[0] if k not in ("acct_id", "cutoff"))
