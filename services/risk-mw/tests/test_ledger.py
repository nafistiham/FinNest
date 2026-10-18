"""The evidence ledger (P0 item 1): the shared spine of the detector and Apa's generated warnings."""

import pytest

from app import ledger as L

TRANSCRIPT = [
    {"speaker": "caller", "text": "আমি বিকাশ হেড অফিস থেকে বলছি, আপনার একাউন্ট আজ বন্ধ হয়ে যাবে।", "ts": 1.0},
    {"speaker": "user", "text": "কেন ভাই?", "ts": 4.0},
    {"speaker": "caller", "text": "এখনই আপনার ফোনে আসা ওটিপি কোডটা বলুন।", "ts": 7.0},
]


def _extraction(**over):
    base = {"tactics": [{"tactic": "AUTHORITY_IMPERSONATION", "quote": "বিকাশ হেড অফিস থেকে বলছি", "turn": 0},
                        {"tactic": "CREDENTIAL_REQUEST", "quote": "ওটিপি কোডটা বলুন", "turn": 2}],
            "claimed_identity": "bank_mfs_staff", "ask": "otp"}
    return {**base, **over}


def test_only_quotes_found_in_the_transcript_enter_the_ledger():
    ext = _extraction(tactics=[*_extraction()["tactics"], {"tactic": "URGENCY_THREAT", "quote": "পুলিশ আসছে", "turn": 2}])
    led = L.Ledger().merge(ext, TRANSCRIPT)
    assert set(led.tactics) == {"AUTHORITY_IMPERSONATION", "CREDENTIAL_REQUEST"}  # the invented quote is dropped
    assert led.tactics["CREDENTIAL_REQUEST"] == L.Evidence("CREDENTIAL_REQUEST", "ওটিপি কোডটা বলুন", 2)


def test_quotes_are_matched_after_unicode_and_space_normalisation_and_only_against_caller_turns():
    messy = _extraction(tactics=[{"tactic": "CREDENTIAL_REQUEST", "quote": "ওটিপি   কোডটা‌ বলুন", "turn": 2},
                                 {"tactic": "SECRECY_ISOLATION", "quote": "কেন ভাই", "turn": 1}])  # the victim's words prove nothing
    led = L.Ledger().merge(messy, TRANSCRIPT)
    assert set(led.tactics) == {"CREDENTIAL_REQUEST"}


def test_evidence_latches_for_the_rest_of_the_call_and_keeps_its_first_turn():
    led = L.Ledger().merge(_extraction(), TRANSCRIPT)
    later = led.merge({"tactics": [], "claimed_identity": "unknown", "ask": "none"}, TRANSCRIPT)
    assert set(later.tactics) == set(led.tactics) and later.claimed_identity == "bank_mfs_staff" and later.asks == ("otp",)
    again = later.merge(_extraction(tactics=[{"tactic": "CREDENTIAL_REQUEST", "quote": "ওটিপি কোডটা বলুন", "turn": 5}]), TRANSCRIPT)
    assert again.tactics["CREDENTIAL_REQUEST"].turn == 2


def test_an_ask_counts_only_with_a_verified_credential_or_payment_quote():
    led = L.Ledger().merge(_extraction(tactics=[], ask="otp"), TRANSCRIPT)
    assert led.asks == ()  # the model said otp but showed no verified quote for it
    led = L.Ledger().merge(_extraction(), TRANSCRIPT)
    assert led.asks == ("otp",)


def test_unknown_enum_values_are_ignored_not_trusted():
    led = L.Ledger().merge(_extraction(claimed_identity="martian", ask="soul",
                                       tactics=[{"tactic": "TELEPATHY", "quote": "বলুন", "turn": 2}]), TRANSCRIPT)
    assert led.tactics == {} and led.claimed_identity == "none" and led.asks == ()


def test_the_ledger_round_trips_through_a_firestore_safe_document():
    led = L.Ledger().merge(_extraction(), TRANSCRIPT)
    doc = led.to_doc()
    assert not any(isinstance(v, list) and any(isinstance(x, list) for x in v) for v in doc.values())  # no array in an array
    assert L.Ledger.from_doc(doc) == led and L.Ledger.from_doc({}) == L.Ledger()


def test_the_hash_moves_with_material_evidence_only():
    led = L.Ledger().merge(_extraction(), TRANSCRIPT)
    same = L.Ledger.from_doc(led.to_doc())
    assert led.hash() == same.hash() and len(led.hash()) == 16
    fewer = L.Ledger().merge(_extraction(tactics=_extraction()["tactics"][:1], ask="none"), TRANSCRIPT)
    assert fewer.hash() != led.hash()
    assert led.hash(pending_action="pin_reset", band="likely") != led.hash(pending_action="send_money", band="likely")


@pytest.mark.parametrize("enum, values", [("TACTICS", 7), ("IDENTITIES", 6), ("ASKS", 8)])
def test_the_enums_match_the_report_schema(enum, values):
    assert len(getattr(L, enum)) == values
