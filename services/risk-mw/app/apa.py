"""Apa's guard rails (spec US-3, FR-4): what she may never say, the hold card's layout, and the token that lets
/v1/apa/why-audio speak only text this server wrote.

Apa has no fixed lines (P0 item 5). Every word she speaks is generated for the call by app.warnings and validated there;
when nothing validates, the floor is an earcon, vibration and the hold card, with no words. The checks below are the base
that validator extends (tts.speakable reuses them too). Apa never speaks a duration: the card can show the timer, but a
scammer listening on speaker should not hear when the money moves.
"""

from __future__ import annotations

import hashlib
import hmac
import re
import secrets
import time
from datetime import UTC, datetime

from app.contracts import UiMode
from app.settings import Settings

WHY_MAX_CHARS = 240
WARNING_MAX_CHARS = 600  # a whole warning (up to four validated lines), spoken in one TTS request
DIGITS = re.compile(r"[0-9০-৯]")
IDS = re.compile(r"\b[a-z]+_[A-Za-z0-9-]+\b")
DURATION_WORDS = re.compile(r"ঘণ্টা|ঘন্টা|মিনিট|সেকেন্ড|সপ্তাহ|\b(hour|hours|minute|minutes|second|seconds)\b", re.IGNORECASE)
TIP_OFF_WORDS = re.compile(r"চক্র|তদন্ত|মামলা|বিশ্লেষক|\b(ring|rings|case|cases|investigat\w*|analyst|watch-?list|mule\w*)\b", re.IGNORECASE)

# --- the hold card's layout per reason (interface, not words) ------------------------------------------------------------

FULLSCREEN = frozenset(("CALL_ACTIVE_NON_CONTACT", "SIM_CHANGED_24H", "APP_SAFETY_BLOCK", "DEST_MULE_RISK", "SCREEN_SHARE_ACTIVE",
                        "SCAM_CONVERSATION", "MONEY_LOCK_ACTIVE", "COACHING_SUSPECTED"))  # the holds that interrupt
LEGACY_TRIGGERS = {"call_active": "CALL_ACTIVE_NON_CONTACT", "screen_share": "SCREEN_SHARE_ACTIVE", "new_payee_high_amount": "NEW_PAYEE_ABOVE_P95",
                   "sim_swap": "SIM_CHANGED_24H", "scam_conversation": "SCAM_CONVERSATION", "mule": "DEST_MULE_RISK", "app_safety": "APP_SAFETY_BLOCK"}
COLD_START_SUFFIX = "_COLD_START"  # app.ato marks a non-personalised identity verdict this way; the card is the same


def reason_code(trigger: str) -> str:
    """The rule's reason code for a trigger: old trigger names and the cold-start variant map to the code."""
    trigger = trigger.removesuffix(COLD_START_SUFFIX)
    return LEGACY_TRIGGERS.get(trigger, trigger)


def ui_for(trigger: str) -> UiMode:
    """Full screen for the holds that interrupt; a banner for a delay, a passkey step-up and a reason this table does not know."""
    return "fullscreen" if reason_code(trigger) in FULLSCREEN else "banner"


# --- why tokens: /v1/apa/why-audio speaks only lines this server validated ----------------------------------------------

_PROCESS_SECRET = secrets.token_bytes(32)  # when RISK_MW_APA_TOKEN_SECRET is empty; good for one instance only


def _mac(text_bn: str, expires: int, settings: Settings) -> str:
    key = settings.apa_token_secret.encode() if settings.apa_token_secret else _PROCESS_SECRET
    return hmac.new(key, f"apa-why|{expires}|{text_bn}".encode(), hashlib.sha256).hexdigest()


def sign_why(text_bn: str, settings: Settings, now: float | None = None) -> tuple[str, datetime]:
    """A token for this exact text: '<expiry, unix seconds>.<HMAC-SHA256 over the expiry and the text>', and the expiry."""
    expires = int(time.time() if now is None else now) + settings.apa_token_ttl_s
    return f"{expires}.{_mac(text_bn, expires, settings)}", datetime.fromtimestamp(expires, UTC)


def verify_why(text_bn: str, token: str | None, settings: Settings, now: float | None = None) -> bool:
    expires, _, mac = (token or "").partition(".")
    if not (expires.isascii() and expires.isdigit() and mac) or int(expires) <= (time.time() if now is None else now):
        return False
    return hmac.compare_digest(mac, _mac(text_bn, int(expires), settings))
