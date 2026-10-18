"""The rolling evaluation of the common point of cash-out against the labels, both candidate
filters side by side."""
from datetime import datetime, timedelta
import json
from pathlib import Path

import pytest

from bhorosha_radar import config
from bhorosha_radar.cashout import CashOut
from bhorosha_radar.cashout_rules import FILTER_FIRST_TIME_SENDERS as FTS, FILTER_PASS_THROUGH as PT
from cashout_eval import (Truth, day_boundaries, first_candidates, lead_days, main, read_truth, right_tills,
                          evaluate_world)

AGENTS = (dict(agent_id='AG-Q', district='Bhola', lat=22.68, lon=90.65, since='2026-01-01T00:00:00'),
          dict(agent_id='AG-B', district='Dhaka', lat=23.81, lon=90.41, since='2026-01-01T00:00:00'))


def at(ts, **delta):
    return (datetime.fromisoformat(ts) + timedelta(**delta)).isoformat(timespec='seconds')


def cash_out(txn_id, ts, acct, till, ring_id=None):
    return dict(txn_id=txn_id, ts=ts, type='cash_out', from_acct=acct, to_acct=f'acct_till_{till}', agent_id=till,
                amount_bdt=3000.0, ring_id=ring_id)


def pay(txn_id, ts, sender, payee, amount=1000.0):
    return dict(txn_id=txn_id, ts=ts, type='send_money', from_acct=sender, to_acct=payee, amount_bdt=amount)


def world(path, one_victim_mule=False):
    """Fourteen days. Three mules confirmed before the world cash out together at a quiet till on day one, with three
    customers; a future mule (first bad on 10-06, confirmed 10-09 09:00) and a customer each collect from three
    strangers and cash out there on 10-06; 300 customers at a busy till keep the network's seed share low. With
    `one_victim_mule`, a second future mule (first bad 10-08 14:00, confirmed 10-11 14:00) takes 3200 from one victim
    and cashes out 3000 at the same till an hour later: one first-time sender, a pass-through."""
    txns = [cash_out(f'bg{i}', at('2026-10-01T03:00:00', seconds=i), f'cust_bg{i}', 'AG-B') for i in range(300)]
    txns += [cash_out(f'q{i}', at('2026-10-01T11:30:00', minutes=10 * i), f'cust_q{i}', 'AG-Q') for i in range(3)]
    txns += [cash_out(f'm{i}', at('2026-10-01T12:00:00', minutes=10 * i), f'm{i}', 'AG-Q', 'ring_a') for i in (1, 2, 3)]
    txns += [pay(f'p4_{i}', at('2026-10-06T09:00:00', minutes=20 * i), f'victim{i}', 'm4') for i in range(3)]
    txns += [pay(f'px_{i}', at('2026-10-06T10:00:00', minutes=20 * i), f'friend{i}', 'x') for i in range(3)]
    txns += [cash_out('m4_out', '2026-10-06T12:00:00', 'm4', 'AG-Q', 'ring_b'), cash_out('x_out', '2026-10-06T13:00:00', 'x', 'AG-Q')]
    txns += [cash_out(f'late{i}', at('2026-10-14T09:00:00', minutes=i), f'cust_bg{i}', 'AG-B') for i in range(5)]
    if one_victim_mule:
        txns += [pay('p5', '2026-10-08T14:00:00', 'victim_c', 'm5', 3200.0),
                 cash_out('m5_out', '2026-10-08T15:00:00', 'm5', 'AG-Q', 'ring_c')]
    labels = [dict(acct_id=f'm{i}', ring_id='ring_a', role='mule_L1', typology='fan_in_fan_out',
                   first_bad_ts='2026-09-20T10:00:00') for i in (1, 2, 3)]
    labels += [dict(acct_id='m4', ring_id='ring_b', role='mule_L1', typology='fan_in_fan_out', first_bad_ts='2026-10-06T09:00:00')]
    labels += [dict(acct_id=f'victim{i}', ring_id='ring_b', role='victim', typology='fan_in_fan_out', first_bad_ts=None)
               for i in range(3)]
    if one_victim_mule:
        labels += [dict(acct_id='m5', ring_id='ring_c', role='mule_L1', typology='fan_in_fan_out',
                        first_bad_ts='2026-10-08T14:00:00'),
                   dict(acct_id='victim_c', ring_id='ring_c', role='victim', typology='fan_in_fan_out', first_bad_ts=None)]
    path.mkdir(parents=True, exist_ok=True)
    for name, rows in (('transactions', txns), ('agents', AGENTS), ('labels', labels)):
        (path/f'{name}.jsonl').write_text(''.join(json.dumps(row) + '\n' for row in rows))
    (path/'config.json').write_text(json.dumps(dict(seed=1, start_date='2026-10-01', days=14)))
    (path/'CHECKSUM').write_text('fixture\n')
    return path


def co(txn_id, ts, acct, till):
    return CashOut(txn_id=txn_id, ts=ts, acct=acct, till=till, amount_bdt=1.0, lat=23.8, lon=90.4, district='Dhaka')


TRUTH = Truth(mules=frozenset({'m1', 'm4', 'm5'}), victims=frozenset({'v'}),
              confirmed_at={'m1': '2026-10-01T00:00:00', 'm4': '2026-10-09T09:00:00', 'm5': '2026-10-30T00:00:00'},
              rings={'m1': ('r',), 'm4': ('r',), 'm5': ('s',), 'v': ('r',)}, roles={})


# --- the scoring rules -------------------------------------------------------------------------------------------

def test_a_till_is_right_when_a_not_yet_confirmed_mule_cashes_out_there_within_seven_days():
    events = (co('a', '2026-10-06T12:00:00', 'm4', 'T1'),  # inside the week, not yet confirmed
              co('b', '2026-10-03T12:00:00', 'm1', 'T2'),  # a mule already confirmed at the check
              co('c', '2026-10-12T00:00:01', 'm5', 'T3'),  # one second past the week
              co('d', '2026-10-12T00:00:00', 'm5', 'T4'),  # the last second of the week
              co('e', '2026-10-04T00:00:00', 'cust', 'T5'),  # a customer
              co('f', '2026-10-05T00:00:00', 'm5', 'T6'))  # at the check itself: not after it
    assert right_tills(events, TRUTH, '2026-10-05T00:00:00', frozenset({'m1'})) == {'T1', 'T4'}
    assert right_tills(events, TRUTH, '2026-10-05T00:00:00', frozenset({'m1', 'm4'})) == {'T4'}


def test_a_candidate_counts_once_on_the_first_day_it_appears():
    runs = ({'as_of': '2026-10-05T00:00:00', 'candidates': [dict(acct='x', source='till_reuse', filter=FTS)]},
            {'as_of': '2026-10-06T00:00:00', 'candidates': [dict(acct='x', source='cluster:c', filter=PT),
                                                            dict(acct='y', source='till_reuse', filter=FTS)]})
    assert [(c['acct'], c['first_day']) for c in first_candidates(runs)] == [('x', '2026-10-05T00:00:00'),
                                                                               ('y', '2026-10-06T00:00:00')]
    assert [(c['acct'], c['first_day']) for c in first_candidates(runs, PT)] == [('x', '2026-10-06T00:00:00')]
    assert [c['acct'] for c in first_candidates(runs, FTS)] == ['x', 'y']


def test_lead_time_is_days_from_the_first_candidate_day_to_confirmation():
    assert lead_days('2026-10-09T09:00:00', '2026-10-07T00:00:00') == pytest.approx(2.375)
    assert lead_days('2026-10-07T00:00:00', '2026-10-07T00:00:00') == 0


def test_day_boundaries_run_at_every_midnight_after_the_first_cashout_through_the_last_day():
    events = (co('a', '2026-10-01T03:00:00', 'c', 'T'), co('b', '2026-10-03T23:59:59', 'c', 'T'))
    assert day_boundaries(events) == ('2026-10-02T00:00:00', '2026-10-03T00:00:00', '2026-10-04T00:00:00')


def test_truth_reads_mules_victims_and_confirmation_with_the_lag(tmp_path):
    rows, truth = read_truth(world(tmp_path/'w'))
    assert truth.mules == {'m1', 'm2', 'm3', 'm4'} and truth.victims == {'victim0', 'victim1', 'victim2'}
    assert truth.confirmed_at['m4'] == at('2026-10-06T09:00:00', days=config.CONFIRMATION_LAG_DAYS)
    assert truth.rings['m4'] == ('ring_b',)
    assert {key for row in rows for key in row} == {'acct_id', 'role', 'ring_id', 'typology', 'first_bad_ts'}


# --- the fixture world end to end --------------------------------------------------------------------------------

def test_the_fixture_world_gives_every_measure_exactly(tmp_path):
    result = evaluate_world(world(tmp_path/'w'))
    assert result['status'] == 'run' and result['missing'] == []
    s = result['summary']
    assert s['days_run'] == 14 and s['first_day'] == '2026-10-02T00:00:00' and s['last_day'] == '2026-10-15T00:00:00'
    flags = s['till_flags']
    assert flags['per_day'] == 1.0 and flags['distinct_tills'] == 1 and flags['scored_days'] == 7
    assert flags['scored_till_days'] == 7 and flags['right'] == 5 and flags['precision'] == pytest.approx(5 / 7)
    assert flags['base_rate'] == pytest.approx(5 / 14)  # two open tills on each of the seven scored days
    assert list(s['filters']) == [FTS, PT]
    for name in (FTS, PT):  # m4 and x took 3000 from three strangers each and cashed out 3000: both filters name them
        f = s['filters'][name]
        cands = f['candidates']
        assert (cands['total'], cands['true'], cands['false']) == (2, 1, 1) and cands['precision'] == 0.5, name
        assert cands['false_per_week'] == pytest.approx(1 / 2)
        assert cands['lead_days'] == dict(min=pytest.approx(2.375), median=pytest.approx(2.375),
                                          mean=pytest.approx(2.375), max=pytest.approx(2.375))
        assert f['held_back'] == dict(accounts=3, mules=0, victims=0, unlabelled=3, most_first_time_senders=0,
                                      most_new_counterparties=0)  # cust_q0-2
        recall = f['recall_of_the_lead']
        assert (recall['future_confirmed_mules'], recall['cashed_out_before_confirmation'], recall['caught']) == (1, 1, 1)
        assert recall['recall'] == 1.0 and recall['recall_of_reachable'] == 1.0
    assert s['live_clusters'] == 1 and s['replayed_clusters']['clusters'] == 1 and s['replayed_clusters']['events'] == 1
    replayed = result['replayed_clusters'][0]
    assert (replayed['seed_accounts'], replayed['other_accounts'], replayed['other_mules'], replayed['other_unlabelled']) == (3, 3, 0, 3)
    assert replayed['rings'] == ['ring_a'] and replayed['first_day'] == '2026-10-02T00:00:00'
    assert replayed['candidates'] == {FTS: 0, PT: 0} and replayed['true_candidates'] == {FTS: 0, PT: 0}
    found = {(c['acct'], c['filter']): c for c in result['candidates']}
    assert set(found) == {('m4', FTS), ('x', FTS), ('m4', PT), ('x', PT)}
    assert found['m4', FTS]['first_day'] == '2026-10-07T00:00:00' and found['m4', FTS]['labelled'] == 'mule'
    assert found['x', PT]['labelled'] == 'unlabelled' and found['x', PT]['lead_days'] is None
    assert (found['m4', PT]['new_counterparties'], found['m4', PT]['received_bdt'], found['m4', PT]['cashed_out_bdt']) == (
        3, 3000.0, 3000.0)
    day = next(d for d in result['days'] if d['as_of'] == '2026-10-07T00:00:00')
    assert (day['till_flags'], day['right']) == (1, 0)
    assert day['new_candidates'] == {FTS: 2, PT: 2} and day['new_true_candidates'] == {FTS: 1, PT: 1}


def test_a_one_victim_mule_is_named_only_by_the_pass_through_filter(tmp_path):
    s = evaluate_world(world(tmp_path/'w', one_victim_mule=True))['summary']
    first, through = s['filters'][FTS], s['filters'][PT]
    assert (first['candidates']['total'], first['candidates']['true']) == (2, 1)  # m4 and x, as before
    assert first['held_back'] == dict(accounts=4, mules=1, victims=0, unlabelled=3, most_first_time_senders=1,
                                      most_new_counterparties=1)  # m5 had one first-time sender
    assert (first['recall_of_the_lead']['caught'], first['recall_of_the_lead']['future_confirmed_mules']) == (1, 2)
    cands = through['candidates']
    assert (cands['total'], cands['true'], cands['false']) == (3, 2, 1) and cands['precision'] == pytest.approx(2 / 3)
    assert cands['false_per_week'] == pytest.approx(1 / 2)
    m5_lead = 2 + 14 / 24  # named at the 10-09 run, confirmed 10-11 14:00
    assert cands['lead_days'] == dict(min=pytest.approx(2.375), median=pytest.approx((2.375 + m5_lead) / 2),
                                      mean=pytest.approx((2.375 + m5_lead) / 2), max=pytest.approx(m5_lead))
    recall = through['recall_of_the_lead']
    assert (recall['future_confirmed_mules'], recall['cashed_out_before_confirmation'], recall['caught']) == (2, 2, 2)
    assert through['held_back'] == dict(accounts=3, mules=0, victims=0, unlabelled=3, most_first_time_senders=0,
                                        most_new_counterparties=0)


def test_cli_writes_json_and_markdown_and_a_missing_world_exits_two(tmp_path):
    seed, out = world(tmp_path/'w'), tmp_path/'results'/'cashout.json'
    assert main(['--seed-dir', str(seed), '--out', str(out)]) == 0
    report = json.loads(out.read_text())
    assert json.loads(json.dumps(report, allow_nan=False)) == report
    assert [w['world'] for w in report['worlds']] == ['w'] and report['config']['TILL_REUSE_P_THRESHOLD'] == config.TILL_REUSE_P_THRESHOLD
    text = out.with_suffix('.md').read_text()
    assert '# Common point of cash-out: rolling evaluation' in text and '| Candidate precision' in text
    for word in ('synthetic', 'lead', 'verdict', 'confirmation lag', 'till flag', 'pass-through', 'added after',
                 'one synthetic world', 'first_time_senders', 'pass_through', 'before its own measurement'):
        assert word in text.lower(), word
    assert '## Candidate filters side by side' in text
    assert main(['--seed-dir', str(seed), '--seed-dir', str(tmp_path/'absent'), '--out', str(out)]) == 2
    worlds = {w['world']: w for w in json.loads(out.read_text())['worlds']}
    assert worlds['absent']['status'] == 'missing' and worlds['absent']['missing'] and worlds['w']['status'] == 'run'
    broken = world(tmp_path/'broken')
    (broken/'labels.jsonl').write_text(json.dumps(dict(acct_id='m', role='mule_L1')) + '\n')  # no first bad event
    assert main(['--seed-dir', str(broken), '--out', str(out)]) == 2
    assert 'first_bad_ts' in json.loads(out.read_text())['worlds'][0]['missing'][0]


def test_the_rules_see_no_ring_id(tmp_path, monkeypatch):
    import cashout_eval
    seen = []
    real = cashout_eval.run_cashout

    def spy(bundle, as_of, seeds_at):
        seen.extend(row for rows in bundle.txns_by_acct.values() for row in rows)
        return real(bundle, as_of, seeds_at)
    monkeypatch.setattr(cashout_eval, 'run_cashout', spy)
    evaluate_world(world(tmp_path/'w'))
    assert seen and not any('ring_id' in row for row in seen)


SEED_CAMPAIGN = Path(__file__).resolve().parents[3]/'data'/'seed-campaign'


@pytest.mark.skipif(not (SEED_CAMPAIGN/'labels.jsonl').exists(), reason='data/seed-campaign has not been generated')
def test_campaign_world_runs_daily_and_no_candidate_is_a_seed_on_its_day():
    result = evaluate_world(SEED_CAMPAIGN)
    assert result['status'] == 'run' and result['summary']['days_run'] >= 30
    assert all(c['lead_days'] is None or c['lead_days'] >= 0 for c in result['candidates'])
