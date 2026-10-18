"""Behaviour (ATO) adapter: the behaviour models reach the rules layer as hits, or go quiet and say so.

Artefacts are trained here from `bhorosha_ato.synth` rather than from HMOG: the adapter's job is
plumbing, and the generated sessions separate cleanly enough to pin it without a dataset.
"""

from __future__ import annotations

import dataclasses
import random
import shutil
import sys
from pathlib import Path

import pytest

SERVICE_DIR = Path(__file__).resolve().parent.parent
PROJECT_DIR = SERVICE_DIR.parent.parent
# conftest.py vendors the synth packages onto sys.path; `ato` is a third root that the image
# vendors the same way (scripts/deploy.sh), so the test adds it here.
if str(PROJECT_DIR / "libs" / "ato") not in sys.path:
    sys.path.insert(0, str(PROJECT_DIR / "libs" / "ato"))

from bhorosha_ato import model as ato_model  # noqa: E402
from bhorosha_ato import schema  # noqa: E402
from bhorosha_ato import synth  # noqa: E402
from bhorosha_ato.explain import ATO_HOLD  # noqa: E402

from app import ato  # noqa: E402
from app.contracts import ScoreRequest  # noqa: E402
from app.rules import DECISION_RANK, RuleHit, decide  # noqa: E402
from app.settings import Settings, get_settings  # noqa: E402

# Derived, not written down. This was pinned at 30 while the schema grew to 39, so the
# parametrisation below exercised 0, 29 and 31 - three vectors that are wrong by the same wide
# margin, none of them next to the real boundary. It read as an off-by-one guard and was not
# one. Deriving it means the adjacent cases stay adjacent the next time a feature is added.
WIRE_LENGTH = len(schema.FEATURES)


@pytest.fixture(scope="session")
def artefacts(tmp_path_factory) -> dict:
    """A full artefacts directory plus the sessions the tests score against it."""
    rng = random.Random(7)
    owner = synth.user_profile(rng)
    enrolment = synth.genuine_rows(owner, 24, rng)
    held_out = synth.genuine_rows(owner, 5, rng)

    directory = tmp_path_factory.mktemp("ato-artefacts")

    # The cold-start stand-in: one model over many people's sessions, which is what a user with
    # no enrolment of her own gets scored by. Built before Rina's model because it is also the
    # reference her calibration is anchored against - other people's sessions, never trained on,
    # scored through her pipeline so the threshold sits on a measured crossover. Without it she
    # takes the quantile fallback, which estimates a 5th percentile from five k-fold margins and
    # steps up on a third of her own sessions.
    pooled = [row for _ in range(8) for row in synth.genuine_rows(synth.user_profile(rng), 6, rng)]
    ato_model.save(ato_model.train_ato(pooled), directory / "cold_start.pkl")

    fitted = ato_model.train_ato(enrolment, reference=pooled)
    ato_model.save(fitted, directory / "ato_rina.pkl")

    # Her representative session, chosen against the model for the same reason the impostor
    # below is: these tests are about the adapter's wiring, and hanging them on an arbitrary row
    # measures the generator's tail instead. Of these five, four score 0.04-0.21 and one scores
    # 0.76 - a genuine 1-in-5 outlier of hers. Taking the median keeps the test able to fail (if
    # a typical session of hers started stepping up, the median would move with it) without
    # pinning it to that tail. The false-reject RATE is a model-level promise and is asserted
    # where it belongs, in ato/tests/test_model.py.
    held_out = sorted(held_out, key=fitted.score)
    owner_row = held_out[len(held_out) // 2]

    # Chosen against the fitted model rather than assumed: generated profiles overlap, and a
    # stranger who happens to swipe like Rina would make the assertions below flap.
    impostor_row = next(
        row
        for _ in range(40)
        for row in synth.genuine_rows(synth.user_profile(rng), 1, rng)
        if fitted.score(row) >= ATO_HOLD
    )

    genuine = synth.genuine_rows(owner, 40, rng)
    coached = synth.coached_rows(genuine, rng)
    coaching = ato_model.train_coaching(
        synth.coaching_matrix(genuine), synth.coaching_matrix(coached), synth.COACHING_FEATURES
    )
    ato_model.save(coaching, directory / "coaching.pkl")

    return {
        "dir": directory,
        "owner_row": owner_row,
        "impostor_row": impostor_row,
        "coached_row": synth.coach(owner_row, rng),
        # Far outside every profile, so the global cold-start model rejects it reliably.
        "wild_row": tuple(value * 4.0 for value in owner_row),
    }


@pytest.fixture
def use_artefacts(monkeypatch):
    """Point the adapter at a directory and drop every cached artefact around the test."""

    def point_at(directory: Path) -> None:
        monkeypatch.setenv("RISK_MW_ATO_ARTEFACTS_DIR", str(directory))
        get_settings.cache_clear()
        ato.reset_cache()

    yield point_at
    get_settings.cache_clear()  # monkeypatch has restored the environment by now
    ato.reset_cache()


def _partial_dir(artefacts: dict, tmp_path: Path, keep: tuple[str, ...]) -> Path:
    directory = tmp_path / "partial"
    directory.mkdir()
    for name in keep:
        shutil.copy(artefacts["dir"] / name, directory / name)
    return directory


# --- degradation ------------------------------------------------------------


def test_unset_artefacts_dir_means_no_hits(use_artefacts, artefacts, monkeypatch):
    monkeypatch.delenv("RISK_MW_ATO_ARTEFACTS_DIR", raising=False)
    get_settings.cache_clear()
    ato.reset_cache()
    assert get_settings().ato_artefacts_dir is None
    assert ato.behaviour_hits("rina", artefacts["impostor_row"]) == ()


def test_missing_artefacts_dir_means_no_hits(use_artefacts, artefacts, tmp_path):
    use_artefacts(tmp_path / "not-deployed")
    assert ato.models() is None
    assert ato.behaviour_hits("rina", artefacts["impostor_row"]) == ()


def test_empty_artefacts_dir_means_no_hits(use_artefacts, artefacts, tmp_path):
    """The directory exists but the upload never happened."""
    (tmp_path / "empty").mkdir()
    use_artefacts(tmp_path / "empty")
    assert ato.models() is not None  # per-user models could still be there; these are not
    assert ato.behaviour_hits("rina", artefacts["impostor_row"]) == ()


def test_unknown_user_without_a_cold_start_stand_in_gets_no_hits(use_artefacts, artefacts, tmp_path):
    use_artefacts(_partial_dir(artefacts, tmp_path, ("coaching.pkl",)))
    assert ato.user_model("nobody") is None
    assert ato.behaviour_hits("nobody", artefacts["wild_row"]) == ()


@pytest.mark.parametrize("length", [0, WIRE_LENGTH - 1, WIRE_LENGTH + 1])
def test_wrong_length_vector_is_refused_not_scored(use_artefacts, artefacts, length):
    use_artefacts(artefacts["dir"])
    assert ato.behaviour_hits("rina", tuple(0.5 for _ in range(length))) == ()


def test_unsafe_user_id_never_becomes_a_path(use_artefacts, artefacts):
    use_artefacts(artefacts["dir"])
    assert ato.user_model("../../etc/passwd") is None
    # It still gets an answer, from the cold-start model, and never reads outside the directory.
    hits = ato.behaviour_hits("../../etc/passwd", artefacts["wild_row"])
    assert all(hit.reason.code.endswith(ato.COLD_START_SUFFIX) or hit.reason.code == "COACHING_SUSPECTED"
               for hit in hits)


def test_a_missing_vendored_package_degrades_like_a_missing_artefact(use_artefacts, artefacts, monkeypatch):
    use_artefacts(artefacts["dir"])
    # None in sys.modules is how CPython reports "this import is unavailable".
    monkeypatch.setitem(sys.modules, "bhorosha_ato.explain", None)
    assert ato.behaviour_hits("rina", artefacts["impostor_row"]) == ()


def test_an_unloadable_artefact_degrades_rather_than_raising(use_artefacts, artefacts, tmp_path):
    directory = tmp_path / "corrupt"
    directory.mkdir()
    (directory / "ato_rina.pkl").write_bytes(b"not a pickle")
    use_artefacts(directory)
    assert ato.user_model("rina") is None
    assert ato.behaviour_hits("rina", artefacts["impostor_row"]) == ()


def test_her_own_session_earns_no_hits(use_artefacts, artefacts):
    use_artefacts(artefacts["dir"])
    assert ato.behaviour_hits("rina", artefacts["owner_row"]) == ()


# --- the signal itself ------------------------------------------------------


def test_a_stranger_converts_into_rule_hits_the_rules_layer_can_use(use_artefacts, artefacts):
    use_artefacts(artefacts["dir"])
    hits = ato.behaviour_hits("rina", artefacts["impostor_row"])

    assert hits, "a stranger on Rina's phone must produce at least one hit"
    codes = {hit.reason.code for hit in hits}
    assert "ATO_BEHAVIOUR_MISMATCH" in codes
    # Her own model exists, so nothing here may be labelled cold start.
    assert not any(code.endswith(ato.COLD_START_SUFFIX) for code in codes)

    for hit in hits:
        assert isinstance(hit, RuleHit)
        assert hit.decision in DECISION_RANK
        assert 0.0 <= hit.reason.weight <= 1.0
        assert hit.reason.text_bn.strip() and hit.reason.text_en.strip()


def test_the_hits_drive_a_decision_through_the_rules_layer(use_artefacts, artefacts):
    use_artefacts(artefacts["dir"])
    hits = ato.behaviour_hits("rina", artefacts["impostor_row"])

    req = ScoreRequest.model_validate({
        "user_id": "rina",
        "session_id": "s1",
        "txn": {"type": "send_money", "amount_bdt": 500, "to_account": "acct_x"},
    })
    result = decide(req, hits, 0.0, "ato-test", Settings())
    assert result.decision in ("step_up", "hold")
    assert result.risk_score >= 0.60
    assert {reason.code for reason in result.reasons} == {hit.reason.code for hit in hits}
    assert result.actions, "a step_up or hold decision must carry an action"


def test_each_scored_session_leaves_its_evidence_for_apas_warning(use_artefacts, artefacts):
    """The warning at the hold reads what the last session showed; a later clean session replaces a flagged one."""
    use_artefacts(artefacts["dir"])
    ato.forget_evidence()
    ato.behaviour_hits("rina", artefacts["impostor_row"])
    flagged = ato.latest_evidence("rina", 900)
    assert flagged is not None and flagged.not_her and not flagged.cold_start
    assert flagged.blocks and set(flagged.blocks) <= set(schema.Block.__args__)
    ato.behaviour_hits("rina", artefacts["owner_row"])
    assert not ato.latest_evidence("rina", 900).not_her
    assert ato.latest_evidence("nobody_scored", 900) is None


def test_a_coached_session_is_still_her_but_raises_coaching(use_artefacts, artefacts):
    """US-3's second scenario, seen from the service side: coaching fires, identity does not."""
    use_artefacts(artefacts["dir"])
    hits = ato.behaviour_hits("rina", artefacts["coached_row"], in_call=True)

    codes = {hit.reason.code for hit in hits}
    assert "COACHING_SUSPECTED" in codes
    assert not any(code.startswith("ATO_BEHAVIOUR_MISMATCH") for code in codes)
    coaching_hit = next(hit for hit in hits if hit.reason.code == "COACHING_SUSPECTED")
    assert coaching_hit.decision == "hold"


def test_a_cold_start_answer_is_labelled_as_one(use_artefacts, artefacts):
    use_artefacts(artefacts["dir"])
    hits = ato.behaviour_hits("brand_new_user", artefacts["wild_row"])

    codes = {hit.reason.code for hit in hits}
    assert "ATO_BEHAVIOUR_MISMATCH" + ato.COLD_START_SUFFIX in codes
    # The personalised code must not also be emitted - that is the thing being prevented.
    assert "ATO_BEHAVIOUR_MISMATCH" not in codes


def test_coaching_is_global_so_a_cold_start_user_keeps_its_plain_code(use_artefacts, artefacts):
    use_artefacts(artefacts["dir"])
    hits = ato.behaviour_hits("brand_new_user", artefacts["coached_row"])
    assert "COACHING_SUSPECTED" in {hit.reason.code for hit in hits}


# --- caching ----------------------------------------------------------------


def test_artefacts_are_loaded_once_not_once_per_request(use_artefacts, artefacts, monkeypatch):
    real_load = ato_model.load
    loaded: list[str] = []

    def counting_load(path):
        loaded.append(Path(path).name)
        return real_load(path)

    monkeypatch.setattr(ato_model, "load", counting_load)
    use_artefacts(artefacts["dir"])

    for _ in range(5):
        ato.behaviour_hits("rina", artefacts["impostor_row"])

    assert sorted(loaded) == ["ato_rina.pkl", "coaching.pkl", "cold_start.pkl"]


def test_a_user_without_a_model_is_only_looked_up_once(use_artefacts, artefacts, monkeypatch):
    use_artefacts(artefacts["dir"])
    ato.behaviour_hits("nobody", artefacts["wild_row"])

    real_load = ato_model.load
    loaded: list[str] = []

    def counting_load(path):
        loaded.append(Path(path).name)
        return real_load(path)

    monkeypatch.setattr(ato_model, "load", counting_load)
    for _ in range(3):
        ato.behaviour_hits("nobody", artefacts["wild_row"])

    assert loaded == [], "the cache must remember the miss, not re-stat the directory"


def test_reset_cache_picks_up_a_newly_deployed_artefact(use_artefacts, artefacts, tmp_path):
    directory = _partial_dir(artefacts, tmp_path, ("coaching.pkl", "cold_start.pkl"))
    use_artefacts(directory)
    assert ato.user_model("rina") is None

    shutil.copy(artefacts["dir"] / "ato_rina.pkl", directory / "ato_rina.pkl")
    assert ato.user_model("rina") is None, "still cached, by design"
    ato.reset_cache()
    assert ato.user_model("rina") is not None


def test_feature_level_evidence_reaches_the_explanation(artefacts, use_artefacts):
    """The artefact carries a background sample, so SHAP runs and the customer is told WHY.

    Before `train_ato` stored one, the explainer always took its deterministic path and the
    reasons list came back empty - a decision with nothing behind it. Measured at 1.7 ms for an
    attribution against the 50 ms budget, so the only reason evidence was missing is that it
    had not been wired.
    """
    use_artefacts(artefacts["dir"])
    identity = ato.user_model("rina")
    assert identity is not None
    assert len(identity.background) > 0, "artefact carries no background to compare against"

    attributions = ato._attributions(identity, artefacts["impostor_row"])
    assert attributions, "a background exists but no attributions came back"
    assert all(a.feature and isinstance(a.shap, float) for a in attributions)


def test_an_artefact_without_a_background_still_answers(artefacts, use_artefacts):
    """An artefact written before backgrounds existed must still produce a decision.

    Evidence is an enhancement to the explanation; losing it may never cost the customer the
    answer itself.
    """
    use_artefacts(artefacts["dir"])
    identity = dataclasses.replace(ato.user_model("rina"), background=())
    assert ato._attributions(identity, artefacts["impostor_row"]) == []

    hits = ato.behaviour_hits("rina", artefacts["impostor_row"])
    assert hits, "no hits at all once evidence was removed"
    assert all(hit.reason.text_bn for hit in hits)
