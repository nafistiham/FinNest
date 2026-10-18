"""Campaign Radar results are projected and rendered without rerunning detection."""
import json
from pathlib import Path
import sys

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import run


def test_campaign_projection_excludes_large_artifact_rows_and_keeps_missing_visible(tmp_path):
    raw={'generated_at':'t','config':{'P_THRESHOLD':1e-7},'measures':{'campaign_recall':{'value':None,'target':'>= 0.9','status':'missing'}},
         'campaigns':[],'benign':[],'incident_classes':{},'false_incidents_per_week':{},'caveat':'campaign data pending',
         'missing':['attempts.jsonl'],'stage0':{'attempts':0},'radar_firings':[{'attempt_ids':['private']}]}
    path=tmp_path/'campaign.json';path.write_text(json.dumps(raw))
    entry=run.load_results(path,run.project_campaign)
    assert entry['data']['measures']['campaign_recall']['status']=='missing'
    assert not {'radar_firings','stage0'} & entry['data'].keys()
    text='\n'.join(run._campaign_section(entry))
    assert 'Campaign Radar' in text and 'missing' in text and 'campaign data pending' in text
    assert 'private' not in text


def test_campaign_markdown_renders_money_and_acceptance_with_no_reexecution():
    entry={'status':'ok','source':'campaign.json','data':run.project_campaign(dict(
        generated_at='t',measures={'retained_fraction':{'value':.75,'target':'>= 0.5','status':'pass'}},
        campaigns=[dict(campaign_id='c',flag_ts='2026-10-17T10:15:00',time_to_flag_min=6,allowed_by_flag=52000,
                        retained_by_flag=39000,retained_fraction=.75,precision=.99,recall=1)],benign=[],caveat='synthetic fixture'))}
    text='\n'.join(run._campaign_section(entry))
    assert '52000' in text and '39000' in text and '0.75' in text and 'synthetic fixture' in text
    assert any(name==run.CAMPAIGN_MODULE and path==run.CAMPAIGN_RESULTS for name,path,_ in run.RESULT_FILES)
    assert run.CAMPAIGN_MODULE not in run.pending_modules({run.CAMPAIGN_MODULE})


def test_explicit_audit_result_is_rendered_as_reader_only():
    data=run.project_campaign(dict(mode='audit_reader',measures={},campaigns=[],stage0={'attempts':2,'rejects':[]},
         live={'status':'pass','scope':'reader sanity only'},caveat='no accuracy inference'))
    text='\n'.join(run._campaign_section({'status':'ok','source':'audit_reader.json','data':data}))
    assert 'reader sanity only' in text and 'pass' in text


def test_campaign_results_absent_degrade_to_not_landed(tmp_path,monkeypatch):
    absent=tmp_path/'campaign.json'
    monkeypatch.setattr(run,'RESULT_FILES',tuple((name,absent if name==run.CAMPAIGN_MODULE else path,project) for name,path,project in run.RESULT_FILES))
    modules=run.result_files()
    assert run.CAMPAIGN_MODULE not in modules
    base={'mule_scorer':{'status':'ok'},'risk_mw_tests':{'status':'ok','summary':'1 passed'},
          'synth_tests':{'status':'ok','summary':'1 passed'}}
    text=run.markdown({'generated_at':'t','modules':{**base,**modules},'pending':list(run.pending_modules(set(modules))),'gemini':None})
    assert '- campaign_radar: not run yet' in text and '## Campaign Radar' not in text


def test_campaign_section_shows_measured_false_incidents_per_route_for_both_worlds_beside_the_nominal_and_the_flag():
    route={'poisson':{'benign_only_incidents':0,'exposure_weeks':5.0152,'per_week':0.0},
           'velocity_cap':{'benign_only_incidents':1,'exposure_weeks':5.0152,'per_week':0.1994}}
    data=run.project_campaign(dict(generated_at='t',caveat='x',
        measures={'benign_burst_incidents':{'value':0,'target':'== 0','status':'pass','evaluated':['payday_1','hospital'],'outside_stream':['wedding']}},
        campaigns=[dict(campaign_id='ring_callcentre_2',flag_ts='f',senders_before_flag=10,minutes_from_first_to_flag=24.4167,
                        flag_firing={'key':'payee_sim_day','window_min':60,'reason':'poisson'},payees_found=3,payees_named=3,payees_total=3,till_found=True)],
        false_incidents_per_week={'nominal':{'p_branch_only':.8604,'budget':1.0},'summary':route,
                                  'campaign_free_replay':{'status':'run','summary':route,'nominal':{'p_branch_only':.856}}}))
    text='\n'.join(run._campaign_section({'status':'ok','source':'campaign.json','data':data}))
    assert 'Benign bursts counted: payday_1, hospital; outside the payment stream: wedding.' in text
    assert 'this world: poisson 0 in 5.02 weeks, velocity_cap 1 in 5.02 weeks (nominal p-branch 0.8604 a week)' in text
    assert 'campaign-free replay: poisson 0 in 5.02 weeks, velocity_cap 1 in 5.02 weeks (nominal p-branch 0.856 a week)' in text
    assert 'ring_callcentre_2: opened at sender 10, 24.42 min after the first attempt, by payee_sim_day (60 min, poisson); payees 3 of 3 (3 named), till found' in text


def test_campaign_section_carries_the_payee_note_from_the_radar_report_verbatim():
    note=("ring_callcentre_0 names 7 payees against 4 true: three benign Bhola payments joined through shared till AG-0038 and "
          "onboarding agent AG-0021, so the spec's 3–5 payee criterion (US-2) fails for this campaign.")
    data=run.project_campaign(dict(generated_at='t',caveat='x',measures={},campaigns=[],payee_note=note))
    assert data['payee_note']==note
    assert note in '\n'.join(run._campaign_section({'status':'ok','source':'campaign.json','data':data}))


def test_campaign_section_without_replay_or_flag_details_renders_as_before():
    data=run.project_campaign(dict(generated_at='t',caveat='x',measures={},campaigns=[dict(campaign_id='c',flag_ts=None)],
                                   false_incidents_per_week={'nominal':None,'campaign_free_replay':{'status':'not run','reason':'no twin'}}))
    text='\n'.join(run._campaign_section({'status':'ok','source':'campaign.json','data':data}))
    assert 'Campaign-free replay: not run (no twin).' in text and 'opened at sender' not in text


def test_campaign_section_labels_false_incidents_nominal_and_shows_classes_and_unevaluated_bursts():
    data=run.project_campaign(dict(generated_at='t',measures={'benign_burst_incidents':{'value':None,'target':'== 0','status':'missing'}},
        campaigns=[dict(campaign_id='c',flag_ts='f',time_to_flag_min=6,allowed_by_flag=0,cashed_out_by_flag=0,retained_by_flag=0,
                        retained_fraction=None,future_allowed_after_flag=33000,precision=1,recall=1,victim_coverage=1)],
        benign=[dict(burst_id='wedding',kind='wedding',observed_attempts=0,incidents=None,status='not evaluated')],
        incident_classes={'fraud_dominant':3},false_incidents_per_week={'nominal':{'p_branch_only':.98784,'budget':1.0}},caveat='x'))
    text='\n'.join(run._campaign_section({'status':'ok','source':'campaign.json','data':data}))
    assert 'False incidents per week, nominal' in text and '0.9878' in text and 'not a guarantee' in text
    assert 'benign_only 0, mixed 0, fraud_dominant 3' in text
    assert '| wedding | wedding | 0 | n/a | not evaluated |' in text
    assert '| c | f | 6 | 0 | 0 | 0 | n/a | 33000 | 1 | 1 | 1 |' in text
