"""Markdown for the cash-out evaluation: tables rendered from the JSON report, nothing recomputed."""
from __future__ import annotations

from collections.abc import Callable

TITLE = '# Common point of cash-out: rolling evaluation against the labels'


def cell(value) -> str:
    """None is n/a; whole floats print as integers, other floats to four significant figures."""
    if value is None:
        return 'n/a'
    if isinstance(value, float):
        return str(int(value)) if value.is_integer() else f'{value:.4g}'
    return str(value)


def _of(numerator, denominator, ratio) -> str:
    return f'{numerator} / {denominator} = {cell(ratio)}'


def _mean(spread: dict | None) -> str:
    return cell(spread['mean']) if spread else 'n/a (no true candidate)'


def _median(spread: dict | None) -> str:
    if not spread:
        return 'n/a (no true candidate)'
    return f"{cell(spread['median'])} ({cell(spread['min'])} to {cell(spread['max'])})"


def _flags(s: dict) -> dict:
    return s['till_flags']


SUMMARY_ROWS: tuple[tuple[str, Callable[[dict], str]], ...] = (
    ('Daily runs (as of 00:00)', lambda s: f"{s['days_run']} ({s['first_day'][:10]} to {s['last_day'][:10]})"),
    ('Cash-outs located; labelled mules', lambda s: f"{s['cashouts']}; {s['mules']}"),
    ('Till flags per day: mean (max); days with a flag', lambda s: f"{cell(_flags(s)['per_day'])} ({_flags(s)['max_per_day']}); "
                                                               f"{_flags(s)['days_with_a_flag']}"),
    ('Distinct tills ever flagged', lambda s: str(_flags(s)['distinct_tills'])),
    ('Till-flag precision: a not-yet-confirmed mule cashed out there in the next 7 days (scored days)',
     lambda s: _of(_flags(s)['right'], _flags(s)['scored_till_days'], _flags(s)['precision'])
     + f" over {_flags(s)['scored_days']} days"),
    ('Base rate: any open till on the same days, same test', lambda s: cell(_flags(s)['base_rate'])),
    ('Live circle clusters (seeds as of each check)', lambda s: str(s['live_clusters'])),
    ('Replayed circle clusters (seeds as of each day): clusters (distinct events)',
     lambda s: f"{s['replayed_clusters']['clusters']} ({s['replayed_clusters']['events']})"),
)

# One candidate filter's measures: (label, render(the filter's measures, the world summary)).
FILTER_ROWS: tuple[tuple[str, Callable[[dict, dict], str]], ...] = (
    ('Candidates (distinct accounts, counted on their first day)', lambda f, s: str(f['candidates']['total'])),
    ('Candidate precision: a labelled non-victim ring member',
     lambda f, s: _of(f['candidates']['true'], f['candidates']['total'], f['candidates']['precision'])),
    ('False candidates per week', lambda f, s: f"{cell(f['candidates']['false_per_week'])} ({f['candidates']['false']} in "
                                               f"{s['days_run']} days)"),
    ('Lead time to the account\'s own confirmation, days: mean', lambda f, s: _mean(f['candidates']['lead_days'])),
    ('Lead time, days: median (min to max)', lambda f, s: _median(f['candidates']['lead_days'])),
    ('Recall of the lead: caught before confirmation / mules not yet confirmed at the first run',
     lambda f, s: _of(f['recall_of_the_lead']['caught'], f['recall_of_the_lead']['future_confirmed_mules'],
                      f['recall_of_the_lead']['recall'])),
    ('... of those that cashed out at a till before confirmation',
     lambda f, s: _of(f['recall_of_the_lead']['caught'], f['recall_of_the_lead']['cashed_out_before_confirmation'],
                      f['recall_of_the_lead']['recall_of_reachable'])),
    ('Held back by this filter, never its candidate: accounts (mules / victims / unlabelled)',
     lambda f, s: f"{f['held_back']['accounts']} ({f['held_back']['mules']} / {f['held_back']['victims']} / "
                  f"{f['held_back']['unlabelled']})"),
    ('... most first-time senders; most new counterparties, among them',
     lambda f, s: f"{cell(f['held_back']['most_first_time_senders'])}; {cell(f['held_back']['most_new_counterparties'])}"),
)


def _summary_lines(worlds: list[dict]) -> list[str]:
    lines = ['| Measure | ' + ' | '.join(w['world'] for w in worlds) + ' |', '|---|' + '---|' * len(worlds)]
    for label, render in SUMMARY_ROWS:
        values = (render(w['summary']) if w['status'] == 'run' else 'missing: ' + '; '.join(w['missing']) for w in worlds)
        lines.append(f'| {label} | ' + ' | '.join(values) + ' |')
    return lines


def _filter_definitions(config: dict) -> list[str]:
    return [f"- first_time_senders (segment 3): at least {cell(config.get('CANDIDATE_MIN_FIRST_TIME_SENDERS'))} distinct "
            f"senders paying in for the first time in the {cell(config.get('CANDIDATE_LOOKBACK_HOURS'))} hours before the "
            'cash-out.',
            '- pass_through (segment 3b, added after the first filter named no candidate): money in from at least '
            f"{cell(config.get('PASS_THROUGH_MIN_NEW_COUNTERPARTIES'))} counterparty the account had not dealt with in "
            f"{cell(config.get('PASS_THROUGH_NEW_DAYS'))} days, and its cash-outs at least "
            f"{cell(config.get('PASS_THROUGH_MIN_SHARE'))} of everything paid in over the same hours. Its constants were "
            'fixed before its own measurement.', '']


def _filter_lines(world: dict) -> list[str]:
    filters = world['summary']['filters']
    lines = [f"### {world['world']}", '', '| Measure | ' + ' | '.join(filters) + ' |', '|---|' + '---|' * len(filters)]
    lines += [f'| {label} | ' + ' | '.join(render(f, world['summary']) for f in filters.values()) + ' |'
              for label, render in FILTER_ROWS]
    return lines + ['']


def _notes(worlds: list[dict]) -> list[str]:
    """One plain sentence per world and filter that named no candidate: what that filter held back."""
    notes = []
    for w in (w for w in worlds if w['status'] == 'run'):
        for name, f in w['summary']['filters'].items():
            if f['candidates']['total']:
                continue
            held = f['held_back']
            notes.append(f"- {w['world']}, {name}: no candidate on any day. The till flags and live clusters held "
                         f"{held['accounts']} non-seed accounts, {held['mules']} of them mules not yet confirmed; the most "
                         f"first-time senders any had was {cell(held['most_first_time_senders'])} and the most new "
                         f"counterparties {cell(held['most_new_counterparties'])}.")
    return notes + [''] if notes else []


def _pair(counts: dict, true_counts: dict) -> str:
    return ' / '.join(f'{n} ({true_counts.get(name, 0)})' for name, n in counts.items())


def _day_lines(world: dict) -> list[str]:
    lines = [f"### Per day: {world['world']}", '',
             '| Day (as of 00:00) | Seeds | Open tills | Till flags | Right (next 7 days) | Scored | Open tills right | '
             'New candidates (true): first-time senders / pass-through | Live clusters | Replayed clusters (new) |',
             '|---|---|---|---|---|---|---|---|---|---|']
    lines += [f"| {d['as_of'][:10]} | {d['seeds']} | {d['open_tills']} | {d['till_flags']} | {d['right']} | "
              f"{'yes' if d['scored'] else 'no'} | {d['open_tills_right']} | "
              f"{_pair(d['new_candidates'], d['new_true_candidates'])} | {d['live_clusters']} | "
              f"{d['replayed_clusters']} ({d['new_replayed_clusters']}) |" for d in world['days']]
    return lines + ['']


def _candidate_lines(worlds: list[dict]) -> list[str]:
    rows = [(w['world'], c) for w in worlds for c in w['candidates']]
    if not rows:
        return ['No candidate in any world under either filter.', '']
    lines = ['| World | Filter | Account | First day | Source | Till | First-time senders | New counterparties | '
             'In / cashed out BDT (lookback) | Label | Roles / rings | Confirmed | Lead days |',
             '|---|---|---|---|---|---|---|---|---|---|---|---|---|']
    lines += [f"| {world} | {c['filter']} | {c['acct']} | {c['first_day'][:10]} | {c['source']} | {c['till']} | "
              f"{c['first_time_senders']} | {c['new_counterparties']} | {cell(c['received_bdt'])} / "
              f"{cell(c['cashed_out_bdt'])} | {c['labelled']} | {', '.join(c['roles'] + c['rings']) or '-'} | "
              f"{c['confirmed_at'] or '-'} | {cell(c['lead_days'])} |" for world, c in rows]
    return lines + ['']


def _cluster_lines(worlds: list[dict], key: str, none: str) -> list[str]:
    rows = [(w['world'], c) for w in worlds for c in w[key]]
    if not rows:
        return [none, '']
    lines = ['| World | Cluster | First day | Opened | District | Cash-outs (expected, p) | Seeds | Others: mules / victims / '
             'unlabelled | Rings | Candidates (true): first-time senders / pass-through | Same event as an earlier '
             'cluster |', '|---|---|---|---|---|---|---|---|---|---|---|']
    lines += [f"| {world} | {c['cluster_id']} | {c['first_day'][:10]} | {c['opened_at']} | {', '.join(c['districts'])} | "
              f"{c['observed']} ({cell(c['expected'])}, {cell(c['p_value'])}) | {c['seed_accounts']} | {c['other_mules']} / "
              f"{c['other_victims']} / {c['other_unlabelled']} | {', '.join(c['rings']) or '-'} | "
              f"{_pair(c['candidates'], c['true_candidates'])} | "
              f"{'yes' if c['same_event_as_an_earlier_cluster'] else 'no'} |" for world, c in rows]
    return lines + ['']


def markdown(report: dict) -> str:
    worlds = report['worlds']
    ran = [w for w in worlds if w['status'] == 'run']
    lines = [TITLE, '', report['caveat'], '', '## Summary', ''] + _summary_lines(worlds) + ['']
    lines += ['## Candidate filters side by side', ''] + _filter_definitions(report['config'])
    lines += [line for w in ran for line in _filter_lines(w)] + _notes(worlds)
    lines += ['## Candidates', ''] + _candidate_lines(ran)
    lines += ['## Replayed clusters (seeds known at each day boundary)', '']
    lines += _cluster_lines(ran, 'replayed_clusters', 'No replayed cluster in any world.')
    lines += ['## Live clusters (seeds as of each check)', '']
    lines += _cluster_lines(ran, 'live_clusters', 'No live cluster in any world: the confirmation lag.')
    lines += ['## Per day', ''] + [line for w in ran for line in _day_lines(w)]
    constants = ', '.join(f'{name} {cell(value)}' for name, value in report['config'].items())
    lines += ['## Constants', '', constants + '.', '', f"Generated {report['generated_at']}.", '']
    return '\n'.join(lines)
