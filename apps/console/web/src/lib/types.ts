/**
 * The shapes the admin service sends.
 *
 * Hand-mirrored from api/schemas.py rather than generated, because generating from OpenAPI is a
 * build step we do not need yet for twelve types. The service's models are strict, so a field
 * renamed there fails its own tests before it reaches here.
 */

/* LIVE is the audit stream: not one detector's output but a record of what the service did,
   carrying rule decisions, Gemini scam turns and the app classifier side by side. */
export type Badge = 'MODEL' | 'RULE' | 'STUB' | 'OFF' | 'NONE' | 'NO DATA' | 'SYNTHETIC' | 'LIVE'
export type Decision = 'allow' | 'step_up' | 'delay' | 'hold' | 'block'
export type Band = 'low' | 'medium' | 'high' | 'critical'

export interface Rates {
  catch_rate: number | null
  catch_rate_denominator: number
  false_positive_rate: number | null
  false_positive_rate_denominator: number
  stop_precision: number | null
  stop_precision_denominator: number
  stopped: number
}

export interface Replay {
  denominator: number
  denominator_label: string
  mix: Record<string, number>
  bands: Record<string, number>
  codes: Record<string, number>
  cooccurrence: Record<string, number>
  codes_that_cannot_fire: string[]
  codes_that_cannot_fire_reason: string
  codes_that_cannot_fire_reason_bn: string
  confusion: Record<string, number>
  rates: Rates
  value: { protected_bdt: number; friction_bdt: number; currency: string }
  histogram: number[]
  histogram_edges: number[]
  daily: { day: string; scored: number; stopped: number }[]
  badge: Badge
}

export interface Gate {
  id: string
  title: string
  title_bn: string
  sees: string
  owner_ticket: string | null
  status: string
  badge: Badge
  note: string
  note_bn: string
  volume: number | null
  caught: number | null
  volume_label?: string | null
  caught_label?: string | null
  volume_label_bn?: string | null
  caught_label_bn?: string | null
}

export interface Target {
  id: string
  label: string
  label_bn: string
  target: string
  target_bn: string
  value: number | null
  unit: string | null
  badge: Badge
  why: string
  why_bn: string
}

export interface Shap {
  feature: string
  value: number
  contribution: number
  direction: 'up' | 'down'
}

export interface BoardRow {
  acct: string
  probability: number
  role: string | null
  typology: string | null
  ring: string | null
  shap: Shap[]
}

export interface BoardMeta {
  scored: number
  at_or_above_hold_threshold: number
  hold_threshold: number
  sample_seed: number
  model_version: string
  /** The case that named this payee, when one did. */
  watchlisted: string | null | null
  badge: Badge
}

export interface ModelRow {
  id: string
  badge: Badge
  version?: string | null
  headline?: string | null
  gates_passed?: boolean | null
  gates_detail?: Record<string, boolean> | null
  per_segment?: Record<string, number> | null
  per_segment_label?: string | null
  eval?: string | null
  generated_at?: string | null
  note?: string | null
  cost_usd?: number | null
}

export interface PolicyCheck {
  id: string
  statement: string
  statement_bn: string
  ok: boolean
  evidence: string
  evidence_bn: string
  source: string
}

export interface Overview {
  generated_at: string
  window: { from: string; to: string; tz: string; days: number }
  source: {
    seed_dir: string
    checksum: string | null
    service: string
    model_version: string
    mule_model_version: string | null
    thresholds: Record<string, number>
    synthetic: boolean
  }
  world: Record<string, number | string> & { badge: Badge }
  replay: Replay
  gates: Gate[]
  targets: Target[]
  mule_board: BoardRow[]
  mule_board_meta: BoardMeta
  models: ModelRow[]
  policy: PolicyCheck[]
  weakest_link: {
    typology: string | null
    ring_recall: number | null
    stubs: string[]
    gates_not_built: string[]
    sentence: string
    sentence_bn: string
  }
}

export interface AccountTxn {
  txn_id: string
  ts: string
  type: string
  amount_bdt: number
  counterparty: string
  direction: 'in' | 'out'
  channel: string
  ring_id: string | null
}

export interface Account {
  acct_id: string
  kind: string
  district: string
  opened_at: string
  status: string
  owner: Record<string, unknown> | null
  mule: { known: boolean; probability: number; model_version: string; as_of: string | null; reasons: Shap[] } | null
  label: { ring_id: string; role: string; typology: string; first_bad_ts: string | null } | null
  transactions: AccountTxn[]
  transactions_truncated: boolean
  transaction_count: number
  devices: string[]
  shared_device_accounts: string[]
  sim_events: Record<string, unknown>[]
  badge: Badge
  synthetic: boolean
}

/** risk-mw's own shapes, for the live panel. */
export interface RiskMwHealth {
  status: string
  service: string
  model_version: string
  demo_mode: boolean
}

export interface MuleScore {
  acct_id: string
  known: boolean
  probability: number
  reasons: Shap[]
  model_version: string
  as_of: string | null
}

export interface CaseReport {
  case_id: string
  acct_id: string
  status: 'queued' | 'running' | 'done' | 'degraded' | 'failed'
  summary_en: string
  summary_bn: string
  evidence: { row_id: string; claim: string }[]
  ring: string[]
  confidence: number
  recommended_action: string
  model_version: string
  redacted?: boolean
  validation_errors?: string[]
  limitations?: string
}

export interface TraceEvent {
  step: 'plan' | 'tool' | 'evidence' | 'error' | 'done'
  text?: string
  name?: string
  args?: Record<string, unknown>
  row_id?: string
  confidence?: number
}

/* --- Case Zero, read through this service because it sends no CORS headers --- */

export interface CaseZeroHealth {
  reachable: boolean
  ok?: boolean
  llm_ready?: boolean
  model?: string
  cases?: number
  error?: string
}

export interface WatchlistPayee {
  acct_id: string
  status: string
  case_id: string
  role: string
  model_score: number
  as_of: string
  analyst_approved: boolean
  facts: string[]
  payments_to_this_payee: number
  stopped_by_rules: number
  amount_bdt: number
}

export interface Watchlist {
  version: string
  generated_at: string
  payees: WatchlistPayee[]
  gap: {
    watchlisted_accounts: number
    payments_to_watchlisted: number
    stopped_by_rules: number
    missed: number
    amount_bdt: number
    stopped_share: number | null
    note: string
    badge: Badge
  }
}

/** Case Zero's own event shapes, kept loose: the Case Zero service owns that contract and it still moves. */
export interface ReplayEvent {
  type: string
  call_id?: string
  name?: string
  args?: Record<string, unknown>
  ok?: boolean
  case_id?: string
  seed?: string
  model?: string
  [key: string]: unknown
}

/* --- the live audit trail ------------------------------------------------ */

export interface AuditRow {
  id: string
  at: string
  kind: string
  uid: string | null
  service: string | null
  model_version: string | null
  processing_ms: number | null
  decision: string | null
  band: string | null
  risk_score: number | null
  reason_codes: string[]
  txn_type: string | null
  amount_bdt: number | null
  to_account: string | null
  session_id: string | null
  flags: string[]
  verdict: string | null
}

/** Gemini's reading of one stored score (GET /v1/admin/audit/{id}/insight). Analysis for the operator, never evidence. */
export interface InsightDriver {
  code: string
  weight: number | null
  reading_en: string
  reading_bn: string
}

export interface AuditInsight {
  available: boolean
  /** Why there is no reading: genai_disabled, spend_cap, timeout, genai_error, invalid, not_a_score, nothing_fired. */
  reason?: string
  insight?: {
    summary_en: string
    summary_bn: string
    drivers: InsightDriver[]
    next_checks: { en: string; bn: string }[]
    caveat_en: string
    caveat_bn: string
  }
  model_id?: string | null
  prompt_version?: string
  cost_usd?: number
  latency_ms?: number
  retried?: boolean
  cached?: boolean
  at?: string
}

export interface AuditPage {
  available: boolean
  error?: string
  rows: AuditRow[]
  facets: Record<string, Record<string, number>>
  window: { returned: number; newest: string | null; oldest: string | null; note: string } | null
  next_before?: string | null
  badge?: Badge
}

/* --- the ring graph, assembled from Case Zero's own tool outputs --------- */

export interface RingNode {
  id: string
  kind: string
  degree: number
  is_seed: boolean
  found_by: string | null
  found_by_tool: string
  role?: string | null
  model_score?: number | null
  case_id?: string | null
  status?: string | null
}

export interface RingEdge {
  source: string
  target: string
  kind: string
  txn_id?: string
  amount_bdt?: number
  ts?: string
  found_by: string | null
  found_by_tool: string
}

export interface RingGraphData {
  case_id: string
  seed: string
  as_of: string
  model: string
  nodes: RingNode[]
  edges: RingEdge[]
  calls: { call_id: string | null; tool: string; ok: boolean; at_s: number; added_nodes: number; added_edges: number }[]
  counts: {
    nodes: number
    edges: number
    money_edges: number
    money_bdt: number
    watchlisted: number
    tool_calls: number
  }
  source: string
  badge: Badge
}


/* --- the architecture map ------------------------------------------------ */

export interface SystemBox {
  id: string
  name: string
  name_bn: string
  what: string
  what_bn: string
  where: string
  badge: Badge
}

export interface SystemLink {
  from: string
  to: string
  label: string
  label_bn: string
}

export interface ModelInPlay {
  id: string
  inside: string
  job: string
  job_bn: string
  version: string | null
  headline: string | null
  badge: Badge
}

export interface Check {
  id: string
  kind: 'model' | 'module'
  label: string
  asks: string
  asks_bn: string
  badge: Badge
  version: string | null
}

export interface JourneyStep {
  step: number
  title: string
  title_bn: string
  plain: string
  plain_bn: string
  route: string
  module: string
}

export interface RouterInfo {
  id: string
  file: string
  prefix: string
  routes: { method: string; path: string }[]
  reaches: string[]
}

export interface ModuleInfo {
  id: string
  file: string
  lines: number
  reaches: string[]
}

export interface Architecture {
  available: boolean
  systems: SystemBox[]
  links: SystemLink[]
  journey: JourneyStep[]
  models: ModelInPlay[]
  checks: Check[]
  risk_mw: {
    routers: RouterInfo[]
    modules: ModuleInfo[]
    counts: {
      routers: number
      routes: number
      modules: number
      reaching_gemini: number
      reaching_firestore: number
    }
  }
  badge: Badge
  source: string
}


/* --- scenarios, scored by the real engine -------------------------------- */

export interface ScenarioCheck {
  id: string
  label: string
  reads: string
  /** `raised` made a code fire, `clear` looked and was satisfied, `off` could not look. */
  verdict: 'raised' | 'clear' | 'off'
  code: string | null
  weight: number | null
  /** The comparison it concluded from, with the engine's own threshold. */
  test: string
}

export interface ScenarioHit {
  code: string
  weight: number
  decision: string
  text_bn: string
  text_en: string
}

export interface Scenario {
  id: string
  name: string
  name_bn: string
  story: string
  story_bn: string
  txn: { type: string; amount_bdt: number; to_account: string; is_new_payee: boolean }
  checks: ScenarioCheck[]
  hits: ScenarioHit[]
  decision: string
  band: string
  risk_score: number
  model_version: string
  /** The case that named this payee, when one did. */
  watchlisted: string | null
}

/* --- Case Zero: the case file ---------------------------------------------
 * One investigation as an analyst reads it (`/v1/admin/casezero/case/{id}/file`, `/replay/file`): the service
 * shapes Case Zero's report and events into this, with labels in both languages for Case Zero's codes. */

export interface Bilingual {
  en: string
  bn: string
}

/** A tool call a claim rests on: `tc_07` and the tool that ran (`shared_entities`); null when unknown. */
export interface CaseCite {
  call_id: string
  tool: string | null
}

export interface CaseFile {
  case_id: string
  seed: string | null
  as_of: string | null
  status: string | null
  source: 'live' | 'recorded'
  model_version: string | null
  decision: {
    action: string | null
    action_label: Bilingual | null
    floor_action: string | null
    floor_action_label: Bilingual | null
    proposed_action: string | null
    proposed_action_label: Bilingual | null
    band: string | null
    model_score: number | null
    escalated: boolean | null
    review_note: string | null
  }
  typology: string | null
  typology_label: Bilingual | null
  members: { acct_id: string; role: string; role_label: Bilingual | null; evidence: CaseCite[] }[]
  excluded: { acct_id: string; reason: string; evidence: CaseCite[] }[]
  red_flags: { code: string; meaning: Bilingual | null; text: string; evidence: CaseCite[] }[]
  timeline: { ts: string; text: string; evidence: CaseCite[] }[]
  narrative: Bilingual
  limitations: string | null
  model_reasons: { feature: string; value?: number; contribution?: number; direction?: string }[]
  checks: {
    citations_passed_first_time: boolean | null
    retried: boolean
    flags_dropped: unknown[]
    members_kept: number
    moved_to_excluded: string[]
  }
  run: {
    model: string | null
    tool_calls: number | null
    turns: number | null
    tokens_in: number | null
    tokens_out: number | null
    cost_usd: number | null
    llm_ms: number | null
    seconds: number | null
  }
  calls: { call_id: string; tool: string | null; args: Record<string, unknown> }[]
}

/* --- the cash-out view: fixtures/cashout.json ------------------- */
/* Hand-mirrored from api/schemas.py (Cashout*). Field names are the radar's own; every timestamp
   carries +06:00; a day is the date of its 00:00 run, which closes the day before. Only
   `evaluation` knows who was a mule. */

export type CashoutKind = 'seed' | 'candidate' | 'ordinary'
export type CashoutFilter = 'first_time_senders' | 'pass_through'

export interface CashoutTill {
  id: string
  district: string | null
  lat: number
  lon: number
  opened: string | null
}

export interface CashoutTillFlag {
  id: string
  seed_accounts: string[]
  accounts: number
  expected: number
  p_value: number
  first_seen_ts: string
  last_seed_ts: string
}

export interface CashoutDay {
  date: string
  as_of: string
  seeds: number
  open_tills: number
  cashouts: number
  till_flags: CashoutTillFlag[]
  clusters: string[]
  candidates: number
  not_flagged: Record<string, number>
}

export interface CashoutCandidate {
  acct: string
  till: string
  ts: string
  amount_bdt: number
  filter: CashoutFilter
  source: string
  first_time_senders: number
  new_counterparties: number
  received_bdt: number
  cashed_out_bdt: number
  pass_through_share: number | null
  first_day: string
  days: string[]
}

export interface CashoutPoint {
  txn_id: string
  ts: string
  acct: string
  till: string
  lat: number
  lon: number
  amount_bdt: number
}

export interface CashoutEvent extends CashoutPoint {
  kind: CashoutKind
}

export interface CashoutCluster {
  cluster_id: string
  mode: 'replay' | 'live'
  first_day: string
  days: string[]
  opened_at: string
  centre_lat: number
  centre_lon: number
  radius_km: number
  window_start: string
  window_end: string
  tills: string[]
  seed_cashouts: CashoutPoint[]
  other_cashouts: CashoutPoint[]
  observed: number
  expected: number
  p_value: number
  baseline_source: string
}

export interface CashoutEvalCandidate {
  acct: string
  filter: CashoutFilter
  first_day: string
  outcome: 'mule' | 'not_mule'
  labelled: string
  confirmed_at: string | null
  lead_days: number | null
}

/** The measures are the evaluation's own dict; only the fields this view prints are named. */
export interface CashoutMeasures {
  days_run?: number
  last_day?: string | null
  live_clusters?: number
  replayed_clusters?: { clusters: number; events: number }
  till_flags?: { precision: number | null; right: number; scored_till_days: number; base_rate: number | null }
  [key: string]: unknown
}

export interface CashoutEvaluation {
  source: string
  generated_at: string | null
  world: string
  seed_checksum: string | null
  config: Record<string, unknown>
  caveat: string | null
  measures: CashoutMeasures
  candidates: CashoutEvalCandidate[]
}

/** GET /v1/admin/cashout: the whole fixture. */
export interface CashoutWhole {
  available: boolean
  reason?: string | null
  generated_at?: string | null
  config: Record<string, unknown>
  tills: CashoutTill[]
  days: CashoutDay[]
  candidates: CashoutCandidate[]
  not_flagged: Record<string, { accounts: number; by_reason: Record<string, number> }>
  clusters: CashoutCluster[]
  events: Record<string, CashoutEvent[]>
  evaluation: CashoutEvaluation | null
}

/** GET /v1/admin/cashout/day/{date}: what one day's map draws. */
export interface CashoutDayView {
  available: boolean
  reason?: string | null
  date: string | null
  as_of: string | null
  seeds: number | null
  cashouts: number | null
  tills: CashoutTill[]
  till_flags: CashoutTillFlag[]
  clusters: CashoutCluster[]
  candidates: CashoutCandidate[]
  not_flagged: Record<string, number>
  events: CashoutEvent[]
}
