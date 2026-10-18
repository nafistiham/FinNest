"""Closed-form tails, historical baseline, routing guards, and immutable run snapshots."""
from dataclasses import FrozenInstanceError, replace
from datetime import datetime, timedelta
import math
from types import SimpleNamespace

import numpy as np
import pandas as pd
import pytest

from bhorosha_radar.baseline import Baseline, cell_universe, nominal_budget
from bhorosha_radar.stream import Attempt
from bhorosha_radar.surprise import cell_tests, detect, incidents, poisson_tail


def a(i=0, **changes):
    return Attempt(**(dict(attempt_id=str(i), ts=f'2026-10-17T10:{i:02d}:00', sender=f's{i}', payee='p',
       amount_bdt=3000, type='send_money', is_new_payee=True, channel='app', decision='hold' if i%2 else 'allow',
       source='seed') | changes))


def row(**changes):
    return dict(run_ts='2026-10-17T10:15:00',key='payee',cell='p',window_min=15,k=12,mu=.5,p=.5,
                surprise=.3,attempt_ids=('a',),busy=False,baseline_source='prior',payday_factor=1.0,
                held_ids=('a',),allowed_ids=()) | changes


@pytest.mark.parametrize('k',range(6))
def test_poisson_tail_agrees_with_closed_form(k):
    mu=.7
    want=1-sum(math.exp(-mu)*mu**i/math.factorial(i) for i in range(k))
    assert float(poisson_tail(np.array([k]),np.array([mu]))[0])==pytest.approx(want,abs=1e-14)


def test_tail_known_low_probability_cases_and_zero_count():
    result=poisson_tail(np.array([30,10,10,0]),np.array([3,.08,1,0]))
    assert result[0]==pytest.approx(4.277e-20,rel=.001)
    assert result[1]==pytest.approx(2.755e-18,rel=.01)
    assert result[2]==pytest.approx(1.114e-7,rel=.001)
    assert result[3]==1


def test_baseline_pools_one_week_and_uses_matching_prior_slots_only():
    rows=(a(0,ts='2026-10-10T10:00:00'), a(1,ts='2026-10-10T10:15:00'),
          a(2,ts='2026-10-10T11:00:00'), a(3,ts='2026-10-17T10:01:00'))
    b=Baseline(rows,{'payee':2},'2026-10-10T00:00:00','2026-10-18T00:00:00')
    # Two senders / one prior week in p, pooled rate = 2 / 2 cells = 1.
    assert b.rate('payee','p','2026-10-17T10:00:00')==(1.5,'prior')
    assert b.rate('payee','unseen','2026-10-17T10:00:00')==(.5,'prior')
    assert b.rate('payee','p','2026-10-10T10:00:00')[1]=='backfill'
    assert b.rate('payee','p','2026-10-10T10:00:00')[0]==.75


def test_baseline_cold_start_explicit_and_payday_default_applies_to_mu():
    b=Baseline((),{'payee':1},'2026-10-01T00:00:00','2026-10-03T00:00:00')
    assert b.rate('payee','p','2026-10-01T10:00:00')[1]=='cold_start'
    assert b.payday_factor('payee','2026-10-10T10:00:00')==3
    assert b.payday_factor('payee','2026-10-12T10:00:00')==1
    assert b.expected('payee','p','2026-10-10T10:15:00',15)[0]==pytest.approx(0.000075)


def test_velocity_cap_only_small_baseline_and_nonbusy_cells():
    tests=pd.DataFrame([row(),row(cell='high',mu=12),row(cell='till',key='payee_till'),row(cell='merchant',busy=True)])
    got=detect(tests)
    assert len(got)==1 and got[0].cell=='p' and got[0].reason=='velocity_cap'
    assert detect(pd.DataFrame([row(k=6,p=1e-20)]))==()


def test_receiving_cells_first_and_busy_cells_still_use_poisson():
    got=detect(pd.DataFrame([row(key='sender_district',p=1e-10),row(key='payee_till',p=1e-10,busy=True),row(p=1e-10)]))
    assert [f.key for f in got]==['payee','payee_till','sender_district']
    assert all(f.reason=='poisson' for f in got)


def test_runs_are_half_open_and_repeated_sender_not_counted_twice():
    attempts=tuple(a(i) for i in range(15))+(a(15),a(16,sender='s0',ts='2026-10-17T10:14:30'))
    tests=cell_tests(attempts,{'payee':1},'2026-10-17T10:00:00','2026-10-17T10:30:00')
    first=tests[(tests.run_ts=='2026-10-17T10:15:00') & (tests.window_min==15)].iloc[0]
    assert first.k==15 and len(first.attempt_ids)==16
    assert '15' not in first.attempt_ids
    firings=detect(tests)
    assert firings and all(next(a.ts for a in attempts if a.attempt_id==i)<f.run_ts for f in firings for i in f.attempt_ids)
    assert any(f.baseline_source=='cold_start' for f in firings)
    with pytest.raises(FrozenInstanceError):
        firings[0].k=0


def test_incident_as_of_excludes_later_firing_and_preserves_initial_flag_snapshot():
    firings=detect(pd.DataFrame([row(p=1e-10), row(run_ts='2026-10-17T11:00:00',p=1e-10,attempt_ids=('b',),held_ids=(),allowed_ids=('b',))]))
    early=incidents(firings,as_of='2026-10-17T10:30:00')[0]
    final=incidents(firings)[0]
    assert early.attempt_ids==('a',) and early.opened_at=='2026-10-17T10:15:00'
    assert final.attempt_ids==('a','b') and final.held==1 and final.allowed==1
    assert early.last_fired_at=='2026-10-17T10:15:00'


def test_universe_counts_available_entities_and_reports_nominal_p_branch_only():
    bundle=SimpleNamespace(accounts={'p':dict(district='Dhaka',onboarding_agent_id='agent')},
                           device_links=(dict(device_id='d'),), sims=(dict(activated_at='2026-10-01T00:00:00'),),
                           sim_events=(),agents={'agent':{}})
    counts=cell_universe(bundle)
    assert counts['payee']==1 and counts['sender_district_band']==6
    assert nominal_budget({'payee':100})==pytest.approx(.02016)
    assert nominal_budget({'payee':100})<1


def test_incident_statistics_come_from_one_firing():
    firings=detect(pd.DataFrame([row(k=30,mu=3,p=1e-20,surprise=20),row(k=40,mu=30,p=1e-8,surprise=8,run_ts='2026-10-17T10:30:00')]))
    incident=incidents(firings)[0]
    assert (incident.observed,incident.expected,incident.p_value,incident.surprise)==(30,3,1e-20,20)


def test_unseen_future_device_cannot_change_prior_baseline_firing():
    from bhorosha_radar.baseline import causal_universe
    prior=tuple(a(i,attempt_id=f'old{i}',ts='2026-10-10T10:00:00',sender=f'old{i}',payee_devices=('old',)) for i in range(16))
    current=tuple(a(i,payee_devices=('new',)) for i in range(10))
    attempts=prior+current
    bundle=SimpleNamespace(accounts={'p':dict(opened_at='2026-10-01T00:00:00',district='Dhaka')},
        device_links=(dict(acct_id='p',device_id='old',first_seen='2026-10-01T00:00:00'),
                      dict(acct_id='p',device_id='new',first_seen='2026-10-17T10:00:00')),
        sims=(),sim_events=(),agents={})
    before=cell_tests(attempts,{'payee_device':2},'2026-10-10T00:00:00','2026-10-18T00:00:00',universe_at=causal_universe(bundle,attempts))
    bundle.device_links+= (dict(acct_id='p',device_id='future',first_seen='2026-10-18T00:00:00'),)
    after=cell_tests(attempts,{'payee_device':3},'2026-10-10T00:00:00','2026-10-18T00:00:00',universe_at=causal_universe(bundle,attempts))
    for tests in (before,after):
        selected=tests[(tests.cell=='new') & (tests.run_ts=='2026-10-17T10:15:00') & (tests.window_min==15)]
        r=selected.iloc[0]
        assert r.k==10 and r.mu==1 and r.baseline_source=='prior'
        assert detect(selected)==()


def test_busy_flag_covers_till_cells_and_merchant_or_till_payees_only():
    from bhorosha_radar.stream import to_frame
    for kind,busy in (('merchant',True),('agent_till',True),('customer',False),(None,False)):
        assert list(to_frame((a(0,payee_kind=kind),),'payee').busy)==[busy],kind
    assert list(to_frame((a(0,payee_till='AG-1'),),'payee_till').busy)==[True]
    assert list(to_frame((a(0,payee_onboarding_agent='AG-1',payee_kind='merchant'),),'payee_onboarding_agent').busy)==[False]


def test_velocity_cap_boundary_is_mu_max_inclusive():
    from bhorosha_radar.config import VELOCITY_CAP, VELOCITY_CAP_MU_MAX
    for window,cap in VELOCITY_CAP.items():
        at_max=detect(pd.DataFrame([row(window_min=window,k=cap,mu=VELOCITY_CAP_MU_MAX,p=.5)]))
        above=detect(pd.DataFrame([row(window_min=window,k=cap,mu=np.nextafter(VELOCITY_CAP_MU_MAX,np.inf),p=.5)]))
        below_cap=detect(pd.DataFrame([row(window_min=window,k=cap-1,mu=.1,p=.5)]))
        assert [f.reason for f in at_max]==['velocity_cap'] and above==() and below_cap==()


def test_one_cell_firing_in_all_three_windows_is_one_incident():
    import hashlib
    firings=detect(pd.DataFrame([row(window_min=15,p=1e-10,surprise=10),row(window_min=60,p=1e-12,surprise=12,attempt_ids=('a','b'),held_ids=('a','b')),
                                 row(window_min=180,p=1e-9,surprise=9,attempt_ids=('a','c'),held_ids=('a',),allowed_ids=('c',))]))
    assert len(firings)==3
    got=incidents(firings)
    assert len(got)==1
    incident=got[0]
    assert incident.window_min==60 and incident.surprise==12 and incident.attempt_ids==('a','b','c')
    assert incident.held==2 and incident.allowed==1
    assert incident.incident_id=='inc_'+hashlib.sha1('payee|p|2026-10-17T10:15:00'.encode()).hexdigest()[:12]


def test_universe_counts_only_sim_days_that_can_be_recent_inside_the_world():
    bundle=SimpleNamespace(accounts={'p':dict(district='Dhaka')},device_links=(),agents={},
        sims=(dict(acct_id='p',activated_at='2025-01-01T00:00:00'),dict(acct_id='q',activated_at='2026-09-07T00:00:00'),
              dict(acct_id='r',activated_at='2026-09-06T23:00:00')),
        sim_events=(dict(acct_id='p',event='swap',ts='2026-10-20T08:00:00'),))
    assert cell_universe(bundle)['payee_sim_day']==4
    # World starts 2026-10-07: only days on or after 2026-09-07 can ever be within SIM_DAY_RECENT_DAYS of a run.
    assert cell_universe(bundle,world_start='2026-10-07T00:00:00')['payee_sim_day']==2
