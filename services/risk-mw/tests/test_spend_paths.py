"""Every Gemini spend goes through the reservation, not only genai_client.call.

spends in more places than call(): the detector's prefix cache (storage for its TTL), v4's second read, Apa's
warning stream, speech-to-text, Gemini Live and the start-up card cache. Each one reserves its worst case before the
request leaves and settles at its billed cost, so none of them can take the instance past the cap.
"""

from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager
from types import SimpleNamespace

import pytest

from app import genai_client, scam, scam_variants, speech
from app.genai_client import GenAIDisabled, ModelRole, SpendLedger
from app.settings import Settings
from app.warnings import composer

ROLE = ModelRole("volume", "offline-fake", input_usd_per_m=0.0, output_usd_per_m=1.0)  # $0.000001 per output token
CAP = 0.0015


def _usage(tokens_out: int) -> SimpleNamespace:
    return SimpleNamespace(prompt_token_count=0, candidates_token_count=tokens_out, thoughts_token_count=0, cached_content_token_count=0,
                           response_token_count=tokens_out, total_token_count=3000)


@pytest.fixture
def fake(monkeypatch):
    """A fake Gemini behind the real ledger and settings: generate, stream, cache create and Live are all recorded."""
    state = SimpleNamespace(ledger=SpendLedger(), sent=[], caches=[], stream_fails=False)
    settings = Settings(genai_enabled=True, genai_backend="vertex", project_id="offline-only", genai_budget_usd=CAP,
                        genai_max_output_tokens=700, warning_max_output_tokens=500)

    def generate_content(**kwargs):
        state.sent.append(("generate", kwargs))
        return SimpleNamespace(text="{}", parsed={}, usage_metadata=_usage(100), candidates=[])

    def generate_content_stream(**kwargs):
        state.sent.append(("stream", kwargs))
        if state.stream_fails:
            raise ConnectionError("dropped after the request left")
        yield SimpleNamespace(candidates=[], usage_metadata=_usage(100))

    def create(**kwargs):
        state.caches.append(kwargs)
        return SimpleNamespace(name="cachedContents/1", usage_metadata=SimpleNamespace(total_token_count=3000))

    @asynccontextmanager
    async def connect(model, config):
        state.sent.append(("live", model))
        yield SimpleNamespace()

    client = SimpleNamespace(models=SimpleNamespace(generate_content=generate_content, generate_content_stream=generate_content_stream),
                             caches=SimpleNamespace(create=create), aio=SimpleNamespace(live=SimpleNamespace(connect=connect)))
    monkeypatch.setattr(genai_client, "get_settings", lambda: settings)
    monkeypatch.setattr(genai_client, "roles", lambda: {"volume": ROLE, "escalation": ROLE, "transcribe": ROLE, "live": ROLE,
                                                        speech.ROLE: ROLE, speech.LIVE_ROLE: ROLE})
    monkeypatch.setattr(genai_client, "_client", lambda location=None: client)
    monkeypatch.setattr(genai_client, "LEDGER", state.ledger)
    genai_client.forget_prefix_caches()
    state.settings = settings
    yield state
    genai_client.forget_prefix_caches()


def _never_past_the_cap(state) -> None:
    assert state.ledger.spent() <= CAP + 1e-12 and state.ledger.reserved() == 0.0


# --- the prefix cache's storage ------------------------------------------------------------------------------------------


def test_a_read_that_would_make_the_prefix_cache_reserves_its_storage(fake):
    """9,000 prefix bytes for an hour at $1 per million an hour is up to $0.009: past a $0.0015 cap, so nothing is made."""
    with pytest.raises(GenAIDisabled, match="spend cap"):
        genai_client.call("scam_turn", "volume", "turn", system="x" * 9000, max_output_tokens=100)
    assert fake.caches == [] and fake.sent == []
    _never_past_the_cap(fake)


def test_a_read_of_a_cache_already_made_reserves_no_storage(fake):
    fake.settings.genai_budget_usd = 1.0
    genai_client.call("scam_turn", "volume", "turn", system="x" * 9000, max_output_tokens=100)  # makes the cache
    fake.settings.genai_budget_usd = fake.ledger.spent() + 0.0002
    genai_client.call("scam_turn", "volume", "turn", system="x" * 9000, max_output_tokens=100)  # reads it: $0.0001 fits
    assert len(fake.caches) == 1 and fake.ledger.reserved() == 0.0


def test_the_start_up_card_cache_goes_through_the_reservation(fake, monkeypatch):
    monkeypatch.setattr(scam, "_cards", lambda settings: SimpleNamespace(prefix=lambda: "x" * 9000))
    assert scam.warm_prefix(fake.settings) is False
    assert fake.caches == []
    _never_past_the_cap(fake)


# --- v4's second read ----------------------------------------------------------------------------------------------------


def test_the_second_read_is_refused_before_it_is_sent_when_it_cannot_fit(fake):
    fake.ledger.add(0.001)
    with pytest.raises(GenAIDisabled, match="spend cap"):
        scam_variants.call_with_thoughts("scam_turn_escalation", "escalation", "turn", max_output_tokens=600)
    assert fake.sent == []
    _never_past_the_cap(fake)


def test_the_second_read_settles_at_its_cost(fake):
    out = scam_variants.call_with_thoughts("scam_turn_escalation", "escalation", "turn", max_output_tokens=500)
    assert out.cost_usd == pytest.approx(0.0001) and fake.ledger.spent() == pytest.approx(0.0001) and fake.ledger.reserved() == 0.0


# --- Apa's warning stream ------------------------------------------------------------------------------------------------


def test_the_warning_stream_is_refused_at_once_when_it_cannot_fit(fake):
    fake.ledger.add(0.0011)  # 500 output tokens is $0.0005: does not fit
    with pytest.raises(GenAIDisabled, match="spend cap"):
        composer._model_text("contents", fake.settings, None, 2.0)
    assert fake.sent == []


def test_a_warning_stream_that_drops_after_it_was_sent_counts_at_its_worst_case(fake):
    fake.stream_fails = True
    with pytest.raises(ConnectionError):
        list(composer._model_text("contents", fake.settings, None, 2.0))
    worst = genai_client.worst_case_usd(ROLE, "contents", composer.system_prompt(fake.settings), None, 500)
    assert fake.ledger.spent() == pytest.approx(worst) and fake.ledger.reserved() == 0.0


def test_a_warning_stream_nobody_reads_holds_no_reservation(fake):
    composer._model_text("contents", fake.settings, None, 2.0)
    assert fake.ledger.reserved() == 0.0 and fake.sent == []


# --- speech --------------------------------------------------------------------------------------------------------------


def test_a_transcription_is_counted_against_the_cap(fake):
    speech.transcribe_call(b"OggS" + b"\x00" * 64, "audio/ogg", fake.settings)
    assert fake.ledger.spent() == pytest.approx(0.0001) and fake.ledger.reserved() == 0.0


def test_a_transcription_that_cannot_fit_is_refused_before_it_is_sent(fake):
    fake.ledger.add(CAP)
    with pytest.raises(GenAIDisabled, match="spend cap"):
        speech.transcribe_call(b"OggS" + b"\x00" * 64, "audio/ogg", fake.settings)
    assert fake.sent == []


def test_a_live_session_that_cannot_fit_is_refused_before_it_connects(fake):
    fake.ledger.add(CAP)

    async def open_once():
        async with speech.gemini_live(fake.settings):
            pass

    with pytest.raises(GenAIDisabled, match="spend cap"):
        asyncio.run(open_once())
    assert fake.sent == []


def test_a_live_session_settles_at_what_it_was_billed(fake):
    fake.settings.genai_budget_usd = 1.0

    async def open_once():
        async with speech.gemini_live(fake.settings) as live:
            live.tokens_out = 250

    asyncio.run(open_once())
    assert fake.ledger.spent() == pytest.approx(0.00025) and fake.ledger.reserved() == 0.0
