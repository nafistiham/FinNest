"""Member-level scoring and Wilson intervals. Victims are never counted as members or false alarms."""

from __future__ import annotations

import math


def wilson(k: int, n: int, z: float = 1.96) -> tuple[float, float]:
    if n == 0:
        return (0.0, 1.0)
    p = k / n
    centre = (p + z * z / (2 * n)) / (1 + z * z / n)
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / (1 + z * z / n)
    return (max(0.0, round(centre - half, 4)), min(1.0, round(centre + half, 4)))


def score_case(pred: set[str], truth: set[str], victims: set[str]) -> dict:
    members = set(pred) - set(victims)
    tp, fp, fn = len(members & truth), len(members - truth), len(truth - members)
    precision = tp / (tp + fp) if tp + fp else 0.0
    recall = tp / (tp + fn) if tp + fn else 0.0
    return {"tp": tp, "fp": fp, "fn": fn, "precision": precision, "recall": recall, "recovered": recall >= 0.75 and precision >= 0.9}
