"""Generate the labelled dialogue set with Gemini and write eval/scam_dialogues.jsonl.

    RISK_MW_GENAI_ENABLED=true RISK_MW_PROJECT_ID=... RISK_MW_GENAI_BACKEND=vertex python -m eval.build_dialogues

6 scam archetypes x 2 channels x 15 dialogues (about 180) and 7 benign look-alike types x 2 channels x 5 (about 70).
Each batch is cached in eval/.gen_cache/, so a re-run never pays twice. Spend is capped by eval/budget.py.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))  # run as eval/x.py, app and eval are one level up
from app import genai_client
from eval import dialogues
from eval.budget import SpendLedger

HERE = Path(__file__).resolve().parent
CACHE = HERE / ".gen_cache"
OUT = HERE / "scam_dialogues.jsonl"
SCAM_PER_CALL, BENIGN_PER_CALL = 15, 5
RESERVE = {"scam": 0.06, "benign": 0.03}
MAX_TOKENS = {"scam": 14000, "benign": 6000}


def batch(kind: str, description: str, channel: str, label: str, n: int, ledger: SpendLedger) -> dialogues.GenBatch:
    cached = CACHE / f"{kind}-{channel}-{n}.json"
    if cached.exists():
        return dialogues.GenBatch.model_validate_json(cached.read_text(encoding="utf-8"))
    ledger.check(RESERVE[label])
    result = genai_client.call("gen_dialogues", "workhorse", dialogues.gen_prompt(kind, description, channel, n, label), schema=dialogues.GenBatch,
                               system=dialogues.GEN_SYSTEM, timeout_s=180, thinking_level="low", max_output_tokens=MAX_TOKENS[label])
    ledger.record(result.cost_usd)
    gen = result.parsed if isinstance(result.parsed, dialogues.GenBatch) else dialogues.GenBatch.model_validate_json(result.text)
    CACHE.mkdir(exist_ok=True)
    cached.write_text(gen.model_dump_json(), encoding="utf-8")
    print(f"  {kind}/{channel}: {len(gen.dialogues)} dialogues, ${result.cost_usd:.4f} ({result.tokens_in} in, {result.tokens_out} out) | spent ${ledger.spent():.4f}", flush=True)
    return gen


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--smoke", action="store_true", help="one tiny benign batch only")
    args = parser.parse_args()
    ledger = SpendLedger()
    if args.smoke:
        gen = batch("benign_delivery", dialogues.BENIGN["benign_delivery"], "bangla", "benign", 2, ledger)
        print(json.dumps(gen.model_dump(), ensure_ascii=False, indent=1)[:1500])
        return
    rows, seen = [], set()
    for label, kinds, n in (("scam", dialogues.ARCHETYPES, SCAM_PER_CALL), ("benign", dialogues.BENIGN, BENIGN_PER_CALL)):
        for kind, description in kinds.items():
            for channel in dialogues.CHANNELS:
                rows += dialogues.to_rows(batch(kind, description, channel, label, n, ledger), kind, channel, label, batch=f"g{n}", seen=seen)
    rows = dialogues.split(rows)
    OUT.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows), encoding="utf-8")
    held = [r for r in rows if r["split"] == "held_out"]
    print(f"{len(rows)} dialogues ({sum(r['label'] == 'scam' for r in rows)} scam, {sum(r['label'] == 'benign' for r in rows)} benign); "
          f"held out {len(held)} -> {OUT} | spent ${ledger.spent():.4f}")


if __name__ == "__main__":
    main()
