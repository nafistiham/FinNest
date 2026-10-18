"""Train the session risk model on synthetic sessions and write models/session_risk.{joblib,json}.

    python scripts/train_session_model.py

There is no real labelled session data, so sessions are drawn from the assumptions below (seed 32).
They encode the spec's story: scam sessions usually happen during a call with a non-contact, often to
a new payee above the usual amount, with a higher scam-conversation score and more hesitant typing.
Device age (since session-hgb-0.2): scam sessions skew modestly to a phone this app first saw in the
last week (a fraudster's own handset, or a fresh install someone talked her into), 15% against 5% of
genuine ones; both otherwise spread over four years, and a fifth of each reports no age and reads 365 days.
The model's scores are therefore illustrative. Rules, not this model, decide holds.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import joblib
import numpy as np
from sklearn.ensemble import HistGradientBoostingClassifier
from sklearn.metrics import roc_auc_score

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from app.session_model import DEVICE_AGE_UNKNOWN_DAYS, FEATURES, META_FILE, MODEL_FILE  # noqa: E402

SEED, N, SCAM_RATE, P95, LABEL_NOISE = 32, 20_000, 0.12, 5000.0, 0.03
NEW_DEVICE_DAYS, NEW_DEVICE_IF_SCAM, NEW_DEVICE_IF_BENIGN, DEVICE_AGE_UNREPORTED = 7.0, 0.15, 0.05, 0.20
VERSION = "session-hgb-0.2"


def device_age_days(rng: np.random.Generator, scam: np.ndarray) -> np.ndarray:
    """Days since the app first saw the device; overlapping on purpose, since plenty of genuine customers have a new phone."""
    n = len(scam)
    new = rng.random(n) < np.where(scam, NEW_DEVICE_IF_SCAM, NEW_DEVICE_IF_BENIGN)
    age = np.where(new, rng.uniform(0, NEW_DEVICE_DAYS, n), rng.uniform(NEW_DEVICE_DAYS, 4 * 365, n))
    return np.where(rng.random(n) < DEVICE_AGE_UNREPORTED, DEVICE_AGE_UNKNOWN_DAYS, age)  # older apps: the neutral value


def sessions(rng: np.random.Generator, n: int) -> tuple[np.ndarray, np.ndarray]:
    scam = rng.random(n) < SCAM_RATE

    def p(if_scam: float, if_benign: float) -> np.ndarray:
        return rng.random(n) < np.where(scam, if_scam, if_benign)

    call = p(0.70, 0.25)  # people do send money while on the phone with family
    sim_recent = p(0.20, 0.01)
    txn = np.where(scam, rng.choice(3, n, p=[0.35, 0.55, 0.10]), rng.choice(3, n, p=[0.05, 0.85, 0.10]))
    amount = np.where(scam, rng.lognormal(8.4, 0.8, n), rng.lognormal(7.6, 0.9, n))
    caution, block = p(0.20, 0.05), p(0.08, 0.005)
    cols = {
        "call_active": call, "caller_not_in_contacts": call & p(0.80, 0.35), "screen_shared": p(0.20, 0.03),
        "obscured_touch": p(0.15, 0.01), "accessibility_services": rng.poisson(np.where(scam, 0.8, 0.1)),
        "sim_changed_recent": sim_recent, "sim_changed_hours": np.where(sim_recent, rng.uniform(0, 24, n), rng.uniform(24, 2000, n)),
        "rooted": p(0.05, 0.02), "app_safety_caution": caution & ~block, "app_safety_block": block,
        "inbound_mule_score": np.where(scam, rng.beta(1.5, 4, n), rng.beta(1, 10, n)),
        "scam_score": np.where(scam, rng.beta(3, 3, n), rng.beta(1, 6, n)),
        "txn_pin_reset": txn == 0, "txn_send_money": txn == 1, "txn_new_payee": txn == 2,
        "is_new_payee": p(0.70, 0.25), "amount_log": np.log1p(amount), "amount_over_p95": amount / P95,
        "hesitation": np.where(scam, rng.normal(0.6, 0.8, n), rng.normal(0.0, 0.7, n)),
        "time_on_screen_s": np.clip(np.where(scam, rng.normal(38, 20, n), rng.normal(24, 12, n)), 0, None),
    }
    labels = scam ^ (rng.random(n) < LABEL_NOISE)  # some reported scams are mislabelled, and some benign ones too
    # Drawn last, so every other column and the labels are exactly the sessions 0.1 was trained on.
    cols = {**cols, "device_age_days": device_age_days(rng, scam)}
    return np.column_stack([cols[name].astype(float) for name in FEATURES]), labels.astype(int)


def main() -> None:
    rng = np.random.default_rng(SEED)
    x, y = sessions(rng, N)
    split = int(0.8 * N)
    model = HistGradientBoostingClassifier(max_depth=4, max_iter=200, learning_rate=0.08, random_state=SEED).fit(x[:split], y[:split])
    auc = roc_auc_score(y[split:], model.predict_proba(x[split:])[:, 1])
    MODEL_FILE.parent.mkdir(parents=True, exist_ok=True)
    joblib.dump(model, MODEL_FILE)
    META_FILE.write_text(json.dumps({"version": VERSION, "features": list(FEATURES), "holdout_auc": round(float(auc), 4), "n": N,
                                     "scam_rate": SCAM_RATE, "label_noise": LABEL_NOISE, "seed": SEED,
                                     "device_age_unknown_days": DEVICE_AGE_UNKNOWN_DAYS,
                                     "trained_on": "synthetic sessions from scripts/train_session_model.py; illustrative, not real data"}, indent=2),
                         encoding="utf-8")
    print(f"{VERSION}: holdout AUC {auc:.4f} on synthetic sessions -> {MODEL_FILE}")


if __name__ == "__main__":
    main()
