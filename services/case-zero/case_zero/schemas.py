"""The writer's draft (what Gemini fills, no score or final action) and the report code builds."""

from __future__ import annotations

from typing import Literal

from typing import Any

from pydantic import BaseModel, Field, PrivateAttr, computed_field

Typology = Literal["otp_takeover_cashout", "purchased_mule_cluster", "ledger_leak_targeting", "agent_round_tripping", "fan_in_fan_out", "dormant_then_active", "none"]
Role = Literal["victim", "mule_L1", "mule_L2", "cashout_agent", "purchased_mule", "controller", "unclear"]
Action = Literal["close_no_action", "monitor", "edd", "freeze"]
# The writer's red flag catalogue (prompts.RED_FLAGS; a test keeps them in step). A closed set, so Gemini's
# structured output cannot invent a code such as "RF99: No suspicious pattern was found."
FlagCode = Literal["RF01", "RF02", "RF03", "RF04", "RF05", "RF06", "RF07", "RF08", "RF09", "RF10", "RF11", "RF12", "RF16"]


class Member(BaseModel):
    acct_id: str
    role: Role
    evidence: list[str] = Field(description="Call ids (tc_NN) whose output shows this account")


class Excluded(BaseModel):
    acct_id: str
    reason: str
    evidence: list[str]


class RedFlag(BaseModel):
    code: FlagCode = Field(description="A code from the red flag catalogue")
    text: str
    evidence: list[str]


class TimelineItem(BaseModel):
    ts: str
    text: str
    evidence: list[str]


class CaseDraft(BaseModel):
    typology: Typology
    members: list[Member]
    excluded: list[Excluded]
    red_flags: list[RedFlag]
    timeline: list[TimelineItem]
    proposed_action: Action
    narrative_en: str
    narrative_bn: str
    limitations: str


class CaseReport(BaseModel):
    case_id: str
    seed: str
    as_of: str
    status: Literal["done", "failed_after_retry", "failed"]
    draft: CaseDraft
    model_score: float
    top_reasons: list[dict]
    action: Action
    floor_action: Action
    band: Literal["critical", "high", "medium", "low"] = "low"
    escalated: bool
    review_note: str | None = None  # set when the writer proposed an action below the score floor
    validation: dict
    model_version: str
    cost: dict
    tool_calls: int
    _ledger: Any = PrivateAttr(default=None)  # the investigation's ledger; never serialised

    @computed_field
    @property
    def exported_status(self) -> str:
        """What the case leaves Case Zero as (done, degraded or failed), for the console and the contract."""
        return exported_status(self.status)


ExportedStatus = Literal["done", "degraded", "failed"]
# What a case leaves Case Zero as (risk-mw's CaseReport status): failed_after_retry is delivered but did not pass
# the citation check after the retry, so it is degraded, never done.
EXPORTED_STATUS: dict[str, ExportedStatus] = {"done": "done", "failed_after_retry": "degraded", "degraded": "degraded", "failed": "failed"}
DECIDED_STATUSES = frozenset({"done", "degraded"})   # exported statuses that carry a delivered case and its action


def exported_status(status: str) -> ExportedStatus:
    return EXPORTED_STATUS[status]


def to_contract(report: CaseReport, ledger) -> dict:
    """Map onto risk-mw's frozen CaseReport. Confidence is the model's score, never the LLM's.

    Evidence rows are real transaction ids from the calls a red flag cites; a flag no transaction backs
    (a shared device, the score itself) has no row to point at and is left out. failed_after_retry is a
    delivered, redacted case: status degraded (never done or failed) with redacted=True, the violations the
    citation check still found in validation_errors, and the limitations. Those three optional fields are sent
    only for a degraded case, so a done or failed contract has exactly the shape risk-mw accepted before the degraded status
    and Case Zero can deploy first; a degraded case needs the risk-mw that knows "degraded" (deploy risk-mw first).
    """
    from case_zero.evidence import evidence_txn   # imported here: it reads the validator, which imports this module

    evidence = []
    for flag in report.draft.red_flags:
        if row_id := evidence_txn(flag, ledger):   # the cited transfer the flag is about, or none
            evidence.append({"row_id": row_id, "claim": flag.text})
    return {
        "case_id": report.case_id,
        "acct_id": report.seed,
        "status": exported_status(report.status),
        "summary_en": report.draft.narrative_en,
        "summary_bn": report.draft.narrative_bn,
        "evidence": evidence,
        "ring": tuple(m.acct_id for m in report.draft.members if m.role != "victim"),
        "confidence": report.model_score,
        "recommended_action": report.action,
        "model_version": report.model_version,
        **({"redacted": True, "validation_errors": [f"{v['code']} in {v['field']}: {v['detail']}" for v in report.validation.get("final", [])],
            "limitations": report.draft.limitations} if report.status == "failed_after_retry" else {}),
    }
