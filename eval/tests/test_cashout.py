"""Common point of cash-out results are projected and rendered from their own file, never re-run."""
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import run

SUMMARY = dict(days_run=36, first_day='2026-10-08T00:00:00', last_day='2026-11-12T00:00:00', cashouts=4103, mules=98,
               till_flags=dict(per_day=0.6389, max_per_day=2, days_with_a_flag=15, distinct_tills=3, scored_days=29,
                               scored_till_days=10, right=9, precision=0.9, base_rate=0.4741),
               filters=dict(
                   first_time_senders=dict(
                       candidates=dict(total=4, true=3, false=1, precision=0.75, false_per_week=0.1944,
                                       lead_days=dict(min=0.5, median=2.25, mean=2.0, max=3.0)),
                       held_back=dict(accounts=137, mules=7, victims=40, unlabelled=90, most_first_time_senders=1,
                                      most_new_counterparties=1),
                       recall_of_the_lead=dict(future_confirmed_mules=98, cashed_out_before_confirmation=88, caught=3,
                                               recall=0.0306, recall_of_reachable=0.0341)),
                   pass_through=dict(
                       candidates=dict(total=10, true=6, false=4, precision=0.6, false_per_week=0.7778,
                                       lead_days=dict(min=0.25, median=1.5, mean=1.6, max=3.0)),
                       held_back=dict(accounts=120, mules=1, victims=30, unlabelled=89, most_first_time_senders=1,
                                      most_new_counterparties=1),
                       recall_of_the_lead=dict(future_confirmed_mules=98, cashed_out_before_confirmation=88, caught=6,
                                               recall=0.0612, recall_of_reachable=0.0682))),
               live_clusters=0, replayed_clusters=dict(clusters=5, events=3))


def raw():
    return dict(generated_at='2026-10-17T16:30:42+00:00', module='common point of cash-out',
                config={'TILL_REUSE_P_THRESHOLD': 1e-3}, caveat='synthetic leads, never verdicts',
                worlds=[dict(world='seed_campaign', status='run', missing=[], seed_checksum='abc', summary=SUMMARY,
                             days=[dict(as_of='private-day')], candidates=[dict(acct='acct_secret')], live_clusters=[],
                             replayed_clusters=[dict(cluster_id='clu_private')]),
                        dict(world='seed', status='missing', missing=['missing labels.jsonl'], seed_checksum=None,
                             summary=None, days=[], candidates=[], live_clusters=[], replayed_clusters=[])])


def test_projection_keeps_each_world_summary_and_drops_per_day_and_per_account_rows(tmp_path):
    path = tmp_path/'cashout.json'
    path.write_text(json.dumps(raw()))
    entry = run.load_results(path, run.project_cashout)
    worlds = entry['data']['worlds']
    assert worlds[0]['summary'] == SUMMARY and worlds[1]['missing'] == ['missing labels.jsonl']
    assert not {'days', 'candidates', 'live_clusters', 'replayed_clusters'} & {key for w in worlds for key in w}
    text = '\n'.join(run._cashout_section(entry))
    assert '## Common point of cash-out' in text
    assert 'private' not in text and 'acct_secret' not in text
    assert ('| seed_campaign | first_time_senders | 36 | 0.6389 | 9/10 = 0.9 (base rate 0.4741) | 4 | 0.75 | 0.1944 | '
            '2.25 (2) | 3/98 = 0.0306 (3/88 reachable) | 0 | 5 (3) |') in text
    assert ('| seed_campaign | pass_through | 36 | 0.6389 | 9/10 = 0.9 (base rate 0.4741) | 10 | 0.6 | 0.7778 | '
            '1.5 (1.6) | 6/98 = 0.0612 (6/88 reachable) | 0 | 5 (3) |') in text
    assert '| World | Filter |' in text and 'Lead days, median (mean)' in text
    assert '- seed: missing (missing labels.jsonl)' in text and 'synthetic leads, never verdicts' in text
    assert run.CASHOUT_MODULE not in run.pending_modules({run.CASHOUT_MODULE})
    assert any(name == run.CASHOUT_MODULE and path == run.CASHOUT_RESULTS for name, path, _ in run.RESULT_FILES)


def test_a_world_with_no_candidate_says_what_the_filter_held_back():
    none = dict(total=0, true=0, false=0, precision=None, false_per_week=0.0, lead_days=None)
    first = {**SUMMARY['filters']['first_time_senders'], 'candidates': none}
    summary = {**SUMMARY, 'filters': {**SUMMARY['filters'], 'first_time_senders': first}}
    data = run.project_cashout({**raw(), 'worlds': [{**raw()['worlds'][0], 'summary': summary}]})
    text = '\n'.join(run._cashout_section({'status': 'ok', 'source': 'cashout.json', 'data': data}))
    assert '| seed_campaign | first_time_senders | 36 | 0.6389 | 9/10 = 0.9 (base rate 0.4741) | 0 | n/a | 0 | n/a |' in text
    assert 'seed_campaign, first_time_senders: no candidate; 137 accounts held back by the filter, 7 of them mules' in text
    assert 'seed_campaign, pass_through: no candidate' not in text


def test_cashout_results_absent_degrade_to_not_landed(tmp_path, monkeypatch):
    absent = tmp_path/'cashout.json'
    monkeypatch.setattr(run, 'RESULT_FILES', tuple((name, absent if name == run.CASHOUT_MODULE else path, project)
                                                   for name, path, project in run.RESULT_FILES))
    modules = run.result_files()
    assert run.CASHOUT_MODULE not in modules
    base = {'mule_scorer': {'status': 'ok'}, 'risk_mw_tests': {'status': 'ok', 'summary': '1 passed'},
            'synth_tests': {'status': 'ok', 'summary': '1 passed'}}
    text = run.markdown({'generated_at': 't', 'modules': {**base, **modules}, 'pending': list(run.pending_modules(set(modules))),
                         'gemini': None})
    assert f'- {run.CASHOUT_MODULE}: not run yet' in text and '## Common point of cash-out' not in text


def test_a_renamed_key_costs_the_section_one_line():
    data = run.project_cashout({**raw(), 'worlds': [{**raw()['worlds'][0], 'summary': {'days_run': 36}}]})
    text = '\n'.join(run._cashout_section({'status': 'ok', 'source': 'cashout.json', 'data': data}))
    assert 'could not render' in text and run.CASHOUT_MODULE in text
