"""Time to Apa's first live "why" audio (spec US-3 S2: audio within 2 s, card already up). A PAID check.

    python scripts/tts_latency.py --dry-run                                  # the plan only: no request, no spend
    python scripts/tts_latency.py --base-url https://risk-mw-....run.app    # the deployed service, with TTS on there
    python scripts/tts_latency.py --base-url http://127.0.0.1:8080 -n 2      # a local uvicorn started with RISK_MW_TTS_ENABLED=true

Each request is one Gemini TTS call (a few tenths of a cent) on a quota of a few requests a minute, so requests go PACE_S
apart, and each speaks a different sample so none is a cache hit. Reports the time to the first audio byte after the WAV
header, and the total. Spend goes on eval/budget.py's SpendLedger: the reserve is checked before each request and the cost is
recorded after, estimated from the audio length (25 audio tokens a second), because the service does not report its bill.
Set AUTH_HEADER (as for scripts/smoke.sh) when the service checks Firebase tokens. The route speaks only text /v1/apa/why
signed, so set RISK_MW_APA_TOKEN_SECRET to the service's secret: the samples are signed with it here.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import statistics
import sys
import time
from collections.abc import Callable, Iterator
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))

from app import apa, genai_client, tts  # noqa: E402
from app.settings import Settings  # noqa: E402

SAMPLES = (
    "কলার আপনার কোড চেয়েছে, তাই থামালাম। কোড কাউকে বলবেন না, কলটা কেটে দিন।",
    "ব্যাংক কখনো ফোনে পিন চায় না। কেউ চাইলে বুঝবেন সে প্রতারক, তাই এটা আটকে রাখলাম।",
    "যিনি ফোনে আছেন তিনি আপনার কন্টাক্টে নেই, আর টাকা পাঠাতে তাড়া দিচ্ছেন। একটু থামুন।",
    "লটারির টাকা পেতে আগে টাকা পাঠাতে হয় না। এটা প্রতারণার চেনা কৌশল, তাই থামালাম।",
    "কেউ আপনাকে বলে বলে পিন বদলাতে বলছে। ব্যাংক এভাবে করায় না, কলটা কেটে দিন।",
)
PACE_S = 20.0
TARGET_MS = 2000.0
HEADER_BYTES = 44
AUDIO_TOKENS_PER_S = 25
TOKENS_IN_ESTIMATE = 200  # the style prompt plus a short Bangla line, rounded up
Post = Callable[[str], tuple[int, Iterator[bytes]]]


def estimate_cost(audio_bytes: int) -> float:
    seconds = audio_bytes / (tts.RATE * tts.SAMPLE_BYTES)
    return genai_client.cost_usd(genai_client.roles()["tts"], TOKENS_IN_ESTIMATE, math.ceil(seconds * AUDIO_TOKENS_PER_S))


def request_body(text: str, settings: Settings) -> dict:
    return {"user_id": "tts-latency", "text_bn": text, "token": apa.sign_why(text, settings)[0]}


def poster(base_url: str, auth_header: str, timeout_s: float = 30.0) -> Post:
    import httpx

    name, _, value = auth_header.partition(":")
    client = httpx.Client(base_url=base_url, timeout=timeout_s, headers={name.strip(): value.strip()})
    settings = Settings()  # RISK_MW_APA_TOKEN_SECRET from the environment

    def post(text: str) -> tuple[int, Iterator[bytes]]:
        request = client.build_request("POST", "/v1/apa/why-audio", json=request_body(text, settings))
        response = client.send(request, stream=True)

        def chunks() -> Iterator[bytes]:
            try:
                yield from response.iter_raw()
            finally:
                response.close()
        return response.status_code, chunks()
    return post


def run(texts: tuple[str, ...], post: Post, ledger, pace_s: float = PACE_S) -> list[dict]:
    rows = []
    for i, text in enumerate(texts):
        if i and pace_s:
            time.sleep(pace_s)
        ledger.check(tts.RESERVE_USD)
        started = time.perf_counter()
        status, chunks = post(text)
        received, first_ms = 0, None
        for chunk in chunks:
            received += len(chunk)
            if first_ms is None and received > HEADER_BYTES:
                first_ms = (time.perf_counter() - started) * 1000
        total_ms = (time.perf_counter() - started) * 1000
        audio = max(0, received - HEADER_BYTES) if status == 200 else 0
        cost = estimate_cost(audio) if audio else 0.0
        ledger.record(cost)
        rows.append({"text_bn": text, "status": status, "first_audio_ms": round(first_ms, 1) if first_ms is not None else None,
                     "total_ms": round(total_ms, 1), "audio_s": round(audio / (tts.RATE * tts.SAMPLE_BYTES), 2), "cost_usd_est": cost})
        first = f"{first_ms:7.0f} ms" if first_ms is not None else "     none"
        print(f"  {status}  first audio {first}  total {total_ms:7.0f} ms  {rows[-1]['audio_s']:5.1f} s audio  ~${cost:.4f}"
              f" | spent ${ledger.spent():.4f}", flush=True)
    return rows


def summary(rows: list[dict]) -> dict:
    firsts = [r["first_audio_ms"] for r in rows if r["first_audio_ms"] is not None]
    return {"n": len(rows), "with_audio": len(firsts), "first_audio_ms_p50": round(statistics.median(firsts), 1) if firsts else None,
            "first_audio_ms_max": max(firsts) if firsts else None, "target_ms": TARGET_MS,
            "s2_met": bool(firsts) and len(firsts) == len(rows) and max(firsts) <= TARGET_MS}


def main(argv: list[str] | None = None) -> None:
    from eval.budget import DEFAULT_FILE, SpendLedger

    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-url", default="http://127.0.0.1:8080")
    parser.add_argument("-n", type=int, default=3, choices=range(1, len(SAMPLES) + 1), metavar=f"1..{len(SAMPLES)}")
    parser.add_argument("--pace-s", type=float, default=PACE_S)
    parser.add_argument("--spend-file", type=Path, default=DEFAULT_FILE)
    parser.add_argument("--out", type=Path, default=None, help="write the rows and the summary as JSON")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)
    ledger, texts = SpendLedger(args.spend_file), SAMPLES[: args.n]
    if args.dry_run:
        print(f"dry run: would POST {args.base_url}/v1/apa/why-audio {len(texts)} times, {args.pace_s:.0f} s apart, reserving "
              f"${tts.RESERVE_USD:.2f} each (ledger ${ledger.spent():.4f} of ${ledger.cap_usd:.2f} spent, {ledger.path.name})")
        for text in texts:
            print(f"  {text}")
        return
    rows = run(texts, poster(args.base_url, os.environ.get("AUTH_HEADER", "X-Demo-User: tts-latency")), ledger, args.pace_s)
    result = {"base_url": args.base_url, "rows": rows, "summary": summary(rows)}
    print(json.dumps(result["summary"], indent=2))
    if args.out:
        args.out.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
