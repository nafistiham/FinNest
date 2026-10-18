"""Offline Campaign Radar acceptance harness; missing data exits 2, failure 1, pass 0."""
from __future__ import annotations

import argparse
from collections import Counter,defaultdict
from dataclasses import asdict,dataclass
from datetime import UTC,datetime,timedelta
import hashlib
import json
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
from types import SimpleNamespace

RADAR=Path(__file__).resolve().parents[1]
PROJECT=RADAR.parents[1]  # the repository root
sys.path.insert(0,str(RADAR))
sys.path.insert(0,str(RADAR/'eval'))
sys.path.append(str(PROJECT/'libs'/'synth'))  # the campaign-free replay regenerates its world with bhorosha_synth

from bhorosha_radar import config
from bhorosha_radar.baseline import Baseline,causal_universe,cell_universe,nominal_budget
from bhorosha_radar.link import link,relations
from bhorosha_radar.measures import (ATTEMPT_PRECISION_MIN,ATTEMPT_RECALL_MIN,FLAG_WITHIN_MIN,
    RETAINED_FRACTION_MIN,VICTIM_COVERAGE_MIN,burst_attempt_ids,burst_incidents,false_incidents_by_route,flag_ts,in_payment_stream,
    incident_class,match,measure,money_at_flag,precision_recall,time_to_flag_min,victim_coverage)
from bhorosha_radar.stream import enrich,read_audit,read_seed,to_frame
from bhorosha_radar.surprise import cell_tests,detect,incidents
from truth import CAMPAIGN_ISSUES,NO_CAMPAIGNS,complete_bursts,load_truth

CAVEAT=('Fixture-first synthetic evaluation; no real-world accuracy claim. Backfill uses later weeks for week-zero '
        'baselines and is reported per firing. Poisson means are estimated; nominal p-branch budgets exclude '
        'the velocity-cap route. Retained money is measured at the flag, without an action-policy counterfactual.')
WORLD_CAVEAT=('Measured on a synthetic world our own generator wrote (seed-campaign: the seed-42 demo world plus three '
        'injected call-centre campaigns); the campaigns show the machinery works, not that it works on a real wallet\'s traffic, and no real '
        'baseline exists: four weeks of synthetic history, week 0 backfilled from later weeks. The ten-sender floor was set '
        'knowing the largest benign cell is seven, so the benign result is partly by construction. The paydays carry no '
        'person-to-person surge in this world, so the payday rows check the cell design on ordinary payday traffic, and the '
        'wedding is three cash-outs that no payment stream holds. Amount links are off. Retained money counts only funds '
        'credited by the flag; money saved is not claimed. The nominal false-incident figure is a p-branch union bound; the '
        'measured counts per route come from this world and its campaign-free replay. No threshold sweep, blind seeds or '
        'live audit in this run.')
TARGETS={'time_to_flag_min':('<=',FLAG_WITHIN_MIN),'retained_fraction':('>=',RETAINED_FRACTION_MIN),
         'campaign_precision':('>=',ATTEMPT_PRECISION_MIN),'campaign_recall':('>=',ATTEMPT_RECALL_MIN),
         'benign_burst_incidents':('==',0),'victim_coverage':('>=',VICTIM_COVERAGE_MIN)}
CAMPAIGN_MEASURES=(('time_to_flag_min','time_to_flag_min',max),('retained_fraction','retained_fraction',min),
                   ('campaign_precision','precision',min),('campaign_recall','recall',min),('victim_coverage','victim_coverage',min))
MONEY_FIELDS=('allowed_by_flag','cashed_out_by_flag','retained_by_flag','retained_fraction','future_allowed_after_flag')
INCIDENT_CLASSES=('benign_only','mixed','fraud_dominant')
NOMINAL_CAVEAT=('nominal: p-branch union bound over the cell universe (SIM days from the world start minus '
                'SIM_DAY_RECENT_DAYS); not a measured false-alarm rate or a guarantee; excludes the velocity cap')


def _observable(row):
    """A table row without its ground truth: the ledger's ring_id and any truth_ column never reach the detector."""
    return {key:value for key,value in row.items() if key!='ring_id' and not key.startswith('truth_')}


def _rows(seed_dir,name):
    path=seed_dir/name
    return tuple(_observable(json.loads(line)) for line in path.read_text(encoding='utf-8').splitlines() if line.strip()) if path.exists() else ()


def load_observable_bundle(seed_dir):
    """Bundle-compatible view of observable tables only; no world generation or hidden annotations."""
    txns=defaultdict(list)
    for t in _rows(seed_dir,'transactions.jsonl'):
        for acct in {t.get('from_acct'),t.get('to_acct')} - {None}:
            txns[acct].append(t)
    return SimpleNamespace(accounts={a['acct_id']:a for a in _rows(seed_dir,'accounts.jsonl')},
        agents={a['agent_id']:a for a in _rows(seed_dir,'agents.jsonl')},device_links=_rows(seed_dir,'device_links.jsonl'),
        sims=_rows(seed_dir,'sims.jsonl'),sim_events=_rows(seed_dir,'sim_events.jsonl'),
        txns_by_acct={acct:tuple(sorted(rows,key=lambda t:t['ts'])) for acct,rows in txns.items()})


def _base_report(seed_dir):
    checksum=seed_dir/'CHECKSUM'
    return dict(generated_at=datetime.now(UTC).isoformat(timespec='seconds'),
        seed_checksum=checksum.read_text().strip() if checksum.exists() else None,
        input_checksums={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(seed_dir.glob('*.jsonl'))},
        config={name:sorted(getattr(config,name)) if isinstance(getattr(config,name),frozenset) else getattr(config,name) for name in dir(config) if name.isupper()},mode='seed',
        measures={name:measure(None,*target) for name,target in TARGETS.items()},campaigns=[],benign=[],
        incident_classes={},false_incidents_per_week={'nominal':None,'by_route':{},
        'campaign_free_replay':{'status':'not run','reason':'requires the separate campaign-free world; never regenerated here'}},
        other_rings={'status':'not run','reason':'separate typology evaluation not implemented yet'},dispersion={},
        live={'status':'not run','reason':'pending the live audit export: an operator runs eval/export_audit.py and passes the file in with --audit'},
        missing=[],caveat=CAVEAT)


def _stage0(attempts,rejects=()):
    return {'attempts':len(attempts),'decisions':dict(Counter(a.decision for a in attempts)),
            'sources':dict(Counter(a.source for a in attempts)),
            'unresolved_senders':sum(a.identity_source=='unresolved_uid' for a in attempts),'rejects':list(rejects)}


OUTSIDE_STREAM='outside stream'


def _benign_row(burst,attempts,tests,all_incidents,ring_attempts) -> tuple[dict,tuple[str,...]]:
    """One burst's result and its issues. A burst with payment types but no attempt in the stream is 'not evaluated',
    never zero incidents; a burst with no payment type at all (cash-outs only) is 'outside stream': no attempt can
    belong to it, so it is reported and left out of the measure, never counted as zero."""
    base=dict(burst_id=burst.burst_id,kind=burst.kind,start=burst.start,end=burst.end)
    invalid=(f'{burst.burst_id}: invalid burst interval',) if burst.start>burst.end else ()
    if not in_payment_stream(burst):
        reason=f"types {', '.join(burst.types)}: no payment the cells count ({', '.join(config.CELL_TYPES)})"
        return dict(base,observed_attempts=0,incidents=None,benign_only=None,mixed=None,status=OUTSIDE_STREAM,reason=reason,
                    incident_classes={},max_k=0,min_p=None,baseline_source=[]),invalid
    ids=burst_attempt_ids(burst,attempts)
    count=burst_incidents(burst,attempts,all_incidents,ring_attempts)
    touched=[i for i in all_incidents if ids.intersection(i.attempt_ids)]
    classes=Counter(incident_class(i,ring_attempts) for i in touched)
    corresponding=[r for r in tests.itertuples(index=False) if ids.intersection(r.attempt_ids)]
    issues=invalid+((f'{burst.burst_id}: no observable in-scope benign attempts; not evaluated',) if count is None else ())
    return dict(base,observed_attempts=len(ids),incidents=count,
        benign_only=None if count is None else classes.get('benign_only',0),mixed=None if count is None else classes.get('mixed',0),
        status='not evaluated' if count is None else 'pass' if count==0 else 'fail',incident_classes=dict(classes),
        max_k=max((r.k for r in corresponding),default=0),min_p=min((r.p for r in corresponding),default=None),
        baseline_source=sorted({r.baseline_source for r in corresponding})),issues


def _benign_measure(rows) -> dict | None:
    """Benign-only plus mixed incidents over the bursts inside the payment stream, naming the bursts it covers and
    the ones outside; None (the measure stays missing) when one in-stream burst is not evaluated or none is in-stream."""
    inside=[r for r in rows if r['status']!=OUTSIDE_STREAM]
    if not inside or any(r['status']=='not evaluated' for r in inside):
        return None
    return {**measure(sum(r['incidents'] for r in inside),*TARGETS['benign_burst_incidents']),
            'evaluated':[r['burst_id'] for r in inside],'outside_stream':[r['burst_id'] for r in rows if r['status']==OUTSIDE_STREAM]}


def _world_window(seed_dir,attempts) -> tuple[str|None,str|None]:
    """config.json's start_date and days, stretched to cover the last attempt's longest window; (None, None) when unknown."""
    path=seed_dir/'config.json'
    cfg=json.loads(path.read_text()) if path.exists() else {}
    day=cfg.get('start_date') or (attempts[0].ts[:10] if attempts else None)
    if day is None:
        return None,None
    start=datetime.fromisoformat(day+'T00:00:00')
    end=start+timedelta(days=cfg.get('days',1))
    if attempts:
        last=max(datetime.fromisoformat(a.ts) for a in attempts)
        end=max(end,last+timedelta(minutes=max(config.WINDOWS_MIN)+config.RUN_EVERY_MIN))
    return start.isoformat(timespec='seconds'),end.isoformat(timespec='seconds')


def _nominal(universe) -> dict:
    return {'p_branch_only':nominal_budget(universe),'universe':universe,'budget':config.FALSE_INCIDENT_BUDGET_PER_WEEK,'caveat':NOMINAL_CAVEAT}


@dataclass(frozen=True)
class Detection:
    universe: dict
    tests: object
    firings: tuple
    incidents: tuple
    rel: object
    by_id: dict
    campaigns: tuple


def _detect(attempts,bundle,start,end,*,link_runs=True) -> Detection:
    """Stages 1 and 2 over the whole stream: cell tests, firings, incidents and (with link_runs) the latest snapshot of
    every campaign."""
    universe=cell_universe(bundle,world_start=start)
    # Include new observable entities in partial fixtures and exported streams.
    universe={key:max(n,to_frame(attempts,key).cell.nunique()) for key,n in universe.items()}
    tests=cell_tests(attempts,universe,start,end,universe_at=causal_universe(bundle,attempts))
    firings=detect(tests)
    rel=relations(bundle); by_id={a.attempt_id:a for a in attempts}
    runs=sorted({f.run_ts for f in firings}) if link_runs else ()
    snapshots={campaign.campaign_id:campaign for run in runs for campaign in link(firings,by_id,rel,run)}
    return Detection(universe,tests,firings,incidents(firings),rel,by_id,tuple(snapshots.values()))


def _flag_firing(truth,firings,flag) -> dict | None:
    """The firing that opened the incident: at the flag run, the one holding most of the campaign's attempts."""
    at_flag=[f for f in firings if f.run_ts==flag and truth.attempt_ids.intersection(f.attempt_ids)]
    best=max(at_flag,key=lambda f:(len(truth.attempt_ids.intersection(f.attempt_ids)),f.surprise),default=None)
    return None if best is None else dict(key=best.key,cell=best.cell,window_min=best.window_min,reason=best.reason,k=best.k,
        mu=best.mu,p=best.p,held=len(best.held_ids),allowed=len(best.allowed_ids),
        campaign_attempts=len(truth.attempt_ids.intersection(best.attempt_ids)),baseline_source=best.baseline_source)


US2_PAYEE_RANGE='3–5'  # spec 08 US-2: one component naming the campaign's 3–5 payees
ENTITY_WORDS=(('payee_till','till'),('payee_onboarding_agent','onboarding agent'),('payee_device','device'),
              ('payee_sim_day','SIM day'),('payee','payee'),('amount','amount'))
COUNT_WORDS=('no','one','two','three','four','five','six','seven','eight','nine','ten')


def _count_word(n) -> str:
    return COUNT_WORDS[n] if n<len(COUNT_WORDS) else str(n)


def _entity_phrase(entities) -> str:
    """'payee_till:AG-0038' and 'payee_onboarding_agent:AG-0021' -> 'till AG-0038 and onboarding agent AG-0021'."""
    words=dict(ENTITY_WORDS); order=[name for name,_ in ENTITY_WORDS]
    parts=[f"{words.get(kind,kind)} {value}" for kind,value in sorted((e.split(':',1) for e in entities),
           key=lambda kv:(order.index(kv[0]) if kv[0] in order else len(order),kv[1]))]
    return parts[0] if len(parts)==1 else ', '.join(parts[:-1])+' and '+parts[-1]


def payee_overreach(truth,best,by_id,ring_attempts) -> str | None:
    """When the matched component names more payees than the campaign has: how many, which attempts came in (benign
    or another ring's, from which district) and the shared entities on the evidence edges that brought them in."""
    if best is None or len(set(best.payees))<=len(truth.payees):
        return None
    extra=[i for i in best.attempt_ids if i not in truth.attempt_ids]
    entities={entity for source,target,entity in best.evidence if source in extra or target in extra}
    kind='benign' if not ring_attempts.intersection(extra) else 'non-campaign'
    districts=sorted({by_id[i].sender_district for i in extra if getattr(by_id[i],'sender_district',None)})
    where=f'{districts[0]} ' if len(districts)==1 else ''
    return (f"names {len(set(best.payees))} payees against {len(truth.payees)} true: {_count_word(len(extra))} {kind} {where}"
            f"payment{'' if len(extra)==1 else 's'} joined through shared {_entity_phrase(entities)}, so the spec's "
            f"{US2_PAYEE_RANGE} payee criterion (US-2) fails for this campaign")


def payee_note(rows) -> str | None:
    """One sentence naming every campaign whose component names more payees than its own, or saying none does."""
    if not rows:
        return None
    over=[f"{r['campaign_id']} {r['payee_overreach']}" for r in rows if r.get('payee_overreach')]
    return '; '.join(over)+'.' if over else "Every campaign's component names only its own payees (US-2)."


def _minutes(later,earlier) -> float:
    return (datetime.fromisoformat(later)-datetime.fromisoformat(earlier)).total_seconds()/60


def _campaign_row(truth,d,ring_attempts=frozenset()) -> dict:
    """One known campaign, linked as of its last payment + 180 min from the run state at that time."""
    as_of=(max(datetime.fromisoformat(d.by_id[i].ts) for i in truth.attempt_ids)+timedelta(minutes=180)).isoformat(timespec='seconds')
    best=match(truth,link(d.firings,d.by_id,d.rel,as_of))
    flag=flag_ts(truth,d.firings)
    precision,recall=precision_recall(truth,best)
    money=money_at_flag(truth,flag) if flag else dict.fromkeys(MONEY_FIELDS)
    first=min(d.by_id[i].ts for i in truth.attempt_ids)
    before=[d.by_id[i] for i in truth.attempt_ids if flag and d.by_id[i].ts<flag]
    named=set(best.payees) if best else set()
    return dict(campaign_id=truth.campaign_id,detected_campaign_id=best.campaign_id if best else None,
        flag_ts=flag,time_to_flag_min=time_to_flag_min(truth,d.firings),as_of=as_of,precision=precision,recall=recall,
        victim_coverage=victim_coverage(truth,best),**money,day=first[:10],first_ts=first,tenth_ts=truth.tenth_ts,
        minutes_from_first_to_flag=_minutes(flag,first) if flag else None,senders_before_flag=len({a.sender for a in before}),
        held_before_flag=sum(a.decision!='allow' for a in before),flag_firing=_flag_firing(truth,d.firings,flag) if flag else None,
        attempts_in_component=len(best.attempt_ids) if best else 0,payees_found=len(named & truth.payees),payees_total=len(truth.payees),
        payees_named=len(named),till_found=bool(best and truth.till in best.tills),
        payee_overreach=payee_overreach(truth,best,d.by_id,ring_attempts))


def _campaign_measures(rows,ledger_present) -> dict:
    """The worst campaign per measure. An unflagged campaign fails timing and retention; it is never dropped."""
    unflagged=any(r['flag_ts'] is None for r in rows)
    result={}
    for name,column,aggregation in CAMPAIGN_MEASURES:
        values=[r[column] for r in rows]
        known=[v for v in values if v is not None]
        value=aggregation(known) if known and not (name=='time_to_flag_min' and len(known)!=len(values)) else None
        outcome=measure(value,*TARGETS[name],na=name=='retained_fraction' and not unflagged and not known)
        if unflagged and name in ('time_to_flag_min','retained_fraction'):
            outcome={**outcome,'status':'fail','reason':'campaign was not flagged'}
        if name=='retained_fraction' and not ledger_present:
            outcome=measure(None,*TARGETS[name])
        result[name]=outcome
    return result


def _artifacts(d,ring_attempts) -> dict:
    """Run-level rows for radar_*.jsonl; only a run whose detector ran carries them, so write_report never truncates
    earlier artefacts on a missing-data run."""
    return {'radar_firings':[asdict(f) for f in d.firings],
            'radar_incidents':[dict(asdict(i),incident_class=incident_class(i,ring_attempts)) for i in d.incidents],
            'radar_campaigns':[asdict(c) for c in d.campaigns]}


def _route_summary(by_route) -> dict:
    """Per route: benign-only incidents over the whole window and per week of exposure."""
    result={}
    for route,weeks in by_route.items():
        count=sum(w['benign_only_incidents'] for w in weeks.values())
        exposure=sum(w['exposure_days'] for w in weeks.values())/7
        result[route]={'benign_only_incidents':count,'exposure_weeks':exposure,'per_week':count/exposure if exposure else None}
    return result


def _world_config(seed_dir) -> dict:
    path=seed_dir/'config.json'
    return json.loads(path.read_text(encoding='utf-8')) if path.exists() else {}


def campaign_free(seed_dir) -> dict:
    """The same world without its campaigns (the generator's --campaigns 0), regenerated in a temporary directory and run
    through stages 0 and 1: what every route fires on when no campaign is in the data. Not run for a seed whose
    config.json has no campaign block (the demo seed, the fixtures)."""
    raw=_world_config(seed_dir)
    if 'campaign' not in raw:
        return {'status':'not run','reason':'the seed has no campaign block in config.json, so there is no campaign-free twin to generate'}
    from bhorosha_synth import schema
    from bhorosha_synth.generate import generate_world,write_world
    cfg=schema.WorldConfig(**{k:v for k,v in raw.items() if k not in ('checksum','campaign')})
    with TemporaryDirectory() as tmp:
        world_dir=Path(tmp)
        checksum=write_world(generate_world(cfg,schema.CampaignConfig(campaigns=0)),world_dir)
        bundle=load_observable_bundle(world_dir)
        attempts=enrich(read_seed(world_dir),bundle)
        start,end=_world_window(world_dir,attempts)
        _,bursts,ring_attempts,issues=load_truth(world_dir)
        d=_detect(attempts,bundle,start,end,link_runs=False)
        benign=[row for row,_ in (_benign_row(b,attempts,d.tests,d.incidents,ring_attempts) for b in bursts)]
    by_route=false_incidents_by_route(d.firings,ring_attempts,start,end)
    return {'status':'run','campaigns':0,'seed':cfg.seed,'checksum':checksum,'attempts':len(attempts),'window':[start,end],
            'issues':[i.message for i in issues if i.code!=NO_CAMPAIGNS],
            'incident_classes':dict(Counter(incident_class(i,ring_attempts) for i in d.incidents)),
            'by_route':by_route,'summary':_route_summary(by_route),'nominal':_nominal(d.universe),'benign':benign}


def evaluate(seed_dir,*,replay=True):
    report=_base_report(seed_dir)
    if 'campaign' in _world_config(seed_dir):
        report['caveat']=WORLD_CAVEAT
    attempts=read_seed(seed_dir)
    report['stage0']=_stage0(attempts)
    bundle=load_observable_bundle(seed_dir)
    start,end=_world_window(seed_dir,attempts)
    report['false_incidents_per_week']['nominal']=_nominal(cell_universe(bundle,world_start=start))
    if not (seed_dir/'attempts.jsonl').exists():
        report['missing']=['missing attempts.jsonl; ledger-only stage 0 is not campaign acceptance']
        return report
    truths,bursts,ring_attempts,issues=load_truth(seed_dir)
    attempts=enrich(attempts,bundle)
    if not attempts:
        report['missing']=[issue.message for issue in issues]+['empty attempt stream']
        return report
    d=_detect(attempts,bundle,start,end)
    report['campaigns']=[_campaign_row(truth,d,ring_attempts) for truth in truths]
    report['payee_note']=payee_note(report['campaigns'])
    if report['campaigns'] and not any(issue.code in CAMPAIGN_ISSUES for issue in issues):
        report['measures'].update(_campaign_measures(report['campaigns'],(seed_dir/'transactions.jsonl').exists()))
    benign=[_benign_row(burst,attempts,d.tests,d.incidents,ring_attempts) for burst in bursts]
    report['benign']=[row for row,_ in benign]
    report['missing']=[issue.message for issue in issues]+[item for _,found in benign for item in found]
    benign_measure=_benign_measure(report['benign'])
    if complete_bursts(bursts) and benign_measure and all(b.start<=b.end for b in bursts):
        report['measures']['benign_burst_incidents']=benign_measure
    report['incident_classes']=dict(Counter(incident_class(i,ring_attempts) for i in d.incidents))
    fipw=report['false_incidents_per_week']
    fipw['nominal']=_nominal(d.universe)
    fipw['by_route']=false_incidents_by_route(d.firings,ring_attempts,start,end)
    fipw['summary']=_route_summary(fipw['by_route'])
    if replay:
        fipw['campaign_free_replay']=campaign_free(seed_dir)
        report['missing']+=[f'campaign-free replay: {item}' for item in fipw['campaign_free_replay'].get('issues',())]
    report['dispersion']=Baseline(attempts,d.universe,start,end).dispersion()
    report['_artifacts']=_artifacts(d,ring_attempts)
    return report


def audit_report(path,seed_dir):
    report=_base_report(seed_dir); report['mode']='audit_reader'; report['measures']={}
    persona_path=PROJECT/'services'/'risk-mw'/'config'/'personas.json'
    mapping={p['uid']:p['acct_id'] for p in json.loads(persona_path.read_text())['personas']} if persona_path.exists() else {}
    bundle=load_observable_bundle(seed_dir)
    attempts,rejects=read_audit(path,mapping,known_accounts=bundle.accounts)
    report['stage0']=_stage0(enrich(attempts,bundle),rejects)
    report['live']={'status':'pass' if attempts and not rejects else 'fail','source':path.name,
                    'scope':'reader sanity only; no detector accuracy inference'}
    return report


def _cell(value):
    """None renders as n/a; whole floats (taka, minutes) as integers; other floats to four significant figures."""
    if value is None:
        return 'n/a'
    if isinstance(value,float):
        return str(int(value)) if value.is_integer() else f'{value:.4g}'
    return str(value)


def _campaign_lines(report):
    lines=['| Campaign | Flag | Minutes after tenth | Allowed by flag BDT | Cashed out by flag BDT | Retained by flag BDT | '
           'Retained fraction | Future allowed after flag BDT | Precision | Recall | Victim coverage |','|---|---|---|---|---|---|---|---|---|---|---|']
    columns=('flag_ts','time_to_flag_min',*MONEY_FIELDS,'precision','recall','victim_coverage')
    return lines+[f"| {r['campaign_id']} | "+' | '.join(_cell(r.get(c)) for c in columns)+' |' for r in report['campaigns']]


def _flag_lines(report):
    """How each campaign was flagged: the clock from its first and tenth attempt, the firing that opened it, what the
    linked component named."""
    lines=['| Campaign | Day | First attempt | Tenth attempt | Flag | Minutes from first | Senders before flag (held) | '
           'Opened by (key: cell, window, route) | k | mu | p | Component attempts | Payees found / named / true | Till found |',
           '|---|---|---|---|---|---|---|---|---|---|---|---|---|---|']
    for r in report['campaigns']:
        f=r.get('flag_firing') or {}
        opened=f"{f['key']}: {f['cell']}, {f['window_min']} min, {f['reason']}" if f else 'n/a'
        lines.append(f"| {r['campaign_id']} | {r.get('day')} | {r.get('first_ts')} | {r.get('tenth_ts')} | {_cell(r['flag_ts'])} | "
                     f"{_cell(r.get('minutes_from_first_to_flag'))} | {r.get('senders_before_flag')} ({r.get('held_before_flag')}) | {opened} | "
                     f"{_cell(f.get('k'))} | {_cell(f.get('mu'))} | {_cell(f.get('p'))} | {r.get('attempts_in_component')} | "
                     f"{r.get('payees_found')} / {r.get('payees_named')} / {r.get('payees_total')} | {'yes' if r.get('till_found') else 'no'} |")
    return lines


def _benign_rows(rows):
    lines=['| Burst | Kind | Attempts | Incidents | Status | Benign-only | Mixed | Window | Max k | Min p |','|---|---|---|---|---|---|---|---|---|---|']
    return lines+[f"| {r['burst_id']} | {r['kind']} | {r['observed_attempts']} | {_cell(r['incidents'])} | {r['status']} | "
                  f"{_cell(r.get('benign_only'))} | {_cell(r.get('mixed'))} | {r.get('start','?')} to {r.get('end','?')} | "
                  f"{r.get('max_k')} | {_cell(r.get('min_p'))} |" for r in rows]


def _benign_lines(report):
    lines=_benign_rows(report['benign'])
    m=report['measures'].get('benign_burst_incidents',{})
    if m.get('evaluated') is not None:
        outside=', '.join(m['outside_stream']) or 'none'
        lines += ['',f"benign_burst_incidents counts benign-only and mixed incidents on {', '.join(m['evaluated'])}; "
                     f"outside the payment stream (no attempt can belong to it, so it is not counted as zero): {outside}."]
    return lines


def _route_table(worlds):
    """Benign-only incidents per route and week for each world, the measured rate beside the nominal p-branch figure."""
    weeks=sorted({week for fipw in worlds.values() for route in fipw.get('by_route',{}).values() for week in route})
    lines=['| World | Route | '+' | '.join(f'Week of {w[:10]}' for w in weeks)+' | Measured per week | Nominal p-branch per week |',
           '|---|---|'+'---|'*len(weeks)+'---|---|']
    for world,fipw in worlds.items():
        nominal=(fipw.get('nominal') or {}).get('p_branch_only')
        for route,by_week in fipw.get('by_route',{}).items():
            summary=(fipw.get('summary') or {}).get(route,{})
            counts=' | '.join(_cell(by_week[w]['benign_only_incidents']) if w in by_week else '-' for w in weeks)
            lines.append(f"| {world} | {route} | {counts} | {_cell(summary.get('per_week'))} | {_cell(nominal) if route=='poisson' else 'n/a (not bounded)'} |")
    return lines


def _false_incident_lines(report):
    fipw=report['false_incidents_per_week']
    nominal=fipw.get('nominal') or {}
    lines=[f"False incidents per week, nominal (p-branch union bound over the cell universe; not a measured rate and not "
           f"a guarantee): {_cell(nominal.get('p_branch_only'))} against a budget of {_cell(nominal.get('budget'))}."]
    replay=fipw['campaign_free_replay']
    worlds={'this world':fipw}|({'campaign-free replay':replay} if replay.get('status')=='run' else {})
    if fipw.get('by_route'):
        lines += ['','Measured benign-only incidents (incidents touching no ring attempt), by route and week:','']+_route_table(worlds)
    lines += ['',f"Campaign-free replay: {replay['status']}"+(f" ({replay['reason']})" if replay.get('reason') else '')+'.']
    if replay.get('status')=='run':
        classes=replay.get('incident_classes',{})
        lines += [f"Same seed and generator with no campaign ({replay['attempts']} attempts, checksum {replay['checksum'][:12]}): incident classes "
                  +', '.join(f'{name} {classes.get(name,0)}' for name in INCIDENT_CLASSES)+'.','']+_benign_rows(replay.get('benign',[]))
    return lines


def _floor_sentence(benign) -> str:
    """Said plainly when a benign burst's closest cell crossed P_THRESHOLD below the sender floor: the floor, not the
    p threshold, is what kept it quiet. Empty when no burst came that close."""
    held=[r for r in benign if r.get('min_p') is not None and r['min_p']<=config.P_THRESHOLD and r.get('max_k',0)<config.MIN_DISTINCT_SENDERS]
    if not held:
        return ''
    reached=' and '.join(f"{r['burst_id']} reached p {_cell(r['min_p'])} with {r['max_k']} senders" for r in held)
    return (f' {reached}, below P_THRESHOLD {_cell(config.P_THRESHOLD)}: the {_count_word(config.MIN_DISTINCT_SENDERS)}-sender floor '
            f'(MIN_DISTINCT_SENDERS {config.MIN_DISTINCT_SENDERS}), not the p threshold, keeps the benign bursts quiet.')


def markdown(report):
    lines=['# Campaign Radar','',report['caveat'],'','| Measure | Value | Target | Status |','|---|---|---|---|']
    lines += [f"| {name} | {_cell(m['value'])} | {m['target']} | {m['status']} |" for name,m in report['measures'].items()]
    lines += ['']+_campaign_lines(report)
    lines += (['']+_flag_lines(report)) if report['campaigns'] and 'flag_firing' in report['campaigns'][0] else []
    lines += ['',report['payee_note']] if report.get('payee_note') else []
    lines += ['']+_benign_lines(report)
    classes=report.get('incident_classes',{})
    lines += ['','Incident classes: '+', '.join(f'{name} {classes.get(name,0)}' for name in INCIDENT_CLASSES)+'.','']
    lines += _false_incident_lines(report)
    dispersion=report.get('dispersion') or {}
    if dispersion:
        values=', '.join(f"{key} {_cell(d['index'])}"+(' (over 1.5)' if d['overdispersed'] else '') for key,d in dispersion.items())
        lines += ['',f'Dispersion index per key (variance over mean of hourly sender counts; over 1.5 the Poisson p-values are '
                     f'optimistic): {values}.'+_floor_sentence(report['benign'])]
    lines += ['']+[f'- {item}' for item in report['missing']]
    lines += ['',f"Live audit: {report['live']['status']}. {report['live'].get('reason',report['live'].get('scope',''))}",'']
    return '\n'.join(lines)


def write_report(report,output):
    output.parent.mkdir(parents=True,exist_ok=True)
    artifacts=report.get('_artifacts')
    payload={key:value for key,value in report.items() if key!='_artifacts'}
    output.write_text(json.dumps(payload,indent=2,allow_nan=False)+'\n',encoding='utf-8')
    output.with_suffix('.md').write_text(markdown(report),encoding='utf-8')
    if artifacts is not None:
        for name in ('radar_firings','radar_incidents','radar_campaigns'):
            (output.parent/f'{name}.jsonl').write_text(''.join(json.dumps(row,allow_nan=False)+'\n' for row in artifacts.get(name,())),encoding='utf-8')


def _holds_detector_results(path):
    """True unless path is absent or an earlier audit-reader report: an audit run never replaces detector output."""
    if not path.exists():
        return False
    try:
        return json.loads(path.read_text(encoding='utf-8')).get('mode')!='audit_reader'
    except (OSError,ValueError,AttributeError):
        return True


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--seed-dir',type=Path,default=PROJECT/'data'/'seed')
    parser.add_argument('--audit',type=Path,help='local JSONL export only; this command never reads cloud services')
    parser.add_argument('--out',type=Path,default=None)
    parser.add_argument('--no-campaign-free',action='store_true',help='skip the campaign-free replay (regenerates the world without campaigns)')
    args=parser.parse_args(argv)
    output=args.out or PROJECT/'eval'/'results'/('audit_reader.json' if args.audit else 'campaign.json')
    if args.audit and _holds_detector_results(output):
        print(f'refusing to write the audit-reader report over {output.name}: it holds detector results; pass another --out',file=sys.stderr)
        return 2
    try:
        report=audit_report(args.audit,args.seed_dir) if args.audit else evaluate(args.seed_dir,replay=not args.no_campaign_free)
    except (OSError,ValueError,KeyError,TypeError) as exc:
        report=_base_report(args.seed_dir); report['missing']=[f'input could not be evaluated: {type(exc).__name__}: {exc}']
        if args.audit:
            report['mode']='audit_reader'; report['measures']={}
            report['live']={'status':'fail','reason':'the audit export could not be read','scope':'reader sanity only'}
    write_report(report,output)
    print(markdown(report))
    if report['missing'] or any(m['status']=='missing' for m in report['measures'].values()):
        return 2
    return 1 if report['live']['status']=='fail' or any(m['status']=='fail' for m in report['measures'].values()) else 0


if __name__=='__main__':
    sys.exit(main())
