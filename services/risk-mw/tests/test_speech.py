"""Live Bangla speech (spec US-5): vocabulary, file transcription, the Live bridge and the 20-utterance smoke test.

Every model call is faked; nothing here reaches Gemini.
"""

from types import SimpleNamespace

import pytest

from app import genai_client, prerender, speech

WAV = b"RIFF" + b"\x00" * 64


# The speech smoke set (eval/speech_smoke/utterances.jsonl and its audio) is not in the public
# repository. Speech to text is off by default, so these tests skip when the set is absent.
def _smoke_set_exists() -> bool:
    from eval import transcription_smoke

    return transcription_smoke.UTTERANCES.exists()


needs_smoke_set = pytest.mark.skipif(
    not _smoke_set_exists(),
    reason="eval/speech_smoke/utterances.jsonl is not present (the speech smoke set is not published)",
)


@pytest.fixture
def gemini(monkeypatch):
    """A fake Gemini behind speech._generate: records each call and answers with the queued transcript."""
    calls, replies = [], []

    def fake(model_id, contents, config, timeout_s=None):
        calls.append(SimpleNamespace(model_id=model_id, contents=contents, config=config))
        return SimpleNamespace(text=replies.pop(0) if replies else "", usage_metadata=SimpleNamespace(
            prompt_token_count=400, candidates_token_count=40, thoughts_token_count=10))
    monkeypatch.setattr(genai_client, "select_backend", lambda settings: "vertex")
    monkeypatch.setattr(speech, "_generate", fake)
    return SimpleNamespace(calls=calls, replies=replies)


# --- vocabulary ---------------------------------------------------------------------------------------


def test_the_vocabulary_has_about_fifty_distinct_scam_terms():
    vocab = speech.SCAM_VOCABULARY
    assert 45 <= len(vocab) <= 60 and len(set(vocab)) == len(vocab)
    for term in ("বিকাশ", "নগদ", "রকেট", "পিন", "ওটিপি", "কোড", "ব্লক", "একাউন্ট বন্ধ", "লটারি", "স্কলারশিপ", "পুরস্কার", "ভেরিফাই",
                 "কাস্টমার কেয়ার", "হেল্পলাইন", "send money", "cash out", "ক্যাশ আউট", "পাসওয়ার্ড", "এজেন্ট", "রেফারেন্স"):
        assert term in vocab, term


def test_every_english_term_has_its_bangla_spelling():
    assert set(speech.LATIN_TERMS) <= set(speech.SCAM_VOCABULARY)
    for latin, bangla in speech.LATIN_TERMS.items():
        assert latin.isascii()
        assert all("ঀ" <= ch <= "৿" or ch == " " for ch in bangla), bangla


# --- file transcription ---------------------------------------------------------------------------------


def test_audio_types_are_normalised_and_checked():
    assert speech.check_audio(WAV, "audio/x-wav") == "audio/wav"
    assert speech.check_audio(WAV, "AUDIO/WEBM; codecs=opus") == "audio/webm"
    assert speech.check_audio(WAV, "audio/mp3") == "audio/mpeg"
    assert speech.check_audio(WAV, "audio/x-m4a") == "audio/mp4"
    for mime in ("audio/ogg", "audio/aac", "audio/mpeg", "audio/mp4"):
        assert speech.check_audio(WAV, mime) == mime
    with pytest.raises(speech.UnsupportedAudioType):
        speech.check_audio(WAV, "video/mp4")
    with pytest.raises(speech.EmptyAudio):
        speech.check_audio(b"", "audio/wav")
    with pytest.raises(speech.AudioTooLarge):
        speech.check_audio(b"\x00" * (speech.MAX_AUDIO_BYTES + 1), "audio/wav")


def test_bad_audio_is_rejected_before_gemini_is_asked(gemini):
    with pytest.raises(speech.AudioTooLarge):
        speech.transcribe(b"\x00" * (speech.MAX_AUDIO_BYTES + 1), "audio/wav")
    assert gemini.calls == []


def test_transcription_is_off_without_gemini():
    from app.settings import Settings

    with pytest.raises(genai_client.GenAIDisabled):
        speech.transcribe(WAV, "audio/wav", Settings(genai_enabled=False))


def test_transcription_sends_inline_audio_to_the_workhorse_with_bangla_hints(gemini):
    gemini.replies.append('  "আপনার ফোনে একটা কোড গেছে,\n কোডটা বলুন" ')
    result = speech.transcribe_call(WAV, "audio/x-wav", speech.get_settings())
    call = gemini.calls[0]
    role = genai_client.roles()["workhorse"]
    assert call.model_id == role.id
    audio = [p for p in call.contents if getattr(p, "inline_data", None) is not None]
    assert len(audio) == 1 and audio[0].inline_data.mime_type == "audio/wav" and audio[0].inline_data.data == WAV
    system = call.config.system_instruction
    assert "bn-BD" in system and "verbatim" in system.lower() and "বিকাশ" in system and "send money" in system
    assert result.text == "আপনার ফোনে একটা কোড গেছে, কোডটা বলুন"
    assert (result.tokens_in, result.tokens_out) == (400, 50)
    assert result.cost_usd == genai_client.cost_usd(role, 400, 50) and result.model_id == role.id
    gemini.replies.append("কোডটা বলুন")
    assert speech.transcribe(WAV, "audio/wav") == "কোডটা বলুন"


# --- POST /v1/scam/transcribe ---------------------------------------------------------------------------


def _b64(data: bytes) -> str:
    import base64
    return base64.b64encode(data).decode()


def transcribe_body(audio: bytes = WAV, mime: str = "audio/wav", **extra) -> dict:
    return {"session_id": "call-1", "audio_b64": _b64(audio), "mime_type": mime, **extra}


def test_the_transcribe_route_is_listed(client):
    assert "/v1/scam/transcribe" in client.get("/openapi.json").json()["paths"]


# Off since 2026-10-17: FinNest does not listen to phone calls, so neither speech path runs unless switched on.


@pytest.fixture
def transcription_on(client):
    """File-mode transcription switched on, for the tests of what it does when it runs."""
    from app.settings import Settings, get_settings

    client.app.dependency_overrides[get_settings] = lambda: Settings(transcription_enabled=True)
    yield
    client.app.dependency_overrides.pop(get_settings, None)


def test_speech_to_text_is_off_by_default():
    from app.settings import Settings

    assert Settings().transcription_enabled is False and Settings().live_transcription_enabled is False


def test_the_transcribe_route_is_off_by_default_even_with_gemini(client, gemini):
    resp = client.post("/v1/scam/transcribe", json=transcribe_body())
    assert resp.status_code == 503, resp.text
    assert "is off" in resp.json()["detail"] and "transcript-first" in resp.json()["detail"]
    assert gemini.calls == []


def test_the_deploy_script_ships_both_speech_paths_off():
    import re
    from pathlib import Path

    script = (Path(__file__).resolve().parents[1] / "scripts" / "deploy.sh").read_text(encoding="utf-8")
    assert re.search(r'^TRANSCRIPTION_ENABLED="\$\{RISK_MW_TRANSCRIPTION_ENABLED:-false\}"$', script, re.M)
    assert re.search(r'^LIVE_TRANSCRIPTION_ENABLED="\$\{RISK_MW_LIVE_TRANSCRIPTION_ENABLED:-false\}"$', script, re.M)
    assert "RISK_MW_TRANSCRIPTION_ENABLED=$TRANSCRIPTION_ENABLED" in script
    assert "RISK_MW_LIVE_TRANSCRIPTION_ENABLED=$LIVE_TRANSCRIPTION_ENABLED" in script


def test_the_transcribe_route_is_off_unless_gemini_is_on(client):
    from app.settings import Settings, get_settings

    client.app.dependency_overrides[get_settings] = lambda: Settings(genai_enabled=False, transcription_enabled=True)
    try:
        resp = client.post("/v1/scam/transcribe", json=transcribe_body())
    finally:
        client.app.dependency_overrides.pop(get_settings, None)
    assert resp.status_code == 503 and "transcript-first" in resp.json()["detail"]


def test_the_transcribe_route_checks_size_type_and_encoding(client, gemini, transcription_on):
    assert client.post("/v1/scam/transcribe", json=transcribe_body(b"\x00" * (speech.MAX_AUDIO_BYTES + 1))).status_code == 413
    assert client.post("/v1/scam/transcribe", json=transcribe_body(mime="text/plain")).status_code == 415
    assert client.post("/v1/scam/transcribe", json=transcribe_body(b"")).status_code == 422
    assert client.post("/v1/scam/transcribe", json={**transcribe_body(), "audio_b64": "not base64!"}).status_code == 422
    assert client.post("/v1/scam/transcribe", json={**transcribe_body(), "extra": 1}).status_code == 422  # strict contract
    assert gemini.calls == []


def _no_classifier(*args, **kwargs):
    raise genai_client.GenAIDisabled("off in this test")


def test_the_transcript_turn_feeds_the_scam_route_unchanged(client, gemini, monkeypatch, transcription_on):
    from app.contracts import Turn

    gemini.replies.append("আপনার একাউন্ট বন্ধ হয়ে যাবে, কোডটা বলুন")
    resp = client.post("/v1/scam/transcribe", json=transcribe_body(mime="audio/webm;codecs=opus"))
    assert resp.status_code == 200, resp.text
    turn = resp.json()
    assert set(turn) == {"speaker", "text", "ts"} and turn["speaker"] == "caller" and turn["ts"] > 0
    assert Turn(**turn).text == "আপনার একাউন্ট বন্ধ হয়ে যাবে, কোডটা বলুন"
    assert gemini.calls[0].contents[0].inline_data.mime_type == "audio/webm"
    monkeypatch.setattr(genai_client, "call", _no_classifier)  # the scam route keeps its own stub verdict; no real model
    monkeypatch.setattr(prerender, "after_turn", lambda *a, **k: None)  # nor Apa's pre-arm, which Gemini-on would also run
    scored = client.post("/v1/scam/turn", json={"session_id": "call-1", "turns": [turn]})
    assert scored.status_code == 200, scored.text


def test_the_app_can_keep_the_turn_on_the_call_clock(client, gemini, transcription_on):
    gemini.replies.append("হ্যালো")
    assert client.post("/v1/scam/transcribe", json=transcribe_body(ts=36.0)).json()["ts"] == 36.0


def test_a_failed_transcription_is_a_502_not_a_crash(client, monkeypatch, transcription_on):
    monkeypatch.setattr(genai_client, "select_backend", lambda settings: "vertex")

    def broken(model_id, contents, config, timeout_s=None):
        raise TimeoutError("slow")
    monkeypatch.setattr(speech, "_generate", broken)
    resp = client.post("/v1/scam/transcribe", json=transcribe_body())
    assert resp.status_code == 502 and "transcript-first" in resp.json()["detail"]


# --- WS /v1/scam/live -----------------------------------------------------------------------------------


class FakeLive:
    """Stands in for a Gemini Live session: every audio chunk it hears comes back as one finished transcription."""

    def __init__(self):
        import asyncio

        self.audio, self.closed, self.ended, self.heard = [], False, False, asyncio.Queue()

    async def send_audio(self, pcm):
        self.audio.append(pcm)
        await self.heard.put("কোডটা বলুন" if len(self.audio) == 1 else "একাউন্ট বন্ধ হয়ে যাবে")

    async def end_audio(self):
        """Like Gemini Live, the last utterance only comes back once the audio stream is declared over."""
        self.ended = True
        await self.heard.put("শেষ কথাটা বলুন")

    async def transcripts(self):
        while True:
            yield await self.heard.get()


@pytest.fixture
def live(client):
    """Live transcription switched on, with the Gemini Live client swapped for FakeLive."""
    from contextlib import asynccontextmanager

    from app.routers import speech as speech_router
    from app.settings import Settings, get_settings

    state = SimpleNamespace(sessions=[], settings={"live_transcription_enabled": True})

    @asynccontextmanager
    async def factory(settings):
        session = FakeLive()
        state.sessions.append(session)
        try:
            yield session
        finally:
            session.closed = True

    client.app.dependency_overrides[speech_router.live_factory] = lambda: factory
    client.app.dependency_overrides[get_settings] = lambda: Settings(**state.settings)
    yield state
    client.app.dependency_overrides.pop(speech_router.live_factory, None)
    client.app.dependency_overrides.pop(get_settings, None)


def _closed_with(ws) -> tuple[int, str]:
    from starlette.websockets import WebSocketDisconnect

    with pytest.raises(WebSocketDisconnect) as closed:
        ws.receive_json()
    return closed.value.code, closed.value.reason


def test_the_live_bridge_refuses_when_switched_off(client):
    from starlette.websockets import WebSocketDisconnect

    with pytest.raises(WebSocketDisconnect) as closed:
        with client.websocket_connect("/v1/scam/live?session_id=c1"):
            pass
    assert closed.value.code == 1008 and "transcript-first" in closed.value.reason


def test_the_live_bridge_refuses_when_gemini_is_off(client):
    from starlette.websockets import WebSocketDisconnect

    from app.settings import Settings, get_settings

    client.app.dependency_overrides[get_settings] = lambda: Settings(live_transcription_enabled=True, genai_enabled=False)
    try:
        with pytest.raises(WebSocketDisconnect) as closed:
            with client.websocket_connect("/v1/scam/live?session_id=c1"):
                pass
    finally:
        client.app.dependency_overrides.pop(get_settings, None)
    assert closed.value.code == 1013 and "transcript-first" in closed.value.reason


def test_finished_transcriptions_come_back_as_caller_turns(client, live):
    from app.contracts import Turn

    with client.websocket_connect("/v1/scam/live?session_id=c1") as ws:
        ws.send_bytes(b"\x01\x00" * 160)
        first = ws.receive_json()
        ws.send_bytes(b"\x02\x00" * 160)
        second = ws.receive_json()
        ws.send_text("end")
        assert ws.receive_json()["text"] == "শেষ কথাটা বলুন"  # flushed by end_audio
        assert _closed_with(ws)[0] == 1000
    assert set(first) == {"speaker", "text", "ts"} and Turn(**first).speaker == "caller"
    assert (first["text"], second["text"]) == ("কোডটা বলুন", "একাউন্ট বন্ধ হয়ে যাবে") and second["ts"] >= first["ts"] > 0
    session = live.sessions[0]
    assert session.audio == [b"\x01\x00" * 160, b"\x02\x00" * 160] and session.closed


def test_the_byte_limit_ends_the_session_before_the_extra_audio_is_sent(client, live):
    live.settings["live_max_bytes"] = 500
    with client.websocket_connect("/v1/scam/live?session_id=c1") as ws:
        ws.send_bytes(b"\x00" * 320)
        ws.receive_json()
        ws.send_bytes(b"\x00" * 320)
        code, reason = _closed_with(ws)
    assert code == 1009 and "byte" in reason
    assert live.sessions[0].audio == [b"\x00" * 320] and live.sessions[0].closed


def test_the_time_limit_ends_a_quiet_session(client, live):
    live.settings["live_max_session_s"] = 0.2
    with client.websocket_connect("/v1/scam/live?session_id=c1") as ws:
        code, reason = _closed_with(ws)
    assert code == 1008 and "time" in reason and live.sessions[0].closed


def _msg(text=None, finished=None, turn_complete=None, interim=None):
    tr = SimpleNamespace(text=text, finished=finished) if text is not None or finished else None
    return SimpleNamespace(server_content=SimpleNamespace(input_transcription=tr, turn_complete=turn_complete, generation_complete=None,
                                                          interim_input_transcription=interim), usage_metadata=None)


def _collect(messages, pause_s=1.0) -> list[str]:
    import asyncio

    async def stream():
        for m in messages:
            if isinstance(m, float):
                await asyncio.sleep(m)
            else:
                yield m

    async def run():
        return [t async for t in speech.final_transcripts(stream(), pause_s=pause_s)]
    return asyncio.run(run())


def test_fragments_join_into_one_turn_when_the_transcription_finishes():
    interim = SimpleNamespace(text="আপনার একা", finished=False)
    msgs = [_msg(interim=interim), _msg("আপনার "), _msg("একাউন্ট  বন্ধ "), _msg("হয়ে যাবে", finished=True), _msg("কোডটা"), _msg(turn_complete=True)]
    assert _collect(msgs) == ["আপনার একাউন্ট বন্ধ হয়ে যাবে", "কোডটা"]


def test_a_pause_or_the_end_of_the_stream_also_closes_a_turn():
    assert _collect([_msg("হ্যালো"), 0.15, _msg("কোডটা বলুন")], pause_s=0.05) == ["হ্যালো", "কোডটা বলুন"]
    assert _collect([_msg(turn_complete=True), _msg("   ")]) == []


def test_the_live_session_asks_for_bangla_transcription_with_the_vocabulary():
    config = speech.live_config()
    assert config.input_audio_transcription.language_codes == ["bn-BD"]
    assert config.input_audio_transcription.custom_vocabulary == list(speech.SCAM_VOCABULARY)
    assert "silent" in str(config.system_instruction).lower()
    assert genai_client.roles()[speech.LIVE_ROLE].id == "gemini-3.8-live"


# --- the 20-utterance smoke test (eval/transcription_smoke.py) --------------------------------------------


def _result(text: str, cost: float = 0.001) -> genai_client.CallResult:
    return genai_client.CallResult(text=text, parsed=None, model_id="gemini-test", tokens_in=500, tokens_out=40, cost_usd=cost, latency_ms=5.0)


@needs_smoke_set
def test_the_smoke_set_has_twenty_utterances_whose_key_terms_are_in_their_own_words():
    from eval import transcription_smoke as smoke

    rows = smoke.load_utterances()
    assert len(rows) == 20 and len({r["id"] for r in rows}) == 20
    for r in rows:
        assert r["text_bn"] and r["key_terms"] and r["label"] in {"scam", "benign"}, r["id"]
        assert smoke.missing_terms(r["key_terms"], r["text_bn"]) == [], r["id"]
    scams = {r["archetype"] for r in rows if r["label"] == "scam"}
    assert scams == {"fake_customer_care", "otp_pin_harvest", "lottery_prize", "wrong_send_refund", "job_loan_fee", "relative_impersonation"}
    assert 3 <= sum(r["label"] == "benign" for r in rows) <= 6


def test_normalisation_is_bangla_aware():
    from eval.transcription_smoke import normalise

    assert normalise("১,০০০ টাকা।") == normalise("1000 টাকা") == "1000 টাকা"
    assert normalise("অ্যাকাউন্ট") == normalise("একাউন্ট")
    assert normalise("OTP টা দিন") == normalise("ওটিপি টা দিন")
    assert normalise("Send Money করুন!") == normalise("সেন্ড মানি করুন")
    assert normalise("কো‌ড") == normalise("কোড") and "‌" not in normalise("কো‌ড")
    assert normalise("দীর্ঘ") == normalise("দির্ঘ")


def test_key_terms_survive_suffixes_spacing_and_script():
    from eval.transcription_smoke import missing_terms

    heard = "আপনার অ্যাকাউন্টটা আজই বন্ধ হবে, OTPটা আর কোডটা বলুন, ক্যাশআউট করুন"
    assert missing_terms(["একাউন্ট বন্ধ", "ওটিপি", "কোড", "ক্যাশ আউট"], heard) == []
    assert missing_terms(["পিন", "লটারি|lottery"], heard) == ["পিন", "লটারি|lottery"]
    assert missing_terms(["লটারি|lottery"], "you won the lottery") == []
    assert missing_terms(["একাউন্ট বন্ধ"], "বন্ধ করবেন না, একাউন্ট নম্বর দিন") == ["একাউন্ট বন্ধ"]  # wrong order


def test_word_accuracy_is_one_minus_the_word_error_rate():
    from eval.transcription_smoke import word_accuracy, word_errors

    assert word_accuracy("কোডটা এখনই বলুন", "কোডটা এখনই বলুন।") == 1.0
    assert word_accuracy("আপনার কোডটা এখনই বলুন", "আপনার কোডটা তাড়াতাড়ি বলুন") == 0.75
    assert word_accuracy("কোডটা বলুন", "") == 0.0
    assert word_accuracy("কোড", "এক দুই তিন চার কোড") == 0.0  # insertions never push it below zero
    assert word_errors("a b c", "a c") == (1, 3)


def test_sixteen_of_twenty_is_the_pass_mark_and_only_recorded_speech_enables_live():
    from eval.transcription_smoke import chosen_path, passes

    assert passes(16, 20) and passes(20, 20)
    assert not passes(15, 20) and not passes(16, 16)  # a partial run cannot pass
    assert chosen_path(passed=True, source="recorded_live") == "live"  # on Gemini Live, the bridge's model (--mode live)
    assert chosen_path(passed=True, source="tts_phone") == chosen_path(passed=True, source="tts_clean") == "transcript_first"  # TTS is provisional
    assert chosen_path(passed=False, source="recorded") == "transcript_first"


def test_scoring_counts_utterances_with_every_key_term_and_pools_word_accuracy():
    from eval.transcription_smoke import score

    rows = [{"id": "u1", "text_bn": "কোডটা এখনই বলুন", "key_terms": ["কোড"]},
            {"id": "u2", "text_bn": "আপনার একাউন্ট বন্ধ হবে", "key_terms": ["একাউন্ট বন্ধ"]},
            {"id": "u3", "text_bn": "পিন বলুন", "key_terms": ["পিন"]}]
    s = score(rows, {"u1": "কোডটা এখনই বলুন", "u2": "আপনার একাউন্ট খোলা"})
    assert (s["recognised"], s["of"], s["passed"]) == (1, 3, False)
    assert [i["missing_terms"] for i in s["items"]] == [[], ["একাউন্ট বন্ধ"], ["পিন"]]
    assert s["word_accuracy"] == round(1 - 4 / 9, 3)  # 0 + 2 + 2 errors over 3 + 4 + 2 reference words


def test_a_run_transcribes_each_audio_file_inside_the_spend_cap(tmp_path):
    from eval import transcription_smoke as smoke
    from eval.budget import SpendLedger

    (tmp_path / "u1.wav").write_bytes(WAV)
    (tmp_path / "u3.m4a").write_bytes(b"m4a")
    rows = [{"id": "u1", "text_bn": "কোডটা এখনই বলুন", "key_terms": ["কোড"]}, {"id": "u2", "text_bn": "পিন বলুন", "key_terms": ["পিন"]},
            {"id": "u3", "text_bn": "পিন বলুন", "key_terms": ["পিন"]}]
    calls = []

    def fake(audio, mime):
        calls.append((audio, mime))
        if mime == "audio/mp4":
            raise RuntimeError("quota")
        return _result("কোডটা এখনই বলুন")
    ledger = SpendLedger(tmp_path / "spend.json", cap_usd=1.0)
    out = smoke.run(rows, tmp_path, "recorded", fake, ledger)
    assert calls == [(WAV, "audio/wav"), (b"m4a", "audio/mp4")] and ledger.spent() == pytest.approx(0.001)
    assert (out["recognised"], out["of"], out["passed"], out["path"], out["provisional"]) == (1, 3, False, "transcript_first", False)
    assert out["items"][1]["error"] == "no audio file" and out["items"][2]["error"] == "RuntimeError"
    assert out["items"][2]["code"] is None and out["items"][2]["ms"] >= 0  # a failed call keeps its error code and time
    assert out["model"] == "gemini-test" and out["cost_usd"] == pytest.approx(0.001)


def test_the_speech_block_joins_intervention_json_without_touching_the_rest(tmp_path):
    import json

    from eval import transcription_smoke as smoke

    path = tmp_path / "intervention.json"
    path.write_text(json.dumps({"n": 50, "metrics": {"precision": 0.935}, "speech_smoke": {"old": True}, "gates": {}}), encoding="utf-8")
    phone = smoke.speech_block({"source": "tts_phone", "passed": True, "recognised": 18, "of": 20, "word_accuracy": 0.9,
                                "path": "transcript_first", "provisional": True, "items": []})
    assert set(phone) == {"source", "passed", "recognised", "of", "word_accuracy", "path", "provisional"}
    smoke.merge_speech_block(path, phone)  # an old flat block is replaced
    data = json.loads(path.read_text(encoding="utf-8"))
    assert list(data) == ["n", "metrics", "speech_smoke", "gates"] and data["metrics"] == {"precision": 0.935}
    assert data["speech_smoke"] == {"tts_phone": phone}
    clean = {**phone, "source": "tts_clean", "recognised": 19}
    smoke.merge_speech_block(path, clean)  # each source keeps its own block
    assert json.loads(path.read_text(encoding="utf-8"))["speech_smoke"] == {"tts_phone": phone, "tts_clean": clean}
    fresh = tmp_path / "missing.json"
    smoke.merge_speech_block(fresh, phone)
    assert json.loads(fresh.read_text(encoding="utf-8")) == {"speech_smoke": {"tts_phone": phone}}


@needs_smoke_set
def test_a_dry_run_calls_nothing_and_writes_nothing(tmp_path, monkeypatch, capsys):
    from eval import transcription_smoke as smoke

    def no_calls(*args, **kwargs):
        raise AssertionError("a dry run must not call Gemini")
    monkeypatch.setattr(speech, "transcribe_call", no_calls)
    monkeypatch.setattr(smoke, "SpendLedger", no_calls)
    monkeypatch.setattr(smoke, "RESULTS", tmp_path / "results")
    (tmp_path / "su01.wav").write_bytes(WAV)
    smoke.main(["--dry-run", "--audio-dir", str(tmp_path)])
    out = capsys.readouterr().out
    assert "dry run" in out and "1 of 20" in out
    assert not (tmp_path / "results").exists()


@needs_smoke_set
def test_a_full_run_writes_its_results_and_the_intervention_block(tmp_path, monkeypatch):
    import json

    from eval import budget, transcription_smoke as smoke

    rows = smoke.load_utterances()
    for r in rows:
        (tmp_path / f"{r['id']}.wav").write_bytes(r["id"].encode())
    reference = {r["id"]: r["text_bn"] for r in rows}
    misheard = {rows[0]["id"], rows[1]["id"], rows[2]["id"]}
    monkeypatch.setattr(speech, "transcribe_call",
                        lambda audio, mime, settings: _result("হ্যালো" if audio.decode() in misheard else reference[audio.decode()]))
    monkeypatch.setattr(smoke, "SpendLedger", lambda: budget.SpendLedger(tmp_path / "spend.json", cap_usd=1.0))
    results = tmp_path / "results"
    results.mkdir()
    (results / "intervention.json").write_text(json.dumps({"n": 50}), encoding="utf-8")
    monkeypatch.setattr(smoke, "RESULTS", results)

    smoke.main(["--audio-dir", str(tmp_path), "--source", "tts_phone", "--limit", "5"])  # partial: own file only
    assert json.loads((results / "intervention.json").read_text(encoding="utf-8")) == {"n": 50}
    smoke.main(["--audio-dir", str(tmp_path), "--source", "tts_phone"])
    out = json.loads((results / "transcription_smoke_tts_phone.json").read_text(encoding="utf-8"))
    assert (out["recognised"], out["of"], out["passed"], out["provisional"], out["path"]) == (17, 20, True, True, "transcript_first")
    merged = json.loads((results / "intervention.json").read_text(encoding="utf-8"))
    assert merged["n"] == 50 and merged["speech_smoke"]["tts_phone"]["recognised"] == 17


def test_a_gemini_server_error_on_one_recording_is_retried_not_lost(monkeypatch):
    """Two of twenty smoke utterances came back as a 5xx with no retry; transcription now goes through genai_client's retry."""
    from types import SimpleNamespace

    from google.genai import errors

    outcomes = [errors.APIError(500, {"error": {"message": "internal"}}),
                SimpleNamespace(text="কোডটা বলুন", usage_metadata=SimpleNamespace(prompt_token_count=40, candidates_token_count=5, thoughts_token_count=0))]
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
    result = speech.transcribe_call(WAV, "audio/wav", speech.get_settings())
    assert result.text == "কোডটা বলুন" and len(calls) == 2


def test_transcription_sends_the_generous_server_deadline(gemini):
    gemini.replies.append("কোডটা বলুন")
    speech.transcribe_call(WAV, "audio/wav", speech.get_settings())
    options = gemini.calls[0].config.http_options
    assert options.headers["X-Server-Timeout"] == str(genai_client.SERVER_TIMEOUT_S)
    assert options.timeout == int(speech.get_settings().transcribe_timeout_s * 1000)


def test_the_live_bridge_opens_on_its_own_regional_client(monkeypatch):
    """gemini-3.8-live is not served at location global (Live answered 1008); it opens in us-central1. Everything else stays global."""
    import asyncio
    from contextlib import asynccontextmanager

    from app.settings import Settings

    assert Settings().live_location == "us-central1" and Settings().genai_location == "global"
    locations = []

    @asynccontextmanager
    async def connect(model, config):
        yield SimpleNamespace()

    def client(location=None):
        locations.append(location)
        return SimpleNamespace(aio=SimpleNamespace(live=SimpleNamespace(connect=connect)))
    monkeypatch.setattr(genai_client, "_client", client)
    monkeypatch.setattr(genai_client, "select_backend", lambda settings: "vertex")

    async def open_once():
        async with speech.gemini_live(Settings()):
            pass
    asyncio.run(open_once())
    assert locations == ["us-central1"]


def test_ending_the_stream_flushes_the_last_utterance_before_closing(client, live):
    """The live smoke lost its only turn: on "end" the bridge cancelled the reader before Gemini Live's final
    transcription (about 3 s later) arrived, and never sent audio_stream_end to ask for it."""
    with client.websocket_connect("/v1/scam/live?session_id=c-end") as ws:
        ws.send_bytes(b"\x01\x00" * 160)
        assert ws.receive_json()["text"] == "কোডটা বলুন"
        ws.send_text("end")
        assert ws.receive_json()["text"] == "শেষ কথাটা বলুন"
        assert _closed_with(ws)[0] == 1000
    assert live.sessions[0].ended and live.sessions[0].closed


# --- the smoke test on the live model (eval/transcription_smoke.py --mode live) ---------------------------


def _tone_wav(rate: int, seconds: float, channels: int = 1) -> bytes:
    """A 16-bit PCM WAV of a 440 Hz tone at about half scale."""
    import io
    import wave

    import numpy as np

    t = np.arange(int(rate * seconds)) / rate
    x = np.round(16000 * np.sin(2 * np.pi * 440 * t)).astype("<i2")
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(channels)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(np.repeat(x, channels).tobytes())
    return buf.getvalue()


class SmokeLive:
    """A Gemini Live session for the smoke harness: part of the utterance comes back while audio streams,
    the rest only after end_audio, like Live. after_end=None never answers after the end (Live went quiet)."""

    def __init__(self, during: str, after_end: str | None, fail: Exception | None = None):
        import asyncio

        self.audio, self.ended, self.closed, self.fail = [], False, False, fail
        self.during, self.after_end, self.heard = during, after_end, asyncio.Queue()
        self.cost_usd = 0.0005

    async def send_audio(self, pcm):
        self.audio.append(pcm)
        if len(self.audio) == 1 and self.during:
            await self.heard.put(self.during)

    async def end_audio(self):
        self.ended = True
        if self.after_end is not None:
            await self.heard.put(self.after_end)
            await self.heard.put(None)  # this fake's stream ends after the last turn; real Live just goes quiet

    async def transcripts(self):
        while True:
            if self.fail is not None and self.ended:
                raise self.fail
            text = await self.heard.get()
            if text is None:
                return
            yield text


def _smoke_live_factory(answers):
    """answers: one (during, after_end[, fail]) per session, in the order the harness opens them."""
    from contextlib import asynccontextmanager

    state = SimpleNamespace(sessions=[], settings=[])

    @asynccontextmanager
    async def factory(settings):
        session = SmokeLive(*answers[len(state.sessions)])
        state.sessions.append(session)
        state.settings.append(settings)
        try:
            yield session
        finally:
            session.closed = True
    return factory, state


def test_live_mode_resamples_each_recording_to_16k_16bit_mono_pcm():
    import numpy as np

    from eval import transcription_smoke as smoke

    for rate, channels in ((8000, 1), (24000, 1), (16000, 1), (44100, 2)):
        pcm = smoke.pcm16k(_tone_wav(rate, 0.5, channels))
        x = np.frombuffer(pcm, dtype="<i2")
        assert len(x) == 8000, (rate, channels)  # half a second at 16 kHz, one channel
        assert 14000 < np.abs(x[500:-500]).max() < 17000, (rate, channels)  # the tone keeps its level
    with pytest.raises(smoke.LiveNeedsWav):
        smoke.pcm16k(b"OggS" + b"\x00" * 64)


def test_live_mode_streams_pcm_through_the_bridge_code_ends_the_audio_and_joins_the_turns():
    import asyncio

    from app.settings import Settings
    from eval import transcription_smoke as smoke

    factory, state = _smoke_live_factory([("কোডটা", "এখনই বলুন")])
    result = asyncio.run(smoke.live_transcribe(_tone_wav(8000, 1.0), "audio/wav", Settings(), factory, pace=0))
    session = state.sessions[0]
    assert result.text == "কোডটা এখনই বলুন" and result.cost_usd == pytest.approx(0.0005)
    assert session.ended and session.closed  # end_audio asked Live for the last turn, then the session closed
    assert sum(map(len, session.audio)) == 2 * 16000 and max(map(len, session.audio)) <= smoke.LIVE_CHUNK_BYTES  # 1 s of 16 kHz 16-bit
    assert state.settings[0].live_location == "us-central1"


def test_live_mode_waits_for_the_last_turn_only_within_live_drain_s():
    import asyncio
    import time

    from app.settings import Settings
    from eval import transcription_smoke as smoke

    factory, _ = _smoke_live_factory([("কোডটা", None)])  # Live never answers after the end
    started = time.monotonic()
    result = asyncio.run(smoke.live_transcribe(_tone_wav(16000, 0.2), "audio/wav", Settings(live_drain_s=0.3), factory, pace=0))
    assert result.text == "কোডটা" and 0.25 < time.monotonic() - started < 2.0

    factory, _ = _smoke_live_factory([("", "x", RuntimeError("live broke"))])
    with pytest.raises(RuntimeError):  # a broken session is a failed utterance, not an empty transcript
        asyncio.run(smoke.live_transcribe(_tone_wav(16000, 0.2), "audio/wav", Settings(live_drain_s=0.3), factory, pace=0))


@needs_smoke_set
def test_a_live_mode_run_scores_like_file_mode_under_its_own_provisional_source(tmp_path, monkeypatch):
    import json

    from eval import budget, transcription_smoke as smoke

    rows = smoke.load_utterances()
    for r in rows:
        (tmp_path / f"{r['id']}.wav").write_bytes(_tone_wav(8000, 0.3))
    (tmp_path / f"{rows[3]['id']}.wav").unlink()
    (tmp_path / f"{rows[3]['id']}.ogg").write_bytes(b"OggS" + b"\x00" * 64)  # Live gets PCM; only WAV can be resampled here
    answers = []
    for n, r in enumerate(rows):
        words = r["text_bn"].split()
        if n == 3:
            continue
        answers.append(("হ্যালো", "") if n in (0, 1) else (" ".join(words[:2]), " ".join(words[2:])))
    factory, state = _smoke_live_factory(answers)
    monkeypatch.setattr(speech, "gemini_live", factory)
    monkeypatch.setattr(speech, "transcribe_call", lambda *a, **k: pytest.fail("live mode must not use file-mode transcription"))
    monkeypatch.setattr(smoke, "SpendLedger", lambda: budget.SpendLedger(tmp_path / "spend.json", cap_usd=1.0))
    results = tmp_path / "results"
    results.mkdir()
    file_block = {"source": "tts_phone", "recognised": 18}
    (results / "intervention.json").write_text(json.dumps({"n": 50, "speech_smoke": {"tts_phone": file_block}}), encoding="utf-8")
    monkeypatch.setattr(smoke, "RESULTS", results)

    smoke.main(["--mode", "live", "--source", "tts_phone", "--audio-dir", str(tmp_path), "--live-pace", "0"])
    out = json.loads((results / "transcription_smoke_tts_phone_live.json").read_text(encoding="utf-8"))
    assert (out["source"], out["mode"], out["provisional"], out["path"]) == ("tts_phone_live", "live", True, "transcript_first")
    assert (out["recognised"], out["of"], out["passed"]) == (17, 20, True)
    assert out["items"][3]["error"] == "LiveNeedsWav" and out["items"][5]["transcript"] == rows[5]["text_bn"]
    assert len(state.sessions) == 19 and all(s.ended and s.closed for s in state.sessions)
    assert out["cost_usd"] == pytest.approx(19 * 0.0005)
    merged = json.loads((results / "intervention.json").read_text(encoding="utf-8"))["speech_smoke"]
    assert merged["tts_phone"] == file_block and merged["tts_phone_live"]["recognised"] == 17  # file mode's entry stays
    assert not (results / "transcription_smoke_tts_phone.json").exists()


def test_only_a_live_mode_pass_on_recorded_speech_enables_the_live_path(tmp_path):
    """The live bridge runs Gemini Live, not the file-mode model: a file-mode pass no longer enables it."""
    from eval import transcription_smoke as smoke
    from eval.budget import SpendLedger

    assert smoke.chosen_path(passed=True, source="recorded_live") == "live"
    assert smoke.chosen_path(passed=True, source="recorded") == "transcript_first"
    assert smoke.chosen_path(passed=True, source="tts_phone_live") == "transcript_first"
    assert smoke.chosen_path(passed=False, source="recorded_live") == "transcript_first"
    rows = [{"id": "u1", "text_bn": "কোডটা বলুন", "key_terms": ["কোড"]}]
    (tmp_path / "u1.wav").write_bytes(WAV)
    out = smoke.run(rows, tmp_path, "recorded_live", lambda audio, mime: _result("কোডটা বলুন"), SpendLedger(tmp_path / "s.json", cap_usd=1.0))
    assert out["provisional"] is False and out["mode"] == "live" and "Gemini Live" in out["note"]  # recorded people, on the live model
    assert "--mode live" in smoke._note(passed=True, source="recorded")  # a file-mode pass says what is still needed


@needs_smoke_set
def test_a_live_mode_dry_run_opens_no_session_and_writes_nothing(tmp_path, monkeypatch, capsys):
    from eval import transcription_smoke as smoke

    def no_calls(*args, **kwargs):
        raise AssertionError("a dry run must not open Gemini Live")
    monkeypatch.setattr(speech, "gemini_live", no_calls)
    monkeypatch.setattr(smoke, "SpendLedger", no_calls)
    monkeypatch.setattr(smoke, "RESULTS", tmp_path / "results")
    (tmp_path / "su01.wav").write_bytes(_tone_wav(8000, 0.1))
    (tmp_path / "su02.ogg").write_bytes(b"OggS")
    smoke.main(["--mode", "live", "--dry-run", "--audio-dir", str(tmp_path)])
    out = capsys.readouterr().out
    assert "dry run" in out and "1 of 20" in out and "Gemini Live" in out and "us-central1" in out and "su02" in out
    assert not (tmp_path / "results").exists()
