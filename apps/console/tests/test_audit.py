"""The audit reader: what a stored document becomes, and what it must not hand out.

The log was shipped with no tests at all, which a review caught. These are the two things that
would actually hurt if they broke: a row that drops the flag which caused the decision, and a
drawer that puts a caller's phone number and a scam transcript on screen because nobody said it
should not.

Nothing here talks to Firestore. `flatten`, `_flags` and `_redact` are pure functions over a
document, which is the whole reason they are separate from the query.
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import get_args

import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "libs" / "app-safety-check"))

from api import audit  # noqa: E402
from api.main import app  # noqa: E402
from bhorosha_app_safety_check.integrity import AttestationLevel  # noqa: E402


SCORE_DOC = {
    "id": "doc-1",
    "at": "2026-10-17T09:00:00+06:00",
    "kind": "score",
    "uid": "u_rina",
    "service": "risk-mw",
    "model_version": "risk-mw-0.2",
    "processing_ms": 41,
    "inputs": {
        "session_id": "s-9",
        "txn": {"type": "send_money", "amount_bdt": 7500, "to_account": "acct_01070"},
        "demo_flags": {
            "call_active": True,
            "sim_swap": False,
            "app_safety_verdict": "BLOCK",
            "scam_score": 0.91,
            "screen_share": None,
        },
    },
    "outputs": {
        "decision": "block",
        "band": "critical",
        "risk_score": 0.97,
        "reasons": [
            {"code": "APP_SAFETY_BLOCK", "text_bn": "আপনার ফোনে একটি ঝুঁকিপূর্ণ অ্যাপ পাওয়া গেছে।", "text_en": "A risky app."},
        ],
    },
}

SCAM_DOC = {
    "id": "doc-2",
    "at": "2026-10-17T09:01:00+06:00",
    "kind": "scam_turn",
    "uid": "u_rina",
    "inputs": {
        "caller_number": "+8801712345678",
        "text": "x" * 300,
        "installed_apps": [{"package": f"com.app{i}"} for i in range(420)],
        "integrity_token": "eyJhbGciOi.very.long",
    },
    "outputs": {"scam_type": "authority_impersonation", "scam_score": 0.88},
}


def test_a_score_row_carries_what_decided_it() -> None:
    row = audit.flatten("doc-1", SCORE_DOC)
    assert row["decision"] == "block"
    assert row["reason_codes"] == ["APP_SAFETY_BLOCK"]
    assert row["amount_bdt"] == 7500
    assert row["to_account"] == "acct_01070"


def test_a_flag_that_is_not_a_boolean_is_still_a_flag() -> None:
    """The two live blocks showed a dash for the flag that caused them.

    `app_safety_verdict` is a string and `scam_score` a float, so filtering on `v is True` dropped
    exactly the flags worth reading.
    """
    flags = audit.flatten("doc-1", SCORE_DOC)["flags"]
    assert "call_active" in flags
    assert "app_safety_verdict=BLOCK" in flags
    assert "scam_score=0.91" in flags
    # Defaults say nothing and must not crowd the column.
    assert not any(f.startswith("sim_swap") for f in flags)
    assert not any(f.startswith("screen_share") for f in flags)


def test_a_non_score_row_still_has_an_outcome() -> None:
    assert audit.flatten("doc-2", SCAM_DOC)["verdict"] == "authority_impersonation"


def test_the_drawer_does_not_hand_out_a_phone_number_or_a_transcript() -> None:
    shown = audit._redact(SCAM_DOC)
    assert shown["inputs"]["caller_number"].endswith("678")
    assert "8801712345" not in shown["inputs"]["caller_number"]
    assert len(shown["inputs"]["text"]) < 120
    assert shown["inputs"]["integrity_token"] == "[hidden]"
    assert "420" in shown["inputs"]["installed_apps"]


def _app_safety_doc(attestation: str) -> dict:
    return {**SCORE_DOC, "inputs": {**SCORE_DOC["inputs"], "integrity_token": "eyJhbGciOi.very.long",
                                    "app_safety": {"verdict": "BLOCK", "attestation": attestation}}}


@pytest.mark.parametrize("level", get_args(AttestationLevel))
def test_the_app_safety_attestation_level_is_shown(level: str) -> None:
    """The drawer's App Safety section says what the server concluded about the phone.

    Enumerated from the check's own AttestationLevel, so a new level fails here until audit.py lets it through.
    """
    shown = audit._redact(_app_safety_doc(level))
    assert shown["inputs"]["app_safety"]["attestation"] == level
    assert shown["inputs"]["integrity_token"] == "[hidden]"


def test_anything_else_under_attestation_stays_hidden() -> None:
    """Only the level words are let through: a token or blob stored under that key is never shown."""
    shown = audit._redact(_app_safety_doc("eyJhbGciOiJFUzI1NiJ9.payload.signature"))
    assert shown["inputs"]["app_safety"]["attestation"] == "[hidden]"


def test_redaction_leaves_the_customer_facing_reasons_alone() -> None:
    """Reproducing what the customer was shown is the drawer's whole purpose."""
    shown = audit._redact(SCORE_DOC)
    assert shown["outputs"]["reasons"] == SCORE_DOC["outputs"]["reasons"]
    assert shown["outputs"]["decision"] == "block"


def test_redaction_never_touches_what_is_stored() -> None:
    before = SCAM_DOC["inputs"]["caller_number"]
    audit._redact(SCAM_DOC)
    assert SCAM_DOC["inputs"]["caller_number"] == before


def test_facets_count_the_page_not_the_collection() -> None:
    rows = [audit.flatten("doc-1", SCORE_DOC), audit.flatten("doc-2", SCAM_DOC)]
    counts = audit.facets(rows)
    assert counts["kind"]["score"] == 1
    assert counts["kind"]["scam_turn"] == 1


def test_the_projection_covers_every_field_the_row_reads() -> None:
    """A field `flatten` reads but the query does not select comes back empty from Firestore."""
    for path in ("outputs.decision", "outputs.reasons", "inputs.demo_flags", "inputs.txn.amount_bdt"):
        assert path in audit.ROW_FIELDS


@pytest.fixture()
def anonymous() -> TestClient:
    return TestClient(app)


def test_both_audit_routes_need_a_token(anonymous: TestClient) -> None:
    assert anonymous.get("/v1/admin/audit").status_code == 401
    assert anonymous.get("/v1/admin/audit/anything").status_code == 401


def test_the_log_degrades_rather_than_failing(anonymous: TestClient, monkeypatch: pytest.MonkeyPatch) -> None:
    """Firestore being unreachable is a named error on the page, not a 500 and not an empty table."""
    def unreachable(**_: object) -> None:
        raise audit.AuditUnavailable("no credentials for Firestore (DefaultCredentialsError)")

    monkeypatch.setattr(audit, "recent", unreachable)
    signed_in = TestClient(app)
    token = signed_in.post("/v1/auth/login", json={"username": "admin", "password": "finnest-local-dev"}).json()["token"]
    body = signed_in.get("/v1/admin/audit", headers={"Authorization": f"Bearer {token}"}).json()
    assert body["available"] is False
    assert "Firestore" in body["error"]
    assert body["rows"] == []
