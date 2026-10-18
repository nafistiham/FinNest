"""Explanation behaviour, with Gemini stubbed.

The point of these tests is that the dangerous failures here are not crashes. A model that
invents a reason, or quietly downgrades a hold to an allow, produces output that looks perfectly
fine and is wrong in a way a customer cannot detect. So each of those is pinned.
"""

from __future__ import annotations

import random
from dataclasses import dataclass
from typing import Any

import pytest

from bhorosha_ato import explain, model, synth
from bhorosha_ato.explain import Attribution, ChallengeExplanation, Reason


@dataclass
class StubResult:
    parsed: Any


class StubGemini:
    """Stands in for genai_client.call, recording what it was asked and replying to script."""

    def __init__(self, *replies: Any) -> None:
        self.replies = list(replies)
        self.calls: list[dict[str, Any]] = []

    def __call__(self, task, role_name, contents, schema=None, system=None):
        self.calls.append(
            {"task": task, "role_name": role_name, "contents": contents, "system": system}
        )
        reply = self.replies.pop(0) if self.replies else None
        if isinstance(reply, Exception):
            raise reply
        return StubResult(parsed=reply)


@pytest.fixture
def attributions() -> list[Attribution]:
    return [
        Attribution("pin_tap_offset_mean_px", 14.2, 6.5, 0.31),
        Attribution("imu_tilt_dominant_rad", 0.71, 0.42, 0.22),
        Attribution("pressure_mean", 0.49, 0.52, 0.04),
    ]


def _explanation(action: str, features: list[str]) -> ChallengeExplanation:
    return ChallengeExplanation(
        action=action,
        bangla_message="পরীক্ষার জন্য একবার পরিচয় নিশ্চিত করতে চাই।",
        english_message="We would like to confirm it is you.",
        reasons=[Reason(feature=f, plain_bangla="ব্যবহারের ধরন অন্যরকম") for f in features],
        confidence=0.8,
    )


# --- the severity floor ----------------------------------------------------

def test_coaching_while_on_a_call_forces_a_hold():
    """The case the demo turns on."""
    assert explain.required_action(0.21, 0.78, in_call=True) == "hold_and_callback"


def test_coaching_alone_steps_up_rather_than_holding():
    assert explain.required_action(0.21, 0.78, in_call=False) == "step_up"


def test_middle_identity_band_steps_up_and_never_blocks():
    """Shared-phone inclusion: Rahima shares a phone. Protection that locks her out is exclusion."""
    assert explain.required_action(0.70, 0.0, in_call=False) == "step_up"


def test_quiet_session_is_allowed():
    assert explain.required_action(0.10, 0.05, in_call=False) == "allow"


# --- the validator ---------------------------------------------------------

def test_invented_reason_is_rejected(attributions):
    bad = _explanation("step_up", ["pin_tap_offset_mean_px", "imu_tilt_dominant_rad",
                                   "swipe_length_px"])
    with pytest.raises(explain.FaithfulnessError, match="no attribution"):
        explain.validate(bad, attributions, "step_up")


def test_missing_material_evidence_is_rejected(attributions):
    """0.31 and 0.22 are material; an explanation may not quietly drop one."""
    bad = _explanation("step_up", ["pin_tap_offset_mean_px"])
    with pytest.raises(explain.FaithfulnessError, match="material evidence"):
        explain.validate(bad, attributions, "step_up")


def test_immaterial_attribution_need_not_be_mentioned(attributions):
    ok = _explanation("step_up", ["pin_tap_offset_mean_px", "imu_tilt_dominant_rad"])
    explain.validate(ok, attributions, "step_up")


def test_model_cannot_soften_the_action(attributions):
    """The failure that matters most: prose that reads fine while the money moves."""
    soft = _explanation("allow", ["pin_tap_offset_mean_px", "imu_tilt_dominant_rad"])
    with pytest.raises(explain.FaithfulnessError, match="softer than"):
        explain.validate(soft, attributions, "hold_and_callback")


def test_model_may_escalate(attributions):
    harder = _explanation("block", ["pin_tap_offset_mean_px", "imu_tilt_dominant_rad"])
    explain.validate(harder, attributions, "step_up")


# --- the call loop ---------------------------------------------------------

def test_faithful_draft_is_returned_on_the_first_call(attributions):
    good = _explanation("step_up", ["pin_tap_offset_mean_px", "imu_tilt_dominant_rad"])
    gemini = StubGemini(good)
    out = explain.explain(0.65, 0.1, attributions, call=gemini)
    assert out is good
    assert len(gemini.calls) == 1
    assert gemini.calls[0]["role_name"] == "workhorse"


def test_rejected_draft_is_retried_once_with_the_violation_named(attributions):
    """The on-camera moment: the validator refuses a draft and the model is told why."""
    bad = _explanation("allow", ["pin_tap_offset_mean_px", "imu_tilt_dominant_rad"])
    good = _explanation("step_up", ["pin_tap_offset_mean_px", "imu_tilt_dominant_rad"])
    gemini = StubGemini(bad, good)

    out = explain.explain(0.65, 0.1, attributions, call=gemini)

    assert out is good
    assert len(gemini.calls) == 2
    assert "rejected" in gemini.calls[1]["system"]
    assert "softer than" in gemini.calls[1]["system"]


def test_two_failures_fall_back_rather_than_shipping_a_bad_draft(attributions):
    bad = _explanation("allow", ["pin_tap_offset_mean_px", "imu_tilt_dominant_rad"])
    gemini = StubGemini(bad, bad)
    out = explain.explain(0.65, 0.1, attributions, call=gemini)
    assert out.action == "step_up"
    explain.validate(out, attributions, "step_up")


def test_gemini_unavailable_still_answers_the_customer(attributions):
    """Demo mode runs with Gemini off, and a paused payment still needs an explanation."""
    gemini = StubGemini(RuntimeError("GenAIDisabled"))
    out = explain.explain(0.9, 0.1, attributions, call=gemini)
    assert out.action == "hold_and_callback"
    assert out.bangla_message


def test_fallback_passes_its_own_validator(attributions):
    out = explain.explain(0.2, 0.8, attributions, in_call=True)
    explain.validate(out, attributions, "hold_and_callback")
    assert "ফোন কেটে" in out.bangla_message


# --- fallbacks only assert what they know -----------------------------------------------
#
# explain() sees two scores, the attributions and whether a call is active. It never sees a SIM event or a verdict,
# so no sentence may claim one, and a call may be mentioned only when in_call says there is one.

CALL_WORDS_EN = ("call", "hang up", "phone")
CALL_WORDS_BN = ("কলে", "ফোন কেটে")


def test_coaching_without_a_call_says_what_was_observed_and_nothing_about_calls():
    """The regression case: explain(0.1, 0.8, [], in_call=False) used to say "you are on a call"."""
    out = explain.explain(0.1, 0.8, [], in_call=False)
    assert not any(w in out.english_message.lower() for w in CALL_WORDS_EN)
    assert not any(w in out.bangla_message for w in CALL_WORDS_BN)
    assert "typing rhythm differed" in out.english_message.lower() and "টাইপ" in out.bangla_message
    assert "SIM" not in out.english_message and "সিম" not in out.bangla_message
    explain.validate(out, [], "step_up", in_call=False)


@pytest.mark.parametrize("in_call", [True, False])
def test_every_fallback_passes_the_validator_with_the_call_state_it_was_given(attributions, in_call):
    for ato_score, coaching_score in ((0.1, 0.1), (0.7, 0.1), (0.9, 0.1), (0.2, 0.8), (0.9, 0.8)):
        out = explain.explain(ato_score, coaching_score, attributions, in_call=in_call)
        explain.validate(out, attributions, explain.required_action(ato_score, coaching_score, in_call), in_call=in_call)


def _claiming(english: str = "We would like to confirm it is you.", bangla: str = "একবার পরিচয় নিশ্চিত করতে চাই।",
              reason: str = "ব্যবহারের ধরন অন্যরকম") -> ChallengeExplanation:
    return ChallengeExplanation(
        action="step_up", bangla_message=bangla, english_message=english, confidence=0.8,
        reasons=[Reason(feature=f, plain_bangla=reason) for f in ("pin_tap_offset_mean_px", "imu_tilt_dominant_rad")],
    )


@pytest.mark.parametrize("draft", [
    _claiming(english="Your SIM was replaced and fraud has been proven."),
    _claiming(english="We have proof this is not you."),
    _claiming(bangla="আপনার সিম বদলানো হয়েছে।"),
    _claiming(bangla="প্রতারণা প্রমাণিত হয়েছে।"),
    _claiming(reason="প্রতারণা নিশ্চিত"),
    _claiming(english="The caller is a scammer."),
    _claiming(english="Fraudsters may be guiding you."),
    _claiming(bangla="একজন প্রতারক আপনাকে ফোন করেছে।"),
    _claiming(reason="জালিয়াত চক্রের ধরন"),
], ids=["en-sim-proven", "en-proof", "bn-sim", "bn-proven", "bn-reason-confirmed", "en-scammer", "en-fraudster", "bn-protarok", "bn-jaliyat"])
def test_a_causal_claim_no_input_backs_is_rejected_even_with_valid_features(attributions, draft):
    with pytest.raises(explain.FaithfulnessError, match="no input backs"):
        explain.validate(draft, attributions, "step_up", in_call=True)


@pytest.mark.parametrize("draft", [
    _claiming(english="You are on a call. Please hang up."),
    _claiming(bangla="আপনি এখন একটি কলে আছেন।"),
], ids=["en", "bn"])
def test_a_call_is_claimed_only_when_there_is_one(attributions, draft):
    with pytest.raises(explain.FaithfulnessError, match="no input backs"):
        explain.validate(draft, attributions, "step_up", in_call=False)
    explain.validate(draft, attributions, "step_up", in_call=True)


def test_similar_words_are_not_mistaken_for_a_sim_claim(attributions):
    explain.validate(_claiming(english="Your touch looks similar but not the same."), attributions, "step_up", in_call=False)


def test_a_draft_claiming_a_call_that_is_not_there_is_retried_with_the_violation_named(attributions):
    bad = _claiming(english="You are on a call with a scammer.")
    good = _explanation("step_up", ["pin_tap_offset_mean_px", "imu_tilt_dominant_rad"])
    gemini = StubGemini(bad, good)
    assert explain.explain(0.65, 0.1, attributions, call=gemini, in_call=False) is good
    assert "no input backs" in gemini.calls[1]["system"]


def test_bangla_message_stays_within_the_sms_sized_limit(attributions):
    out = explain.explain(0.2, 0.8, attributions, in_call=True)
    assert len(out.bangla_message) <= 240


# --- hits handed to the risk engine ---------------------------------------

def test_coached_session_emits_a_hold_hit_with_bangla_text(attributions):
    out = explain.explain(0.21, 0.78, attributions, in_call=True)
    hits = explain.as_behaviour_hits(out, 0.21, 0.78)
    codes = {h.code for h in hits}
    assert codes == {"COACHING_SUSPECTED"}, "identity was low, so only coaching should fire"
    hit = hits[0]
    assert hit.decision == "hold"
    assert hit.text_bn and hit.text_en
    assert 0.0 <= hit.weight <= 1.0


def test_both_scores_high_emits_two_separate_hits(attributions):
    out = explain.explain(0.91, 0.77, attributions, in_call=False)
    hits = explain.as_behaviour_hits(out, 0.91, 0.77)
    assert {h.code for h in hits} == {"ATO_BEHAVIOUR_MISMATCH", "COACHING_SUSPECTED"}


def test_quiet_session_emits_no_hits(attributions):
    out = explain.explain(0.1, 0.1, attributions)
    assert explain.as_behaviour_hits(out, 0.1, 0.1) == ()


# --- SHAP ------------------------------------------------------------------

def test_attributions_point_at_identity_features_only():
    """Identity reads morphology, so an attribution for a tempo feature would be a bug."""
    rng = random.Random(7)
    profile = synth.user_profile(rng)
    rows = synth.genuine_rows(profile, 20, rng)
    fitted = model.train_ato(rows)

    stranger = synth.genuine_rows(synth.user_profile(rng), 1, rng)[0]
    attributions = explain.top_attributions(fitted, stranger, rows[:10], k=4, nsamples=60)

    assert len(attributions) == 4
    for a in attributions:
        assert a.feature in explain.IDENTITY_FEATURES


def test_shap_without_a_background_is_an_error():
    rng = random.Random(7)
    profile = synth.user_profile(rng)
    fitted = model.train_ato(synth.genuine_rows(profile, 10, rng))
    with pytest.raises(ValueError):
        explain.top_attributions(fitted, synth.genuine_rows(profile, 1, rng)[0], [])


def test_the_coaching_hit_follows_the_action_rather_than_always_holding(attributions):
    """A hold without a live call is stricter than required_action asks for.

    Caught by a route test: in_call changed the explanation's action but never the hit's
    decision, so a coached session was held whether or not anyone was on the phone. Shared-phone inclusion
    is the reason that matters - holding Rahima every time is exclusion, not protection.
    """
    on_call = explain.explain(0.2, 0.8, attributions, in_call=True)
    off_call = explain.explain(0.2, 0.8, attributions, in_call=False)

    assert on_call.action == "hold_and_callback"
    assert off_call.action == "step_up"

    assert explain.as_behaviour_hits(on_call, 0.2, 0.8)[0].decision == "hold"
    assert explain.as_behaviour_hits(off_call, 0.2, 0.8)[0].decision == "step_up"
