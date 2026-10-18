"""Case ids: CZ- and ten random base32 characters, so a case cannot be found by counting."""

from __future__ import annotations

import secrets

CASE_ID_PREFIX = "CZ-"
CASE_ID_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"   # RFC 4648 base32, 5 bits a character
CASE_ID_LENGTH = 10                                       # 50 bits


def new_case_id() -> str:
    """CZ- and ten characters, each drawn on its own with secrets.choice from the 32-character alphabet.

    Each character is uniform over the alphabet and independent of the others, so an id carries the full 50 bits."""
    return CASE_ID_PREFIX + "".join(secrets.choice(CASE_ID_ALPHABET) for _ in range(CASE_ID_LENGTH))
