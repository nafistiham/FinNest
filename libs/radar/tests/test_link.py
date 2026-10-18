from dataclasses import replace
from types import SimpleNamespace

import pandas as pd
import pytest

from bhorosha_radar.link import link, payee_links, relations, synchrony
from bhorosha_radar.stream import Attempt
from bhorosha_radar.surprise import detect


def attempt(i,**changes):
    return Attempt(**(dict(attempt_id=f'a{i}',ts=f'2026-10-17T09:{i:02d}:00',sender=f's{i}',payee=f'p{i%3}',
       amount_bdt=3000,type='send_money',is_new_payee=True,channel='app',decision='hold' if i%2 else 'allow',
       source='seed',payee_onboarding_agent='shared') | changes))


def firing(ids,ts='2026-10-17T10:00:00'):
    return detect(pd.DataFrame([dict(run_ts=ts,key='payee_onboarding_agent',cell='shared',window_min=180,
        k=30,mu=1,p=1e-20,surprise=20,attempt_ids=tuple(ids),busy=False,baseline_source='prior',payday_factor=1,
        held_ids=(),allowed_ids=())]))[0]


def rel():
    return relations(SimpleNamespace(accounts={'p0':{'onboarding_agent_id':'shared','opened_at':'2026-10-01T00:00:00'}},
        device_links=({'acct_id':'p0','device_id':'old','first_seen':'2026-10-16T10:00:00'},
                      {'acct_id':'p0','device_id':'future','first_seen':'2026-10-17T11:00:00'}),sims=(),sim_events=()))


def test_link_explains_shared_entities_keeps_all_decisions_and_excludes_noise():
    attempts={f'a{i}':attempt(i) for i in range(6)}
    attempts['noise']=attempt(7,attempt_id='noise',payee='unrelated',payee_onboarding_agent=None)
    campaigns=link((firing(attempts),),attempts,rel(),'2026-10-17T10:00:00')
    assert len(campaigns)==1
    c=campaigns[0]
    assert c.attempt_ids==tuple(f'a{i}' for i in range(6))
    assert c.senders==tuple(f's{i}' for i in range(6)) and c.held==3 and c.allowed==3
    assert len(c.evidence)==5 and any('payee_onboarding_agent:shared'==e[2] for e in c.evidence)
    assert c.concentration==2 and c.allowed_bdt==9000
    assert len(link((firing(('a0','a1')),),attempts,rel(),'2026-10-17T10:00:00'))==0


def test_link_snapshot_cannot_see_later_firings_attempts_or_relations():
    attempts={f'a{i}':attempt(i) for i in range(6)}
    attempts['future']=attempt(7,attempt_id='future',ts='2026-10-17T10:00:00')
    c=link((firing(attempts),firing(attempts,'2026-10-17T11:00:00')),attempts,rel(),'2026-10-17T10:00:00')[0]
    assert 'future' not in c.attempt_ids
    assert all('future' not in str(edge) for edge in c.payee_links)
    assert {r['entity'] for r in payee_links(rel(),('p0',),'2026-10-17T10:00:00')}=={'device:old','onboarding_agent:shared'}


def test_link_lookback_uses_incident_opening_within_24_hours():
    early={f'a{i}':attempt(i,ts=f'2026-10-16T10:{i:02d}:00') for i in range(6)}
    later={f'b{i}':attempt(i,attempt_id=f'b{i}',ts=f'2026-10-17T09:{i:02d}:00') for i in range(6)}
    all_attempts=early|later
    fs=(firing(early,'2026-10-16T10:15:00'),firing(later,'2026-10-17T09:15:00'))
    assert len(link(fs,all_attempts,rel(),'2026-10-17T10:00:00')[0].attempt_ids)==12
    assert len(link(fs,all_attempts,rel(),'2026-10-17T12:00:00')[0].attempt_ids)==6


def test_synchrony_is_largest_10_minute_span():
    from datetime import datetime,timedelta
    ts=[(datetime(2026,10,17,10)+timedelta(minutes=3*i)).isoformat() for i in range(30)]
    assert synchrony(ts)==pytest.approx(4/30)
    assert synchrony([])==0


def test_link_ignores_an_earlier_attempt_that_only_a_later_firing_holds():
    attempts={f'a{i}':attempt(i) for i in range(6)}
    attempts['late_only']=attempt(30,attempt_id='late_only',ts='2026-10-17T09:30:00')
    early=firing({k:v for k,v in attempts.items() if k!='late_only'})
    later=firing(attempts,'2026-10-17T11:00:00')
    assert 'late_only' in later.attempt_ids and attempts['late_only'].ts<'2026-10-17T10:00:00'
    c=link((early,later),attempts,rel(),'2026-10-17T10:00:00')[0]
    assert 'late_only' not in c.attempt_ids and len(c.attempt_ids)==6
    assert 'late_only' in link((early,later),attempts,rel(),'2026-10-17T11:00:00')[0].attempt_ids
