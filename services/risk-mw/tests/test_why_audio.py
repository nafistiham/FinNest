"""Live Apa audio (spec US-3 S2, FR-4): POST /v1/apa/why-audio speaks one of Apa's validated lines with Gemini TTS,
and only text this server signed.

Every model call here is a fake: tts._stream and tts._once are replaced for the whole module. Engine choice and fallback
are in test_tts_engines.py; here the primary engine answers.
"""

import io
import struct
import time
import wave
from types import SimpleNamespace

import pytest

from app import apa, genai_client, state, tts
from app.settings import Settings, get_settings

WHY = "কলার আপনার কোড চেয়েছে, তাই থামালাম। কলটা কেটে দিন।"
OTHER_WHY = "ব্যাংক কখনো ফোনে পিন চায় না, তাই এটা আটকে রাখলাম।"
PCM = (b"\x01\x00" * 2400, b"\x02\x00" * 2400)  # two 0.1 s chunks, 16-bit mono at 24 kHz
USAGE = SimpleNamespace(prompt_token_count=120, candidates_token_count=250, thoughts_token_count=None)
HEADER = struct.Struct("<4sI4s4sIHHIIHH4sI")


def _response(data: bytes | None, usage=None):
    parts = [SimpleNamespace(inline_data=SimpleNamespace(data=data, mime_type="audio/L16;codec=pcm;rate=24000"))] if data else []
    return SimpleNamespace(candidates=[SimpleNamespace(content=SimpleNamespace(parts=parts))], usage_metadata=usage)


def _api_error(code: int):
    from google.genai import errors
    return errors.APIError(code, {"error": {"message": str(code)}})


class FakeTTS:
    """generate_content_stream / generate_content stand-ins. A stream outcome is an exception or a list of responses and exceptions;
    either outcome may also be a dict from model id to outcome, for engines that answer differently."""

    def __init__(self):
        self.stream_calls, self.once_calls = [], []
        self.stream_outcome = [_response(PCM[0]), _response(PCM[1], USAGE)]
        self.once_outcome = _response(b"".join(PCM), USAGE)

    def stream(self, engine, contents, config):
        self.stream_calls.append((engine.id, contents, config))
        outcome = self.stream_outcome
        if isinstance(outcome, dict):
            outcome = outcome.get(engine.id, [_response(PCM[0]), _response(PCM[1], USAGE)])

        def responses():  # like the SDK, the request goes out on the first next()
            if isinstance(outcome, Exception):
                raise outcome
            for item in outcome:
                if isinstance(item, Exception):
                    raise item
                yield item
        return responses()

    def once(self, engine, contents, config):
        self.once_calls.append((engine.id, contents, config))
        outcome = self.once_outcome
        if isinstance(outcome, dict):
            outcome = outcome.get(engine.id, _response(b"".join(PCM), USAGE))
        if isinstance(outcome, Exception):
            raise outcome
        return outcome


@pytest.fixture(autouse=True)
def fake(monkeypatch):
    f = FakeTTS()
    monkeypatch.setattr(tts, "_stream", f.stream)
    monkeypatch.setattr(tts, "_once", f.once)
    tts.reset()
    yield f
    tts.reset()


def _settings(**overrides) -> Settings:
    base = {"genai_enabled": True, "tts_enabled": True, "project_id": "p", "genai_backend": "vertex", "tts_budget_usd": 0.50}
    return Settings(**{**base, **overrides})


@pytest.fixture
def use_settings(client):
    def apply(**overrides) -> Settings:
        settings = _settings(**overrides)
        client.app.dependency_overrides[get_settings] = lambda: settings
        return settings
    yield apply
    client.app.dependency_overrides.pop(get_settings, None)


SIGNED = object()


def _post(client, text=WHY, token=SIGNED):
    """By default the text carries the token /v1/apa/why would have issued for it (the default per-process secret)."""
    body = {"user_id": "rina", "text_bn": text}
    if token is SIGNED:
        token = apa.sign_why(text, get_settings())[0]
    if token is not None:
        body["token"] = token
    return client.post("/v1/apa/why-audio", json=body)


# --- the stream ---------------------------------------------------------------------------------------


def test_the_reply_is_a_wav_header_then_the_pcm_as_it_arrives(client, use_settings):
    use_settings()
    r = _post(client)
    assert r.status_code == 200 and r.headers["content-type"] == "audio/wav"
    riff, riff_size, wave_id, fmt, fmt_size, pcm_format, channels, rate, byte_rate, align, bits, data, data_size = \
        HEADER.unpack(r.content[:44])
    assert (riff, wave_id, fmt, fmt_size, data) == (b"RIFF", b"WAVE", b"fmt ", 16, b"data")
    assert (pcm_format, channels, rate, bits, byte_rate, align) == (1, 1, 24000, 16, 48000, 2)
    assert riff_size == data_size == 0xFFFFFFFF  # a live stream does not know its length yet
    assert r.content[44:] == b"".join(PCM)


def test_speak_yields_each_pcm_chunk_as_gemini_sends_it():
    assert list(tts.speak(WHY, _settings())) == list(PCM)


def test_the_urgent_style_and_the_voice_go_to_the_tts_role(client, fake, use_settings):
    from scripts import render_apa_audio

    use_settings(tts_voice="Sulafat")
    _post(client)
    model_id, contents, config = fake.stream_calls[0]
    assert model_id == genai_client.roles()["tts"].id == tts.engines()[0].id  # the ids are pinned once, in test_tts_engines.py
    assert tts.URGENT_STYLE == render_apa_audio.STYLES["urgent"] and contents == tts.contents(model_id, WHY)
    assert config.response_modalities == ["AUDIO"] and config.speech_config.voice_config.prebuilt_voice_config.voice_name == "Sulafat"


def test_cost_is_recorded_on_the_instance_ledger(client, use_settings):
    use_settings()
    _post(client)
    role = genai_client.roles()["tts"]
    assert tts.LEDGER.spent_usd == pytest.approx(genai_client.cost_usd(role, 120, 250))
    assert tts.LEDGER.calls == 1 and tts.LEDGER.held_usd == 0


def test_when_streaming_is_refused_one_call_is_spoken_whole(client, fake, use_settings):
    use_settings()
    fake.stream_outcome = _api_error(400)
    r = _post(client)
    assert r.status_code == 200 and r.content[44:] == b"".join(PCM) and len(fake.once_calls) == 1
    _post(client, OTHER_WHY)
    assert len(fake.stream_calls) == 1 and len(fake.once_calls) == 2  # this instance stops asking for a stream


def test_a_stream_cut_short_ends_the_audio_and_is_not_cached(client, fake, use_settings):
    use_settings()
    fake.stream_outcome = [_response(PCM[0]), RuntimeError("connection reset")]
    r = _post(client)
    assert r.status_code == 200 and r.content[44:] == PCM[0]
    assert tts.LEDGER.spent_usd == pytest.approx(tts.RESERVE_USD)  # the server may still bill a cut stream
    fake.stream_outcome = [_response(PCM[0]), _response(PCM[1], USAGE)]
    assert _post(client).content[44:] == b"".join(PCM) and len(fake.stream_calls) == 2


# --- the cache ----------------------------------------------------------------------------------------


def test_a_repeated_explanation_is_spoken_once_and_replayed_with_its_length(client, fake, use_settings):
    use_settings()
    first, second = _post(client), _post(client)
    assert len(fake.stream_calls) == 1 and first.content[44:] == second.content[44:]
    with wave.open(io.BytesIO(second.content)) as w:
        assert (w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()) == (1, 2, 24000, 4800)


def test_the_cache_keeps_only_the_most_recent_lines(client, fake, use_settings):
    use_settings(tts_cache_size=1)
    for text in (WHY, OTHER_WHY, WHY, WHY):
        _post(client, text)
    assert len(fake.stream_calls) == 3


# --- Apa's rules --------------------------------------------------------------------------------------


@pytest.mark.parametrize("text", [
    "কলার আপনার ৬ সংখ্যার কোড চেয়েছে।",             # a Bangla digit
    "কলার আপনার 6 সংখ্যার কোড চেয়েছে।",             # an ASCII digit
    "কলার আপনার ٦ সংখ্যার কোড চেয়েছে।",             # a digit from another script
    "আপনি যে নম্বরে টাকা পাঠাচ্ছেন সেটা নিয়ে সতর্কতা আছে, acct_pirganj তাই আটকে রাখলাম।",  # an account id
    "এক ঘণ্টা পরে আবার চেষ্টা করুন।",                # a duration
    "কয়েক মিনিট অপেক্ষা করুন, তারপর পাঠান।",        # a duration
    "এই নম্বর নিয়ে তদন্ত চলছে।",                    # tipping off
    "এটা একটা চক্রের কাজ, তাই আটকে রাখলাম।",         # tipping off
    "Send the money now, everything is fine.",       # not Bangla: Apa's endpoint is not a general voice
    "   ",                                           # nothing to say
])
def test_text_that_breaks_apas_rules_is_refused_before_any_model_call(client, fake, use_settings, text):
    use_settings()
    r = _post(client, text)
    assert r.status_code == 422 and fake.stream_calls == [] and fake.once_calls == []


def test_text_longer_than_a_whole_warning_is_refused(client, fake, use_settings):
    use_settings()
    assert _post(client, "ক" * (apa.WARNING_MAX_CHARS + 1)).status_code == 422 and fake.stream_calls == []


def test_a_short_bangla_line_with_latin_acronyms_is_still_speakable():
    assert tts.speakable(WHY) and tts.speakable("কলার আপনার OTP আর PIN চেয়েছে, তাই থামালাম।")


# --- only text this server wrote: the token from /v1/apa/why ------------------------------------------

# Passes every speakable() rule, yet tells the victim to read the code out: a caller must not get this in Apa's voice.
VISHING = "আপা বলছি। আপনার একাউন্ট ঝুঁকিতে আছে, ফোনে যিনি আছেন তাঁকে এখনই কোডটা বলে দিন।"


def test_text_without_a_token_is_refused_403_before_any_model_call(client, fake, use_settings):
    use_settings()
    assert tts.speakable(VISHING)
    r = _post(client, VISHING, token=None)
    assert r.status_code == 403 and fake.stream_calls == [] and fake.once_calls == []


@pytest.mark.parametrize("token", [
    lambda: apa.sign_why(WHY, get_settings())[0],                                              # issued for other text
    lambda: apa.sign_why(VISHING, get_settings(), time.time() - get_settings().apa_token_ttl_s - 1)[0],  # expired
    lambda: apa.sign_why(VISHING, Settings(apa_token_secret="another instance"))[0],          # another secret
    lambda: "9999999999." + "0" * 64,                                                         # forged
    lambda: "",
])
def test_a_wrong_or_expired_token_is_refused_403_before_any_model_call(client, fake, use_settings, token):
    use_settings()
    r = _post(client, VISHING, token=token())
    assert r.status_code == 403 and fake.stream_calls == [] and fake.once_calls == []


def test_a_line_of_apas_generated_warning_is_spoken_with_its_token(client, fake, use_settings, monkeypatch):
    """Each validated line carries its own token (P0 item 5): the per-line audio the pre-render will use."""
    from app.ledger import Evidence, Ledger
    from app.warnings import composer

    use_settings()
    ledger = Ledger(tactics={"CREDENTIAL_REQUEST": Evidence("CREDENTIAL_REQUEST", "কোডটা বলুন", 0)}, claimed_identity="bank_mfs_staff", asks=("otp",))
    state.store().set("scam_sessions", "call-1", {"uid": "demo", "ledger": ledger.to_doc(), "band": "likely", "updated_at": time.time()})
    line = "কোডটা কাউকে বলবেন না, কলটা কেটে দিন।"
    monkeypatch.setattr(composer, "_model_text", lambda *args, **kwargs: iter([f"A| {line} || Don't tell anyone the code; hang up.\n"]))
    why = client.post("/v1/apa/why", json={"user_id": "rina", "trigger": "SCAM_CONVERSATION", "session_id": "call-1",
                                           "pending_action": "pin_reset"}).json()
    first = why["lines"][0]
    assert first["text_bn"] == line
    r = _post(client, first["text_bn"], token=first["token"])
    assert r.status_code == 200 and r.content[44:] == b"".join(PCM) and len(fake.stream_calls) == 1


def test_a_configured_secret_signs_and_checks_the_token(client, fake, use_settings):
    settings = use_settings(apa_token_secret="shared by every instance")
    assert _post(client, WHY, token=apa.sign_why(WHY, Settings(apa_token_secret="per-process"))[0]).status_code == 403
    assert _post(client, WHY, token=apa.sign_why(WHY, settings)[0]).status_code == 200


# --- fallbacks: 204, and the phone speaks the text itself -----------------------------------------------------------


def test_tts_is_off_by_default_and_answers_204(client, fake):
    assert Settings().tts_enabled is False
    r = _post(client)
    assert r.status_code == 204 and r.content == b"" and fake.stream_calls == []


def test_tts_on_without_a_gemini_backend_answers_204(client, fake, use_settings):
    use_settings(genai_enabled=False)
    assert _post(client).status_code == 204 and fake.stream_calls == []


def test_over_the_spend_cap_answers_204_without_a_call(client, fake, use_settings):
    use_settings(tts_budget_usd=tts.RESERVE_USD / 2)
    assert _post(client).status_code == 204 and fake.stream_calls == [] and tts.LEDGER.held_usd == 0


def test_the_cap_counts_real_spend(client, fake, use_settings):
    use_settings(tts_budget_usd=tts.RESERVE_USD * 1.1)
    assert _post(client).status_code == 200
    assert _post(client, OTHER_WHY).status_code == 204 and len(fake.stream_calls) == 1


def test_rate_limited_answers_204_fast_and_backs_off(client, fake, use_settings):
    use_settings()
    fake.stream_outcome = _api_error(429)
    started = time.perf_counter()
    first = _post(client)
    elapsed = time.perf_counter() - started
    second = _post(client, OTHER_WHY)
    assert first.status_code == second.status_code == 204 and elapsed < 0.5
    assert len(fake.stream_calls) == 2 and fake.once_calls == []  # each engine asked once, and neither again while it rests
    assert tts.LEDGER.spent_usd == 0 and tts.LEDGER.held_usd == 0


@pytest.mark.parametrize("failure", [_api_error(500), _api_error(503), TimeoutError("read timed out")])
def test_a_failing_model_answers_204(client, fake, use_settings, failure):
    use_settings()
    fake.stream_outcome = failure  # on both engines: a 500 or 503 moves to the other engine, a timeout does not
    asked = 1 if isinstance(failure, TimeoutError) else 2
    assert _post(client).status_code == 204 and len(fake.stream_calls) == asked and fake.once_calls == []
    assert tts.LEDGER.held_usd == 0


def test_a_primary_engine_that_is_not_served_is_spoken_by_the_fallback(client, fake, use_settings):
    use_settings()
    primary, fallback = tts.engines()
    fake.stream_outcome, fake.once_outcome = {primary.id: _api_error(404)}, {primary.id: _api_error(404)}
    r = _post(client)
    assert r.status_code == 200 and r.content[44:] == b"".join(PCM)
    assert [c[0] for c in fake.stream_calls] == [primary.id, fallback.id] and fake.stream_calls[1][1] == tts.URGENT_STYLE + WHY
    _post(client, OTHER_WHY)
    assert [c[0] for c in fake.stream_calls][2:] == [fallback.id]


def test_a_reply_without_audio_answers_204(client, fake, use_settings):
    use_settings()
    fake.stream_outcome = [_response(None, USAGE)]
    assert _post(client).status_code == 204


# --- scripts/tts_latency.py ---------------------------------------------------------------------------


def test_latency_script_dry_run_calls_nothing_and_spends_nothing(tmp_path, capsys, monkeypatch):
    from scripts import tts_latency

    monkeypatch.setattr(tts_latency, "poster", lambda *a, **k: pytest.fail("a dry run must not build a client"))
    tts_latency.main(["--dry-run", "--spend-file", str(tmp_path / "spend.json")])
    assert "dry run" in capsys.readouterr().out.lower() and not (tmp_path / "spend.json").exists()


def test_latency_script_samples_pass_apas_rules():
    from scripts import tts_latency

    assert len(tts_latency.SAMPLES) >= 3 and all(tts.speakable(t) for t in tts_latency.SAMPLES)


def test_latency_script_signs_each_sample_with_the_services_secret():
    from scripts import tts_latency

    service = Settings(apa_token_secret="the service's secret")
    body = tts_latency.request_body(tts_latency.SAMPLES[0], service)
    assert body["text_bn"] == tts_latency.SAMPLES[0] and apa.verify_why(body["text_bn"], body["token"], service)


def test_latency_script_times_first_audio_and_records_spend(tmp_path):
    from eval.budget import SpendLedger
    from scripts import tts_latency

    def post(text):
        if text == tts_latency.SAMPLES[1]:
            return 204, iter(())
        return 200, iter((tts.wav_header(), PCM[0], PCM[1]))
    ledger = SpendLedger(tmp_path / "spend.json", cap_usd=1.0)
    rows = tts_latency.run(tts_latency.SAMPLES[:2], post, ledger, pace_s=0)
    assert [r["status"] for r in rows] == [200, 204]
    assert rows[0]["first_audio_ms"] is not None and rows[0]["total_ms"] >= rows[0]["first_audio_ms"]
    assert rows[0]["audio_s"] == pytest.approx(0.2) and rows[1]["first_audio_ms"] is None
    assert ledger.spent() > 0 and ledger._read()["calls"] == 2


def test_live_tts_speaks_in_the_chosen_voice():
    from app.settings import Settings
    from scripts.render_apa_audio import DEFAULT_VOICE

    assert Settings().tts_voice == DEFAULT_VOICE == "Sulafat"


def test_tts_sends_the_generous_server_deadline():
    from app import genai_client, tts
    from app.settings import Settings

    options = tts._config(Settings()).http_options
    assert options.headers["X-Server-Timeout"] == str(genai_client.SERVER_TIMEOUT_S) and options.timeout == int(Settings().tts_timeout_s * 1000)
