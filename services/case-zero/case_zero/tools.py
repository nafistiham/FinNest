"""The tools the investigator may call.

`as_of` is injected by the ledger from the investigation, never chosen by the model, so the
agent cannot look past the moment it is investigating. Labels and personas never appear.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import urllib.error
import urllib.parse
import urllib.request

from bhorosha_graph import tools as gt

from case_zero import patterns
from case_zero.policy import band_for
from case_zero.world import World, alias_id, real_id

ENTITY_RE = re.compile(r"^(device|sim|nid|phone):(.+)$")
RAW_ENTITY_RE = re.compile(r"^(dev|sim|nid|ph)_[A-Za-z0-9_]+$")


def _opaque(kind: str, raw: str) -> str:
    return f"{kind}:{hashlib.sha1(raw.encode()).hexdigest()[:12]}"


def to_model(node):
    """Outputs the model may see: persona ids aliased, identity ids hashed (the names embed ring ids)."""
    if isinstance(node, dict):
        return {k: to_model(v) for k, v in node.items() if k not in ("ring_id", "role", "owner_segment")}
    if isinstance(node, list | tuple):
        return [to_model(v) for v in node]
    if isinstance(node, str):
        if m := ENTITY_RE.match(node):
            return _opaque(m[1], m[2])
        if RAW_ENTITY_RE.match(node):
            return _opaque("device" if node.startswith("dev_") else node.split("_", 1)[0], node)
        return alias_id(node)
    return node


def from_model(node):
    if isinstance(node, dict):
        return {k: from_model(v) for k, v in node.items()}
    if isinstance(node, list | tuple):
        return [from_model(v) for v in node]
    return real_id(node) if isinstance(node, str) else node

NEIGHBOUR_LIMIT = 25


def _obj(properties: dict, required: list[str]) -> dict:
    return {"type": "object", "properties": properties, "required": required}


_ACCT = {"type": "string", "description": "Account id, e.g. acct_01070 or acct_till_AG-0192"}

TOOL_SPECS: list[dict] = [
    {"name": "get_account", "description": "Account profile: kind (customer, agent_till, merchant, payroll), district, opened_at, status, onboarding agent.", "parameters": _obj({"acct_id": _ACCT}, ["acct_id"])},
    {"name": "score", "description": "The mule model's probability for an account at the investigation time, with its top 10 reasons. Authoritative: never restate it differently.", "parameters": _obj({"acct_id": _ACCT}, ["acct_id"])},
    {"name": "score_neighbours", "description": "The mule model's score for every account within `hops` money transfers (1-3) or sharing a device/SIM/NID/phone with this account, at the investigation time. Returns those at or above min_score, highest first. One call instead of scoring accounts one by one.", "parameters": _obj({"acct_id": _ACCT, "hops": {"type": "integer", "description": "1 to 3, default 2"}, "min_score": {"type": "number", "description": "0.2 to 0.95, default 0.5"}}, ["acct_id"])},
    {"name": "neighbours", "description": "Money-flow counterparties within 1 or 2 transfers, in either direction. Each row is one transfer between the counterparty and `via` (the account it was reached from): the earliest one out of `via` if there is any, otherwise the earliest one into it. The row gives its txn_id, from_acct (sender), to_acct (receiver), amount_bdt, txn_type and first_ts (that transfer's time).", "parameters": _obj({"acct_id": _ACCT, "hops": {"type": "integer", "description": "1 or 2"}}, ["acct_id"])},
    {"name": "path_between", "description": "Shortest time-ordered money path from source to target, with each transaction.", "parameters": _obj({"source": _ACCT, "target": _ACCT, "max_hops": {"type": "integer", "description": "1 to 5"}}, ["source", "target"])},
    {"name": "shared_entities", "description": "Devices, SIMs, NIDs, phones or onboarding agents shared by two or more of the accounts.", "parameters": _obj({"acct_ids": {"type": "array", "items": _ACCT, "description": "2 to 10 account ids"}}, ["acct_ids"])},
    {"name": "velocity_stats", "description": "Inbound and outbound counts and totals in the last window_hours, distinct counterparties and pass-through ratio.", "parameters": _obj({"acct_id": _ACCT, "window_hours": {"type": "integer", "description": "1 to 720, default 24"}}, ["acct_id"])},
    {"name": "agent_till_stats", "description": "Cash-in and cash-out activity at an agent's till, with repeat counterparties.", "parameters": _obj({"agent_id": {"type": "string", "description": "Agent id, e.g. AG-0192"}}, ["agent_id"])},
    {"name": "kyc_dupe_check", "description": "Other accounts sharing this account's NID, phone, device or SIM.", "parameters": _obj({"acct_id": _ACCT}, ["acct_id"])},
    {"name": "known_fraud_proximity", "description": "Hops to accounts analysts had already confirmed as fraud (3-day confirmation lag) before the investigation time.", "parameters": _obj({"acct_id": _ACCT, "max_hops": {"type": "integer", "description": "1 to 3, default 2"}}, ["acct_id"])},
    {"name": "dormant_cohort", "description": "If this account woke from dormancy (14+ days with no outgoing money, then 2+ inbound transfers passed straight out), the other customer accounts that woke the same way within 12 hours. Bought accounts are often switched on together; they need not share money or devices.", "parameters": _obj({"acct_id": _ACCT}, ["acct_id"])},
    {"name": "device_safety", "description": "The App Safety Check's standing verdict for the customer's phone (from risk-mw): known, verdict SAFE/CAUTION/BLOCK, risk_score, flagged_packages (apps that can read or control the screen, remote-access tools, fake loan apps), attestation (tampered = a modified banking app), source (server = the bank ran the check itself; phone = reported by the customer's phone with a payment, the bank did not re-run it) and facts (what was found, as codes: REMOTE_CONTROL, SCREEN_CAPTURE, READS_MESSAGES, MODIFIED_APP, FAKE_APP, FAKE_LOAN_APP, UNSAFE_PHONE). Describes the phone NOW, not at the investigation time or any transfer. A BLOCK or 'tampered' from the bank's check on a victim supports a takeover, on a mule a controlled device; a CAUTION, or any verdict with source phone, is only what was reported or found, never proof of a compromise.", "parameters": _obj({"acct_id": _ACCT}, ["acct_id"])},
    {"name": "common_point_of_compromise", "description": "Counterparties (e.g. a merchant) that most of this account's recent senders had paid, far more often than chance, and other accounts that payers of that point recently sent money to and that cashed it straight out. Finds sibling mules fed by the same leaked customer list.", "parameters": _obj({"acct_id": _ACCT}, ["acct_id"])},
]


KNOWN_TOOLS = frozenset(t["name"] for t in TOOL_SPECS)   # what the model may call; seed_brief is code's tc_00 only
SEED_BRIEF = "seed_brief"

# risk-mw, where the App Safety Check keeps the phone's standing verdict per uid. Empty = the tool answers
# known=false with a note, so an investigation never depends on the other service being up.
RISK_MW_URL = os.environ.get("CASE_ZERO_RISK_MW_URL", "").rstrip("/")
RISK_MW_TIMEOUT_S = 2.0
DEVICE_SAFETY_FIELDS = ("known", "verdict", "risk_score", "flagged_packages", "attestation", "source", "facts")  # no timestamps: the ledger records only world-format times, and a cited one would read as an unknown date


def _device_safety(acct_id: str, base_url: str = "") -> dict:
    """GET {risk-mw}/v1/appsafety/latest/{uid}. The app sends its checks under the persona's account id, so the uid
    is the account id. Any failure is a known=false answer with the reason; the tool never raises into the loop."""
    base = base_url or RISK_MW_URL
    if not base:
        return {"acct_id": acct_id, "known": False, "note": "risk-mw not configured (CASE_ZERO_RISK_MW_URL)"}
    # include_phone (2026-10-18): without it risk-mw answers from its own checks only, and a BLOCK the customer's
    # phone reported with a payment read as known=false. risk-mw finds the persona by account id as well as by uid.
    url = f"{base}/v1/appsafety/latest/{urllib.parse.quote(acct_id, safe='')}?include_phone=true"
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers={"X-Demo-User": "case-zero"}), timeout=RISK_MW_TIMEOUT_S) as resp:  # noqa: S310 - our own service
            payload = json.loads(resp.read())
        if not isinstance(payload, dict):
            raise ValueError("risk-mw answered with something other than a JSON object")
    except urllib.error.HTTPError as exc:
        return {"acct_id": acct_id, "known": False, "note": f"risk-mw answered HTTP {exc.code}"}
    except (urllib.error.URLError, TimeoutError, OSError, ValueError) as exc:
        return {"acct_id": acct_id, "known": False, "note": f"risk-mw unreachable: {exc.__class__.__name__}"}
    out = {"acct_id": acct_id, **{k: payload.get(k) for k in DEVICE_SAFETY_FIELDS if k in payload}}
    if not out.get("known"):
        out["note"] = "no App Safety Check on record for this account in the last 24 h"
    return out


def _clamp(value: int, low: int, high: int) -> int:
    return max(low, min(high, int(value)))


def _get_account(world: World, as_of: str, acct_id: str) -> dict:
    a = world.account(acct_id)
    if a is None:
        return {"acct_id": acct_id, "found": False}
    keep = ("acct_id", "kind", "district", "opened_at", "status", "onboarding_agent_id")
    return {"found": True, **{k: a.get(k) for k in keep if k in a}}


CANDIDATE_LIMIT = 20
IDENTITY_PREFIXES = ("device:", "sim:", "nid:", "phone:")


def _score_neighbours(world: World, as_of: str, acct_id: str, hops: int = 2, min_score: float = 0.5, limit: int = CANDIDATE_LIMIT) -> dict:
    hops, min_score = _clamp(hops, 1, 3), max(0.2, min(0.95, float(min_score)))
    found: dict[str, tuple[int, str]] = {}
    for row in gt.neighbours(world.bundle, real_id(acct_id), hops, as_of, 1_000_000)["neighbours"]:
        found.setdefault(alias_id(row["acct_id"]), (row["hops"], "money"))
    for entity in world.entity_links(acct_id, as_of):
        if entity.startswith(IDENTITY_PREFIXES):
            for other in world.entity_holders(entity, as_of):
                found.setdefault(other, (1, "identity"))
    found.pop(alias_id(acct_id), None)
    probs = world.bulk_probability(list(found), as_of)
    rows = [{"acct_id": a, "probability": p, "hops": found[a][0], "via": found[a][1], "kind": (world.account(a) or {}).get("kind")} for a, p in probs.items() if p >= min_score]
    rows.sort(key=lambda r: (-r["probability"], r["hops"], r["acct_id"]))
    return {"acct_id": acct_id, "as_of": as_of, "min_score": min_score, "checked": len(found), "candidates": rows[:limit], "truncated": len(rows) > limit}


def _pattern_leads(world: World, as_of: str, acct_id: str) -> dict:
    """Accounts the pattern tools tie to the seed without money or devices; empty when there are none."""
    leads = {}
    cohort = patterns.dormant_cohort(world, as_of, acct_id)
    if cohort["cohort"]:
        leads["seed_wake"], leads["dormant_cohort"] = cohort["seed_wake"], cohort["cohort"]
    cpc = patterns.common_point_of_compromise(world, as_of, acct_id)
    if cpc["linked_accounts"]:
        leads["common_points"], leads["common_point_linked"] = cpc["common_points"], cpc["linked_accounts"]
    return leads


def _score(world: World, as_of: str, acct_id: str) -> dict:
    out = world.score_at(acct_id, as_of)
    return {**out, "band": band_for(out["probability"])}


def _seed_brief(world: World, as_of: str, acct_id: str) -> dict:
    """tc_00: the seed's own score and band, the model's high-scoring accounts around it, and any pattern leads."""
    return {**_score(world, as_of, acct_id), "model_candidates": _score_neighbours(world, as_of, acct_id, hops=2, min_score=0.5, limit=10)["candidates"],
            "pattern_leads": _pattern_leads(world, as_of, real_id(acct_id))}


def _shared_entities(world: World, as_of: str, acct_ids: list[str]) -> dict:
    holders: dict[str, set[str]] = {}
    for acct in acct_ids:
        for entity in world.entity_links(acct, as_of):
            holders.setdefault(entity, set()).add(alias_id(acct))
    shared = [{"kind": e.split(":", 1)[0], "entity": e, "acct_ids": sorted(a)} for e, a in holders.items() if len(a) >= 2]
    return {"acct_ids": list(acct_ids), "shared": sorted(shared, key=lambda e: (-len(e["acct_ids"]), e["entity"]))}


def _kyc_dupe_check(world: World, as_of: str, acct_id: str) -> dict:
    def shared(kind: str) -> list[str]:
        return sorted({o for e in world.entity_links(acct_id, as_of) if e.startswith(f"{kind}:") for o in world.entity_holders(e, as_of)} - {alias_id(acct_id)})
    return {"acct_id": acct_id, "nid_shared_with": shared("nid"), "phone_shared_with": shared("phone"), "device_shared_with": shared("device"), "sim_shared_with": shared("sim")}


def run_tool(world: World, name: str, as_of: str, args: dict) -> dict:
    """Run one tool. Raises KeyError for an unknown tool and TypeError for bad arguments."""
    return to_model(_dispatch(world, name, as_of, from_model(args)))


def _dispatch(world: World, name: str, as_of: str, args: dict) -> dict:
    b = world.bundle
    handlers = {
        "get_account": lambda acct_id: _get_account(world, as_of, acct_id),
        "score": lambda acct_id: _score(world, as_of, acct_id),
        "score_neighbours": lambda acct_id, hops=2, min_score=0.5: _score_neighbours(world, as_of, acct_id, hops, min_score),
        SEED_BRIEF: lambda acct_id: _seed_brief(world, as_of, acct_id),
        "neighbours": lambda acct_id, hops=1: gt.neighbours(b, acct_id, _clamp(hops, 1, 2), as_of, NEIGHBOUR_LIMIT),
        "path_between": lambda source, target, max_hops=5: gt.path_between(b, source, target, _clamp(max_hops, 1, 5), as_of),
        "shared_entities": lambda acct_ids: _shared_entities(world, as_of, list(acct_ids)[:10]),
        "velocity_stats": lambda acct_id, window_hours=24: gt.velocity_stats(b, acct_id, _clamp(window_hours, 1, 720), as_of),
        "agent_till_stats": lambda agent_id: gt.agent_till_stats(b, agent_id, as_of),
        "kyc_dupe_check": lambda acct_id: _kyc_dupe_check(world, as_of, acct_id),
        "known_fraud_proximity": lambda acct_id, max_hops=2: world.known_fraud_proximity(acct_id, as_of, _clamp(max_hops, 1, 3)),
        "dormant_cohort": lambda acct_id: patterns.dormant_cohort(world, as_of, acct_id),
        "common_point_of_compromise": lambda acct_id: patterns.common_point_of_compromise(world, as_of, acct_id),
        "device_safety": lambda acct_id: _device_safety(acct_id),
    }
    return handlers[name](**args)
