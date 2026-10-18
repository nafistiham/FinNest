"""Five Bangla warning lines on both TTS engines, in Apa's voice, so a native ear can choose the primary.
A PAID check: ten Gemini TTS calls, about a cent in all.

    python scripts/tts_engine_smoke.py --dry-run     # the engines, the lines, the reserve and the pace; calls nothing, writes nothing
    RISK_MW_GENAI_ENABLED=true RISK_MW_PROJECT_ID=... RISK_MW_GENAI_BACKEND=vertex python scripts/tts_engine_smoke.py

Both engines in config/models.yaml (roles tts and tts_fallback) speak every line in Sulafat with the urgent style, through
app.tts.responses: the request the service itself sends, streamed first and whole when a stream is refused. Writes
eval/tts_engine_smoke/<model id>/<n>.wav and eval/results/tts_engine_smoke.json: per engine, reachable or the error code,
first-byte and total ms, seconds of audio, characters per second and cost. An engine that answers "model not found", or
whose quota never clears, is recorded with that code and not asked again. Requests go PACE_S apart for the TTS quota of a
few requests a minute; a 429 waits RETRY_WAITS, then gives up on that engine. Spend goes on eval/budget.py's SpendLedger,
checked before each request and recorded after. Because pre-rendering hides TTS latency, choose on Bangla quality and
availability, not on speed; then pin the winner in config/models.yaml and PINNED in tests/test_tts_engines.py.
"""

from __future__ import annotations

import argparse
import json
import math
import statistics
import sys
import time
from collections.abc import Callable, Iterable
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))

from app import genai_client, tts  # noqa: E402
from app.settings import Settings, get_settings  # noqa: E402

def _line(n: int, role: str, text_bn: str, text_en: str) -> dict:
    return {"n": n, "role": role, "text_bn": text_bn, "text_en": text_en, "native_check": "pending"}


# The report's illustrative A|T|R|X for an OTP request, a claimed bank, a "likely" band and the address রহিমা, then one
# more line for a send-money hold. A non-native draft: native_check stays "pending" until a native speaker has read them.
LINES = (
    _line(1, "A", "রহিমা, একটু থামুন — কোডটা কাউকে বলবেন না।", "Rahima, stop for a moment: don't tell anyone the code."),
    _line(2, "T", "ফোনে আপনার মেসেজে আসা কোডটা চাওয়া হচ্ছে।", "The code that came in your message is being asked for on the phone."),
    _line(3, "R", "আসল ব্যাংক বা ভরসা কখনো ফোনে এই কোড চায় না।", "A real bank, or Bhorosha, never asks for this code on the phone."),
    _line(4, "X", "কলটা কেটে দিন, তারপর অ্যাপের \"ভরসায় কল করুন\" বোতাম চাপুন।", "Hang up, then press the app's 'Call Bhorosha' button."),
    _line(5, "X", "টাকাটা এখন পাঠাবেন না, আগে পরিবারের কারো সাথে কথা বলুন।", "Don't send the money now; talk to someone in your family first."),
)
VOICE = "Sulafat"
PACE_S = 7.0                         # the project's TTS quota is a handful of requests a minute
RETRY_WAITS = (30.0, 60.0, 120.0)
RESERVE_PER_LINE = tts.RESERVE_USD
TIMEOUT_S = 30.0                     # the 3.x TTS Preview has taken 10-20 s to a first chunk under shared capacity
TOKENS_IN_ESTIMATE = 200             # the style and a short line, for the rare reply without usage
AUDIO_TOKENS_PER_S = 25
OUT_DIR = HERE / "eval" / "tts_engine_smoke"
RESULT_FILE = HERE / "eval" / "results" / "tts_engine_smoke.json"
Synth = Callable[[genai_client.ModelRole, str, Settings], Iterable[Any]]


def _synth(engine: genai_client.ModelRole, text_bn: str, settings: Settings) -> Iterable[Any]:
    return tts.responses(engine, text_bn, settings)


def _ms(since: float) -> float:
    return round((time.perf_counter() - since) * 1000, 1)


def _speak(engine: genai_client.ModelRole, text_bn: str, settings: Settings, synth: Synth, sleep: Callable[[float], None]) -> dict:
    """One line on one engine: timings, PCM and usage, or the error. A 429 waits RETRY_WAITS before it gives up."""
    from google.genai import errors

    for wait in (*RETRY_WAITS, None):
        started, first_ms, parts, usage = time.perf_counter(), None, [], None
        try:
            for response in synth(engine, text_bn, settings):
                usage = getattr(response, "usage_metadata", None) or usage
                for pcm in tts.audio(response):
                    first_ms = first_ms if first_ms is not None else _ms(started)
                    parts.append(pcm)
            if not parts:  # a 200 with no audio (the reported Bangla bug) is not a working engine
                return {"status": "no_audio", "stop": False, "message": "the engine answered with no audio", "billed": usage is not None}
            return {"status": "ok", "first_byte_ms": first_ms, "total_ms": _ms(started), "pcm": b"".join(parts), "usage": usage}
        except errors.APIError as exc:
            quota = tts.quota_name(exc) if exc.code == 429 else None
            if exc.code == 429 and wait is not None:
                print(f"  {engine.id}: 429 ({quota or 'quota not named'}), waiting {wait:.0f} s", flush=True)
                sleep(wait)
                continue
            return {"status": exc.code, "stop": exc.code == 429 or tts.model_missing(exc, engine.id), "quota": quota,
                    "message": (exc.message or "")[:300], "billed": False}
        except Exception as exc:  # noqa: BLE001 - a timeout or a cut stream is a result here, and may still be billed
            return {"status": exc.__class__.__name__, "stop": False, "message": str(exc)[:300], "billed": True}
    raise AssertionError("unreachable")


def _cost(engine: genai_client.ModelRole, usage: Any, seconds: float) -> tuple[float, bool]:
    """The billed cost from the reply's usage, or an estimate from the audio length when it reports none."""
    tokens_in, tokens_out = genai_client.billed_tokens(usage) if usage is not None else (0, 0)
    if tokens_in or tokens_out:
        return genai_client.cost_usd(engine, tokens_in, tokens_out), False
    return genai_client.cost_usd(engine, TOKENS_IN_ESTIMATE, math.ceil(seconds * AUDIO_TOKENS_PER_S)), True


def _summary(engine: genai_client.ModelRole, settings: Settings, rows: list[dict]) -> dict:
    ok = [r for r in rows if r["status"] == "ok"]
    firsts = [r["first_byte_ms"] for r in ok if r["first_byte_ms"] is not None]
    seconds, chars = sum(r["audio_s"] for r in ok), sum(r["chars"] for r in ok)
    tried = [r["status"] for r in rows if r["status"] != "skipped"]
    return {"role": engine.name, "model_id": engine.id, "location": engine.location or settings.genai_location,
            "tts_style": engine.tts_style or "prompt", "reachable": bool(ok), "error": None if ok else (tried[0] if tried else None),
            "streamed": tts.streams(engine.id) if ok else None,
            "first_byte_ms_p50": round(statistics.median(firsts), 1) if firsts else None, "first_byte_ms_max": max(firsts, default=None),
            "total_ms_p50": round(statistics.median(r["total_ms"] for r in ok), 1) if ok else None,
            "audio_s": round(seconds, 2), "chars_per_second": round(chars / seconds, 1) if seconds else None,
            "cost_usd": round(sum(r["cost_usd"] for r in rows), 6), "lines": rows}


def run(engines: Iterable[genai_client.ModelRole], lines: Iterable[dict], settings: Settings, ledger, out_dir: Path,
        synth: Synth | None = None, sleep: Callable[[float], None] | None = None, pace_s: float | None = None) -> dict:
    """Every line on every engine, PACE_S apart; WAVs under out_dir/<model id>/, and the result as a dict."""
    synth, sleep = synth or _synth, sleep or time.sleep
    pace_s = PACE_S if pace_s is None else pace_s
    lines, requests, result = list(lines), 0, {}
    for engine in engines:
        rows, stopped = [], False
        for line in lines:
            row = {"n": line["n"], "role": line["role"], "status": "skipped", "file": None, "first_byte_ms": None, "total_ms": None,
                   "audio_s": 0.0, "chars": len(line["text_bn"]), "chars_per_second": None, "cost_usd": 0.0}
            rows.append(row)
            if stopped:
                continue
            if requests:
                sleep(pace_s)
            requests += 1
            ledger.check(RESERVE_PER_LINE)
            spoken = _speak(engine, line["text_bn"], settings, synth, sleep)
            row["status"] = spoken["status"]
            if spoken["status"] == "ok":
                pcm = spoken["pcm"]
                seconds = len(pcm) / (tts.RATE * tts.SAMPLE_BYTES)
                row["cost_usd"], row["cost_estimated"] = _cost(engine, spoken["usage"], seconds)
                target = out_dir / engine.id / f"{line['n']}.wav"
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(tts.wav_header(len(pcm)) + pcm)
                row.update(file=target.relative_to(out_dir).as_posix(), first_byte_ms=spoken["first_byte_ms"], total_ms=spoken["total_ms"],
                           audio_s=round(seconds, 2), chars_per_second=round(row["chars"] / seconds, 1) if seconds else None)
            else:
                row.update(message=spoken["message"], **({"quota": spoken["quota"]} if spoken.get("quota") else {}))
                row["cost_usd"] = RESERVE_PER_LINE if spoken["billed"] else 0.0
                stopped = spoken["stop"]
            ledger.record(row["cost_usd"])
            first = f"{row['first_byte_ms']:7.0f} ms" if row["first_byte_ms"] is not None else "      none"
            print(f"  {engine.id:28s} {line['n']} {line['role']}  {str(row['status']):8s} first byte {first}  {row['audio_s']:5.1f} s"
                  f"  ${row['cost_usd']:.4f} | spent ${ledger.spent():.4f}", flush=True)
        result[engine.id] = _summary(engine, settings, rows)
    return {"run_at": datetime.now(timezone.utc).isoformat(timespec="seconds"), "voice": settings.tts_voice, "style": tts.URGENT_STYLE,
            "native_check": "pending", "lines": lines, "engines": result}


def main(argv: list[str] | None = None) -> None:
    from eval.budget import DEFAULT_FILE, SpendLedger

    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dry-run", action="store_true", help="the plan and its reserve; no model call, nothing written")
    parser.add_argument("--spend-file", type=Path, default=DEFAULT_FILE)
    parser.add_argument("--out-dir", type=Path, default=OUT_DIR)
    parser.add_argument("--result", type=Path, default=RESULT_FILE)
    parser.add_argument("--pace-s", type=float, default=PACE_S)
    parser.add_argument("--timeout-s", type=float, default=TIMEOUT_S)
    args = parser.parse_args(argv)
    settings = get_settings().model_copy(update={"tts_voice": VOICE, "tts_timeout_s": args.timeout_s})
    pair, ledger = tts.engines(), SpendLedger(args.spend_file)
    if args.dry_run:
        requests = len(pair) * len(LINES)
        print(f"dry run: {len(LINES)} lines on {len(pair)} engines in {VOICE}, urgent style, {args.pace_s:.0f} s apart (about "
              f"{max(0, requests - 1) * args.pace_s:.0f} s); reserve ${requests * RESERVE_PER_LINE:.2f} (ledger ${ledger.spent():.4f} of "
              f"${ledger.cap_usd:.2f} spent, {ledger.path.name}). Nothing sent, nothing written.")
        for engine in pair:
            where, style = engine.location or settings.genai_location, engine.tts_style or "prompt"
            print(f"  {engine.name:13s} {engine.id:28s} {where:8s} style in {style:8s} ${engine.input_usd_per_m:.2f} in / "
                  f"${engine.output_usd_per_m:.2f} out per M -> {args.out_dir / engine.id}")
        for line in LINES:
            print(f"  {line['n']} {line['role']}| {line['text_bn']}   ({line['text_en']}; native check {line['native_check']})")
        return
    genai_client.select_backend(settings)  # stop here, not mid-run, when Gemini is off
    result = run(pair, LINES, settings, ledger, args.out_dir, pace_s=args.pace_s)
    args.result.parent.mkdir(parents=True, exist_ok=True)
    args.result.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    for model_id, row in result["engines"].items():
        verdict = "reachable" if row["reachable"] else f"error {row['error']}"
        print(f"{model_id:28s} {verdict:10s} first byte p50 {row['first_byte_ms_p50']} ms, total p50 {row['total_ms_p50']} ms, "
              f"{row['audio_s']} s audio, {row['chars_per_second']} chars/s, ${row['cost_usd']:.4f}")
    print(f"wrote {args.result}; listen to {args.out_dir} with a native speaker before pinning an engine")


if __name__ == "__main__":
    main()
