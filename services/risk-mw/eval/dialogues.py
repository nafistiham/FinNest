"""The labelled Bangla/Banglish dialogue set (spec section 7).

Gemini writes varied phone-call transcripts for each scam archetype and each hard benign look-alike,
in Bangla script and in Banglish; code assigns the labels it asked for (never the model's), timestamps,
ids, removes near-duplicates and holds out a stratified 50. A human should spot-check 20%.
"""

from __future__ import annotations

import hashlib
import re
from typing import Literal

from pydantic import BaseModel, Field

# The generated dialogues are detector inputs. Real brand names are kept only so the detector can recognise them.
ARCHETYPES = {
    "fake_customer_care": "a caller posing as bank, bKash, Nagad or 'customer care' staff who threatens that the account will be blocked or closed unless the user acts now",
    "otp_pin_harvest": "a caller who gets the user to read out an OTP, verification code, PIN or password (often for a 'verification', 'update' or 'PIN reset')",
    "lottery_prize": "a caller announcing a lottery, prize, reward or gift that needs a fee or a send-money first",
    "wrong_send_refund": "a caller claiming they sent money to the user's number by mistake and pressing for it to be sent back",
    "job_loan_fee": "a caller offering a loan, job, scholarship or government stipend that needs an upfront registration or processing fee",
    "relative_impersonation": "a caller claiming to be a son, brother or other relative on a new number, in trouble, asking for money urgently and for secrecy",
}
BENIGN = {
    "benign_bank_call": "a genuine bank or wallet help-line call (follow-up on a complaint, card delivery, a reminder) that never asks for a PIN, OTP or password",
    "benign_relative": "a real relative or friend asking for or returning money in an ordinary, unpressured way with shared context",
    "benign_delivery": "a courier at the door who needs the delivery code shown in the user's app to hand over a parcel",
    "benign_merchant": "a shopkeeper or merchant confirming a payment or an order the user really placed",
    "benign_salary": "an employer, office or family member coordinating a salary, remittance or bill payment the user expects",
    "benign_agent": "a mobile-money agent or shop helping with a cash-in or cash-out the user asked for, without asking for secrets",
    "benign_recharge": "a telecom or utility reminder about a recharge, bill or package, with no request for codes or money transfers to a person",
}
CHANNELS = {"bangla": "Bangla script", "banglish": "Banglish (Bangla written in Latin letters, mixed with English words)"}
TS_STEP = 6.0


class GenTurn(BaseModel):
    speaker: Literal["caller", "user"]
    text: str


class GenDialogue(BaseModel):
    requested_secret: Literal["none", "otp", "pin", "password", "other"]
    first_detectable_turn: int = Field(description="0-based index of the first turn where a careful listener could tell it is this pattern")
    turns: list[GenTurn]


class GenBatch(BaseModel):
    dialogues: list[GenDialogue]


GEN_SYSTEM = """You write realistic, varied phone-call transcripts between a CALLER and a USER (a customer of a Bangladeshi mobile-money
bank) for training and testing a scam detector. Ground them in documented Bangladeshi scam and everyday call patterns.
Vary names, providers (bKash, Nagad, Rocket, the bank), amounts in Taka, reasons, tone and length (4 to 8 turns,
starting with the caller, mostly alternating). Never use real phone numbers. Write natural speech, not textbook prose."""


def gen_prompt(kind: str, description: str, channel: str, n: int, label: str) -> str:
    what = "a scam" if label == "scam" else "an ordinary, legitimate call that a naive detector might wrongly flag"
    return (f"Write {n} different transcripts of {what}: {description}.\n"
            f"Language: {CHANNELS[channel]}.\n"
            f"Make the {n} transcripts differ in scenario details and wording; about a third should be subtle.\n"
            f"For each, set requested_secret to what the caller asks for, and first_detectable_turn to the 0-based index of the "
            f"first turn where a careful listener could recognise it ({kind}).")


def _norm(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip().lower()


def to_rows(gen: GenBatch, archetype: str, channel: str, label: str, batch: str = "", seen: set[str] | None = None) -> list[dict]:
    """Labelled rows from one generated batch; near-duplicates (same words up to spacing and case) are dropped."""
    seen = set() if seen is None else seen
    rows = []
    for i, d in enumerate(gen.dialogues):
        turns = [t for t in d.turns if t.text.strip()]
        key = "|".join(_norm(t.text) for t in turns)
        if not turns or key in seen:
            continue
        seen.add(key)
        caller_idx = [k for k, t in enumerate(turns) if t.speaker == "caller"] or [0]
        first = None if label == "benign" else (d.first_detectable_turn if 0 <= d.first_detectable_turn < len(turns) else caller_idx[0])
        rows.append({"id": f"{archetype}-{channel}-{batch}-{i:02d}-" + hashlib.sha1(key.encode()).hexdigest()[:6],
                     "label": label, "archetype": archetype, "channel": channel, "requested_secret": d.requested_secret,
                     "first_detectable_turn": first, "turns": [{"speaker": t.speaker, "text": t.text.strip(), "ts": k * TS_STEP} for k, t in enumerate(turns)]})
    return rows


def split(rows: list[dict], held_out: int = 50, scam_share: float = 0.6) -> list[dict]:
    """Mark a stratified, deterministic held-out set: scams spread evenly over archetypes, benign over types."""
    def order(r: dict) -> str:
        return hashlib.sha1(r["id"].encode()).hexdigest()

    chosen: set[str] = set()
    for label, quota in (("scam", round(held_out * scam_share)), ("benign", held_out - round(held_out * scam_share))):
        groups: dict[str, list[dict]] = {}
        for r in sorted((r for r in rows if r["label"] == label), key=order):
            groups.setdefault(r["archetype"], []).append(r)
        names, k = sorted(groups), 0
        while quota > 0 and any(groups.values()):
            g = groups[names[k % len(names)]]
            if g:
                chosen.add(g.pop(0)["id"])
                quota -= 1
            k += 1
    return [{**r, "split": "held_out" if r["id"] in chosen else "dev"} for r in rows]
