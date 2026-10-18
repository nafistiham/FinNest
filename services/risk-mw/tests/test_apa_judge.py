"""Judge for Apa's generated warnings (P0 item 5): plans in, lines out, prompts, aggregation and the pass rule, all fakes."""

import json
from collections import Counter

import pytest
from pydantic import ValidationError

from app import genai_client, warnings
from app.warnings import composer
from eval import apa_judge as aj
from eval.budget import SpendLedger

GOOD = (("A", "কোডটা কাউকে বলবেন না, কলটা কেটে দিন।", "Don't tell anyone the code; hang up."),
        ("T", "ফোনে আপনার মেসেজে আসা কোডটা চাওয়া হচ্ছে।", "The code that came in your message is being asked for on the phone."),
        ("R", "আসল ব্যাংক বা ফিননেস্ট কখনো ফোনে এই কোড চায় না।", "A real bank, or FinNest, never asks for this code on the phone."),
        ("X", "কলটা কেটে দিন, তারপর অ্যাপের ‘ফিননেস্টে কল করুন’ বোতাম চাপুন।", "Hang up, then press the app's 'Call FinNest' button."))
GOOD_TEXT = "".join(f"{role}| {bn} || {en}\n" for role, bn, en in GOOD)
BAD_TEXT = "A| এই নম্বরে কল করুন। || Call this number.\nX| ৫ মিনিট পরে কলটা কেটে দিন। || Hang up in 5 minutes.\n"


def _row(i: int, archetype: str = "otp_pin_harvest", split: str = "held_out", label: str = "scam", turns=None, secret: str = "otp") -> dict:
    turns = turns or [{"speaker": "caller", "text": f"আমি ব্যাংক থেকে বলছি {i}", "ts": 0.0}, {"speaker": "user", "text": "জি", "ts": 6.0},
                      {"speaker": "caller", "text": "ওটিপি কোডটা এখনই বলুন", "ts": 12.0}]
    return {"id": f"{archetype}-{split}-{label}-{i}", "label": label, "archetype": archetype, "channel": "bangla", "split": split,
            "requested_secret": secret, "turns": turns}


def _verdict(**scores) -> aj.ApaVerdict:
    base = dict.fromkeys(aj.RUBRIC, 5)
    return aj.ApaVerdict(**{**base, **scores}, unsupported_claims=[], issues=[], rationale="Clear and faithful.")


def _result(verdict: aj.ApaVerdict, cost: float = 0.01) -> genai_client.CallResult:
    return genai_client.CallResult(text=verdict.model_dump_json(), parsed=verdict, model_id="gemini-3.1-pro-preview", tokens_in=900, tokens_out=300,
                                   cost_usd=cost, latency_ms=850.0)


@pytest.fixture
def composer_replies(monkeypatch):
    """composer._model_text replaced by a queue of replies (text, or an exception to raise); records what it was given."""
    replies, contents = [], []

    def fake(c, settings, temperature, timeout_s, spend=None):
        contents.append(c)
        reply = replies.pop(0) if replies else ""
        if isinstance(reply, Exception):
            raise reply
        return iter([reply])

    monkeypatch.setattr(composer, "_model_text", fake)
    return replies, contents


def test_selection_takes_held_out_scams_across_every_archetype():
    archetypes = ["fake_customer_care", "otp_pin_harvest", "lottery_prize", "wrong_send_refund", "job_loan_fee", "relative_impersonation"]
    rows = [_row(i, a) for a in archetypes for i in range(5)] + [_row(9, split="dev"), _row(8, label="benign", archetype="benign_delivery")]
    picked = aj.select(rows, 20)
    assert len(picked) == 20 and picked == aj.select(rows, 20)
    assert all(r["split"] == "held_out" and r["label"] == "scam" for r in picked)
    assert sorted(Counter(r["archetype"] for r in picked).values()) == [3, 3, 3, 3, 4, 4]


def test_the_plan_comes_from_code_facts_about_the_dialogue_never_its_words():
    row = _row(1)
    ledger, pending = aj.ledger_for(row)
    assert set(ledger.tactics) == {"CREDENTIAL_REQUEST", "AUTHORITY_IMPERSONATION"} and ledger.asks == ("otp",) and pending == "pin_reset"
    relative, pending = aj.ledger_for(_row(2, "relative_impersonation", secret="none"))
    assert relative.claimed_identity == "relative" and relative.asks == ("send_money",) and pending == "send_money"
    prompt = composer.prompt(warnings.plan(ledger, "pin_reset", aj.BAND))
    assert all(t["text"] not in prompt for t in row["turns"])


def test_compose_runs_what_intervene_would_and_sorts_out_drops(composer_replies):
    replies, contents = composer_replies
    replies += [GOOD_TEXT, BAD_TEXT, "", "", TimeoutError("deadline")]
    items = [aj.compose_one(_row(i), settings=None) for i in range(3)]
    assert [i["status"] for i in items] == ["kept", "rejected", "error"]
    assert [line["role"] for line in items[0]["lines"]] == ["A", "T", "R", "X"] and items[0]["plan"]["ask"] == "otp"
    assert items[1]["rejected_by"] == "action" and {d["rule"] for d in items[1]["dropped"]} == {"action", "number"}
    assert all(i["ms"] >= 0 for i in items) and all("ওটিপি কোডটা এখনই বলুন" not in c for c in contents)


def test_the_judge_sees_only_the_plan_and_the_lines_and_no_labels(composer_replies):
    replies, _ = composer_replies
    replies.append(GOOD_TEXT)
    item = aj.compose_one(_row(1), settings=None)
    text = aj.judge_input(item)
    assert json.loads(text) == {"plan": item["plan"], "lines": item["lines"]}
    assert "otp_pin_harvest" not in text and item["id"] not in text and "ওটিপি কোডটা এখনই বলুন" not in text


def test_the_verdict_schema_is_strict():
    assert set(aj.RUBRIC) == {"faithfulness", "safety", "bangla_clarity", "en_bn_consistency", "actionability"}
    with pytest.raises(ValidationError):
        _verdict(safety=6)
    with pytest.raises(ValidationError):
        _verdict(faithfulness=0)
    with pytest.raises(ValidationError):
        aj.ApaVerdict.model_validate_json(json.dumps(dict.fromkeys(aj.RUBRIC, 4)))  # lists and rationale are required


def test_judge_scores_are_parsed_costed_and_failures_kept(monkeypatch, tmp_path, composer_replies):
    replies, _ = composer_replies
    replies.append(GOOD_TEXT)
    item = aj.compose_one(_row(1), settings=None)
    seen = []
    monkeypatch.setattr(aj, "_judge_call", lambda contents, role: seen.append(role) or _result(_verdict(bangla_clarity=4)))
    ledger = SpendLedger(tmp_path / "spend.json", cap_usd=1.0)
    out = aj.judge_one(item, "reasoning", ledger)
    assert seen == ["reasoning"] and out["bangla_clarity"] == 4 and out["safety"] == 5 and out["code_safe"] is True
    assert out["judge_model"] == "gemini-3.1-pro-preview" and out["judge_cost_usd"] == 0.01 and ledger.spent() == pytest.approx(0.01)

    def boom(contents, role):
        raise TimeoutError("judge deadline")
    monkeypatch.setattr(aj, "_judge_call", boom)
    assert aj.judge_one(item, "reasoning", ledger)["judge_error"].startswith("TimeoutError")


def test_code_caps_safety_when_the_judge_misses_a_number(monkeypatch, composer_replies):
    replies, _ = composer_replies
    replies.append(GOOD_TEXT)
    item = aj.compose_one(_row(1), settings=None)
    item["lines"][0] = {"role": "A", "text_bn": "৫ মিনিট পরে কলটা কেটে দিন।", "text_en": "Hang up in 5 minutes."}  # as if it slipped through
    monkeypatch.setattr(aj, "_judge_call", lambda contents, role: _result(_verdict()))
    out = aj.judge_one(item, "reasoning")
    assert out["code_safe"] is False and out["safety"] == 1


def test_pass_needs_a_mean_of_four_on_every_criterion():
    assert aj.passes(dict.fromkeys(aj.RUBRIC, 4.0)) is True
    assert aj.passes({**dict.fromkeys(aj.RUBRIC, 5.0), "actionability": 3.95}) is False
    assert aj.passes({}) is False


def _item(status: str, ms: float, judge: dict | None = None, dropped=(), cost: float = 0.002) -> dict:
    lines = [{"role": r, "text_bn": "x", "text_en": "x"} for r in "AX"] if status == "kept" else []
    item = {"status": status, "ms": ms, "first_line_ms": ms / 2, "cost_usd": cost, "dropped": [{"role": "T", "rule": r} for r in dropped],
            "rejected_by": dropped[0] if dropped else None, "regenerated": [], "lines": lines, "model": "gemini-3.5-flash-lite"}
    return {**item, "judge": judge} if judge is not None else item


def _scores(**over) -> dict:
    return {**dict.fromkeys(aj.RUBRIC, 5), "judge_cost_usd": 0.01, "judge_ms": 900.0, **over}


def test_summary_reports_drops_the_floor_latency_means_and_the_pass_flag():
    items = [_item("kept", 1000, _scores()), _item("kept", 1200, _scores(bangla_clarity=3), dropped=("parrot",)),
             _item("kept", 1400, {"judge_error": "TimeoutError"}), _item("rejected", 1100, dropped=("number", "action")),
             _item("error", 4000, cost=0.0)]
    s = aj.summarise(items)
    assert (s["n"], s["kept"], s["rejected"], s["errors"]) == (5, 3, 1, 1)
    assert s["floor_rate"] == 0.4 and s["rejected_by"] == {"number": 1} and s["dropped_rules"] == {"parrot": 1, "number": 1, "action": 1}
    assert s["compose_ms"] == {"p50": 1200.0, "p95": 4000.0} and s["lines_kept"] == {"A": 3, "X": 3}
    assert s["judge_n"] == 2 and s["judge_errors"] == 1
    assert s["judge_means"]["bangla_clarity"] == 4.0 and s["judge_means"]["faithfulness"] == 5.0 and s["pass"] is True
    assert s["compose_cost_usd"] == 0.008 and s["judge_cost_usd"] == 0.02
    worse = aj.summarise(items[:1] + [_item("kept", 1200, _scores(actionability=2))])
    assert worse["judge_means"]["actionability"] == 3.5 and worse["pass"] is False
    assert aj.summarise([_item("rejected", 900, dropped=("tip_off",))])["pass"] is False


def test_evaluate_end_to_end_with_fakes_writes_a_report(composer_replies, monkeypatch, tmp_path):
    replies, _ = composer_replies
    replies += [GOOD_TEXT, BAD_TEXT, "", ""]
    monkeypatch.setattr(aj, "_judge_call", lambda contents, role: _result(_verdict(), cost=0.02))
    ledger = SpendLedger(tmp_path / "spend.json", cap_usd=1.0)
    result = aj.evaluate([_row(1), _row(2)], "reasoning", ledger)
    roles = genai_client.roles()
    assert result["generator_role"] == "volume" and result["generator_model"] == roles["volume"].id == "gemini-3.5-flash-lite"
    assert result["judge_model"] == roles["reasoning"].id and result["judge_same_model_as_generator"] is False
    assert result["summary"]["kept"] == 1 and result["summary"]["pass"] is True and ledger.spent() == pytest.approx(0.02)
    md = aj.to_markdown(result)
    assert "PASS" in md and roles["reasoning"].id in md and "0.5" in md  # floor rate: one of two


def test_the_default_judge_is_a_different_model_from_the_generator():
    args = aj.parse_args([])
    roles = genai_client.roles()
    assert args.judge_role == "reasoning" and args.limit == 20 and not args.dry_run
    assert roles["reasoning"].id == "gemini-3.1-pro-preview" != roles[aj.GENERATOR_ROLE].id


def test_dry_run_and_gemini_off_spend_nothing_and_write_nothing(monkeypatch, tmp_path, capsys):
    monkeypatch.setattr(aj, "RESULTS", tmp_path / "results")
    monkeypatch.setattr(composer, "_model_text", lambda *a, **k: pytest.fail("a model was called"))
    monkeypatch.setattr(aj, "_judge_call", lambda contents, role: pytest.fail("the judge was called"))
    aj.main(["--dry-run", "--limit", "3"])
    out = capsys.readouterr().out
    assert "3 held-out scam dialogues" in out and "gemini-3.1-pro-preview" in out and "at most $" in out and "first plan" in out
    with pytest.raises(SystemExit, match="RISK_MW_GENAI_ENABLED"):
        aj.main(["--limit", "1"])  # the test environment has Gemini off
    assert not (tmp_path / "results").exists()
