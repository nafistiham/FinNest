import os
import sys
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

SERVICE_DIR = Path(__file__).resolve().parent.parent
ROOT_DIR = SERVICE_DIR.parent.parent  # the repository root
PROJECT_DIR = ROOT_DIR  # kept for test modules that import it
sys.path.insert(0, str(SERVICE_DIR))
# bhorosha_graph and bhorosha_synth (libs/synth), bhorosha_ato (libs/ato) and
# bhorosha_app_safety_check (libs/app-safety-check). scripts/deploy.sh vendors the same
# packages into the image.
sys.path.insert(0, str(ROOT_DIR / "libs" / "synth"))
# The behaviour (ATO) artefacts directory has no default here. Every test that wants the
# behaviour signal points RISK_MW_ATO_ARTEFACTS_DIR at a directory itself (a temp directory it
# trains, or models/ato on purpose). A default would be shadowed in those tests and would make
# every other suite load the behaviour models first.
sys.path.insert(0, str(ROOT_DIR / "libs" / "ato"))
sys.path.insert(0, str(ROOT_DIR / "libs" / "app-safety-check"))

os.environ.setdefault("RISK_MW_DEMO_MODE", "true")
os.environ.setdefault("RISK_MW_AUTH_REQUIRED", "false")
os.environ.setdefault("RISK_MW_FIRESTORE_ENABLED", "false")
os.environ.setdefault("RISK_MW_GENAI_ENABLED", "false")
os.environ.setdefault("RISK_MW_RATE_LIMIT_ENABLED", "false")
os.environ.setdefault("RISK_MW_MULE_ARTEFACTS_DIR", str(ROOT_DIR / "models" / "mule"))
os.environ.setdefault("RISK_MW_APPSAFETY_ARTEFACTS_DIR", str(ROOT_DIR / "models" / "app-safety-check"))


@pytest.fixture(scope="session")
def client() -> TestClient:
    from main import app

    with TestClient(app) as test_client:
        yield test_client


@pytest.fixture
def score_body() -> dict:
    return {
        "user_id": "rina",
        "session_id": "s1",
        "txn": {"type": "send_money", "amount_bdt": 500, "to_account": "acct_pirganj", "is_new_payee": False},
        "demo_flags": {},
    }


@pytest.fixture(autouse=True)
def fresh_state():
    """Each test starts with an empty in-memory state store (demo_state, users, interventions, ...), and no customer's App
    Safety result or behaviour session from an earlier test: Apa's warning reads both (app.warnings.signals)."""
    from app import appsafety_engine, ato, state

    state.reset_memory()
    appsafety_engine.forget_verdicts()
    appsafety_engine.forget_carried()
    ato.forget_evidence()
    yield
    state.reset_memory()
    appsafety_engine.forget_verdicts()
    appsafety_engine.forget_carried()
    ato.forget_evidence()


@pytest.fixture(autouse=True)
def no_real_gemini(monkeypatch):
    """No test may reach a real model. Building a real google-genai client or loading real Google credentials raises
    inside the app (an ordinary exception, so the shared TestClient survives) and fails the test at teardown.
    A test that needs a client patches google.genai.Client itself (see test_genai_client.fake_genai)."""
    import google.genai

    from app import genai_client

    attempts = []

    class NoRealGemini:
        def __init__(self, *args, **kwargs):
            attempts.append("google.genai.Client")
            raise AssertionError("tests must not build a real Gemini client")

    def no_credentials():
        attempts.append("google.auth.default")
        raise AssertionError("tests must not load real Google credentials")

    monkeypatch.setattr(google.genai, "Client", NoRealGemini)
    monkeypatch.setattr(genai_client, "_credentials", no_credentials)
    genai_client._cached_client.cache_clear()
    yield
    genai_client._cached_client.cache_clear()
    if attempts:
        pytest.fail(f"the test tried to reach a real Gemini model: {attempts}")


@pytest.fixture(autouse=True)
def _fresh_request_state():
    """Every test starts with no session signals, interventions or trusted-contact requests in memory.

    Session state feeds the rules: an OFFHOOK posted by one test would otherwise hold another test's PIN
    reset for the next minute.
    """
    from app import interventions, sessions
    from app.routers import actions

    sessions.forget()
    interventions.STORE.clear()
    actions.STORE.clear()
    yield


@pytest.fixture
def auth_on(monkeypatch):
    """Auth required, with the Firebase check faked to "the bearer token is the uid" (as the auth probes do)."""
    from app.settings import get_settings

    monkeypatch.setenv("RISK_MW_AUTH_REQUIRED", "true")
    monkeypatch.setattr("app.auth._verify_firebase_token", lambda token: token)
    get_settings.cache_clear()
    yield
    get_settings.cache_clear()


@pytest.fixture(autouse=True)
def no_trailing_timers(monkeypatch):
    """No test leaves a pre-render timer behind to fire into a later test's store; tests/test_prerender.py inspects them."""
    from app import prerender

    class Recorder:
        def schedule(self, key, delay, fn):
            return False

    monkeypatch.setattr(prerender, "TRAILING", Recorder())
