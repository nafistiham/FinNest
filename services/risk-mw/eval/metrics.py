"""Detection metrics for the scam-conversation classifier (spec US-2, FR-7)."""

from __future__ import annotations

import math
import statistics
from collections import defaultdict

Z95 = 1.959964


def wilson(k: int, n: int, z: float = Z95) -> tuple[float, float] | None:
    """Wilson score interval for k of n (95% by default): honest at 17 or 33 dialogues, where k/n alone reads as more than it is."""
    if n <= 0:
        return None
    p, z2 = k / n, z * z
    centre = (p + z2 / (2 * n)) / (1 + z2 / n)
    half = z * math.sqrt(p * (1 - p) / n + z2 / (4 * n * n)) / (1 + z2 / n)
    return round(max(0.0, centre - half), 3), round(min(1.0, centre + half), 3)


def intervals(outcomes: list[dict]) -> dict:
    """Wilson 95% intervals for summarise()'s precision, recall and benign false-positive rate."""
    scams = [o for o in outcomes if o["label"] == "scam"]
    benign = [o for o in outcomes if o["label"] == "benign"]
    tp = sum(o["detected_turn"] is not None for o in scams)
    fp = sum(o["detected_turn"] is not None for o in benign)
    return {"precision": wilson(tp, tp + fp), "recall": wilson(tp, len(scams)), "benign_false_positive_rate": wilson(fp, len(benign))}


def pass_rate(outcomes: list[dict]) -> dict:
    """Adversarial scams caught (all are scams), with its interval and how late the catch came."""
    passed = [o for o in outcomes if o["detected_turn"] is not None]
    late = [o["detected_turn"] - o["first_detectable_turn"] for o in passed if o.get("first_detectable_turn") is not None]
    return {"n": len(outcomes), "passed": len(passed), "rate": round(len(passed) / len(outcomes), 3) if outcomes else None,
            "ci": wilson(len(passed), len(outcomes)), "median_turns_after_first_detectable": statistics.median(late) if late else None}


def summarise(outcomes: list[dict]) -> dict:
    scams = [o for o in outcomes if o["label"] == "scam"]
    benign = [o for o in outcomes if o["label"] == "benign"]
    tp = sum(o["detected_turn"] is not None for o in scams)
    fp = sum(o["detected_turn"] is not None for o in benign)
    detected = [o for o in scams if o["detected_turn"] is not None]
    by_arch: dict[str, list[bool]] = defaultdict(list)
    for o in scams:
        by_arch[o.get("archetype", "?")].append(o["detected_turn"] is not None)
    return {
        "n_scam": len(scams), "n_benign": len(benign),
        "precision": round(tp / (tp + fp), 3) if tp + fp else None,
        "recall": round(tp / len(scams), 3) if scams else None,
        "benign_false_positive_rate": round(fp / len(benign), 3) if benign else None,
        "median_turns_to_detection": statistics.median(o["detected_turn"] for o in detected) if detected else None,
        "median_turns_after_first_detectable": statistics.median(o["detected_turn"] - o["first_detectable_turn"] for o in detected) if detected else None,
        "recall_by_archetype": {a: round(sum(v) / len(v), 3) for a, v in sorted(by_arch.items())},
    }
