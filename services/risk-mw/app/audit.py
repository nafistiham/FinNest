"""Audit trail (FR-3): every scoring and intervention call is recorded.

Writes to Firestore `audit/{id}` when enabled; otherwise logs a structured line. Never raises
into the request path - a failed audit write is logged, not surfaced to the caller.
"""

from __future__ import annotations

import json
import logging
import uuid
from datetime import UTC, datetime
from functools import lru_cache
from typing import Any

from app.settings import get_settings

log = logging.getLogger("audit")
COLLECTION = "audit"


@lru_cache(maxsize=1)
def _firestore_client():
    from google.cloud import firestore

    settings = get_settings()
    return firestore.Client(project=settings.project_id or None)


def _version(outputs: dict[str, Any]) -> str:
    """The version that answered: the response's own model_version, else this build's rules and session model."""
    if isinstance(outputs, dict) and outputs.get("model_version"):
        return str(outputs["model_version"])
    from app import session_model

    return f"rules+{session_model.model_version()}"


def record(kind: str, uid: str, inputs: dict[str, Any], outputs: dict[str, Any], processing_ms: float) -> str:
    settings = get_settings()
    audit_id = str(uuid.uuid4())
    doc = {
        "id": audit_id,
        "kind": kind,
        "uid": uid,
        "inputs": inputs,
        "outputs": outputs,
        "processing_ms": round(processing_ms, 2),
        "model_version": _version(outputs),
        "service": settings.service_name,
        "at": datetime.now(UTC).isoformat(),
    }
    if not settings.firestore_enabled:
        log.info(json.dumps(doc, ensure_ascii=False))
        return audit_id
    try:
        _firestore_client().collection(COLLECTION).document(audit_id).set(doc)
    except Exception as exc:  # noqa: BLE001 - audit failure must not fail the request
        log.error("audit write failed id=%s err=%s", audit_id, exc)
    return audit_id
