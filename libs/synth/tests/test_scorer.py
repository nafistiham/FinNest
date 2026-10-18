"""Leakage-safe features, LightGBM mule scorer with SHAP reasons, temporal eval."""

from __future__ import annotations

import json
import time
from dataclasses import replace

import pytest

from bhorosha_graph import features as feat
from bhorosha_graph.bundle import build_bundle
from bhorosha_graph.scorer import MuleScorer, pending_transfer, train_and_evaluate, with_transfer
from bhorosha_synth import schema as s
from bhorosha_synth.generate import generate_world

CUTOFF = "2026-11-02T00:00:00"
MULE_HOLD_THRESHOLD = 0.80  # risk-mw's RISK_MW_MULE_HOLD_THRESHOLD default
FORBIDDEN = {"label", "ring_id", "role", "typology", "balance_after", "first_bad_ts", "is_fraud"}


@pytest.fixture(scope="module")
def world():
    return generate_world(s.WorldConfig(seed=42))


@pytest.fixture(scope="module")
def bundle(world):
    return build_bundle(world)


@pytest.fixture(scope="module")
def result(world, bundle):
    return train_and_evaluate(world, bundle)


def test_feature_rows_have_no_forbidden_columns(bundle):
    rows = feat.compute_features(bundle, CUTOFF)
    assert rows
    assert not FORBIDDEN & set(rows[0].keys())
    assert len(rows[0]) >= 20


def test_features_use_only_events_before_cutoff(world, bundle):
    """Truncating the world at the cutoff must not change any feature value."""
    truncated = replace(
        world,
        transactions=tuple(t for t in world.transactions if t["ts"] < CUTOFF),
        sim_events=tuple(e for e in world.sim_events if e["ts"] < CUTOFF),
        device_links=tuple(l for l in world.device_links if l["first_seen"] < CUTOFF),
        labels=tuple(l for l in world.labels if l["first_bad_ts"] < CUTOFF),
    )
    full = {r["acct_id"]: r for r in feat.compute_features(bundle, CUTOFF)}
    cut = {r["acct_id"]: r for r in feat.compute_features(build_bundle(truncated), CUTOFF)}
    assert full == cut


def test_temporal_split_and_metrics(result):
    m = result.metrics
    print(json.dumps(m["test"], indent=1))
    assert m["split"]["train_cutoffs"][-1] < m["split"]["test_cutoffs"][0]
    assert 0 <= m["test"]["auc_pr"] <= 1
    assert m["test"]["precision_at_50"] >= 0.8
    assert m["test"]["ring_level_recall"] >= 0.85
    assert set(m["test"]["recall_by_typology"]) <= set(s.TYPOLOGIES)
    assert "recall_at_precision_0.9" in m["test"]


def test_score_returns_probability_and_ten_shap_reasons_fast(result):
    scorer: MuleScorer = result.scorer
    l1 = next(l["acct_id"] for l in result.labels if l["ring_id"] == s.DEMO_RING_ID and l["role"] == "mule_L1")
    started = time.perf_counter()
    out = scorer.score(l1)
    ms = (time.perf_counter() - started) * 1000
    assert 0 <= out["probability"] <= 1
    assert len(out["reasons"]) == 10
    assert {"feature", "value", "contribution", "direction"} <= set(out["reasons"][0])
    assert ms < 20


def test_ring_members_carry_a_network_reason_near_the_top(result):
    """Spec US-3: the network signal must be load-bearing, not decorative."""
    scorer: MuleScorer = result.scorer
    members = [l["acct_id"] for l in result.labels if l["role"] in ("mule_L1", "mule_L2", "purchased_mule") and l["ring_id"] in (s.DEMO_RING_ID, "ring_cluster_0")]
    network = feat.NETWORK_FEATURES
    hits = sum(1 for acct in members if any(r["feature"] in network for r in scorer.score(acct)["reasons"][:5]))
    assert hits / len(members) >= 0.5


def test_demo_ring_is_surfaced_in_the_top_50(result):
    """The ring the scorer surfaces must be the ring that cashes out Rina's money (spec section 2):
    the L1 mule that received the drain is in the analyst's top 50, so the investigator can expand from it."""
    scorer: MuleScorer = result.scorer
    ranked = scorer.features.assign(p=scorer.booster.predict(scorer.features[list(scorer.feature_names)].to_numpy())).nlargest(50, "p")
    l1 = next(l["acct_id"] for l in result.labels if l["ring_id"] == s.DEMO_RING_ID and l["role"] == "mule_L1")
    demo = {l["acct_id"] for l in result.labels if l["ring_id"] == s.DEMO_RING_ID and l["role"] in ("mule_L1", "mule_L2")}
    assert l1 in set(ranked.index)
    assert len(demo & set(ranked.index)) >= 2


def test_unknown_account_scores_as_zero_with_explanation(result):
    out = result.scorer.score("acct_does_not_exist")
    assert out["probability"] == 0.0 and out["reasons"] == [] and out["known"] is False


# --- time-aware scoring -----------------------------------------------------------------------------------


def test_score_at_the_artefact_cutoff_matches_score(result, bundle):
    scorer: MuleScorer = result.scorer
    l1 = next(l["acct_id"] for l in result.labels if l["ring_id"] == s.DEMO_RING_ID and l["role"] == "mule_L1")
    at_cutoff = scorer.score_at(bundle, l1, scorer.cutoff)
    assert at_cutoff["probability"] == pytest.approx(scorer.score(l1)["probability"], abs=1e-6)
    assert at_cutoff["as_of"] == scorer.cutoff and len(at_cutoff["reasons"]) == 10


def test_score_at_an_earlier_time_does_not_see_the_future(result, bundle):
    scorer: MuleScorer = result.scorer
    l1 = next(l["acct_id"] for l in result.labels if l["ring_id"] == s.DEMO_RING_ID and l["role"] == "mule_L1")
    before_theft = scorer.score_at(bundle, l1, "2026-11-10T14:00:00")
    assert before_theft["as_of"] == "2026-11-10T14:00:00"
    assert before_theft["probability"] < scorer.score(l1)["probability"]


def test_score_at_computes_each_time_once(result, bundle, monkeypatch):
    scorer: MuleScorer = result.scorer
    calls = []
    real = feat.compute_features
    monkeypatch.setattr(feat, "compute_features", lambda b, c, *a, **k: calls.append(c) or real(b, c, *a, **k))
    accts = [l["acct_id"] for l in result.labels if l["role"] == "mule_L2"][:3]
    for acct in accts:
        scorer.score_at(bundle, acct, "2026-11-09T12:00:00")
    assert calls == ["2026-11-09T12:00:00"]


def test_score_at_for_an_unknown_account(result, bundle):
    out = result.scorer.score_at(bundle, "acct_does_not_exist", "2026-11-09T12:00:00")
    assert out["known"] is False and out["probability"] == 0.0 and out["as_of"] == "2026-11-09T12:00:00"


# --- the transfer being screened --------------------------------------------------------------------
#
# The demo payee looks clean strictly before Rina's transfer and like a mule once it has landed, because the
# feature that fires is "received money from an account with a SIM swap in the last 24 h". Screening a payee
# therefore scores it twice at one moment: on the evidence so far, and with the pending transfer appended.


def _demo_transfer(bundle) -> dict:
    l1 = next(l["acct_id"] for l in bundle.labels if l["ring_id"] == s.DEMO_RING_ID and l["role"] == "mule_L1")
    return next(t for t in bundle.txns_by_acct[s.RINA_ACCT] if t["from_acct"] == s.RINA_ACCT and t["to_acct"] == l1)


def _screen_demo(scorer: MuleScorer, bundle, sender: str = s.RINA_ACCT, money_moves: bool = True) -> dict:
    demo = _demo_transfer(bundle)
    return scorer.screen_transfer(bundle, demo["to_acct"], demo["ts"], sender, demo["amount_bdt"] if money_moves else None)


def test_account_features_match_the_full_table(bundle):
    context = feat.feature_context(bundle, CUTOFF)
    table = {r["acct_id"]: r for r in feat.compute_features(bundle, CUTOFF)}
    for acct in sorted(table)[:25] + [s.RINA_ACCT]:
        assert feat.account_features(bundle, acct, context) == table[acct]


def test_account_features_for_an_unscored_account_is_none(bundle):
    assert feat.account_features(bundle, "acct_does_not_exist", feat.feature_context(bundle, CUTOFF)) is None


def test_pending_transfer_lands_one_tick_before_as_of():
    txn = pending_transfer("acct_a", "acct_b", 7900, "2026-11-10T14:13:00")
    assert txn["ts"] == "2026-11-10T14:12:59"
    assert (txn["from_acct"], txn["to_acct"], txn["amount_bdt"], txn["type"]) == ("acct_a", "acct_b", 7900.0, "send_money")


def test_with_transfer_leaves_the_bundle_untouched(bundle):
    demo = _demo_transfer(bundle)
    index, payee_rows, sender_rows = bundle.txns_by_acct, bundle.txns_by_acct[demo["to_acct"]], bundle.txns_by_acct[s.RINA_ACCT]
    txn = pending_transfer(s.RINA_ACCT, demo["to_acct"], 7900, demo["ts"])
    view = with_transfer(bundle, txn)
    assert bundle.txns_by_acct is index and index[demo["to_acct"]] is payee_rows and index[s.RINA_ACCT] is sender_rows
    assert txn not in payee_rows and txn in view.txns_by_acct[demo["to_acct"]] and txn in view.txns_by_acct[s.RINA_ACCT]
    stamps = [t["ts"] for t in view.txns_by_acct[demo["to_acct"]]]
    assert stamps == sorted(stamps)


def test_screening_the_demo_transfer_scores_the_payee_before_and_with_it(result, bundle):
    scorer: MuleScorer = result.scorer
    demo = _demo_transfer(bundle)
    screen = _screen_demo(scorer, bundle)
    before = scorer.score_at(bundle, demo["to_acct"], demo["ts"])
    assert screen["known"] is True and screen["as_of"] == demo["ts"]
    assert screen["before"]["probability"] == pytest.approx(before["probability"], abs=1e-6)
    assert screen["before"]["probability"] < MULE_HOLD_THRESHOLD < screen["with_this_transfer"]["probability"]
    assert screen["moved"]["feature"] in {"hops_to_recent_sim_swap", "inbound_from_recent_swap_7d"}
    assert screen["moved"]["contribution_change"] > 0


def test_screening_twice_gives_the_same_answer_and_leaves_score_at_alone(result, bundle):
    scorer: MuleScorer = result.scorer
    demo = _demo_transfer(bundle)
    first, again = _screen_demo(scorer, bundle), _screen_demo(scorer, bundle)
    assert first == again
    assert scorer.score_at(bundle, demo["to_acct"], demo["ts"])["probability"] == first["before"]["probability"]


def test_the_sim_swap_is_what_rinas_transfer_adds_over_anyone_elses(result, bundle):
    """Measured, not assumed: the same 7,900 from Rafiq (no SIM swap) also crosses the threshold, because the
    amount alone makes an account that cashes out what it receives look like a mule. Rina's swap adds on top."""
    rina, rafiq = _screen_demo(result.scorer, bundle), _screen_demo(result.scorer, bundle, sender=s.RAFIQ_ACCT)
    assert rafiq["with_this_transfer"]["probability"] < rina["with_this_transfer"]["probability"]
    assert rafiq["moved"]["feature"] not in {"hops_to_recent_sim_swap", "inbound_from_recent_swap_7d"}


def test_a_small_transfer_from_an_account_without_a_sim_swap_does_not_cross(result, bundle):
    demo = _demo_transfer(bundle)
    screen = result.scorer.screen_transfer(bundle, demo["to_acct"], demo["ts"], s.RAFIQ_ACCT, 500)
    assert screen["with_this_transfer"]["probability"] < MULE_HOLD_THRESHOLD


def test_screening_without_money_moving_scores_the_evidence_so_far(result, bundle):
    screen = _screen_demo(result.scorer, bundle, money_moves=False)
    assert screen["with_this_transfer"] == screen["before"] and screen["moved"] is None
    demo = _demo_transfer(bundle)
    assert result.scorer.screen_transfer(bundle, demo["to_acct"], demo["ts"]) == screen


def test_screening_without_money_moving_explains_the_row_once(result, bundle, monkeypatch):
    from bhorosha_graph import scorer as scorer_module

    calls = []
    real = scorer_module._shap_row
    monkeypatch.setattr(scorer_module, "_shap_row", lambda explainer, row: calls.append(1) or real(explainer, row))
    _screen_demo(result.scorer, bundle, money_moves=False)
    assert len(calls) == 1


def test_a_transfer_without_a_payer_is_refused(result, bundle):
    with pytest.raises(ValueError, match="paying account"):
        result.scorer.screen_transfer(bundle, "acct_01070", "2026-11-10T14:13:00", None, 500)


def test_screening_an_unknown_payee(result, bundle):
    screen = result.scorer.screen_transfer(bundle, "acct_does_not_exist", "2026-11-10T14:13:00", s.RINA_ACCT, 500)
    assert screen["known"] is False and screen["moved"] is None
    assert screen["before"]["probability"] == screen["with_this_transfer"]["probability"] == 0.0
