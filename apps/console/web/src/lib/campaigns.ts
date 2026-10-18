/**
 * The Incidents view's shapes and the pure joins it draws from.
 *
 * Hand-mirrored from api/schemas.py (RadarIncident, RadarFiring, RadarCampaign, CampaignAttempt,
 * CampaignEvaluation), whose field names are the radar's own. Everything below is a pure function of
 * the fixture, so the screen never invents a figure: every label is read from the data.
 *
 * Time: the builder appends +06:00 to the radar's naive Asia/Dhaka strings, and `instant` still reads
 * any offset-less string as Asia/Dhaka. `new Date(naive)` would read it as the viewer's local time,
 * which on a laptop in Dhaka looks right and on the judges' laptops does not.
 */

import type { Decision } from './types'

export interface RadarIncident {
  incident_id: string
  key: string
  cell: string
  window_min: number
  opened_at: string
  last_fired_at: string
  observed: number
  expected: number
  p_value: number
  surprise: number
  reason: string
  firing_runs: string[]
  baseline_source: string
  payday_factor: number
  attempt_ids: string[]
  held: number
  allowed: number
}

export interface RadarFiring {
  run_ts: string
  key: string
  cell: string
  window_min: number
  k: number
  mu: number
  p: number
  surprise: number
  reason: string
  baseline_source: string
  payday_factor: number
  attempts: number
  held: number
  allowed: number
}

export interface SharedEntity {
  entity: string
  kind: string
  payees: string[]
  in_evidence: boolean
}

export type EvidenceTriple = [string, string, string]

export interface RadarCampaign {
  campaign_id: string
  opened_at: string
  as_of: string
  attempt_ids: string[]
  senders: string[]
  payees: string[]
  tills: string[]
  incident_ids: string[]
  held: number
  allowed: number
  allowed_bdt: number
  synchrony: number
  concentration: number
  rank_score: number
  evidence: EvidenceTriple[]
  payee_links: { payee: string; entity: string; kind: string }[]
  shared_entities: SharedEntity[]
  superseded_by: string | null
}

export interface CampaignAttempt {
  attempt_id: string
  ts: string
  sender: string
  payee: string | null
  amount_bdt: number
  decision: Decision
  sender_district: string | null
  payee_district: string | null
  payee_onboarding_agent: string | null
  payee_devices: string[]
  payee_sim_day: string | null
  payee_till: string | null
  payee_next_hops: string[]
}

export interface EvalMeasure {
  value: number | null
  target: string
  status: string
  evaluated?: string[] | null
  outside_stream?: string[] | null
  reason?: string | null
}

export interface EvalCampaign {
  campaign_id: string
  detected_campaign_id: string | null
  flag_ts: string | null
  tenth_ts: string | null
  time_to_flag_min: number | null
  allowed_by_flag: number | null
  cashed_out_by_flag: number | null
  retained_by_flag: number | null
  retained_fraction: number | null
  future_allowed_after_flag: number | null
  precision: number | null
  recall: number | null
  victim_coverage: number | null
  payees_found: number | null
  payees_named: number | null
  payees_total: number | null
  payee_overreach: string | null
}

export type IncidentClass = 'benign_only' | 'mixed' | 'fraud_dominant'

export interface CampaignEvaluation {
  source: string
  generated_at: string | null
  seed_checksum: string | null
  config: Record<string, unknown>
  measures: Record<string, EvalMeasure>
  caveat: string | null
  payee_note: string | null
  incident_classes: Record<string, number>
  incidents: { incident_id: string; incident_class: IncidentClass }[]
  campaigns: EvalCampaign[]
}

export interface CampaignsSource {
  seed_dir: string
  seed_checksum: string | null
  input_checksums: Record<string, string>
  eval_file: string
  eval_sha256: string | null
  producer: string
  timezone: string
  synthetic: boolean
}

export interface CampaignsList {
  available: boolean
  reason?: string | null
  generated_at?: string | null
  source?: CampaignsSource | null
  incidents: RadarIncident[]
  campaigns: RadarCampaign[]
  evaluation?: CampaignEvaluation | null
}

export interface CampaignIncident {
  available: boolean
  reason?: string | null
  incident?: RadarIncident | null
  campaigns: RadarCampaign[]
  firings: RadarFiring[]
  attempts: CampaignAttempt[]
}

/* --- time ---------------------------------------------------------------- */

export const DHAKA_OFFSET = '+06:00'
const HAS_OFFSET = /(Z|[+-]\d\d:\d\d)$/

export const withOffset = (ts: string): string => (HAS_OFFSET.test(ts) ? ts : ts + DHAKA_OFFSET)
export const instant = (ts: string): number => new Date(withOffset(ts)).getTime()

const clock = new Intl.DateTimeFormat('en-GB', { timeZone: 'Asia/Dhaka', hour: '2-digit', minute: '2-digit', hour12: false })
const clockSeconds = new Intl.DateTimeFormat('en-GB', {
  timeZone: 'Asia/Dhaka', hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false,
})
const calendar = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Dhaka', year: 'numeric', month: '2-digit', day: '2-digit' })

export const hm = (ts: string): string => clock.format(instant(ts))
export const hms = (ts: string): string => clockSeconds.format(instant(ts))
export const dateOf = (ts: string): string => calendar.format(instant(ts))
/** "2026-11-06 14:30 +06:00": every time this view prints says which clock it is on. */
export const stamp = (ts: string): string => `${dateOf(ts)} ${hm(ts)} ${DHAKA_OFFSET}`

/* --- numbers ------------------------------------------------------------- */

/** Expected counts run from 1e-5 to tens; fixed decimals would print most of them as 0.00. */
export const fmtCount = (value: number): string =>
  value >= 10 ? value.toFixed(1) : value >= 0.01 ? value.toFixed(2) : value.toExponential(1)

export const surpriseExponent = (surprise: number): string => surprise.toFixed(2)

export function pParts(p: number): [string, string] {
  const [mantissa = '0', exponent = '0'] = p.toExponential(2).split('e')
  return [mantissa, String(Number(exponent))]
}

/* --- joins --------------------------------------------------------------- */

export type RankBy = 'surprise' | 'retained'

export const evalFor = (campaignId: string | null, evaluation: CampaignEvaluation | null | undefined): EvalCampaign | null =>
  campaignId && evaluation ? evaluation.campaigns.find((row) => row.detected_campaign_id === campaignId) ?? null : null

/** Every snapshot holding the incident, in id order. The view never silently picks one. */
export const campaignsHolding = (incidentId: string, campaigns: RadarCampaign[]): RadarCampaign[] =>
  campaigns.filter((c) => c.incident_ids.includes(incidentId)).sort((a, b) => a.campaign_id.localeCompare(b.campaign_id))

/** The one current campaign holding the incident, or null when there is none or a real choice. */
export function soleCampaign(holding: RadarCampaign[]): string | null {
  const current = holding.filter((c) => c.superseded_by === null)
  return current.length === 1 ? current[0]!.campaign_id : null
}

const bySurprise = (a: RadarIncident, b: RadarIncident): number =>
  b.surprise - a.surprise || instant(b.opened_at) - instant(a.opened_at) || a.incident_id.localeCompare(b.incident_id)

/** Retained at the flag over the incident's current campaigns: eval-only, unknown sorts last. */
export function retainedFor(incident: RadarIncident, campaigns: RadarCampaign[], evaluation: CampaignEvaluation | null | undefined): number | null {
  const values = campaignsHolding(incident.incident_id, campaigns)
    .filter((c) => c.superseded_by === null)
    .map((c) => evalFor(c.campaign_id, evaluation)?.retained_by_flag)
    .filter((v): v is number => typeof v === 'number')
  return values.length ? Math.max(...values) : null
}

export function rankIncidents(
  incidents: RadarIncident[],
  rankBy: RankBy,
  campaigns: RadarCampaign[],
  evaluation: CampaignEvaluation | null | undefined,
): RadarIncident[] {
  if (rankBy === 'surprise') return [...incidents].sort(bySurprise)
  const money = new Map(incidents.map((i) => [i.incident_id, retainedFor(i, campaigns, evaluation)]))
  return [...incidents].sort((a, b) => {
    const left = money.get(a.incident_id) ?? null
    const right = money.get(b.incident_id) ?? null
    if (left === null && right !== null) return 1
    if (right === null && left !== null) return -1
    return (right ?? 0) - (left ?? 0) || bySurprise(a, b)
  })
}

export const byTime = (a: CampaignAttempt, b: CampaignAttempt): number =>
  instant(a.ts) - instant(b.ts) || a.attempt_id.localeCompare(b.attempt_id)

/* --- evidence ------------------------------------------------------------ */

export const ENTITY_ORDER = ['payee_onboarding_agent', 'payee_till', 'payee_sim_day', 'payee_device', 'payee'] as const

export interface LinkingEntity {
  entity: string
  kind: string
  value: string
  payees: string[]
  triples: [string, string][]
  inEvidence: boolean
}

const kindRank = (kind: string): number => {
  const index = (ENTITY_ORDER as readonly string[]).indexOf(kind)
  return index < 0 ? ENTITY_ORDER.length : index
}

const split = (entity: string): [string, string] => {
  const at = entity.indexOf(':')
  return at < 0 ? [entity, ''] : [entity.slice(0, at), entity.slice(at + 1)]
}

/**
 * The entities the graph may draw. Evidence first: each triple joins the payees of its two attempts
 * to the entity it names. A `payee:` triple between two attempts to the same payee only says they are
 * the same payee, so it adds no node. Then the shared entities no triple needed, marked as such.
 */
export function linkingEntities(campaign: RadarCampaign, payeeOf: Map<string, string | null>): LinkingEntity[] {
  const found = new Map<string, LinkingEntity>()
  for (const [source, target, entity] of campaign.evidence) {
    const left = payeeOf.get(source) ?? null
    const right = payeeOf.get(target) ?? null
    const [kind, value] = split(entity)
    if (kind === 'payee' && left === right) continue
    const entry = found.get(entity) ?? { entity, kind, value, payees: [], triples: [], inEvidence: true }
    for (const payee of [left, right]) if (payee && !entry.payees.includes(payee)) entry.payees.push(payee)
    entry.triples.push([source, target])
    found.set(entity, entry)
  }
  for (const shared of campaign.shared_entities) {
    if (found.has(shared.entity) || shared.in_evidence) continue
    const [kind, value] = split(shared.entity)
    found.set(shared.entity, { entity: shared.entity, kind, value, payees: [...shared.payees], triples: [], inEvidence: false })
  }
  return [...found.values()].sort((a, b) => Number(b.inEvidence) - Number(a.inEvidence) || kindRank(a.kind) - kindRank(b.kind) || a.entity.localeCompare(b.entity))
}

export function entityCounts(evidence: EvidenceTriple[]): [string, number][] {
  const counts = new Map<string, number>()
  for (const [, , entity] of evidence) counts.set(entity, (counts.get(entity) ?? 0) + 1)
  return [...counts.entries()].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
}

/** Each payee's latest attempt in the campaign: its entities as of the last time anyone paid it. */
export function payeeProfiles(campaign: RadarCampaign, attempts: Map<string, CampaignAttempt>): Map<string, CampaignAttempt> {
  const latest = new Map<string, CampaignAttempt>()
  for (const id of campaign.attempt_ids) {
    const attempt = attempts.get(id)
    if (!attempt?.payee) continue
    const seen = latest.get(attempt.payee)
    if (!seen || byTime(seen, attempt) < 0) latest.set(attempt.payee, attempt)
  }
  return latest
}

/* --- eval measures, read the way the model cards read status -------------- */

export const MEASURE_TONE: Record<string, string> = { pass: 'good', fail: 'bad', missing: 'muted', 'n/a': 'muted' }

export const measureLabel = (status: string): string =>
  status === 'pass' || status === 'fail' || status === 'n/a' ? status : 'NO DATA'

export type GateState = { state: 'none' | 'failed' | 'unmeasured' | 'passed'; names: string[]; total: number }

/** Like a model card's gates_passed: a missing measure is never counted as a pass. */
export function gateState(measures: Record<string, EvalMeasure>): GateState {
  const rows = Object.entries(measures)
  const failed = rows.filter(([, m]) => m.status === 'fail').map(([name]) => name)
  const unmeasured = rows.filter(([, m]) => !['pass', 'fail', 'n/a'].includes(m.status)).map(([name]) => name)
  if (!rows.length) return { state: 'none', names: [], total: 0 }
  if (failed.length) return { state: 'failed', names: failed, total: rows.length }
  if (unmeasured.length) return { state: 'unmeasured', names: unmeasured, total: rows.length }
  return { state: 'passed', names: [], total: rows.length }
}

/* --- local export -------------------------------------------------------- */

const quote = (value: unknown): string => {
  const text = String(value ?? '')
  // A cell starting with = + - @ is a formula to a spreadsheet; prefix it so it stays text.
  const safe = /^[=+\-@]/.test(text) ? `'${text}` : text
  return `"${safe.replace(/"/g, '""')}"`
}

export function attemptsCsv(attempts: CampaignAttempt[]): string {
  const columns = ['attempt_id', 'ts', 'sender', 'payee', 'amount_bdt', 'decision'] as const
  const rows = attempts.map((a) => columns.map((key) => quote(key === 'ts' ? withOffset(a.ts) : a[key])).join(','))
  return [columns.join(','), ...rows].join('\n') + '\n'
}

export function download(name: string, body: string, type: string): void {
  const link = document.createElement('a')
  link.href = URL.createObjectURL(new Blob([body], { type }))
  link.download = name
  link.click()
  URL.revokeObjectURL(link.href)
}
