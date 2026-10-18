"""The Incidents view's read side: fixtures/campaigns.json, validated once and kept.

The fixture is written by tools/build_campaigns.py, which runs the radar over the campaign world.
Nothing here runs the radar, reads Firestore or calls Gemini; a request only slices what is already
in memory.

A missing or malformed fixture raises `Unavailable` with a reason the route hands back as
`available: false`, the way `_read_eval` makes a model card NO DATA: the console shows that the
source is missing, never a zero. The file is re-read when its size or mtime changes, so a rebuilt
fixture is picked up without a restart, and validated against the strict schema as a whole, so one
broken section is a missing source rather than a half-drawn screen.
"""

from __future__ import annotations

import json
import logging
import re
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from pydantic import ValidationError

from api.schemas import CampaignAttempt, CampaignsFixture, RadarCampaign, RadarFiring, RadarIncident

log = logging.getLogger("campaigns")

DEFAULT_FIXTURE = Path(__file__).resolve().parents[1] / "fixtures" / "campaigns.json"
FIXTURE = DEFAULT_FIXTURE
INCIDENT_ID = re.compile(r"inc_[0-9a-f]{12}")
REBUILD_HINT = "run tools/build_campaigns.py"


class Unavailable(RuntimeError):
    """The fixture cannot be served; the message says why, for the console to show."""


@dataclass(frozen=True)
class Loaded:
    fixture: CampaignsFixture
    incidents: dict[str, RadarIncident]
    attempts: dict[str, CampaignAttempt]
    firings: dict[tuple[str, str, str], tuple[RadarFiring, ...]]


_lock = threading.Lock()
_cache: dict[str, Any] = {"stamp": None, "loaded": None}


def forget() -> None:
    """Drop the cached fixture; the next read loads it again. Used by the tests."""
    with _lock:
        _cache.update(stamp=None, loaded=None)


def _index(fixture: CampaignsFixture) -> Loaded:
    firings: dict[tuple[str, str, str], list[RadarFiring]] = {}
    for firing in fixture.firings:
        firings.setdefault((firing.key, firing.cell, firing.run_ts), []).append(firing)
    return Loaded(
        fixture=fixture,
        incidents={i.incident_id: i for i in fixture.incidents},
        attempts={a.attempt_id: a for a in fixture.attempts},
        firings={key: tuple(rows) for key, rows in firings.items()},
    )


def _parse(path: Path) -> Loaded:
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
        return _index(CampaignsFixture.model_validate(raw))
    # ValidationError is a ValueError too, so it is caught first; the ValueError branch is bad JSON or
    # bytes that are not UTF-8 (JSONDecodeError, UnicodeDecodeError).
    except ValidationError as exc:
        log.warning("campaigns fixture at %s does not match the schema: %s", path, exc)
        raise Unavailable(f"{path.name} does not match the schema ({exc.error_count()} errors); {REBUILD_HINT}") from exc
    except (OSError, ValueError) as exc:
        log.warning("campaigns fixture unreadable at %s: %s", path, exc)
        raise Unavailable(f"{path.name} could not be read ({type(exc).__name__}); {REBUILD_HINT}") from exc


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


def listing() -> dict[str, Any]:
    fixture = load().fixture
    return {
        "available": True, "generated_at": fixture.generated_at, "source": fixture.source,
        "incidents": fixture.incidents, "campaigns": fixture.campaigns, "evaluation": fixture.evaluation,
    }


def _campaigns_holding(loaded: Loaded, incident_id: str) -> list[RadarCampaign]:
    """Every snapshot that names the incident, in id order: the view never picks one silently."""
    return sorted((c for c in loaded.fixture.campaigns if incident_id in c.incident_ids), key=lambda c: c.campaign_id)


def incident(incident_id: str) -> dict[str, Any] | None:
    """One incident with its firings, the campaigns that hold it and every attempt they draw; None if unknown."""
    loaded = load()
    found = loaded.incidents.get(incident_id) if INCIDENT_ID.fullmatch(incident_id) else None
    if found is None:
        return None
    holding = _campaigns_holding(loaded, incident_id)
    firings = [f for run in found.firing_runs for f in loaded.firings.get((found.key, found.cell, run), ())]
    wanted = set(found.attempt_ids)
    for campaign in holding:
        wanted |= set(campaign.attempt_ids)
        wanted |= {aid for source, target, _entity in campaign.evidence for aid in (source, target)}
    attempts = sorted((loaded.attempts[aid] for aid in wanted if aid in loaded.attempts), key=lambda a: (a.ts, a.attempt_id))
    return {
        "available": True, "incident": found, "campaigns": holding,
        "firings": sorted(firings, key=lambda f: (f.run_ts, f.window_min)), "attempts": attempts,
    }
