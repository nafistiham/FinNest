"""Receiving-side tests first; every firing preserves exactly one run's evidence."""
from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime, timedelta
import hashlib
import math

import numpy as np
import pandas as pd
from scipy.stats import poisson

from .baseline import Baseline
from .config import (INCIDENT_MERGE_GAP_MIN, MIN_DISTINCT_SENDERS, P_THRESHOLD, RECEIVING_KEYS,
                     RUN_EVERY_MIN, SENDER_KEYS, VELOCITY_CAP, VELOCITY_CAP_MU_MAX, WINDOWS_MIN)
from .stream import to_frame


@dataclass(frozen=True)
class Firing:
    run_ts: str
    key: str
    cell: str
    window_min: int
    k: int
    mu: float
    p: float
    surprise: float
    reason: str
    attempt_ids: tuple[str, ...]
    baseline_source: str = 'unknown'
    payday_factor: float = 1.0
    held_ids: tuple[str, ...] = ()
    allowed_ids: tuple[str, ...] = ()


@dataclass(frozen=True)
class Incident:
    incident_id: str
    key: str
    cell: str
    window_min: int
    opened_at: str
    last_fired_at: str
    observed: int
    expected: float
    p_value: float
    surprise: float
    reason: str
    firing_runs: tuple[str, ...]
    baseline_source: str
    payday_factor: float
    attempt_ids: tuple[str, ...]
    held: int
    allowed: int


def poisson_tail(k, mu) -> np.ndarray:
    return np.where(np.asarray(k)==0,1.0,poisson.sf(np.asarray(k)-1,mu))


def cell_tests(attempts, universe, start, end, *, universe_at=None) -> pd.DataFrame:
    baseline = Baseline(attempts,universe,start,end,universe_at=universe_at)
    begin,stop = datetime.fromisoformat(start),datetime.fromisoformat(end)
    cadence = timedelta(minutes=RUN_EVERY_MIN)
    max_run = math.floor((stop-begin)/cadence)
    by_id = {a.attempt_id:a for a in attempts}
    rows=[]
    for key in (*RECEIVING_KEYS,*SENDER_KEYS):
        if key not in universe:
            continue
        groups=defaultdict(list)
        for a in to_frame(attempts,key).itertuples(index=False):
            ts=datetime.fromisoformat(a.ts)
            for window in WINDOWS_MIN:
                first=max(0,math.floor((ts-begin)/cadence)+1)
                last=min(max_run,math.floor((ts+timedelta(minutes=window)-begin)/cadence))
                for run_index in range(first,last+1):
                    groups[run_index,a.cell,window].append(a)
        for (index,cell,window),items in sorted(groups.items()):
            run=(begin+index*cadence).isoformat(timespec='seconds')
            mu,source,payday=baseline.expected(key,cell,run,window)
            ids=tuple(sorted({a.attempt_id for a in items},key=lambda i:(by_id[i].ts,i)))
            rows.append(dict(run_ts=run,key=key,cell=cell,window_min=window,k=len({a.sender for a in items}),mu=mu,
                attempt_ids=ids,busy=any(a.busy for a in items),baseline_source=source,payday_factor=payday,
                held_ids=tuple(i for i in ids if by_id[i].decision!='allow'),allowed_ids=tuple(i for i in ids if by_id[i].decision=='allow')))
    columns=['run_ts','key','cell','window_min','k','mu','attempt_ids','busy','baseline_source','payday_factor','held_ids','allowed_ids','p','surprise']
    if not rows:
        return pd.DataFrame(columns=columns)
    result=pd.DataFrame(rows)
    result['p']=poisson_tail(result.k.to_numpy(),result.mu.to_numpy())
    # logsf can underflow too; bounded at the smallest positive float to keep JSON finite.
    result['surprise']=-np.log10(np.maximum(result.p.to_numpy(),np.nextafter(0.0,1.0)))
    return result[columns]


def detect(tests, *, p_threshold=P_THRESHOLD, min_senders=MIN_DISTINCT_SENDERS) -> tuple[Firing, ...]:
    output=[]
    for key in (*RECEIVING_KEYS,*SENDER_KEYS):
        for row in tests[tests.key==key].itertuples(index=False) if not tests.empty else ():
            reason=None
            if row.k>=min_senders and row.p<=p_threshold:
                reason='poisson'
            elif row.k>=VELOCITY_CAP[row.window_min] and row.mu<=VELOCITY_CAP_MU_MAX and not row.busy and key!='payee_till':
                reason='velocity_cap'
            if reason:
                output.append(Firing(row.run_ts,key,row.cell,int(row.window_min),int(row.k),float(row.mu),float(row.p),
                    float(row.surprise),reason,tuple(row.attempt_ids),row.baseline_source,float(row.payday_factor),tuple(row.held_ids),tuple(row.allowed_ids)))
    return tuple(output)


def incidents(firings, as_of=None) -> tuple[Incident, ...]:
    """One incident per (key, cell) burst: firings in any window within INCIDENT_MERGE_GAP_MIN of each other merge,
    and the incident keeps the window of its most surprising firing."""
    by_cell=defaultdict(list)
    for firing in firings:
        if as_of is None or firing.run_ts<=as_of:
            by_cell[firing.key,firing.cell].append(firing)
    output=[]
    for (key,cell),items in sorted(by_cell.items()):
        groups=[]
        for f in sorted(items,key=lambda f:f.run_ts):
            if not groups or datetime.fromisoformat(f.run_ts)-datetime.fromisoformat(groups[-1][-1].run_ts)>timedelta(minutes=INCIDENT_MERGE_GAP_MIN):
                groups.append([])
            groups[-1].append(f)
        for group in groups:
            first,last=group[0],group[-1]
            best=max(group,key=lambda f:f.surprise)
            ids=tuple(sorted({i for f in group for i in f.attempt_ids}))
            held={i for f in group for i in f.held_ids}; allowed={i for f in group for i in f.allowed_ids}
            iid='inc_'+hashlib.sha1(f'{key}|{cell}|{first.run_ts}'.encode()).hexdigest()[:12]
            output.append(Incident(iid,key,cell,best.window_min,first.run_ts,last.run_ts,best.k,best.mu,best.p,best.surprise,
                best.reason,tuple(sorted({f.run_ts for f in group})),best.baseline_source,max(f.payday_factor for f in group),ids,len(held),len(allowed)))
    return tuple(sorted(output,key=lambda i:(i.opened_at,i.key,i.cell,i.window_min)))
