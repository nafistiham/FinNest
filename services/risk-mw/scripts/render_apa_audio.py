"""Render a validated Apa line with Gemini TTS for a native-speaker pick of voice and style.

    python scripts/render_apa_audio.py --text "<a validated line>" --name otp-a --out /tmp/apa --dry-run   # the plan, no model call
    python scripts/render_apa_audio.py --text "<a validated line>" --name otp-a --out /tmp/apa              # every style x sample voice
    python scripts/render_apa_audio.py --ogg /tmp/apa/otp-a                                                 # WAVs already there -> OGG

Apa has no fixed lines any more (P0 item 5): her words are generated per call by app.warnings, so there is nothing to
pre-record and nothing here renders a stored script. This only auditions a line a person pastes in, and only one Apa may
speak (tts.speakable). Gemini TTS on Vertex AI (role `tts` in config/models.yaml), 24 kHz mono WAV, urgent and quick by
default. --ogg converts with libsndfile (soundfile, in requirements-dev.txt), Opus when it has it, else Vorbis, and calls
no model. Spend is capped by eval/budget.py.
"""

from __future__ import annotations

import argparse
import io
import json
import sys
import time
import wave
from collections.abc import Callable
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))

STYLES = {
    "urgent": ("Say this urgently, at a quick, natural Dhaka speaking pace, like a protective older sister who has just caught "
               "her younger sister about to be cheated on a phone call. Alert, clear and serious, stressing the warning words, "
               "no long pauses and not panicked: "),
    "alarm": ("Speak fast and with alarm, like an older sister cutting into a scam call to stop it right now. Raised, tense "
              "energy, every sentence firm and quick, in natural Bangladeshi Bangla: "),
    "firm_calm": ("Say this firmly and briskly, like a bank's safety officer in an emergency: steady, confident, quick, "
                  "no hesitation, in natural Bangladeshi Bangla: "),
}
DEFAULT_STYLE = "urgent"
DEFAULT_VOICE = "Sulafat"  # The team picked the urgent-Sulafat sample (2026-10-16); a native-speaker re-check is still open
SAMPLE_VOICES = ("Kore", "Pulcherrima", "Zephyr", "Sulafat")  # firm, forward, bright, warm
RATE = 24000
RESERVE_PER_LINE = 0.01
PACE_S = 7.0          # the project's TTS quota is a handful of requests per minute
RETRY_WAITS = (30.0, 60.0)
OGG_SUBTYPES = ("OPUS", "VORBIS")  # Opus is smaller and what Android plays natively; Vorbis when this libsndfile lacks it


def pcm_to_wav(pcm: bytes) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(pcm)
    return buf.getvalue()


def sample_jobs(text: str, name: str, out: Path, voices: tuple[str, ...], styles: tuple[str, ...]) -> list[tuple[str, str, Path, str]]:
    """One line in every style and voice, as out/<name>/<style>-<voice>.wav. Only a line Apa may speak is rendered."""
    from app import tts

    if not tts.speakable(text):
        raise SystemExit("not a line Apa may speak (tts.speakable): paste a line app.warnings validated")
    return [(style, voice, out / name / f"{style}-{voice}.wav", text) for style in styles for voice in voices]


def pending(jobs: list[tuple[str, str, Path, str]]) -> list[tuple[str, str, Path, str]]:
    """The jobs render() would run: it skips files already there."""
    return [job for job in jobs if not job[2].exists()]


def ogg_subtype(writes: Callable[[str], bool]) -> str:
    """The first OGG codec that writes(subtype) can actually encode."""
    for subtype in OGG_SUBTYPES:
        if writes(subtype):
            return subtype
    raise RuntimeError("this libsndfile writes neither OGG Opus nor OGG Vorbis; convert with ffmpeg -i x.wav -c:a libopus -b:a 32k x.ogg")


def to_ogg(folder: Path) -> tuple[str, list[Path]]:
    """Convert the WAVs already rendered in folder to OGG beside them (same name, .ogg). No model call."""
    try:
        import soundfile as sf
    except ImportError as exc:
        raise SystemExit("--ogg needs libsndfile through soundfile: pip install -r requirements-dev.txt") from exc

    def writes(subtype: str) -> bool:
        try:
            sf.write(io.BytesIO(), [0.0] * (RATE // 10), RATE, format="OGG", subtype=subtype)
        except Exception:  # noqa: BLE001 - libsndfile reports a missing codec in more than one way
            return False
        return True

    subtype, done = ogg_subtype(writes), []
    for wav in sorted(folder.glob("*.wav")):
        data, rate = sf.read(str(wav))
        target = wav.with_suffix(".ogg")
        sf.write(str(target), data, rate, format="OGG", subtype=subtype)
        done.append(target)
    return subtype, done


def render(jobs: list[tuple[str, str, Path, str]]) -> list[dict]:
    from google import genai
    from google.genai import errors as genai_errors
    from google.genai import types

    from app import genai_client, tts
    from app.settings import get_settings
    from eval.budget import SpendLedger

    role = genai_client.roles()["tts"]
    settings = get_settings()
    client = genai.Client(vertexai=True, project=settings.project_id, location=settings.genai_location)
    ledger, done = SpendLedger(), []
    for style, voice, target, text in jobs:
        if target.exists():
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        ledger.check(RESERVE_PER_LINE)
        config = types.GenerateContentConfig(response_modalities=["AUDIO"], speech_config=types.SpeechConfig(
            voice_config=types.VoiceConfig(prebuilt_voice_config=types.PrebuiltVoiceConfig(voice_name=voice))))
        for wait in (*RETRY_WAITS, None):
            try:
                resp = client.models.generate_content(model=role.id, contents=tts.contents(role.id, text, STYLES[style]), config=config)
                break
            except genai_errors.APIError as exc:
                if exc.code != 429 or wait is None:
                    raise
                print(f"  quota hit, waiting {wait:.0f} s", flush=True)
                time.sleep(wait)
        tokens_in, tokens_out = genai_client.billed_tokens(resp.usage_metadata)
        cost = genai_client.cost_usd(role, tokens_in, tokens_out)
        ledger.record(cost)
        pcm = resp.candidates[0].content.parts[0].inline_data.data
        target.write_bytes(pcm_to_wav(pcm))
        seconds = round(len(pcm) / (2 * RATE), 2)
        done.append({"style": style, "voice": voice, "file": target.name, "seconds": seconds,
                     "chars_per_second": round(len(text) / seconds, 1), "cost_usd": cost, "text_bn": text})
        print(f"  {style:9s} {voice:12s} {target.name:34s} {seconds:5.1f} s ({done[-1]['chars_per_second']} chars/s)  ${cost:.4f} | spent ${ledger.spent():.4f}", flush=True)
        time.sleep(PACE_S)
    return done


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--text", help="a line app.warnings validated, to audition in every style and sample voice")
    parser.add_argument("--name", default="line", help="the folder under --out for this line's WAVs")
    parser.add_argument("--out", type=Path, help="where to write; nothing is kept in the repository")
    parser.add_argument("--voices", nargs="*", default=list(SAMPLE_VOICES))
    parser.add_argument("--styles", nargs="*", default=list(STYLES))
    parser.add_argument("--dry-run", action="store_true", help="list what would be rendered and the most it could cost; no model call")
    parser.add_argument("--ogg", metavar="DIR", help="convert the WAVs already in DIR to OGG beside them; no model call")
    return parser.parse_args(argv)


def main() -> None:
    args = parse_args()
    if args.ogg:
        subtype, converted = to_ogg(Path(args.ogg))
        size = sum(p.stat().st_size for p in converted) // 1024
        print(f"{len(converted)} OGG {subtype} files, {size} KB in all, in {args.ogg}" if converted else f"no .wav files in {args.ogg}")
        return
    if not (args.text and args.out):
        raise SystemExit("give --text (a validated line) and --out; Apa has no stored lines to render")
    jobs = sample_jobs(args.text, args.name, args.out, tuple(args.voices), tuple(args.styles))
    index = args.out / args.name / "index.json"
    if args.dry_run:
        todo = pending(jobs)
        print(f"{len(todo)} to render, {len(jobs) - len(todo)} already there; at most ${len(todo) * RESERVE_PER_LINE:.2f}")
        for _, _, target, _ in todo:
            print(f"  {target.relative_to(args.out).as_posix()}")
        return
    done = render(jobs)
    model = __import__("app.genai_client", fromlist=["roles"]).roles()["tts"].id
    old = json.loads(index.read_text(encoding="utf-8"))["files"] if index.exists() else []
    index.parent.mkdir(parents=True, exist_ok=True)
    index.write_text(json.dumps({"model": model, "styles": {k: STYLES[k] for k in {j[0] for j in jobs}}, "files": old + done},
                                ensure_ascii=False, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
