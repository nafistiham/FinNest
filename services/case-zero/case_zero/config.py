"""Pinned values for Case Zero. Model IDs and prices live only in risk-mw/config/models.yaml."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from bhorosha_graph.features import CONFIRMATION_LAG_DAYS

from case_zero import PROJECT_DIR

DEMO_SEED = "acct_01070"
DEMO_AS_OF = "2026-11-10T14:35:00"
WORLD_START = "2026-10-07T00:00:00"   # the synthetic world: 35 days from 2026-10-07 (seed/config.json)
WORLD_END = "2026-11-11T00:00:00"


@dataclass(frozen=True)
class Settings:
    project_dir: Path = PROJECT_DIR
    models_yaml: Path = PROJECT_DIR / "services" / "risk-mw" / "config" / "models.yaml"
    model_role: str = "workhorse"
    thinking_level: str = "low"
    max_tool_calls: int = 15        # 10 left complex rings half-explored
    min_tool_calls: int = 4         # the agent may not conclude from tc_00 alone
    max_nudges: int = 2
    investigator_timeout_s: float = 55.0   # the tool loop; leaves 35 s of the 90 s for the case writer
    llm_turn_timeout_s: float = 60.0       # one Gemini turn; a slow turn is retried once, not fatal
    writer_timeout_s: float = 45.0   # the bilingual case is the longest output; 25 s timed out on 3.8 Flash
    writer_max_output_tokens: int = 16_384   # thinking + the bilingual case; the 6,000 tool-turn cap could cut the JSON off
    run_timeout_s: float = 90.0      # the spec's wall clock: past it, the case ends with status failed
    confirmation_lag_days: int = CONFIRMATION_LAG_DAYS
