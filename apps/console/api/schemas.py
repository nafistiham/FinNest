"""Response models for /v1/admin/*.

Same discipline as risk-mw's `app/contracts.py`: strict and frozen, so an unknown field is a loud
422 rather than a silently ignored typo, and so the TypeScript types the console generates from
this schema cannot drift from what the service actually sends.

The shapes are deliberately permissive about *values* (a gate may have no measurement, a model may
have no eval) and strict about *structure* (everything that can be rendered carries a badge).
"""

from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field

Badge = Literal["MODEL", "RULE", "STUB", "OFF", "NONE", "NO DATA", "SYNTHETIC"]


class Strict(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)


class Window(Strict):
    from_: str = Field(alias="from")
    to: str
    tz: str
    days: int

    model_config = ConfigDict(extra="forbid", frozen=True, populate_by_name=True)


class Thresholds(Strict):
    band_medium: float
    band_high: float
    band_critical: float
    mule_hold_threshold: float
    default_p95_amount_bdt: float


class Source(Strict):
    seed_dir: str
    checksum: str | None
    service: str
    model_version: str
    mule_model_version: str | None
    thresholds: Thresholds
    synthetic: bool


class WorldCounts(Strict):
    customers: int
    accounts: int
    transactions: int
    agents: int
    merchants: int
    devices: int
    sims: int
    sim_events: int
    device_links: int
    labelled_accounts: int
    rings: int
    first_day: str
    last_day: str
    days: int
    badge: Badge


class Rates(Strict):
    catch_rate: float | None
    catch_rate_denominator: int
    false_positive_rate: float | None
    false_positive_rate_denominator: int
    stop_precision: float | None
    stop_precision_denominator: int
    stopped: int


class Value(Strict):
    protected_bdt: int
    friction_bdt: int
    currency: str


class Day(Strict):
    day: str
    scored: int
    stopped: int


class Replay(Strict):
    denominator: int
    denominator_label: str
    mix: dict[str, int]
    bands: dict[str, int]
    codes: dict[str, int]
    cooccurrence: dict[str, int]
    codes_that_cannot_fire: list[str]
    codes_that_cannot_fire_reason: str
    codes_that_cannot_fire_reason_bn: str
    confusion: dict[str, int]
    rates: Rates
    value: Value
    histogram: list[int]
    histogram_edges: list[float]
    daily: list[Day]
    badge: Badge


class Gate(Strict):
    id: str
    title: str
    title_bn: str
    sees: str
    owner_ticket: str | None
    status: str
    badge: Badge
    note: str
    note_bn: str
    volume: int | None
    caught: int | None
    volume_label: str | None = None
    caught_label: str | None = None
    volume_label_bn: str | None = None
    caught_label_bn: str | None = None


class Target(Strict):
    id: str
    label: str
    label_bn: str
    target: str
    target_bn: str
    value: float | None
    unit: str | None
    badge: Badge
    why: str
    why_bn: str


class Shap(Strict):
    feature: str
    value: float
    contribution: float
    direction: Literal["up", "down"]


class BoardRow(Strict):
    acct: str
    probability: float
    role: str | None
    typology: str | None
    ring: str | None
    shap: list[Shap]


class BoardMeta(Strict):
    scored: int
    at_or_above_hold_threshold: int
    hold_threshold: float
    sample_seed: int
    model_version: str | None
    badge: Badge


class Model(Strict):
    id: str
    badge: Badge
    version: str | None = None
    headline: str | None = None
    gates_passed: bool | None = None
    gates_detail: dict[str, bool] | None = None
    per_segment: dict[str, float] | None = None
    per_segment_label: str | None = None
    eval: str | None = None
    generated_at: str | None = None
    note: str | None = None
    cost_usd: float | None = None


class PolicyCheck(Strict):
    id: str
    statement: str
    statement_bn: str
    ok: bool
    evidence: str
    evidence_bn: str
    source: str


class WeakestLink(Strict):
    typology: str | None
    ring_recall: float | None
    stubs: list[str]
    gates_not_built: list[str]
    sentence: str
    sentence_bn: str


class Overview(Strict):
    generated_at: str
    window: Window
    source: Source
    world: WorldCounts
    replay: Replay
    gates: list[Gate]
    targets: list[Target]
    mule_board: list[BoardRow]
    mule_board_meta: BoardMeta
    models: list[Model]
    policy: list[PolicyCheck]
    weakest_link: WeakestLink


class AccountTxn(Strict):
    txn_id: str
    ts: str
    type: str
    amount_bdt: float
    counterparty: str
    direction: Literal["in", "out"]
    channel: str
    ring_id: str | None


class AccountLabel(Strict):
    ring_id: str
    role: str
    typology: str
    first_bad_ts: str | None


class AccountMule(Strict):
    known: bool
    probability: float
    model_version: str
    as_of: str | None
    reasons: list[Shap]


class Account(Strict):
    acct_id: str
    kind: str
    district: str
    opened_at: str
    status: str
    owner: dict[str, Any] | None
    mule: AccountMule | None
    label: AccountLabel | None
    transactions: list[AccountTxn]
    transactions_truncated: bool
    transaction_count: int
    devices: list[str]
    shared_device_accounts: list[str]
    sim_events: list[dict[str, Any]]
    badge: Badge
    synthetic: bool


class Health(Strict):
    status: str
    service: str
    version: str
    upstream: str
    fixture_generated_at: str | None
    synthetic: bool


# --- the Incidents view: fixtures/campaigns.json -------------------------------------------
#
# Field names are the radar's own (libs/radar/bhorosha_radar: Incident, Firing, Campaign, Attempt),
# so the console and the producer read the same words. Every timestamp carries +06:00: the builder
# appends it to the radar's naive Asia/Dhaka strings.

Decision = Literal["allow", "step_up", "delay", "hold", "block"]
IncidentClass = Literal["benign_only", "mixed", "fraud_dominant"]


class RadarIncident(Strict):
    incident_id: str
    key: str
    cell: str
    window_min: int
    opened_at: str
    last_fired_at: str
    observed: int
    expected: float
    p_value: float
    surprise: float
    reason: str
    firing_runs: list[str]
    baseline_source: str
    payday_factor: float
    attempt_ids: list[str]
    held: int
    allowed: int


class RadarFiring(Strict):
    """One run's snapshot of one cell. Counts only; the incident holds the attempt ids."""

    run_ts: str
    key: str
    cell: str
    window_min: int
    k: int
    mu: float
    p: float
    surprise: float
    reason: str
    baseline_source: str
    payday_factor: float
    attempts: int
    held: int
    allowed: int


class PayeeLink(Strict):
    payee: str
    entity: str
    kind: str


class SharedEntity(Strict):
    """An entity two or more of a campaign's payees share as of the campaign (payee_links, grouped)."""

    entity: str
    kind: str
    payees: list[str]
    in_evidence: bool


class RadarCampaign(Strict):
    campaign_id: str
    opened_at: str
    as_of: str
    attempt_ids: list[str]
    senders: list[str]
    payees: list[str]
    tills: list[str]
    incident_ids: list[str]
    held: int
    allowed: int
    allowed_bdt: float
    synchrony: float
    concentration: float
    rank_score: float
    evidence: list[tuple[str, str, str]]
    payee_links: list[PayeeLink]
    shared_entities: list[SharedEntity]
    superseded_by: str | None


class CampaignAttempt(Strict):
    """An attempt as the radar saw it, enriched as of its own timestamp. No label rides along."""

    attempt_id: str
    ts: str
    sender: str
    payee: str | None
    amount_bdt: float
    decision: Decision
    sender_district: str | None
    payee_district: str | None
    payee_onboarding_agent: str | None
    payee_devices: list[str]
    payee_sim_day: str | None
    payee_till: str | None
    payee_next_hops: list[str]


class EvalMeasure(Strict):
    value: float | None
    target: str
    status: str
    evaluated: list[str] | None = None
    outside_stream: list[str] | None = None
    reason: str | None = None


class EvalCampaign(Strict):
    """campaign.json's row for one true campaign; joined to the radar by detected_campaign_id."""

    campaign_id: str
    detected_campaign_id: str | None
    flag_ts: str | None
    tenth_ts: str | None
    time_to_flag_min: float | None
    allowed_by_flag: float | None
    cashed_out_by_flag: float | None
    retained_by_flag: float | None
    retained_fraction: float | None
    future_allowed_after_flag: float | None
    precision: float | None
    recall: float | None
    victim_coverage: float | None
    payees_found: int | None
    payees_named: int | None
    payees_total: int | None
    payee_overreach: str | None


class EvalIncidentClass(Strict):
    incident_id: str
    incident_class: IncidentClass


class CampaignEvaluation(Strict):
    """Outcomes against generated truth. Display only; never an input to detection or ranking."""

    source: str
    generated_at: str | None
    seed_checksum: str | None
    config: dict[str, Any]
    measures: dict[str, EvalMeasure]
    caveat: str | None
    payee_note: str | None
    incident_classes: dict[str, int]
    incidents: list[EvalIncidentClass]
    campaigns: list[EvalCampaign]


class CampaignsSource(Strict):
    seed_dir: str
    seed_checksum: str | None
    input_checksums: dict[str, str]
    eval_file: str
    eval_sha256: str | None
    producer: str
    timezone: str
    synthetic: bool


class CampaignsFixture(Strict):
    """The whole of fixtures/campaigns.json, as tools/build_campaigns.py writes it."""

    generated_at: str
    source: CampaignsSource
    incidents: list[RadarIncident]
    firings: list[RadarFiring]
    campaigns: list[RadarCampaign]
    attempts: list[CampaignAttempt]
    evaluation: CampaignEvaluation | None


class CampaignsList(Strict):
    """GET /v1/admin/campaigns: the incident rail and the campaign table."""

    available: bool
    reason: str | None = None
    generated_at: str | None = None
    source: CampaignsSource | None = None
    incidents: list[RadarIncident] = []
    campaigns: list[RadarCampaign] = []
    evaluation: CampaignEvaluation | None = None


class CampaignIncident(Strict):
    """GET /v1/admin/campaigns/{incident_id}: what the map, timeline and graph draw for one incident."""

    available: bool
    reason: str | None = None
    incident: RadarIncident | None = None
    campaigns: list[RadarCampaign] = []
    firings: list[RadarFiring] = []
    attempts: list[CampaignAttempt] = []


# --- the cash-out view: fixtures/cashout.json ----------------------------------------------
#
# Written by tools/build_cashout.py from the radar's common point of cash-out rules over the campaign world. Field
# names are the radar's own (libs/radar/bhorosha_radar/cashout_rules.py: TillFlag, Cluster, Candidate), except a
# till's and a flag's `id`. Every timestamp carries +06:00; a day is the date of its 00:00 run, which closes the day
# before. Only `evaluation` knows who was a mule.

CashoutKind = Literal["seed", "candidate", "ordinary"]
CandidateFilter = Literal["first_time_senders", "pass_through"]
ClusterMode = Literal["replay", "live"]
CandidateOutcome = Literal["mule", "not_mule"]


class CashoutTill(Strict):
    id: str
    district: str | None
    lat: float
    lon: float
    opened: str | None


class CashoutTillFlag(Strict):
    """More confirmed mules cashed out at this till in the reuse window than its own volume predicts."""

    id: str
    seed_accounts: list[str]
    accounts: int
    expected: float
    p_value: float
    first_seen_ts: str
    last_seed_ts: str


class CashoutDay(Strict):
    """One daily run, as of 00:00 on `date`."""

    date: str
    as_of: str
    seeds: int
    open_tills: int
    cashouts: int
    till_flags: list[CashoutTillFlag]
    clusters: list[str]
    candidates: int
    not_flagged: dict[str, int]


class CashoutCandidate(Strict):
    """A lead for an analyst, once per filter, as the first run that named it saw it. Never a verdict."""

    acct: str
    till: str
    ts: str
    amount_bdt: float
    filter: CandidateFilter
    source: str
    first_time_senders: int
    new_counterparties: int
    received_bdt: float
    cashed_out_bdt: float
    pass_through_share: float | None
    first_day: str
    days: list[str]


class CashoutHeldBack(Strict):
    accounts: int
    by_reason: dict[str, int]


class CashoutPoint(Strict):
    """One cash-out at its till, located as of the moment."""

    txn_id: str
    ts: str
    acct: str
    till: str
    lat: float
    lon: float
    amount_bdt: float


class CashoutEvent(CashoutPoint):
    kind: CashoutKind


class CashoutCluster(Strict):
    """A space-time circle of confirmed-mule cash-outs, frozen when it opened; `replay` looks back at days past."""

    cluster_id: str
    mode: ClusterMode
    first_day: str
    days: list[str]
    opened_at: str
    centre_lat: float
    centre_lon: float
    radius_km: float
    window_start: str
    window_end: str
    tills: list[str]
    seed_cashouts: list[CashoutPoint]
    other_cashouts: list[CashoutPoint]
    observed: int
    expected: float
    p_value: float
    baseline_source: str


class CashoutEvalCandidate(Strict):
    acct: str
    filter: CandidateFilter
    first_day: str
    outcome: CandidateOutcome
    labelled: str
    confirmed_at: str | None
    lead_days: float | None


class CashoutEvaluation(Strict):
    """cashout.json's seed_campaign world against generated truth. Display only; never an input to the rules."""

    source: str
    generated_at: str | None
    world: str
    seed_checksum: str | None
    config: dict[str, Any]
    caveat: str | None
    measures: dict[str, Any]
    candidates: list[CashoutEvalCandidate]


class CashoutSource(CampaignsSource):
    """The inputs fixtures/cashout.json was built from, with their checksums."""


class CashoutFixture(Strict):
    """The whole of fixtures/cashout.json, as tools/build_cashout.py writes it."""

    generated_at: str
    source: CashoutSource
    config: dict[str, Any]
    tills: list[CashoutTill]
    days: list[CashoutDay]
    candidates: list[CashoutCandidate]
    not_flagged: dict[str, CashoutHeldBack]
    clusters: list[CashoutCluster]
    events: dict[str, list[CashoutEvent]]
    evaluation: CashoutEvaluation | None


class CashoutView(Strict):
    """GET /v1/admin/cashout: the whole fixture."""

    available: bool
    reason: str | None = None
    generated_at: str | None = None
    source: CashoutSource | None = None
    config: dict[str, Any] = {}
    tills: list[CashoutTill] = []
    days: list[CashoutDay] = []
    candidates: list[CashoutCandidate] = []
    not_flagged: dict[str, CashoutHeldBack] = {}
    clusters: list[CashoutCluster] = []
    events: dict[str, list[CashoutEvent]] = {}
    evaluation: CashoutEvaluation | None = None


class CashoutDayView(Strict):
    """GET /v1/admin/cashout/day/{date}: what one day's map draws."""

    available: bool
    reason: str | None = None
    date: str | None = None
    as_of: str | None = None
    seeds: int | None = None
    cashouts: int | None = None
    tills: list[CashoutTill] = []
    till_flags: list[CashoutTillFlag] = []
    clusters: list[CashoutCluster] = []
    candidates: list[CashoutCandidate] = []
    not_flagged: dict[str, int] = {}
    events: list[CashoutEvent] = []
