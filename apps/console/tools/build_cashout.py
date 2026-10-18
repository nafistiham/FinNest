"""Write fixtures/cashout.json from the campaign world.

The cash-out view's data, built the way build_campaigns.py builds the Incidents view's: the radar's common point of
cash-out rules run here, once, over data/seed-campaign, and the console and its two API routes read the committed
result. Nothing at request time replays the rules, reads Firestore or calls Gemini.

    python3 tools/build_cashout.py            # write fixtures/cashout.json
    python3 tools/build_cashout.py --check    # fail if the committed file is stale

What it reads:

* The rules (libs/radar/bhorosha_radar: cashout, cashout_rules, cashout_seeds), through the functions
  eval/cashout_eval.py itself runs: load_observable_bundle, scan_cashouts, day_boundaries, daily_run and
  first_candidates. One run per midnight, Asia/Dhaka, as of that instant, with the mules confirmed by then; each run
  also replays the circle over the days already past with the seeds known at that midnight.
* The seeds come from cashout_seeds.read_labels, which cuts labels.jsonl to acct_id, role and first_bad_ts: the
  confirmed-mule input the rules are built to take. No ring, typology or label reaches a detector section.
* eval/results/cashout.json (segments 3 and 3b) for the `evaluation` block: the seed_campaign world's
  measures, the caveat and the config, and one outcome per candidate. The build fails when that file was produced
  from another seed, another config or other candidates than the run here, so the evaluation can never describe a
  different run from the flags printed beside it. The outcome is eval-only and lives under `evaluation`.

Adapter rules, as build_campaigns.py's:

* Every timestamp the radar writes is naive Asia/Dhaka; it leaves here with +06:00 appended.
* A day is named by the date of its run (00:00), and that run closes the day before it.
* Events are kept only for days with a till flag or a cluster, to keep the file small: the cash-outs of the day the
  run closes, every seed cash-out a flag rests on and each listed candidate's own cash-out, with the kind of its
  account as of that run (seed, candidate or ordinary). A cluster carries its own members.
* Candidates are counted as the evaluation counts them: each account once per filter, on the first run that names
  it, with every day a run listed it.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from collections import Counter, defaultdict
from collections.abc import Callable, Iterable, Mapping, Sequence
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.build_campaigns import BuildError, comparable, serialize, sha256, with_offset  # noqa: E402

REPO = ROOT.parents[1]                      # apps/console -> the repo root
SEED_DIR = REPO / "data" / "seed-campaign"
EVAL_JSON = REPO / "eval" / "results" / "cashout.json"
# The eval names the world by its generator label, not by the directory it sits in.
WORLD = "seed_campaign"
RADAR_EVAL_DIR = REPO / "libs" / "radar" / "eval"
FIXTURE = ROOT / "fixtures" / "cashout.json"

SEED, CANDIDATE, ORDINARY = "seed", "candidate", "ordinary"
MULE, NOT_MULE = "mule", "not_mule"
MODES = (("replay", "replayed"), ("live", "live_clusters"))  # (mode, the daily run's key)
EVAL_ONLY_CONFIG = ("HORIZON_DAYS",)  # the evaluation's own constant; the rules never read it


# --- small pure pieces --------------------------------------------------------------------------------

def _shift(ts: str, **delta: float) -> str:
    return (datetime.fromisoformat(ts) + timedelta(**delta)).isoformat(timespec="seconds")


def day_of(as_of: str) -> str:
    """A daily run is named by its date: the run at 2026-10-23T00:00:00 is the day 2026-10-23."""
    return as_of[:10]


def share(received_bdt: float, cashed_out_bdt: float) -> float | None:
    """Cashed out over received in the lookback: the pass-through filter's ratio, None when nothing came in."""
    return cashed_out_bdt / received_bdt if received_bdt else None


def kind(acct: str, seeds: frozenset[str], named: frozenset[str]) -> str:
    """An account as of one run: a confirmed mule, a lead that run listed, or neither."""
    return SEED if acct in seeds else CANDIDATE if acct in named else ORDINARY


def outcome(labelled: str) -> str:
    """Eval-only, and the evaluation's own test: `mule` for a labelled non-victim ring member, whenever it is
    confirmed (inside the world or after its last day; `confirmed_at` and `lead_days` sit beside it), `not_mule` for
    a victim or an unlabelled account."""
    return MULE if labelled == MULE else NOT_MULE


# --- the rules, replayed ------------------------------------------------------------------------------

def _cashout_eval() -> Any:
    """cashout_eval.py, imported rather than shelled out; importing it puts the radar and the synth on the path."""
    if str(RADAR_EVAL_DIR) not in sys.path:
        sys.path.insert(0, str(RADAR_EVAL_DIR))
    import cashout_eval  # noqa: PLC0415 - lives outside this package, found only once the path is set

    return cashout_eval


@dataclass(frozen=True)
class Replay:
    runs: tuple[dict, ...]  # cashout_eval.daily_run, one per midnight
    events: tuple[Any, ...]  # every located cash-out (bhorosha_radar.cashout.CashOut), time-sorted
    tills: tuple[Any, ...]  # every till with a place (bhorosha_radar.cashout_rules.Till)
    config: dict[str, Any]  # the rules' constants as JSON values
    reuse_days: int


def replay(seed_dir: Path) -> Replay:
    ce = _cashout_eval()
    from bhorosha_radar import config  # noqa: PLC0415 - on the path once cashout_eval is imported
    from bhorosha_radar.cashout_rules import OUTPUT_CONSTANTS, read_tills  # noqa: PLC0415
    from bhorosha_radar.cashout_seeds import confirmed_mules_over_time, read_labels  # noqa: PLC0415

    bundle = ce.load_observable_bundle(seed_dir)
    events = ce.scan_cashouts(bundle).events
    if not events:
        raise BuildError(f"{seed_dir} holds no located cash-out; the rules have nothing to read")
    seeds_at = confirmed_mules_over_time(read_labels(seed_dir))
    runs = tuple(ce.daily_run(bundle, events, day, seeds_at) for day in ce.day_boundaries(events))
    constants = json.loads(json.dumps({name: getattr(config, name) for name in OUTPUT_CONSTANTS}))
    return Replay(runs=runs, events=events, tills=read_tills(bundle), config=constants,
                  reuse_days=config.TILL_REUSE_DAYS)


# --- projections --------------------------------------------------------------------------------------

def till_row(till: Any) -> dict[str, Any]:
    return {"id": till.till, "district": till.district, "lat": till.lat, "lon": till.lon, "opened": with_offset(till.since)}


def flag_row(flag: Mapping[str, Any]) -> dict[str, Any]:
    return {"id": flag["till"], "seed_accounts": list(flag["seed_accounts"]), "accounts": flag["accounts"],
            "expected": flag["expected"], "p_value": flag["p_value"], "first_seen_ts": with_offset(flag["first_seen_ts"]),
            "last_seed_ts": with_offset(flag["last_seed_ts"])}


def cashout_row(event: Any) -> dict[str, Any]:
    return {"txn_id": event.txn_id, "ts": with_offset(event.ts), "acct": event.acct, "till": event.till,
            "lat": event.lat, "lon": event.lon, "amount_bdt": event.amount_bdt}


def _clusters_listed(run: Mapping[str, Any]) -> list[tuple[str, Mapping[str, Any]]]:
    return [(mode, c) for mode, key in MODES for c in run[key]]


def day_row(run: Mapping[str, Any], events: Sequence[Any], filters: Sequence[str]) -> dict[str, Any]:
    as_of = run["as_of"]
    closing = sum(1 for e in events if _shift(as_of, days=-1) < e.ts <= as_of)
    return {
        "date": day_of(as_of), "as_of": with_offset(as_of), "seeds": len(run["seeds"]),
        "open_tills": len(run["open_tills"]), "cashouts": closing,
        "till_flags": [flag_row(f) for f in run["flag_rows"]],
        "clusters": sorted({c["cluster_id"] for _mode, c in _clusters_listed(run)}),
        "candidates": len(run["candidates"]),
        "not_flagged": {name: sum(n["filter"] == name for n in run["not_flagged"]) for name in filters},
    }


def day_events(run: Mapping[str, Any], events: Sequence[Any], reuse_days: int) -> list[dict[str, Any]]:
    """What one run's map draws: the day it closes, the seed cash-outs its flags rest on, its candidates' cash-outs."""
    as_of = run["as_of"]
    opened, oldest = _shift(as_of, days=-1), _shift(as_of, days=-reuse_days)
    resting = {(f["till"], acct) for f in run["flag_rows"] for acct in f["seed_accounts"]}
    leads = {(c["acct"], c["till"], c["ts"]) for c in run["candidates"]}
    chosen = [e for e in events if e.ts <= as_of and (
        e.ts > opened or ((e.till, e.acct) in resting and e.ts > oldest) or (e.acct, e.till, e.ts) in leads)]
    seeds, named = frozenset(run["seeds"]), frozenset(c["acct"] for c in run["candidates"])
    return [{**cashout_row(e), "kind": kind(e.acct, seeds, named)} for e in chosen]


def candidate_rows(runs: Sequence[Mapping[str, Any]], filters: Sequence[str], first_candidates: Callable) -> list[dict]:
    rows = []
    for name in filters:
        listed: dict[str, list[str]] = defaultdict(list)
        for run in runs:
            for acct in sorted({c["acct"] for c in run["candidates"] if c["filter"] == name}):
                listed[acct].append(day_of(run["as_of"]))
        for c in first_candidates(runs, name):
            rows.append({
                "acct": c["acct"], "till": c["till"], "ts": with_offset(c["ts"]), "amount_bdt": c["amount_bdt"],
                "filter": c["filter"], "source": c["source"], "first_time_senders": c["first_time_senders"],
                "new_counterparties": c["new_counterparties"], "received_bdt": c["received_bdt"],
                "cashed_out_bdt": c["cashed_out_bdt"], "pass_through_share": share(c["received_bdt"], c["cashed_out_bdt"]),
                "first_day": day_of(c["first_day"]), "days": listed[c["acct"]],
            })
    return sorted(rows, key=lambda r: (r["first_day"], r["ts"], r["acct"], r["filter"]))


def held_back(runs: Sequence[Mapping[str, Any]], candidates: Iterable[Mapping[str, Any]],
              filters: Sequence[str]) -> dict[str, dict[str, Any]]:
    """Per filter: accounts a run listed inside a flag or cluster but the filter held back on every day it saw them
    (the evaluation's `held_back`), by the reason given the last time they were listed."""
    named = {(c["acct"], c["filter"]) for c in candidates}
    out = {}
    for name in filters:
        last_reason = {n["acct"]: n["reason"] for run in runs for n in run["not_flagged"] if n["filter"] == name}
        held = Counter(reason for acct, reason in last_reason.items() if (acct, name) not in named)
        out[name] = {"accounts": sum(held.values()), "by_reason": dict(sorted(held.items()))}
    return out


def cluster_rows(runs: Sequence[Mapping[str, Any]], by_txn: Mapping[str, Any]) -> list[dict[str, Any]]:
    """Each distinct cluster once, as the run that first listed it froze it, with every day a run listed it."""
    first: dict[tuple[str, str], tuple[str, Mapping[str, Any]]] = {}
    days: dict[tuple[str, str], list[str]] = defaultdict(list)
    for run in runs:
        for mode, c in _clusters_listed(run):
            key = (mode, c["cluster_id"])
            first.setdefault(key, (run["as_of"], c))
            days[key].append(day_of(run["as_of"]))
    rows = []
    for (mode, cluster_id), (as_of, c) in first.items():
        seeded = set(c["seed_cashouts"])
        rows.append({
            "cluster_id": cluster_id, "mode": mode, "first_day": day_of(as_of), "days": days[mode, cluster_id],
            "opened_at": with_offset(c["opened_at"]), "centre_lat": c["centre_lat"], "centre_lon": c["centre_lon"],
            "radius_km": c["radius_km"], "window_start": with_offset(c["window_start"]),
            "window_end": with_offset(c["window_end"]), "tills": list(c["tills"]),
            "seed_cashouts": [cashout_row(by_txn[t]) for t in sorted(seeded, key=lambda t: (by_txn[t].ts, t))],
            "other_cashouts": [cashout_row(by_txn[t]) for t in c["all_cashouts"] if t not in seeded],
            "observed": c["observed"], "expected": c["expected"], "p_value": c["p_value"],
            "baseline_source": c["baseline_source"],
        })
    return sorted(rows, key=lambda r: (r["opened_at"], r["cluster_id"], r["mode"]))


# --- the evaluation block -----------------------------------------------------------------------------

def _seed_checksums(seed_dir: Path) -> dict[str, str]:
    return {path.name: sha256(path) for path in sorted(seed_dir.glob("*.jsonl"))}


def _seed_checksum(seed_dir: Path) -> str | None:
    checksum = seed_dir / "CHECKSUM"
    return checksum.read_text().strip() if checksum.exists() else None


def _read_report(path: Path) -> dict[str, Any] | None:
    """Missing or malformed is None, as build_campaigns treats campaign.json."""
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def _measures(summary: Mapping[str, Any]) -> dict[str, Any]:
    return {**summary, "first_day": with_offset(summary.get("first_day")), "last_day": with_offset(summary.get("last_day"))}


def _world(report: Mapping[str, Any], seed_dir: Path) -> Mapping[str, Any]:
    world = next((w for w in report.get("worlds", []) if w.get("world") == WORLD), None)
    if world is None or world.get("status") != "run":
        raise BuildError(f"{EVAL_JSON.name} holds no {seed_dir.name} run; rerun eval/cashout_eval.py")
    if world.get("seed_checksum") != _seed_checksum(seed_dir):
        raise BuildError(f"{EVAL_JSON.name} was generated from another {seed_dir.name}; rerun eval/cashout_eval.py")
    return world


def evaluation_block(report: dict[str, Any] | None, seed_dir: Path, rules: Replay,
                     candidates: Sequence[Mapping[str, Any]]) -> dict[str, Any] | None:
    if report is None:
        return None
    world = _world(report, seed_dir)
    evaluated = {k: v for k, v in report.get("config", {}).items() if k not in EVAL_ONLY_CONFIG}
    if evaluated != rules.config:
        raise BuildError(f"{EVAL_JSON.name} ran with another config than bhorosha_radar's; rerun eval/cashout_eval.py")
    ours = {(c["acct"], c["filter"], c["first_day"]) for c in candidates}
    theirs = {(r["acct"], r["filter"], day_of(r["first_day"])) for r in world.get("candidates", [])}
    if ours != theirs or world["summary"]["days_run"] != len(rules.runs):
        raise BuildError(f"{EVAL_JSON.name} scored other candidates or days than this run; rerun eval/cashout_eval.py")
    rows = [{"acct": r["acct"], "filter": r["filter"], "first_day": day_of(r["first_day"]),
             "outcome": outcome(r["labelled"]), "labelled": r["labelled"],
             "confirmed_at": with_offset(r["confirmed_at"]), "lead_days": r["lead_days"]}
            for r in world["candidates"]]
    return {
        "source": "eval/results/cashout.json", "generated_at": report.get("generated_at"),
        "world": world["world"], "seed_checksum": world["seed_checksum"], "config": report.get("config", {}),
        "caveat": report.get("caveat"), "measures": _measures(world["summary"]),
        "candidates": sorted(rows, key=lambda r: (r["first_day"], r["acct"], r["filter"])),
    }


# --- the whole fixture --------------------------------------------------------------------------------

def _source(seed_dir: Path, eval_path: Path) -> dict[str, Any]:
    return {
        "seed_dir": "data/seed-campaign", "seed_checksum": _seed_checksum(seed_dir),
        "input_checksums": {**_seed_checksums(seed_dir), "config.json": sha256(seed_dir / "config.json")},
        "eval_file": "eval/results/cashout.json",
        "eval_sha256": sha256(eval_path) if eval_path.exists() else None,
        "producer": "libs/radar: bhorosha_radar cash-out rules, run through eval/cashout_eval.py",
        "timezone": "Asia/Dhaka (+06:00)", "synthetic": True,
    }


def build(seed_dir: Path = SEED_DIR, eval_path: Path = EVAL_JSON) -> dict[str, Any]:
    """The fixture as plain JSON values (lists, not tuples), so it compares equal to the file."""
    ce = _cashout_eval()
    rules = replay(seed_dir)
    filters = ce.FILTERS
    by_txn = {e.txn_id: e for e in rules.events}
    days = [day_row(run, rules.events, filters) for run in rules.runs]
    candidates = candidate_rows(rules.runs, filters, ce.first_candidates)
    busy = {d["date"] for d in days if d["till_flags"] or d["clusters"]}
    payload = {
        "generated_at": datetime.now(UTC).isoformat(timespec="seconds"),
        "source": _source(seed_dir, eval_path),
        "config": rules.config,
        "tills": [till_row(t) for t in rules.tills],
        "days": days,
        "candidates": candidates,
        "not_flagged": held_back(rules.runs, candidates, filters),
        "clusters": cluster_rows(rules.runs, by_txn),
        "events": {day_of(run["as_of"]): day_events(run, rules.events, rules.reuse_days)
                   for run in rules.runs if day_of(run["as_of"]) in busy},
        "evaluation": evaluation_block(_read_report(eval_path), seed_dir, rules, candidates),
    }
    return json.loads(serialize(payload))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="compare against the committed fixture")
    parser.add_argument("--out", type=Path, default=FIXTURE)
    args = parser.parse_args(argv)

    started = time.perf_counter()
    try:
        payload = build()
    except BuildError as exc:
        print(f"FAIL {exc}", file=sys.stderr)
        return 2
    took = time.perf_counter() - started

    if args.check:
        if not args.out.exists():
            print(f"FAIL {args.out} does not exist", file=sys.stderr)
            return 1
        if comparable(json.loads(args.out.read_text(encoding="utf-8"))) != comparable(payload):
            print(f"FAIL {args.out} is stale; run tools/build_cashout.py", file=sys.stderr)
            return 1
        print(f"ok   {args.out.name} is current ({took:.1f}s to recompute)")
        return 0

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(serialize(payload), encoding="utf-8")
    flagged = [d["date"] for d in payload["days"] if d["till_flags"]]
    print(f"wrote {args.out.relative_to(ROOT)}  ({args.out.stat().st_size / 1024:.0f} KB, {took:.1f}s)")
    print(f"  {len(payload['days'])} days, {len(flagged)} with a till flag, {len(payload['clusters'])} clusters, "
          f"{len(payload['candidates'])} candidates, {sum(map(len, payload['events'].values()))} events "
          f"on {len(payload['events'])} days")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
