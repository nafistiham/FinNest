#!/usr/bin/env python3
"""Add or update localisation keys in both ARB files atomically.

The script takes an exclusive file lock, so parallel read-modify-write cycles
never overwrite each other. Run `make gen` afterwards to regenerate the
localisation classes.

Usage (run from apps/mobile):
  python3 tool/arb_add.py KEY "Bangla text" "English text" [KEY2 "bn" "en" ...]
  python3 tool/arb_add.py --json entries.json      # {"key": {"bn": "...", "en": "...", "meta": {...}}}

`meta` (optional) is written as the "@key" entry in the Bangla template, e.g.
{"placeholders": {"name": {"type": "String"}}}.
"""
from __future__ import annotations

import fcntl
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BN = ROOT / "lib/l10n/app_bn.arb"
EN = ROOT / "lib/l10n/app_en.arb"
LOCK = ROOT / "lib/l10n/.arb.lock"


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def dump(path: Path, data: dict) -> None:
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def main(argv: list[str]) -> int:
    entries: dict[str, dict] = {}
    if len(argv) >= 2 and argv[0] == "--json":
        entries = json.loads(Path(argv[1]).read_text(encoding="utf-8"))
    else:
        if len(argv) % 3 != 0 or not argv:
            print(__doc__)
            return 2
        for i in range(0, len(argv), 3):
            entries[argv[i]] = {"bn": argv[i + 1], "en": argv[i + 2]}

    LOCK.parent.mkdir(parents=True, exist_ok=True)
    with LOCK.open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        bn, en = load(BN), load(EN)
        for key, value in entries.items():
            bn[key] = value["bn"]
            en[key] = value["en"]
            if "meta" in value:
                bn["@" + key] = value["meta"]
        dump(BN, bn)
        dump(EN, en)
        fcntl.flock(lock, fcntl.LOCK_UN)
    print(f"added/updated {len(entries)} key(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
