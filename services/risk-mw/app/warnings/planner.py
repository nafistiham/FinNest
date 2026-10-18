"""The warning plan: code decides what Apa's warning is about, the model only phrases it.

A plan holds facts and nothing a caller said: one or two verified tactics, the ask, the claimed identity CLASS (never the
claimed name), the pending action, the certainty band, the address the user chose, simple mode and which warning of the
call this is. Leaving the transcript out closes the two ways a scammer's words could reach Apa's mouth: parroting and
injection. The action Apa points to is chosen here too, so the model never decides what the customer should do.
"""

from __future__ import annotations

import hashlib
import json
import unicodedata
from dataclasses import dataclass, field

from app.ledger import ASK_TACTIC, TACTICS, Ledger
from app.settings import Settings, get_settings

BANDS = ("possible", "likely", "almost_certain")
# What the caller wants out of her tells more than how they push, so the asks' tactics come first.
TACTIC_ORDER = ("CREDENTIAL_REQUEST", "PAYMENT_REDIRECTION", "REMOTE_ACCESS_REQUEST", "AUTHORITY_IMPERSONATION",
                "PRIZE_OR_REFUND_BAIT", "URGENCY_THREAT", "SECRECY_ISOLATION")
ASK_ORDER = ("otp", "pin", "password", "send_money", "personal_wallet_payment", "install_app", "secrecy")  # most dangerous first
CREDENTIALS = ("otp", "pin", "password")
MONEY = ("send_money", "personal_wallet_payment")
SENDS = ("send_money", "new_payee")
MAX_TACTICS = 2
ADDRESS_MAX_CHARS, ADDRESS_MAX_WORDS = 24, 3

TACTIC_GLOSS = {"CREDENTIAL_REQUEST": "asks for a secret (the code from your message, your PIN or a password)",
                "PAYMENT_REDIRECTION": "asks you to send money somewhere",
                "REMOTE_ACCESS_REQUEST": "asks you to install an app or share your screen",
                "AUTHORITY_IMPERSONATION": "presents as an official (describe the request, never who they say they are)",
                "PRIZE_OR_REFUND_BAIT": "baits you with a prize, a refund or money sent by mistake",
                "URGENCY_THREAT": "rushes or threatens you",
                "SECRECY_ISOLATION": "tells you to keep it secret or not to tell anyone"}
# What risk-mw already verified about her phone (App Safety) and how it is being used (the behaviour model,
# ), in plain words for the model (app.warnings.signals picks them; most dangerous first). Never an app's name,
# a package, a score or a feature's value. Glosses and rules speak to her as "you", as her lines must: the model copies
# them word for word (live, 2026-10-18: "An app on her phone can see and control her screen."). So a gloss's length is
# line T's: SCREEN_CAPTURE's second clause ("so someone else may see it") made its T lines 13 or 14 words, over the cap.
PHONE_GLOSS = {"REMOTE_CONTROL": "an app on your phone can see and control your screen",
               "MODIFIED_APP": "the FinNest app on this phone has been changed; it is not the real app",
               "SCREEN_CAPTURE": "something on your phone is sharing your screen",
               "READS_MESSAGES": "an app on your phone can read your messages, including the codes the bank sends",
               "FAKE_APP": "an app on your phone pretends to be a bank or FinNest",
               "FAKE_LOAN_APP": "a loan app on your phone can take your contacts and photos",
               "UNSAFE_PHONE": "this phone's safety settings are switched off, or it is not a real phone"}
PHONE_FACTS = tuple(PHONE_GLOSS)
# What line R says for each phone fact (2026-10-18): a rule that is true of the bank and useful to her. Left to itself the
# model wrote rules a bank cannot keep ("the bank never lets another app read your messages") or none ("FinNest makes
# sure."). {brand} is the bank's English name; the model renders it in Bangla. Glosses and rules avoid words the validator
# bans (recording, system, install, download; "Store" is one letter from "score"), or every line built on them is dropped,
# and stay short enough for line R's 12 words. NATIVE CHECK on the renderings.
PHONE_RULE = {"REMOTE_CONTROL": "{brand} never asks anyone to see or control your screen",
              "SCREEN_CAPTURE": "{brand} never asks you to share your screen with anyone",
              "READS_MESSAGES": "{brand} never asks anyone for the code that comes in your messages",
              "MODIFIED_APP": "{brand} works only through its own real app",
              "FAKE_APP": "{brand} has only one app of its own",
              "FAKE_LOAN_APP": "a real loan never needs your contacts or photos",
              "UNSAFE_PHONE": "{brand} checks first when a phone's safety settings are off"}


def phone_rule(fact: str, brand_en: str) -> str:
    return PHONE_RULE[fact].format(brand=brand_en)

BEHAVIOUR_GLOSS = {"NOT_HER_PATTERN": "the app is being used differently from how you usually use it",
                   "COACHED_PATTERN": "the long pauses before each step look like someone is telling you what to press",
                   "SWIPE": "the swiping is different from your usual",
                   "TOUCH": "how hard and where the screen is touched is different from your usual",
                   "TYPING": "the rhythm of typing the PIN is different from your usual",
                   "HOLDING": "the way the phone is held and moved is different from your usual"}
BEHAVIOUR_FACTS = tuple(BEHAVIOUR_GLOSS)
# Why the app held this payment, from the hold's own reasons (app.rules; app.warnings.signals maps them), for a hold with
# no call, phone or behaviour facts: with speech to text off (2026-10-17) that is most holds, and with nothing to say the
# model wrote empty lines ("a real bank or office never says such things", 2026-10-18). Each says only what the rule
# established: the mule screen scores the payee WITH this payment, so PAYEE_MULE never says the account is a
# known one. Never an account, an amount, a score or a time. Most telling first. NATIVE CHECK on the renderings.
HOLD_GLOSS = {"PAYEE_MULE": "with this payment, the receiving account looks like one that takes money in and passes it straight on",
              "SIM_CHANGED": "the SIM for your phone number was changed recently",
              "CALL_ON": "you are on a phone call while doing this",
              "NEW_PAYEE_LARGE": "your first payment to this person, and more than you usually send"}
HOLD_FACTS = tuple(HOLD_GLOSS)
# What line R says for each hold fact: what FinNest itself does, true of every hold the fact comes from.
HOLD_RULE = {"PAYEE_MULE": "{brand} checks first before money goes to an account like this",
             "SIM_CHANGED": "{brand} checks first when a phone number's SIM has just been changed",
             "CALL_ON": "{brand} never asks you to do this during a phone call",
             "NEW_PAYEE_LARGE": "{brand} checks first before a large first payment to someone new"}


def hold_rule(fact: str, brand_en: str) -> str:
    return HOLD_RULE[fact].format(brand=brand_en)


# The ledger facts a phone fact lets a line name (the validator's allow-list): a screen-control app may be described
# with screen and install words, a message reader with the code it can read. The others need no ledger word. A first
# large payment is a send to a new payee, so it may say "new payee" while the pending action is send_money.
PHONE_LICENSES = {"REMOTE_CONTROL": ("REMOTE_ACCESS_REQUEST",), "SCREEN_CAPTURE": ("REMOTE_ACCESS_REQUEST",),
                  "READS_MESSAGES": ("otp",)}
HOLD_LICENSES = {"NEW_PAYEE_LARGE": ("new_payee",)}
# Certainty in words, never a number. Non-native draft: NATIVE CHECK.
CERTAINTY = {"possible": ("প্রতারণা হতে পারে", "this could be fraud"),
             "likely": ("প্রতারণার মতো লাগছে", "this looks like fraud"),
             "almost_certain": ("প্রায় নিশ্চিত প্রতারণা", "almost certainly fraud")}
# The action vocabulary stays fixed so Apa stays recognisable; the model picks the words around it. NATIVE CHECK.
ACTIONS = {"hang_up": ("কলটা কেটে দিন", "hang up"),
           "dont_tell_code": ("কোডটা কাউকে বলবেন না", "don't say or type the code to anyone"),
           "dont_send": ("টাকা পাঠাবেন না", "don't send the money"),
           "pause": ("একটু থামুন", "stop for a moment"),
           "talk_family": ("পরিবারের কারও সাথে কথা বলে নিন", "talk to someone in your family first"),
           # A PIN-reset hold's own words (offered by the prompt, never chosen as the primary action, so keys stay put).
           "dont_change_pin": ("এখন পিন বদল করবেন না", "don't change the PIN now"),
           # The next step when App Safety found something: the app's own safety page (app_bn.arb "safety"), which lists
           # the apps to remove and the settings to fix. Only for phone facts; never a link, a number or another app.
           "open_safety": ("অ্যাপের ‘ফোনের নিরাপত্তা’ পাতাটা দেখে নিন", "open 'Phone safety' in the app")}
# The safe path to the bank: the app's own call button, named by settings (brand), so Apa never points at a button the app
# does not have. Its words come from the plan (Plan.words), not from ACTIONS.
CALL_BANK = "call_bank"
OPEN_SAFETY = "open_safety"
ACTION_IDS = (*ACTIONS, CALL_BANK)
_DEFAULTS = Settings.model_fields


def call_bank_words(button_bn: str, button_en: str) -> tuple[str, str]:
    return f"অ্যাপের ‘{button_bn}’ বোতাম চাপুন", f"press the app's '{button_en}' button"


@dataclass(frozen=True)
class Plan:
    tactics: tuple[str, ...] = ()
    ask: str = "none"
    identity: str = "none"
    pending_action: str | None = None
    band: str = "possible"
    address: str | None = None
    simple: bool = False
    index: int = 0
    action: str = "pause"
    safe_path: str = CALL_BANK
    known: frozenset[str] = field(default_factory=frozenset)  # every tactic and ask the ledger holds: the validator's allow-list
    phone: tuple[str, ...] = ()      # PHONE_FACTS, most dangerous first
    behaviour: tuple[str, ...] = ()  # BEHAVIOUR_FACTS
    hold: tuple[str, ...] = ()       # HOLD_FACTS, only when the plan has nothing else to say
    brand_bn: str = _DEFAULTS["brand_bn"].default  # the bank's name, as settings give it (plan() fills these)
    brand_en: str = _DEFAULTS["brand_en"].default
    call_button_bn: str = _DEFAULTS["call_button_bn"].default
    call_button_en: str = _DEFAULTS["call_button_en"].default

    def words(self, action: str) -> tuple[str, str]:
        """The fixed Bangla and English words of an action; the bank's button by its name in the app."""
        return call_bank_words(self.call_button_bn, self.call_button_en) if action == CALL_BANK else ACTIONS[action]

    def facts(self) -> dict:
        """What the composer reads: the facts, glossed, and nothing a caller said."""
        bn, en = CERTAINTY[self.band]
        out = {"tactics": [{"tactic": t, "means": TACTIC_GLOSS[t]} for t in self.tactics], "ask": self.ask,
               "identity_class": self.identity, "pending_action": self.pending_action,
               "certainty": {"band": self.band, "bn": bn, "en": en}, "address": self.address, "simple": self.simple,
               "warning_number": self.index + 1,
               "primary_action": {"action": self.action, "bn": self.words(self.action)[0], "en": self.words(self.action)[1]},
               "safe_path": {"action": self.safe_path, "bn": self.words(self.safe_path)[0], "en": self.words(self.safe_path)[1]}}
        if self.phone:  # only when there are some, so a call's plan reads as before
            out["phone"] = [{"fact": f, "means": PHONE_GLOSS[f], "rule": phone_rule(f, self.brand_en)} for f in self.phone]
        if self.behaviour:
            out["behaviour"] = [{"fact": f, "means": BEHAVIOUR_GLOSS[f]} for f in self.behaviour]
        if self.hold:
            out["hold"] = [{"fact": f, "means": HOLD_GLOSS[f], "rule": hold_rule(f, self.brand_en)} for f in self.hold]
        return out

    def to_prompt(self) -> str:
        return json.dumps(self.facts(), ensure_ascii=False)


def _is_bangla(ch: str) -> bool:
    return unicodedata.name(ch, "").startswith("BENGALI ") and not ch.isdigit()


def clean_address(address: str | None) -> str | None:
    """The form of address she chose, if it is a short Bangla name (one to three words, no digits); otherwise none at all."""
    text = " ".join(unicodedata.normalize("NFC", address or "").split())
    if not text or len(text) > ADDRESS_MAX_CHARS or len(text.split()) > ADDRESS_MAX_WORDS:
        return None
    return text if all(ch == " " or _is_bangla(ch) for ch in text) else None


def _ask(ledger: Ledger) -> str:
    return next((a for a in ASK_ORDER if a in ledger.asks), "none")


def _tactics(ledger: Ledger, ask: str) -> tuple[str, ...]:
    first = ASK_TACTIC.get(ask)
    ordered = sorted((t for t in ledger.tactics if t in TACTICS), key=lambda t: (t != first, TACTIC_ORDER.index(t)))
    return tuple(ordered[:MAX_TACTICS])


def _action(ask: str, pending: str | None, tactics: tuple[str, ...], hold: tuple[str, ...] = ()) -> str:
    if ask in CREDENTIALS:
        return "dont_tell_code"
    if ask in MONEY or pending in SENDS:
        return "dont_send"
    return "hang_up" if tactics or ask != "none" or "CALL_ON" in hold else "pause"


def _known_facts(codes: tuple[str, ...] | list[str], allowed: tuple[str, ...]) -> tuple[str, ...]:
    return tuple(dict.fromkeys(c for c in codes if c in allowed))


def _hold_facts(hold: tuple[str, ...], ask: str, tactics: tuple[str, ...], phone: tuple[str, ...],
                behaviour: tuple[str, ...]) -> tuple[str, ...]:
    """The hold's facts, only when the plan has nothing else to say: a call's, the phone's and the behaviour model's
    facts have their own lines T and R, and a call's plan and key stay as they were."""
    return () if tactics or ask != "none" or phone or behaviour else _known_facts(hold, HOLD_FACTS)


def key(ledger: Ledger, pending_action: str | None, band: str | None, phone: tuple[str, ...] = (),
        behaviour: tuple[str, ...] = (), hold: tuple[str, ...] = ()) -> str:
    """What a warning is kept and matched under (the pre-render, the hold, the card's reuse, the scam turn's ledger_hash): the
    ledger and the band, and the pending action only as far as it changes the instruction the plan chooses. During a call the
    phone sends turns with no pending action: a code ask is "don't say the code" whether or not a send is open, while a call
    with no ask moves from "hang up" to "don't send the money" when a send is held. Phone, behaviour and hold facts join
    the key only when the plan has some, so a call's key is unchanged."""
    ask = _ask(ledger)
    tactics = _tactics(ledger, ask)
    phone, behaviour = _known_facts(phone, PHONE_FACTS), _known_facts(behaviour, BEHAVIOUR_FACTS)
    hold = _hold_facts(hold, ask, tactics, phone, behaviour)
    base = ledger.hash(_action(ask, pending_action, tactics, hold), band)
    if not phone and not behaviour and not hold:
        return base
    return hashlib.sha1(json.dumps([base, phone, behaviour, *([hold] if hold else [])]).encode()).hexdigest()[:len(base)]


def plan(ledger: Ledger, pending_action: str | None, band: str, address: str | None = None, simple: bool = False, index: int = 0,
         phone: tuple[str, ...] = (), behaviour: tuple[str, ...] = (), hold: tuple[str, ...] = ()) -> Plan:
    """The facts Apa's next warning is written from. An unknown band understates (possible) rather than overclaims; an
    unknown phone, behaviour or hold code is dropped."""
    ask = _ask(ledger)
    tactics = _tactics(ledger, ask)
    identity = ledger.claimed_identity
    phone, behaviour = _known_facts(phone, PHONE_FACTS), _known_facts(behaviour, BEHAVIOUR_FACTS)
    hold = _hold_facts(hold, ask, tactics, phone, behaviour)
    # A risky app or setting is fixed on the app's phone-safety page; the call button stays the path for everything else,
    # and for a hold that also carries a caller's request (pasted into the assistant): the request is the urgent part.
    alone = bool(phone) and not tactics and ask == "none"
    safe_path = "talk_family" if identity == "relative" or simple else OPEN_SAFETY if alone else CALL_BANK
    licensed = (*(lic for f in phone for lic in PHONE_LICENSES.get(f, ())), *(lic for f in hold for lic in HOLD_LICENSES.get(f, ())))
    s = get_settings()
    return Plan(tactics=tactics, ask=ask, identity=identity, pending_action=pending_action,
                band=band if band in BANDS else "possible", address=clean_address(address), simple=bool(simple), index=max(0, int(index)),
                action=_action(ask, pending_action, tactics, hold), safe_path=safe_path,
                known=frozenset((*ledger.tactics, *ledger.asks, *licensed)), phone=phone, behaviour=behaviour, hold=hold,
                brand_bn=s.brand_bn, brand_en=s.brand_en, call_button_bn=s.call_button_bn, call_button_en=s.call_button_en)
