"""The 300 ms promise as a measured hit rate: is a fresh warning already rendered when the hold fires? PAID.

    python scripts/prerender_replay.py --dry-run         # the calls, the planned model and TTS calls, the reserve: no spend
    RISK_MW_GENAI_ENABLED=true RISK_MW_TTS_ENABLED=true RISK_MW_PROJECT_ID=... python scripts/prerender_replay.py

Replays 20 held-out scam calls turn by turn on their own ts timeline. At call start, app.prerender.call_start_pair (C0); then
for every caller turn app.scam.score_turn with a pending action, then app.prerender.maybe_prearm with the call's state (C1), so
the real composer (app.warnings) and the real TTS run. Two submit moments: at the crossing (the first caller turn whose risk
reaches the alert level with the pending action, recommended_action "hold_and_warn": the worst case) and at the next caller
turn. A pre-render started at its turn's ts plus that turn's scoring time and was ready after its measured generation and
render time (the wall time of the call, or gen_ms plus the render times when they are longer). At the hold, once its turn is
scored, the latest pre-render ready by then is "fresh" when its key (app.warnings.key) is the hold's, "stale" otherwise (with
the reason: the band moved, or the evidence); with none ready, "call_start" when the C0 pair was ready; else "none". Calls that
never hold are listed apart. TTS renders alternate between the tts and tts_fallback roles when both answer (two quotas), and a 429 on
one hands the line to the other. Spend: eval/budget.py's SpendLedger (RISK_MW_EVAL_BUDGET_USD), checked before each step with
a worst-case reserve and charged after with what the Gemini and TTS ledgers moved. Writes eval/results/prerender_replay.json.
"""

from __future__ import annotations

import argparse
import inspect
import json
import os
import sys
import threading
import time
from collections import defaultdict
from collections.abc import Callable, Iterator
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))

from app.contracts import ScamTurnRequest  # noqa: E402

DIALOGUES = HERE / "eval" / "scam_dialogues.jsonl"
OUT = HERE / "eval" / "results" / "prerender_replay.json"
N_CALLS = 20
PENDING_ACTION = "send_money"
ENGINES = ("tts", "tts_fallback")
DELIVERY_MS = 200.0          # push to the phone, the report's 0.1-0.3 s
TTS_RESERVE = 0.01           # app.tts.RESERVE_USD: the worst case for one line
RESERVE_TURN = 0.003         # one detector read with the cards prefix
RESERVE_C0 = 0.002 + 2 * TTS_RESERVE
RESERVE_C1 = 0.002 + 4 * TTS_RESERVE
EXPECTED_WARNINGS_USD = 0.01  # the report: about one cent of composer and TTS a suspicious call
EXPECTED_READ_USD = 0.0007    # V0's measured cost of one detector read
STATUSES = ("fresh", "stale", "call_start", "none")
ROUTE_PARAMS = ("role", "role_name", "engine")
clock = time.perf_counter
wall = time.time  # a replayed call starts now: the pre-render's `now` is this plus the call's own ts, never a bare 0.0


@dataclass(frozen=True)
class Deps:
    """The pipeline the replay drives; real_deps() is the paid one, tests pass fakes."""

    score_turn: Callable[..., Any]
    state_of: Callable[..., Any]
    maybe_prearm: Callable[..., Any]
    call_start_pair: Callable[..., Any]
    key: Callable[..., str] | None = None  # app.warnings.key, what a prepared warning is kept under; None: ledger.hash


def _state_of(session_id: str, uid: str, response: Any) -> Any:
    """The call's state after a scored turn, from the session document the detector wrote (ledger, risk, band)."""
    from app import scam, state

    doc = scam.own_session(state.get_many(scam.session_keys(session_id, uid)), uid)
    return scam.session_state_of(doc)


def real_deps() -> Deps:
    from app import prerender, scam

    missing = [name for name, mod in (("scam.session_state_of", scam), ("prerender.maybe_prearm", prerender)) if not hasattr(mod, name.split(".")[1])]
    if missing:
        raise SystemExit(f"the replay needs the merged detector and pre-render: {missing} not found")
    from app import warnings

    # Each call runs on its own ts timeline, so a real trailing timer would refresh outside it and outside the eval ledger's
    # reserve. The replay does not model the trailing refresh yet: its "fresh" rate is a lower bound for the service's.
    prerender.TRAILING = _NoTimers()
    return Deps(score_turn=scam.score_turn, state_of=_state_of, maybe_prearm=prerender.maybe_prearm, call_start_pair=prerender.call_start_pair,
                key=warnings.key)


class _NoTimers:
    def schedule(self, key: Any, delay: float, fn: Any) -> bool:
        return False


def pick_calls(rows: list[dict], n: int = N_CALLS) -> list[dict]:
    """n held-out scam calls, taken in turn from each archetype in id order: deterministic and spread over the archetypes."""
    groups: dict[str, list[dict]] = defaultdict(list)
    for r in sorted((r for r in rows if r.get("split") == "held_out" and r["label"] == "scam"), key=lambda r: r["id"]):
        groups[r["archetype"]].append(r)
    picked, names = [], sorted(groups)
    while len(picked) < n and any(groups.values()):
        for name in names:
            if groups[name] and len(picked) < n:
                picked.append(groups[name].pop(0))
    return picked


def _spent_now() -> float:
    """What the Gemini and TTS instance ledgers have charged so far: their movement across a step is that step's cost."""
    from app import genai_client, tts

    ledger = getattr(tts, "LEDGER", None)
    tts_spent = getattr(ledger, "spent_usd", None)
    if tts_spent is None and hasattr(ledger, "spent"):
        tts_spent = ledger.spent()
    return float(genai_client.LEDGER.spent()) + float(tts_spent or 0.0)


def _step(ledger: Any, reserve: float, fn: Callable[[], Any]) -> tuple[Any, float]:
    """Run one pipeline step under the spend cap; returns its result and its measured wall time in ms."""
    if ledger is not None:
        ledger.check(reserve)
        before = _spent_now()
    started = clock()
    try:
        return fn(), (clock() - started) * 1000
    finally:
        if ledger is not None:
            ledger.record(max(0.0, _spent_now() - before))


def _entry(p: Any, stage: str, started_at: float, wall_ms: float) -> dict:
    render = {str(k): float(v) for k, v in (getattr(p, "render_ms", None) or {}).items()}
    gen_ms = float(getattr(p, "gen_ms", 0.0) or 0.0)
    ready_ms = max(wall_ms, gen_ms + sum(render.values()))  # a pre-render that renders in the background is not ready on return
    return {"stage": getattr(p, "stage", None) or stage, "warning_id": getattr(p, "warning_id", None), "ledger_hash": getattr(p, "ledger_hash", None),
            "lines": len(getattr(p, "lines", ()) or ()), "gen_ms": gen_ms, "render_ms": render, "wall_ms": round(wall_ms, 1),
            "started_at": round(started_at, 3), "ready_at": round(started_at + ready_ms / 1000, 3)}


def classify(prepared: list[dict], c0: dict | None, hold_at: float, hold_hash: str) -> str:
    """At hold_at (the moment the hold can fire: its turn scored), the latest pre-render ready by then decides."""
    ready = [p for p in prepared if p["ready_at"] <= hold_at]
    if ready:
        return "fresh" if max(ready, key=lambda p: p["ready_at"])["ledger_hash"] == hold_hash else "stale"
    return "call_start" if c0 is not None and c0["ready_at"] <= hold_at else "none"


def stale_reason(prepared: list[dict], hold: dict) -> str | None:
    """Why the latest ready pre-render did not match: the certainty band moved (same evidence) or the evidence moved."""
    ready = [p for p in prepared if p["ready_at"] <= hold["at"]]
    if not ready:
        return None
    latest = max(ready, key=lambda p: p["ready_at"])
    return "band" if latest["evidence"] == hold["evidence"] and latest["band"] != hold["band"] else "evidence"


def replay_call(row: dict, deps: Deps, settings: Any, *, pending_action: str = PENDING_ACTION, uid: str = "replay",
                ledger: Any = None, guard: Any = None) -> dict:
    """Two submit moments (review finding, H): at the crossing (she presses send the moment the risk first reaches the alert:
    the worst case, since a pre-render started on that turn cannot be ready yet) and at the next caller turn (the scammer
    talks her through it). The pre-arm runs on every scored turn up to the crossing, the crossing turn included."""
    session_id, turns, epoch = f"replay-{row['id']}", row["turns"], wall()
    keyf = deps.key or (lambda led, pending, band: led.hash(pending, band))
    t0 = float(turns[0]["ts"])
    c0, c0_ms = _step(ledger, RESERVE_C0, lambda: deps.call_start_pair(session_id, uid, settings, now=epoch + t0))
    c0_entry = _entry(c0, "C0", t0, c0_ms) if c0 is not None else None
    prepared: list[dict] = []
    hold = nxt = None
    for i, turn in enumerate(turns):
        if turn["speaker"] != "caller":
            continue
        req = ScamTurnRequest(session_id=session_id, turns=turns[: i + 1], pending_action=pending_action)
        out, score_ms = _step(ledger, RESERVE_TURN, lambda req=req: deps.score_turn(req, settings, uid))
        if guard is not None:
            guard.check("volume")  # score_turn swallows the guard's refusal as an 'uncertain' read: never score the call on it
        state = deps.state_of(session_id, uid, out)
        at = float(turn["ts"]) + score_ms / 1000
        point = {"turn": i, "ts": float(turn["ts"]), "at": round(at, 3), "risk": state.risk, "band": state.band,
                 "ledger_hash": keyf(state.ledger, pending_action, state.band), "evidence": keyf(state.ledger, pending_action, None)}
        if hold is not None:
            nxt = point  # the next caller turn: she submits once it is scored
            break
        if out.recommended_action == "hold_and_warn":
            hold = point
        p, wall_ms = _step(ledger, RESERVE_C1, lambda state=state, at=at: deps.maybe_prearm(session_id, uid, state, pending_action, settings,
                                                                                            now=epoch + at))
        if p is not None:
            prepared.append({**_entry(p, "C1", at, wall_ms), "band": state.band, "evidence": point["evidence"]})
    status = classify(prepared, c0_entry, hold["at"], hold["ledger_hash"]) if hold else "no_hold"
    status_next = (classify(prepared, c0_entry, nxt["at"], nxt["ledger_hash"]) if nxt else status) if hold else "no_hold"
    return {"id": row["id"], "archetype": row["archetype"], "first_detectable_turn": row.get("first_detectable_turn"),
            "caller_turns": sum(t["speaker"] == "caller" for t in turns), "status": status, "status_next": status_next,
            "stale_reason": stale_reason(prepared, hold) if status == "stale" else None,
            "stale_reason_next": stale_reason(prepared, nxt or hold) if status_next == "stale" else None,
            "hold": hold, "next": nxt, "c0": c0_entry, "prepared": prepared}


def _pct(xs: list[float], p: float) -> float | None:
    return round(sorted(xs)[min(len(xs) - 1, int(p * len(xs)))], 1) if xs else None


def summarise(calls: list[dict], spreader: EngineSpreader | None = None) -> dict:
    held = [c for c in calls if c["status"] != "no_hold"]
    counts = {s: sum(c["status"] == s for c in held) for s in STATUSES}
    counts_next = {s: sum(c.get("status_next") == s for c in held) for s in STATUSES}
    reasons = {m: {r: sum(c.get(k) == r for c in held) for r in ("band", "evidence")}
               for m, k in (("at_crossing", "stale_reason"), ("next_turn", "stale_reason_next"))}
    prepared = [p for c in calls for p in ([c["c0"]] if c["c0"] else []) + c["prepared"]]
    gen = [p["gen_ms"] for p in prepared]
    renders = [r["ms"] for r in spreader.renders if r["ok"]] if spreader and spreader.renders else []
    source = "tts" if renders else "prerender"
    renders = renders or [ms for p in prepared for ms in p["render_ms"].values()]
    gen_p50, gen_p95, r_p50, r_p95 = _pct(gen, 0.5), _pct(gen, 0.95), _pct(renders, 0.5), _pct(renders, 0.95)
    cold = None
    if gen_p50 is not None and r_p50 is not None:
        cold = {"p50": round(gen_p50 + r_p50 + DELIVERY_MS, 1), "p95": round(gen_p95 + r_p95 + DELIVERY_MS, 1),
                "method": "a whole warning's generation (an upper bound for line A) + one line's render + 200 ms delivery; first audible "
                          "sample on a phone still to be timed"}
    return {"n_calls": len(calls), "held": len(held), "no_hold": [c["id"] for c in calls if c["status"] == "no_hold"],
            "counts": counts, "hit_rate": {s: round(counts[s] / len(held), 3) if held else None for s in STATUSES},
            "counts_next_turn": counts_next,
            "hit_rate_next_turn": {s: round(counts_next[s] / len(held), 3) if held else None for s in STATUSES},
            "stale_reasons": reasons,
            "generation_ms": {"p50": gen_p50, "p95": gen_p95, "n": len(gen)},
            "render_ms_per_line": {"p50": r_p50, "p95": r_p95, "n": len(renders)}, "render_source": source,
            "cold_path_estimate_ms": cold, "engines": spreader.summary() if spreader else None, "calls": calls}


def run(rows: list[dict], deps: Deps, settings: Any, *, pending_action: str = PENDING_ACTION, uid: str = "replay", ledger: Any = None,
        spreader: EngineSpreader | None = None, progress: Path | None = None, guard: Any = None) -> dict:
    """Each finished call (with the TTS renders it made) is appended to `progress` as it lands; a restarted run takes those
    from it. The spend cap or a tripped read-cost guard stops the run and keeps what it paid for (`stopped` says why)."""
    from eval.budget import BudgetExceeded
    from eval.intervention_eval import CostTooHigh

    done = {}
    if progress is not None and progress.exists():
        done = {r["call"]["id"]: r for r in (json.loads(x) for x in progress.read_text(encoding="utf-8").splitlines() if x.strip())}
    calls, stopped = [], None
    for r in rows:
        if r["id"] in done:
            calls.append(done[r["id"]]["call"])
            if spreader is not None:
                spreader.renders.extend(done[r["id"]].get("renders", []))
            continue
        before = len(spreader.renders) if spreader is not None else 0
        try:
            call = replay_call(r, deps, settings, pending_action=pending_action, uid=uid, ledger=ledger, guard=guard)
        except (BudgetExceeded, CostTooHigh) as exc:
            stopped = f"{exc.__class__.__name__}: {exc}"
            break
        calls.append(call)
        if progress is not None:
            progress.parent.mkdir(parents=True, exist_ok=True)
            renders = spreader.renders[before:] if spreader is not None else []
            with progress.open("a", encoding="utf-8") as f:
                f.write(json.dumps({"call": call, "renders": renders}, ensure_ascii=False) + "\n")
    return {"pending_action": pending_action, "stopped": stopped, **summarise(calls, spreader)}


def write(result: dict, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")


# --- spreading TTS renders over the two engines -------------------------------------------------------


def _rate_limited(exc: BaseException) -> bool:
    return exc.__class__.__name__ == "RateLimited" or getattr(exc, "code", None) == 429 or "429" in str(exc)


class EngineSpreader:
    """Stands in for app.tts.speak during the replay: alternates renders between the engines (each has its own quota) when
    speak can be told which one to use, hands a rate-limited line to the other engine, drops an engine that is not there, and
    times every render to its last chunk."""

    def __init__(self, speak: Callable[..., Any], engines: tuple[str, ...]) -> None:
        self.speak, self.engines = speak, tuple(engines)
        params = inspect.signature(speak).parameters
        self.param = next((p for p in ROUTE_PARAMS if p in params), None)
        self.routed = self.param is not None and len(self.engines) > 1
        self.renders: list[dict] = []
        self.dropped: list[str] = []
        self._n = 0
        self._lock = threading.Lock()

    def _next(self) -> str | None:
        if not self.routed:
            return None
        with self._lock:
            engine = self.engines[self._n % len(self.engines)]
            self._n += 1
            return engine

    def _record(self, engine: str | None, started: float, ok: bool, error: str | None = None) -> None:
        with self._lock:
            self.renders.append({"engine": engine, "ms": round((clock() - started) * 1000, 1), "ok": ok, "error": error})

    def _other(self, engine: str | None, exc: BaseException) -> str | None:
        if engine is None:
            return None
        with self._lock:
            if not _rate_limited(exc) and engine in self.engines and len(self.engines) > 1:
                self.engines = tuple(e for e in self.engines if e != engine)  # not there (404/400): gone for the rest of the replay
                self.dropped.append(engine)
            return next((e for e in self.engines if e != engine), None)

    def __call__(self, *args: Any, **kwargs: Any) -> Any:
        return self._call(args, kwargs, self._next(), retry=True)

    def _call(self, args: tuple, kwargs: dict, engine: str | None, retry: bool) -> Any:
        kw = {**kwargs, self.param: engine} if engine and self.param else kwargs
        started = clock()
        try:
            out = self.speak(*args, **kw)
        except Exception as exc:
            self._record(engine, started, False, exc.__class__.__name__)
            other = self._other(engine, exc) if retry else None
            if other is None:
                raise
            return self._call(args, kwargs, other, retry=False)
        if isinstance(out, Iterator):
            return self._timed(out, args, kwargs, engine, started, retry)
        self._record(engine, started, True)
        return out

    def _timed(self, chunks: Iterator, args: tuple, kwargs: dict, engine: str | None, started: float, retry: bool) -> Iterator:
        sent = False
        try:
            for chunk in chunks:
                sent = True
                yield chunk
        except Exception as exc:
            self._record(engine, started, False, exc.__class__.__name__)
            other = self._other(engine, exc) if retry and not sent else None
            if other is None:
                raise
            out = self._call(args, kwargs, other, retry=False)
            if isinstance(out, Iterator):
                yield from out
            else:
                yield out
            return
        self._record(engine, started, True)

    def summary(self) -> dict:
        per = defaultdict(lambda: {"ok": 0, "failed": 0})
        for r in self.renders:
            per[str(r["engine"])]["ok" if r["ok"] else "failed"] += 1
        return {"engines": list(self.engines), "routed": self.routed, "dropped": self.dropped, "renders": dict(per),
                "note": None if self.routed else "app.tts.speak takes no engine argument (or one engine): renders were not spread"}


@contextmanager
def spreading(engines: tuple[str, ...]) -> Iterator[EngineSpreader]:
    from app import tts

    original = tts.speak
    spreader = EngineSpreader(original, engines)
    tts.speak = spreader
    try:
        yield spreader
    finally:
        tts.speak = original


def configured_engines() -> tuple[str, ...]:
    from app import genai_client

    roles = genai_client.load_roles(genai_client.get_settings().models_config_path)
    return tuple(e for e in ENGINES if e in roles)


# --- the command line --------------------------------------------------------------------------------


def plan(rows: list[dict], settings: Any, ledger: Any, engines: tuple[str, ...]) -> str:
    per_call = int(getattr(settings, "prearm_max_per_call", 4))
    turns = sum(t["speaker"] == "caller" for r in rows for t in r["turns"])
    reserve = len(rows) * (RESERVE_C0 + per_call * RESERVE_C1) + turns * RESERVE_TURN
    lines = [f"dry run: {len(rows)} held-out scam calls, {turns} caller turns at most; no model or TTS call is made and nothing is written"]
    lines += [f"  {r['id']}: {sum(t['speaker'] == 'caller' for t in r['turns'])} caller turns" for r in rows]
    expected = len(rows) * EXPECTED_WARNINGS_USD + turns * EXPECTED_READ_USD
    lines += [f"  per call: one C0 pair (one composer call, two renders), one detector read per caller turn up to the hold, up to "
              f"{per_call} C1 refreshes (one composer call and up to four renders each)",
              f"  each step reserves its worst case before it runs (C0 ${RESERVE_C0:.3f}, C1 ${RESERVE_C1:.3f}, a turn ${RESERVE_TURN:.3f}; "
              f"${reserve:.2f} if every step cost that) and is charged what the Gemini and TTS ledgers moved; expected about "
              f"${expected:.2f} (the report's cent a suspicious call plus the reads)",
              f"  ledger ${ledger.spent():.4f} of ${ledger.cap_usd:.2f} spent ({ledger.path.name})",
              f"  TTS engines configured: {list(engines) or 'none'} of {list(ENGINES)}; renders alternate only when both answer",
              f"  pending action {PENDING_ACTION}; writes {OUT.relative_to(HERE)}"]
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> None:
    from app.settings import get_settings
    from eval.budget import DEFAULT_FILE, SpendLedger

    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("-n", type=int, default=N_CALLS, help="held-out scam calls to replay")
    parser.add_argument("--pending-action", default=PENDING_ACTION, choices=("send_money", "new_payee", "pin_reset"))
    parser.add_argument("--spend-file", type=Path, default=DEFAULT_FILE)
    parser.add_argument("--out", type=Path, default=OUT)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--progress", type=Path, default=OUT.with_name("prerender_replay.progress.jsonl"),
                        help="per-call results, appended as each finishes and read back on restart")
    args = parser.parse_args(argv)
    rows = pick_calls([json.loads(line) for line in DIALOGUES.read_text(encoding="utf-8").splitlines() if line.strip()], args.n)
    settings = get_settings()
    ledger = SpendLedger(args.spend_file, cap_usd=float(os.environ.get("RISK_MW_EVAL_BUDGET_USD", "1.60")))
    engines = configured_engines()
    if args.dry_run:
        print(plan(rows, settings, ledger, engines))
        return
    if not (settings.genai_enabled and settings.tts_enabled):
        raise SystemExit("Gemini or TTS is off (RISK_MW_GENAI_ENABLED, RISK_MW_TTS_ENABLED): the replay would measure the fallbacks")
    from eval.intervention_eval import ReadCostGuard, RoleLimits, guarded_calls

    deps, guard = real_deps(), ReadCostGuard()
    with spreading(engines) as spreader, guarded_calls(RoleLimits(per_role=2, guard=guard)):
        result = run(rows, deps, settings, pending_action=args.pending_action, uid="replay", ledger=ledger, spreader=spreader,
                     progress=args.progress, guard=guard)
    result["spent_usd_ledger"] = ledger.spent()
    write(result, args.out)
    print(json.dumps({k: result[k] for k in ("stopped", "held", "counts", "hit_rate", "hit_rate_next_turn", "stale_reasons", "generation_ms",
                                             "render_ms_per_line", "cold_path_estimate_ms")},
                     indent=2))


if __name__ == "__main__":
    main()
