"""The vocabulary of the App Safety Check: signals, severities, verdicts, and the policy facts the rules cite.

Everything a rule or a prompt relies on as a *fact about Google Play policy or about known tools*
lives here with its source, so the code comments and the proposal cite the same thing (spec FR-5).
The wire types mirror `services/risk-mw/app/contracts.py` (InstalledApp / DeviceState) without
importing them: this package is also used by the trainer and the eval, which never load FastAPI.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Literal

Verdict = Literal["SAFE", "CAUTION", "BLOCK"]
Severity = Literal["low", "medium", "high", "critical"]
RecommendedAction = Literal["PROCEED", "PROCEED_WITH_OTP", "DELAY_24H", "BLOCK_AND_CALL_BANK"]
Signal = Literal[
    "CLIENT_TAMPERED",
    "BUNDLE_MISMATCH",
    "UNATTESTED_CLIENT",
    "DEVICE_INTEGRITY_FAILED",
    "IMPLAUSIBLE_BUNDLE",
    "BUNDLE_SHRUNK",
    "SIDELOADED_ACCESSIBILITY",
    "OVERLAY_CAPABLE",
    "LOAN_APP_DATA_HARVEST",
    "SIDELOADED_DATA_REACH",
    "KNOWN_RAT",
    "DROPPER_INSTALLED",
    "SMS_ROLE_TAKEOVER",
    "NOTIFICATION_LISTENER",
    "NFC_RELAY_CAPABLE",
    "BRAND_IMPERSONATION",
    "ICON_HIDDEN",
    "PLAY_PROTECT_OFF",
    "DEVICE_ROOTED",
    "DEV_OPTIONS_ON",
    "DEVICE_ADMIN",
    "CLASSIFIER_HIGH",
    "INTEGRITY_CONTROLLING",
    "INTEGRITY_CAPTURING",
    "INTEGRITY_PLAY_PROTECT",
    "OTHER",
]
SIGNALS: tuple[str, ...] = Signal.__args__  # type: ignore[attr-defined]
VERDICTS: tuple[str, ...] = Verdict.__args__  # type: ignore[attr-defined]
SEVERITIES: tuple[str, ...] = Severity.__args__  # type: ignore[attr-defined]
ACTIONS: tuple[str, ...] = RecommendedAction.__args__  # type: ignore[attr-defined]

VERDICT_RANK: dict[str, int] = {"SAFE": 0, "CAUTION": 1, "BLOCK": 2}
Resolution = Literal["NONE", "UNINSTALL_AND_RECHECK", "FIX_PHONE_AND_RECHECK", "REINSTALL_FROM_PLAY", "CALL_BANK", "WAIT"]

# One hit's contribution to the device score. Scores combine with noisy-OR (1 - prod(1 - w)), so two
# lows stay SAFE (0.19), three lows are a CAUTION (0.27), one high is a CAUTION, one critical is a BLOCK.
SEVERITY_WEIGHT: dict[str, float] = {"low": 0.10, "medium": 0.40, "high": 0.70, "critical": 0.95}
CAUTION_THRESHOLD = 0.20  # a clean device scores under 20 on the 0-100 scale
BLOCK_THRESHOLD = 0.80
CLASSIFIER_HIGH_THRESHOLD = 0.80
DEVICE = "device"  # the `package` a device-level hit carries

# --- Install origin ---------------------------------------------------------
# `installer` is what PackageManager.getInstallSourceInfo().installingPackageName reports; the collector
# sends "system" for FLAG_SYSTEM apps (installer is null for them) so "unknown" stays an honest signal.
PLAY_STORE = "com.android.vending"
# App stores. Play Protect's "Internet-sideloading" definition excludes stores (browsers, messaging apps and file managers
# are what it names), so these are "store" origins, not sideloads; Play alone is "play". Ids from research/policy_rules.md 6.
TRUSTED_STORES: frozenset[str] = frozenset({
    PLAY_STORE,
    "com.sec.android.app.samsungapps",  # Galaxy Store
    "com.huawei.appmarket",  # AppGallery
    "com.xiaomi.mipicks", "com.xiaomi.market",  # GetApps
    "com.oppo.market", "com.heytap.market",  # OPPO / realme
    "com.vivo.appstore", "com.bbk.appstore",  # vivo
    "com.amazon.venezia",  # Amazon Appstore
    "org.fdroid.fdroid", "com.aurora.store",
})
BROWSERS: frozenset[str] = frozenset({
    "com.android.chrome", "org.mozilla.firefox", "com.sec.android.app.sbrowser", "com.opera.browser",
    "com.opera.mini.native", "com.brave.browser", "com.microsoft.emmx", "com.UCMobile.intl", "com.mi.globalbrowser",
})
PACKAGE_INSTALLERS: frozenset[str] = frozenset({"com.google.android.packageinstaller", "com.android.packageinstaller"})
SYSTEM = "system"
Origin = Literal["play", "store", "system", "browser", "sideload", "unknown"]


def install_origin(installer: str | None) -> Origin:
    if installer == PLAY_STORE:
        return "play"
    if installer in TRUSTED_STORES:
        return "store"
    if installer == SYSTEM:
        return "system"
    if installer in BROWSERS:
        return "browser"
    if installer in PACKAGE_INSTALLERS:
        return "sideload"
    if installer:
        # Any other package (a file manager, a messaging app, a third-party store) installed it.
        return "sideload"
    return "unknown"


def is_sideloaded(installer: str | None) -> bool:
    """A browser, the package installer, the shell (adb), a file manager, a messaging app: something installed it from a
    file. Policy: a *null* installer is not sideloaded by itself. On one test
    phone 19 of 80 apps had no provenance at all (`packageSource` UNSPECIFIED, every InstallSourceInfo name null), the
    shape of OEM partner preloads and Phone Clone restores; the collector now reports the real source whenever the OS
    has one (an adb install arrives as com.android.shell), so null means "nobody knows", weighed by is_unknown_origin."""
    return install_origin(installer) in ("browser", "sideload")


def is_unknown_origin(installer: str | None) -> bool:
    """No provenance at all. Hard only when the app can act on the screen now (rules.app_hits); otherwise its reach is
    recorded soft so Gemini and the audit still see it."""
    return install_origin(installer) == "unknown"


# --- Policy facts (FR-5) ----------------------------------------------------
# Google Play Protect's enhanced fraud protection blocks the install of Internet-sideloaded apps (browsers, messaging
# apps, file managers) that request "RECEIVE_SMS, READ_SMS, BIND_Notifications, and Accessibility", the permissions
# financial-fraud malware abuses to read OTPs and act on the screen. Sources, accessed 2026-10-16: Singapore pilot
# https://security.googleblog.com/2024/02/piloting-new-ways-to-protect-Android-users-from%20financial-fraud.html and the
# India launch https://blog.google/intl/en-in/products/launching-enhanced-fraud-protection-pilot-in-india/. Bangladesh is
# not named in any rollout post (2026-02 "185 markets" has no list), so this rule re-implements the check server-side.
PLAY_PROTECT_FRAUD_PERMISSIONS: frozenset[str] = frozenset({
    "RECEIVE_SMS", "READ_SMS", "BIND_NOTIFICATION_LISTENER_SERVICE", "BIND_ACCESSIBILITY_SERVICE",
})
# Google Play Personal Loans policy, verbatim: "The following permissions are prohibited: READ_EXTERNAL_STORAGE,
# READ_MEDIA_IMAGES, READ_CONTACTS, ACCESS_FINE_LOCATION, READ_PHONE_NUMBERS, READ_MEDIA_VIDEO, QUERY_ALL_PACKAGES,
# WRITE_EXTERNAL_STORAGE". A loan-like app declaring them is the BFIU fake-loan pattern (contacts and photos harvested
# for blackmail). Source, accessed 2026-10-16: https://support.google.com/googleplay/android-developer/answer/9876821
LENDING_FORBIDDEN_PERMISSIONS: frozenset[str] = frozenset({
    "READ_EXTERNAL_STORAGE", "READ_MEDIA_IMAGES", "READ_CONTACTS", "ACCESS_FINE_LOCATION",
    "READ_PHONE_NUMBERS", "READ_MEDIA_VIDEO", "QUERY_ALL_PACKAGES", "WRITE_EXTERNAL_STORAGE",
})
# SMS and call-log permissions are restricted to default handlers by the separate Permissions policy, accessed 2026-10-16:
# https://support.google.com/googleplay/android-developer/answer/10208820. A loan app has no business declaring them.
RESTRICTED_SMS_CALL_LOG_PERMISSIONS: frozenset[str] = frozenset({
    "READ_SMS", "RECEIVE_SMS", "SEND_SMS", "READ_CALL_LOG", "WRITE_CALL_LOG", "PROCESS_OUTGOING_CALLS",
})
# Permissions that count as one data category each when the harvest rule counts how much an app reaches for.
# READ+WRITE_EXTERNAL_STORAGE on one app is one reach for the photo library, not two.
HARVEST_CATEGORIES: dict[str, str] = {
    "READ_EXTERNAL_STORAGE": "storage", "WRITE_EXTERNAL_STORAGE": "storage", "READ_MEDIA_IMAGES": "storage", "READ_MEDIA_VIDEO": "storage",
    "READ_CONTACTS": "contacts", "ACCESS_FINE_LOCATION": "location", "READ_PHONE_NUMBERS": "phone", "QUERY_ALL_PACKAGES": "packages",
    "READ_SMS": "sms", "RECEIVE_SMS": "sms", "SEND_SMS": "sms", "READ_CALL_LOG": "call_log", "WRITE_CALL_LOG": "call_log", "PROCESS_OUTGOING_CALLS": "call_log",
}
# Remote-access tools scammers talk victims into installing during a fake customer-care call (the RBI AnyDesk
# advisory of 2019 is the canonical South Asian case). The tools are legitimate; a bank seeing one next to an active
# call is the signal. "control" = the phone can be driven remotely; "viewer" = this phone only views another screen.
# Package ids verified on Play on 2026-10-16 (RustDesk is F-Droid only).
KNOWN_RAT_PACKAGES: dict[str, tuple[str, str]] = {
    "com.anydesk.anydeskandroid": ("AnyDesk", "control"),
    "com.teamviewer.quicksupport.market": ("TeamViewer QuickSupport", "control"),
    "com.teamviewer.host.market": ("TeamViewer Host", "control"),
    "com.teamviewer.quicksupport.addon.universal": ("TeamViewer Universal Add-On", "control"),
    "com.carriez.flutter_hbb": ("RustDesk", "control"),
    "com.sand.airsos": ("AirDroid Remote Support", "control"),
    "com.sand.airmirror": ("AirMirror", "control"),
    "com.sand.airdroid": ("AirDroid", "control"),
    "com.zoho.assist.agent": ("Zoho Assist", "control"),
    "com.splashtop.sos": ("Splashtop SOS", "control"),
    "com.splashtop.streamer.csrs": ("Splashtop Streamer", "control"),
    "com.screenconnect.androidclient": ("ScreenConnect", "control"),
    "com.logmein.rescuemobile": ("LogMeIn Rescue", "control"),
    "com.islonline.isllight.mobile.android": ("ISL Light", "control"),
    "com.teknopars.AlpemixPro": ("Alpemix", "control"),
    "it.nanosystems.Supremo": ("Supremo", "control"),
    "com.teamviewer.teamviewer.market.mobile": ("TeamViewer Remote Control", "viewer"),
    "com.google.chromeremotedesktop": ("Chrome Remote Desktop", "viewer"),
    "com.microsoft.rdc.androidx": ("Windows App", "viewer"),
    "com.prosoftnet.rpcnew": ("RemotePC Viewer", "viewer"),
    "com.koushikdutta.vysor": ("Vysor", "viewer"),
    "com.apowersoft.mirror": ("ApowerMirror", "viewer"),
}
# BFIU press release (reported 2026-08-28/29) naming 30 unauthorised digital loan apps; names differ by outlet,
# so these are matched as case-insensitive hints against the app label, never as proof. Sources:
# https://www.dhakatribune.com/business/418603/digital-loan-fraud-bfiu-identifies-31-fake-apps and
# https://www.bssnews.net/business/418749/BFIU-warns-against-unauthorised-digital-loan-platforms
BFIU_FAKE_LOAN_APPS: tuple[str, ...] = (
    "Sathi Loan", "PopCash", "Pop Cash", "FinCash", "Fin Cash", "Quick Loan", "Quick Taka", "Dhaka Fin", "LoanVibe", "LoanBhaib",
    "Dost Loan", "Taka Cash Loan", "Keonja Loan", "KWANZA Loan", "Keoyaj Loan", "SSH Money", "LoanBuddy", "LoanBadi", "CashHora",
    "Cash-Hora", "Cash Hara", "Alo Cash", "Fast Loan", "Easy Taka", "Easy Cash", "Dhairya Loan", "Dhorjo Loan", "Dhoirjo Loan",
    "Fin.do", "Fin Dot Do", "Fin Net Due", "BongoCash", "Asha Loan", "Asa Loan", "Suvidha Loan", "Subidha Loan", "Smart Loan BD",
    "Online Loan BD", "City Online Loan", "BD Shohoj Loan", "BD Sahaj Loan", "Cash Loan", "LoanHat", "Loan Haat", "TakaNow", "Taka Nao",
)
# "Sonali" is on the BFIU list too, but matching it would flag Sonali Bank's real app; the harvest rule needs a permission hit anyway.
LOAN_LABEL_HINTS: tuple[str, ...] = ("loan", "taka", "cash", "credit", "ঋণ", "টাকা", "লোন", "ক্যাশ")

# Apps a Bangladeshi phone commonly carries that reach for contacts, SMS or storage for a legitimate reason, and that are
# routinely installed through SHAREit, a phone shop's file transfer or a browser rather than Play. For these packages the
# harvest and classifier flags are soft (Gemini arbitrates); the accessibility, remote-access and overlay rules still apply.
# A trojan cannot share a package name with the genuine app on the same phone. Ids verified on Play 2026-10-16 where marked.
# Real brand names are kept only so the detector can recognise them; these labels are never shown to the customer.
KNOWN_PUBLISHER_PACKAGES: dict[str, str] = {
    "com.bKash.customerapp": "bKash", "com.bKash.customerapp.uat": "bKash UAT",  # the wallet's own test build
    "com.konasl.nagad": "Nagad", "com.dbbl.mbs.apps.main": "Rocket", "com.upay.customer": "Upay",
    "com.imo.android.imoim": "imo", "com.facebook.lite": "Facebook Lite", "com.facebook.katana": "Facebook", "com.facebook.orca": "Messenger",
    "com.whatsapp": "WhatsApp", "org.telegram.messenger": "Telegram", "com.truecaller": "Truecaller", "com.lenovo.anyshare.gps": "SHAREit",
    "com.google.android.gm": "Gmail", "com.android.chrome": "Chrome", "com.google.android.apps.messaging": "Messages",
    "com.samsung.android.messaging": "Samsung Messages", "com.android.mms": "Messages", "com.google.android.contacts": "Contacts",
    "com.google.android.apps.photos": "Photos", "com.viber.voip": "Viber", "com.pathao.user": "Pathao", "com.daraz.android": "Daraz",
}

# Brand names that droppers and fake apps borrow for their label (Crocodilus "Chrome", Herodotus "Google Play",
# SpyNote fake Play pages, Bangladesh fake bKash/Nagad/bank builds). A sideloaded app wearing one of these labels under
# a package that is not the real vendor's is impersonation.
# Real brand names are kept only so the detector can recognise them.
BRAND_LABELS: dict[str, tuple[str, ...]] = {
    "chrome": ("com.android.chrome", "com.chrome.beta", "com.chrome.dev", "com.chrome.canary", "com.google.chromeremotedesktop"),
    "google play": ("com.android.vending",), "play store": ("com.android.vending",), "play protect": ("com.android.vending", "com.google.android.gms"),
    "bkash": ("com.bKash.customerapp", "com.bKash.customerapp.uat"), "বিকাশ": ("com.bKash.customerapp", "com.bKash.customerapp.uat"), "nagad": ("com.konasl.nagad",), "নগদ": ("com.konasl.nagad",),
    "rocket": ("com.dbbl.mbs.apps.main",), "upay": ("com.upay.customer",), "bhorosha": ("com.bhorosha.app",), "ভরসা": ("com.bhorosha.app",),
    "finnest": ("com.bhorosha.app",), "ফিননেস্ট": ("com.bhorosha.app",),
    "whatsapp": ("com.whatsapp", "com.whatsapp.w4b"), "imo": ("com.imo.android.imoim",), "facebook": ("com.facebook.katana", "com.facebook.lite"),
    "system update": (), "security update": (), "android update": (), "play update": (),
}

# Play Integrity `environmentDetails`. Source: https://developer.android.com/google/play/integrity/verdicts
# "appAccessRiskVerdict.appsDetected" values and "playProtectVerdict" values, accessed 2026-10-16.
APPS_DETECTED_VALUES: tuple[str, ...] = (
    "KNOWN_INSTALLED", "UNKNOWN_INSTALLED", "KNOWN_CAPTURING", "UNKNOWN_CAPTURING",
    "KNOWN_CONTROLLING", "UNKNOWN_CONTROLLING", "KNOWN_OVERLAYS", "UNKNOWN_OVERLAYS",
)
PLAY_PROTECT_VERDICT_VALUES: tuple[str, ...] = (
    "UNEVALUATED", "NO_ISSUES", "NO_DATA", "POSSIBLE_RISK", "MEDIUM_RISK", "HIGH_RISK",
)

# --- Copy ------------------------------------------------------------------
# Bangla first, English second; `{app}` is the app label or package. The word "malware" is deliberately absent:
# the bank can show signals, it cannot prove intent, so every line says "risky" / "ঝুঁকিপূর্ণ".
# Copy rules: plain words a garment worker uses ("ফোন" not "ডিভাইস", "টাকা পাঠানো" not
# "লেনদেন"), at most two sentences, each ending in one thing to do, never blaming the user.
SIGNAL_TEXT: dict[str, tuple[str, str]] = {
    "CLIENT_TAMPERED": (
        "এই ব্যাংকিং অ্যাপটি আসল নয়। প্লে স্টোর থেকে আসল অ্যাপটি ইনস্টল করুন।",
        "This banking app is not the genuine one. Install the real app from the Play Store.",
    ),
    "BUNDLE_MISMATCH": (
        "ফোনের তথ্য যাচাইয়ে মিলছে না, তাই টাকা পাঠানো আটকে রাখা হলো। ব্যাংকে কল করুন।",
        "The phone's report does not match its attestation, so sending money is held. Call the bank.",
    ),
    "UNATTESTED_CLIENT": (
        "ফোনটি গুগলের মাধ্যমে যাচাই করা যায়নি। টাকা পাঠাতে ওটিপি লাগবে।",
        "The phone could not be verified through Google. Sending money will need an OTP.",
    ),
    "DEVICE_INTEGRITY_FAILED": (
        "গুগল এই ফোনটি যাচাই করতে পারছে না। টাকা পাঠাতে ওটিপি লাগবে।",
        "Google cannot verify this phone. Sending money will need an OTP.",
    ),
    "IMPLAUSIBLE_BUNDLE": (
        "ফোনের অ্যাপের তালিকা পাওয়া যায়নি, তাই পরীক্ষা সম্পূর্ণ হয়নি। অ্যাপটি বন্ধ করে আবার খুলুন।",
        "The phone's app list could not be read, so the check is incomplete. Close and reopen the app.",
    ),
    "BUNDLE_SHRUNK": (
        "আগের বারের চেয়ে ফোনে অনেক কম অ্যাপ দেখা যাচ্ছে। অ্যাপটি বন্ধ করে আবার খুলুন।",
        "Far fewer apps are visible than last time. Close and reopen the app.",
    ),
    "SIDELOADED_ACCESSIBILITY": (
        "{app} অ্যাপটি প্লে স্টোরের বাইরে থেকে ইনস্টল করা, আর এটি আপনার স্ক্রিন পড়তে ও আপনার হয়ে ট্যাপ করতে পারে। অ্যাপটি আনইনস্টল করুন।",
        "{app} was installed from outside the Play Store and can read your screen and tap on your behalf. Uninstall it.",
    ),
    "OVERLAY_CAPABLE": (
        "{app} অ্যাপটি অন্য অ্যাপের উপরে নিজের স্ক্রিন দেখাতে পারে; নকল পিন স্ক্রিন এভাবেই দেখানো হয়। অ্যাপটি আনইনস্টল করুন।",
        "{app} can draw over other apps; fake PIN screens are shown this way. Uninstall it.",
    ),
    "LOAN_APP_DATA_HARVEST": (
        "{app} অ্যাপটি আপনার কন্টাক্ট, ছবি বা এসএমএস পড়ার অনুমতি চায়, যা একটি ঋণ অ্যাপের দরকার নেই। অ্যাপটি আনইনস্টল করুন।",
        "{app} asks to read your contacts, photos or SMS, which a loan app does not need. Uninstall it.",
    ),
    "SIDELOADED_DATA_REACH": (
        "{app} অ্যাপটি প্লে স্টোর থেকে ইনস্টল করা হয়নি, আর এটি আপনার কন্টাক্ট, ছবি বা এসএমএস পড়তে পারে। সাবধান থাকুন।",
        "{app} was not installed from the Play Store and can read your contacts, photos or SMS. Be careful.",
    ),
    "KNOWN_RAT": (
        "{app} দিয়ে অন্য কেউ দূর থেকে আপনার ফোন চালাতে পারে। টাকা পাঠানোর আগে এটি আনইনস্টল করুন।",
        "Someone can operate your phone from afar through {app}. Uninstall it before sending money.",
    ),
    "DROPPER_INSTALLED": (
        "{app} অ্যাপটি একটি অচেনা অ্যাপের মাধ্যমে ইনস্টল হয়েছে। এটি আনইনস্টল করুন।",
        "{app} was installed through an unfamiliar app. Uninstall it.",
    ),
    "SMS_ROLE_TAKEOVER": (
        "{app} অ্যাপটি এখন আপনার ফোনের মেসেজ অ্যাপ হয়ে আছে, তাই ব্যাংকের ওটিপি এটি পড়তে পারে। এটি আনইনস্টল করুন।",
        "{app} is now your phone's messaging app, so it can read the bank's OTP. Uninstall it.",
    ),
    "NOTIFICATION_LISTENER": (
        "{app} অ্যাপটি আপনার সব নোটিফিকেশন পড়তে পারে, ওটিপিসহ। এটি আনইনস্টল করুন।",
        "{app} can read all your notifications, OTPs included. Uninstall it.",
    ),
    "NFC_RELAY_CAPABLE": (
        "{app} অ্যাপটি আপনার কার্ড ট্যাপ করার সময় কার্ডের তথ্য অন্য কোথাও পাঠাতে পারে। এটি আনইনস্টল করুন।",
        "{app} can relay your card's data elsewhere when you tap to pay. Uninstall it.",
    ),
    "BRAND_IMPERSONATION": (
        "{app} নামের এই অ্যাপটি আসল নয়। এটি আনইনস্টল করুন।",
        "This app calling itself {app} is not the real one. Uninstall it.",
    ),
    "ICON_HIDDEN": (
        "{app} অ্যাপটি ইনস্টলের পর নিজের আইকন লুকিয়ে ফেলেছে, যা সাধারণ অ্যাপ করে না। সেটিংস থেকে এটি আনইনস্টল করুন।",
        "{app} hid its own icon after installing, which ordinary apps do not do. Uninstall it from Settings.",
    ),
    "PLAY_PROTECT_OFF": (
        "গুগল প্লে প্রোটেক্ট বন্ধ আছে। প্লে স্টোরের সেটিংসে গিয়ে এটি চালু করুন।",
        "Google Play Protect is turned off. Turn it on in the Play Store settings.",
    ),
    "DEVICE_ROOTED": (
        "ফোনটি রুট করা, তাই এর নিরাপত্তা দুর্বল। টাকা পাঠাতে ওটিপি লাগবে।",
        "The phone is rooted, so its protections are weak. Sending money will need an OTP.",
    ),
    "DEV_OPTIONS_ON": (
        "ডেভেলপার অপশন বা ইউএসবি ডিবাগিং চালু আছে। দরকার না হলে সেটিংসে গিয়ে বন্ধ করুন।",
        "Developer options or USB debugging are on. Turn them off in Settings if you do not need them.",
    ),
    "DEVICE_ADMIN": (
        "{app} অ্যাপটি ফোনের অ্যাডমিন অধিকার নিয়েছে, তাই সহজে মোছা যায় না। সেটিংসে গিয়ে আগে অ্যাডমিন বন্ধ করুন, তারপর আনইনস্টল করুন।",
        "{app} holds device-admin rights, so it resists removal. Turn off its admin rights in Settings first, then uninstall it.",
    ),
    "CLASSIFIER_HIGH": (
        "{app} অ্যাপটি যে অনুমতিগুলো চায়, তা পরিচিত ঝুঁকিপূর্ণ অ্যাপের মতো। অ্যাপটি দরকার না হলে মুছে ফেলুন।",
        "{app} asks for permissions the way known risky apps do. Remove it if you do not need it.",
    ),
    "INTEGRITY_CONTROLLING": (
        "গুগলের মতে অন্য একটি অ্যাপ এখন আপনার স্ক্রিন চালাচ্ছে, তাই টাকা পাঠানো আটকে রাখা হলো। ব্যাংকে কল করুন।",
        "Google reports that another app is controlling your screen right now, so sending money is held. Call the bank.",
    ),
    "INTEGRITY_CAPTURING": (
        "গুগলের মতে অন্য একটি অ্যাপ আপনার স্ক্রিন দেখতে বা রেকর্ড করতে পারে। স্ক্রিন শেয়ার বন্ধ করুন।",
        "Google reports that another app can see or record your screen. Stop screen sharing.",
    ),
    "INTEGRITY_PLAY_PROTECT": (
        "গুগল প্লে প্রোটেক্ট এই ফোনে ঝুঁকি পেয়েছে। প্লে স্টোরে গিয়ে প্লে প্রোটেক্ট দিয়ে ফোন স্ক্যান করুন।",
        "Google Play Protect reports a risk on this phone. Open the Play Store and run a Play Protect scan.",
    ),
    "OTHER": ("{app} অ্যাপটি নিয়ে সাবধান থাকুন।", "Be careful with {app}."),
}
# Keyed by (verdict, plural). "{apps}" is one name, or names joined with " ও ".
VERDICT_TEXT: dict[tuple[str, bool], tuple[str, str]] = {
    ("SAFE", False): ("আপনার ফোনে ঝুঁকিপূর্ণ কিছু পাওয়া যায়নি।", "Nothing risky was found on your phone."),
    ("CAUTION", False): (
        "{apps} অ্যাপটি ঝুঁকিপূর্ণ হতে পারে। টাকা পাঠানোর আগে এটি আনইনস্টল করুন।",
        "{apps} may be risky. Uninstall it before you send money.",
    ),
    ("CAUTION", True): (
        "{apps} অ্যাপগুলো ঝুঁকিপূর্ণ হতে পারে। টাকা পাঠানোর আগে এগুলো আনইনস্টল করুন।",
        "{apps} may be risky. Uninstall them before you send money.",
    ),
    ("BLOCK", False): (
        "{apps} অ্যাপটি আপনার ফোন নিয়ন্ত্রণ করতে পারে। আগে এটি আনইনস্টল করুন, তারপর টাকা পাঠান।",
        "{apps} can control your phone. Uninstall it first, then send money.",
    ),
    ("BLOCK", True): (
        "{apps} অ্যাপগুলো আপনার ফোন নিয়ন্ত্রণ করতে পারে। আগে এগুলো আনইনস্টল করুন, তারপর টাকা পাঠান।",
        "{apps} can control your phone. Uninstall them first, then send money.",
    ),
}
GENERIC_CAUTION_TEXT: tuple[str, str] = (
    "আপনার ফোনে কিছু ঝুঁকির লক্ষণ পাওয়া গেছে। টাকা পাঠানোর আগে অচেনা অ্যাপগুলো মুছে ফেলুন।",
    "Some risk signals were found on your phone. Remove unfamiliar apps before you send money.",
)
VERDICT_ACTION: dict[str, str] = {"SAFE": "PROCEED", "CAUTION": "PROCEED_WITH_OTP", "BLOCK": "DELAY_24H"}
# Signals whose BLOCK should send the customer to the bank rather than to the uninstall screen.
CALL_BANK_SIGNALS: frozenset[str] = frozenset({"CLIENT_TAMPERED", "BUNDLE_MISMATCH", "INTEGRITY_CONTROLLING"})
# Fired by checks that do not trust the client (rules.plausibility_hits); a re-check carrying one can never lower a stored BLOCK.
PLAUSIBILITY_SIGNALS: frozenset[str] = frozenset({"IMPLAUSIBLE_BUNDLE", "BUNDLE_SHRUNK"})
# Resolutions a re-check can act on: the customer removes or fixes something, checks again, and the BLOCK lifts.
RECHECK_RESOLUTIONS: frozenset[str] = frozenset({"UNINSTALL_AND_RECHECK", "FIX_PHONE_AND_RECHECK"})
DEVICE_LEVEL_SIGNALS: frozenset[str] = frozenset({"DEVICE_ROOTED", "DEVICE_INTEGRITY_FAILED", "DEV_OPTIONS_ON", "PLAY_PROTECT_OFF", "INTEGRITY_PLAY_PROTECT", "INTEGRITY_CAPTURING", "UNATTESTED_CLIENT", "IMPLAUSIBLE_BUNDLE", "BUNDLE_SHRUNK"})
# Permissions the research marks as old-SDK artefacts (pre-API-23 apps declared them freely); the model must not learn "old app = malware".
ARTEFACT_PERMISSIONS: frozenset[str] = frozenset({"POST_NOTIFICATIONS", "READ_PHONE_STATE", "READ_EXTERNAL_STORAGE", "WRITE_EXTERNAL_STORAGE", "MOUNT_UNMOUNT_FILESYSTEMS", "GET_TASKS", "READ_LOGS"})
SIGNAL_TITLE: dict[str, tuple[str, str]] = {
    "CLIENT_TAMPERED": ("অ্যাপটি আসল নয়", "App is not genuine"), "BUNDLE_MISMATCH": ("তথ্য মিলছে না", "Report mismatch"),
    "UNATTESTED_CLIENT": ("ফোন যাচাই হয়নি", "Phone not verified"), "DEVICE_INTEGRITY_FAILED": ("ফোন যাচাই হচ্ছে না", "Phone cannot be verified"),
    "IMPLAUSIBLE_BUNDLE": ("তালিকা পাওয়া যায়নি", "App list missing"), "BUNDLE_SHRUNK": ("তালিকা ছোট হয়েছে", "App list shrank"),
    "SIDELOADED_ACCESSIBILITY": ("স্ক্রিন পড়তে পারে", "Can read your screen"), "OVERLAY_CAPABLE": ("স্ক্রিনের উপরে দেখায়", "Draws over apps"),
    "LOAN_APP_DATA_HARVEST": ("তথ্য নিয়ে নেয়", "Takes your data"), "SIDELOADED_DATA_REACH": ("বাইরে থেকে ইনস্টল", "Installed from outside the store"),
    "KNOWN_RAT": ("দূর থেকে নিয়ন্ত্রণ", "Remote control"), "PLAY_PROTECT_OFF": ("প্লে প্রোটেক্ট বন্ধ", "Play Protect off"),
    "DROPPER_INSTALLED": ("অচেনা অ্যাপ দিয়ে ইনস্টল", "Installed by a dropper"), "SMS_ROLE_TAKEOVER": ("এসএমএস অ্যাপ বদলে গেছে", "SMS app taken over"),
    "NOTIFICATION_LISTENER": ("নোটিফিকেশন পড়ে", "Reads notifications"), "NFC_RELAY_CAPABLE": ("কার্ডের তথ্য পাঠাতে পারে", "Can relay card taps"),
    "BRAND_IMPERSONATION": ("নকল অ্যাপ", "Impersonates a brand"), "ICON_HIDDEN": ("আইকন লুকানো", "Icon hidden"),
    "DEVICE_ROOTED": ("ফোন রুট করা", "Phone rooted"), "DEV_OPTIONS_ON": ("ডেভেলপার অপশন চালু", "Developer options on"),
    "DEVICE_ADMIN": ("অ্যাডমিন অধিকার", "Device admin"), "CLASSIFIER_HIGH": ("সন্দেহজনক অনুমতি", "Suspicious permissions"),
    "INTEGRITY_CONTROLLING": ("স্ক্রিন অন্যের হাতে", "Screen controlled by another app"), "INTEGRITY_CAPTURING": ("স্ক্রিন রেকর্ড হচ্ছে", "Screen is being captured"),
    "INTEGRITY_PLAY_PROTECT": ("প্লে প্রোটেক্ট সতর্কতা", "Play Protect warning"), "OTHER": ("সতর্কতা", "Caution"),
}


# --- Wire rows ---------------------------------------------------------------


@dataclass(frozen=True)
class AppRow:
    package: str
    label: str = ""
    installer: str | None = None
    version: str = ""
    permissions: tuple[str, ...] = ()
    has_accessibility_service: bool = False
    accessibility_enabled: bool = False
    target_sdk: int | None = None
    first_install: str | None = None
    has_notification_listener: bool = False
    has_hce_service: bool = False
    is_default_sms_app: bool = False
    launcher_icon_hidden: bool = False
    installer_declares_install_packages: bool = False

    @property
    def name(self) -> str:
        return self.label or self.package


@dataclass(frozen=True)
class DeviceRow:
    overlay_holders: tuple[str, ...] = ()
    device_admins: tuple[str, ...] = ()
    dev_options: bool = False
    adb: bool = False
    rooted: bool = False
    play_protect: bool = True
    sdk_int: int | None = None
    default_sms_package: str | None = None
    nfc_default_payment_package: str | None = None


@dataclass(frozen=True)
class IntegrityVerdict:
    """What the server learned from the Play Integrity token, or from the demo stand-in.

    `failed` means a token was offered but could not be verified (bad signature, expired, decode error); that is not the
    same as `none`, because an honest client never presents a bad token.
    """

    source: Literal["google", "demo", "none", "failed"]
    apps_detected: tuple[str, ...] = ()
    play_protect_verdict: str = "UNEVALUATED"
    request_hash: str | None = None
    app_recognition: str = "UNEVALUATED"  # appIntegrity.appRecognitionVerdict
    package_name: str | None = None
    certificate_digests: tuple[str, ...] = ()
    device_recognition: tuple[str, ...] = ()  # deviceIntegrity.deviceRecognitionVerdict
    licensing: str = "UNEVALUATED"  # accountDetails.appLicensingVerdict
    timestamp_ms: int | None = None

    @property
    def simulated(self) -> bool:
        return self.source != "google"


@dataclass(frozen=True)
class Bundle:
    apps: tuple[AppRow, ...] = ()
    device: DeviceRow = DeviceRow()
    integrity: IntegrityVerdict = IntegrityVerdict(source="none")
    attestation: str = "none"  # integrity.AttestationLevel, computed by the caller against bundle_hash
    require_attestation: bool = False  # production: no SAFE without a bound, recognised token; demo: recorded only
    previous_app_count: int | None = None  # from the last report for this uid, for the plausibility check


@dataclass(frozen=True)
class Hit:
    """One signal on one app (or on the device), with the evidence that justifies it.

    `soft` marks a hit Gemini may overrule: a classifier or data-harvest flag on a Play-installed app, where the
    permission pattern is suspicious but the distribution channel is not (the backup-app case).
    Every other hit is a floor the model cannot lower.
    """

    signal: str
    severity: str
    package: str
    evidence: str
    text_bn: str
    text_en: str
    soft: bool = False
    contributions: tuple[tuple[str, float], ...] = field(default=())

    @property
    def weight(self) -> float:
        return SEVERITY_WEIGHT[self.severity]


def canonical_permission(name: str) -> str:
    """'android.permission.READ_SMS' -> 'READ_SMS'; also normalises dataset column spellings."""
    tail = name.strip().rsplit(".", 1)[-1]
    return "".join(ch if ch.isalnum() else "_" for ch in tail).upper().strip("_")
