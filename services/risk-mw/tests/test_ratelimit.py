"""Per-caller limits and the Gemini spend cap: a public URL must not be able to burn the budget."""

from __future__ import annotations

import logging

import pytest
from fastapi.testclient import TestClient

from app import genai_client
from app.ratelimit import SlidingWindowLimiter, client_ip


class FakeClock:
    def __init__(self) -> None:
        self.now = 1000.0

    def __call__(self) -> float:
        return self.now


def test_limiter_admits_up_to_the_limit_then_reports_the_wait():
    clock = FakeClock()
    limiter = SlidingWindowLimiter(limit=3, window_s=60, clock=clock)
    assert [limiter.check("a") for _ in range(3)] == [0.0, 0.0, 0.0]
    wait = limiter.check("a")
    assert 0 < wait <= 60


def test_limiter_frees_a_slot_when_the_oldest_call_leaves_the_window():
    clock = FakeClock()
    limiter = SlidingWindowLimiter(limit=2, window_s=60, clock=clock)
    limiter.check("a")
    clock.now += 30
    limiter.check("a")
    assert limiter.check("a") > 0
    clock.now += 31  # the first call is now 61 s old
    assert limiter.check("a") == 0.0


def test_limiter_keeps_callers_apart():
    limiter = SlidingWindowLimiter(limit=1, window_s=60, clock=FakeClock())
    assert limiter.check("a") == 0.0
    assert limiter.check("b") == 0.0
    assert limiter.check("a") > 0


def test_a_rejected_call_does_not_extend_the_wait():
    clock = FakeClock()
    limiter = SlidingWindowLimiter(limit=1, window_s=60, clock=clock)
    limiter.check("a")
    for _ in range(50):
        limiter.check("a")
    clock.now += 61
    assert limiter.check("a") == 0.0


def test_limiter_memory_is_bounded():
    limiter = SlidingWindowLimiter(limit=1, window_s=60, clock=FakeClock(), max_keys=100)
    for i in range(1000):
        limiter.check(f"ip{i}")
    assert limiter.tracked_keys() <= 100


def test_would_admit_reports_the_wait_without_counting_and_record_counts():
    clock = FakeClock()
    limiter = SlidingWindowLimiter(limit=1, window_s=60, clock=clock)
    assert [limiter.would_admit("a") for _ in range(3)] == [0.0, 0.0, 0.0]
    assert limiter.tracked_keys() == 0
    limiter.record("a")
    assert 0 < limiter.would_admit("a") <= 60
    assert limiter.check("a") > 0
    clock.now += 61
    assert limiter.would_admit("a") == 0.0


def test_a_rejection_is_logged_once_per_key_per_window():
    clock = FakeClock()
    limiter = SlidingWindowLimiter(limit=1, window_s=60, clock=clock)
    assert [limiter.rejection_log_due("a") for _ in range(3)] == [True, False, False]
    assert limiter.rejection_log_due("b") is True
    clock.now += 60
    assert limiter.rejection_log_due("a") is True


def test_the_rejection_log_memory_is_bounded():
    limiter = SlidingWindowLimiter(limit=1, window_s=60, clock=FakeClock(), max_keys=100)
    assert all(limiter.rejection_log_due(f"ip{i}") for i in range(1000))
    assert limiter.logged_keys() <= 100


def test_client_ip_trusts_the_last_forwarded_hop_not_the_first():
    # Cloud Run appends the real client after whatever the caller sent, so the first hop can be forged.
    assert client_ip({"x-forwarded-for": "6.6.6.6, 203.0.113.9"}, "10.0.0.1") == "203.0.113.9"
    assert client_ip({}, "10.0.0.1") == "10.0.0.1"


@pytest.fixture
def limited_client(monkeypatch):
    monkeypatch.setenv("RISK_MW_RATE_LIMIT_ENABLED", "true")
    monkeypatch.setenv("RISK_MW_RATE_LIMIT_GENAI_PER_MIN", "2")
    monkeypatch.setenv("RISK_MW_RATE_LIMIT_GENAI_ALL_PER_MIN", "4")
    monkeypatch.setenv("RISK_MW_RATE_LIMIT_DEFAULT_PER_MIN", "5")
    from app.settings import get_settings

    get_settings.cache_clear()
    import main

    with TestClient(main.create_app()) as test_client:
        yield test_client
    monkeypatch.undo()
    get_settings.cache_clear()


SCAM = {"session_id": "s", "turns": [{"speaker": "caller", "text": "code bolun", "ts": 1}]}


def test_gemini_routes_get_the_tight_limit_and_a_retry_hint(limited_client):
    codes = [limited_client.post("/v1/scam/turn", json=SCAM).status_code for _ in range(3)]
    assert codes == [200, 200, 429]
    blocked = limited_client.post("/v1/scam/turn", json=SCAM)
    assert int(blocked.headers["retry-after"]) >= 1


def test_every_v1_route_shares_the_default_limit_but_health_is_exempt(limited_client):
    codes = [limited_client.post("/v1/apa/turn", json={"user_id": "r", "text_bn": "x"}).status_code for _ in range(7)]
    assert codes[:5] == [200] * 5 and set(codes[5:]) == {429}
    assert all(limited_client.get("/health").status_code == 200 for _ in range(10))


def test_a_forged_first_hop_does_not_buy_a_fresh_quota(limited_client):
    first = {"X-Forwarded-For": "1.1.1.1, 203.0.113.9"}
    forged = {"X-Forwarded-For": "2.2.2.2, 203.0.113.9"}
    assert limited_client.post("/v1/scam/turn", json=SCAM, headers=first).status_code == 200
    assert limited_client.post("/v1/scam/turn", json=SCAM, headers=first).status_code == 200
    assert limited_client.post("/v1/scam/turn", json=SCAM, headers=forged).status_code == 429


def test_the_shared_gemini_bucket_holds_even_when_every_call_looks_like_a_new_caller(limited_client):
    """On Cloud Run the address a caller presents can vary by connection, so per-caller limits alone can
    be walked around with parallel connections. The shared bucket does not depend on telling callers apart."""
    codes = [limited_client.post("/v1/scam/turn", json=SCAM, headers={"X-Forwarded-For": f"203.0.113.{i}"}).status_code for i in range(6)]
    assert codes == [200, 200, 200, 200, 429, 429]


def test_the_shared_bucket_does_not_touch_other_routes(limited_client):
    assert all(limited_client.post("/v1/apa/turn", json={"user_id": "r", "text_bn": "x"}, headers={"X-Forwarded-For": f"203.0.113.{i}"}).status_code == 200 for i in range(5))


GENAI_ROUTES = [("/v1/scam/turn", SCAM), ("/v1/investigate", {"acct_id": "acct_01070"})]


@pytest.mark.parametrize(("route", "body"), GENAI_ROUTES)
def test_a_call_the_shared_bucket_rejects_does_not_spend_the_callers_own_quota(limited_client, route, body):
    """Both Gemini buckets are checked before either counts, so a call the shared bucket turns away
    leaves the caller's own quota as it was."""
    clock = FakeClock()
    limited_client.app.state.limiters = {
        "genai": SlidingWindowLimiter(limit=2, window_s=600, clock=clock),
        "genai_all": SlidingWindowLimiter(limit=2, window_s=60, clock=clock),
    }

    def post(ip: str) -> int:
        return limited_client.post(route, json=body, headers={"X-Forwarded-For": ip}).status_code

    assert [post("198.51.100.1"), post("198.51.100.2")] == [200, 200]  # the shared bucket is now full
    assert [post("203.0.113.9") for _ in range(3)] == [429, 429, 429]
    clock.now += 61  # the shared window has cleared; the caller's own ten-minute window has not
    assert [post("203.0.113.9") for _ in range(3)] == [200, 200, 429]


def _rate_limit_logs(caplog) -> list[logging.LogRecord]:
    return [r for r in caplog.records if r.name == "app.ratelimit" and "rate limited" in r.getMessage()]


@pytest.mark.parametrize(("route", "body", "bucket"), [("/v1/scam/turn", SCAM, "genai"), ("/v1/apa/turn", {"user_id": "r", "text_bn": "x"}, "default")])
def test_a_flood_of_rejections_logs_once_per_caller_per_window(limited_client, caplog, route, body, bucket):
    clock = FakeClock()
    limited_client.app.state.limiters = {bucket: SlidingWindowLimiter(limit=1, window_s=60, clock=clock)}
    caplog.set_level(logging.INFO, logger="app.ratelimit")

    def post() -> int:
        return limited_client.post(route, json=body, headers={"X-Forwarded-For": "x" * 5000 + ", 203.0.113.9"}).status_code

    assert [post(), post(), post()] == [200, 429, 429]
    clock.now += 30
    assert post() == 429
    assert len(_rate_limit_logs(caplog)) == 1
    clock.now += 31  # a minute after the logged rejection; the caller's own window has cleared as well
    assert [post(), post()] == [200, 429]
    logs = _rate_limit_logs(caplog)
    assert len(logs) == 2
    assert all(len(r.getMessage()) < 1000 for r in logs)  # the header is the caller's text; it is cut short


# --- spend cap -------------------------------------------------------------------------------


def test_ledger_accumulates_and_resets():
    ledger = genai_client.SpendLedger()
    ledger.add(0.25)
    ledger.add(0.5)
    assert ledger.spent() == pytest.approx(0.75)
    ledger.reset()
    assert ledger.spent() == 0.0


def test_calls_stop_once_the_spend_cap_is_reached(monkeypatch):
    monkeypatch.setenv("RISK_MW_GENAI_ENABLED", "true")
    monkeypatch.setenv("RISK_MW_PROJECT_ID", "p")
    monkeypatch.setenv("RISK_MW_GENAI_BUDGET_USD", "1.0")
    from app.settings import get_settings

    get_settings.cache_clear()
    try:
        genai_client.LEDGER.reset()
        genai_client.LEDGER.add(1.0)
        with pytest.raises(genai_client.GenAIDisabled, match="spend cap"):
            genai_client.call("t", "volume", "hello")
    finally:
        genai_client.LEDGER.reset()
        get_settings.cache_clear()


def test_scam_turn_degrades_to_the_stub_when_the_cap_is_reached(monkeypatch, client):
    def capped(*args, **kwargs):
        raise genai_client.GenAIDisabled("spend cap reached")

    monkeypatch.setattr(genai_client, "call", capped)
    response = client.post("/v1/scam/turn", json=SCAM)
    assert response.status_code == 200
