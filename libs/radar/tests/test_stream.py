"""Reader schema, reject isolation, and historical enrichment boundaries."""
from dataclasses import replace
import json
from types import SimpleNamespace

from bhorosha_radar.stream import Attempt, amount_band, enrich, read_audit, read_seed, to_frame, to_local


def write_rows(path, rows):
    path.write_text(''.join(json.dumps(r) + '\n' for r in rows))


def attempt(**changes):
    return Attempt(**(dict(attempt_id='a', ts='2026-10-17T10:00:00', sender='s', payee='p',
                          amount_bdt=3000, type='send_money', is_new_payee=True, channel='app',
                          decision='hold', source='seed') | changes))


def audit(**changes):
    return dict(id='doc-1', kind='score', uid='rina', at='2026-10-17T04:00:00Z', processing_ms=12,
                inputs=dict(user_id='rina', txn=dict(type='send_money', amount_bdt=3000,
                            to_account='p', is_new_payee=True), demo_flags=dict(sim_swap=True)),
                outputs=dict(decision='hold', reasons=[])) | changes


def test_seed_preserves_every_decision_and_drops_extra_columns(tmp_path):
    decisions = ('allow', 'step_up', 'delay', 'hold', 'block')
    write_rows(tmp_path/'attempts.jsonl', [dict(attempt_id=str(i), ts='2026-10-17T10:00:00',
               from_acct='s', to_acct='p', amount_bdt=3000, type='send_money', is_new_payee=True,
               decision=d, channel='app', truth_campaign='hidden', ring_id='hidden') for i,d in enumerate(decisions)])
    got = read_seed(tmp_path)
    assert tuple(a.decision for a in got) == decisions
    assert all(a.payee == 'p' and a.source == 'seed' for a in got)
    assert not any('hidden' in str(a) for a in got)


def test_ledger_fallback_is_explicit_and_excludes_cashouts(tmp_path):
    write_rows(tmp_path/'transactions.jsonl', [dict(txn_id='t', ts='2026-10-17T10:00:00', from_acct='s',
               to_acct='p', amount_bdt=3000, type=t, channel='app') for t in ('send_money','cash_out')])
    got=read_seed(tmp_path)
    assert len(got)==1 and got[0].decision=='allow' and got[0].source=='ledger_only'


def test_audit_mapping_normalisation_and_rejects_are_per_document(tmp_path):
    rows = [audit(), audit(id='pin',inputs=dict(user_id='acct_known',txn=dict(type='pin_reset'),demo_flags={})),
            audit(id='other',kind='intervene'), audit(id='bad-decision',outputs=dict(decision='release')),
            audit(id='no-time',at=None), audit(id='bad-input',inputs=[]),
            audit(id='unknown',uid='unknown',inputs=dict(user_id='anonymous',txn=dict(type='send_money'),demo_flags={}))]
    path=tmp_path/'audit.jsonl'; write_rows(path, rows)
    got,rejects=read_audit(path, {'rina':'acct_rina'}, known_accounts={'acct_known'})
    assert len(got)==3 and len(rejects)==3
    assert got[0].sender=='acct_rina' and got[0].identity_source=='inputs.user_id_mapping'
    assert got[0].ts=='2026-10-17T10:00:00' and got[0].decision=='hold'
    assert got[0].sender_minutes_since_sim_change==0
    assert got[1].payee is None and got[1].sender=='acct_known'
    assert got[2].sender=='uid:unknown'
    assert {r['id'] for r in rejects}=={'bad-decision','no-time','bad-input'}


def test_malformed_json_and_nonobject_are_rejected_without_stopping_reader(tmp_path):
    path=tmp_path/'audit.jsonl'; path.write_text('not-json\n[]\n'+json.dumps(audit())+'\n')
    got,rejects=read_audit(path, {})
    assert len(got)==1 and len(rejects)==2


def test_uid_mapping_fallback_uses_document_uid(tmp_path):
    path=tmp_path/'audit.jsonl'; write_rows(path,[audit(inputs=dict(user_id='missing',txn=dict(type='pin_reset')))])
    got,_=read_audit(path, {'rina':'acct_rina'})
    assert got[0].sender=='acct_rina' and got[0].identity_source=='uid_mapping'


def test_enrichment_cannot_peek_at_future_devices_sim_or_cashout():
    bundle=SimpleNamespace(accounts={'s':dict(district='Dhaka'), 'p':dict(district='Bhola',onboarding_agent_id='ag',kind='customer')},
        device_links=(dict(acct_id='p',device_id='old',first_seen='2026-10-16T10:00:00'),
                      dict(acct_id='p',device_id='future',first_seen='2026-10-17T11:00:00')),
        sims=(dict(acct_id='p',activated_at='2026-10-01T00:00:00'),),
        sim_events=(dict(acct_id='p',event='swap',ts='2026-10-17T11:00:00'),
                    dict(acct_id='s',event='swap',ts='2026-10-17T09:00:00')),
        txns_by_acct={'p':(dict(type='cash_out',ts='2026-10-16T10:00:00',from_acct='p',to_acct='t',agent_id='opaque-7'),
                           dict(type='send_money',ts='2026-10-17T09:00:00',from_acct='p',to_acct='hop'),
                           dict(type='cash_out',ts='2026-10-17T11:00:00',from_acct='p',to_acct='other',agent_id='future'))})
    original=attempt(); got=enrich((original,),bundle)[0]
    assert original.payee_devices==() and got.payee_devices==('old',)
    assert got.payee_till=='opaque-7' and got.payee_sim_day=='2026-10-01'
    assert got.payee_next_hops==('hop',) and got.sender_minutes_since_sim_change==60
    assert got.sender_district=='Dhaka' and got.payee_district=='Bhola'
    assert got.payee_onboarding_agent=='ag' and got.payee_kind=='customer'
    assert enrich((replace(original,ts='2026-12-17T10:00:00'),),bundle)[0].payee_sim_day is None


def test_cells_explode_devices_dedupe_and_filter_sender_new_payee_only():
    a=replace(attempt(),payee_devices=('d1','d1','d2'), sender_district='Dhaka')
    assert list(to_frame((a,), 'payee_device')['cell'])==['d1','d2']
    assert to_frame((replace(a,is_new_payee=False),),'sender_district').empty
    assert to_frame((replace(a,type='cash_out'),),'payee').empty
    assert len(to_frame((a,), 'payee'))==1


def test_timezone_and_amount_bands():
    assert to_local('2026-10-17T23:30:00-02:00')=='2026-10-18T07:30:00'
    assert to_local('2026-10-17T10:00:00')=='2026-10-17T10:00:00'
    assert amount_band(499)!=amount_band(500)
    assert amount_band(3000)==amount_band(4999)


def test_malformed_audit_payee_is_rejected_before_enrichment(tmp_path):
    path=tmp_path/'audit.jsonl'
    write_rows(path,[audit(),audit(id='bad',inputs=dict(user_id='rina',txn=dict(type='send_money',to_account=['bad'],amount_bdt=3000)))])
    got,rejects=read_audit(path,{'rina':'acct_rina'})
    assert len(got)==1 and len(rejects)==1 and rejects[0]['id']=='bad'
    bundle=SimpleNamespace(accounts={},device_links=(),sims=(),sim_events=(),txns_by_acct={})
    assert len(enrich(got,bundle))==1


def test_malformed_audit_primitives_are_individual_rejects(tmp_path):
    path=tmp_path/'audit.jsonl'
    rows=[audit()]
    rows += [audit(id=str(i),inputs=dict(user_id='rina',txn={'type':'send_money'}|txn)) for i,txn in enumerate(
        ({'type':[]},{'is_new_payee':'false'},{'to_account':''},{'amount_bdt':True}))]
    write_rows(path,rows)
    got,rejects=read_audit(path,{'rina':'acct_rina'})
    assert len(got)==1 and len(rejects)==4
