"""Compare the detector's reasoning variants with V0 and pick the one scam_variant should name. No model call.

    python eval/variant_table.py            # reads eval/results/variants/v*.json and eval/results/intervention.json (V0)

Selection rule: the best recall among the variants whose benign false-positive rate is at most 10% and whose per-turn p95 on
the synchronous path is at most 2.5 s; ties go to the lower benign FPR, then the adversarial pass rate, then the lower p95, then
the cheaper call. v4's second read runs in the background in production, so its synchronous p95 is what counts and its
escalation (share of turns, how much later the verdict lands) is reported apart. An incomplete run (spend cap, a failed dialogue)
is not compared. Writes eval/results/variant_comparison.md and .json.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))  # run as eval/x.py; app and eval are one level up
from app.scam_variants import VARIANTS
from eval import metrics

RESULTS = Path(__file__).resolve().parent / "results"
FPR_MAX = 0.10
P95_MAX_MS = 2500.0
RULE = (f"best recall among variants with benign FPR <= {FPR_MAX:.0%} and synchronous per-turn p95 <= {P95_MAX_MS / 1000:.1f} s; "
        "ties: lower FPR, higher adversarial pass rate, lower p95, lower cost; incomplete runs are not compared")


def _ci(value) -> list | None:
    return list(value) if value else None


def v0_row(saved: dict) -> dict:
    """V0 from eval/results/intervention.json: the detector before P0 (six caller turns, 60 s window)."""
    m, outcomes = saved["metrics"], saved.get("outcomes", [])
    ci = metrics.intervals(outcomes) if outcomes else {}
    n = saved.get("n") or len(outcomes) or None
    return {"name": "V0", "reads": f"before P0: last six caller turns, {saved.get('model', 'volume role')} at minimal thinking",
            "n_held_out": n, "precision": m.get("precision"), "precision_ci": _ci(ci.get("precision")), "recall": m.get("recall"),
            "recall_ci": _ci(ci.get("recall")), "fpr": m.get("benign_false_positive_rate"), "fpr_ci": _ci(ci.get("benign_false_positive_rate")),
            "adversarial_rate": None, "adversarial": None, "median_turns_to_detection": m.get("median_turns_to_detection"),
            "p50_ms": saved.get("classifier_turn_ms", {}).get("p50"), "p95_ms": saved.get("classifier_turn_ms", {}).get("p95"),
            "cost_per_call_usd": round(saved["classifier_cost_usd"] / n, 6) if n and saved.get("classifier_cost_usd") is not None else None,
            "flip_rate": None, "escalation": None, "incomplete": False}


def variant_row(r: dict) -> dict:
    m, ci, adv = r.get("metrics") or {}, r.get("intervals") or {}, r.get("adversarial")
    return {"name": r["variant"], "reads": r.get("reads"), "n_held_out": (r.get("n") or {}).get("held_out"),
            "precision": m.get("precision"), "precision_ci": _ci(ci.get("precision")), "recall": m.get("recall"), "recall_ci": _ci(ci.get("recall")),
            "fpr": m.get("benign_false_positive_rate"), "fpr_ci": _ci(ci.get("benign_false_positive_rate")),
            "adversarial_rate": adv["rate"] if adv else None, "adversarial": f"{adv['passed']}/{adv['n']}" if adv else None,
            "median_turns_to_detection": r.get("median_turns_to_detection"), "p50_ms": (r.get("turn_ms") or {}).get("p50"),
            "p95_ms": (r.get("turn_ms") or {}).get("p95"), "cost_per_call_usd": (r.get("cost") or {}).get("per_call_usd"),
            "flip_rate": (r.get("flip_vs_v0") or {}).get("rate"), "escalation": r.get("escalation"), "incomplete": bool(r.get("incomplete"))}


def _excluded(row: dict) -> str | None:
    if row["incomplete"]:
        return "incomplete run"
    if row["recall"] is None or row["fpr"] is None:
        return "no held-out metrics"
    if row["fpr"] > FPR_MAX:
        return f"benign FPR {row['fpr']} > {FPR_MAX}"
    if row["p95_ms"] is None or row["p95_ms"] > P95_MAX_MS:
        return f"synchronous p95 {row['p95_ms']} ms > {P95_MAX_MS:.0f} ms"
    return None


def _overlap(a: list | None, b: list | None) -> bool:
    return bool(a and b) and a[0] <= b[1] and b[0] <= a[1]


def select(rows: list[dict]) -> dict:
    candidates = [r for r in rows if r["name"] != "V0"]
    excluded = {r["name"]: why for r in candidates if (why := _excluded(r))}
    full = max((r["n_held_out"] or 0 for r in candidates), default=0)  # a run on fewer held-out rows measured something else
    excluded.update({r["name"]: f"run on {r['n_held_out']} held-out rows, not {full}: not comparable" for r in candidates
                     if r["name"] not in excluded and (r["n_held_out"] or 0) < full})
    eligible = [r for r in candidates if r["name"] not in excluded]
    eligible.sort(key=lambda r: (-r["recall"], r["fpr"], -(r["adversarial_rate"] if r["adversarial_rate"] is not None else -1.0),
                                 r["p95_ms"], r["cost_per_call_usd"] if r["cost_per_call_usd"] is not None else float("inf")))
    winner = eligible[0] if eligible else None
    overlaps = [r["name"] for r in eligible[1:] if winner and _overlap(r["recall_ci"], winner["recall_ci"])]
    note = (f"Set RISK_MW_SCAM_VARIANT={winner['name']}." if winner else
            "No variant meets the rule; scam_variant stays v1 until one does.")
    if overlaps:
        note += f" Its recall interval overlaps {overlaps}: at this sample size the difference is not significant."
    return {"rule": RULE, "winner": winner["name"] if winner else None, "eligible": [r["name"] for r in eligible], "excluded": excluded,
            "recall_overlaps_winner": overlaps, "note": note}


def build(results_dir: Path = RESULTS) -> dict:
    rows, missing = [], []
    v0 = results_dir / "intervention.json"
    if v0.exists():
        rows.append(v0_row(json.loads(v0.read_text(encoding="utf-8"))))
    for v in VARIANTS:
        path = results_dir / "variants" / f"{v}.json"
        if path.exists():
            rows.append(variant_row(json.loads(path.read_text(encoding="utf-8"))))
        else:
            missing.append(v)
    return {"rule": RULE, "rows": rows, "missing": missing, "selection": select(rows)}


def _ci_text(ci: list | None) -> str:
    return f"{ci[0]:.2f}–{ci[1]:.2f}" if ci else "n/a"


def to_markdown(table: dict) -> str:
    sel = table["selection"]
    lines = ["# Detector variants against V0", "",
             f"**Selection rule:** {table['rule']}.", "",
             f"**Winner:** {sel['winner'] or 'none'}. {sel['note']}", "",
             "| Variant | Recall (95% CI) | Benign FPR (95% CI) | Precision (95% CI) | Adversarial | Median turns | p50 / p95 ms (sync) "
             "| Cost a call | Flips vs V0 | Verdict |",
             "|---|---|---|---|---|---|---|---|---|---|"]
    for r in table["rows"]:
        verdict = "baseline" if r["name"] == "V0" else ("winner" if r["name"] == sel["winner"] else
                                                        f"excluded: {sel['excluded'][r['name']]}" if r["name"] in sel["excluded"] else "eligible")
        lines.append(f"| {r['name']} | {r['recall']} ({_ci_text(r['recall_ci'])}) | {r['fpr']} ({_ci_text(r['fpr_ci'])}) | "
                     f"{r['precision']} ({_ci_text(r['precision_ci'])}) | {r['adversarial'] or 'n/a'} | {r['median_turns_to_detection']} | "
                     f"{r['p50_ms']} / {r['p95_ms']} | {r['cost_per_call_usd']} | "
                     f"{r['flip_rate'] if r['flip_rate'] is not None else 'n/a'} | {verdict} |")
    escalated = [r for r in table["rows"] if r["escalation"] and r["escalation"].get("escalated")]
    if escalated:
        lines += ["", "Escalations and resamples, off the synchronous numbers above:", "",
                  "| Variant | Turns escalated | Verdict changed | Lands after (p50 / p95 ms) | Lands before the next caller turn |", "|---|---|---|---|---|"]
        for r in escalated:
            e = r["escalation"]
            lands = e.get("lands_after_ms") or {}
            lines.append(f"| {r['name']} | {e['escalated']} of {e['turns']} ({e['share']}) | {e.get('changed_share')} | "
                         f"{lands.get('p50', 'n/a')} / {lands.get('p95', 'n/a')} | {e.get('lands_before_next_caller_turn', 'n/a')} |")
    if table["missing"]:
        lines += ["", f"Not run yet: {table['missing']} (python eval/intervention_eval.py --variant ...)."]
    lines += ["", "Each row is one run of Gemini-generated held-out dialogues plus a non-native adversarial draft (native check pending); "
                  "read the intervals before calling a difference real."]
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> dict:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--results-dir", type=Path, default=RESULTS)
    args = parser.parse_args(argv)
    table = build(args.results_dir)
    (args.results_dir / "variant_comparison.json").write_text(json.dumps(table, ensure_ascii=False, indent=2), encoding="utf-8")
    (args.results_dir / "variant_comparison.md").write_text(to_markdown(table), encoding="utf-8")
    print(to_markdown(table))
    return table


if __name__ == "__main__":
    main()
