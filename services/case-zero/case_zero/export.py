"""payee_risk: the watch-list Eleven seconds reads.

It is built from decisions, not from the display history: each decided report (DECIDED) leaves a small
record of its members, their roles and the action, which outlives the report when the bounded case store
evicts it. Every non-victim member of a decision is "suspected" (Eleven seconds holds payments to it).
After an analyst approves a `done` case, members whose own score at the case time is in the critical band
(policy.BAND_THRESHOLDS, risk-mw's 0.85) become "confirmed" (Eleven seconds declines). Everyone else stays
suspected: hold, never auto-decline.

A `degraded` report (failed_after_retry: it failed validation after the retry) still names its members: redaction already
removed any member whose citation failed, and the code membership check re-checked the rest against the
world's own transfers and identity links. So its members are held like any other, but never confirmed:
a decline needs a fully validated case.
"""

from __future__ import annotations

from datetime import datetime, timezone

from case_zero.policy import band_for
from case_zero.schemas import DECIDED_STATUSES, EXPORTED_STATUS, CaseReport
from case_zero.world import World

CONFIRM_BAND = "critical"
RANK = {"suspected": 1, "confirmed": 2}
DECIDED = DECIDED_STATUSES   # final exported statuses that decide who the case names (schemas.py)
CONFIRMABLE = frozenset({"done"})            # an analyst's approval can turn these into a decline


def decision(case_id: str, report: CaseReport) -> dict | None:
    """What the watch-list keeps from a decided report, or None when it decided nothing: not final yet, or
    nobody but a victim named (an unknown or idle account is `done` with no members)."""
    status = EXPORTED_STATUS.get(report.status)   # failed_after_retry is exported (and decided) as degraded
    if status not in DECIDED or all(m.role == "victim" for m in report.draft.members):
        return None
    members = [{"acct_id": m.acct_id, "role": m.role, "facts": [f.text for f in report.draft.red_flags if set(f.evidence) & set(m.evidence)]}
               for m in report.draft.members]
    return {"case_id": case_id, "seed": report.seed, "as_of": report.as_of, "status": status, "action": report.action, "members": members}


def payee_risk(decisions: dict[str, dict], approved: set[str], world: World) -> dict:
    payees: dict[str, dict] = {}
    for case_id, d in sorted(decisions.items()):
        confirmable = case_id in approved and d["status"] in CONFIRMABLE
        for m in d["members"]:
            if m["role"] == "victim":
                continue
            score = world.score_at(m["acct_id"], d["as_of"])["probability"]
            status = "confirmed" if confirmable and band_for(score) == CONFIRM_BAND else "suspected"
            row = {"acct_id": m["acct_id"], "status": status, "case_id": case_id, "role": m["role"], "model_score": score,
                   "as_of": d["as_of"], "analyst_approved": case_id in approved, "facts": m["facts"]}
            current = payees.get(m["acct_id"])
            if current is None or RANK[status] > RANK[current["status"]]:
                payees[m["acct_id"]] = row
    return {"version": "payee-risk/1", "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"), "payees": sorted(payees.values(), key=lambda p: p["acct_id"])}
