"""Pass 3, driven by a fake feature table: the artefacts that ship and the manifest beside them.

No archive is involved and none is faked - `bhorosha_ato.datasets.iter_hmog_sessions` is still a
stub, and the licence for HMOG cannot be scripted. Everything on this side of the table can be
tested now, and these are the properties a trained directory has to have before anyone serves
it: a per-user model fitted on one person, a too-thin persona skipped rather than quietly
handed the global model under her own name, and a manifest that can still answer "which table
did this .pkl come from?" six weeks later.

The fake table is shaped like HMOG rather than like a convenient matrix: reading and
map-navigation sessions carrying no PIN block at all, writing sessions carrying everything.
`extract.IDENTITY_TASKS` is the writing sessions, so a fixture of uniform rows would let these
tests pass while the real thing trained identity on sessions with eleven substituted columns.
"""

from __future__ import annotations

import json
import random
from pathlib import Path

import pytest

from bhorosha_ato import extract, model, synth, train
from bhorosha_ato.extract import SessionRecord, StaleTableError
from bhorosha_ato.model import MIN_ENROLMENT_SESSIONS
from bhorosha_ato.schema import FEATURES, from_vector, to_vector

# Deliberately tiny, like test_extract.py: nothing asserted here is about statistical strength.
# Each eligible user gets 8 writing sessions, as in the real archive. THIN_USER gets one fewer
# than MIN_ENROLMENT_SESSIONS, which is the case the skip logic exists for.
USERS = ("u000", "u001", "u002")
THIN_USER = "u003"
ABSENT_USER = "u404"
PER_IDENTITY_TASK, WRITING, SEED = 3, 8, 30
THIN_SESSIONS = MIN_ENROLMENT_SESSIONS - 1

PIN_FEATURES = tuple(f.name for f in FEATURES if f.block == "pin")


def _blocks(**overrides) -> dict:
    """Every schema block present unless overridden.

    Derived from extract.BLOCKS rather than written out: two blocks were added to the schema
    later and every hand-written four-key dict in these fixtures broke at once.
    """
    blocks = {name: True for name in extract.BLOCKS}
    blocks.update(overrides)
    return blocks


def _without_pin(row: tuple[float, ...]) -> tuple[float, ...]:
    """The same row with the PIN block replaced by its declared `missing` substitutes.

    What a HMOG reading or map-navigation session actually looks like: no typing in it, so
    eleven of the the schema's columns are substitutes rather than measurements.
    """
    return to_vector({
        name: value for name, value in from_vector(row).items() if name not in PIN_FEATURES
    })


def _fake_records(seed: int = SEED) -> list[SessionRecord]:
    """A table the extractor could have written, with HMOG's task structure.

    Values come from `synth` so the users are actually separable; session ids restart at 0 for
    every user on purpose, because HMOG numbers sessions within a user and that is what makes
    `SessionRecord.key` necessary for any overlap check.
    """
    rng = random.Random(seed)
    records: list[SessionRecord] = []
    for user, writing in [(u, WRITING) for u in USERS] + [(THIN_USER, THIN_SESSIONS)]:
        profile = synth.user_profile(rng)
        session = 0
        for task in ("reading", "map"):
            for _ in range(PER_IDENTITY_TASK):
                records.append(SessionRecord(
                    user=user,
                    session=f"session_{session}",
                    task=task,
                    features=_without_pin(synth.genuine_row(profile, rng)),
                    blocks_present=_blocks(pin=False),
                ))
                session += 1
        for _ in range(writing):
            records.append(SessionRecord(
                user=user,
                session=f"session_{session}",
                task="writing",
                features=synth.genuine_row(profile, rng),
                blocks_present=_blocks(),
            ))
            session += 1
    return records


def _write(directory: Path, seed: int = SEED) -> Path:
    table = directory / "hmog_features.jsonl"
    extract.write_table(_fake_records(seed), table, dataset="hmog", source="fake://no-archive")
    return table


@pytest.fixture(scope="module")
def table(tmp_path_factory) -> Path:
    return _write(tmp_path_factory.mktemp("train_table"))


@pytest.fixture(scope="module")
def out(tmp_path_factory, table: Path) -> Path:
    directory = tmp_path_factory.mktemp("train_out")
    train.train_artefacts(table, directory, users=[*USERS, THIN_USER, ABSENT_USER], seed=SEED)
    return directory


@pytest.fixture(scope="module")
def artefacts(out: Path) -> dict:
    return json.loads((out / train.MANIFEST_FILE).read_text(encoding="utf-8"))


# --- the per-user artefacts -----------------------------------------------

def test_a_per_user_artefact_loads_and_scores_its_owner(out: Path, table: Path):
    """The whole point of the pass: a file the service can load and score a session with."""
    fitted = model.load(out / train.ato_file("u000"))
    assert isinstance(fitted, model.AtoModel)
    assert fitted.per_user is True

    sessions = extract.group_by_user(extract.read_table(table), extract.IDENTITY_TASKS)
    scores = fitted.scores([record.features for record in sessions["u000"]])
    assert all(0.0 <= score <= 1.0 for score in scores)
    # Her own sessions must sit below the step-up line, or the artefact would challenge her on
    # every payment she makes.
    assert max(scores) < 0.60, f"the owner's own sessions score {scores} against her own model"


def test_a_per_user_model_scores_a_stranger_higher_than_its_owner(out: Path, table: Path):
    sessions = extract.group_by_user(extract.read_table(table), extract.IDENTITY_TASKS)
    fitted = model.load(out / train.ato_file("u000"))
    owner = fitted.scores([r.features for r in sessions["u000"]])
    stranger = fitted.scores([r.features for r in sessions["u001"]])
    assert min(stranger) > max(owner), (
        f"owner {owner} vs stranger {stranger}: the shipped artefact does not separate them"
    )


def test_a_per_user_model_never_saw_another_users_sessions(artefacts: dict):
    """Recorded per user, so this is checkable from the directory alone and not just here.

    The ids are `extract.SessionRecord.key`, i.e. user-qualified: HMOG numbers sessions within a
    user, so on bare ids a check like this would compare "session_3" against "session_3" and
    pass whatever happened.
    """
    for entry in artefacts["per_user"]:
        assert entry["train_session_ids"], entry
        assert all(key.startswith(f"{entry['user']}/") for key in entry["train_session_ids"])
        assert len(set(entry["train_session_ids"])) == entry["n_train_sessions"]

    ids = [key for entry in artefacts["per_user"] for key in entry["train_session_ids"]]
    assert len(ids) == len(set(ids)), "one session trained two different personas' models"


def test_mixed_ownership_is_an_assertion_not_a_silent_fit(table: Path):
    """A model fitted on two people scores well on both, and the .pkl cannot reveal it."""
    sessions = extract.group_by_user(extract.read_table(table), extract.IDENTITY_TASKS)
    mixed = sessions["u000"] + sessions["u001"][:1]
    with pytest.raises(AssertionError, match="one person's sessions"):
        train.train_user_model(mixed, "u000")


def test_identity_models_are_fitted_on_the_identity_tasks_only(table: Path):
    """Mixing tasks makes the model separate tasks rather than people - see IDENTITY_TASKS."""
    records = extract.read_table(table)
    sessions = extract.group_by_user(records, extract.IDENTITY_TASKS)["u000"]
    reading = [r for r in records if r.user == "u000" and r.task == "reading"]
    with pytest.raises(AssertionError, match="extract.IDENTITY_TASKS"):
        train.train_user_model(sessions + reading, "u000")


def test_only_the_requested_personas_get_artefacts(table: Path, tmp_path: Path):
    train.train_artefacts(table, tmp_path, users=["u001"], seed=SEED)
    assert {p.name for p in tmp_path.glob("ato_*.pkl")} == {train.ato_file("u001")}


def test_a_user_id_that_cannot_become_a_filename_is_refused():
    """`ato_{user}.pkl` is written into --out and read back by name."""
    for bad in ("../escape", "a/b", "", "has space", ".hidden"):
        with pytest.raises(ValueError, match="cannot become a filename"):
            train.ato_file(bad)


# --- the users who must NOT get a per-user artefact ------------------------

def test_a_thin_user_is_skipped_rather_than_silently_globalised(out: Path, artefacts: dict):
    """`ato_u003.pkl` holding the population model would be served as personalised."""
    assert not (out / train.ato_file(THIN_USER)).exists()
    assert train.ato_file(THIN_USER) not in artefacts["files"]
    assert THIN_USER not in {entry["user"] for entry in artefacts["per_user"]}

    skipped = {entry["user"]: entry for entry in artefacts["skipped_users"]}
    assert skipped[THIN_USER]["identity_sessions"] == THIN_SESSIONS
    assert "MIN_ENROLMENT_SESSIONS" in skipped[THIN_USER]["reason"]
    assert train.COLD_START_FILE in skipped[THIN_USER]["reason"]


def test_a_requested_user_absent_from_the_table_is_recorded_not_dropped(artefacts: dict):
    skipped = {entry["user"]: entry for entry in artefacts["skipped_users"]}
    assert skipped[ABSENT_USER]["identity_sessions"] == 0
    assert "not in" in skipped[ABSENT_USER]["reason"]


def test_a_thin_user_cannot_be_forced_through_the_per_user_path(table: Path):
    sessions = extract.group_by_user(extract.read_table(table), extract.IDENTITY_TASKS)
    with pytest.raises(AssertionError, match="MIN_ENROLMENT_SESSIONS"):
        train.train_user_model(sessions[THIN_USER], THIN_USER)


# --- the two global artefacts ---------------------------------------------

def test_the_cold_start_model_is_distinguishable_from_a_per_user_one(out: Path, artefacts: dict):
    """The distinction the whole skip logic rests on, checkable from the file and the manifest."""
    cold_start = model.load(out / train.COLD_START_FILE)
    assert isinstance(cold_start, model.AtoModel)
    assert cold_start.per_user is False
    assert model.load(out / train.ato_file("u000")).per_user is True

    assert artefacts["cold_start"]["per_user"] is False
    assert artefacts["files"][train.COLD_START_FILE]["kind"] == "population_identity"
    assert all(entry["kind"] == "per_user_identity"
               for name, entry in artefacts["files"].items() if name.startswith("ato_"))


def test_the_cold_start_model_learned_from_the_population_not_one_person(
    table: Path, artefacts: dict
):
    """It is the only artefact here fitted across users, and the manifest has to say so."""
    sessions = extract.group_by_user(extract.read_table(table), extract.IDENTITY_TASKS)
    total = sum(len(records) for records in sessions.values())
    assert artefacts["cold_start"]["n_train_sessions"] == total
    assert artefacts["cold_start"]["users"] == len(sessions)
    # Including the thin user: she has no model of her own, so the fallback has to have seen a
    # population that includes people like her.
    assert total > sum(entry["n_train_sessions"] for entry in artefacts["per_user"])


def test_the_cold_start_model_scores_a_session_it_never_saw(out: Path):
    cold_start = model.load(out / train.COLD_START_FILE)
    rng = random.Random(7)
    rows = synth.genuine_rows(synth.user_profile(rng), 3, rng)
    assert all(0.0 <= cold_start.score(row) <= 1.0 for row in rows)


def test_the_coaching_artefact_loads_and_separates_coached_sessions(out: Path, table: Path):
    coaching = model.load(out / train.COACHING_FILE)
    assert isinstance(coaching, model.CoachingModel)
    assert coaching.feature_names == synth.COACHING_FEATURES

    rng = random.Random(SEED)
    sessions = extract.group_by_user(extract.read_table(table), extract.COACHING_TASKS)
    genuine = [record.features for record in sessions["u000"]]
    genuine_scores = coaching.scores(synth.coaching_matrix(genuine))
    coached_scores = coaching.scores(
        synth.coaching_matrix(synth.coached_rows(genuine, rng))
    )
    assert max(genuine_scores) < 0.6 <= min(coached_scores), (
        f"genuine {genuine_scores} vs coached {coached_scores}: the shipped coaching model does "
        "not separate the two at the threshold the product acts on"
    )


def test_the_coaching_artefact_is_labelled_as_partly_generated(artefacts: dict):
    """Half its training data cannot be measured, and the directory has to admit it."""
    assert "GENERATED" in artefacts["coaching"]["source"]
    assert "synth.coach" in artefacts["coaching"]["source"]
    assert artefacts["files"][train.COACHING_FILE]["kind"] == "global_coaching"


# --- the manifest ---------------------------------------------------------

def test_the_manifest_names_every_file_written_with_its_size(out: Path, artefacts: dict):
    """Without this, "which .pkl is in this directory and how big" needs a shell."""
    on_disk = {path.name for path in out.iterdir()} - {train.MANIFEST_FILE}
    assert set(artefacts["files"]) == on_disk
    for name, entry in artefacts["files"].items():
        assert entry["bytes"] == (out / name).stat().st_size > 0
        assert len(entry["sha256"]) == 64
    assert train.COLD_START_FILE in artefacts["files"]
    assert train.COACHING_FILE in artefacts["files"]


def test_the_manifest_records_which_table_and_seed_produced_the_artefacts(
    table: Path, artefacts: dict
):
    """The failure this manifest exists for: a .pkl from a stale table looks exactly like a
    fresh one, and nothing inside the pickle can tell them apart."""
    expected = extract.read_manifest(table)
    # The name, never the path: this file is committed, so an absolute path would record whose
    # machine ran the trainer. The checksum is what identifies the table.
    assert artefacts["table"]["file"] == table.name
    assert "path" not in artefacts["table"]
    assert str(table.parent) not in json.dumps(artefacts)
    assert artefacts["table"]["table_sha256"] == expected.table_sha256
    assert artefacts["table"]["rows"] == expected.rows
    assert artefacts["table"]["dataset"] == "hmog"
    assert artefacts["table"]["extractor_version"] == extract.EXTRACTOR_VERSION
    assert artefacts["seed"] == SEED
    assert artefacts["artefact_version"] == train.ARTEFACT_VERSION


def test_the_manifest_records_the_schema_the_models_were_fitted_against(artefacts: dict):
    """Positions are the wire format, so a model beside a different schema scores garbage."""
    assert artefacts["schema_length"] == len(FEATURES)
    assert artefacts["schema_names"] == [f.name for f in FEATURES]
    assert artefacts["identity_tasks"] == list(extract.IDENTITY_TASKS)
    assert artefacts["coaching_tasks"] == list(extract.COACHING_TASKS)


def test_a_leftover_per_user_artefact_from_an_earlier_table_is_listed(table: Path, tmp_path: Path):
    """The service loads the directory by name, so a stray ato_*.pkl would be served as current."""
    stale = tmp_path / train.ato_file("u999")
    stale.write_bytes(b"not a model")
    written = train.train_artefacts(table, tmp_path, users=["u000"], seed=SEED)
    assert written["unlisted_per_user_files"] == [stale.name]
    assert stale.name not in written["files"]


# --- determinism ----------------------------------------------------------

def test_the_same_table_and_seed_record_the_same_session_ids(table: Path, tmp_path: Path):
    first = train.train_artefacts(table, tmp_path / "a", users=list(USERS), seed=SEED)
    second = train.train_artefacts(table, tmp_path / "b", users=list(USERS), seed=SEED)
    assert first["per_user"] == second["per_user"]
    assert first["skipped_users"] == second["skipped_users"]
    assert first["cold_start"] == second["cold_start"]


def test_the_same_table_and_seed_produce_byte_identical_models(table: Path, tmp_path: Path):
    """Measured, not assumed: the fits are either seedless or carry a fixed random_state, and
    the row order comes from `extract.group_by_user`'s sorted output rather than from the order
    the extractor walked the archive in."""
    first = train.train_artefacts(table, tmp_path / "a", users=list(USERS), seed=SEED)
    second = train.train_artefacts(table, tmp_path / "b", users=list(USERS), seed=SEED)
    assert {n: e["sha256"] for n, e in first["files"].items()} == {
        n: e["sha256"] for n, e in second["files"].items()
    }


def test_a_different_seed_only_moves_the_coaching_model(table: Path, tmp_path: Path):
    """--seed drives the GENERATED coached sessions and nothing else; the identity artefacts
    must not quietly depend on it, or "same table, same model" would stop being true."""
    first = train.train_artefacts(table, tmp_path / "a", users=list(USERS), seed=SEED)
    other = train.train_artefacts(table, tmp_path / "b", users=list(USERS), seed=SEED + 1)
    identity = [train.ato_file(u) for u in USERS] + [train.COLD_START_FILE]
    assert [first["files"][n]["sha256"] for n in identity] == [
        other["files"][n]["sha256"] for n in identity
    ]
    assert first["files"][train.COACHING_FILE]["sha256"] != \
        other["files"][train.COACHING_FILE]["sha256"]


# --- the command line -----------------------------------------------------

def test_main_writes_the_whole_directory(table: Path, tmp_path: Path, capsys):
    assert train.main(["--table", str(table), "--out", str(tmp_path), "--users", *USERS,
                       "--seed", str(SEED)]) == 0
    assert {path.name for path in tmp_path.iterdir()} == {
        *(train.ato_file(user) for user in USERS),
        train.COLD_START_FILE, train.COACHING_FILE, train.MANIFEST_FILE,
    }
    printed = json.loads(capsys.readouterr().out)
    assert printed["per_user_models"] == len(USERS)
    assert printed["table_sha256"] == extract.read_manifest(table).table_sha256


def test_main_defaults_to_every_eligible_user_in_the_table(table: Path, tmp_path: Path):
    """The default has to exclude the thin user, not fall back to a global model for her."""
    assert train.main(["--table", str(table), "--out", str(tmp_path)]) == 0
    assert {path.name for path in tmp_path.glob("ato_*.pkl")} == {
        train.ato_file(user) for user in USERS
    }


def test_main_refuses_a_missing_table_and_names_the_pass_that_writes_it(tmp_path: Path):
    with pytest.raises(SystemExit, match="bhorosha_ato.extract"):
        train.main(["--table", str(tmp_path / "nope.jsonl"), "--out", str(tmp_path)])


def test_a_truncated_table_is_refused_rather_than_trained_on(tmp_path: Path):
    """A truncated table still parses, still fits, and the .pkl it writes looks healthy."""
    table = _write(tmp_path)
    lines = table.read_text(encoding="utf-8").splitlines(keepends=True)
    table.write_text("".join(lines[:-4]), encoding="utf-8")

    with pytest.raises(StaleTableError):
        train.train_artefacts(table, tmp_path / "out", users=list(USERS), seed=SEED)
    with pytest.raises(SystemExit, match="disagrees with its manifest"):
        train.main(["--table", str(table), "--out", str(tmp_path / "out")])


# --- demo personas ---------------------------------------------------------
#
# Rina, Rafiq and Rahima are fictional. The app sends `user_id: "rina"` and app.ato looks for
# ato_rina.pkl, so without a persona artefact the service falls back to cold_start.pkl and
# challenges her own normal payments - which is the one thing the demo's green path cannot do.
# Her behaviour therefore has to be borrowed from a real volunteer, and the point of these
# tests is that the borrowing is recorded rather than hidden behind a copied filename.

PERSONA, PERSONA_SOURCE = "rina", "u000"


@pytest.fixture(scope="module")
def persona_out(tmp_path_factory, table: Path) -> Path:
    directory = tmp_path_factory.mktemp("train_persona")
    train.train_artefacts(
        table, directory, users=list(USERS), seed=SEED,
        personas={PERSONA: PERSONA_SOURCE, "ghost": ABSENT_USER},
    )
    return directory


@pytest.fixture(scope="module")
def persona_manifest(persona_out: Path) -> dict:
    return json.loads((persona_out / train.MANIFEST_FILE).read_text(encoding="utf-8"))


def test_a_persona_artefact_is_written_under_her_own_name(persona_out: Path):
    """app.ato looks for ato_{user_id}.pkl, so the filename is the whole integration."""
    fitted = model.load(persona_out / train.ato_file(PERSONA))
    assert isinstance(fitted, model.AtoModel)
    assert fitted.per_user is True, "a persona served as personalised must not be the global model"


def test_a_persona_scores_her_source_sessions_below_the_step_up_line(
    persona_out: Path, table: Path
):
    """The reason she exists: her normal sessions have to pass, or the green path never goes green."""
    sessions = extract.group_by_user(extract.read_table(table), extract.IDENTITY_TASKS)
    fitted = model.load(persona_out / train.ato_file(PERSONA))
    scores = fitted.scores([r.features for r in sessions[PERSONA_SOURCE]])
    assert max(scores) < 0.60, f"persona {PERSONA} challenges her own sessions: {scores}"


def test_a_persona_is_identical_to_the_model_of_the_user_she_borrows(
    persona_out: Path, table: Path
):
    """Borrowed, not re-fitted on something else: same sessions in, so same scores out."""
    sessions = extract.group_by_user(extract.read_table(table), extract.IDENTITY_TASKS)
    rows = [r.features for r in sessions[PERSONA_SOURCE]]
    persona = model.load(persona_out / train.ato_file(PERSONA))
    source = model.load(persona_out / train.ato_file(PERSONA_SOURCE))
    assert persona.scores(rows) == source.scores(rows)


def test_the_manifest_says_whose_sessions_a_persona_borrows(persona_manifest: dict):
    """The provenance question - "whose data is ato_rina.pkl?" - answerable from the directory."""
    entry = next(e for e in persona_manifest["per_user"] if e["user"] == PERSONA)
    assert entry["source_user"] == PERSONA_SOURCE
    assert all(sid.startswith(f"{PERSONA_SOURCE}/") for sid in entry["train_session_ids"])
    note = persona_manifest["files"][train.ato_file(PERSONA)]["note"]
    assert PERSONA_SOURCE in note and PERSONA in note


def test_a_table_user_records_itself_as_its_own_source(persona_manifest: dict):
    entry = next(e for e in persona_manifest["per_user"] if e["user"] == "u001")
    assert entry["source_user"] == "u001"


def test_a_persona_whose_source_is_missing_is_skipped_with_the_reason(persona_manifest: dict):
    """Never the global model under her name - the same rule as for a too-thin table user."""
    skipped = {e["user"]: e for e in persona_manifest["skipped_users"]}
    assert "ghost" in skipped
    assert ABSENT_USER in skipped["ghost"]["reason"]
    assert train.ato_file("ghost") not in persona_manifest["files"]


def test_a_persona_may_not_shadow_a_real_table_user(table: Path, tmp_path: Path):
    """Two models named ato_u000.pkl, one borrowed, would make the directory a liar."""
    with pytest.raises(ValueError, match="shadow"):
        train.train_artefacts(
            table, tmp_path, users=list(USERS), seed=SEED, personas={"u000": "u001"},
        )


def test_the_cli_parses_persona_pairs():
    assert train._parse_personas(["rina=100669", "rahima=151985"]) == {
        "rina": "100669", "rahima": "151985",
    }


@pytest.mark.parametrize("bad", ["rina", "=100669", "rina=", "../etc=u000"])
def test_the_cli_refuses_a_malformed_persona_pair(bad: str):
    """An error, not a skip: a silent drop writes a directory with no ato_rina.pkl and no reason."""
    with pytest.raises(SystemExit):
        train._parse_personas([bad])
