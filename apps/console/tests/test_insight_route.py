"""GET /v1/admin/audit/{id}/insight: Gemini's reading of a stored score, behind the operator sign-in."""

from __future__ import annotations

import re
import sys
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from api import audit, insight  # noqa: E402
from api.main import app  # noqa: E402
from api.risk_mw import genai_client  # noqa: E402
from tests.test_insight import FakeGemini, good_answer, score_doc  # noqa: E402

DOC_ID = "be977224-1f95-4d7e-ad67-e8d1f4c7bebb"


@pytest.fixture(scope="module")
def client() -> TestClient:
    anonymous = TestClient(app)
    response = anonymous.post("/v1/auth/login", json={"username": "admin", "password": "finnest-local-dev"})
    assert response.status_code == 200, response.text
    signed_in = TestClient(app)
    signed_in.headers["Authorization"] = f"Bearer {response.json()['token']}"
    return signed_in


@pytest.fixture(autouse=True)
def _stored(monkeypatch: pytest.MonkeyPatch) -> None:
    insight.forget()
    monkeypatch.setattr(audit, "one", lambda doc_id, full=False: score_doc() if doc_id == DOC_ID else None)


def test_the_route_needs_a_token() -> None:
    assert TestClient(app).get(f"/v1/admin/audit/{DOC_ID}/insight").status_code == 401


def test_the_route_answers_with_the_reading(client: TestClient, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(insight, "gemini", FakeGemini(good_answer()))
    body = client.get(f"/v1/admin/audit/{DOC_ID}/insight").json()
    assert body["available"] is True
    assert body["insight"]["drivers"][0] == {**good_answer()["drivers"][0], "weight": 0.95}
    assert body["model_id"] == "gemini-test"


def test_gemini_off_is_a_200_that_says_so(client: TestClient, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(insight, "gemini", FakeGemini(genai_client.GenAIDisabled("RISK_MW_GENAI_ENABLED is false")))
    response = client.get(f"/v1/admin/audit/{DOC_ID}/insight")
    assert response.status_code == 200
    assert response.json() == {"available": False, "reason": "genai_disabled"}


def test_an_unknown_or_malformed_id_is_a_404(client: TestClient) -> None:
    assert client.get("/v1/admin/audit/no-such-doc/insight").status_code == 404
    assert client.get("/v1/admin/audit/" + "x" * 200 + "/insight").status_code == 404


def test_the_reading_is_built_from_the_redacted_document(client: TestClient, monkeypatch: pytest.MonkeyPatch) -> None:
    asked: list[bool] = []
    monkeypatch.setattr(audit, "one", lambda doc_id, full=False: asked.append(full) or score_doc())
    monkeypatch.setattr(insight, "gemini", FakeGemini(good_answer()))
    client.get(f"/v1/admin/audit/{DOC_ID}/insight")
    assert asked == [False]


def test_the_deploy_turns_gemini_on_for_the_console_with_its_own_cap() -> None:
    deploy = (ROOT / "scripts" / "deploy.sh").read_text(encoding="utf-8")
    assert "RISK_MW_GENAI_ENABLED=true" in deploy
    assert re.search(r"RISK_MW_PROJECT_ID=\$PROJECT", deploy)
    assert re.search(r"RISK_MW_GENAI_BUDGET_USD=\$\{CONSOLE_GEMINI_BUDGET_USD:-[0-9.]+\}", deploy)
    # app/settings.py reads model ids and prices from ../config/models.yaml beside the vendored app package.
    assert re.search(r'cp "\$ROOT/services/risk-mw/config/models.yaml" "\$CONSOLE/vendor/config/"', deploy)


def test_the_image_installs_the_gemini_sdk() -> None:
    requirements = (ROOT / "api" / "requirements.txt").read_text(encoding="utf-8")
    assert re.search(r"^google-genai>=", requirements, re.M)


def test_the_vendored_layout_reads_the_model_table(tmp_path: Path) -> None:
    """What deploy.sh builds: vendor/app and vendor/config/models.yaml, with vendor/ on the path and no risk-mw beside it."""
    import shutil
    import subprocess

    service = ROOT.parents[1] / "services" / "risk-mw"
    vendor = tmp_path / "vendor"
    shutil.copytree(service / "app", vendor / "app", ignore=shutil.ignore_patterns("__pycache__"))
    (vendor / "config").mkdir()
    shutil.copy(service / "config" / "models.yaml", vendor / "config" / "models.yaml")
    probe = "from app.genai_client import roles; from app.settings import get_settings; " \
            "print(roles()['workhorse'].id, get_settings().models_config_path)"
    result = subprocess.run([sys.executable, "-c", probe], cwd=tmp_path, env={"PYTHONPATH": str(vendor), "PATH": "/usr/bin:/bin"},
                            text=True, capture_output=True, timeout=60)
    assert result.returncode == 0, result.stderr[-2000:]
    model_id, path = result.stdout.split()
    assert model_id.startswith("gemini-") and path == str(vendor / "config" / "models.yaml")
