"""Backend selection: API key first (the $50 Gemini prepay), Vertex AI as fallback ($300 credit)."""

from pathlib import Path

import pytest

from app import genai_client
from app.settings import Settings


def _settings(**overrides) -> Settings:
    base = {"demo_mode": True, "genai_enabled": True, "gemini_api_key": "", "project_id": "", "genai_backend": "auto"}
    return Settings(**{**base, **overrides})


def test_auto_prefers_api_key_when_present():
    assert genai_client.select_backend(_settings(gemini_api_key="k", project_id="p")) == "api_key"


def test_auto_falls_back_to_vertex_when_only_project():
    assert genai_client.select_backend(_settings(project_id="p")) == "vertex"


def test_auto_with_nothing_configured_is_disabled():
    with pytest.raises(genai_client.GenAIDisabled):
        genai_client.select_backend(_settings())


def test_explicit_vertex_without_project_is_disabled():
    with pytest.raises(genai_client.GenAIDisabled):
        genai_client.select_backend(_settings(genai_backend="vertex", gemini_api_key="k"))


def test_explicit_api_key_without_key_is_disabled():
    with pytest.raises(genai_client.GenAIDisabled):
        genai_client.select_backend(_settings(genai_backend="api_key", project_id="p"))


def test_disabled_flag_wins():
    with pytest.raises(genai_client.GenAIDisabled):
        genai_client.select_backend(_settings(genai_enabled=False, gemini_api_key="k"))


def test_roles_load_from_yaml():
    roles = genai_client.load_roles(Path(__file__).resolve().parent.parent / "config" / "models.yaml")
    assert {"workhorse", "volume", "live", "reasoning", "judge"} <= set(roles)
    assert roles["volume"].input_usd_per_m > 0


def test_cost_is_per_million_tokens():
    role = genai_client.ModelRole(name="x", id="m", input_usd_per_m=1.0, output_usd_per_m=10.0)
    assert genai_client.cost_usd(role, tokens_in=1_000_000, tokens_out=100_000) == pytest.approx(2.0)


class _Resp:
    text = "{}"
    parsed = None
    usage_metadata = None


def _scripted_client(monkeypatch, outcomes):
    from types import SimpleNamespace

    calls = []

    def generate_content(model, contents, config):
        calls.append(model)
        item = outcomes.pop(0)
        if isinstance(item, Exception):
            raise item
        return item
    monkeypatch.setattr(genai_client, "_client", lambda: SimpleNamespace(models=SimpleNamespace(generate_content=generate_content)))
    monkeypatch.setattr(genai_client, "select_backend", lambda settings: "vertex")
    monkeypatch.setattr(genai_client.time, "sleep", lambda s: None)
    return calls


def _err(code):
    from google.genai import errors
    return errors.APIError(code, {"error": {"message": str(code)}})


def test_a_503_or_429_is_retried_once_within_the_timeout(monkeypatch):
    calls = _scripted_client(monkeypatch, [_err(503), _Resp()])
    assert genai_client.call("t", "volume", "x", timeout_s=4.0).text == "{}" and len(calls) == 2
    calls = _scripted_client(monkeypatch, [_err(429), _err(429), _err(429)])
    with pytest.raises(Exception):
        genai_client.call("t", "volume", "x", timeout_s=4.0)
    assert len(calls) == 3


def test_other_errors_and_tight_timeouts_are_not_retried(monkeypatch):
    calls = _scripted_client(monkeypatch, [_err(400), _Resp()])
    with pytest.raises(Exception):
        genai_client.call("t", "volume", "x", timeout_s=4.0)
    assert len(calls) == 1
    calls = _scripted_client(monkeypatch, [_err(503), _Resp()])
    with pytest.raises(Exception):
        genai_client.call("t", "volume", "x", timeout_s=0.3)  # no time left for a retry
    assert len(calls) == 1


def test_a_500_is_retried_once_like_a_503(monkeypatch):
    """Gemini answered about one audio transcription in ten with a 500 during the speech smoke runs; one short retry recovers it."""
    calls = _scripted_client(monkeypatch, [_err(500), _Resp()])
    assert genai_client.call("t", "volume", "x", timeout_s=4.0).text == "{}" and len(calls) == 2


class _Clock:
    """genai_client's clock: sleeps and model calls move it forward, nothing really waits."""

    def __init__(self) -> None:
        self.now = 0.0

    def monotonic(self) -> float:
        return self.now

    perf_counter = monotonic

    def sleep(self, seconds: float) -> None:
        self.now += seconds


def _timed_client(monkeypatch, outcomes):
    """Each outcome is (seconds it takes, response or error). An attempt that would outlast its HTTP timeout ends at
    that timeout with a TimeoutError, as the HTTP client does. Returns the clock and each attempt's (start, timeout_ms)."""
    from types import SimpleNamespace

    clock, attempts = _Clock(), []

    def generate_content(model, contents, config):
        took, item = outcomes.pop(0)
        limit_s = config.http_options.timeout / 1000
        attempts.append((round(clock.now, 3), config.http_options.timeout))
        assert config.http_options.headers["X-Server-Timeout"] == str(genai_client.SERVER_TIMEOUT_S)
        clock.now += min(took, limit_s)
        if took > limit_s:
            raise TimeoutError("read timed out")
        if isinstance(item, Exception):
            raise item
        return item
    monkeypatch.setattr(genai_client, "_client", lambda: SimpleNamespace(models=SimpleNamespace(generate_content=generate_content)))
    monkeypatch.setattr(genai_client, "select_backend", lambda settings: "vertex")
    monkeypatch.setattr(genai_client, "time", clock)
    return clock, attempts


def test_a_retry_gets_only_the_time_left_so_the_call_ends_by_its_timeout(monkeypatch):
    """A 503 at 2.5 s, a 0.4 s wait, then a retry with a fresh 4 s HTTP timeout: the 4 s call took 6.9 s."""
    clock, attempts = _timed_client(monkeypatch, [(2.5, _err(503)), (3.9, _Resp())])
    with pytest.raises(TimeoutError):
        genai_client.call("t", "volume", "x", timeout_s=4.0)
    assert attempts == [(0.0, 4000), (2.9, 1100)] and clock.now == pytest.approx(4.0)

    clock, attempts = _timed_client(monkeypatch, [(0.2, _err(429)), (3.0, _Resp())])  # a quick 429 leaves room for a slow answer
    assert genai_client.call("t", "volume", "x", timeout_s=4.0).text == "{}"
    assert attempts == [(0.0, 4000), (0.6, 3400)] and clock.now == pytest.approx(3.6)


def test_no_retry_when_its_wait_and_one_more_second_do_not_fit(monkeypatch):
    clock, attempts = _timed_client(monkeypatch, [(3.2, _err(503)), (0.1, _Resp())])
    with pytest.raises(Exception) as raised:
        genai_client.call("t", "volume", "x", timeout_s=4.0)
    assert getattr(raised.value, "code", None) == 503 and len(attempts) == 1 and clock.now == pytest.approx(3.2)


@pytest.mark.parametrize("codes,timeout_s", [((503, 503, 503), 10.0), ((429, 429, 429), 4.0), ((503, 500, 400), 10.0)])
def test_the_last_error_is_raised_as_itself_never_an_index_error(monkeypatch, codes, timeout_s):
    """The third retryable error raised IndexError (code None), so the speech smoke could not tell a Gemini 5xx from a mishearing."""
    from google.genai import errors

    clock, attempts = _timed_client(monkeypatch, [(0.1, _err(code)) for code in codes])
    with pytest.raises(errors.APIError) as raised:
        genai_client.call("t", "volume", "x", timeout_s=timeout_s)
    assert raised.value.code == codes[-1] and len(attempts) == 3 and clock.now <= timeout_s


def test_vertex_gets_a_generous_server_deadline_while_the_client_still_stops_at_its_timeout():
    """A tight X-Server-Timeout made Vertex answer 504 DEADLINE_EXCEEDED after about 2.3 s on calls that finish in 2-3 s
    without it (14 of 20 Apa explanations in the judge run). The client's own timeout still bounds the wait."""
    options = genai_client.http_options(4.0)
    assert options.timeout == 4000 and int(options.headers["X-Server-Timeout"]) == genai_client.SERVER_TIMEOUT_S >= 30


def test_every_structured_call_sends_the_generous_server_deadline(monkeypatch):
    from types import SimpleNamespace

    seen = []

    def generate_content(model, contents, config):
        seen.append(config.http_options)
        return _Resp()
    monkeypatch.setattr(genai_client, "_client", lambda: SimpleNamespace(models=SimpleNamespace(generate_content=generate_content)))
    monkeypatch.setattr(genai_client, "select_backend", lambda settings: "vertex")
    genai_client.call("t", "volume", "x", timeout_s=4.0)
    assert seen[0].timeout == 4000 and seen[0].headers["X-Server-Timeout"] == str(genai_client.SERVER_TIMEOUT_S)


@pytest.fixture
def fake_genai(monkeypatch):
    """google.genai.Client and the ADC credentials replaced by counting fakes; the client cache starts empty."""
    from types import SimpleNamespace

    import google.genai

    built, refreshed = [], []

    class FakeClient:
        def __init__(self, **kwargs):
            built.append(kwargs)
            self.models = SimpleNamespace(generate_content=self.no_model_call)

        @staticmethod
        def no_model_call(**kwargs):
            raise AssertionError("warm-up must not call a model")

    creds = SimpleNamespace(refresh=lambda request: refreshed.append(request))
    monkeypatch.setattr(google.genai, "Client", FakeClient)
    monkeypatch.setattr(genai_client, "_credentials", lambda: creds)
    monkeypatch.setattr(genai_client, "select_backend", lambda settings: "vertex")
    genai_client._cached_client.cache_clear()
    yield SimpleNamespace(built=built, refreshed=refreshed, creds=creds)
    genai_client._cached_client.cache_clear()


def test_the_client_is_built_once_per_location_and_reused(fake_genai):
    """It was built on every call, so each call loaded credentials and fetched a token outside its timeout (first call 5.9 s)."""
    first = genai_client._client()
    assert genai_client._client() is first and len(fake_genai.built) == 1
    assert fake_genai.built[0]["location"] == "global" and fake_genai.built[0]["credentials"] is fake_genai.creds
    regional = genai_client._client("us-central1")
    assert regional is not first and fake_genai.built[1]["location"] == "us-central1" and genai_client._client("us-central1") is regional


def test_warm_up_builds_the_client_and_fetches_a_token_without_a_model_call(fake_genai):
    assert genai_client.warm_up() is True
    assert len(fake_genai.built) == 1 and len(fake_genai.refreshed) == 1


def test_warm_up_is_skipped_when_gemini_is_off_and_never_stops_start_up(fake_genai, monkeypatch):
    def off(settings):
        raise genai_client.GenAIDisabled("off")
    monkeypatch.setattr(genai_client, "select_backend", off)
    assert genai_client.warm_up() is False and fake_genai.built == []
    monkeypatch.setattr(genai_client, "select_backend", lambda settings: "vertex")

    def broken(request):
        raise RuntimeError("no network")
    monkeypatch.setattr(fake_genai.creds, "refresh", broken)
    assert genai_client.warm_up() is False  # logged, not raised


def test_start_up_warms_the_gemini_client(monkeypatch):
    from fastapi.testclient import TestClient

    from main import app

    calls = []
    monkeypatch.setattr(genai_client, "warm_up", lambda: calls.append(1) or False)
    with TestClient(app):
        pass
    assert calls == [1]
