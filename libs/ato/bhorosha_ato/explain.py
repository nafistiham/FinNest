"""SHAP attributions -> a plain-Bangla explanation, and the hits the risk engine consumes.

Three things here are deliberate.

**Gemini writes the words; the rules bound the severity.** The model returns an `action`, but a
language model must never be able to turn a hold into an allow. `required_action()` computes the
floor from the scores, and an explanation that comes back weaker than that floor is rejected.

**Every cited reason must trace to an attribution.** `validate()` enforces it, and a rejected
draft is re-sent once with the violation named before anything is shown to a customer. A fraud
product that invents evidence is worse than no product.

**The Gemini client is injected, not imported.** `ato` and `risk-mw` are separate roots, so
this module takes a callable with the signature of `genai_client.call` instead of importing it.
That keeps the package testable without credentials and without a path hack.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Any, Literal, Protocol

import numpy as np
from pydantic import BaseModel, Field

from bhorosha_ato.model import DERIVED_IDENTITY, identity_matrix
from bhorosha_ato.schema import IDENTITY_FEATURES

Action = Literal["allow", "step_up", "hold_and_callback", "block"]

# Severity order. Gemini may escalate above the computed floor but never below it.
ACTION_RANK: dict[str, int] = {"allow": 0, "step_up": 1, "hold_and_callback": 2, "block": 3}

# An attribution this small is noise; the explanation is not required to mention it.
MIN_CITED_SHAP = 0.1

COACHING_CONCERN = 0.6
ATO_STEP_UP = 0.60
ATO_HOLD = 0.85

# Claims no input of explain() can back. It sees two scores, the attributions and whether a call is active:
# never a SIM event and never a verdict, so a sentence asserting one, or calling anyone a scammer, is rejected whatever
# features it cites. English terms match whole words ("sim" is not "similar"); Bangla ones match inside words (প্রমাণ
# covers প্রমাণিত, প্রতারক covers প্রতারকের; প্রতারণা, "fraud", is not one of them).
UNBACKED_CLAIMS_EN = (
    "proven", "proof", "replaced", "sim", "fraud has been", "confirmed fraud", "scammer", "scammers", "fraudster", "fraudsters",
)
UNBACKED_CLAIMS_BN = ("প্রমাণ", "সিম", "প্রতারণা নিশ্চিত", "প্রতারক", "জালিয়াত")
# Backed only when in_call is true.
CALL_CLAIMS_EN = ("on a call", "on the phone", "hang up", "this call")
CALL_CLAIMS_BN = ("কলে আছেন", "ফোন কেটে", "কল কেটে", "ফোনে কথা")


class Reason(BaseModel):
    """One cited reason. Must correspond to a SHAP attribution, never invented."""

    feature: str
    plain_bangla: str


class ChallengeExplanation(BaseModel):
    """The response schema Gemini must fill. The UI renders these fields only - no free text."""

    action: Action
    bangla_message: str = Field(max_length=240)
    english_message: str
    reasons: list[Reason]
    confidence: float = Field(ge=0.0, le=1.0)


@dataclass(frozen=True, slots=True)
class Attribution:
    """One feature's contribution to the identity score, with what it was measured against."""

    feature: str
    value: float
    baseline: float
    shap: float


@dataclass(frozen=True, slots=True)
class BehaviourHit:
    """A rule hit in the shape `risk-mw`'s `rules.RuleHit` expects.

    Mirrored rather than imported, for the same separate-roots reason as the Gemini client. The
    risk-mw side adapter converts these into real `RuleHit`s. Why hits at all, rather than a
    bare score: `rules.decide()` folds `model_score` into `risk_score` via max() but takes the
    decision and the customer-visible reasons solely from rule hits, so a model returning a
    float moves a number and changes nothing a person would see.
    """

    code: str
    weight: float
    text_bn: str
    text_en: str
    decision: str


class FaithfulnessError(RuntimeError):
    """The draft cited evidence that does not exist, or softened the required action."""


class GeminiCall(Protocol):
    """The subset of `genai_client.call` this module needs."""

    def __call__(
        self,
        task: str,
        role_name: str,
        contents: str,
        schema: type[BaseModel] | None = ...,
        system: str | None = ...,
    ) -> Any: ...


FAITHFULNESS_SYSTEM_PROMPT = """\
You explain to a Bangladeshi mobile-money customer why her payment was questioned.

Rules you must not break:
- Cite only reasons present in top_shap. Never invent a reason.
- Cover every top_shap entry whose absolute shap value is at least 0.1.
- Write bangla_message in plain second-person Bangla, no jargon, at most 240 characters,
  naming the two strongest reasons.
- If coaching_score is at least 0.6 and the device is in a call, tell her in Bangla to hang up
  and call the number printed on her card.
- Your action must be at least as cautious as minimum_action. You may escalate, never soften.
- Never state or imply that fraud has been established. This is a question, not a verdict.
- Mention a call only when in_call is true. Never mention a SIM, and never say anything was
  proven or replaced: say what was observed.
"""


def required_action(ato_score: float, coaching_score: float, in_call: bool) -> Action:
    """The floor on severity, computed from the scores rather than asked of the model.

    Shared-phone inclusion is the reason the middle band is `step_up` and not `block`: Rahima shares a phone and
    has low literacy, and protection that locks her out is just exclusion wearing a safety
    label. Repeated failures escalate, but that is the router's job, not this function's.
    """
    if coaching_score >= COACHING_CONCERN and in_call:
        return "hold_and_callback"
    if ato_score >= ATO_HOLD:
        return "hold_and_callback"
    if coaching_score >= COACHING_CONCERN or ato_score >= ATO_STEP_UP:
        return "step_up"
    return "allow"


def top_attributions(
    model: Any,
    row: tuple[float, ...],
    background: list[tuple[float, ...]],
    k: int = 5,
    nsamples: int = 200,
) -> list[Attribution]:
    """Top-k SHAP attributions for one session against a background of normal sessions.

    KernelExplainer because a OneClassSVM decision function is not a tree and has no exact
    attribution method. The explained quantity is the NEGATED decision function, so a positive
    shap value always means "pushed towards suspicious" - the same direction as `ato_score`.
    Getting that sign wrong would make every Bangla explanation argue the opposite of the
    verdict.
    """
    import shap  # imported lazily: a 200 ms import that most callers never need

    if not background:
        raise ValueError("SHAP needs a background of normal sessions to compare against")

    bg = identity_matrix(background)
    target = identity_matrix([row])

    def suspicion(x: np.ndarray) -> np.ndarray:
        return -model.pipeline.decision_function(x)

    explainer = shap.KernelExplainer(suspicion, bg)
    values = np.asarray(explainer.shap_values(target[0], nsamples=nsamples, silent=True)).ravel()
    baselines = bg.mean(axis=0)

    attributions = [
        Attribution(
            feature=name,
            value=float(target[0][i]),
            baseline=float(baselines[i]),
            shap=float(values[i]),
        )
        for i, name in enumerate(ATTRIBUTION_NAMES)
    ]
    attributions.sort(key=lambda a: abs(a.shap), reverse=True)
    return attributions[:k]


# The columns the identity model actually sees, named in the same order identity_matrix
# builds them. Kept derived from one source: a second copy of this projection is what broke
# SHAP when the derived ratios were added, because the explainer was still building 14 columns
# for a pipeline expecting 17.
ATTRIBUTION_NAMES: tuple[str, ...] = IDENTITY_FEATURES + tuple(
    name for name, _, _ in DERIVED_IDENTITY
)


def _unbacked_claims(explanation: ChallengeExplanation, in_call: bool | None) -> list[str]:
    texts = [explanation.bangla_message, explanation.english_message] + [r.plain_bangla for r in explanation.reasons]
    english = " ".join(texts).lower()
    en_terms = UNBACKED_CLAIMS_EN + (CALL_CLAIMS_EN if in_call is False else ())
    bn_terms = UNBACKED_CLAIMS_BN + (CALL_CLAIMS_BN if in_call is False else ())
    return [t for t in en_terms if re.search(rf"\b{re.escape(t)}\b", english)] + [t for t in bn_terms if any(t in x for x in texts)]


def validate(
    explanation: ChallengeExplanation,
    attributions: list[Attribution],
    minimum_action: Action,
    *,
    in_call: bool | None = None,
) -> None:
    """Reject a draft that invented evidence, missed material evidence, softened the action, or
    claimed something no input backs (a SIM change, proof, or a call when `in_call` is False;
    None leaves the call check out, for callers that do not know the call state).

    This is the check that gets shown on camera: an explanation is not a piece of prose we hope
    is right, it is a claim that either resolves against the attributions or does not ship.
    """
    cited = {reason.feature for reason in explanation.reasons}
    known = {a.feature for a in attributions}

    invented = cited - known
    if invented:
        raise FaithfulnessError(
            f"cited reasons with no attribution behind them: {sorted(invented)}"
        )

    material = {a.feature for a in attributions if abs(a.shap) >= MIN_CITED_SHAP}
    missed = material - cited
    if missed:
        raise FaithfulnessError(f"failed to mention material evidence: {sorted(missed)}")

    if ACTION_RANK[explanation.action] < ACTION_RANK[minimum_action]:
        raise FaithfulnessError(
            f"action {explanation.action!r} is softer than the required {minimum_action!r}"
        )

    claims = _unbacked_claims(explanation, in_call)
    if claims:
        raise FaithfulnessError(f"claims no input backs: {claims}")


def explain(
    ato_score: float,
    coaching_score: float,
    attributions: list[Attribution],
    *,
    call: GeminiCall | None = None,
    in_call: bool = False,
) -> ChallengeExplanation:
    """Produce the customer-facing explanation, or fall back to a deterministic one.

    One retry on a faithfulness failure, with the violation named in the prompt, then the
    deterministic fallback. Three reasons not to loop further: a model that has broken the
    contract twice is unlikely to fix itself on a third pass, the customer is waiting, and the
    fallback is already honest - it just reads like a machine rather than like Apa.
    """
    minimum = required_action(ato_score, coaching_score, in_call)
    if call is None:
        return _fallback(ato_score, coaching_score, attributions, minimum, in_call)

    contents = _prompt_payload(ato_score, coaching_score, attributions, minimum, in_call)
    system = FAITHFULNESS_SYSTEM_PROMPT
    for attempt in (1, 2):
        try:
            result = call(
                task="ato_explain",
                role_name="workhorse",
                contents=contents,
                schema=ChallengeExplanation,
                system=system,
            )
            explanation = getattr(result, "parsed", None)
            if not isinstance(explanation, ChallengeExplanation):
                raise FaithfulnessError("model returned no parsed explanation")
            validate(explanation, attributions, minimum, in_call=in_call)
            return explanation
        except FaithfulnessError as failure:
            if attempt == 2:
                return _fallback(ato_score, coaching_score, attributions, minimum, in_call)
            system = (
                f"{FAITHFULNESS_SYSTEM_PROMPT}\n"
                f"Your previous answer was rejected: {failure}. Correct it."
            )
        except Exception:
            # Gemini disabled, no credentials, network - the customer still gets an answer.
            return _fallback(ato_score, coaching_score, attributions, minimum, in_call)
    return _fallback(ato_score, coaching_score, attributions, minimum, in_call)


def _prompt_payload(
    ato_score: float,
    coaching_score: float,
    attributions: list[Attribution],
    minimum: Action,
    in_call: bool,
) -> str:
    import json

    return json.dumps(
        {
            "decision_inputs": {
                "ato_score": round(ato_score, 3),
                "coaching_score": round(coaching_score, 3),
                "in_call": in_call,
                "top_shap": [
                    {
                        "feature": a.feature,
                        "value": round(a.value, 3),
                        "baseline": round(a.baseline, 3),
                        "shap": round(a.shap, 3),
                    }
                    for a in attributions
                ],
            },
            "minimum_action": minimum,
        },
        ensure_ascii=False,
    )


# Plain-Bangla phrasing for the features a customer might actually be told about. Deliberately
# not generated: the fallback has to work with Gemini switched off, and these are the sentences
# a bank's own compliance team would sign off on.
FEATURE_BANGLA: dict[str, str] = {
    "pin_tap_offset_mean_px": "আপনার পিন টেপার ধরন অন্যরকম লাগছে",
    "pressure_mean": "স্ক্রিনে চাপ দেওয়ার ধরন অন্যরকম",
    "pin_pressure_mean": "পিন দেওয়ার সময় চাপের ধরন অন্যরকম",
    "imu_tilt_dominant_rad": "ফোন ধরার কোণ স্বাভাবিকের চেয়ে আলাদা",
    "imu_gyro_mag_mean": "ফোন ধরার ভঙ্গি স্বাভাবিকের চেয়ে আলাদা",
    "imu_gyro_mag_std": "হাতের নড়াচড়া স্বাভাবিকের চেয়ে আলাদা",
    "imu_accel_mag_mean": "ফোনের অবস্থান স্বাভাবিকের চেয়ে আলাদা",
    "imu_accel_mag_std": "হাতের কাঁপুনি স্বাভাবিকের চেয়ে বেশি",
    "swipe_angle_rad": "স্ক্রিনে হাত চালানোর দিক অন্যরকম",
    "swipe_length_px": "স্ক্রিনে হাত চালানোর দূরত্ব অন্যরকম",
    "swipe_start_x": "স্ক্রিন স্পর্শের জায়গা অন্যরকম",
    "swipe_start_y": "স্ক্রিন স্পর্শের জায়গা অন্যরকম",
    "swipe_end_x": "হাত চালানো শেষ হওয়ার জায়গা অন্যরকম",
    "swipe_end_y": "হাত চালানো শেষ হওয়ার জায়গা অন্যরকম",
}

HANG_UP_BANGLA = (
    "আপনি এখন একটি কলে আছেন। কেউ ফোনে বলে বলে লেনদেন করাচ্ছে কি না আমরা নিশ্চিত নই। "
    "ফোন কেটে কার্ডের পিছনের নম্বরে নিজে কল করুন।"
)

# Coaching suspected with no call established: say what was observed, nothing about calls or SIMs.
OBSERVED_COACHING_BANGLA = (
    "আপনার টাইপ করার ছন্দ আপনার স্বাভাবিক ছন্দ থেকে আলাদা লাগছে, তাই একবার আপনার পরিচয় নিশ্চিত করতে চাই। "
    "এটি একটি যাচাই, কোনো অভিযোগ নয়।"
)
OBSERVED_COACHING_ENGLISH = (
    "Your typing rhythm differed from your usual one, so we would like to confirm it is really you. "
    "This is a check, not an accusation."
)


def _fallback(
    ato_score: float,
    coaching_score: float,
    attributions: list[Attribution],
    minimum: Action,
    in_call: bool,
) -> ChallengeExplanation:
    """Deterministic explanation, used when Gemini is off or has failed the contract twice.

    Cites exactly the material attributions, so it satisfies the same validator the generated
    version has to pass. It mentions a call only when `in_call` establishes one.
    """
    material = [a for a in attributions if abs(a.shap) >= MIN_CITED_SHAP] or attributions[:1]
    reasons = [
        Reason(
            feature=a.feature,
            plain_bangla=FEATURE_BANGLA.get(a.feature, "আপনার ব্যবহারের ধরনে পরিবর্তন দেখা গেছে"),
        )
        for a in material
    ]

    if coaching_score >= COACHING_CONCERN and in_call:
        bangla = HANG_UP_BANGLA
        english = (
            "This payment is paused because the typing rhythm suggests you may be "
            "being guided by someone on a call. Please hang up and call the number on your card."
        )
    elif coaching_score >= COACHING_CONCERN:
        bangla, english = OBSERVED_COACHING_BANGLA, OBSERVED_COACHING_ENGLISH
    elif minimum == "allow":
        bangla = "সব স্বাভাবিক দেখাচ্ছে।"
        english = "Nothing unusual detected."
    else:
        bangla = "নিরাপত্তার জন্য একবার আপনার পরিচয় নিশ্চিত করতে চাই। এটি একটি যাচাই, কোনো অভিযোগ নয়।"
        english = (
            "We would like to confirm it is really you before this goes through. "
            "This is a check, not an accusation."
        )

    return ChallengeExplanation(
        action=minimum,
        bangla_message=bangla,
        english_message=english,
        reasons=reasons,
        confidence=round(float(max(ato_score, coaching_score)), 3),
    )


# The explanation's action and a rule hit's decision are different vocabularies for the same
# judgement, so the mapping lives in one place. Deriving the coaching hit's decision from the
# action rather than hardcoding it is what makes `in_call` reach the outcome: coaching alone is
# a step-up, coaching on a live call is a hold, and required_action already says so.
DECISION_FOR_ACTION: dict[str, str] = {
    "allow": "allow",
    "step_up": "step_up",
    "hold_and_callback": "hold",
    "block": "block",
}


def as_behaviour_hits(
    explanation: ChallengeExplanation, ato_score: float, coaching_score: float
) -> tuple[BehaviourHit, ...]:
    """Explanation -> the hits `rules.decide()` already knows how to fuse.

    Two separate hits rather than one blended number, because the two scores mean different
    things to the person reading the case: "we are not sure this is her" and "we think someone
    is talking her through it" call for different responses.
    """
    hits: list[BehaviourHit] = []
    bangla = explanation.bangla_message

    if ato_score >= ATO_STEP_UP:
        hits.append(
            BehaviourHit(
                code="ATO_BEHAVIOUR_MISMATCH",
                weight=round(min(ato_score, 1.0), 3),
                text_bn=bangla,
                text_en=explanation.english_message,
                decision="hold" if ato_score >= ATO_HOLD else "step_up",
            )
        )
    if coaching_score >= COACHING_CONCERN:
        hits.append(
            BehaviourHit(
                code="COACHING_SUSPECTED",
                weight=round(min(coaching_score, 1.0), 3),
                text_bn=bangla if bangla else HANG_UP_BANGLA,
                text_en=explanation.english_message,
                # Not a hardcoded hold: a hold without a live call is harsher than
                # required_action asks for, and the whole point of shared-phone inclusion is that protection must not
                # become exclusion for someone on a shared phone.
                decision=DECISION_FOR_ACTION.get(explanation.action, "step_up"),
            )
        )
    return tuple(hits)
