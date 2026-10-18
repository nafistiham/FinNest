"""The scam classifier that answers when Gemini is off, over budget or failed. Pure: no I/O.

A secret word alone is not a request: "Never share your OTP" is the bank's own advice. A secret counts only when a
caller turn has, in the same sentence, a request verb that no negation cancels: a negation word earlier in the verb's
clause ("never", "don't", "কখনো"; but not "if you don't give me...", which is a threat), or "না" right after a future
or prohibitive form ("বলবেন না" = don't tell). After an imperative "না" coaxes rather than refuses ("বলুন না" = do
tell), so it is still a request. The pressure and authority cues are unchanged. Every answer is marked model_version
"stub-fallback" with a fixed fallback_reason code (genai_client.FALLBACK_CODES), so a client and the audit row can tell.
"""

from __future__ import annotations

import re
import unicodedata
from collections.abc import Iterable

from app.contracts import ScamTurnRequest, ScamTurnResponse

STUB_MODEL_VERSION = "stub-fallback"  # the marker /v1/investigate's stub uses too

SECRET_TERMS: dict[str, tuple[str, ...]] = {
    "otp": ("ওটিপি", "otp", "কোড", "code"),
    "pin": ("পিন", "pin"),
    "password": ("পাসওয়ার্ড", "password", "passcode"),
}
REQUEST_VERBS = frozenset({
    "বলুন", "বলেন", "বলবেন", "বলো", "দিন", "দেন", "দিবেন", "দেবেন", "দাও", "পাঠান", "পাঠাবেন", "পাঠিয়ে", "জানান", "জানাবেন", "শেয়ার",
    "bolun", "bolen", "bolben", "bolo", "din", "den", "diben", "deben", "dao", "pathan", "pathaben",  # Banglish
    "share", "tell", "give", "read", "send", "say", "provide", "need", "confirm", "verify",
})
REQUEST_PHRASES: tuple[tuple[str, ...], ...] = (
    ("what", "is", "your"), ("what's", "your"),
    ("বলতে", "হবে"), ("দিতে", "হবে"), ("পাঠাতে", "হবে"), ("জানাতে", "হবে"), ("bolte", "hobe"), ("dite", "hobe"),  # obligation
)
NEGATIONS_BEFORE = frozenset({"never", "don't", "dont", "not", "কখনো", "কখনোই", "কখনও", "কখনই", "kokhono"})
CONDITIONAL = "if"  # "if you don't give me the OTP ..." is a threat, not advice
NEGATIONS_AFTER = frozenset({"না", "na"})
# Only after these does "না" refuse: future and prohibitive forms ("বলবেন না", "শেয়ার করবেন না", "বলতে হবে না").
PROHIBITIVE_FORMS = frozenset({
    "বলবেন", "দিবেন", "দেবেন", "পাঠাবেন", "করবেন", "জানাবেন", "হবে",
    "bolben", "diben", "deben", "pathaben", "korben", "hobe",
})
NEGATION_AFTER_WINDOW = 2  # the verb, an auxiliary (করবেন, হবে), then না
URGENCY_WORDS = ("বন্ধ", "ব্লক", "এখনই", "এক্ষুনি", "block", "now", "immediately", "suspend")
AUTHORITY_WORDS = ("কাস্টমার কেয়ার", "হেড অফিস", "customer care", "head office", "bank")
CONFIDENCE_SECRET = 0.85
CONFIDENCE_PRESSURE = 0.55
CONFIDENCE_NONE = 0.05

_SENTENCE_BREAK = re.compile(r"[.!?।;\n]+")
_CLAUSE_BREAK = re.compile(r"[,،]+")
_TOKEN = re.compile(r"[^\s.,!?।;:\"“”()\[\]{}/…\-]+")


def _normalise(text: str) -> str:
    # NFC so a য় typed as one code point or as য + nukta compares equal; a curly apostrophe reads as a straight one.
    return unicodedata.normalize("NFC", text).replace("’", "'").lower()


def _nfc_all(words: Iterable[str]) -> frozenset[str]:
    return frozenset(_normalise(w) for w in words)


_VERBS, _NEGATIONS = _nfc_all(REQUEST_VERBS), _nfc_all(NEGATIONS_BEFORE)
_NEGATIONS_AFTER, _PROHIBITIVE = _nfc_all(NEGATIONS_AFTER), _nfc_all(PROHIBITIVE_FORMS)
_PHRASES = tuple(tuple(_normalise(w) for w in phrase) for phrase in REQUEST_PHRASES)
_SECRETS = {kind: tuple(_normalise(t) for t in terms) for kind, terms in SECRET_TERMS.items()}


def _tokens(text: str) -> list[str]:
    return [t.strip("'") for t in _TOKEN.findall(text) if t.strip("'")]


def _is_secret(token: str, term: str) -> bool:
    # Bangla nouns take suffixes (ওটিপিটা, পিনটা, কোডটি); English must match the whole word ("pin" is not "spinning").
    return token == term if term.isascii() else token.startswith(term)


def _first_secret(tokens: list[str]) -> str | None:
    for token in tokens:
        for kind, terms in _SECRETS.items():
            if any(_is_secret(token, term) for term in terms):
                return kind
    return None


def _request_positions(tokens: list[str]) -> list[int]:
    singles = [i for i, t in enumerate(tokens) if t in _VERBS]
    phrases = [i for i in range(len(tokens)) for p in _PHRASES if tuple(tokens[i:i + len(p)]) == p]
    return singles + phrases


def _refused_after(tokens: list[str], at: int) -> bool:
    """"না" within the window after the request refuses only when a future or prohibitive form precedes it."""
    window = tokens[at:at + 1 + NEGATION_AFTER_WINDOW]
    cut = next((i for i, t in enumerate(window) if t in _NEGATIONS_AFTER), None)
    return cut is not None and any(t in _PROHIBITIVE for t in window[:cut])


def _negated(tokens: list[str], at: int) -> bool:
    before = [i for i, t in enumerate(tokens[:at]) if t in _NEGATIONS]
    threat = bool(before) and CONDITIONAL in tokens[:before[0]]
    return (bool(before) and not threat) or _refused_after(tokens, at)


def _live_request(clause: list[str]) -> bool:
    return any(not _negated(clause, i) for i in _request_positions(clause))


def requested_secret(text: str) -> str | None:
    """The secret one caller turn asks for (otp | pin | password), or None when it only names one."""
    for sentence in _SENTENCE_BREAK.split(_normalise(text)):
        clauses = [_tokens(c) for c in _CLAUSE_BREAK.split(sentence)]
        secret = _first_secret([t for clause in clauses for t in clause])
        if secret and any(_live_request(clause) for clause in clauses):
            return secret
    return None


def _mentions(text: str, words: tuple[str, ...]) -> bool:
    lowered = text.lower()
    return any(w in lowered for w in words)


def classify(body: ScamTurnRequest, fallback_reason: str) -> ScamTurnResponse:
    """The stub's answer for the caller's turns, marked as the fallback with `fallback_reason`."""
    caller = [t.text for t in body.turns if t.speaker == "caller"]
    asking = next(((text, kind) for text in reversed(caller) if (kind := requested_secret(text))), None)
    secret = asking[1] if asking else None
    caller_text = " ".join(caller)
    pressure, authority = _mentions(caller_text, URGENCY_WORDS), _mentions(caller_text, AUTHORITY_WORDS)
    confidence = CONFIDENCE_SECRET if secret else (CONFIDENCE_PRESSURE if pressure or authority else CONFIDENCE_NONE)
    return ScamTurnResponse(
        scam_type="fake_customer_care" if (secret or authority) else ("pressure" if pressure else "benign"),
        urgency="high" if (secret and pressure) else ("medium" if pressure else "none"),
        requested_secret=secret or "none",
        confidence=confidence,
        evidence_quote=asking[0] if asking else (caller[-1] if caller else ""),
        recommended_action="hold_and_warn" if secret else ("warn" if pressure else "none"),
        rolling_score=confidence,  # one request decides: no average across requests and no hysteresis
        model_version=STUB_MODEL_VERSION,
        fallback_reason=fallback_reason,
    )
