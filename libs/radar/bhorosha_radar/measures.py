"""Acceptance calculations, separate from the detector's input path."""
from dataclasses import dataclass
from datetime import datetime, timedelta
import operator

from .config import CELL_TYPES
from .link import Campaign
from .surprise import incidents


@dataclass(frozen=True)
class CampaignTruth:
    campaign_id: str
    attempt_ids: frozenset[str]
    victims: frozenset[str]
    tenth_ts: str
    allowed: tuple[tuple[str, float], ...]
    cashouts: tuple[tuple[str, float], ...]
    payees: frozenset[str]
    till: str | None = None


# Evaluation thresholds from spec section 7; these never influence detection.
FLAG_WITHIN_MIN = 15.0
RETAINED_FRACTION_MIN = 0.5
ATTEMPT_PRECISION_MIN = ATTEMPT_RECALL_MIN = 0.9
VICTIM_COVERAGE_MIN = 1.0
FRAUD_DOMINANT_SHARE = 0.8


def flag_ts(truth, firings) -> str | None:
    return min((f.run_ts for f in firings if truth.attempt_ids.intersection(f.attempt_ids)), default=None)


def time_to_flag_min(truth, firings) -> float | None:
    flag = flag_ts(truth, firings)
    return (datetime.fromisoformat(flag) - datetime.fromisoformat(truth.tenth_ts)).total_seconds() / 60 if flag else None


def money_at_flag(truth, flag) -> dict:
    received = sum(amount for ts, amount in truth.allowed if ts < flag)
    exited = sum(amount for ts, amount in truth.cashouts if ts < flag)
    retained = received - exited
    return dict(allowed_by_flag=received, cashed_out_by_flag=exited,
                retained_by_flag=retained, retained_fraction=retained / received if received else None,
                future_allowed_after_flag=sum(amount for ts, amount in truth.allowed if ts >= flag))


def precision_recall(truth, campaign) -> tuple[float, float]:
    predicted = set(campaign.attempt_ids) if campaign else set()
    overlap = len(truth.attempt_ids.intersection(predicted))
    return (overlap / len(predicted) if predicted else 0.0,
            overlap / len(truth.attempt_ids) if truth.attempt_ids else 0.0)


def victim_coverage(truth, campaign) -> float | None:
    return len(truth.victims.intersection(campaign.senders if campaign else ())) / len(truth.victims) if truth.victims else None


def match(truth, campaigns) -> Campaign | None:
    best = max(campaigns, key=lambda c: len(truth.attempt_ids.intersection(c.attempt_ids)), default=None)
    return best if best and truth.attempt_ids.intersection(best.attempt_ids) else None


def incident_class(incident, ring_attempts) -> str:
    ids = set(incident.attempt_ids)
    overlap = len(ids.intersection(ring_attempts))
    return "benign_only" if not overlap else "fraud_dominant" if overlap / len(ids) >= FRAUD_DOMINANT_SHARE else "mixed"


def measure(value, op, threshold, *, na=False) -> dict:
    compare = {"<=": operator.le, ">=": operator.ge, "==": operator.eq}[op]
    status = ("n/a" if na else "missing") if value is None else ("pass" if compare(value, threshold) else "fail")
    return {"value": value, "target": f"{op} {threshold}", "status": status}


def in_payment_stream(burst) -> bool:
    """False when none of the burst's activity types is a payment the cells count (a wedding of cash-outs): no
    attempt can ever belong to it, so it is reported outside the stream, never as zero incidents or as missing data."""
    return not burst.types or bool(set(burst.types).intersection(CELL_TYPES))


def burst_attempt_ids(burst, attempts) -> set[str]:
    """Attempts in the stream that belong to a benign burst (its half-open interval start <= ts < end, as bursts.jsonl
    defines it; its types and accounts)."""
    return {a.attempt_id for a in attempts if burst.start<=a.ts<burst.end and (not burst.types or a.type in burst.types)
            and (not burst.acct_ids or a.sender in burst.acct_ids or a.payee in burst.acct_ids)}


def burst_incidents(burst, attempts, incidents, ring_attempts) -> int | None:
    """Benign-only and mixed incidents touching the burst. None means not evaluated: a burst with no attempt in
    the stream has nothing the detector could have fired on, so zero incidents there would be a false pass."""
    ids=burst_attempt_ids(burst,attempts)
    if not ids:
        return None
    return sum(bool(ids.intersection(i.attempt_ids)) and incident_class(i,ring_attempts)!='fraud_dominant' for i in incidents)


def false_incidents_by_route(firings, ring_attempts, start, end) -> dict:
    begin,stop=datetime.fromisoformat(start),datetime.fromisoformat(end)
    result={}
    for route in ('poisson','velocity_cap'):
        route_incidents=incidents(tuple(f for f in firings if f.reason==route))
        weeks={}
        cursor=begin
        while cursor<stop:
            next_week=min(cursor+timedelta(days=7),stop)
            count=sum(cursor<=datetime.fromisoformat(i.opened_at)<next_week and incident_class(i,ring_attempts)=='benign_only' for i in route_incidents)
            days=(next_week-cursor).total_seconds()/86400
            weeks[cursor.isoformat(timespec='seconds')]={'benign_only_incidents':count,'exposure_days':days,'per_week':count*7/days}
            cursor=next_week
        result[route]=weeks
    return result
