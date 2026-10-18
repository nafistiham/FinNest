"""Two TTS engines, one voice. The primary and the fallback come from config/models.yaml (roles tts and
tts_fallback); a model that is not served moves the call to the other engine for the rest of the process. A 429 moves the
same warning to the other engine (each has its own quota) and rests the one that answered it; every engine is paced under
its quota (tts_requests_per_min), so a request that would be refused is never sent, and RateLimited means both are spent.

Every model call here is a fake (tts._stream and tts._once, or genai_client._client); nothing reaches Gemini.
"""

import dataclasses
import time
from types import SimpleNamespace

import pytest

from app import genai_client, tts
from app.settings import Settings

# The engine pin, in one place: (primary, fallback). Change it here and in config/models.yaml together, once
# scripts/tts_engine_smoke.py and a native ear have chosen. Every other test reads the ids from tts.engines().
PINNED = ("gemini-3.8-flash-lite-tts", "gemini-2.5-flash-tts")

WHY = "কলার আপনার কোড চেয়েছে, তাই থামালাম। কলটা কেটে দিন।"
PCM = (b"\x01\x00" * 2400, b"\x02\x00" * 2400)
USAGE = SimpleNamespace(prompt_token_count=120, candidates_token_count=250, thoughts_token_count=None)
QUOTA = "aiplatform.googleapis.com/generate_content_requests_per_minute_per_project_per_base_model"


def _response(data: bytes | None, usage=None):
    parts = [SimpleNamespace(inline_data=SimpleNamespace(data=data, mime_type="audio/L16;codec=pcm;rate=24000"))] if data else []
    return SimpleNamespace(candidates=[SimpleNamespace(content=SimpleNamespace(parts=parts))], usage_metadata=usage)


def _api_error(code: int, message: str | None = None, details: list | None = None):
    from google.genai import errors

    error = {"code": code, "message": message or str(code), **({"details": details} if details else {})}
    return errors.APIError(code, {"error": error})


class Engines:
    """Per-model stand-ins for generate_content_stream and generate_content. An outcome is an exception or a list of
    responses and exceptions; a model with no outcome set answers with two streamed chunks, or one whole response."""

    def __init__(self):
        self.calls: list[tuple[str, str, object]] = []  # (stream | once, model id, contents)
        self.stream: dict[str, object] = {}
        self.once: dict[str, object] = {}

    def stream_fn(self, engine, contents, config):
        self.calls.append(("stream", engine.id, contents))
        outcome = self.stream.get(engine.id, [_response(PCM[0]), _response(PCM[1], USAGE)])

        def responses():  # like the SDK, the request goes out on the first next()
            if isinstance(outcome, Exception):
                raise outcome
            for item in outcome:
                if isinstance(item, Exception):
                    raise item
                yield item
        return responses()

    def once_fn(self, engine, contents, config):
        self.calls.append(("once", engine.id, contents))
        outcome = self.once.get(engine.id, _response(b"".join(PCM), USAGE))
        if isinstance(outcome, Exception):
            raise outcome
        return outcome

    def models(self, kind: str | None = None) -> list[str]:
        return [model for k, model, _ in self.calls if kind in (None, k)]


@pytest.fixture
def fake(monkeypatch):
    f = Engines()
    monkeypatch.setattr(tts, "_stream", f.stream_fn)
    monkeypatch.setattr(tts, "_once", f.once_fn)
    tts.reset()
    yield f
    tts.reset()


def _settings(**overrides) -> Settings:
    base = {"genai_enabled": True, "tts_enabled": True, "project_id": "p", "genai_backend": "vertex", "tts_budget_usd": 0.50}
    return Settings(**{**base, **overrides})


def _primary_and_fallback():
    primary, fallback = tts.engines()
    return primary, fallback


# --- the pin ------------------------------------------------------------------------------------------


def test_models_yaml_pins_the_primary_and_the_fallback():
    assert tuple(e.id for e in tts.engines()) == PINNED
    assert [e.name for e in tts.engines()] == list(tts.ENGINE_ROLES) == ["tts", "tts_fallback"]


def test_the_engines_are_priced_per_audio_token_as_the_research_note_says():
    roles = genai_client.roles()
    assert (roles["tts"].input_usd_per_m, roles["tts"].output_usd_per_m) == (0.50, 6.00)
    assert (roles["tts_fallback"].input_usd_per_m, roles["tts_fallback"].output_usd_per_m) == (0.50, 10.00)


def test_the_preview_primary_is_served_from_the_global_endpoint_and_reads_its_text_verbatim():
    primary, fallback = _primary_and_fallback()
    assert primary.location == "global" and primary.tts_style == "metadata"
    assert fallback.location is None and fallback.tts_style == "prompt"


def test_a_missing_or_duplicate_fallback_leaves_one_engine(monkeypatch):
    role = genai_client.ModelRole("tts", "m", 0.5, 6.0)
    monkeypatch.setattr(genai_client, "roles", lambda: {"tts": role})
    assert tts.engines() == (role,)
    monkeypatch.setattr(genai_client, "roles", lambda: {"tts": role, "tts_fallback": genai_client.ModelRole("tts_fallback", "m", 0.5, 6.0)})
    assert tts.engines() == (role,)


# --- one voice, one style, two request shapes ---------------------------------------------------------


def test_the_primary_speaks_first_with_the_text_verbatim_and_the_urgent_style_in_speech_metadata(fake):
    primary, _ = _primary_and_fallback()
    assert list(tts.speak(WHY, _settings())) == list(PCM)
    assert fake.models() == [primary.id]
    (content,) = fake.calls[0][2]
    (part,) = content.parts
    assert part.text == WHY and part.speech_metadata.style == tts.URGENT_STYLE.rstrip(": ")


def test_the_fallback_takes_the_urgent_style_as_a_spoken_instruction_prefix_as_the_clips_were_made():
    _, fallback = _primary_and_fallback()
    assert tts.contents(fallback.id, WHY) == tts.URGENT_STYLE + WHY
    assert not isinstance(tts.contents("an-unknown-model", WHY, "Calm: "), str)  # unknown: fail closed, the style is never read aloud


def test_both_engines_speak_in_the_same_voice(fake, monkeypatch):
    primary, fallback = _primary_and_fallback()
    fake.stream[primary.id] = _api_error(404)
    fake.once[primary.id] = _api_error(404)
    configs = []

    def recording(engine, contents, config):
        configs.append(config.speech_config.voice_config.prebuilt_voice_config.voice_name)
        return fake.stream_fn(engine, contents, config)
    monkeypatch.setattr(tts, "_stream", recording)
    list(tts.speak(WHY, _settings(tts_voice="Sulafat")))
    assert configs == ["Sulafat", "Sulafat"] and fake.models("stream") == [primary.id, fallback.id]


def test_each_engine_is_called_on_its_own_endpoint(monkeypatch):
    primary, fallback = _primary_and_fallback()
    seen = []

    class Models:
        def __init__(self, location):
            self.location = location

        def generate_content_stream(self, model, contents, config):
            seen.append((self.location, model))
            if model == primary.id:
                raise _api_error(404)
            return iter([_response(PCM[0], USAGE)])

        def generate_content(self, model, contents, config):
            seen.append((self.location, model))
            raise _api_error(404)

    monkeypatch.setattr(genai_client, "_client", lambda location=None: SimpleNamespace(models=Models(location)))
    tts.reset()
    try:
        assert list(tts.speak(WHY, _settings())) == [PCM[0]]
    finally:
        tts.reset()
    assert seen == [("global", primary.id), ("global", primary.id), (None, fallback.id)]  # None: settings.genai_location


# --- model not served: move to the other engine, and remember it --------------------------------------


def test_a_primary_that_is_not_found_moves_the_call_to_the_fallback_and_is_remembered(fake):
    primary, fallback = _primary_and_fallback()
    fake.stream[primary.id] = _api_error(404)
    fake.once[primary.id] = _api_error(404, f"Publisher Model `{primary.id}` was not found")
    assert list(tts.speak(WHY, _settings())) == list(PCM)
    assert fake.models() == [primary.id, primary.id, fallback.id]
    assert tts.LEDGER.spent_usd == pytest.approx(genai_client.cost_usd(fallback, 120, 250))  # billed at the engine that spoke
    fake.calls.clear()
    assert list(tts.speak(WHY, _settings())) == list(PCM)
    assert fake.models() == [fallback.id]  # the missing primary is not asked again in this process


def test_a_400_that_names_the_model_counts_as_not_served(fake):
    primary, fallback = _primary_and_fallback()
    fake.stream[primary.id] = _api_error(400, f"Model {primary.id} is not available in this location")
    fake.once[primary.id] = _api_error(400, f"Model {primary.id} is not available in this location")
    assert list(tts.speak(WHY, _settings())) == list(PCM) and fake.models()[-1] == fallback.id


def test_a_400_that_does_not_name_the_model_is_a_failure_not_a_fallback(fake):
    primary, _ = _primary_and_fallback()
    fake.stream[primary.id] = _api_error(400, "Request contains an invalid argument.")
    fake.once[primary.id] = _api_error(400, "Request contains an invalid argument.")
    with pytest.raises(tts.Unavailable) as caught:
        list(tts.speak(WHY, _settings()))
    assert not isinstance(caught.value, tts.RateLimited) and fake.models() == [primary.id, primary.id]


def test_a_stream_refused_by_one_engine_is_spoken_whole_by_that_engine_and_the_other_still_streams(fake):
    primary, fallback = _primary_and_fallback()
    fake.stream[primary.id] = _api_error(400, f"Streaming is not supported for {primary.id}")
    assert list(tts.speak(WHY, _settings())) == [b"".join(PCM)]
    assert fake.calls[0][:2] == ("stream", primary.id) and fake.calls[1][:2] == ("once", primary.id) and len(fake.calls) == 2
    fake.calls.clear()
    list(tts.speak("ব্যাংক কখনো ফোনে পিন চায় না।", _settings()))
    assert fake.calls[0][:2] == ("once", primary.id)  # the primary is still there; it just does not stream
    tts._backend.missing.add(primary.id)
    fake.calls.clear()
    list(tts.speak("ব্যাংক কখনো ফোনে পিন চায় না।", _settings()))
    assert fake.calls[0][:2] == ("stream", fallback.id)


def test_when_neither_engine_is_served_tts_is_unavailable_and_stops_asking(fake):
    primary, fallback = _primary_and_fallback()
    for model in (primary.id, fallback.id):
        fake.stream[model], fake.once[model] = _api_error(404), _api_error(404)
    with pytest.raises(tts.Unavailable):
        list(tts.speak(WHY, _settings()))
    assert len(fake.calls) == 4 and tts.LEDGER.spent_usd == 0 and tts.LEDGER.held_usd == 0
    fake.calls.clear()
    with pytest.raises(tts.Unavailable):
        list(tts.speak(WHY, _settings()))
    assert fake.calls == []


@pytest.mark.parametrize("code", [500, 503])
def test_a_500_or_503_before_any_audio_moves_the_same_warning_to_the_fallback(fake, code):
    """Apa always speaks in Gemini's voice (the phone has no voice of its own): a one-off server error on one engine is not
    the end of the warning when the other engine can speak it."""
    primary, fallback = _primary_and_fallback()
    fake.stream[primary.id] = _api_error(code)
    assert b"".join(tts.speak(WHY, _settings())) == b"".join(PCM) and fake.models() == [primary.id, fallback.id]


def test_a_500_on_both_engines_is_unavailable_not_rate_limited(fake):
    primary, fallback = _primary_and_fallback()
    fake.stream[primary.id], fake.stream[fallback.id] = _api_error(500), _api_error(503)
    with pytest.raises(tts.Unavailable) as caught:
        list(tts.speak(WHY, _settings()))
    assert not isinstance(caught.value, tts.RateLimited) and fake.models() == [primary.id, fallback.id]


def test_a_timeout_does_not_move_to_the_fallback(fake):
    """The time budget is spent and the request may have been billed: no second request."""
    primary, _ = _primary_and_fallback()
    fake.stream[primary.id] = TimeoutError("read timed out")
    with pytest.raises(tts.Unavailable):
        list(tts.speak(WHY, _settings()))
    assert fake.models() == [primary.id]


# --- 429 and pacing: the other engine speaks; a request that would be refused is never sent -------------


def test_a_429_on_the_primary_moves_the_same_warning_to_the_fallback(fake):
    primary, fallback = _primary_and_fallback()
    details = [{"@type": "type.googleapis.com/google.rpc.QuotaFailure", "violations": [{"quotaMetric": QUOTA}]}]
    fake.stream[primary.id] = _api_error(429, "Quota exceeded.", details)
    assert b"".join(tts.speak(WHY, _settings())) == b"".join(PCM)
    assert fake.models() == [primary.id, fallback.id]
    assert tts.LEDGER.held_usd == 0 and tts.LEDGER.spent_usd > 0  # the fallback's audio is billed, the refused request is not


def test_after_a_429_the_primary_rests_and_the_fallback_speaks(fake):
    primary, fallback = _primary_and_fallback()
    fake.stream[primary.id] = _api_error(429, f"Quota exceeded for {QUOTA} with base model: {primary.id}.")
    list(tts.speak(WHY, _settings()))
    list(tts.speak("ব্যাংক কখনো ফোনে পিন চায় না।", _settings()))
    assert fake.models() == [primary.id, fallback.id, fallback.id]  # no second request to the engine that said 429


def test_a_429_on_both_engines_raises_rate_limited_and_names_the_quota(fake):
    primary, fallback = _primary_and_fallback()
    fake.stream[primary.id] = _api_error(429)
    fake.stream[fallback.id] = _api_error(429, f"Quota exceeded for {QUOTA} with base model: {fallback.id}.")
    with pytest.raises(tts.RateLimited) as caught:
        list(tts.speak(WHY, _settings()))
    assert caught.value.quota == QUOTA and isinstance(caught.value, tts.Unavailable)  # callers that keep the floor still work
    assert fake.models() == [primary.id, fallback.id] and tts.LEDGER.spent_usd == 0 and tts.LEDGER.held_usd == 0
    with pytest.raises(tts.RateLimited):
        list(tts.speak("ব্যাংক কখনো ফোনে পিন চায় না।", _settings()))
    assert len(fake.calls) == 2  # both resting: nothing is sent


def test_no_engine_is_sent_more_requests_a_minute_than_its_pace(fake, monkeypatch):
    """The quota is a few requests a minute per model: the server counts its own and never sends the one that would be
    refused. Two a minute here: two warnings on the primary, two on the fallback, the fifth is not sent at all."""
    primary, fallback = _primary_and_fallback()
    now = [1000.0]
    monkeypatch.setattr(tts, "_clock", lambda: now[0])
    settings = _settings(tts_requests_per_min=2, tts_fallback_requests_per_min=2)
    texts = [f"{WHY} {word}" for word in ("এক", "দুই", "তিন", "চার", "পাঁচ")]
    for text in texts[:4]:
        assert b"".join(tts.speak(text, settings))
    with pytest.raises(tts.RateLimited):
        list(tts.speak(texts[4], settings))
    assert fake.models() == [primary.id, primary.id, fallback.id, fallback.id]
    assert tts.LEDGER.held_usd == 0
    now[0] += 61  # a minute later the primary has room again
    assert b"".join(tts.speak(texts[4], settings)) and fake.models()[-1] == primary.id


def test_each_engine_has_its_own_pace(fake, monkeypatch):
    """Live, 2026-10-17: gemini-2.5-flash-tts answered 429 on its 7th request in a minute while 3.8 Flash-Lite took 8 without
    one. The fallback is paced on its own, lower limit."""
    primary, fallback = _primary_and_fallback()
    monkeypatch.setattr(tts, "_clock", lambda: 1000.0)
    settings = _settings(tts_requests_per_min=2, tts_fallback_requests_per_min=1)
    for word in ("এক", "দুই", "তিন"):
        assert b"".join(tts.speak(f"{WHY} {word}", settings))
    with pytest.raises(tts.RateLimited):
        list(tts.speak(f"{WHY} চার", settings))
    assert fake.models() == [primary.id, primary.id, fallback.id]


def test_a_cached_warning_costs_no_request(fake, monkeypatch):
    monkeypatch.setattr(tts, "_clock", lambda: 1000.0)
    settings = _settings(tts_requests_per_min=1)
    first = tts.say(WHY, settings)
    b"".join([first.first, *first.rest])
    again = tts.say(WHY, settings)
    assert again.cached and len(fake.calls) == 1


def test_a_429_from_the_fallback_also_raises_rate_limited(fake):
    primary, fallback = _primary_and_fallback()
    fake.stream[primary.id], fake.once[primary.id] = _api_error(404), _api_error(404)
    fake.stream[fallback.id] = _api_error(429)
    with pytest.raises(tts.RateLimited) as caught:
        list(tts.speak(WHY, _settings()))
    assert caught.value.quota is None and fake.models() == [primary.id, primary.id, fallback.id]


# --- the older renderers that use the tts role send the style where its engine reads it ---------------


def _sent_style(body) -> tuple[str, str]:
    """(text, style) of a speech_metadata request."""
    (content,) = body
    (part,) = content.parts
    return part.text, part.speech_metadata.style


def test_the_speech_smoke_renderer_never_puts_its_direction_in_the_text_of_a_verbatim_engine(monkeypatch):
    from scripts import make_smoke_audio as m

    sent = []

    class Models:
        def generate_content(self, model, contents, config):
            sent.append(contents)
            return _response(PCM[0], USAGE)
    monkeypatch.setattr(genai_client, "_client", lambda location=None: SimpleNamespace(models=Models()))
    primary, fallback = _primary_and_fallback()
    m._synthesise(primary.id, WHY, "Kore", "Calm and ordinary. ")
    m._synthesise(fallback.id, WHY, "Kore", "Calm and ordinary. ")
    assert _sent_style(sent[0]) == (WHY, "Calm and ordinary.") and sent[1] == "Calm and ordinary. " + WHY


def test_the_audition_renderer_never_puts_its_direction_in_the_text_of_a_verbatim_engine(monkeypatch, tmp_path):
    import google.genai

    from eval import budget
    from scripts import render_apa_audio as r

    sent, ledger = [], budget.SpendLedger(tmp_path / "spend.json", cap_usd=1.0)

    class Client:
        def __init__(self, **kwargs):
            self.models = self

        def generate_content(self, model, contents, config):
            sent.append((model, contents))
            return _response(PCM[0], USAGE)
    monkeypatch.setattr(google.genai, "Client", Client)
    monkeypatch.setattr(budget, "SpendLedger", lambda: ledger)  # never the real .eval_spend.json
    monkeypatch.setattr(r, "PACE_S", 0)
    r.render([("urgent", "Sulafat", tmp_path / "a.wav", WHY)])
    assert sent[0][0] == tts.engines()[0].id and _sent_style(sent[0][1]) == (WHY, r.STYLES["urgent"].rstrip(": "))
    assert (tmp_path / "a.wav").exists() and ledger.spent() > 0


# --- scripts/tts_engine_smoke.py (paid; only fakes here) ----------------------------------------------

REPORT_DRAFT = (  # the report's illustrative A|T|R|X ("Engine choice..." cites it from "Code plans, Flash-Lite phrases, code checks")
    ("A", "রহিমা, একটু থামুন — কোডটা কাউকে বলবেন না।"),
    ("T", "ফোনে আপনার মেসেজে আসা কোডটা চাওয়া হচ্ছে।"),
    ("R", "আসল ব্যাংক বা ভরসা কখনো ফোনে এই কোড চায় না।"),
    ("X", "কলটা কেটে দিন, তারপর অ্যাপের \"ভরসায় কল করুন\" বোতাম চাপুন।"),
)


def _smoke_synth(outcomes: dict):
    """A stand-in for tts.responses: outcomes maps a model id to a list, one entry per request, of an exception or None
    (two streamed chunks); a model with no list left answers with two chunks."""
    calls = []

    def synth(engine, text, settings):
        calls.append((engine.id, text, settings.tts_voice))
        queue = outcomes.get(engine.id) or []
        outcome = queue.pop(0) if queue else None
        if isinstance(outcome, Exception):
            raise outcome
        return iter([_response(PCM[0]), _response(PCM[1], USAGE)])
    return synth, calls


def test_the_smoke_lines_are_the_reports_draft_and_one_more_all_pending_a_native_check():
    from scripts import tts_engine_smoke as s

    assert len(s.LINES) == 5 and tuple((line["role"], line["text_bn"]) for line in s.LINES[:4]) == REPORT_DRAFT
    assert all(line["native_check"] == "pending" and line["text_en"] for line in s.LINES)
    assert all(tts.speakable(line["text_bn"]) for line in s.LINES)  # no digits, tip-off words or English, as Apa must
    assert s.VOICE == "Sulafat" and [line["n"] for line in s.LINES] == [1, 2, 3, 4, 5]


def test_the_smoke_dry_run_calls_nothing_and_writes_nothing(tmp_path, capsys, monkeypatch):
    from scripts import tts_engine_smoke as s

    monkeypatch.setattr(tts, "responses", lambda *a, **k: pytest.fail("a dry run must not call a model"))
    monkeypatch.setattr(genai_client, "_client", lambda *a, **k: pytest.fail("a dry run must not build a client"))
    s.main(["--dry-run", "--spend-file", str(tmp_path / "spend.json"), "--out-dir", str(tmp_path / "out"),
            "--result", str(tmp_path / "result.json")])
    out = capsys.readouterr().out
    assert "dry run" in out.lower() and all(e.id in out for e in tts.engines()) and "$0.10" in out
    assert list(tmp_path.iterdir()) == []


def test_the_smoke_renders_every_line_on_both_engines_in_sulafat_and_records_what_a_native_ear_needs(tmp_path):
    import wave

    from eval.budget import SpendLedger
    from scripts import tts_engine_smoke as s

    primary, fallback = _primary_and_fallback()
    synth, calls = _smoke_synth({})
    ledger, sleeps = SpendLedger(tmp_path / "spend.json", cap_usd=1.0), []
    result = s.run(tts.engines(), s.LINES, _settings(tts_voice="Sulafat"), ledger, tmp_path / "out", synth=synth, sleep=sleeps.append)
    assert [c[0] for c in calls] == [primary.id] * 5 + [fallback.id] * 5 and {c[2] for c in calls} == {"Sulafat"}
    assert sleeps == [s.PACE_S] * 9  # paced for the TTS quota, between every two requests
    for engine in (primary, fallback):
        for n in range(1, 6):
            with wave.open(str(tmp_path / "out" / engine.id / f"{n}.wav")) as w:
                assert (w.getframerate(), w.getnchannels(), w.getnframes()) == (24000, 1, 4800)
        row = result["engines"][engine.id]
        assert row["reachable"] is True and row["error"] is None and row["role"] == engine.name
        assert row["first_byte_ms_p50"] is not None and row["total_ms_p50"] >= row["first_byte_ms_p50"]
        assert row["audio_s"] == pytest.approx(1.0) and row["chars_per_second"] > 0
        assert row["cost_usd"] == pytest.approx(5 * genai_client.cost_usd(engine, 120, 250))
        assert [line["status"] for line in row["lines"]] == ["ok"] * 5
    assert ledger.spent() == pytest.approx(sum(r["cost_usd"] for r in result["engines"].values())) and ledger._read()["calls"] == 10
    assert result["voice"] == "Sulafat" and result["native_check"] == "pending" and len(result["lines"]) == 5


def test_an_engine_that_is_not_found_is_recorded_with_its_code_and_not_asked_again(tmp_path):
    from eval.budget import SpendLedger
    from scripts import tts_engine_smoke as s

    primary, fallback = _primary_and_fallback()
    synth, calls = _smoke_synth({primary.id: [_api_error(404)]})
    ledger, sleeps = SpendLedger(tmp_path / "spend.json", cap_usd=1.0), []
    result = s.run(tts.engines(), s.LINES, _settings(), ledger, tmp_path / "out", synth=synth, sleep=sleeps.append)
    row = result["engines"][primary.id]
    assert row["reachable"] is False and row["error"] == 404 and row["cost_usd"] == 0
    assert [line["status"] for line in row["lines"]] == [404] + ["skipped"] * 4
    assert [c[0] for c in calls] == [primary.id] + [fallback.id] * 5 and not (tmp_path / "out" / primary.id).exists()
    assert result["engines"][fallback.id]["reachable"] is True and len(sleeps) == 5


def test_the_smoke_backs_off_on_a_429_and_a_quota_that_never_clears_stops_that_engine(tmp_path):
    from eval.budget import SpendLedger
    from scripts import tts_engine_smoke as s

    primary, fallback = _primary_and_fallback()
    quota_429 = _api_error(429, f"Quota exceeded for {QUOTA} with base model: {fallback.id}.")
    synth, calls = _smoke_synth({primary.id: [_api_error(429), _api_error(429)], fallback.id: [quota_429] * 4})
    ledger, sleeps = SpendLedger(tmp_path / "spend.json", cap_usd=1.0), []
    result = s.run(tts.engines(), s.LINES, _settings(), ledger, tmp_path / "out", synth=synth, sleep=sleeps.append)
    assert sleeps[:2] == list(s.RETRY_WAITS[:2]) and result["engines"][primary.id]["reachable"] is True
    row = result["engines"][fallback.id]
    assert row["reachable"] is False and row["error"] == 429 and row["lines"][0]["quota"] == QUOTA
    assert [line["status"] for line in row["lines"]] == [429] + ["skipped"] * 4
    assert [c[0] for c in calls].count(fallback.id) == len(s.RETRY_WAITS) + 1


def test_the_smoke_writes_its_result_where_the_brief_says(tmp_path, monkeypatch):
    import json

    from scripts import tts_engine_smoke as s

    assert s.RESULT_FILE.as_posix().endswith("eval/results/tts_engine_smoke.json")
    assert s.OUT_DIR.as_posix().endswith("eval/tts_engine_smoke")
    synth, _ = _smoke_synth({})
    monkeypatch.setattr(s, "_synth", synth)
    monkeypatch.setattr(s, "PACE_S", 0)
    monkeypatch.setattr(genai_client, "select_backend", lambda settings: "vertex")
    s.main(["--spend-file", str(tmp_path / "spend.json"), "--out-dir", str(tmp_path / "out"), "--result", str(tmp_path / "r.json")])
    written = json.loads((tmp_path / "r.json").read_text(encoding="utf-8"))
    assert set(written["engines"]) == {e.id for e in tts.engines()} and written["lines"][0]["text_bn"] == REPORT_DRAFT[0][1]


# --- review fixes ----------------------------------------------------------------------------------------


def test_a_verbatim_engine_gets_its_style_in_metadata_whichever_role_it_sits_in(monkeypatch):
    """Swapping only the ids of the two role blocks left 3.8 marked 'prompt', so it would have read the English direction
    aloud. The style mode now belongs to the model: a Gemini 3.x TTS model is verbatim wherever it is configured."""
    swapped = {name: dataclasses.replace(role, tts_style="prompt" if role.id.startswith("gemini-3") else "metadata")
               for name, role in genai_client.roles().items()}
    monkeypatch.setattr(genai_client, "roles", lambda: swapped)
    body = tts.contents("gemini-3.8-flash-lite-tts", WHY)
    assert not isinstance(body, str) and body[0].parts[0].text == WHY and body[0].parts[0].speech_metadata.style
    assert isinstance(tts.contents("gemini-2.5-flash-tts", WHY), str)  # an older engine is told how to speak before the text
    assert isinstance(tts.contents("gemini-9.9-unknown-tts", WHY), str) is False  # unknown models fail closed: nothing read aloud


def test_an_empty_stream_from_a_served_engine_says_no_audio_not_not_served(fake):
    primary, _ = _primary_and_fallback()
    fake.stream[primary.id], fake.once[primary.id] = [], _response(None)
    with pytest.raises(tts.Unavailable) as raised:
        list(tts.speak(WHY, _settings()))
    assert "no audio" in str(raised.value) and "not found" not in str(raised.value)


def test_the_smoke_does_not_count_an_engine_that_answers_with_no_audio_as_reachable(tmp_path):
    from eval.budget import SpendLedger
    from scripts import tts_engine_smoke as smoke

    primary, fallback = _primary_and_fallback()

    def synth(engine, text_bn, settings):
        return iter([_response(None, USAGE)] if engine.id == primary.id else [_response(PCM[0], USAGE)])
    out = smoke.run([primary, fallback], smoke.LINES[:1], _settings(), SpendLedger(tmp_path / "s.json", cap_usd=1.0), tmp_path,
                    synth=synth, sleep=lambda s: None, pace_s=0)
    engines = out["engines"]
    assert engines[primary.id]["reachable"] is False and engines[primary.id]["lines"][0]["status"] == "no_audio"
    assert engines[fallback.id]["reachable"] is True
