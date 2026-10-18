"""The live audit trail: every call risk-mw actually answered.

risk-mw runs with RISK_MW_FIRESTORE_ENABLED=true, so every score, signal bundle, scam turn,
app-safety check and intervention is written to audit/{id} with the request as sent, the response
as returned, the time it took and the model version that produced it. Nobody has ever read it.

This is a different thing from the replay the rest of the console is built on. The replay says what
the engine would decide about the seed world - deterministic, the same 2,330 rows every time, and
only two of the nine rule codes able to fire. This says what happened: who called, with what flags,
and what came back. Call state, SIM swaps and scam scores are in here, so all nine codes appear.

Reading is index-free on purpose. Ordering by `at` uses the single-field index Firestore creates
itself; filtering by kind or decision on top of that would need a composite index, and building one
under a deadline is a bad trade for a facet we can apply to the page we already fetched.
"""

from __future__ import annotations

import logging
import os
import time
from functools import lru_cache
from typing import Any

log = logging.getLogger("audit")

# The Google Cloud project that holds risk-mw's Firestore audit collection. Unset means the client
# library's own default (GOOGLE_CLOUD_PROJECT or the application-default credentials).
PROJECT = os.environ.get("PROJECT_ID") or os.environ.get("GOOGLE_CLOUD_PROJECT") or None
COLLECTION = "audit"
DEFAULT_LIMIT = 300
MAX_LIMIT = 1000
# The console polls every five seconds to feel live, so the cache has to be shorter than that
# or half the polls would return the same page twice. Three seconds still absorbs a burst of
# tabs without turning each one into its own Firestore read.
CACHE_TTL_S = 3

_cache: dict[str, tuple[float, Any]] = {}

# What the drawer must not hand out by default. Field names, not paths, because the same name
# means the same thing wherever in a document it appears.
PHONE_FIELDS = frozenset({"caller_number", "phone", "msisdn", "to_msisdn"})
TEXT_FIELDS = frozenset({"text", "transcript", "snippet", "utterance", "message", "prompt", "reply"})
LONG_LISTS = frozenset({"installed_apps", "features", "feature_vector", "packages"})
DROPPED = frozenset({"integrity_token", "id_token", "attestation", "nonce"})
# ...except an `attestation` that is one of these words. In an audit row that key holds the level risk-mw reduced
# the Play Integrity verdict to (bhorosha_app_safety_check.integrity.AttestationLevel), never the token itself: the token
# travels as `integrity_token` and stays hidden. A level is a conclusion, not a credential (nothing can be replayed with
# "tampered"), and it is what an operator needs to read a block: it decides whether a re-check may lift one. Anything
# else stored under the key, such as a raw attestation blob, is still hidden. Copied, because the deployed console does
# not ship the check's package; tests/test_audit.py enumerates the check's own list against this one.
ATTESTATION_LEVELS = frozenset({"none", "failed", "tampered", "mismatch", "unbound", "virtual", "basic", "device", "strong"})
TEXT_KEEP = 40


class AuditUnavailable(RuntimeError):
    """Firestore could not be read. The console says why rather than showing an empty table."""


@lru_cache(maxsize=1)
def _client() -> Any:
    """One client for the process.

    It was being constructed on every cache miss and every drawer open and never closed, which
    leaks a gRPC channel per call. risk-mw's own `app/audit.py` caches it the same way.
    """
    try:
        from google.cloud import firestore
    except ImportError as exc:  # pragma: no cover - the dependency is in requirements
        raise AuditUnavailable("google-cloud-firestore is not installed") from exc
    try:
        return firestore.Client(project=PROJECT)
    except Exception as exc:  # noqa: BLE001 - every credential failure looks different
        raise AuditUnavailable(
            f"no credentials for Firestore ({type(exc).__name__}). "
            "On Cloud Run this is the service account; locally, run "
            "`gcloud auth application-default login`."
        ) from exc


def _first(value: Any, *path: str, default: Any = None) -> Any:
    for key in path:
        if not isinstance(value, dict):
            return default
        value = value.get(key)
    return default if value is None else value


# Exactly the paths `flatten` reads. Without a projection, listing the log pulls every document
# whole - an `appsafety` row carries up to five hundred installed packages, a `signals` row a
# feature vector - to build a seventeen-field table row. Firestore charges for the document, not
# for what you use, but the bytes still cross the wire on every poll from every open tab.
ROW_FIELDS: tuple[str, ...] = (
    "id", "at", "kind", "uid", "service", "model_version", "processing_ms",
    "outputs.decision", "outputs.band", "outputs.risk_score", "outputs.reasons",
    "outputs.verdict", "outputs.scam_type", "outputs.recommended_action",
    "inputs.session_id", "inputs.demo_flags",
    "inputs.txn.type", "inputs.txn.amount_bdt", "inputs.txn.to_account",
)


def _flags(flags: dict[str, Any]) -> list[str]:
    """Every demo flag that is not at its default, as `name` or `name=value`.

    False, None and empty strings are the defaults and say nothing; everything else is why a row
    looks the way it does.
    """
    out: list[str] = []
    for key in sorted(flags):
        value = flags[key]
        if value is True:
            out.append(key)
        elif value is False or value is None or value == "":
            continue
        else:
            out.append(f"{key}={value}")
    return out


def flatten(doc_id: str, raw: dict[str, Any]) -> dict[str, Any]:
    """One audit document as a table row.

    Only the fields a reader scans. The whole document is still one request away, and the drawer
    shows it unmodified - a decision is evidence, not a derivation.
    """
    inputs = raw.get("inputs") or {}
    outputs = raw.get("outputs") or {}
    txn = inputs.get("txn") or {}
    flags = inputs.get("demo_flags") or {}
    reasons = outputs.get("reasons") or []
    return {
        "id": raw.get("id") or doc_id,
        "at": raw.get("at"),
        "kind": raw.get("kind"),
        "uid": raw.get("uid"),
        "service": raw.get("service"),
        "model_version": raw.get("model_version"),
        "processing_ms": raw.get("processing_ms"),
        "decision": outputs.get("decision"),
        "band": outputs.get("band"),
        "risk_score": outputs.get("risk_score"),
        "reason_codes": [r.get("code") for r in reasons if isinstance(r, dict)],
        "txn_type": txn.get("type"),
        "amount_bdt": txn.get("amount_bdt"),
        "to_account": txn.get("to_account"),
        "session_id": inputs.get("session_id"),
        # What was switched on, as words. Taking only `v is True` dropped every flag that is not
        # a boolean - `app_safety_verdict: "BLOCK"`, `scam_score`, `inbound_mule_score` - so the
        # two rows that actually blocked showed a dash for the flag that caused them. Anything
        # set to a non-default value is named; a value that is not a bare True is named with it.
        "flags": _flags(flags),
        # Whatever a non-score route answered with, so one table can hold every kind.
        "verdict": outputs.get("verdict") or outputs.get("scam_type") or outputs.get("recommended_action"),
    }


def recent(
    limit: int = DEFAULT_LIMIT,
    before: str | None = None,
    since: str | None = None,
) -> list[dict[str, Any]]:
    """Documents newest first, flattened. Three ways to ask, and only one of them is a full read.

    * nothing      - the first page, when the view opens
    * `before`     - the `at` of the last row shown, for the next page down
    * `since`      - the `at` of the newest row shown, for a poll

    `since` is the one that matters. A console polling every five seconds must not re-read three
    hundred documents to discover that nothing happened; with an inequality on `at` the query
    returns the handful that are actually new, and usually none. Both filters are on the same field
    the query orders by, so Firestore serves them from the single-field index it maintains itself -
    no composite index, nothing to deploy.
    """
    limit = max(1, min(limit, MAX_LIMIT))
    key = f"{limit}:{before or ''}:{since or ''}"
    hit = _cache.get(key)
    if hit and time.time() - hit[0] < CACHE_TTL_S:
        return hit[1]

    from google.cloud import firestore

    query = _client().collection(COLLECTION).select(ROW_FIELDS)
    if since:
        query = query.where(filter=firestore.FieldFilter("at", ">", since))
    query = query.order_by("at", direction=firestore.Query.DESCENDING)
    if before:
        query = query.start_after({"at": before})
    try:
        rows = [flatten(doc.id, doc.to_dict() or {}) for doc in query.limit(limit).stream()]
    except Exception as exc:  # noqa: BLE001 - a read failure must degrade, not 500
        raise AuditUnavailable(f"{type(exc).__name__}: {exc}") from exc

    now = time.time()
    # Keys carry `before`/`since` cursors, so a long session invents a new one on every page and
    # every poll. Without this the dict only ever grows.
    for stale in [k for k, (when, _) in _cache.items() if now - when > CACHE_TTL_S * 10]:
        _cache.pop(stale, None)
    _cache[key] = (now, rows)
    return rows


def _redact(raw: Any, path: str = "") -> Any:
    """Shorten what a shoulder cannot usefully see but a screenshot would carry away.

    The drawer renders a whole audit document, and some of those documents hold a caller's phone
    number, the transcript of a scam call, what the customer said to the assistant, and every
    package installed on their handset. The console is behind one demo password on a public URL;
    "it is only visible to operators" is not true of a tab left open next to a judge. Nothing is
    removed from the stored document - this only shapes the copy that is sent for display, and
    `?full=1` still returns it whole for the one place that needs it.
    """
    if isinstance(raw, dict):
        return {k: _redact(v, f"{path}.{k}" if path else k) for k, v in raw.items()}
    if isinstance(raw, list):
        key = path.rsplit(".", 1)[-1]
        if key in LONG_LISTS:
            return f"[{len(raw)} items, hidden - ask for ?full=1]"
        return [_redact(v, path) for v in raw]
    key = path.rsplit(".", 1)[-1]
    if key in DROPPED and not (key == "attestation" and raw in ATTESTATION_LEVELS):
        return "[hidden]"
    if isinstance(raw, str):
        if key in PHONE_FIELDS and len(raw) > 3:
            return f"{'•' * (len(raw) - 3)}{raw[-3:]}"
        if key in TEXT_FIELDS and len(raw) > TEXT_KEEP:
            return f"{raw[:TEXT_KEEP]}… [{len(raw)} chars, ask for ?full=1]"
    return raw


def one(doc_id: str, full: bool = False) -> dict[str, Any] | None:
    """The document as it was written, redacted for display unless `full` is asked for.

    Nothing is recomputed either way: redaction shortens, it never derives.
    """
    doc = _client().collection(COLLECTION).document(doc_id).get()
    if not doc.exists:
        return None
    raw = doc.to_dict() or {}
    return raw if full else _redact(raw)


def facets(rows: list[dict[str, Any]]) -> dict[str, dict[str, int]]:
    """Counts over the page we fetched, so a filter is never a guess.

    Explicitly over the page and not the collection: saying "378 scores" when the number came from
    the most recent 300 documents would be the kind of denominator-free claim this console exists
    to avoid. The response carries `window` so the screen can say so.
    """
    out: dict[str, dict[str, int]] = {"kind": {}, "decision": {}, "uid": {}, "reason_codes": {}}
    for row in rows:
        for field in ("kind", "decision", "uid"):
            value = row.get(field)
            if value:
                out[field][value] = out[field].get(value, 0) + 1
        for code in row.get("reason_codes") or []:
            out["reason_codes"][code] = out["reason_codes"].get(code, 0) + 1
    return {name: dict(sorted(counts.items(), key=lambda kv: -kv[1])) for name, counts in out.items()}
