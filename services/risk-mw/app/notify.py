"""FCM pushes for the trusted-contact check (spec US-4). Off unless RISK_MW_FCM_ENABLED=true."""

from __future__ import annotations

import logging

from app.settings import get_settings

log = logging.getLogger(__name__)


def send(token: str, data: dict[str, str], title: str, body: str) -> str:
    """Send one high-priority data + notification message; returns 'sent', 'disabled' or 'error'."""
    if not get_settings().fcm_enabled:
        return "disabled"
    try:
        import firebase_admin
        from firebase_admin import messaging

        if not firebase_admin._apps:  # noqa: SLF001 - documented idempotent init check
            firebase_admin.initialize_app()
        messaging.send(messaging.Message(
            token=token, data=data, notification=messaging.Notification(title=title, body=body),
            android=messaging.AndroidConfig(priority="high"),
        ))
        return "sent"
    except Exception as exc:  # noqa: BLE001 - a failed push must not fail the hold
        log.error("fcm push failed: %s", exc.__class__.__name__)
        return "error"
