"""A second synthetic world for tuning, so the scored world (seed 42) is only ever used for the final number.

Same generator and the same shipped scorer as the synthetic world; only the random draw differs.

    python -m eval.dev_world --seed 7          # writes .dev_world/seed7/{data/seed,models/mule}
"""

from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path

from case_zero import PROJECT_DIR
from bhorosha_graph.bundle import build_bundle, load_world_tables, save_bundle
from bhorosha_synth import generate

SERVICE_DIR = Path(__file__).resolve().parent.parent
SCORER_FILES = ("model.lgb", "scorer.json", "features.parquet")


def build_dev_world(seed: int, out: Path) -> Path:
    """Generate world `seed` into `out/data/seed`, build its graph bundle and copy the shipped scorer beside it."""
    if (out / "models" / "mule" / "graph.pkl").exists():
        return out
    if generate.main(["--seed", str(seed), "--out", str(out / "data" / "seed")]) != 0:
        raise RuntimeError(f"world generation failed for seed {seed}")
    save_bundle(build_bundle(load_world_tables(out / "data" / "seed")), out / "models" / "mule" / "graph.pkl")
    for name in SCORER_FILES:
        shutil.copy(PROJECT_DIR / "models" / "mule" / name, out / "models" / "mule" / name)
    return out


def default_dir(seed: int) -> Path:
    return SERVICE_DIR / ".dev_world" / f"seed{seed}"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seed", type=int, default=7)
    args = parser.parse_args()
    print(build_dev_world(args.seed, default_dir(args.seed)))
    sys.exit(0)
