"""The App Safety triage reaches Gemini with every argument where genai_client.call expects it (plan Task 6, 2026-10-18).

Since 6afa922 `_gemini` passed `system, THINKING_LEVEL, timeout, max_tokens` positionally into
`call(task, role, contents, schema, system, timeout_s, thinking_level, max_output_tokens)`: the timeout landed in
`thinking_level` and the thinking level in `timeout_s`, every triage raised (`'float' object has no attribute 'upper'`)
and every check answered from the rule templates. The fake below has the real signature, so it binds the arguments
exactly as the real call would.
"""

from __future__ import annotations

import inspect
from types import SimpleNamespace

from app import appsafety_engine, genai_client
from app.settings import get_settings


def test_triage_passes_arguments_by_name(monkeypatch):
    seen = {}
    real = inspect.signature(genai_client.call)

    def fake(*args, **kwargs):
        seen.update(real.bind(*args, **kwargs).arguments)
        return SimpleNamespace(parsed={"ok": True})

    monkeypatch.setattr(appsafety_engine.genai_client, "call", fake)
    assert appsafety_engine._gemini("SYSTEM", '{"apps_with_findings": []}', dict) == {"ok": True}
    settings = get_settings()
    assert seen["task"] == appsafety_engine.GEMINI_TASK and seen["role_name"] == appsafety_engine.GEMINI_ROLE
    assert seen["system"] == "SYSTEM" and seen["contents"] == '{"apps_with_findings": []}' and seen["schema"] is dict
    assert seen["thinking_level"] == appsafety_engine.THINKING_LEVEL
    assert seen["timeout_s"] == max(appsafety_engine.GEMINI_HTTP_MIN_TIMEOUT_S, settings.appsafety_gemini_timeout_s)
    assert seen["max_output_tokens"] == settings.appsafety_max_output_tokens
