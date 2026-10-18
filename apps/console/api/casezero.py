"""Case Zero, read server-side.

Why a proxy, when this console calls risk-mw straight from the browser: Case Zero sends no CORS
headers, so a browser fetch to it is blocked. Fetching it here is the only way to show what it
knows.

What this deliberately does not do is re-declare Case Zero's shapes. That contract belongs to the
Case Zero service and it is still moving; a strict model of another service's evolving response
would break this console every time it ships. These routes pass the JSON through and type only the one thing we compute
ourselves - the watch-list gap in §G4.

Everything is cached briefly: the watch-list changes when an investigation finishes, not between
two clicks, and a console that re-fetches another team's service on every render is a bad neighbour.
"""

from __future__ import annotations

import json
import logging
import os
import time
import urllib.error
import urllib.request
from typing import Any

log = logging.getLogger("casezero")

# The Case Zero service's base URL, e.g. http://localhost:8080 or its Cloud Run URL. Unset means
# the Case Zero panels say the service is not configured instead of calling anything.
BASE = os.environ.get("CASE_ZERO_URL", "").rstrip("/")
TIMEOUT_S = 12
CACHE_TTL_S = 60

_cache: dict[str, tuple[float, Any]] = {}


class CaseZeroUnavailable(RuntimeError):
    """Case Zero did not answer. The console degrades to a message, never to a blank panel."""


class CaseNotFound(CaseZeroUnavailable):
    """Case Zero answered 404: it keeps cases in memory, so a redeploy (or 200 newer cases) drops them."""


def _require_base() -> None:
    if not BASE:
        raise CaseZeroUnavailable("CASE_ZERO_URL is not set")


def _get(path: str, ttl: float = CACHE_TTL_S) -> Any:
    hit = _cache.get(path)
    if hit and time.time() - hit[0] < ttl:
        return hit[1]
    _require_base()
    request = urllib.request.Request(f"{BASE}{path}", headers={"Accept": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT_S) as response:
            payload = json.loads(response.read())
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            raise CaseNotFound(path) from exc
        log.warning("case-zero %s failed: %s", path, exc)
        if hit:
            return hit[1]
        raise CaseZeroUnavailable(str(exc)) from exc
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError) as exc:
        log.warning("case-zero %s failed: %s", path, exc)
        if hit:
            return hit[1]  # stale is better than empty when the neighbour is down
        raise CaseZeroUnavailable(str(exc)) from exc
    _cache[path] = (time.time(), payload)
    return payload


def health() -> dict[str, Any]:
    return _get("/health", ttl=30)


def seeds() -> list[dict[str, Any]]:
    return _get("/api/seeds", ttl=600)


def payee_risk() -> dict[str, Any]:
    """The watch-list: accounts an investigation has implicated, with the facts behind each."""
    return _get("/api/payee-risk")


def case(case_id: str) -> dict[str, Any]:
    return _get(f"/api/cases/{case_id}", ttl=300)


def events(case_id: str) -> list[dict[str, Any]]:
    """The run's events (tool calls and their results), for naming the tool behind each cited call."""
    return (_get(f"/api/investigations/{case_id}?since=0", ttl=300) or {}).get("events") or []


# --- the case file ----------------------------------------------------------------------------------------------------
# Labels for Case Zero's codes, in the console's two languages. The red-flag meanings are Case Zero's own
# (case_zero/prompts.py RED_FLAGS); the Bangla is a non-native draft (NATIVE CHECK).

RED_FLAG_MEANING: dict[str, tuple[str, str]] = {
    "RF01": ("Rapid pass-through: money leaves within minutes of arriving", "দ্রুত পার করা: টাকা আসার কয়েক মিনিটের মধ্যে বেরিয়ে যায়"),
    "RF02": ("Fan-out: one account splits money to several accounts", "ছড়িয়ে দেওয়া: এক অ্যাকাউন্টের টাকা কয়েকটা অ্যাকাউন্টে ভাগ হয়"),
    "RF03": ("Cash-out at an agent till shortly after receipt", "টাকা আসার পরপরই এজেন্টের কাছে ক্যাশ আউট"),
    "RF04": ("Takeover signal upstream: SIM swap or new device before the transfer",
             "অ্যাকাউন্ট দখলের লক্ষণ: টাকা পাঠানোর আগে সিম বা ফোন বদল"),
    "RF05": ("Dormant account suddenly active", "অনেকদিন অচল অ্যাকাউন্ট হঠাৎ সচল"),
    "RF06": ("Device, SIM, NID or phone shared between accounts", "একই ফোন, সিম, এনআইডি বা নম্বর একাধিক অ্যাকাউন্টে"),
    "RF07": ("Accounts onboarded together by the same agent", "একই এজেন্টের হাতে একসাথে খোলা অ্যাকাউন্ট"),
    "RF08": ("Close to fraud already confirmed by analysts", "অ্যানালিস্টদের আগে নিশ্চিত করা প্রতারণার কাছাকাছি"),
    "RF09": ("Round-tripping or repeat counterparties at an agent till", "এজেন্টের কাছে একই লোকদের সাথে বারবার টাকা ঘোরানো"),
    "RF10": ("KYC duplicate: NID or phone reused", "কেওয়াইসি ডুপ্লিকেট: একই এনআইডি বা নম্বর আবার ব্যবহার"),
    "RF11": ("Small first payment, then larger transfers (test payment)", "প্রথমে ছোট পরীক্ষামূলক পেমেন্ট, তারপর বড় অঙ্ক"),
    "RF12": ("High model score with matching reasons", "মডেলের উঁচু স্কোর, সাথে মিলে যাওয়া কারণ"),
    "RF16": ("A tool output tried to instruct the investigator", "টুলের ফলাফলে তদন্তকারীকে নির্দেশ দেওয়ার চেষ্টা"),
}
TYPOLOGY_LABEL: dict[str, tuple[str, str]] = {
    "otp_takeover_cashout": ("OTP takeover and cash-out", "ওটিপি দিয়ে অ্যাকাউন্ট দখল ও ক্যাশ আউট"),
    "purchased_mule_cluster": ("Purchased mule cluster", "কেনা মিউল অ্যাকাউন্টের দল"),
    "ledger_leak_targeting": ("Targeting from a leaked customer list", "ফাঁস হওয়া গ্রাহক তালিকা ধরে প্রতারণা"),
    "agent_round_tripping": ("Agent round-tripping", "এজেন্টের কাছে টাকা ঘোরানো"),
    "fan_in_fan_out": ("Fan-in, fan-out", "অনেকের টাকা এক জায়গায় জড়ো করে ছড়িয়ে দেওয়া"),
    "dormant_then_active": ("Dormant, then active", "অচল অ্যাকাউন্ট হঠাৎ সচল"),
    "none": ("No fraud pattern", "কোনো প্রতারণার ধরন নেই"),
}
ROLE_LABEL: dict[str, tuple[str, str]] = {
    "victim": ("Victim", "ক্ষতিগ্রস্ত"),
    "mule_L1": ("First mule", "প্রথম স্তরের মিউল"),
    "mule_L2": ("Second-layer mule", "দ্বিতীয় স্তরের মিউল"),
    "cashout_agent": ("Cash-out agent", "ক্যাশ-আউট এজেন্ট"),
    "purchased_mule": ("Purchased mule", "কেনা মিউল"),
    "controller": ("Controller", "নিয়ন্ত্রক"),
    "unclear": ("Role unclear", "ভূমিকা অস্পষ্ট"),
}
ACTION_LABEL: dict[str, tuple[str, str]] = {
    "freeze": ("Freeze", "ফ্রিজ"),
    "edd": ("Enhanced due diligence", "বাড়তি যাচাই (ইডিডি)"),
    "monitor": ("Monitor", "নজরে রাখা"),
    "close_no_action": ("Close, no action", "বন্ধ, কোনো পদক্ষেপ নয়"),
}
SEED_CALL = "tc_00"  # Case Zero's seed brief: the model's score and leads, prefetched before the agent's first turn


def _label(table: dict[str, tuple[str, str]], key: str | None) -> dict[str, str] | None:
    if not key:
        return None
    en, bn = table.get(key, (key, key))
    return {"en": en, "bn": bn}


def case_file(report: dict[str, Any], events: list[dict[str, Any]], source: str) -> dict[str, Any]:
    """One investigation as an analyst reads it: the decision and who made which part of it (the score's floor is
    code's, the proposal is the model's), the members with the calls that prove each, the red flags, the timeline, the
    look-alikes ruled out, both narratives, the model's reasons, the checks code ran and what the run cost.

    `source` is "live" (a case Case Zero holds now) or "recorded" (the replay). Every field tolerates a missing piece:
    a degraded or failed case still reads."""
    tools: dict[str, str | None] = {SEED_CALL: "seed_brief"}
    calls = [{"call_id": SEED_CALL, "tool": "seed_brief", "args": {"acct_id": report.get("seed")}}]
    for e in events:
        call_id = e.get("call_id")
        if e.get("type") == "tool_call" and call_id and call_id not in tools:
            tools[call_id] = e.get("name")
            calls.append({"call_id": call_id, "tool": e.get("name"), "args": e.get("args") or {}})

    def cite(ids: list[str] | None) -> list[dict[str, Any]]:
        return [{"call_id": c, "tool": tools.get(c)} for c in ids or []]

    draft = report.get("draft") or {}
    validation = report.get("validation") or {}
    gate = validation.get("gate") or {}
    cost = report.get("cost") or {}
    done = next((e for e in events if e.get("type") == "done"), {})
    first_pass = validation.get("first_pass")
    return {
        "case_id": report.get("case_id"),
        "seed": report.get("seed"),
        "as_of": report.get("as_of"),
        "status": report.get("status"),
        "source": source,
        "model_version": report.get("model_version"),
        "decision": {
            "action": report.get("action"), "action_label": _label(ACTION_LABEL, report.get("action")),
            "floor_action": report.get("floor_action"), "floor_action_label": _label(ACTION_LABEL, report.get("floor_action")),
            "proposed_action": draft.get("proposed_action"), "proposed_action_label": _label(ACTION_LABEL, draft.get("proposed_action")),
            "band": report.get("band"), "model_score": report.get("model_score"), "escalated": report.get("escalated"),
            "review_note": report.get("review_note"),
        },
        "typology": draft.get("typology"),
        "typology_label": _label(TYPOLOGY_LABEL, draft.get("typology")),
        "members": [{"acct_id": m.get("acct_id"), "role": m.get("role"), "role_label": _label(ROLE_LABEL, m.get("role")),
                     "evidence": cite(m.get("evidence"))} for m in draft.get("members") or []],
        "excluded": [{"acct_id": x.get("acct_id"), "reason": x.get("reason"), "evidence": cite(x.get("evidence"))}
                     for x in draft.get("excluded") or []],
        "red_flags": [{"code": r.get("code"), "meaning": _label(RED_FLAG_MEANING, r.get("code")), "text": r.get("text"),
                       "evidence": cite(r.get("evidence"))} for r in draft.get("red_flags") or []],
        "timeline": [{"ts": t.get("ts"), "text": t.get("text"), "evidence": cite(t.get("evidence"))} for t in draft.get("timeline") or []],
        "narrative": {"en": draft.get("narrative_en") or "", "bn": draft.get("narrative_bn") or ""},
        "limitations": draft.get("limitations"),
        "model_reasons": [r for r in report.get("top_reasons") or [] if isinstance(r, dict)],
        "checks": {
            "citations_passed_first_time": (not first_pass) if first_pass is not None else None,
            "retried": bool(validation.get("retried")),
            "flags_dropped": list(validation.get("flags_dropped") or []),
            "members_kept": len(gate.get("kept") or {}),
            "moved_to_excluded": list((gate.get("dropped") or {}).keys()) if isinstance(gate.get("dropped"), dict) else list(gate.get("dropped") or []),
        },
        "run": {
            "model": cost.get("model"), "tool_calls": report.get("tool_calls", len(calls) - 1), "turns": cost.get("turns"),
            "tokens_in": cost.get("tokens_in"), "tokens_out": cost.get("tokens_out"), "cost_usd": cost.get("cost_usd"),
            "llm_ms": cost.get("llm_ms"), "seconds": done.get("_t"),
        },
        "calls": calls,
    }


def replay() -> list[dict[str, Any]]:
    """A recorded agent run, as a list of events.

    The endpoint answers NDJSON - one event per line - so the console can show the whole tool loop
    without spending anyone's Gemini budget. That matters during judging more than it sounds.
    """
    _require_base()
    request = urllib.request.Request(f"{BASE}/api/replay", headers={"Accept": "application/x-ndjson"})
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT_S) as response:
            body = response.read().decode()
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise CaseZeroUnavailable(str(exc)) from exc
    events: list[dict[str, Any]] = []
    for line in body.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return events


def graph() -> dict[str, Any]:
    """The graph Case Zero traversed, assembled from its own tool outputs.

    Every tool result in a run carries a `graph_delta` - the nodes and edges that call discovered.
    Replaying the run in order and accumulating them gives the investigator's view of the ring
    exactly as it built it up: no layout we invented, no edge we inferred, nothing drawn that a
    named tool call did not return.

    Each node and edge therefore carries the call that first introduced it. That is the point. A
    picture of a fraud ring is a serious claim about people, and this one can be taken apart back
    to the tool output it came from, the same way the case text can be taken apart to its evidence.
    """
    events = replay()

    nodes: dict[str, dict[str, Any]] = {}
    edges: dict[str, dict[str, Any]] = {}
    calls: list[dict[str, Any]] = []
    meta: dict[str, Any] = {}

    for event in events:
        kind = event.get("type")
        if kind == "run_started":
            meta = {
                "case_id": event.get("case_id"),
                "seed": event.get("seed"),
                "as_of": event.get("as_of"),
                "model": event.get("model"),
            }
        if kind in {"tool_result", "score"}:
            call_id = event.get("call_id")
            name = event.get("name") or ("score" if kind == "score" else "unknown")
            delta = event.get("graph_delta") or {}
            added_nodes = 0
            added_edges = 0
            for node in delta.get("nodes") or []:
                node_id = node.get("id")
                if not node_id or node_id in nodes:
                    continue
                nodes[node_id] = {**node, "found_by": call_id, "found_by_tool": name}
                added_nodes += 1
            for edge in delta.get("edges") or []:
                key = f"{edge.get('source')}>{edge.get('target')}:{edge.get('txn_id') or edge.get('kind')}"
                if key in edges:
                    continue
                edges[key] = {**edge, "found_by": call_id, "found_by_tool": name}
                added_edges += 1
            calls.append({
                "call_id": call_id, "tool": name, "ok": event.get("ok"),
                "at_s": event.get("_t"), "added_nodes": added_nodes, "added_edges": added_edges,
            })

    # What the watch-list says about any of these accounts. Also server data, also not ours.
    roles: dict[str, dict[str, Any]] = {}
    try:
        for payee in payee_risk().get("payees", []):
            roles[payee["acct_id"]] = {
                "role": payee.get("role"),
                "model_score": payee.get("model_score"),
                "case_id": payee.get("case_id"),
                "status": payee.get("status"),
            }
    except CaseZeroUnavailable:
        pass

    degree: dict[str, int] = {}
    for edge in edges.values():
        for end in ("source", "target"):
            node_id = edge.get(end)
            if node_id:
                degree[node_id] = degree.get(node_id, 0) + 1
                nodes.setdefault(node_id, {"id": node_id, "kind": "unknown",
                                           "found_by": edge.get("found_by"),
                                           "found_by_tool": edge.get("found_by_tool")})

    seed = meta.get("seed")
    for node_id, node in nodes.items():
        node["degree"] = degree.get(node_id, 0)
        node["is_seed"] = node_id == seed
        node.update(roles.get(node_id, {}))

    money = [e for e in edges.values() if e.get("kind") == "money"]
    return {
        **meta,
        "nodes": list(nodes.values()),
        "edges": list(edges.values()),
        "calls": calls,
        "counts": {
            "nodes": len(nodes),
            "edges": len(edges),
            "money_edges": len(money),
            "money_bdt": round(sum(e.get("amount_bdt") or 0 for e in money)),
            "watchlisted": sum(1 for n in nodes.values() if n.get("role")),
            "tool_calls": len(calls),
        },
        "source": "Case Zero /api/replay, graph_delta of each tool result",
        "badge": "MODEL",
    }
