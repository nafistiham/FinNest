"""One investigation's evidence ledger: numbered tool calls and every fact they returned.

The validator checks the written case against this ledger, so anything the case cites must
appear here. Call ids are short (tc_00 is the seed score, fetched by code before the agent runs).
A call is reserved (numbered), run, then recorded: the run step only reads the world, so the calls of
one model turn can run in threads at once and still be recorded in the model's order.
"""

from __future__ import annotations

import re
import time
from dataclasses import dataclass, field

from case_zero.tools import KNOWN_TOOLS, SEED_BRIEF, run_tool
from case_zero.world import World

LIST_CAP = 25
ID_RE = re.compile(r"^(?:acct_[A-Za-z0-9_]+(?:-\d{4})?|txn_\d{6}|AG-\d{4}|(?:device|sim|nid|phone|onboarding_agent):\S+)$")
TS_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2})?$")


def _whole_taka(node, key: str = ""):
    """Amount fields become whole Taka so the model never sees or repeats 7900.0."""
    if isinstance(node, dict):
        return {k: _whole_taka(v, k) for k, v in node.items()}
    if isinstance(node, list):
        return [_whole_taka(v, key) for v in node]
    if isinstance(node, float) and key.endswith("_bdt"):
        return int(round(node))
    return node


def _cap_lists(node) -> tuple[object, bool]:
    if isinstance(node, dict):
        out, cut = {}, False
        for k, v in node.items():
            out[k], c = _cap_lists(v)
            cut = cut or c
        return out, cut
    if isinstance(node, list):
        items = [_cap_lists(v) for v in node[:LIST_CAP]]
        return [i for i, _ in items], len(node) > LIST_CAP or any(c for _, c in items)
    return node, False


@dataclass
class Ledger:
    world: World
    seed: str
    as_of: str
    max_calls: int = 10
    entries: list[dict] = field(default_factory=list)
    ids: set[str] = field(default_factory=set)
    amounts_bdt: set[int] = field(default_factory=set)
    times: set[str] = field(default_factory=set)
    numbers: set[int] = field(default_factory=set)  # every numeric value a tool returned (counts, totals)
    _used: int = 0

    @property
    def budget_left(self) -> int:
        return self.max_calls - self._used

    def prefetch_score(self) -> dict:
        args = {"acct_id": self.seed}  # score + the model's candidates around the seed
        return self.record(SEED_BRIEF, args, self.run("tc_00", SEED_BRIEF, args, known={SEED_BRIEF}))

    def call(self, tool: str, /, **kwargs) -> dict:
        return self.record(tool, kwargs, self.run(self.reserve(), tool, kwargs))

    def reserve(self) -> str | None:
        """The next call id, or None once the budget is spent. Taken before the call runs."""
        if self._used >= self.max_calls:
            return None
        self._used += 1
        return f"tc_{self._used:02d}"

    def entry(self, call_id: str) -> dict | None:
        return next((e for e in self.entries if e["call_id"] == call_id), None)

    def run(self, call_id: str | None, name: str, args: dict, known: frozenset[str] | set[str] = KNOWN_TOOLS) -> dict:
        """One reserved call's result. Reads the world and leaves the ledger alone, so it is safe in a thread."""
        if call_id is None:
            return {"call_id": None, "ok": False, "error": "tool budget exhausted", "data": None, "truncated": False}
        started = time.perf_counter()
        if name not in known:
            result = {"call_id": call_id, "ok": False, "error": f"unknown tool {name}", "data": None, "truncated": False}
        else:
            try:
                data, truncated = _cap_lists(_whole_taka(run_tool(self.world, name, self.as_of, args)))
                truncated = truncated or bool(isinstance(data, dict) and data.get("truncated"))
                result = {"call_id": call_id, "ok": True, "data": data, "truncated": truncated}
            except KeyError as exc:  # raised inside a real tool, e.g. a missing field
                result = {"call_id": call_id, "ok": False, "error": f"tool error: KeyError {exc}", "data": None, "truncated": False}
            except (TypeError, ValueError) as exc:
                result = {"call_id": call_id, "ok": False, "error": f"bad arguments: {exc}", "data": None, "truncated": False}
        return {**result, "ms": round((time.perf_counter() - started) * 1000, 2)}

    def record(self, name: str, args: dict, outcome: dict) -> dict:
        """Adds a finished call to the ledger (one thread, call-id order) and returns it with its graph delta."""
        if outcome["call_id"] is None:
            return outcome  # over budget: nothing ran
        result = {k: v for k, v in outcome.items() if k != "ms"}
        found_ids, found_amounts, found_times = set(), set(), set()
        self._harvest(result["data"], "", found_ids, found_amounts, found_times)
        self.ids |= found_ids
        self.amounts_bdt |= found_amounts
        self.times |= found_times
        delta = self._graph_delta(name, result["data"], found_ids)
        self.entries.append({**result, "name": name, "args": args, "ids": sorted(found_ids), "amounts_bdt": sorted(found_amounts), "ms": outcome["ms"]})
        return {**result, "graph_delta": delta}

    def _harvest(self, node, key: str, ids: set, amounts: set, times: set) -> None:
        if isinstance(node, dict):
            for k, v in node.items():
                self._harvest(v, k, ids, amounts, times)
        elif isinstance(node, list):
            for v in node:
                self._harvest(v, key, ids, amounts, times)
        elif isinstance(node, str):
            if ID_RE.match(node):
                ids.add(node)
            elif TS_RE.match(node):
                times.add(node)
        elif isinstance(node, (int, float)) and not isinstance(node, bool):
            self.numbers.add(int(round(node)))
            if key.endswith("_bdt"):
                amounts.add(int(round(node)))

    def _graph_delta(self, name: str, data, found_ids: set[str]) -> dict:
        if not isinstance(data, dict):
            return {"nodes": [], "edges": []}
        nodes = [{"id": i, "kind": self._kind(i)} for i in sorted(found_ids) if not i.startswith("txn_")]
        edges = []
        if name == "path_between":
            edges = [{"source": st["from"], "target": st["to"], "txn_id": st["txn_id"], "amount_bdt": st["amount_bdt"], "ts": st["ts"], "kind": "money"} for st in data.get("steps", [])]
        elif name == "neighbours":  # the walk follows money both ways: draw each row's transfer from sender to receiver
            edges = [{"source": n["from_acct"], "target": n["to_acct"], "txn_id": n["txn_id"], "amount_bdt": n.get("amount_bdt"), "ts": n.get("first_ts"), "kind": "money"} for n in data.get("neighbours", [])]
        elif name == "shared_entities":  # a shared device, SIM, NID or phone: a "link" edge, drawn with no arrow
            edges = [{"source": e["entity"], "target": a, "kind": "link"} for e in data.get("shared", []) for a in e["acct_ids"]]
        elif name == "known_fraud_proximity":
            edges = [{"source": data["acct_id"], "target": h["acct_id"], "kind": "proximity"} for h in data.get("hits", [])]
        elif name == "dormant_cohort":
            edges = [{"source": data["acct_id"], "target": c["acct_id"], "ts": c["first_in"], "kind": "pattern"} for c in data.get("cohort", [])]
        elif name == "common_point_of_compromise":
            edges = [{"source": data["acct_id"], "target": p["acct_id"], "kind": "pattern"} for p in data.get("common_points", [])]
            edges += [{"source": t["via_point"], "target": a["acct_id"], "ts": t["ts"], "kind": "pattern"} for a in data.get("linked_accounts", []) for t in a["transfers"][:1]]
        return {"nodes": nodes, "edges": edges}

    def _kind(self, ident: str) -> str:
        if ident.startswith("AG-"):
            return "agent"
        if ":" in ident:
            return ident.split(":", 1)[0]
        acct = self.world.account(ident)
        return acct.get("kind", "customer") if acct else "unknown"
