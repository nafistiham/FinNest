"""Apa's warning is written and rendered before the hold (C0 at call start, C1 as the evidence grows),
kept per call, and the hold picks fresh, stale, call-start or nothing. The composer (app.warnings) and the voice (app.tts) are
fakes installed in sys.modules, so no model is ever called. The Bangla strings are test fixtures, not product text."""

import struct
import sys
import time
import types
from dataclasses import dataclass, field

import pytest

import app
from app import prerender, scam, state
from app.ledger import Evidence, Ledger
from app.warnings.planner import key as warning_key
from app.settings import Settings

PCM = b"\x00\x01" * 2400  # 0.1 s of 24 kHz 16-bit mono


@dataclass(frozen=True)
class WarningLine:
    role: str
    text_bn: str
    text_en: str = ""


@dataclass(frozen=True)
class Warning:
    lines: tuple = ()
    dropped: tuple = ()
    regenerated: tuple = ()
    timings_ms: dict = field(default_factory=dict)


def lines(*pairs):
    return tuple(WarningLine(role, text, f"en: {text}") for role, text in pairs)


A, T, R, X = "আপা বলছি, একটু থামুন।", "উনি নিজেকে ব্যাংকের লোক বলছেন।", "ব্যাংক কখনো কোড চায় না।", "কলটা কেটে দিন।"
T2 = "উনি আপনার কাছে কোড চাইছেন।"
FOUR = lines(("A", A), ("T", T), ("R", R), ("X", X))


class FakeWarnings(types.ModuleType):
    """app.warnings as builder W publishes it: plan() and generate(); each generate() returns the next queued lines. key() is
    the real one: a pure function of the ledger, the pending action and the band."""

    WarningLine = WarningLine
    Warning = Warning
    key = staticmethod(warning_key)

    def __init__(self):
        super().__init__("app.warnings")
        self.queue, self.plans, self.generated, self.fail = [], [], [], None

    def plan(self, ledger, pending_action, band, address=None, simple=False, index=0):
        planned = {"ledger": ledger, "pending_action": pending_action, "band": band, "address": address, "index": index, "simple": simple}
        self.plans.append(planned)
        return planned

    def generate(self, plan, caller_turns, settings, last_good=None):
        if self.fail:
            raise self.fail
        self.generated.append({"plan": plan, "caller_turns": caller_turns, "last_good": last_good, "settings": settings})
        out = self.queue.pop(0) if len(self.queue) > 1 else (self.queue[0] if self.queue else FOUR)
        return Warning(lines=out)


class FakeTTS(types.ModuleType):
    """app.tts as builder T publishes it: speak() yields 24 kHz PCM, RateLimited on a 429, Unavailable when off."""

    RATE = 24000

    class Unavailable(RuntimeError):
        pass

    class RateLimited(RuntimeError):
        pass

    def __init__(self):
        super().__init__("app.tts")
        self.spoken, self.limit_on, self.off, self.audio = [], set(), False, PCM

    def speak(self, text_bn, settings):
        self.spoken.append(text_bn)
        if self.off:
            raise self.Unavailable("RISK_MW_TTS_ENABLED is false")
        if text_bn in self.limit_on:
            raise self.RateLimited("429")
        yield self.audio


@pytest.fixture
def fakes(monkeypatch):
    composer, voice = FakeWarnings(), FakeTTS()
    monkeypatch.setitem(sys.modules, "app.warnings", composer)
    monkeypatch.setitem(sys.modules, "app.tts", voice)
    monkeypatch.setattr(app, "warnings", composer, raising=False)
    monkeypatch.setattr(app, "tts", voice, raising=False)
    return composer, voice


class Trailing:
    """prerender.TRAILING without timers: what was scheduled, and the newest refresh owed per call."""

    def __init__(self):
        self.calls, self.latest = [], {}

    def schedule(self, key, delay, fn):
        self.latest[key] = fn
        if any(k == key for k, _, _ in self.calls):
            return False
        self.calls.append((key, delay, fn))
        return True


@pytest.fixture
def trailing(monkeypatch):
    timers = Trailing()
    monkeypatch.setattr(prerender, "TRAILING", timers)
    return timers


@dataclass(frozen=True)
class CallState:
    ledger: Ledger
    risk: float
    band: str = "likely"


AUTH = Ledger(tactics={"AUTHORITY_IMPERSONATION": Evidence("AUTHORITY_IMPERSONATION", "আমি ব্যাংক থেকে বলছি", 0)},
              claimed_identity="bank_mfs_staff")
CRED = Ledger(tactics={**AUTH.tactics, "CREDENTIAL_REQUEST": Evidence("CREDENTIAL_REQUEST", "কোডটা বলুন", 2)},
              claimed_identity="bank_mfs_staff", asks=("otp",))
S = Settings(prerender_audio=True)


def prearm(session="call-1", ledger=AUTH, risk=0.6, now=100.0, uid="rina", band="likely", pending="send_money", settings=S):
    return prerender.maybe_prearm(session, uid, CallState(ledger, risk, band), pending, settings, now=now)


# --- C1: the speculative refresh ------------------------------------------------------------------------------------


def test_below_the_prearm_threshold_nothing_is_written(fakes):
    composer, _ = fakes
    assert prearm(risk=0.49) is None
    assert composer.generated == [] and prerender.latest("call-1", "rina") is None


def test_prearm_writes_renders_and_keeps_the_warning(fakes):
    composer, voice = fakes
    got = prearm()
    assert got.stage == "C1" and got.session_id == "call-1" and got.ledger_hash == warning_key(AUTH, "send_money", "likely")
    assert [line.role for line in got.lines] == ["A", "T", "R", "X"] and [line.text_bn for line in got.lines] == [A, T, R, X]
    assert all(line.clip_id and not line.speak_on_device for line in got.lines)
    assert set(got.render_ms) == {"A", "T", "R", "X"} and got.gen_ms >= 0 and got.created_at == 100.0
    assert voice.spoken == [A, T, R, X]
    assert prerender.latest("call-1", "rina") == got
    audio, mime = prerender.clip(got.lines[0].clip_id)
    assert mime == "audio/ogg" and audio[:4] == b"OggS"
    planned = composer.plans[0]
    assert (planned["ledger"], planned["pending_action"], planned["band"], planned["index"]) == (AUTH, "send_money", "likely", 0)


def test_the_same_evidence_is_not_written_twice(fakes):
    composer, _ = fakes
    assert prearm(now=100.0) is not None
    assert prearm(risk=0.8, now=200.0) is None  # the risk moved, the material evidence did not
    assert len(composer.generated) == 1


def test_a_material_change_inside_the_debounce_waits_for_the_next_turn(fakes):
    composer, _ = fakes
    first = prearm(now=100.0)
    assert prearm(ledger=CRED, now=102.0) is None
    second = prearm(ledger=CRED, now=103.5)
    assert second.ledger_hash == warning_key(CRED, "send_money", "likely") and second.warning_id != first.warning_id
    assert len(composer.generated) == 2


def test_a_material_change_inside_the_debounce_is_written_when_the_debounce_ends(fakes, trailing, monkeypatch):
    """The live run (2026-10-17): turns 1.3 s apart, the code ask landed inside the debounce, no later turn came, and the hold
    found the older warning. The change now gets one trailing refresh, from the call as it stands when the debounce ends."""
    composer, _ = fakes
    monkeypatch.setattr(prerender, "session_state", lambda session_id, uid=None: CallState(CRED, 0.9, "almost_certain"))
    monkeypatch.setattr(prerender, "profile", lambda uid: (None, False))
    prearm(now=100.0)
    assert prearm(ledger=CRED, now=102.0) is None  # not now...
    (key, delay, fire), = trailing.calls
    assert key == prerender.doc_key("call-1", "rina") and delay == pytest.approx(1.0)
    later = fire()  # ...but when the debounce ends, from the newest evidence
    assert later.stage == "C1" and later.ledger_hash == warning_key(CRED, "send_money", "almost_certain")
    assert prerender.latest("call-1", "rina") == later and len(composer.generated) == 2


def test_one_trailing_refresh_a_call_with_the_newest_turns(fakes, trailing):
    prearm(now=100.0)
    prearm(ledger=CRED, now=101.0)
    prerender.maybe_prearm("call-1", "rina", CallState(CRED, 0.9, "almost_certain"), "send_money", S, now=102.0, caller_turns=("t2",))
    assert len(trailing.calls) == 1 and trailing.latest[prerender.doc_key("call-1", "rina")] is not trailing.calls[0][2]


def test_no_trailing_refresh_for_the_same_evidence_or_past_the_cap(fakes, trailing):
    prearm(now=100.0)
    assert prearm(now=101.0) is None  # the same evidence: nothing is owed
    for i, band in enumerate(("possible", "almost_certain", "likely")):
        prearm(band=band, pending=None, now=110.0 + 10 * i)
    assert prearm(ledger=CRED, now=141.0) is None  # past the cap
    assert trailing.calls == []


def test_at_most_the_cap_of_refreshes_per_call(fakes):
    for i, (band, pending) in enumerate((("possible", None), ("likely", None), ("likely", "send_money"), ("almost_certain", "send_money"))):
        assert prearm(band=band, pending=pending, now=100.0 + 10 * i) is not None
    assert prearm(ledger=CRED, now=200.0) is None
    assert prerender.latest("call-1", "rina").ledger_hash == warning_key(AUTH, "send_money", "almost_certain")


def test_only_changed_lines_are_rendered_again_and_replaced_clips_go(fakes):
    composer, voice = fakes
    composer.queue = [FOUR, lines(("A", A), ("T", T2), ("R", R), ("X", X))]
    first = prearm(now=100.0)
    voice.spoken.clear()
    second = prearm(ledger=CRED, now=110.0)
    assert voice.spoken == [T2]
    assert [line.clip_id for line in second.lines if line.role != "T"] == [line.clip_id for line in first.lines if line.role != "T"]
    assert second.lines[1].clip_id != first.lines[1].clip_id
    assert prerender.clip(first.lines[1].clip_id) is None and prerender.clip(second.lines[1].clip_id) is not None


def test_the_composer_gets_the_last_good_lines_and_a_running_index(fakes):
    composer, _ = fakes
    prearm(now=100.0)
    prearm(ledger=CRED, now=110.0)
    assert composer.generated[0]["last_good"] is None
    assert tuple(composer.generated[1]["last_good"]) == FOUR
    assert [p["index"] for p in composer.plans] == [0, 1]


def test_the_composer_checks_against_the_callers_verified_words(fakes):
    composer, _ = fakes
    prearm(ledger=CRED)
    assert set(composer.generated[0]["caller_turns"]) == {"আমি ব্যাংক থেকে বলছি", "কোডটা বলুন"}


def test_a_rate_limited_line_goes_to_the_phone_as_text_and_rendering_stops(fakes):
    _, voice = fakes
    voice.limit_on = {T}
    got = prearm()
    a, t, r, x = got.lines
    assert a.clip_id and not a.speak_on_device
    assert all(line.clip_id is None and line.speak_on_device for line in (t, r, x))
    assert voice.spoken == [A, T]  # dropped to the next rung at once: no pacing, no further calls


def test_tts_off_leaves_every_line_for_on_device_speech(fakes):
    _, voice = fakes
    voice.off = True
    got = prearm()
    assert all(line.clip_id is None and line.speak_on_device for line in got.lines) and voice.spoken == [A]


def test_no_validated_text_keeps_nothing_and_frees_the_slot(fakes):
    composer, _ = fakes
    composer.queue = [()]
    assert prearm(now=100.0) is None and prerender.latest("call-1", "rina") is None
    composer.queue = [FOUR]
    assert prearm(now=104.0) is not None


def test_a_failing_composer_never_raises(fakes):
    composer, _ = fakes
    composer.fail = RuntimeError("boom")
    assert prearm() is None and prerender.latest("call-1", "rina") is None


# --- C0: the call-start pair ----------------------------------------------------------------------------------------


def test_the_call_start_pair_is_attention_and_action_only_and_once_per_call(fakes):
    composer, voice = fakes
    got = prerender.call_start_pair("call-2", "rina", S, now=50.0)
    assert got.stage == "C0" and [line.role for line in got.lines] == ["A", "X"] and voice.spoken == [A, X]
    assert (composer.plans[0]["ledger"], composer.plans[0]["pending_action"]) == (Ledger(), None)
    assert prerender.call_start_pair("call-2", "rina", S, now=60.0) is None and len(composer.generated) == 1


def test_the_call_start_pair_can_be_switched_off(fakes):
    composer, _ = fakes
    assert prerender.call_start_pair("call-2", "rina", Settings(prerender_audio=True, call_start_pair_enabled=False), now=50.0) is None
    assert composer.generated == []


# --- the hold -------------------------------------------------------------------------------------------------------


def test_the_hold_picks_none_call_start_fresh_or_stale(fakes):
    nothing = prerender.for_hold("call-3", "rina", "any")
    assert (nothing.status, nothing.warning, nothing.earcon, nothing.vibrate, nothing.stream_rest) == ("none", None, True, True, True)

    prerender.call_start_pair("call-3", "rina", S, now=50.0)
    pair = prerender.for_hold("call-3", "rina", warning_key(AUTH, "send_money", "likely"))
    assert pair.status == "call_start" and [line.role for line in pair.warning.lines] == ["A", "X"] and pair.stream_rest

    prearm(session="call-3", now=100.0)
    fresh = prerender.for_hold("call-3", "rina", warning_key(AUTH, "send_money", "likely"))
    assert fresh.status == "fresh" and len(fresh.warning.lines) == 4 and all(line.clip_id for line in fresh.warning.lines)
    assert not fresh.stream_rest and not fresh.speak_on_device

    stale = prerender.for_hold("call-3", "rina", warning_key(CRED, "send_money", "likely"))
    assert stale.status == "stale" and [line.role for line in stale.warning.lines] == ["A"] and stale.warning.lines[0].clip_id
    assert stale.stream_rest and not stale.speak_on_device


def test_the_hold_says_when_a_line_has_no_audio(fakes):
    _, voice = fakes
    voice.limit_on = {R}
    prearm()
    held = prerender.for_hold("call-1", "rina", warning_key(AUTH, "send_money", "likely"))
    assert held.status == "fresh" and held.speak_on_device


def test_a_hold_never_fails_over_an_unreadable_warning(fakes):
    got = prearm(session="call-6")
    key = prerender.doc_key("call-6", "rina")
    doc = state.store().get(*key)
    state.store().set(*key, {**doc, "warning": {**doc["warning"], "stage": "C9"}})
    assert prerender.for_hold("call-6", "rina", got.ledger_hash).status == "none" and prerender.latest("call-6", "rina") is None
    state.store().set(*key, {**doc, "warning": {**doc["warning"], "lines": [{"role": "Z", "text_bn": A}]}})
    assert prerender.for_hold("call-6", "rina", got.ledger_hash).status == "none"


def test_warnings_and_clips_belong_to_their_account(fakes):
    got = prearm(session="call-4")
    assert prerender.latest("call-4", "mallory") is None
    assert prerender.for_hold("call-4", "mallory", got.ledger_hash).status == "none"
    assert prerender.clip(got.lines[0].clip_id, uid="mallory") is None
    assert prerender.clip(got.lines[0].clip_id, uid="rina") is not None


def test_hold_hash_reads_the_calls_ledger_and_band():
    doc = {"ledger": CRED.to_doc(), "band": "likely", "risk": 0.8, "updated_at": time.time()}
    assert prerender.hold_hash(doc, "send_money") == warning_key(CRED, "send_money", "likely")
    assert prerender.hold_hash({}, "pin_reset") == warning_key(Ledger(), "pin_reset", scam.certainty_band(0.0))  # no call: the floor band


def test_hold_hash_uses_the_detectors_view_when_it_has_one(monkeypatch):
    seen = []
    monkeypatch.setattr(scam, "session_state_of", lambda doc: seen.append(doc) or CallState(CRED, 0.9, "almost_certain"), raising=False)
    assert prerender.hold_hash({"x": 1}, "send_money") == warning_key(CRED, "send_money", "almost_certain") and seen == [{"x": 1}]


# --- clips ----------------------------------------------------------------------------------------------------------


def test_wav_when_the_setting_asks_for_it(fakes):
    got = prearm(settings=Settings(prerender_audio=True, clip_format="wav"))
    audio, mime = prerender.clip(got.lines[0].clip_id)
    assert mime == "audio/wav" and audio[:4] == b"RIFF" and audio[44:] == PCM
    assert struct.unpack("<I", audio[24:28])[0] == 24000 and struct.unpack("<I", audio[40:44])[0] == len(PCM)


def test_audio_too_large_for_a_document_is_left_to_the_phone(fakes, monkeypatch):
    _, voice = fakes
    monkeypatch.setattr(prerender, "CLIP_MAX_BYTES", 100)
    got = prearm()
    assert all(line.clip_id is None and line.speak_on_device for line in got.lines) and voice.spoken == [A, T, R, X]


def _nested_lists(value):
    if isinstance(value, dict):
        return any(_nested_lists(v) for v in value.values())
    if isinstance(value, list | tuple):
        return any(isinstance(v, list | tuple) or _nested_lists(v) for v in value)
    return False


def test_documents_are_firestore_safe(fakes):
    got = prearm(session="call-5")
    warning_doc = state.store().get(*prerender.doc_key("call-5", "rina"))
    clip_doc = state.store().get(prerender.CLIPS, got.lines[0].clip_id)
    assert warning_doc and not _nested_lists(warning_doc) and isinstance(warning_doc["warning"]["lines"], list)
    assert not _nested_lists(clip_doc) and isinstance(clip_doc["audio"], bytes) and clip_doc["uid"] == "rina"
    assert all(isinstance(k, str) for k in warning_doc["warning"]["render_ms"])


def test_her_address_and_simple_mode_reach_every_stage(fakes):
    """Review finding (P): C1 dropped simple mode, C0 and C2 dropped both, and the card then reused those lines."""
    composer, _ = fakes
    state.store().set("users", "rina", {"apa_address": "রহিমা", "apa_simple_mode": True})
    state.store().set(*scam.session_keys("call-9", "rina")[0], {"uid": "rina", "ledger": CRED.to_doc(), "band": "likely", "risk": 0.8,
                                                              "rolling": 0.8, "turns": [], "updated_at": time.time()})
    prerender.call_start_pair("call-9", "rina", S, now=50.0)
    prerender.after_turn("call-9", "rina", None, S, now=100.0)
    state.store().merge(*scam.session_keys("call-9", "rina")[0], {"band": "almost_certain", "risk": 0.95})  # new evidence: C2 writes
    list(prerender.cold_stream("call-9", "rina", "send_money", S, now=200.0))
    assert [(p["address"], p["simple"]) for p in composer.plans] == [("রহিমা", True)] * 3


def test_a_call_start_pair_without_x_does_not_make_the_stream_withhold_x(fakes):
    composer, _ = fakes
    composer.queue = [lines(("A", A))]
    prerender.call_start_pair("call-8", "rina", S, now=50.0)
    composer.queue = [FOUR]
    sent = list(prerender.cold_stream("call-8", "rina", "send_money", S, skip_roles=("A", "X"), now=100.0))
    assert [r.get("role") for r in sent[:-1]] == ["T", "R", "X"]


def test_the_pre_render_gives_the_composer_its_own_longer_deadline(fakes):
    """Replay finding (2026-10-17): C0 and C1 run in the background, yet used the hold path's 2.5 s composer deadline; the
    composer takes about 2.4 s (p95 2.5 s), so most call-start pairs and many refreshes were cut short or lost."""
    composer, _ = fakes
    assert S.prearm_timeout_s > S.warning_timeout_s
    prerender.call_start_pair("call-7", "rina", S, now=50.0)
    prearm(session="call-7", now=100.0)
    assert [g["settings"].warning_timeout_s for g in composer.generated] == [S.prearm_timeout_s] * 2


def test_the_timer_runs_the_newest_refresh_once():
    import threading

    timers, ran, done = prerender.Trailing(), [], threading.Event()
    key = prerender.doc_key("call-1", "rina")
    assert timers.schedule(key, 0.05, lambda: ran.append("older")) is True
    assert timers.schedule(key, 0.05, lambda: ran.append("newest") or done.set()) is False  # one timer a call
    assert done.wait(timeout=2) and ran == ["newest"]
    assert timers.schedule(key, 0.01, lambda: None) is True  # once it has run, the call may be owed another
