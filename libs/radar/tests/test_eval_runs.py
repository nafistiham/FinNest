"""What the first run on the campaign world needs from the harness: bursts outside the payment stream,
benign-only and mixed counts per burst, the flag firing per campaign, and the campaign-free replay's shape."""
import json

from fixtures import seed_fixture
from radar_eval import campaign_free, evaluate, main
from bhorosha_radar.config import CELL_TYPES
from bhorosha_radar.measures import in_payment_stream
from truth import Burst


def _wedding_of_cash_outs_only(seed):
    path=seed/'bursts.jsonl'
    rows=[json.loads(line) for line in path.read_text().splitlines()]
    rows=[dict(b,types=['cash_out']) if b['kind']=='wedding' else b for b in rows]
    path.write_text(''.join(json.dumps(b)+'\n' for b in rows))


def test_a_burst_with_no_payment_type_is_outside_the_stream():
    def burst(types):
        return Burst('b','b','2026-10-17T10:00:00','2026-10-17T11:00:00',(),types)
    assert CELL_TYPES==('send_money',)
    assert not in_payment_stream(burst(('cash_out',)))
    assert in_payment_stream(burst(('salary','cash_out','send_money'))) and in_payment_stream(burst(()))


def test_burst_membership_is_half_open_like_the_bursts_contract():
    from types import SimpleNamespace
    from bhorosha_radar.measures import burst_attempt_ids
    burst=Burst('b','b','2026-10-17T10:00:00','2026-10-17T11:00:00',(),('send_money',))
    attempts=[SimpleNamespace(attempt_id=ts,ts=ts,sender='s',payee='p',type='send_money')
              for ts in ('2026-10-17T10:00:00','2026-10-17T10:59:59','2026-10-17T11:00:00')]
    assert burst_attempt_ids(burst,attempts)=={'2026-10-17T10:00:00','2026-10-17T10:59:59'}


def test_cash_out_only_burst_is_reported_outside_the_stream_and_the_measure_names_what_it_covers(tmp_path):
    seed=seed_fixture(tmp_path/'seed'); _wedding_of_cash_outs_only(seed)
    output=tmp_path/'out'/'campaign.json'
    assert main(['--seed-dir',str(seed),'--out',str(output)])==0
    report=json.loads(output.read_text())
    rows={r['burst_id']:r for r in report['benign']}
    assert rows['wedding']['status']=='outside stream' and rows['wedding']['incidents'] is None
    assert 'cash_out' in rows['wedding']['reason']
    benign=report['measures']['benign_burst_incidents']
    assert benign['status']=='pass' and benign['value']==0
    assert benign['evaluated']==['payday_1','payday_2','hospital'] and benign['outside_stream']==['wedding']
    assert not report['missing']
    assert '| wedding | wedding | 0 | n/a | outside stream |' in (output.parent/'campaign.md').read_text()


def test_every_burst_outside_the_stream_leaves_the_measure_missing(tmp_path):
    seed=seed_fixture(tmp_path/'seed')
    path=seed/'bursts.jsonl'
    path.write_text(''.join(json.dumps(dict(json.loads(line),types=['cash_out']))+'\n' for line in path.read_text().splitlines()))
    assert evaluate(seed)['measures']['benign_burst_incidents']['status']=='missing'


def test_benign_rows_count_benign_only_and_mixed_incidents_separately(tmp_path):
    report=evaluate(seed_fixture(tmp_path/'customer',shop_kind='customer'))
    payday=next(r for r in report['benign'] if r['burst_id']=='payday_1')
    assert (payday['benign_only'],payday['mixed'])==(1,0) and payday['incidents']==1
    assert payday['start']=='2026-10-10T10:00:00' and payday['end']=='2026-10-10T11:00:00'
    hospital=next(r for r in report['benign'] if r['burst_id']=='hospital')
    assert (hospital['benign_only'],hospital['mixed'],hospital['incidents'])==(0,0,0)


def test_campaign_row_names_the_flag_firing_the_senders_before_it_and_the_payees_found(tmp_path):
    row=evaluate(seed_fixture(tmp_path/'seed'))['campaigns'][0]
    assert row['first_ts']=='2026-10-17T10:00:00' and row['tenth_ts']=='2026-10-17T10:09:00'
    assert row['flag_ts']=='2026-10-17T10:15:00' and row['minutes_from_first_to_flag']==15
    assert row['senders_before_flag']==15  # attempts 10:00 to 10:14 precede the 10:15 run
    assert row['flag_firing']['k']>=10 and row['flag_firing']['reason'] in ('poisson','velocity_cap')
    assert {'key','cell','window_min','mu','p','held','allowed'}<=set(row['flag_firing'])
    assert (row['payees_found'],row['payees_total'])==(3,3) and row['till_found'] is False


def test_report_page_names_each_keys_dispersion_index_and_which_are_over_the_flag(tmp_path):
    from radar_eval import markdown
    report=evaluate(seed_fixture(tmp_path/'seed'))
    report['dispersion']={'payee':{'index':3.2,'overdispersed':True},'payee_till':{'index':None,'overdispersed':False}}
    text=markdown(report)
    assert 'Dispersion index per key' in text and 'payee 3.2 (over 1.5)' in text and 'payee_till n/a' in text


def test_dispersion_line_says_the_ten_sender_floor_keeps_a_burst_quiet_when_its_p_alone_would_fire(tmp_path):
    from radar_eval import markdown
    report=evaluate(seed_fixture(tmp_path/'seed'))
    report['dispersion']={'payee':{'index':3.2,'overdispersed':True}}
    for row in report['benign']:
        row.update(min_p=1e-3)
    assert 'not the p threshold' not in markdown(report)
    hospital=next(r for r in report['benign'] if r['burst_id']=='hospital')
    hospital.update(min_p=2.758e-25,max_k=7)
    assert ('hospital reached p 2.758e-25 with 7 senders, below P_THRESHOLD 1e-07: the ten-sender floor '
            '(MIN_DISTINCT_SENDERS 10), not the p threshold, keeps the benign bursts quiet.') in markdown(report)


def _overreach_fixture():
    from types import SimpleNamespace
    truth=SimpleNamespace(attempt_ids=frozenset({'a1','a2','a3'}),payees=frozenset({'p1'}))
    best=SimpleNamespace(attempt_ids=('a1','a2','a3','b1','b2'),payees=('p1','q1','q2'),
                         evidence=(('a1','a2','payee:p1'),('a1','b1','payee_till:T9'),('b1','b2','payee_onboarding_agent:AG-1')))
    by_id={i:SimpleNamespace(sender_district='Bhola') for i in ('a1','a2','a3','b1','b2')}
    return truth,best,by_id


def test_a_campaign_naming_more_payees_than_its_own_says_how_many_which_links_and_that_us2_fails():
    from radar_eval import payee_overreach
    truth,best,by_id=_overreach_fixture()
    assert payee_overreach(truth,best,by_id,frozenset({'a1','a2','a3'}))==(
        "names 3 payees against 1 true: two benign Bhola payments joined through shared till T9 and onboarding agent AG-1, "
        "so the spec's 3–5 payee criterion (US-2) fails for this campaign")
    exact=type(best)(attempt_ids=('a1','a2','a3'),payees=('p1',),evidence=(('a1','a2','payee:p1'),))
    assert payee_overreach(truth,exact,by_id,frozenset())is None and payee_overreach(truth,None,by_id,frozenset()) is None


def test_payee_note_names_every_overreaching_campaign_and_otherwise_says_none_does():
    from radar_eval import payee_note
    rows=[dict(campaign_id='ring_a',payee_overreach='names 3 payees against 1 true: x'),dict(campaign_id='ring_b',payee_overreach=None)]
    assert payee_note(rows)=='ring_a names 3 payees against 1 true: x.'
    assert payee_note([dict(campaign_id='ring_b',payee_overreach=None)])=="Every campaign's component names only its own payees (US-2)."
    assert payee_note([]) is None


def test_campaign_free_replay_is_not_run_for_a_seed_without_a_campaign_block(tmp_path):
    replay=campaign_free(seed_fixture(tmp_path/'seed'))
    assert replay['status']=='not run' and 'campaign' in replay['reason']
