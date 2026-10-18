import json
from pathlib import Path
import subprocess
import sys

import pytest

from fixtures import seed_fixture
from radar_eval import evaluate, main
from truth import load_truth
from bhorosha_radar.stream import read_seed, to_frame


def test_truth_payments_exclude_cashout_outcomes_and_all_are_detector_visible(tmp_path):
    seed=seed_fixture(tmp_path/'seed')
    campaigns,bursts,all_ids,issues=load_truth(seed)
    assert issues==() and len(campaigns)==1 and len(bursts)==4
    t=campaigns[0]
    assert len(t.attempt_ids)==30 and len(t.victims)==30
    assert len(t.allowed)==11 and t.cashouts==(('2026-10-17T10:31:00',1000),)
    visible=set(to_frame(read_seed(seed),'payee').attempt_id)
    assert t.attempt_ids <= visible and 'outcome' not in t.attempt_ids
    assert len(all_ids)==30


def test_fixture_acceptance_runs_all_stages_and_writes_finite_artifacts(tmp_path):
    seed=seed_fixture(tmp_path/'seed'); output=tmp_path/'result'/'campaign.json'
    assert main(['--seed-dir',str(seed),'--out',str(output)])==0
    report=json.loads(output.read_text())
    assert all(m['status']=='pass' for m in report['measures'].values())
    assert report['measures']['time_to_flag_min']['value']==6
    assert report['measures']['campaign_recall']['value']==1
    assert report['campaigns'][0]['allowed_by_flag']==33000
    assert report['campaigns'][0]['retained_fraction']==1
    assert report['live']['status']=='not run' and report['false_incidents_per_week']['campaign_free_replay']['status']=='not run'
    for name in ('campaign.md','radar_firings.jsonl','radar_incidents.jsonl','radar_campaigns.jsonl'):
        assert (output.parent/name).exists()
    assert len((output.parent/'radar_campaigns.jsonl').read_text().splitlines())>=1
    assert 'Fixture' in (output.parent/'campaign.md').read_text() or 'synthetic' in (output.parent/'campaign.md').read_text()


def test_absent_campaign_data_never_passes_acceptance(tmp_path):
    seed=tmp_path/'seed'; seed.mkdir()
    output=tmp_path/'campaign.json'
    assert main(['--seed-dir',str(seed),'--out',str(output)])==2
    report=json.loads(output.read_text())
    assert set(m['status'] for m in report['measures'].values())=={'missing'}
    assert 'attempts.jsonl' in ' '.join(report['missing'])
    assert not report['campaigns']


def test_benign_bursts_missing_cannot_be_reported_zero(tmp_path):
    seed=seed_fixture(tmp_path/'seed'); (seed/'bursts.jsonl').unlink()
    report=evaluate(seed)
    assert report['measures']['benign_burst_incidents']['status']=='missing'
    assert report['measures']['campaign_precision']['status']=='pass'


def test_campaigns_missing_are_missing_not_zero_or_pass(tmp_path):
    seed=seed_fixture(tmp_path/'seed'); (seed/'labels.jsonl').write_text('')
    report=evaluate(seed)
    assert report['measures']['campaign_precision']['status']=='missing'
    assert report['measures']['victim_coverage']['status']=='missing'


def test_audit_cli_is_reader_sanity_only_and_rejects_are_visible(tmp_path):
    from test_stream import audit
    path=tmp_path/'audit.jsonl'; path.write_text(json.dumps(audit())+'\n')
    output=tmp_path/'campaign.json'
    assert main(['--audit',str(path),'--seed-dir',str(tmp_path/'no-seed'),'--out',str(output)])==0
    report=json.loads(output.read_text())
    assert report['mode']=='audit_reader' and report['stage0']['attempts']==1
    assert report['stage0']['decisions']=={'hold':1}
    assert report['stage0']['unresolved_senders']==0  # built-in persona mapping is read from existing risk-mw config
    assert report['measures']=={} and report['live']['status']=='pass'
    path.write_text(path.read_text()+'bad-json\n')
    assert main(['--audit',str(path),'--out',str(output)])==1
    assert json.loads(output.read_text())['stage0']['rejects'][0]['line']==2


def test_detector_sources_do_not_access_ground_truth_or_network_clients():
    import re
    root=Path(__file__).resolve().parents[1]/'bhorosha_radar'
    for name in ('stream','baseline','surprise','link','cashout','geo','cashout_rules'):
        text=(root/f'{name}.py').read_text()
        assert not re.search(r'truth_|ring_id|labels|google\.cloud|google\.genai',text),name


def test_subprocess_missing_seed_exit_code_is_two(tmp_path):
    cli=Path(__file__).resolve().parents[1]/'eval'/'radar_eval.py'
    result=subprocess.run([sys.executable,str(cli),'--seed-dir',str(tmp_path/'missing'),'--out',str(tmp_path/'campaign.json')],capture_output=True,text=True)
    assert result.returncode==2
    assert 'missing' in result.stdout


def test_absent_ledger_cannot_claim_retention(tmp_path):
    seed=seed_fixture(tmp_path/'seed'); (seed/'transactions.jsonl').unlink()
    report=evaluate(seed)
    assert report['measures']['retained_fraction']['status']=='missing'
    assert any('transactions.jsonl' in issue for issue in report['missing'])


def test_four_copies_of_one_burst_cannot_stand_in_for_required_scenarios(tmp_path):
    seed=seed_fixture(tmp_path/'seed')
    bursts=[dict(burst_id=f'hospital{i}',kind='hospital',start='2026-10-21T10:00:00',end='2026-10-21T11:00:00') for i in range(4)]
    (seed/'bursts.jsonl').write_text(''.join(json.dumps(b)+'\n' for b in bursts))
    report=evaluate(seed)
    assert report['measures']['benign_burst_incidents']['status']=='missing'


def test_burst_metadata_without_observed_attempts_is_missing(tmp_path):
    seed=seed_fixture(tmp_path/'seed')
    path=seed/'bursts.jsonl'
    bursts=[dict(json.loads(line),start='2026-12-01T00:00:00',end='2026-12-01T01:00:00',acct_ids=['absent']) for line in path.read_text().splitlines()]
    path.write_text(''.join(json.dumps(b)+'\n' for b in bursts))
    report=evaluate(seed)
    assert report['measures']['benign_burst_incidents']['status']=='missing'
    assert any('no observable' in item for item in report['missing'])


def test_audit_default_is_separate_and_preserves_existing_detector_artifacts(tmp_path,monkeypatch):
    import radar_eval
    from test_stream import audit
    project=tmp_path/'project'; (project/'eval'/'results').mkdir(parents=True)
    monkeypatch.setattr(radar_eval,'PROJECT',project)
    output=project/'eval'/'results'
    original={'campaign.json':'{"mode":"seed"}', 'radar_firings.jsonl':'seed-firing\n',
              'radar_incidents.jsonl':'seed-incident\n','radar_campaigns.jsonl':'seed-campaign\n'}
    for name,content in original.items():
        (output/name).write_text(content)
    source=tmp_path/'audit.jsonl'; source.write_text(json.dumps(audit())+'\n')
    assert main(['--audit',str(source),'--seed-dir',str(tmp_path/'missing')])==0
    assert all((output/name).read_text()==content for name,content in original.items())
    report=json.loads((output/'audit_reader.json').read_text())
    assert report['mode']=='audit_reader' and report['live']['status']=='pass'


def test_missing_attempt_stream_still_reports_conservative_nominal_universe(tmp_path):
    seed=seed_fixture(tmp_path/'seed'); (seed/'attempts.jsonl').unlink()
    report=evaluate(seed)
    nominal=report['false_incidents_per_week']['nominal']
    assert nominal['universe']['payee']==34 and sum(nominal['universe'].values())==87
    assert nominal['p_branch_only']==pytest.approx(.0175392)
    assert all(m['status']=='missing' for m in report['measures'].values())


def _point_burst_at_absent_accounts(seed,kinds):
    path=seed/'bursts.jsonl'
    rows=[json.loads(line) for line in path.read_text().splitlines()]
    rows=[dict(b,acct_ids=['absent']) if b['kind'] in kinds else b for b in rows]
    path.write_text(''.join(json.dumps(b)+'\n' for b in rows))


def test_burst_without_attempts_is_reported_not_evaluated_never_zero_incidents(tmp_path):
    seed=seed_fixture(tmp_path/'seed'); _point_burst_at_absent_accounts(seed,{'wedding'})
    output=tmp_path/'out'/'campaign.json'
    assert main(['--seed-dir',str(seed),'--out',str(output)])==2
    report=json.loads(output.read_text())
    rows={r['kind']:r for r in report['benign']}
    assert rows['wedding']['status']=='not evaluated' and rows['wedding']['incidents'] is None
    assert rows['wedding']['observed_attempts']==0
    assert all(rows[k]['status']=='pass' and rows[k]['incidents']==0 for k in ('payday_1','payday_2','hospital'))
    assert report['measures']['benign_burst_incidents']['status']=='missing'
    assert '| wedding | wedding | 0 | n/a | not evaluated |' in (output.parent/'campaign.md').read_text()


def test_audit_run_refuses_to_overwrite_a_detector_report_given_as_out(tmp_path):
    from test_stream import audit
    results=tmp_path/'results'; results.mkdir()
    original={'campaign.json':'{"mode": "seed"}\n','campaign.md':'seed report\n','radar_firings.jsonl':'seed-firing\n'}
    for name,content in original.items():
        (results/name).write_text(content)
    source=tmp_path/'audit.jsonl'; source.write_text(json.dumps(audit())+'\n')
    assert main(['--audit',str(source),'--seed-dir',str(tmp_path/'missing'),'--out',str(results/'campaign.json')])==2
    assert all((results/name).read_text()==content for name,content in original.items())


def test_failed_audit_read_still_writes_an_audit_report_that_a_later_audit_run_replaces(tmp_path):
    from test_stream import audit
    output=tmp_path/'audit_reader.json'
    assert main(['--audit',str(tmp_path/'absent.jsonl'),'--seed-dir',str(tmp_path/'missing'),'--out',str(output)])==2
    assert json.loads(output.read_text())['mode']=='audit_reader'
    source=tmp_path/'audit.jsonl'; source.write_text(json.dumps(audit())+'\n')
    assert main(['--audit',str(source),'--seed-dir',str(tmp_path/'missing'),'--out',str(output)])==0
    assert json.loads(output.read_text())['live']['status']=='pass'


def test_fixture_firings_hold_only_earlier_attempts_and_incidents_carry_a_class(tmp_path):
    seed=seed_fixture(tmp_path/'seed'); output=tmp_path/'out'/'campaign.json'
    assert main(['--seed-dir',str(seed),'--out',str(output)])==0
    ts={a.attempt_id:a.ts for a in read_seed(seed)}
    firings=[json.loads(line) for line in (output.parent/'radar_firings.jsonl').read_text().splitlines()]
    assert firings and all(ts[i]<f['run_ts'] for f in firings for i in f['attempt_ids'])
    incidents=[json.loads(line) for line in (output.parent/'radar_incidents.jsonl').read_text().splitlines()]
    assert incidents and {i['incident_class'] for i in incidents}<={'benign_only','mixed','fraud_dominant'}
    report=json.loads(output.read_text())
    assert sum(report['incident_classes'].values())==len(incidents)
    text=(output.parent/'campaign.md').read_text()
    assert 'False incidents per week, nominal' in text and 'not a guarantee' in text
    assert 'nominal' in report['false_incidents_per_week']['nominal']['caveat']
    assert 'Incident classes: benign_only 0, mixed 0, fraud_dominant' in text


def test_nothing_credited_by_the_flag_gives_retained_fraction_na_with_all_five_money_fields(tmp_path):
    seed=seed_fixture(tmp_path/'seed')
    path=seed/'attempts.jsonl'
    rows=[json.loads(line) for line in path.read_text().splitlines()]
    # Only the last eleven payments (10:19 onward) are allowed; the first firing is at 10:15.
    rows=[dict(r,decision='allow' if int(r['attempt_id'][1:])>=19 else 'hold') if r.get('truth_campaign') and r['type']=='send_money' else r for r in rows]
    path.write_text(''.join(json.dumps(r)+'\n' for r in rows))
    output=tmp_path/'out'/'campaign.json'
    assert main(['--seed-dir',str(seed),'--out',str(output)])==0
    report=json.loads(output.read_text())
    row=report['campaigns'][0]
    assert row['flag_ts']=='2026-10-17T10:15:00'
    assert {k:row[k] for k in ('allowed_by_flag','cashed_out_by_flag','retained_by_flag','retained_fraction','future_allowed_after_flag')}==dict(
        allowed_by_flag=0,cashed_out_by_flag=0,retained_by_flag=0,retained_fraction=None,future_allowed_after_flag=33000)
    assert report['measures']['retained_fraction']['status']=='n/a'
    assert '| c | 2026-10-17T10:15:00 | 6 | 0 | 0 | 0 | n/a | 33000 |' in (output.parent/'campaign.md').read_text()


SEED=Path(__file__).resolve().parents[3]/'data'/'seed'


@pytest.mark.skipif(not (SEED/'accounts.jsonl').exists(),reason='data/seed tables are absent')
def test_nominal_p_branch_budget_on_the_seed_universe_is_within_one_false_incident_a_week():
    from bhorosha_radar.baseline import cell_universe,nominal_budget
    from bhorosha_radar.config import FALSE_INCIDENT_BUDGET_PER_WEEK
    from radar_eval import load_observable_bundle
    start=json.loads((SEED/'config.json').read_text())['start_date']+'T00:00:00'
    universe=cell_universe(load_observable_bundle(SEED),world_start=start)
    nominal=nominal_budget(universe)
    print(f'nominal p-branch false incidents per week: {nominal:.4f} over M = 3 x {sum(universe.values())} cells {universe}')
    # SIM days older than world start - SIM_DAY_RECENT_DAYS can never fire: 33 days, not every historical activation.
    assert universe['payee_sim_day']<=40 and nominal==pytest.approx(.856,abs=.001)
    assert nominal<=FALSE_INCIDENT_BUDGET_PER_WEEK


def test_observable_bundle_and_enriched_attempts_carry_no_ring_or_truth_field(tmp_path):
    from dataclasses import asdict
    from bhorosha_radar.stream import enrich
    from radar_eval import load_observable_bundle
    seed=seed_fixture(tmp_path/'seed')
    with (seed/'transactions.jsonl').open('a') as handle:
        handle.write(json.dumps(dict(txn_id='t2',ts='2026-10-17T09:00:00',from_acct='p0',to_acct='hop',amount_bdt=10,
                                     type='send_money',ring_id='ring_x',truth_campaign='ring_x'))+'\n')
    bundle=load_observable_bundle(seed)
    tables=[bundle.accounts.values(),bundle.agents.values(),bundle.device_links,bundle.sims,bundle.sim_events,
            *bundle.txns_by_acct.values()]
    keys={key for table in tables for row in table for key in row}
    assert 'ring_id' not in keys and not any(key.startswith('truth_') for key in keys)
    enriched=enrich(read_seed(seed),bundle)
    assert enriched and all('ring_id' not in asdict(a) and not any(k.startswith('truth_') for k in asdict(a)) for a in enriched)
    assert not any('ring_x' in str(a) for a in enriched)


def _add_ledger_ring_attempt(seed,truth_campaign):
    with (seed/'attempts.jsonl').open('a') as handle:
        handle.write(json.dumps(dict(attempt_id='fan1',ts='2026-10-12T10:00:00',from_acct='m1',to_acct='fan_payee',amount_bdt=900,
            type='send_money',is_new_payee=True,channel='app',decision='allow',txn_id='tx_fan',truth_campaign=truth_campaign))+'\n')
    with (seed/'transactions.jsonl').open('a') as handle:
        handle.write(json.dumps(dict(txn_id='tx_fan',ts='2026-10-12T10:00:00',from_acct='m1',to_acct='fan_payee',amount_bdt=900,
            type='send_money',ring_id='ring_fan_0'))+'\n')


def test_ledger_ring_attempts_count_as_fraud_and_an_untagged_one_is_an_issue(tmp_path):
    from truth import UNTAGGED_RING_ATTEMPT
    tagged=seed_fixture(tmp_path/'tagged'); _add_ledger_ring_attempt(tagged,'ring_fan_0')
    _,_,ring,issues=load_truth(tagged)
    assert 'fan1' in ring and issues==()
    untagged=seed_fixture(tmp_path/'untagged'); _add_ledger_ring_attempt(untagged,None)
    _,_,ring,issues=load_truth(untagged)
    assert 'fan1' in ring and [i.code for i in issues]==[UNTAGGED_RING_ATTEMPT]
    output=tmp_path/'out'/'campaign.json'
    assert main(['--seed-dir',str(untagged),'--out',str(output)])==2
    assert any('truth_campaign' in item for item in json.loads(output.read_text())['missing'])


def test_truth_issues_carry_codes_that_gate_the_campaign_measures(tmp_path):
    from truth import INCOMPLETE_CAMPAIGN,NO_CAMPAIGNS
    seed=seed_fixture(tmp_path/'seed')
    labels=(seed/'labels.jsonl').read_text().splitlines()
    (seed/'labels.jsonl').write_text('\n'.join(labels[1:])+'\n')
    assert [i.code for i in load_truth(seed)[3]]==[INCOMPLETE_CAMPAIGN]
    assert evaluate(seed)['measures']['campaign_recall']['status']=='missing'
    (seed/'labels.jsonl').write_text('')
    assert [i.code for i in load_truth(seed)[3]]==[NO_CAMPAIGNS]


def test_missing_data_run_keeps_earlier_detector_artifacts(tmp_path):
    seed=seed_fixture(tmp_path/'seed'); (seed/'attempts.jsonl').unlink()
    out=tmp_path/'out'; out.mkdir()
    names=('radar_firings.jsonl','radar_incidents.jsonl','radar_campaigns.jsonl')
    for name in names:
        (out/name).write_text('earlier\n')
    assert main(['--seed-dir',str(seed),'--out',str(out/'campaign.json')])==2
    assert main(['--seed-dir',str(tmp_path/'absent'),'--out',str(out/'campaign.json')])==2
    assert all((out/name).read_text()=='earlier\n' for name in names)


def test_payday_burst_at_the_velocity_cap_passes_only_through_the_payday_factor_and_busy_guard(tmp_path,monkeypatch):
    from bhorosha_radar import baseline
    def payday(seed):
        report=evaluate(seed)
        return report['measures']['benign_burst_incidents'],next(r for r in report['benign'] if r['burst_id']=='payday_1')
    result,row=payday(seed_fixture(tmp_path/'merchant'))
    assert result['status']=='pass' and row['status']=='pass' and row['max_k']==12 and row['observed_attempts']==12
    result,row=payday(seed_fixture(tmp_path/'customer',shop_kind='customer'))
    assert result['status']=='fail' and row['incident_classes']=={'benign_only':1}
    monkeypatch.setattr(baseline,'PAYDAY_FACTOR_DEFAULT',1.0)
    result,row=payday(seed_fixture(tmp_path/'no_factor'))
    assert result['status']=='fail' and row['status']=='fail'
