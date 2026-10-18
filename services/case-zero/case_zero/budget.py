"""A hard cap on Gemini spend that survives restarts.

Every call holds its own worst case against the cap before it is sent and settles to its real cost
after (an estimate when we stopped waiting, nothing for an error reply). Holds and writes go through one
lock per spend file, shared by every ledger on that file in this process (the agent and the judge in an
eval), so concurrent calls cannot all pass the check. The total lives in a small JSON file, so separate
runs (server, eval, scripts) share one cap; holds are per process.
"""

from __future__ import annotations

import json
import os
import threading
from dataclasses import dataclass
from pathlib import Path

_REGISTRY = threading.Lock()
_LOCKS: dict[Path, threading.Lock] = {}
_HELD: dict[Path, float] = {}   # spend file -> what calls in flight have reserved


class BudgetExceeded(RuntimeError):
    """Raised before a Gemini call that could take spend past the cap."""


@dataclass
class SpendLedger:
    path: Path
    cap_usd: float

    def __post_init__(self) -> None:
        self._key = Path(self.path).resolve()
        with _REGISTRY:
            self._lock = _LOCKS.setdefault(self._key, threading.Lock())

    def _read(self) -> dict:
        try:
            return json.loads(self.path.read_text(encoding="utf-8"))
        except (FileNotFoundError, json.JSONDecodeError):
            return {"spent_usd": 0.0, "calls": 0}

    def spent(self) -> float:
        return float(self._read()["spent_usd"])

    def calls(self) -> int:
        return int(self._read()["calls"])

    def held(self) -> float:
        return _HELD.get(self._key, 0.0)

    def check(self, reserve_usd: float) -> None:
        spent, held = self.spent(), self.held()
        if spent + held + reserve_usd > self.cap_usd:
            raise BudgetExceeded(f"Gemini spend cap reached: ${spent:.4f} spent and ${held:.4f} held of ${self.cap_usd:.2f}; next call could cost ${reserve_usd:.2f}")

    def reserve(self, usd: float) -> float:
        """Hold a call's worst case against the cap until settle(); raises BudgetExceeded instead."""
        with self._lock:
            self.check(usd)
            _HELD[self._key] = self.held() + usd
        return usd

    def settle(self, held_usd: float, cost_usd: float) -> None:
        """Release a hold and record what the call cost (0: it was not billed)."""
        with self._lock:
            _HELD[self._key] = max(0.0, self.held() - held_usd)
            if cost_usd > 0:
                self._add(cost_usd)

    def record(self, cost_usd: float) -> None:
        with self._lock:
            self._add(cost_usd)

    def _add(self, cost_usd: float) -> None:  # callers hold the lock
        state = self._read()
        state = {"spent_usd": round(state["spent_usd"] + cost_usd, 6), "calls": state["calls"] + 1}
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(state), encoding="utf-8")
        os.replace(tmp, self.path)
