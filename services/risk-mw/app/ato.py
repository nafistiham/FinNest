"""Behaviour (ATO) adapter: the behaviour models (is this her? is she being coached?) in risk-mw.

Artefacts are read once from RISK_MW_ATO_ARTEFACTS_DIR and cached: the per-user identity model
`ato_<uid>.pkl`, the global coaching model `coaching.pkl`, and `cold_start.pkl` for users who
have not enrolled enough sessions yet. If the directory, a file, or the `bhorosha_ato` package
is missing the API still runs - this module emits no hits and says why in the log, exactly as
`app.mule` does when its scorer artefacts are absent. A behavioural signal going quiet must
never be able to fail a payment. The same degradation covers a directory whose `artefacts.json`
says it was fitted against a different feature order than this build serves: positions are the
wire format, so those models are refused rather than served - cheaply up front from
`artefacts.json` (`_declares_a_different_schema`), and then per artefact against the columns the
model itself records having been fitted on (`_fitted_on_another_schema`), which needs no manifest
and so also catches a stale pickle that an edited or absent manifest would have waved through.

Why hits rather than a score: `rules.decide()` folds a model score into `risk_score` with max()
but takes the decision and every customer-visible reason from rule hits alone, so a bare float
would move a number and change nothing a person would see. `bhorosha_ato.explain` builds those
hits as `BehaviourHit`, mirroring `rules.RuleHit` rather than importing it because `ato` and
`risk-mw` are separate roots; the conversion back is the job of this module.
"""

from __future__ import annotations

import json
import logging
import re
import threading
import time
from collections import OrderedDict
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path
from typing import Any

from app import sessions
from app.contracts import Decision, Reason
from app.rules import DECISION_RANK, RuleHit
from app.settings import get_settings

log = logging.getLogger(__name__)

COACHING_ARTEFACT = "coaching.pkl"
COLD_START_ARTEFACT = "cold_start.pkl"
# Written beside the artefacts by `bhorosha_ato.train` (its MANIFEST_FILE). It records the
# feature order and length every .pkl in the directory was fitted against, which is the only
# way this side can tell a current artefact from a stale one - see `_declares_a_different_schema`.
MANIFEST_ARTEFACT = "artefacts.json"

# Codes that describe the identity verdict, and therefore the ones a cold-start answer has to
# be labelled on. The coaching model is global by design - it answers a question about the
# situation, not about the person - so a missing per-user model says nothing about it.
IDENTITY_CODES = frozenset({"ATO_BEHAVIOUR_MISMATCH"})
COLD_START_SUFFIX = "_COLD_START"

# `user_id` arrives from the request body (the contract only checks min_length=1) and becomes
# part of a filename, so it is restricted rather than trusted: a uid carrying "../" must not
# turn into a read outside the artefacts directory. The same set the trainer allows when it
# writes `ato_<uid>.pkl`, so the reader can open everything the writer can produce and nothing
# else; the length cap is this side's own.
SAFE_USER_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")

# Per-user models are cached by uid. Bounded, because an unbounded cache keyed by a
# request-supplied id is a slow memory leak on a long-lived Cloud Run instance.
USER_MODEL_CACHE = 64

# Weakest decision a hit may carry if `explain` ever emits a decision this service does not
# know. Dropping the hit would hide a real signal; escalating it on a guess would be worse.
FALLBACK_DECISION: Decision = "step_up"


@dataclass(frozen=True)
class BehaviourModels:
    """The artefacts that are not per-user, loaded once."""

    artefacts: Path
    coaching: Any | None  # bhorosha_ato.model.CoachingModel
    cold_start: Any | None  # bhorosha_ato.model.AtoModel, the global stand-in
    loaded_ms: float


def _fitted_on_another_schema(artefact: Any, path: Path) -> bool:
    """Does this artefact's OWN record of its columns contradict the schema this build serves?

    The manifest check above can only read what `artefacts.json` CLAIMS, and three real cases
    defeat it: a manifest hand-edited or regenerated beside models that were never refitted; a
    directory with no manifest at all, which is served unverified by design; and a single
    `ato_<uid>.pkl` copied in from an older generation, because `user_model` opens that file by
    name and the manifest only lists the files the trainer itself wrote (it even carries an
    `unlisted_per_user_files` key, so a stray artefact is an anticipated state, not a far-fetched
    one). Every fitted model carries the column names it was trained on, and that is the one
    statement in the directory that cannot be changed without refitting. So this is the check
    that cannot be lied to, and it runs on each artefact as it is loaded.

    Same quiet contract as everything else here: a contradicting artefact is treated as ABSENT,
    which is a state every caller already handles - no coaching model means a coaching score of
    0.0, no cold-start model means no stand-in, and a stale per-user model makes her cold start
    rather than scoring her against someone else's columns. Nothing raises, and the rest of the
    directory keeps working: a stale coaching model must not cost us the identity verdict.

    And the same "only on a positive contradiction" rule, which here has a case worth naming.
    `AtoModel` is a slots dataclass, so a pickle written when it had one field fewer restores
    through `__setstate__`'s zip with `feature_names` simply never set - measured: such a model
    loads, reports no attribute, and happily scores 0.854 on a constant row. That is an artefact
    that says NOTHING about its columns, not one that disagrees, so it is served with a warning.
    It cannot be written by this build (pickling it raises), only read from an older one.
    """
    try:
        from bhorosha_ato.model import DERIVED_IDENTITY, AtoModel, CoachingModel
        from bhorosha_ato.schema import IDENTITY_FEATURES
        from bhorosha_ato.synth import COACHING_FEATURES
    except ImportError as exc:
        # Nothing can score without the package, so there is no wrong-column read to prevent.
        log.warning("bhorosha_ato unavailable (%s); %s left unverified", exc, path.name)
        return False

    if isinstance(artefact, AtoModel):
        # Written the way `AtoModel.feature_names`'s own default is written, because that is
        # what `model.identity_matrix` actually builds at score time. If identity ever gets
        # derived columns back, both move together instead of drifting.
        expected = IDENTITY_FEATURES + tuple(name for name, _, _ in DERIVED_IDENTITY)
    elif isinstance(artefact, CoachingModel):
        # `_scores` hands this model `synth.coaching_matrix`'s six-column projection, so that
        # is the list it has to have been fitted on.
        expected = tuple(COACHING_FEATURES)
    else:
        log.warning(
            "%s holds a %s, which this adapter has no column list for",
            path, type(artefact).__name__,
        )
        return False

    names = getattr(artefact, "feature_names", None)
    if not names:
        # Absent (the older-pickle case above) or empty, which are indistinguishable here and
        # both mean "declares nothing". Unverifiable, so served - see the rule above.
        log.warning(
            "%s does not record the columns it was fitted on; serving it unverified", path,
        )
        return False
    if tuple(names) == expected:
        return False
    log.error(
        "%s was fitted on %d columns that are not the %d bhorosha_ato.schema now declares for "
        "it; treating it as absent rather than scoring the wrong quantity out of every "
        "position. Re-run bhorosha_ato.train.",
        path, len(tuple(names)), len(expected),
    )
    return True


def _load_artefact(path: Path) -> Any | None:
    """joblib-load one artefact, or None with the reason logged.

    None also when the loaded model turns out to have been fitted on another schema, so no
    caller can forget to check - see `_fitted_on_another_schema`.
    """
    try:
        from bhorosha_ato.model import load
    except ImportError as exc:
        # The deployed image vendors `ato` the way it vendors the synth packages; a skipped
        # vendor step degrades the signal instead of taking the service down.
        log.warning("bhorosha_ato unavailable (%s); behaviour signal is off", exc)
        return None
    if not path.is_file():
        log.info("behaviour artefact %s is absent", path)
        return None
    started = time.perf_counter()
    try:
        artefact = load(path)
    except Exception as exc:  # noqa: BLE001 - see below
        # Deliberately broad: unpickling fails in as many ways as there are drifts between the
        # training and serving environments (sklearn version, truncated upload, moved module),
        # and none of them may reach a request.
        log.error("behaviour artefact %s could not be loaded: %s", path, exc)
        return None
    log.info("loaded %s in %.0f ms", path.name, (time.perf_counter() - started) * 1000)
    if _fitted_on_another_schema(artefact, path):
        return None
    return artefact


def _declares_a_different_schema(directory: Path) -> bool:
    """Does `artefacts.json` say these models were fitted against a schema we no longer serve?

    This is the one failure `bhorosha_ato.schema` is built around and the one nothing on this
    side used to check. `behaviour_hits` compares the INCOMING vector to `len(FEATURES)`, which
    catches an old client; it says nothing about what the pickles were fitted on. The schema
    grew 30 -> 39 -> 55 features during development, and a previous generation of artefacts fitted on 30
    shipped against a 39-feature wire without a word: every position is then a different
    quantity than the model expects, and an identity score comes back plausible and meaningless.
    The trainer records the order it fitted against, so this reads it back.

    REFUSED QUIETLY (the caller serves no models), NOT by raising, and the choice is forced by
    where this runs. `models()` is reached from inside a request - `routers/risk.py` ->
    `behaviour_hits` -> here - and never at start-up, so a raise would not stop a bad deployment:
    it would 500 a customer's payment, on every request, since `lru_cache` does not cache
    exceptions and each call would re-raise. That is the opposite of this module's contract
    ("a behavioural signal going quiet must never be able to fail a payment"), and it is how
    `app.mule` already treats artefacts it cannot use. Going quiet is also safe in the direction
    that matters: `rules.decide` folds behaviour in through max() and reasons, so no hits can
    only fail to escalate - it can never allow something the rest of the rules would have held.
    The log line is ERROR, not the INFO an unset directory gets, because an unset directory is a
    configuration choice and this is a broken deployment that someone has to go and fix.

    Offline the same mismatch RAISES, in `extract.read_table` (`StaleTableError`). The asymmetry
    is deliberate: there a human is at a terminal and the alternative is silently training on
    the wrong columns, while here the alternative is a declined payment.

    Returns True only when the manifest positively declares a different order or length. An
    absent or unreadable manifest is NOT a refusal - see the branches below. This is the cheap
    check, made before anything is unpickled and able to refuse a whole directory at once;
    `_fitted_on_another_schema` is the one that cannot be lied to, per artefact, after load.
    """
    path = directory / MANIFEST_ARTEFACT
    if not path.is_file():
        # Served, deliberately. A directory with no manifest is unverifiable, not known-stale:
        # artefacts assembled by hand or by a trainer that predates the field look exactly like
        # this, and the adapter's own suite builds such directories from `bhorosha_ato.synth`.
        # Refusing them would trade a working signal for a guess, and nothing is left unguarded
        # by serving them: `_fitted_on_another_schema` checks each model's OWN fitted column list
        # as it loads, which does not need a manifest and cannot be edited into agreement, and
        # `behaviour_hits` still refuses a vector that is not `len(FEATURES)`. The directory this
        # repo actually ships does carry a manifest, pinned by tests/test_ato_committed_artefacts.
        log.warning(
            "no %s beside the behaviour artefacts at %s; serving them unverified - the feature "
            "order they were fitted on cannot be checked against this build",
            MANIFEST_ARTEFACT, directory,
        )
        return False
    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
        declared_names = manifest["schema_names"]
        declared_length = int(manifest["schema_length"])
        if not isinstance(declared_names, list):
            raise TypeError(f"schema_names is {type(declared_names).__name__}, not a list")
        names = tuple(str(name) for name in declared_names)
    except (OSError, ValueError, TypeError, KeyError, AttributeError) as exc:
        # Same bucket as "absent": a truncated or hand-edited manifest declares nothing, so
        # there is nothing to disagree with. Logged at ERROR because, unlike an absent manifest,
        # a corrupt one means an upload went wrong and the .pkl files may have gone with it -
        # which `_load_artefact` would then report file by file.
        log.error("%s could not be read (%s); serving the artefacts unverified", path, exc)
        return False
    try:
        from bhorosha_ato.schema import FEATURES, NAMES
    except ImportError as exc:
        # No package means no scoring at all, so there is no wrong-column read to prevent here.
        log.warning("bhorosha_ato unavailable (%s); behaviour artefacts left unverified", exc)
        return False
    if names == NAMES and declared_length == len(FEATURES):
        return False
    log.error(
        "behaviour artefacts at %s were fitted against a different feature order or length "
        "(%d features) than bhorosha_ato.schema declares (%d); refusing the directory rather "
        "than scoring the wrong quantity out of every position. Re-run bhorosha_ato.train.",
        directory, declared_length, len(FEATURES),
    )
    return True


@lru_cache(maxsize=1)
def models() -> BehaviourModels | None:
    """The shared artefacts, or None when the behaviour signal is off."""
    artefacts = get_settings().ato_artefacts_dir
    if artefacts is None or not Path(artefacts).is_dir():
        log.info("RISK_MW_ATO_ARTEFACTS_DIR not set or missing; behaviour signal is off")
        return None
    directory = Path(artefacts)
    # Before the artefacts are read, not after: a stale directory is 2.6 MB of cold_start.pkl
    # that would be unpickled only to be thrown away, and the per-user models this would go on
    # to serve through `user_model` are the stale ones.
    if _declares_a_different_schema(directory):
        return None
    started = time.perf_counter()
    coaching = _load_artefact(directory / COACHING_ARTEFACT)
    cold_start = _load_artefact(directory / COLD_START_ARTEFACT)
    loaded_ms = (time.perf_counter() - started) * 1000
    # Kept even when both are None: per-user models may still be present, and an identity
    # verdict on its own is worth having.
    log.info(
        "behaviour artefacts from %s in %.0f ms (coaching=%s cold_start=%s)",
        directory, loaded_ms, coaching is not None, cold_start is not None,
    )
    return BehaviourModels(directory, coaching, cold_start, round(loaded_ms, 1))


@lru_cache(maxsize=USER_MODEL_CACHE)
def user_model(user_id: str) -> Any | None:
    """This user's own identity model, or None if she has not enrolled one.

    Cached including the misses, so a user without a model costs one stat() rather than one per
    request.
    """
    loaded = models()
    if loaded is None:
        return None
    if not SAFE_USER_ID.match(user_id):
        log.warning("user id %r is not a usable artefact name; no per-user model", user_id)
        return None
    return _load_artefact(loaded.artefacts / f"ato_{user_id}.pkl")


def _scores(identity: Any, coaching: Any | None, row: tuple[float, ...]) -> tuple[float, float]:
    """(ato_score, coaching_score) for one session.

    The two models take different inputs and getting that wrong yields plausible numbers from
    the wrong columns. `AtoModel.score` wants the FULL wire row and narrows it to the
    morphology columns itself; the coaching model was fitted on the six-column
    `synth.coaching_matrix` projection and must be handed that.
    """
    from bhorosha_ato.synth import coaching_matrix

    ato_score = float(identity.score(row))
    if coaching is None:
        return ato_score, 0.0
    return ato_score, float(coaching.score(coaching_matrix([row])[0]))


def _as_rule_hit(hit: Any, cold_start: bool) -> RuleHit:
    """BehaviourHit -> RuleHit, labelling an identity verdict that is not personalised."""
    code = hit.code
    if cold_start and code in IDENTITY_CODES:
        # A cold-start answer must never be presented as a personalised one: the reason code
        # itself carries it, so it survives into the audit log and the case file.
        code = f"{code}{COLD_START_SUFFIX}"
    decision: Decision = hit.decision if hit.decision in DECISION_RANK else FALLBACK_DECISION
    if decision != hit.decision:
        log.warning("behaviour hit %s asked for unknown decision %r", code, hit.decision)
    return RuleHit(
        Reason(
            code=code,
            weight=round(min(max(float(hit.weight), 0.0), 1.0), 3),
            text_bn=hit.text_bn,
            text_en=hit.text_en,
        ),
        decision,
    )


# The per-session features /v1/risk/signals leaves for /v1/risk/score live in app.sessions, keyed by
# (caller uid, session id) with a TTL; routers/risk.py reads them there and hands them in.


def forget_behaviour() -> None:
    """Drop every stored session. For tests and for an artefacts redeploy; kept here for existing callers."""
    sessions.forget()
    forget_evidence()


# --- what the last scored session showed, for Apa's warning at the hold ----------------------------------------
# The scoring path stays offline (call=None below). Gemini words the explanation later, in Apa's warning at
# /v1/intervene (app.warnings.signals), from this record: flags and the feature groups that pushed the score, never
# the scores themselves or a feature's value. In memory and bounded, like app.appsafety_engine's latest verdicts:
# one Cloud Run instance for the demo.

EVIDENCE_LIMIT = 1024


@dataclass(frozen=True)
class BehaviourEvidence:
    ato_score: float
    coaching_score: float
    not_her: bool  # ato_score at or above the step-up floor (bhorosha_ato.explain.ATO_STEP_UP)
    coached: bool  # coaching_score at or above COACHING_CONCERN
    blocks: tuple[str, ...]  # schema blocks of the attributions that pushed towards suspicious, strongest first
    cold_start: bool  # no model of her own: there is no "her usual" to compare with
    at: float  # time.monotonic()


_EVIDENCE: OrderedDict[str, BehaviourEvidence] = OrderedDict()
_EVIDENCE_LOCK = threading.Lock()


def remember_evidence(user_id: str, evidence: BehaviourEvidence) -> None:
    with _EVIDENCE_LOCK:
        _EVIDENCE[user_id] = evidence
        _EVIDENCE.move_to_end(user_id)
        while len(_EVIDENCE) > EVIDENCE_LIMIT:
            _EVIDENCE.popitem(last=False)


def latest_evidence(user_id: str, max_age_s: float, now: float | None = None) -> BehaviourEvidence | None:
    """Her last scored session, if it is younger than max_age_s."""
    with _EVIDENCE_LOCK:
        entry = _EVIDENCE.get(user_id)
    if entry is None or (time.monotonic() if now is None else now) - entry.at > max_age_s:
        return None
    return entry


def forget_evidence() -> None:
    with _EVIDENCE_LOCK:
        _EVIDENCE.clear()


def _blocks(attributions: list[Any]) -> tuple[str, ...]:
    """The schema block of each attribution that pushed towards suspicious (positive shap), strongest first; derived
    ratios that are not schema features have no block and are left out."""
    from bhorosha_ato.schema import FEATURES

    block_of = {f.name: f.block for f in FEATURES}
    return tuple(block_of[a.feature] for a in attributions if a.shap > 0 and a.feature in block_of)


def _attributions(identity: Any, row: tuple[float, ...]) -> list[Any]:
    """Top SHAP attributions, or none when the artefact carries no background to compare to.

    Failures here are swallowed deliberately: evidence is an enhancement to the explanation,
    and losing it must never cost the customer the decision itself.
    """
    background = list(getattr(identity, "background", ()) or ())
    if not background:
        return []
    try:
        from bhorosha_ato.explain import top_attributions

        return top_attributions(identity, row, background, k=4, nsamples=60)
    except Exception as exc:  # noqa: BLE001 - no evidence is better than no answer
        log.warning("attributions unavailable, explaining without them: %s", exc)
        return []


def behaviour_hits(
    user_id: str, features: tuple[float, ...], *, in_call: bool = False
) -> tuple[RuleHit, ...]:
    """Score one session's behaviour vector and return the rule hits it earns.

    Empty is the honest answer whenever the signal cannot be computed - no artefacts, artefacts
    fitted against another schema, no model for this user and no cold-start stand-in, a vector
    that is not the wire length, or anything at all going wrong inside the models. The caller
    fuses these with `rules.evaluate()`'s hits and never has to handle an exception from here.

    `in_call` reaches `explain.required_action`, which holds a suspected-coaching session on an
    active call rather than merely stepping it up.
    """
    loaded = models()
    if loaded is None:
        return ()
    try:
        from bhorosha_ato.explain import ATO_STEP_UP, COACHING_CONCERN, as_behaviour_hits, explain
        from bhorosha_ato.schema import FEATURES
    except ImportError as exc:
        log.warning("bhorosha_ato unavailable (%s); no behaviour hits", exc)
        return ()

    if len(features) != len(FEATURES):
        # The contract caps `behaviour.features` at 64 and validates nothing else, so a client
        # on an older schema reaches here with the wrong number of columns. Scoring it would
        # read the wrong quantity out of every position.
        log.warning(
            "behaviour vector for %s has %d features, expected %d; no behaviour hits",
            user_id, len(features), len(FEATURES),
        )
        return ()

    identity = user_model(user_id)
    cold_start = identity is None
    if cold_start:
        identity = loaded.cold_start
    if identity is None:
        log.info("no identity model for %s and no cold-start stand-in; no behaviour hits", user_id)
        return ()
    # A per-user artefact fitted below MIN_ENROLMENT_SESSIONS is a global model wearing the
    # user's filename, and `train_ato` records that in `per_user`. Either route is cold start.
    cold_start = cold_start or not getattr(identity, "per_user", False)

    row = tuple(float(value) for value in features)
    try:
        ato_score, coaching_score = _scores(identity, loaded.coaching, row)
        # Feature-level evidence when the artefact carries a background of the owner's normal
        # sessions, which `train_ato` now stores. Measured at 1.7 ms for an attribution against
        # the 50 ms budget, so the reason to skip it was never latency. Without a background -
        # an artefact from before that change, or the population model - the explainer still
        # produces its message, just with no reasons behind it.
        #
        # call=None keeps this offline regardless: no Gemini, no credentials, no network in the
        # request path. The explanation is deterministic either way.
        attributions = _attributions(identity, row)
        explanation = explain(
            ato_score, coaching_score, attributions, call=None, in_call=in_call
        )
        hits = as_behaviour_hits(explanation, ato_score, coaching_score)
        remember_evidence(user_id, BehaviourEvidence(
            ato_score=ato_score, coaching_score=coaching_score, not_her=ato_score >= ATO_STEP_UP,
            coached=coaching_score >= COACHING_CONCERN, blocks=_blocks(attributions), cold_start=cold_start,
            at=time.monotonic()))
    except Exception as exc:  # noqa: BLE001 - a scoring failure degrades, it does not 500
        log.exception("behaviour scoring failed for %s: %s", user_id, exc)
        return ()

    log.info(
        "behaviour for %s: ato=%.3f coaching=%.3f cold_start=%s hits=%d",
        user_id, ato_score, coaching_score, cold_start, len(hits),
    )
    return tuple(_as_rule_hit(hit, cold_start) for hit in hits)


def reset_cache() -> None:
    """Drop every cached artefact. For tests and for a reload after a redeploy of artefacts."""
    models.cache_clear()
    user_model.cache_clear()
