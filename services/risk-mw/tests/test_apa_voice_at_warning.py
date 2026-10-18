"""Apa speaks in the chosen Gemini voice only when a warning is given, in one request, and never past the TTS quota.

The quota is a few requests a minute per model. Pre-rendering every line of every refresh during a call spent it before
the hold needed it (live run, 2026-10-17: ten renders, then 429). Now the pre-render writes Apa's text only, and the
warning is spoken whole, once, when it is given: /v1/intervene signs its joined text and /v1/apa/why-audio speaks it in one
request. Every model call here is a fake (tts._stream and tts._once); nothing reaches Gemini.
"""

from __future__ import annotations

import time
from types import SimpleNamespace

import pytest

from app import apa, prerender, state, tts
from app.settings import Settings, get_settings

PCM = (b"\x01\x00" * 2400, b"\x02\x00" * 2400)
USAGE = SimpleNamespace(prompt_token_count=120, candidates_token_count=250, thoughts_token_count=None)
LINE = "কোডটা কাউকে বলবেন না, কলটা কেটে দিন।"


def _response(data: bytes):
    parts = [SimpleNamespace(inline_data=SimpleNamespace(data=data, mime_type="audio/L16;codec=pcm;rate=24000"))]
    return SimpleNamespace(candidates=[SimpleNamespace(content=SimpleNamespace(parts=parts))], usage_metadata=USAGE)


@pytest.fixture(autouse=True)
def fake(monkeypatch):
    sent: list[tuple[str, object]] = []

    def stream(engine, contents, config):
        sent.append((engine.id, contents))
        return iter([_response(PCM[0]), _response(PCM[1])])

    def once(engine, contents, config):
        sent.append((engine.id, contents))
        return _response(b"".join(PCM))

    monkeypatch.setattr(tts, "_stream", stream)
    monkeypatch.setattr(tts, "_once", once)
    tts.reset()
    yield sent
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


# --- the pre-render writes Apa's text; audio waits for the warning --------------------------------------------------------


def test_the_pre_render_writes_the_text_but_renders_no_audio_by_default(fake):
    renderer = prerender._Renderer((), "rina", "call-1", _settings())
    line = renderer.line(SimpleNamespace(role="A", text_bn=LINE, text_en="Don't tell anyone the code; hang up."))
    assert line.clip_id is None and line.speak_on_device and fake == []


def test_the_pre_render_still_renders_when_asked(fake):
    renderer = prerender._Renderer((), "rina", "call-1", _settings(prerender_audio=True))
    line = renderer.line(SimpleNamespace(role="A", text_bn=LINE, text_en="Don't tell anyone the code; hang up."))
    assert line.clip_id is not None and len(fake) == 1


# --- the warning is spoken whole, once, when it is given ------------------------------------------------------------------


def test_a_whole_warning_is_speakable_up_to_its_own_limit():
    warning = ("কলটা কেটে দিন। " * 40)[: apa.WARNING_MAX_CHARS]
    assert len(warning) > apa.WHY_MAX_CHARS and not tts.speakable(warning)  # longer than one explanation
    assert tts.speakable(warning, apa.WARNING_MAX_CHARS)
    assert not tts.speakable(warning + "ক", apa.WARNING_MAX_CHARS)


def test_intervene_signs_the_whole_warning_and_why_audio_speaks_it_in_one_request(client, fake, use_settings, monkeypatch):
    from app.ledger import Evidence, Ledger
    from app.warnings import composer

    use_settings()
    ledger = Ledger(tactics={"CREDENTIAL_REQUEST": Evidence("CREDENTIAL_REQUEST", "কোডটা বলুন", 0)}, claimed_identity="bank_mfs_staff", asks=("otp",))
    state.store().set("scam_sessions", "call-1", {"uid": "demo", "ledger": ledger.to_doc(), "band": "likely", "updated_at": time.time()})
    monkeypatch.setattr(composer, "_model_text", lambda *args, **kwargs: iter([f"A| {LINE} || Don't tell anyone the code; hang up.\n"]))
    out = client.post("/v1/intervene", json={"user_id": "rina", "trigger": "SCAM_CONVERSATION", "txn": {"type": "pin_reset"},
                                             "session_id": "call-1"}).json()
    assert out["script_bn"] and out["audio_token"] and out["audio_expires_at"]
    assert fake == []  # giving the warning renders nothing by itself: the phone asks for the audio once
    r = client.post("/v1/apa/why-audio", json={"user_id": "rina", "text_bn": out["script_bn"], "token": out["audio_token"]})
    assert r.status_code == 200 and r.content[44:] == b"".join(PCM) and len(fake) == 1


def test_why_audio_speaks_a_signed_whole_warning_longer_than_one_explanation(client, fake, use_settings):
    use_settings()
    warning = ("কলটা কেটে দিন, তারপর ব্যাংকে কল করুন। " * 20)[: apa.WARNING_MAX_CHARS - 10]
    token = apa.sign_why(warning, get_settings())[0]
    r = client.post("/v1/apa/why-audio", json={"user_id": "rina", "text_bn": warning, "token": token})
    assert r.status_code == 200 and len(fake) == 1


def test_why_audio_refuses_text_over_the_warning_limit(client, fake, use_settings):
    use_settings()
    text = "ক" * (apa.WARNING_MAX_CHARS + 1)
    r = client.post("/v1/apa/why-audio", json={"user_id": "rina", "text_bn": text, "token": apa.sign_why(text, get_settings())[0]})
    assert r.status_code == 422 and fake == []


def test_when_both_engines_are_spent_nothing_is_sent_and_the_phone_plays_its_own_gemini_clip(client, fake, use_settings, monkeypatch):
    """Never a 429 from Google and never a failed warning: past the pace the route answers 204 and the phone plays its own
    pre-rendered clip, recorded in the same Gemini voice (Apa never speaks in the phone's own voice)."""
    monkeypatch.setattr(tts, "_clock", lambda: 1000.0)
    use_settings(tts_requests_per_min=1, tts_fallback_requests_per_min=1)
    texts = [f"{LINE} {word}" for word in ("এক", "দুই", "তিন")]
    codes = [client.post("/v1/apa/why-audio", json={"user_id": "rina", "text_bn": t, "token": apa.sign_why(t, get_settings())[0]}).status_code
             for t in texts]
    assert codes == [200, 200, 204] and len(fake) == 2  # one on each engine, then nothing sent
