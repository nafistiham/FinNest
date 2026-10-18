"""Code holds the authority: the score sets the minimum action; the agent may raise it one level."""

from __future__ import annotations

from case_zero.validator import flag_supported

ACTIONS = ("close_no_action", "monitor", "edd", "freeze")
# The platform's score bands: risk-mw app/settings.py band_critical, band_high, band_medium (a test keeps them in step).
BAND_THRESHOLDS = {"critical": 0.85, "high": 0.60, "medium": 0.30}
BAND_FLOOR = {"critical": "freeze", "high": "edd", "medium": "monitor", "low": "close_no_action"}


def band_for(probability: float) -> str:
    return next((band for band, cut in BAND_THRESHOLDS.items() if probability >= cut), "low")


def floor_action(probability: float) -> str:
    return BAND_FLOOR[band_for(probability)]


def final_action(probability: float, proposed: str, validated_flags: int) -> str:
    floor = ACTIONS.index(floor_action(probability))
    wanted = ACTIONS.index(proposed) if proposed in ACTIONS else floor
    if wanted <= floor or validated_flags < 1:
        return ACTIONS[floor]
    return ACTIONS[min(wanted, floor + 1)]

SCORE_ONLY_FLAGS = frozenset({"RF12"})  # the model score itself is already the floor; it cannot also justify escalation
# Flags that never raise the action: the score's own (RF12), and an instruction found in a tool output (RF16), which
# says something about the data, not about what the account did.
NON_ESCALATING_FLAGS = SCORE_ONLY_FLAGS | {"RF16"}


def escalation_flags(red_flags, ledger, case=frozenset()) -> int:
    """Red flags that may justify one level above the score floor: each cites a call of a tool that can show it,
    made for an account it names, or for an agent flag an account in the case (validator.flag_supported).
    RF12 (the score) and RF16 (an instruction in a tool output) never count."""
    return sum(1 for f in red_flags if f.code not in NON_ESCALATING_FLAGS and flag_supported(f, ledger, case))
