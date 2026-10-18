"""Session risk model: 21 features from the score request and the session's stored signals.

Trained by scripts/train_session_model.py on a synthetic session generator with written-down
assumptions (there is no real labelled data), so its numbers are illustrative. It is fused as
risk = max(rules, model); on its own it can only ask for a step-up, never hold money.
"""

from __future__ import annotations

import json
import math
from functools import lru_cache
from pathlib import Path

from app.contracts import ScoreRequest

MODEL_DIR = Path(__file__).resolve().parent.parent / "models"
MODEL_FILE = MODEL_DIR / "session_risk.joblib"
META_FILE = MODEL_DIR / "session_risk.json"

FEATURES = (
    "call_active", "caller_not_in_contacts", "screen_shared", "obscured_touch", "accessibility_services",
    "sim_changed_recent", "sim_changed_hours", "rooted", "device_age_days", "app_safety_caution", "app_safety_block",
    "inbound_mule_score", "scam_score", "txn_pin_reset", "txn_send_money", "txn_new_payee",
    "is_new_payee", "amount_log", "amount_over_p95", "hesitation", "time_on_screen_s",
)
SIM_UNKNOWN_HOURS = 2000.0
# An app that does not report when it first saw the device reads as a phone a year old: neutral, never alarming.
DEVICE_AGE_UNKNOWN_DAYS = 365.0
# hesitation and time_on_screen_s are fixed at the no-signal values. Typing and touch behaviour belongs to the
# behaviour model (app.ato), whose wire vector starts with swipe ms and px: read here, they made a normal 3,000 BDT
# send score 0.43 instead of 0.08.
NO_TYPING_SIGNAL = (0.0, 0.0)


def features(req: ScoreRequest, signals: dict, p95_amount_bdt: float) -> list[float]:
    f, t = req.demo_flags, req.txn
    call_active = f.call_active or signals.get("call_state") == "OFFHOOK"
    sim_hours = signals.get("subscription_changed_hours")
    sim_hours = 1.0 if f.sim_swap and sim_hours is None else (SIM_UNKNOWN_HOURS if sim_hours is None else float(sim_hours))
    device_age = signals.get("device_age_days")
    return [
        float(call_active), float(call_active and not f.caller_in_contacts),
        float(f.screen_share or bool(signals.get("screen_capture")) or bool(signals.get("screen_recording"))),
        float(bool(signals.get("obscured_touch"))), float(len(signals.get("accessibility_services") or ())),
        float(sim_hours <= 24.0), sim_hours, float(bool(signals.get("rooted"))),
        DEVICE_AGE_UNKNOWN_DAYS if device_age is None else float(device_age),
        float(f.app_safety_verdict == "CAUTION"), float(f.app_safety_verdict == "BLOCK"),
        f.inbound_mule_score, f.scam_score,
        float(t.type == "pin_reset"), float(t.type == "send_money"), float(t.type == "new_payee"),
        float(t.is_new_payee), math.log1p(t.amount_bdt), t.amount_bdt / max(p95_amount_bdt, 1.0),
        *NO_TYPING_SIGNAL,
    ]


@lru_cache(maxsize=1)
def _load():
    import joblib

    return joblib.load(MODEL_FILE), json.loads(META_FILE.read_text(encoding="utf-8"))


def warm_up() -> None:
    """Load the model and run one throwaway prediction at start-up: sklearn's first predict_proba is the slow one (5 ms, then 0.4)."""
    model, _ = _load()
    model.predict_proba([[0.0] * len(FEATURES)])


def predict(req: ScoreRequest, signals: dict, p95_amount_bdt: float) -> float:
    model, _ = _load()
    return round(float(model.predict_proba([features(req, signals, p95_amount_bdt)])[0][1]), 3)


def model_version() -> str:
    return _load()[1]["version"]
