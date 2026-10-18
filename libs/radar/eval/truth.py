"""Evaluation-only adapter. No detector module imports this file."""
from dataclasses import dataclass
import json
from pathlib import Path

from bhorosha_radar.measures import CampaignTruth
from bhorosha_radar.stream import to_local

EXPECTED_CAMPAIGN_PAYMENTS = 30  # the acceptance scenario has thirty victim-originated payments
EXPECTED_BENIGN_BURSTS = 4  # two paydays, wedding, hospital

# Issue codes. CAMPAIGN_ISSUES withhold the campaign measures; every issue makes the run exit 2.
MISSING_ATTEMPTS = 'missing_attempts'
MISSING_LEDGER = 'missing_ledger'
NO_CAMPAIGNS = 'no_campaigns'
INCOMPLETE_CAMPAIGN = 'incomplete_campaign'
MISSING_BURSTS = 'missing_bursts'
UNTAGGED_RING_ATTEMPT = 'untagged_ring_attempt'
CAMPAIGN_ISSUES = frozenset({NO_CAMPAIGNS, INCOMPLETE_CAMPAIGN})


@dataclass(frozen=True)
class Burst:
    burst_id: str
    kind: str
    start: str
    end: str
    acct_ids: tuple[str,...]
    types: tuple[str,...]


@dataclass(frozen=True)
class Issue:
    code: str
    message: str


def rows(seed_dir: Path, name: str) -> tuple[dict, ...]:
    path=seed_dir/name
    return tuple(json.loads(line) for line in path.read_text(encoding='utf-8').splitlines() if line.strip()) if path.exists() else ()


def ring_attempt_ids(attempts, ledger) -> tuple[frozenset[str], tuple[Issue, ...]]:
    """Payment attempts of any labelled ring: those carrying a truth_campaign, plus those whose ledger row (joined on
    txn_id) has a ring_id. The generator sets truth_campaign = ring_id on every labelled ring's attempts, so a ledger ring
    attempt without one is an issue; there is no label-based fallback."""
    ring_txns={t['txn_id'] for t in ledger if t.get('ring_id') and t.get('txn_id')}
    payments=[a for a in attempts if a.get('type')=='send_money']
    tagged={a['attempt_id'] for a in payments if a.get('truth_campaign')}
    joined={a['attempt_id'] for a in payments if a.get('txn_id') in ring_txns}
    untagged=sorted(joined-tagged)
    issues=(Issue(UNTAGGED_RING_ATTEMPT,f'{len(untagged)} attempts belong to a ledger ring but carry no truth_campaign '
                  f'(the generator sets truth_campaign = ring_id), e.g. {untagged[:3]}'),) if untagged else ()
    return frozenset(tagged|joined),issues


def _campaign_truth(cid, labels, payments, ledger) -> CampaignTruth | Issue:
    victims=frozenset(l['acct_id'] for l in labels if l.get('ring_id')==cid and l.get('role')=='victim')
    own=sorted((a for a in payments if a['truth_campaign']==cid and a.get('from_acct') in victims),key=lambda a:(a['ts'],a['attempt_id']))
    if len(own)!=EXPECTED_CAMPAIGN_PAYMENTS or len(victims)!=EXPECTED_CAMPAIGN_PAYMENTS:
        return Issue(INCOMPLETE_CAMPAIGN,f'{cid}: expected thirty victim payment attempts and thirty victims; got {len(own)}, {len(victims)}')
    cashouts=[t for t in ledger if t.get('type')=='cash_out' and t.get('ring_id')==cid]
    return CampaignTruth(cid,frozenset(a['attempt_id'] for a in own),victims,to_local(own[9]['ts']),
        tuple((to_local(a['ts']),float(a['amount_bdt'])) for a in own if a.get('decision')=='allow'),
        tuple((to_local(t['ts']),float(t['amount_bdt'])) for t in cashouts),
        frozenset(a['to_acct'] for a in own if a.get('to_acct')),next((t.get('agent_id') for t in cashouts),None))


def load_truth(seed_dir) -> tuple[tuple[CampaignTruth, ...], tuple[Burst, ...], frozenset[str], tuple[Issue, ...]]:
    attempts=rows(seed_dir,'attempts.jsonl')
    labels=rows(seed_dir,'labels.jsonl')
    ledger=rows(seed_dir,'transactions.jsonl')
    payments=[a for a in attempts if a.get('truth_campaign') and a.get('type')=='send_money']
    campaign_ids={l['ring_id'] for l in labels if l.get('typology')=='callcentre_campaign'}
    issues=[]
    if not (seed_dir/'attempts.jsonl').exists():
        issues.append(Issue(MISSING_ATTEMPTS,'missing attempts.jsonl (generate the campaign world)'))
    if not (seed_dir/'transactions.jsonl').exists():
        issues.append(Issue(MISSING_LEDGER,'missing transactions.jsonl: cash-out outcomes are unknown'))
    if not campaign_ids:
        issues.append(Issue(NO_CAMPAIGNS,'missing labelled callcentre_campaign campaigns (generate the campaign world)'))
    truths=[_campaign_truth(cid,labels,payments,ledger) for cid in sorted(campaign_ids)]
    issues += [t for t in truths if isinstance(t,Issue)]
    bursts=tuple(Burst(b['burst_id'],b['kind'],to_local(b['start']),to_local(b['end']),tuple(b.get('acct_ids',())),tuple(b.get('types',())))
                 for b in rows(seed_dir,'bursts.jsonl'))
    if not complete_bursts(bursts):
        issues.append(Issue(MISSING_BURSTS,'missing benign bursts: need two paydays, wedding and hospital (bursts.jsonl)'))
    ring_attempts,ring_issues=ring_attempt_ids(attempts,ledger)
    return tuple(t for t in truths if isinstance(t,CampaignTruth)),bursts,ring_attempts,tuple(issues)+ring_issues


def complete_bursts(bursts) -> bool:
    names=[(b.burst_id+' '+b.kind).lower() for b in bursts]
    return (len(bursts)>=EXPECTED_BENIGN_BURSTS and sum('payday' in name for name in names)>=2
            and any('wedding' in name for name in names) and any('hospital' in name for name in names)
            and len({b.burst_id for b in bursts})==len(bursts))
