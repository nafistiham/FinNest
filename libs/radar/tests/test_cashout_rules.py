"""Till reuse against each till's own volume and space-time clusters seeded by confirmed
mules, the two candidate filters side by side (first-time senders, pass-through), the output."""
from dataclasses import asdict
from datetime import datetime, timedelta
import hashlib
import json
import math
from pathlib import Path
import random

import pytest

from bhorosha_radar import config
from bhorosha_radar.cashout import CashOut
from bhorosha_radar.cashout_rules import (FILTER_FIRST_TIME_SENDERS, FILTER_PASS_THROUGH, FILTERS,
                                          REASON_FEW_FIRST_TIME_SENDERS, REASON_LOW_PASS_THROUGH_SHARE,
                                          REASON_NO_NEW_COUNTERPARTY, SOURCE_TILL_REUSE, Candidate, Cluster, NotFlagged,
                                          PassThrough, Till, TillBaseline, TillFlag, candidates, first_time_senders,
                                          is_pass_through, pass_through, run_cashout, space_time_clusters, till_reuse)
from bhorosha_radar.geo import haversine_km
from bhorosha_radar.surprise import poisson_tail

SEED = Path(__file__).resolve().parents[3]/'data'/'seed-campaign'
KM_PER_DEGREE_LAT = math.pi * config.EARTH_RADIUS_KM / 180
DHAKA = (23.8103, 90.4125)


def place(name, km_north=0.0, km_east=0.0, since='2026-01-01T00:00:00'):
    lat = DHAKA[0] + km_north / KM_PER_DEGREE_LAT
    lon = DHAKA[1] + km_east / (KM_PER_DEGREE_LAT * math.cos(math.radians(lat)))
    return Till(till=name, lat=lat, lon=lon, district='Dhaka', since=since)


def co(txn_id, ts, acct, till, amount=3000.0):
    return CashOut(txn_id=txn_id, ts=ts, acct=acct, till=till.till, amount_bdt=amount, lat=till.lat, lon=till.lon,
                   district=till.district)


def at(ts, **delta):
    return (datetime.fromisoformat(ts) + timedelta(**delta)).isoformat(timespec='seconds')


def always(*accts):
    seeds = frozenset(accts)
    return lambda ts: seeds


def confirmed(**times):
    """Seeds by confirmation time: an account is a seed at `ts` once its time is at or before `ts`."""
    return lambda ts: frozenset(acct for acct, when in times.items() if when <= ts)


def pay(txn_id, ts, sender, payee, kind='send_money'):
    return dict(txn_id=txn_id, ts=ts, type=kind, from_acct=sender, to_acct=payee, amount_bdt=1000.0)


def by_acct(rows):
    """Like the observable bundle: every transaction filed under both of its accounts."""
    grouped = {}
    for row in rows:
        for acct in {row['from_acct'], row['to_acct']}:
            grouped.setdefault(acct, []).append(row)
    return {acct: tuple(sorted(items, key=lambda r: r['ts'])) for acct, items in grouped.items()}


# --- first-time senders ------------------------------------------------------------------------------------------

CASH_OUT_AT = '2026-10-20T12:00:00'
INFLOW = (
    pay('p1', '2026-10-20T08:00:00', 's1', 'm'),
    pay('p2', '2026-10-20T09:00:00', 's1', 'm'),  # the same sender twice is one sender
    pay('p3', '2026-10-20T10:00:00', 's2', 'm'),
    pay('p4', '2026-10-20T11:59:59', 's3', 'm'),
    pay('p5', '2026-10-20T11:00:00', 'old', 'm'),  # paid m four days ago: not first-time
    pay('p6', '2026-10-16T11:00:00', 'old', 'm'),
    pay('p7', '2026-10-19T11:59:59', 'early', 'm'),  # 24 h and one second before: outside the lookback
    pay('p8', '2026-10-20T12:00:00', 'same_second', 'm'),  # at the cash-out itself: not before it
    pay('p9', '2026-10-20T12:30:00', 'later', 'm'),  # after the cash-out
    pay('p10', '2026-10-20T10:30:00', 'employer', 'm', kind='salary'),  # not a stranger's payment
    pay('p11', '2026-10-20T10:45:00', 'm', 'x'),  # money out of m
)


def test_first_time_senders_counts_distinct_new_senders_in_the_lookback():
    assert first_time_senders('m', CASH_OUT_AT, by_acct(INFLOW), 24) == 3
    assert first_time_senders('m', CASH_OUT_AT, by_acct(INFLOW)) == 3  # the default lookback is the constant
    assert first_time_senders('nobody', CASH_OUT_AT, by_acct(INFLOW), 24) == 0


def test_first_time_senders_ignores_money_after_ts():
    assert first_time_senders('m', '2026-10-20T09:30:00', by_acct(INFLOW), 24) == 2  # s1 and early; s2, s3 not yet
    later = INFLOW + (pay('p12', '2026-10-20T12:00:01', 's4', 'm'), pay('p13', '2026-10-21T09:00:00', 's5', 'm'))
    assert first_time_senders('m', CASH_OUT_AT, by_acct(later), 24) == 3


def test_a_sender_who_paid_before_the_lookback_is_not_first_time_even_inside_it():
    assert first_time_senders('m', CASH_OUT_AT, by_acct(INFLOW), 24) == 3  # 'old' paid inside 24 h, but not first
    assert first_time_senders('m', CASH_OUT_AT, by_acct(INFLOW), 100) == 5  # its first payment is inside 100 h
    with pytest.raises(ValueError):
        first_time_senders('m', CASH_OUT_AT, by_acct(INFLOW), 0)


# --- till reuse --------------------------------------------------------------------------------------------------

A, B = place('AG-A'), place('AG-B', km_north=20)
BUSY = place('AG-BUSY', km_east=20)
AS_OF = '2026-11-01T12:00:00'
QUIET_NETWORK = 600  # customers cashing out at a busy till at night: the network's seed share stays near half a percent
BACKGROUND = tuple(co(f'bg{i}', at('2026-10-06T02:00:00', seconds=i), f'cust_bg{i}', BUSY) for i in range(QUIET_NETWORK))
REUSE = (
    co('r1', '2026-10-05T09:00:00', 'm1', A),
    co('r2', '2026-10-20T09:00:00', 'm2', A),
    co('r3', '2026-10-21T09:00:00', 'n1', A),  # a customer
    co('r4', '2026-10-22T09:00:00', 'm3', B),  # the only seed at B
    co('r5', '2026-10-22T10:00:00', 'm3', B),
) + BACKGROUND


def test_a_till_with_two_seeds_in_thirty_days_flags_and_one_with_one_seed_does_not():
    flags = till_reuse(REUSE, always('m1', 'm2', 'm3'), AS_OF)
    assert [f.till for f in flags] == ['AG-A']
    flag = flags[0]
    share = 3 / (4 + QUIET_NETWORK)  # m1, m2, m3 among every account that cashed out in the month
    assert flag.accounts == 3 and flag.expected == pytest.approx(3 * share)
    assert flag.p_value == pytest.approx(float(poisson_tail(2, flag.expected)))
    assert flag.p_value <= config.TILL_REUSE_P_THRESHOLD
    assert flag == TillFlag(till='AG-A', lat=A.lat, lon=A.lon, district='Dhaka', seed_accounts=('m1', 'm2'), accounts=3,
                            expected=flag.expected, p_value=flag.p_value, first_seen_ts='2026-10-20T09:00:00',
                            last_seed_ts='2026-10-20T09:00:00')


def test_a_seed_cashout_older_than_thirty_days_does_not_count():
    assert till_reuse(REUSE, always('m1', 'm2', 'm3'), at(REUSE[0].ts, days=config.TILL_REUSE_DAYS)) == ()
    assert [f.till for f in till_reuse(REUSE, always('m1', 'm2'), at(REUSE[0].ts, days=29))] == ['AG-A']


def test_seeds_count_only_once_confirmed_and_the_flag_is_first_seen_at_the_next_check():
    seeds = confirmed(m1='2026-10-08T09:00:00', m2='2026-10-21T08:00:00')
    assert till_reuse(REUSE, seeds, '2026-10-21T07:00:00') == ()  # m2 not yet confirmed
    flags = till_reuse(REUSE, seeds, AS_OF)
    assert flags[0].first_seen_ts == '2026-10-21T09:00:00'  # the first check (a cash-out) after m2's confirmation
    assert till_reuse(REUSE, seeds, '2026-10-21T08:30:00')[0].first_seen_ts == '2026-10-21T08:30:00'  # or as_of


def test_customers_and_repeat_cashouts_by_one_seed_never_make_a_flag():
    assert till_reuse(REUSE, always('m1', 'm3'), AS_OF) == ()
    assert till_reuse(REUSE, always(), AS_OF) == ()


def test_till_reuse_ignores_cashouts_after_as_of_and_input_order():
    late = REUSE + (co('r6', '2026-11-02T09:00:00', 'm4', B),)
    shuffled = list(late)
    random.Random(3).shuffle(shuffled)
    seeds = always('m1', 'm2', 'm3', 'm4')
    assert till_reuse(shuffled, seeds, AS_OF) == till_reuse(REUSE, seeds, AS_OF)
    assert [f.till for f in till_reuse(REUSE, seeds, AS_OF)] == ['AG-A']


# --- till reuse against each till's own volume --------------------------------------------------------------------

BUSY_TILL, QUIET_TILL, REST_TILL = place('AG-BUSY'), place('AG-QUIET', km_north=5), place('AG-REST', km_north=10)
MONTH_DAY, MONTH_AS_OF = '2026-10-10T10:00:00', '2026-10-20T12:00:00'


def month(spec, day=MONTH_DAY, prefix=''):
    """Cash-outs on one day: for each (till, accounts, seeds), that many distinct accounts, the first `seeds` of them
    seeds. Returns the events and the seed accounts."""
    events, seeds = [], set()
    for till, accounts, seeded in spec:
        for i in range(accounts):
            acct = f'{prefix}{till.till}_{"seed" if i < seeded else "cust"}{i}'
            events.append(co(f'{prefix}{till.till}_{i}', at(day, seconds=i), acct, till))
            seeds |= {acct} if i < seeded else set()
    return tuple(events), frozenset(seeds)


PROPORTIONAL = ((BUSY_TILL, 400, 8), (QUIET_TILL, 6, 3), (REST_TILL, 1594, 29))  # 2000 accounts, 40 seeds: 2%


def test_a_busy_till_with_seeds_in_proportion_to_its_volume_does_not_flag():
    events, seeds = month(PROPORTIONAL)
    assert len({e.acct for e in events}) == 2000 and len(seeds) == 40
    flags = {f.till for f in till_reuse(events, always(*seeds), MONTH_AS_OF)}
    assert 8 >= config.TILL_REUSE_MIN_SEEDS  # eight seeds at the busy till: the two-seed floor alone would flag it
    assert not flags & {'AG-BUSY', 'AG-REST'}  # 8 seeds against 400 x 2% = 8 expected; 29 against 31.9


def test_a_quiet_till_with_a_disproportionate_share_of_seeds_flags_with_its_expected_count_and_p():
    events, seeds = month(PROPORTIONAL)
    flags = till_reuse(events, always(*seeds), MONTH_AS_OF)
    assert [f.till for f in flags] == ['AG-QUIET']
    quiet = flags[0]
    assert len(quiet.seed_accounts) == 3 and quiet.accounts == 6
    assert quiet.expected == pytest.approx(6 * 40 / 2000)
    assert quiet.p_value == pytest.approx(float(poisson_tail(3, 6 * 40 / 2000)))
    assert quiet.p_value <= config.TILL_REUSE_P_THRESHOLD


def test_a_till_volume_counts_distinct_accounts_not_repeat_cashouts():
    events, seeds = month(PROPORTIONAL)
    regulars = tuple(co(f'rep{c}_{i}', at(MONTH_DAY, hours=1, seconds=60 * c + i), f'{QUIET_TILL.till}_cust{c}', QUIET_TILL)
                     for c in (3, 4, 5) for i in range(50))  # the quiet till's three customers come back fifty times
    flags = till_reuse(events + regulars, always(*seeds), MONTH_AS_OF)
    assert [(f.till, f.accounts) for f in flags] == [('AG-QUIET', 6)]


def test_one_seed_never_flags_a_till_however_quiet():
    events, seeds = month(((QUIET_TILL, 1, 1), (REST_TILL, 1999, 0)))
    assert float(poisson_tail(1, 1 * len(seeds) / 2000)) <= config.TILL_REUSE_P_THRESHOLD  # the floor, not p, holds it
    assert till_reuse(events, always(*seeds), MONTH_AS_OF) == ()


def test_the_seed_share_is_network_wide_and_as_of_each_check():
    events, seeds = month(PROPORTIONAL)
    later, more = month(((REST_TILL, 300, 300),), day='2026-10-15T10:00:00', prefix='late_')  # 300 more seeds elsewhere
    full = events + later
    assert [f.till for f in till_reuse(full, always(*seeds | more), '2026-10-14T12:00:00')] == ['AG-QUIET']
    assert till_reuse(full, always(*seeds | more), MONTH_AS_OF) == ()  # 6 x 340/2300 = 0.89 expected: three is not rare
    not_yet = confirmed(**{acct: '2026-10-01T00:00:00' for acct in seeds}, **{acct: '2026-11-30T00:00:00' for acct in more})
    assert [f.till for f in till_reuse(full, not_yet, MONTH_AS_OF)] == ['AG-QUIET']  # the 300 are not seeds yet


def test_the_running_counts_agree_with_a_recount_from_scratch_as_the_window_slides():
    """Random cash-outs over three months with seeds confirmed over time: the flags, accounts, expected counts and p at
    each as_of match a direct recount of the window, through every add, drop and confirmation."""
    rng = random.Random(5)
    tills = tuple(place(f'AG-{i}', km_north=3 * i) for i in range(6))
    accounts = [f'a{i}' for i in range(300)]
    mules = {acct: at('2026-08-01T00:00:00', hours=rng.randrange(24 * 90)) for acct in rng.sample(accounts, 40)}
    events = tuple(co(f't{i}', at('2026-08-01T00:00:00', minutes=rng.randrange(60 * 24 * 90)), acct,
                      tills[0] if acct in mules and rng.random() < 0.8 else rng.choice(tills[1:]))
                   for i, acct in enumerate(rng.choice(accounts) for _ in range(2500)))  # the mules favour one till
    seeds_at = confirmed(**mules)
    flagged_somewhere = False
    for as_of in ('2026-08-20T00:00:00', '2026-09-15T12:00:00', '2026-10-10T06:00:00', '2026-10-29T00:00:00'):
        oldest, seeds = at(as_of, days=-config.TILL_REUSE_DAYS), seeds_at(as_of)
        inside = [e for e in events if oldest < e.ts <= as_of]
        share = len({e.acct for e in inside} & seeds) / len({e.acct for e in inside})
        recount = {}
        for till in {e.till for e in inside}:
            here = {e.acct for e in inside if e.till == till}
            k, mu = len(here & seeds), len(here) * share
            if k >= config.TILL_REUSE_MIN_SEEDS and float(poisson_tail(k, mu)) <= config.TILL_REUSE_P_THRESHOLD:
                recount[till] = (k, len(here), mu, float(poisson_tail(k, mu)))
        flags = till_reuse(events, seeds_at, as_of)
        assert {f.till: (len(f.seed_accounts), f.accounts) for f in flags} == {t: v[:2] for t, v in recount.items()}
        assert all(f.expected == pytest.approx(recount[f.till][2]) and f.p_value == pytest.approx(recount[f.till][3])
                   for f in flags)
        flagged_somewhere |= bool(flags)
    assert flagged_somewhere


def test_a_flag_that_lapses_and_returns_is_first_seen_at_its_return():
    events, seeds = month(PROPORTIONAL)
    later, more = month(((REST_TILL, 300, 300),), day='2026-10-15T10:00:00', prefix='late_')
    back = tuple(co(f'back{i}', '2026-10-18T10:00:00', f'back_cust{i}', REST_TILL) for i in range(20000))
    assert till_reuse(events + later, always(*seeds | more), '2026-10-17T00:00:00') == ()  # lapsed
    flags = till_reuse(events + later + back, always(*seeds | more), MONTH_AS_OF)  # 20000 customers dilute the share
    assert [(f.till, f.first_seen_ts) for f in flags] == [('AG-QUIET', '2026-10-18T10:00:00')]

# --- space-time clusters -----------------------------------------------------------------------------------------

T0 = '2026-10-20T10:00:00'
FAR = place('AG-FAR', km_north=50)


def line(d_km):
    """Three tills on a north-south line: the centroid of one cash-out at each is the middle till."""
    return place('AG-S', km_north=-d_km), place('AG-M'), place('AG-N', km_north=d_km)


def circle_events(d_km=2.4, last_seed_min=60, customers=3):
    south, middle, north = line(d_km)
    seeds = (co('s1', T0, 'seed1', north), co('s2', at(T0, minutes=30), 'seed2', middle),
             co('s3', at(T0, minutes=last_seed_min), 'seed3', south))
    others = tuple(co(f'c{i}', at(T0, minutes=10 * i + 5), f'cust{i}', middle) for i in range(customers))
    far = (co('f1', at(T0, minutes=20), 'seed4', FAR),)  # a seed far away never joins the circle
    return tuple(sorted(seeds + others + far, key=lambda e: (e.ts, e.txn_id))), (south, middle, north, FAR)


def baseline_for(events, tills, start=None, end=None):
    return TillBaseline(events, tills, start=start or min(e.ts for e in events), end=end or max(e.ts for e in events))


SEEDS = always('seed1', 'seed2', 'seed3', 'seed4')


def test_three_seed_cashouts_within_the_radius_and_window_open_a_cluster():
    events, tills = circle_events()
    assert haversine_km(tills[0].lat, tills[0].lon, tills[1].lat, tills[1].lon) == pytest.approx(2.4, abs=1e-6)
    clusters = space_time_clusters(events, SEEDS, baseline_for(events, tills))
    assert len(clusters) == 1
    cluster = clusters[0]
    assert cluster.opened_at == at(T0, minutes=60) == cluster.window_end
    assert cluster.window_start == at(T0, minutes=60 - config.CLUSTER_WINDOW_MIN)
    assert cluster.seed_cashouts == ('s1', 's2', 's3')
    assert cluster.all_cashouts == ('s1', 'c0', 'c1', 'c2', 's2', 's3') and cluster.observed == 6
    assert cluster.tills == ('AG-M', 'AG-N', 'AG-S') and cluster.radius_km == config.CLUSTER_RADIUS_KM
    assert haversine_km(cluster.centre_lat, cluster.centre_lon, tills[1].lat, tills[1].lon) < 1e-6
    assert cluster.p_value <= config.CLUSTER_P_THRESHOLD and cluster.baseline_source == 'cold_start'


@pytest.mark.parametrize('d_km,last_seed_min', [(3.1, 60), (2.4, 100)])
def test_seeds_at_3_1_km_from_their_centroid_or_100_minutes_apart_do_not_open_a_cluster(d_km, last_seed_min):
    events, tills = circle_events(d_km=d_km, last_seed_min=last_seed_min)
    assert space_time_clusters(events, SEEDS, baseline_for(events, tills)) == ()


def test_seeds_at_the_corners_of_a_triangle_join_through_their_centroid():
    """No seed lies within 2.5 km of another, but all three lie 2.4 km from their centroid."""
    corners = tuple(place(f'AG-{i}', km_north=2.4 * math.cos(math.radians(a)), km_east=2.4 * math.sin(math.radians(a)))
                    for i, a in enumerate((0, 120, 240)))
    events = tuple(co(f's{i}', at(T0, minutes=5 * i), f'seed{i}', corners[i % 3]) for i in range(3))
    events += tuple(co(f'c{i}', at(T0, minutes=20 + i), f'cust{i}', corners[0]) for i in range(3))
    clusters = space_time_clusters(events, always('seed0', 'seed1', 'seed2'), baseline_for(events, corners))
    assert len(clusters) == 1 and clusters[0].observed == 6


def test_the_floor_blocks_a_cluster_with_too_few_cashouts_however_surprising():
    events, tills = circle_events(customers=2)
    assert len(events) - 1 < config.CLUSTER_MIN_CASHOUTS  # five inside the circle, one far away
    assert space_time_clusters(events, SEEDS, baseline_for(events, tills)) == ()


def history(tills, per_hour, weeks=4, hour='10:00:00'):
    """Background cash-outs by customers at the opening's hour of week, for each of the previous weeks."""
    rows = []
    for week in range(1, weeks + 1):
        day = at(T0[:11] + hour, days=-7 * week)
        rows += [co(f'h{week}_{t.till}_{i}', at(day, minutes=i), f'bg{week}_{i}', t) for t in tills for i in range(per_hour)]
    return tuple(rows)


def test_a_busy_circle_does_not_fire_on_six_cashouts():
    events, tills = circle_events()
    busy = history(tills[:3], per_hour=10) + events
    assert space_time_clusters(busy, SEEDS, baseline_for(busy, tills)) == ()
    quiet = history(tills[:3], per_hour=0) + events
    fired = space_time_clusters(quiet, SEEDS, baseline_for(events, tills, start=at(T0, days=-28)))
    assert len(fired) == 1 and fired[0].baseline_source == 'prior'


def test_a_till_that_opens_in_week_3_does_not_dilute_the_pooled_rate_of_an_earlier_comparison_week():
    """Each comparison week's total is shared among the tills open at that hour, not at the rated hour."""
    start, per_hour = '2026-09-07T00:00:00', 10
    old, new = place('AG-OLD'), place('AG-NEW', km_north=1, since=at(start, days=21))
    rated = at(start, days=28, hours=10)  # week 4; its comparisons are the same hour in weeks 3, 2, 1 and 0
    rows = tuple(co(f'{t.till}_{week}_{i}', at(start, days=7 * week, hours=10, minutes=i), f'c_{t.till}_{week}_{i}', t)
                 for week in range(4) for t in (old, new) if t.since <= at(start, days=7 * week, hours=10)
                 for i in range(per_hour))
    baseline = TillBaseline(rows, (old, new), start=start, end=at(rated, hours=1))
    assert len(rows) == 5 * per_hour  # the old till in weeks 0-3, the new one in week 3 only
    # Every open till cashed out ten times at every comparison hour, so the pooled rate is ten and so is the old
    # till's own: the new till must not halve weeks 0-2 by counting as open there.
    assert baseline.rate('AG-OLD', rated) == (pytest.approx(per_hour), 'prior')


def test_the_live_circle_waits_for_confirmation_so_seeds_confirmed_later_open_nothing():
    events, tills = circle_events()
    three_days_later = confirmed(seed1=at(T0, days=3), seed2=at(T0, days=3), seed3=at(T0, days=3))
    assert space_time_clusters(events, three_days_later, baseline_for(events, tills)) == ()


def test_nothing_after_opened_at_changes_the_opening_snapshot():
    events, tills = circle_events()
    base = history(tills[:3], per_hour=1, hour='03:00:00')  # four prior weeks, none at the opening's hours
    cut = base + events
    opened = space_time_clusters(cut, SEEDS, baseline_for(cut, tills))[0]
    after = (co('a1', at(opened.opened_at, minutes=1), 'cust9', tills[1]),
             co('a2', at(opened.opened_at, minutes=2), 'seed9', tills[1]),
             co('a3', at(opened.opened_at, minutes=3), 'seed10', tills[2]),
             co('a4', at(opened.opened_at, minutes=4), 'seed11', tills[0]))
    full = cut + after

    def seeds_later(ts):  # more mules, and a customer of the circle, are confirmed after the opening
        return SEEDS(ts) | (frozenset({'seed9', 'seed10', 'seed11', 'cust0'}) if ts > opened.opened_at else frozenset())

    replay = space_time_clusters(full, seeds_later, baseline_for(full, tills))
    assert opened.baseline_source == 'prior'
    assert replay[0] == opened
    assert not set(replay[0].all_cashouts) & {'a1', 'a2', 'a3', 'a4'}


def test_cluster_id_is_the_sha1_of_its_seed_txn_ids_and_independent_of_input_order():
    events, tills = circle_events()
    cluster = space_time_clusters(events, SEEDS, baseline_for(events, tills))[0]
    assert cluster.cluster_id == 'clu_' + hashlib.sha1('|'.join(sorted(cluster.seed_cashouts)).encode()).hexdigest()[:12]
    shuffled = list(events)
    random.Random(11).shuffle(shuffled)
    assert space_time_clusters(shuffled, SEEDS, baseline_for(events, tills)) == (cluster,)


def test_a_seed_cashout_belongs_to_one_cluster_only():
    events, tills = circle_events()
    _south, middle, _north = tills[:3]
    more = events + tuple(co(f'x{i}', at(T0, minutes=61 + i), f'cust_x{i}', middle) for i in range(3))
    clusters = space_time_clusters(more, SEEDS, baseline_for(more, tills))
    assert len(clusters) == 1


# --- candidates --------------------------------------------------------------------------------------------------

def strangers(payee, before, n, prefix):
    return tuple(pay(f'{prefix}{i}', at(before, hours=-(i + 1)), f'{prefix}_sender{i}', payee) for i in range(n))


def test_a_non_seed_with_three_first_time_senders_is_a_candidate_and_one_with_one_is_not_flagged():
    events = REUSE + (co('k1', '2026-10-25T09:00:00', 'mule_x', A), co('k2', '2026-10-25T10:00:00', 'cust_y', A),
                      co('k3', '2026-10-25T11:00:00', 'mule_z', B),  # B is not flagged
                      co('k4', '2026-09-25T11:00:00', 'mule_w', A))  # before the reuse window
    ledger = (strangers('mule_x', '2026-10-25T09:00:00', 3, 'x') + strangers('cust_y', '2026-10-25T10:00:00', 1, 'y')
              + strangers('mule_z', '2026-10-25T11:00:00', 5, 'z') + strangers('mule_w', '2026-09-25T11:00:00', 5, 'w'))
    seeds = frozenset({'m1', 'm2', 'm3'})
    flag = till_reuse(events, always(*seeds), AS_OF)[0]
    found, held = candidates(flag, events, seeds, by_acct(ledger), as_of=AS_OF)
    assert found == (Candidate(acct='mule_x', till='AG-A', ts='2026-10-25T09:00:00', amount_bdt=3000.0,
                               first_time_senders=3, source=SOURCE_TILL_REUSE, filter=FILTER_FIRST_TIME_SENDERS,
                               new_counterparties=3, received_bdt=3000.0, cashed_out_bdt=0.0),)  # no cash-out row in this ledger
    assert {n.acct: (n.first_time_senders, n.reason) for n in held} == {
        'n1': (0, REASON_FEW_FIRST_TIME_SENDERS), 'cust_y': (1, REASON_FEW_FIRST_TIME_SENDERS)}
    assert all(isinstance(n, NotFlagged) and n.source == SOURCE_TILL_REUSE and n.filter == FILTER_FIRST_TIME_SENDERS
               for n in held)
    explicit = candidates(flag, events, seeds, by_acct(ledger), as_of=AS_OF, candidate_filter=FILTER_FIRST_TIME_SENDERS)
    assert explicit == (found, held)  # the first filter is the default, unchanged


def test_cluster_candidates_come_from_inside_its_circle_and_window():
    events, tills = circle_events()
    cluster = space_time_clusters(events, SEEDS, baseline_for(events, tills))[0]
    ledger = strangers('cust0', at(T0, minutes=5), 4, 'a') + strangers('cust1', at(T0, minutes=15), 2, 'b')
    found, held = candidates(cluster, events, frozenset(SEEDS(T0)), by_acct(ledger))
    assert [(c.acct, c.first_time_senders, c.source) for c in found] == [('cust0', 4, f'cluster:{cluster.cluster_id}')]
    assert sorted(n.acct for n in held) == ['cust1', 'cust2']
    assert not {c.acct for c in found + held} & {'seed1', 'seed2', 'seed3', 'seed4'}


# --- the pass-through filter (segment 3b) -------------------------------------------------------------------------

def money(txn_id, ts, sender, payee, amount, kind='send_money'):
    return dict(txn_id=txn_id, ts=ts, type=kind, from_acct=sender, to_acct=payee, amount_bdt=amount)


def cash(txn_id, ts, acct, amount, till='AG-A'):
    return dict(txn_id=txn_id, ts=ts, type='cash_out', from_acct=acct, to_acct=f'acct_till_{till}', agent_id=till,
                amount_bdt=amount)


def test_the_pass_through_constants_are_the_ones_fixed_before_measurement():
    assert (config.PASS_THROUGH_MIN_NEW_COUNTERPARTIES, config.PASS_THROUGH_NEW_DAYS, config.PASS_THROUGH_MIN_SHARE) == (1, 30, 0.8)
    assert config.PASS_THROUGH_IN_TYPES == config.FIRST_TIME_SENDER_TYPES == ('send_money',)
    assert (config.CANDIDATE_MIN_FIRST_TIME_SENDERS, config.CANDIDATE_LOOKBACK_HOURS) == (3, 24)  # the first filter
    assert FILTERS == (FILTER_FIRST_TIME_SENDERS, FILTER_PASS_THROUGH) == ('first_time_senders', 'pass_through')


PT_AT = '2026-10-20T12:00:00'
PASS_LEDGER = (
    money('i1', '2026-10-20T08:00:00', 'victim', 'p', 5000.0),  # a stranger: new
    money('i2', '2026-10-20T09:30:00', 'victim', 'p', 1000.0),  # the same stranger again: one counterparty
    money('i3', '2026-10-20T09:00:00', 'sister', 'p', 1000.0),  # paid p 29 days earlier: not new
    money('i4', '2026-09-21T09:00:00', 'sister', 'p', 500.0),
    money('i5', '2026-10-20T10:00:00', 'cousin', 'p', 1000.0),  # p paid the cousin ten days earlier: either way counts
    money('i6', '2026-10-10T10:00:00', 'p', 'cousin', 200.0),
    money('i7', '2026-10-20T10:30:00', 'friend', 'p', 1000.0),  # last dealt with 31 days earlier: new again
    money('i8', '2026-09-19T10:30:00', 'friend', 'p', 300.0),
    money('i9', '2026-10-20T08:30:00', 'twin', 'p', 1000.0),  # exactly 30 days earlier: inside the month, not new
    money('i10', '2026-09-20T08:30:00', 'twin', 'p', 100.0),
    money('i11', '2026-10-20T11:00:00', 'employer', 'p', 2000.0, kind='salary'),  # received, but no counterparty
    money('i12', '2026-10-19T11:59:59', 'early', 'p', 9000.0),  # one second before the lookback
    money('i13', PT_AT, 'same_second', 'p', 9000.0),  # at the cash-out itself: not before it
    money('i14', '2026-10-20T13:00:00', 'later', 'p', 9000.0),  # after the cash-out
    money('i15', '2026-10-20T11:15:00', 'p', 'shop', 700.0, kind='payment'),  # money out that is not cash
    cash('o1', '2026-10-19T12:00:00', 'p', 4000.0),  # the first second of the lookback
    cash('o2', '2026-10-20T11:30:00', 'p', 2000.0),
    cash('o3', PT_AT, 'p', 5000.0),  # the cash-out itself
    cash('o4', '2026-10-20T12:00:01', 'p', 7000.0),  # after it
    cash('o5', '2026-10-19T11:00:00', 'p', 4000.0),  # before the lookback
)


def test_pass_through_counts_new_counterparties_and_money_in_and_out_over_the_lookback():
    evidence = pass_through('p', PT_AT, by_acct(PASS_LEDGER))
    assert evidence == PassThrough(new_counterparties=2, received_bdt=12000.0, cashed_out_bdt=11000.0)  # victim, friend
    assert evidence.share == pytest.approx(11000 / 12000)
    assert pass_through('p', PT_AT, by_acct(PASS_LEDGER), 24) == evidence  # the lookback is CANDIDATE_LOOKBACK_HOURS
    assert pass_through('nobody', PT_AT, by_acct(PASS_LEDGER)) == PassThrough(0, 0.0, 0.0)
    assert PassThrough(0, 0.0, 0.0).share is None


def test_pass_through_ignores_everything_after_the_cashout():
    later = PASS_LEDGER + (money('l1', '2026-10-20T12:00:01', 'stranger2', 'p', 500.0),
                           money('l2', '2026-10-21T09:00:00', 'stranger3', 'p', 500.0),
                           cash('l3', '2026-10-20T18:00:00', 'p', 900.0))
    assert pass_through('p', PT_AT, by_acct(later)) == pass_through('p', PT_AT, by_acct(PASS_LEDGER))
    assert pass_through('p', '2026-10-20T09:15:00', by_acct(PASS_LEDGER)) == PassThrough(
        new_counterparties=2, received_bdt=16000.0, cashed_out_bdt=8000.0)  # victim and early are new; o5 and o1
    with pytest.raises(ValueError):
        pass_through('p', PT_AT, by_acct(PASS_LEDGER), 0)


def test_the_pass_through_rule_needs_a_new_counterparty_and_eighty_percent_out():
    assert is_pass_through(PassThrough(1, 1000.0, 800.0))  # exactly the share
    assert not is_pass_through(PassThrough(1, 1000.0, 799.0))
    assert not is_pass_through(PassThrough(0, 1000.0, 1000.0))  # only old counterparties
    assert not is_pass_through(PassThrough(1, 0.0, 0.0))  # nothing received
    assert is_pass_through(pass_through('p', PT_AT, by_acct(PASS_LEDGER)))


def test_pass_through_candidates_beside_the_first_filter():
    events = REUSE + (co('k1', '2026-10-25T09:00:00', 'one_victim', A, 4500.0),  # one stranger, 90% out: passes
                      co('k2', '2026-10-25T10:00:00', 'keeper', A, 3000.0),  # one stranger, 60% out
                      co('k3', '2026-10-25T11:00:00', 'regular', A, 3000.0),  # only his mother, paying for weeks
                      co('k4', '2026-10-25T12:00:00', 'collector', A, 1000.0),  # three strangers, a third out
                      co('k5', '2026-10-25T13:00:00', 'one_victim', A, 400.0))  # a second, later cash-out
    ledger = (money('v1', '2026-10-25T08:00:00', 'victim1', 'one_victim', 5000.0),
              money('v2', '2026-10-25T08:00:00', 'stranger', 'keeper', 5000.0),
              money('v3', '2026-10-01T08:00:00', 'mother', 'regular', 1000.0),
              money('v4', '2026-10-25T08:00:00', 'mother', 'regular', 3000.0))
    ledger += strangers('collector', '2026-10-25T12:00:00', 3, 'c') + tuple(ledger_row(e) for e in events)
    seeds = frozenset({'m1', 'm2', 'm3'})
    flag = till_reuse(events, always(*seeds), AS_OF)[0]
    assert flag.till == 'AG-A'
    first, first_held = candidates(flag, events, seeds, by_acct(ledger), as_of=AS_OF)
    assert [c.acct for c in first] == ['collector'] and all(c.filter == FILTER_FIRST_TIME_SENDERS for c in first)
    found, held = candidates(flag, events, seeds, by_acct(ledger), as_of=AS_OF, candidate_filter=FILTER_PASS_THROUGH)
    assert found == (Candidate(acct='one_victim', till='AG-A', ts='2026-10-25T09:00:00', amount_bdt=4500.0,
                               first_time_senders=1, source=SOURCE_TILL_REUSE, filter=FILTER_PASS_THROUGH,
                               new_counterparties=1, received_bdt=5000.0, cashed_out_bdt=4500.0),)  # its earliest pass
    assert {n.acct: n.reason for n in held} == {'n1': REASON_NO_NEW_COUNTERPARTY, 'regular': REASON_NO_NEW_COUNTERPARTY,
                                                'keeper': REASON_LOW_PASS_THROUGH_SHARE,
                                                'collector': REASON_LOW_PASS_THROUGH_SHARE}
    assert all(n.filter == FILTER_PASS_THROUGH and n.source == SOURCE_TILL_REUSE for n in held)
    assert not {c.acct for c in found + held} & seeds
    with pytest.raises(ValueError):
        candidates(flag, events, seeds, by_acct(ledger), as_of=AS_OF, candidate_filter='three_strangers')


def test_a_pass_through_lead_in_a_cluster_keeps_its_source_and_sees_nothing_after_its_cashout():
    events, tills = circle_events()
    cluster = space_time_clusters(events, SEEDS, baseline_for(events, tills))[0]
    cust0 = next(e for e in events if e.acct == 'cust0')
    ledger = (money('a1', at(cust0.ts, hours=-1), 'stranger', 'cust0', 3500.0), ledger_row(cust0))
    found, held = candidates(cluster, events, frozenset(SEEDS(T0)), by_acct(ledger), candidate_filter=FILTER_PASS_THROUGH)
    assert [(c.acct, c.source, c.filter) for c in found] == [('cust0', f'cluster:{cluster.cluster_id}', FILTER_PASS_THROUGH)]
    assert found[0].cashed_out_bdt == 3000.0 and found[0].received_bdt == 3500.0
    late = ledger + (money('a2', at(cust0.ts, minutes=1), 'stranger9', 'cust0', 90000.0),)  # would sink the share
    assert candidates(cluster, events, frozenset(SEEDS(T0)), by_acct(late), candidate_filter=FILTER_PASS_THROUGH)[0] == found
    assert sorted(n.acct for n in held) == ['cust1', 'cust2']


# --- the output --------------------------------------------------------------------------------------------------

def agent(t):
    return dict(agent_id=t.till, district=t.district, lat=t.lat, lon=t.lon, since=t.since)


def ledger_row(e):
    return dict(txn_id=e.txn_id, ts=e.ts, type='cash_out', from_acct=e.acct, to_acct=f'acct_till_{e.till}',
                agent_id=e.till, amount_bdt=e.amount_bdt)


def test_run_cashout_is_json_ready_and_holds_every_part():
    events, tills = circle_events()
    agents = tuple(agent(t) for t in tills) + (dict(agent_id='AG-NOWHERE', district='Bhola', lat=None, lon=None),)
    txns = tuple(ledger_row(e) for e in events + REUSE) + strangers('cust0', at(T0, minutes=5), 3, 'a')
    reuse_tills = tuple(agent(t) for t in (A, B, BUSY))
    out = run_cashout({'transactions': txns, 'agents': agents + reuse_tills}, AS_OF, always('seed1', 'seed2', 'seed3', 'm1', 'm2'))
    assert json.loads(json.dumps(out)) == out
    assert set(out) == {'as_of', 'tills', 'till_flags', 'clusters', 'candidates', 'not_flagged', 'counts', 'config', 'caveat'}
    assert {t['till'] for t in out['tills']} == {'AG-S', 'AG-M', 'AG-N', 'AG-FAR', 'AG-A', 'AG-B', 'AG-BUSY'}
    assert all(isinstance(t['lat'], float) and isinstance(t['lon'], float) for t in out['tills'])
    assert [f['till'] for f in out['till_flags']] == ['AG-A']
    flag = out['till_flags'][0]
    assert flag['accounts'] == 3 and 0 < flag['expected'] < 1 and flag['p_value'] <= config.TILL_REUSE_P_THRESHOLD
    assert len(out['clusters']) == 1 and out['counts']['clusters'] == 1
    assert {c['acct'] for c in out['candidates']} == {'cust0'}
    assert {(c['acct'], c['filter']) for c in out['candidates']} == {('cust0', FILTER_FIRST_TIME_SENDERS),
                                                                     ('cust0', FILTER_PASS_THROUGH)}
    assert out['counts']['candidates'] == len(out['candidates']) and out['counts']['not_flagged'] == len(out['not_flagged'])
    assert out['counts']['candidate_accounts'] == 1
    assert out['counts']['candidates_by_filter'] == {FILTER_FIRST_TIME_SENDERS: 1, FILTER_PASS_THROUGH: 1}
    assert {n['filter'] for n in out['not_flagged']} == set(FILTERS)
    for name in ('PASS_THROUGH_MIN_NEW_COUNTERPARTIES', 'PASS_THROUGH_NEW_DAYS', 'PASS_THROUGH_MIN_SHARE'):
        assert out['config'][name] == getattr(config, name)
    assert out['config']['TILL_REUSE_DAYS'] == config.TILL_REUSE_DAYS
    assert out['config']['TILL_REUSE_P_THRESHOLD'] == config.TILL_REUSE_P_THRESHOLD
    assert out['config']['CLUSTER_P_THRESHOLD'] == config.P_THRESHOLD
    caveat = out['caveat'].lower()
    assert 'synthetic' in caveat and 'lead' in caveat and 'till reuse' in caveat and 'confirm' in caveat
    assert 'pass-through' in caveat and 'first-time' in caveat


def test_run_cashout_needs_a_seed_function():
    with pytest.raises(TypeError):
        run_cashout({'transactions': (), 'agents': ()}, AS_OF, frozenset())


@pytest.mark.skipif(not (SEED/'agents.jsonl').exists(), reason='data/seed-campaign has not been generated')
def test_campaign_world_runs_and_no_seed_is_a_candidate():
    from bhorosha_radar.cashout_seeds import confirmed_mules, read_labels
    from radar_eval import load_observable_bundle
    bundle, rows = load_observable_bundle(SEED), read_labels(SEED)
    as_of = max(t['ts'] for ts in bundle.txns_by_acct.values() for t in ts)
    out = run_cashout(bundle, as_of, lambda ts: confirmed_mules(rows, ts))
    seeds = confirmed_mules(rows, as_of)
    assert json.loads(json.dumps(out)) == out and len(out['tills']) == 40
    assert out['till_flags'] and not {c['acct'] for c in out['candidates'] + out['not_flagged']} & seeds
