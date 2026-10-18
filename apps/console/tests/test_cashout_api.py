"""GET /v1/admin/cashout and /v1/admin/cashout/day/{date}: the cash-out view's two reads.

Both serve fixtures/cashout.json and nothing else: no rule replay, Firestore read or Gemini call at request time. A
missing or malformed fixture is `available: false`, as the Incidents view's routes report theirs; it is never a 500
and never a map of zeros. A date that is not YYYY-MM-DD is a 422; a well-formed date with no daily run is a 404.
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

from api import cashout  # noqa: E402
from api.main import app  # noqa: E402
from api.schemas import CashoutDayView, CashoutView  # noqa: E402


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
    path = tmp_path / "cashout.json"
    monkeypatch.setattr(cashout, "FIXTURE", path)
    cashout.forget()
    yield path
    cashout.forget()


@pytest.fixture(scope="module")
def whole(client: TestClient) -> dict:
    cashout.forget()
    response = client.get("/v1/admin/cashout")
    assert response.status_code == 200, response.text
    return response.json()


def _flagged_day(whole: dict) -> dict:
    return next(d for d in whole["days"] if d["till_flags"] and d["clusters"])


def test_the_whole_fixture_parses_into_its_model(whole: dict) -> None:
    body = CashoutView(**whole)
    assert body.available is True
    assert body.source is not None and body.source.synthetic is True
    assert len(body.tills) == 40
    assert body.days and body.candidates and body.clusters and body.events
    assert body.evaluation is not None and body.evaluation.candidates


def test_the_whole_fixture_is_the_file(whole: dict) -> None:
    on_disk = json.loads(cashout.DEFAULT_FIXTURE.read_text(encoding="utf-8"))
    assert {k: v for k, v in whole.items() if k not in ("available", "reason")} == on_disk


def test_one_day_comes_with_everything_its_map_draws(client: TestClient, whole: dict) -> None:
    day = _flagged_day(whole)
    response = client.get(f"/v1/admin/cashout/day/{day['date']}")
    assert response.status_code == 200, response.text
    body = CashoutDayView(**response.json())
    assert body.available is True and body.date == day["date"] and body.as_of == day["as_of"]
    assert len(body.tills) == 40
    assert [f.model_dump() for f in body.till_flags] == day["till_flags"]
    assert {c.cluster_id for c in body.clusters} == set(day["clusters"])
    assert [e.model_dump() for e in body.events] == whole["events"][day["date"]]
    listed = [c for c in whole["candidates"] if day["date"] in c["days"]]
    assert [c.model_dump() for c in body.candidates] == listed
    assert body.not_flagged == day["not_flagged"]


def test_a_quiet_day_has_tills_but_no_events(client: TestClient, whole: dict) -> None:
    quiet = next(d for d in whole["days"] if not d["till_flags"] and not d["clusters"])
    body = client.get(f"/v1/admin/cashout/day/{quiet['date']}").json()
    assert body["available"] is True and len(body["tills"]) == 40
    assert body["events"] == [] and body["till_flags"] == [] and body["clusters"] == []


def test_a_date_with_no_daily_run_is_a_404(client: TestClient) -> None:
    assert client.get("/v1/admin/cashout/day/2030-01-01").status_code == 404


@pytest.mark.parametrize("bad", ["2026-1-1", "yesterday", "2026-02-30", "2026-10-23T00:00:00", "20261023"])
def test_a_malformed_date_is_a_422(client: TestClient, bad: str) -> None:
    assert client.get(f"/v1/admin/cashout/day/{bad}").status_code == 422


def test_served_from_the_fixture_fast(client: TestClient, whole: dict) -> None:
    response = client.get(f"/v1/admin/cashout/day/{_flagged_day(whole)['date']}")
    assert float(response.headers["X-Processing-Time-Ms"]) < 500


def test_a_missing_fixture_is_unavailable_not_an_error(client: TestClient, fixture_at: Path) -> None:
    for path in ("/v1/admin/cashout", "/v1/admin/cashout/day/2026-10-23"):
        response = client.get(path)
        assert response.status_code == 200, path
        assert response.json()["available"] is False, path
        assert "build_cashout" in response.json()["reason"]


@pytest.mark.parametrize("payload", [b"{not json", b"\xff\xfe\x00not utf-8", b"[]"])
def test_malformed_fixture_is_unavailable(client: TestClient, fixture_at: Path, payload: bytes) -> None:
    fixture_at.write_bytes(payload)
    for path in ("/v1/admin/cashout", "/v1/admin/cashout/day/2026-10-23"):
        response = client.get(path)
        assert response.status_code == 200, path
        assert response.json()["available"] is False, path


def test_a_fixture_missing_a_section_is_unavailable(client: TestClient, fixture_at: Path) -> None:
    on_disk = json.loads(cashout.DEFAULT_FIXTURE.read_text(encoding="utf-8"))
    fixture_at.write_text(json.dumps({k: v for k, v in on_disk.items() if k != "tills"}))
    for path in ("/v1/admin/cashout", "/v1/admin/cashout/day/2026-10-23"):
        response = client.get(path)
        assert response.status_code == 200, path
        assert response.json()["available"] is False, path


def test_a_rebuilt_fixture_is_read_again(client: TestClient, fixture_at: Path) -> None:
    on_disk = json.loads(cashout.DEFAULT_FIXTURE.read_text(encoding="utf-8"))
    fixture_at.write_text(json.dumps(on_disk))
    assert len(client.get("/v1/admin/cashout").json()["days"]) == len(on_disk["days"])
    fixture_at.write_text(json.dumps({**on_disk, "days": on_disk["days"][:2], "events": {}}))
    assert len(client.get("/v1/admin/cashout").json()["days"]) == 2
