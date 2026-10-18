"""Transcript-first demo path: scripted dialogues through /v1/scam/turn, /v1/risk/score and /v1/intervene."""

from app import demo_replay, state
from app.ledger import Evidence, Ledger

HERO_FLAGS = {"call_active": True, "caller_in_contacts": False, "sim_swap": True}
GOOD = (("A", "রহিমা, একটু থামুন — কোডটা কাউকে বলবেন না।", "Rahima, stop for a moment: don't tell anyone the code."),
        ("T", "ফোনে আপনার মেসেজে আসা কোডটা চাওয়া হচ্ছে।", "The code that came in your message is being asked for on the phone."),
        ("R", "আসল ব্যাংক বা ফিননেস্ট কখনো ফোনে এই কোড চায় না।", "A real bank, or FinNest, never asks for this code on the phone."),
        ("X", "কলটা কেটে দিন, তারপর অ্যাপের ‘ফিননেস্টে কল করুন’ বোতাম চাপুন।", "Hang up, then press the app's 'Call FinNest' button."))


def _post(client):
    def post(path, body):
        resp = client.post(path, json=body)
        assert resp.status_code == 200, resp.text
        return resp.json()
    return post


def _hero():
    return next(s for s in demo_replay.load_scripts() if s["id"] == "hero_rina_fake_care")


def test_the_demo_scripts_are_complete():
    scripts = demo_replay.load_scripts()
    assert len(scripts) == 9 and len({s["id"] for s in scripts}) == 9
    assert {s["archetype"] for s in scripts if s["label"] == "scam"} == {
        "fake_customer_care", "otp_pin_harvest", "lottery_prize", "wrong_send_refund", "job_loan_fee", "relative_impersonation"}
    for s in scripts:
        assert all(t["speaker"] in ("caller", "user") and t["text"] for t in s["turns"])
        if s["label"] == "scam":
            assert s["pending_action"] in ("pin_reset", "send_money") and s["secret_turn"] < len(s["turns"])


def test_the_hero_call_is_held_with_both_reasons_and_apa_has_no_fixed_line(client):
    hero = _hero()
    out = demo_replay.replay(_post(client), hero, HERO_FLAGS)
    assert out["decision"] == "hold" and {"CALL_ACTIVE_NON_CONTACT", "SIM_CHANGED_24H"} <= set(out["reasons"])
    assert out["detected_turn"] is not None and out["detected_turn"] <= hero["secret_turn"]
    assert len(out["timeline"]) == len(hero["turns"])
    apa = out["apa"]  # Gemini is off, so no line validates: the floor
    assert (apa["script_bn"], apa["lines"], apa["audio_asset_id"], apa["warning_id"]) == ("", [], None, None)
    assert apa["earcon"] is True and apa["vibrate"] is True and apa["ui"] == "fullscreen"


def test_apas_warning_is_generated_from_the_calls_ledger_and_never_its_words(client, monkeypatch):
    from app.warnings import composer

    contents, paths = [], []
    text = "".join(f"{role}| {bn} || {en}\n" for role, bn, en in GOOD)
    monkeypatch.setattr(composer, "_model_text", lambda c, *args, **kwargs: contents.append(c) or iter([text]))
    state.store().set("users", "rina", {"apa_address": "রহিমা"})
    ledger = Ledger(tactics={"CREDENTIAL_REQUEST": Evidence("CREDENTIAL_REQUEST", "কোডটা এখনই আমাকে বলুন", 6)},
                    claimed_identity="bank_mfs_staff", asks=("otp",))
    post = _post(client)

    def detector_and_app(path, body):
        paths.append(path)
        if path == "/v1/intervene":  # the detector has kept the call's ledger by now (builder D writes it on every turn)
            state.store().merge("scam_sessions", body["session_id"], {"ledger": ledger.to_doc(), "band": "likely"})
        return post(path, body)

    hero = _hero()
    out = demo_replay.replay(detector_and_app, hero, HERO_FLAGS)
    assert paths[-1] == "/v1/intervene" and "/v1/apa/why" not in paths
    assert [line["role"] for line in out["apa"]["lines"]] == ["A", "T", "R", "X"] and out["apa"]["warning_id"]
    assert out["apa"]["script_bn"] == " ".join(bn for _, bn, _ in GOOD) and out["apa"]["speak_on_device"] is True
    # Every composer call (the pre-arms after scored turns, then the hold's) reads the plan, never the caller's words.
    assert contents and not any(t["text"] in c for c in contents for t in hero["turns"])


def test_the_real_help_line_never_alerts(client):
    call = next(s for s in demo_replay.load_scripts() if s["id"] == "benign_help_line")
    out = demo_replay.replay(_post(client), call, {})
    assert out["detected_turn"] is None and out["decision"] is None and max(t["rolling_score"] for t in out["timeline"]) < 0.7
