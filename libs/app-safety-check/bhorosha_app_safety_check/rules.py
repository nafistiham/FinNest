"""Hand-crafted rules (spec FR-5): pure functions from wire rows to hits. No I/O, no model.

Each rule names the policy fact it rests on; the facts themselves and their sources are in `schema.py`.
"""

from __future__ import annotations

from bhorosha_app_safety_check import schema as s
from bhorosha_app_safety_check.schema import AppRow, Bundle, DeviceRow, Hit, IntegrityVerdict


def _hit(signal: str, severity: str, package: str, evidence: str, app_name: str = "", *, soft: bool = False, contributions=()) -> Hit:
    bn, en = s.SIGNAL_TEXT[signal]
    return Hit(signal, severity, package, evidence, bn.format(app=app_name), en.format(app=app_name), soft, tuple(contributions))


def _bfiu_listed(app: AppRow) -> bool:
    label = app.label.lower()
    return any(name.lower() in label for name in s.BFIU_FAKE_LOAN_APPS)


def _looks_like_loan_app(app: AppRow) -> bool:
    return _bfiu_listed(app) or any(hint in app.label.lower() or hint in app.package.lower() for hint in s.LOAN_LABEL_HINTS)


def _impersonated_brand(app: AppRow) -> str | None:
    label = app.label.lower().strip()
    for brand, genuine in s.BRAND_LABELS.items():
        if brand in label and app.package not in genuine:
            return brand
    return None


def app_hits(app: AppRow, overlay_holder: bool = False) -> tuple[Hit, ...]:
    hits: list[Hit] = []
    perms = {s.canonical_permission(p) for p in app.permissions}
    origin = s.install_origin(app.installer)
    unknown = s.is_unknown_origin(app.installer)
    # Policy: an app nobody can vouch for (null provenance: OEM preload, Phone Clone restore) counts as
    # sideloaded only when it can act on the screen now, an enabled accessibility service or a held overlay; otherwise
    # its reach is recorded soft. A browser, the shell or a file manager as installer is sideloaded as before.
    sideloaded = s.is_sideloaded(app.installer) or (unknown and (app.accessibility_enabled or overlay_holder))

    # Rule 1. A sideloaded app with an accessibility service is the banking-trojan shape (Vultur, BlackRock, and in
    # 2025–2026 Crocodilus, Herodotus, Sturnus, Octo2): enabled means it can read the screen now; declared means one tap
    # away. Accessibility plus an overlay on the same sideloaded package is the black-screen takeover combo (rule 2 of
    # the 2026 list), so a declared-but-not-enabled service is high rather than medium when the app also holds overlay.
    if sideloaded and app.has_accessibility_service:
        severity = "critical" if app.accessibility_enabled else ("high" if overlay_holder else "medium")
        hits.append(_hit("SIDELOADED_ACCESSIBILITY", severity, app.package, f"installer={app.installer or 'unknown'} accessibility_enabled={app.accessibility_enabled} overlay={overlay_holder}", app.name))
    elif unknown and app.has_accessibility_service:
        hits.append(_hit("SIDELOADED_ACCESSIBILITY", "low", app.package, f"installer=unknown (no provenance) accessibility_enabled=False overlay={overlay_holder}", app.name, soft=True))

    # Rule 2026-3. Session-installer laundering: the app was installed by another sideloaded app that can install packages
    # (SecuriDropper, Zombinder, the Crocodilus and Herodotus droppers). Critical when the payload also reaches for the
    # screen or SMS, high otherwise.
    if app.installer_declares_install_packages:
        escalated = app.has_accessibility_service or bool(perms & s.PLAY_PROTECT_FRAUD_PERMISSIONS)
        hits.append(_hit("DROPPER_INSTALLED", "critical" if escalated else "high", app.package, f"installer={app.installer} declares REQUEST_INSTALL_PACKAGES, payload_reaches_screen_or_sms={escalated}", app.name))

    # Rule 2026-4. A non-store app that made itself the default SMS app reads every OTP (Crocodilus SpinderSpike,
    # Herodotus); a non-store notification listener reads them from the shade.
    if app.is_default_sms_app and sideloaded:
        hits.append(_hit("SMS_ROLE_TAKEOVER", "critical", app.package, f"default SMS app, installer={app.installer or 'unknown'}", app.name))
    # A known publisher's own build (bKash, Truecaller) is that publisher wherever it was installed from (a
    # wallet's own UAT build with a null installer was once read as an NFC relay); the classifier applies the same exemption.
    known_publisher = app.package in s.KNOWN_PUBLISHER_PACKAGES
    if app.has_notification_listener and sideloaded and not known_publisher:
        hits.append(_hit("NOTIFICATION_LISTENER", "high", app.package, f"declares BIND_NOTIFICATION_LISTENER_SERVICE, installer={app.installer or 'unknown'}", app.name))
    elif app.has_notification_listener and unknown and not known_publisher:
        hits.append(_hit("NOTIFICATION_LISTENER", "low", app.package, "declares BIND_NOTIFICATION_LISTENER_SERVICE, installer=unknown (no provenance)", app.name, soft=True))

    # Rule 2026-5. A host-card-emulation service on a non-store app is the NFC relay wave of 2025 (NGate, PhantomCard,
    # SuperCard X, the 760-app Tap-and-Steal campaign); on a store app it is a wallet, soft.
    if app.has_hce_service:
        if sideloaded and not known_publisher:
            hits.append(_hit("NFC_RELAY_CAPABLE", "high", app.package, f"declares HOST_APDU_SERVICE, installer={app.installer or 'unknown'}", app.name))
        else:
            hits.append(_hit("NFC_RELAY_CAPABLE", "low", app.package, f"declares HOST_APDU_SERVICE, origin={origin} known_publisher={known_publisher}", app.name, soft=True))

    # Brand impersonation: a sideloaded app wearing Chrome's, Google Play's, bKash's or the bank's own name
    # under a package that is not the vendor's. Every 2025 dropper campaign and the Bangladesh fake-bank builds do this.
    brand = _impersonated_brand(app)
    if brand and (sideloaded or unknown):  # a preload does not wear bKash's name under another package
        hits.append(_hit("BRAND_IMPERSONATION", "high", app.package, f"label impersonates {brand!r}, package={app.package}, installer={app.installer or 'unknown'}", app.name))

    # Rule 2026-9. A recently sideloaded app that hid its launcher icon: what Play Protect live threat detection flags on
    # Pixels, which the bank must do itself on the Xiaomi/Vivo/Realme mix.
    if app.launcher_icon_hidden and sideloaded:
        hits.append(_hit("ICON_HIDDEN", "medium", app.package, f"no launcher activity, installer={app.installer or 'unknown'}", app.name))
    elif app.launcher_icon_hidden and unknown:
        hits.append(_hit("ICON_HIDDEN", "low", app.package, "no launcher activity, installer=unknown (no provenance)", app.name, soft=True))

    # Rule 2. Known remote-access tools: legitimate software, but on a banking phone during a scam call they are
    # the "helper app". Sideloaded or accessibility-enabled copies are worse than the Play build.
    if app.package in s.KNOWN_RAT_PACKAGES:
        tool, tier = s.KNOWN_RAT_PACKAGES[app.package]
        if tier == "control":
            severity = "critical" if (app.accessibility_enabled or sideloaded) else "high"
            hits.append(_hit("KNOWN_RAT", severity, app.package, f"known remote-access tool {tool} ({tier}) installer={app.installer or 'unknown'}", app.name))
        elif sideloaded:
            hits.append(_hit("KNOWN_RAT", "medium", app.package, f"known remote-access tool {tool} ({tier}) installer={app.installer or 'unknown'}", app.name))
        else:
            # A viewer-only client from a store cannot drive this phone: recorded, soft, never a reason for Gemini to raise.
            hits.append(_hit("KNOWN_RAT", "low", app.package, f"known remote-access tool {tool} ({tier}) installer={app.installer or 'unknown'}", app.name, soft=True))

    # Rule 3. Data harvesting: the Play Protect fraud permissions and the lending-policy forbidden permissions as
    # hand-crafted features. A sideloaded app that looks like a loan app, or any sideloaded app declaring an SMS/OTP
    # permission, is the BFIU fake-loan pattern (hard). A sideloaded well-known app (bKash via SHAREit, Facebook Lite
    # from a phone shop, which is how many Bangladeshi phones are set up) only earns a soft SIDELOADED_DATA_REACH;
    # a Play-installed app declaring several categories is a soft flag too (a backup app looks like this).
    fraud = sorted(perms & s.PLAY_PROTECT_FRAUD_PERMISSIONS)
    forbidden = sorted(perms & (s.LENDING_FORBIDDEN_PERMISSIONS | s.RESTRICTED_SMS_CALL_LOG_PERMISSIONS))
    categories = {s.HARVEST_CATEGORIES[p] for p in forbidden}
    loan_like = _looks_like_loan_app(app)
    known_publisher = app.package in s.KNOWN_PUBLISHER_PACKAGES
    evidence = f"origin={origin} loan_like={loan_like} known_publisher={known_publisher} fraud_permissions={fraud} forbidden_permissions={forbidden} categories={sorted(categories)}"
    reaching = bool(fraud) or len(categories) >= 2
    if sideloaded and reaching and not known_publisher and (loan_like or fraud):
        hits.append(_hit("LOAN_APP_DATA_HARVEST", "high", app.package, evidence, app.name))
    elif _bfiu_listed(app) and reaching:
        # A regulator-named app still on Play: a hard medium, Gemini may not clear it.
        hits.append(_hit("LOAN_APP_DATA_HARVEST", "medium", app.package, evidence, app.name))
    elif unknown and reaching and not known_publisher and loan_like:
        # A loan-named app reaching for contacts, photos or SMS with no provenance: hard medium (a preload is not called "Taka Cash").
        hits.append(_hit("LOAN_APP_DATA_HARVEST", "medium", app.package, evidence, app.name))
    elif (sideloaded or unknown) and reaching:
        hits.append(_hit("SIDELOADED_DATA_REACH", "low", app.package, evidence, app.name, soft=True))
    elif (loan_like and reaching) or len(categories) >= 3 or fraud:
        # "cash", "taka", "credit" in a Play-installed label, or a Play app with broad reach: soft, Gemini arbitrates.
        hits.append(_hit("LOAN_APP_DATA_HARVEST", "low", app.package, evidence, app.name, soft=True))

    return tuple(hits)


def device_hits(device: DeviceRow, apps: tuple[AppRow, ...]) -> tuple[Hit, ...]:
    hits: list[Hit] = []
    by_package = {app.package: app for app in apps}

    # Rule 2026-4 (device view). The default SMS package itself, when it is a sideloaded app we can see.
    if device.default_sms_package and device.default_sms_package in by_package:
        sms_app = by_package[device.default_sms_package]
        if s.is_sideloaded(sms_app.installer) and not sms_app.is_default_sms_app:
            hits.append(_hit("SMS_ROLE_TAKEOVER", "critical", sms_app.package, f"device default SMS app, installer={sms_app.installer or 'unknown'}", sms_app.name))

    # Rule 4. Overlay permission on a sideloaded app: the fake-PIN-page vector (SYSTEM_ALERT_WINDOW holders).
    for holder in device.overlay_holders:
        app = by_package.get(holder)
        if app is not None and s.is_sideloaded(app.installer):
            hits.append(_hit("OVERLAY_CAPABLE", "medium", holder, f"overlay holder installer={app.installer or 'unknown'}", app.name))

    # Rule 5. Device-admin rights on a sideloaded app: malware uses them to resist uninstall.
    for admin in device.device_admins:
        app = by_package.get(admin)
        if app is not None and s.is_sideloaded(app.installer):
            hits.append(_hit("DEVICE_ADMIN", "high", admin, f"device admin installer={app.installer or 'unknown'}", app.name))

    if device.rooted:
        hits.append(_hit("DEVICE_ROOTED", "high", s.DEVICE, "rooted=true"))
    if device.dev_options or device.adb:
        hits.append(_hit("DEV_OPTIONS_ON", "low", s.DEVICE, f"dev_options={device.dev_options} adb={device.adb}"))
    if not device.play_protect:
        hits.append(_hit("PLAY_PROTECT_OFF", "medium", s.DEVICE, "play_protect=false"))
    return tuple(hits)


def integrity_hits(verdict: IntegrityVerdict) -> tuple[Hit, ...]:
    """UNKNOWN_CONTROLLING is a hard BLOCK; capturing/overlays and Play Protect risk add weight."""
    if verdict.source in ("none", "failed"):
        return ()
    hits: list[Hit] = []
    detected = set(verdict.apps_detected)
    source = f"source={verdict.source}"
    if "UNKNOWN_CONTROLLING" in detected:
        hits.append(_hit("INTEGRITY_CONTROLLING", "critical", s.DEVICE, f"appsDetected=UNKNOWN_CONTROLLING {source}"))
    elif "KNOWN_CONTROLLING" in detected:
        hits.append(_hit("INTEGRITY_CONTROLLING", "medium", s.DEVICE, f"appsDetected=KNOWN_CONTROLLING {source}"))
    if "UNKNOWN_CAPTURING" in detected or "UNKNOWN_OVERLAYS" in detected:
        hits.append(_hit("INTEGRITY_CAPTURING", "high", s.DEVICE, f"appsDetected={sorted(detected & {'UNKNOWN_CAPTURING', 'UNKNOWN_OVERLAYS'})} {source}"))
    # 2026 list rule 11: attackers switch Play Protect off during the call (POSSIBLE_RISK); a found threat is a block.
    protect = {"HIGH_RISK": "critical", "MEDIUM_RISK": "high", "POSSIBLE_RISK": "medium"}.get(verdict.play_protect_verdict)
    if protect:
        hits.append(_hit("INTEGRITY_PLAY_PROTECT", protect, s.DEVICE, f"playProtectVerdict={verdict.play_protect_verdict} {source}"))
    return tuple(hits)


SHRINK_RATIO = 0.3  # a report with under 30 % of last time's apps is not the same phone, or not an honest one


def attestation_hits(bundle: Bundle) -> tuple[Hit, ...]:
    """What the server concludes about the *client* from the attestation level (integrity.attestation_level).

    This is the defence against a modified binary: the bundle is a claim; only a bound, Play-recognised token turns it
    into evidence. Tampered, mismatched and failed are hard; "none" and "unbound" are hard only where attestation is
    required (production), and a recorded low signal in demo mode, where the build is not on Play yet.
    """
    level = bundle.attestation
    if level == "tampered":
        return (_hit("CLIENT_TAMPERED", "critical", s.DEVICE, f"attestation={level} appRecognitionVerdict={bundle.integrity.app_recognition} package={bundle.integrity.package_name}"),)
    if level == "mismatch":
        return (_hit("BUNDLE_MISMATCH", "critical", s.DEVICE, f"attestation={level} requestHash does not cover this bundle"),)
    if level == "failed":
        return (_hit("UNATTESTED_CLIENT", "medium", s.DEVICE, f"attestation={level} token offered but not verifiable"),)
    hits: list[Hit] = []
    if level in ("none", "unbound"):
        severity = "medium" if bundle.require_attestation else "low"
        hits.append(_hit("UNATTESTED_CLIENT", severity, s.DEVICE, f"attestation={level} require_attestation={bundle.require_attestation}", soft=not bundle.require_attestation))
    if level in ("virtual", "basic"):  # "device" and "strong" are what a healthy phone earns; nothing to add
        hits.append(_hit("DEVICE_INTEGRITY_FAILED", "high" if level == "virtual" else "medium", s.DEVICE, f"attestation={level} deviceRecognitionVerdict={list(bundle.integrity.device_recognition)}"))
    return tuple(hits)


def plausibility_hits(bundle: Bundle) -> tuple[Hit, ...]:
    """Checks that do not depend on the client's honesty: a real phone always has launchable apps, and the same phone
    does not lose most of them between two checks a few minutes apart (a modified client posting an empty or trimmed
    list to clear a BLOCK is the case this guards)."""
    if not bundle.apps:
        return (_hit("IMPLAUSIBLE_BUNDLE", "medium", s.DEVICE, "installed_apps is empty"),)
    previous = bundle.previous_app_count
    if previous and previous >= 5 and len(bundle.apps) < previous * SHRINK_RATIO:
        return (_hit("BUNDLE_SHRUNK", "medium", s.DEVICE, f"apps={len(bundle.apps)} previous={previous}"),)
    return ()


def evaluate(bundle: Bundle) -> tuple[Hit, ...]:
    """Every rule hit for this bundle: client attestation and plausibility first, then apps, device, Play Integrity."""
    hits: list[Hit] = []
    hits.extend(attestation_hits(bundle))
    hits.extend(plausibility_hits(bundle))
    overlay = set(bundle.device.overlay_holders)
    for app in bundle.apps:
        hits.extend(app_hits(app, overlay_holder=app.package in overlay))
    hits.extend(device_hits(bundle.device, bundle.apps))
    hits.extend(integrity_hits(bundle.integrity))
    return tuple(hits)
