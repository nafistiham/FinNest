/**
 * Everything that talks to a server.
 *
 * Two upstreams, deliberately not proxied through one another: this service for the aggregate, and
 * risk-mw directly for anything live. Proxying risk-mw would put a stale copy of somebody else's
 * contract in our codebase, and the contract is frozen on their side for a reason.
 *
 * Rate discipline, from risk-mw's README: 300 calls a minute per caller across /v1, and 30 a minute
 * per caller on the Gemini routes with a spend ledger behind them. So: health is polled slowly,
 * everything else is a click, and no Gemini route is ever called by a timer.
 */

import { clearSession, session } from './auth'
import type {
  Account,
  Architecture,
  AuditInsight,
  AuditPage,
  CaseFile,
  CaseReport,
  CaseZeroHealth,
  MuleScore,
  Overview,
  ReplayEvent,
  RingGraphData,
  RiskMwHealth,
  Scenario,
  TraceEvent,
  Watchlist,
  CashoutDayView,
  CashoutWhole,
} from './types'
import type { CampaignIncident, CampaignsList } from './campaigns'

// The risk-mw base URL, set at build time with VITE_RISK_MW_URL; a local risk-mw on :8080 otherwise.
// The Live panel can override it per browser.
const RISK_MW_DEFAULT = (import.meta.env.VITE_RISK_MW_URL || 'http://localhost:8080').replace(/\/+$/, '')
const RISK_MW_KEY = 'bhorosha-admin-risk-mw-url'

export const riskMwBase = (): string => {
  try {
    return localStorage.getItem(RISK_MW_KEY) ?? RISK_MW_DEFAULT
  } catch {
    return RISK_MW_DEFAULT
  }
}

export const setRiskMwBase = (url: string): void => {
  try {
    localStorage.setItem(RISK_MW_KEY, url.trim().replace(/\/+$/, ''))
  } catch {
    /* a browser with storage disabled still works, it just forgets */
  }
}

export class ApiError extends Error {
  constructor(
    message: string,
    readonly status: number,
    readonly retryAfter?: number,
  ) {
    super(message)
  }
}

/** Our own routes carry the operator's token; risk-mw's do not, because it has its own demo auth. */
const authed = (): HeadersInit => {
  const current = session()
  return current ? { Authorization: `Bearer ${current.token}` } : {}
}

async function json<T>(response: Response): Promise<T> {
  if (response.status === 401) {
    clearSession()
    window.dispatchEvent(new Event('bhorosha-signed-out'))
    throw new ApiError('Session expired. Sign in again.', 401)
  }
  if (response.status === 429) {
    const retry = Number(response.headers.get('Retry-After') ?? 0)
    throw new ApiError(`Over quota. Retry in ${retry || '?'}s.`, 429, retry)
  }
  if (!response.ok) {
    const body = await response.text()
    throw new ApiError(body.slice(0, 300) || response.statusText, response.status)
  }
  return (await response.json()) as T
}

/* --- this service ------------------------------------------------------- */

/** The aggregate. Served from the committed fixture, so first paint never waits on a SHAP pass. */
/** What is running and how a payment moves through it. */
/** A few payments put through the engine the service actually runs. */
export const getScenarios = async (): Promise<{ scenarios: Scenario[] }> =>
  json<{ scenarios: Scenario[] }>(await fetch('/v1/admin/scenarios', { headers: authed() }))

export const getArchitecture = async (): Promise<Architecture> =>
  json<Architecture>(await fetch('/v1/admin/architecture', { headers: authed() }))

export const getOverview = async (refresh = false): Promise<Overview> =>
  json<Overview>(await fetch(`/v1/admin/overview${refresh ? '?refresh=true' : ''}`, { headers: authed() }))

export const getAccount = async (acctId: string): Promise<Account> =>
  json<Account>(await fetch(`/v1/admin/account/${encodeURIComponent(acctId)}`, { headers: authed() }))

/* --- the live audit trail ----------------------------------------------- */

/** What risk-mw actually answered, from Firestore. The other half of the replay. */
export const getAudit = async (limit = 50, before?: string, since?: string): Promise<AuditPage> => {
  const query = new URLSearchParams({ limit: String(limit) })
  if (before) query.set('before', before)
  // A poll asks only for what arrived after the newest row already on screen.
  if (since) query.set('since', since)
  return json<AuditPage>(await fetch(`/v1/admin/audit?${query}`, { headers: authed() }))
}

export const getAuditDocument = async (id: string): Promise<Record<string, unknown>> =>
  json<Record<string, unknown>>(await fetch(`/v1/admin/audit/${encodeURIComponent(id)}`, { headers: authed() }))

/** Gemini's reading of one stored score. Slow the first time (a model call), cached per document after that. */
export const getAuditInsight = async (id: string): Promise<AuditInsight> =>
  json<AuditInsight>(await fetch(`/v1/admin/audit/${encodeURIComponent(id)}/insight`, { headers: authed() }))

/* --- the radar's incidents and campaigns ------------------------ */

/** The rail and the campaign table, from the committed radar fixture. `available: false` is NO DATA. */
export const getCampaigns = async (): Promise<CampaignsList> =>
  json<CampaignsList>(await fetch('/v1/admin/campaigns', { headers: authed() }))

/** One incident with its firings, the campaigns holding it and every attempt they draw. */
export const getCampaignIncident = async (incidentId: string): Promise<CampaignIncident> =>
  json<CampaignIncident>(await fetch(`/v1/admin/campaigns/${encodeURIComponent(incidentId)}`, { headers: authed() }))

/* --- the common point of cash-out ------------------------------- */

/** Tills, daily runs, flags, clusters, candidates and the eval, from the committed fixture. */
export const getCashout = async (): Promise<CashoutWhole> =>
  json<CashoutWhole>(await fetch('/v1/admin/cashout', { headers: authed() }))

/** One daily run (YYYY-MM-DD) with the cash-outs its map draws. */
export const getCashoutDay = async (date: string): Promise<CashoutDayView> =>
  json<CashoutDayView>(await fetch(`/v1/admin/cashout/day/${encodeURIComponent(date)}`, { headers: authed() }))

/* --- Case Zero, proxied ------------------------------------------------- */

/**
 * Case Zero sends no CORS headers, so unlike risk-mw it cannot be called from the browser. These
 * go through this service, which also joins the watch-list to what the payment path did about it.
 */
export const getCasezeroHealth = async (): Promise<CaseZeroHealth> =>
  json<CaseZeroHealth>(await fetch('/v1/admin/casezero/health', { headers: authed() }))

export const getWatchlist = async (): Promise<Watchlist> =>
  json<Watchlist>(await fetch('/v1/admin/casezero/watchlist', { headers: authed() }))

/** The ring as Case Zero traversed it, assembled from the graph_delta of each tool result. */
export const getRingGraph = async (): Promise<RingGraphData> =>
  json<RingGraphData>(await fetch('/v1/admin/casezero/graph', { headers: authed() }))

export const getReplay = async (): Promise<ReplayEvent[]> =>
  json<ReplayEvent[]>(await fetch('/v1/admin/casezero/replay', { headers: authed() }))

/** A live case's full file: decision, members, red flags, timeline, look-alikes, narratives, checks, run. 404 once
    Case Zero no longer holds the case (it keeps cases in memory; a redeploy clears them). */
export const getCaseFile = async (caseId: string): Promise<CaseFile> =>
  json<CaseFile>(await fetch(`/v1/admin/casezero/case/${encodeURIComponent(caseId)}/file`, { headers: authed() }))

/** The recorded run's case file, the same shape: always there, no Gemini call. */
export const getReplayFile = async (): Promise<CaseFile> =>
  json<CaseFile>(await fetch('/v1/admin/casezero/replay/file', { headers: authed() }))

/* --- risk-mw, live ------------------------------------------------------ */

export const riskMwHealth = async (): Promise<RiskMwHealth> =>
  json<RiskMwHealth>(await fetch(`${riskMwBase()}/health`))

export const demoRing = async (): Promise<Record<string, string[]>> =>
  json<Record<string, string[]>>(await fetch(`${riskMwBase()}/v1/mule/demo-ring`))

export const muleScore = async (acctId: string): Promise<MuleScore> =>
  json<MuleScore>(await fetch(`${riskMwBase()}/v1/mule/score/${encodeURIComponent(acctId)}`))

/**
 * Open an investigation. A Gemini route: one per explicit click, never on a timer, and risk-mw
 * returns the same case for the same account inside 30 minutes anyway.
 */
export const investigate = async (acctId: string): Promise<{ case_id: string; stream_url: string }> =>
  json<{ case_id: string; stream_url: string }>(
    await fetch(`${riskMwBase()}/v1/investigate`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ acct_id: acctId }),
    }),
  )

export const caseReport = async (caseId: string): Promise<CaseReport> =>
  json<CaseReport>(await fetch(`${riskMwBase()}/v1/investigations/${encodeURIComponent(caseId)}`))

/**
 * Stream the agent's trace. Returns an abort function: a case runs for about 45 seconds and the
 * operator must be able to walk away from it without leaving a connection open, because each open
 * stream holds one of risk-mw's 80 concurrent slots for a minute.
 */
export function streamCase(
  caseId: string,
  onEvent: (event: TraceEvent) => void,
  onDone: (error?: string) => void,
): () => void {
  const controller = new AbortController()
  ;(async () => {
    try {
      const response = await fetch(`${riskMwBase()}/v1/investigations/${encodeURIComponent(caseId)}/events`, {
        signal: controller.signal,
      })
      if (!response.ok || !response.body) {
        onDone(`stream failed: HTTP ${response.status}`)
        return
      }
      const reader = response.body.getReader()
      const decoder = new TextDecoder()
      let buffer = ''
      for (;;) {
        const { done, value } = await reader.read()
        if (done) break
        buffer += decoder.decode(value, { stream: true })
        const chunks = buffer.split('\n\n')
        buffer = chunks.pop() ?? ''
        for (const chunk of chunks) {
          const line = chunk.replace(/^data:\s?/, '').trim()
          if (!line) continue
          try {
            onEvent(JSON.parse(line) as TraceEvent)
          } catch {
            onEvent({ step: 'error', text: line })
          }
        }
      }
      onDone()
    } catch (error) {
      if ((error as Error).name !== 'AbortError') onDone((error as Error).message)
      else onDone()
    }
  })()
  return () => controller.abort()
}
