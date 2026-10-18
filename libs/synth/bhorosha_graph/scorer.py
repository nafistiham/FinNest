"""LightGBM mule-ring scorer with TreeSHAP reasons and a temporal evaluation."""

from __future__ import annotations

import json
import threading
from collections import OrderedDict
from dataclasses import dataclass, field, replace
from datetime import timedelta
from pathlib import Path

import lightgbm as lgb
import numpy as np
import pandas as pd
import shap
from sklearn.metrics import average_precision_score, precision_recall_curve

from bhorosha_graph import features as feat
from bhorosha_graph.bundle import GraphBundle
from bhorosha_synth import schema as s
from bhorosha_synth.world import World

TRAIN_CUTOFF_DAYS: tuple[int, ...] = (7, 14, 21)
TEST_CUTOFF_DAYS: tuple[int, ...] = (28, 35)
TOP_K = 50
TOP_REASONS = 10
PRECISION_TARGET = 0.9
MODEL_FILE, FEATURES_FILE, META_FILE = "model.lgb", "features.parquet", "scorer.json"
MODEL_VERSION = "mule-lgbm-0.1"
FRAME_CACHE_SIZE = 8  # feature tables kept for score_at; one per distinct as_of, ~1 s each to build
TICK = timedelta(seconds=1)  # the world's timestamp resolution (schema.TS_FORMAT)
PENDING_TXN_ID = "txn_pending"
PENDING_TXN_TYPE = "send_money"


def pending_transfer(from_acct: str, to_acct: str, amount_bdt: float, as_of: str) -> dict:
    """The transfer being screened, as a transaction row.

    Stamped one tick before `as_of`: features count only events strictly before their cutoff, so this is the
    latest moment at which the transfer has landed by `as_of`. A real transaction at `as_of` itself stays
    invisible, exactly as it is to score_at.
    """
    return {
        "txn_id": PENDING_TXN_ID, "ts": s.format_ts(s.parse_ts(as_of) - TICK), "type": PENDING_TXN_TYPE, "amount_bdt": float(amount_bdt),
        "from_acct": from_acct, "to_acct": to_acct, "channel": "app", "status": "pending", "agent_id": None, "device_id": None,
    }


def with_transfer(bundle: GraphBundle, txn: dict) -> GraphBundle:
    """A copy of `bundle` whose transaction index also holds `txn`; `bundle` itself is not touched.

    Only `txns_by_acct`, the index the features read, gains the row; the money-flow graph is shared unchanged.
    """
    touched = {acct: tuple(sorted((*bundle.txns_by_acct.get(acct, ()), txn), key=lambda t: t["ts"])) for acct in (txn["from_acct"], txn["to_acct"])}
    return replace(bundle, txns_by_acct={**bundle.txns_by_acct, **touched})


@dataclass(frozen=True)
class MuleScorer:
    booster: lgb.Booster
    feature_names: tuple[str, ...]
    features: pd.DataFrame  # indexed by acct_id, at the final cutoff
    explainer: shap.TreeExplainer
    cutoff: str
    version: str = MODEL_VERSION
    # score_at memo, keyed by (bundle identity, as_of). Mutated in place, which a frozen dataclass allows.
    _frames: OrderedDict = field(default_factory=OrderedDict, init=False, repr=False, compare=False)
    _lock: threading.Lock = field(default_factory=threading.Lock, init=False, repr=False, compare=False)

    def score(self, acct_id: str) -> dict:
        """Score at the artefact cutoff: the end of the world, with everything that has happened visible."""
        if acct_id not in self.features.index:
            return self._unknown(acct_id, self.cutoff)
        return self._explain(self.features.loc[[acct_id], list(self.feature_names)], acct_id, self.cutoff)

    def score_at(self, bundle: GraphBundle, acct_id: str, as_of: str) -> dict:
        """Score as of an earlier moment: features built from events before `as_of` only.

        `score` is frozen at the artefact cutoff, so for a case mid-theft it would see the future
        (an account that is clean at 14:35 can look 0.89 once the ring has finished). Use this when
        the question has a time.
        """
        frame = self.features_at(bundle, as_of)
        if acct_id not in frame.index:
            return self._unknown(acct_id, as_of)
        return self._explain(frame.loc[[acct_id], list(self.feature_names)], acct_id, as_of)

    def features_at(self, bundle: GraphBundle, as_of: str) -> pd.DataFrame:
        """All accounts' features as of `as_of`, built once per distinct time and kept."""
        key = (id(bundle), as_of)
        with self._lock:
            entry = self._frames.get(key)
            if entry is not None and entry[0] is bundle:  # the bundle ref also stops id reuse after a GC
                self._frames.move_to_end(key)
                return entry[1]
        frame = pd.DataFrame(feat.compute_features(bundle, as_of)).set_index("acct_id")[list(self.feature_names)]
        with self._lock:
            self._frames[key] = (bundle, frame)
            while len(self._frames) > FRAME_CACHE_SIZE:
                self._frames.popitem(last=False)
        return frame

    def screen_transfer(self, bundle: GraphBundle, acct_id: str, as_of: str, from_acct: str | None = None, amount_bdt: float | None = None) -> dict:
        """Score a payee as of `as_of` twice: on the evidence so far, and with the transfer being screened landed.

        `before` equals score_at(bundle, acct_id, as_of). `with_this_transfer` scores the same moment on a copy of
        the bundle holding one more transfer, from_acct -> acct_id for amount_bdt; the bundle is not changed. With no
        amount (a payee being added, or just a look at the account) both are the evidence-so-far score. `moved` is the
        feature the transfer changed whose contribution rose most, or None: the part of the risk this transfer brings,
        which is what an honest reason names. One account's features are built, not the whole table, so this costs
        milliseconds at any `as_of` where score_at costs about a second for each new one.
        """
        if amount_bdt is not None and not from_acct:
            raise ValueError("a transfer to screen needs the paying account")
        ctx = feat.feature_context(bundle, as_of)
        before_row = feat.account_features(bundle, acct_id, ctx)
        if before_row is None:
            unknown = self._unknown(acct_id, as_of)
            return {"acct_id": acct_id, "known": False, "as_of": as_of, "model_version": self.version, "before": unknown, "with_this_transfer": unknown, "moved": None}
        before = self._matrix(before_row)
        before_c = _shap_row(self.explainer, before)
        explained = self._explain_with(before, before_c, acct_id, as_of)
        screen = {"acct_id": acct_id, "known": True, "as_of": as_of, "model_version": self.version, "before": explained, "with_this_transfer": explained, "moved": None}
        if amount_bdt is None:
            return screen  # no money moves: one row, explained once
        after = self._matrix(feat.account_features(with_transfer(bundle, pending_transfer(from_acct, acct_id, amount_bdt, as_of)), acct_id, ctx))
        after_c = _shap_row(self.explainer, after)
        return {
            **screen,
            "with_this_transfer": self._explain_with(after, after_c, acct_id, as_of),
            "moved": _moved_feature(self.feature_names, before, after, before_c, after_c),
        }

    def _matrix(self, row: dict) -> pd.DataFrame:
        return pd.DataFrame([row])[list(self.feature_names)]

    def _unknown(self, acct_id: str, as_of: str) -> dict:
        return {"acct_id": acct_id, "known": False, "probability": 0.0, "reasons": [], "model_version": self.version, "as_of": as_of}

    def _explain(self, row: pd.DataFrame, acct_id: str, as_of: str) -> dict:
        return self._explain_with(row, _shap_row(self.explainer, row), acct_id, as_of)

    def _explain_with(self, row: pd.DataFrame, contributions: np.ndarray, acct_id: str, as_of: str) -> dict:
        probability = float(self.booster.predict(row.to_numpy())[0])
        order = np.argsort(-np.abs(contributions))[:TOP_REASONS]
        reasons = [
            {"feature": self.feature_names[i], "value": float(row.iloc[0, i]), "contribution": round(float(contributions[i]), 4), "direction": "up" if contributions[i] > 0 else "down"}
            for i in order
        ]
        return {"acct_id": acct_id, "known": True, "probability": round(probability, 4), "reasons": reasons, "model_version": self.version, "as_of": as_of}

    def save(self, out_dir: Path) -> Path:
        out_dir.mkdir(parents=True, exist_ok=True)
        self.booster.save_model(str(out_dir / MODEL_FILE))
        self.features.to_parquet(out_dir / FEATURES_FILE)
        (out_dir / META_FILE).write_text(json.dumps({"feature_names": self.feature_names, "cutoff": self.cutoff, "version": self.version}), encoding="utf-8")
        return out_dir


def load_scorer(artefact_dir: Path) -> MuleScorer:
    meta = json.loads((artefact_dir / META_FILE).read_text(encoding="utf-8"))
    booster = lgb.Booster(model_file=str(artefact_dir / MODEL_FILE))
    features = pd.read_parquet(artefact_dir / FEATURES_FILE)
    return MuleScorer(booster, tuple(meta["feature_names"]), features, shap.TreeExplainer(booster), meta["cutoff"], meta["version"])


@dataclass(frozen=True)
class TrainResult:
    scorer: MuleScorer
    metrics: dict
    labels: tuple[dict, ...]


def _shap_row(explainer: shap.TreeExplainer, row: pd.DataFrame) -> np.ndarray:
    values = explainer.shap_values(row.to_numpy())
    if isinstance(values, list):  # older shap returns [class0, class1]
        values = values[-1]
    return np.asarray(values).reshape(-1)


def _moved_feature(names: tuple[str, ...], before: pd.DataFrame, after: pd.DataFrame, before_c: np.ndarray, after_c: np.ndarray) -> dict | None:
    """The feature whose value changed and whose push towards "mule" grew most between two rows, or None."""
    moved = [
        {"feature": names[i], "before": float(before.iloc[0, i]), "after": float(after.iloc[0, i]), "contribution_change": round(float(after_c[i] - before_c[i]), 4)}
        for i in range(len(names))
        if before.iloc[0, i] != after.iloc[0, i] and after_c[i] > before_c[i]
    ]
    return max(moved, key=lambda m: m["contribution_change"], default=None)


def _cutoffs(world: World, days: tuple[int, ...]) -> tuple[str, ...]:
    start = s.parse_ts(f"{world.config.start_date}T00:00:00")
    return tuple(s.format_ts(start + timedelta(days=d)) for d in days)


def _positives_at(labels: tuple[dict, ...], cutoff: str) -> dict[str, dict]:
    return {l["acct_id"]: l for l in labels if l["role"] in feat.FRAUD_ROLES and l["first_bad_ts"] < cutoff}


def _frame(bundle: GraphBundle, labels: tuple[dict, ...], cutoffs: tuple[str, ...]) -> pd.DataFrame:
    rows = []
    for cutoff in cutoffs:
        positives = _positives_at(labels, cutoff)
        for r in feat.compute_features(bundle, cutoff):
            rows.append({**r, "y": int(r["acct_id"] in positives)})
    return pd.DataFrame(rows)


def _train(frame: pd.DataFrame, names: tuple[str, ...]) -> lgb.Booster:
    y = frame["y"].to_numpy()
    pos, neg = int(y.sum()), int(len(y) - y.sum())
    params = {"objective": "binary", "learning_rate": 0.05, "num_leaves": 15, "min_child_samples": 5, "feature_fraction": 0.9, "bagging_fraction": 0.9, "bagging_freq": 1,
              "scale_pos_weight": neg / max(pos, 1), "verbose": -1, "seed": 42, "deterministic": True, "num_threads": 1}
    return lgb.train(params, lgb.Dataset(frame[list(names)].to_numpy(), label=y, feature_name=list(names)), num_boost_round=300)


def _ring_recall(frame: pd.DataFrame, labels: tuple[dict, ...], cutoff: str, k: int) -> float:
    rows = frame[frame["cutoff"] == cutoff].nlargest(k, "p")
    top = set(rows["acct_id"])
    rings: dict[str, set[str]] = {}
    for l in _positives_at(labels, cutoff).values():
        rings = {**rings, l["ring_id"]: rings.get(l["ring_id"], set()) | {l["acct_id"]}}
    return round(sum(1 for members in rings.values() if members & top) / len(rings), 3) if rings else 0.0


def _typology_recall(frame: pd.DataFrame, labels: tuple[dict, ...], cutoffs: tuple[str, ...], k: int) -> dict[str, float]:
    caught: dict[str, list[int]] = {}
    for cutoff in cutoffs:
        top = set(frame[frame["cutoff"] == cutoff].nlargest(k, "p")["acct_id"])
        for l in _positives_at(labels, cutoff).values():
            caught = {**caught, l["typology"]: caught.get(l["typology"], []) + [int(l["acct_id"] in top)]}
    return {t: round(sum(v) / len(v), 3) for t, v in sorted(caught.items())}


def _recall_at_precision(y: np.ndarray, p: np.ndarray, target: float) -> float:
    precision, recall, _ = precision_recall_curve(y, p)
    eligible = recall[precision >= target]
    return round(float(eligible.max()), 3) if eligible.size else 0.0


def train_and_evaluate(world: World, bundle: GraphBundle) -> TrainResult:
    train_cutoffs, test_cutoffs = _cutoffs(world, TRAIN_CUTOFF_DAYS), _cutoffs(world, TEST_CUTOFF_DAYS)
    train = _frame(bundle, world.labels, train_cutoffs)
    test = _frame(bundle, world.labels, test_cutoffs)
    names = feat.feature_names(tuple(train.drop(columns=["y"]).to_dict("records")[:1]))
    booster = _train(train, names)
    test = test.assign(p=booster.predict(test[list(names)].to_numpy()))
    y, p = test["y"].to_numpy(), test["p"].to_numpy()
    per_cutoff_precision = [float(test[test["cutoff"] == c].nlargest(TOP_K, "p")["y"].mean()) for c in test_cutoffs]
    metrics = {
        "model_version": MODEL_VERSION,
        "split": {"train_cutoffs": list(train_cutoffs), "test_cutoffs": list(test_cutoffs), "train_rows": int(len(train)), "train_positives": int(train["y"].sum()), "test_rows": int(len(test)), "test_positives": int(y.sum())},
        "test": {
            "auc_pr": round(float(average_precision_score(y, p)), 3),
            "precision_at_50": round(float(np.mean(per_cutoff_precision)), 3),
            "precision_at_50_by_cutoff": dict(zip(test_cutoffs, [round(x, 3) for x in per_cutoff_precision], strict=True)),
            "recall_at_precision_0.9": _recall_at_precision(y, p, PRECISION_TARGET),
            "ring_level_recall": round(float(np.mean([_ring_recall(test, world.labels, c, TOP_K) for c in test_cutoffs])), 3),
            "recall_by_typology": _typology_recall(test, world.labels, test_cutoffs, TOP_K),
        },
        "features": list(names),
        "note": "Synthetic data inflates scores; harder subsets (dormant_then_active, purchased_mule_cluster) are reported separately above.",
    }
    final_cutoff = test_cutoffs[-1]
    final = test[test["cutoff"] == final_cutoff].set_index("acct_id")
    scorer = MuleScorer(booster, names, final[list(names)], shap.TreeExplainer(booster), final_cutoff)
    return TrainResult(scorer, metrics, world.labels)
