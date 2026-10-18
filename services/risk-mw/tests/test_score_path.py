"""Score path (spec sections 3, 6 and 7): the documents a score needs are read in parallel and the models
are loaded at start-up, so the p95 under 100 ms survives Firestore round trips and the first request; device age
travels from /v1/risk/signals into the session model."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app import ato, interventions, scam, session_model, state
from app.contracts import ScoreRequest

SERVICE_DIR = Path(__file__).resolve().parent.parent
READ_S = 0.05  # one Firestore read from Cloud Run, roughly
HELD_SEND = {"user_id": "rina", "session_id": "s1",
             "txn": {"type": "send_money", "amount_bdt": 3000, "to_account": "acct_new", "is_new_payee": True}}


class SlowStore:
    """The memory store with a 50 ms round trip on every read."""

    def __init__(self, inner: state.Store) -> None:
        self.inner = inner

    def get(self, collection: str, doc_id: str) -> dict:
        time.sleep(READ_S)
        return self.inner.get(collection, doc_id)

    def set(self, collection: str, doc_id: str, data: dict) -> None:
        self.inner.set(collection, doc_id, data)

    def merge(self, collection: str, doc_id: str, data: dict) -> None:
        self.inner.merge(collection, doc_id, data)

    def delete(self, collection: str, doc_id: str) -> None:
        self.inner.delete(collection, doc_id)

    def run(self, fn):  # state.transaction: the reads inside are slow too
        return fn(self)


def _every_doc_has_a_say() -> set[str]:
    """One reason per document the score reads, so a read that went missing changes the answer."""
    db = state.store()
    db.set("demo_state", "rina", {"screen_share": True})
    db.set("users", "rina", {"p95_send_bdt": 2000})
    db.set("scam_sessions", "s1", {"turns": [[1.0, 0.95]], "rolling": 0.95, "updated_at": time.time()})
    db.set("money_lock", "rina", {"until": (datetime.now(UTC) + timedelta(hours=1)).isoformat()})
    return {"SCREEN_SHARE_ACTIVE", "NEW_PAYEE_ABOVE_P95", "SCAM_CONVERSATION", "MONEY_LOCK_ACTIVE"}


@pytest.mark.parametrize("seeded", [False, True], ids=["empty-docs", "every-doc-has-a-say"])
def test_a_score_reads_its_documents_at_once(client, monkeypatch, seeded):
    """Demo mode and a send read demo_state, scam_sessions (two keys), users, money_lock and the prepared warning: 250 ms one
    after another. The device signals are not a document: they are the caller's session in app.sessions."""
    codes = _every_doc_has_a_say() if seeded else set()
    plain = client.post("/v1/risk/score", json=HELD_SEND)
    assert plain.status_code == 200 and codes <= {r["code"] for r in plain.json()["reasons"]}

    slow = SlowStore(state.store())
    monkeypatch.setattr(state, "store", lambda: slow)
    resp = client.post("/v1/risk/score", json=HELD_SEND)

    took_ms = float(resp.headers["X-Processing-Time-Ms"])
    assert took_ms < 3 * READ_S * 1000, f"{took_ms:.0f} ms: the reads ran one after another"
    assert resp.json() == plain.json()


def test_start_up_loads_the_session_model_and_the_behaviour_artefacts():
    """The first score must not be the one that pays for loading them (about 170 ms before the warm-up)."""
    from main import app

    session_model._load.cache_clear()
    ato.reset_cache()
    with TestClient(app):
        assert session_model._load.cache_info().currsize == 1
        assert ato.models.cache_info().currsize == 1  # cached even when off: no artefacts directory means None


def test_the_warm_up_also_runs_one_prediction(monkeypatch):
    """Loading is not enough: sklearn's first predict_proba is several times slower than the ones after it."""
    seen = []

    class Model:
        def predict_proba(self, rows):
            seen.extend(rows)
            return [[1.0, 0.0]]

    monkeypatch.setattr(session_model, "_load", lambda: (Model(), {"version": "fake"}))
    session_model.warm_up()
    assert len(seen) == 1 and len(seen[0]) == len(session_model.FEATURES)


FIRST_PREDICT_PER_THREAD = """
import json, threading, time
import main  # sets the OpenMP default before any model runs, as in production
from app import session_model
from app.contracts import ScoreRequest

session_model.warm_up()
req = ScoreRequest(user_id="rina", session_id="t", txn={"type": "send_money", "amount_bdt": 500})
took = []

def predict_once():
    started = time.perf_counter()
    session_model.predict(req, {}, 5000.0)
    took.append((time.perf_counter() - started) * 1000)

for _ in range(5):
    thread = threading.Thread(target=predict_once)
    thread.start()
    thread.join()
print(json.dumps(took))
"""


def test_a_request_thread_that_never_predicted_is_not_slow():
    """FastAPI runs each score on a pool thread. With an OpenMP team per prediction, a thread's first predict_proba
    built its own team (up to about 45 ms); main.py asks for one OpenMP thread, which also makes a warm one 0.3 ms, not 4.7.
    Measured in a fresh interpreter: OpenMP reads the setting once, so in this process any earlier test that predicted
    before main was imported (test_session_model, run first) made this fail at 33-47 ms."""
    env = {k: v for k, v in os.environ.items() if k != "OMP_NUM_THREADS"}  # main.py's own default is what is under test
    run = subprocess.run([sys.executable, "-c", FIRST_PREDICT_PER_THREAD], cwd=SERVICE_DIR, env=env, capture_output=True, text=True,
                         timeout=120)
    assert run.returncode == 0, run.stderr[-800:]
    took = json.loads(run.stdout.strip().splitlines()[-1])
    assert len(took) == 5 and max(took) < 25, took


def test_the_by_id_helpers_still_answer_for_their_other_callers():
    _every_doc_has_a_say()
    assert scam.session_score("s1") == 0.95 and interventions.money_lock_until("rina") is not None
    assert scam.session_score("no-call") == 0.0 and interventions.money_lock_until("nobody") is None


# --- device age (spec section 3 feature inputs) ------------------------------


def _signal(client, session_id: str, first_seen_at: str | None) -> dict:
    device = {"first_seen_at": first_seen_at} if first_seen_at else {}
    resp = client.post("/v1/risk/signals", json={"session_id": session_id, "device": device}, headers={"X-Demo-User": "rina"})
    assert resp.status_code == 200, resp.text
    from app import sessions
    from app.routers import risk
    from app.settings import get_settings
    return risk._model_signals(sessions.recall("rina", session_id, datetime.now(UTC), get_settings()))


def _age(features: list[float]) -> float:
    return features[session_model.FEATURES.index("device_age_days")]


def test_signals_store_the_device_age_in_days(client):
    three_days_ago = (datetime.now(UTC) - timedelta(days=3)).isoformat().replace("+00:00", "Z")
    assert _signal(client, "new-phone", three_days_ago)["device_age_days"] == pytest.approx(3.0, abs=0.01)
    assert _signal(client, "old-app", None)["device_age_days"] is None


def test_a_time_without_a_zone_is_utc_and_a_future_one_is_today(client):
    naive = (datetime.now(UTC) - timedelta(days=10)).replace(tzinfo=None).isoformat()
    assert _signal(client, "naive", naive)["device_age_days"] == pytest.approx(10.0, abs=0.01)
    skewed = (datetime.now(UTC) + timedelta(days=2)).isoformat()
    assert _signal(client, "skewed", skewed)["device_age_days"] == 0.0


def test_the_session_model_reads_device_age_and_an_unknown_one_is_a_neutral_year():
    req = ScoreRequest(user_id="rina", session_id="d", txn={"type": "send_money", "amount_bdt": 500})
    assert _age(session_model.features(req, {"device_age_days": 2.5}, 5000.0)) == 2.5
    assert _age(session_model.features(req, {}, 5000.0)) == _age(session_model.features(req, {"device_age_days": None}, 5000.0)) == 365.0


def test_a_phone_first_seen_this_week_raises_the_model_score():
    """Same call, same new payee, same amount: only the device's age differs."""
    req = ScoreRequest(user_id="rina", session_id="d", txn={"type": "send_money", "amount_bdt": 8000, "is_new_payee": True},
                       demo_flags={"call_active": True, "scam_score": 0.3})
    new, old = (session_model.predict(req, {"device_age_days": days}, 5000.0) for days in (1.0, 700.0))
    assert new > old


def test_a_new_phone_on_its_own_never_holds_money(client, score_body):
    """The model alone can only ask for a step-up; a device first seen an hour ago is no exception."""
    an_hour_ago = (datetime.now(UTC) - timedelta(hours=1)).isoformat()
    _signal(client, score_body["session_id"], an_hour_ago)
    assert client.post("/v1/risk/score", json=score_body).json()["decision"] in {"allow", "step_up"}
