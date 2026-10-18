"""Rolling evaluation of the common point of cash-out against the labels; exit 0 run, 2 a world is missing data.

At every day boundary (00:00, Dhaka time) the rules run as of that instant with the mules confirmed by then
(`run_cashout`, seeds as of each check), and the circle is replayed over the days already past with the seeds known at
the boundary. Till flags are scored per day, candidates once per filter on the first day that filter names them: the
first-time-sender filter and the pass-through filter are measured side by side with the same measures.
This module and `cashout_seeds.py` are the only readers of `labels.jsonl` for the cash-out rules; the rules see
observable tables only.

    python eval/cashout_eval.py                       # both worlds -> ../../eval/results/cashout.json, .md
    python eval/cashout_eval.py --seed-dir ../../data/seed-campaign --out /tmp/cashout.json
"""
from __future__ import annotations

import argparse
from collections.abc import Iterable, Mapping
from dataclasses import asdict, dataclass
from datetime import UTC, datetime, timedelta
import json
from pathlib import Path
import statistics
import sys

RADAR = Path(__file__).resolve().parents[1]
PROJECT = RADAR.parents[1]  # the repository root
sys.path.insert(0, str(RADAR))
sys.path.insert(0, str(RADAR/'eval'))
sys.path.append(str(PROJECT/'libs'/'synth'))

from bhorosha_graph.features import FRAUD_ROLES  # noqa: E402
from bhorosha_radar import config  # noqa: E402
from bhorosha_radar.cashout import CashOut, scan_cashouts  # noqa: E402
from bhorosha_radar.cashout_rules import (FILTERS, OUTPUT_CONSTANTS, TillBaseline, candidates,  # noqa: E402
                                          read_tills, run_cashout, space_time_clusters)
from bhorosha_radar.cashout_seeds import confirmed_mules_over_time  # noqa: E402
from bhorosha_radar.stream import to_local  # noqa: E402
from cashout_report import markdown  # noqa: E402
from radar_eval import load_observable_bundle  # noqa: E402

HORIZON_DAYS = 7  # a flagged till is right when a not-yet-confirmed mule cashes out there within the following week
DAYS_PER_WEEK = 7
WORLDS = (PROJECT/'data'/'seed-campaign', PROJECT/'data'/'seed')
DEFAULT_OUT = PROJECT/'eval'/'results'/'cashout.json'
LABEL_FIELDS = ('acct_id', 'role', 'ring_id', 'typology', 'first_bad_ts')
REQUIRED_FILES = ('transactions.jsonl', 'agents.jsonl', 'labels.jsonl')
MULE, VICTIM, UNLABELLED = 'mule', 'victim', 'unlabelled'
DAY = timedelta(days=1)


@dataclass(frozen=True)
class Truth:
    mules: frozenset[str]  # accounts with a non-victim label row: mules, purchased mules, controllers, cash-out agents
    victims: frozenset[str]  # accounts whose only label rows are victim rows
    confirmed_at: Mapping[str, str]  # mule -> the instant after which it is a seed (first bad event plus the lag)
    rings: Mapping[str, tuple[str, ...]]  # labelled account -> its ring ids
    roles: Mapping[str, tuple[str, ...]]  # labelled account -> its roles


def _shift(ts: str, **delta: float) -> str:
    return (datetime.fromisoformat(ts) + timedelta(**delta)).isoformat(timespec='seconds')


def read_truth(seed_dir: Path) -> tuple[tuple[dict, ...], Truth]:
    """(label rows cut to LABEL_FIELDS, the truth the scores use). An account is a seed for `as_of` strictly after its
    earliest non-victim first bad event plus CONFIRMATION_LAG_DAYS: `confirmed_mules`' rule, so the two agree."""
    lines = (seed_dir/'labels.jsonl').read_text(encoding='utf-8').splitlines()
    parsed = (json.loads(line) for line in lines if line.strip())
    rows = tuple({key: row.get(key) for key in LABEL_FIELDS} for row in parsed)
    first_bad: dict[str, str] = {}
    for r in (r for r in rows if r['role'] in FRAUD_ROLES):
        if not isinstance(r['first_bad_ts'], str) or not r['first_bad_ts']:
            raise ValueError(f"{r['acct_id']}: {r['role']} without first_bad_ts")
        first = to_local(r['first_bad_ts'])
        first_bad[r['acct_id']] = min(first, first_bad.get(r['acct_id'], first))
    mules = frozenset(first_bad)

    def grouped(field: str) -> dict[str, tuple[str, ...]]:
        values: dict[str, set[str]] = {}
        for r in rows:
            values.setdefault(r['acct_id'], set()).update({r[field]} if r[field] else set())
        return {acct: tuple(sorted(found)) for acct, found in values.items()}
    return rows, Truth(mules=mules, victims=frozenset(r['acct_id'] for r in rows) - mules,
                       confirmed_at={a: _shift(t, days=config.CONFIRMATION_LAG_DAYS) for a, t in first_bad.items()},
                       rings=grouped('ring_id'), roles=grouped('role'))


def labelled(acct: str, truth: Truth) -> str:
    return MULE if acct in truth.mules else VICTIM if acct in truth.victims else UNLABELLED


# --- the scoring rules -------------------------------------------------------------------------------------------

def day_boundaries(events: tuple[CashOut, ...]) -> tuple[str, ...]:
    """Every midnight after the first cash-out's day, through the midnight that ends the last cash-out's day."""
    first = datetime.fromisoformat(events[0].ts[:10]) + DAY
    last = datetime.fromisoformat(events[-1].ts[:10]) + DAY
    return tuple((first + i * DAY).isoformat(timespec='seconds') for i in range((last - first).days + 1))


def right_tills(events: Iterable[CashOut], truth: Truth, as_of: str, seeds: frozenset[str],
                horizon_days: int = HORIZON_DAYS) -> frozenset[str]:
    """Tills where a labelled mule that is not a seed at `as_of` cashed out in `(as_of, as_of + horizon]`."""
    end = _shift(as_of, days=horizon_days)
    return frozenset(e.till for e in events if as_of < e.ts <= end and e.acct in truth.mules and e.acct not in seeds)


def first_candidates(runs: Iterable[Mapping], candidate_filter: str | None = None) -> tuple[dict, ...]:
    """Each candidate account once, on the first daily run that lists it, with that run's lead; only the leads of
    `candidate_filter` when one is given."""
    seen: dict[str, dict] = {}
    for run in runs:
        for c in run['candidates']:
            if candidate_filter is None or c.get('filter') == candidate_filter:
                seen.setdefault(c['acct'], {**c, 'first_day': run['as_of']})
    return tuple(seen.values())


def lead_days(confirmed_at: str, first_day: str) -> float:
    """Days from the first daily run that named the account to the account's own confirmation."""
    return (datetime.fromisoformat(confirmed_at) - datetime.fromisoformat(first_day)) / DAY


def _ratio(numerator: int | float, denominator: int | float) -> float | None:
    return numerator / denominator if denominator else None


def _spread(values: list[float]) -> dict | None:
    if not values:
        return None
    return dict(min=min(values), median=statistics.median(values), mean=statistics.fmean(values), max=max(values))


# --- one day -----------------------------------------------------------------------------------------------------

def _replay(bundle, past: tuple[CashOut, ...], as_of: str, seeds: frozenset[str]) -> tuple[dict, ...]:
    """The circle over every cash-out up to `as_of`, with the seeds known at `as_of` standing for every check."""
    if not past:
        return ()
    baseline = TillBaseline(past, read_tills(bundle, as_of), start=past[0].ts, end=as_of)
    clusters = space_time_clusters(past, lambda _ts: seeds, baseline)
    leads = (tuple(candidates(c, past, seeds, bundle.txns_by_acct, candidate_filter=name) for name in FILTERS)
             for c in clusters)
    return tuple(dict(asdict(c), candidates=[asdict(x) for found, _held in pairs for x in found],
                      not_flagged=[asdict(x) for _found, held in pairs for x in held])
                 for c, pairs in zip(clusters, leads))


def daily_run(bundle, events: tuple[CashOut, ...], as_of: str, seeds_at) -> dict:
    out = run_cashout(bundle, as_of, seeds_at)
    seeds = seeds_at(as_of)
    return dict(as_of=as_of, seeds=seeds, open_tills=tuple(t['till'] for t in out['tills']),
                till_flags=tuple(f['till'] for f in out['till_flags']), flag_rows=out['till_flags'],
                candidates=out['candidates'], not_flagged=out['not_flagged'], live_clusters=out['clusters'],
                replayed=_replay(bundle, tuple(e for e in events if e.ts <= as_of), as_of, seeds))


# --- the world ---------------------------------------------------------------------------------------------------

def _by_filter(leads: Iterable[Mapping], truth: Truth) -> tuple[dict[str, int], dict[str, int]]:
    """(leads, labelled-mule leads) per candidate filter."""
    leads = tuple(leads)
    return ({name: sum(x['filter'] == name for x in leads) for name in FILTERS},
            {name: sum(x['filter'] == name and x['acct'] in truth.mules for x in leads) for name in FILTERS})


def _day_rows(runs, events, truth, last_day) -> list[dict]:
    rows, named, replayed = [], set(), set()
    for run in runs:
        right = right_tills(events, truth, run['as_of'], run['seeds'])
        new = {(c['acct'], c['filter']): c for c in run['candidates'] if (c['acct'], c['filter']) not in named}
        named |= set(new)
        new_by_filter, new_true_by_filter = _by_filter(new.values(), truth)
        new_replayed = [c['cluster_id'] for c in run['replayed'] if c['cluster_id'] not in replayed]
        replayed |= set(new_replayed)
        rows.append(dict(as_of=run['as_of'], seeds=len(run['seeds']), open_tills=len(run['open_tills']),
                         open_tills_right=len(right & set(run['open_tills'])), till_flags=len(run['till_flags']),
                         flagged_tills=list(run['till_flags']), right=len(right & set(run['till_flags'])),
                         scored=_shift(run['as_of'], days=HORIZON_DAYS) <= last_day, new_candidates=new_by_filter,
                         new_true_candidates=new_true_by_filter, live_clusters=len(run['live_clusters']),
                         replayed_clusters=len(run['replayed']), new_replayed_clusters=len(new_replayed)))
    return rows


def _flag_summary(days: list[dict]) -> dict:
    scored = [d for d in days if d['scored']]
    flagged, right = sum(d['till_flags'] for d in scored), sum(d['right'] for d in scored)
    return dict(per_day=_ratio(sum(d['till_flags'] for d in days), len(days)), max_per_day=max(d['till_flags'] for d in days),
                days_with_a_flag=sum(d['till_flags'] > 0 for d in days),
                distinct_tills=len({t for d in days for t in d['flagged_tills']}), scored_days=len(scored),
                scored_till_days=flagged, right=right, precision=_ratio(right, flagged),
                base_rate=_ratio(sum(d['open_tills_right'] for d in scored), sum(d['open_tills'] for d in scored)))


def _candidate_rows(runs, truth, candidate_filter: str) -> list[dict]:
    rows = []
    for c in first_candidates(runs, candidate_filter):
        kind = labelled(c['acct'], truth)
        lead = lead_days(truth.confirmed_at[c['acct']], c['first_day']) if kind == MULE else None
        rows.append(dict(acct=c['acct'], filter=candidate_filter, first_day=c['first_day'], source=c['source'],
                         till=c['till'], ts=c['ts'], amount_bdt=c['amount_bdt'],
                         first_time_senders=c['first_time_senders'], new_counterparties=c['new_counterparties'],
                         received_bdt=c['received_bdt'], cashed_out_bdt=c['cashed_out_bdt'], labelled=kind,
                         roles=list(truth.roles.get(c['acct'], ())), rings=list(truth.rings.get(c['acct'], ())),
                         confirmed_at=truth.confirmed_at.get(c['acct']), lead_days=lead))
    return rows


def _recall(candidate_rows, events, truth, first_day) -> dict:
    """Mules not yet seeds at the first daily run, the ones that cashed out at a till before confirmation (all the rule
    can see), and the ones named as candidates before their confirmation."""
    future = {m for m in truth.mules if truth.confirmed_at[m] >= first_day}
    reachable = {e.acct for e in events if e.acct in future and e.ts < truth.confirmed_at[e.acct]}
    caught = {c['acct'] for c in candidate_rows if c['acct'] in future and c['lead_days'] and c['lead_days'] > 0}
    return dict(future_confirmed_mules=len(future), cashed_out_before_confirmation=len(reachable), caught=len(caught),
                recall=_ratio(len(caught), len(future)), recall_of_reachable=_ratio(len(caught), len(reachable)))


def _held_back(runs, truth, named: set[str], candidate_filter: str) -> dict:
    """Accounts a daily run listed inside a till flag or live cluster but held back by `candidate_filter` on every day,
    never its candidate: by label (a held mule is one not yet confirmed that day), and the most first-time senders and
    new counterparties shown by any of their held cash-outs."""
    senders: dict[str, int] = {}
    counterparties: dict[str, int] = {}
    for run in runs:
        for n in (n for n in run['not_flagged'] if n['filter'] == candidate_filter):
            senders[n['acct']] = max(senders.get(n['acct'], 0), n['first_time_senders'])
            counterparties[n['acct']] = max(counterparties.get(n['acct'], 0), n['new_counterparties'])
    held = [acct for acct in senders if acct not in named]
    kinds = [labelled(acct, truth) for acct in held]
    return dict(accounts=len(held), mules=kinds.count(MULE), victims=kinds.count(VICTIM),
                unlabelled=kinds.count(UNLABELLED),
                most_first_time_senders=max((senders[a] for a in held), default=None),
                most_new_counterparties=max((counterparties[a] for a in held), default=None))


def _filter_summary(runs, events, truth, first_day: str, candidate_filter: str) -> tuple[dict, list[dict]]:
    """One candidate filter's measures over the daily runs, and its candidate rows."""
    found = _candidate_rows(runs, truth, candidate_filter)
    false = sum(c['labelled'] != MULE for c in found)
    summary = dict(candidates=dict(total=len(found), true=len(found) - false, false=false,
                                   precision=_ratio(len(found) - false, len(found)),
                                   false_per_week=_ratio(false, len(runs) / DAYS_PER_WEEK),
                                   lead_days=_spread([c['lead_days'] for c in found if c['lead_days'] is not None])),
                   held_back=_held_back(runs, truth, {c['acct'] for c in found}, candidate_filter),
                   recall_of_the_lead=_recall(found, events, truth, first_day))
    return summary, found


def _cluster_rows(clusters: Iterable[tuple[str, dict]], by_txn: Mapping[str, CashOut], seeds_at, truth) -> list[dict]:
    """What each distinct cluster held, from the day it was first seen: seeds, the other accounts by label, rings."""
    rows, events = [], []
    for day, c in clusters:
        txns = set(c['all_cashouts'])
        accts, seeds = {by_txn[t].acct for t in txns}, seeds_at(day)
        others = sorted(accts - seeds)
        overlap = next((i for i, earlier in enumerate(events) if earlier & txns), None)
        events = events + [txns] if overlap is None else [e | txns if i == overlap else e for i, e in enumerate(events)]
        found, true_found = _by_filter(c.get('candidates', []), truth)
        rows.append(dict(cluster_id=c['cluster_id'], first_day=day, opened_at=c['opened_at'], observed=c['observed'],
                         expected=c['expected'], p_value=c['p_value'],
                         districts=sorted({by_txn[t].district for t in txns if by_txn[t].district}),
                         seed_accounts=len(accts & seeds), other_accounts=len(others),
                         other_mules=sum(labelled(a, truth) == MULE for a in others),
                         other_victims=sum(labelled(a, truth) == VICTIM for a in others),
                         other_unlabelled=sum(labelled(a, truth) == UNLABELLED for a in others),
                         rings=sorted({r for a in accts for r in truth.rings.get(a, ())}),
                         candidates=found, true_candidates=true_found,
                         same_event_as_an_earlier_cluster=overlap is not None))
    return rows


def _distinct(runs, key: str) -> list[tuple[str, dict]]:
    seen: dict[str, tuple[str, dict]] = {}
    for run in runs:
        for c in run[key]:
            seen.setdefault(c['cluster_id'], (run['as_of'], c))
    return list(seen.values())


def _world_name(seed_dir: Path) -> str:
    """The world's name in reports: the generator's underscore form (seed_campaign), whatever the directory is called."""
    return seed_dir.name.replace('-', '_')


def _missing(seed_dir: Path) -> list[str]:
    return [f'missing {name}' for name in REQUIRED_FILES if not (seed_dir/name).exists()]


def evaluate_world(seed_dir: Path) -> dict:
    """The daily runs over one world and every measure; `status` is 'missing' (with reasons) when it cannot run."""
    checksum = seed_dir/'CHECKSUM'
    base = dict(world=_world_name(seed_dir), seed_checksum=checksum.read_text().strip() if checksum.exists() else None,
                status='missing', missing=_missing(seed_dir), summary=None, days=[], candidates=[], live_clusters=[],
                replayed_clusters=[])
    if base['missing']:
        return base
    bundle, (rows, truth) = load_observable_bundle(seed_dir), read_truth(seed_dir)
    events = scan_cashouts(bundle).events
    missing = (['no located cash-out'] if not events else []) + (['no labelled mule'] if not truth.mules else [])
    if missing:
        return {**base, 'missing': missing}
    seeds_at = confirmed_mules_over_time(rows)
    boundaries = day_boundaries(events)
    runs = tuple(daily_run(bundle, events, day, seeds_at) for day in boundaries)
    days = _day_rows(runs, events, truth, boundaries[-1])
    measured = {name: _filter_summary(runs, events, truth, boundaries[0], name) for name in FILTERS}
    by_txn = {e.txn_id: e for e in events}
    live = _cluster_rows(_distinct(runs, 'live_clusters'), by_txn, seeds_at, truth)
    replayed = _cluster_rows(_distinct(runs, 'replayed'), by_txn, seeds_at, truth)
    summary = dict(days_run=len(runs), first_day=boundaries[0], last_day=boundaries[-1], cashouts=len(events),
                   mules=len(truth.mules), till_flags=_flag_summary(days),
                   filters={name: measures for name, (measures, _rows) in measured.items()},
                   live_clusters=len(live),
                   replayed_clusters=dict(clusters=len(replayed),
                                          events=sum(not c['same_event_as_an_earlier_cluster'] for c in replayed)))
    found = [row for _measures, rows in measured.values() for row in rows]
    return {**base, 'status': 'run', 'summary': summary, 'days': days, 'candidates': found, 'live_clusters': live,
            'replayed_clusters': replayed}


CAVEAT = ('Synthetic worlds our own generator wrote (seed_campaign: the seed-42 world plus three call-centre campaigns; '
          'seed: the demo world): every till, cash-out and account is generated, and no number here is a field result. '
          'A candidate is a lead for an analyst to review, never a verdict or a block. A till flag says only that more '
          f'confirmed mules cashed out at that till in the last {config.TILL_REUSE_DAYS} days than its own volume '
          'predicts at the network-wide share of seeds (at least TILL_REUSE_MIN_SEEDS of them and a Poisson tail at most '
          'TILL_REUSE_P_THRESHOLD): a place to look, not a finding about the agent who runs it. A seed is a mule an '
          f'analyst confirmed {config.CONFIRMATION_LAG_DAYS} days after its first bad event, while a ring empties its '
          f'mules within hours: that confirmation lag is why the live {config.CLUSTER_WINDOW_MIN}-minute circle, which '
          f'needs {config.CLUSTER_MIN_SEEDS} confirmed mules inside it as it happens, does not fire; the replayed circle '
          'uses the seeds known at each day boundary to look back at days already past. Till-flag precision counts only '
          f'days whose {HORIZON_DAYS}-day horizon ends inside the world, beside the base rate of any open till on the '
          'same days. The labels are read only by this evaluation and cashout_seeds.py. The Poisson tails assume no '
          'over-dispersion, so p-values may be optimistic. For hours in the first week of cash-outs (every till\'s '
          'first week here: all opened before it) the baseline borrows the following weeks (reported as '
          'baseline_source: backfill), so a p-value in the first week is not strictly as of the moment; none of the '
          'reported clusters falls in a first week. Two candidate filters are measured side by side. The '
          'first-time-sender filter (at least CANDIDATE_MIN_FIRST_TIME_SENDERS strangers paying in during the day before '
          'the cash-out) was set before any of these numbers and, in its first measurement, named no candidate on either world. The '
          'pass-through '
          'filter was added after that, because the first filter produced no candidates: money in from at least '
          f'{config.PASS_THROUGH_MIN_NEW_COUNTERPARTIES} counterparty the account had not dealt with in '
          f'{config.PASS_THROUGH_NEW_DAYS} days, and cash-outs at least {config.PASS_THROUGH_MIN_SHARE:.0%} of everything '
          f'paid in over the same {config.CANDIDATE_LOOKBACK_HOURS} hours. Its constants were fixed in config.py before '
          'its own measurement and were not tuned on these numbers, but the decision to add a filter at all followed a '
          'result. Both worlds are one synthetic world: seed_campaign is the demo seed plus three campaigns, so the two '
          'columns are not independent replications, and one synthetic world is not evidence that either filter works '
          'on a real ledger.')


def _guarded(seed_dir: Path) -> dict:
    """evaluate_world, with an unreadable or malformed input reported as missing for that world, never a crash."""
    try:
        return evaluate_world(seed_dir)
    except (OSError, ValueError, KeyError, TypeError) as exc:
        return dict(world=_world_name(seed_dir), seed_checksum=None, status='missing', summary=None, days=[], candidates=[],
                    live_clusters=[], replayed_clusters=[],
                    missing=[f'input could not be evaluated: {type(exc).__name__}: {exc}'])


def report(seed_dirs: Iterable[Path]) -> dict:
    return dict(generated_at=datetime.now(UTC).isoformat(timespec='seconds'), module='common point of cash-out',
                config={**{name: getattr(config, name) for name in OUTPUT_CONSTANTS}, 'HORIZON_DAYS': HORIZON_DAYS},
                caveat=CAVEAT, worlds=[_guarded(d) for d in seed_dirs])


def write(result: dict, output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2, allow_nan=False) + '\n', encoding='utf-8')
    output.with_suffix('.md').write_text(markdown(result), encoding='utf-8')


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--seed-dir', type=Path, action='append', help='a world to evaluate; repeat for more '
                        '(default: data/seed-campaign and data/seed)')
    parser.add_argument('--out', type=Path, default=DEFAULT_OUT)
    args = parser.parse_args(argv)
    result = report(args.seed_dir or WORLDS)
    write(result, args.out)
    sys.stdout.write(markdown(result))
    return 2 if any(w['status'] != 'run' for w in result['worlds']) else 0


if __name__ == '__main__':
    sys.exit(main())
