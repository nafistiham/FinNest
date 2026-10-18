"""A hard cap on eval spend (Gemini and text-to-speech), persisted in .eval_spend.json (git-ignored)."""

from __future__ import annotations

import json
import os
import threading
from dataclasses import dataclass, field
from pathlib import Path

DEFAULT_FILE = Path(__file__).resolve().parent.parent / ".eval_spend.json"


class BudgetExceeded(RuntimeError):
    pass


@dataclass
class SpendLedger:
    path: Path = DEFAULT_FILE
    cap_usd: float = float(os.environ.get("RISK_MW_EVAL_BUDGET_USD", "1.60"))
    _lock: threading.Lock = field(default_factory=threading.Lock, repr=False)

    def _read(self) -> dict:
        try:
            return json.loads(self.path.read_text(encoding="utf-8"))
        except (FileNotFoundError, json.JSONDecodeError):
            return {"spent_usd": 0.0, "calls": 0}

    def spent(self) -> float:
        return float(self._read()["spent_usd"])

    def check(self, reserve_usd: float) -> None:
        if self.spent() + reserve_usd > self.cap_usd:
            raise BudgetExceeded(f"eval spend cap: ${self.spent():.4f} of ${self.cap_usd:.2f} spent; next call may cost ${reserve_usd:.3f}")

    def record(self, cost_usd: float) -> None:
        with self._lock:
            s = self._read()
            self.path.write_text(json.dumps({"spent_usd": round(s["spent_usd"] + cost_usd, 6), "calls": s["calls"] + 1}), encoding="utf-8")
