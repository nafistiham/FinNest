"""Runtime configuration. Everything comes from the environment; nothing is hardcoded."""

from __future__ import annotations

from datetime import datetime
from functools import lru_cache
from pathlib import Path
from typing import Literal

from pydantic import AliasChoices, Field, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

CONFIG_DIR = Path(__file__).resolve().parent.parent / "config"
SCENARIO_TS_FORMAT = "%Y-%m-%dT%H:%M:%S"  # the synthetic world's timestamps (bhorosha_synth.schema.TS_FORMAT)

GenAIBackend = Literal["auto", "api_key", "vertex"]


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="RISK_MW_", extra="ignore")

    project_id: str = ""
    region: str = "asia-southeast1"
    service_name: str = "risk-mw"
    model_version: str = "risk-mw-0.2"  # /health, the FastAPI version and audit rows whose answer names no model of its own

    # Demo mode: no Firebase token check, no Firestore writes, no Gemini calls.
    demo_mode: bool = True
    auth_required: bool = False
    firestore_enabled: bool = False
    genai_enabled: bool = False

    # Gemini backend. "auto" = API key if present (prepaid Gemini credit), else Vertex AI
    # (project + region, paid from the Cloud welcome credit). The key is read from the
    # standard GOOGLE_API_KEY / GEMINI_API_KEY variables, never from code or config files.
    genai_backend: GenAIBackend = "auto"
    # Vertex AI location for Gemini. "global" serves the full line-up; asia-southeast1 only had gemini-2.5-flash on 2026-10-16.
    genai_location: str = "global"
    gemini_api_key: str = Field(default="", validation_alias=AliasChoices("GOOGLE_API_KEY", "GEMINI_API_KEY"))

    models_config_path: Path = CONFIG_DIR / "models.yaml"
    # Mule scorer artefacts (graph.pkl, model.lgb, features.parquet, scorer.json). Unset = model off, demo flags only.
    mule_artefacts_dir: Path | None = None
    # Scenario clock: the moment payees are scored at (YYYY-MM-DDTHH:MM:SS, the world's time). Unset = the demo
    # transfer's moment in demo mode or with auth off, the wall clock in Dhaka otherwise (app.clock). Never from a request.
    scenario_now: str | None = None
    # Behaviour artefacts (ato_<uid>.pkl, coaching.pkl, cold_start.pkl). Unset = behaviour signal off.
    ato_artefacts_dir: Path | None = None

    # Decision thresholds (fractions of 1.0)
    band_medium: float = 0.30
    band_high: float = 0.60
    band_critical: float = 0.85
    mule_hold_threshold: float = 0.80

    # Defaults used when a user document is missing (demo personas)
    default_p95_amount_bdt: float = 5000.0
    sim_change_hold_hours: int = 24

    # Scam-conversation classifier. Help-line numbers a genuine wallet or bank call comes from (two mobile wallets'
    # published short codes); add FinNest's own number with RISK_MW_HELP_LINES.
    help_lines: tuple[str, ...] = ("16247", "16167")
    # The detector's knowledge: tactic_cards/<version>.yaml and examples/<version>.yaml under this directory, the
    # live version named in tactic_cards/active_version. The files are looked at again at most every tactic_cards_ttl_s, so a
    # new card or a rollback needs no deploy.
    knowledge_dir: Path = Path(__file__).resolve().parent / "data"
    tactic_cards_ttl_s: float = Field(default=15.0, ge=0)
    # How long a call's evidence keeps feeding /v1/risk/score after its last scored turn (it was a rolling 60 s window).
    scam_session_ttl_s: float = Field(default=600.0, gt=0)
    # How long the behaviour model's last scored session may still be told in Apa's warning (app.warnings.signals): the
    # warning follows the score within seconds; a session older than this says nothing.
    behaviour_evidence_ttl_s: float = Field(default=900.0, gt=0)
    # Speech (US-5). Off since 2026-10-17: FinNest does not listen to phone calls. Each path needs its own switch and
    # Gemini on. The limits cap one live session's Gemini spend: 300 s of 16 kHz 16-bit mono is 9.6 MB.
    transcription_enabled: bool = False  # POST /v1/scam/transcribe (file mode)
    live_transcription_enabled: bool = False  # WS /v1/scam/live (Gemini Live)
    live_location: str = "us-central1"  # gemini-3.8-live is not served at "global"; everything else stays on genai_location
    live_max_session_s: float = 300.0
    live_max_bytes: int = 9_600_000
    live_drain_s: float = 8.0  # after the app ends the stream, how long to wait for Live's last transcriptions
    # Apa's warning, written and rendered before the hold (app.prerender). Pre-arm sits below the hold
    # (rules.SCAM_SCORE_HOLD_THRESHOLD, 0.70) so the clips are on the phone when it fires; a refresh needs a material ledger
    # change, waits the debounce and stops at the cap, so a suspicious call costs about 8-10 TTS calls. Nothing is spent while
    # Gemini or TTS is off: the composer and the voice own those switches.
    prearm_risk: float = Field(default=0.5, ge=0, le=1)
    prearm_debounce_s: float = Field(default=3.0, ge=0)
    prearm_max_per_call: int = Field(default=4, ge=0)
    # The composer's deadline for C0 and C1, which run in the background: the composer takes about 2.4 s (p95 2.5 s), so the hold
    # path's warning_timeout_s cut most call-start pairs short in the replay (2026-10-17). The cold path keeps warning_timeout_s.
    prearm_timeout_s: float = Field(default=8.0, gt=0)
    call_start_pair_enabled: bool = True  # C0: an A+X pair when a call from a caller not in contacts starts (1 short LLM call, 2 TTS)
    clip_format: Literal["ogg_opus", "wav"] = "ogg_opus"  # ogg_opus falls back to WAV when soundfile cannot write Opus
    transcribe_timeout_s: float = 10.0
    fcm_enabled: bool = False
    scam_timeout_s: float = 4.0
    # The detector's reasoning variant (app/scam_variants.py, v1-v5). v3 won eval/variant_table.py's rule on 2026-10-17 (recall 1.0,
    # benign FPR 0.059, sync p95 1.93 s; eval/results/variant_comparison.md); the others stay selectable here.
    scam_variant: str = "v3"
    # Live TTS for Apa's dynamic "why" (US-3 S2). Off by default: it spends money and the quota is a few requests a minute.
    # The budget is per instance and resets on restart. The voice should match the pre-rendered fixed lines once a native speaker picks.
    tts_enabled: bool = False
    tts_budget_usd: float = 0.50
    tts_voice: str = "Sulafat"
    tts_timeout_s: float = 8.0
    tts_cache_size: int = 32
    # Requests a minute each TTS engine is sent, counted here (app.tts), under the model's quota, so a request that would be
    # refused with a 429 is never sent. Measured live on 2026-10-17: gemini-3.8-flash-lite-tts took 8 in a minute without a
    # 429 (about ten before one); gemini-2.5-flash-tts answered 429 on its 7th.
    tts_requests_per_min: int = Field(default=8, ge=1)            # the primary (role tts)
    tts_fallback_requests_per_min: int = Field(default=5, ge=1)   # the fallback (role tts_fallback)
    # Pre-render (C0, C1, C2) writes Apa's text before the hold. Off: no audio is rendered until a warning is given, when
    # the phone asks for the whole warning once (/v1/intervene's audio_token). On: each line is rendered as before.
    prerender_audio: bool = False
    # /v1/apa/why signs each explanation (HMAC-SHA256 over the text and an expiry) so /v1/apa/why-audio speaks only text this
    # server wrote. Empty = a random secret per process: fine for one instance; give every instance the same secret once the
    # service scales out, or a token issued by one instance is refused (403) by another and the phone speaks the line itself.
    apa_token_secret: str = Field(default="", repr=False)
    apa_token_ttl_s: int = Field(default=300, ge=1)
    # Apa's generated warnings. One composer call (the stream, its checks and at most one regeneration)
    # gets this long; past it the hold answers with what validated, the call's last good lines, or the floor (earcon,
    # vibration and the card, no words). Four short lines and their English fit the output cap at minimal thinking.
    warning_timeout_s: float = Field(default=2.5, gt=0)
    warning_max_output_tokens: int = Field(default=1024, ge=256)
    # The bank as the customer sees it in the app . Apa's own name is never spoken, so
    # this is the name she says; the button is the app's own label for calling the bank (app_bn.arb / app_en.arb safetyCallBank).
    brand_bn: str = "ফিননেস্ট"
    brand_en: str = "FinNest"
    call_button_bn: str = "ফিননেস্টে কল করুন"
    call_button_en: str = "Call FinNest"
    # What /v1/risk/signals leaves for /v1/risk/score, per (caller uid, session id): dropped this long after
    # the last post, and the oldest sessions go first past the limit.
    session_ttl_s: int = 1800
    session_limit: int = 512
    # Device signals that describe the phone right now (call state, screen capture) count for /v1/risk/score only
    # this long after they were posted; a SIM change counts for sim_change_hold_hours.
    live_signal_fresh_s: int = 60
    # Per-persona p95 send amount, mirrored from the seed loader (libs/synth/load_seed.py PERSONAS).
    personas_path: Path = CONFIG_DIR / "personas.json"

    # Action parameters
    pin_reset_freeze_minutes: int = 60
    new_payee_delay_minutes: int = 60
    trusted_contact_expiry_minutes: int = 10
    # The scheduler's shared secret for POST /v1/actions/trusted-contact/sweep (header X-Operator-Token). Empty: with auth on
    # nobody can sweep (overdue requests are still handled whenever anything looks at them); in demo mode anyone gets counts.
    operator_token: str = ""

    # Case Zero base URL. Unset = /v1/investigate streams the scripted stub.
    investigator_url: str = ""
    # A finished case for the same account is reused for this long, because Case Zero admits only a
    # few new investigations per caller and risk-mw is, to it, a single caller.
    investigator_reuse_s: int = 1800

    # Public-URL protection. Per-caller call quotas (per minute), and a Gemini spend ceiling per
    # instance: past it, Gemini routes answer from their stubs instead of spending more.
    rate_limit_enabled: bool = True
    rate_limit_default_per_min: int = 300
    rate_limit_genai_per_min: int = 30
    # Shared by all callers on the Gemini routes; a floor under the per-caller quota (see ratelimit.enforce_all).
    rate_limit_genai_all_per_min: int = 90
    genai_budget_usd: float = 5.0
    # A long system prefix (the detector's tactic cards) is kept as explicit cached content, so every read pays the cached input
    # price: implicit caching hit on sequential reads but hardly at all under parallel load on the global endpoint.
    genai_prefix_cache: bool = True
    genai_prefix_cache_ttl_s: int = Field(default=3600, ge=300)
    # Output cap (thinking included) for a Gemini call that names none, so every call has a worst case the spend
    # ledger can reserve before it is sent. Generous for a JSON classification; a truncated answer is a stub.
    genai_max_output_tokens: int = Field(default=8192, gt=0)

    # App Safety Check. Artefacts: model.txt + columns.json + meta.json from bhorosha_app_safety_check.train;
    # absent -> rules-only. The demo integrity secret signs the synthetic Play Integrity verdict the demo panel sends
    # (accepted only in demo mode); the package name is what a real token would be decoded against.
    appsafety_artefacts_dir: Path | None = None  # models/app-safety-check, vendored by deploy.sh; None/missing = rules only
    appsafety_package_name: str = "com.bhorosha.app"
    # Empty = a random per-instance secret with a loud log line (tokens then die with the instance); scripts/deploy.sh sets one.
    demo_integrity_secret: str = ""
    appsafety_gemini_timeout_s: float = 4.5  # spec: triage under 4 s p95; the fallback answers when the model does not
    # Output-side cost cap per triage call (thinking tokens count against it): six bilingual reasons fit in about 1,000.
    appsafety_max_output_tokens: int = 1536
    # Start-up: the classifier and the Gemini client are always warmed; one background model call (about $0.0005) only when
    # this is on, for a demo whose first triage must not be the cold one. Never waited for.
    appsafety_warm_up_call: bool = False
    appsafety_verdict_ttl_s: int = 900  # how long a SAFE/CAUTION verdict for a uid feeds /v1/risk/score
    appsafety_block_ttl_s: int = 86400  # a BLOCK lasts as long as its DELAY_24H unless a clean attested re-check lifts it
    # APP_SAFETY_CAUTION on the score (D2 2026-10-18): it allows, so its weight stays under band_high (0.60) and an
    # allowed transfer never reads "high"; the demo panel's CAUTION alone, with no check behind it, gets the default.
    app_safety_caution_weight_cap: float = 0.59
    app_safety_caution_default_weight: float = 0.45
    appsafety_google_integrity_enabled: bool = False  # decode real Play Integrity tokens via Google (needs ADC + a Play-published app)
    # Production: no SAFE without a Play-recognised token bound to the bundle (a modded client cannot earn SAFE).
    # Demo: the build is not on Play, so an unattested bundle is only recorded. None = follow demo_mode.
    appsafety_require_attestation: bool | None = None
    appsafety_cert_digests: tuple[str, ...] = ()  # SHA-256 digests of the Play signing certificate(s); empty = not checked
    # Service callers allowed to read another uid's standing verdict once auth is required (Case Zero, the fraud desk).
    appsafety_latest_readers: tuple[str, ...] = ("case-zero", "fraud-desk")

    @field_validator("scenario_now")
    @classmethod
    def _scenario_now_is_a_world_timestamp(cls, value: str | None) -> str | None:
        """Fail at start-up on a clock the scorer could not compare against the world's timestamps."""
        if not value:
            return None
        datetime.strptime(value, SCENARIO_TS_FORMAT)  # ValueError -> a ValidationError naming the field
        return value


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()
