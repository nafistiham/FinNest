"""Train the mule scorer on the seed world, report metrics, and package artefacts.

    python eval/mule_eval.py --seed-dir ../../data/seed --artefacts ../../models/mule --out ../../eval/results/mule.json
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from datetime import UTC, datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from bhorosha_graph.bundle import build_bundle, load_world_tables, save_bundle  # noqa: E402
from bhorosha_graph.scorer import train_and_evaluate  # noqa: E402


def _markdown(metrics: dict) -> str:
    test = metrics["test"]
    rows = [
        "| Metric | Value |", "|---|---|",
        f"| AUC-PR (test cutoffs) | {test['auc_pr']} |",
        f"| Precision @ top 50 per cutoff | {test['precision_at_50']} |",
        f"| Recall at precision 0.9 | {test['recall_at_precision_0.9']} |",
        f"| Ring-level recall @ 50 | {test['ring_level_recall']} |",
    ]
    rows += [f"| Recall @ 50 · {t} | {v} |" for t, v in test["recall_by_typology"].items()]
    split = metrics["split"]
    rows.append(f"| Split | train cutoffs {', '.join(c[:10] for c in split['train_cutoffs'])} ({split['train_positives']} positives / {split['train_rows']} rows); test cutoffs {', '.join(c[:10] for c in split['test_cutoffs'])} ({split['test_positives']} / {split['test_rows']}) |")
    return "\n".join(rows) + f"\n\n{metrics['note']}\n"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--seed-dir", type=Path, default=Path(__file__).resolve().parents[3] / "data" / "seed")
    parser.add_argument("--artefacts", type=Path, default=None, help="write model.lgb, features.parquet, scorer.json, graph.pkl here (omit to evaluate only)")
    parser.add_argument("--out", type=Path, default=Path(__file__).resolve().parents[3] / "eval" / "results" / "mule.json")
    args = parser.parse_args(argv)

    started = time.perf_counter()
    world = load_world_tables(args.seed_dir)
    bundle = build_bundle(world)
    result = train_and_evaluate(world, bundle)
    elapsed = round(time.perf_counter() - started, 1)

    artefacts: dict[str, int] = {}
    if args.artefacts is not None:
        result.scorer.save(args.artefacts)
        save_bundle(bundle, args.artefacts / "graph.pkl")
        artefacts = {p.name: p.stat().st_size for p in args.artefacts.iterdir()}
    metrics = {**result.metrics, "generated_at": datetime.now(UTC).isoformat(timespec="seconds"), "seed_checksum": world.checksum(), "artefacts_written": artefacts}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(metrics, indent=2) + "\n", encoding="utf-8")
    args.out.with_suffix(".md").write_text(_markdown(metrics), encoding="utf-8")
    print(json.dumps({"out": str(args.out), "artefacts": str(args.artefacts) if args.artefacts else None, "test": metrics["test"], "train_seconds": elapsed}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
