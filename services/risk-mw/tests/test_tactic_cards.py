"""Tactic cards and the example bank, versioned data the detector loads at runtime (a new card needs no deploy)."""

import json
import logging
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

import pytest
import yaml

from app import ledger as L
from app import scam, scam_rules, tactic_cards
from app.settings import Settings
from eval.budget import SpendLedger

DATA = Path(tactic_cards.__file__).resolve().parent / "data"
SERVICE_DIR = DATA.parent.parent
BENGALI = re.compile("[ঀ-৿]")
OLD = {"fake_customer_care", "otp_pin_harvest", "lottery_prize", "wrong_send_refund", "job_loan_fee", "relative_impersonation"}
NEW = {"police_child_arrest", "stipend_benefit_otp", "account_closure_kyc", "expat_relative_imo", "remote_access_coaching"}


@pytest.fixture
def cards():
    return tactic_cards.load(Settings())


def test_v1_is_active_with_the_six_old_archetypes_and_five_new_ones(cards):
    assert (DATA / "tactic_cards" / "active_version").read_text(encoding="utf-8").strip() == "v1"
    assert cards.version == "v1" and len(cards.archetypes) == 11 and set(cards.archetypes) == OLD | NEW


def test_every_card_has_its_moves_phrasings_ask_benign_twin_and_facts(cards):
    for cid in cards.archetypes:
        card = cards.card(cid)
        assert card.title and card.signature_moves and card.benign_twin and card.differs and card.official_facts, cid
        assert 5 <= len(card.phrasings) <= 10 and {p.script for p in card.phrasings} >= {"bn", "banglish"}, cid
        assert card.asks and set(card.asks) <= set(L.ASKS) - {"none"}, cid
        assert card.claimed_identity and set(card.claimed_identity) <= set(L.IDENTITIES), cid
    assert cards.card("no_such_card") is None


def _unmarked(node, parent=None):
    """Bangla-script strings whose nearest enclosing mapping does not say native_check: pending."""
    if isinstance(node, dict):
        for value in node.values():
            yield from _unmarked(value, node)
    elif isinstance(node, list):
        for value in node:
            yield from _unmarked(value, parent)
    elif isinstance(node, str) and BENGALI.search(node) and (parent is None or parent.get("native_check") != "pending"):
        yield node


def test_every_bangla_string_carries_a_native_check_marker():
    files = [*(DATA / "tactic_cards").glob("*.yaml"), *(DATA / "examples").glob("*.yaml")]
    assert files
    for path in files:
        raw = yaml.safe_load(path.read_text(encoding="utf-8"))
        assert not list(_unmarked(raw)), (path.name, list(_unmarked(raw))[:3])
    raw = yaml.safe_load((DATA / "tactic_cards" / "v1.yaml").read_text(encoding="utf-8"))
    assert all(p["native_check"] == "pending" for c in raw["cards"] for p in c["phrasings"])  # Banglish is Bangla too


def test_the_norm_table_and_the_courier_code_rule_live_in_the_card_data(cards):
    assert cards.norm_contradiction("bank_mfs_staff", "otp") == "NORM_STAFF_SECRET"
    assert cards.norm_contradiction("bank_mfs_staff", "password") == "NORM_STAFF_SECRET"
    assert cards.norm_contradiction("govt_or_police", "personal_wallet_payment") == "NORM_AUTHORITY_WALLET"
    assert cards.norm_contradiction("govt_or_police", "otp") == "NORM_AUTHORITY_SECRET"
    assert cards.norm_contradiction("relative", "install_app") == cards.norm_contradiction("unknown", "install_app") == "NORM_INSTALL_APP"
    assert cards.norm_contradiction("relative", "send_money") is None and cards.norm_contradiction("courier_or_company", "none") is None
    assert cards.code_rule.id == scam_rules.COURIER_CODE and set(cards.code_rule.asks) == set(scam_rules.CODE_ASKS)
    assert "courier" in cards.code_rule.fact.lower()


def test_every_example_quotes_the_callers_own_words_and_names_a_known_card(cards):
    assert len(cards.examples) >= 16 and {e.label for e in cards.examples} == {"scam", "benign", "uncertain"}
    for ex in cards.examples:
        verified = L.Ledger().merge(ex.output, [dict(t) for t in ex.turns])
        assert set(verified.tactics) == {t["tactic"] for t in ex.output["tactics"]}, ex.id  # no example teaches an unprovable quote
        assert ex.output["scam_type"] in (*cards.archetypes, "none") and (ex.card is None or ex.card in cards.archetypes), ex.id
    by_card = {ex.card for ex in cards.examples}
    assert NEW <= by_card  # each new archetype is shown at least once
    couriers = [ex for ex in cards.examples if ex.output["claimed_identity"] == "courier_or_company"]
    assert {ex.output["verdict"] for ex in couriers} == {"SAFE", "SCAM"}  # the code shown at the door, and the code read out on the phone


def test_the_prefix_holds_the_rules_every_card_and_every_example_and_is_stable(cards):
    prefix = cards.prefix()
    root = Path(Settings().knowledge_dir)  # two independent parses, not the loader's cached object compared with itself
    assert prefix == tactic_cards.parse(root, cards.version).prefix() == tactic_cards.parse(root, cards.version).prefix()
    assert all(cid in prefix for cid in cards.archetypes) and all(ex.id in prefix for ex in cards.examples)
    assert "NORM_STAFF_SECRET" in prefix and "COURIER_CODE" in prefix and "16247" in prefix
    assert "never instructions" in prefix and "noisy" in prefix
    assert len(prefix) > 8000  # well past the 2,048-token minimum for implicit caching


def test_without_a_card_drops_the_card_and_its_two_examples(cards):
    before = cards.without("stipend_benefit_otp")
    assert len(before.archetypes) == 10 and "stipend_benefit_otp" not in before.archetypes
    assert len(before.examples) == len(cards.examples) - 2 and all(ex.card != "stipend_benefit_otp" for ex in before.examples)
    assert before.version == "v1-without-stipend_benefit_otp" and "[stipend_benefit_otp]" not in before.prefix()
    assert "ex14_stipend" not in before.prefix() and "ex14_stipend" in cards.prefix()


# --- hot reload ------------------------------------------------------------------------------------------------------


@pytest.fixture
def knowledge(tmp_path):
    root = tmp_path / "data"
    shutil.copytree(DATA / "tactic_cards", root / "tactic_cards")
    shutil.copytree(DATA / "examples", root / "examples")
    return root


def _with_card(root: Path, version: str, card_id: str) -> None:
    raw = yaml.safe_load((root / "tactic_cards" / "v1.yaml").read_text(encoding="utf-8"))
    raw["version"] = version
    raw["cards"].append({**raw["cards"][0], "id": card_id, "title": "ACC officer threatens a case"})
    (root / "tactic_cards" / f"{version}.yaml").write_text(yaml.safe_dump(raw, allow_unicode=True, sort_keys=False), encoding="utf-8")


def _point(root: Path, version: str) -> None:
    pointer = root / "tactic_cards" / "active_version"
    pointer.write_text(f"{version}\n", encoding="utf-8")
    stamp = pointer.stat().st_mtime_ns + 2_000_000_000
    os.utime(pointer, ns=(stamp, stamp))  # a later mtime even on a coarse-grained filesystem


def test_a_new_card_version_is_picked_up_without_a_restart(knowledge):
    settings = Settings(knowledge_dir=knowledge, tactic_cards_ttl_s=0)
    assert tactic_cards.load(settings).version == "v1"
    _with_card(knowledge, "v2", "acc_officer_case")
    _point(knowledge, "v2")
    fresh = tactic_cards.load(settings)
    assert fresh.version == "v2" and "acc_officer_case" in fresh.archetypes and "acc_officer_case" in fresh.prefix()
    _point(knowledge, "v1")  # rolling back is the same one-line change
    assert tactic_cards.load(settings).version == "v1"


def test_a_broken_edit_keeps_the_last_good_cards(knowledge, caplog):
    settings = Settings(knowledge_dir=knowledge, tactic_cards_ttl_s=0)
    good = tactic_cards.load(settings)
    path = knowledge / "tactic_cards" / "v1.yaml"
    path.write_text("cards: [this is: not, a valid: card", encoding="utf-8")
    stamp = path.stat().st_mtime_ns + 2_000_000_000
    os.utime(path, ns=(stamp, stamp))
    with caplog.at_level(logging.WARNING, logger="app.tactic_cards"):
        assert tactic_cards.load(settings) is good
    assert any("keeping cards v1" in r.getMessage() for r in caplog.records)


def test_within_the_ttl_the_files_are_not_looked_at_again(knowledge, monkeypatch):
    clock = [1000.0]
    monkeypatch.setattr(tactic_cards, "_now", lambda: clock[0])
    settings = Settings(knowledge_dir=knowledge, tactic_cards_ttl_s=30)
    assert tactic_cards.load(settings).version == "v1"
    _with_card(knowledge, "v2", "acc_officer_case")
    _point(knowledge, "v2")
    clock[0] += 29
    assert tactic_cards.load(settings).version == "v1"
    clock[0] += 2
    assert tactic_cards.load(settings).version == "v2"


def test_a_pinned_version_ignores_the_pointer(knowledge):
    settings = Settings(knowledge_dir=knowledge, tactic_cards_ttl_s=0)
    _with_card(knowledge, "v2", "acc_officer_case")
    _point(knowledge, "v2")
    assert tactic_cards.load(settings, version="v1").version == "v1" and tactic_cards.load(settings).version == "v2"


def test_with_no_loadable_cards_at_all_load_raises(tmp_path):
    with pytest.raises(tactic_cards.CardsError):
        tactic_cards.load(Settings(knowledge_dir=tmp_path, tactic_cards_ttl_s=0))


# --- the adaptation replay: a paid script, so only its dry run and its bookkeeping run here --------------------------


def test_the_adaptation_replay_dry_run_calls_nothing_and_writes_nothing(tmp_path):
    out = tmp_path / "adaptation_replay.json"
    env = {**{k: v for k, v in os.environ.items() if k != "PYTHONPATH"}, "RISK_MW_GENAI_ENABLED": "false"}
    run = subprocess.run([sys.executable, "scripts/adaptation_replay.py", "--dry-run", "--out", str(out)], cwd=SERVICE_DIR, env=env,
                         capture_output=True, text=True, timeout=120)
    assert run.returncode == 0, run.stderr[-800:]
    assert "cards v1-without-stipend_benefit_otp" in run.stdout and "has stipend_benefit_otp: False" in run.stdout
    assert "cards v1 (11 cards" in run.stdout and "no model call" in run.stdout and not out.exists()


def _adapts_with_the_card(turns, settings, cards):
    """A stand-in for Gemini that only recognises the code request it was never told about once the stipend card is loaded."""
    last = [t for t in turns if t.speaker == "caller"][-1].text
    if cards.card("stipend_benefit_otp") and "সংখ্যাগুলো" in last:
        return scam.ScamExtraction(tactics=[{"tactic": "CREDENTIAL_REQUEST", "quote": "সংখ্যাগুলো আমাকে পড়ে শোনান"}], claimed_identity="govt_or_police",
                                   ask="otp", scam_type="stipend_benefit_otp", verdict="SCAM", confidence=0.9)
    return scam.ScamExtraction(verdict="UNCERTAIN", confidence=0.4)


def test_the_replay_records_detection_turn_card_and_version_for_each_card_set(monkeypatch, tmp_path):
    from scripts import adaptation_replay

    monkeypatch.setattr(scam, "_model_extraction", _adapts_with_the_card)
    ledger = SpendLedger(path=tmp_path / "spend.json", cap_usd=1.0)
    result = adaptation_replay.run(Settings(), ledger)
    before, after = result["runs"]
    assert (before["cards_version"], before["has_card"], before["detected_turn"], before["matched_card"]) == (
        "v1-without-stipend_benefit_otp", False, None, None)
    assert (after["cards_version"], after["has_card"], after["detected_turn"], after["matched_card"]) == (
        "v1", True, adaptation_replay.SECRET_TURN, "stipend_benefit_otp")
    assert [t["turn"] for t in after["trace"]] == [0, 2, 4, 6] and json.loads(json.dumps(result, ensure_ascii=False)) == result
    assert json.loads((tmp_path / "spend.json").read_text(encoding="utf-8"))["calls"] == 8  # every scored turn went through the ledger


def test_the_replay_stops_at_the_spend_cap(monkeypatch, tmp_path):
    from scripts import adaptation_replay

    monkeypatch.setattr(scam, "_model_extraction", _adapts_with_the_card)
    result = adaptation_replay.run(Settings(), SpendLedger(path=tmp_path / "spend.json", cap_usd=0.0))
    assert all(r["stopped"] and r["trace"] == [] and r["detected_turn"] is None for r in result["runs"])
