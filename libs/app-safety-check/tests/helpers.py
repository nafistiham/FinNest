"""Shared builders for the bhorosha_app_safety_check unit tests (import as `from helpers import ...`)."""
import sys
from pathlib import Path

import numpy as np
import pytest

MODULE_DIR = Path(__file__).resolve().parents[1]
if str(MODULE_DIR) not in sys.path:
    sys.path.insert(0, str(MODULE_DIR))

from bhorosha_app_safety_check import schema as s  # noqa: E402

PLAY = "com.android.vending"
CHROME = "com.android.chrome"


def app(package: str, label: str = "", installer: str | None = PLAY, perms: tuple[str, ...] = (), service: bool = False, enabled: bool = False) -> s.AppRow:
    return s.AppRow(package, label, installer, permissions=tuple(f"android.permission.{p}" for p in perms), has_accessibility_service=service, accessibility_enabled=enabled)


def bundle(apps: tuple[s.AppRow, ...] = (), device: s.DeviceRow | None = None, integrity: s.IntegrityVerdict | None = None, attestation: str = "device", **kw) -> s.Bundle:
    """A bundle from a genuine build on a healthy phone unless told otherwise."""
    return s.Bundle(apps=apps, device=device or s.DeviceRow(), integrity=integrity or s.IntegrityVerdict(source="demo", device_recognition=("MEETS_DEVICE_INTEGRITY",), app_recognition="PLAY_RECOGNIZED"), attestation=attestation, **kw)


@pytest.fixture
def takanow() -> s.AppRow:
    return app("com.demo.takanow", "TakaNow Loan", CHROME, ("READ_CONTACTS", "READ_SMS", "RECEIVE_SMS", "READ_MEDIA_IMAGES", "ACCESS_FINE_LOCATION", "SYSTEM_ALERT_WINDOW", "REQUEST_INSTALL_PACKAGES"), service=True, enabled=True)


@pytest.fixture
def clean_apps() -> tuple[s.AppRow, ...]:
    return (
        app("com.whatsapp", "WhatsApp", perms=("READ_CONTACTS", "CAMERA", "RECORD_AUDIO")),
        app("com.google.android.apps.maps", "Maps", perms=("ACCESS_FINE_LOCATION",)),
        app("com.android.settings", "Settings", installer="system"),
    )


@pytest.fixture(scope="session")
def tiny_artefacts(tmp_path_factory) -> Path:
    """A real LightGBM booster on a toy permission table, so the serving path is exercised end to end."""
    import lightgbm as lgb

    from bhorosha_app_safety_check.features import Vectoriser
    from bhorosha_app_safety_check.model import META_FILE, MODEL_FILE

    rng = np.random.default_rng(7)
    columns = ["android.permission.READ_SMS", "android.permission.RECEIVE_SMS", "android.permission.READ_CONTACTS", "android.permission.SYSTEM_ALERT_WINDOW", "android.permission.INTERNET", "android.permission.CAMERA", "android.permission.ACCESS_FINE_LOCATION", "android.permission.BIND_ACCESSIBILITY_SERVICE"]
    n = 600
    y = rng.integers(0, 2, n)
    x = np.zeros((n, len(columns)), dtype=np.float32)
    for i in range(n):
        if y[i]:
            x[i, [0, 1, 3, 7]] = rng.random(4) < 0.9
            x[i, [4, 2]] = rng.random(2) < 0.6
        else:
            x[i, [4, 5, 6]] = rng.random(3) < 0.7
            x[i, [2]] = rng.random(1) < 0.3
    booster = lgb.train({"objective": "binary", "num_leaves": 7, "learning_rate": 0.2, "verbose": -1, "min_data_in_leaf": 5, "seed": 1}, lgb.Dataset(x, label=y), num_boost_round=40)
    out = tmp_path_factory.mktemp("artefacts")
    booster.save_model(str(out / MODEL_FILE))
    Vectoriser(columns).save(out)
    (out / META_FILE).write_text('{"version": "test-lgbm", "gates_passed": true}', encoding="utf-8")
    return out
