"""Write fixtures/overview.json from the seed world.

A build step, not a request handler: the mule board is a SHAP pass per account and takes most of a
minute. Committing the result means the console works with no backend at all, the API can answer
instantly while it recomputes, and the proposal and the console cannot disagree - they read the
same file.

    python3 tools/build_overview.py            # write fixtures/overview.json
    python3 tools/build_overview.py --check    # fail if the committed file is stale
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from api import aggregate  # noqa: E402

FIXTURE = ROOT / "fixtures" / "overview.json"
ROLLUP = ROOT / "fixtures" / "payee_rollup.json"
# generated_at is the one field that legitimately differs between two runs of the same data.
VOLATILE = ("generated_at",)


def _comparable(payload: dict) -> dict:
    return {k: v for k, v in payload.items() if k not in VOLATILE}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="compare against the committed fixture")
    parser.add_argument("--out", type=Path, default=FIXTURE)
    args = parser.parse_args(argv)

    started = time.perf_counter()
    world = aggregate.load_world()
    replayed = aggregate.replay(world)
    rollup = replayed.pop("payee_rollup")
    payload = aggregate.build(world=world, replayed=replayed)
    took = time.perf_counter() - started

    if args.check:
        if not args.out.exists():
            print(f"FAIL {args.out} does not exist", file=sys.stderr)
            return 1
        committed = json.loads(args.out.read_text())
        if _comparable(committed) != _comparable(payload):
            print(f"FAIL {args.out} is stale; run tools/build_overview.py", file=sys.stderr)
            return 1
        print(f"ok   {args.out.name} is current ({took:.1f}s to recompute)")
        return 0

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(payload, indent=1, ensure_ascii=False) + "\n")
    # Per-payee counts for the Case Zero watch-list join. A build artefact for the same reason the
    # overview is one: on one Cloud Run CPU, computing it in a request took fifteen seconds.
    ROLLUP.write_text(json.dumps(rollup, separators=(",", ":")) + "\n")
    replay = payload["replay"]
    print(f"wrote {args.out.relative_to(ROOT)}  ({args.out.stat().st_size / 1024:.0f} KB, {took:.1f}s)")
    print(f"wrote {ROLLUP.relative_to(ROOT)}  ({ROLLUP.stat().st_size / 1024:.0f} KB, {len(rollup)} payees)")
    print(f"  scored {replay['denominator']}  mix {replay['mix']}")
    print(f"  catch {replay['rates']['catch_rate']} of {replay['rates']['catch_rate_denominator']}"
          f"   false positives {replay['rates']['false_positive_rate']} of "
          f"{replay['rates']['false_positive_rate_denominator']}")
    print(f"  {payload['weakest_link']['sentence']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
