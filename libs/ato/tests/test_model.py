"""Model behaviour on generated sessions.

These run without the HMOG archive on purpose: the pipeline has to be provably correct before
real data arrives, and the properties asserted here are the ones the demo depends on.

Nothing here is a measured result. Numbers against the spec's targets come only from
`eval/ato_eval.py` on HMOG.
"""

from __future__ import annotations

import random

import numpy as np
import pytest

from bhorosha_ato import schema, model, synth
from bhorosha_ato.schema import FEATURES, INDEX


@pytest.fixture
def rng() -> random.Random:
    return random.Random(30)


@pytest.fixture
def owner(rng: random.Random):
    """One user's profile plus enough enrolment sessions for a per-user model."""
    profile = synth.user_profile(rng)
    return profile, synth.genuine_rows(profile, 40, rng)


def test_generated_row_matches_the_wire_contract(owner):
    _, rows = owner
    assert all(len(row) == len(FEATURES) for row in rows)


def test_a_per_user_model_separates_its_owner_from_strangers(owner, rng):
    """The premise of the whole model: how someone touches the phone identifies them."""
    profile, enrolment = owner
    fitted = model.train_ato(enrolment)

    held_out = synth.genuine_rows(profile, 30, rng)
    impostors = [
        row
        for _ in range(12)
        for row in synth.genuine_rows(synth.user_profile(rng), 3, rng)
    ]

    eer, threshold = model.equal_error_rate(fitted.scores(held_out), fitted.scores(impostors))
    assert 0.0 <= eer < 0.25, f"owner and strangers are not separable at all (EER {eer:.3f})"
    assert isinstance(threshold, float)


def test_cold_start_user_is_not_passed_off_as_personalised(rng):
    """Two enrolment sessions cannot support a per-user model, and the model must admit it."""
    profile = synth.user_profile(rng)
    fitted = model.train_ato(synth.genuine_rows(profile, 2, rng))
    assert fitted.per_user is False
    assert fitted.n_train_sessions == 2


def test_training_without_sessions_is_an_error_not_an_empty_model(rng):
    with pytest.raises(ValueError):
        model.train_ato([])


def test_coach_leaves_the_grip_untouched(owner, rng):
    """Rule 5 of the generator: same person, same phone, so the IMU block must not move."""
    _, rows = owner
    for row in rows[:10]:
        coached = synth.coach(row, rng)
        for name in synth.GRIP_FEATURES:
            assert coached[INDEX[name]] == row[INDEX[name]]


def test_coach_slows_typing_and_adds_hesitation(owner, rng):
    _, rows = owner
    for row in rows[:10]:
        coached = synth.coach(row, rng)
        assert coached[INDEX["pin_flight_1_ms"]] + coached[INDEX["pin_flight_2_ms"]] \
            + coached[INDEX["pin_flight_3_ms"]] > row[INDEX["pin_flight_1_ms"]] \
            + row[INDEX["pin_flight_2_ms"]] + row[INDEX["pin_flight_3_ms"]]
        assert coached[INDEX["pin_backspaces"]] > row[INDEX["pin_backspaces"]]
        assert coached[INDEX["swipe_v_mean"]] < row[INDEX["swipe_v_mean"]]


def test_coaching_model_detects_generated_coached_sessions(owner, rng):
    profile, enrolment = owner
    coached = synth.coached_rows(enrolment, rng)
    fitted = model.train_coaching(
        synth.coaching_matrix(enrolment),
        synth.coaching_matrix(coached),
        synth.COACHING_FEATURES,
    )

    fresh_genuine = synth.genuine_rows(profile, 30, rng)
    fresh_coached = synth.coached_rows(fresh_genuine, rng)

    detected = model.detection_rate(fitted.scores(synth.coaching_matrix(fresh_coached)), 0.6)
    false_positives = model.detection_rate(
        fitted.scores(synth.coaching_matrix(fresh_genuine)), 0.6
    )
    assert detected >= 0.90, f"coached detection {detected:.2f} below the spec's 0.90"
    assert false_positives <= 0.10, f"false positives {false_positives:.2f} above the spec's 0.10"


def test_coached_session_is_still_her(owner, rng):
    """The demo, as an assertion.

    A coached session must stay recognisable as the owner - low ato_score - while the coaching
    score runs high. If these two ever move together, the product loses its only interesting
    claim, and the video's central moment stops being true.
    """
    profile, enrolment = owner
    ato = model.train_ato(enrolment)
    coaching = model.train_coaching(
        synth.coaching_matrix(enrolment),
        synth.coaching_matrix(synth.coached_rows(enrolment, rng)),
        synth.COACHING_FEATURES,
    )

    genuine = synth.genuine_rows(profile, 25, rng)
    coached = synth.coached_rows(genuine, rng)

    impostors = [
        row
        for _ in range(10)
        for row in synth.genuine_rows(synth.user_profile(rng), 3, rng)
    ]
    _, identity_threshold = model.equal_error_rate(ato.scores(genuine), ato.scores(impostors))

    still_her = model.detection_rate(
        [-s for s in ato.scores(coached)], -identity_threshold
    )
    coached_flagged = model.detection_rate(
        coaching.scores(synth.coaching_matrix(coached)), 0.6
    )

    assert still_her >= 0.80, (
        f"only {still_her:.0%} of coached sessions were still recognised as the owner; "
        "the identity model is reacting to hesitation, which collapses the two scores into one"
    )
    assert coached_flagged >= 0.90, f"coaching score missed them ({coached_flagged:.0%})"


def test_eer_needs_both_sides(owner):
    _, rows = owner
    fitted = model.train_ato(rows)
    with pytest.raises(ValueError):
        model.equal_error_rate(fitted.scores(rows), [])


def test_models_round_trip_through_disk(owner, tmp_path):
    _, rows = owner
    fitted = model.train_ato(rows)
    path = tmp_path / "ato_rina.pkl"
    model.save(fitted, path)
    reloaded = model.load(path)
    assert reloaded.score(rows[0]) == pytest.approx(fitted.score(rows[0]))


# --- score calibration ----------------------------------------------------

def test_a_stranger_scores_above_the_step_up_line_and_the_owner_below(owner, rng):
    """The bug this calibration exists to fix.

    With a plain sigmoid over the SVM margin, every session landed near 0.5: a stranger scored
    0.55 against the owner's 0.50, so absolute thresholds were meaningless and a stranger
    holding her unlocked phone was allowed through. EER never caught it, because EER sweeps a
    relative threshold and is blind to where the scores actually sit.

    This was a strict xfail until the reference path existed, and the assertions below are the
    ones it carried unchanged. The quantile anchors it used to be run against overshot their 5%
    budget sevenfold - 33.5% measured on real HMOG writing sessions, 23% here - so what
    makes it pass is not a weaker bound but a `reference` sample: with the population to measure
    against, `train_ato` places the step-up line at the crossover instead of at a 5th percentile
    of five numbers. Without one it would still fail, which is why the fallback exists and is
    labelled rather than relied on.
    """
    profile, enrolment = owner
    population = [
        row for _ in range(20) for row in synth.genuine_rows(synth.user_profile(rng), 3, rng)
    ]
    fitted = model.train_ato(enrolment, reference=population)

    her_own = fitted.scores(synth.genuine_rows(profile, 30, rng))
    strangers = fitted.scores([
        row for _ in range(12) for row in synth.genuine_rows(synth.user_profile(rng), 3, rng)
    ])

    # Not perfect separation - there is genuine overlap at a few percent EER, and demanding
    # none would just be a test that fails on honest data. What must hold is that the two
    # populations sit on opposite sides of the policy lines.
    her_median = sorted(her_own)[len(her_own) // 2]
    stranger_median = sorted(strangers)[len(strangers) // 2]
    assert stranger_median - her_median > 0.30, (
        f"owner median {her_median:.2f} vs stranger median {stranger_median:.2f}: "
        "the score scale is too compressed for absolute thresholds to mean anything"
    )
    assert sum(s >= 0.60 for s in her_own) / len(her_own) <= 0.15
    assert sum(s >= 0.60 for s in strangers) / len(strangers) >= 0.80


def test_score_is_monotone_in_the_margin(owner):
    """Lower margin must always mean a higher score, or the Bangla explanation argues backwards."""
    _, enrolment = owner
    cal = model.train_ato(enrolment).calibration
    margins = [0.3, 0.1, 0.0, -0.1, -0.3, -0.6]
    scores = [cal.apply(m) for m in margins]
    assert scores == sorted(scores), scores
    assert all(0.0 <= s <= 1.0 for s in scores)


def test_calibration_records_the_policy_it_encodes(owner):
    """The thresholds are a false-reject budget, so the budget has to be inspectable."""
    _, enrolment = owner
    cal = model.train_ato(enrolment).calibration
    assert cal.step_up_quantile == 0.05
    assert cal.hold_quantile == 0.01
    assert cal.oos_margin_std > 0.0


def test_identical_sessions_do_not_break_the_mapping(rng):
    """A user whose sessions are all identical gives degenerate quantiles.

    np.interp needs strictly increasing anchors, so this would otherwise raise or return a
    flat map - and a flat map silently scores everyone the same.
    """
    profile = synth.user_profile(rng)
    one = synth.genuine_row(profile, rng)
    fitted = model.train_ato([one] * 8)
    assert 0.0 <= fitted.score(one) <= 1.0


def test_calibration_survives_the_round_trip(owner, tmp_path):
    _, enrolment = owner
    fitted = model.train_ato(enrolment)
    path = tmp_path / "ato_cal.pkl"
    model.save(fitted, path)
    assert model.load(path).calibration == fitted.calibration


# --- calibration against a population reference -----------------------------
#
# The quantile anchors above promise a 5% false step-up budget and realise 32% on HMOG, because
# a 5th percentile taken from the five k-fold margins that five enrolment sessions allow is
# noise. The tests below pin the replacement: 0.60 placed where the owner-rejection and
# impostor-acceptance rates actually cross, measured against a sample of other people's
# sessions. Nothing here is a measured result either - see this file's docstring - but the
# synthetic owners reproduce the defect faithfully (33-58% false step-up on the fallback path
# against 0-3% on the reference path), so the properties are testable without the archive.


@pytest.fixture
def population(rng: random.Random):
    """Sessions belonging to twenty other people - a stand-in for the pooled cold-start table.

    Twenty rather than three: `MIN_REFERENCE_SESSIONS` rejects a sample too small to resolve the
    acceptance rate the crossover is placed at, and a handful of sessions from one stranger
    would describe that stranger rather than the population.
    """
    return [
        row for _ in range(20) for row in synth.genuine_rows(synth.user_profile(rng), 3, rng)
    ]


def test_a_reference_sample_moves_the_step_up_anchor(owner, population):
    """The whole point: the same enrolment sessions calibrate differently against a population.

    If the anchors came out identical the reference would be decoration, and the realised
    false step-up rate would still be the quantile path's.
    """
    _, enrolment = owner
    fallback = model.train_ato(enrolment).calibration
    anchored = model.train_ato(enrolment, reference=population).calibration

    assert anchored.xs != fallback.xs
    # Index 2 is the 0.60 anchor. The quantile path puts it at the owner's own 5th percentile;
    # the crossover puts it between her sessions and the population, which on these owners is
    # further out - a session has to look more unlike her before it is challenged.
    assert anchored.xs[2] != fallback.xs[2]
    assert anchored.ys == fallback.ys, "the policy lines themselves must not move"


def test_a_model_says_which_calibration_it_carries(owner, population):
    """A caller has to be able to tell the two promises apart.

    The fallback and the crossover anchors make different claims about the same 0.60 line, and
    an artefact that did not say which one it carries would be scored against the wrong one -
    silently, because both produce perfectly plausible numbers.
    """
    _, enrolment = owner
    fallback = model.train_ato(enrolment).calibration
    anchored = model.train_ato(enrolment, reference=population).calibration

    assert fallback.anchored_on_reference is False
    assert fallback.reference_sessions == 0
    assert fallback.crossover_rate is None

    assert anchored.anchored_on_reference is True
    assert anchored.reference_sessions == len(population)
    assert anchored.crossover_rate is not None
    assert 0.0 <= anchored.crossover_rate <= 1.0


def test_the_fallback_calibration_is_byte_for_byte_what_it_always_was(owner):
    """Adding the reference path must not move any already-trained model's scores.

    Every `ato_{user}.pkl` on disk was fitted without a reference, and `cold_start.pkl` is read
    by the risk API as an absolute score. A quiet change to the fallback anchors would re-score
    all of them with nothing in the artefact saying so.
    """
    _, enrolment = owner
    margins = model._out_of_sample_margins(model.identity_matrix(enrolment), True, 0.08)
    assert model.train_ato(enrolment).calibration.xs == tuple(
        model._quantile_anchors(margins, 0.05, 0.01)
    )


def test_the_realised_false_step_up_rate_is_inside_the_promised_budget(rng):
    """The defect, as a measurement rather than as a promise.

    Twelve owners with five enrolment sessions each - the enrolment size the quantile path
    cannot survive - scored on five held-out sessions of their own and on everyone else's. The
    budget asserted here is the product's: `explain.ATO_STEP_UP` must not fire on more than a
    few percent of a customer's own payments.

    Both paths are measured so the comparison is in the failure message. A regression that
    reintroduced the quantile anchors would read 33-58% here.
    """
    people = []
    for _ in range(12):
        profile = synth.user_profile(rng)
        people.append(
            (synth.genuine_rows(profile, 5, rng), synth.genuine_rows(profile, 5, rng))
        )

    stepped_up = held = own_sessions = caught = stranger_sessions = 0
    stepped_up_fallback = caught_fallback = 0
    for subject, (enrolment, holdout) in enumerate(people):
        reference = [row for i, (e, _) in enumerate(people) if i != subject for row in e]
        strangers = [row for i, (_, h) in enumerate(people) if i != subject for row in h]

        anchored = model.train_ato(enrolment, reference=reference)
        own = anchored.scores(holdout)
        stepped_up += sum(1 for s in own if s >= 0.60)
        held += sum(1 for s in own if s >= 0.85)
        own_sessions += len(own)
        caught += sum(1 for s in anchored.scores(strangers) if s >= 0.60)
        stranger_sessions += len(strangers)

        fallback = model.train_ato(enrolment)
        stepped_up_fallback += sum(1 for s in fallback.scores(holdout) if s >= 0.60)
        caught_fallback += sum(1 for s in fallback.scores(strangers) if s >= 0.60)

    false_step_up = stepped_up / own_sessions
    false_hold = held / own_sessions
    strangers_caught = caught / stranger_sessions
    report = (
        f"false step-up {false_step_up:.1%} (fallback "
        f"{stepped_up_fallback / own_sessions:.1%}), false hold {false_hold:.1%}, "
        f"strangers caught {strangers_caught:.1%} (fallback "
        f"{caught_fallback / stranger_sessions:.1%})"
    )
    assert false_step_up <= 0.10, report
    assert false_hold <= 0.05, report
    # The other half of the trade. Placing 0.60 where it means something costs strangers - on
    # HMOG 96.2% caught became 85.5% - and a calibration that bought its budget by letting
    # everyone through would pass the assertion above and be worthless.
    assert strangers_caught >= 0.70, report


def test_the_crossover_score_is_still_monotone_in_the_margin(owner, population):
    """Same property as the quantile path, asserted again because the anchors are new.

    The ordering fixup in `_crossover_anchors` pushes anchors around to keep np.interp's x axis
    increasing, and an off-by-one there would produce a map that scores a worse session lower -
    which the Bangla explanation would then argue backwards.
    """
    _, enrolment = owner
    cal = model.train_ato(enrolment, reference=population).calibration
    margins = [0.3, 0.1, 0.0, -0.1, -0.3, -0.6]
    scores = [cal.apply(m) for m in margins]
    assert scores == sorted(scores), scores
    assert all(0.0 <= s <= 1.0 for s in scores)
    assert list(cal.xs) == sorted(cal.xs), cal.xs


def test_the_measured_budget_is_recorded_rather_than_asserted(owner, population):
    """On the reference path the two quantile fields stop being a promise and become a reading.

    `Calibration` keeps one meaning for `step_up_quantile` on both paths - the share of the
    owner's own out-of-sample sessions at or beyond the anchor - so it has to be measured once
    the crossover, not a percentile, decided where the anchor went.
    """
    _, enrolment = owner
    margins = model._out_of_sample_margins(model.identity_matrix(enrolment), True, 0.08)
    cal = model.train_ato(enrolment, reference=population).calibration

    assert cal.step_up_quantile == pytest.approx(
        sum(1 for m in margins if m <= -cal.xs[2]) / len(margins)
    )
    assert cal.hold_quantile == pytest.approx(
        sum(1 for m in margins if m <= -cal.xs[3]) / len(margins)
    )
    assert cal.hold_quantile <= cal.step_up_quantile


def test_a_reference_sample_too_small_to_measure_with_is_refused(owner):
    """Three strangers cannot locate an 8% acceptance rate, and pretending otherwise is worse.

    Silently falling back would leave a model labelled `anchored_on_reference=False` for a
    caller who believes they supplied a reference, which is the one thing that flag exists to
    prevent.
    """
    _, enrolment = owner
    too_few = enrolment[: model.MIN_REFERENCE_SESSIONS - 1]
    with pytest.raises(ValueError, match="MIN_REFERENCE_SESSIONS"):
        model.train_ato(enrolment, reference=too_few)


def test_the_owner_may_not_appear_in_her_own_reference_sample(owner, population):
    """Pooling the population table without excluding the subject is the obvious mistake.

    It drags the crossover toward the owner and raises her own step-up line, and no downstream
    test on the artefact could detect it: the model stays one-class, the scores stay plausible,
    and only the customer notices.
    """
    _, enrolment = owner
    with pytest.raises(AssertionError, match="other people's sessions only"):
        model.train_ato(enrolment, reference=population + list(enrolment[:1]))


def test_the_owner_reject_curve_leaves_no_dead_zone(owner):
    """The five-sample curve must be able to express a rate between its order statistics.

    A step function reads 0 below the smallest of five margins and 0.2 at it, so a crossing
    meant to land near 0.10 has nowhere to go - measured on HMOG that is the difference between
    a 23.0% and a 10.4% realised false step-up.
    """
    xs, ys = model._owner_reject_curve(np.asarray([-0.5, -0.3, -0.2, -0.1, 0.0]))
    assert list(ys) == pytest.approx([1 / 6, 2 / 6, 3 / 6, 4 / 6, 5 / 6])
    assert list(xs) == sorted(xs)
    # Strictly between the two lowest order statistics, which a step function cannot produce.
    assert 1 / 6 < float(np.interp(-0.4, xs, ys)) < 2 / 6


def test_identical_sessions_do_not_break_the_crossover_mapping(rng, population):
    """A user whose sessions are all identical gives a degenerate owner curve.

    Every margin equal means every plotting position lands on one x value, which np.interp
    cannot interpolate over at all - and the fallback path already has a test for its own
    version of this, so the reference path needs one too.
    """
    profile = synth.user_profile(rng)
    one = synth.genuine_row(profile, rng)
    fitted = model.train_ato([one] * 8, reference=population)
    assert 0.0 <= fitted.score(one) <= 1.0
    assert list(fitted.calibration.xs) == sorted(fitted.calibration.xs)


def _wire(identity_row):
    """An identity-only row padded into a full wire vector."""
    out = [0.0] * len(schema.FEATURES)
    for pos, value in zip(schema.IDENTITY_INDEX, identity_row):
        out[pos] = float(value)
    return tuple(out)


# --- the crossover anchor on a perfectly separated user ---------------------
#
# Measured on the demo phone, not imagined: after enrolling the owner's own PIN sessions the
# OneClassSVM saturated - every impostor session returned the identical margin - so the
# crossover, the hold anchor and the floor anchor all landed on that one value, 5e-08 apart.
# np.interp at exactly that point returned 0.5999999999653823, and a real third person holding
# the phone was allowed through by three parts in ten billion.

def test_crossover_sits_inside_the_gap_not_on_the_impostor_edge():
    owner = np.array([0.020, 0.018, 0.015, 0.012, 0.010, -0.001])
    impostor = np.full(400, -0.183)          # saturated: every stranger the same margin
    threshold, _ = model._crossover(owner, impostor)
    assert impostor[0] < threshold < owner.min(), (
        f"crossover {threshold} is not strictly inside the gap "
        f"({impostor[0]}, {owner.min()}): a session at the impostor margin lands on the anchor"
    )


def test_a_saturated_impostor_scores_clear_of_the_step_up_line():
    """The failure in one assertion: the stranger must not land a hair under the threshold."""
    rng = np.random.default_rng(30)
    owner_rows = [tuple(rng.normal(0.0, 0.01, len(schema.IDENTITY_FEATURES))) for _ in range(20)]
    reference = [tuple(rng.normal(8.0, 0.01, len(schema.IDENTITY_FEATURES))) for _ in range(400)]
    fitted = model.train_ato(
        [_wire(r) for r in owner_rows], reference=[_wire(r) for r in reference]
    )
    stranger = fitted.score(_wire(reference[0]))
    assert stranger >= 0.85, f"a saturated stranger scored {stranger!r}, below the hold line"
