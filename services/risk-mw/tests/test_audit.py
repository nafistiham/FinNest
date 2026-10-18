"""Audit rows (Firestore audit/{id}, or the log when Firestore is off) carry the version that actually answered."""

import json
import logging

from app import audit


def test_an_audit_row_records_the_version_the_response_reports(caplog):
    with caplog.at_level(logging.INFO, logger="audit"):
        audit.record("score", "rina", {"user_id": "rina"}, {"decision": "allow", "model_version": "rules+session-hgb-0.2"}, 1.0)
        audit.record("signals", "rina", {"session_id": "s"}, {"stored": True}, 1.0)
    rows = [json.loads(r.getMessage()) for r in caplog.records if r.getMessage().startswith("{")]
    assert rows[-2]["model_version"] == "rules+session-hgb-0.2"
    assert rows[-1]["model_version"] != "stub-0.1"  # a row without a model in its response still says which service build wrote it


def test_health_and_audit_rows_without_a_model_name_a_real_service_version(client):
    """/health and the FastAPI version said "stub-0.1" long after the stub was replaced."""
    from app.settings import Settings

    assert Settings().model_version == "risk-mw-0.2"
    assert client.get("/health").json()["model_version"] == "risk-mw-0.2"
