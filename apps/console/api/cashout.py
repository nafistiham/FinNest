"""The cash-out view's read side: fixtures/cashout.json, validated once and kept.

The fixture is written by tools/build_cashout.py, which replays the radar's common point of cash-out rules over the
campaign world. Nothing here replays the rules, reads Firestore or calls Gemini; a request only slices what is
already in memory. Same discipline as api/campaigns.py: a missing or malformed fixture raises `Unavailable` with a
reason the route hands back as `available: false`, the file is re-read only when its size or mtime changes, and it is
validated against the strict schema as a whole, so one broken section is a missing source, not a half-drawn map.
"""

from __future__ import annotations

import json
import logging
import re
import threading
from dataclasses import dataclass
from datetime import date as Date
from pathlib import Path
from typing import Any

from pydantic import ValidationError

from api.schemas import CashoutDay, CashoutFixture

log = logging.getLogger("cashout")

DEFAULT_FIXTURE = Path(__file__).resolve().parents[1] / "fixtures" / "cashout.json"
FIXTURE = DEFAULT_FIXTURE
DAY = re.compile(r"\d{4}-\d{2}-\d{2}")
REBUILD_HINT = "run tools/build_cashout.py"


class Unavailable(RuntimeError):
    """The fixture cannot be served; the message says why, for the console to show."""


@dataclass(frozen=True)
class Loaded:
    fixture: CashoutFixture
    days: dict[str, CashoutDay]


_lock = threading.Lock()
_cache: dict[str, Any] = {"stamp": None, "loaded": None}


def forget() -> None:
    """Drop the cached fixture; the next read loads it again. Used by the tests."""
    with _lock:
        _cache.update(stamp=None, loaded=None)


def is_day(value: str) -> bool:
    """YYYY-MM-DD and a real calendar date."""
    if not DAY.fullmatch(value):
        return False
    try:
        Date.fromisoformat(value)
    except ValueError:
        return False
    return True


def _parse(path: Path) -> Loaded:
    try:
        fixture = CashoutFixture.model_validate(json.loads(path.read_text(encoding="utf-8")))
    # ValidationError is a ValueError too, so it is caught first; the ValueError branch is bad JSON or bytes that are
    # not UTF-8 (JSONDecodeError, UnicodeDecodeError).
    except ValidationError as exc:
        log.warning("cashout fixture at %s does not match the schema: %s", path, exc)
        raise Unavailable(f"{path.name} does not match the schema ({exc.error_count()} errors); {REBUILD_HINT}") from exc
    except (OSError, ValueError) as exc:
        log.warning("cashout fixture unreadable at %s: %s", path, exc)
        raise Unavailable(f"{path.name} could not be read ({type(exc).__name__}); {REBUILD_HINT}") from exc
    return Loaded(fixture=fixture, days={d.date: d for d in fixture.days})


def load() -> Loaded:
    try:
        stat = FIXTURE.stat()
    except OSError as exc:
        raise Unavailable(f"{FIXTURE.name} is missing; {REBUILD_HINT}") from exc
    stamp = (str(FIXTURE), stat.st_mtime_ns, stat.st_size)
    with _lock:
        if _cache["stamp"] != stamp:
            # Cleared first: a fixture that turns malformed must not keep serving the last good one.
            _cache.update(stamp=None, loaded=None)
            _cache.update(loaded=_parse(FIXTURE), stamp=stamp)
        return _cache["loaded"]


def whole() -> dict[str, Any]:
    fixture = load().fixture
    return {"available": True, **{name: getattr(fixture, name) for name in CashoutFixture.model_fields}}


def day(value: str) -> dict[str, Any] | None:
    """One daily run with what its map draws; None when no run has that date. `value` is checked by is_day first."""
    loaded = load()
    found = loaded.days.get(value)
    if found is None:
        return None
    fixture = loaded.fixture
    return {
        "available": True, "date": found.date, "as_of": found.as_of, "seeds": found.seeds, "cashouts": found.cashouts,
        "tills": [t for t in fixture.tills if t.opened is None or t.opened <= found.as_of],
        "till_flags": found.till_flags,
        "clusters": [c for c in fixture.clusters if found.date in c.days],
        "candidates": [c for c in fixture.candidates if found.date in c.days],
        "not_flagged": found.not_flagged,
        "events": fixture.events.get(found.date, []),
    }
