"""Train the permission classifier on LAMDA with a time-aware split and write the serving artefacts (model v2).

    python -m bhorosha_app_safety_check.train_lamda --lamda /path/to/lamda --out ../../models/app-safety-check \
        [--years 2019-2022] [--naticusdroid /path/to/naticusdroid.csv]

LAMDA (IQSeC Lab, UTEP; https://huggingface.co/datasets/IQSeC-Lab/LAMDA, MIT) ships one `Baseline/<year>_{train,test}.parquet`
pair per year with 4,561 int8 bag-of-words static features and `label` (VirusTotal detections >= 4). This trainer keeps
only what a bank app can see through `PackageManager`: the `RequestedPermissionList_android.permission.*` tokens as
`android.permission.*` columns, plus two derived service columns, "declares an accessibility service" and "declares a
notification listener" (from the `IntentFilterList_` tokens OR the matching `BIND_*` permission request), named as
pseudo-permissions so `pipeline.classifier_hits` can feed them unchanged. SDK-artefact permissions that teach the model
"old app = malware" are dropped (`DROPPED_PERMISSIONS`).

Split (time-aware): fit on the train parquets of `--years` (default 2019-2022) with 30 % of the last year held back for
early stopping and isotonic calibration, report in-distribution metrics on the untouched test parquets of those years,
and report 2023 and 2024 (train + test parquets) as true future data. 2016-2018 are excluded by default: measured on
2026-10-16, training 2016-2022 dragged the pooled hold-out AUC to 0.92 (2016-2018 per-year AUC 0.82-0.87, 2019-2022
0.94-0.97) for the same 2023 AUC, so the oldest years add drift without adding future accuracy; `--years 2016-2022`
reproduces that run. `train.py` stays for CSV datasets.

Calibration is saved into meta.json as monotone knots (`calibration.knots_raw` / `knots_calibrated`); `model.py`
applies them with `numpy.interp`, so model.txt stays a plain LightGBM booster.
"""

from __future__ import annotations

import argparse
import json
import time
from datetime import UTC, datetime
from pathlib import Path

import numpy as np
import pandas as pd

from bhorosha_app_safety_check.features import Vectoriser
from bhorosha_app_safety_check.model import META_FILE, MODEL_FILE
from bhorosha_app_safety_check.schema import canonical_permission

VERSION_PREFIX = "appsafety-0.2-lamda"
SEED = 42
GATE_ACCURACY = 0.90
GATE_ROC_AUC = 0.95
MAX_MODEL_BYTES = 5 * 1024 * 1024  # the FR-3 gate
TARGET_MODEL_BYTES = 4_500_000  # what the trainer keeps under, trimming rounds, so the gate has margin
OPERATING_THRESHOLD = 0.80  # CLASSIFIER_HIGH in schema; recall and benign flag rate are reported at this point
TRAIN_YEARS = (2019, 2020, 2021, 2022)
AVAILABLE_TRAIN_YEARS = (2016, 2017, 2018, 2019, 2020, 2021, 2022)
EXCLUSION_REASON = ("2016-2018 excluded: with them the pooled in-distribution hold-out AUC fell to 0.92 (per-year AUC 2016 0.87, 2017 0.82, "
                    "2018 0.82 vs 2019-2022 0.94-0.97) and the 2023 AUC stayed at 0.92, i.e. measured drift in the oldest years without "
                    "future gain; refit with --years 2016-2022 to reproduce")
FUTURE_YEARS = (2023, 2024)
VALIDATION_FRACTION = 0.3  # of the last training year's train parquet, held back for early stopping and calibration
MAX_KNOTS = 256

PERMISSION_TOKEN = "RequestedPermissionList_android.permission."
SERVICE_COLUMNS = {  # pseudo-permission -> LAMDA tokens that are OR-ed into it
    "android.permission.BIND_ACCESSIBILITY_SERVICE": (
        "IntentFilterList_android.accessibilityservice.AccessibilityService",
        "RequestedPermissionList_android.permission.BIND_ACCESSIBILITY_SERVICE",
    ),
    "android.permission.BIND_NOTIFICATION_LISTENER_SERVICE": (
        "IntentFilterList_android.service.notification.NotificationListenerService",
        "RequestedPermissionList_android.permission.BIND_NOTIFICATION_LISTENER_SERVICE",
    ),
}
DROPPED_PERMISSIONS = (
    "POST_NOTIFICATIONS", "READ_PHONE_STATE", "READ_EXTERNAL_STORAGE", "WRITE_EXTERNAL_STORAGE",
    "MOUNT_UNMOUNT_FILESYSTEMS", "GET_TASKS", "READ_LOGS",
)
# The 5 MB text-model budget caps total leaves near 45k; within it, fewer deeper trees at a higher learning rate scored
# best on the pooled hold-out (sweep 2026-10-16: 63x700 @0.05 AUC 0.916, 127x350 @0.1 AUC 0.921, 255x180 @0.15 AUC 0.923 but 5.1 MB).
PARAMS = {
    "objective": "binary", "num_leaves": 127, "learning_rate": 0.1, "feature_fraction": 0.8, "bagging_fraction": 0.8,
    "bagging_freq": 1, "min_data_in_leaf": 20, "lambda_l2": 1.0, "seed": SEED, "verbose": -1, "num_threads": 0,
}
MAX_ROUNDS = 350
EARLY_STOP = 50
DATASET = {
    "name": "LAMDA Baseline (IQSeC Lab, UTEP), permissions + declared services",
    "licence": "MIT",
    "source_url": "https://huggingface.co/datasets/IQSeC-Lab/LAMDA",
    "paper": "https://arxiv.org/abs/2505.18551",
    "label_column": "label",
    "label_rule": "VirusTotal detections >= 4 -> malware (1); AndroZoo APKs",
}


class FeaturePlan:
    """Serving column order and, per column, the LAMDA `feat_i` ids that are OR-ed into it."""

    def __init__(self, mapping_csv: Path):
        fm = pd.read_csv(mapping_csv)
        token_to_feat = dict(zip(fm["feature_name"], fm["mapped_name"]))
        feats_by_column: dict[str, list[str]] = {}
        for token, feat in token_to_feat.items():
            if token.startswith(PERMISSION_TOKEN):
                column = token[len("RequestedPermissionList_"):]
                if canonical_permission(column) in DROPPED_PERMISSIONS or column in SERVICE_COLUMNS:
                    continue
                feats_by_column.setdefault(column, []).append(feat)
        for column, tokens in SERVICE_COLUMNS.items():
            feats = [token_to_feat[t] for t in tokens if t in token_to_feat]
            if feats:
                feats_by_column[column] = feats
        self.columns: list[str] = sorted(feats_by_column)
        self.feats: list[list[str]] = [feats_by_column[c] for c in self.columns]
        canon = [canonical_permission(c) for c in self.columns]
        if len(set(canon)) != len(canon):
            raise ValueError("two LAMDA columns map onto one canonical permission name")
        self.needed: list[str] = sorted({f for fs in self.feats for f in fs})

    def matrix(self, df: pd.DataFrame) -> np.ndarray:
        x = np.zeros((len(df), len(self.columns)), dtype=np.float32)
        for i, feats in enumerate(self.feats):
            x[:, i] = (df[feats].to_numpy(dtype=np.int16).max(axis=1) > 0)
        return x


def load_year(lamda: Path, year: int, split: str, plan: FeaturePlan) -> tuple[np.ndarray, np.ndarray]:
    path = lamda / "Baseline" / f"{year}_{split}.parquet"
    if not path.exists():
        path = lamda / "Baseline" / str(year) / f"{year}_{split}.parquet"  # the Hugging Face layout
    df = pd.read_parquet(path, columns=[*plan.needed, "label"])
    return plan.matrix(df), df["label"].to_numpy(dtype=np.int8)


def fit(x_fit, y_fit, x_val, y_val):
    import lightgbm as lgb

    train_set = lgb.Dataset(x_fit, label=y_fit)
    val_set = lgb.Dataset(x_val, label=y_val, reference=train_set)
    return lgb.train(PARAMS, train_set, num_boost_round=MAX_ROUNDS, valid_sets=[val_set], callbacks=[lgb.early_stopping(EARLY_STOP, verbose=False)])


def isotonic_knots(raw: np.ndarray, y: np.ndarray) -> tuple[list[float], list[float]]:
    """Monotone raw -> calibrated map as interp knots; piecewise linear between isotonic thresholds, clipped outside."""
    from sklearn.isotonic import IsotonicRegression

    ir = IsotonicRegression(y_min=0.0, y_max=1.0, out_of_bounds="clip", increasing=True).fit(raw, y)
    kr, kc = np.asarray(ir.X_thresholds_, dtype=float), np.asarray(ir.y_thresholds_, dtype=float)
    if len(kr) > MAX_KNOTS:
        keep = np.unique(np.round(np.linspace(0, len(kr) - 1, MAX_KNOTS)).astype(int))
        kr, kc = kr[keep], kc[keep]
    kc = np.clip(kc, 0.001, 0.999)  # a permission pattern is never certain either way
    return [round(float(v), 6) for v in kr], [round(float(v), 6) for v in kc]


def calibrate(raw: np.ndarray, knots: tuple[list[float], list[float]]) -> np.ndarray:
    return np.interp(raw, knots[0], knots[1])


def metrics(y: np.ndarray, p: np.ndarray) -> dict:
    from sklearn.metrics import accuracy_score, brier_score_loss, confusion_matrix, f1_score, roc_auc_score

    pred = (p >= 0.5).astype(int)
    flagged = p >= OPERATING_THRESHOLD
    positives, negatives = y == 1, y == 0
    return {
        "accuracy": round(float(accuracy_score(y, pred)), 4),
        "macro_f1": round(float(f1_score(y, pred, average="macro")), 4),
        "roc_auc": round(float(roc_auc_score(y, p)), 4) if positives.any() and negatives.any() else None,
        "brier": round(float(brier_score_loss(y, p)), 4),
        f"recall_at_{OPERATING_THRESHOLD}": round(float(flagged[positives].mean()), 4) if positives.any() else None,
        f"benign_flag_rate_at_{OPERATING_THRESHOLD}": round(float(flagged[negatives].mean()), 4) if negatives.any() else None,
        "confusion_matrix": {"labels": ["benign", "malicious"], "rows": confusion_matrix(y, pred, labels=[0, 1]).tolist()},
        "test_rows": int(len(y)), "test_positives": int(y.sum()),
    }


def predict_ms(booster, x: np.ndarray) -> float:
    started = time.perf_counter()
    for row in x[:200]:
        booster.predict(row.reshape(1, -1))
    return round((time.perf_counter() - started) * 1000 / min(200, len(x)), 3)


def importances(booster, columns: list[str], k: int = 20) -> list[dict]:
    gains = booster.feature_importance(importance_type="gain")
    order = np.argsort(gains)[::-1][:k]
    total = float(gains.sum()) or 1.0
    return [{"feature": canonical_permission(columns[i]), "gain_share": round(float(gains[i]) / total, 4)} for i in order if gains[i] > 0]


def naticusdroid_continuity(csv: Path, columns: list[str], booster, knots) -> dict:
    """Score the previous training set over the columns the two corpora share (label `Result`, 1 = malware)."""
    df = pd.read_csv(csv, low_memory=False)
    index = {canonical_permission(c): i for i, c in enumerate(columns)}
    common = [(c, index[canonical_permission(c)]) for c in df.columns if c != "Result" and str(c).startswith("android.permission.") and canonical_permission(c) in index]
    x = np.zeros((len(df), len(columns)), dtype=np.float32)
    for c, i in common:
        x[:, i] = (pd.to_numeric(df[c], errors="coerce").fillna(0).to_numpy() > 0)
    y = (pd.to_numeric(df["Result"], errors="coerce").fillna(0).to_numpy() == 1).astype(np.int8)
    m = metrics(y, calibrate(booster.predict(x), knots))
    return {"file": csv.name, "common_columns": len(common), "rows": int(len(df)), **m}


def save_within_budget(booster, out: Path) -> tuple[int, int]:
    """Save the booster; if the text file is over the size target, keep fewer rounds (the early-stopped tail changes little)."""
    rounds = int(booster.best_iteration or booster.current_iteration())
    while True:
        booster.save_model(str(out / MODEL_FILE), num_iteration=rounds)
        size = (out / MODEL_FILE).stat().st_size
        if size <= TARGET_MODEL_BYTES or rounds <= 50:
            return rounds, size
        rounds = int(rounds * TARGET_MODEL_BYTES / size * 0.97)


def train(lamda: Path, out: Path, naticusdroid: Path | None, years: tuple[int, ...] = TRAIN_YEARS) -> dict:
    from sklearn.model_selection import train_test_split

    if not years or any(y >= min(FUTURE_YEARS) for y in years):
        raise SystemExit(f"--years must be training years before {min(FUTURE_YEARS)}, got {years}")
    TRAIN_YEARS = tuple(sorted(years))  # noqa: N806 - shadows the module default on purpose
    plan = FeaturePlan(lamda / "Baseline" / "feature_mapping.csv")
    rows_per_year: dict[str, dict] = {}
    fit_parts, hold_parts = [], []
    x_val = y_val = None
    for year in TRAIN_YEARS:
        x_tr, y_tr = load_year(lamda, year, "train", plan)
        x_te, y_te = load_year(lamda, year, "test", plan)
        rows_per_year[str(year)] = {"train": int(len(y_tr)), "train_positives": int(y_tr.sum()), "test": int(len(y_te)), "test_positives": int(y_te.sum())}
        if year == TRAIN_YEARS[-1]:
            x_tr, x_val, y_tr, y_val = train_test_split(x_tr, y_tr, test_size=VALIDATION_FRACTION, random_state=SEED, stratify=y_tr)
        fit_parts.append((x_tr, y_tr))
        hold_parts.append((year, x_te, y_te))
    x_fit = np.vstack([p[0] for p in fit_parts])
    y_fit = np.concatenate([p[1] for p in fit_parts])
    del fit_parts

    started = time.perf_counter()
    booster = fit(x_fit, y_fit, x_val, y_val)
    train_s = time.perf_counter() - started
    out.mkdir(parents=True, exist_ok=True)
    best = int(booster.best_iteration or booster.current_iteration())
    rounds, size = save_within_budget(booster, out)
    Vectoriser(plan.columns).save(out)

    raw_val = booster.predict(x_val, num_iteration=rounds)
    knots = isotonic_knots(raw_val, y_val)
    val_before, val_after = metrics(y_val, raw_val), metrics(y_val, calibrate(raw_val, knots))

    x_hold = np.vstack([p[1] for p in hold_parts])
    y_hold = np.concatenate([p[2] for p in hold_parts])
    raw_hold = booster.predict(x_hold, num_iteration=rounds)
    m = metrics(y_hold, calibrate(raw_hold, knots))
    m["predict_ms_per_app"] = predict_ms(booster, x_hold)
    m_raw = metrics(y_hold, raw_hold)  # calibration is monotone (same AUC) but moves the 0.5 cut, so both are recorded
    by_year = {str(year): metrics(y_te, calibrate(booster.predict(x_te, num_iteration=rounds), knots)) for year, x_te, y_te in hold_parts}
    del hold_parts, x_hold

    future = {}
    for year in FUTURE_YEARS:
        parts = [load_year(lamda, year, split, plan) for split in ("train", "test")]
        x_f, y_f = np.vstack([p[0] for p in parts]), np.concatenate([p[1] for p in parts])
        rows_per_year[str(year)] = {"rows": int(len(y_f)), "positives": int(y_f.sum()), "used_for": "future-year evaluation only"}
        future[str(year)] = metrics(y_f, calibrate(booster.predict(x_f, num_iteration=rounds), knots))

    continuity = naticusdroid_continuity(naticusdroid, plan.columns, booster, knots) if naticusdroid and naticusdroid.exists() else None

    gates = {"accuracy_ge_0.90": m["accuracy"] >= GATE_ACCURACY, "roc_auc_ge_0.95": m["roc_auc"] >= GATE_ROC_AUC, "model_under_5mb": size <= MAX_MODEL_BYTES}
    meta = {
        "version": f"{VERSION_PREFIX}-lgbm-{rounds}",
        "trained_at": datetime.now(UTC).isoformat(),
        "trainer": "bhorosha_app_safety_check.train_lamda",
        "dataset": {
            **DATASET,
            "train_years": list(TRAIN_YEARS), "future_years": list(FUTURE_YEARS),
            "excluded_years": {"years": [y for y in AVAILABLE_TRAIN_YEARS if y not in TRAIN_YEARS], "reason": EXCLUSION_REASON if set(AVAILABLE_TRAIN_YEARS) - set(TRAIN_YEARS) else ""},
            "rows": int(len(y_fit) + len(y_val)), "positives": int(y_fit.sum() + y_val.sum()),
            "rows_per_year": rows_per_year,
        },
        "features": {
            "count": len(plan.columns),
            "source": "RequestedPermissionList_android.permission.* tokens as android.permission.* columns; two derived service columns",
            "derived_service_columns": {c: list(t) for c, t in SERVICE_COLUMNS.items()},
            "dropped_permissions": list(DROPPED_PERMISSIONS),
            "intents_included": False,
        },
        "split": {
            "scheme": f"time-aware: fit {TRAIN_YEARS[0]}-{TRAIN_YEARS[-1]} train parquets with 30% of {TRAIN_YEARS[-1]} held back (early stopping, calibration); in-distribution hold-out = {TRAIN_YEARS[0]}-{TRAIN_YEARS[-1]} test parquets; future = 2023, 2024 train+test",
            "fit": int(len(y_fit)), "validation": int(len(y_val)), "validation_year": TRAIN_YEARS[-1], "holdout_test": int(m["test_rows"]), "seed": SEED,
        },
        "params": {**PARAMS, "num_boost_round": rounds, "early_stopping_rounds": EARLY_STOP, "best_iteration": best, "rounds_trimmed_for_size": best - rounds, "size_target_bytes": TARGET_MODEL_BYTES},
        "train_seconds": round(train_s, 1),
        "model_bytes": size,
        "metrics": m,
        "metrics_uncalibrated": {k: m_raw[k] for k in ("accuracy", "macro_f1", "roc_auc", "brier")},
        "metrics_by_year": by_year,
        "future_metrics": future,
        "naticusdroid_continuity": continuity,
        "calibration": {
            "method": "isotonic regression, piecewise-linear between thresholds, clipped outside",
            "fitted_on": f"{TRAIN_YEARS[-1]} validation slice ({int(len(y_val))} rows)",
            "knots_raw": knots[0], "knots_calibrated": knots[1],
            "validation_brier_before": val_before["brier"], "validation_brier_after": val_after["brier"],
        },
        "gates": gates,
        "gates_passed": all(gates.values()),
        "top_features": importances(booster, plan.columns),
    }
    (out / META_FILE).write_text(json.dumps(meta, indent=1), encoding="utf-8")
    return meta


def parse_years(spec: str) -> tuple[int, ...]:
    if "-" in spec:
        a, b = spec.split("-", 1)
        return tuple(range(int(a), int(b) + 1))
    return tuple(int(v) for v in spec.split(","))


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--lamda", type=Path, required=True, help="directory holding Baseline/<year>_{train,test}.parquet and Baseline/feature_mapping.csv")
    ap.add_argument("--out", type=Path, default=Path(__file__).resolve().parents[3] / "models" / "app-safety-check")
    ap.add_argument("--naticusdroid", type=Path, default=None, help="optional NATICUSdroid CSV for the continuity check")
    ap.add_argument("--years", default=f"{TRAIN_YEARS[0]}-{TRAIN_YEARS[-1]}", help="training years, '2019-2022' or '2019,2020,2021,2022'")
    args = ap.parse_args(argv)
    meta = train(args.lamda, args.out, args.naticusdroid, parse_years(args.years))
    m = meta["metrics"]
    print(f"{meta['version']}: in-distribution accuracy {m['accuracy']} macro-F1 {m['macro_f1']} ROC-AUC {m['roc_auc']} | "
          f"{meta['features']['count']} features, {meta['model_bytes']/1e6:.2f} MB, {m['predict_ms_per_app']} ms/app | gates {'PASS' if meta['gates_passed'] else 'FAIL'} -> {args.out}")
    for year, f in meta["future_metrics"].items():
        print(f"  {year}: AUC {f['roc_auc']} macro-F1 {f['macro_f1']} recall@{OPERATING_THRESHOLD} {f[f'recall_at_{OPERATING_THRESHOLD}']} benign flag rate {f[f'benign_flag_rate_at_{OPERATING_THRESHOLD}']} ({f['test_rows']} rows, {f['test_positives']} malware)")
    if meta["naticusdroid_continuity"]:
        c = meta["naticusdroid_continuity"]
        print(f"  NATICUSdroid continuity ({c['common_columns']} common columns): accuracy {c['accuracy']} AUC {c['roc_auc']}")


if __name__ == "__main__":
    main()
