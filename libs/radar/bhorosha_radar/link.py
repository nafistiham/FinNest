"""Explainable connected components over incident attempts and declared shared entities."""
from dataclasses import dataclass
from datetime import datetime, timedelta
import hashlib
import math

import networkx as nx

from .config import (LINK_BY_AMOUNT, LINK_LOOKBACK_HOURS, MIN_CAMPAIGN_ATTEMPTS,
                     MIN_CAMPAIGN_SENDERS, SIM_DAY_RECENT_DAYS, SYNCHRONY_SPAN_MIN)
from .surprise import incidents


@dataclass(frozen=True)
class Campaign:
    campaign_id: str
    opened_at: str
    as_of: str
    attempt_ids: tuple[str,...]
    senders: tuple[str,...]
    payees: tuple[str,...]
    tills: tuple[str,...]
    incident_ids: tuple[str,...]
    held: int
    allowed: int
    allowed_bdt: float
    synchrony: float
    concentration: float
    rank_score: float
    evidence: tuple[tuple[str,str,str],...]
    payee_links: tuple[dict,...]


@dataclass(frozen=True)
class Relations:
    accounts: dict
    device_links: tuple[dict,...]
    sims: tuple[dict,...]
    sim_events: tuple[dict,...]


def relations(bundle) -> Relations:
    return Relations(bundle.accounts,tuple(bundle.device_links),tuple(bundle.sims),tuple(bundle.sim_events))


def entity_keys(a, link_by_amount=LINK_BY_AMOUNT) -> tuple[str, ...]:
    keys=[]
    for name,value in (('payee',a.payee),('payee_till',a.payee_till),('payee_sim_day',a.payee_sim_day),
                       ('payee_onboarding_agent',a.payee_onboarding_agent)):
        if value:
            keys.append(f'{name}:{value}')
    keys.extend(f'payee_device:{value}' for value in a.payee_devices)
    keys.extend(f'payee:{value}' for value in a.payee_next_hops)
    if link_by_amount:
        keys.append(f'amount:{round(a.amount_bdt/500)*500}')
    return tuple(sorted(set(keys)))


def payee_links(rel, payees, as_of) -> tuple[dict, ...]:
    result=[]
    for payee in sorted(set(payees)):
        account=rel.accounts.get(payee,{})
        if account.get('onboarding_agent_id') and account.get('opened_at','')<=as_of:
            result.append(dict(payee=payee,entity=f"onboarding_agent:{account['onboarding_agent_id']}",kind='onboarding_agent'))
        for row in rel.device_links:
            if row['acct_id']==payee and row['first_seen']<=as_of:
                result.append(dict(payee=payee,entity=f"device:{row['device_id']}",kind='device'))
        activations=[s['activated_at'] for s in rel.sims if s['acct_id']==payee and s['activated_at']<=as_of]
        activations += [e['ts'] for e in rel.sim_events if e['acct_id']==payee and e['ts']<=as_of and e.get('event') in ('activate','swap')]
        recent=max(activations,default=None)
        if recent and (datetime.fromisoformat(as_of)-datetime.fromisoformat(recent)).total_seconds()<=SIM_DAY_RECENT_DAYS*86400:
            result.append(dict(payee=payee,entity=f'sim_day:{recent[:10]}',kind='sim_day'))
    return tuple(result)


def synchrony(ts, span_min=SYNCHRONY_SPAN_MIN) -> float:
    dates=sorted(datetime.fromisoformat(t) for t in ts)
    left,best=0,0
    for right,value in enumerate(dates):
        while value-dates[left]>timedelta(minutes=span_min):
            left+=1
        best=max(best,right-left+1)
    return best/len(dates) if dates else 0.0


def link(firings, attempts_by_id, rel, as_of) -> tuple[Campaign, ...]:
    cutoff=(datetime.fromisoformat(as_of)-timedelta(hours=LINK_LOOKBACK_HOURS)).isoformat(timespec='seconds')
    active=tuple(i for i in incidents(firings,as_of) if cutoff<i.opened_at<=as_of)
    ids={aid for i in active for aid in i.attempt_ids if aid in attempts_by_id and attempts_by_id[aid].ts<as_of}
    ordered=sorted(ids,key=lambda aid:(attempts_by_id[aid].ts,aid))
    graph=nx.Graph(); owners={}
    for aid in ordered:
        graph.add_node(aid)
        for entity in entity_keys(attempts_by_id[aid]):
            if entity in owners:
                graph.add_edge(owners[entity],aid,entity=entity)
            else:
                owners[entity]=aid
    result=[]
    for component in nx.connected_components(graph):
        attempts=[attempts_by_id[aid] for aid in ordered if aid in component]
        senders=tuple(sorted({a.sender for a in attempts}))
        if len(attempts)<MIN_CAMPAIGN_ATTEMPTS or len(senders)<MIN_CAMPAIGN_SENDERS:
            continue
        payees=tuple(sorted({a.payee for a in attempts if a.payee}))
        concentration=len(senders)/len(payees) if payees else 0.0
        related=[i for i in active if component.intersection(i.attempt_ids)]
        evidence=tuple((source,target,graph.edges[source,target]['entity']) for source,target in nx.bfs_edges(graph,attempts[0].attempt_id))
        result.append(Campaign('camp_'+hashlib.sha1(attempts[0].attempt_id.encode()).hexdigest()[:10],min(i.opened_at for i in related),as_of,
            tuple(a.attempt_id for a in attempts),senders,payees,tuple(sorted({a.payee_till for a in attempts if a.payee_till})),
            tuple(sorted(i.incident_id for i in related)),sum(a.decision!='allow' for a in attempts),sum(a.decision=='allow' for a in attempts),
            sum(a.amount_bdt for a in attempts if a.decision=='allow'),synchrony([a.ts for a in attempts]),concentration,
            max(i.surprise for i in related)+math.log2(max(concentration,1e-12)),evidence,payee_links(rel,payees,as_of)))
    return tuple(sorted(result,key=lambda c:(-c.rank_score,c.campaign_id)))
