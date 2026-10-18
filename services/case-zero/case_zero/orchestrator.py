"""Runs one investigation: tool loop, case writer, validator with one retry, then code builds the report."""

from __future__ import annotations

import asyncio
import time
from collections.abc import Awaitable, Callable

from google.genai import errors as genai_errors
from google.genai import types
from pydantic import ValidationError

from case_zero import prompts
from case_zero.budget import BudgetExceeded
from case_zero.config import Settings
from case_zero.ledger import Ledger
from case_zero.llm import LLM, LLMTurn, cost_usd
from case_zero.policy import ACTIONS, band_for, escalation_flags, final_action, floor_action
from case_zero.schemas import CaseDraft, CaseReport, exported_status
from case_zero.gate import apply_gate, strip_accusations
from case_zero.tools import TOOL_SPECS
from case_zero.validator import Violation, case_accounts, drop_unsupported_flags, flag_feedback, redact, validate
from case_zero.world import World

Emit = Callable[[dict], Awaitable[None]]
FAULT_EN = " (fault injection) acct_rina also lost Tk 12,345."
FAULT_BN = " (ফল্ট ইনজেকশন) acct_rina আরও ১২,৩৪৫ টাকা হারান।"


class _Usage:
    def __init__(self, role) -> None:
        self.role, self.tokens_in, self.tokens_out, self.llm_ms, self.turns = role, 0, 0, 0.0, 0

    def add(self, turn: LLMTurn) -> None:
        self.tokens_in += turn.tokens_in
        self.tokens_out += turn.tokens_out
        self.llm_ms += turn.latency_ms
        self.turns += 1

    def as_dict(self) -> dict:
        return {"model": self.role.id, "turns": self.turns, "tokens_in": self.tokens_in, "tokens_out": self.tokens_out,
                "cost_usd": cost_usd(self.tokens_in, self.tokens_out, self.role), "llm_ms": round(self.llm_ms)}


def _model_content(turn: LLMTurn) -> types.Content:
    if turn.raw_content is not None:
        return turn.raw_content  # keeps Gemini's thought signatures for the next turn
    return types.Content(role="model", parts=[types.Part(function_call=types.FunctionCall(id=c.id, name=c.name, args=c.args)) for c in turn.function_calls])


def _user(text: str) -> types.Content:
    return types.Content(role="user", parts=[types.Part(text=text)])


def _llm_failure(exc: Exception) -> str:
    if isinstance(exc, BudgetExceeded):
        return "Gemini spend cap reached"
    if isinstance(exc, asyncio.TimeoutError):
        return "timed out"
    return f"Gemini error {getattr(exc, 'code', '')}".strip()


def _fallback_draft(seed: str, floor: str, reason: str) -> CaseDraft:
    return CaseDraft(typology="none", members=[], excluded=[], red_flags=[], timeline=[], proposed_action=floor,
                     narrative_en=f"No validated case narrative is available for {seed}. See the tool trace.",
                     narrative_bn=f"{seed}-এর জন্য যাচাইকৃত কোনো বিবরণ নেই। টুল ট্রেস দেখুন।", limitations=reason)


async def _investigate(llm: LLM, ledger: Ledger, emit: Emit, usage: _Usage, settings: Settings, deadline: float, limits: list[str]) -> str:
    contents = [_user(prompts.investigator_task(ledger.seed, ledger.as_of, ledger.entries[0]))]
    loop_deadline = min(deadline, time.monotonic() + settings.investigator_timeout_s)
    nudges, slow_retries = 0, 0
    while True:
        remaining = loop_deadline - time.monotonic()
        if remaining <= 0:
            limits.append("investigation stopped at its time limit")
            return ""
        try:
            turn = await llm.chat(prompts.INVESTIGATOR_SYSTEM, contents, TOOL_SPECS, None, min(remaining, settings.llm_turn_timeout_s))
        except asyncio.TimeoutError:
            if slow_retries < 1 and loop_deadline - time.monotonic() > 5:
                slow_retries += 1  # one slow Gemini turn should not end the investigation
                continue
            limits.append("investigation stopped at its time limit")
            return ""
        except (genai_errors.APIError, BudgetExceeded) as exc:
            limits.append(f"investigation stopped early: {_llm_failure(exc)}")
            return ""
        usage.add(turn)
        if not turn.function_calls:
            used = ledger.max_calls - ledger.budget_left
            if used < settings.min_tool_calls and nudges < settings.max_nudges and ledger.budget_left > 0:
                nudges += 1  # concluding from tc_00 alone is not an investigation
                contents.append(_model_content(turn) if turn.raw_content is not None else types.Content(role="model", parts=[types.Part(text=turn.text or "(no reply)")]))
                contents.append(_user(prompts.investigate_more(used, settings.min_tool_calls)))
                continue
            return turn.text
        contents.append(_model_content(turn))
        calls = [(fc, ledger.reserve()) for fc in turn.function_calls]  # numbered in the model's order before any runs
        for fc, call_id in calls:
            await emit({"type": "tool_call", "call_id": call_id, "name": fc.name, "args": fc.args})
        outcomes = await asyncio.gather(*(asyncio.to_thread(ledger.run, call_id, fc.name, fc.args) for fc, call_id in calls))  # one turn's calls are independent
        responses = []
        for (fc, _), outcome in zip(calls, outcomes):
            result = ledger.record(fc.name, fc.args, outcome)
            await emit({"type": "tool_result", "name": fc.name, "args": fc.args, **result})
            payload = {k: result[k] for k in ("call_id", "ok", "data", "truncated") if k in result} | ({"error": result["error"]} if "error" in result else {})
            responses.append(types.Part(function_response=types.FunctionResponse(id=fc.id, name=fc.name, response=payload)))
        contents.append(types.Content(role="user", parts=responses))
        if ledger.budget_left <= 0:
            limits.append(f"tool budget of {ledger.max_calls} calls reached")
            return ""


async def _write(llm: LLM, ledger: Ledger, notes: str, limits: list[str], emit: Emit, usage: _Usage, settings: Settings, deadline: float, fault_inject: bool):
    """Returns (draft or None, first-pass violations, violations still standing, retried, first-pass flag feedback).

    A draft is only ever paired with its own violations, so when the retry fails (timeout, bad JSON,
    API error) the first draft comes back with everything wrong with it and gets redacted. Red flags no
    fitting call backs share that one retry: the writer is told why; if the retry does not give a draft that
    passes, the first draft (which passed the citation check) stands and code drops those flags.
    """
    contents = [_user(prompts.writer_task(ledger.seed, ledger.as_of, ledger.entries, notes, limits))]
    best: tuple[CaseDraft, list[Violation]] | None = None
    passed: CaseDraft | None = None   # a first draft that passed the citation check but was sent back for its red flags
    first_pass: list[Violation] = []
    flag_notes: list[Violation] = []
    for attempt in (1, 2):
        timeout = min(settings.writer_timeout_s, deadline - time.monotonic())
        if timeout <= 1:
            limits.append("case writer ran out of time")
            break
        turn, failure = None, None
        try:
            turn = await llm.chat(prompts.WRITER_SYSTEM, contents, None, CaseDraft, timeout, max_output_tokens=settings.writer_max_output_tokens)
            usage.add(turn)
            draft = turn.parsed or CaseDraft.model_validate_json(turn.text)
        except (ValidationError, ValueError) as exc:
            failure = Violation("invalid_json", "draft", str(exc)[:300])
        except (asyncio.TimeoutError, genai_errors.APIError, BudgetExceeded) as exc:
            failure = Violation("writer_failed", "draft", _llm_failure(exc))
            limits.append(f"case writer: {_llm_failure(exc)}")
        if failure is not None:
            await emit({"type": "validator", "attempt": attempt, "pass": False, "fault_injected": False, "violations": [failure.__dict__]})
            if attempt == 1:
                first_pass = [failure]
            if isinstance(failure.detail, str) and "spend cap" in failure.detail:
                break
            contents.append(_user(prompts.retry_feedback([failure])))
            continue
        injected = fault_inject and attempt == 1
        if injected:
            draft = draft.model_copy(update={"narrative_en": draft.narrative_en + FAULT_EN, "narrative_bn": draft.narrative_bn + FAULT_BN})
        violations = validate(draft, ledger)
        feedback = flag_feedback(draft, ledger) if attempt == 1 else []   # after the retry, code drops what is still unsupported
        await emit({"type": "draft", "attempt": attempt, "draft": draft.model_dump()})
        await emit({"type": "validator", "attempt": attempt, "pass": not (violations or feedback), "fault_injected": injected,
                    "violations": [v.__dict__ for v in violations + feedback]})
        if attempt == 1:
            first_pass, flag_notes = violations, feedback
        if not violations and not feedback:
            return draft, first_pass, [], attempt == 2, flag_notes
        if violations:
            best = (draft, violations)
        else:
            passed = draft
        if turn is not None and turn.text:
            contents.append(types.Content(role="model", parts=[types.Part(text=turn.text)]))
        contents.append(_user(prompts.retry_feedback(violations + feedback)))
    if passed is not None:
        return passed, first_pass, [], True, flag_notes
    if best is None:
        return None, first_pass, [], True, flag_notes
    return best[0], first_pass, best[1], True, flag_notes


async def run_investigation(world: World, llm: LLM, seed: str, as_of: str, emit: Emit, case_id: str, fault_inject: bool = False, settings: Settings = Settings()) -> CaseReport:
    deadline = time.monotonic() + settings.run_timeout_s
    ledger = Ledger(world, seed, as_of, settings.max_tool_calls)
    usage = _Usage(llm.role)
    limits: list[str] = []
    await emit({"type": "run_started", "case_id": case_id, "seed": seed, "as_of": as_of, "model": llm.role.id, "max_tool_calls": settings.max_tool_calls})
    score = await asyncio.to_thread(ledger.prefetch_score)
    await emit({"type": "score", **score})
    probability = float(score["data"]["probability"]) if score["ok"] else 0.0
    floor = floor_action(probability)
    status = "done"
    first_pass, final, retried = [], [], False
    gate_info: dict = {"kept": {}, "dropped": {}}
    flags_dropped: list[str] = []
    flag_notes: list[Violation] = []
    accusations_removed: list[str] = []
    post_gate: list[Violation] | None = None
    if world.account(seed) is None:
        draft = _fallback_draft(seed, "close_no_action", f"Account {seed} not found in the bank's records at {as_of}.")
    elif not score["ok"]:  # never investigate on a missing score: it would silently lower the floor
        status, floor = "failed", "close_no_action"
        draft = _fallback_draft(seed, floor, f"The model score could not be computed at {as_of} ({score.get('error')}); no investigation was run.")
    elif not world.has_activity(seed, as_of):
        draft = _fallback_draft(seed, "close_no_action", f"Account {seed} has no activity at or before {as_of}; nothing to investigate.")
    else:
        notes = await _investigate(llm, ledger, emit, usage, settings, deadline, limits)
        await emit({"type": "usage", **usage.as_dict()})
        draft, first_pass, final, retried, flag_notes = await _write(llm, ledger, notes, limits, emit, usage, settings, deadline, fault_inject)
        if draft is None:
            status = "failed"
            draft = _fallback_draft(seed, floor, "The case writer did not return a valid case. " + "; ".join(limits))
        elif final:
            status = "failed_after_retry"
            draft = redact(draft, final)
        written = draft.limitations   # the writer's own; every limitation line code adds below is left out of the re-check
        missing = [x for x in limits if x.casefold() not in draft.limitations.casefold()]
        if missing:
            draft = draft.model_copy(update={"limitations": " ".join(x for x in (draft.limitations, "; ".join(missing) + ".") if x)})
        if status != "failed":
            checked = draft
            draft, flags_dropped = drop_unsupported_flags(draft, ledger)
            draft, gate_info = await asyncio.to_thread(apply_gate, world, seed, as_of, draft)
            await emit({"type": "gate", **gate_info})
            draft, accusations_removed = strip_accusations(draft, gate_info["dropped"])  # an excluded account is accused nowhere else
            if status == "done" and draft != checked:  # code changed a passed draft: check what the writer wrote that is still exported
                post_gate = validate(draft.model_copy(update={"limitations": written}), ledger)
                await emit({"type": "validator", "attempt": "post_gate", "pass": not post_gate, "fault_injected": False, "violations": [v.__dict__ for v in post_gate]})
                if post_gate:
                    status, final = "failed_after_retry", post_gate
                    draft = redact(draft, post_gate, "after the code check")
    action = final_action(probability, draft.proposed_action, escalation_flags(draft.red_flags, ledger, case_accounts(draft, ledger)) if status == "done" else 0)
    review_note = None
    if status != "failed" and draft.proposed_action in ACTIONS and ACTIONS.index(draft.proposed_action) < ACTIONS.index(floor):
        review_note = f"The case writer proposed {draft.proposed_action}, below the score floor {floor}; the action was set to {floor}. A human should review the disagreement."
    report = CaseReport(
        case_id=case_id, seed=seed, as_of=as_of, status=status, draft=draft, model_score=probability,
        top_reasons=score["data"].get("reasons", []) if score["ok"] else [], action=action, floor_action=floor, band=band_for(probability), review_note=review_note,
        escalated=action != floor, validation={"first_pass": [v.__dict__ for v in first_pass], "final": [v.__dict__ for v in final], "retried": retried, "gate": gate_info, "flag_feedback": [v.__dict__ for v in flag_notes], "flags_dropped": flags_dropped, "accusations_removed": accusations_removed,
                                               **({"post_gate": [v.__dict__ for v in post_gate]} if post_gate is not None else {})},
        model_version=f"{world.scorer.version}+{llm.role.id}", cost=usage.as_dict(), tool_calls=ledger.max_calls - ledger.budget_left,
    )
    await emit({"type": "report", "report": report.model_dump()})
    await emit({"type": "done", "case_id": case_id, "status": exported_status(status)})
    report._ledger = ledger
    return report
