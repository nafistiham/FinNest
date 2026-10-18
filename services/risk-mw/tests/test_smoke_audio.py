"""scripts/make_smoke_audio.py: the provisional speech-smoke set in 20 Gemini TTS voices, clean and phone-band (paid; faked here)."""

import io
import json
import wave
from collections import defaultdict
from types import SimpleNamespace

import numpy as np
import pytest

from app import genai_client
from eval import transcription_smoke as smoke
from eval.budget import SpendLedger
from scripts import make_smoke_audio as m

# The speech smoke set (eval/speech_smoke/utterances.jsonl and its audio) is not in the public
# repository. Speech to text is off by default, so these tests skip when the set is absent.
needs_smoke_set = pytest.mark.skipif(
    not smoke.UTTERANCES.exists(),
    reason="eval/speech_smoke/utterances.jsonl is not present (the speech smoke set is not published)",
)

PCM_1S = (np.sin(2 * np.pi * 1000 * np.arange(24000) / 24000) * 8000).astype("<i2").tobytes()  # 1 kHz, one second at 24 kHz


def _tts(pcm: bytes = PCM_1S):
    part = SimpleNamespace(inline_data=SimpleNamespace(data=pcm))
    return SimpleNamespace(candidates=[SimpleNamespace(content=SimpleNamespace(parts=[part]))],
                           usage_metadata=SimpleNamespace(prompt_token_count=30, candidates_token_count=25, thoughts_token_count=0))


def _wav(path):
    with wave.open(io.BytesIO(path.read_bytes())) as w:
        return w.getframerate(), np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(float)


def _tone_level(x: np.ndarray, rate: int, hz: float) -> float:
    spectrum = np.abs(np.fft.rfft(x))
    return float(spectrum[int(round(hz * len(x) / rate))])


@needs_smoke_set
def test_ten_male_and_ten_female_voices_each_used_once():
    cast = m.cast(smoke.load_utterances())
    genders = [g for _, g in cast.values()]
    voices = [v for v, _ in cast.values()]
    assert len(cast) == 20 and genders.count("male") == 10 and genders.count("female") == 10 and len(set(voices)) == 20
    assert set(m.MALE_VOICES) == {v for v, g in cast.values() if g == "male"}
    assert set(m.FEMALE_VOICES) == {v for v, g in cast.values() if g == "female"}


@needs_smoke_set
def test_no_archetype_is_one_gender_and_the_benign_look_alikes_have_both():
    rows = smoke.load_utterances()
    cast = m.cast(rows)
    by_archetype, benign = defaultdict(set), set()
    for row in rows:
        by_archetype[row["archetype"]].add(cast[row["id"]][1])
        if row["label"] == "benign":
            benign.add(cast[row["id"]][1])
    assert all(genders == {"male", "female"} for arch, genders in by_archetype.items() if sum(r["archetype"] == arch for r in rows) > 1)
    assert benign == {"male", "female"}


@needs_smoke_set
def test_each_line_sounds_like_a_phone_call_scams_pressing_and_benign_calm():
    rows = smoke.load_utterances()
    scam = next(r for r in rows if r["label"] == "scam")
    benign = next(r for r in rows if r["label"] == "benign")
    for row in (scam, benign):
        style = m.style_for(row).lower()
        assert "phone call" in style and "dhaka" in style and "newsreader" in style
    assert "hurried" in m.style_for(scam).lower() and "hesitation" in m.style_for(scam).lower()
    assert "calm" in m.style_for(benign).lower() and "hurried" not in m.style_for(benign).lower()
    assert len({m.style_for(r) for r in rows}) > 2  # each archetype adds its own mood


def test_the_phone_band_copy_is_8_khz_band_limited_with_light_noise():
    low = (np.sin(2 * np.pi * 120 * np.arange(24000) / 24000) * 8000).astype("<i2")
    mixed = (np.frombuffer(PCM_1S, dtype="<i2").astype(int) + low).clip(-32768, 32767).astype("<i2").tobytes()
    out = np.frombuffer(m.phone_band(mixed, seed=1), dtype="<i2").astype(float)
    assert len(out) == 8000
    assert _tone_level(out, 8000, 120) < 0.1 * _tone_level(out, 8000, 1000)  # below 300 Hz is cut, speech band kept
    assert m.phone_band(mixed, seed=1) == m.phone_band(mixed, seed=1) != m.phone_band(mixed, seed=2)
    hiss = np.frombuffer(m.phone_band(b"\x00\x00" * 24000, seed=1), dtype="<i2")
    assert 0 < np.abs(hiss).max() < 50  # light noise, even on silence


@needs_smoke_set
def test_a_render_writes_clean_and_phone_copies_and_an_index_with_voice_and_gender(tmp_path):
    rows = smoke.load_utterances()[:2]
    calls, sleeps = [], []

    def synth(model_id, text, voice, style):
        calls.append((model_id, text, voice, style))
        return _tts()
    clean, phone = tmp_path / "clean", tmp_path / "phone"
    ledger = SpendLedger(tmp_path / "spend.json", cap_usd=1.0)
    done = m.render(m.jobs(rows, m.cast(rows), clean, phone), ledger, synth=synth, sleep=sleeps.append)
    assert sleeps == [m.PACE_S] and [c[2] for c in calls] == [m.MALE_VOICES[0], m.FEMALE_VOICES[0]]
    assert calls[0][0] == genai_client.roles()["tts"].id and calls[0][1] == rows[0]["text_bn"] and calls[0][3] == m.style_for(rows[0])
    assert _wav(clean / "su01.wav")[0] == 24000 and _wav(phone / "su01.wav")[0] == 8000
    assert [(d["id"], d["voice"], d["gender"]) for d in done] == [("su01", m.MALE_VOICES[0], "male"), ("su02", m.FEMALE_VOICES[0], "female")]
    assert done[0]["clean"] == "clean/su01.wav" and done[0]["phone"] == "phone/su01.wav" and done[0]["seconds"] == 1.0
    assert ledger.spent() == pytest.approx(sum(d["cost_usd"] for d in done)) and ledger.spent() > 0


@needs_smoke_set
def test_rendering_backs_off_on_a_429_and_a_quota_that_never_clears_stops_the_run(tmp_path):
    from google.genai import errors

    rows = smoke.load_utterances()[:1]
    replies = [errors.APIError(429, {"error": {"message": "quota"}}), _tts()]

    def synth(model_id, text, voice, style):
        item = replies.pop(0)
        if isinstance(item, Exception):
            raise item
        return item
    sleeps = []
    ledger = SpendLedger(tmp_path / "spend.json", cap_usd=1.0)
    m.render(m.jobs(rows, m.cast(rows), tmp_path / "c", tmp_path / "p"), ledger, synth=synth, sleep=sleeps.append)
    assert sleeps == [m.RETRY_WAITS[0]]

    def always_429(model_id, text, voice, style):
        raise errors.APIError(429, {"error": {"message": "quota"}})
    sleeps.clear()
    with pytest.raises(errors.APIError):
        m.render(m.jobs(rows, m.cast(rows), tmp_path / "c2", tmp_path / "p2"), ledger, synth=always_429, sleep=sleeps.append)
    assert sleeps == list(m.RETRY_WAITS) and not (tmp_path / "c2" / "su01.wav").exists()


def test_synthetic_audio_stays_out_of_the_recorded_folder():
    assert smoke.AUDIO_DIRS["tts_clean"] == m.OUT_CLEAN and smoke.AUDIO_DIRS["tts_phone"] == m.OUT_PHONE
    assert m.OUT_CLEAN.parent == m.OUT_PHONE.parent == m.TTS_DIR != smoke.AUDIO_DIRS["recorded"]
    assert smoke.AUDIO_DIRS["recorded"] not in (m.OUT_CLEAN, m.OUT_PHONE, *m.OUT_CLEAN.parents)


@needs_smoke_set
def test_the_dry_run_lists_the_cast_and_calls_nothing(tmp_path, monkeypatch, capsys):
    def no_calls(*args, **kwargs):
        raise AssertionError("a dry run must not call Gemini")
    monkeypatch.setattr(m, "TTS_DIR", tmp_path)
    monkeypatch.setattr(m, "OUT_CLEAN", tmp_path / "clean")
    monkeypatch.setattr(m, "OUT_PHONE", tmp_path / "phone")
    monkeypatch.setattr(m, "_synthesise", no_calls)
    monkeypatch.setattr(m, "SpendLedger", no_calls)
    m.main(["--dry-run"])
    out = capsys.readouterr().out
    assert "dry run" in out and "20 of 20" in out and "10 male" in out and "10 female" in out and "Charon" in out and "Kore" in out
    assert not (tmp_path / "clean").exists()


@needs_smoke_set
def test_a_full_render_writes_a_provisional_index_and_phone_only_rebuilds_without_calls(tmp_path, monkeypatch):
    monkeypatch.setattr(m, "TTS_DIR", tmp_path)
    monkeypatch.setattr(m, "OUT_CLEAN", tmp_path / "clean")
    monkeypatch.setattr(m, "OUT_PHONE", tmp_path / "phone")
    monkeypatch.setattr(m, "PACE_S", 0.0)
    monkeypatch.setattr(m, "_synthesise", lambda model_id, text, voice, style: _tts())
    monkeypatch.setattr(m, "SpendLedger", lambda: SpendLedger(tmp_path / "spend.json", cap_usd=1.0))
    monkeypatch.setattr(genai_client, "select_backend", lambda settings: "vertex")
    m.main(["--limit", "2"])
    index = json.loads((tmp_path / "index.json").read_text(encoding="utf-8"))
    assert index["provisional"] is True and "provisional" in index["note"] and index["model"] == genai_client.roles()["tts"].id
    assert index["phone"] == {"rate": 8000, "band_hz": [300.0, 3400.0], "snr_db": m.PHONE_SNR_DB}
    assert {k: (v["voice"], v["gender"]) for k, v in index["files"].items()} == {"su01": (m.MALE_VOICES[0], "male"),
                                                                                 "su02": (m.FEMALE_VOICES[0], "female")}
    (tmp_path / "phone" / "su01.wav").unlink()

    def no_calls(*args, **kwargs):
        raise AssertionError("--phone-only must not call Gemini")
    monkeypatch.setattr(m, "_synthesise", no_calls)
    m.main(["--phone-only"])
    assert _wav(tmp_path / "phone" / "su01.wav")[0] == 8000
