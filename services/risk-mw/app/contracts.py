"""API contracts for risk-mw. Frozen at the start of the build: the app and every module code against these.
"""

from __future__ import annotations

from datetime import datetime
from typing import Annotated, Any, Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

Decision = Literal["allow", "step_up", "delay", "hold", "block"]
Band = Literal["low", "medium", "high", "critical"]
TxnType = Literal["pin_reset", "new_payee", "send_money"]
UiMode = Literal["banner", "fullscreen", "call_apa"]
SafetyVerdict = Literal["SAFE", "CAUTION", "BLOCK"]
# "verified" = the uid came from a checked Firebase ID token; "demo" = auth is off and the caller is whoever
# X-Demo-User says (or "demo"), so a body user_id is taken at its word and marked as such.
IdentitySource = Literal["verified", "demo"]


class Strict(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)


# --- /v1/risk/signals -------------------------------------------------------


class DeviceInfo(Strict):
    model: str = ""
    os: str = ""
    rooted: bool = False
    sim_serial_hash: str = ""
    sim_changed_at: str | None = None
    first_seen_at: datetime | None = None  # Optional, when this app install first saw the device (device age)


class DeviceSignals(Strict):
    call_state: Literal["IDLE", "RINGING", "OFFHOOK"] = "IDLE"
    audio_mode: str = ""
    subscription_changed_hours: float | None = None
    accessibility_services: tuple[str, ...] = ()
    screen_capture: bool = False
    screen_recording: bool = False
    obscured_touch: bool = False
    caller_in_contacts: bool | None = None  # Optional; OFFHOOK from a caller not in contacts (or not known) prepares Apa's C0 pair


class Behaviour(Strict):
    features: tuple[float, ...] = Field(default=(), max_length=64)


class SignalsRequest(Strict):
    session_id: str = Field(min_length=1)
    device: DeviceInfo = DeviceInfo()
    signals: DeviceSignals = DeviceSignals()
    integrity_token: str | None = None
    behaviour: Behaviour = Behaviour()
    # Additive: what the demo panel forced into this post, by field name ("call_state",
    # "subscription_changed_hours", "sim_changed_at", "screen_capture", "screen_recording") or by demo flag name
    # ("call_active", "sim_swap", "screen_share"). A flag derived only from these is reported as "demo", not "device".
    simulated: tuple[Annotated[str, Field(min_length=1, max_length=64)], ...] = Field(default=(), max_length=32)


class SignalsResponse(Strict):
    stored: bool


# --- /v1/risk/score ---------------------------------------------------------


class Txn(Strict):
    type: TxnType
    amount_bdt: float = Field(default=0.0, ge=0)
    to_account: str | None = None
    is_new_payee: bool = False
    txn_id: str | None = Field(default=None, max_length=64)  # Optional, keys transactions/{txnId}


class DemoFlags(Strict):
    sim_swap: bool = False
    call_active: bool = False
    screen_share: bool = False
    caller_in_contacts: bool = False
    app_safety_verdict: SafetyVerdict = "SAFE"
    inbound_mule_score: float = Field(default=0.0, ge=0, le=1)
    scam_score: float = Field(default=0.0, ge=0, le=1)


# The phone's App Safety block is cut to size, never refused (2026-10-18): a 422 on /v1/risk/score is a transfer that
# cannot be verified, so the money would not move over a payload that is merely too big. What is kept is what the
# decision, FNA's warning and the audit need: the most severe findings first, and a count of what was cut.
APP_SAFETY_MAX_FINDINGS = 50
APP_SAFETY_MAX_PACKAGES = 50
APP_SAFETY_MAX_TEXT = 255
APP_SAFETY_MAX_SIGNAL = 64
SEVERITY_RANK = {"critical": 0, "high": 1, "medium": 2, "low": 3}


def _clip(value: Any, limit: int = APP_SAFETY_MAX_TEXT) -> Any:
    return value[:limit] if isinstance(value, str) else value


class AppSafetyFinding(Strict):
    """One finding of the App Safety Check, as the score needs it: what was found, how bad, and where."""

    package: str
    signal: str
    severity: Literal["low", "medium", "high", "critical"]
    scope: Literal["app", "device"] = "app"

    @field_validator("package", mode="before")
    @classmethod
    def _clip_package(cls, value: Any) -> Any:
        return _clip(value)

    @field_validator("signal", mode="before")
    @classmethod
    def _clip_signal(cls, value: Any) -> Any:
        return _clip(value, APP_SAFETY_MAX_SIGNAL)


class AppSafetyContext(Strict):
    """The App Safety Check result the phone holds when it asks for a score. The app copies it from the last
    `/v1/appsafety/check` answer (source "check") or, when that failed, from `/v1/appsafety/latest/{uid}` (source
    "latest"). It lets the score see the verdict and its findings even when this instance never ran the check (a
    restart, another instance, an expired entry). A client can only raise the verdict this way, never lower it: the
    score takes the stronger of the stored verdict, the demo flag and this block."""

    verdict: SafetyVerdict
    risk_score: float = Field(default=0.0, ge=0, le=1)
    findings: tuple[AppSafetyFinding, ...] = ()
    apps_to_uninstall: tuple[str, ...] = ()
    recommended_action: str = ""
    resolution: str = "NONE"
    attestation: str = "none"
    simulated_verdict: bool = False
    model_version: str = ""
    check_id: str = ""
    checked_at: str = ""
    valid_until: str = ""
    source: Literal["check", "latest"] = "check"
    findings_dropped: int = Field(default=0, ge=0)  # the server's count of findings it cut; a value the phone sends is replaced

    @model_validator(mode="before")
    @classmethod
    def _cut_to_size(cls, data: Any) -> Any:
        """The most severe findings first (the phone's order within a severity), then every list and string capped.
        Anything that is not the expected shape is left for validation to refuse."""
        if not isinstance(data, dict):
            return data
        data = {k: _clip(v) for k, v in data.items()}
        findings = data.get("findings")
        if isinstance(findings, (list, tuple)):
            def rank(f: Any) -> int:  # an unexpected shape sorts last and is left for validation to refuse
                severity = f.get("severity") if isinstance(f, dict) else None
                return SEVERITY_RANK.get(severity, len(SEVERITY_RANK)) if isinstance(severity, str) else len(SEVERITY_RANK)
            ordered = sorted(findings, key=rank)  # sorted() is stable: the phone's order holds within a severity
            data["findings"] = ordered[:APP_SAFETY_MAX_FINDINGS]
            data["findings_dropped"] = len(ordered) - len(data["findings"])  # the server's count, never the phone's
        else:
            data["findings_dropped"] = 0
        packages = data.get("apps_to_uninstall")
        if isinstance(packages, (list, tuple)):
            data["apps_to_uninstall"] = [_clip(p) for p in packages[:APP_SAFETY_MAX_PACKAGES]]
        return data


class ScoreRequest(Strict):
    user_id: str = Field(min_length=1)
    session_id: str = Field(min_length=1)
    txn: Txn
    demo_flags: DemoFlags = DemoFlags()
    # The App Safety Check result the phone holds, so the decision does not depend on this instance's memory.
    app_safety: AppSafetyContext | None = None


SignalSource = Literal["device", "demo", "none"]


class SignalSources(Strict):
    """Where each live-risk input came from. "device" = the phone measured it and posted it to
    /v1/risk/signals (wins when both say yes); "demo" = only a demo_flag or a posted value listed in `simulated` said
    so; "none" = off. caller_in_contacts only ever comes from the request body, so it is "demo" or "none": "demo"
    there means a client flag is what kept a call from holding a PIN reset."""

    call_active: SignalSource = "none"
    sim_swap: SignalSource = "none"
    screen_share: SignalSource = "none"
    caller_in_contacts: SignalSource = "none"


class Reason(Strict):
    code: str
    weight: float = Field(ge=0, le=1)
    text_bn: str
    text_en: str


class Action(Strict):
    type: str
    params: dict[str, int | float | str | bool] = {}


class ScoreResponse(Strict):
    decision: Decision
    risk_score: float = Field(ge=0, le=1)
    band: Band
    reasons: tuple[Reason, ...]
    actions: tuple[Action, ...]
    model_version: str
    warning: HoldWarning | None = None  # On a hold, Apa's prepared warning for this call (see HoldWarning); null otherwise
    # Additive: whose identity was scored; "demo" when auth is off and user_id was taken at its word.
    identity_source: IdentitySource | None = None
    signal_sources: SignalSources | None = None  # Additive: which inputs were simulated
    # Additions (additive, defaulted; null when no known payee was screened): the payee's mule score at the
    # server's scenario clock on the evidence so far and with this transfer landed (DEST_MULE_RISK fires on the
    # second), the feature this transfer moved most, and the clock itself.
    payee_score_before: float | None = Field(default=None, ge=0, le=1)
    payee_score_with_this_transfer: float | None = Field(default=None, ge=0, le=1)
    payee_moved_feature: str | None = None
    payee_score_as_of: str | None = None


# --- /v1/mule/score ---------------------------------------------------------


class MuleReason(Strict):
    feature: str
    value: float
    contribution: float
    direction: Literal["up", "down"]


class MuleScoreResponse(Strict):
    acct_id: str
    known: bool
    probability: float = Field(ge=0, le=1)
    reasons: tuple[MuleReason, ...]
    model_version: str
    as_of: str | None = None


# --- /v1/appsafety/check ----------------------------------------------------


class InstalledApp(Strict):
    package: str
    label: str = ""
    installer: str | None = None
    version: str = ""  # FR-2 (additive)
    permissions: tuple[str, ...] = ()
    has_accessibility_service: bool = False
    accessibility_enabled: bool = False
    target_sdk: int | None = None
    first_install: str | None = None
    # 2026 signals (additive, defaulted): declared notification listener, NFC host-card-emulation service, SMS role,
    # a hidden launcher icon, and whether the installing package is itself a sideloaded app that can install packages (a dropper).
    has_notification_listener: bool = False
    has_hce_service: bool = False
    is_default_sms_app: bool = False
    launcher_icon_hidden: bool = False
    installer_declares_install_packages: bool = False


class DeviceState(Strict):
    overlay_holders: tuple[str, ...] = ()
    device_admins: tuple[str, ...] = ()
    dev_options: bool = False
    adb: bool = False
    rooted: bool = False
    play_protect: bool = True
    # 2026 signals (additive, defaulted)
    sdk_int: int | None = None
    default_sms_package: str | None = None
    nfc_default_payment_package: str | None = None


class AppSafetyRequest(Strict):
    installed_apps: tuple[InstalledApp, ...] = Field(default=(), max_length=500)  # bounds the classifier loop and the prompt
    device: DeviceState = DeviceState()
    integrity_token: str | None = None


class Finding(Strict):
    package: str
    signal: str
    severity: Literal["low", "medium", "high", "critical"]
    evidence: str
    explanation_bn: str
    explanation_en: str
    # Additions (additive, defaulted): a short title for the panel row and whether the row is about an app or the phone.
    title_bn: str = ""
    title_en: str = ""
    scope: Literal["app", "device"] = "app"


class UninstallTarget(Strict):
    package: str
    label: str
    primary_signal: str
    deep_link: str  # "package:<pkg>" for Settings.ACTION_APPLICATION_DETAILS_SETTINGS


class AppSafetyResponse(Strict):
    verdict: SafetyVerdict
    risk_score: float = Field(ge=0, le=1)
    findings: tuple[Finding, ...]
    recommended_action: str
    apps_to_uninstall: tuple[str, ...]
    user_message_bn: str
    user_message_en: str
    simulated_verdict: bool
    # Additions (additive, defaulted): the classifier/engine version and the Gemini-as-judge fields of spec US-3 S2.
    model_version: str = ""
    agrees_with_classifier: bool | None = None
    disagreement_reason: str = ""
    # What the server concluded about the *client*: none | failed | tampered | mismatch | unbound | virtual | basic | device | strong.
    attestation: str = "none"
    # What lifts the verdict: NONE | UNINSTALL_AND_RECHECK | FIX_PHONE_AND_RECHECK | REINSTALL_FROM_PLAY | CALL_BANK | WAIT.
    resolution: str = "NONE"
    # True only on a BLOCK the customer can lift (uninstall / fix the phone, then check again) from a client whose re-check
    # the server would accept (attested, or any client in demo mode). False on SAFE/CAUTION, on reinstall/call-the-bank blocks
    # and, in production, on an unattested client: the panel then shows no "check again" button.
    recheck_lifts_block: bool = False
    uninstall_targets: tuple[UninstallTarget, ...] = ()
    check_id: str = ""
    valid_until: str = ""  # ISO-8601; until then /v1/risk/score reads this verdict for the same uid


class AppSafetyLatest(Strict):
    """GET /v1/appsafety/latest/{uid}: the standing verdict for a uid, or `known=false`."""

    uid: str
    known: bool
    verdict: SafetyVerdict = "SAFE"
    risk_score: float = Field(default=0.0, ge=0, le=1)
    flagged_packages: tuple[str, ...] = ()
    attestation: str = "none"
    checked_at: str = ""
    valid_until: str = ""
    # (2026-10-18), for Case Zero: "server" = this service ran the check; "phone" = the phone reported it with a
    # payment (only with ?include_phone=true). facts = the closed-set phone facts behind the verdict, no package names.
    source: Literal["server", "phone"] = "server"
    facts: tuple[str, ...] = ()


class DemoIntegrityRequest(Strict):
    """Demo panel: mint a signed synthetic Play Integrity verdict bound to the bundle the app is about to send (demo mode only)."""

    installed_apps: tuple[InstalledApp, ...] = Field(default=(), max_length=500)
    device: DeviceState = DeviceState()
    apps_detected: tuple[str, ...] = ()
    play_protect_verdict: str = "NO_ISSUES"
    app_recognition: Literal["PLAY_RECOGNIZED", "UNRECOGNIZED_VERSION", "UNEVALUATED"] = "PLAY_RECOGNIZED"
    device_recognition: tuple[str, ...] = ("MEETS_DEVICE_INTEGRITY",)
    bound: bool = True  # False mints a token with no requestHash (an "unbound" attestation)


class DemoIntegrityResponse(Strict):
    integrity_token: str
    bundle_hash: str
    expires_in_s: int


# --- /v1/intervene, /v1/scam/turn, /v1/apa/turn -----------------------------


class InterveneRequest(Strict):
    user_id: str = Field(min_length=1)
    trigger: str = Field(min_length=1)
    txn: Txn
    transcript_snippet: str | None = None  # only checked against (Apa must not parrot it), never shown to the model
    # P0 (additive): which call and which hold the warning is for. Without them the hold is found from txn.txn_id.
    session_id: str | None = Field(default=None, max_length=128)
    intervention_id: str | None = Field(default=None, max_length=64)


class InterveneResponse(Strict):
    intervene: bool
    script_bn: str  # the validated lines joined; "" on the floor (no validated text: earcon, vibration and the card)
    script_en: str
    audio_asset_id: str | None = None  # always null; there are no recorded clips
    ui: UiMode
    actions: tuple[Action, ...]
    cooldown_s: int = Field(ge=0)
    # Kept for compatibility and always null.
    explanation_bn: str | None = None
    explanation_en: str | None = None
    # P0 (additive): Apa's warning, generated for this call and validated line by line (app.warnings).
    lines: tuple[ApaLine, ...] = ()
    earcon: bool = True              # always: the earcon, vibration and card fire at 0 ms whatever Apa says
    vibrate: bool = True
    speak_on_device: bool = False    # true when there are lines and no audio for them: the phone's own TTS speaks them
    warning_id: str | None = None    # null on the floor
    ledger_hash: str | None = None   # the evidence the warning was written from (keys a pre-render)
    # Additive: the server's id for this intervention, owned by the caller; the only id
    # POST /v1/actions/trusted-contact accepts once auth is on.
    intervention_id: str | None = None
    identity_source: IdentitySource | None = None  # Additive, as on ScoreResponse
    # The whole warning in Apa's Gemini voice, one TTS request: POST /v1/apa/why-audio with script_bn and this token. Null
    # when there is no warning to speak. A 204 there means TTS is spent: the phone plays its own pre-rendered clip, recorded in
    # the same Gemini voice (Apa never speaks in the phone's own voice).
    audio_token: str | None = None
    audio_expires_at: str | None = None


class ApaWhyAudioRequest(Strict):  # POST /v1/apa/why-audio -> streamed audio/wav, 24 kHz mono 16-bit; 204: speak it on the device
    user_id: str = Field(min_length=1)
    text_bn: str = Field(min_length=1, max_length=600)  # a validated line or a whole warning (apa.WARNING_MAX_CHARS); checked again
    token: str | None = Field(default=None, max_length=128)  # issued with this exact text_bn; missing, wrong or expired -> 403


class ApaLine(Strict):  # one line of Apa's generated warning (A attention, T tactic, R rule, X action), validated
    role: Literal["A", "T", "R", "X"]
    text_bn: str
    text_en: str = ""
    token: str | None = None       # lets /v1/apa/why-audio speak text_bn and nothing else; null when it may not be spoken
    expires_at: str | None = None
    clip_id: str | None = None     # a pre-rendered line: GET /v1/apa/clips/{clip_id}; null: no audio for this line
    speak_on_device: bool = False  # true when there is no clip: the phone speaks text_bn with its own Bangla voice


class ApaWhyRequest(Strict):  # POST /v1/apa/why, Apa's warning from the composer, on demand
    user_id: str = Field(min_length=1)
    trigger: str = Field(min_length=1)
    transcript_snippet: str | None = None
    # P0 (additive): the call, the hold and the action the warning is about
    session_id: str | None = Field(default=None, max_length=128)
    intervention_id: str | None = Field(default=None, max_length=64)
    pending_action: TxnType | None = None


class ApaWhyResponse(Strict):  # every field is null (and lines empty) when no line validates
    explanation_bn: str | None = None  # the validated lines joined
    explanation_en: str | None = None
    token: str | None = None  # lets /v1/apa/why-audio speak explanation_bn whole; null when it may not be spoken (too long, say)
    expires_at: str | None = None
    lines: tuple[ApaLine, ...] = ()  # P0 (additive): each with its own token


class Turn(Strict):
    speaker: Literal["caller", "user"]
    text: str
    ts: float


class ScamTurnRequest(Strict):
    session_id: str = Field(min_length=1)
    turns: tuple[Turn, ...] = Field(min_length=1)
    pending_action: str | None = None
    amount_bdt: float | None = Field(default=None, ge=0)
    caller_number: str | None = Field(default=None, max_length=32)  # Optional, for the help-line allow-list


class ScamClassification(Strict):
    """The classification every scam-turn answer carries; ScamTurnResponse adds who answered and the evidence code verified."""

    scam_type: str
    urgency: Literal["none", "low", "medium", "high"]
    requested_secret: Literal["none", "otp", "pin", "password", "other"]
    confidence: float = Field(ge=0, le=1)
    evidence_quote: str
    recommended_action: str
    rolling_score: float = Field(ge=0, le=1)


class TranscribeRequest(Strict):  # POST /v1/scam/transcribe (file-mode speech, spec US-5); answers with a Turn
    session_id: str = Field(min_length=1)
    audio_b64: str
    mime_type: str = Field(min_length=1, max_length=100)
    ts: float | None = None  # seconds on the call's clock; the server's clock when missing


class ScamTurnResponse(ScamClassification):
    # Additions (additive, defaulted): who answered (the Gemini model id, or "stub-fallback" as /v1/investigate
    # uses it) and, for the stub, why Gemini did not.
    model_version: str = ""
    fallback_reason: str | None = None
    # P0 (detector): optional, so older clients are untouched. The call's evidence as code verified it (the ledger),
    # the rules that fired, the tactic card the call matched and the card version, the ledger's hash and the certainty band.
    verdict: Literal["SAFE", "UNCERTAIN", "SCAM"] | None = None
    tactics: tuple[str, ...] = ()
    claimed_identity: str | None = None
    ask: str | None = None
    rule_hits: tuple[str, ...] = ()
    matched_card: str | None = None
    cards_version: str | None = None
    ledger_hash: str | None = None
    band: Literal["possible", "likely", "almost_certain"] | None = None


class ApaContext(Strict):
    last_risk: float | None = None
    screen: str | None = None


class ApaTurnRequest(Strict):
    user_id: str = Field(min_length=1)
    text_bn: str = Field(min_length=1)
    context: ApaContext = ApaContext()


class ApaTurnResponse(Strict):
    reply_bn: str
    reply_en: str
    tool_calls: tuple[str, ...]


# --- /v1/actions/trusted-contact -------------------------------------------


class TrustedContactRequest(Strict):
    intervention_id: str = Field(min_length=1)
    # Optional when users/{owner}.trusted_contact_uid is on file, and then it may only name that one (else 403)
    contact_uid: str | None = Field(default=None, min_length=1)


class TrustedContactResponse(Strict):
    request_id: str
    expires_at: str


class TrustedContactDecision(Strict):
    request_id: str
    status: Literal["approved", "declined", "expired", "pending"]
    # Additive: the uid that settled the request; None while pending or once it expired unanswered.
    decided_by: str | None = None
    # True when decided_by is the named contact. Always true with auth on (anyone else is refused); in demo mode
    # anyone may decide and this says whether it was the contact. None while pending or after an unanswered expiry.
    contact_verified: bool | None = None


class TrustedContactState(Strict):  # GET /v1/actions/trusted-contact/{id}
    request_id: str
    intervention_id: str
    contact_uid: str
    status: Literal["approved", "declined", "expired", "pending"]
    expires_at: str
    push: Literal["sent", "no_token", "disabled", "error"]
    decided_by: str | None = None  # as on TrustedContactDecision
    contact_verified: bool | None = None


class TrustedContactSweep(Strict):  # POST /v1/actions/trusted-contact/sweep, for a scheduler
    checked: int = Field(ge=0)
    expired: tuple[str, ...] = ()  # request ids: only for the operator token, empty for anyone else
    expired_count: int = Field(default=0, ge=0)  # what everyone else sees


# --- /v1/actions/money-lock ----------------------------------------


class MoneyLockRequest(Strict):
    user_id: str = Field(min_length=1)
    minutes: int = Field(ge=1, le=7 * 24 * 60)
    locked_bdt: float | None = Field(default=None, gt=0)  # Lock only this part of the balance; None locks it all


class MoneyLockStatus(Strict):
    user_id: str
    locked: bool
    until: str | None = None
    locked_bdt: float | None = None  # The locked sub-balance; None while unlocked or when the whole balance is locked


# --- Apa's prepared warning: /v1/apa/warning, /v1/apa/clips, ScoreResponse.warning -------------

WarningRole = Literal["A", "T", "R", "X"]  # attention, tactic, rule, action
WarningStage = Literal["C0", "C1", "C2"]  # call-start pair, speculative refresh, cold path at the hold


class ApaWarning(Strict):  # GET /v1/apa/warning/{session_id}: the latest warning prepared for this call
    warning_id: str
    session_id: str
    ledger_hash: str  # the evidence it was written from; the hold compares it with the hash of the call's ledger then
    stage: WarningStage
    lines: tuple[ApaLine, ...]
    created_at: float
    gen_ms: float = 0.0
    render_ms: dict[str, float] = {}  # per role, for the lines rendered by this stage


class HoldWarning(Strict):  # what a hold response carries; earcon, vibration and card fire at 0 ms in every case
    status: Literal["fresh", "stale", "call_start", "none"]
    warning: ApaWarning | None = None  # fresh: every line; stale: its A line; call_start: the C0 A+X pair; none: null
    earcon: bool = True
    vibrate: bool = True
    speak_on_device: bool = False  # some line here has no clip
    stream_rest: bool = False  # open POST /v1/apa/warning/stream for the lines this warning lacks (skip_roles: those it has)


class ApaWarningStreamRequest(Strict):  # POST /v1/apa/warning/stream (C2): NDJSON ApaLine records, then {"done": true, ...}
    session_id: str = Field(min_length=1)
    pending_action: TxnType | None = None  # the held transaction's type, as in the hold's ledger hash
    skip_roles: tuple[WarningRole, ...] = Field(default=(), max_length=4)  # lines the phone already played


ScoreResponse.model_rebuild()  # its optional `warning` names HoldWarning, defined above


# --- /v1/investigate --------------------------------------------------------


class InvestigateRequest(Strict):
    acct_id: str = Field(min_length=1)


class InvestigateResponse(Strict):
    case_id: str
    stream_url: str


class Evidence(Strict):
    row_id: str
    claim: str


class CaseReport(Strict):
    case_id: str
    acct_id: str
    status: Literal["queued", "running", "done", "degraded", "failed"]  # degraded: delivered, but it failed Case Zero's citation check after the retry
    summary_en: str
    summary_bn: str
    evidence: tuple[Evidence, ...]
    ring: tuple[str, ...]
    confidence: float = Field(ge=0, le=1)
    recommended_action: str
    model_version: str
    redacted: bool = False  # optional: validation failed twice, so unsupported sentences were removed
    validation_errors: tuple[str, ...] = ()  # optional: what the citation check still found, for a degraded case
    limitations: str = ""  # optional: what the case could not establish, and what code removed from it
