"""Eval (spec FR-7, section 7): the scam-conversation classifier on the held-out dialogues, plus scoring latency.

    RISK_MW_GENAI_ENABLED=true RISK_MW_PROJECT_ID=... RISK_MW_GENAI_BACKEND=vertex python -m eval.intervention_eval --variant v1 v2 v3 v4 v5
    python -m eval.intervention_eval --variant all --set both --dry-run   # the calls and the reserve only: no model call, no spend
    python -m eval.intervention_eval --recompute     # after a relabel: rescore the saved outcomes, no classifier calls

Each dialogue is replayed turn by turn through app.scam.score_turn (the same code /v1/scam/turn runs), scoring after
every caller turn, as the app would while the caller speaks. A dialogue counts as flagged at the first turn whose
rolling score reaches 0.7. Spend is capped by eval/budget.py (RISK_MW_EVAL_BUDGET_USD).

V0, the detector before P0, is eval/results/intervention.json and stays the baseline: a variant run never writes it, and a
plain classifier run rewrites it only with --replace-baseline. P0 item 4 re-measures with the reasoning variants of
app/scam_variants.py (--variant v1..v5, settings.scam_variant set for score_turn) on the held-out set, the adversarial set or
both (--set), and writes eval/results/variants/<variant>.json and .md: precision, recall and benign FPR with Wilson 95%
intervals, the adversarial pass rate, median turns to detection, per-turn p50/p95 latency on the synchronous path, cost per
call, the flip rate against V0's outcomes, and for v4 the escalation share and how much later its verdict lands. All the
variants given run in one process: a semaphore per model role (--per-role, default 4) and a shared back-off after a 429 keep
them inside the quota, and a rate-limited read is retried rather than scored as `uncertain`.
"""

from __future__ import annotations

import argparse
import contextvars
import functools
import json
import logging
import os
import statistics
import sys
import threading
import time
from collections.abc import Callable, Iterator
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))  # run as eval/x.py (FR-7), app and eval are one level up
from app import genai_client, scam, scam_variants
from app.contracts import ScamTurnRequest
from app.settings import Settings, get_settings
from eval import metrics
from eval.budget import DEFAULT_FILE, BudgetExceeded, SpendLedger

log = logging.getLogger("eval")
HERE = Path(__file__).resolve().parent
DIALOGUES = HERE / "scam_dialogues.jsonl"
ADVERSARIAL = HERE / "adversarial_dialogues.jsonl"
RESULTS = HERE / "results"
RESERVE_PER_CALL = 0.002
HELP_LINE_FOR = {"benign_bank_call": "16247"}  # genuine help-line calls come from the help line
SETS = ("held_out", "adversarial", "both")
# Worst case per caller turn, escalation included: what each turn holds against the cap before it calls.
# Sized for an uncached read ($0.0031 measured under parallel load before the prefix cache), so concurrent turns cannot
# settle past the cap even when the cache misses; the read-cost guard stops a run whose reads cost that much anyway.
TURN_RESERVE = {"v1": 0.0035, "v2": 0.0035, "v3": 0.0045, "v4": 0.012, "v5": 0.0105}
CALLS_PER_TURN = {"v1": 1, "v2": 1, "v3": 1, "v4": 2, "v5": 3}  # at most
VARIANT_READS = {"v1": "volume at minimal thinking", "v2": "volume at minimal, a check field before the verdict",
                 "v3": "volume at low thinking", "v4": "volume at minimal, then workhorse at low on borderline turns (background)",
                 "v5": "volume at minimal, three samples and a majority vote on borderline turns"}
PER_ROLE = 4
RETRIES_429, BACKOFF_S = 5, 2.0
clock = time.perf_counter


def _percentile(xs: list[float], p: float) -> float | None:
    return round(sorted(xs)[min(len(xs) - 1, int(p * len(xs)))], 1) if xs else None


def score_latency(n: int = 300) -> dict:
    """In-process /v1/risk/score latency (warm, memory store): the spec's 100 ms p95 target."""
    from fastapi.testclient import TestClient

    from main import app

    bodies = [{"user_id": "rina", "session_id": "lat-q", "txn": {"type": "send_money", "amount_bdt": 500, "to_account": "acct_00036"}},
              {"user_id": "rina", "session_id": "lat-h", "txn": {"type": "pin_reset"}, "demo_flags": {"call_active": True, "sim_swap": True}},
              {"user_id": "rina", "session_id": "lat-d", "txn": {"type": "send_money", "amount_bdt": 9000, "to_account": "acct_01288", "is_new_payee": True}}]
    with TestClient(app) as client:
        for b in bodies:
            client.post("/v1/risk/score", json=b)
        server = [float(client.post("/v1/risk/score", json=bodies[i % 3]).headers["X-Processing-Time-Ms"]) for i in range(n)]
    return {"n": n, "p50_ms": round(statistics.median(server), 1), "p95_ms": _percentile(server, 0.95), "where": "in-process, memory store"}


def run_dialogue(row: dict, ledger: SpendLedger | None, calls: list) -> dict:
    settings = get_settings()
    turns, detected, trace = row["turns"], None, []
    for i, turn in enumerate(turns):
        if turn["speaker"] != "caller":
            continue
        if ledger is not None:
            ledger.check(RESERVE_PER_CALL)
        started = time.perf_counter()
        before = len(calls)
        out = scam.score_turn(ScamTurnRequest(session_id=f"eval-{row['id']}", turns=turns[: i + 1], caller_number=HELP_LINE_FOR.get(row["archetype"])), settings)
        cost = sum(c.cost_usd for c in calls[before:])
        if ledger is not None:
            ledger.record(cost)
        trace.append({"turn": i, "scam_type": out.scam_type, "confidence": out.confidence, "rolling": out.rolling_score,
                      "quote": out.evidence_quote, "ms": round((time.perf_counter() - started) * 1000, 1)})
        if detected is None and out.rolling_score >= scam.ALERT_PAIR:
            detected = i
    return {"id": row["id"], "label": row["label"], "archetype": row["archetype"], "channel": row["channel"],
            "first_detectable_turn": row.get("first_detectable_turn"), "turns": len(turns), "detected_turn": detected, "trace": trace}


def evaluate(rows: list[dict], ledger: SpendLedger | None, latency: dict | None = None) -> dict:
    calls: list = []
    original = genai_client.call

    def counting(*args, **kwargs):
        result = original(*args, **kwargs)
        calls.append(result)
        return result

    genai_client.call = counting
    try:
        outcomes = [run_dialogue(r, ledger, calls) for r in rows]
    finally:
        genai_client.call = original
    m = metrics.summarise(outcomes)
    turn_ms = [t["ms"] for o in outcomes for t in o["trace"]]
    latency = latency or {"p95_ms": None}
    return {"metrics": m, "gates": gates_for(m, latency), "classifier_calls": sum(len(o["trace"]) for o in outcomes),
            "classifier_cost_usd": round(sum(c.cost_usd for c in calls), 4), "classifier_tokens": [sum(c.tokens_in for c in calls), sum(c.tokens_out for c in calls)],
            "classifier_turn_ms": {"p50": _percentile(turn_ms, 0.5), "p95": _percentile(turn_ms, 0.95)},
            "model": calls[0].model_id if calls else None, "score_latency": latency, **errors_of(outcomes), "outcomes": outcomes}


def gates_for(m: dict, latency: dict | None) -> dict:
    latency = latency or {"p95_ms": None}
    return {
        "precision_0_85": m["precision"] is not None and m["precision"] >= 0.85,
        "recall_0_80": m["recall"] is not None and m["recall"] >= 0.80,
        "benign_fpr_0_10": m["benign_false_positive_rate"] is not None and m["benign_false_positive_rate"] <= 0.10,
        "score_p95_under_100ms": latency.get("p95_ms") is not None and latency["p95_ms"] < 100,
    }


def errors_of(outcomes: list[dict]) -> dict:
    return {"false_positives": [{"id": o["id"], "archetype": o["archetype"], "quote": o["trace"][-1]["quote"] if o["trace"] else ""}
                                for o in outcomes if o["label"] == "benign" and o["detected_turn"] is not None],
            "misses": [{"id": o["id"], "archetype": o["archetype"], "max_rolling": max((t["rolling"] for t in o["trace"]), default=0.0)}
                       for o in outcomes if o["label"] == "scam" and o["detected_turn"] is None]}


RECOMPUTED_NOTE = ("Recomputed from the saved per-dialogue outcomes after relabelling (no classifier calls): the classifier's turn-by-turn "
                   "verdicts are unchanged, only the labels they are scored against moved. Latency and cost come from the original run.")


def recompute(saved: dict, rows: list[dict]) -> dict:
    """The held-out numbers again from saved outcomes and the dataset's current labels; the first 'before' is kept."""
    by_id = {r["id"]: r for r in rows}
    outcomes, changed = [], []
    for o in saved["outcomes"]:
        row = by_id.get(o["id"], {})
        new = {**o, **{k: row[k] for k in ("label", "archetype", "first_detectable_turn") if k in row}}
        if any(new[k] != o[k] for k in ("label", "archetype", "first_detectable_turn")):
            changed.append(o["id"])
        outcomes.append(new)
    m = metrics.summarise(outcomes)
    before = saved.get("before_relabel") or {k: saved[k] for k in ("metrics", "gates", "false_positives", "misses") if k in saved}
    return {**saved, "metrics": m, "gates": gates_for(m, saved.get("score_latency")), **errors_of(outcomes), "outcomes": outcomes,
            "relabelled": sorted(set(saved.get("relabelled", [])) | set(changed)), "before_relabel": before, "recomputed_note": RECOMPUTED_NOTE}


def to_markdown(r: dict) -> str:
    m, g = r["metrics"], r["gates"]
    lines = [f"# Classifier eval ({r['n']} held-out dialogues, {r['model']})", "",
             "| Metric | Value | Target |", "|---|---|---|",
             f"| Precision on scam | {m['precision']} | ≥ 0.85 {'pass' if g['precision_0_85'] else 'FAIL'} |",
             f"| Recall on scam | {m['recall']} | ≥ 0.80 {'pass' if g['recall_0_80'] else 'FAIL'} |",
             f"| False-positive rate on benign | {m['benign_false_positive_rate']} | ≤ 0.10 {'pass' if g['benign_fpr_0_10'] else 'FAIL'} |",
             f"| Median turns to detection | {m['median_turns_to_detection']} (median {m['median_turns_after_first_detectable']} after the first detectable turn) | reported |",
             f"| Scoring latency p95 | {r['score_latency']['p95_ms']} ms ({r['score_latency'].get('where', '')}) | < 100 ms {'pass' if g['score_p95_under_100ms'] else 'FAIL'} |",
             f"| Classifier call p50 / p95 | {r['classifier_turn_ms']['p50']} / {r['classifier_turn_ms']['p95']} ms | reported |",
             f"| Cost | ${r['classifier_cost_usd']} for {r['classifier_calls']} classifier calls | reported |", "",
             f"Scam {m['n_scam']}, benign {m['n_benign']}. Recall by archetype: {m['recall_by_archetype']}.",
             f"False positives: {[f['id'] for f in r['false_positives']] or 'none'}. Misses: {[x['id'] for x in r['misses']] or 'none'}.", "",
             *_relabel_lines(r),
             "Dialogues are Gemini-generated from documented Bangladeshi scam patterns (eval/build_dialogues.py) and still need a 20% human spot-check; "
             "the classifier and the generator are both Gemini models, so these numbers are likely optimistic."]
    return "\n".join(lines) + "\n"


def _relabel_lines(r: dict) -> list[str]:
    if "before_relabel" not in r:
        return []
    b = r["before_relabel"]["metrics"]
    return [f"Relabelled held-out dialogues: {r['relabelled']}. Before: precision {b['precision']}, recall {b['recall']}, "
            f"false-positive rate {b['benign_false_positive_rate']} (scam {b['n_scam']}, benign {b['n_benign']}). {r['recomputed_note']}", ""]


def keep_speech_smoke(result: dict, path: Path) -> dict:
    """A classifier re-run rewrites intervention.json; the speech smoke results (eval/transcription_smoke.py) stay."""
    previous = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
    return {**result, "speech_smoke": previous["speech_smoke"]} if "speech_smoke" in previous else result


# --- P0 item 4: the reasoning variants ---------------------------------------------------------------


@dataclass
class TurnMeter:
    """What one scored turn spent and waited for, across every thread its reads ran in (v5 samples in parallel)."""

    cost_usd: float = 0.0
    calls: int = 0
    rate_limited: int = 0
    background_s: float = 0.0                       # v4's second read: off the synchronous path in production
    waits: dict[int, float] = field(default_factory=dict)  # per thread: queued on a semaphore, backing off, or lost to a 429
    _lock: threading.Lock = field(default_factory=threading.Lock, repr=False)

    def waited(self, seconds: float) -> None:
        with self._lock:
            ident = threading.get_ident()
            self.waits[ident] = self.waits.get(ident, 0.0) + max(0.0, seconds)

    def limited(self) -> None:
        with self._lock:
            self.rate_limited += 1

    def charge(self, result: Any, seconds: float, background: bool) -> None:
        with self._lock:
            self.cost_usd += float(getattr(result, "cost_usd", 0.0) or 0.0)
            self.calls += 1
            self.background_s += seconds if background else 0.0

    def excluded_s(self, home: int) -> float:
        """Waiting the turn would not have done alone: its own thread's, plus the longest of the parallel ones (they overlap)."""
        with self._lock:
            return self.waits.get(home, 0.0) + max((s for t, s in self.waits.items() if t != home), default=0.0)


METER: contextvars.ContextVar[TurnMeter | None] = contextvars.ContextVar("eval_turn_meter", default=None)
CACHED_READ_USD = 0.0007  # a volume read with the cards prefix in its explicit cache (probe, 2026-10-17)


class CostTooHigh(RuntimeError):
    """The run's first volume reads cost more than the guard allows: the prefix cache is not being hit."""


class ReadCostGuard:
    """Stops a paid run early when its first volume reads cost more than threshold_usd at the median (the read that makes the
    cache carries its storage, so the median, not the mean). After that, every read raises CostTooHigh and the run records
    the dialogues it skipped."""

    def __init__(self, threshold_usd: float = 2 * CACHED_READ_USD, after: int = 8, role: str = "volume") -> None:
        self.threshold_usd, self.after, self.role = threshold_usd, after, role
        self.costs: list[float] = []
        self.tripped: float | None = None  # the median that tripped it
        self._lock = threading.Lock()

    def check(self, role: str) -> None:
        if self.tripped is not None:
            raise CostTooHigh(f"median per-read cost ${self.tripped:.5f} over the first {self.after} {self.role} reads is above "
                              f"${self.threshold_usd:.5f}: the prefix cache is not being hit")

    def observe(self, role: str, result: Any) -> None:
        if role != self.role:
            return
        with self._lock:
            if self.tripped is not None or len(self.costs) >= self.after:
                return
            self.costs.append(float(getattr(result, "cost_usd", 0.0) or 0.0))
            if len(self.costs) == self.after and (median := sorted(self.costs)[len(self.costs) // 2]) > self.threshold_usd:
                self.tripped = median
                log.warning("stopping: median per-read cost $%.5f > $%.5f", median, self.threshold_usd)


def sync_ms(wall_s: float, meter: TurnMeter, home: int, esc: dict | None) -> float:
    """What the caller's turn waits for in production. Waits on a semaphore or a 429 are taken out, and v4's background read.
    v5's samples ran in parallel threads that may have queued: their whole block comes out and the slowest sample's own read
    latency goes back in (review finding, H: subtracting the longest wait under-reported v5 under contention)."""
    if esc and esc.get("kind") == "self_consistency" and esc.get("wall_ms") is not None:
        return max(0.0, (wall_s - meter.waits.get(home, 0.0) - esc["wall_ms"] / 1000) * 1000 + float(esc.get("latency_ms") or 0.0))
    return max(0.0, wall_s - meter.excluded_s(home) - meter.background_s) * 1000


class RoleLimits:
    """A semaphore per model role and, after a 429, a cool-down every caller of that role waits out: several variants run at
    once inside the quota, and a rate-limited read is retried with exponential back-off instead of being scored as uncertain."""

    def __init__(self, per_role: int = PER_ROLE, retries: int = RETRIES_429, backoff_s: float = BACKOFF_S,
                 sleep: Callable[[float], Any] = time.sleep, guard: ReadCostGuard | None = None) -> None:
        self.per_role, self.retries, self.backoff_s, self.sleep, self.guard = max(1, per_role), retries, backoff_s, sleep, guard
        self.rate_limited = 0
        self._sems: dict[str, threading.BoundedSemaphore] = {}
        self._cool_until: dict[str, float] = {}
        self._lock = threading.Lock()

    def _semaphore(self, role: str) -> threading.BoundedSemaphore:
        with self._lock:
            return self._sems.setdefault(role, threading.BoundedSemaphore(self.per_role))

    def _cool_down(self, role: str, meter: TurnMeter | None) -> None:
        with self._lock:
            left = self._cool_until.get(role, 0.0) - time.monotonic()
        if left > 0:
            self.sleep(left)
            if meter is not None:
                meter.waited(left)

    def _limited(self, role: str, attempt: int, meter: TurnMeter | None, lost_s: float) -> None:
        backoff = self.backoff_s * 2 ** attempt
        with self._lock:
            self._cool_until[role] = max(self._cool_until.get(role, 0.0), time.monotonic() + backoff)
            self.rate_limited += 1
        if meter is not None:
            meter.waited(lost_s)
            meter.limited()
        log.warning("%s rate-limited (429); backing off %.1f s", role, backoff)

    def wrap(self, fn: Callable[..., Any]) -> Callable[..., Any]:
        @functools.wraps(fn)
        def guarded(task: str, role_name: str, *args: Any, **kwargs: Any) -> Any:
            meter, background = METER.get(), task == scam_variants.ESCALATION_TASK
            for attempt in range(self.retries + 1):
                if self.guard is not None:
                    self.guard.check(role_name)
                self._cool_down(role_name, meter)
                queued = clock()
                with self._semaphore(role_name):
                    started = clock()
                    if meter is not None:
                        meter.waited(started - queued)
                    token = genai_client.RETRY_CODES_VAR.set(genai_client.RETRY_CODES - {429})  # every 429 comes here, metered
                    try:
                        result = fn(task, role_name, *args, **kwargs)
                    except Exception as exc:
                        if getattr(exc, "code", None) != 429 or attempt == self.retries:
                            if meter is not None and background:  # a failed background read is still off the synchronous path
                                meter.charge(None, clock() - started, background=True)
                            raise
                        lost = clock() - started
                    else:
                        if meter is not None:
                            meter.charge(result, clock() - started, background=background)
                        if self.guard is not None:
                            self.guard.observe(role_name, result)
                        return result
                    finally:
                        genai_client.RETRY_CODES_VAR.reset(token)
                self._limited(role_name, attempt, meter, lost)  # the next attempt waits out the cool-down, holding no slot
            raise AssertionError("unreachable")
        return guarded


@contextmanager
def guarded_calls(limits: RoleLimits) -> Iterator[None]:
    """Route every model read the detector makes (genai_client.call and v4's call_with_thoughts) through the role limits."""
    original = (genai_client.call, scam_variants.call_with_thoughts)
    genai_client.call, scam_variants.call_with_thoughts = limits.wrap(original[0]), limits.wrap(original[1])
    try:
        yield
    finally:
        genai_client.call, scam_variants.call_with_thoughts = original


class Budget:
    """The eval SpendLedger with in-process holds: turns running at once each hold their worst case before they call, so
    together they cannot pass the cap that one turn at a time respects."""

    def __init__(self, ledger: SpendLedger) -> None:
        self.ledger, self.held = ledger, 0.0
        self._lock = threading.Lock()

    def hold(self, usd: float) -> None:
        with self._lock:
            self.ledger.check(self.held + usd)
            self.held = round(self.held + usd, 6)

    def settle(self, held: float, cost: float) -> None:
        with self._lock:
            self.held = max(0.0, round(self.held - held, 6))
            self.ledger.record(cost)


def _escalation_trace(esc: dict | None, ts: float, next_ts: float | None, sync_ms: float) -> dict | None:
    if not esc:
        return None
    out = {k: esc.get(k) for k in ("kind", "background", "trigger", "changed", "latency_ms", "agreement", "error")}
    out["verdict"] = esc.get("verdict", esc.get("majority"))
    if esc.get("background") and next_ts is not None and esc.get("latency_ms") is not None:
        out["lands_before_next_caller_turn"] = (ts + (sync_ms + esc["latency_ms"]) / 1000) <= next_ts
    return out


def replay_dialogue(row: dict, variant: str, settings: Settings, budget: Budget | None = None, guard: ReadCostGuard | None = None) -> dict:
    """Score every caller turn of one dialogue under `variant`, as /v1/scam/turn would while the caller speaks. A tripped
    guard abandons the dialogue (score_turn turns the guard's refusal into an 'uncertain' read, which must not be scored)."""
    turns, detected, trace = row["turns"], None, []
    reserve = TURN_RESERVE.get(variant, RESERVE_PER_CALL)
    caller_ts = [t["ts"] for t in turns if t["speaker"] == "caller"]
    for i, turn in enumerate(turns):
        if turn["speaker"] != "caller":
            continue
        if budget is not None:
            budget.hold(reserve)
        meter, home = TurnMeter(), threading.get_ident()
        token = METER.set(meter)
        try:
            with scam_variants.recording() as recorded, scam_variants.synchronous_escalations():
                started = clock()
                out = scam.score_turn(ScamTurnRequest(session_id=f"eval-{variant}-{row['id']}", turns=turns[: i + 1],
                                                      caller_number=HELP_LINE_FOR.get(row["archetype"])), settings)
                wall_s = clock() - started
        finally:
            METER.reset(token)
            if budget is not None:
                budget.settle(reserve, meter.cost_usd)
        esc = next((r.escalation for r in recorded if r.escalated and r.escalation), None)
        turn_ms = sync_ms(wall_s, meter, home, esc)
        next_ts = next((t for t in caller_ts if t > turn["ts"]), None)
        trace.append({"turn": i, "scam_type": out.scam_type, "verdict": getattr(out, "verdict", None), "confidence": out.confidence,
                      "rolling": out.rolling_score, "quote": out.evidence_quote, "ms": round(turn_ms, 1), "wall_ms": round(wall_s * 1000, 1),
                      "cost_usd": round(meter.cost_usd, 6), "calls": meter.calls, "rate_limited": meter.rate_limited,
                      "escalation": _escalation_trace(esc, turn["ts"], next_ts, turn_ms)})
        if guard is not None:
            guard.check("volume")
        if detected is None and out.rolling_score >= scam.ALERT_PAIR:
            detected = i
    return {"id": row["id"], "label": row["label"], "archetype": row["archetype"], "channel": row.get("channel"), "split": row.get("split"),
            "first_detectable_turn": row.get("first_detectable_turn"), "turns": len(turns), "detected_turn": detected, "trace": trace}


def flip_rate(outcomes: list[dict], baseline: dict | None) -> dict | None:
    """How many held-out dialogues changed flagged/clear against V0's saved outcomes (labels play no part)."""
    v0 = {o["id"]: o["detected_turn"] is not None for o in (baseline or {}).get("outcomes", [])}
    if not v0:
        return None
    common = [o for o in outcomes if o["id"] in v0]
    flips = [o for o in common if (o["detected_turn"] is not None) != v0[o["id"]]]
    return {"n": len(common), "flips": len(flips), "rate": round(len(flips) / len(common), 3) if common else None,
            "now_flagged": sorted(o["id"] for o in flips if o["detected_turn"] is not None),
            "now_clear": sorted(o["id"] for o in flips if o["detected_turn"] is None)}


def escalation_summary(traces: list[dict]) -> dict:
    esc = [t["escalation"] for t in traces if t["escalation"]]
    landed = [e for e in esc if e.get("background") and e.get("latency_ms") is not None and not e.get("error")]
    lands = [e["latency_ms"] for e in landed]
    before_next = [e["lands_before_next_caller_turn"] for e in landed if "lands_before_next_caller_turn" in e]
    return {"turns": len(traces), "escalated": len(esc), "share": round(len(esc) / len(traces), 3) if traces else None,
            "kinds": sorted({e["kind"] for e in esc if e.get("kind")}), "errors": sum(bool(e.get("error")) for e in esc),
            "changed_share": round(sum(bool(e.get("changed")) for e in esc) / len(esc), 3) if esc else None,
            "lands_after_ms": {"p50": _percentile(lands, 0.5), "p95": _percentile(lands, 0.95)} if lands else None,
            "lands_before_next_caller_turn": round(sum(before_next) / len(before_next), 3) if before_next else None}


def summarise_variant(variant: str, outcomes: list[dict], *, skipped: list[str] | tuple = (), baseline: dict | None = None,
                      sets: tuple = ()) -> dict:
    held = [o for o in outcomes if o.get("split") != "adversarial"]
    adversarial = [o for o in outcomes if o.get("split") == "adversarial"]
    traces = [t for o in outcomes for t in o["trace"]]
    turn_ms, wall_ms = [t["ms"] for t in traces], [t["wall_ms"] for t in traces]
    cost = sum(t["cost_usd"] for t in traces)
    m = metrics.summarise(held) if held else None
    return {
        "variant": variant, "reads": VARIANT_READS.get(variant), "sets": list(sets), "n": {"held_out": len(held), "adversarial": len(adversarial)},
        "metrics": m, "intervals": metrics.intervals(held) if held else None,
        "adversarial": {**metrics.pass_rate(adversarial), "missed": sorted(o["id"] for o in adversarial if o["detected_turn"] is None)}
        if adversarial else None,
        "median_turns_to_detection": m["median_turns_to_detection"] if m else None,
        "turn_ms": {"p50": _percentile(turn_ms, 0.5), "p95": _percentile(turn_ms, 0.95), "n": len(turn_ms), "path": "synchronous"},
        "turn_wall_ms": {"p50": _percentile(wall_ms, 0.5), "p95": _percentile(wall_ms, 0.95)},
        "cost": {"total_usd": round(cost, 6), "per_call_usd": round(cost / len(outcomes), 6) if outcomes else None,
                 "per_turn_usd": round(cost / len(traces), 6) if traces else None, "model_calls": sum(t["calls"] for t in traces)},
        "flip_vs_v0": flip_rate(held, baseline),
        "escalation": escalation_summary(traces),
        "rate_limited": sum(t["rate_limited"] for t in traces),
        **errors_of(held),
        "incomplete": {"skipped": sorted(skipped), "reason": "the eval spend cap (RISK_MW_EVAL_BUDGET_USD) was reached, or the dialogue "
                       "failed (its error class is named)"} if skipped else None,
        "outcomes": outcomes,
    }


def load_progress(path: Path | None) -> dict[tuple[str, str], dict]:
    """(variant, dialogue id) -> the outcome a stopped run already paid for."""
    if path is None or not path.exists():
        return {}
    return {(r["variant"], r["outcome"]["id"]): r["outcome"] for r in _jsonl(path)}


def run_variants(variants: tuple[str, ...], rows: list[dict], *, ledger: SpendLedger | None = None, per_role: int = PER_ROLE,
                 baseline: dict | None = None, sets: tuple = (), limits: RoleLimits | None = None, progress: Path | None = None,
                 guard: ReadCostGuard | None = None) -> list[dict]:
    """Every variant over every row at once, dialogues in parallel and turns in order, model reads bounded per role. Each finished
    dialogue is appended to `progress` as it lands, and a restarted run takes those from it instead of reading them again."""
    limits = limits or RoleLimits(per_role, guard=guard)
    budget = Budget(ledger) if ledger is not None else None
    base = get_settings()
    settings = {v: base.model_copy(update={"scam_variant": v}) for v in variants}
    done = load_progress(progress)
    outcomes: dict[str, dict[str, dict]] = {v: {r["id"]: done[(v, r["id"])] for r in rows if (v, r["id"]) in done} for v in variants}
    skipped: dict[str, list[str]] = {v: [] for v in variants}
    stopped: dict[str, str] = {}
    lock = threading.Lock()

    def one(row: dict, variant: str) -> dict:
        outcome = replay_dialogue(row, variant, settings[variant], budget, guard)
        if progress is not None:
            with lock:
                progress.parent.mkdir(parents=True, exist_ok=True)
                with progress.open("a", encoding="utf-8") as f:
                    f.write(json.dumps({"variant": variant, "outcome": outcome}, ensure_ascii=False) + "\n")
        return outcome

    with guarded_calls(limits), ThreadPoolExecutor(max_workers=max(1, per_role * 2), thread_name_prefix="eval") as pool:
        jobs = [(v, r, pool.submit(contextvars.copy_context().run, one, r, v)) for v in variants for r in rows if r["id"] not in outcomes[v]]
        for v, r, job in jobs:
            try:
                outcomes[v][r["id"]] = job.result()
            except BudgetExceeded:
                skipped[v].append(r["id"])
            except CostTooHigh as exc:
                skipped[v].append(r["id"])
                stopped[v] = str(exc)
            except Exception as exc:  # noqa: BLE001 - one broken dialogue must not throw away a paid run
                log.warning("variant %s, dialogue %s failed: %r", v, r["id"], exc)
                skipped[v].append(f"{r['id']} ({exc.__class__.__name__})")
    results = []
    for v in variants:
        ordered = [outcomes[v][r["id"]] for r in rows if r["id"] in outcomes[v]]
        result = summarise_variant(v, ordered, skipped=skipped[v], baseline=baseline, sets=sets)
        result["row_ids"] = [r["id"] for r in rows]
        if v in stopped and result["incomplete"]:
            result["incomplete"]["reason"] = f"stopped early on the per-read cost: {stopped[v]}"
        results.append(result)
    return results


def _ci(ci: Any) -> str:
    return f"{ci[0]:.2f}–{ci[1]:.2f}" if ci else "n/a"


def variant_markdown(r: dict) -> str:
    m, ci, adv, esc, cost, flips = r["metrics"] or {}, r["intervals"] or {}, r["adversarial"], r["escalation"], r["cost"], r["flip_vs_v0"]
    passed = f"{adv['passed']} of {adv['n']} = {adv['rate']}" if adv else "not run"
    flipped = f"{flips['flips']} of {flips['n']} (now flagged {flips['now_flagged']}, now clear {flips['now_clear']})" if flips else "no V0 outcomes"
    lines = [f"# Detector variant {r['variant']}: {r['reads']}", "",
             f"Sets: {', '.join(r['sets']) or 'given rows'}; held-out {r['n']['held_out']}, adversarial {r['n']['adversarial']}.", "",
             "| Metric | Value | Wilson 95% interval |", "|---|---|---|",
             f"| Precision | {m.get('precision')} | {_ci(ci.get('precision'))} |",
             f"| Recall | {m.get('recall')} | {_ci(ci.get('recall'))} |",
             f"| Benign false-positive rate | {m.get('benign_false_positive_rate')} | {_ci(ci.get('benign_false_positive_rate'))} |",
             f"| Adversarial pass rate | {passed} | {_ci(adv['ci']) if adv else 'n/a'} |",
             f"| Median turns to detection | {m.get('median_turns_to_detection')} "
             f"({m.get('median_turns_after_first_detectable')} after the first detectable turn) | |",
             f"| Per-turn latency p50 / p95, synchronous path | {r['turn_ms']['p50']} / {r['turn_ms']['p95']} ms | |",
             f"| Cost | ${cost['per_call_usd']} a call, ${cost['per_turn_usd']} a turn, ${cost['total_usd']} in all "
             f"({cost['model_calls']} model reads) | |",
             f"| Flips against V0 | {flipped} | |",
             f"| Escalated or resampled turns | {esc['escalated']} of {esc['turns']} ({esc['share']}); verdict changed on {esc['changed_share']} | |"]
    if esc["lands_after_ms"]:
        lines.append(f"| Background verdict lands after | p50 {esc['lands_after_ms']['p50']} / p95 {esc['lands_after_ms']['p95']} ms; "
                     f"before the next caller turn on {esc['lands_before_next_caller_turn']} | |")
    lines += ["", f"False positives: {[f['id'] for f in r['false_positives']] or 'none'}. Misses: {[x['id'] for x in r['misses']] or 'none'}. "
                  f"Adversarial misses: {adv['missed'] if adv else 'n/a'}.",
              f"Rate-limited reads retried: {r['rate_limited']}." + (f" INCOMPLETE: {r['incomplete']['reason']}; skipped {r['incomplete']['skipped']}."
                                                                      if r["incomplete"] else ""), "",
              "Held-out dialogues are Gemini-generated and the adversarial ones are a non-native draft pending a native check; read the "
              "intervals, not the point estimates, before calling one variant better than another."]
    return "\n".join(lines) + "\n"


def write_variant(result: dict, out_dir: Path) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / f"{result['variant']}.json").write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    (out_dir / f"{result['variant']}.md").write_text(variant_markdown(result), encoding="utf-8")


def _jsonl(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def load_rows(which: str, limit: int = 0) -> list[dict]:
    held = [r for r in _jsonl(DIALOGUES) if r["split"] == "held_out"] if which in ("held_out", "both") else []
    adversarial = _jsonl(ADVERSARIAL) if which in ("adversarial", "both") else []
    return held[: limit or None] + adversarial[: limit or None]


def eval_cap() -> float:
    return float(os.environ.get("RISK_MW_EVAL_BUDGET_USD", "1.60"))


def plan(variants: tuple[str, ...], rows: list[dict], ledger: SpendLedger, per_role: int = PER_ROLE) -> str:
    turns = sum(t["speaker"] == "caller" for r in rows for t in r["turns"])
    adversarial = sum(r.get("split") == "adversarial" for r in rows)
    lines = [f"dry run: {len(rows)} dialogues ({len(rows) - adversarial} held-out, {adversarial} adversarial), {turns} caller turns "
             f"per variant; no model call is made and nothing is written"]
    baseline = load_baseline() or {}
    per_read = (baseline["classifier_cost_usd"] / baseline["classifier_calls"]) if baseline.get("classifier_calls") else RESERVE_PER_CALL / 3
    expected = 0.0
    for v in variants:
        reads = turns * CALLS_PER_TURN[v]
        # worst case: every turn escalated (a 3.8 Flash read costs about five Flash-Lite reads) or resampled twice
        expected += turns * per_read * (1 + {"v4": 5, "v5": 2}.get(v, 0))
        lines.append(f"  {v} ({VARIANT_READS[v]}): {turns} to {reads} model reads; reserve ${TURN_RESERVE[v]:.3f} a turn, held against "
                     f"the cap until the turn settles")
    fits = ledger.spent() + expected <= ledger.cap_usd
    lines += [f"  expected about ${expected:.2f} at V0's ${per_read:.5f} a read, every possible escalation counted (V0 read six turns; "
              f"the full transcript and the cards prefix cost more, the cached prefix less)",
              f"  ledger ${ledger.spent():.4f} of ${ledger.cap_usd:.2f} spent ({ledger.path.name}): "
              + ("fits" if fits else "may stop at the cap, and the run records what it skipped"),
              f"  at most {per_role} reads in flight per model role (--per-role); writes eval/results/variants/<variant>.json and .md, "
              f"never eval/results/intervention.json (V0 stays the baseline)"]
    return "\n".join(lines)


def require_gemini() -> None:
    """A variant run with Gemini off would measure the keyword stub; stop instead."""
    try:
        genai_client.select_backend(get_settings())
    except genai_client.GenAIDisabled as exc:
        raise SystemExit(f"Gemini is off ({exc}); a variant run would measure the offline stub. Use --dry-run, or enable Gemini.") from exc


def load_baseline() -> dict | None:
    path = RESULTS / "intervention.json"
    return json.loads(path.read_text(encoding="utf-8")) if path.exists() else None


def run_variant_cli(args: argparse.Namespace) -> None:
    variants = scam_variants.VARIANTS if "all" in args.variant else tuple(dict.fromkeys(args.variant))
    rows = load_rows(args.set, args.limit)
    ledger = SpendLedger(args.spend_file or DEFAULT_FILE, cap_usd=eval_cap())
    if args.dry_run:
        print(plan(variants, rows, ledger, args.per_role))
        return
    require_gemini()
    sets = ("held_out", "adversarial") if args.set == "both" else (args.set,)
    progress = None if args.no_progress else (args.progress or RESULTS / "variants" / "progress.jsonl")
    results = run_variants(variants, rows, ledger=ledger, per_role=args.per_role, baseline=load_baseline(), sets=sets, progress=progress,
                           guard=ReadCostGuard())
    for result in results:
        write_variant(result, RESULTS / "variants")
        print(variant_markdown(result))
    print(f"spent ${ledger.spent():.4f} of ${ledger.cap_usd:.2f} on the eval ledger")


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--split", default="held_out", choices=["held_out", "dev", "all"], help="a plain (V0) run's dialogues")
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--recompute", action="store_true", help="rescore the saved outcomes against the current labels; no classifier calls")
    parser.add_argument("--variant", nargs="+", choices=(*scam_variants.VARIANTS, "all"), help="re-measure with these reasoning variants")
    parser.add_argument("--set", default="both", choices=SETS, help="a variant run's dialogues: held-out, adversarial or both")
    parser.add_argument("--per-role", type=int, default=PER_ROLE, help="model reads in flight at once per model role")
    parser.add_argument("--dry-run", action="store_true", help="list the calls and the reserve; call nothing, write nothing")
    parser.add_argument("--spend-file", type=Path, default=None, help="the eval spend ledger (default .eval_spend.json)")
    parser.add_argument("--replace-baseline", action="store_true", help="let a plain classifier run overwrite intervention.json (V0)")
    parser.add_argument("--progress", type=Path, default=None,
                        help="a variant run's per-dialogue results, appended as each finishes and read back on restart "
                             "(default eval/results/variants/progress.jsonl)")
    parser.add_argument("--no-progress", action="store_true", help="neither read nor write the progress file")
    args = parser.parse_args(argv)
    if args.variant:
        run_variant_cli(args)
        return
    rows = _jsonl(DIALOGUES)
    if args.recompute:
        result = recompute(json.loads((RESULTS / "intervention.json").read_text(encoding="utf-8")), rows)
        (RESULTS / "intervention.json").write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
        (RESULTS / "intervention.md").write_text(to_markdown(result), encoding="utf-8")
        print(to_markdown(result))
        return
    if (RESULTS / "intervention.json").exists() and not args.replace_baseline:
        parser.error("eval/results/intervention.json is V0, the baseline the variants are compared with: measure a variant with "
                     "--variant, or pass --replace-baseline to overwrite it")
    rows = [r for r in rows if args.split == "all" or r["split"] == args.split][: args.limit or None]
    ledger = SpendLedger(args.spend_file or DEFAULT_FILE, cap_usd=eval_cap())
    result = {"n": len(rows), "split": args.split, **evaluate(rows, ledger, score_latency()), "spent_usd_ledger": ledger.spent()}
    RESULTS.mkdir(exist_ok=True)
    result = keep_speech_smoke(result, RESULTS / "intervention.json")
    (RESULTS / "intervention.json").write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    (RESULTS / "intervention.md").write_text(to_markdown(result), encoding="utf-8")
    print(to_markdown(result))


if __name__ == "__main__":
    main()
