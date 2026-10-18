"""The permission classifier at serving time: load once, score one app in well under 20 ms .

Artefacts (written by `train_lamda.py`, or `train.py` for CSV datasets): `model.txt` (LightGBM text booster, < 5 MB),
`columns.json`, `meta.json` (metrics, gates, dataset provenance, optional calibration knots). When meta.json carries
`calibration.knots_raw / knots_calibrated`, the booster's raw probability is passed through that monotone map
(`numpy.interp`) before it is compared with the 0.80 threshold; contributions stay raw TreeSHAP values from LightGBM's
own `pred_contrib`, so serving needs no `shap` dependency.
"""

from __future__ import annotations

import json
from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path

import numpy as np

from bhorosha_app_safety_check.features import Vectoriser

MODEL_FILE = "model.txt"
META_FILE = "meta.json"
TOP_CONTRIBUTIONS = 5


def calibration_knots(meta: dict) -> tuple[np.ndarray, np.ndarray] | None:
    """`meta["calibration"] = {"knots_raw": [...], "knots_calibrated": [...]}`, validated; None when the model is uncalibrated."""
    cal = meta.get("calibration")
    if not isinstance(cal, dict) or not cal.get("knots_raw"):
        return None
    raw = np.asarray(cal["knots_raw"], dtype=float)
    calibrated = np.asarray(cal.get("knots_calibrated", ()), dtype=float)
    if raw.shape != calibrated.shape or raw.ndim != 1 or np.any(np.diff(raw) < 0) or np.any(np.diff(calibrated) < 0):
        raise ValueError("meta.json calibration knots must be two equal-length non-decreasing lists")
    return raw, calibrated


@dataclass(frozen=True)
class Prediction:
    probability: float
    contributions: tuple[tuple[str, float], ...]  # top declared permissions pushing the score up, (name, shap)


class AppClassifier:
    def __init__(self, booster, vectoriser: Vectoriser, meta: dict):
        self.booster = booster
        self.vectoriser = vectoriser
        self.meta = meta
        self.calibration = calibration_knots(meta)

    def calibrate(self, raw: float) -> float:
        """Monotone raw -> calibrated map from meta.json (`train_lamda.py` isotonic knots); identity when absent."""
        if self.calibration is None:
            return raw
        return float(np.interp(raw, self.calibration[0], self.calibration[1]))

    @property
    def version(self) -> str:
        return str(self.meta.get("version", "appsafety-lgbm"))

    @classmethod
    def load(cls, artefacts: Path) -> AppClassifier:
        import lightgbm as lgb

        booster = lgb.Booster(model_file=str(artefacts / MODEL_FILE))
        vectoriser = Vectoriser.load(artefacts)
        if booster.num_feature() != len(vectoriser):
            raise ValueError(f"model expects {booster.num_feature()} features, columns.json has {len(vectoriser)}")
        meta = json.loads((artefacts / META_FILE).read_text(encoding="utf-8"))
        return cls(booster, vectoriser, meta)

    def predict(self, permissions: Iterable[str]) -> Prediction:
        return self.predict_many([permissions])[0]

    def predict_many(self, apps: Iterable[Iterable[str]]) -> list[Prediction]:
        """Score every app of a phone in two booster calls instead of two per app. A real 80-app phone took 1.4 s one app
        at a time (17 ms each, most of it LightGBM call overhead); batched it is tens of ms."""
        rows = [self.vectoriser.transform(list(a)) for a in apps]
        if not rows:
            return []
        x = np.vstack(rows)
        probabilities = self.booster.predict(x)
        contributions = self.booster.predict(x, pred_contrib=True)[:, :-1]  # last column is the bias
        out: list[Prediction] = []
        for row, probability, contrib in zip(x, probabilities, contributions, strict=True):
            present = [(self.vectoriser.columns[i], float(contrib[i])) for i in np.flatnonzero(row)]
            top = sorted((c for c in present if c[1] > 0), key=lambda c: -c[1])[:TOP_CONTRIBUTIONS]
            out.append(Prediction(round(self.calibrate(float(probability)), 4), tuple((name, round(value, 3)) for name, value in top)))
        return out
