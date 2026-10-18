"""Hour-of-week empirical Bayes baseline with explicit backfill/cold-start provenance."""
from collections import defaultdict
from datetime import datetime, timedelta
from functools import lru_cache
import math

import numpy as np

from .config import (AMOUNT_BANDS, BASELINE_WEEKS, LAMBDA_FLOOR_PER_HOUR, PAYDAY_DAYS_OF_MONTH,
                     PAYDAY_FACTOR_DEFAULT, PAYDAY_FACTOR_MAX, PRIOR_WEEKS, P_THRESHOLD,
                     RECEIVING_KEYS, RUN_EVERY_MIN, SENDER_KEYS, SIM_DAY_RECENT_DAYS, WINDOWS_MIN)
from .stream import to_frame

HOUR = timedelta(hours=1)
WEEK_HOURS = 168


def _entity_cells(bundle, as_of=None, world_start=None):
    accounts={aid:a for aid,a in bundle.accounts.items() if as_of is None or a.get('opened_at','')<=as_of}
    districts={a.get('district') for a in accounts.values()}-{None}
    links=[d for d in bundle.device_links if as_of is None or d.get('first_seen','')<=as_of]
    activations=[s['activated_at'] for s in bundle.sims if as_of is None or s['activated_at']<=as_of]
    activations += [e['ts'] for e in bundle.sim_events if e.get('event') in ('activate','swap') and (as_of is None or e['ts']<=as_of)]
    # A SIM day older than SIM_DAY_RECENT_DAYS at as_of (or at the world's start) can never be a cell again.
    horizon=as_of if as_of is not None else world_start
    if horizon is not None:
        cutoff=datetime.fromisoformat(horizon)-timedelta(days=SIM_DAY_RECENT_DAYS)
        activations=[ts for ts in activations if datetime.fromisoformat(ts)>=cutoff]
    return dict(payee=set(accounts),payee_onboarding_agent={a.get('onboarding_agent_id') for a in accounts.values()}-{None},
        payee_device={d['device_id'] for d in links},payee_sim_day={ts[:10] for ts in activations},
        payee_till={aid for aid,a in bundle.agents.items() if as_of is None or a.get('since','')<=as_of},
        sender_district=districts,sender_district_band={f'{district}:band_{band}' for district in districts for band in range(len(AMOUNT_BANDS)+1)})


def cell_universe(bundle, as_of=None, *, world_start=None) -> dict[str,int]:
    """Every cell that can exist by the end of the data, or time-filtered counts when as_of is supplied. With
    world_start, SIM days stop at world_start - SIM_DAY_RECENT_DAYS: older days can never be recent at any run."""
    return {key:len(values) for key,values in _entity_cells(bundle,as_of,world_start).items()}


def causal_universe(bundle, attempts):
    """Per-hour pooled denominators exclude future entities and unobserved exported cells."""
    first_seen={key:{} for key in (*RECEIVING_KEYS,*SENDER_KEYS)}
    for key,cells in first_seen.items():
        for row in to_frame(attempts,key).itertuples(index=False):
            cells[row.cell]=min(cells.get(row.cell,row.ts),row.ts)

    @lru_cache(maxsize=None)
    def at(hour_ts):
        values=_entity_cells(bundle,hour_ts)
        for key,cells in first_seen.items():
            values[key].update(cell for cell,ts in cells.items() if ts<hour_ts)
        return {key:len(cells) for key,cells in values.items()}
    return at


def nominal_budget(universe) -> float:
    """Union bound for the nominal p branch; estimated means and cap need replay measurement."""
    runs_per_week = 7 * 24 * 60 / RUN_EVERY_MIN
    return runs_per_week * P_THRESHOLD * len(WINDOWS_MIN) * sum(universe.values())


class Baseline:
    def __init__(self, attempts, universe, start, end, *, universe_at=None):
        self.start = datetime.fromisoformat(start).replace(minute=0, second=0, microsecond=0)
        self.end = datetime.fromisoformat(end)
        self.hours = math.ceil((self.end-self.start).total_seconds()/3600)
        self.universe = dict(universe)
        self.universe_at = universe_at
        senders = defaultdict(set)
        for key in universe:
            for row in to_frame(attempts, key).itertuples(index=False):
                ts = datetime.fromisoformat(row.ts)
                index = math.floor((ts-self.start).total_seconds()/3600)
                senders[key, row.cell, index].add(row.sender)
        self.counts = {group: len(ids) for group,ids in senders.items()}
        totals = defaultdict(int)
        for (key,_cell,index),count in self.counts.items():
            totals[key,index] += count
        self.totals = dict(totals)
        self._rates, self._payday_factors = {}, {}

    def _index(self, ts):
        return math.floor((datetime.fromisoformat(ts)-self.start).total_seconds()/3600)

    def _prior(self, index):
        return [index-WEEK_HOURS*d for d in range(1,BASELINE_WEEKS+1) if index-WEEK_HOURS*d >= 0]

    def rate(self, key, cell, hour_ts):
        """(hourly rate, baseline source) for one cell and hour, memoised per instance."""
        if (key,cell,hour_ts) not in self._rates:
            self._rates[key,cell,hour_ts] = self._rate(key,cell,hour_ts)
        return self._rates[key,cell,hour_ts]

    def _rate(self, key, cell, hour_ts):
        index = self._index(hour_ts)
        if not 0 <= index < self.hours:
            return LAMBDA_FLOOR_PER_HOUR, 'cold_start'
        comparisons = self._prior(index)
        source = 'prior'
        if not comparisons:
            comparisons = [index+WEEK_HOURS*d for d in range(1,BASELINE_WEEKS+1) if index+WEEK_HOURS*d < self.hours]
            source = 'backfill' if comparisons else 'cold_start'
        weeks = len(comparisons)
        size=(self.universe_at(hour_ts) if self.universe_at else self.universe).get(key,0)
        pooled = max(sum(self.totals.get((key,j),0) for j in comparisons) / (max(weeks,1)*max(size,1)), LAMBDA_FLOOR_PER_HOUR)
        own = sum(self.counts.get((key,cell,j),0) for j in comparisons)
        return (own+PRIOR_WEEKS*pooled)/(weeks+PRIOR_WEEKS), source

    def payday_factor(self, key, hour_ts):
        """Payday multiplier for one key and hour, memoised per instance."""
        if (key,hour_ts) not in self._payday_factors:
            self._payday_factors[key,hour_ts] = self._payday_factor(key,hour_ts)
        return self._payday_factors[key,hour_ts]

    def _payday_factor(self, key, hour_ts):
        ts = datetime.fromisoformat(hour_ts)
        if ts.day not in PAYDAY_DAYS_OF_MONTH:
            return 1.0
        index = self._index(hour_ts)
        previous = [j for j in range(max(index,0)) if (self.start+j*HOUR).day in PAYDAY_DAYS_OF_MONTH
                    and (self.start+j*HOUR).hour == ts.hour]
        prior = self._prior(index)
        denominator = sum(self.totals.get((key,j),0) for j in prior)/len(prior) if prior else 0
        if not previous or not denominator:
            return PAYDAY_FACTOR_DEFAULT
        return min(PAYDAY_FACTOR_MAX,max(1.0,self.totals.get((key,previous[-1]),0)/denominator))

    def expected(self, key, cell, run_ts, window_min):
        end = datetime.fromisoformat(run_ts)
        begin = end-timedelta(minutes=window_min)
        hour = begin.replace(minute=0,second=0,microsecond=0)
        mu, sources, factors = 0.0, set(), []
        while hour < end:
            overlap = (min(end,hour+HOUR)-max(begin,hour)).total_seconds()/3600
            rate,source = self.rate(key,cell,hour.isoformat(timespec='seconds'))
            factor = self.payday_factor(key,hour.isoformat(timespec='seconds'))
            mu += rate*factor*overlap
            sources.add(source); factors.append(factor)
            hour += HOUR
        source = 'cold_start' if 'cold_start' in sources else 'backfill' if 'backfill' in sources else 'prior'
        return mu, source, max(factors,default=1.0)

    def dispersion(self):
        """Variance/mean of complete per-key hourly totals, including empty hours."""
        result={}
        for key in self.universe:
            values=np.array([self.totals.get((key,j),0) for j in range(self.hours)],dtype=float)
            mean=float(values.mean()) if len(values) else 0
            value=float(values.var()/mean) if mean else None
            result[key]={'index':value,'overdispersed':value is not None and value>1.5}
        return result
