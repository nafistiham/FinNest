"""Deterministic verdict from hits. This is the floor the model cannot lower.

Scoring is per app first, then across apps: the strongest hit on each app counts once, and apps combine with
noisy-OR. Soft hits (Play-installed apps the classifier or the harvest rule frowns at) are one group worth at most
SOFT_GROUP_CAP, just under the CAUTION line: a phone full of chatty Play apps stays SAFE on its own, and a rooted
phone plus five of them is a CAUTION, not a BLOCK. The total is capped below the BLOCK line unless a *hard
escalator* exists - a critical hit, or a high hit that is not soft.
"""

from __future__ import annotations

from dataclasses import dataclass

from bhorosha_app_safety_check import schema as s
from bhorosha_app_safety_check.schema import Hit

SOFT_CAP = 0.79  # just under BLOCK_THRESHOLD: soft and medium evidence alone never blocks a payment
SOFT_GROUP_CAP = 0.19  # just under CAUTION_THRESHOLD: soft hits alone never reach CAUTION, however many apps carry one


@dataclass(frozen=True)
class Score:
    risk: float  # 0..1
    verdict: str
    hard: bool  # a hard escalator was present

    @property
    def rank(self) -> int:
        return s.VERDICT_RANK[self.verdict]


def hard_escalator(hits: tuple[Hit, ...]) -> bool:
    return any(h.severity == "critical" or (h.severity == "high" and not h.soft) for h in hits)


def combine(hits: tuple[Hit, ...]) -> Score:
    if not hits:
        return Score(0.0, "SAFE", False)
    strongest: dict[str, float] = {}
    soft_survival = 1.0
    for hit in hits:
        if hit.soft:
            soft_survival *= 1.0 - hit.weight
        else:
            strongest[hit.package] = max(strongest.get(hit.package, 0.0), hit.weight)
    survival = 1.0 - min(1.0 - soft_survival, SOFT_GROUP_CAP)
    for weight in strongest.values():
        survival *= 1.0 - weight
    risk = 1.0 - survival
    hard = hard_escalator(hits)
    if not hard:
        risk = min(risk, SOFT_CAP)
    risk = round(min(max(risk, 0.0), 1.0), 3)
    return Score(risk, verdict_for(risk), hard)


def verdict_for(risk: float) -> str:
    if risk >= s.BLOCK_THRESHOLD:
        return "BLOCK"
    if risk >= s.CAUTION_THRESHOLD:
        return "CAUTION"
    return "SAFE"


def floor(hits: tuple[Hit, ...]) -> Score:
    """The verdict from the hits Gemini may not overrule (everything that is not soft)."""
    return combine(tuple(h for h in hits if not h.soft))


def max_verdict(a: str, b: str) -> str:
    return a if s.VERDICT_RANK[a] >= s.VERDICT_RANK[b] else b


def min_verdict(a: str, b: str) -> str:
    return a if s.VERDICT_RANK[a] <= s.VERDICT_RANK[b] else b
