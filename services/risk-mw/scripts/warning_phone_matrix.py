"""FNA's warning for every App Safety phone fact and every hold fact, written by real Gemini and checked by the validator (2026-10-18).

Run it after any change to the composer's instruction, the planner's glosses or rules, or the validator:

    cd services/risk-mw
    RISK_MW_GENAI_ENABLED=true RISK_MW_GENAI_BACKEND=vertex RISK_MW_PROJECT_ID=<project> \\
        PYTHONPATH=. python scripts/warning_phone_matrix.py [--rounds 2] [--only FAKE_APP] [--out results.jsonl]

One JSON line per warning (its lines and every rejected line with the rule it broke), then a summary: warnings with a
dropped line, warnings with no lines at all (the floor) and the cost. On 2026-10-18 the prompt before this change dropped
lines in 7 of 19 warnings; after it, 0 of 9 for the last fixed fact and 6 of 44 (all one fact, since fixed) for the rest.
The only floors seen were network timeouts at the composer's deadline.

The HOLD_ cases are holds with no call, phone or behaviour facts, the common case with speech to text off: before the
hold facts (2026-10-18) such a plan read like "NOTHING/send" and got lines about nothing. With them, two rounds
on the final instruction rejected no line in 22 hold and no-facts warnings; two were floors from network timeouts
(eval/results/warning_matrix_hold_facts.jsonl).

Second person (2026-10-18): with the glosses in the third person, three rounds on main kept five English lines
saying "her screen" in 3 of 99 warnings (eval/results/warning_matrix_second_person_main.jsonl). With every gloss saying
"you" and the validator's person rule, three rounds kept none and the rule rejected no line; the five lines dropped were
all too long, four of them SCREEN_CAPTURE and FAKE_LOAN_APP T lines, as before (warning_matrix_second_person.jsonl).

SCREEN_CAPTURE's gloss (2026-10-18): the model rendered both of its clauses ("... sharing your screen, so someone
else may see it"). Eight rounds of --only SCREEN_CAPTURE dropped the T line as too long in 5 of 16 warnings, at 13 to 16
words (warning_matrix_screen_capture_before.jsonl). With the gloss cut to its first clause, eight rounds dropped no line,
and every T line was 8 to 10 words (warning_matrix_screen_capture.jsonl). FAKE_LOAN_APP is unchanged: five rounds of
--only FAKE_LOAN dropped one T and one R line at 13 words in 17 warnings, but its T lines sit at 11 or 12 words, with
no room to spare (warning_matrix_fake_loan.jsonl). The floors in these runs were network timeouts.
"""

from __future__ import annotations

import argparse
import json
import sys
import time

from app.ledger import Ledger
from app.settings import get_settings
from app.warnings import composer, planner

CASES = [{"name": f"{f}/{a}", "phone": (f,), "pending": a} for f in planner.PHONE_FACTS for a in ("send_money", "pin_reset")]
CASES += [
    {"name": "RAT+SMS/send", "phone": ("REMOTE_CONTROL", "READS_MESSAGES"), "pending": "send_money"},
    {"name": "RAT+NOT_HER/send", "phone": ("REMOTE_CONTROL",), "behaviour": ("NOT_HER_PATTERN", "TOUCH"), "pending": "send_money"},
    {"name": "FAKE_LOAN/address", "phone": ("FAKE_LOAN_APP",), "pending": "send_money", "address": "রহিমা"},
    {"name": "UNSAFE/simple", "phone": ("UNSAFE_PHONE",), "pending": "send_money", "simple": True},
    {"name": "MODIFIED/new_payee", "phone": ("MODIFIED_APP",), "pending": "new_payee"},
    {"name": "BEHAVIOUR_ONLY/send", "phone": (), "behaviour": ("NOT_HER_PATTERN", "TYPING"), "pending": "send_money"},
    {"name": "NOTHING/send", "phone": (), "pending": "send_money"},
    # A caller's code request pasted into the assistant, with a phone fact riding along: the request keeps line R and
    # the call button (final review, 2026-10-18).
    {"name": "OTP+FAKE_LOAN/send", "phone": ("FAKE_LOAN_APP",), "pending": "send_money", "asks": ("otp",)},
    {"name": "OTP+RAT/pin", "phone": ("REMOTE_CONTROL",), "pending": "pin_reset", "asks": ("otp",)},
]
# Why the app held it, when nothing else is known (planner.HOLD_FACTS, read from the hold's reasons at /v1/intervene).
CASES += [
    {"name": "HOLD_PAYEE_MULE/send", "phone": (), "hold": ("PAYEE_MULE",), "pending": "send_money"},   # the demo: Rina pays acct_01070
    {"name": "HOLD_PAYEE_MULE+NEW_PAYEE/send", "phone": (), "hold": ("PAYEE_MULE", "NEW_PAYEE_LARGE"), "pending": "send_money"},
    {"name": "HOLD_PAYEE_MULE/address", "phone": (), "hold": ("PAYEE_MULE",), "pending": "send_money", "address": "রিনা"},
    {"name": "HOLD_SIM_CHANGED/send", "phone": (), "hold": ("SIM_CHANGED",), "pending": "send_money"},
    {"name": "HOLD_SIM_CHANGED/pin", "phone": (), "hold": ("SIM_CHANGED",), "pending": "pin_reset"},
    {"name": "HOLD_SIM_CHANGED/simple", "phone": (), "hold": ("SIM_CHANGED",), "pending": "send_money", "simple": True},
    {"name": "HOLD_NEW_PAYEE_LARGE/send", "phone": (), "hold": ("NEW_PAYEE_LARGE",), "pending": "send_money"},
    {"name": "HOLD_CALL_ON/pin", "phone": (), "hold": ("CALL_ON",), "pending": "pin_reset"},
    {"name": "HOLD_CALL_ON/send", "phone": (), "hold": ("CALL_ON",), "pending": "send_money"},
    {"name": "HOLD_SIM+CALL/pin", "phone": (), "hold": ("SIM_CHANGED", "CALL_ON"), "pending": "pin_reset"},
]


def main() -> int:
    args = argparse.ArgumentParser()
    args.add_argument("--rounds", type=int, default=1)
    args.add_argument("--only", default="", help="run only cases whose name contains this")
    args.add_argument("--out", default="", help="also write the JSON lines to this file")
    opts = args.parse_args()

    rejected: list[tuple[str, str, str, str]] = []
    validate, validate_en = composer.validate, composer.validate_en

    def watch_bn(role, text, plan, turns, address=None):
        result = validate(role, text, plan, turns, address)
        if not result.ok:
            rejected.append(("bn", role, result.rule, text))
        return result

    def watch_en(role, text):
        result = validate_en(role, text)
        if not result.ok:
            rejected.append(("en", role, result.rule, text))
        return result

    composer.validate, composer.validate_en = watch_bn, watch_en
    settings, rows, cost = get_settings(), [], 0.0
    for index, case in enumerate([c for c in CASES * opts.rounds if opts.only in c["name"]]):
        plan = planner.plan(Ledger(asks=case.get("asks", ())), case["pending"], "likely", address=case.get("address"), simple=case.get("simple", False),
                            index=index, phone=case["phone"], behaviour=case.get("behaviour", ()), hold=case.get("hold", ()))
        rejected.clear()
        started = time.perf_counter()
        warning = composer.generate(plan, (), settings)
        cost += warning.cost_usd
        row = {"case": case["name"], "ms": round((time.perf_counter() - started) * 1000), "rejected": list(rejected),
               "lines": [(line.role, line.text_bn, line.text_en) for line in warning.lines]}
        rows.append(row)
        print(json.dumps(row, ensure_ascii=False), flush=True)
    summary = {"warnings": len(rows), "with_a_dropped_line": sum(1 for r in rows if r["rejected"]),
               "floors": sum(1 for r in rows if not r["lines"]), "cost_usd": round(cost, 4)}
    print(json.dumps(summary))
    if opts.out:
        with open(opts.out, "w", encoding="utf-8") as out:
            out.writelines(json.dumps(r, ensure_ascii=False) + "\n" for r in [*rows, summary])
    return 0


if __name__ == "__main__":
    sys.exit(main())
