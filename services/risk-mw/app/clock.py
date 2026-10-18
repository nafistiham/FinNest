"""The scenario clock: the moment a payee is scored at, decided by the server and never by a request.

The synthetic world has a timeline, and the demo transfer (Rina to acct_01070) happens at 2026-11-10T14:13:00. Scoring a
payee "now" means scoring it on the events before this moment, so the moment must not be something a caller can move:
a client that could ask for the end of the world would see the ring after it has finished. In demo mode, or whenever
auth is off, the service stands at the demo transfer unless RISK_MW_SCENARIO_NOW moves it; in production it reads the
wall clock in Dhaka.
"""

from __future__ import annotations

from collections.abc import Callable
from datetime import datetime, timedelta, timezone

from app.settings import SCENARIO_TS_FORMAT, Settings

DEMO_SCENARIO_NOW = "2026-11-10T14:13:00"  # Rina's 7,900 to acct_01070 in the synthetic world (seed 42)
DHAKA = timezone(timedelta(hours=6), "Asia/Dhaka")  # Bangladesh keeps no daylight saving; no tz database needed


def dhaka_now() -> datetime:
    return datetime.now(DHAKA)


def scenario_now(settings: Settings, wall_clock: Callable[[], datetime] = dhaka_now) -> str:
    """The as_of every payee score uses, in the world's timestamp format."""
    if settings.scenario_now:
        return settings.scenario_now
    if settings.demo_mode or not settings.auth_required:
        return DEMO_SCENARIO_NOW
    return wall_clock().strftime(SCENARIO_TS_FORMAT)
