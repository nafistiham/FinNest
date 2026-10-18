"""Common point of cash-out: till reuse, space-time clusters seeded by confirmed mules, two candidate filters.

Seed-free by construction: confirmed mules arrive as an argument (a frozenset, or a callable `seeds_at(ts)` giving the
accounts confirmed as of `ts`) and are never read here; `cashout_seeds.py` makes them and the caller passes them in.
Every rule sees only what was known at its check time. The rules run on each cash-out: a till flag counts the seeds
confirmed as of each check, a cluster is a frozen snapshot of the check that opened it (like the radar's firings), and
both candidate filters (first-time senders; pass-through: money in from a new counterparty and out as cash) stop at
the cash-out. The outputs are leads for an analyst, never verdicts or blocks.
"""
from __future__ import annotations

from bisect import bisect_right
from collections import Counter, defaultdict, deque
from collections.abc import Callable, Iterable, Mapping
from dataclasses import asdict, dataclass
from datetime import datetime, timedelta
import hashlib
import math
from types import MappingProxyType

from . import config
from .cashout import CashOut, _sources, scan_cashouts
from .config import (BASELINE_WEEKS, CANDIDATE_LOOKBACK_HOURS, CANDIDATE_MIN_FIRST_TIME_SENDERS, CASHOUT_TYPE,
                     CLUSTER_MIN_CASHOUTS, CLUSTER_MIN_SEEDS, CLUSTER_P_THRESHOLD, CLUSTER_RADIUS_KM, CLUSTER_WINDOW_MIN,
                     FIRST_TIME_SENDER_TYPES, LAMBDA_FLOOR_PER_HOUR, PASS_THROUGH_IN_TYPES,
                     PASS_THROUGH_MIN_NEW_COUNTERPARTIES, PASS_THROUGH_MIN_SHARE, PASS_THROUGH_NEW_DAYS, PRIOR_WEEKS,
                     TILL_REUSE_DAYS, TILL_REUSE_MIN_SEEDS, TILL_REUSE_P_THRESHOLD)
from .geo import haversine_km, is_valid_point
from .stream import _amount, to_local
from .surprise import poisson_tail

SeedsAt = Callable[[str], Iterable[str]]  # accounts confirmed as mules as of a local timestamp

SOURCE_TILL_REUSE = 'till_reuse'
SOURCE_CLUSTER = 'cluster:'  # followed by the cluster id
REASON_FEW_FIRST_TIME_SENDERS = 'few_first_time_senders'
REASON_NO_NEW_COUNTERPARTY = 'no_new_counterparty'  # pass-through: nobody new paid in during the lookback
REASON_LOW_PASS_THROUGH_SHARE = 'low_pass_through_share'  # pass-through: too little of the money in went out as cash
FILTER_FIRST_TIME_SENDERS, FILTER_PASS_THROUGH = 'first_time_senders', 'pass_through'
FILTERS = (FILTER_FIRST_TIME_SENDERS, FILTER_PASS_THROUGH)  # the candidate filters, run side by side
SOURCE_PRIOR, SOURCE_BACKFILL, SOURCE_COLD_START = 'prior', 'backfill', 'cold_start'
HOUR = timedelta(hours=1)
WEEK_HOURS = 168
OUTPUT_CONSTANTS = ('TILL_REUSE_DAYS', 'TILL_REUSE_MIN_SEEDS', 'TILL_REUSE_P_THRESHOLD', 'CLUSTER_RADIUS_KM',
                    'CLUSTER_WINDOW_MIN', 'CLUSTER_MIN_SEEDS', 'CLUSTER_MIN_CASHOUTS', 'CLUSTER_P_THRESHOLD',
                    'CANDIDATE_MIN_FIRST_TIME_SENDERS', 'CANDIDATE_LOOKBACK_HOURS', 'FIRST_TIME_SENDER_TYPES',
                    'PASS_THROUGH_MIN_NEW_COUNTERPARTIES', 'PASS_THROUGH_NEW_DAYS', 'PASS_THROUGH_MIN_SHARE',
                    'PASS_THROUGH_IN_TYPES', 'CONFIRMATION_LAG_DAYS', 'BASELINE_WEEKS', 'PRIOR_WEEKS',
                    'LAMBDA_FLOOR_PER_HOUR')
CAVEAT = ('Synthetic world: every till, cash-out and account here is generated, and no number is a field result. '
          'Each candidate is a lead for an analyst to review, never a verdict or a block. Seeds are mules an analyst '
          f'confirmed {config.CONFIRMATION_LAG_DAYS} days after their first bad event, while a ring cashes out within '
          'hours, so the live 90-minute circle rarely fires: till reuse over 30 days is the live rule, and the circle '
          'is for replaying a past day. A till flags when more confirmed mules cashed out there than its own volume '
          'predicts at the network-wide share of seeds, not merely when two did. Expected counts assume a Poisson rate '
          'with no payday factor and no over-dispersion, so p-values may be optimistic; the minimum counts keep a '
          'quiet till or circle from firing on a handful. For hours in the first week of cash-outs (every till\'s '
          'first week here: all opened before it) the baseline borrows the following weeks (reported as '
          'baseline_source: backfill), so a p-value in the first week is not strictly as of the moment; none of the '
          'clusters reported on the evaluated worlds falls in a first week. Two candidate filters run side by side '
          'and each lead names its own: first-time senders (at least '
          f'{CANDIDATE_MIN_FIRST_TIME_SENDERS} strangers paying in during the '
          f'{CANDIDATE_LOOKBACK_HOURS} hours before the cash-out) and pass-through (money in from at least '
          f'{PASS_THROUGH_MIN_NEW_COUNTERPARTIES} counterparty new in {PASS_THROUGH_NEW_DAYS} days, and cash-outs at '
          f'least {PASS_THROUGH_MIN_SHARE:.0%} of everything paid in over the same hours).')


@dataclass(frozen=True)
class Till:
    till: str
    lat: float
    lon: float
    district: str | None
    since: str | None  # local time the till opened; None is always open


@dataclass(frozen=True)
class TillFlag:
    till: str
    lat: float
    lon: float
    district: str | None
    seed_accounts: tuple[str, ...]  # distinct seeds that cashed out here in the reuse window, as of the check
    accounts: int  # distinct accounts that cashed out here in the reuse window: the till's own volume
    expected: float  # accounts x the network's share of cash-out accounts that are seeds, same window and check
    p_value: float  # Poisson tail of len(seed_accounts) given expected
    first_seen_ts: str  # the first check of the current run of checks at which the till met the rule
    last_seed_ts: str  # the latest seed cash-out here in the reuse window


@dataclass(frozen=True)
class Cluster:
    cluster_id: str
    opened_at: str
    centre_lat: float
    centre_lon: float
    radius_km: float
    window_start: str
    window_end: str
    tills: tuple[str, ...]  # every open till inside the circle: the expected count sums over them
    seed_cashouts: tuple[str, ...]  # txn ids of seed cash-outs in the circle no earlier cluster holds
    all_cashouts: tuple[str, ...]  # txn ids of every cash-out inside the radius and window at opening
    observed: int
    expected: float
    p_value: float
    baseline_source: str


@dataclass(frozen=True)
class Candidate:
    acct: str
    till: str
    ts: str
    amount_bdt: float
    first_time_senders: int
    source: str  # where it was found: 'till_reuse' or 'cluster:<id>'
    filter: str  # which candidate filter named it: 'first_time_senders' or 'pass_through'
    new_counterparties: int  # the pass-through evidence of this cash-out, whichever filter named it
    received_bdt: float
    cashed_out_bdt: float


@dataclass(frozen=True)
class NotFlagged:
    acct: str
    till: str
    ts: str
    amount_bdt: float
    first_time_senders: int
    source: str
    filter: str
    new_counterparties: int
    received_bdt: float
    cashed_out_bdt: float
    reason: str


@dataclass(frozen=True)
class PassThrough:
    """Money through one account in the lookback before one of its cash-outs."""
    new_counterparties: int  # distinct accounts paying in that it had not dealt with in the PASS_THROUGH_NEW_DAYS before
    received_bdt: float  # everything paid in to it, of any type, strictly before the cash-out
    cashed_out_bdt: float  # its cash-outs at any till, up to and including this one

    @property
    def share(self) -> float | None:
        return self.cashed_out_bdt / self.received_bdt if self.received_bdt else None


def _shift(ts: str, **delta: float) -> str:
    return (datetime.fromisoformat(ts) + timedelta(**delta)).isoformat(timespec='seconds')


def _ordered(cashouts: Iterable[CashOut], as_of: str | None = None) -> tuple[CashOut, ...]:
    """Cash-outs at or before `as_of`, by time then txn id."""
    kept = (e for e in cashouts if as_of is None or e.ts <= as_of)
    return tuple(sorted(kept, key=lambda e: (e.ts, e.txn_id)))


# --- first-time senders ------------------------------------------------------------------------------------------

def _positive(value, name: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not 0 < value < math.inf:
        raise ValueError(f'{name} must be a positive number, got {value!r}')
    return value


def _lookback(ts: str, lookback_h: float) -> tuple[str, str]:
    """(start, end) of the lookback before a cash-out at `ts`, in local time."""
    end = to_local(ts)
    return _shift(end, hours=-_positive(lookback_h, 'lookback_h (hours)')), end


def first_time_senders(acct: str, ts: str, txns_by_acct: Mapping[str, Iterable[Mapping]],
                       lookback_h: float = CANDIDATE_LOOKBACK_HOURS) -> int:
    """Distinct senders who paid `acct` in the `lookback_h` hours before `ts` and never before that lookback.

    Only payments strictly before `ts` count, so nothing at or after the cash-out changes the number.
    """
    start, end = _lookback(ts, lookback_h)
    first_paid: dict[str, str] = {}
    for row in txns_by_acct.get(acct, ()):
        sender = row.get('from_acct')
        if row.get('type') not in FIRST_TIME_SENDER_TYPES or row.get('to_acct') != acct or not sender or sender == acct:
            continue
        paid = to_local(row['ts'])
        if paid < end and paid < first_paid.get(sender, end):
            first_paid[sender] = paid
    return sum(1 for first in first_paid.values() if first >= start)


# --- pass-through ------------------------------------------------------------------------------------------------

def _counterparty(row: Mapping, acct: str) -> str | None:
    """The other account of one of `acct`'s rows, or None when the row is not between `acct` and another account."""
    sender, payee = row.get('from_acct'), row.get('to_acct')
    if payee == acct and sender and sender != acct:
        return sender
    if sender == acct and payee and payee != acct:
        return payee
    return None


def _own_rows(acct: str, txns_by_acct: Mapping[str, Iterable[Mapping]], end: str) -> tuple[tuple[str, Mapping], ...]:
    """(local time, row) of `acct`'s rows at or before `end`, once per txn id, in time order."""
    rows = {row.get('txn_id') or id(row): row for row in txns_by_acct.get(acct, ())}
    timed = ((to_local(row['ts']), row) for row in rows.values())
    return tuple(sorted(((when, row) for when, row in timed if when <= end), key=lambda item: item[0]))


def pass_through(acct: str, ts: str, txns_by_acct: Mapping[str, Iterable[Mapping]],
                 lookback_h: float = CANDIDATE_LOOKBACK_HOURS, new_days: float = PASS_THROUGH_NEW_DAYS) -> PassThrough:
    """Money through `acct` in the `lookback_h` hours up to its cash-out at `ts`.

    New counterparties are the distinct accounts paying it in (PASS_THROUGH_IN_TYPES) strictly before `ts` with which it
    had no row, either way and of any type, in the `new_days` before that payment. Received is everything paid in to it
    over the lookback strictly before `ts`; cashed out is its cash-outs at any till from the start of the lookback
    through `ts`, the one at `ts` included. Nothing after `ts` counts.
    """
    start, end = _lookback(ts, lookback_h)
    month = timedelta(days=_positive(new_days, 'new_days'))
    dealt: dict[str, list[str]] = defaultdict(list)  # counterparty -> times of its rows with `acct`, earlier first
    new, received, cashed = set(), 0.0, 0.0
    for when, row in _own_rows(acct, txns_by_acct, end):
        other, amount = _counterparty(row, acct), _amount(row.get('amount_bdt'))
        if row.get('type') == CASHOUT_TYPE and row.get('from_acct') == acct and when >= start:
            cashed += amount
        if other is None:
            continue
        if row.get('to_acct') == acct and start <= when < end:
            received += amount
            oldest = (datetime.fromisoformat(when) - month).isoformat(timespec='seconds')
            if row.get('type') in PASS_THROUGH_IN_TYPES and not any(oldest <= t < when for t in dealt[other]):
                new.add(other)
        dealt[other].append(when)
    return PassThrough(new_counterparties=len(new), received_bdt=received, cashed_out_bdt=cashed)


def is_pass_through(evidence: PassThrough) -> bool:
    """At least PASS_THROUGH_MIN_NEW_COUNTERPARTIES new counterparties paid in, and cash-outs at least
    PASS_THROUGH_MIN_SHARE of everything received over the same lookback."""
    return (evidence.new_counterparties >= PASS_THROUGH_MIN_NEW_COUNTERPARTIES and evidence.received_bdt > 0
            and evidence.cashed_out_bdt >= PASS_THROUGH_MIN_SHARE * evidence.received_bdt)


# --- till reuse --------------------------------------------------------------------------------------------------

@dataclass(frozen=True)
class _Reuse:
    """One till's test at one check: distinct seeds observed, distinct accounts, expected seeds and the Poisson tail."""
    observed: int
    accounts: int
    expected: float
    p_value: float


class _ReuseWindow:
    """Cash-outs per till and account inside the sliding reuse window of the replay, with running counts of the distinct
    seed accounts per till and across the network, so each check costs one pass over the tills."""

    def __init__(self) -> None:
        self.by_till: dict[str, Counter] = defaultdict(Counter)
        self.by_acct: dict[str, Counter] = defaultdict(Counter)
        self.seeds: frozenset[str] = frozenset()
        self.seeds_by_till: Counter = Counter()  # till -> distinct seed accounts that cashed out there
        self.seed_accounts = 0  # distinct seed accounts that cashed out anywhere

    def add(self, e: CashOut) -> None:
        new_here, new_anywhere = not self.by_till[e.till][e.acct], e.acct not in self.by_acct
        self.by_till[e.till][e.acct] += 1
        self.by_acct[e.acct][e.till] += 1
        if e.acct in self.seeds:
            self.seeds_by_till[e.till] += new_here
            self.seed_accounts += new_anywhere

    def drop(self, e: CashOut) -> None:
        for outer, inner, table in ((e.till, e.acct, self.by_till), (e.acct, e.till, self.by_acct)):
            table[outer][inner] -= 1
            if not table[outer][inner]:
                del table[outer][inner]
            if not table[outer]:
                del table[outer]
        if e.acct in self.seeds:
            self.seeds_by_till[e.till] -= e.acct not in self.by_till.get(e.till, ())
            self.seed_accounts -= e.acct not in self.by_acct

    def set_seeds(self, now: frozenset[str]) -> None:
        """Move the running seed counts to the seeds confirmed as of this check."""
        for acct in (now ^ self.seeds) & self.by_acct.keys():
            sign = 1 if acct in now else -1
            for till in self.by_acct[acct]:
                self.seeds_by_till[till] += sign
            self.seed_accounts += sign
        self.seeds = now

    def tests(self) -> dict[str, _Reuse]:
        """The till-reuse test of every till with at least TILL_REUSE_MIN_SEEDS seeds: expected seeds are the till's
        distinct accounts times the network's share of accounts that are seeds (the till's own included)."""
        tills = sorted(t for t, n in self.seeds_by_till.items() if n >= TILL_REUSE_MIN_SEEDS)
        if not tills:
            return {}
        share = self.seed_accounts / len(self.by_acct)
        observed = [self.seeds_by_till[t] for t in tills]
        expected = [len(self.by_till[t]) * share for t in tills]
        p_values = poisson_tail(observed, expected)
        return {t: _Reuse(observed=k, accounts=len(self.by_till[t]), expected=mu, p_value=float(p))
                for t, k, mu, p in zip(tills, observed, expected, p_values)}


def _flagged(window: _ReuseWindow) -> dict[str, _Reuse]:
    return {till: test for till, test in window.tests().items() if test.p_value <= TILL_REUSE_P_THRESHOLD}


def _flag_onsets(events: tuple[CashOut, ...], seeds_at: SeedsAt, as_of: str) -> tuple[dict[str, str], dict[str, _Reuse]]:
    """Replay the rule at each cash-out and at `as_of`: (till -> first check of its current run of flagged checks, the
    tests of the tills flagged at `as_of`). Every till is retested at every check: the share is network-wide."""
    window, onset, flagged = _ReuseWindow(), {}, {}
    head, tail = 0, 0
    for check in sorted({e.ts for e in events} | {as_of}):
        while head < len(events) and events[head].ts <= check:
            window.add(events[head])
            head += 1
        oldest = _shift(check, days=-TILL_REUSE_DAYS)
        while tail < head and events[tail].ts <= oldest:
            window.drop(events[tail])
            tail += 1
        window.set_seeds(frozenset(seeds_at(check)))
        flagged = _flagged(window)
        onset = {till: onset.get(till, check) for till in flagged}
    return onset, flagged


def till_reuse(cashouts: Iterable[CashOut], seeds_at: SeedsAt, as_of: str) -> tuple[TillFlag, ...]:
    """Tills where more distinct seeds cashed out in the TILL_REUSE_DAYS up to `as_of` than the till's own volume
    predicts: at least TILL_REUSE_MIN_SEEDS of them, and a Poisson tail at most TILL_REUSE_P_THRESHOLD given the
    expected count (the till's distinct cash-out accounts times the network-wide share of cash-out accounts that are
    seeds, in the same window). A busy till with seeds in proportion to its volume does not flag.

    Seeds are those confirmed as of each check (`seeds_at(check)`); the window is `(check - days, check]`.
    """
    as_of = to_local(as_of)
    events = _ordered(cashouts, as_of)
    onset, tests = _flag_onsets(events, seeds_at, as_of)
    seeds, oldest = frozenset(seeds_at(as_of)), _shift(as_of, days=-TILL_REUSE_DAYS)
    flags = []
    for till in sorted(onset):
        here = tuple(e for e in events if e.till == till and e.ts > oldest)
        seeded = tuple(e for e in here if e.acct in seeds)
        place, test = here[-1], tests[till]
        flags.append(TillFlag(till=till, lat=place.lat, lon=place.lon, district=place.district,
                              seed_accounts=tuple(sorted({e.acct for e in seeded})), accounts=test.accounts,
                              expected=test.expected, p_value=test.p_value, first_seen_ts=onset[till],
                              last_seed_ts=max(e.ts for e in seeded)))
    return tuple(flags)


# --- the per-till baseline ---------------------------------------------------------------------------------------

class TillBaseline:
    """Hourly cash-out rate per till: the same hour of week over the BASELINE_WEEKS before, shrunk toward the pooled
    rate of all open tills with PRIOR_WEEKS of weight, as the radar's cell baseline. The pooled rate shares each
    comparison hour's total among the tills open at that hour, so a till that opens later does not dilute earlier
    weeks. Hours with no earlier week borrow later weeks inside `[start, end]` and say `backfill`; hours with neither
    say `cold_start` and use the floor."""

    def __init__(self, cashouts: Iterable[CashOut], tills: Iterable[Till], start: str, end: str):
        self.tills = MappingProxyType({t.till: t for t in tills})
        self._since = MappingProxyType({t.till: to_local(t.since) if t.since else None for t in self.tills.values()})
        self._always_open = sum(since is None for since in self._since.values())
        self._openings = tuple(sorted(since for since in self._since.values() if since is not None))
        self.start = datetime.fromisoformat(to_local(start)).replace(minute=0, second=0)
        self.hours = self._index(to_local(end)) + 1
        counts, totals = Counter(), Counter()
        for e in cashouts:
            index = self._index(e.ts)
            if 0 <= index < self.hours:
                counts[e.till, index] += 1
                totals[index] += 1
        self._counts, self._totals = MappingProxyType(dict(counts)), MappingProxyType(dict(totals))

    def _index(self, ts: str) -> int:
        return math.floor((datetime.fromisoformat(ts) - self.start) / HOUR)

    def _open(self, ts: str) -> tuple[Till, ...]:
        return tuple(t for t in self.tills.values() if self._since[t.till] is None or self._since[t.till] <= ts)

    def _open_at(self, index: int) -> int:
        """How many tills are open at the hour `index`: the same test as `_open`, counted."""
        hour_ts = (self.start + index * HOUR).isoformat(timespec='seconds')
        return self._always_open + bisect_right(self._openings, hour_ts)

    def tills_within(self, lat: float, lon: float, radius_km: float, as_of: str) -> tuple[str, ...]:
        """Tills open at `as_of` whose place lies within `radius_km` of the point."""
        return tuple(sorted(t.till for t in self._open(as_of) if haversine_km(lat, lon, t.lat, t.lon) <= radius_km))

    def _comparisons(self, index: int) -> tuple[tuple[int, ...], str]:
        prior = tuple(index - WEEK_HOURS * d for d in range(1, BASELINE_WEEKS + 1) if index - WEEK_HOURS * d >= 0)
        if prior:
            return prior, SOURCE_PRIOR
        later = tuple(index + WEEK_HOURS * d for d in range(1, BASELINE_WEEKS + 1) if index + WEEK_HOURS * d < self.hours)
        return later, SOURCE_BACKFILL if later else SOURCE_COLD_START

    def rate(self, till: str, hour_ts: str) -> tuple[float, str]:
        """(cash-outs per hour, baseline source) for one till and the hour starting at `hour_ts`."""
        index = self._index(hour_ts)
        if not 0 <= index < self.hours:
            return LAMBDA_FLOOR_PER_HOUR, SOURCE_COLD_START
        comparisons, source = self._comparisons(index)
        weeks = len(comparisons)
        till_hours = max(sum(self._open_at(j) for j in comparisons), 1)  # each week's total over its own open tills
        pooled = max(sum(self._totals.get(j, 0) for j in comparisons) / till_hours, LAMBDA_FLOOR_PER_HOUR)
        own = sum(self._counts.get((till, j), 0) for j in comparisons)
        return (own + PRIOR_WEEKS * pooled) / (weeks + PRIOR_WEEKS), source

    def expected(self, tills: Iterable[str], begin: str, end: str) -> tuple[float, str]:
        """Expected cash-outs at `tills` over `[begin, end]`, and the weakest baseline source used."""
        start, stop = datetime.fromisoformat(begin), datetime.fromisoformat(end)
        hour, mu, sources = start.replace(minute=0, second=0), 0.0, set()
        while hour < stop:
            overlap = (min(stop, hour + HOUR) - max(start, hour)) / HOUR
            for till in tills:
                rate, source = self.rate(till, hour.isoformat(timespec='seconds'))
                mu, sources = mu + rate * overlap, sources | {source}
            hour += HOUR
        weakest = next((s for s in (SOURCE_COLD_START, SOURCE_BACKFILL) if s in sources), SOURCE_PRIOR)
        return mu, weakest


# --- space-time clusters -----------------------------------------------------------------------------------------

def _centroid(events: Iterable[CashOut]) -> tuple[float, float]:
    """Mean latitude and longitude: within a few kilometres the plane is the sphere to metres."""
    points = tuple((e.lat, e.lon) for e in events)
    return sum(p[0] for p in points) / len(points), sum(p[1] for p in points) / len(points)


def _tighten(group: tuple[CashOut, ...]) -> tuple[CashOut, ...]:
    """Drop the cash-out farthest from the centroid until every one lies within the radius of it."""
    while group:
        lat, lon = _centroid(group)
        far = max(group, key=lambda e: (haversine_km(lat, lon, e.lat, e.lon), e.ts, e.txn_id))
        if haversine_km(lat, lon, far.lat, far.lon) <= CLUSTER_RADIUS_KM:
            return group
        group = tuple(e for e in group if e is not far)
    return group


def _seed_group(seed_events: tuple[CashOut, ...]) -> tuple[CashOut, ...] | None:
    """Seed cash-outs by at least CLUSTER_MIN_SEEDS accounts all within the radius of their centroid, or None.

    Two members of such a set lie within twice the radius of each other, so each seed in turn gathers its neighbours
    within that distance and `_tighten` trims them; the group with the most accounts (then cash-outs) wins, the
    earliest anchor breaking ties."""
    best, best_rank = None, (0, 0)
    for anchor in seed_events:
        near = tuple(e for e in seed_events
                     if haversine_km(anchor.lat, anchor.lon, e.lat, e.lon) <= 2 * CLUSTER_RADIUS_KM)
        group = _tighten(near)
        rank = (len({e.acct for e in group}), len(group))
        if rank[0] >= CLUSTER_MIN_SEEDS and rank > best_rank:
            best, best_rank = group, rank
    return best


def _try_open(window: tuple[CashOut, ...], check: str, seeds: frozenset[str], baseline: TillBaseline,
              claimed: frozenset[str]) -> Cluster | None:
    """The cluster this check opens, or None: a seed group, then the floor and the Poisson tail."""
    group = _seed_group(tuple(e for e in window if e.acct in seeds and e.txn_id not in claimed))
    if group is None:
        return None
    lat, lon = _centroid(group)
    members = tuple(e for e in window if haversine_km(lat, lon, e.lat, e.lon) <= CLUSTER_RADIUS_KM)
    tills = tuple(sorted(set(baseline.tills_within(lat, lon, CLUSTER_RADIUS_KM, check)) | {e.till for e in members}))
    start = _shift(check, minutes=-CLUSTER_WINDOW_MIN)
    expected, source = baseline.expected(tills, start, check)
    p_value = float(poisson_tail(len(members), expected))
    if len(members) < CLUSTER_MIN_CASHOUTS or p_value > CLUSTER_P_THRESHOLD:
        return None
    seed_ids = tuple(e.txn_id for e in members if e.acct in seeds and e.txn_id not in claimed)
    cluster_id = 'clu_' + hashlib.sha1('|'.join(sorted(seed_ids)).encode()).hexdigest()[:12]
    return Cluster(cluster_id=cluster_id, opened_at=check, centre_lat=lat, centre_lon=lon, radius_km=CLUSTER_RADIUS_KM,
                   window_start=start, window_end=check, tills=tills, seed_cashouts=seed_ids,
                   all_cashouts=tuple(e.txn_id for e in members), observed=len(members), expected=expected,
                   p_value=p_value, baseline_source=source)


def space_time_clusters(cashouts: Iterable[CashOut], seeds_at: SeedsAt, baseline: TillBaseline) -> tuple[Cluster, ...]:
    """Walk cash-outs in time order and open a cluster at the first check where CLUSTER_MIN_SEEDS distinct seeds
    (confirmed as of that check) cashed out within CLUSTER_RADIUS_KM of their centroid in the CLUSTER_WINDOW_MIN up to
    it, the circle holds at least CLUSTER_MIN_CASHOUTS cash-outs, and its Poisson tail is at most CLUSTER_P_THRESHOLD.

    A cluster is frozen at opening: later cash-outs and later confirmations never change it, and a seed cash-out
    belongs to one cluster only."""
    events = _ordered(cashouts)
    window: deque[CashOut] = deque()
    clusters, claimed, head = [], frozenset(), 0
    for check in sorted({e.ts for e in events}):
        while head < len(events) and events[head].ts <= check:
            window.append(events[head])
            head += 1
        oldest = _shift(check, minutes=-CLUSTER_WINDOW_MIN)
        while window and window[0].ts < oldest:
            window.popleft()
        if len(window) < CLUSTER_MIN_CASHOUTS or len({e.acct for e in window}) < CLUSTER_MIN_SEEDS:
            continue  # cannot fire: no need to ask for the seeds
        cluster = _try_open(tuple(window), check, frozenset(seeds_at(check)), baseline, claimed)
        if cluster is not None:
            clusters.append(cluster)
            claimed = claimed | frozenset(cluster.seed_cashouts)
    return tuple(clusters)


# --- candidates --------------------------------------------------------------------------------------------------

def _inside(flag_or_cluster: TillFlag | Cluster, cashouts: tuple[CashOut, ...], as_of: str | None
            ) -> tuple[str, tuple[CashOut, ...]]:
    """(source, cash-outs inside): at a flagged till in the reuse window up to `as_of`, or a cluster's own members."""
    if isinstance(flag_or_cluster, TillFlag):
        end = to_local(as_of) if as_of else max((e.ts for e in cashouts), default='')
        oldest = _shift(end, days=-TILL_REUSE_DAYS) if end else ''
        return SOURCE_TILL_REUSE, tuple(e for e in cashouts if e.till == flag_or_cluster.till and oldest < e.ts <= end)
    if isinstance(flag_or_cluster, Cluster):
        members = frozenset(flag_or_cluster.all_cashouts)
        return SOURCE_CLUSTER + flag_or_cluster.cluster_id, tuple(e for e in cashouts if e.txn_id in members)
    raise TypeError(f'expected a TillFlag or a Cluster, got {type(flag_or_cluster).__name__}')


@dataclass(frozen=True)
class _Lead:
    """One non-seed cash-out inside a flag or cluster with both filters' evidence, as of the cash-out."""
    event: CashOut
    first_time_senders: int
    evidence: PassThrough


def _first_time_pick(leads: list[_Lead]) -> tuple[_Lead, str | None]:
    """The cash-out with the most first-time senders (then the earliest), and why it is held back, if it is."""
    lead = min(leads, key=lambda x: (-x.first_time_senders, x.event.ts, x.event.txn_id))
    held = lead.first_time_senders < CANDIDATE_MIN_FIRST_TIME_SENDERS
    return lead, REASON_FEW_FIRST_TIME_SENDERS if held else None


def _pass_through_pick(leads: list[_Lead]) -> tuple[_Lead, str | None]:
    """The earliest cash-out that passes; failing that, the closest to passing (most new counterparties, then the
    highest share, then the earliest), and why it is held back."""
    passing = [x for x in leads if is_pass_through(x.evidence)]
    if passing:
        return min(passing, key=lambda x: (x.event.ts, x.event.txn_id)), None
    lead = min(leads, key=lambda x: (-x.evidence.new_counterparties, -(x.evidence.share or 0.0), x.event.ts,
                                     x.event.txn_id))
    few = lead.evidence.new_counterparties < PASS_THROUGH_MIN_NEW_COUNTERPARTIES
    return lead, REASON_NO_NEW_COUNTERPARTY if few else REASON_LOW_PASS_THROUGH_SHARE


PICKS = MappingProxyType({FILTER_FIRST_TIME_SENDERS: _first_time_pick, FILTER_PASS_THROUGH: _pass_through_pick})


def candidates(flag_or_cluster: TillFlag | Cluster, cashouts: Iterable[CashOut], seeds: frozenset[str],
               txns_by_acct: Mapping[str, Iterable[Mapping]], *, as_of: str | None = None,
               candidate_filter: str = FILTER_FIRST_TIME_SENDERS) -> tuple[tuple[Candidate, ...], tuple[NotFlagged, ...]]:
    """(candidates, not flagged) under one candidate filter: each non-seed account cashing out inside the flag or
    cluster, once. `txns_by_acct` files each ledger row under its accounts (a bundle's `txns_by_acct`).

    `first_time_senders` (the default): a candidate when one of its cash-outs there had at least
    CANDIDATE_MIN_FIRST_TIME_SENDERS first-time senders in the CANDIDATE_LOOKBACK_HOURS before it (the cash-out with the
    most is kept). `pass_through`: a candidate when one of its cash-outs there passes `is_pass_through` over the same
    lookback (the earliest that passes is kept). Otherwise it is listed as not flagged with the reason. Every lead carries
    both filters' evidence as of its cash-out. A till flag's window ends at `as_of`, by default the latest cash-out given.
    """
    if candidate_filter not in PICKS:
        raise ValueError(f'candidate_filter must be one of {FILTERS}, got {candidate_filter!r}')
    source, inside = _inside(flag_or_cluster, _ordered(cashouts), as_of)
    by_acct: dict[str, list[_Lead]] = defaultdict(list)
    for e in inside:
        if e.acct not in seeds:
            by_acct[e.acct].append(_Lead(event=e, first_time_senders=first_time_senders(e.acct, e.ts, txns_by_acct),
                                         evidence=pass_through(e.acct, e.ts, txns_by_acct)))
    found, held = [], []
    for acct in sorted(by_acct):
        lead, reason = PICKS[candidate_filter](by_acct[acct])
        e, evidence = lead.event, lead.evidence
        row = dict(acct=acct, till=e.till, ts=e.ts, amount_bdt=e.amount_bdt, first_time_senders=lead.first_time_senders,
                   source=source, filter=candidate_filter, new_counterparties=evidence.new_counterparties,
                   received_bdt=evidence.received_bdt, cashed_out_bdt=evidence.cashed_out_bdt)
        if reason is None:
            found.append(Candidate(**row))
        else:
            held.append(NotFlagged(**row, reason=reason))
    return tuple(sorted(found, key=_lead_order)), tuple(sorted(held, key=_lead_order))


def _lead_order(lead: Candidate | NotFlagged) -> tuple[str, str]:
    return lead.ts, lead.acct


# --- the output --------------------------------------------------------------------------------------------------

def read_tills(bundle_or_tables, as_of: str | None = None) -> tuple[Till, ...]:
    """Every till in the agents table with a valid place, open at `as_of` when given, by agent id."""
    _txns, agents = _sources(bundle_or_tables)
    tills = (Till(till=str(a['agent_id']), lat=float(a['lat']), lon=float(a['lon']), district=a.get('district'),
                  since=to_local(a['since']) if a.get('since') else None)
             for a in agents.values() if is_valid_point(a.get('lat'), a.get('lon')))
    return tuple(sorted((t for t in tills if as_of is None or not t.since or t.since <= as_of), key=lambda t: t.till))


def _by_account(bundle_or_tables) -> Mapping[str, tuple[Mapping, ...]]:
    """Every ledger row filed under each of its accounts: a bundle's own `txns_by_acct`, or built from the tables with
    one row per txn id."""
    if not isinstance(bundle_or_tables, Mapping):
        return bundle_or_tables.txns_by_acct
    txns, _agents = _sources(bundle_or_tables)
    rows = {row.get('txn_id') or id(row): row for row in txns}
    grouped: dict[str, list[Mapping]] = defaultdict(list)
    for row in rows.values():
        for acct in {row.get('from_acct'), row.get('to_acct')} - {None}:
            grouped[acct].append(row)
    return {acct: tuple(items) for acct, items in grouped.items()}


def _memo(seeds_at: SeedsAt) -> Callable[[str], frozenset[str]]:
    cache: dict[str, frozenset[str]] = {}

    def at(ts: str) -> frozenset[str]:
        if ts not in cache:
            cache[ts] = frozenset(seeds_at(ts))
        return cache[ts]
    return at


def _json(value):
    if isinstance(value, Mapping):
        return {key: _json(item) for key, item in value.items()}
    if isinstance(value, (tuple, list, frozenset)):
        return [_json(item) for item in value]
    return value


def run_cashout(bundle_or_tables, as_of: str, seeds_at: SeedsAt) -> dict:
    """The JSON-ready cash-out picture as of `as_of`: tills, till flags, clusters, candidates and the ones not flagged,
    under each candidate filter (a lead's `filter` names it; an account can be a candidate under both).

    `seeds_at(ts)` gives the mules confirmed as of `ts`; the caller makes it (see `cashout_seeds.confirmed_mules`).
    """
    if not callable(seeds_at):
        raise TypeError('seeds_at must be a callable from a timestamp to the confirmed accounts')
    as_of = to_local(as_of)
    scan = scan_cashouts(bundle_or_tables, end=_shift(as_of, seconds=1))
    events, seeds_at = scan.events, _memo(seeds_at)
    tills = read_tills(bundle_or_tables, as_of)
    flags = till_reuse(events, seeds_at, as_of)
    baseline = TillBaseline(events, tills, start=events[0].ts if events else as_of, end=as_of)
    clusters = space_time_clusters(events, seeds_at, baseline)
    seeds, ledger = seeds_at(as_of), _by_account(bundle_or_tables)
    leads = tuple(candidates(rule, events, seeds, ledger, as_of=as_of, candidate_filter=name)
                  for rule in (*flags, *clusters) for name in FILTERS)
    found = tuple(c for pair in leads for c in pair[0])
    held = tuple(n for pair in leads for n in pair[1])
    per_till = Counter(e.till for e in events)
    return _json(dict(
        as_of=as_of,
        tills=[dict(asdict(t), cashouts=per_till.get(t.till, 0)) for t in tills],
        till_flags=[asdict(f) for f in flags], clusters=[asdict(c) for c in clusters],
        candidates=[asdict(c) for c in found], not_flagged=[asdict(n) for n in held],
        counts=dict(cashouts=len(events), skipped=dict(scan.skipped), tills=len(tills), seeds=len(seeds),
                    till_flags=len(flags), clusters=len(clusters), candidates=len(found),
                    candidate_accounts=len({c.acct for c in found}),
                    candidates_by_filter={name: sum(c.filter == name for c in found) for name in FILTERS},
                    not_flagged=len(held)),
        config={name: getattr(config, name) for name in OUTPUT_CONSTANTS}, caveat=CAVEAT))
