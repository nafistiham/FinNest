"""Live-speech smoke test (spec US-5, section 7): 20 Bangla utterances through Gemini transcription.

    python -m eval.transcription_smoke --dry-run                     # what would run: audio found, spend reserve; no calls
    RISK_MW_GENAI_ENABLED=true RISK_MW_PROJECT_ID=... RISK_MW_GENAI_BACKEND=vertex python -m eval.transcription_smoke
    ... python -m eval.transcription_smoke --source tts_phone        # Gemini TTS audio from scripts/make_smoke_audio.py (provisional)
    ... python -m eval.transcription_smoke --source tts_clean        # the same lines before the phone-band filter (provisional)
    ... python -m eval.transcription_smoke --mode live               # the same files through Gemini Live, the WS bridge's model

Recorded audio: one file per utterance in eval/speech_smoke/audio/<id>.wav (or .ogg, .mp3, .m4a, .aac, .webm, under
2 MB), the text_bn line of eval/speech_smoke/utterances.jsonl read naturally, played from a second phone on speaker.

File mode (the default) sends each file through app.speech.transcribe_call, the code behind POST /v1/scam/transcribe.
Live mode measures what WS /v1/scam/live runs instead: each WAV file is resampled to 16 kHz 16-bit mono PCM and streamed
in 100 ms chunks (in real time unless --live-pace says otherwise) into app.speech.gemini_live, the bridge's own Gemini
Live session (us-central1, bn-BD, the scam vocabulary); then end_audio asks for the last transcription, and every turn
that comes back within live_drain_s is joined into that utterance's transcript. Its results carry their own source key,
<source>_live (tts_phone_live, recorded_live). An utterance counts as recognised when every key term is in the
transcript after Bangla-aware normalisation (digits in both scripts, spelling variants, English words folded onto their
Bangla spelling); word accuracy is 1 - WER against the reference. The live path is enabled only when at least 16 of 20
are recognised by Gemini Live on recorded speech (recorded_live); a file-mode pass shows the transcribe route works but
does not measure the live model. TTS audio is synthetic speech, not people, so a pass on it is provisional and the
transcript-first path stays the demo path. Writes eval/results/transcription_smoke_<source>.json and, on a full run,
that source's entry in the speech_smoke block of eval/results/intervention.json. Spend is capped by eval/budget.py.
"""

from __future__ import annotations

import argparse
import asyncio
import io
import json
import math
import re
import sys
import time
import unicodedata
import wave
from collections.abc import Callable
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))  # run as eval/x.py, app and eval are one level up
from app import genai_client, speech
from app.routers.speech import LIVE_QUIET_AFTER_TURN_S
from app.settings import Settings, get_settings
from eval.budget import SpendLedger

HERE = Path(__file__).resolve().parent
UTTERANCES = HERE / "speech_smoke" / "utterances.jsonl"
AUDIO_DIRS = {"recorded": HERE / "speech_smoke" / "audio",  # real people only
              "tts_clean": HERE / "speech_smoke" / "audio_tts" / "clean", "tts_phone": HERE / "speech_smoke" / "audio_tts" / "phone"}
RESULTS = HERE / "results"
AUDIO_EXTENSIONS = {".wav": "audio/wav", ".ogg": "audio/ogg", ".mp3": "audio/mpeg", ".m4a": "audio/mp4", ".aac": "audio/aac", ".webm": "audio/webm"}
SET_SIZE = 20
PASS_MIN = 16
RESERVE_PER_CALL = 0.005
MAX_GAP = 2        # words allowed between the parts of a multi-word key term ("একাউন্টটা আজই বন্ধ")
PASS_RULE = f"every key term recognised in at least {PASS_MIN} of {SET_SIZE} utterances, on recorded speech"
BLOCK_KEYS = ("source", "passed", "recognised", "of", "word_accuracy", "path", "provisional")
LIVE = "_live"              # live-mode results: <source>_live, so they never overwrite file mode's
LIVE_RATE = 16_000          # what the bridge forwards to Gemini Live: 16 kHz 16-bit mono PCM (speech.PCM_MIME)
LIVE_CHUNK_S = 0.1
LIVE_CHUNK_BYTES = int(LIVE_RATE * LIVE_CHUNK_S) * 2

# --- normalisation and scoring -------------------------------------------------------------------------

BN_DIGITS = str.maketrans("০১২৩৪৫৬৭৮৯", "0123456789")
ZERO_WIDTH = re.compile("[​‌‍﻿]")
SPELLING = (("অ্যা", "এ"), ("ী", "ি"), ("ূ", "ু"), ("ঈ", "ই"), ("ঊ", "উ"), ("ঙ্ক", "ংক"))  # variants a transcript may pick either way
LATIN = {latin.lower(): bangla for latin, bangla in speech.LATIN_TERMS.items()}
LATIN_RE = re.compile(r"(?<![a-z])(" + "|".join(re.escape(k) for k in sorted(LATIN, key=len, reverse=True)) + r")(?![a-z])")


def normalise(text: str) -> str:
    text = ZERO_WIDTH.sub("", unicodedata.normalize("NFC", text)).translate(BN_DIGITS)
    text = re.sub(r"(?<=\d),(?=\d)", "", text).lower()
    text = "".join(" " if unicodedata.category(ch)[0] in "PS" else ch for ch in text)  # \w would drop Bangla vowel signs
    text = LATIN_RE.sub(lambda m: LATIN[m.group(1)], re.sub(r"\s+", " ", text))
    for variant, canonical in SPELLING:
        text = text.replace(variant, canonical)
    return re.sub(r"\s+", " ", text).strip()


def _in_order(words: list[str], tokens: list[str]) -> bool:
    for start, token in enumerate(tokens):
        if words[0] not in token:
            continue
        at = start
        for word in words[1:]:
            at = next((k for k in range(at + 1, min(len(tokens), at + 2 + MAX_GAP)) if word in tokens[k]), -1)
            if at < 0:
                break
        else:
            return True
    return False


def term_found(term: str, tokens: list[str]) -> bool:
    """A key term (alternatives split by "|") is found inside a word, so Bangla suffixes count: কোড in কোডটা."""
    for alternative in term.split("|"):
        words = normalise(alternative).split()
        if words and (any("".join(words) in t for t in tokens) or (len(words) > 1 and _in_order(words, tokens))):
            return True
    return False


def missing_terms(key_terms: list[str], transcript: str | None) -> list[str]:
    tokens = normalise(transcript or "").split()
    return [term for term in key_terms if not term_found(term, tokens)]


def word_errors(reference: str, hypothesis: str | None) -> tuple[int, int]:
    """Word-level edit distance and the reference length."""
    ref, hyp = normalise(reference).split(), normalise(hypothesis or "").split()
    row = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, 1):
        prev, row[0] = row[0], i
        for j, h in enumerate(hyp, 1):
            prev, row[j] = row[j], min(row[j] + 1, row[j - 1] + 1, prev + (r != h))
    return row[-1], len(ref)


def word_accuracy(reference: str, hypothesis: str | None) -> float:
    errors, words = word_errors(reference, hypothesis)
    return round(max(0.0, 1 - errors / max(1, words)), 3)


def passes(recognised: int, of: int) -> bool:
    """At least 16 of 20; a partial run cannot pass."""
    return of >= SET_SIZE and recognised * SET_SIZE >= PASS_MIN * of


def chosen_path(passed: bool, source: str) -> str:
    """Only Gemini Live on recorded people (recorded_live) can enable the live bridge: file mode runs another model."""
    return "live" if passed and source == "recorded" + LIVE else "transcript_first"


def is_recorded(source: str) -> bool:
    return source.removesuffix(LIVE) == "recorded"


def score(rows: list[dict], transcripts: dict[str, str | None]) -> dict:
    items, errors, words = [], 0, 0
    for row in rows:
        heard = transcripts.get(row["id"])
        missing = missing_terms(row["key_terms"], heard)
        e, n = word_errors(row["text_bn"], heard)
        errors, words = errors + e, words + n
        items.append({"id": row["id"], "recognised": not missing and heard is not None, "missing_terms": missing,
                      "word_accuracy": round(max(0.0, 1 - e / max(1, n)), 3), "transcript": heard, "reference": row["text_bn"]})
    recognised = sum(i["recognised"] for i in items)
    return {"recognised": recognised, "of": len(items), "passed": passes(recognised, len(items)),
            "word_accuracy": round(max(0.0, 1 - errors / max(1, words)), 3), "items": items}


# --- running -------------------------------------------------------------------------------------------


def load_utterances(path: Path = UTTERANCES) -> list[dict]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def find_audio(audio_dir: Path, uid: str) -> tuple[Path, str] | None:
    for ext, mime in AUDIO_EXTENSIONS.items():
        if (path := audio_dir / f"{uid}{ext}").is_file():
            return path, mime
    return None


def _percentile(xs: list[float], p: float) -> float | None:
    return round(sorted(xs)[min(len(xs) - 1, int(p * len(xs)))], 1) if xs else None


def _note(passed: bool, source: str) -> str:
    live = source.endswith(LIVE)
    if not is_recorded(source):
        return (f"Synthetic Gemini TTS speech, not recorded people{', through Gemini Live' if live else ''}: provisional. "
                "The transcript-first path stays the demo path until recorded speech passes on Gemini Live (--mode live).")
    if passed and live:
        return "Live path enabled: Gemini Live, the bridge's model, recognised every key term in at least 16 of 20 recorded utterances."
    if passed:
        return ("File-mode transcription recognised every key term in at least 16 of 20 recorded utterances. The live bridge runs "
                "Gemini Live, another model: the live path waits for --mode live to pass on the same recordings.")
    return (f"Fewer than 16 of 20 recorded utterances had every key term{' on Gemini Live' if live else ''}: "
            "the transcript-first path drives the demo (spec US-5 S2).")


def run(rows: list[dict], audio_dir: Path, source: str, transcribe: Callable[[bytes, str], genai_client.CallResult],
        ledger: SpendLedger) -> dict:
    transcripts: dict[str, str | None] = {}
    extra: dict[str, dict] = {}
    results: list[genai_client.CallResult] = []
    for row in rows:
        found = find_audio(audio_dir, row["id"])
        if found is None:
            transcripts[row["id"]], extra[row["id"]] = None, {"error": "no audio file"}
            continue
        path, mime = found
        ledger.check(RESERVE_PER_CALL)
        started = time.perf_counter()
        try:
            result = transcribe(path.read_bytes(), mime)
        except Exception as exc:  # noqa: BLE001 - one failed utterance is a miss, not the end of the run
            transcripts[row["id"]] = None
            extra[row["id"]] = {"error": exc.__class__.__name__, "code": getattr(exc, "code", None),
                                "ms": round((time.perf_counter() - started) * 1000, 1)}
            print(f"  {row['id']} failed: {exc.__class__.__name__} {getattr(exc, 'code', '')}", flush=True)
            continue
        ledger.record(result.cost_usd)
        results.append(result)
        transcripts[row["id"]] = result.text
        extra[row["id"]] = {"file": path.name, "ms": round((time.perf_counter() - started) * 1000, 1), "cost_usd": result.cost_usd}
        print(f"  {row['id']} {result.latency_ms:7.1f} ms ${result.cost_usd:.4f} | {result.text[:70]}", flush=True)
    scored = score(rows, transcripts)
    for item in scored["items"]:
        item.update(extra.get(item["id"], {}))
    ms = [r.latency_ms for r in results]
    provisional = not is_recorded(source)
    return {"source": source, "mode": "live" if source.endswith(LIVE) else "file", "provisional": provisional,
            "model": results[0].model_id if results else None, "language": speech.LANGUAGE,
            "pass_rule": PASS_RULE, "passed": scored["passed"], "recognised": scored["recognised"], "of": scored["of"],
            "word_accuracy": scored["word_accuracy"], "path": chosen_path(scored["passed"], source), "note": _note(scored["passed"], source),
            "latency_ms": {"p50": _percentile(ms, 0.5), "p95": _percentile(ms, 0.95)}, "cost_usd": round(sum(r.cost_usd for r in results), 4),
            "items": scored["items"]}


# --- live mode: the WS bridge's Gemini Live session --------------------------------------------------------


class LiveNeedsWav(ValueError):
    """Gemini Live takes raw PCM; this harness can only resample 16-bit PCM WAV files (convert other formats first)."""


def pcm16k(audio: bytes) -> bytes:
    """A 16-bit WAV file as 16 kHz 16-bit mono PCM, what the app streams to the bridge."""
    import numpy as np

    try:
        with wave.open(io.BytesIO(audio)) as w:
            channels, width, rate, frames = w.getnchannels(), w.getsampwidth(), w.getframerate(), w.readframes(w.getnframes())
    except (wave.Error, EOFError) as exc:
        raise LiveNeedsWav("live mode streams PCM: it reads 16-bit WAV files only") from exc
    if width != 2:
        raise LiveNeedsWav(f"{8 * width}-bit WAV: live mode reads 16-bit PCM only")
    x = np.frombuffer(frames, dtype="<i2").astype(np.float64)
    if channels > 1:
        x = x[: len(x) - len(x) % channels].reshape(-1, channels).mean(axis=1)
    if rate != LIVE_RATE:
        from scipy.signal import resample_poly

        g = math.gcd(LIVE_RATE, rate)
        x = resample_poly(x, LIVE_RATE // g, rate // g)
    return np.clip(np.round(x), -32768, 32767).astype("<i2").tobytes()


async def _drain(reader: asyncio.Task, new_turn: asyncio.Event, drain_s: float) -> None:
    """As the bridge does after "end": wait up to drain_s for Live's last turns; once one has come, a short quiet ends it."""
    loop = asyncio.get_running_loop()
    deadline, heard = loop.time() + drain_s, False
    while not reader.done() and (left := deadline - loop.time()) > 0:
        new_turn.clear()
        waiter = asyncio.ensure_future(new_turn.wait())
        done, _ = await asyncio.wait({reader, waiter}, timeout=min(left, LIVE_QUIET_AFTER_TURN_S) if heard else left,
                                     return_when=asyncio.FIRST_COMPLETED)
        waiter.cancel()
        if not done:
            return
        heard = heard or waiter in done


async def live_transcribe(audio: bytes, mime: str, settings: Settings, factory: speech.LiveFactory,
                          pace: float = 1.0) -> genai_client.CallResult:
    """One utterance through a Live session from factory (speech.gemini_live in a real run): 16 kHz PCM in 100 ms chunks,
    paced like a call when pace is 1, then end_audio, then the turns that come back within live_drain_s, joined in order.
    latency_ms is from the end of the audio to the last turn. A broken session raises, so the utterance is a miss."""
    if mime != "audio/wav":
        raise LiveNeedsWav(f"{mime}: live mode streams PCM, so it reads WAV files only")
    pcm = pcm16k(audio)
    turns: list[str] = []
    new_turn = asyncio.Event()
    last_turn_at: list[float] = []
    async with factory(settings) as live:
        async def collect() -> None:
            async for text in live.transcripts():
                if text := text.strip():
                    turns.append(text)
                    last_turn_at[:] = [time.perf_counter()]
                    new_turn.set()

        reader = asyncio.create_task(collect())
        try:
            for at in range(0, len(pcm), LIVE_CHUNK_BYTES):
                if reader.done():
                    break
                await live.send_audio(pcm[at: at + LIVE_CHUNK_BYTES])
                if pace > 0:
                    await asyncio.sleep(pace * LIVE_CHUNK_S)
            ended = time.perf_counter()
            if not reader.done():
                await live.end_audio()
                await _drain(reader, new_turn, settings.live_drain_s)
        finally:
            reader.cancel()
            outcome = (await asyncio.gather(reader, return_exceptions=True))[0]
        if isinstance(outcome, Exception):
            raise outcome
        tokens_in, tokens_out = int(getattr(live, "tokens_in", 0)), int(getattr(live, "tokens_out", 0))
        cost = float(getattr(live, "cost_usd", 0.0))
    latency_ms = round(max(0.0, (last_turn_at[0] if last_turn_at else time.perf_counter()) - ended) * 1000, 1)
    return genai_client.CallResult(text=" ".join(turns), parsed=None, model_id=genai_client.roles()[speech.LIVE_ROLE].id,
                                   tokens_in=tokens_in, tokens_out=tokens_out, cost_usd=cost, latency_ms=latency_ms)


def speech_block(result: dict) -> dict:
    return {key: result[key] for key in BLOCK_KEYS}


def merge_speech_block(path: Path, block: dict) -> None:
    """Set this source's entry in intervention.json's speech_smoke block; other sources and every other key stay in place."""
    data = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
    current = data.get("speech_smoke")
    by_source = current if isinstance(current, dict) and all(isinstance(v, dict) and "source" in v for v in current.values()) else {}
    data["speech_smoke"] = {**by_source, block["source"]: block}
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")


def _dry_run(rows: list[dict], audio_dir: Path, live: bool) -> None:
    found = [r["id"] for r in rows if find_audio(audio_dir, r["id"])]
    usable = [uid for uid in found if not live or find_audio(audio_dir, uid)[1] == "audio/wav"]
    try:
        backend = genai_client.select_backend(get_settings())
    except genai_client.GenAIDisabled as exc:
        backend = f"off ({exc})"
    what = (f"Gemini Live sessions ({genai_client.roles()[speech.LIVE_ROLE].id} in {get_settings().live_location}, 16 kHz PCM)"
            if live else "Gemini calls")
    print(f"dry run: {len(usable)} of {len(rows)} {'WAV ' if live else ''}audio files in {audio_dir}; up to {len(usable)} {what}, "
          f"reserve ${len(usable) * RESERVE_PER_CALL:.3f}; Gemini backend {backend}. Nothing sent, nothing written.")
    if missing := [r["id"] for r in rows if r["id"] not in found]:
        print(f"missing audio: {', '.join(missing)}")
    if not_wav := [uid for uid in found if uid not in usable]:
        print(f"not WAV, so not streamed (convert to 16-bit WAV): {', '.join(not_wav)}")


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--source", default="recorded", choices=sorted(AUDIO_DIRS))
    parser.add_argument("--mode", default="file", choices=("file", "live"),
                        help="file: POST /v1/scam/transcribe's model (default); live: Gemini Live, what WS /v1/scam/live runs")
    parser.add_argument("--audio-dir", type=Path, default=None, help="default: eval/speech_smoke/audio (recorded) or audio_tts/{clean,phone}")
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--live-pace", type=float, default=1.0, help="live mode: 1 streams in real time like a call, 0 as fast as possible")
    parser.add_argument("--dry-run", action="store_true", help="list what would be sent and its spend reserve; call nothing, write nothing")
    args = parser.parse_args(argv)
    every = load_utterances()
    rows = every[: args.limit or None]
    audio_dir = args.audio_dir or AUDIO_DIRS[args.source]
    live = args.mode == "live"
    if args.dry_run:
        _dry_run(rows, audio_dir, live)
        return
    settings = get_settings()
    ledger = SpendLedger()
    source = args.source + (LIVE if live else "")
    if live:
        loop = asyncio.new_event_loop()  # one loop for every session: the cached Gemini client stays on it
        try:
            result = run(rows, audio_dir, source, lambda audio, mime: loop.run_until_complete(
                live_transcribe(audio, mime, settings, speech.gemini_live, args.live_pace)), ledger)
        finally:
            loop.close()
    else:
        result = run(rows, audio_dir, source, lambda audio, mime: speech.transcribe_call(audio, mime, settings), ledger)
    result["spent_usd_ledger"] = ledger.spent()
    RESULTS.mkdir(parents=True, exist_ok=True)
    (RESULTS / f"transcription_smoke_{source}.json").write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    if len(rows) == len(every):
        merge_speech_block(RESULTS / "intervention.json", speech_block(result))
    else:
        print("partial run: eval/results/intervention.json left as it was")
    print(f"{source}: {result['recognised']} of {result['of']} with every key term ({'pass' if result['passed'] else 'no pass'}), "
          f"word accuracy {result['word_accuracy']}, path {result['path']}, ${result['cost_usd']}. {result['note']}")


if __name__ == "__main__":
    main()
