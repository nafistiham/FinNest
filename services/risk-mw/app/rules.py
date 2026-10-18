"""Deterministic rules (FR-2). Pure functions: no I/O, no mutation.

Rules run before any model; the final risk is max(rules, model) and the decision is the
most severe decision any rule asked for. Every reason carries Bangla and English text so
the app never has to compose copy.
"""

from __future__ import annotations

from dataclasses import dataclass

from app import appsafety_text, payee as payee_text
from app.contracts import Action, Band, Decision, Reason, ScoreRequest, ScoreResponse, Txn, TxnType
from app.payee import PayeeScreen
from app.settings import Settings

DECISION_RANK: dict[Decision, int] = {"allow": 0, "step_up": 1, "delay": 2, "hold": 3, "block": 4}

WEIGHT_CALL_ACTIVE = 0.90
WEIGHT_SIM_CHANGED = 0.85
WEIGHT_NEW_PAYEE = 0.60
WEIGHT_APP_SAFETY_BLOCK = 0.95
WEIGHT_SCREEN_SHARE = 0.50
SCAM_SCORE_HOLD_THRESHOLD = 0.70
# Spec US-2: the transactional triggers a scam conversation holds; the classifier's recommended_action reads the same tuple.
SCAM_HOLD_TXN_TYPES: tuple[TxnType, ...] = ("pin_reset", "new_payee", "send_money")


@dataclass(frozen=True)
class RuleHit:
    reason: Reason
    decision: Decision


def _hit(code: str, weight: float, text_bn: str, text_en: str, decision: Decision) -> RuleHit:
    return RuleHit(Reason(code=code, weight=round(weight, 3), text_bn=text_bn, text_en=text_en), decision)


def evaluate(req: ScoreRequest, p95_amount_bdt: float, settings: Settings, payee: PayeeScreen | None = None,
             stored_app_safety_risk: float | None = None, app_safety_facts: tuple[str, ...] = ()) -> tuple[RuleHit, ...]:
    """Return every rule that fires for this request, in evaluation order.

    `payee` is the mule screen of txn.to_account; it only words DEST_MULE_RISK, whose firing is decided by
    the fused demo_flags.inbound_mule_score like every other rule. `stored_app_safety_risk` is the risk of this
    instance's own App Safety verdict when that verdict is CAUTION; it weighs APP_SAFETY_CAUTION with the phone's copy.
    `app_safety_facts` are the phone facts behind the verdict (app.warnings.signals.phone_facts); they word
    APP_SAFETY_BLOCK, whose firing is decided by the fused verdict alone.
    """
    flags, txn = req.demo_flags, req.txn
    hits: list[RuleHit] = []

    if txn.type == "pin_reset" and flags.call_active and not flags.caller_in_contacts:
        hits.append(_hit(
            "CALL_ACTIVE_NON_CONTACT", WEIGHT_CALL_ACTIVE,
            "আপনি এখন এমন একটি নম্বরের সাথে কলে আছেন যা আপনার কন্টাক্টে নেই। কলে থাকা অবস্থায় পিন বদলানো নিরাপদ নয়।",
            "You are on a call with a number not in your contacts. Changing your PIN during a call is not safe.",
            "hold",
        ))
    if flags.sim_swap:
        hits.append(_hit(
            "SIM_CHANGED_24H", WEIGHT_SIM_CHANGED,
            f"গত {settings.sim_change_hold_hours} ঘণ্টার মধ্যে আপনার সিম পরিবর্তন হয়েছে।",
            f"Your SIM changed within the last {settings.sim_change_hold_hours} hours.",
            "hold",
        ))
    if txn.is_new_payee and txn.amount_bdt > p95_amount_bdt:
        hits.append(_hit(
            "NEW_PAYEE_ABOVE_P95", WEIGHT_NEW_PAYEE,
            "নতুন একজন প্রাপকের কাছে আপনার স্বাভাবিকের চেয়ে বড় অঙ্কের টাকা পাঠানো হচ্ছে।",
            "This is a first payment to a new payee and larger than your usual amount.",
            "delay",
        ))
    if flags.app_safety_verdict == "BLOCK":
        # The overlay shows this text verbatim: it names what was found (appsafety_text), not always a screen-control app.
        hits.append(_hit("APP_SAFETY_BLOCK", WEIGHT_APP_SAFETY_BLOCK, *appsafety_text.block_text(app_safety_facts), "block"))
    if flags.app_safety_verdict == "CAUTION":
        # The App Safety Check found something worth a look but not a block. It raises the risk score and names
        # the reason; it never changes the decision by itself. Weighed by the source(s) that said CAUTION, capped below
        # band_high (D2): an allowed transfer never reads "high".
        phone = req.app_safety.risk_score if req.app_safety is not None and req.app_safety.verdict == "CAUTION" else None
        risks = [r for r in (phone, stored_app_safety_risk) if r is not None]
        weight = max(risks) if risks else settings.app_safety_caution_default_weight
        hits.append(_hit(
            "APP_SAFETY_CAUTION", max(0.0, min(settings.app_safety_caution_weight_cap, weight)),
            "আপনার ফোনে একটি সন্দেহজনক অ্যাপ পাওয়া গেছে। ফোনের নিরাপত্তা দেখে নিন।",
            "A suspicious app was found on your phone. Check the phone safety page.",
            "allow",
        ))
    if flags.inbound_mule_score > settings.mule_hold_threshold:
        hits.append(_hit("DEST_MULE_RISK", flags.inbound_mule_score, *payee_text.reason_text(payee, settings.mule_hold_threshold), "hold"))
    if flags.screen_share:
        hits.append(_hit(
            "SCREEN_SHARE_ACTIVE", WEIGHT_SCREEN_SHARE,
            "আপনার স্ক্রিন এখন শেয়ার হচ্ছে। অন্য কেউ আপনার পিন দেখে ফেলতে পারে।",
            "Your screen is being shared. Someone else may see your PIN.",
            "step_up",
        ))
    if flags.scam_score >= SCAM_SCORE_HOLD_THRESHOLD and txn.type in SCAM_HOLD_TXN_TYPES:
        hits.append(_hit(
            "SCAM_CONVERSATION", flags.scam_score,
            "চলমান কথোপকথনে প্রতারণার লক্ষণ পাওয়া গেছে। লেনদেনটি এখন না করাই নিরাপদ।",
            "The ongoing conversation shows signs of a scam. It is safer not to proceed now.",
            "hold",
        ))
    return tuple(hits)


WEIGHT_MONEY_LOCK = 0.70


def model_hit(score: float) -> RuleHit:
    """The session model alone is never enough to hold money; it can ask for a passkey step-up."""
    return _hit(
        "MODEL_RISK", score,
        "এই সেশনের ধরন অস্বাভাবিক মনে হচ্ছে। নিশ্চিত হতে আপনার পাসকি দিয়ে যাচাই করুন।",
        "This session looks unusual. Please confirm with your passkey.",
        "step_up",
    )


def money_lock_hit() -> RuleHit:
    """The customer locked her money (Money Lock); a send waits until she unlocks it."""
    return _hit(
        "MONEY_LOCK_ACTIVE", WEIGHT_MONEY_LOCK,
        "আপনি নিজে টাকা লক করে রেখেছেন। পাঠাতে চাইলে আগে লক খুলুন।",
        "You have locked your money. Unlock it first if you want to send.",
        "hold",
    )


def band_for(score: float, settings: Settings) -> Band:
    if score >= settings.band_critical:
        return "critical"
    if score >= settings.band_high:
        return "high"
    if score >= settings.band_medium:
        return "medium"
    return "low"


def actions_for(decision: Decision, txn: Txn, settings: Settings) -> tuple[Action, ...]:
    trusted = Action(type="trusted_contact_check", params={"expires_in_minutes": settings.trusted_contact_expiry_minutes})
    if decision == "block":
        return (Action(type="block_transaction", params={"reason": "app_safety"}),)
    if decision == "hold":
        primary = (
            Action(type="freeze_pin_reset", params={"minutes": settings.pin_reset_freeze_minutes})
            if txn.type == "pin_reset"
            else Action(type="hold_transaction", params={"minutes": settings.pin_reset_freeze_minutes})
        )
        return (primary, trusted)
    if decision == "delay":
        return (Action(type="delay_new_payee", params={"minutes": settings.new_payee_delay_minutes}), trusted)
    if decision == "step_up":
        return (Action(type="step_up_verification", params={"method": "passkey"}),)
    return ()


def decide(
    req: ScoreRequest, hits: tuple[RuleHit, ...], model_score: float, model_version: str, settings: Settings, payee: PayeeScreen | None = None,
) -> ScoreResponse:
    """Fuse rule hits with the model score into the response contract; `payee` adds the two payee scores."""
    decision: Decision = max((h.decision for h in hits), key=lambda d: DECISION_RANK[d], default="allow")
    risk = max((h.reason.weight for h in hits), default=0.0)
    risk = round(max(risk, model_score), 3)
    return ScoreResponse(
        decision=decision,
        risk_score=risk,
        band=band_for(risk, settings),
        reasons=tuple(h.reason for h in hits),
        actions=actions_for(decision, req.txn, settings),
        model_version=model_version,
        **payee_text.response_fields(payee),
    )
