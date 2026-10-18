"""Every reason code risk-mw can emit has a place on the console.

ALL_CODES in api/aggregate.py and CHECKS in api/scenarios.py are typed lists, and a typed list goes
stale the day risk-mw learns a new code: APP_SAFETY_CAUTION was emitted for a day before
anyone noticed it appeared in neither column of the overview and in no check of the system picture.
So the codes are read out of risk-mw's own source, not out of a list someone remembered to update.
"""

from __future__ import annotations

import ast
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from api import aggregate, scenarios  # noqa: E402
from api.risk_mw import ATO_PACKAGE, SERVICE, get_settings  # noqa: E402
from app import ato  # noqa: E402

RULES = SERVICE / "app" / "rules.py"
EXPLAIN = ATO_PACKAGE / "bhorosha_ato" / "explain.py"


def _hit_codes(node: ast.AST) -> set[str]:
    """The literal code of every `_hit("CODE", ...)` call under `node`."""
    return {
        call.args[0].value
        for call in ast.walk(node)
        if isinstance(call, ast.Call) and isinstance(call.func, ast.Name) and call.func.id == "_hit"
        and call.args and isinstance(call.args[0], ast.Constant) and isinstance(call.args[0].value, str)
    }


def _behaviour_codes() -> set[str]:
    """Every `BehaviourHit(code="...")` the explainer builds, plus the cold-start label app.ato adds."""
    tree = ast.parse(EXPLAIN.read_text())
    codes = {
        kw.value.value
        for call in ast.walk(tree)
        if isinstance(call, ast.Call) and isinstance(call.func, ast.Name) and call.func.id == "BehaviourHit"
        for kw in call.keywords
        if kw.arg == "code" and isinstance(kw.value, ast.Constant)
    }
    return codes | {f"{code}{ato.COLD_START_SUFFIX}" for code in ato.IDENTITY_CODES}


RULES_TREE = ast.parse(RULES.read_text())
RULE_CODES = _hit_codes(RULES_TREE)
EVALUATE = next(n for n in RULES_TREE.body if isinstance(n, ast.FunctionDef) and n.name == "evaluate")
EVALUATE_CODES = _hit_codes(EVALUATE)
BEHAVIOUR_CODES = _behaviour_codes()


def test_the_source_reading_finds_what_is_known_to_be_there() -> None:
    """A parser that found nothing would pass every test below, so it has to find these first."""
    assert {"APP_SAFETY_BLOCK", "MODEL_RISK", "MONEY_LOCK_ACTIVE"} <= RULE_CODES
    assert "MODEL_RISK" not in EVALUATE_CODES and "APP_SAFETY_BLOCK" in EVALUATE_CODES
    assert {"ATO_BEHAVIOUR_MISMATCH", "COACHING_SUSPECTED", "ATO_BEHAVIOUR_MISMATCH_COLD_START"} <= BEHAVIOUR_CODES


def test_every_code_risk_mw_can_emit_is_in_all_codes() -> None:
    missing = (RULE_CODES | BEHAVIOUR_CODES) - set(aggregate.ALL_CODES)
    assert not missing, f"risk-mw emits {sorted(missing)}, which ALL_CODES does not list"


@pytest.mark.parametrize("code", sorted(EVALUATE_CODES))
def test_every_rule_code_is_claimed_and_explained_by_one_check(code: str) -> None:
    """The system picture names, for each check, the codes it can fire and why one did."""
    owners = [c for c in scenarios.CHECKS if code in c["codes"]]
    assert len(owners) == 1, f"{code} is claimed by {[c['id'] for c in owners]}"
    txn = {"type": "send_money", "amount_bdt": 24000.0, "is_new_payee": True}
    flags = {"inbound_mule_score": 0.9, "scam_score": 0.8, "app_safety_verdict": code.removeprefix("APP_SAFETY_")}
    verdict = scenarios._verdict(owners[0], txn, flags, {code: 0.5}, get_settings())
    assert verdict["verdict"] == "raised" and verdict["code"] == code
    assert verdict["test"] != code, f"{code} has no explanation in scenarios._test_for"


def test_app_safety_caution_says_it_is_capped_below_a_hold() -> None:
    check = next(c for c in scenarios.CHECKS if c["id"] == "app-safety")
    settings = get_settings()
    verdict = scenarios._verdict(check, {"type": "send_money", "amount_bdt": 1.0, "is_new_payee": False},
                                 {"app_safety_verdict": "CAUTION"}, {"APP_SAFETY_CAUTION": 0.45}, settings)
    assert '"CAUTION"' in verdict["test"]
    assert str(settings.app_safety_caution_weight_cap) in verdict["test"]
