"""Confirmed-mule seeds for the cash-out rules: the radar package's one reader of label rows.

A mule is not known when it starts: an analyst confirms it CONFIRMATION_LAG_DAYS after its first bad event. The rule is
the synth's `bhorosha_graph.features.confirmed_fraud`, reused so the scorer, the investigator's graph tools and the radar
agree on who was known when (a first bad event strictly before `as_of - lag`). Every non-victim role of the synth
(mules, purchased mules, controllers, cash-out agents) counts; a victim row never does, so an account taken over in one
ring and a mule in another is a seed only once its mule row is confirmed. Kept apart from `cashout.py`, which the
label-hygiene grep test covers; the evaluation and the rules call this module explicitly.
"""
from __future__ import annotations

from bisect import bisect_left
from collections.abc import Callable, Iterable, Mapping
import json
from pathlib import Path
from types import SimpleNamespace

from bhorosha_graph.features import FRAUD_ROLES, confirmed_before, confirmed_fraud

from .config import CONFIRMATION_LAG_DAYS
from .stream import to_local

VICTIM_ROLE = 'victim'
LABEL_FIELDS = ('acct_id', 'role', 'first_bad_ts')  # all a seed needs; ring and typology stay in the file


def read_labels(seed_dir: Path) -> tuple[dict, ...]:
    """`labels.jsonl` cut to LABEL_FIELDS; an absent file is no rows."""
    path = seed_dir / 'labels.jsonl'
    if not path.exists():
        return ()
    rows = (json.loads(line) for line in path.read_text(encoding='utf-8').splitlines() if line.strip())
    return tuple({key: row.get(key) for key in LABEL_FIELDS} for row in rows)


def _checked(row: Mapping) -> dict:
    """A copy of one label row with its first bad event in local time; raises ValueError naming the account."""
    acct, role = row.get('acct_id'), row.get('role')
    if not isinstance(acct, str) or not acct:
        raise ValueError(f'label row without acct_id: {dict(row)!r}')
    if role not in FRAUD_ROLES and role != VICTIM_ROLE:
        raise ValueError(f'{acct}: unknown role {role!r}')
    if role == VICTIM_ROLE:
        return dict(row)
    first_bad = row.get('first_bad_ts')
    if not isinstance(first_bad, str) or not first_bad:
        raise ValueError(f'{acct}: {role} without first_bad_ts')
    return {**row, 'first_bad_ts': to_local(first_bad)}


def _checked_lag(lag_days) -> int:
    if isinstance(lag_days, bool) or not isinstance(lag_days, int) or lag_days < 0:
        raise ValueError(f'lag_days must be a nonnegative integer, got {lag_days!r}')
    return lag_days


def confirmed_mules(labels: Iterable[Mapping], as_of: str, lag_days: int = CONFIRMATION_LAG_DAYS) -> frozenset[str]:
    """Accounts an analyst would have confirmed as fraud by `as_of` (read in Dhaka time): the seeds. Never a victim."""
    lag_days = _checked_lag(lag_days)
    rows = tuple(_checked(row) for row in labels)
    # confirmed_fraud reads only `.labels` of its bundle argument
    return frozenset(confirmed_fraud(SimpleNamespace(labels=rows), to_local(as_of), lag_days))


def confirmed_mules_over_time(labels: Iterable[Mapping], lag_days: int = CONFIRMATION_LAG_DAYS
                              ) -> Callable[[str], frozenset[str]]:
    """`confirmed_mules(labels, ts, lag_days)` as a function of `ts`, for a replay that asks at thousands of checks.

    The rows are checked once; each answer is the mule rows whose first bad event is strictly before
    `confirmed_before(ts)`, the same comparison as the synth's `confirmed_fraud`, found by bisection and shared."""
    lag_days = _checked_lag(lag_days)
    mules = sorted((row['first_bad_ts'], row['acct_id']) for row in map(_checked, labels) if row['role'] in FRAUD_ROLES)
    firsts = tuple(first for first, _acct in mules)
    answers: dict[int, frozenset[str]] = {}

    def seeds_at(as_of: str) -> frozenset[str]:
        n = bisect_left(firsts, confirmed_before(to_local(as_of), lag_days))
        if n not in answers:
            answers[n] = frozenset(acct for _first, acct in mules[:n])
        return answers[n]
    return seeds_at
