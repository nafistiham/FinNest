"""The evidence ledger: what the call has shown, kept by code, not by the model.

Gemini proposes tactics with quotes, the caller's claimed identity class and the ask; the ledger keeps only what it can
verify: a tactic enters with a quote that is a substring of one of the CALLER's turns (after Unicode and space
normalisation), an ask enters only with the verified tactic that carries it, and nothing once verified is forgotten for
the rest of the call. The detector's rules and Apa's warning composer both read this, never the model's raw output, and
its hash keys the speculative pre-render. Stored as a Firestore-safe document (no array directly inside an array).
"""

from __future__ import annotations

import hashlib
import json
import re
import unicodedata
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field, replace
from typing import Any

TACTICS = ("AUTHORITY_IMPERSONATION", "URGENCY_THREAT", "SECRECY_ISOLATION", "CREDENTIAL_REQUEST",
           "PAYMENT_REDIRECTION", "REMOTE_ACCESS_REQUEST", "PRIZE_OR_REFUND_BAIT")
IDENTITIES = ("bank_mfs_staff", "govt_or_police", "relative", "courier_or_company", "unknown", "none")
ASKS = ("none", "otp", "pin", "password", "send_money", "personal_wallet_payment", "install_app", "secrecy")
# An ask is evidence only when the tactic that makes it was itself verified with a quote.
ASK_TACTIC = {"otp": "CREDENTIAL_REQUEST", "pin": "CREDENTIAL_REQUEST", "password": "CREDENTIAL_REQUEST",
              "send_money": "PAYMENT_REDIRECTION", "personal_wallet_payment": "PAYMENT_REDIRECTION",
              "install_app": "REMOTE_ACCESS_REQUEST", "secrecy": "SECRECY_ISOLATION"}
VAGUE_IDENTITIES = ("none", "unknown")
QUOTE_MAX = 200
ZERO_WIDTH = re.compile("[​‌‍﻿]")


def normalise(text: str) -> str:
    """NFC, no zero-width joiners, one space, lower-case Latin: the form quotes and turns are compared in."""
    return re.sub(r"\s+", " ", ZERO_WIDTH.sub("", unicodedata.normalize("NFC", text or ""))).strip().lower()


@dataclass(frozen=True)
class Evidence:
    tactic: str
    quote: str
    turn: int


@dataclass(frozen=True)
class Ledger:
    tactics: Mapping[str, Evidence] = field(default_factory=dict)  # first verified evidence per tactic, latched
    claimed_identity: str = "none"                                  # the first specific class wins; vague ones never overwrite it
    asks: tuple[str, ...] = ()                                      # verified asks, in the order they were first verified
    flags: tuple[str, ...] = ()                                     # code-detected markers (for example META_TALK), latched

    def merge(self, extraction: Mapping[str, Any], turns: Sequence[Mapping[str, Any]]) -> Ledger:
        """Fold one model extraction into the ledger, keeping only what the transcript proves."""
        caller = {i: normalise(str(t.get("text", ""))) for i, t in enumerate(turns) if t.get("speaker") == "caller"}
        tactics = dict(self.tactics)
        for item in extraction.get("tactics") or ():
            name, quote = str(item.get("tactic", "")), str(item.get("quote", ""))[:QUOTE_MAX]
            if name not in TACTICS or name in tactics or not (needle := normalise(quote)):
                continue
            hit = next((i for i, text in caller.items() if needle in text), None)
            if hit is not None:
                tactics[name] = Evidence(name, quote.strip(), hit)
        identity = str(extraction.get("claimed_identity", "none"))
        if identity not in IDENTITIES or (identity in VAGUE_IDENTITIES and self.claimed_identity != "none"):
            identity = self.claimed_identity
        elif self.claimed_identity not in VAGUE_IDENTITIES:
            identity = self.claimed_identity
        asks = list(self.asks)
        ask = str(extraction.get("ask", "none"))
        if ask in ASK_TACTIC and ASK_TACTIC[ask] in tactics and ask not in asks:
            asks.append(ask)
        return replace(self, tactics=tactics, claimed_identity=identity, asks=tuple(asks))

    def with_flag(self, flag: str) -> Ledger:
        return self if flag in self.flags else replace(self, flags=(*self.flags, flag))

    def distinct_tactics(self) -> int:
        return len(self.tactics)

    def to_doc(self) -> dict[str, Any]:
        return {"tactics": [{"tactic": e.tactic, "quote": e.quote, "turn": e.turn} for e in self.tactics.values()],
                "claimed_identity": self.claimed_identity, "asks": list(self.asks), "flags": list(self.flags)}

    @classmethod
    def from_doc(cls, doc: Mapping[str, Any] | None) -> Ledger:
        doc = doc or {}
        tactics = {e["tactic"]: Evidence(e["tactic"], e.get("quote", ""), int(e.get("turn", 0)))
                   for e in doc.get("tactics") or () if isinstance(e, Mapping) and e.get("tactic") in TACTICS}
        identity = doc.get("claimed_identity", "none")
        return cls(tactics=tactics, claimed_identity=identity if identity in IDENTITIES else "none",
                   asks=tuple(a for a in doc.get("asks") or () if a in ASK_TACTIC), flags=tuple(doc.get("flags") or ()))

    def hash(self, pending_action: str | None = None, band: str | None = None) -> str:
        """What a warning is written from: the tactic set, the asks, the identity class, the flags, the pending action and
        the certainty band. Quotes and turns are left out, so a re-worded repeat of the same evidence keeps the hash."""
        material = {"tactics": sorted(self.tactics), "asks": list(self.asks), "identity": self.claimed_identity,
                    "flags": sorted(self.flags), "pending": pending_action, "band": band}
        return hashlib.sha1(json.dumps(material, sort_keys=True).encode()).hexdigest()[:16]
