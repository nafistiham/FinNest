"""What APP_SAFETY_BLOCK says, by what the App Safety Check found (2026-10-18).

The app shows a block reason verbatim on its full-screen overlay, so the reason must name what was really found: "can see
or control your screen" is wrong for a fake loan app or an app reading her messages. The keys are the phone facts FNA's
warning uses (app.warnings.planner.PHONE_FACTS, chosen by app.warnings.signals.facts_from), so the overlay and the voice
describe the same thing. No app name, signal code or number: the safety page lists the apps and their uninstall links.

Each line says what was found, that this cannot go ahead now (a block also stops a PIN reset, not only a transfer), and
the next step in the app's own words for its safety page ("ফোনের নিরাপত্তা" / "Phone safety", app_bn.arb / app_en.arb).
Bangla is a non-native draft: NATIVE CHECK.
"""

from __future__ import annotations

_REMOVE = ("অ্যাপটি সরিয়ে ফোনের নিরাপত্তা আবার যাচাই করুন।", "Remove the app, then check phone safety again.")
_OPEN = ("ফোনের নিরাপত্তা খুলে দেখে নিন কী করতে হবে।", "Open phone safety to see what to do.")


def _line(found_bn: str, found_en: str, step: tuple[str, str]) -> tuple[str, str]:
    return (f"{found_bn}, তাই এটি এখন করা যাবে না। {step[0]}", f"{found_en}, so this cannot go ahead now. {step[1]}")


BLOCK_TEXT: dict[str, tuple[str, str]] = {
    "REMOTE_CONTROL": _line("আপনার ফোনের একটি অ্যাপ আপনার স্ক্রিন দেখতে ও চালাতে পারে",
                            "An app on your phone can see and control your screen", _REMOVE),
    "MODIFIED_APP": _line("এই ফোনের ফিননেস্ট অ্যাপটি আসল নয়, বদলানো একটি কপি",
                          "The FinNest app on this phone is a changed copy, not the real one", _OPEN),
    "SCREEN_CAPTURE": _line("আপনার ফোনে কিছু একটা আপনার স্ক্রিন রেকর্ড বা শেয়ার করছে",
                            "Something on your phone is recording or sharing your screen", _OPEN),
    "READS_MESSAGES": _line("আপনার ফোনের একটি অ্যাপ আপনার মেসেজ পড়তে পারে, ব্যাংকের পাঠানো কোডসহ",
                            "An app on your phone can read your messages, including the codes your bank sends", _REMOVE),
    "FAKE_APP": _line("আপনার ফোনের একটি অ্যাপ নিজেকে ব্যাংক বা ফিননেস্ট বলে দেখায়, কিন্তু আসল নয়",
                      "An app on your phone pretends to be a bank or FinNest", _REMOVE),
    "FAKE_LOAN_APP": _line("আপনার ফোনের একটি ঋণের অ্যাপ আপনার কন্টাক্ট আর ছবি নিয়ে নিতে পারে",
                           "A loan app on your phone can take your contacts and photos", _REMOVE),
    "UNSAFE_PHONE": _line("এই ফোনের নিজস্ব সুরক্ষা চালু নেই",
                          "This phone's built-in protections are off", _OPEN),
}

GENERAL: tuple[str, str] = _line("আপনার ফোনে ঝুঁকিপূর্ণ কিছু পাওয়া গেছে", "Something risky was found on your phone", _OPEN)


def block_text(facts: tuple[str, ...]) -> tuple[str, str]:
    """The overlay line for the most dangerous fact (facts come most dangerous first), or the general line."""
    return BLOCK_TEXT.get(facts[0], GENERAL) if facts else GENERAL
