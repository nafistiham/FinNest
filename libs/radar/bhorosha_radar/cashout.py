"""Cash-outs at agent tills as located events; a till has a place only from the moment it existed (as of each event).

Observable tables only: the ledger's cash-out rows and the agents table. Hidden annotations on a ledger row never reach
a `CashOut`, whose fields are fixed below. Confirmed-mule seeds live in `cashout_seeds.py`, apart from this reader.
"""
from __future__ import annotations

from collections import Counter
from collections.abc import Iterable, Mapping
from dataclasses import dataclass
from types import MappingProxyType

from .config import CASHOUT_TYPE
from .geo import is_valid_point
from .stream import _amount, to_local

SKIP_NO_TILL = 'no_till'  # the row names no agent till
SKIP_NO_COORDINATES = 'no_coordinates'  # the till is not in the agents table, or has no valid latitude and longitude
SKIP_TILL_NOT_OPEN = 'till_not_yet_open'  # the agent's `since` is after the cash-out: the till had no place yet


@dataclass(frozen=True)
class CashOut:
    txn_id: str
    ts: str  # local Asia/Dhaka time, seconds
    acct: str  # the account cashing out (the ledger's from_acct)
    till: str  # agent_id of the till that paid out
    amount_bdt: float
    lat: float
    lon: float
    district: str | None  # the till's district


@dataclass(frozen=True)
class CashOutScan:
    events: tuple[CashOut, ...]  # time-sorted, ties by txn_id
    skipped: Mapping[str, int]  # skip reason -> cash-outs in the window left without a place


def _sources(bundle_or_tables) -> tuple[tuple[dict, ...], Mapping[str, dict]]:
    """(ledger rows, agents by id) from a bundle (`agents`, `txns_by_acct`) or a mapping of `transactions`, `agents`."""
    if isinstance(bundle_or_tables, Mapping):
        txns = tuple(bundle_or_tables.get('transactions', ()))
        agents = bundle_or_tables.get('agents', ())
    else:  # a bundle files every transaction under both of its accounts; _cashout_rows collapses the copies
        txns = tuple(t for rows in bundle_or_tables.txns_by_acct.values() for t in rows)
        agents = bundle_or_tables.agents
    return txns, agents if isinstance(agents, Mapping) else {a['agent_id']: a for a in agents}


def _cashout_rows(txns: Iterable[dict]) -> tuple[dict, ...]:
    """One row per cash-out txn_id, its timestamp in local time; conflicting copies of one txn_id raise ValueError."""
    by_id: dict[str, dict] = {}
    for row in txns:
        if row.get('type') != CASHOUT_TYPE:
            continue
        txn_id = row.get('txn_id')
        if not isinstance(txn_id, str) or not txn_id or not isinstance(row.get('ts'), str):
            raise ValueError(f'cash-out without txn_id or ts: {txn_id!r}')
        if txn_id in by_id and by_id[txn_id] != row:
            raise ValueError(f'conflicting rows for txn_id {txn_id}')
        by_id[txn_id] = row
    return tuple({**row, 'ts': to_local(row['ts'])} for row in by_id.values())


def _skip_reason(row: dict, agent: Mapping | None) -> str | None:
    if not row.get('agent_id'):
        return SKIP_NO_TILL
    if agent is None or not is_valid_point(agent.get('lat'), agent.get('lon')):
        return SKIP_NO_COORDINATES
    since = agent.get('since')  # a till without an opening time is taken as always open
    return SKIP_TILL_NOT_OPEN if since and to_local(since) > row['ts'] else None


def _event(row: dict, agent: Mapping) -> CashOut:
    acct = row.get('from_acct')
    if not isinstance(acct, str) or not acct:
        raise ValueError(f'{row["txn_id"]}: cash-out without from_acct')
    return CashOut(txn_id=row['txn_id'], ts=row['ts'], acct=acct, till=str(row['agent_id']),
                   amount_bdt=_amount(row.get('amount_bdt')), lat=float(agent['lat']), lon=float(agent['lon']),
                   district=agent.get('district'))


def scan_cashouts(bundle_or_tables, start: str | None = None, end: str | None = None) -> CashOutScan:
    """Every cash-out with `start <= ts < end` located at its till as of the moment, and the count of each skip."""
    txns, agents = _sources(bundle_or_tables)
    lo, hi = (to_local(bound) if bound else None for bound in (start, end))
    rows = tuple(r for r in _cashout_rows(txns) if (lo is None or r['ts'] >= lo) and (hi is None or r['ts'] < hi))
    reasons = tuple(_skip_reason(r, agents.get(r.get('agent_id'))) for r in rows)
    events = (_event(r, agents[r['agent_id']]) for r, reason in zip(rows, reasons) if reason is None)
    skipped = Counter(reason for reason in reasons if reason is not None)
    return CashOutScan(events=tuple(sorted(events, key=lambda e: (e.ts, e.txn_id))),
                       skipped=MappingProxyType(dict(sorted(skipped.items()))))


def read_cashouts(bundle_or_tables, start: str | None = None, end: str | None = None) -> tuple[CashOut, ...]:
    """The located cash-out events of `scan_cashouts`, time-sorted; see its `skipped` for the rows left out."""
    return scan_cashouts(bundle_or_tables, start, end).events
