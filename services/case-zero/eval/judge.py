"""The narrative judge for the eval (spec US-4 and US-5): the OCBC four-criterion rubric, 1 to 5, plus
English/Bangla consistency, scored from the case file and only the tool outputs it cites. No labels.

The eval's default judge is the `reasoning` role in risk-mw/config/models.yaml (Gemini 3.1 Pro preview
on Vertex AI): a different model from the agent's 3.8 Flash, as a code review suggested, though the
same family, so some self-preference bias is still possible. `--judge-role judge` uses the agent's own
model. The results say which model judged, per case.
"""

from __future__ import annotations

import hashlib
import json

from google.genai import types
from pydantic import BaseModel, Field

from case_zero.llm import cost_usd

JUDGE_TIMEOUT_S = 45.0
MAX_OUTPUT_CHARS = 1500   # per cited tool output
MAX_INPUT_CHARS = 20_000
RUBRIC = ("evidence", "consistency", "clarity", "actionability")

JUDGE_SYSTEM = """You are an independent senior fraud-operations reviewer at a Bangladeshi digital bank. You did not write this case.
Score it from 1 to 5 on each criterion, using ONLY the case file and the cited tool outputs you are given.
Be strict: 5 = no issues, 4 = minor issues, 3 = noticeable issues, 2 = serious problems, 1 = unusable.

- evidence: every claim (accounts, roles, amounts, times, red flags) is supported by a cited tool output. List each unsupported claim in unsupported_claims.
- consistency: typology, roles, timeline, red flags and the recommended action agree with each other and with the evidence.
- clarity: a busy analyst understands what happened, who did what and why in one read, in plain language.
- actionability: the next step is clear: the action, which accounts to freeze or review, and what is still unknown (limitations).
- en_bn_consistency: narrative_bn says the same as narrative_en (the same accounts, amounts, dates, times and typology) in natural Bangla. List each difference in mismatches.

The model score and the action were set by the bank's code, not by the writer: judge whether the case justifies them, not the numbers themselves.
Keep the rationale under 60 words."""

JUDGE_SHA = hashlib.sha256(JUDGE_SYSTEM.encode()).hexdigest()[:12]


class JudgeScore(BaseModel):
    evidence: int = Field(ge=1, le=5)
    consistency: int = Field(ge=1, le=5)
    clarity: int = Field(ge=1, le=5)
    actionability: int = Field(ge=1, le=5)
    en_bn_consistency: int = Field(ge=1, le=5)
    mismatches: list[str]
    unsupported_claims: list[str]
    rationale: str


def judge_input(report, ledger) -> str:
    """The case file plus the outputs of the calls it cites, each trimmed; roles are written inline, not as label fields."""
    d = report.draft
    cited = sorted({c for group in (d.members, d.excluded, d.red_flags, d.timeline) for item in group for c in item.evidence})
    evidence = []
    for call_id in cited:
        entry = ledger.entry(call_id) if ledger is not None else None
        if entry is not None:
            output = json.dumps(entry["data"], ensure_ascii=False, default=str)
            evidence.append({"call_id": call_id, "tool": entry["name"], "args": entry["args"],
                             "output": output[:MAX_OUTPUT_CHARS] + (" …(trimmed)" if len(output) > MAX_OUTPUT_CHARS else "")})
    case = {
        "seed": report.seed, "as_of": report.as_of, "model_score": report.model_score, "band": report.band,
        "action": report.action, "score_floor": report.floor_action, "typology": d.typology,
        "members": [f"{m.acct_id} as {m.role} [{', '.join(m.evidence)}]" for m in d.members],
        "excluded": [f"{x.acct_id}: {x.reason} [{', '.join(x.evidence)}]" for x in d.excluded],
        "red_flags": [f"{f.code}: {f.text} [{', '.join(f.evidence)}]" for f in d.red_flags],
        "timeline": [f"{t.ts}: {t.text} [{', '.join(t.evidence)}]" for t in d.timeline],
        "narrative_en": d.narrative_en, "narrative_bn": d.narrative_bn, "limitations": d.limitations,
    }
    text = ("Case file:\n" + json.dumps(case, ensure_ascii=False, indent=1)
            + "\n\nTool outputs the case cites:\n" + json.dumps(evidence, ensure_ascii=False, indent=1))
    return text[:MAX_INPUT_CHARS]


async def judge_case(llm, report, timeout_s: float = JUDGE_TIMEOUT_S) -> dict:
    """Scores for one case, or {"judge_error": …}; a judge failure never fails the eval. Both name the judge's model."""
    contents = [types.Content(role="user", parts=[types.Part(text=judge_input(report, report._ledger))])]
    try:
        turn = await llm.chat(JUDGE_SYSTEM, contents, None, JudgeScore, timeout_s)
        score = turn.parsed if isinstance(turn.parsed, JudgeScore) else JudgeScore.model_validate_json(turn.text)
    except Exception as exc:  # bad JSON, timeouts, API errors, the spend cap, credentials: recorded on the row
        return {"judge_error": f"{type(exc).__name__}: {str(exc)[:200]}", "judge_model": llm.role.id}
    return {**score.model_dump(), "judge_model": turn.model_id, "judge_tokens_in": turn.tokens_in, "judge_tokens_out": turn.tokens_out,
            "judge_cost_usd": cost_usd(turn.tokens_in, turn.tokens_out, llm.role)}
