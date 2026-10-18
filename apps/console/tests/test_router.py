"""The routes answer, and they answer in the shape the console was built against.

Each test asserts the response parses into its declared model. That is the whole point of the strict
schemas: the console generates its TypeScript from this service's OpenAPI, so a field renamed here
without a migration fails at this line rather than as an undefined on a rendered page.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from api.main import app  # noqa: E402
from api.risk_mw import get_settings, mule, scenario_now  # noqa: E402
from api.schemas import Account, Health, Model, Overview  # noqa: E402


@pytest.fixture(scope="module")
def anonymous() -> TestClient:
    return TestClient(app)


@pytest.fixture(scope="module")
def client(anonymous: TestClient) -> TestClient:
    """A signed-in operator. Every /v1/admin route needs one."""
    response = anonymous.post("/v1/auth/login", json={"username": "admin", "password": "finnest-local-dev"})
    assert response.status_code == 200, response.text
    signed_in = TestClient(app)
    signed_in.headers["Authorization"] = f"Bearer {response.json()['token']}"
    return signed_in


def test_admin_routes_need_a_token(anonymous: TestClient) -> None:
    for path in ("/v1/admin/overview", "/v1/admin/models", "/v1/admin/account/acct_01070",
                 "/v1/admin/audit", "/v1/admin/audit/some-doc-id",
                 "/v1/admin/campaigns", "/v1/admin/campaigns/inc_000000000000",
                 "/v1/admin/cashout", "/v1/admin/cashout/day/2026-10-23", "/v1/admin/cashout/day/not-a-date"):
        assert anonymous.get(path).status_code == 401, path


def test_wrong_password_is_rejected(anonymous: TestClient) -> None:
    assert anonymous.post("/v1/auth/login", json={"username": "admin", "password": "no"}).status_code == 401
    assert anonymous.post("/v1/auth/login", json={"username": "someone", "password": "finnest-local-dev"}).status_code == 401


def test_a_tampered_token_is_rejected(client: TestClient) -> None:
    token = client.headers["Authorization"].removeprefix("Bearer ")
    bad = TestClient(app)
    bad.headers["Authorization"] = f"Bearer {token[:-3]}xyz"
    assert bad.get("/v1/admin/overview").status_code == 401


def test_me_returns_the_operator(client: TestClient) -> None:
    assert client.get("/v1/auth/me").json() == {"username": "admin"}


def test_health(client: TestClient) -> None:
    response = client.get("/health")
    assert response.status_code == 200
    health = Health(**response.json())
    assert health.service == "finnest-admin"
    assert health.synthetic is True


def test_overview_parses_into_its_model(client: TestClient) -> None:
    response = client.get("/v1/admin/overview")
    assert response.status_code == 200, response.text
    overview = Overview(**response.json())
    assert overview.replay.denominator > 0
    assert overview.source.synthetic is True
    assert len(overview.gates) == 8
    assert len(overview.targets) == 5


def test_overview_is_served_from_the_fixture_fast(client: TestClient) -> None:
    """First paint must not wait on a SHAP pass."""
    response = client.get("/v1/admin/overview")
    assert float(response.headers["X-Processing-Time-Ms"]) < 500


def test_models_route(client: TestClient) -> None:
    response = client.get("/v1/admin/models")
    assert response.status_code == 200
    rows = [Model(**row) for row in response.json()]
    # case-zero and ato-identity rows appear only when their eval results exist (they are not committed).
    assert {row.id for row in rows} >= {"mule-lgbm", "app-safety"}


def test_account_drill_down(client: TestClient) -> None:
    response = client.get("/v1/admin/account/acct_01070")
    assert response.status_code == 200, response.text
    account = Account(**response.json())
    assert account.acct_id == "acct_01070"
    # The drawer scores at the server's scenario clock, as /v1/mule/score does. At the demo instant the payee has not yet
    # received Rina's transfer, so on the evidence so far it scores low (0.0002); the old end-of-world score saw the ring finish.
    assert account.mule is not None and account.mule.as_of == scenario_now(get_settings())
    assert account.mule.probability == round(mule.model().score_at("acct_01070", account.mule.as_of)["probability"], 4)
    assert account.label is not None and account.label.role == "mule_L1"
    assert account.transaction_count > 0
    assert account.synthetic is True


def test_unknown_account_is_a_404(client: TestClient) -> None:
    assert client.get("/v1/admin/account/acct_does_not_exist").status_code == 404


# --- Case Zero ---------------------------------------------------------------

def test_casezero_health_reports_reachability_rather_than_failing(client: TestClient) -> None:
    """A neighbour being down must degrade the panel, never the page."""
    response = client.get("/v1/admin/casezero/health")
    assert response.status_code == 200
    assert "reachable" in response.json()


def test_watchlist_joins_the_payment_path(client: TestClient) -> None:
    """The point of this route: what the investigator named, against what the rules did about it."""
    response = client.get("/v1/admin/casezero/watchlist")
    if response.status_code == 502:
        pytest.skip("case zero unreachable from this machine")
    assert response.status_code == 200, response.text
    body = response.json()
    gap = body["gap"]
    assert gap["watchlisted_accounts"] == len(body["payees"])
    assert gap["payments_to_watchlisted"] == sum(p["payments_to_this_payee"] for p in body["payees"])
    assert gap["stopped_by_rules"] + gap["missed"] == gap["payments_to_watchlisted"]
    for payee in body["payees"]:
        assert payee["stopped_by_rules"] <= payee["payments_to_this_payee"]


def test_casezero_routes_need_a_token(anonymous: TestClient) -> None:
    assert anonymous.get("/v1/admin/casezero/watchlist").status_code == 401


def test_the_console_html_always_revalidates(client: TestClient) -> None:
    """A deploy nobody can see is a deploy that did not happen.

    StaticFiles sends no Cache-Control, and a browser given no instruction caches heuristically
    without revalidating - so index.html came from the viewer's own cache, pointing at the previous
    build's assets, which were cached too. The console looked unchanged while the API under it was
    new.
    """
    response = client.get("/")
    if response.status_code == 404:
        pytest.skip("no built console in this checkout")
    assert response.headers["cache-control"] == "no-cache"


def test_hashed_assets_are_cacheable_forever(client: TestClient) -> None:
    """The other half: a fingerprinted name means a changed file is a different URL."""
    page = client.get("/")
    if page.status_code == 404:
        pytest.skip("no built console in this checkout")
    asset = re.search(r"assets/[A-Za-z0-9._-]+\.js", page.text)
    assert asset, "the console page references no asset"
    headers = client.get(f"/{asset.group(0)}").headers
    assert "immutable" in headers["cache-control"]
    assert "max-age=31536000" in headers["cache-control"]
