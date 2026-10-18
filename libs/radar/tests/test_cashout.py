"""Cash-outs at tills located as of the moment, confirmed-mule seeds with the confirmation delay."""
from dataclasses import asdict, fields
import json
import math
from pathlib import Path
import random

import pytest

from bhorosha_radar import config
from bhorosha_radar.cashout import (SKIP_NO_COORDINATES, SKIP_NO_TILL, SKIP_TILL_NOT_OPEN, CashOut, read_cashouts,
                                    scan_cashouts)
from bhorosha_radar.cashout_seeds import confirmed_mules, read_labels
from bhorosha_radar.geo import haversine_km
from radar_eval import load_observable_bundle

SEED = Path(__file__).resolve().parents[3]/'data'/'seed-campaign'

AGENTS = (
    dict(agent_id='AG-A', district='Sylhet', lat=24.848, lon=91.90752, since='2026-03-09T08:00:00'),
    dict(agent_id='AG-B', district='Dhaka', lat=23.8103, lon=90.4125, since='2026-10-10T12:00:00'),  # opens mid-fixture
    dict(agent_id='AG-C', district='Bhola', lat=None, lon=None, since='2026-01-01T00:00:00'),  # no coordinates
)


def cash_out(txn_id, ts, acct, till, amount=3000.0, **extra):
    return dict(txn_id=txn_id, ts=ts, type='cash_out', from_acct=acct, to_acct=f'acct_till_{till}', agent_id=till,
                amount_bdt=amount, channel='agent', status='ok') | extra


TXNS = (
    cash_out('t1', '2026-10-09T09:00:00', 'm1', 'AG-A', 4000.0),
    cash_out('t2', '2026-10-09T10:00:00', 'm2', 'AG-B'),  # AG-B did not exist yet
    cash_out('t3', '2026-10-11T08:30:00', 'm2', 'AG-B'),
    cash_out('t4', '2026-10-11T08:30:00', 'm3', 'AG-C'),  # till without coordinates
    cash_out('t0', '2026-10-11T08:30:00', 'm5', 'AG-A', ring_id='ring_hidden', truth_campaign='ring_hidden'),
    cash_out('t6', '2026-10-12T09:00:00', 'm4', 'AG-Z'),  # unknown till
    cash_out('t7', '2026-10-12T10:00:00', 'm4', None),  # names no till
    dict(txn_id='t5', ts='2026-10-10T07:00:00', type='send_money', from_acct='m1', to_acct='m2', agent_id=None,
         amount_bdt=500.0),
)


def tables(txns=TXNS, agents=AGENTS):
    return {'transactions': txns, 'agents': agents}


def test_every_cashout_is_one_event_at_its_till_with_its_coordinates_and_district():
    events = read_cashouts(tables())
    assert [e.txn_id for e in events] == ['t1', 't0', 't3']
    first = events[0]
    assert first == CashOut(txn_id='t1', ts='2026-10-09T09:00:00', acct='m1', till='AG-A', amount_bdt=4000.0,
                            lat=24.848, lon=91.90752, district='Sylhet')
    assert events[2].district == 'Dhaka' and (events[2].lat, events[2].lon) == (23.8103, 90.4125)


def test_till_created_after_the_cashout_has_no_location_and_every_skip_is_counted():
    scan = scan_cashouts(tables())
    assert 't2' not in {e.txn_id for e in scan.events}
    assert dict(scan.skipped) == {SKIP_TILL_NOT_OPEN: 1, SKIP_NO_COORDINATES: 2, SKIP_NO_TILL: 1}
    assert len(scan.events) + sum(scan.skipped.values()) == sum(t['type'] == 'cash_out' for t in TXNS)


def test_a_till_opening_at_the_very_moment_of_the_cashout_is_located():
    events = read_cashouts(tables(txns=(cash_out('t', '2026-10-10T12:00:00', 'm', 'AG-B'),)))
    assert [e.txn_id for e in events] == ['t']


def test_window_is_half_open_and_skips_outside_it_are_not_counted():
    scan = scan_cashouts(tables(), start='2026-10-11T08:30:00', end='2026-10-12T09:00:00')
    assert [e.txn_id for e in scan.events] == ['t0', 't3']
    assert dict(scan.skipped) == {SKIP_NO_COORDINATES: 1}


def test_order_is_by_time_then_txn_id_and_independent_of_input_order():
    shuffled = list(TXNS)
    random.Random(7).shuffle(shuffled)
    assert read_cashouts(tables(txns=tuple(shuffled))) == read_cashouts(tables())


def test_events_carry_no_ring_or_truth_field():
    assert {f.name for f in fields(CashOut)} == {'txn_id', 'ts', 'acct', 'till', 'amount_bdt', 'lat', 'lon', 'district'}
    assert not any('ring_hidden' in str(asdict(e)) for e in read_cashouts(tables()))


def test_bundle_input_lists_each_transaction_once(tmp_path):
    (tmp_path/'transactions.jsonl').write_text(''.join(json.dumps(t) + '\n' for t in TXNS))
    (tmp_path/'agents.jsonl').write_text(''.join(json.dumps(a) + '\n' for a in AGENTS))
    bundle = load_observable_bundle(tmp_path)  # files each transaction under both of its accounts
    assert read_cashouts(bundle) == read_cashouts(tables())
    assert dict(scan_cashouts(bundle).skipped) == dict(scan_cashouts(tables()).skipped)


def test_conflicting_rows_for_one_txn_id_and_bad_amounts_are_rejected():
    clash = (cash_out('t', '2026-10-11T08:00:00', 'm', 'AG-A'), cash_out('t', '2026-10-11T09:00:00', 'm', 'AG-A'))
    with pytest.raises(ValueError, match='txn_id'):
        read_cashouts(tables(txns=clash))
    with pytest.raises(ValueError):
        read_cashouts(tables(txns=(cash_out('t', '2026-10-11T08:00:00', 'm', 'AG-A', amount=-5),)))


def test_invalid_coordinates_count_as_none():
    agents = (dict(agent_id='AG-X', district='Khulna', lat=95.0, lon=89.5, since='2026-01-01T00:00:00'),
              dict(agent_id='AG-Y', district='Khulna', lat=True, lon=89.5, since='2026-01-01T00:00:00'))
    txns = (cash_out('a', '2026-10-11T08:00:00', 'm', 'AG-X'), cash_out('b', '2026-10-11T08:00:00', 'm', 'AG-Y'))
    scan = scan_cashouts(tables(txns=txns, agents=agents))
    assert scan.events == () and dict(scan.skipped) == {SKIP_NO_COORDINATES: 2}


# --- geo ---------------------------------------------------------------------------------------------------------

def test_haversine_matches_two_known_distances():
    assert haversine_km(51.5074, -0.1278, 48.8566, 2.3522) == pytest.approx(343.5, abs=0.5)  # London to Paris
    assert haversine_km(0.0, 0.0, 90.0, 0.0) == pytest.approx(math.pi * config.EARTH_RADIUS_KM / 2)  # equator to pole
    assert haversine_km(24.848, 91.90752, 24.848, 91.90752) == 0.0
    assert haversine_km(23.8, 90.4, 24.8, 91.9) == pytest.approx(haversine_km(24.8, 91.9, 23.8, 90.4))


def test_haversine_rejects_points_off_the_globe():
    with pytest.raises(ValueError):
        haversine_km(91.0, 0.0, 0.0, 0.0)
    with pytest.raises(ValueError):
        haversine_km(0.0, float('nan'), 0.0, 0.0)


# --- confirmed-mule seeds ----------------------------------------------------------------------------------------

LABELS = (
    dict(acct_id='m1', ring_id='r1', role='mule_L1', typology='fan_in_fan_out', first_bad_ts='2026-10-01T12:00:00'),
    dict(acct_id='m2', ring_id='r1', role='mule_L2', typology='fan_in_fan_out', first_bad_ts='2026-10-05T12:00:00'),
    dict(acct_id='c1', ring_id='r1', role='controller', typology='fan_in_fan_out', first_bad_ts='2026-10-02T00:00:00'),
    dict(acct_id='v1', ring_id='r1', role='victim', typology='fan_in_fan_out', first_bad_ts='2026-09-01T00:00:00'),
)


def test_lag_matches_the_synth_constant():
    from bhorosha_graph.features import CONFIRMATION_LAG_DAYS
    assert config.CONFIRMATION_LAG_DAYS == CONFIRMATION_LAG_DAYS == 3


def test_a_mule_is_a_seed_only_after_the_confirmation_lag():
    assert confirmed_mules(LABELS, '2026-10-04T11:59:59') == frozenset()
    assert confirmed_mules(LABELS, '2026-10-04T12:00:01') == {'m1'}
    assert confirmed_mules(LABELS, '2026-10-05T00:00:01') == {'m1', 'c1'}
    assert confirmed_mules(LABELS, '2026-10-05T12:00:01', lag_days=0) == {'m1', 'm2', 'c1'}


def test_the_exact_boundary_follows_the_synth_rule():
    from types import SimpleNamespace
    from bhorosha_graph.features import confirmed_fraud
    boundary = '2026-10-04T12:00:00'  # m1's first bad event plus three days
    assert confirmed_mules(LABELS, boundary) == frozenset(confirmed_fraud(SimpleNamespace(labels=LABELS), boundary))


def test_victims_are_never_seeds():
    assert 'v1' not in confirmed_mules(LABELS, '2027-01-01T00:00:00')
    assert confirmed_mules([dict(acct_id='v', role='victim', first_bad_ts=None)], '2027-01-01T00:00:00') == frozenset()


def test_a_victim_row_never_confirms_an_account_that_is_also_a_mule_elsewhere():
    """The campaign world holds two such accounts (taken over in one ring, a mule in another): only the mule row counts."""
    both = (dict(acct_id='x', role='victim', first_bad_ts='2026-09-01T00:00:00'),
            dict(acct_id='x', role='mule_L1', first_bad_ts='2026-10-20T00:00:00'))
    assert confirmed_mules(both, '2026-10-22T00:00:00') == frozenset()
    assert confirmed_mules(both, '2026-10-23T00:00:01') == {'x'}


def test_as_of_with_an_offset_is_read_in_dhaka_time():
    assert confirmed_mules(LABELS, '2026-10-04T06:00:01Z') == {'m1'}  # 12:00:01 in Dhaka


def test_malformed_seed_inputs_are_rejected():
    with pytest.raises(ValueError):
        confirmed_mules([dict(acct_id='m', role='mule_L1')], '2026-10-10T00:00:00')  # no first bad event
    with pytest.raises(ValueError):
        confirmed_mules([dict(acct_id='m', role='mule_L9', first_bad_ts='2026-10-01T00:00:00')], '2026-10-10T00:00:00')
    with pytest.raises(ValueError):
        confirmed_mules(LABELS, '2026-10-10T00:00:00', lag_days=-1)


def test_seeds_over_time_answer_as_confirmed_mules_does_at_every_instant():
    from bhorosha_radar.cashout_seeds import confirmed_mules_over_time
    both = LABELS + (dict(acct_id='m1', role='mule_L2', first_bad_ts='2026-10-03T00:00:00'),  # a second row, later
                     dict(acct_id='v1', role='mule_L1', first_bad_ts='2026-10-06T00:00:00'))  # a victim elsewhere
    instants = ('2026-09-01T00:00:00', '2026-10-04T11:59:59', '2026-10-04T12:00:00', '2026-10-04T12:00:01',
                '2026-10-05T00:00:01', '2026-10-06T06:00:01Z', '2026-10-09T00:00:01', '2027-01-01T00:00:00')
    for lag in (0, 3):
        seeds_at = confirmed_mules_over_time(both, lag)
        assert all(seeds_at(ts) == confirmed_mules(both, ts, lag) for ts in instants)
    assert confirmed_mules_over_time(both)('2026-10-04T12:00:01') == {'m1'}  # the default lag is the constant
    with pytest.raises(ValueError):
        confirmed_mules_over_time(LABELS, -1)
    with pytest.raises(ValueError):
        confirmed_mules_over_time([dict(acct_id='m', role='mule_L1')])


def test_read_labels_keeps_only_what_a_seed_needs(tmp_path):
    assert read_labels(tmp_path) == ()
    (tmp_path/'labels.jsonl').write_text(''.join(json.dumps(r) + '\n' for r in LABELS))
    rows = read_labels(tmp_path)
    assert {key for row in rows for key in row} == {'acct_id', 'role', 'first_bad_ts'}
    assert confirmed_mules(rows, '2026-10-05T00:00:01') == {'m1', 'c1'}


@pytest.mark.skipif(not (SEED/'agents.jsonl').exists(), reason='data/seed-campaign has not been generated')
def test_campaign_world_cashouts_are_all_accounted_for_and_every_seed_has_a_confirmed_mule_row():
    scan = scan_cashouts(load_observable_bundle(SEED))
    ledger = [json.loads(line) for line in (SEED/'transactions.jsonl').read_text().splitlines() if line.strip()]
    assert len(scan.events) + sum(scan.skipped.values()) == sum(t['type'] == 'cash_out' for t in ledger)
    assert scan.events and all(e.district for e in scan.events)
    labels = read_labels(SEED)
    as_of = scan.events[-1].ts
    seeds = confirmed_mules(labels, as_of)
    mule_rows = {row['acct_id'] for row in labels if row['role'] != 'victim' and row['first_bad_ts'] < as_of}
    assert seeds and seeds <= mule_rows
    from bhorosha_radar.cashout_seeds import confirmed_mules_over_time
    seeds_at = confirmed_mules_over_time(labels)
    assert all(seeds_at(e.ts) == confirmed_mules(labels, e.ts) for e in scan.events[::97])
