"""The scenario clock: the server, never the request body, decides the moment a payee is scored at."""

from __future__ import annotations

from datetime import UTC, datetime, timedelta

import pytest
from pydantic import ValidationError

from app import clock
from app.settings import Settings

PRODUCTION = {"demo_mode": False, "auth_required": True}
WALL_CLOCK_SLACK_S = 2  # the answer is truncated to the second and the test reads the clock a moment later


def _settings(**overrides) -> Settings:
    return Settings(**overrides)


def test_demo_mode_stands_at_the_demo_transfer():
    assert clock.scenario_now(_settings(demo_mode=True)) == clock.DEMO_SCENARIO_NOW == "2026-11-10T14:13:00"


def test_auth_off_is_demo_time_even_outside_demo_mode():
    assert clock.scenario_now(_settings(demo_mode=False, auth_required=False)) == clock.DEMO_SCENARIO_NOW


def test_the_setting_moves_the_clock():
    assert clock.scenario_now(_settings(scenario_now="2026-11-10T14:12:00")) == "2026-11-10T14:12:00"
    assert clock.scenario_now(_settings(scenario_now="2026-11-10T14:12:00", **PRODUCTION)) == "2026-11-10T14:12:00"


def test_production_reads_the_wall_clock_in_dhaka():
    fixed = datetime(2026, 10, 17, 9, 30, 5, tzinfo=clock.DHAKA)
    assert clock.scenario_now(_settings(**PRODUCTION), wall_clock=lambda: fixed) == "2026-10-17T09:30:05"


def test_production_reads_the_real_clock_six_hours_ahead_of_utc():
    answered = datetime.strptime(clock.scenario_now(_settings(**PRODUCTION)), "%Y-%m-%dT%H:%M:%S")
    dhaka = datetime.now(UTC).replace(tzinfo=None) + timedelta(hours=6)
    assert abs((answered - dhaka).total_seconds()) <= WALL_CLOCK_SLACK_S


def test_demo_mode_never_reads_the_wall_clock():
    def wall_clock() -> datetime:
        raise AssertionError("demo mode must not read the wall clock")

    assert clock.scenario_now(_settings(demo_mode=True), wall_clock=wall_clock) == clock.DEMO_SCENARIO_NOW
    assert clock.scenario_now(_settings(scenario_now="2026-11-10T14:12:00", **PRODUCTION), wall_clock=wall_clock) == "2026-11-10T14:12:00"


@pytest.mark.parametrize("value", ["tomorrow", "2026-11-10 14:12", "2026-11-10T14:12:00Z"])
def test_a_malformed_setting_is_refused_at_start_up(value):
    with pytest.raises(ValidationError, match="scenario_now"):
        _settings(scenario_now=value)


def test_an_empty_setting_means_unset():
    assert _settings(scenario_now="").scenario_now is None
