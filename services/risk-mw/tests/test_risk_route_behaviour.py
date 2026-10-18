"""The /v1/risk route with the behaviour model wired in.

app/ato.py has its own unit tests. These cover the join the route makes, which nothing else
does: a session signals its features at one endpoint and is scored at another, and the two are
connected only by session_id. Without a test here the wiring passes trivially, because with no
artefacts present the adapter returns no hits and every existing assertion holds unchanged.
"""

from __future__ import annotations

import random
import sys
from pathlib import Path

import pytest

SERVICE_DIR = Path(__file__).resolve().parent.parent
PROJECT_DIR = SERVICE_DIR.parent.parent
for candidate in (SERVICE_DIR, PROJECT_DIR / "libs" / "ato"):
    if str(candidate) not in sys.path:
        sys.path.insert(0, str(candidate))

from bhorosha_ato import model as ato_model  # noqa: E402
from bhorosha_ato import synth  # noqa: E402
from bhorosha_ato.explain import ATO_HOLD  # noqa: E402

from app import ato  # noqa: E402
from app.settings import get_settings  # noqa: E402


@pytest.fixture(scope="module")
def trained() -> dict:
    """Artefacts for one owner, plus an owner row and a stranger row chosen against the model."""
    import tempfile

    rng = random.Random(11)
    owner = synth.user_profile(rng)
    enrolment = synth.genuine_rows(owner, 24, rng)
    directory = Path(tempfile.mkdtemp(prefix="route-ato-"))

    fitted = ato_model.train_ato(enrolment)
    ato_model.save(fitted, directory / "ato_rina.pkl")

    pooled = [row for _ in range(8) for row in synth.genuine_rows(synth.user_profile(rng), 6, rng)]
    ato_model.save(ato_model.train_ato(pooled, per_user=False), directory / "cold_start.pkl")

    genuine = synth.genuine_rows(owner, 40, rng)
    ato_model.save(
        ato_model.train_coaching(
            synth.coaching_matrix(genuine),
            synth.coaching_matrix(synth.coached_rows(genuine, rng)),
            synth.COACHING_FEATURES,
        ),
        directory / "coaching.pkl",
    )

    # Picked against the fitted model rather than assumed: generated profiles overlap, and a
    # stranger who happens to swipe like the owner would make these assertions flap.
    stranger = next(
        row
        for _ in range(60)
        for row in synth.genuine_rows(synth.user_profile(rng), 1, rng)
        if fitted.score(row) >= ATO_HOLD
    )
    held_out = synth.genuine_rows(owner, 3, rng)
    return {
        "dir": directory,
        "owner_row": held_out[0],
        "stranger_row": stranger,
        "coached_row": synth.coach(held_out[0], rng),
    }


@pytest.fixture
def wired(monkeypatch, trained):
    """Point the service at the artefacts and clear every cache around the test."""
    monkeypatch.setenv("RISK_MW_ATO_ARTEFACTS_DIR", str(trained["dir"]))
    get_settings.cache_clear()
    ato.reset_cache()
    yield
    get_settings.cache_clear()
    ato.reset_cache()


def _signal(client, session_id: str, features) -> None:
    response = client.post(
        "/v1/risk/signals",
        json={"session_id": session_id, "behaviour": {"features": list(features)}},
        headers={"X-Demo-User": "rina"},
    )
    assert response.status_code == 200, response.text


def _score(client, body: dict) -> dict:
    response = client.post("/v1/risk/score", json=body, headers={"X-Demo-User": "rina"})
    assert response.status_code == 200, response.text
    return response.json()


def _codes(result: dict) -> set[str]:
    return {reason["code"] for reason in result["reasons"]}


def test_a_session_that_signalled_nothing_scores_exactly_as_before(client, score_body, wired):
    """The route must not depend on behaviour features arriving. Most requests in the demo
    will not carry them, and a missing signal call cannot change the rule outcome."""
    result = _score(client, score_body)
    assert not any(code.startswith("ATO_") or code == "COACHING_SUSPECTED" for code in _codes(result))


def test_the_owners_own_session_adds_no_behaviour_reason(client, score_body, trained, wired):
    _signal(client, score_body["session_id"], trained["owner_row"])
    result = _score(client, score_body)
    assert "ATO_BEHAVIOUR_MISMATCH" not in _codes(result)


def test_a_stranger_on_her_phone_reaches_the_decision(client, score_body, trained, wired):
    """The point of the whole ticket, measured through the route rather than the model."""
    _signal(client, score_body["session_id"], trained["stranger_row"])
    result = _score(client, score_body)

    codes = _codes(result)
    assert any(code.startswith("ATO_BEHAVIOUR_MISMATCH") for code in codes), codes
    assert result["decision"] != "allow"
    reason = next(r for r in result["reasons"] if r["code"].startswith("ATO_BEHAVIOUR_MISMATCH"))
    assert reason["text_bn"] and reason["text_en"]


def test_a_coached_session_on_a_live_call_is_held(client, score_body, trained, wired):
    """US-3's second scenario end to end: the owner is recognised, the coaching is not, and
    call_active is what turns that into a hold rather than a step-up."""
    _signal(client, score_body["session_id"], trained["coached_row"])
    body = {**score_body, "demo_flags": {"call_active": True}}
    result = _score(client, body)

    assert "COACHING_SUSPECTED" in _codes(result), _codes(result)
    assert result["decision"] == "hold"
    assert any(action["type"] in {"hold_transaction", "freeze_pin_reset"} for action in result["actions"])


def test_the_same_coached_session_without_a_call_does_not_hold(client, score_body, trained, wired):
    """Proves call_active is actually reaching required_action and not being ignored."""
    _signal(client, score_body["session_id"], trained["coached_row"])
    result = _score(client, {**score_body, "demo_flags": {"call_active": False}})
    assert result["decision"] != "hold"


def test_features_are_matched_by_session_not_by_user(client, score_body, trained, wired):
    """A different session id must not pick up another session's features, or one scored
    request would leak behaviour into an unrelated one."""
    _signal(client, "some-other-session", trained["stranger_row"])
    result = _score(client, score_body)
    assert not any(code.startswith("ATO_BEHAVIOUR_MISMATCH") for code in _codes(result))
