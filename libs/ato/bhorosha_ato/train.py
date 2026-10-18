"""Pass 3: a feature table in, the small artefacts that ship out .

    python -m bhorosha_ato.train --table ../../models/ato/hmog_features.jsonl \
        --out ../../models/ato --users 100669 151985 171538

Pass 1 (`bhorosha_ato.extract`) turns the 6 GB archive into a compact table; pass 2
(`eval/ato_eval.py`) measures what the models can do on it; this pass writes the files the
service loads at start-up:

    ato_{user}.pkl   one per demo persona, fitted ONLY on that person's own enrolment sessions
    coaching.pkl     one global coaching model - it answers a question about a situation
    cold_start.pkl   the global fallback for a user below model.MIN_ENROLMENT_SESSIONS
    artefacts.json   which table every file above came from, and which sessions trained it

Why the manifest is not decoration. A .pkl carries no record of the table it was fitted on, so
a model trained on a stale or truncated extraction is as plausible as a fresh one and "which
extraction is this model from?" has no answer six weeks later. `artefacts.json` records the
table path and the checksum `extract.read_table` verified, the seed, the schema length and the
exact session ids behind every per-user model - and those ids are also what lets a later eval
be checked for overlap against what actually shipped.

Why a per-user and a population model must never share a filename. `cold_start.pkl` is the one
identity artefact here fitted on the POPULATION; everything called `ato_{user}.pkl` is fitted
on one person and nobody else. A cold-start model written as `ato_rina.pkl` would be served as
personalised while being nothing of the kind, so a persona with too few sessions is skipped and
the reason recorded in the manifest rather than quietly globalised.

No metrics are produced here. An EER needs held-out sessions and impostors, and these artefacts
are deliberately fitted on everything the person has - measuring and shipping are two different
commands, and `eval/ato_eval.py` is the one that reports numbers.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import random
import re
import sys
import time
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

from bhorosha_ato import extract, model, synth
from bhorosha_ato.model import MIN_ENROLMENT_SESSIONS
from bhorosha_ato.schema import FEATURES, NAMES

# Bumped whenever the meaning of a field in artefacts.json or the layout of the directory
# changes, so a directory written by an older trainer is a visible mismatch to whatever loads
# it rather than a silent misreading.
ARTEFACT_VERSION = 1

# Sits beside the mule artefacts under models/, relative to libs/ato, which is where this module
# and eval/ato_eval.py are both run from.
DEFAULT_OUT = Path("../../models/ato")

# Fixed names, because the service loads them from a directory by name rather than being told
# each path. A renamed artefact is a start-up failure in the risk-mw, not something it can
# recover from, so the names live here and nowhere else.
COACHING_FILE = "coaching.pkl"
COLD_START_FILE = "cold_start.pkl"
MANIFEST_FILE = "artefacts.json"

# Same default as eval/ato_eval.py, so the two commands line up in the plan's three-command run.
DEFAULT_SEED = 30

# `nu` is ignored by the IsolationForest branch of `model._fit_pipeline`; it is passed only so
# the cold-start fit goes through exactly the same helper as every other fit.
_COLD_START_NU = 0.08

# User ids reach the filesystem as `ato_{user}.pkl`, so they are checked rather than trusted. An
# id carrying a slash or a `..` would write outside --out, and an id carrying a space would
# produce a filename the service cannot predict. HMOG's ids are numeric; this is about what
# happens when the next dataset's are not.
_SAFE_USER = re.compile(r"\A[A-Za-z0-9][A-Za-z0-9_.-]*\Z")


def ato_file(user: str) -> str:
    """Artefact filename for one persona. The only place this name is spelled."""
    if not _SAFE_USER.match(user) or ".." in user:
        raise ValueError(
            f"user id {user!r} cannot become a filename: ato_{{user}}.pkl is written into --out "
            "and read back by name, so ids are restricted to letters, digits, '_', '.' and '-'"
        )
    return f"ato_{user}.pkl"


@dataclass(frozen=True, slots=True)
class PerUserFit:
    """One persona's artefact, with the sessions that trained it.

    The ids travel with the model for the same reason `model.Split` carries them: a claim about
    which sessions trained something is worthless if nobody can check it, and checking a later
    eval for overlap against what shipped needs these exact ids.
    """

    user: str
    file: str
    fitted: model.AtoModel
    session_ids: tuple[str, ...]
    # Whose sessions actually trained it. Equal to `user` for a table user; different for a
    # demo persona, whose behaviour has to be borrowed from a real volunteer because Rina is
    # fictional and has no sessions of her own. Recorded so "whose data is ato_rina.pkl?" is
    # answerable from the manifest rather than from somebody's memory.
    source_user: str = ""


@dataclass(frozen=True, slots=True)
class SkippedUser:
    """A requested persona that did NOT get an artefact, and why.

    Recorded rather than dropped: a persona missing from the directory with no explanation looks
    like a trainer bug, and the alternative - writing the global model under her name - is the
    one outcome this pass exists to prevent.
    """

    user: str
    identity_sessions: int
    reason: str


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def train_user_model(
    sessions: list[extract.SessionRecord],
    user: str,
    reference: list[extract.SessionRecord] | None = None,
    source_user: str | None = None,
) -> PerUserFit:
    """Fit one persona's identity model on her own enrolment sessions and nothing else.

    The ownership check is an assertion rather than a convention. Nothing in the fitted pipeline
    records whose sessions went into it, so one wrong `group_by_user` key would produce an
    `ato_rina.pkl` fitted partly on someone else - a model that scores well on two people, which
    is exactly the failure a one-class identity model must not have and which no downstream test
    on the artefact alone could detect.
    """
    # The artefact is named for `user`; the sessions belong to `source`. They differ only for a
    # demo persona. The assertion is unchanged in strength - still exactly one owner - because
    # the failure it guards against (a model fitted on two people, which scores well on both)
    # does not care what the file is called.
    source = source_user or user
    owners = sorted({record.user for record in sessions})
    if owners != [source]:
        raise AssertionError(
            f"{ato_file(user)} would be fitted on sessions from {owners}: a per-user identity "
            f"model must see one person's sessions ({source}) and no one else's"
        )
    tasks = sorted({record.task for record in sessions})
    if set(tasks) - set(extract.IDENTITY_TASKS):
        raise AssertionError(
            f"{user}: identity sessions {tasks} include a task outside "
            f"extract.IDENTITY_TASKS {list(extract.IDENTITY_TASKS)}; mixing tasks makes the "
            "model separate tasks rather than people (see extract.IDENTITY_TASKS)"
        )
    if len(sessions) < MIN_ENROLMENT_SESSIONS:
        raise AssertionError(
            f"{user}: {len(sessions)} identity sessions is below MIN_ENROLMENT_SESSIONS "
            f"({MIN_ENROLMENT_SESSIONS}), so train_ato would fall back to a global model and "
            f"{ato_file(user)} would be presented as personalised"
        )

    # The reference is other people's sessions, never trained on, scored through this user's own
    # pipeline so the 0.60 threshold can be placed where owner-rejection and impostor-acceptance
    # actually cross. Without it train_ato keeps the old quantile anchors, which estimate a 5th
    # percentile from five k-fold margins and fire on a third of the owner's own sessions.
    own = {record.key for record in sessions}
    reference_rows = [
        record.features for record in (reference or [])
        if record.user != source and record.key not in own
    ]
    # Too small a reference is passed as none rather than as an error. A table with only a few
    # users cannot resolve the acceptance rate the crossover is placed at, and refusing outright
    # would make the trainer unusable on exactly the small tables the tests and a first run use.
    # The fallback is the documented quantile path, and the calibration records which it took.
    if len(reference_rows) < model.MIN_REFERENCE_SESSIONS:
        reference_rows = []
    fitted = model.train_ato(
        [record.features for record in sessions],
        reference=reference_rows or None,
    )
    if not fitted.per_user:
        raise AssertionError(
            f"{user}: train_ato returned a population model for {len(sessions)} sessions; "
            f"{ato_file(user)} must not claim to be personalised"
        )
    # Session keys, not bare session ids: HMOG numbers sessions within a user, so an overlap
    # check on bare ids would compare "session_3" against "session_3" and pass whatever
    # happened. `extract.SessionRecord.key` is user-qualified for that reason.
    return PerUserFit(
        user=user,
        file=ato_file(user),
        fitted=fitted,
        session_ids=tuple(record.key for record in sessions),
        source_user=source,
    )


def train_cold_start(records: list[extract.SessionRecord]) -> model.AtoModel:
    """The one identity artefact fitted on the POPULATION rather than on one person.

    This is the fallback for a user with fewer than MIN_ENROLMENT_SESSIONS sessions of her own:
    too few to generalise from, so a model of how people in general touch a phone stands in
    until she has used the app a few times. It is a weaker, different claim than any
    `ato_{user}.pkl` makes, which is why it gets its own filename and carries `per_user=False`.

    `train_ato` infers `per_user` from the number of rows it is handed, and the population has
    hundreds, so left to itself it would fit a per-user OneClassSVM and label it
    `per_user=True`. Which kind of model a cold-start artefact is must not depend on how much
    data happened to be available, so the kind is stated explicitly rather than inferred.

    One measured surprise worth stating rather than discovering during a deploy: this is the one
    artefact that is NOT tiny. `model._fit_pipeline` fits `IsolationForest(n_estimators=200)`,
    and 200 pickled trees come to ~2.3 MB against ~3.6 KB for a per-user SVM. Still trivial to
    load, but the plan's "5 KB each" is true of the per-user and coaching artefacts only, and
    the per-file sizes in artefacts.json are there so nobody has to guess.
    """
    if not records:
        raise ValueError("no identity sessions in the table to fit a cold-start model on")

    rows = [record.features for record in records]
    return model.train_ato(rows, nu=_COLD_START_NU, per_user=False)


def train_coaching_model(
    records: list[extract.SessionRecord], rng: random.Random
) -> model.CoachingModel:
    """One global coaching model: genuine typing sessions against their coached counterparts.

    Global rather than per-user because the question is about a situation, not about a person -
    hesitation and dead gaps look the same whoever is being talked through the payment.

    The coached side is GENERATED by `synth.coach` and can only be generated: no public dataset
    records a person being coached through a payment. That is a limitation of the model this
    file writes, not of this file, and `artefacts.json` says so beside the artefact.
    """
    if not records:
        raise ValueError("no coaching-task sessions in the table to fit a coaching model on")

    genuine = [record.features for record in records]
    return model.train_coaching(
        synth.coaching_matrix(genuine),
        synth.coaching_matrix(synth.coached_rows(genuine, rng)),
        synth.COACHING_FEATURES,
    )


def _resolve_users(
    identity_sessions: dict[str, list[extract.SessionRecord]], users: list[str] | None
) -> list[str]:
    """Which personas were asked for, in a fixed order.

    Sorted rather than left in the order given on the command line, so two runs that name the
    same personas differently still write the same manifest.
    """
    if users is None:
        return sorted(identity_sessions)
    return sorted(dict.fromkeys(users))


def train_artefacts(
    table: Path,
    out: Path,
    users: list[str] | None = None,
    seed: int = DEFAULT_SEED,
    personas: dict[str, str] | None = None,
) -> dict:
    """Fit and write every artefact, and return the manifest that was written.

    `read_table` verifies the table against its manifest first, so a truncated or hand-edited
    extraction is refused here rather than baked into a .pkl that looks fine.

    Deterministic by construction: the fits are seeded inside sklearn or seedless (OneClassSVM,
    StandardScaler, LogisticRegression, and IsolationForest with a fixed random_state), the row
    order comes from `extract.group_by_user`'s sorted output rather than from the order the
    extractor walked the archive, and `--seed` drives the only random thing left - the generated
    coached counterparts the coaching model is fitted against.
    """
    # Either format, picked by the manifest's extractor version. This entry point read only the
    # version 1 positional table until agent B measured that it raised StaleTableError on the
    # one real table we have (80 columns against a 39-feature schema) - so the trainer a deploy
    # would run was dead on real data, and artefacts had to be built one call below it.
    records = extract.read_any_table(table)
    manifest = extract.read_manifest(table)
    identity_sessions = extract.group_by_user(records, extract.IDENTITY_TASKS)
    coaching_sessions = extract.group_by_user(records, extract.COACHING_TASKS)

    requested = _resolve_users(identity_sessions, users)
    # persona name -> the table user whose sessions stand in for her. Rina, Rafiq and Rahima are
    # fictional: the app sends `user_id: "rina"` and app.ato looks for ato_rina.pkl, so without
    # this the service falls back to cold_start.pkl and challenges her own normal payments.
    # Kept separate from `requested` so a persona can never silently shadow a real table user.
    aliases = dict(personas or {})
    for persona in sorted(aliases):
        if persona in requested:
            raise ValueError(
                f"--persona {persona}= collides with a user already in the table; a persona "
                "must not shadow the person whose sessions it borrows"
            )
    # Built before the per-user loop because each per-user model is calibrated against it. Each
    # user's own rows are filtered out inside train_user_model, so nobody is their own impostor.
    population = [record for sessions in identity_sessions.values() for record in sessions]
    fits: list[PerUserFit] = []
    skipped: list[SkippedUser] = []
    for user in requested:
        sessions = identity_sessions.get(user, [])
        if len(sessions) < MIN_ENROLMENT_SESSIONS:
            # Skipped, never globalised under her name. The count and the reason go into the
            # manifest so "why is there no ato_rina.pkl?" is answerable from the directory.
            reason = (
                f"not in {table.name} at all"
                if not sessions
                else f"{len(sessions)} identity sessions, below MIN_ENROLMENT_SESSIONS "
                     f"({MIN_ENROLMENT_SESSIONS}); cold_start.pkl serves this user instead"
            )
            skipped.append(SkippedUser(user, len(sessions), reason))
            continue
        fits.append(train_user_model(sessions, user, reference=population))

    for persona in sorted(aliases):
        source = aliases[persona]
        sessions = identity_sessions.get(source, [])
        if len(sessions) < MIN_ENROLMENT_SESSIONS:
            reason = (
                f"stands in for {source}, which is not in {table.name} at all"
                if not sessions
                else f"stands in for {source}, which has {len(sessions)} identity sessions, "
                     f"below MIN_ENROLMENT_SESSIONS ({MIN_ENROLMENT_SESSIONS}); cold_start.pkl "
                     "serves this persona instead"
            )
            skipped.append(SkippedUser(persona, len(sessions), reason))
            continue
        fits.append(
            train_user_model(sessions, persona, reference=population, source_user=source)
        )

    # Both global artefacts are fitted on the whole table, not on the requested personas: they
    # are population models, and narrowing them to three demo users would make them worse for no
    # reason while leaving the filenames unchanged.
    cold_start = train_cold_start(population)
    coaching_rows = [record for sessions in coaching_sessions.values() for record in sessions]
    coaching = train_coaching_model(coaching_rows, random.Random(seed))

    out.mkdir(parents=True, exist_ok=True)
    # Anything matching the per-user pattern that was here before this run. Listed below rather
    # than deleted: a leftover ato_*.pkl from an earlier table would be loaded by the service as
    # a current persona, and the manifest is the only place that can say it is not one.
    pre_existing = {path.name for path in out.glob("ato_*.pkl")}

    files: dict[str, dict] = {}

    def _record(name: str, kind: str, note: str) -> None:
        path = out / name
        files[name] = {
            "bytes": path.stat().st_size,
            "sha256": _sha256(path),
            "kind": kind,
            "note": note,
        }

    for fit in fits:
        model.save(fit.fitted, out / fit.file)
        _record(
            fit.file,
            "per_user_identity",
            f"fitted on {fit.source_user}'s own {len(fit.session_ids)} "
            f"{'+'.join(extract.IDENTITY_TASKS)} sessions and no one else's"
            + (f", served as persona {fit.user}" if fit.source_user != fit.user else ""),
        )
    model.save(cold_start, out / COLD_START_FILE)
    _record(
        COLD_START_FILE,
        "population_identity",
        "the ONLY identity artefact fitted on the population rather than on one person; the "
        f"fallback below MIN_ENROLMENT_SESSIONS ({MIN_ENROLMENT_SESSIONS}) sessions, and never "
        "to be served under an ato_{user}.pkl name",
    )
    model.save(coaching, out / COACHING_FILE)
    _record(
        COACHING_FILE,
        "global_coaching",
        "global by nature - it answers a question about a situation, not about a person; the "
        "coached side of its training data is GENERATED by synth.coach, because no public "
        "dataset records a person being talked through a payment",
    )

    artefacts = {
        "artefact_version": ARTEFACT_VERSION,
        "seed": seed,
        "generated_at": datetime.now(UTC).isoformat(),
        # Where every file above came from. The checksum is the one `extract.read_table` just
        # verified against the bytes on disk, so it names this extraction and no other.
        "table": {
            # The NAME, not the path. artefacts.json is committed, and an absolute path records
            # whose laptop ran the trainer rather than which table was read - the checksum below
            # already identifies the bytes, and it is the field that can actually be verified.
            "file": table.name,
            "dataset": manifest.dataset,
            "table_sha256": manifest.table_sha256,
            "rows": manifest.rows,
            "rows_per_task": manifest.rows_per_task,
            "users_in_table": len(manifest.rows_per_user),
            "extractor_version": manifest.extractor_version,
            "generated_at": manifest.generated_at,
            "source": manifest.source,
        },
        # Positions are the wire format (see schema.py), so the length and order the models were
        # fitted against are recorded with them: a model loaded beside a different schema scores
        # garbage without raising anything.
        "schema_length": len(FEATURES),
        "schema_names": list(NAMES),
        "identity_tasks": list(extract.IDENTITY_TASKS),
        "coaching_tasks": list(extract.COACHING_TASKS),
        "files": files,
        "per_user": [
            {
                "user": fit.user,
                # Whose sessions trained it. Same as `user` for a table user; the volunteer a
                # demo persona borrows from otherwise, so the provenance of ato_rina.pkl is a
                # fact in the directory rather than something only the trainer's author knew.
                "source_user": fit.source_user or fit.user,
                "file": fit.file,
                "per_user": fit.fitted.per_user,
                "n_train_sessions": fit.fitted.n_train_sessions,
                # The ids themselves, not just the count: an eval can only be checked for
                # overlap against what shipped if what shipped says which sessions it saw.
                "train_session_ids": list(fit.session_ids),
                "feature_names": list(fit.fitted.feature_names),
                # How this user's operating point was placed, and how well it could be placed.
                # `crossover_rate` is the rate at which her own rejection and a stranger's
                # acceptance cross: it is the floor on how often this model can challenge her
                # and still catch anyone. Recorded per user because the spread is wide - over
                # 100 HMOG users the median is 0.111 but six exceed 0.20 and one reaches 0.450,
                # which is a model that cannot separate that user from the population at all.
                # Nothing here refuses to ship such a model; choosing that cutoff is a policy
                # call. This only makes it visible, instead of leaving it inside a pickle.
                "calibration": {
                    "anchored_on_reference": fit.fitted.calibration.anchored_on_reference,
                    "reference_sessions": fit.fitted.calibration.reference_sessions,
                    "crossover_rate": fit.fitted.calibration.crossover_rate,
                },
            }
            for fit in fits
        ],
        "skipped_users": [
            {
                "user": skip.user,
                "identity_sessions": skip.identity_sessions,
                "reason": skip.reason,
            }
            for skip in skipped
        ],
        "cold_start": {
            "file": COLD_START_FILE,
            "per_user": cold_start.per_user,
            "users": len(identity_sessions),
            "n_train_sessions": cold_start.n_train_sessions,
            "source": "every user's identity sessions in the table, pooled",
        },
        "coaching": {
            "file": COACHING_FILE,
            "users": len(coaching_sessions),
            "genuine_sessions": len(coaching_rows),
            "coached_sessions": len(coaching_rows),
            "feature_names": list(coaching.feature_names),
            "source": "HMOG "
            + "+".join(extract.COACHING_TASKS)
            + " sessions as the genuine side; coached counterparts GENERATED by synth.coach "
            "from --seed - no public coached dataset exists",
        },
        # Files matching ato_*.pkl that this run did not write. The service loads the directory
        # by name, so one of these would be served as a current persona while having been fitted
        # on some earlier table.
        "unlisted_per_user_files": sorted(pre_existing - {fit.file for fit in fits}),
        "note": "per-user identity models are fitted on that user's own enrolment sessions "
                "only, which is asserted and not assumed; cold_start.pkl is the only identity "
                "artefact fitted on the population and is never written under a per-user name; "
                "no metric is measured here - eval/ato_eval.py reports numbers",
    }
    (out / MANIFEST_FILE).write_text(json.dumps(artefacts, indent=2) + "\n", encoding="utf-8")
    return artefacts


def _refuse_table(table: Path) -> str:
    """Why training cannot start, naming the command that produces what is missing."""
    return (
        f"--table {table} does not exist, so there is nothing to train on.\n"
        "This pass reads the extracted feature table, never the archive. Write the table once "
        "with:\n"
        f"  python -m bhorosha_ato.extract --dataset hmog --out {table} --users <ids...>\n"
        "`python -m bhorosha_ato.extract --dataset hmog` prints everything still standing "
        "between the archive and the table."
    )


def _parse_personas(pairs: list[str] | None) -> dict[str, str]:
    """`NAME=USER_ID` pairs into a mapping, refusing anything that would surprise later.

    A malformed pair is an error rather than a skip: silently dropping one would write a
    directory with no ato_rina.pkl in it and no reason recorded anywhere.
    """
    personas: dict[str, str] = {}
    for pair in pairs or []:
        name, sep, source = pair.partition("=")
        if not sep or not name or not source:
            raise SystemExit(f"--persona expects NAME=USER_ID, got {pair!r}")
        try:
            ato_file(name)  # refuses anything that cannot become a filename
        except ValueError as exc:
            # Re-raised as SystemExit so every bad --persona pair fails the same way, with the
            # reason on stderr rather than a traceback.
            raise SystemExit(f"--persona {pair!r}: {exc}") from exc
        if name in personas:
            raise SystemExit(f"--persona {name} given twice")
        personas[name] = source
    return personas


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--table", type=Path, default=extract.DEFAULT_TABLE,
                        help="feature table written by bhorosha_ato.extract; this pass reads "
                             "the table, never the archive")
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT,
                        help=f"directory for ato_{{user}}.pkl, {COLD_START_FILE}, "
                             f"{COACHING_FILE} and {MANIFEST_FILE}")
    parser.add_argument("--users", nargs="+", default=None, metavar="USER_ID",
                        help="demo personas to fit a per-user model for; default is every user "
                             "in the table with at least MIN_ENROLMENT_SESSIONS "
                             f"({MIN_ENROLMENT_SESSIONS}) identity sessions. A requested user "
                             "below that is skipped and the reason recorded, never served as "
                             "the global model under her own name")
    parser.add_argument("--persona", action="append", default=None, metavar="NAME=USER_ID",
                        help="write ato_NAME.pkl from USER_ID's sessions, for a demo persona "
                             "who has no sessions of her own (e.g. --persona rina=100669). The "
                             "manifest records which volunteer each persona borrows from")
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED,
                        help="RNG seed for the GENERATED coached sessions the coaching model is "
                             "fitted against; the identity fits are deterministic without it")
    args = parser.parse_args(argv)

    if not args.table.exists():
        raise SystemExit(_refuse_table(args.table))

    started = time.perf_counter()
    try:
        artefacts = train_artefacts(
            args.table, args.out, args.users, args.seed, _parse_personas(args.persona)
        )
    except extract.StaleTableError as exc:
        raise SystemExit(
            f"refused {args.table}: {exc}\n"
            "A table that disagrees with its manifest cannot be trained on: a truncated one "
            "still parses, still fits, and the .pkl it produces is indistinguishable from a "
            "good one."
        ) from exc

    print(json.dumps({
        "out": str(args.out),
        "manifest": str(args.out / MANIFEST_FILE),
        "table": artefacts["table"]["file"],
        "table_sha256": artefacts["table"]["table_sha256"],
        "seed": artefacts["seed"],
        "per_user_models": len(artefacts["per_user"]),
        "skipped_users": artefacts["skipped_users"],
        "unlisted_per_user_files": artefacts["unlisted_per_user_files"],
        "files": {name: meta["bytes"] for name, meta in artefacts["files"].items()},
        "train_seconds": round(time.perf_counter() - started, 1),
    }, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
