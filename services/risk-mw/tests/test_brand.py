"""The brand Apa names and the button she points to are settings (renamed the app FinNest on 2026-10-17).

Apa's own name is never spoken, so the brand is the only name a listener hears: the composer's prompt, the planner's safe
path, the validator's allowed action and the trusted contact's push all read it from settings, and the action names the
app's real button (app_bn.arb `safetyCallBank`: ফিননেস্টে কল করুন, app_en.arb: Call FinNest).
"""

import pytest

from app import scam_rules
from app.ledger import Evidence, Ledger
from app.routers import actions
from app.settings import Settings, get_settings
from app.warnings import composer, planner, validator

CODE_ASK = Ledger(tactics={"CREDENTIAL_REQUEST": Evidence("CREDENTIAL_REQUEST", "কোডটা বলুন", 0)},
                  claimed_identity="bank_mfs_staff", asks=("otp",))
FINNEST_X = "কলটা কেটে দিন, তারপর অ্যাপের ‘ফিননেস্টে কল করুন’ বোতাম চাপুন।"
BHOROSHA_X = "কলটা কেটে দিন, তারপর অ্যাপের ‘ভরসায় কল করুন’ বোতাম চাপুন।"


@pytest.fixture
def bhorosha(monkeypatch):
    """The old brand, set the way a deploy would set it."""
    for key, value in (("BRAND_BN", "ভরসা"), ("BRAND_EN", "Bhorosha"), ("CALL_BUTTON_BN", "ভরসায় কল করুন"),
                       ("CALL_BUTTON_EN", "Call Bhorosha")):
        monkeypatch.setenv(f"RISK_MW_{key}", value)
    get_settings.cache_clear()
    yield get_settings()
    get_settings.cache_clear()


def _plan() -> planner.Plan:
    return planner.plan(CODE_ASK, None, "likely")


def test_the_default_brand_is_finnest_and_the_button_is_the_apps_own():
    s = Settings()
    assert (s.brand_bn, s.brand_en, s.call_button_bn, s.call_button_en) == ("ফিননেস্ট", "FinNest", "ফিননেস্টে কল করুন", "Call FinNest")


def test_the_plan_hands_the_composer_the_apps_real_button():
    p = _plan()
    assert p.safe_path == "call_bank"
    assert p.facts()["safe_path"] == {"action": "call_bank", "bn": "অ্যাপের ‘ফিননেস্টে কল করুন’ বোতাম চাপুন",
                                      "en": "press the app's 'Call FinNest' button"}


def test_the_composer_prompt_names_the_brand_and_never_the_old_one():
    system = composer.system_prompt(Settings())
    assert "ফিননেস্ট" in system and "FinNest" in system and "‘ফিননেস্টে কল করুন’" in system and "'Call FinNest'" in system
    assert "ভরসা" not in system and "Bhorosha" not in system


def test_the_validator_accepts_the_apps_button_and_refuses_one_the_app_does_not_have():
    assert validator.validate("X", FINNEST_X, _plan(), ()).ok
    assert validator.validate("X", BHOROSHA_X, _plan(), ()) == validator.Check(False, "action")


def test_dont_tell_the_bank_is_the_scammers_line_and_is_refused():
    assert validator.validate("X", "ফিননেস্টকে কিছু বলবেন না।", _plan(), ()) == validator.Check(False, "action")


def test_the_trusted_contacts_push_names_the_brand():
    assert actions.push_title(Settings()) == "ফিননেস্ট: অনুমোদন দরকার"


def test_another_brand_set_in_settings_flows_through_every_part(bhorosha):
    p = _plan()
    assert p.facts()["safe_path"]["bn"] == "অ্যাপের ‘ভরসায় কল করুন’ বোতাম চাপুন"
    assert validator.validate("X", BHOROSHA_X, p, ()).ok and not validator.validate("X", FINNEST_X, p, ()).ok
    assert "‘ভরসায় কল করুন’" in composer.system_prompt(bhorosha) and "ফিননেস্ট" not in composer.system_prompt(bhorosha)
    assert actions.push_title(bhorosha) == "ভরসা: অনুমোদন দরকার"


@pytest.mark.parametrize("said", ["this transfer is approved by FinNest", "ফিননেস্ট থেকে অনুমোদন দেওয়া আছে",
                                  "approved by Bhorosha"])
def test_a_caller_invoking_either_name_of_the_bank_s_approval_is_meta_talk(said):
    assert scam_rules.meta_talk(said)
