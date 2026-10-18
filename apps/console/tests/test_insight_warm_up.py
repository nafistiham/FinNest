"""The first Gemini reading after a deploy must not be the cold one.

On one deployed revision the first reading started two minutes after the instance did, with the
world warm-up long finished, and got no answer from Vertex within its 40 s timeout; every later reading took
about 8.5 s. A risk-mw revision showed the same cold start: its first model call took 6.2 s against about 1.5 s
for the same task afterwards. risk-mw warms the client, the token and (in its deploy) one model call at
start-up; the console now does the same, in the background, and logs why any reading failed.
"""

from __future__ import annotations

import logging
import re
import sys
import threading
from pathlib import Path
from typing import Any

import pytest
from fastapi.testclient import TestClient

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from api import insight  # noqa: E402
from api.risk_mw import genai_client  # noqa: E402
from tests.test_insight import FakeGemini, score_doc  # noqa: E402


@pytest.fixture(autouse=True)
def _fresh() -> None:
    insight.forget()


def _record_calls(monkeypatch: pytest.MonkeyPatch, client_ready: bool = True, call_raises: BaseException | None = None) -> dict:
    seen: dict[str, Any] = {"client": 0, "calls": []}

    def warm_client() -> bool:
        seen["client"] += 1
        return client_ready

    def call(task: str, role: str, contents: Any, **kwargs: Any) -> Any:
        seen["calls"].append({"task": task, "role": role, "contents": contents, **kwargs})
        if call_raises:
            raise call_raises
        return None

    monkeypatch.setattr(genai_client, "warm_up", warm_client)
    monkeypatch.setattr(genai_client, "call", call)
    return seen


def test_warming_builds_the_client_and_its_token_without_a_model_call_by_default(monkeypatch: pytest.MonkeyPatch) -> None:
    seen = _record_calls(monkeypatch)
    assert insight.warm_up() is True
    assert seen["client"] == 1 and seen["calls"] == []


def test_warming_makes_one_full_reading_of_a_built_in_sample(monkeypatch: pytest.MonkeyPatch) -> None:
    """On the next revision, after a tiny "say OK" warm-up the first real reading still took 23.2 s, the next 4.0 s
    with the same output size. So the warm-up is now a reading itself: same prompt, same schema, same limits."""
    seen = _record_calls(monkeypatch)
    assert insight.warm_up(call=True) is True
    assert len(seen["calls"]) == 1
    made = seen["calls"][0]
    system, contents = insight.prompt(insight.basis(insight.SAMPLE_DOC))
    assert made["task"] == "console_insight_warm_up" and made["role"] == insight.ROLE
    assert made["system"] == system and made["contents"] == contents
    assert made["schema"] is insight.Answer
    assert made["thinking_level"] == insight.THINKING and made["max_output_tokens"] == insight.MAX_OUTPUT_TOKENS


def test_the_sample_is_a_held_score_with_several_reasons() -> None:
    facts = insight.basis(insight.SAMPLE_DOC)
    assert insight.SAMPLE_DOC["kind"] == "score" and facts["decision"] == "hold"
    assert len(facts["reasons"]) >= 3 and "app_safety" in facts and facts["signals"]


def test_the_sample_reading_is_never_anyones_cached_reading(monkeypatch: pytest.MonkeyPatch) -> None:
    _record_calls(monkeypatch)
    insight.warm_up(call=True)
    assert len(insight._cache) == 0


def test_a_reading_and_the_warm_up_go_through_the_same_call(monkeypatch: pytest.MonkeyPatch) -> None:
    seen = _record_calls(monkeypatch)
    insight.gemini("system", "contents")
    insight.warm_up(call=True)
    reading, warm = seen["calls"]
    assert reading["task"] == "console_insight"
    assert {k: v for k, v in reading.items() if k not in ("task", "system", "contents", "timeout_s")} == \
           {k: v for k, v in warm.items() if k not in ("task", "system", "contents", "timeout_s")}


def test_warming_does_nothing_more_when_gemini_is_off(monkeypatch: pytest.MonkeyPatch) -> None:
    seen = _record_calls(monkeypatch, client_ready=False)
    assert insight.warm_up(call=True) is False
    assert seen["calls"] == []


def test_a_failed_warm_up_call_never_raises(monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture) -> None:
    _record_calls(monkeypatch, call_raises=TimeoutError("cold"))
    with caplog.at_level(logging.WARNING, logger="insight"):
        assert insight.warm_up(call=True) is False
    assert "TimeoutError" in caplog.text


def test_the_warm_up_call_is_switched_by_the_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    seen = _record_calls(monkeypatch)
    monkeypatch.setenv("FINNEST_ADMIN_GEMINI_WARM_UP_CALL", "true")
    insight.warm_up_from_env()
    assert len(seen["calls"]) == 1
    monkeypatch.setenv("FINNEST_ADMIN_GEMINI_WARM_UP_CALL", "false")
    insight.warm_up_from_env()
    assert len(seen["calls"]) == 1 and seen["client"] == 2


def test_the_console_warms_gemini_at_start_beside_the_world(monkeypatch: pytest.MonkeyPatch) -> None:
    """Its own thread: the first reading must not wait behind the seed world either."""
    from api import main

    started = threading.Event()
    monkeypatch.setattr(insight, "warm_up_from_env", lambda: started.set())
    monkeypatch.setattr(main, "warm", lambda: None)
    with TestClient(main.app):
        assert started.wait(5), "the console did not warm Gemini at start-up"


def test_the_deploy_makes_the_warm_up_call() -> None:
    deploy = (ROOT / "scripts" / "deploy.sh").read_text(encoding="utf-8")
    assert re.search(r"FINNEST_ADMIN_GEMINI_WARM_UP_CALL=\$\{CONSOLE_GEMINI_WARM_UP_CALL:-true\}", deploy)


def test_a_failed_reading_is_logged_with_its_cause(caplog: pytest.LogCaptureFixture) -> None:
    """The live timeout left nothing to diagnose it by: the drawer gets a fixed code, the log now gets the cause."""
    with caplog.at_level(logging.WARNING, logger="insight"), pytest.raises(insight.InsightUnavailable):
        insight.explain("doc-cold", score_doc(), generate=FakeGemini(TimeoutError("read timed out")))
    assert "doc-cold" in caplog.text and "timeout" in caplog.text and "TimeoutError" in caplog.text
    assert re.search(r"after \d+\.\d s", caplog.text)
