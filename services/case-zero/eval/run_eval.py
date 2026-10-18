"""Case Zero evaluation: agent vs three baselines on every labelled ring plus benign look-alikes.

    python -m eval.run_eval --baselines-only          # no Gemini needed
    python -m eval.run_eval --out eval/results/case_zero.json

Synthetic world: numbers show behaviour on the generator, not real-world accuracy.
"""

from __future__ import annotations

import argparse
import asyncio
import dataclasses
import json
import math
import statistics
import time
from collections import Counter
from pathlib import Path

from case_zero import PROJECT_DIR, prompts
from case_zero.config import Settings
from case_zero.llm import GeminiLLM, model_family
from case_zero.orchestrator import run_investigation
from case_zero.schemas import exported_status
from case_zero.world import World
from eval.baselines import bfs2, score_only, shared_entity_components
from eval.judge import JUDGE_SHA, RUBRIC, judge_case
from eval.metrics import score_case, wilson
from eval.reach import findable
from eval.seeds import benign_seeds, ring_seeds

FLAG_ACTIONS = {"edd", "freeze"}
TUNING_RINGS = {"ring_demo_otp"}   # the prompt was tuned on this ring; reported separately
PER_CASE_RESERVE = 0.10            # never start a case that could cross the spend cap
CONCURRENCY = 3   # --concurrency 1 avoids slow, timed-out turns
JUDGE_ROLE = "reasoning"   # Gemini 3.1 Pro preview: a different model from the agent's 3.8 Flash; --judge-role judge for the agent's own
MAIN_RESULTS = "case_zero.json"
SPEC_RESULTS = "investigator.json"   # the spec's (section 7) name for the main results file
# Gate keys stay as results files have them; the Markdown names what a gate really checks. G3 checks that every id,
# amount and time a case cites exists in a tool output, not that the sentence follows from it.
GATE_LABELS = {"G3_validator": "G3_citation_check"}


def _recall_findable(pred: set[str], reach: set[str]) -> float:
    return round(len(set(pred) & reach) / len(reach), 3) if reach else 0.0


AGENT_METHODS = ("case_zero", "case_zero_ungated")


def merge_rerun(result: dict, fresh: dict[str, dict], method: str = "case_zero") -> dict:
    """Replace one method's metrics for re-run rings only, marking them; every other row stays as it was."""
    for row in result["rows"]:
        key = row["ring_id"] or row["seed"]
        if key in fresh:
            row["methods"][method] = {**fresh[key], "rerun": True}
    return result


def judge_models(rows: list[dict], method: str = "case_zero") -> set[str]:
    """The models that judged these rows (each judged row names its judge, errors included)."""
    return {m["judge"]["judge_model"] for m in (r["methods"].get(method, {}) for r in rows) if isinstance(m.get("judge"), dict) and m["judge"].get("judge_model")}


def apply_rerun(base: dict, fresh_result: dict, rerun_keys, reason: str) -> dict:
    """Merge re-run cases (both agent rows) into earlier results, then recompute the summary and the gates.
    Refuses when the re-run was judged by another model than the cases it joins: one G5 needs one judge."""
    keys = {rerun_keys} if isinstance(rerun_keys, str) else set(rerun_keys)
    fresh_judges = judge_models([r for r in fresh_result["rows"] if (r["ring_id"] or r["seed"]) in keys])
    kept_judges = judge_models([r for r in base["rows"] if (r["ring_id"] or r["seed"]) not in keys])
    if fresh_judges and kept_judges and fresh_judges != kept_judges:
        raise ValueError(f"the re-run was judged by {sorted(fresh_judges)} but the other cases by {sorted(kept_judges)}; "
                         "re-run with the same --judge-role, or re-run every case")
    for method in AGENT_METHODS:
        fresh = {(r["ring_id"] or r["seed"]): r["methods"][method] for r in fresh_result["rows"] if method in r["methods"] and (r["ring_id"] or r["seed"]) in keys}
        merge_rerun(base, fresh, method)
    names = sorted({k for r in base["rows"] for k in r["methods"]})
    base["summary"] = {n: summarise(base["rows"], n) for n in names}
    if "case_zero" in base["summary"]:
        base["gates"] = gates(base["summary"]["case_zero"])
    base["spent_usd_ledger"] = fresh_result.get("spent_usd_ledger", base.get("spent_usd_ledger"))
    base["reruns"] = sorted(set(base.get("reruns", [])) | keys)
    base["note"] = base.get("note", "") + f" Re-run: {', '.join(sorted(keys))} ({reason})."
    for k in ("judge_sha", "judge_model"):
        if k in fresh_result:
            base[k] = fresh_result[k]
    if "settings" in fresh_result and fresh_result["settings"] != base.get("settings"):
        base["rerun_settings"] = fresh_result["settings"]  # the re-run rows ran with these, the rest with base["settings"]
    return base


def nearest_rank(sorted_values: list[float], pct: float) -> float:
    """The smallest value with at least pct of the values at or below it (nearest-rank percentile)."""
    return sorted_values[max(0, math.ceil(pct * len(sorted_values)) - 1)]


def settings_snapshot(settings: Settings) -> dict:
    """The Settings a run used; paths relative to the project so results carry no local paths."""
    def plain(v):
        if isinstance(v, Path):
            return v.relative_to(PROJECT_DIR).as_posix() if v.is_relative_to(PROJECT_DIR) else v.name
        return v
    return {k: plain(v) for k, v in dataclasses.asdict(settings).items()}


def budget_allows(spent: float, cap: float, reserve: float = PER_CASE_RESERVE) -> bool:
    return spent + reserve <= cap


def baseline_preds(world: World, seed: dict) -> dict[str, set[str]]:
    return {"bfs_2hop": bfs2(world, seed["seed"], seed["as_of"]), "score_only_0.5": score_only(world, seed["seed"], seed["as_of"]),
            "shared_entity_component": shared_entity_components(world, seed["seed"])}


async def agent_pred(world: World, llm, seed: dict, i: int, judge_llm=None, settings: Settings = Settings()) -> tuple[set[str], dict]:
    async def emit(_):
        return None
    started = time.perf_counter()
    report = await run_investigation(world, llm, seed["seed"], seed["as_of"], emit, f"EV-{i:04d}", settings=settings)
    members = {m.acct_id for m in report.draft.members if m.role != "victim"}
    dropped = sorted(report.validation.get("gate", {}).get("dropped", {}))
    seconds = round(time.perf_counter() - started, 1)  # the case alone; the judge is timed separately
    judged = {}
    if judge_llm is not None:
        judge_started = time.perf_counter()
        judged = {"judge": {**await judge_case(judge_llm, report), "judge_seconds": round(time.perf_counter() - judge_started, 1)}}
    return members, {**judged, "action": report.action, "status": report.status, "exported_status": exported_status(report.status),
                     "first_pass_ok": not report.validation["first_pass"], "limitations": report.draft.limitations,
                     "flags_dropped": len(report.validation.get("flags_dropped", [])), "accusations_removed": len(report.validation.get("accusations_removed", [])),
                     "seconds": seconds, "cost_usd": report.cost["cost_usd"], "tool_calls": report.tool_calls,
                     "tokens_in": report.cost.get("tokens_in", 0), "tokens_out": report.cost.get("tokens_out", 0), "model": report.cost.get("model"),
                     "members": sorted(members), "roles": {m.acct_id: m.role for m in report.draft.members}, "proposed": sorted(members | set(dropped)), "gate_dropped": dropped}


def agent_methods(pred: set[str], info: dict, seed: dict, reach: set[str]) -> dict[str, dict]:
    """Case Zero after the membership gate, and the writer's own list before it (same run, no extra spend)."""
    flagged = info["action"] in FLAG_ACTIONS
    ungated = set(info["proposed"])
    return {"case_zero": {**score_case(pred, seed["truth"], seed["victims"]), **info, "recall_findable": _recall_findable(pred, reach), "flagged": flagged},
            "case_zero_ungated": {**score_case(ungated, seed["truth"], seed["victims"]), "recall_findable": _recall_findable(ungated, reach), "flagged": flagged}}


def summarise(rows: list[dict], method: str) -> dict:
    ran = [r for r in rows if method in r["methods"] and "skipped" not in r["methods"][method]]
    scored = [r for r in ran if not r.get("tuning")]
    rings = [r for r in scored if r["ring_id"]]
    benign = [r for r in scored if not r["ring_id"]]
    recovered = sum(r["methods"][method]["recovered"] for r in rings)
    alarms = sum(r["methods"][method]["flagged"] for r in benign)
    mean = lambda key: round(sum(r["methods"][method].get(key, 0.0) for r in rings) / len(rings), 3) if rings else None
    out = {"rings": len(rings), "rings_recovered": recovered, "rings_recovered_ci95": wilson(recovered, len(rings)),
           "mean_precision": mean("precision"), "mean_recall": mean("recall"), "mean_recall_findable": mean("recall_findable"),
           "benign": len(benign), "benign_false_alarms": alarms,
           "benign_closed": sum(1 for r in benign if r["methods"][method].get("action") == "close_no_action"), "benign_false_alarm_ci95": wilson(alarms, len(benign)),
           "skipped_budget": sum(1 for r in rows if r["methods"].get(method, {}).get("skipped") == "budget"),
           "skipped_tuning": sum(1 for r in rows if r["methods"].get(method, {}).get("skipped") == "tuning ring"),
           "skipped_error": sum(1 for r in rows if r["methods"].get(method, {}).get("skipped") == "error"),
           "tuning_rows": sum(1 for r in ran if r.get("tuning"))}
    timed = [r["methods"][method] for r in scored if "seconds" in r["methods"][method]]  # same rows as the accuracy numbers
    if timed:
        secs = sorted(m["seconds"] for m in timed)
        out.update({"validator_first_pass": [sum(1 for m in timed if m["first_pass_ok"]), len(timed)],
                    "statuses": dict(Counter(m["status"] for m in timed)),
                    "exported_statuses": dict(exported := Counter(exported_status(m["status"]) for m in timed)), "degraded": exported["degraded"],
                    "flags_dropped_total": sum(m.get("flags_dropped", 0) for m in timed), "accusations_removed_total": sum(m.get("accusations_removed", 0) for m in timed),
                    "seconds_p50": statistics.median(secs), "seconds_p95": nearest_rank(secs, 0.95),
                    "cost_usd_total": round(sum(m["cost_usd"] for m in timed), 4), "cost_usd_per_case": round(sum(m["cost_usd"] for m in timed) / len(timed), 4),
                    "tokens_in_total": sum(m.get("tokens_in", 0) for m in timed), "tokens_out_total": sum(m.get("tokens_out", 0) for m in timed)})
    judged = [m["judge"] for m in (r["methods"][method] for r in scored) if isinstance(m.get("judge"), dict) and "judge_error" not in m["judge"]]
    if judged:
        out.update({"judge_n": len(judged), "judge_models": sorted(judge_models(scored, method)), "judge_errors": sum(1 for r in scored if "judge_error" in (r["methods"][method].get("judge") or {})),
                    "judge_means": {k: round(statistics.mean(j[k] for j in judged), 2) for k in (*RUBRIC, "en_bn_consistency")},
                    "judge_cost_usd_total": round(sum(j.get("judge_cost_usd", 0.0) for j in judged), 4)})
    return out


def gates(s: dict) -> dict:
    """The spec's five gates (section 7 and the US-5 diagram)."""
    means = s.get("judge_means") or {}
    statuses = s.get("statuses") or {}
    return {
        "G1_recovery": (s.get("mean_recall") or 0) >= 0.75 and (s.get("mean_precision") or 0) >= 0.90,
        "G2_benign_closed": s.get("benign_closed", 0) >= 0.8 * s.get("benign", 0),
        "G3_validator": bool(statuses) and {exported_status(k) for k in statuses} == {"done"},   # a degraded case is not done
        "G4_latency_cost": s.get("seconds_p95") is not None and s["seconds_p95"] < 60 and "cost_usd_total" in s,
        "G5_judge": bool(means) and all(means[k] >= 4 for k in RUBRIC) and len(s.get("judge_models", [])) <= 1,   # one judge for every case
    }


async def main(args: argparse.Namespace) -> dict:
    world_dir = Path(args.world_dir) if args.world_dir else PROJECT_DIR
    world = World.load(world_dir)
    settings = Settings()
    llm = None if args.baselines_only else GeminiLLM.from_env(settings.models_yaml, settings.model_role, settings.thinking_level)
    judge_llm = GeminiLLM.from_env(settings.models_yaml, args.judge_role) if (args.judge and llm is not None) else None
    seeds = ring_seeds(world) + benign_seeds(world, n=10)
    rows = []
    for i, seed in enumerate(seeds[: args.limit or None]):
        methods = {}
        reach = findable(world, seed["seed"], seed["as_of"], seed["truth"])
        for name, pred in baseline_preds(world, seed).items():
            m = score_case(pred, seed["truth"], seed["victims"])
            methods[name] = {**m, "recall_findable": _recall_findable(pred, reach), "flagged": seed["seed"] in pred and len(set(pred) - {seed["seed"]}) >= 1}
        rows.append({"ring_id": seed["ring_id"], "typology": seed["typology"], "seed": seed["seed"], "as_of": seed["as_of"],
                     "tuning": seed["ring_id"] in TUNING_RINGS, "truth": len(seed["truth"]), "findable": len(reach), "_reach": reach, "methods": methods})
    if llm is not None:
        gate = asyncio.Semaphore(args.concurrency)

        async def agent(i: int, seed: dict, row: dict) -> None:
            async with gate:
                if args.rerun and (row["ring_id"] or row["seed"]) not in args.rerun:
                    return
                if row["tuning"] and args.skip_tuning:  # excluded from the scores anyway; save the spend
                    row["methods"]["case_zero"] = {"skipped": "tuning ring"}
                    return
                if args.only and (row["ring_id"] or row["seed"]) not in args.only:
                    return
                if not budget_allows(llm.budget.spent(), llm.budget.cap_usd):
                    row["methods"]["case_zero"] = {"skipped": "budget"}
                    return
                try:
                    pred, info = await agent_pred(world, llm, seed, i, judge_llm=judge_llm, settings=settings)
                except Exception as exc:  # recorded on its row; the other cases and the results file still happen
                    row["methods"]["case_zero"] = {"skipped": "error", "error": f"{type(exc).__name__}: {exc}"}
                    print(f"{i + 1:2d}/{len(rows)} {seed['seed']:22s} error: {type(exc).__name__}: {exc}", flush=True)
                    return
                row["methods"].update(agent_methods(pred, info, seed, row["_reach"]))
                m = row["methods"]["case_zero"]
                print(f"{i + 1:2d}/{len(rows)} {seed['seed']:22s} {seed['typology']:24s} agent recall={m['recall']:.2f} precision={m['precision']:.2f} "
                      f"action={m['action']} status={m['status']} {m['seconds']}s ${m['cost_usd']} | spent ${llm.budget.spent():.4f}", flush=True)

        await asyncio.gather(*(agent(i, s, r) for i, (s, r) in enumerate(zip(seeds, rows))))
    for r in rows:
        r.pop("_reach", None)
    rings = [r for r in rows if r["ring_id"] and not r["tuning"]]
    ceiling = {"members": sum(r["truth"] for r in rings), "findable": sum(r["findable"] for r in rings)}
    names = sorted({k for r in rows for k in r["methods"]})
    return {"world": "synthetic world (seed 42)" if world_dir == PROJECT_DIR else f"dev world {world_dir.name} (tuning only)", "prompt_sha": prompts.PROMPT_SHA, "model": llm.role.id if llm else None,
            "settings": {**settings_snapshot(settings), "concurrency": args.concurrency, "judge_role": args.judge_role if judge_llm is not None else None},
            "spent_usd_ledger": llm.budget.spent() if llm else 0.0,
            "note": "Synthetic data; baselines and agent see only events before as_of; known fraud uses a 3-day confirmation lag; ring_demo_otp was used for prompt tuning and is excluded from the summary.",
            "findable_ceiling": ceiling, "summary": (summary := {n: summarise(rows, n) for n in names}), "rows": rows,
            **({"gates": gates(summary["case_zero"])} if "case_zero" in summary else {}),
            **({"judge_sha": JUDGE_SHA, "judge_model": judge_llm.role.id} if judge_llm is not None else {})}


def to_markdown(result: dict) -> str:
    lines = ["| Method | Rings recovered (95% CI) | Mean precision | Mean recall | Recall of findable members | Benign false alarms (95% CI) |", "|---|---|---|---|---|---|"]
    for name, s in result["summary"].items():
        lo, hi = s["rings_recovered_ci95"]
        blo, bhi = s["benign_false_alarm_ci95"]
        lines.append(f"| {name} | {s['rings_recovered']}/{s['rings']} ({lo:.2f}–{hi:.2f}) | {s['mean_precision']} | {s['mean_recall']} | {s['mean_recall_findable']} | {s['benign_false_alarms']}/{s['benign']} ({blo:.2f}–{bhi:.2f}) |")
    c = result.get("findable_ceiling", {})
    if c:
        lines += ["", f"Findable ceiling: {c['findable']} of {c['members']} ring members are reachable from their seed at as_of (3 money hops or a shared identity); no method can find the rest."]
    agent = result["summary"].get("case_zero", {})
    if "validator_first_pass" in agent:
        k, n = agent["validator_first_pass"]
        degraded = agent.get("degraded", sum(v for st, v in agent["statuses"].items() if exported_status(st) == "degraded"))   # older results lack the count
        lines += ["", f"Case Zero (prompt {result['prompt_sha']}, {result['model']}): citation check passed first time {k}/{n}; statuses {agent['statuses']} ({degraded} degraded); "
                  f"p50 {agent['seconds_p50']} s, p95 {agent['seconds_p95']} s; ${agent['cost_usd_per_case']} per case, ${agent['cost_usd_total']} total; "
                  f"{agent['skipped_budget']} skipped for budget; {agent.get('skipped_error', 0)} ended in an error; tuning ring {'not run' if agent['skipped_tuning'] else 'run and reported separately'}."]
        if "flags_dropped_total" in agent:  # runs that record dropped flags
            lines[-1] += (f" Code removed {agent['flags_dropped_total']} red flag(s) that cited no fitting call for an account they name, and "
                          f"{agent['accusations_removed_total']} flag(s), timeline entries or sentences naming an account the membership check excluded.")
    if "judge_means" in agent:
        jm = agent["judge_means"]
        judge_model, agent_model = result.get("judge_model") or "", result.get("model") or ""
        if judge_model == agent_model:
            family = "the same model as the agent, so self-preference bias is possible"
        elif model_family(judge_model) == model_family(agent_model):
            family = f"a different model from the agent ({agent_model}), though both are {model_family(agent_model)}, so some self-preference bias is still possible"
        else:
            family = f"a different model family from the agent ({agent_model})"
        lines += ["", f"Judge ({result.get('judge_model')}, prompt {result.get('judge_sha')}; {family}), "
                  f"{agent['judge_n']} cases, {agent['judge_errors']} judge errors: evidence {jm['evidence']}, consistency {jm['consistency']}, clarity {jm['clarity']}, "
                  f"actionability {jm['actionability']}, English/Bangla consistency {jm['en_bn_consistency']} (1-5)."]
    if "gates" in result:
        lines += ["", "Spec gates: " + ", ".join(f"{GATE_LABELS.get(k, k)} {'pass' if v else 'FAIL'}" for k, v in result["gates"].items()) + "."]
    return "\n".join(lines) + "\n\n" + result["note"] + " A ring counts as recovered at recall ≥ 0.75 and precision ≥ 0.90 over its non-victim members.\n"


def write_results(result: dict, out: Path) -> None:
    """The results JSON and its Markdown; the main results file is also written under the spec's name."""
    out.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(result, indent=2, default=sorted)
    out.write_text(text, encoding="utf-8")
    if out.name == MAIN_RESULTS:  # other --out files (dev worlds, experiments) never overwrite it
        out.with_name(SPEC_RESULTS).write_text(text, encoding="utf-8")
    out.with_suffix(".md").write_text(to_markdown(result), encoding="utf-8")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--baselines-only", action="store_true")
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--skip-tuning", action="store_true", help="do not run the agent on the prompt-tuning ring")
    parser.add_argument("--concurrency", type=int, default=CONCURRENCY)
    parser.add_argument("--rerun", type=lambda s: set(s.split(",")), default=set(), help="re-run only these rings and merge into --out")
    parser.add_argument("--out", default="eval/results/case_zero.json")
    parser.add_argument("--world-dir", default="", help="evaluate on another world (e.g. .dev_world/seed7); default is the scored seed-42 world")
    parser.add_argument("--only", type=lambda s: set(s.split(",")), default=set(), help="run the agent only on these rings or seeds (smoke tests)")
    parser.add_argument("--rerun-reason", default="re-run one at a time", help="why the --rerun cases were re-run (goes into the results note)")
    parser.add_argument("--judge", action="store_true", help="score each case with the narrative judge")
    parser.add_argument("--judge-role", default=JUDGE_ROLE, help=f"models.yaml role for the judge (default {JUDGE_ROLE}: a different Gemini model from the agent; `judge` is the agent's own)")
    return parser.parse_args(argv)


if __name__ == "__main__":
    args = parse_args()
    result = asyncio.run(main(args))
    out = Path(args.out)
    if args.rerun:  # merge the re-run cases into the existing results, then recompute the summary and gates
        result = apply_rerun(json.loads(out.read_text(encoding="utf-8")), result, args.rerun, args.rerun_reason)
    write_results(result, out)
    print(to_markdown(result))
