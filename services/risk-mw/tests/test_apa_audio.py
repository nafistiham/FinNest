"""Apa voice auditions: a validated line in every style and sample voice, as WAV with an index. No stored lines."""

import io
import sys
import wave
from pathlib import Path

import pytest

from scripts import render_apa_audio as r

LINE = "রহিমা, একটু থামুন — কোডটা কাউকে বলবেন না।"  # test data (non-native draft)


def test_there_are_no_stored_lines_to_render():
    assert not any(hasattr(r, name) for name in ("lines", "full_jobs", "OUT"))


def test_pcm_becomes_a_playable_wav():
    pcm = b"\x00\x01" * 24000  # one second of 16-bit mono at 24 kHz
    data = r.pcm_to_wav(pcm)
    with wave.open(io.BytesIO(data)) as w:
        assert (w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()) == (1, 2, 24000, 24000)


def test_the_tts_model_comes_from_models_yaml():
    from app import genai_client, tts
    role = genai_client.roles()["tts"]
    assert role.id == tts.engines()[0].id  # the ids are pinned once, in test_tts_engines.py


def test_the_default_style_is_urgent_and_quick_not_slow():
    style = r.STYLES[r.DEFAULT_STYLE].lower()
    assert r.DEFAULT_STYLE == "urgent" and "urgent" in style and "quick" in style and "slow" not in style
    assert {"urgent", "alarm", "firm_calm"} <= set(r.STYLES)


def test_a_validated_line_is_auditioned_in_every_style_and_voice(tmp_path):
    jobs = r.sample_jobs(LINE, "otp-a", tmp_path, ("Kore", "Zephyr"), ("urgent", "alarm"))
    assert [j[:2] for j in jobs] == [("urgent", "Kore"), ("urgent", "Zephyr"), ("alarm", "Kore"), ("alarm", "Zephyr")]
    assert jobs[0][2] == tmp_path / "otp-a" / "urgent-Kore.wav" and jobs[0][3] == LINE


def test_only_a_line_apa_may_speak_is_rendered(tmp_path):
    with pytest.raises(SystemExit, match="speakable"):
        r.sample_jobs("Call 01700-000000 now.", "bad", tmp_path, ("Kore",), ("urgent",))


def test_without_a_line_there_is_nothing_to_render(monkeypatch):
    monkeypatch.setattr(sys, "argv", ["render_apa_audio.py", "--dry-run"])
    with pytest.raises(SystemExit, match="no stored lines"):
        r.main()


def test_the_chosen_voice_is_still_sulafat():
    """The team picked the urgent-Sulafat sample; live TTS speaks in it (Settings.tts_voice)."""
    assert (r.DEFAULT_VOICE, r.DEFAULT_STYLE) == ("Sulafat", "urgent")


# --- OGG conversion (no model call) ---------------------------------------------------------------------------------


def test_ogg_codec_is_opus_when_libsndfile_has_it_else_vorbis():
    assert r.ogg_subtype(lambda subtype: True) == "OPUS"
    assert r.ogg_subtype(lambda subtype: subtype == "VORBIS") == "VORBIS"
    with pytest.raises(RuntimeError, match="neither OGG Opus nor OGG Vorbis"):
        r.ogg_subtype(lambda subtype: False)


class FakeSoundFile:
    """Stands in for the soundfile module: this libsndfile has Vorbis but no Opus."""

    def __init__(self):
        self.written = []

    def read(self, path):
        with wave.open(str(path)) as w:
            return [0.0] * w.getnframes(), w.getframerate()

    def write(self, file, data, samplerate, format=None, subtype=None):
        if subtype != "VORBIS":
            raise RuntimeError("Error opening <_io.BytesIO>: Format not recognised.")
        if isinstance(file, (str, Path)):
            Path(file).write_bytes(b"OggS")
            self.written.append((Path(file).name, len(data), samplerate, format, subtype))


def test_ogg_mode_converts_the_wavs_in_a_folder_without_a_model_call(tmp_path, monkeypatch):
    for name in ("apa_scam_conversation", "apa_generic_caution"):
        (tmp_path / f"{name}.wav").write_bytes(r.pcm_to_wav(b"\x00\x00" * 2400))
    (tmp_path / "index.json").write_text("{}", encoding="utf-8")
    fake = FakeSoundFile()
    monkeypatch.setitem(sys.modules, "soundfile", fake)
    monkeypatch.setitem(sys.modules, "google.genai", None)  # any model client import would fail
    monkeypatch.setattr(r, "render", lambda jobs: pytest.fail("--ogg must not render"))
    monkeypatch.setattr(sys, "argv", ["render_apa_audio.py", "--ogg", str(tmp_path)])
    r.main()
    assert sorted(fake.written) == [("apa_generic_caution.ogg", 2400, 24000, "OGG", "VORBIS"),
                                    ("apa_scam_conversation.ogg", 2400, 24000, "OGG", "VORBIS")]
    assert sorted(p.name for p in tmp_path.iterdir()) == ["apa_generic_caution.ogg", "apa_generic_caution.wav", "apa_scam_conversation.ogg",
                                                         "apa_scam_conversation.wav", "index.json"]


def test_ogg_mode_says_how_to_get_libsndfile_when_it_is_missing(tmp_path, monkeypatch):
    (tmp_path / "apa_x.wav").write_bytes(r.pcm_to_wav(b"\x00\x00" * 240))
    monkeypatch.setitem(sys.modules, "soundfile", None)
    with pytest.raises(SystemExit, match="requirements-dev.txt"):
        r.to_ogg(tmp_path)
    assert not (tmp_path / "apa_x.ogg").exists()


def test_a_real_wav_becomes_a_playable_ogg(tmp_path):
    sf = pytest.importorskip("soundfile")
    (tmp_path / "apa_x.wav").write_bytes(r.pcm_to_wav(b"\x00\x10" * 12000))  # half a second
    subtype, done = r.to_ogg(tmp_path)
    info = sf.info(str(done[0]))
    assert done == [tmp_path / "apa_x.ogg"] and info.format == "OGG" and info.subtype == subtype in r.OGG_SUBTYPES
    assert info.duration == pytest.approx(0.5, abs=0.05)


def test_dry_run_lists_what_would_be_rendered_and_spends_nothing(tmp_path, monkeypatch, capsys):
    first = r.sample_jobs(LINE, "otp-a", tmp_path, ("Kore", "Zephyr"), ("urgent", "alarm"))[0][2]
    first.parent.mkdir(parents=True)
    first.write_bytes(b"already rendered")
    monkeypatch.setattr(r, "render", lambda jobs: pytest.fail("a dry run must not render"))
    monkeypatch.setattr(sys, "argv", ["render_apa_audio.py", "--text", LINE, "--name", "otp-a", "--out", str(tmp_path),
                                      "--voices", "Kore", "Zephyr", "--styles", "urgent", "alarm", "--dry-run"])
    r.main()
    out = capsys.readouterr().out
    assert "3 to render, 1 already there" in out and f"at most ${3 * r.RESERVE_PER_LINE:.2f}" in out and first.name not in out
    assert sorted(p.name for p in first.parent.iterdir()) == [first.name]  # no index written
