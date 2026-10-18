"""Sign-in settings come from the environment, and a deployed console refuses the local-dev values."""

from __future__ import annotations

import importlib
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

NAMES = ("ADMIN_USER", "ADMIN_PASSWORD", "SESSION_SECRET", "K_SERVICE")


@pytest.fixture
def clean_env(monkeypatch: pytest.MonkeyPatch):
    for name in NAMES:
        monkeypatch.delenv(name, raising=False)
    import api.auth as auth

    yield monkeypatch, auth
    for name in NAMES:
        monkeypatch.delenv(name, raising=False)
    importlib.reload(auth)


def test_the_account_is_read_from_the_environment(clean_env) -> None:
    monkeypatch, auth = clean_env
    monkeypatch.setenv("ADMIN_USER", "analyst")
    monkeypatch.setenv("ADMIN_PASSWORD", "a-real-password")
    reloaded = importlib.reload(auth)
    assert reloaded.USER == "analyst"
    assert reloaded.check_password("analyst", "a-real-password")
    assert not reloaded.check_password("analyst", reloaded.LOCAL_DEV_PASSWORD)


def test_local_development_falls_back_to_the_labelled_defaults(clean_env) -> None:
    _monkeypatch, auth = clean_env
    reloaded = importlib.reload(auth)
    assert reloaded.USER == "admin"
    assert reloaded.check_password("admin", reloaded.LOCAL_DEV_PASSWORD)


@pytest.mark.parametrize("missing", ["ADMIN_PASSWORD", "SESSION_SECRET"])
def test_cloud_run_refuses_to_start_without_real_values(clean_env, missing: str) -> None:
    monkeypatch, auth = clean_env
    monkeypatch.setenv("K_SERVICE", "finnest-admin")
    for name in ("ADMIN_PASSWORD", "SESSION_SECRET"):
        if name != missing:
            monkeypatch.setenv(name, "set-for-real")
    with pytest.raises(RuntimeError, match=missing):
        importlib.reload(auth)


def test_cloud_run_starts_with_real_values(clean_env) -> None:
    monkeypatch, auth = clean_env
    monkeypatch.setenv("K_SERVICE", "finnest-admin")
    monkeypatch.setenv("ADMIN_PASSWORD", "a-real-password")
    monkeypatch.setenv("SESSION_SECRET", "a-real-secret")
    assert importlib.reload(auth).SECRET == "a-real-secret"
