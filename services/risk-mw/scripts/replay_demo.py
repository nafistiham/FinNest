"""Replay a scripted scam call through risk-mw, turn by turn (the transcript-first demo path).

    python scripts/replay_demo.py                                   # hero call, in-process
    python scripts/replay_demo.py --script loan_fee --base-url https://risk-mw-....run.app
    python scripts/replay_demo.py --all --out /tmp/replay.json

In-process runs use the keyword stub unless RISK_MW_GENAI_ENABLED=true and RISK_MW_PROJECT_ID are set.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent.parent / "synth"))

HERO_FLAGS = {"call_active": True, "caller_in_contacts": False, "sim_swap": True}


def poster(base_url: str | None):
    if base_url:
        import httpx

        client = httpx.Client(base_url=base_url, timeout=30.0)
        return lambda path, body: client.post(path, json=body).raise_for_status().json()
    from fastapi.testclient import TestClient

    from main import app

    client = TestClient(app)
    return lambda path, body: client.post(path, json=body).raise_for_status().json()


def show(result: dict) -> None:
    print(f"\n== {result['script']} ({result['label']}) — detected at turn {result['detected_turn']}, secret asked at turn {result['secret_turn']}")
    for t in result["timeline"]:
        print(f"  {t['turn']:>2} {t['speaker']:6s} {t['scam_type']:22s} conf {t['confidence']:.2f} rolling {t['rolling_score']:.2f} {t['recommended_action']:13s} | {t['text'][:70]}")
    if result["decision"]:
        print(f"  decision {result['decision']} ({', '.join(result['reasons'])})")
    if result["apa"]:
        apa = result["apa"]
        print(f"  Apa [{apa['ui']}, warning {apa['warning_id'] or 'none: the floor, earcon and vibration only'}]")
        for line in apa["lines"] or ():
            print(f"    {line['role']}| {line['text_bn']}")


def main() -> None:
    from app import demo_replay

    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--script", default="hero_rina_fake_care")
    parser.add_argument("--all", action="store_true")
    parser.add_argument("--base-url", default=None)
    parser.add_argument("--out", default=None)
    args = parser.parse_args()
    post = poster(args.base_url)
    scripts = demo_replay.load_scripts()
    chosen = scripts if args.all else [s for s in scripts if s["id"] == args.script]
    results = [demo_replay.replay(post, s, HERO_FLAGS if s["id"] == "hero_rina_fake_care" else {}) for s in chosen]
    for r in results:
        show(r)
    if args.out:
        Path(args.out).write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
