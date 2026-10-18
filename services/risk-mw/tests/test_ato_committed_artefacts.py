"""The behaviour (ATO) artefacts in models/ato, loaded through the adapter the way Cloud Run loads them.

tests/test_ato_adapter.py trains its own artefacts from `bhorosha_ato.synth` into a temp
directory. It tests the plumbing, not the files that deploy. This module tests the directory
that scripts/deploy.sh copies into the image.

The public repository ships no behaviour artefacts: the identity, population (cold-start) and
coaching models are fitted on HMOG sessions, which are not redistributed (see models/README.md).
Without them the adapter returns no behaviour hits, and the service runs as before. The tests
that need the models skip with a clear reason; the "degrades to no hits" check always runs.

When the models are present, this module asserts:

  - the directory loads through `app.ato` and scores a `len(schema.FEATURES)` vector into usable
    rule hits. The fitted width in the pickles is checked against the schema, not only the
    width that the manifest declares;
  - a directory whose manifest declares a DIFFERENT schema is refused quietly, together with
    its per-user models.

It does not measure how well the model separates people. Those rates belong in
tests/test_ato_real_data.py and the ato library's own evaluation. The sessions reachable here
are the sessions the models were FITTED on (each model carries its own background sample). So
a low score on one of them only checks the wiring.
"""

from __future__ import annotations

import dataclasses
import json
import shutil
import sys
from pathlib import Path

import pytest

SERVICE_DIR = Path(__file__).resolve().parent.parent
PROJECT_DIR = SERVICE_DIR.parent.parent
# conftest.py vendors `ato` onto sys.path; repeated here for the same reason the other two ato
# test modules repeat it - this module imports the package at collection time.
if str(PROJECT_DIR / "libs" / "ato") not in sys.path:
    sys.path.insert(0, str(PROJECT_DIR / "libs" / "ato"))

from bhorosha_ato import model as ato_model  # noqa: E402
from bhorosha_ato import schema  # noqa: E402
from bhorosha_ato.explain import ATO_HOLD  # noqa: E402

from app import ato  # noqa: E402
from app.contracts import ScoreRequest  # noqa: E402
from app.rules import DECISION_RANK, RuleHit, decide  # noqa: E402
from app.settings import Settings, get_settings  # noqa: E402

# The directory scripts/deploy.sh vendors into the image. Not a fixture and not configurable:
# this module exists to test THIS path.
COMMITTED = PROJECT_DIR / "models" / "ato"


def _behaviour_models_present() -> bool:
    """True when the directory holds the population model and the first per-user model it lists."""
    try:
        listed = json.loads((COMMITTED / ato.MANIFEST_ARTEFACT).read_text(encoding="utf-8"))["per_user"]
    except (OSError, ValueError, KeyError, TypeError):
        return False
    first = listed[0]["file"] if listed else None
    return (COMMITTED / ato.COLD_START_ARTEFACT).exists() and bool(first) and (COMMITTED / first).exists()


needs_behaviour_models = pytest.mark.skipif(
    not _behaviour_models_present(),
    reason="models/ato holds no behaviour models (they are fitted on HMOG sessions and are not published)",
)
needs_manifest = pytest.mark.skipif(
    not (COMMITTED / ato.MANIFEST_ARTEFACT).exists(),
    reason="models/ato/artefacts.json is not present (the behaviour artefacts are not published)",
)


@pytest.fixture(scope="module")
def manifest() -> dict:
    return json.loads((COMMITTED / ato.MANIFEST_ARTEFACT).read_text(encoding="utf-8"))


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


@pytest.fixture
def shipped(use_artefacts) -> None:
    use_artefacts(COMMITTED)


def _owner_and_stranger(manifest: dict) -> tuple[str, tuple[float, ...], tuple[float, ...]]:
    """(owner uid, one of her own committed sessions, a session of someone else's she rejects).

    Both rows come out of the committed .pkl files themselves: `train_ato` stores a background
    sample of the sessions it fitted on, which is what the explainer compares against, so the
    artefacts carry real HMOG feature vectors and this test needs no table.

    The stranger is chosen AGAINST the owner's model - the first row, scanning users in manifest
    order, that her model actually rejects - for the same reason `test_ato_adapter.py` picks its
    impostor that way. Picking a fixed pair would assert something about two HMOG volunteers;
    the assertions below are about the adapter. Measured: the first candidate row qualifies, so
    the scan loads two models, not a hundred.
    """
    users = [fit["user"] for fit in manifest["per_user"]]
    owner = users[0]
    identity = ato.user_model(owner)
    own_row = tuple(float(value) for value in identity.background[0])
    stranger_row = next(
        row
        for other in users[1:]
        for row in (tuple(float(v) for v in r) for r in ato.user_model(other).background)
        if identity.score(row) >= ATO_HOLD
    )
    return owner, own_row, stranger_row


# --- the committed directory is the schema this build serves -----------------


@needs_manifest
def test_the_committed_manifest_declares_the_schema_this_build_serves(manifest):
    """The assertion whose absence let 39-feature artefacts ship against a 55-feature wire."""
    assert tuple(manifest["schema_names"]) == schema.NAMES
    assert manifest["schema_length"] == len(schema.FEATURES)


@needs_behaviour_models
def test_the_committed_pickles_were_fitted_on_this_schema_not_just_labelled_with_it(shipped, manifest):
    """Checked in the artefacts themselves, because the manifest is the thing that could lie.

    `models()` trusts the manifest - it has nothing else to read before unpickling - so a
    hand-edited `artefacts.json` beside stale models would pass that check. The .pkl files
    carry the morphology column names they were fitted on and a background of full wire rows,
    so both widths are verifiable here without the training table.
    """
    for fit in manifest["per_user"][:3]:
        identity = ato.user_model(fit["user"])
        assert identity is not None, f"{fit['file']} is in the manifest but did not load"
        assert tuple(identity.feature_names) == schema.IDENTITY_FEATURES
        assert {len(row) for row in identity.background} == {len(schema.FEATURES)}

    cold_start = ato.models().cold_start
    assert cold_start is not None
    assert tuple(cold_start.feature_names) == schema.IDENTITY_FEATURES
    assert tuple(ato.models().coaching.feature_names) == tuple(manifest["coaching"]["feature_names"])


# --- scoring the wire vector through the shipped files -----------------------


@needs_behaviour_models
def test_the_committed_artefacts_load_through_the_adapter(shipped, manifest):
    loaded = ato.models()
    assert loaded is not None, "the directory that deploys was refused"
    assert loaded.artefacts == COMMITTED
    assert loaded.coaching is not None, f"{ato.COACHING_ARTEFACT} did not load"
    assert loaded.cold_start is not None, f"{ato.COLD_START_ARTEFACT} did not load"

    owner = manifest["per_user"][0]["user"]
    identity = ato.user_model(owner)
    assert identity is not None and identity.per_user, "her model is the population's, not hers"


@needs_behaviour_models
def test_a_wire_length_vector_scores_through_the_committed_artefacts(shipped, manifest):
    """The reviewer's case: 55 floats in, a usable answer out, on the files that ship."""
    owner, own_row, _ = _owner_and_stranger(manifest)
    assert len(own_row) == len(schema.FEATURES)

    identity = ato.user_model(owner)
    score = identity.score(own_row)
    assert isinstance(score, float) and 0.0 <= score <= 1.0

    # One of the sessions this model was fitted on, so the only honest claim is that it is not
    # mistaken for a stranger. The false-reject RATE on held-out sessions is measured in
    # tests/test_ato_real_data.py, where a dataset is available to measure it on.
    assert ato.behaviour_hits(owner, own_row) == ()


@needs_behaviour_models
def test_a_stranger_on_her_account_becomes_customer_visible_hits(shipped, manifest):
    owner, _, stranger_row = _owner_and_stranger(manifest)
    hits = ato.behaviour_hits(owner, stranger_row)

    assert hits, "a session her own committed model scores above ATO_HOLD produced no hit"
    codes = {hit.reason.code for hit in hits}
    assert "ATO_BEHAVIOUR_MISMATCH" in codes
    # Her model is per-user, so nothing here may be labelled as a cold-start answer.
    assert not any(code.endswith(ato.COLD_START_SUFFIX) for code in codes)

    for hit in hits:
        assert isinstance(hit, RuleHit)
        assert hit.decision in DECISION_RANK
        assert 0.0 <= hit.reason.weight <= 1.0
        assert hit.reason.text_bn.strip() and hit.reason.text_en.strip()


@needs_behaviour_models
def test_those_hits_drive_a_decision_through_the_rules_layer(shipped, manifest):
    """End to end on the shipped files: artefact -> hit -> the decision a customer gets."""
    owner, _, stranger_row = _owner_and_stranger(manifest)
    hits = ato.behaviour_hits(owner, stranger_row)

    req = ScoreRequest.model_validate({
        "user_id": owner,
        "session_id": "committed-artefacts",
        "txn": {"type": "send_money", "amount_bdt": 500, "to_account": "acct_x"},
    })
    result = decide(req, hits, 0.0, "ato-committed", Settings())
    assert result.decision in ("step_up", "hold")
    assert {reason.code for reason in result.reasons} == {hit.reason.code for hit in hits}
    assert result.actions, "a step_up or hold decision must carry an action"


@needs_behaviour_models
def test_a_cold_start_user_is_served_by_the_committed_population_model(shipped, manifest):
    """A uid with no artefact of her own still gets an answer, labelled as not personalised."""
    _, _, stranger_row = _owner_and_stranger(manifest)
    assert ato.user_model("not_an_hmog_user") is None

    hits = ato.behaviour_hits("not_an_hmog_user", stranger_row)
    for hit in hits:
        assert hit.reason.code.endswith(ato.COLD_START_SUFFIX) or hit.reason.code == "COACHING_SUSPECTED"
        assert hit.reason.code != "ATO_BEHAVIOUR_MISMATCH"


# --- the refusal ------------------------------------------------------------


def _stale_dir(tmp_path: Path, manifest: dict, *, mutate) -> tuple[Path, str]:
    """A copy of the shipped artefacts whose manifest is put through `mutate`.

    Real, loadable .pkl files, so what is being tested is the manifest check and not a corrupt
    pickle: without the check this directory scores happily, which is the defect.
    """
    directory = tmp_path / "stale"
    directory.mkdir()
    owner = manifest["per_user"][0]["user"]
    for name in (ato.COACHING_ARTEFACT, ato.COLD_START_ARTEFACT, f"ato_{owner}.pkl"):
        shutil.copy(COMMITTED / name, directory / name)
    mutated = mutate(json.loads(json.dumps(manifest)))
    (directory / ato.MANIFEST_ARTEFACT).write_text(json.dumps(mutated), encoding="utf-8")
    return directory, owner


def _shrink(manifest: dict) -> dict:
    """The generation before the per-key hold ranks, which is what actually shipped once.

    Derived by dropping the keyrank block rather than hardcoding 39, so this stays a
    short-by-a-block manifest the next time the schema grows.
    """
    names = [name for name in manifest["schema_names"] if not name.startswith("keyrank_")]
    assert len(names) < len(schema.FEATURES), "the keyrank block is gone; pick another cut"
    manifest["schema_names"] = names
    manifest["schema_length"] = len(names)
    return manifest


def _reorder(manifest: dict) -> dict:
    """Same features, same count, two columns swapped. Order IS the wire format."""
    names = list(manifest["schema_names"])
    names[0], names[1] = names[1], names[0]
    manifest["schema_names"] = names
    return manifest


@needs_behaviour_models
@pytest.mark.parametrize("mutate", [_shrink, _reorder], ids=["shorter", "reordered"])
def test_artefacts_fitted_on_another_schema_are_refused_not_scored(
    use_artefacts, manifest, tmp_path, mutate
):
    directory, owner = _stale_dir(tmp_path, manifest, mutate=mutate)
    use_artefacts(directory)

    assert ato.models() is None, "a directory declaring another schema was served"
    # The per-user models are the stale ones, so the refusal has to reach them too.
    assert ato.user_model(owner) is None
    assert ato.behaviour_hits(owner, tuple(0.5 for _ in schema.FEATURES)) == ()


@needs_behaviour_models
def test_the_refusal_is_quiet_rather_than_an_exception(use_artefacts, manifest, tmp_path, caplog):
    """It degrades like every other unusable artefact: no hits, an ERROR in the log, no 500.

    `models()` is called inside a request, so raising here would decline payments instead of
    stopping a bad deployment. ERROR rather than INFO because, unlike an unset directory, this
    is something an operator has to go and fix.
    """
    directory, owner = _stale_dir(tmp_path, manifest, mutate=_shrink)
    use_artefacts(directory)

    with caplog.at_level("INFO", logger="app.ato"):
        assert ato.behaviour_hits(owner, tuple(0.5 for _ in schema.FEATURES)) == ()
    refusals = [r for r in caplog.records if r.levelname == "ERROR" and "fitted against" in r.getMessage()]
    assert len(refusals) == 1, "the refusal has to say why, once"
    assert str(len(schema.FEATURES)) in refusals[0].getMessage()


# --- what is NOT a mismatch -------------------------------------------------


@needs_behaviour_models
def test_a_directory_with_no_manifest_is_served_unverified(use_artefacts, manifest, tmp_path):
    """Unverifiable is not known-stale, and this is the documented choice.

    An artefacts directory assembled by hand, or by a trainer older than the manifest field,
    looks exactly like this - as do the synthetic directories `tests/test_ato_adapter.py`
    builds, which carry no manifest and must keep working. Refusing on absence would trade a
    working signal for a guess; the wire is still protected by `behaviour_hits`'s length check,
    and the directory that actually deploys does carry a manifest (asserted at the top of this
    file).
    """
    directory, owner = _stale_dir(tmp_path, manifest, mutate=lambda m: m)
    (directory / ato.MANIFEST_ARTEFACT).unlink()
    use_artefacts(directory)

    assert ato.models() is not None
    assert ato.user_model(owner) is not None
    assert ato.behaviour_hits(owner, tuple(0.5 for _ in schema.FEATURES))


@needs_behaviour_models
@pytest.mark.parametrize(
    "text",
    [
        "",
        "{",
        "null",
        "[]",
        json.dumps({"schema_length": len(schema.FEATURES)}),
        # The right length and a name that is a bare string, so iterating it would compare
        # single characters against feature names and call every directory stale.
        json.dumps({"schema_names": schema.NAMES[0], "schema_length": len(schema.FEATURES)}),
    ],
    ids=["empty", "truncated", "null", "list", "no-names", "names-not-a-list"],
)
def test_an_unreadable_manifest_is_served_unverified_not_refused(
    use_artefacts, manifest, tmp_path, text
):
    """A manifest that declares nothing cannot disagree with anything.

    Same bucket as an absent one, so a half-written upload degrades the check rather than the
    signal; if the .pkl files went with it, `_load_artefact` reports that file by file.
    """
    directory, owner = _stale_dir(tmp_path, manifest, mutate=lambda m: m)
    (directory / ato.MANIFEST_ARTEFACT).write_text(text, encoding="utf-8")
    use_artefacts(directory)

    assert ato.models() is not None
    assert ato.behaviour_hits(owner, tuple(0.5 for _ in schema.FEATURES))


def test_an_empty_directory_still_starts_and_simply_says_nothing(use_artefacts, tmp_path):
    """The demo deployed before the trainer ran: no manifest, no models, no crash.

    The check must not turn an empty directory into an error - `scripts/deploy.sh` deploys one
    on purpose when the artefacts are absent.
    """
    directory = tmp_path / "empty"
    directory.mkdir()
    use_artefacts(directory)

    loaded = ato.models()
    assert loaded is not None, "an empty directory is not a stale one"
    assert loaded.coaching is None and loaded.cold_start is None
    assert ato.behaviour_hits("rina", tuple(0.5 for _ in schema.FEATURES)) == ()


# --- the refusal that does not need the manifest -----------------------------
#
# Everything above this line can be defeated by editing a text file. `artefacts.json` is the
# trainer's own claim about what it fitted, so a manifest regenerated beside models that were
# never refitted passes it, a directory with no manifest is served unverified on purpose, and a
# single `ato_<uid>.pkl` dropped in from an older generation is never looked up in it at all -
# `user_model` opens that filename directly. The models themselves record the columns they were
# fitted on, which cannot be changed without refitting, so that is what these tests exercise.


@pytest.fixture(scope="module")
def rows(manifest) -> dict:
    """An owner, one of her own sessions, and a session her model rejects.

    Read straight out of the committed pickles rather than through the adapter, so this fixture
    does not care where RISK_MW_ATO_ARTEFACTS_DIR points while a test is rewriting artefacts.
    """
    users = [fit["user"] for fit in manifest["per_user"]]
    owner = users[0]
    identity = ato_model.load(COMMITTED / f"ato_{owner}.pkl")
    stranger_row = next(
        row
        for other in users[1:]
        for row in (
            tuple(float(v) for v in r)
            for r in ato_model.load(COMMITTED / f"ato_{other}.pkl").background
        )
        if identity.score(row) >= ATO_HOLD
    )
    return {
        "owner": owner,
        "own_row": tuple(float(v) for v in identity.background[0]),
        "stranger_row": stranger_row,
    }


def _restale(path: Path, keep: int) -> None:
    """Rewrite one artefact in place as a model fitted on `keep` of its columns.

    The pipeline inside is untouched, so this is exactly the dangerous artefact: it loads, it
    scores, every number it returns looks ordinary, and only its own column list gives it away.
    """
    artefact = ato_model.load(path)
    ato_model.save(dataclasses.replace(artefact, feature_names=artefact.feature_names[:keep]), path)


def _real_dir(tmp_path: Path, owner: str, *, manifest: dict | None = None) -> Path:
    """The shipped coaching, cold-start and one per-user model, copied somewhere writable."""
    directory = tmp_path / "artefacts"
    directory.mkdir()
    for name in (ato.COACHING_ARTEFACT, ato.COLD_START_ARTEFACT, f"ato_{owner}.pkl"):
        shutil.copy(COMMITTED / name, directory / name)
    if manifest is not None:
        (directory / ato.MANIFEST_ARTEFACT).write_text(json.dumps(manifest), encoding="utf-8")
    return directory


@needs_behaviour_models
def test_a_truthful_manifest_beside_a_stale_per_user_model_does_not_save_it(
    use_artefacts, manifest, rows, tmp_path
):
    """The hole the manifest check cannot see, and the reason the second check exists.

    The manifest here is the shipped one, unedited and correct - it declares all 55 features -
    so `_declares_a_different_schema` passes the directory. Her own model is from another
    generation. Without the artefact-level check she is scored by it and the answer looks fine.
    """
    owner = rows["owner"]

    # First the real directory, so the assertion below is not vacuous: this row DOES earn the
    # personalised verdict when her own model is the one that was fitted on this schema.
    use_artefacts(COMMITTED)
    before = {hit.reason.code for hit in ato.behaviour_hits(owner, rows["stranger_row"])}
    assert "ATO_BEHAVIOUR_MISMATCH" in before

    directory = _real_dir(tmp_path, owner, manifest=manifest)
    _restale(directory / f"ato_{owner}.pkl", keep=20)
    use_artefacts(directory)

    assert ato.models() is not None, "the manifest is correct; the directory is not stale"
    assert ato.user_model(owner) is None, "her stale model was served"

    # She is not enrolled as far as this build is concerned, so the personalised verdict is
    # gone and anything the cold-start stand-in says must be labelled as not hers. Measured:
    # the stand-in has no opinion on this particular row at all, which is its own business -
    # it was chosen against HER model, and asserting what the population model makes of it
    # would be a claim about the model rather than about this refusal.
    after = {hit.reason.code for hit in ato.behaviour_hits(owner, rows["stranger_row"])}
    assert "ATO_BEHAVIOUR_MISMATCH" not in after
    assert all(
        code.endswith(ato.COLD_START_SUFFIX) or code == "COACHING_SUSPECTED" for code in after
    ), after


@needs_behaviour_models
def test_a_stale_cold_start_model_in_a_directory_with_no_manifest_is_refused(
    use_artefacts, rows, tmp_path
):
    """The case `_declares_a_different_schema` deliberately serves, caught one level down.

    No manifest at all, so the cheap check waves the directory through with a warning. The
    population model is from another generation, and a user with no artefact of her own would
    be scored entirely by it.
    """
    directory = _real_dir(tmp_path, rows["owner"])
    _restale(directory / ato.COLD_START_ARTEFACT, keep=30)
    use_artefacts(directory)

    loaded = ato.models()
    assert loaded is not None
    assert loaded.cold_start is None, "a stale population model was served"
    assert ato.behaviour_hits("not_an_hmog_user", rows["stranger_row"]) == ()
    # The per-user model is untouched and must keep working: this refusal is per artefact.
    assert ato.user_model(rows["owner"]) is not None


@needs_behaviour_models
def test_a_stale_coaching_model_does_not_cost_us_the_identity_verdict(
    use_artefacts, rows, tmp_path
):
    """Per artefact, not per directory. Losing one signal may not silence the other."""
    directory = _real_dir(tmp_path, rows["owner"])
    _restale(directory / ato.COACHING_ARTEFACT, keep=3)
    use_artefacts(directory)

    assert ato.models().coaching is None, "a stale coaching model was served"
    codes = {hit.reason.code for hit in ato.behaviour_hits(rows["owner"], rows["stranger_row"])}
    assert "ATO_BEHAVIOUR_MISMATCH" in codes, "identity went quiet with the coaching model"
    assert "COACHING_SUSPECTED" not in codes


@needs_behaviour_models
def test_the_artefact_level_refusal_says_which_file_and_why(use_artefacts, rows, tmp_path, caplog):
    directory = _real_dir(tmp_path, rows["owner"])
    _restale(directory / ato.COLD_START_ARTEFACT, keep=30)
    use_artefacts(directory)

    with caplog.at_level("INFO", logger="app.ato"):
        ato.behaviour_hits("not_an_hmog_user", rows["stranger_row"])
    refusals = [
        record for record in caplog.records
        if record.levelname == "ERROR" and "was fitted on" in record.getMessage()
    ]
    assert len(refusals) == 1
    message = refusals[0].getMessage()
    assert ato.COLD_START_ARTEFACT in message
    assert str(len(schema.IDENTITY_FEATURES)) in message


@needs_behaviour_models
def test_a_model_that_records_no_columns_at_all_is_served_unverified(
    use_artefacts, monkeypatch, rows, tmp_path
):
    """An older pickle declares nothing, which is not the same as disagreeing.

    `AtoModel` is a slots dataclass, so a pickle written when it had one field fewer restores
    through `__setstate__`'s zip with `feature_names` never set: measured, it loads, reports no
    attribute and scores 0.854 on a constant row. Reproduced here at the load boundary rather
    than from a file on disk, because this build cannot WRITE such a pickle - `__getstate__`
    reads every field and raises - which is itself why the case can only arrive from an
    older one.
    """
    directory = _real_dir(tmp_path, rows["owner"])
    real_load = ato_model.load

    def load_without_feature_names(path):
        artefact = real_load(path)
        if not isinstance(artefact, ato_model.AtoModel):
            return artefact
        older = object.__new__(ato_model.AtoModel)
        older.__setstate__(list(artefact.__getstate__())[:-1])
        assert getattr(older, "feature_names", None) is None
        return older

    monkeypatch.setattr(ato_model, "load", load_without_feature_names)
    use_artefacts(directory)

    assert ato.models().cold_start is not None, "an unverifiable model was refused"
    assert ato.user_model(rows["owner"]) is not None
    assert ato.behaviour_hits(rows["owner"], rows["stranger_row"]), "the signal went quiet"


@pytest.mark.skipif(_behaviour_models_present(), reason="the behaviour models are present; the tests above cover them")
def test_the_published_repository_without_behaviour_models_gives_no_hits(use_artefacts):
    """No behaviour models are published: the adapter loads nothing, and it says nothing."""
    use_artefacts(COMMITTED)
    loaded = ato.models()
    assert loaded is None or loaded.cold_start is None
    assert ato.user_model("rina") is None
    assert ato.behaviour_hits("rina", tuple(0.0 for _ in schema.FEATURES)) == ()
