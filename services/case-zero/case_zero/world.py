"""The synthetic world, with two corrections Case Zero needs (the synth library is not modified).

1. Known fraud counts only after the same confirmation lag the scorer features use. Its
   `known_fraud_proximity` treats every labelled account as confirmed the moment its first bad
   event happens, so mid-theft it names the ring under investigation.
2. Scores are computed at the investigation's `as_of`. The library's `MuleScorer.score` reads features
   frozen at the final cutoff (2026-11-11), i.e. after the theft.
"""

from __future__ import annotations

import json
import threading
from dataclasses import dataclass, field
from datetime import timedelta
from pathlib import Path

import pandas as pd
from bhorosha_graph import tools as gt
from bhorosha_graph.bundle import GraphBundle, load_bundle
from bhorosha_graph.features import CONFIRMATION_LAG_DAYS, compute_features
from bhorosha_graph.scorer import TOP_REASONS, MuleScorer, _shap_row, load_scorer
from bhorosha_synth import schema as s

MAX_CACHED_CUTOFFS = 16
# the persona id spells out its own label; the agent and the console only ever see the alias.
ALIASES = {"acct_newphone_benign": "acct_09001"}
REAL = {v: k for k, v in ALIASES.items()}


def real_id(acct_id: str) -> str:
    return REAL.get(acct_id, acct_id)


def alias_id(acct_id: str) -> str:
    return ALIASES.get(acct_id, acct_id)


@dataclass(frozen=True)
class World:
    bundle: GraphBundle
    scorer: MuleScorer
    lag_days: int = CONFIRMATION_LAG_DAYS
    link_times: dict = field(default_factory=dict, compare=False, repr=False)  # (acct, entity) -> first visible ts
    _cache: dict = field(default_factory=dict, compare=False, repr=False)
    _lock: threading.Lock = field(default_factory=threading.Lock, compare=False, repr=False)

    @classmethod
    def load(cls, project_dir: Path) -> "World":
        bundle = load_bundle(project_dir / "models" / "mule" / "graph.pkl")
        scorer = load_scorer(project_dir / "models" / "mule")
        return cls(bundle=bundle, scorer=scorer, link_times=_link_times(project_dir / "data" / "seed", bundle))

    def account(self, acct_id: str) -> dict | None:
        row = self.bundle.accounts.get(real_id(acct_id))
        return {**row, "acct_id": acct_id} if row else None

    def has_activity(self, acct_id: str, as_of: str) -> bool:
        return any(t["ts"] <= as_of for t in self.bundle.txns_by_acct.get(real_id(acct_id), ()))

    def entity_links(self, acct_id: str, as_of: str) -> set[str]:
        """Device, SIM, NID, phone and onboarding links that existed at `as_of` (the graph has no times)."""
        acct = real_id(acct_id)
        if acct not in self.bundle.links:
            return set()
        return {e for e in self.bundle.links.neighbors(acct) if self.link_times.get((acct, e), "9999") <= as_of}

    def entity_holders(self, entity: str, as_of: str) -> set[str]:
        return {alias_id(a) for a in self.bundle.links.neighbors(entity) if self.link_times.get((a, entity), "9999") <= as_of}

    def _features_at(self, as_of: str) -> pd.DataFrame:
        with self._lock:
            cached = self._cache.get(as_of)
            if cached is not None:
                return cached
            frame = pd.DataFrame(compute_features(self.bundle, as_of)).set_index("acct_id")
            if len(self._cache) >= MAX_CACHED_CUTOFFS:
                self._cache.pop(next(iter(self._cache)))
            self._cache[as_of] = frame
            return frame

    def score_at(self, acct_id: str, as_of: str) -> dict:
        frame = self._features_at(as_of)
        base = {"acct_id": acct_id, "model_version": self.scorer.version, "as_of": as_of}
        if real_id(acct_id) not in frame.index:
            return {**base, "known": False, "probability": 0.0, "reasons": []}
        row = frame.loc[[real_id(acct_id)], list(self.scorer.feature_names)]
        probability = float(self.scorer.booster.predict(row.to_numpy())[0])
        contributions = _shap_row(self.scorer.explainer, row)
        order = sorted(range(len(contributions)), key=lambda i: -abs(contributions[i]))[:TOP_REASONS]
        reasons = [
            {"feature": self.scorer.feature_names[i], "value": float(row.iloc[0, i]), "contribution": round(float(contributions[i]), 4), "direction": "up" if contributions[i] > 0 else "down"}
            for i in order
        ]
        return {**base, "known": True, "probability": round(probability, 4), "reasons": reasons}

    def bulk_probability(self, acct_ids, as_of: str) -> dict[str, float]:
        """Model probability for many accounts at once (no SHAP), keyed by the ids passed in."""
        frame = self._features_at(as_of)
        pairs = [(a, real_id(a)) for a in acct_ids if real_id(a) in frame.index]
        if not pairs:
            return {}
        probs = self.scorer.booster.predict(frame.loc[[r for _, r in pairs], list(self.scorer.feature_names)].to_numpy())
        return {a: round(float(p), 4) for (a, _), p in zip(pairs, probs)}

    def known_fraud_proximity(self, acct_id: str, as_of: str, max_hops: int = 2) -> dict:
        """Hops (either direction) to fraud an analyst would have confirmed before `as_of`."""
        acct_id = real_id(acct_id)
        confirmed_before = s.format_ts(s.parse_ts(as_of) - timedelta(days=self.lag_days))
        confirmed = {l["acct_id"]: l for l in self.bundle.labels if l["role"] in gt.FRAUD_ROLES and l["first_bad_ts"] < confirmed_before and l["acct_id"] != acct_id}
        frontier, seen, hits = {acct_id}, {acct_id}, []
        for depth in range(1, max_hops + 1):
            next_frontier = set()
            for node in sorted(frontier):
                for t in gt._edges_from(self.bundle, node, as_of) + gt._edges_to(self.bundle, node, as_of):
                    other = t["to_acct"] if t["from_acct"] == node else t["from_acct"]
                    if other in seen:
                        continue
                    seen.add(other)
                    next_frontier.add(other)
                    if other in confirmed:
                        hits.append({"acct_id": alias_id(other), "hops": depth, "confirmed_before": confirmed_before})  # no ring id or role: labels never reach the agent
            frontier = next_frontier
        return {"acct_id": alias_id(acct_id), "as_of": as_of, "confirmation_lag_days": self.lag_days, "min_hops": min((h["hops"] for h in hits), default=None), "hits": sorted(hits, key=lambda h: (h["hops"], h["acct_id"]))}


def _link_times(seed_dir: Path, bundle: GraphBundle) -> dict:
    """When each identity link became visible: device first_seen, SIM activation, else the account's opening."""
    times = {}
    for acct, entity in bundle.links.edges():
        a, e = (acct, entity) if ":" in entity else (entity, acct)
        times[(a, e)] = bundle.accounts.get(a, {}).get("opened_at") or "0000"
    for line in (seed_dir / "device_links.jsonl").read_text(encoding="utf-8").splitlines():
        row = json.loads(line)
        times[(row["acct_id"], f"device:{row['device_id']}")] = row["first_seen"]
    for line in (seed_dir / "sims.jsonl").read_text(encoding="utf-8").splitlines():
        row = json.loads(line)
        times[(row["acct_id"], f"sim:{row['sim_id']}")] = row["activated_at"]
    return times
