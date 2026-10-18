"""Write fixtures/campaigns.json from the campaign world.

The Incidents view's data, built the way build_overview.py builds the overview: the radar runs here,
once, over data/seed-campaign, and the console and its two API routes read the committed result.
Nothing at request time runs the radar, reads Firestore or calls Gemini.

    python3 tools/build_campaigns.py            # write fixtures/campaigns.json
    python3 tools/build_campaigns.py --check    # fail if the committed file is stale

What it reads:

* Stages 0 to 2 of the radar (libs/radar), through the functions radar_eval.py itself
  runs: load_observable_bundle, read_seed, enrich, _world_window, _detect. The detector never sees a
  label, a ring_id or a truth_ column; radar_eval strips them before it hands the tables over.
* eval/results/campaign.json (written by libs/radar/eval/radar_eval.py) for the `evaluation` block: measures, caveat, config,
  money at the flag per matched campaign, incident class counts and the payee note. The build fails
  when that file was generated from other inputs than the seed read here, so the evaluation can
  never describe a different run from the incidents printed beside it.
* The per-incident class is radar_eval's incident_class over the truth ring attempts, the same call
  that writes radar_incidents.jsonl. It is eval-only and lives under `evaluation`, never on an
  incident or an attempt.

Adapter rules:

* Every timestamp the radar writes is naive Asia/Dhaka; it leaves here with +06:00 appended, so the
  browser never reads it as host-local time.
* Firings keep their counts, not their attempt id lists; the incident holds the union.
* A campaign snapshot whose attempts a later snapshot contains in full is marked `superseded_by`.
  The radar keeps one snapshot per campaign id, and an id is the hash of the component's earliest
  attempt, so a component that later grows backwards in time leaves its earlier snapshot behind.
* payee_links stay as the producer writes them ({payee, entity, kind}) and are also grouped into
  `shared_entities`: an entity two or more of the campaign's payees share as of the campaign, with
  whether an evidence triple names it.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import time
from collections import Counter, defaultdict
from collections.abc import Iterable, Sequence
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parents[1]                      # apps/console -> the repo root
SEED_DIR = REPO / "data" / "seed-campaign"
EVAL_JSON = REPO / "eval" / "results" / "campaign.json"
RADAR_EVAL_DIR = REPO / "libs" / "radar" / "eval"
FIXTURE = ROOT / "fixtures" / "campaigns.json"

# generated_at is the one field that legitimately differs between two runs over the same inputs.
VOLATILE = ("generated_at",)
DHAKA_OFFSET = "+06:00"
_HAS_OFFSET = re.compile(r"(Z|[+-]\d\d:\d\d)$")

ATTEMPT_FIELDS = (
    "attempt_id", "ts", "sender", "payee", "amount_bdt", "decision", "sender_district", "payee_district",
    "payee_onboarding_agent", "payee_devices", "payee_sim_day", "payee_till", "payee_next_hops",
)
FIRING_FIELDS = (
    "run_ts", "key", "cell", "window_min", "k", "mu", "p", "surprise", "reason", "baseline_source", "payday_factor",
)
EVAL_CAMPAIGN_FIELDS = (
    "campaign_id", "detected_campaign_id", "flag_ts", "tenth_ts", "time_to_flag_min", "allowed_by_flag",
    "cashed_out_by_flag", "retained_by_flag", "retained_fraction", "future_allowed_after_flag", "precision",
    "recall", "victim_coverage", "payees_found", "payees_named", "payees_total", "payee_overreach",
)
EVAL_CAMPAIGN_TIMES = ("flag_ts", "tenth_ts")
MEASURE_FIELDS = ("value", "target", "status", "evaluated", "outside_stream", "reason")
# payee_links name an entity by kind; evidence triples name the same entity with the receiving key.
LINK_KIND_TO_KEY = {"onboarding_agent": "payee_onboarding_agent", "device": "payee_device", "sim_day": "payee_sim_day"}
ENTITY_ORDER = ("payee_onboarding_agent", "payee_till", "payee_sim_day", "payee_device", "payee")


class BuildError(RuntimeError):
    """An input the fixture cannot honestly be built from."""


# --- small pure pieces --------------------------------------------------------------------------------

def with_offset(ts: str | None) -> str | None:
    """A naive radar timestamp is Asia/Dhaka; say so. One with an offset already is left alone."""
    if ts is None:
        return None
    return ts if _HAS_OFFSET.search(ts) else ts + DHAKA_OFFSET


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def serialize(payload: dict[str, Any]) -> str:
    """Sorted keys, fixed indent, no NaN: two builds of the same inputs are the same bytes."""
    return json.dumps(payload, indent=1, ensure_ascii=False, sort_keys=True, allow_nan=False) + "\n"


def comparable(payload: dict[str, Any]) -> dict[str, Any]:
    return {k: v for k, v in payload.items() if k not in VOLATILE}


def superseded_by(campaign: Any, campaigns: Sequence[Any]) -> str | None:
    """The latest snapshot that holds every attempt of this one and more (or the same, later)."""
    own = set(campaign.attempt_ids)
    later = [
        other for other in campaigns
        if other.campaign_id != campaign.campaign_id and own <= set(other.attempt_ids)
        and (own < set(other.attempt_ids) or other.as_of > campaign.as_of)
    ]
    if not later:
        return None
    return max(later, key=lambda c: (c.as_of, len(c.attempt_ids), c.campaign_id)).campaign_id


def shared_entities(campaign: Any) -> list[dict[str, Any]]:
    """payee_links grouped by entity: the ones two or more of the campaign's payees share."""
    named = {entity for _source, _target, entity in campaign.evidence}
    payees: dict[tuple[str, str], set[str]] = defaultdict(set)
    for link in campaign.payee_links:
        kind = LINK_KIND_TO_KEY.get(link["kind"], link["kind"])
        value = link["entity"].split(":", 1)[1]
        payees[kind, f"{kind}:{value}"].add(link["payee"])
    rows = [
        {"entity": entity, "kind": kind, "payees": sorted(members), "in_evidence": entity in named}
        for (kind, entity), members in payees.items() if len(members) >= 2
    ]
    order = {kind: index for index, kind in enumerate(ENTITY_ORDER)}
    return sorted(rows, key=lambda r: (order.get(r["kind"], len(order)), r["entity"]))


# --- the radar run ------------------------------------------------------------------------------------

def _radar() -> Any:
    """radar_eval.py, imported rather than shelled out: the same functions, in this process."""
    if str(RADAR_EVAL_DIR) not in sys.path:
        sys.path.insert(0, str(RADAR_EVAL_DIR))
    import radar_eval  # noqa: PLC0415 - lives outside this package, found only once the path is set

    return radar_eval


def detect(seed_dir: Path) -> Any:
    radar = _radar()
    bundle = radar.load_observable_bundle(seed_dir)
    attempts = radar.enrich(radar.read_seed(seed_dir), bundle)
    if not attempts:
        raise BuildError(f"{seed_dir} holds no attempts.jsonl; the radar has nothing to read")
    start, end = radar._world_window(seed_dir, attempts)
    return radar._detect(attempts, bundle, start, end)


# --- projections --------------------------------------------------------------------------------------

def incident_row(incident: Any) -> dict[str, Any]:
    return {
        "incident_id": incident.incident_id, "key": incident.key, "cell": incident.cell,
        "window_min": incident.window_min, "opened_at": with_offset(incident.opened_at),
        "last_fired_at": with_offset(incident.last_fired_at), "observed": incident.observed,
        "expected": incident.expected, "p_value": incident.p_value, "surprise": incident.surprise,
        "reason": incident.reason, "firing_runs": [with_offset(run) for run in incident.firing_runs],
        "baseline_source": incident.baseline_source, "payday_factor": incident.payday_factor,
        "attempt_ids": list(incident.attempt_ids), "held": incident.held, "allowed": incident.allowed,
    }


def firing_rows(firings: Iterable[Any], incidents: Iterable[Any]) -> list[dict[str, Any]]:
    """The firings that make up an incident: same key and cell, at one of its runs."""
    wanted = {(i.key, i.cell, run) for i in incidents for run in i.firing_runs}
    rows = [
        {**{name: getattr(f, name) for name in FIRING_FIELDS}, "run_ts": with_offset(f.run_ts),
         "attempts": len(f.attempt_ids), "held": len(f.held_ids), "allowed": len(f.allowed_ids)}
        for f in firings if (f.key, f.cell, f.run_ts) in wanted
    ]
    return sorted(rows, key=lambda r: (r["run_ts"], r["key"], r["cell"], r["window_min"]))


def campaign_row(campaign: Any, campaigns: Sequence[Any]) -> dict[str, Any]:
    return {
        "campaign_id": campaign.campaign_id, "opened_at": with_offset(campaign.opened_at),
        "as_of": with_offset(campaign.as_of), "attempt_ids": list(campaign.attempt_ids),
        "senders": list(campaign.senders), "payees": list(campaign.payees), "tills": list(campaign.tills),
        "incident_ids": list(campaign.incident_ids), "held": campaign.held, "allowed": campaign.allowed,
        "allowed_bdt": campaign.allowed_bdt, "synchrony": campaign.synchrony,
        "concentration": campaign.concentration, "rank_score": campaign.rank_score,
        "evidence": [list(triple) for triple in campaign.evidence],
        "payee_links": [{"payee": link["payee"], "entity": link["entity"], "kind": link["kind"]} for link in campaign.payee_links],
        "shared_entities": shared_entities(campaign),
        "superseded_by": superseded_by(campaign, campaigns),
    }


def attempt_row(attempt: Any) -> dict[str, Any]:
    """Observable fields only. The projection is an allowlist, so a label cannot ride along."""
    row = {name: getattr(attempt, name) for name in ATTEMPT_FIELDS}
    return {**row, "ts": with_offset(attempt.ts), "payee_devices": list(attempt.payee_devices),
            "payee_next_hops": list(attempt.payee_next_hops)}


# --- the evaluation block -----------------------------------------------------------------------------

def _seed_checksums(seed_dir: Path) -> dict[str, str]:
    """The same set radar_eval records as input_checksums: every JSONL table in the seed."""
    return {path.name: sha256(path) for path in sorted(seed_dir.glob("*.jsonl"))}


def _read_report(path: Path) -> dict[str, Any] | None:
    """Missing or malformed is None, as aggregate._read_eval treats a model card's eval file."""
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def _measures(measures: dict[str, Any]) -> dict[str, Any]:
    return {name: {k: m[k] for k in MEASURE_FIELDS if k in m} for name, m in sorted(measures.items())}


def _eval_campaign(row: dict[str, Any]) -> dict[str, Any]:
    out = {name: row.get(name) for name in EVAL_CAMPAIGN_FIELDS}
    return {**out, **{name: with_offset(row.get(name)) for name in EVAL_CAMPAIGN_TIMES}}


def _incident_classes(seed_dir: Path, incidents: Sequence[Any]) -> list[dict[str, str]]:
    radar = _radar()
    _truths, _bursts, ring_attempts, _issues = radar.load_truth(seed_dir)
    return [{"incident_id": i.incident_id, "incident_class": radar.incident_class(i, ring_attempts)} for i in incidents]


def evaluation_block(report: dict[str, Any] | None, seed_dir: Path, detection: Any) -> dict[str, Any] | None:
    if report is None:
        return None
    if report.get("input_checksums") != _seed_checksums(seed_dir):
        raise BuildError(f"{EVAL_JSON.name} was generated from other inputs than {seed_dir.name}; rerun radar_eval.py")
    campaign_ids = {c.campaign_id for c in detection.campaigns}
    rows = [_eval_campaign(row) for row in report.get("campaigns", [])]
    unknown = [r["detected_campaign_id"] for r in rows if r["detected_campaign_id"] and r["detected_campaign_id"] not in campaign_ids]
    if unknown:
        raise BuildError(f"{EVAL_JSON.name} names campaigns this radar run did not produce: {unknown}")
    classes = _incident_classes(seed_dir, detection.incidents)
    counts = dict(Counter(row["incident_class"] for row in classes))
    if counts != report.get("incident_classes", {}):
        raise BuildError(f"incident classes {counts} disagree with {EVAL_JSON.name} {report.get('incident_classes')}")
    return {
        "source": "eval/results/campaign.json", "generated_at": report.get("generated_at"),
        "seed_checksum": report.get("seed_checksum"), "config": report.get("config", {}),
        "measures": _measures(report.get("measures", {})), "caveat": report.get("caveat"),
        "payee_note": report.get("payee_note"), "incident_classes": counts, "incidents": classes, "campaigns": rows,
    }


# --- the whole fixture --------------------------------------------------------------------------------

def _source(seed_dir: Path, eval_path: Path) -> dict[str, Any]:
    checksum = seed_dir / "CHECKSUM"
    inputs = {**_seed_checksums(seed_dir), "config.json": sha256(seed_dir / "config.json")}
    return {
        "seed_dir": "data/seed-campaign", "seed_checksum": checksum.read_text().strip() if checksum.exists() else None,
        "input_checksums": inputs, "eval_file": "eval/results/campaign.json",
        "eval_sha256": sha256(eval_path) if eval_path.exists() else None,
        "producer": "libs/radar: bhorosha_radar stages 0-2, run through eval/radar_eval.py",
        "timezone": "Asia/Dhaka (+06:00)", "synthetic": True,
    }


def build(seed_dir: Path = SEED_DIR, eval_path: Path = EVAL_JSON) -> dict[str, Any]:
    """The fixture as plain JSON values (lists, not tuples), so it compares equal to the file."""
    detection = detect(seed_dir)
    campaigns = detection.campaigns
    held_ids = {aid for i in detection.incidents for aid in i.attempt_ids}
    held_ids |= {aid for c in campaigns for aid in c.attempt_ids}
    attempts = sorted((detection.by_id[aid] for aid in held_ids), key=lambda a: (a.ts, a.attempt_id))
    payload = {
        "generated_at": datetime.now(UTC).isoformat(timespec="seconds"),
        "source": _source(seed_dir, eval_path),
        "incidents": [incident_row(i) for i in detection.incidents],
        "firings": firing_rows(detection.firings, detection.incidents),
        "campaigns": [campaign_row(c, campaigns) for c in sorted(campaigns, key=lambda c: (-c.rank_score, c.campaign_id))],
        "attempts": [attempt_row(a) for a in attempts],
        "evaluation": evaluation_block(_read_report(eval_path), seed_dir, detection),
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
            print(f"FAIL {args.out} is stale; run tools/build_campaigns.py", file=sys.stderr)
            return 1
        print(f"ok   {args.out.name} is current ({took:.1f}s to recompute)")
        return 0

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(serialize(payload), encoding="utf-8")
    evaluation = payload["evaluation"] or {}
    matched = [row["detected_campaign_id"] for row in evaluation.get("campaigns", []) if row["detected_campaign_id"]]
    print(f"wrote {args.out.relative_to(ROOT)}  ({args.out.stat().st_size / 1024:.0f} KB, {took:.1f}s)")
    print(f"  {len(payload['incidents'])} incidents, {len(payload['firings'])} firings, "
          f"{len(payload['campaigns'])} campaign snapshots, {len(payload['attempts'])} attempts")
    print(f"  evaluated campaigns: {', '.join(matched) or 'none'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
