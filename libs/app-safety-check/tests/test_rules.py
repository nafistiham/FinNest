"""Rules on the five scenario families, plus the install-origin table.

Real brand names are kept only so the detector can recognise them."""

from __future__ import annotations

import pytest

from bhorosha_app_safety_check import rules, schema as s, scoring
from helpers import CHROME, PLAY, app, bundle


def _signals(hits):
    return {h.signal for h in hits}


def test_takanow_is_a_critical_sideloaded_accessibility_hit(takanow):
    hits = rules.app_hits(takanow)
    sig = {h.signal: h for h in hits}
    assert sig["SIDELOADED_ACCESSIBILITY"].severity == "critical"
    assert "TakaNow Loan" in sig["SIDELOADED_ACCESSIBILITY"].text_bn and "আনইনস্টল" in sig["SIDELOADED_ACCESSIBILITY"].text_bn
    assert sig["LOAN_APP_DATA_HARVEST"].severity == "high"
    assert scoring.combine(hits).verdict == "BLOCK"


def test_declared_but_disabled_accessibility_is_only_medium():
    a = app("com.x.helper", "Helper", CHROME, service=True, enabled=False)
    (hit,) = rules.app_hits(a)
    assert (hit.signal, hit.severity) == ("SIDELOADED_ACCESSIBILITY", "medium")
    assert scoring.combine((hit,)).verdict == "CAUTION"


def test_clean_play_device_has_no_hits(clean_apps):
    assert rules.evaluate(bundle(clean_apps)) == ()
    assert scoring.combine(()).verdict == "SAFE"


def test_unattested_clean_device_is_safe_in_demo_but_caution_in_production(clean_apps):
    demo = rules.evaluate(s.Bundle(apps=clean_apps))  # attestation "none", not required
    assert [(h.signal, h.severity, h.soft) for h in demo] == [("UNATTESTED_CLIENT", "low", True)]
    assert scoring.combine(demo).verdict == "SAFE"
    prod = rules.evaluate(s.Bundle(apps=clean_apps, require_attestation=True))
    assert [(h.signal, h.severity, h.soft) for h in prod] == [("UNATTESTED_CLIENT", "medium", False)]
    assert scoring.combine(prod).verdict == "CAUTION"  # production: no SAFE without a bound, recognised token


def test_modded_client_and_mismatched_bundle_are_critical(clean_apps):
    for level, signal in (("tampered", "CLIENT_TAMPERED"), ("mismatch", "BUNDLE_MISMATCH")):
        hits = rules.evaluate(bundle(clean_apps, attestation=level))
        assert [(h.signal, h.severity) for h in hits] == [(signal, "critical")]
        assert scoring.combine(hits).verdict == "BLOCK"
    failed = rules.evaluate(bundle(clean_apps, attestation="failed"))
    assert [(h.signal, h.severity, h.soft) for h in failed] == [("UNATTESTED_CLIENT", "medium", False)]


def test_emulator_or_rooted_attestation_is_a_device_integrity_hit(clean_apps):
    virtual = rules.evaluate(bundle(clean_apps, attestation="virtual"))
    assert [(h.signal, h.severity) for h in virtual] == [("DEVICE_INTEGRITY_FAILED", "high")]
    basic = rules.evaluate(bundle(clean_apps, attestation="basic"))
    assert [(h.signal, h.severity) for h in basic] == [("DEVICE_INTEGRITY_FAILED", "medium")]


def test_empty_or_shrunken_app_list_is_not_evidence():
    assert [(h.signal, h.severity) for h in rules.plausibility_hits(bundle(()))] == [("IMPLAUSIBLE_BUNDLE", "medium")]
    few = (app("com.whatsapp", "WhatsApp"),)
    assert [h.signal for h in rules.plausibility_hits(bundle(few, previous_app_count=40))] == ["BUNDLE_SHRUNK"]
    assert rules.plausibility_hits(bundle(few, previous_app_count=3)) == ()


def test_sideloaded_known_publisher_is_soft_not_a_hard_caution():
    bkash = app("com.bKash.customerapp", "bKash", "com.lenovo.anyshare.gps", ("READ_CONTACTS", "READ_SMS", "CAMERA", "READ_PHONE_STATE"))
    (hit,) = rules.app_hits(bkash)
    assert hit.signal == "SIDELOADED_DATA_REACH" and hit.soft
    imo = app("com.imo.android.imoim", "imo", None, ("READ_CONTACTS", "READ_EXTERNAL_STORAGE", "RECORD_AUDIO"))
    (hit,) = rules.app_hits(imo)
    assert hit.signal == "SIDELOADED_DATA_REACH" and hit.soft
    unknown_loan = app("com.x.loan", "Sahaj Loan", None, ("READ_CONTACTS", "READ_MEDIA_IMAGES"))
    (loan_hit,) = rules.app_hits(unknown_loan)  # loan-named, reaching, no provenance: hard medium
    assert loan_hit.signal == "LOAN_APP_DATA_HARVEST" and not loan_hit.soft and loan_hit.severity == "medium"


def test_play_installed_backup_app_is_a_soft_low_flag():
    backup = app("com.backup.pro", "Backup Pro", PLAY, ("READ_CONTACTS", "READ_EXTERNAL_STORAGE", "WRITE_EXTERNAL_STORAGE", "READ_CALL_LOG"))
    (hit,) = rules.app_hits(backup)
    assert hit.signal == "LOAN_APP_DATA_HARVEST" and hit.severity == "low" and hit.soft
    assert scoring.combine((hit,)).verdict == "SAFE"


def test_bfiu_listed_label_from_play_with_harvest_permissions_is_medium_not_soft():
    loan = app("com.quick.taka", "Quick Taka", PLAY, ("READ_CONTACTS", "READ_MEDIA_IMAGES", "ACCESS_FINE_LOCATION"))
    (hit,) = rules.app_hits(loan)
    assert hit.severity == "medium" and not hit.soft


def test_generic_cash_label_from_play_is_only_soft():
    wallet = app("com.nagad.android", "Nagad Cash Wallet", PLAY, ("READ_CONTACTS", "ACCESS_FINE_LOCATION"))
    (hit,) = rules.app_hits(wallet)
    assert hit.severity == "low" and hit.soft


@pytest.mark.parametrize("installer,enabled,severity", [(PLAY, False, "high"), (CHROME, False, "critical"), (PLAY, True, "critical")])
def test_remote_access_tools(installer, enabled, severity):
    anydesk = app("com.anydesk.anydeskandroid", "AnyDesk", installer, service=True, enabled=enabled)
    hits = {h.signal: h for h in rules.app_hits(anydesk)}
    assert hits["KNOWN_RAT"].severity == severity


def test_viewer_only_remote_desktop_client_is_low():
    (hit,) = rules.app_hits(app("com.google.chromeremotedesktop", "Chrome Remote Desktop", PLAY))
    assert (hit.signal, hit.severity, hit.soft) == ("KNOWN_RAT", "low", True)
    (hit,) = rules.app_hits(app("com.google.chromeremotedesktop", "Chrome Remote Desktop", CHROME))
    assert (hit.severity, hit.soft) == ("medium", False)


def test_sideloaded_file_manager_with_storage_only_is_not_a_harvest():
    assert rules.app_hits(app("com.x.files", "Files", CHROME, ("READ_EXTERNAL_STORAGE", "WRITE_EXTERNAL_STORAGE"))) == ()


def test_sideloaded_unknown_app_reaching_two_categories_without_sms_is_only_soft():
    (hit,) = rules.app_hits(app("com.x.helper", "Helper", CHROME, ("READ_CONTACTS", "ACCESS_FINE_LOCATION")))
    assert hit.signal == "SIDELOADED_DATA_REACH" and hit.soft
    (hit,) = rules.app_hits(app("com.x.helper", "Helper", CHROME, ("READ_CONTACTS", "RECEIVE_SMS")))
    assert hit.signal == "LOAN_APP_DATA_HARVEST" and hit.severity == "high"


def test_device_rules():
    apps = (app("com.x.overlay", "Overlay", CHROME), app("com.x.admin", "Admin", CHROME), app("com.play.overlay", "PlayOverlay", PLAY))
    device = s.DeviceRow(overlay_holders=("com.x.overlay", "com.play.overlay"), device_admins=("com.x.admin",), dev_options=True, adb=True, rooted=True, play_protect=False)
    hits = rules.device_hits(device, apps)
    by = {(h.signal, h.package): h.severity for h in hits}
    assert by[("OVERLAY_CAPABLE", "com.x.overlay")] == "medium"
    assert ("OVERLAY_CAPABLE", "com.play.overlay") not in by
    assert by[("DEVICE_ADMIN", "com.x.admin")] == "high"
    assert by[("DEVICE_ROOTED", s.DEVICE)] == "high"
    assert by[("DEV_OPTIONS_ON", s.DEVICE)] == "low"
    assert by[("PLAY_PROTECT_OFF", s.DEVICE)] == "medium"


def test_integrity_unknown_controlling_is_a_critical_floor():
    verdict = s.IntegrityVerdict(source="demo", apps_detected=("KNOWN_INSTALLED", "UNKNOWN_CONTROLLING"), play_protect_verdict="POSSIBLE_RISK")
    hits = {h.signal: h.severity for h in rules.integrity_hits(verdict)}
    assert hits == {"INTEGRITY_CONTROLLING": "critical", "INTEGRITY_PLAY_PROTECT": "medium"}  # POSSIBLE_RISK = Play Protect switched off, a step-up
    assert rules.integrity_hits(s.IntegrityVerdict(source="none")) == ()


@pytest.mark.parametrize("installer,origin,sideloaded", [
    (PLAY, "play", False), ("com.sec.android.app.samsungapps", "store", False), ("system", "system", False),
    (CHROME, "browser", True), ("com.google.android.packageinstaller", "sideload", True), ("com.whatsapp", "sideload", True), (None, "unknown", False), ("", "unknown", False), ("com.android.shell", "sideload", True),  # policy 2026-10-17: null provenance is not a sideload
])
def test_install_origin(installer, origin, sideloaded):
    assert s.install_origin(installer) == origin
    assert s.is_sideloaded(installer) is sideloaded


def test_copy_never_says_malware_or_jargon():
    for bn, en in list(s.SIGNAL_TEXT.values()) + list(s.VERDICT_TEXT.values()) + [s.GENERIC_CAUTION_TEXT]:
        assert "malware" not in en.lower() and "ম্যালওয়্যার" not in bn
        assert "লেনদেন" not in bn and "ডিভাইস" not in bn  # plain words: Rina says টাকা পাঠানো and ফোন
        assert bn.count("।") <= 2 and " বা " not in bn.rsplit("।", 2)[-2] if bn.count("।") >= 2 else True  # at most two sentences, one action



def test_2026_rules_dropper_sms_role_listener_nfc_impersonation_icon():
    payload = s.AppRow("com.x.payload", "Secure Update", "com.x.dropper", permissions=("android.permission.READ_SMS",), installer_declares_install_packages=True)
    by = {h.signal: h for h in rules.app_hits(payload)}
    assert by["DROPPER_INSTALLED"].severity == "critical"  # payload reaches SMS
    assert by["LOAN_APP_DATA_HARVEST"].severity == "high"
    quiet_payload = s.AppRow("com.x.p2", "Tools", "com.x.dropper", installer_declares_install_packages=True)
    assert {h.signal: h.severity for h in rules.app_hits(quiet_payload)} == {"DROPPER_INSTALLED": "high"}
    sms = s.AppRow("com.x.sms", "Messages Pro", CHROME, is_default_sms_app=True)
    assert {h.signal: h.severity for h in rules.app_hits(sms)} == {"SMS_ROLE_TAKEOVER": "critical"}
    listener = s.AppRow("com.x.notif", "Notif Saver", CHROME, has_notification_listener=True)
    assert {h.signal: h.severity for h in rules.app_hits(listener)} == {"NOTIFICATION_LISTENER": "high"}
    nfc = s.AppRow("com.x.tap", "Tap Pay", CHROME, has_hce_service=True)
    assert {h.signal: h.severity for h in rules.app_hits(nfc)} == {"NFC_RELAY_CAPABLE": "high"}
    wallet = s.AppRow("com.google.android.apps.walletnfcrel", "Google Wallet", PLAY, has_hce_service=True)
    (hit,) = rules.app_hits(wallet)
    assert hit.signal == "NFC_RELAY_CAPABLE" and hit.soft
    fake_bkash = s.AppRow("com.bkash.mod.free", "bKash Mod", "org.telegram.messenger")
    assert {h.signal: h.severity for h in rules.app_hits(fake_bkash)} == {"BRAND_IMPERSONATION": "high"}
    real_bkash = s.AppRow("com.bKash.customerapp", "bKash", "org.telegram.messenger")
    assert "BRAND_IMPERSONATION" not in {h.signal for h in rules.app_hits(real_bkash)}
    hidden = s.AppRow("com.x.hidden", "Service", CHROME, launcher_icon_hidden=True)
    assert {h.signal: h.severity for h in rules.app_hits(hidden)} == {"ICON_HIDDEN": "medium"}
    assert rules.app_hits(s.AppRow("com.x.plain", "Plain", PLAY, launcher_icon_hidden=True, has_notification_listener=True)) == ()  # Play-installed: no sideload rules


def test_accessibility_plus_overlay_on_a_sideloaded_app_is_high_even_when_not_enabled():
    a = s.AppRow("com.x.overlay", "Helper", CHROME, has_accessibility_service=True)
    assert rules.app_hits(a, overlay_holder=True)[0].severity == "high"
    assert rules.app_hits(a, overlay_holder=False)[0].severity == "medium"
    hits = rules.evaluate(bundle((a,), device=s.DeviceRow(overlay_holders=("com.x.overlay",))))
    assert {h.signal: h.severity for h in hits} == {"SIDELOADED_ACCESSIBILITY": "high", "OVERLAY_CAPABLE": "medium"}


def test_device_default_sms_package_that_is_a_sideloaded_app_is_a_takeover():
    sms = s.AppRow("com.x.sms", "SMS Lite", CHROME)
    hits = rules.device_hits(s.DeviceRow(default_sms_package="com.x.sms"), (sms,))
    assert {h.signal: h.severity for h in hits} == {"SMS_ROLE_TAKEOVER": "critical"}
    assert rules.device_hits(s.DeviceRow(default_sms_package="com.google.android.apps.messaging"), (sms,)) == ()


def test_null_provenance_is_unknown_origin_not_sideloaded():
    """OEM preloads and Phone Clone restores arrive with no installer at all; adb arrives as the shell."""
    callapp = s.AppRow("com.callapp.contacts", "CallApp", None, permissions=("android.permission.READ_SMS", "android.permission.READ_CONTACTS", "android.permission.READ_CALL_LOG"), has_accessibility_service=True, has_notification_listener=True)
    hits = rules.evaluate(bundle((callapp,)))
    assert hits and all(h.soft for h in hits), [(h.signal, h.severity, h.soft) for h in hits]
    assert {h.signal for h in hits} >= {"SIDELOADED_ACCESSIBILITY", "NOTIFICATION_LISTENER", "SIDELOADED_DATA_REACH"}
    # the same app with its accessibility service switched on can act on the screen now: hard, critical
    live = s.AppRow("com.callapp.contacts", "CallApp", None, permissions=callapp.permissions, has_accessibility_service=True, accessibility_enabled=True, has_notification_listener=True)
    live_hits = rules.evaluate(bundle((live,)))
    assert any(h.signal == "SIDELOADED_ACCESSIBILITY" and h.severity == "critical" for h in live_hits) and any(h.signal == "NOTIFICATION_LISTENER" and not h.soft for h in live_hits)
    # an overlay held by an unknown-origin app counts the same way
    overlay = rules.evaluate(bundle((callapp,), device=s.DeviceRow(overlay_holders=("com.callapp.contacts",))))
    assert any(h.signal == "SIDELOADED_ACCESSIBILITY" and h.severity == "high" for h in overlay)
    # adb installs are reported as the shell by the collector and stay sideloaded
    shell = s.AppRow("com.x.loan", "Taka Cash", "com.android.shell", permissions=("android.permission.READ_SMS", "android.permission.READ_CONTACTS"), has_accessibility_service=True)
    assert any(h.signal == "SIDELOADED_ACCESSIBILITY" and h.severity == "medium" for h in rules.evaluate(bundle((shell,))))
    # a loan-named app with SMS reach and no provenance is still a hard medium; impersonation needs no provenance either
    loan = s.AppRow("com.x.takacash", "Taka Cash", None, permissions=("android.permission.READ_SMS", "android.permission.READ_CONTACTS"))
    assert any(h.signal == "LOAN_APP_DATA_HARVEST" and h.severity == "medium" and not h.soft for h in rules.evaluate(bundle((loan,))))
    fake = s.AppRow("com.x.bkash", "bKash", None)
    assert any(h.signal == "BRAND_IMPERSONATION" and not h.soft for h in rules.evaluate(bundle((fake,))))
    assert s.is_sideloaded(None) is False and s.is_unknown_origin(None) and s.is_sideloaded("com.android.shell")
