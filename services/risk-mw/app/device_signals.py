"""What the phone posted to /v1/risk/signals becomes the three live-risk flags the rules read.

The rules read ScoreRequest.demo_flags only. Before this module a real off-hook call, a fresh SIM and screen capture
were audited and dropped, so the phone's own signals protected nothing. Here they are derived from the caller's
stored session (app.sessions) and OR'd into demo_flags, and the answer names, per flag, whether the phone measured
it ("device") or only the demo panel said so ("demo": a demo flag, or a posted value the app lists in `simulated`,
because the app merges its demo panel into the signals it posts). Pure functions: no I/O, no mutation.

- call_active: call state OFFHOOK or RINGING, posted within RISK_MW_LIVE_SIGNAL_FRESH_S (60 s).
- sim_swap: SIM changed within RISK_MW_SIM_CHANGE_HOLD_HOURS (24 h), from subscription_changed_hours (aged by the
  time since it was posted) or device.sim_changed_at. An instant more than CLOCK_SKEW_TOLERANCE_S in the future is
  unreadable; one within it counts as just changed.
- screen_share: screen capture or projection (recording), posted within the same live window as the call state.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import UTC, datetime

from app.contracts import DemoFlags, SignalSource, SignalSources
from app.sessions import SessionState
from app.settings import Settings

log = logging.getLogger(__name__)

LIVE_CALL_STATES = frozenset({"OFFHOOK", "RINGING"})
SECONDS_PER_HOUR = 3600.0
CLOCK_SKEW_TOLERANCE_S = 300.0  # a phone clock this far ahead of the server still reads as "just changed"
LIVE_FLAGS = ("call_active", "sim_swap", "screen_share")
# The posted fields each flag is derived from; `simulated` may name either the flag or its fields.
FLAG_FIELDS: dict[str, tuple[str, ...]] = {
    "call_active": ("call_state",),
    "sim_swap": ("subscription_changed_hours", "sim_changed_at"),
    "screen_share": ("screen_capture", "screen_recording"),
}
KNOWN_SIMULATED = frozenset(FLAG_FIELDS) | frozenset(f for fields in FLAG_FIELDS.values() for f in fields)


@dataclass(frozen=True)
class DeviceFlags:
    call_active: bool = False
    sim_swap: bool = False
    screen_share: bool = False


@dataclass(frozen=True)
class DerivedSignals:
    device: DeviceFlags = DeviceFlags()  # measured by the phone
    simulated: DeviceFlags = DeviceFlags()  # posted, but forced by the demo panel (listed in `simulated`)


def _age_s(state: SessionState, now: datetime) -> float:
    return (now - state.received_at).total_seconds()


def _parse_instant(value: str | None, now: datetime) -> datetime | None:
    """An ISO-8601 instant no later than now (+ clock skew), else None and a log line."""
    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(value)
    except ValueError:
        log.warning("device.sim_changed_at %r is not ISO-8601; ignored", value)
        return None
    instant = parsed if parsed.tzinfo else parsed.replace(tzinfo=UTC)
    if (instant - now).total_seconds() > CLOCK_SKEW_TOLERANCE_S:
        log.warning("device.sim_changed_at %s is in the future; ignored", value)
        return None
    return min(instant, now)


def _reported_hours(state: SessionState, now: datetime) -> float | None:
    hours = state.signals.signals.subscription_changed_hours
    if hours is None or hours < 0:
        return None
    return hours + _age_s(state, now) / SECONDS_PER_HOUR


def _hours_since(instant: datetime | None, now: datetime) -> float | None:
    return None if instant is None else (now - instant).total_seconds() / SECONDS_PER_HOUR


def _within(hours: float | None, window_h: float) -> bool:
    return hours is not None and hours <= window_h


def _simulated_fields(state: SessionState) -> frozenset[str]:
    named = frozenset(state.signals.simulated)
    unknown = named - KNOWN_SIMULATED
    if unknown:
        log.warning("simulated names %s are not signals this service derives from; ignored", sorted(unknown))
    return named | frozenset(f for flag, fields in FLAG_FIELDS.items() if flag in named for f in fields)


def _readings(state: SessionState, now: datetime, settings: Settings) -> dict[str, bool]:
    """Per posted field: does it, on its own, support its flag at `now`?"""
    signals = state.signals.signals
    live = _age_s(state, now) <= settings.live_signal_fresh_s
    changed_at = _parse_instant(state.signals.device.sim_changed_at, now)
    return {
        "call_state": live and signals.call_state in LIVE_CALL_STATES,
        "subscription_changed_hours": _within(_reported_hours(state, now), settings.sim_change_hold_hours),
        "sim_changed_at": _within(_hours_since(changed_at, now), settings.sim_change_hold_hours),
        "screen_capture": live and signals.screen_capture,
        "screen_recording": live and signals.screen_recording,
    }


def derive(state: SessionState | None, now: datetime, settings: Settings) -> DerivedSignals:
    """The flags this caller's last /signals post supports at `now`, split into measured and simulated."""
    if state is None:
        return DerivedSignals()
    readings = _readings(state, now, settings)
    simulated = _simulated_fields(state)

    def flags(forced: bool) -> DeviceFlags:
        return DeviceFlags(**{
            flag: any(readings[f] for f in fields if (f in simulated) == forced) for flag, fields in FLAG_FIELDS.items()
        })

    return DerivedSignals(device=flags(forced=False), simulated=flags(forced=True))


def _source(measured: bool, forced: bool) -> SignalSource:
    if measured:
        return "device"
    return "demo" if forced else "none"


def fuse(flags: DemoFlags, derived: DerivedSignals) -> tuple[DemoFlags, SignalSources]:
    """New demo_flags with each live-risk flag OR'd with the posted signals, and where each one came from."""
    def posted(source: DeviceFlags, flag: str) -> bool:
        return bool(getattr(source, flag))

    fused = flags.model_copy(update={
        flag: getattr(flags, flag) or posted(derived.device, flag) or posted(derived.simulated, flag) for flag in LIVE_FLAGS
    })
    sources = SignalSources(
        **{
            flag: _source(posted(derived.device, flag), posted(derived.simulated, flag) or getattr(flags, flag))
            for flag in LIVE_FLAGS
        },
        caller_in_contacts=_source(False, flags.caller_in_contacts),
    )
    return fused, sources
