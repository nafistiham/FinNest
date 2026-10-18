"""The detector's card prefix as explicit cached content (P0 items 3-4): every read pays the cached price, not only the lucky ones.

Implicit caching hit on sequential reads but hardly at all under parallel load on the global endpoint ($0.003 a read instead
of about $0.0007). Explicit context caching hit on every read, the first included. Every client here is a fake.
"""

from types import SimpleNamespace

import pytest

from app import genai_client
from app.settings import Settings

PREFIX = "RULES " * 2000  # 12,000 characters: a card prefix
USAGE = SimpleNamespace(prompt_token_count=8600, candidates_token_count=80, thoughts_token_count=0, cached_content_token_count=8000)


class FakeModels:
    def __init__(self, fail=None):
        self.configs, self.fail = [], list(fail or [])

    def generate_content(self, model, contents, config):
        self.configs.append(config)
        if self.fail:
            raise self.fail.pop(0)
        return SimpleNamespace(text='{"ok": true}', parsed=None, usage_metadata=USAGE, candidates=[])


class FakeCaches:
    def __init__(self, fail=None):
        self.created, self.fail = [], fail

    def create(self, model, config):
        if self.fail:
            raise self.fail
        self.created.append((model, config))
        return SimpleNamespace(name=f"projects/p/locations/global/cachedContents/{len(self.created)}",
                               usage_metadata=SimpleNamespace(total_token_count=8000))


@pytest.fixture
def gemini(monkeypatch):
    def install(settings=None, *, create_fails=None, read_fails=None):
        client = SimpleNamespace(models=FakeModels(read_fails), caches=FakeCaches(create_fails))
        monkeypatch.setattr(genai_client, "_client", lambda location=None: client)
        monkeypatch.setattr(genai_client, "select_backend", lambda s: "vertex")
        monkeypatch.setattr(genai_client, "get_settings", lambda: settings or Settings(genai_enabled=True, project_id="p"))
        genai_client.forget_prefix_caches()
        return client
    yield install
    genai_client.forget_prefix_caches()


def test_a_long_system_prefix_is_cached_once_and_every_read_names_the_cache(gemini):
    client = gemini()
    first = genai_client.call("scam_turn", "volume", "turns 1", system=PREFIX)
    second = genai_client.call("scam_turn", "volume", "turns 2", system=PREFIX)
    (model, created), = client.caches.created
    assert model == genai_client.roles()["volume"].id and created.system_instruction == PREFIX and created.ttl == "3600s"
    assert [c.cached_content for c in client.models.configs] == ["projects/p/locations/global/cachedContents/1"] * 2
    assert all(c.system_instruction is None for c in client.models.configs)  # the prefix travels in the cache, not again
    assert first.cost_usd > second.cost_usd > 0  # the read that created the cache carries its storage for the TTL


def test_the_storage_charge_is_the_cached_tokens_for_the_ttl_at_the_storage_price(gemini):
    gemini()
    role = genai_client.roles()["volume"]
    first = genai_client.call("scam_turn", "volume", "turns", system=PREFIX)
    read = genai_client.cost_usd(role, 8600, 80, 8000)
    assert first.cost_usd == pytest.approx(read + 8000 * 1.0 * role.cache_storage_usd_per_m_hour / 1_000_000, abs=1e-6)


def test_a_short_system_prompt_and_the_setting_off_stay_inline(gemini):
    client = gemini()
    genai_client.call("apa", "volume", "x", system="short rules")
    assert client.caches.created == [] and client.models.configs[0].system_instruction == "short rules"
    client = gemini(Settings(genai_enabled=True, project_id="p", genai_prefix_cache=False))
    genai_client.call("scam_turn", "volume", "x", system=PREFIX)
    assert client.caches.created == [] and client.models.configs[0].system_instruction == PREFIX


def test_a_cache_near_its_end_is_made_again(gemini, monkeypatch):
    client = gemini()
    now = [1000.0]
    monkeypatch.setattr(genai_client.time, "time", lambda: now[0])
    genai_client.call("scam_turn", "volume", "x", system=PREFIX)
    now[0] += 3600 - genai_client.PREFIX_CACHE_RENEW_S + 1
    genai_client.call("scam_turn", "volume", "x", system=PREFIX)
    assert len(client.caches.created) == 2 and client.models.configs[-1].cached_content.endswith("/2")


def test_a_failed_create_reads_inline_and_waits_before_trying_again(gemini):
    client = gemini(create_fails=RuntimeError("caching not supported for this model"))
    out = genai_client.call("scam_turn", "volume", "x", system=PREFIX)
    genai_client.call("scam_turn", "volume", "y", system=PREFIX)
    assert out.text == '{"ok": true}' and [c.system_instruction for c in client.models.configs] == [PREFIX, PREFIX]
    assert all(c.cached_content is None for c in client.models.configs)


def test_a_cache_that_is_gone_is_forgotten_and_the_read_goes_inline(gemini):
    from google.genai import errors

    gone = errors.ClientError(404, {"error": {"code": 404, "message": "CachedContent not found", "status": "NOT_FOUND"}})
    client = gemini(read_fails=[gone])
    out = genai_client.call("scam_turn", "volume", "x", system=PREFIX)
    assert out.text == '{"ok": true}' and client.models.configs[-1].system_instruction == PREFIX
    genai_client.call("scam_turn", "volume", "y", system=PREFIX)
    assert len(client.caches.created) == 2  # made again on the next read


def test_v4s_second_read_uses_its_own_models_cache(gemini, monkeypatch):
    from app import scam_variants

    client = gemini()
    monkeypatch.setattr(scam_variants, "get_settings", genai_client.get_settings)
    genai_client.call("scam_turn", "volume", "x", system=PREFIX)
    scam_variants.call_with_thoughts("scam_escalation", "workhorse", "x", system=PREFIX, thinking_level="low")
    assert [m for m, _ in client.caches.created] == [genai_client.roles()["volume"].id, genai_client.roles()["workhorse"].id]
    assert client.models.configs[-1].cached_content.endswith("/2") and client.models.configs[-1].system_instruction is None


def test_start_up_makes_the_detectors_card_cache_so_the_first_turn_reads_it(gemini):
    """The create took the first live scam turn on a fresh instance to 4.3 s against the 4 s budget (e2e, 2026-10-17)."""
    from app import scam

    settings = Settings(genai_enabled=True, project_id="p")
    client = gemini(settings)
    before = genai_client.LEDGER.spent()
    assert scam.warm_prefix(settings) is True
    (model, created), = client.caches.created
    assert model == genai_client.roles()["volume"].id and created.system_instruction == scam._cards(settings).prefix()
    assert genai_client.LEDGER.spent() > before  # its storage is charged at start-up, as the first read would have
    first = genai_client.call("scam_turn", "volume", "turn 1", system=created.system_instruction)
    assert len(client.caches.created) == 1 and client.models.configs[0].cached_content.endswith("/1")
    assert first.cost_usd == pytest.approx(genai_client.cost_usd(genai_client.roles()["volume"], 8600, 80, 8000), abs=1e-6)


def test_start_up_makes_no_card_cache_when_gemini_is_off():
    from app import scam

    assert scam.warm_prefix(Settings(genai_enabled=False)) is False


def test_the_service_starts_the_card_cache_in_the_background(monkeypatch):
    """Start-up does not wait on Gemini: the cache is made off the lifespan, in a thread of its own."""
    import threading

    from fastapi.testclient import TestClient

    from app import scam
    from main import app

    made = threading.Event()
    monkeypatch.setattr(scam, "warm_prefix", lambda settings=None: made.set() or True)
    with TestClient(app):
        assert made.wait(timeout=5)
