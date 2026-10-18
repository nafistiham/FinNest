"""GET /v1/admin/campaigns and /v1/admin/campaigns/{incident_id}: the Incidents view's two reads.

Both serve fixtures/campaigns.json and nothing else: no radar run, Firestore read or Gemini call at
request time. A missing or malformed fixture is `available: false`, the way the audit log reports a
Firestore it cannot reach; it is never a 500 and never a page of zeros.
"""

from __future__ import annotations

import json
import sys
from collections.abc import Iterator
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from api import campaigns  # noqa: E402
from api.main import app  # noqa: E402
from api.schemas import CampaignIncident, CampaignsList  # noqa: E402


@pytest.fixture(scope="module")
def client() -> TestClient:
    anonymous = TestClient(app)
    response = anonymous.post("/v1/auth/login", json={"username": "admin", "password": "finnest-local-dev"})
    assert response.status_code == 200, response.text
    signed_in = TestClient(app)
    signed_in.headers["Authorization"] = f"Bearer {response.json()['token']}"
    return signed_in


@pytest.fixture
def fixture_at(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> Iterator[Path]:
    """Point the reader at a scratch file, and forget whatever it had cached."""
    path = tmp_path / "campaigns.json"
    monkeypatch.setattr(campaigns, "FIXTURE", path)
    campaigns.forget()
    yield path
    campaigns.forget()


@pytest.fixture(scope="module")
def listing(client: TestClient) -> dict:
    campaigns.forget()
    response = client.get("/v1/admin/campaigns")
    assert response.status_code == 200, response.text
    return response.json()


def test_the_list_parses_into_its_model(listing: dict) -> None:
    body = CampaignsList(**listing)
    assert body.available is True
    assert body.source is not None and body.source.synthetic is True
    assert len(body.incidents) == 31
    assert {c.campaign_id for c in body.campaigns} >= {"camp_4e281feff4", "camp_4a56fe9746", "camp_5815ecd8fd"}
    assert body.evaluation is not None and len(body.evaluation.campaigns) == 3


def test_the_list_carries_no_attempts_or_firings(listing: dict) -> None:
    """The list is the rail and the campaign table; the heavy rows come with one incident."""
    assert "attempts" not in listing and "firings" not in listing


def test_one_incident_comes_with_everything_its_panels_draw(client: TestClient, listing: dict) -> None:
    top = max(listing["incidents"], key=lambda i: i["surprise"])
    response = client.get(f"/v1/admin/campaigns/{top['incident_id']}")
    assert response.status_code == 200, response.text
    body = CampaignIncident(**response.json())
    assert body.available is True and body.incident is not None
    assert body.incident.incident_id == top["incident_id"]
    assert body.campaigns and all(top["incident_id"] in c.incident_ids for c in body.campaigns)
    held = {a.attempt_id for a in body.attempts}
    assert set(top["attempt_ids"]) <= held
    for campaign in body.campaigns:
        assert set(campaign.attempt_ids) <= held
        assert {aid for triple in campaign.evidence for aid in triple[:2]} <= held
    assert body.firings and all(f.key == top["key"] and f.cell == top["cell"] for f in body.firings)
    assert {f.run_ts for f in body.firings} == set(top["firing_runs"])


def test_an_incident_in_two_campaigns_returns_both_in_id_order(client: TestClient, listing: dict) -> None:
    shared = [i for i in listing["incidents"]
              if sum(i["incident_id"] in c["incident_ids"] for c in listing["campaigns"]) > 1]
    assert shared, "the campaign world has incidents two snapshots share"
    body = client.get(f"/v1/admin/campaigns/{shared[0]['incident_id']}").json()
    ids = [c["campaign_id"] for c in body["campaigns"]]
    assert len(ids) > 1 and ids == sorted(ids)


def test_an_unknown_incident_is_a_404(client: TestClient) -> None:
    assert client.get("/v1/admin/campaigns/inc_000000000000").status_code == 404
    assert client.get("/v1/admin/campaigns/not-an-incident").status_code == 404


def test_served_from_the_fixture_fast(client: TestClient, listing: dict) -> None:
    response = client.get(f"/v1/admin/campaigns/{listing['incidents'][0]['incident_id']}")
    assert float(response.headers["X-Processing-Time-Ms"]) < 500


def test_a_missing_fixture_is_unavailable_not_an_error(client: TestClient, fixture_at: Path) -> None:
    for path in ("/v1/admin/campaigns", "/v1/admin/campaigns/inc_000000000000"):
        response = client.get(path)
        assert response.status_code == 200, path
        assert response.json()["available"] is False, path
        assert "build_campaigns" in response.json()["reason"]


@pytest.mark.parametrize("payload", [b"{not json", b"\xff\xfe\x00not utf-8", b"[]"])
def test_malformed_fixture_is_unavailable(client: TestClient, fixture_at: Path, payload: bytes) -> None:
    fixture_at.write_bytes(payload)
    for path in ("/v1/admin/campaigns", "/v1/admin/campaigns/inc_000000000000"):
        response = client.get(path)
        assert response.status_code == 200, path
        assert response.json()["available"] is False, path


def test_a_fixture_missing_a_section_is_unavailable(client: TestClient, fixture_at: Path) -> None:
    whole = json.loads(campaigns.DEFAULT_FIXTURE.read_text(encoding="utf-8"))
    fixture_at.write_text(json.dumps({k: v for k, v in whole.items() if k != "incidents"}))
    response = client.get("/v1/admin/campaigns")
    assert response.status_code == 200
    assert response.json()["available"] is False


def test_a_rebuilt_fixture_is_read_again(client: TestClient, fixture_at: Path) -> None:
    whole = json.loads(campaigns.DEFAULT_FIXTURE.read_text(encoding="utf-8"))
    fixture_at.write_text(json.dumps(whole))
    assert len(client.get("/v1/admin/campaigns").json()["incidents"]) == 31
    fixture_at.write_text(json.dumps({**whole, "incidents": whole["incidents"][:2], "campaigns": []}))
    assert len(client.get("/v1/admin/campaigns").json()["incidents"]) == 2
