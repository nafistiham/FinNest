"""DEST_MULE_RISK says what the score measures: the risk this transfer brings, not "a known mule"."""

from __future__ import annotations

import pytest

from app import payee
from app.payee import PayeeScreen

THRESHOLD = 0.80
LEAD_BN = "এই নম্বরে টাকা পাঠালে ঝুঁকি বাড়ে কারণ"
LEAD_EN = "Sending money to this number raises the risk because"


def _screen(before: float = 0.0002, after: float | None = 0.9082, moved: str | None = "hops_to_recent_sim_swap") -> PayeeScreen:
    return PayeeScreen(acct_id="acct_01070", as_of="2026-11-10T14:13:00", before=before, with_this_transfer=after, moved_feature=moved)


def _texts(screen: PayeeScreen | None) -> tuple[str, str]:
    return payee.reason_text(screen, THRESHOLD)


@pytest.mark.parametrize("screen", [_screen(), _screen(before=0.95), _screen(moved=None), _screen(moved="p2p_in_count_30d"), _screen(before=0.95, after=None), None])
def test_every_reason_leads_with_what_sending_does_and_never_calls_the_payee_a_known_mule(screen):
    text_bn, text_en = _texts(screen)
    assert text_bn.startswith(LEAD_BN) and text_bn.endswith("।")
    assert text_en.startswith(LEAD_EN) and text_en.endswith(".")
    assert "মিউল" not in text_bn and "mule" not in text_en.lower() and "known to" not in text_en.lower()


def test_a_sim_swap_mover_is_named_in_both_languages():
    text_bn, text_en = _texts(_screen())
    assert "সিম" in text_bn and "২৪ ঘণ্টা" in text_bn
    assert "SIM" in text_en and "24 hours" in text_en


@pytest.mark.parametrize("feature", ["hops_to_recent_sim_swap", "inbound_from_recent_swap_7d"])
def test_both_sim_swap_features_read_the_same(feature):
    assert _texts(_screen(moved=feature)) == _texts(_screen())


@pytest.mark.parametrize("feature", ["p2p_in_count_30d", "in_total_7d", "distinct_senders_30d"])
def test_an_inflow_mover_says_the_money_coming_in_is_unusual_and_nothing_about_sims(feature):
    text_bn, text_en = _texts(_screen(moved=feature))
    assert "SIM" not in text_en and "সিম" not in text_bn
    assert "coming in" in text_en


def test_a_payee_already_suspicious_before_the_transfer_is_described_as_such():
    text_bn, text_en = _texts(_screen(before=0.95))
    assert "already" in text_en and "আগেই" in text_bn


def test_a_hit_from_the_demo_panel_claims_only_a_high_score():
    text_bn, text_en = _texts(None)
    assert "risk score" in text_en and "স্কোর" in text_bn
    assert _texts(_screen(after=0.1)) == (text_bn, text_en)  # the model is quiet: the flag drove the hit


def test_without_a_paying_account_the_rule_uses_the_score_before_and_says_the_transfer_was_not_screened():
    unscreened = _screen(before=0.95, after=None, moved=None)
    assert unscreened.rule_score == 0.95
    text_bn, text_en = _texts(unscreened)
    assert "paying account is not known" in text_en and "চেনা নয়" in text_bn
    assert _screen(before=0.0002, after=None).rule_score == 0.0002


def test_an_unlisted_mover_falls_back_to_the_pattern_sentence():
    assert _texts(_screen(moved="kind_is_till")) == _texts(_screen(moved=None))


def test_response_fields_carry_both_numbers_and_the_clock():
    assert payee.response_fields(None) == {}
    assert payee.response_fields(_screen()) == {
        "payee_score_before": 0.0002,
        "payee_score_with_this_transfer": 0.9082,
        "payee_moved_feature": "hops_to_recent_sim_swap",
        "payee_score_as_of": "2026-11-10T14:13:00",
    }
