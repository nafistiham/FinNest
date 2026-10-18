"""Per-user one-class model (is this Rina?) and the coaching model (is she being coached?).

One-class is forced by the setting, not chosen for style: in production we only ever hold the
account owner's own sessions. Impostor data is used for evaluation and never for training,
which also avoids one of the pitfalls catalogued in the touch-dynamics literature.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import joblib
import numpy as np
from sklearn.ensemble import IsolationForest
from sklearn.linear_model import LogisticRegression
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler
from sklearn.svm import OneClassSVM

from bhorosha_ato.schema import IDENTITY_FEATURES, IDENTITY_INDEX, INDEX

# Timing was deliberately NOT given back to identity, and the numbers are why.
#
# Measuring identity on morphology alone gives 11.4% EER on HMOG's writing sessions against a
# 3-10% target, so the obvious move was to hand identity some scale-free ratio of the typing
# timings - on the theory that coercion multiplies every timing by one factor, leaving ratios
# intact. Measured on the real data, that halved the EER to 5.8% and took the share of coached
# sessions still recognised as the owner from 88.3% to 0.0%.
#
# The theory was wrong in a specific way worth recording: coercion does not merely slow typing,
# it makes it more VARIABLE - the generator's own rule is a 1.6-2.5x stretch with high variance
# plus dead gaps. Ratios between quantiles are precisely variance-sensitive, so a scale-free
# ratio is not a coercion-free one. There is no free lunch in this direction.
#
# The coached-session acceptance scenario requires that a coached session still scores as the owner.
# Trading an explicit acceptance criterion for five points of EER is the wrong way round, so
# identity stays on morphology and the EER miss is reported as a miss.
#
# What might work later, and cannot be tried from the current table: the RANK ORDER of per-key
# hold times - which keys she dwells on - is identity-bearing and invariant to both scale and
# variance. The table stores only quantiles, so testing it would mean re-extracting.
DERIVED_IDENTITY: tuple[tuple[str, str, str], ...] = ()


def derived_identity(row: tuple[float, ...]) -> list[float]:
    """Empty by design - see the note above."""
    return []


def identity_matrix(rows: list[tuple[float, ...]]) -> np.ndarray:
    """Morphology columns plus the derived ratios, in one place so train and score agree.

    Two call sites computing this differently is the kind of mistake that trains on one feature
    set and scores on another, and produces a number that looks plausible.
    """
    return np.asarray(
        [[row[i] for i in IDENTITY_INDEX] + derived_identity(row) for row in rows], dtype=float
    )

# Fewer enrolment sessions than this and a per-user model has nothing to generalise from, so a
# global outlier model stands in until the user has used the app a few times.
MIN_ENROLMENT_SESSIONS = 3

# A result below this on HMOG is treated as a session leak and investigated, not celebrated:
# published SOTA on that dataset is around 3.6%.
EER_LEAK_SUSPICION = 0.03


@dataclass(frozen=True, slots=True)
class Split:
    """Which sessions trained the model and which were held out, recorded for the report.

    EER is meaningless without this. Mixing sessions across train and test is the most common
    way these results get overstated, so the number and its split travel together.
    """

    train_sessions: tuple[str, ...] = ()
    test_sessions: tuple[str, ...] = ()
    impostor_users: tuple[str, ...] = ()
    note: str = ""


@dataclass(frozen=True, slots=True)
class Calibration:
    """Maps a raw SVM margin onto [0, 1] against a false-reject budget.

    Two problems make the raw margin unusable as a score. It is tiny in magnitude, so squashing
    it through a sigmoid lands every session near 0.5 and absolute thresholds stop meaning
    anything - a stranger scored 0.55 against the owner's 0.50 before this existed. And the
    margins of the sessions the model was FITTED on are optimistic: in testing they averaged
    +0.034 while held-out sessions from the same person averaged -0.047, so calibrating on
    training margins misjudges the owner's own future sessions.

    So the anchors come from out-of-sample margins collected by k-fold over the enrolment set,
    and they are expressed as a policy rather than as magic numbers.

    There are two ways to place them, and `anchored_on_reference` says which one a given model
    carries. With a reference sample of population sessions the 0.60 anchor sits at the MEASURED
    crossover of the owner-rejection and impostor-acceptance curves and 0.85 at the median of
    the impostor margins - see `_crossover_anchors`. Without one the anchors fall back to
    quantiles of the owner's own out-of-sample margins, which is the historical behaviour and
    realises 33.5% against the 5% it promises on real data - see `_quantile_anchors`.

    `step_up_quantile` and `hold_quantile` mean the same thing on both paths: the share of the
    owner's own out-of-sample sessions sitting at or beyond that anchor. On the fallback path it
    is the share that was ASKED for; on the reference path it is the share that was MEASURED
    once the crossover decided where the anchor goes. One number, one meaning, either way.
    """

    xs: tuple[float, ...]
    ys: tuple[float, ...]
    step_up_quantile: float
    hold_quantile: float
    oos_margin_mean: float
    oos_margin_std: float
    # False on a model whose anchors came from quantiles of five numbers. Carried on the object
    # rather than inferred from the anchors because the two calibrations make different promises
    # and a caller - the risk API, the eval harness, an auditor - has to be able to tell a model
    # that was anchored against a population from one that was not. Defaults to False so an
    # artefact pickled before this field existed unpickles as what it actually is.
    anchored_on_reference: bool = False
    reference_sessions: int = 0
    # The shared value of the two error curves where they cross. None on the fallback path,
    # where nothing was measured. Read it as a conservative bound rather than as the realised
    # rate: the owner's side of the crossing is estimated from five out-of-sample margins, and
    # on HMOG this reads 0.161 where the realised false step-up is 0.104. What makes it worth
    # carrying is that it is the same crossing `equal_error_rate` reports, so it says how
    # separable this particular user is from the population - a user whose crossover rate is
    # 0.4 has no usable operating point and the calibration cannot invent one.
    crossover_rate: float | None = None

    def apply(self, margin: float) -> float:
        return float(np.interp(-margin, self.xs, self.ys))


@dataclass(frozen=True, slots=True)
class AtoModel:
    """A fitted per-user model plus the knowledge of whether it is really per-user yet."""

    pipeline: Pipeline
    per_user: bool
    n_train_sessions: int
    calibration: Calibration
    # A handful of the owner's own enrolment rows, carried so the explainer can produce
    # feature-level evidence at request time. SHAP needs something to compare against, and
    # without this the explainer always falls back to its deterministic path and the customer
    # is told a decision with no reasons behind it. Measured cost: 1.7 ms for an attribution
    # against a 50 ms budget, and about 2 KB on disk - so the reason not to carry it was never
    # latency or size, it was simply not having been done.
    background: tuple[tuple[float, ...], ...] = ()
    feature_names: tuple[str, ...] = IDENTITY_FEATURES + tuple(
        name for name, _, _ in DERIVED_IDENTITY
    )

    def score(self, row: tuple[float, ...]) -> float:
        """One session -> ato_score in [0, 1], where higher means less like the owner.

        The demo's shape depends on this direction: a coached session should score LOW here
        (it is still her) while the coaching score runs high.
        """
        return self.calibration.apply(self._decision(row))

    def scores(self, rows: list[tuple[float, ...]]) -> list[float]:
        return [self.score(row) for row in rows]

    def _decision(self, row: tuple[float, ...]) -> float:
        """Takes a full 30-feature wire row and projects it down to the morphology columns.

        Callers pass whole sessions; narrowing happens here so no caller has to remember which
        columns identity is allowed to see.
        """
        return float(self.pipeline.decision_function(identity_matrix([row]))[0])


def _fit_pipeline(x: np.ndarray, per_user: bool, nu: float) -> Pipeline:
    estimator = (
        OneClassSVM(kernel="rbf", nu=nu, gamma="scale")
        if per_user
        else IsolationForest(n_estimators=200, random_state=0)
    )
    pipeline = Pipeline([("scale", StandardScaler()), ("model", estimator)])
    pipeline.fit(x)
    return pipeline


def _out_of_sample_margins(x: np.ndarray, per_user: bool, nu: float) -> np.ndarray:
    """Margins for each enrolment session from a model that never saw it.

    Needed because a one-class model is systematically kinder to the points it was fitted on,
    and a score calibrated on those would call the owner's ordinary future sessions suspicious.
    k-fold is cheap here - a handful of extra fits on a few dozen rows.

    Worth recording that this works: over 40 HMOG users with five enrolment sessions, these
    k-fold margins averaged -0.0837 while the same users' genuinely held-out sessions scored
    -0.0832 through the full fit. The proxy is unbiased, which is what makes it usable as the
    owner side of a crossover.
    """
    n = len(x)
    folds = min(5, n) if n >= 4 else n
    if folds < 2:
        return np.asarray([float(_fit_pipeline(x, per_user, nu).decision_function(x)[0])])

    margins = np.empty(n, dtype=float)
    for fold in range(folds):
        held_out = np.arange(n) % folds == fold
        fitted = _fit_pipeline(x[~held_out], per_user, nu)
        margins[held_out] = fitted.decision_function(x[held_out])
    return margins


# Why the reference sample is scored through the FULL fit while the owner side is scored by
# k-fold, which looks inconsistent and is not.
#
# The calibration has to predict what the DEPLOYED model - the one fitted on all five enrolment
# sessions - will do to two populations. For strangers there is nothing to estimate: they never
# trained it, so scoring them through it directly is the answer rather than a proxy. For the
# owner's future sessions there is no such luxury, and k-fold stands in; `_out_of_sample_margins`
# records that the stand-in is unbiased.
#
# Scoring the reference through the fold models instead was tried and is measurably wrong. Fold
# models see four rows, not five, and they compress the impostor tail: over 40 HMOG users the
# same impostor sessions averaged -0.1018 through fold models against -0.1138 through the full
# fit, while the owner's margins were unchanged. Calibrating against the compressed tail put the
# 1.0 saturation anchor at -0.1111, above the real impostor 5th percentile of -0.1283, so at
# deployment nearly every stranger piled up at exactly 1.0. Over 100 users and four splits that
# cost everything the fix was for: false step-up 34.6% against 10.4%, no better than the quantile
# anchors it replaced, and the ties blunted the per-user EER from 0.094 to 0.159. A calibration
# cannot improve separability and this one was destroying it.
def _reference_margins(pipeline: Pipeline, reference: np.ndarray) -> np.ndarray:
    return np.asarray(pipeline.decision_function(reference), dtype=float)


# Below this many reference rows the impostor curve cannot resolve a tail rate near the
# crossover - with 10 rows the finest acceptance rate it can express is 10%, which is the whole
# quantity being measured. A caller who supplies fewer has made a mistake and is told so rather
# than silently handed the fallback calibration.
MIN_REFERENCE_SESSIONS = 20

# Where 0.85 goes once 0.60 is pinned to the crossover: the median of the reference impostor
# margins. Stated as a sentence a bank can argue with - "a session at 0.85 is at least as unlike
# the account owner as half of all strangers are" - and, unlike a 1st percentile of five
# numbers, it is estimable from the sample it is taken on.
#
# Deliberately NOT a second crossover at some cost ratio. The owner side has five
# out-of-sample margins, so its rejection rate is quantised to multiples of 20% and any
# crossover placed where that rate is meant to be ~1% is reading noise off a five-point curve,
# which is the original defect wearing a different hat. The impostor side has hundreds of rows,
# so its median is the one quantity here that a quantile can honestly be taken of.
REFERENCE_HOLD_QUANTILE = 0.50

# Where the score saturates at 1.0. A session as unlike the owner as the most extreme 5% of
# strangers has nothing left to distinguish, and anchoring the ceiling inside the measured
# impostor range rather than by extrapolating a spread keeps most of the impostor distribution
# on the sloped part of the map instead of piled up at 1.0 - ties at the ceiling are invisible
# to a threshold but they do blunt the EER.
REFERENCE_FLOOR_QUANTILE = 0.05


# How many points to sweep when looking for the crossing. The difference between the two curves
# is monotone in the threshold, so there is exactly one crossing and a sweep cannot land on a
# local minimum; this only sets how precisely it is located.
CROSSOVER_GRID = 4001


def _owner_reject_curve(margins: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """The owner's rejection rate as a function of the margin, from five numbers.

    The step function `mean(margins <= t)` is the obvious choice and it is the defect: it reads
    0 below the smallest of five margins and 20% at it, so a crossing meant to sit near 10% has
    nowhere to land and snaps to one or the other. Measured on HMOG that put the realised false
    step-up at 23.0% while the model reported 3.7% - the right idea with the wrong curve.

    So the five margins are read as order statistics with Weibull plotting positions,
    `i / (n + 1)`, and interpolated between. That convention is not a choice of taste: for the
    i-th smallest of n samples, `E[F(x_i)] = i / (n + 1)` exactly, so it is the unbiased
    estimate of the PROBABILITY at a measured point, which is the quantity a crossover equates.
    (Hazen's `(i - 0.5) / n` is the convention for the other direction - estimating a quantile
    at a given probability. Measured on the same 100 users it sits further along the same
    frontier: 13.1% false step-up with 90.0% of strangers caught, against Weibull's 10.4% and
    85.5%. Neither dominates, and the budget is the thing with a stated number, so the
    convention that estimates a probability is the one used.)

    Note what this is not: a smoothing constant chosen because the resulting number looked
    acceptable. There is no free parameter in `i / (n + 1)`.
    """
    s = np.sort(np.asarray(margins, dtype=float))
    n = len(s)
    pos = (np.arange(n) + 1.0) / (n + 1.0)
    # Repeated margins would leave np.interp with a non-increasing x axis, which it does not
    # define, and a user whose sessions are all identical produces exactly that. Collapsing each
    # repeated value onto its highest position keeps the curve a function.
    keep = np.append(np.diff(s) > 0.0, True)
    return s[keep], pos[keep]


def _crossover(owner: np.ndarray, impostor: np.ndarray) -> tuple[float, float]:
    """The margin where the owner-rejection and impostor-acceptance curves cross.

    A session is challenged when its margin is at or below the returned threshold, so sweeping
    the threshold upward raises the share of the owner's own sessions that are challenged and
    lowers the share of strangers let through. Where the two meet is the only operating point on
    the curve that was chosen by measurement rather than by assertion.

    The same event `equal_error_rate` finds, in margin space instead of score space, and
    deliberately so: the score is a monotone remap of the margin, so this is that crossing seen
    one step earlier - which is why anchoring here cannot move the EER.

    Returns the threshold and the shared rate at it. The rate is an estimate off five owner
    margins and reads conservative - 0.161 on HMOG where the realised false step-up is 0.104 -
    so it is a bound to argue with, not the realised rate.
    """
    xs, ys = _owner_reject_curve(owner)
    impostor_sorted = np.sort(np.asarray(impostor, dtype=float))
    lo = min(float(xs[0]), float(impostor_sorted[0]))
    hi = max(float(xs[-1]), float(impostor_sorted[-1]))
    grid = np.linspace(lo, hi, CROSSOVER_GRID) if hi > lo else np.asarray([lo])

    reject_owner = np.interp(grid, xs, ys)
    # P(impostor margin > t), by position rather than by a comparison per grid point.
    accept_impostor = 1.0 - np.searchsorted(
        impostor_sorted, grid, side="right"
    ) / len(impostor_sorted)

    gap = np.abs(reject_owner - accept_impostor)
    # When the two distributions are separated by a range of thresholds rather than meeting at
    # a point, every threshold in that range scores the same and argmin returns its first
    # index - the impostor edge. A session whose margin IS that edge then lands exactly on the
    # anchor, and np.interp returns the value just below it. Measured on the demo phone: a
    # stranger scored 0.5999999999653823 against the 0.60 step-up line and was allowed through.
    # The middle of the plateau carries the same error rate with the most room either side.
    tol = 1e-12
    plateau = np.flatnonzero(gap <= gap.min() + tol)
    at = int(plateau[len(plateau) // 2])
    return float(grid[at]), float((reject_owner[at] + accept_impostor[at]) / 2.0)


def _quantile_anchors(
    margins: np.ndarray, step_up_quantile: float, hold_quantile: float
) -> list[float]:
    """The historical anchors: quantiles of the owner's own out-of-sample margins.

    Kept verbatim, including the 1e-6 nudge, because this is what a model with no reference
    sample must carry. Changing it would move every already-trained artefact's scores as a side
    effect of adding the reference path.

    It is also known to be wrong by a wide margin, which is why it is now the fallback and not
    the only path: with five enrolment sessions a 5th-percentile anchor is estimated from five
    numbers, and over 100 HMOG users the 5% budget it promises is realised as 33.5%.
    """
    q_high = float(np.quantile(margins, 0.95))
    q_median = float(np.median(margins))
    q_step_up = float(np.quantile(margins, step_up_quantile))
    q_hold = float(np.quantile(margins, hold_quantile))

    # Where the score saturates. Scaled by how far hold already sits below the median, so a
    # tightly clustered user saturates sooner than a variable one.
    spread = max(q_median - q_hold, 1e-6)
    q_floor = q_hold - 4.0 * spread

    xs = [-q_high, -q_median, -q_step_up, -q_hold, -q_floor]
    # np.interp needs strictly increasing xs; degenerate margins (every session identical)
    # would otherwise produce a flat or non-monotone map.
    for i in range(1, len(xs)):
        if xs[i] <= xs[i - 1]:
            xs[i] = xs[i - 1] + 1e-6
    return xs


def _crossover_anchors(
    margins: np.ndarray, reference_margins: np.ndarray
) -> tuple[list[float], float]:
    """Anchors placed where the two error curves actually cross.

    0.60 goes to the crossover margin, so "step up" means "this session is at least as unlike
    the owner as the point where challenging her own sessions and admitting strangers cost the
    same". 0.85 goes to the median impostor margin. Both are read off distributions large enough
    to carry the quantity being read.

    The two measured anchors are authoritative and the decorative ones give way to them. If a
    user is hard enough that her own median session already sits below the crossover, the 0.15
    and 0.0 anchors are pushed out of the way rather than the crossover being dragged up to meet
    them: pulling the step-up line back to her median is exactly the 30%-false-step-up failure
    this function exists to remove, and it would reappear only for the users who can least
    afford it.
    """
    q_step_up, crossover_rate = _crossover(margins, reference_margins)
    q_hold = float(np.quantile(reference_margins, REFERENCE_HOLD_QUANTILE))
    q_floor = float(np.quantile(reference_margins, REFERENCE_FLOOR_QUANTILE))
    q_high = float(np.quantile(margins, 0.95))
    q_median = float(np.median(margins))

    # A scale-aware minimum gap, so a forced separation stays small next to the spread of the
    # margins it separates instead of being a fixed 1e-6 cliff on a distribution whose own
    # spread may be 1e-4.
    scale = float(np.std(reference_margins))
    gap = max(scale, 1e-6) * 0.05

    xs = [-q_high, -q_median, -q_step_up, -q_hold, -q_floor]
    # Outward from the measured step-up anchor at index 2, which never moves.
    for i in (1, 0):
        xs[i] = min(xs[i], xs[i + 1] - gap)
    for i in (3, 4):
        xs[i] = max(xs[i], xs[i - 1] + gap)
    return xs, crossover_rate


def _calibrate(
    margins: np.ndarray,
    step_up_quantile: float = 0.05,
    hold_quantile: float = 0.01,
    reference_margins: np.ndarray | None = None,
) -> Calibration:
    """Anchor the score so `explain.ATO_STEP_UP` and `explain.ATO_HOLD` mean something.

    With `reference_margins` - other people's sessions scored through this user's own fitted
    pipeline, see `_reference_margins` - the anchors come from `_crossover_anchors` and the
    realised budget is measured off the owner's margins afterwards rather than assumed. Without
    one the anchors come from `_quantile_anchors` and the budget is the one that was asked for.

    The anchors are kept in `-margin` space so the mapping is increasing, which is what
    np.interp requires and what makes "higher score means more suspicious" true by
    construction rather than by a sign convention someone has to remember.
    """
    ys = [0.0, 0.15, 0.60, 0.85, 1.0]

    if reference_margins is None:
        xs = _quantile_anchors(margins, step_up_quantile, hold_quantile)
        crossover_rate: float | None = None
        reference_sessions = 0
        anchored_on_reference = False
    else:
        xs, crossover_rate = _crossover_anchors(margins, reference_margins)
        reference_sessions = int(len(reference_margins))
        anchored_on_reference = True
        # The measured share of the owner's own out-of-sample sessions at or beyond each
        # anchor, replacing the share that used to be asserted. Quantised to 1/len(margins) -
        # five enrolment sessions can only report multiples of 20% - which is the honest
        # resolution of this estimate and the reason the anchor itself is no longer taken from
        # it. `crossover_rate` is the number to read for the realised rate.
        step_up_quantile = float(np.mean(margins <= -xs[2]))
        hold_quantile = float(np.mean(margins <= -xs[3]))

    return Calibration(
        xs=tuple(xs),
        ys=tuple(ys),
        step_up_quantile=step_up_quantile,
        hold_quantile=hold_quantile,
        oos_margin_mean=float(margins.mean()),
        oos_margin_std=float(margins.std()),
        anchored_on_reference=anchored_on_reference,
        reference_sessions=reference_sessions,
        crossover_rate=crossover_rate,
    )


BACKGROUND_SAMPLE = 8


def train_ato(
    rows: list[tuple[float, ...]],
    nu: float = 0.08,
    per_user: bool | None = None,
    reference: list[tuple[float, ...]] | None = None,
) -> AtoModel:
    """Fit the owner model on genuine sessions only.

    Per-user `OneClassSVM(kernel="rbf", gamma="scale")` on standardised features, which is what
    the research note settles on for a budget of minutes rather than hours. Below
    MIN_ENROLMENT_SESSIONS it falls back to a global IsolationForest, and says so via
    `per_user`, so a cold-start user is never scored by a model fitted on three points and
    presented as if it were personalised.

    Only the morphology columns are used - see `schema.Signal` for why identity must not read
    tempo. Full wire rows go in; the projection happens here.

    `reference` is a sample of sessions belonging to OTHER PEOPLE - the same pooled population
    `train.train_cold_start` already fits over. It never trains anything; it is scored through
    this user's own fitted pipeline to give the calibration an impostor margin distribution to
    place its anchors against. The one-class property is untouched: no impostor row reaches
    `_fit_pipeline`, which is the pitfall `schema` and the module docstring both warn about.

    Pass it whenever the population is available. Omitting it leaves the model on the quantile
    fallback, which `Calibration.anchored_on_reference` records as False.
    """
    if not rows:
        raise ValueError("no enrolment sessions to train on")

    x = identity_matrix(rows)
    reference_matrix: np.ndarray | None = None
    if reference is not None:
        if len(reference) < MIN_REFERENCE_SESSIONS:
            raise ValueError(
                f"reference sample has {len(reference)} sessions, below MIN_REFERENCE_SESSIONS "
                f"({MIN_REFERENCE_SESSIONS}); a crossover placed against fewer cannot resolve "
                "the acceptance rate it is being placed at. Pass more population sessions, or "
                "pass none and take the documented quantile fallback"
            )
        # A reference row that is also an enrolment row would put the owner into her own
        # impostor distribution and drag the crossover toward her, inflating the step-up line
        # for the one person it is meant to protect. Nothing downstream could detect it, so it
        # is asserted here. Exact-row comparison is enough: the mistake this catches is pooling
        # the population table without excluding the subject, not two people typing identically.
        owned = {tuple(row) for row in rows}
        collisions = sum(1 for row in reference if tuple(row) in owned)
        if collisions:
            raise AssertionError(
                f"{collisions} of {len(reference)} reference sessions are also enrolment "
                "sessions; a reference sample must hold other people's sessions only, or the "
                "crossover is measured against the owner herself"
            )
        reference_matrix = identity_matrix(reference)

    # Inferring per_user from the row count is right for a real person and wrong for the
    # population model: 800 rows pooled from 100 users would be labelled per_user=True and
    # fitted as a OneClassSVM, which is the opposite of a cold-start artefact. An explicit
    # override lets the caller say which kind it is asking for.
    if per_user is None:
        per_user = len(rows) >= MIN_ENROLMENT_SESSIONS
    pipeline = _fit_pipeline(x, per_user, nu)
    calibration = _calibrate(
        _out_of_sample_margins(x, per_user, nu),
        reference_margins=(
            None if reference_matrix is None
            else _reference_margins(pipeline, reference_matrix)
        ),
    )
    return AtoModel(
        pipeline=pipeline,
        per_user=per_user,
        n_train_sessions=len(rows),
        calibration=calibration,
        background=tuple(rows[:BACKGROUND_SAMPLE]),
    )


@dataclass(frozen=True, slots=True)
class CoachingModel:
    """Supervised, because unlike identity we can label coaching - we generate it."""

    pipeline: Pipeline
    feature_names: tuple[str, ...]

    def score(self, features: list[float]) -> float:
        x = np.asarray(features, dtype=float).reshape(1, -1)
        return float(self.pipeline.predict_proba(x)[0][1])

    def scores(self, matrix: list[list[float]]) -> list[float]:
        return [self.score(features) for features in matrix]


def train_coaching(
    genuine: list[list[float]], coached: list[list[float]], feature_names: tuple[str, ...]
) -> CoachingModel:
    """Logistic regression over the timing and dead-time features only.

    Kept linear and narrow on purpose. The output has to be explainable to a customer in one
    Bangla sentence, and a model that can only see hesitation cannot smuggle identity into a
    coaching verdict.
    """
    if not genuine or not coached:
        raise ValueError("need both genuine and coached sessions to fit a classifier")

    x = np.asarray(genuine + coached, dtype=float)
    y = np.asarray([0] * len(genuine) + [1] * len(coached))
    pipeline = Pipeline([
        ("scale", StandardScaler()),
        ("model", LogisticRegression(max_iter=1000)),
    ])
    pipeline.fit(x, y)
    return CoachingModel(pipeline=pipeline, feature_names=feature_names)


def equal_error_rate(genuine: list[float], impostor: list[float]) -> tuple[float, float]:
    """Sweep the threshold and return (eer, threshold).

    Scores run "higher means more impostor-like", so a session is accepted when its score is at
    or below the threshold. FRR is genuine sessions rejected; FAR is impostor sessions accepted.
    EER is where the two cross.
    """
    if not genuine or not impostor:
        raise ValueError("EER needs both genuine and impostor scores")

    g = np.asarray(genuine, dtype=float)
    i = np.asarray(impostor, dtype=float)
    thresholds = np.unique(np.concatenate([g, i]))

    best_eer, best_threshold, best_gap = 1.0, float(thresholds[0]), float("inf")
    for t in thresholds:
        frr = float(np.mean(g > t))
        far = float(np.mean(i <= t))
        gap = abs(far - frr)
        if gap < best_gap:
            best_eer, best_threshold, best_gap = (far + frr) / 2.0, float(t), gap
    return best_eer, best_threshold


def detection_rate(scores: list[float], threshold: float) -> float:
    """Fraction of sessions scoring at or above the threshold - used for coached detection."""
    if not scores:
        return 0.0
    return float(np.mean(np.asarray(scores, dtype=float) >= threshold))


def save(model: object, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    joblib.dump(model, path)


def load(path: Path) -> object:
    return joblib.load(path)
