/**
 * The cash-out map's pure pieces: what is in focus, where a point lands, which mark a
 * cash-out gets, and the 15-minute bins. Every figure is read from the day route; nothing here
 * invents an event, a baseline or a position other than the spiral that spreads a till's dots.
 *
 * Time is Asia/Dhaka throughout (lib/campaigns.ts `instant` reads the +06:00 the builder writes).
 */

import { dateOf, instant } from '../../lib/campaigns'
import type { CashoutCluster, CashoutDay, CashoutDayView, CashoutEvent, CashoutPoint, CashoutTill, CashoutTillFlag } from '../../lib/types'

/* --- focus ---------------------------------------------------------------- */

export type Focus = { kind: 'till'; id: string } | { kind: 'cluster'; id: string }

export const sameFocus = (a: Focus | null, b: Focus | null): boolean =>
  a !== null && b !== null && a.kind === b.kind && a.id === b.id

const byP = <T extends { p_value: number }>(a: T, b: T): number => a.p_value - b.p_value

/** The most unusual flag of the day, else its most unusual cluster: a rule, never a pick for effect. */
export function defaultFocus(day: CashoutDayView): Focus | null {
  const flag = [...day.till_flags].sort((a, b) => byP(a, b) || a.id.localeCompare(b.id))[0]
  if (flag) return { kind: 'till', id: flag.id }
  const cluster = [...day.clusters].sort((a, b) => byP(a, b) || a.cluster_id.localeCompare(b.cluster_id))[0]
  return cluster ? { kind: 'cluster', id: cluster.cluster_id } : null
}

export interface Resolved {
  focus: Focus
  flag: CashoutTillFlag | null
  cluster: CashoutCluster | null
  lat: number
  lon: number
  /** The tills the focus is about: the flagged till, or the cluster's own. */
  tills: string[]
}

export function resolve(day: CashoutDayView, focus: Focus | null): Resolved | null {
  if (!focus) return null
  if (focus.kind === 'till') {
    const flag = day.till_flags.find((f) => f.id === focus.id) ?? null
    const till = day.tills.find((t) => t.id === focus.id)
    return till ? { focus, flag, cluster: null, lat: till.lat, lon: till.lon, tills: [till.id] } : null
  }
  const cluster = day.clusters.find((c) => c.cluster_id === focus.id) ?? null
  return cluster
    ? { focus, flag: null, cluster, lat: cluster.centre_lat, lon: cluster.centre_lon, tills: cluster.tills }
    : null
}

/* --- geometry ------------------------------------------------------------- */

export const KM_PER_DEG_LAT = 110.57
export const kmPerDegLon = (lat: number): number => 111.32 * Math.cos((lat * Math.PI) / 180)

export const distanceKm = (aLat: number, aLon: number, bLat: number, bLon: number): number =>
  Math.hypot((aLat - bLat) * KM_PER_DEG_LAT, (aLon - bLon) * kmPerDegLon((aLat + bLat) / 2))

/** A square of 2 * HALF_KM around the focus, drawn SIZE px wide with MARGIN on each side. */
export const HALF_KM = 9
export const SIZE = 560
export const MARGIN = 10

export interface Frame {
  pxPerKm: number
  x: (lon: number) => number
  y: (lat: number) => number
  inside: (lat: number, lon: number) => boolean
  /** Inside, or within `padKm` of the edge: a till just outside still shows the part of its spiral that reaches in. */
  near: (lat: number, lon: number, padKm: number) => boolean
  lat0: number
  lat1: number
  lon0: number
  lon1: number
}

export function frame(lat: number, lon: number, halfKm = HALF_KM): Frame {
  const pxPerKm = (SIZE - 2 * MARGIN) / (2 * halfKm)
  const dLat = halfKm / KM_PER_DEG_LAT
  const dLon = halfKm / kmPerDegLon(lat)
  const lat0 = lat - dLat
  const lat1 = lat + dLat
  const lon0 = lon - dLon
  const lon1 = lon + dLon
  return {
    pxPerKm,
    x: (value) => MARGIN + (value - lon0) * kmPerDegLon(lat) * pxPerKm,
    y: (value) => MARGIN + (lat1 - value) * KM_PER_DEG_LAT * pxPerKm,
    inside: (a, b) => a >= lat0 && a <= lat1 && b >= lon0 && b <= lon1,
    near: (a, b, padKm) => {
      const pLat = padKm / KM_PER_DEG_LAT
      const pLon = padKm / kmPerDegLon(lat)
      return a >= lat0 - pLat && a <= lat1 + pLat && b >= lon0 - pLon && b <= lon1 + pLon
    },
    lat0,
    lat1,
    lon0,
    lon1,
  }
}

const GOLDEN = Math.PI * (3 - Math.sqrt(5))

/**
 * Spread the cash-outs at each till into a sunflower spiral around it, oldest at the centre, so a
 * till's dots can be counted. Positions use every point given, so a dot does not move when the
 * scrubber hides a later one.
 */
export function spiral<T extends Pick<CashoutPoint, 'txn_id' | 'ts' | 'lat' | 'lon'>>(
  points: T[],
  at: Frame,
  start = 9,
  step = 5.2,
): Map<string, [number, number]> {
  const groups = new Map<string, T[]>()
  for (const point of points) {
    const key = `${point.lat},${point.lon}`
    groups.set(key, [...(groups.get(key) ?? []), point])
  }
  const placed = new Map<string, [number, number]>()
  for (const group of groups.values()) {
    const ordered = [...group].sort((a, b) => instant(a.ts) - instant(b.ts) || a.txn_id.localeCompare(b.txn_id))
    ordered.forEach((point, index) => {
      const r = start + step * Math.sqrt(index)
      const angle = index * GOLDEN
      placed.set(point.txn_id, [at.x(point.lon) + r * Math.cos(angle), at.y(point.lat) + r * Math.sin(angle)])
    })
  }
  return placed
}

/* --- marks ---------------------------------------------------------------- */

export type Mark = 'seed' | 'candidate' | 'inside' | 'ordinary'

export interface Drawn extends CashoutPoint {
  mark: Mark
  /** Before the day on the time axis: drawn from the start, faded. */
  earlier: boolean
}

export const DAY_MS = 86_400_000
export const MINUTES = 1440

/** The start of a Dhaka calendar day, in ms. */
export const dayStart = (date: string): number => instant(`${date}T00:00:00+06:00`)

/** The calendar day a 00:00 run closes: the date before it. */
export const closedDay = (date: string): string => dateOf(new Date(dayStart(date) - DAY_MS).toISOString())

export const minuteOf = (ts: string, start: number): number => (instant(ts) - start) / 60_000

/** The day the time axis spans for this focus: the closed day for a till, the cluster's own day. */
export const axisDay = (day: CashoutDayView, focus: Resolved): string =>
  focus.cluster ? dateOf(focus.cluster.window_start) : closedDay(day.date ?? '')

export function marksForTill(day: CashoutDayView, till: string): Drawn[] {
  const start = dayStart(closedDay(day.date ?? ''))
  return day.events.map((event) => ({
    ...event,
    mark: event.kind === 'seed' ? 'seed' : event.kind === 'candidate' ? 'candidate' : event.till === till ? 'inside' : 'ordinary',
    earlier: instant(event.ts) <= start,
  }))
}

/**
 * Accounts known to be confirmed mules by the run on `date`: every account a kept event marks `seed`
 * on that day or earlier, and every seed a till flag of that day or earlier rests on. The fixture keeps
 * events only for busy days, so the flags' `seed_accounts` name confirmed mules whose cash-outs it may
 * not have kept. Confirmation is never withdrawn, so a seed stays one on every later day.
 */
export function seedsAsOf(events: Record<string, CashoutEvent[]>, days: CashoutDay[], date: string): Set<string> {
  const fromEvents = Object.entries(events)
    .filter(([day]) => day <= date)
    .flatMap(([, rows]) => rows.filter((row) => row.kind === 'seed').map((row) => row.acct))
  const fromFlags = days
    .filter((day) => day.date <= date)
    .flatMap((day) => day.till_flags.flatMap((flag) => flag.seed_accounts))
  return new Set([...fromEvents, ...fromFlags])
}

export type MemberRole = 'seed' | 'candidate' | 'inside'

/** A member of a circle: a seed when it opened the circle or is a confirmed mule as of the run. */
export function memberRole(cluster: CashoutCluster, acct: string, seeds: Set<string>, candidates: Set<string>): MemberRole {
  if (seeds.has(acct) || cluster.seed_cashouts.some((point) => point.acct === acct)) return 'seed'
  return candidates.has(acct) ? 'candidate' : 'inside'
}

/** A cluster draws its own members only: the fixture keeps them, not the rest of that day. */
export function marksForCluster(cluster: CashoutCluster, seeds: Set<string>, candidates: Set<string>): Drawn[] {
  return [...cluster.seed_cashouts, ...cluster.other_cashouts]
    .map((point): Drawn => ({ ...point, mark: memberRole(cluster, point.acct, seeds, candidates), earlier: false }))
    .sort((a, b) => instant(a.ts) - instant(b.ts) || a.txn_id.localeCompare(b.txn_id))
}

export function marksFor(day: CashoutDayView, focus: Resolved, seeds: Set<string>): Drawn[] {
  if (focus.cluster) return marksForCluster(focus.cluster, seeds, new Set(day.candidates.map((c) => c.acct)))
  return marksForTill(day, focus.focus.id)
}

/* --- bins ----------------------------------------------------------------- */

export const BIN_MIN = 15

export interface Bin {
  minute: number
  seed: number
  candidate: number
  other: number
}

export function bins(rows: Drawn[], start: number): Bin[] {
  const out: Bin[] = Array.from({ length: MINUTES / BIN_MIN }, (_, i) => ({ minute: i * BIN_MIN, seed: 0, candidate: 0, other: 0 }))
  for (const row of rows) {
    const minute = minuteOf(row.ts, start)
    if (minute < 0 || minute >= MINUTES) continue
    const bin = out[Math.floor(minute / BIN_MIN)]!
    if (row.mark === 'seed') bin.seed += 1
    else if (row.mark === 'candidate') bin.candidate += 1
    else bin.other += 1
  }
  return out
}

/** What the strip counts: the focused till's cash-outs on the axis day, or the circle's members. */
export function stripRows(drawn: Drawn[], focus: Resolved): Drawn[] {
  return focus.cluster ? drawn : drawn.filter((row) => row.till === focus.focus.id && !row.earlier)
}

/* --- numbers -------------------------------------------------------------- */

/** "1 in 7,194", or the cap below 1e-12 with the exact value left for the title. */
export function oneIn(p: number): { kind: 'below' | 'onein' | 'plain'; n: string; exact: string } {
  const exact = `p = ${p.toExponential(3)}`
  if (p < 1e-12) return { kind: 'below', n: '', exact }
  if (p < 0.01) return { kind: 'onein', n: Math.round(1 / p).toLocaleString('en-IN'), exact }
  return { kind: 'plain', n: p.toFixed(3), exact }
}

export const tillsById = (tills: CashoutTill[]): Map<string, CashoutTill> => new Map(tills.map((t) => [t.id, t]))

export const configNumber = (config: Record<string, unknown> | undefined, key: string, fallback: number): number => {
  const value = config?.[key]
  return typeof value === 'number' && Number.isFinite(value) ? value : fallback
}
