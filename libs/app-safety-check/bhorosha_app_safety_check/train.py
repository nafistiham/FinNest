"""Train the permission classifier and write the serving artefacts plus metrics.

    python -m bhorosha_app_safety_check.train --csv data/dataset.csv --label-column class --malicious-labels "1,S" \
        --out ../../models/app-safety-check --dataset-name "CICMalDroid 2020 static features"

Reads a CSV of one app per row with binary permission / intent columns and a label column; keeps only
`android.permission.*`-style columns (plus intent actions when present); stratified 80/20 split with a fixed seed;
LightGBM with early stopping on a slice of the training fold. Gates (accuracy >= 0.90, ROC-AUC >= 0.95) and the
confusion matrix land in meta.json and in the eval JSON; the model file must stay under 5 MB (FR-3).
"""

from __future__ import annotations

import argparse
import json
import re
import time
from datetime import UTC, datetime
from pathlib import Path

import numpy as np
import pandas as pd

from bhorosha_app_safety_check import __version__
from bhorosha_app_safety_check.features import Vectoriser
from bhorosha_app_safety_check.model import META_FILE, MODEL_FILE

SEED = 42
GATE_ACCURACY = 0.90
GATE_ROC_AUC = 0.95
MAX_MODEL_BYTES = 5 * 1024 * 1024
PERMISSION_COLUMN = re.compile(r"(^|\.)([A-Z][A-Z0-9_]{3,})$")  # ends in an UPPER_SNAKE token: READ_SMS, android.permission.READ_SMS
INTENT_COLUMN = re.compile(r"android\.intent\.action\.", re.IGNORECASE)
PARAMS = {
    "objective": "binary", "num_leaves": 63, "learning_rate": 0.05, "feature_fraction": 0.8, "bagging_fraction": 0.8,
    "bagging_freq": 1, "min_data_in_leaf": 20, "lambda_l2": 1.0, "is_unbalance": True, "seed": SEED, "verbose": -1,
}
MAX_ROUNDS = 400
EARLY_STOP = 40


def feature_columns(df: pd.DataFrame, label: str, include_intents: bool = True) -> list[str]:
    cols = []
    for c in df.columns:
        if c == label:
            continue
        name = str(c)
        if PERMISSION_COLUMN.search(name) or (include_intents and INTENT_COLUMN.search(name)):
            cols.append(c)
    return cols


def binarise(df: pd.DataFrame, cols: list[str]) -> np.ndarray:
    x = df[cols].apply(pd.to_numeric, errors="coerce").fillna(0).to_numpy(dtype=np.float32)
    return (x > 0).astype(np.float32)


def labels(df: pd.DataFrame, label: str, malicious: set[str]) -> np.ndarray:
    raw = df[label].astype(str).str.strip()
    return raw.isin(malicious).to_numpy(dtype=np.int8)


def split(x: np.ndarray, y: np.ndarray, seed: int = SEED):
    from sklearn.model_selection import train_test_split

    x_tr, x_te, y_tr, y_te = train_test_split(x, y, test_size=0.2, random_state=seed, stratify=y)
    x_fit, x_val, y_fit, y_val = train_test_split(x_tr, y_tr, test_size=0.125, random_state=seed, stratify=y_tr)  # 10 % of all
    return (x_fit, y_fit), (x_val, y_val), (x_te, y_te)


def fit(x_fit, y_fit, x_val, y_val):
    import lightgbm as lgb

    train_set = lgb.Dataset(x_fit, label=y_fit)
    val_set = lgb.Dataset(x_val, label=y_val, reference=train_set)
    return lgb.train(PARAMS, train_set, num_boost_round=MAX_ROUNDS, valid_sets=[val_set], callbacks=[lgb.early_stopping(EARLY_STOP, verbose=False)])


def metrics(booster, x_te: np.ndarray, y_te: np.ndarray) -> dict:
    from sklearn.metrics import accuracy_score, confusion_matrix, f1_score, roc_auc_score

    p = booster.predict(x_te)
    pred = (p >= 0.5).astype(int)
    cm = confusion_matrix(y_te, pred, labels=[0, 1]).tolist()
    started = time.perf_counter()
    for row in x_te[:200]:
        booster.predict(row.reshape(1, -1))
    per_app_ms = (time.perf_counter() - started) * 1000 / min(200, len(x_te))
    return {
        "accuracy": round(float(accuracy_score(y_te, pred)), 4),
        "macro_f1": round(float(f1_score(y_te, pred, average="macro")), 4),
        "roc_auc": round(float(roc_auc_score(y_te, p)), 4),
        "confusion_matrix": {"labels": ["benign", "malicious"], "rows": cm},
        "test_rows": int(len(y_te)), "test_positives": int(y_te.sum()),
        "predict_ms_per_app": round(per_app_ms, 3),
    }


def importances(booster, columns: list[str], k: int = 20) -> list[dict]:
    gains = booster.feature_importance(importance_type="gain")
    order = np.argsort(gains)[::-1][:k]
    total = float(gains.sum()) or 1.0
    return [{"feature": columns[i], "gain_share": round(float(gains[i]) / total, 4)} for i in order if gains[i] > 0]


def train(csv: Path, label: str, malicious: set[str], out: Path, dataset_name: str, source_url: str, include_intents: bool = True, max_rows: int | None = None) -> dict:
    df = pd.read_csv(csv, low_memory=False)
    if max_rows:
        df = df.sample(n=min(max_rows, len(df)), random_state=SEED)
    cols = feature_columns(df, label, include_intents)
    if len(cols) < 10:
        raise SystemExit(f"only {len(cols)} permission-like columns found in {csv}; check --label-column and the file")
    x, y = binarise(df, cols), labels(df, label, malicious)
    if y.sum() == 0 or y.sum() == len(y):
        raise SystemExit(f"labels are all one class; --malicious-labels {sorted(malicious)} does not match {df[label].unique()[:10]}")
    (x_fit, y_fit), (x_val, y_val), (x_te, y_te) = split(x, y)
    started = time.perf_counter()
    booster = fit(x_fit, y_fit, x_val, y_val)
    train_s = time.perf_counter() - started
    m = metrics(booster, x_te, y_te)
    out.mkdir(parents=True, exist_ok=True)
    booster.save_model(str(out / MODEL_FILE))
    Vectoriser([str(c) for c in cols]).save(out)
    size = (out / MODEL_FILE).stat().st_size
    gates = {"accuracy_ge_0.90": m["accuracy"] >= GATE_ACCURACY, "roc_auc_ge_0.95": m["roc_auc"] >= GATE_ROC_AUC, "model_under_5mb": size <= MAX_MODEL_BYTES}
    meta = {
        "version": f"{__version__}-lgbm-{booster.best_iteration or booster.current_iteration()}",
        "trained_at": datetime.now(UTC).isoformat(),
        "dataset": {"name": dataset_name, "source_url": source_url, "file": csv.name, "rows": int(len(df)), "positives": int(y.sum()), "label_column": label, "malicious_labels": sorted(malicious)},
        "features": {"count": len(cols), "intents_included": include_intents},
        "split": {"train": int(len(y_fit)), "validation": int(len(y_val)), "test": int(len(y_te)), "seed": SEED},
        "params": {**PARAMS, "num_boost_round": int(booster.best_iteration or booster.current_iteration()), "early_stopping_rounds": EARLY_STOP},
        "train_seconds": round(train_s, 1),
        "model_bytes": size,
        "metrics": m,
        "gates": gates,
        "gates_passed": all(gates.values()),
        "top_features": importances(booster, [str(c) for c in cols]),
    }
    (out / META_FILE).write_text(json.dumps(meta, indent=1), encoding="utf-8")
    return meta


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--csv", type=Path, required=True)
    ap.add_argument("--label-column", required=True)
    ap.add_argument("--malicious-labels", required=True, help="comma-separated label values that mean malicious")
    ap.add_argument("--out", type=Path, default=Path(__file__).resolve().parents[3] / "models" / "app-safety-check")
    ap.add_argument("--dataset-name", default="")
    ap.add_argument("--source-url", default="")
    ap.add_argument("--no-intents", action="store_true")
    ap.add_argument("--max-rows", type=int, default=None)
    args = ap.parse_args(argv)
    meta = train(args.csv, args.label_column, {v.strip() for v in args.malicious_labels.split(",")}, args.out, args.dataset_name, args.source_url, not args.no_intents, args.max_rows)
    m = meta["metrics"]
    print(f"{meta['version']}: accuracy {m['accuracy']} macro-F1 {m['macro_f1']} ROC-AUC {m['roc_auc']} | {meta['features']['count']} features, {meta['model_bytes']/1e6:.2f} MB, {m['predict_ms_per_app']} ms/app | gates {'PASS' if meta['gates_passed'] else 'FAIL'} -> {args.out}")


if __name__ == "__main__":
    main()
