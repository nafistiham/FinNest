"""Render the 20 speech-smoke utterances with Gemini TTS (spec US-5), for a smoke run before recordings exist.

    python scripts/make_smoke_audio.py --dry-run         # the voice cast, what would be rendered and its reserve; calls nothing
    RISK_MW_GENAI_ENABLED=true RISK_MW_PROJECT_ID=... RISK_MW_GENAI_BACKEND=vertex python scripts/make_smoke_audio.py
    python scripts/make_smoke_audio.py --phone-only      # rebuild the phone-band copies from the clean WAVs; calls nothing
    python -m eval.transcription_smoke --source tts_phone    (then --source tts_clean)

Each utterance gets its own Gemini TTS voice (role `tts`): 10 male and 10 female, alternating down the list so no
archetype is one gender. A per-line style prompt makes it sound like one side of a real phone call in Dhaka Bangla:
scam callers hurried and pressing with natural hesitations, benign callers calm. Every line is written twice:
eval/speech_smoke/audio_tts/clean/<id>.wav (24 kHz) and audio_tts/phone/<id>.wav (8 kHz, 300-3400 Hz, light hiss),
which is closer to a call played from a second phone on speaker. eval/speech_smoke/audio/ stays for real recordings:
TTS speech is still not people, so smoke results on it are provisional. Paced for the TTS quota (about 7 s apart,
longer waits on a 429); files already there are kept unless --force. Spend is capped by eval/budget.py.
"""

from __future__ import annotations

import argparse
import io
import json
import sys
import time
import wave
import zlib
from collections.abc import Callable
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))

from app import genai_client, tts  # noqa: E402
from app.settings import get_settings  # noqa: E402
from eval.budget import SpendLedger  # noqa: E402
from eval.transcription_smoke import AUDIO_DIRS, load_utterances  # noqa: E402
from scripts.render_apa_audio import RATE, pcm_to_wav  # noqa: E402

OUT_CLEAN, OUT_PHONE = AUDIO_DIRS["tts_clean"], AUDIO_DIRS["tts_phone"]
TTS_DIR = OUT_CLEAN.parent
# Gemini TTS prebuilt voices by Google's own list.
MALE_VOICES = ("Charon", "Fenrir", "Orus", "Puck", "Algenib", "Iapetus", "Enceladus", "Umbriel", "Alnilam", "Schedar")
FEMALE_VOICES = ("Kore", "Zephyr", "Aoede", "Leda", "Despina", "Callirrhoe", "Autonoe", "Erinome", "Gacrux", "Vindemiatrix")
PHONE_CALL = ("This is one side of a real phone call in Bangladesh, not a newsreader or an announcement. Speak natural, "
              "conversational Dhaka Bangla the way people really talk on the phone, everyday pronunciation, ")
SCAM_DELIVERY = "hurried and pressing, pushing the listener to act right now, with small natural hesitations and fillers between phrases. "
BENIGN_DELIVERY = "calm and ordinary, relaxed, nothing urgent. "
MOODS = {
    "fake_customer_care": "The caller claims to be mobile-money customer care: official-sounding but pushy.",
    "otp_pin_harvest": "The caller is impatient and insistent about getting the code.",
    "lottery_prize": "The caller is over-friendly and excited, like a salesman with good news.",
    "wrong_send_refund": "The caller sounds anxious and pleading, a little breathless.",
    "job_loan_fee": "The caller is businesslike but keeps pushing the fee.",
    "relative_impersonation": "The caller sounds distressed and rushed, like a relative in trouble.",
    "benign_bank_call": "A real bank help-line agent: polite, steady and professional.",
    "benign_relative": "A family member asking a small favour: warm and casual.",
    "benign_delivery": "A courier waiting at the gate: plain and matter-of-fact.",
    "benign_agent": "A local mobile-money agent: friendly and easy-going.",
}
PHONE_RATE = 8000
PHONE_BAND_HZ = (300.0, 3400.0)
PHONE_SNR_DB = 30.0  # light hiss under the voice
RESERVE_PER_LINE = 0.01
PACE_S = 7.0
RETRY_WAITS = (30.0, 60.0, 120.0)
NOTE = ("Synthetic Gemini TTS speech, not recorded people: smoke results on it are provisional, and only recorded speech "
        "(eval/speech_smoke/audio/) can enable the live path.")


def cast(rows: list[dict]) -> dict[str, tuple[str, str]]:
    """One voice per utterance, male and female alternating down the list, so every archetype with two or more lines hears both."""
    male, female = iter(MALE_VOICES), iter(FEMALE_VOICES)
    return {row["id"]: (next(male), "male") if n % 2 == 0 else (next(female), "female") for n, row in enumerate(rows)}


def style_for(row: dict) -> str:
    delivery = BENIGN_DELIVERY if row.get("label") == "benign" else SCAM_DELIVERY
    return f"{PHONE_CALL}{delivery}{MOODS.get(row.get('archetype', ''), '')} Say this line: "


def phone_band(pcm: bytes, seed: int) -> bytes:
    """24 kHz PCM -> 8 kHz, 300-3400 Hz band-pass and light deterministic hiss: a voice heard through a phone on speaker."""
    import numpy as np
    from scipy.signal import butter, resample_poly, sosfiltfilt

    x = np.frombuffer(pcm, dtype="<i2").astype(np.float64) / 32768.0
    y = sosfiltfilt(butter(4, PHONE_BAND_HZ, btype="bandpass", fs=PHONE_RATE, output="sos"), resample_poly(x, 1, RATE // PHONE_RATE))
    rms = float(np.sqrt(np.mean(y ** 2))) if y.size else 0.0
    y = y + np.random.default_rng(seed).normal(0.0, max(rms, 1e-3) * 10 ** (-PHONE_SNR_DB / 20), y.size)
    return (np.clip(y, -1.0, 1.0) * 32767).astype("<i2").tobytes()


def _wav(pcm: bytes, rate: int) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(pcm)
    return buf.getvalue()


def _seed(uid: str) -> int:
    return zlib.crc32(uid.encode())


def jobs(rows: list[dict], voices: dict[str, tuple[str, str]], clean: Path, phone: Path, force: bool = False) -> list[dict]:
    return [{"row": r, "voice": voices[r["id"]][0], "gender": voices[r["id"]][1], "clean": clean / f"{r['id']}.wav", "phone": phone / f"{r['id']}.wav"}
            for r in rows if force or not (clean / f"{r['id']}.wav").exists()]


def _synthesise(model_id: str, text: str, voice: str, style: str) -> Any:
    from google.genai import types

    config = types.GenerateContentConfig(response_modalities=["AUDIO"], speech_config=types.SpeechConfig(
        voice_config=types.VoiceConfig(prebuilt_voice_config=types.PrebuiltVoiceConfig(voice_name=voice))))
    return genai_client._client().models.generate_content(model=model_id, contents=tts.contents(model_id, text, style), config=config)


def render(todo: list[dict], ledger: SpendLedger, synth: Callable[[str, str, str, str], Any] | None = None,
           sleep: Callable[[float], None] | None = None) -> list[dict]:
    from google.genai import errors

    synth, sleep = synth or _synthesise, sleep or time.sleep
    role = genai_client.roles()["tts"]
    done = []
    for n, job in enumerate(todo):
        row, style = job["row"], style_for(job["row"])
        if n:
            sleep(PACE_S)
        ledger.check(RESERVE_PER_LINE)
        for wait in (*RETRY_WAITS, None):
            try:
                resp = synth(role.id, row["text_bn"], job["voice"], style)
                break
            except errors.APIError as exc:
                if exc.code != 429 or wait is None:
                    raise
                print(f"  quota hit, waiting {wait:.0f} s", flush=True)
                sleep(wait)
        tokens_in, tokens_out = genai_client.billed_tokens(resp.usage_metadata)
        cost = genai_client.cost_usd(role, tokens_in, tokens_out)
        ledger.record(cost)
        pcm = resp.candidates[0].content.parts[0].inline_data.data
        for path, data in ((job["clean"], pcm_to_wav(pcm)), (job["phone"], _wav(phone_band(pcm, _seed(row["id"])), PHONE_RATE))):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        done.append({"id": row["id"], "archetype": row.get("archetype"), "label": row.get("label"), "voice": job["voice"],
                     "gender": job["gender"], "clean": f"{job['clean'].parent.name}/{job['clean'].name}",
                     "phone": f"{job['phone'].parent.name}/{job['phone'].name}", "seconds": round(len(pcm) / (2 * RATE), 2),
                     "cost_usd": cost, "style": style, "text_bn": row["text_bn"]})
        print(f"  {row['id']} {job['voice']:12s} {job['gender']:6s} {done[-1]['seconds']:5.1f} s ${cost:.4f} | spent ${ledger.spent():.4f}", flush=True)
    return done


def rebuild_phone(rows: list[dict]) -> int:
    """Phone-band copies from the clean WAVs already rendered; no model call."""
    made = 0
    for row in rows:
        clean = OUT_CLEAN / f"{row['id']}.wav"
        if clean.is_file():
            with wave.open(io.BytesIO(clean.read_bytes())) as w:
                pcm = w.readframes(w.getnframes())
            OUT_PHONE.mkdir(parents=True, exist_ok=True)
            (OUT_PHONE / clean.name).write_bytes(_wav(phone_band(pcm, _seed(row["id"])), PHONE_RATE))
            made += 1
    return made


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--force", action="store_true", help="render again files that already exist")
    parser.add_argument("--phone-only", action="store_true", help="rebuild the phone-band copies from the clean WAVs; no model call")
    parser.add_argument("--dry-run", action="store_true", help="list the cast, what would be rendered and its reserve; call nothing, write nothing")
    args = parser.parse_args(argv)
    every = load_utterances()
    voices = cast(every)
    rows = every[: args.limit or None]
    if args.phone_only:
        print(f"{rebuild_phone(rows)} phone-band copies written to {OUT_PHONE}")
        return
    todo = jobs(rows, voices, OUT_CLEAN, OUT_PHONE, args.force)
    if args.dry_run:
        genders = [voices[r["id"]][1] for r in rows]
        print(f"dry run: {len(todo)} of {len(rows)} utterances to render into {OUT_CLEAN} and {OUT_PHONE}, "
              f"{genders.count('male')} male and {genders.count('female')} female voices; reserve ${len(todo) * RESERVE_PER_LINE:.2f}, "
              f"about {max(0, len(todo) - 1) * PACE_S:.0f} s at the quota pace. Nothing sent, nothing written.")
        for row in rows:
            print(f"  {row['id']} {row['archetype']:22s} {voices[row['id']][0]:12s} {voices[row['id']][1]}")
        return
    genai_client.select_backend(get_settings())  # stop here, not mid-run, when Gemini is off
    done = render(todo, SpendLedger())
    index = TTS_DIR / "index.json"
    old = json.loads(index.read_text(encoding="utf-8")).get("files", {}) if index.exists() else {}
    files = dict(sorted({**old, **{d["id"]: d for d in done}}.items()))
    TTS_DIR.mkdir(parents=True, exist_ok=True)
    index.write_text(json.dumps({"model": genai_client.roles()["tts"].id, "provisional": True, "note": NOTE,
                                 "voices": {"male": list(MALE_VOICES), "female": list(FEMALE_VOICES)},
                                 "phone": {"rate": PHONE_RATE, "band_hz": list(PHONE_BAND_HZ), "snr_db": PHONE_SNR_DB}, "files": files},
                                ensure_ascii=False, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
