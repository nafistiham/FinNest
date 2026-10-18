"""Per-user p95 send amount for NEW_PAYEE_ABOVE_P95.

The seed's accounts.jsonl rows carry no amount profile; the per-persona p95 lives in the seed loader's PERSONAS, which
writes it to Firestore users/{uid}. config/personas.json mirrors those rows (a test keeps them in step) so the score
path reads it offline, by uid ("rina") or by account id ("acct_rina", what the app's persona picker sends). Anyone
else gets RISK_MW_DEFAULT_P95_AMOUNT_BDT. A missing or unreadable file degrades to the default, never to an error.
"""

from __future__ import annotations

import json
import logging
from functools import lru_cache
from pathlib import Path
from types import MappingProxyType
from typing import Mapping

from app.settings import Settings

log = logging.getLogger(__name__)


@lru_cache(maxsize=1)
def _load(path: Path) -> Mapping[str, float]:
    try:
        rows = json.loads(path.read_text(encoding="utf-8"))["personas"]
        pairs = tuple(
            (key, float(row["p95_send_bdt"])) for row in rows for key in (str(row["uid"]), str(row["acct_id"]))
        )
    except (OSError, ValueError, KeyError, TypeError) as exc:
        log.error("persona table %s unreadable (%s); every user gets the default p95", path, exc)
        return MappingProxyType({})
    return MappingProxyType(dict(pairs))


def table(settings: Settings) -> Mapping[str, float]:
    """uid and account id -> p95 send amount, read once."""
    return _load(Path(settings.personas_path))


def p95_amount_for(user_id: str, settings: Settings) -> float:
    return table(settings).get(user_id, settings.default_p95_amount_bdt)


@lru_cache(maxsize=1)
def _accounts(path: Path) -> Mapping[str, str]:
    try:
        pairs = tuple((str(row["uid"]), str(row["acct_id"])) for row in json.loads(path.read_text(encoding="utf-8"))["personas"])
    except (OSError, ValueError, KeyError, TypeError) as exc:
        log.error("persona table %s unreadable (%s); no persona uid maps to an account", path, exc)
        return MappingProxyType({})
    return MappingProxyType(dict(pairs))


def account_for(uid: str, settings: Settings) -> str | None:
    """The account a persona uid pays from ("rina" -> "acct_rina"), from the same table; None for anyone else."""
    return _accounts(Path(settings.personas_path)).get(uid)


def uid_for_account(acct_id: str, settings: Settings) -> str | None:
    """The persona uid behind an account ("acct_rina" -> "rina"): Case Zero asks by account, the app checks by uid."""
    return next((uid for uid, acct in _accounts(Path(settings.personas_path)).items() if acct == acct_id), None)
