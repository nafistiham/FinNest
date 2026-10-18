"""Apa's line validator: nine deterministic rules, well under 5 ms a line, before anyone hears a word.

Neither the model's own safety nor an LLM judge can be the gate in Bangla, so code is. It extends app.apa's checks (digits,
ids, durations, tip-off words) with the report's eight rules and a ninth, in this order, and names the first that fails:
  shape    one of A|T|R|X, within its word cap, every sentence ended with "।" (speakable: OTP spelt ও-টি-পি)
  script   Bangla script; loanwords pass only written in it (LOANWORDS lists the ones the composer is told to use)
  number   no digit, number word, amount or duration
  tip_off  no tip-off word, a one-letter edit of one included (exact for short terms: এআই is one edit from এই, "this")
  name     no name but the address she chose
  person   she is spoken to, never about: no তার, তাঁর or উনার before something of hers (her phone, screen, messages,
           SIM, PIN, number or family); in English no she, her, he or his, no "their phone" and no "the customer"
  parrot   no run of four tokens shared with any caller turn
  ledger   every word that names a ledger fact (a secret, a tactic, an identity class, money, the pending action, the
           certainty) is in the plan's ledger
  action   A and X carry an allowed action; nothing anywhere tells her to do anything else ("call this number" fails)
Code never edits a failed line; the composer drops or replaces it. The lexicons are a non-native first draft: NATIVE CHECK.
"""

from __future__ import annotations

import re
import unicodedata
from collections.abc import Sequence
from dataclasses import dataclass
from functools import lru_cache

from app import apa
from app.ledger import VAGUE_IDENTITIES, normalise
from app.warnings.planner import CREDENTIALS, MONEY, SENDS, Plan

ROLES = ("A", "T", "R", "X")
ACTION_ROLES = ("A", "X")
RULES = ("shape", "script", "number", "tip_off", "name", "person", "parrot", "ledger", "action")
WORD_CAPS = {"A": 10, "T": 12, "R": 12, "X": 14}
EN_WORD_CAP = 28
PARROT_N = 4
FUZZY_MIN = 5  # code points; a one-letter edit of a shorter word is usually another everyday word

LOANWORDS = ("অ্যাপ", "ব্যাংক", "কোড", "ও-টি-পি", "পিন", "পাসওয়ার্ড", "মেসেজ", "ফোন", "কল", "বোতাম")
PUNCT = set(" \t।,;:—–-‘’“”\"'()…") | {"\u200c", "\u200d"}  # ZWNJ and ZWJ shape Bangla conjuncts
STRIP = "।,;:—–‘’“”\"'()…!?."
SUFFIXES = ("দেরকে", "দের", "েরা", "ের", "এর", "কেই", "কে", "রা", "তে", "টা", "টি", "র", "ে", "ও", "ই")

NUMBER_WORDS = frozenset((
    "এক", "দুই", "দু", "দুটো", "দুটি", "দুইটা", "তিন", "তিনটা", "তিনটি", "চার", "চারটা", "পাঁচ", "পাঁচটা", "ছয়", "ছয়", "সাত", "আট",
    "দশ", "এগারো", "বারো", "তেরো", "চৌদ্দ", "চোদ্দ", "পনেরো", "ষোলো", "সতেরো", "আঠারো", "উনিশ", "বিশ", "কুড়ি", "পঁচিশ", "ত্রিশ",
    "তিরিশ", "চল্লিশ", "পঞ্চাশ", "ষাট", "সত্তর", "আশি", "নব্বই", "শ", "শো", "শত", "একশ", "একশো", "দেড়", "আড়াই", "সাড়ে", "শূন্য"))
NUMBER_STEMS = ("হাজার", "লাখ", "লক্ষ", "কোটি")
NUMBER_INSIDE = ("হাজার", "লাখ", "কোটি")  # compounds such as দশহাজার (লক্ষ is left out: লক্ষ্য means "aim")
HUNDREDS = ("শো", "শ", "শত", "শোর", "শোটা")  # পাঁচশো, দুইশো: a number word and a hundreds ending, nothing between
NUMBER_TRANSLIT = frozenset(("জিরো", "ওয়ান", "টু", "থ্রি", "ফোর", "ফাইভ", "সিক্স", "সেভেন", "এইট", "নাইন", "টেন", "টুয়েন্টি", "থার্টি",
                             "ফিফটি", "হান্ড্রেড", "থাউজেন্ড", "মিলিয়ন"))  # English numbers in Bangla script
NUMBER_EN = re.compile(r"\b(two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|twenty|thirty|forty|fifty|hundred|thousand|lakh|"
                       r"crore|million|billion|dozen|days?|weeks?|months?|years?)\b", re.IGNORECASE)
TIP_OFF = ("তদন্ত", "পুলিশ", "চক্র", "শনাক্ত", "সিস্টেম", "এআই", "রেকর্ড", "গ্যাং", "ডিটেক্ট", "স্কোর", "ট্রান্সক্রিপ্ট", "মামলা",
           "বিশ্লেষক", "অ্যানালিস্ট", "মিউল", "ফ্ল্যাগ", "নজরদারি", "অ্যালগরিদম", "প্রতারক",  # প্রতারক accuses the person
           "গোয়েন্দা", "\u09b0\u09cd\u09af\u09be\u09ac", "গ্রেফতার", "গ্রেপ্তার")  # detective, RAB (as normalise() spells it), arrest
TIP_OFF_PHRASES = ("ধরা পড়", "কৃত্রিম বুদ্ধি")
TIP_OFF_EN = ("investigation", "investigate", "police", "ring", "rings", "gang", "flagged", "flag", "detect", "detected", "detection",
              "system", "ai", "algorithm", "model", "score", "record", "recorded", "recording", "transcript", "analyst", "watchlist",
              "mule", "scammer", "fraudster", "criminal", "detective", "detectives", "arrest", "arrested", "arresting", "rab")
# Real brand names are kept only so the validator can recognise them and keep them out of a warning.
# Other providers and common Bangladeshi names; the bank (settings.brand_bn) and আপা (her) are not names here. NATIVE CHECK: extend.
NAMES = frozenset(("বিকাশ", "নগদ", "রকেট", "এমক্যাশ", "শিওরক্যাশ", "রহিম", "রহিমা", "করিম", "রিনা", "আক্তার", "খাতুন", "বেগম",
                   "হোসেন", "হোসাইন", "আহমেদ", "আহমদ", "রহমান", "উদ্দিন", "চৌধুরী", "মিয়া", "জামান", "হাসান", "কবির",
                   "আলম", "সুলতানা", "ফাতেমা", "নাসরিন", "রফিক", "শফিক", "কামাল", "জামাল", "সাকিব", "তানিয়া", "সালমা", "আয়েশা",
                   "মোহাম্মদ", "মুহাম্মদ", "আব্দুল", "সুমন", "রাজু", "রুবেল", "শাহিন", "মিতু"))
NAMES_EN = ("bkash", "nagad", "rocket", "upay")
# Every line speaks to her as আপনি and "you" (live, 2026-10-18: the plan's third-person gloss came back as "An app on her
# phone can see and control her screen."). In Bangla the slip is a third person's possessive before something of hers;
# তার alone also means "of that" (তার পর, then; তার আগে, before that), so only these nouns count. In English a gendered
# pronoun never belongs in a line (the caller's sex is never known and the bank is "it"). "They" is usually the caller,
# a bank or a plural, so only "their" before something of hers counts, and not after anyone or someone, where it is the
# generic one ("FinNest never asks anyone for their PIN"). NATIVE CHECK on the Bangla.
THIRD_PERSON_BN = ("তার", "তাঁর", "তাহার", "উনার", "ওনার", "ওঁর", "ওর", "তাদের", "তাঁদের", "ওদের")
HER_THINGS_BN = ("ফোন", "স্ক্রিন", "মেসেজ", "এসএমএস", "সিম", "পিন", "ও-টি-পি", "পাসওয়ার্ড", "নম্বর", "পরিবার")
THIRD_PERSON_EN = re.compile(r"\b(she|her|hers|herself|he|him|his|himself)\b|\bthe (customer|user)s?\b(?!\s+(care|service|support))",
                             re.IGNORECASE)
THEIR_THINGS_EN = re.compile(r"\btheir\s+(phone|screen|messages?|texts?|sms|sim|pin|contacts|photos|usual|family)\b", re.IGNORECASE)
GENERIC_EN = re.compile(r"\b(anyone|anybody|someone|somebody|everyone|everybody|no one|nobody|people|whoever)\b", re.IGNORECASE)
# (stems, kind, value): consecutive tokens starting with these stems name that ledger fact. Longer phrases first.
LEXICON = (
    (("পিন", "বদল"), "pending", "pin_reset"), (("পিন", "রিসেট"), "pending", "pin_reset"), (("পিন", "পরিবর্তন"), "pending", "pin_reset"),
    (("নতুন", "প্রাপক"), "pending", "new_payee"), (("প্রায়", "নিশ্চিত"), "band", "almost_certain"),
    # "secret information / code / number" names the credential itself; "গোপন" alone (keep it secret) is the secrecy tactic
    (("গোপন", "তথ্য"), "secret", "credential"), (("গোপন", "কোড"), "secret", "credential"), (("গোপন", "নম্বর"), "secret", "credential"),
    (("গোপন", "পিন"), "secret", "credential"),
    (("নিশ্চিত", "প্রতারণা"), "band", "almost_certain"), (("কাস্টমার", "কেয়ার"), "identity", "bank_mfs_staff"),
    (("ও-টি-পি",), "ask", "otp"), (("কোড",), "ask", "otp"), (("পিন",), "ask", "pin"), (("পাসওয়ার্ড",), "ask", "password"),
    (("টাকা",), "money", "send_money"),
    (("স্ক্রিন",), "tactic", "REMOTE_ACCESS_REQUEST"), (("ইনস্টল",), "tactic", "REMOTE_ACCESS_REQUEST"),
    (("ডাউনলোড",), "tactic", "REMOTE_ACCESS_REQUEST"), (("পুরস্কার",), "tactic", "PRIZE_OR_REFUND_BAIT"),
    (("লটারি",), "tactic", "PRIZE_OR_REFUND_BAIT"), (("রিফান্ড",), "tactic", "PRIZE_OR_REFUND_BAIT"),
    (("উপহার",), "tactic", "PRIZE_OR_REFUND_BAIT"), (("তাড়াহুড়",), "tactic", "URGENCY_THREAT"), (("হুমকি",), "tactic", "URGENCY_THREAT"),
    (("গোপন",), "tactic", "SECRECY_ISOLATION"),
    (("সরকারি",), "identity", "govt_or_police"), (("থানা",), "identity", "govt_or_police"), (("আত্মীয়",), "identity", "relative"),
    (("কুরিয়ার",), "identity", "courier_or_company"), (("কোম্পানি",), "identity", "courier_or_company"),
    (("ডেলিভারি",), "identity", "courier_or_company"), (("ব্যাংক",), "identity", "bank_mfs_staff"),
)
# Imperatives: the polite -উন form, the short ones, and the familiar forms Apa should not use but must not slip through.
IMPERATIVE_SHORT = frozenset(("দিন", "নিন", "যান", "দেন", "নেন", "পাঠান", "জানান", "চালান", "বলেন", "করেন", "রাখেন", "দাও", "করো", "বলো",
                              "রাখো", "পাঠাও", "যাও", "নাও", "চাপো"))
DONT_VERBS = ("বলবেন", "দেবেন", "দিবেন", "জানাবেন", "লিখবেন", "পাঠাবেন", "চাপবেন", "করবেন")  # "don't say / give / type / send / press"
FORBIDDEN = (("এই", "নম্বর"), ("নিরাপদ", "অ্যাকাউন্ট"), ("কথা", "চালিয়ে"), ("টাকা", "নিরাপদ"), ("ফেরত", "পাবেন"), ("কল", "ব্যাক"),
             ("ফিরতি", "কল"), ("ক্লিক",), ("এজেন্ট",))
SAFE_PEOPLE = ("পরিবার", "আপনজন")  # never "don't tell" these, nor the bank (the plan's brand_bn)
FORBIDDEN_EN = re.compile(r"\b(this number|call back|ring back|safe account|keep talking|stay on the line|agents?|click\w*|links?|"
                          r"install\w*|your money is safe|refunds?)\b", re.IGNORECASE)
NOT_IMPERATIVE = frozenset(("নতুন", "আগুন", "খুন", "গুণ", "দ্বিগুণ"))  # end in -উন without being verbs
_FUZZY_BY_LEN: dict[int, tuple[str, ...]] = {}
for _term in TIP_OFF:
    if len(_term) >= FUZZY_MIN:
        for _n in (len(_term) - 1, len(_term), len(_term) + 1):
            _FUZZY_BY_LEN[_n] = (*_FUZZY_BY_LEN.get(_n, ()), _term)


@dataclass(frozen=True)
class Check:
    ok: bool
    rule: str | None = None


OK = Check(True)


def _fail(rule: str) -> Check:
    return Check(False, rule)


def tokens(text: str) -> list[str]:
    """Words, normalised as the ledger compares text, without edge punctuation; a token needs a letter."""
    out = []
    for raw in normalise(text).split():
        word = raw.strip(STRIP)
        if word and any(ch.isalpha() or unicodedata.category(ch).startswith("M") for ch in word):
            out.append(word)
    return out


def _stems(word: str) -> set[str]:
    return {word, *(word[: -len(s)] for s in SUFFIXES if word.endswith(s) and len(word) > len(s) + 1)}


def _within_one(a: str, b: str) -> bool:
    """Levenshtein distance at most 1, without the full table."""
    if a == b:
        return True
    if abs(len(a) - len(b)) > 1:
        return False
    if len(a) > len(b):
        a, b = b, a
    i = 0
    while i < len(a) and a[i] == b[i]:
        i += 1
    return a[i + 1:] == b[i + 1:] if len(a) == len(b) else a[i:] == b[i + 1:]


def _near_tip_off(word: str) -> bool:
    """A tip-off term starts the word, or the word (or its stem) is one edit from a term of five or more code points."""
    if word.startswith(TIP_OFF):
        return True
    return any(_within_one(stem, term) for stem in _stems(word) if len(stem) >= FUZZY_MIN for term in _FUZZY_BY_LEN.get(len(stem), ()))


def _starts(words: Sequence[str], stems: Sequence[str]) -> bool:
    return len(words) >= len(stems) and all(w.startswith(s) for w, s in zip(words, stems, strict=False))


def _has(words: Sequence[str], *stems: str) -> bool:
    return any(w.startswith(s) for w in words for s in stems)


# --- the rules --------------------------------------------------------------------------------------------------------


def _shape(role: str, text: str, words: list[str]) -> bool:
    body = text.strip()
    return (role in ROLES and bool(words) and len(words) <= WORD_CAPS[role] and body.endswith("।") and "\n" not in body
            and not any(ch in body for ch in "?!.") and "ওটিপি" not in words)


def _script(text: str) -> bool:
    return all(ch in PUNCT or ch.isspace() or ch.isdigit() or "\u0980" <= ch <= "\u09ff" for ch in unicodedata.normalize("NFC", text))


def _number(text: str, words: list[str]) -> bool:
    if apa.DIGITS.search(text) or apa.IDS.search(text) or apa.DURATION_WORDS.search(text) or any(ch.isdigit() for ch in text):
        return True
    return any(_numberish(w) for w in words)


def _numberish(word: str) -> bool:
    if word in NUMBER_WORDS or word in NUMBER_TRANSLIT or word.startswith(NUMBER_STEMS) or any(s in word[1:] for s in NUMBER_INSIDE):
        return True
    return any(word.startswith(n) and word[len(n):] in HUNDREDS for n in NUMBER_WORDS)


def _tip_off(text: str, words: list[str]) -> bool:
    flat = normalise(text)
    if apa.TIP_OFF_WORDS.search(text) or any(p in flat for p in TIP_OFF_PHRASES):
        return True
    return any(_near_tip_off(w) for w in words)


def _name(words: list[str], address: str | None) -> bool:
    allowed = set(tokens(address or ""))
    return any(not (stems & allowed) and stems & NAMES for stems in map(_stems, words))


def _third_person(words: list[str]) -> bool:
    pronouns, things = _third_person_words()
    return any(w in pronouns and nxt.startswith(things) for w, nxt in zip(words, words[1:], strict=False))


@lru_cache(maxsize=1)
def _third_person_words() -> tuple[frozenset[str], tuple[str, ...]]:
    return frozenset(tokens(" ".join(THIRD_PERSON_BN))), tuple(tokens(" ".join(HER_THINGS_BN)))


PARROT_SPLIT = re.compile(r"[\s।,;:—–\-‘’“”\"'()…!?./]+")


def _plain(text: str) -> list[str]:
    """Words for the parroting check: split on every punctuation mark too, so 'আপনার-একাউন্ট' is two words, as the caller said them."""
    return [w for w in PARROT_SPLIT.split(normalise(text)) if any(ch.isalpha() or unicodedata.category(ch).startswith("M") for ch in w)]


@lru_cache(maxsize=64)
def _caller_grams(turns: tuple[str, ...]) -> frozenset[tuple[str, ...]]:
    grams: set[tuple[str, ...]] = set()
    for turn in turns:
        words = _plain(turn)
        grams.update(tuple(words[i:i + PARROT_N]) for i in range(len(words) - PARROT_N + 1))
    return frozenset(grams)


def _parrot(text: str, caller_turns: Sequence[str]) -> bool:
    grams, words = _caller_grams(tuple(caller_turns)), _plain(text)
    return any(tuple(words[i:i + PARROT_N]) in grams for i in range(len(words) - PARROT_N + 1))


def facts_named(words: list[str]) -> list[tuple[str, str]]:
    """(kind, value) for every ledger fact the words name, each word counted once."""
    found, i = [], 0
    while i < len(words):
        hit = next(((stems, kind, value) for stems, kind, value in LEXICON if _starts(words[i:], stems)), None)
        if hit:
            found.append((hit[1], hit[2]))
        i += len(hit[0]) if hit else 1
    return found


def _faithful(kind: str, value: str, plan: Plan) -> bool:
    if kind in ("ask", "tactic"):
        return value in plan.known
    if kind == "pending":
        return value == plan.pending_action or value in plan.known  # a hold fact's licence (planner.HOLD_LICENSES)
    if kind == "band":
        return value == plan.band
    if kind == "secret":
        return plan.ask in CREDENTIALS or "CREDENTIAL_REQUEST" in plan.known
    if kind == "money":
        return (plan.pending_action in SENDS or plan.ask in MONEY
                or bool({"PAYMENT_REDIRECTION", "PRIZE_OR_REFUND_BAIT"} & plan.known))
    if kind == "identity":
        return value == plan.identity or (value == "bank_mfs_staff" and plan.identity in VAGUE_IDENTITIES)
    return False


# The app's phone-safety page as an action (2026-10-18): a clause counts only when every word in it is one of these,
# so "turn off phone safety", "install an app for phone safety" or "open phone safety on a website" never pass (final
# review, 2026-10-18: matching on নিরাপত্তা plus any -নিন verb let all of them through).
SAFETY_PAGE_WORDS = ("অ্যাপের", "অ্যাপে", "অ্যাপ", "ফোনের", "নিরাপত্তা", "পাতা", "পাতাটা", "পাতাটি", "দেখে", "দেখুন", "নিন", "খুলুন", "খুলে",
                     "এখন", "তারপর", "একবার")
PHONE_SAFETY_EN = re.compile(r"phone safety", re.IGNORECASE)
PHONE_SAFETY_ABUSE_EN = re.compile(r"\b(turn\w*\s+(it\s+)?off|switch\w*\s+(it\s+)?off|disabl\w*|websites?|web\s*pages?|browsers?|shar\w*|"
                                   r"another app|other apps?|reset\w*|delet\w*|remov\w*|caller)\b", re.IGNORECASE)
CLAUSE_BREAK = re.compile(r"[,;:—–]|\s(?:তারপর|আর|এবং|তবে|কিন্তু|পরে|তাহলে)\s")
SECRET_STEMS = ("কোড", "ও-টি-পি", "পিন", "পাসওয়ার্ড", "গোপন")
MONEY_STEMS = ("টাকা",)


def _instructions(words: list[str]) -> list[str]:
    """Positive instructions in a clause: an imperative (-উন, the short forms), a polite future (-বেন) or an obligation
    (-তে হবে), none followed by না. A dropped না turns "বলবেন না" (don't say) into "বলবেন" (you will say): an instruction."""
    out = []
    for i, w in enumerate(words):
        if words[i + 1:i + 2] == ["না"]:
            continue
        if (w.endswith("ুন") and w not in NOT_IMPERATIVE) or w in IMPERATIVE_SHORT or w.endswith("বেন"):
            out.append(w)
        elif w == "হবে" and i > 0 and words[i - 1].endswith("তে"):
            out.append(words[i - 1])
    return out


def _dont_forms(words: list[str]) -> list[str]:
    return [w for i, w in enumerate(words) if words[i + 1:i + 2] == ["না"] and w.endswith("বেন")]


def _covered(verb: str, words: list[str], brand: str, phone: bool = False) -> bool:
    """Whether a positive instruction is one of the allowed actions, judged inside its own clause. A clause that names a
    secret or money holds no positive instruction at all: "tell the code, then hang up" fails on its first clause."""
    if _has(words, *SECRET_STEMS, *MONEY_STEMS):
        return False
    if verb.startswith("থাম"):
        return True  # stop: the attention verb of every example
    if verb.startswith(("দি", "দে", "রাখ", "রেখে", "কাট", "কেটে")) and _has(words, "কেটে", "রেখে", "কাট") and _has(words, "কল", "ফোন", "লাইন"):
        return True  # hang up
    if verb.startswith(("কর", "চাপ", "দি", "দে")) and _has(words, brand) and _has(words, "অ্যাপ", "বোতাম", "কল", "ফোন"):
        return not _has(words, "নম্বর")  # call the bank from the app's button, never a number
    if phone and _has(words, "নিরাপত্তা") and set(words) <= _safety_words():
        return True  # the app's own phone-safety page, only when App Safety found something, in its fixed words only
    return verb.startswith(("বল", "নি", "নে", "কর")) and _has(words, "পরিবার", "আপনজন")  # talk to family


@lru_cache(maxsize=1)
def _safety_words() -> frozenset[str]:
    return frozenset(tokens(" ".join(SAFETY_PAGE_WORDS)))


def _action(role: str, text: str, brand: str, phone: bool = False) -> bool:
    """True when every instruction in the line is an allowed action, each judged in its own clause (and A or X has one)."""
    allowed = 0
    for sentence in normalise(text).split("।"):
        words = tokens(sentence)
        if any(_starts(words[i:], stems) for stems in FORBIDDEN for i in range(len(words))):
            return False
        for clause in (tokens(c) for c in CLAUSE_BREAK.split(sentence)):
            for verb in _instructions(clause):
                if not _covered(verb, clause, brand, phone):
                    return False
                allowed += 1
            for verb in _dont_forms(clause):
                if not verb.startswith(DONT_VERBS) or _has(clause, *SAFE_PEOPLE, brand):
                    return False  # "don't hang up", "don't tell your family" are the scammer's lines
                allowed += 1
    return allowed > 0 or role not in ACTION_ROLES


def validate(role: str, text: str, plan: Plan, caller_turns: Sequence[str], address: str | None = None) -> Check:
    """The first of the nine rules a Bangla line fails, or OK. `address` defaults to the plan's."""
    words = tokens(text or "")
    if not _shape(role, text or "", words):
        return _fail("shape")
    if not _script(text):
        return _fail("script")
    if _number(text, words):
        return _fail("number")
    if _tip_off(text, words):
        return _fail("tip_off")
    if _name(words, address if address is not None else plan.address):
        return _fail("name")
    if _third_person(words):
        return _fail("person")
    if _parrot(text, caller_turns):
        return _fail("parrot")
    if not all(_faithful(kind, value, plan) for kind, value in facts_named(words)):
        return _fail("ledger")
    if not _action(role, text, normalise(plan.brand_bn), bool(plan.phone)):
        return _fail("action")
    return OK


def validate_en(role: str, text: str) -> Check:
    """The English rendering (shown as script_en, never spoken): the same bans, in English."""
    words = re.findall(r"[a-z][a-z.'-]*", (text or "").lower())
    if role not in ROLES or not words or len(words) > EN_WORD_CAP:
        return _fail("en:shape")
    if apa.DIGITS.search(text) or apa.IDS.search(text) or apa.DURATION_WORDS.search(text) or NUMBER_EN.search(text):
        return _fail("en:number")
    clean = [w.strip(".'-") for w in words]
    if apa.TIP_OFF_WORDS.search(text) or any(w == t or (len(t) >= FUZZY_MIN and _within_one(w, t)) for w in clean for t in TIP_OFF_EN):
        return _fail("en:tip_off")
    if any(w in NAMES_EN for w in clean):
        return _fail("en:name")
    if THIRD_PERSON_EN.search(text) or any(not GENERIC_EN.search(text[:m.start()]) for m in THEIR_THINGS_EN.finditer(text)):
        return _fail("en:person")
    if FORBIDDEN_EN.search(text) or (PHONE_SAFETY_EN.search(text) and PHONE_SAFETY_ABUSE_EN.search(text)):
        return _fail("en:action")
    return OK
