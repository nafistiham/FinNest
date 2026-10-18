"""The Gemini spend cap is a ceiling under concurrency.

A probe showed the race: with $0.001 spent and a $0.0015 cap, two concurrent
$0.001 calls both passed a check-then-add ledger and it ended at $0.003. Now every call reserves its worst case before
it is sent, and settles at its real cost (or releases the reservation) afterwards.
"""

from __future__ import annotations

import json
import logging
import threading
from concurrent.futures import ThreadPoolExecutor
from types import SimpleNamespace
from unittest.mock import patch

import pytest

from app import genai_client
from app.genai_client import GenAIDisabled, ModelRole, SpendLedger
from app.settings import Settings

OUTPUT_ONLY = ModelRole("volume", "offline-fake", input_usd_per_m=0.0, output_usd_per_m=1.0)  # $0.000001 per output token
WAIT_S = 10


# --- the ledger ---------------------------------------------------------------------------------


def test_a_reservation_is_admitted_only_while_it_fits_under_the_cap():
    ledger = SpendLedger()
    ledger.add(0.001)
    first = ledger.reserve(0.0005, cap_usd=0.0015)
    assert first is not None and ledger.reserved() == pytest.approx(0.0005)
    assert ledger.reserve(0.0005, cap_usd=0.0015) is None
    assert ledger.spent() == pytest.approx(0.001)


def test_settling_below_the_reservation_frees_the_difference():
    ledger = SpendLedger()
    token = ledger.reserve(0.001, cap_usd=0.0015)
    assert ledger.reserve(0.001, cap_usd=0.0015) is None
    assert ledger.settle(token, 0.0002) == pytest.approx(0.0002)
    assert ledger.reserved() == 0.0
    assert ledger.reserve(0.001, cap_usd=0.0015) is not None


def test_releasing_a_reservation_spends_nothing():
    ledger = SpendLedger()
    token = ledger.reserve(0.001, cap_usd=0.001)
    ledger.release(token)
    assert ledger.spent() == 0.0 and ledger.reserved() == 0.0


def test_a_reservation_is_closed_exactly_once():
    ledger = SpendLedger()
    token = ledger.reserve(0.001, cap_usd=1.0)
    ledger.settle(token, 0.001)
    with pytest.raises(KeyError):
        ledger.release(token)


def test_a_negative_reservation_is_refused():
    with pytest.raises(ValueError):
        SpendLedger().reserve(-0.1, cap_usd=1.0)


def test_reset_clears_spend_and_reservations():
    ledger = SpendLedger()
    ledger.add(0.5)
    ledger.reserve(0.25, cap_usd=1.0)
    ledger.reset()
    assert ledger.spent() == 0.0 and ledger.reserved() == 0.0


# --- call() -------------------------------------------------------------------------------------


def _response(tokens_out: int, thinking: int = 0) -> SimpleNamespace:
    usage = SimpleNamespace(prompt_token_count=0, candidates_token_count=tokens_out, thoughts_token_count=thinking)
    return SimpleNamespace(text="offline", parsed=None, usage_metadata=usage, candidates=[])


@pytest.fixture
def offline(monkeypatch):
    """call() against a fake Gemini: the real ledger, settings and cost code; returns a hook to script the model."""
    state = SimpleNamespace(ledger=SpendLedger(), generate=lambda **kwargs: _response(500), configs=[])
    settings = Settings(genai_enabled=True, genai_backend="vertex", project_id="offline-only", genai_budget_usd=0.0015, genai_max_output_tokens=700)

    def generate_content(**kwargs):
        state.configs.append(kwargs["config"])
        return state.generate(**kwargs)

    monkeypatch.setattr(genai_client, "get_settings", lambda: settings)
    monkeypatch.setattr(genai_client, "roles", lambda: {"volume": OUTPUT_ONLY})
    monkeypatch.setattr(genai_client, "_client", lambda: SimpleNamespace(models=SimpleNamespace(generate_content=generate_content)))
    monkeypatch.setattr(genai_client, "LEDGER", state.ledger)
    return state


def test_the_probe_scenario_admits_exactly_one_of_two_concurrent_calls(offline):
    offline.ledger.add(0.001)
    rejected = threading.Event()

    def generate(**kwargs):
        assert rejected.wait(WAIT_S), "both calls were admitted"
        return _response(500)

    def attempt(_: int) -> str:
        try:
            genai_client.call("review", "volume", "offline", max_output_tokens=500)
            return "admitted"
        except GenAIDisabled:
            rejected.set()
            return "refused"

    offline.generate = generate
    with ThreadPoolExecutor(max_workers=2) as pool:
        outcomes = sorted(pool.map(attempt, range(2)))
    assert outcomes == ["admitted", "refused"]
    assert offline.ledger.spent() <= 0.0015 + 1e-12
    assert offline.ledger.reserved() == 0.0


def test_a_call_that_fails_after_it_was_sent_counts_at_its_worst_case(offline):
    """A timeout or a dropped connection may still be billed, so the cap must count it."""

    def timed_out(**kwargs):
        raise TimeoutError("deadline exceeded")

    offline.generate = timed_out
    with pytest.raises(TimeoutError):
        genai_client.call("review", "volume", "offline", max_output_tokens=500)
    assert offline.ledger.reserved() == 0.0 and offline.ledger.spent() == pytest.approx(0.0005)


def test_a_call_that_fails_before_it_is_sent_releases_its_reservation(offline, monkeypatch):
    def no_client():
        raise RuntimeError("credentials unavailable")

    monkeypatch.setattr(genai_client, "_client", no_client)
    with pytest.raises(RuntimeError):
        genai_client.call("review", "volume", "offline", max_output_tokens=500)
    assert offline.ledger.reserved() == 0.0 and offline.ledger.spent() == 0.0
    assert offline.configs == []


def test_a_cheaper_answer_settles_at_its_real_cost(offline):
    offline.generate = lambda **kwargs: _response(100)
    result = genai_client.call("review", "volume", "offline", max_output_tokens=1000)
    assert result.cost_usd == pytest.approx(0.0001)
    assert offline.ledger.spent() == pytest.approx(0.0001) and offline.ledger.reserved() == 0.0


def test_thinking_tokens_are_paid_for(offline):
    offline.generate = lambda **kwargs: _response(100, thinking=300)
    assert genai_client.call("review", "volume", "offline", max_output_tokens=1000).cost_usd == pytest.approx(0.0004)


def test_a_call_that_names_no_output_cap_is_bounded_by_the_setting(offline):
    offline.ledger.add(0.0008)  # 0.0008 + 700 output tokens at $1/M = 0.0015: fits exactly
    genai_client.call("review", "volume", "offline")
    assert offline.configs[-1].max_output_tokens == 700


def test_a_call_whose_worst_case_does_not_fit_is_refused_before_it_is_sent(offline):
    offline.ledger.add(0.001)
    with pytest.raises(GenAIDisabled, match="spend cap"):
        genai_client.call("review", "volume", "offline", max_output_tokens=600)
    assert offline.configs == []


def test_the_cost_log_line_carries_the_reservation(offline, caplog):
    with caplog.at_level(logging.INFO, logger="genai"):
        genai_client.call("review", "volume", "offline", max_output_tokens=500)
    line = json.loads(next(r.getMessage() for r in caplog.records if r.name == "genai" and r.getMessage().startswith("{")))
    assert line["reserved_usd"] == pytest.approx(0.0005) and line["cost_usd"] == pytest.approx(0.0005)


def test_worst_case_counts_every_input_byte_and_the_whole_output_allowance():
    role = ModelRole("x", "m", input_usd_per_m=1.0, output_usd_per_m=10.0)
    assert genai_client.worst_case_usd(role, "abcd", "ef", None, 100) == pytest.approx((6 * 1.0 + 100 * 10.0) / 1_000_000)


def test_bangla_input_is_counted_in_utf8_bytes():
    """A Bangla letter is three UTF-8 bytes; a byte-fallback tokenizer can spend a token on each."""
    role = ModelRole("x", "m", input_usd_per_m=1.0, output_usd_per_m=0.0)
    assert genai_client.worst_case_usd(role, "ওটিপি", None, None, 0) == pytest.approx(len("ওটিপি") * 3 / 1_000_000)


def test_the_probe_ledger_setup_is_still_supported():
    """The probe builds its own ledger and calls add(); both stay."""
    with patch.object(genai_client, "LEDGER", SpendLedger()):
        assert genai_client.LEDGER.add(0.001) == pytest.approx(0.001)


# --- what the callers send: SDK contents and dict schemas -------------------------------------


def test_a_content_of_text_parts_counts_like_its_text():
    """The detector sends the call as a types.Content, one part per turn; every part's bytes count."""
    from google.genai import types

    role = ModelRole("x", "m", input_usd_per_m=1.0, output_usd_per_m=0.0)
    content = types.Content(role="user", parts=[types.Part.from_text(text="ab"), types.Part.from_text(text="ওটিপি")])
    assert genai_client.worst_case_usd(role, content, None, None, 0) == genai_client.worst_case_usd(role, "ab" + "ওটিপি", None, None, 0)


def test_inline_bytes_count_byte_for_byte():
    """Audio and other inline data: one token a byte bounds any tokenizer."""
    from google.genai import types

    role = ModelRole("x", "m", input_usd_per_m=1.0, output_usd_per_m=0.0)
    contents = [types.Part.from_bytes(data=b"\x00" * 100, mime_type="audio/ogg"), "Transcribe this recording."]
    assert genai_client.worst_case_usd(role, contents, None, None, 0) == pytest.approx((100 + len("Transcribe this recording.")) / 1_000_000)


def test_a_dict_schema_counts_by_its_json():
    role = ModelRole("x", "m", input_usd_per_m=1.0, output_usd_per_m=0.0)
    schema = {"type": "OBJECT", "properties": {"verdict": {"type": "STRING"}}}
    assert genai_client.worst_case_usd(role, "", None, schema, 0) == pytest.approx(len(json.dumps(schema).encode()) / 1_000_000)


def test_the_detectors_read_is_admitted_and_settled(offline):
    """Detector: a Content and a Vertex dict schema go through the reservation like a string does."""
    from google.genai import types

    offline.ledger.reset()
    content = types.Content(role="user", parts=[types.Part.from_text(text="caller: কোডটা বলুন")])
    genai_client.call("scam_turn", "volume", content, schema={"type": "OBJECT", "properties": {}}, max_output_tokens=500)
    assert offline.ledger.spent() == pytest.approx(0.0005) and offline.ledger.reserved() == 0.0
