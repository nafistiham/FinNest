/**
 * Where the money comes out: the common point of cash-out on a map.
 *
 * The radar's cash-out rules on the campaign world, read from the committed fixture through two
 * admin routes: the whole fixture once, for the days, the tills and the evaluation, then one daily
 * run at a time. A country overview, an 18 km map around the flagged till or replayed cluster in
 * focus, the incident beside it, and the day under them as a scrubber and a 15-minute strip. Nothing
 * here re-runs a rule, polls, sends a request on an analyst's behalf or calls Gemini.
 */

import { useCallback, useEffect, useMemo, useState } from 'react'
import { getCashout, getCashoutDay } from '../../lib/api'
import { DISTRICT_BN } from '../../lib/campaignStrings'
import { hm, stamp } from '../../lib/campaigns'
import { useT } from '../../lib/i18n'
import type { CashoutDay, CashoutDayView, CashoutWhole } from '../../lib/types'
import { Panel } from '../primitives'
import { CashoutOverview } from '../cashout/CashoutOverview'
import { CashoutPanel } from '../cashout/CashoutPanel'
import { CashoutStrip } from '../cashout/CashoutStrip'
import { CashoutZoom } from '../cashout/CashoutZoom'
import type { Focus } from '../cashout/cashoutMath'
import {
  MINUTES,
  axisDay,
  closedDay,
  configNumber,
  dayStart,
  defaultFocus,
  frame,
  marksFor,
  resolve,
  sameFocus,
  seedsAsOf,
  stripRows,
} from '../cashout/cashoutMath'
import { useXT } from '../cashout/cashoutStrings'
import '../cashout/cashout.css'

const busy = (day: CashoutDay): boolean => day.till_flags.length > 0 || day.clusters.length > 0

function DayPicker({ days, value, onChange }: { days: CashoutDay[]; value: string | null; onChange: (date: string) => void }) {
  const xt = useXT()
  return (
    <label className="co-day">
      <span>{xt('xo.day')}</span>
      <select value={value ?? ''} onChange={(event) => onChange(event.target.value)} title={xt('xo.day.hint')}>
        {days.map((day) => (
          <option key={day.date} value={day.date}>
            {`${day.date} · ${
              day.till_flags.length ? `${day.till_flags.map((f) => f.id).join(', ')} ${xt('xo.day.flagged')}` : xt('xo.day.noflag')
            } · ${day.clusters.length} ${xt('xo.day.clusters')}`}
          </option>
        ))}
      </select>
    </label>
  )
}

function FocusPicker({ day, focus, onFocus }: { day: CashoutDayView; focus: Focus | null; onFocus: (focus: Focus) => void }) {
  const xt = useXT()
  const { lang } = useT()
  const district = (id: string) => {
    const name = day.tills.find((t) => t.id === id)?.district ?? '—'
    return lang === 'bn' ? DISTRICT_BN[name] ?? name : name
  }
  return (
    <div className="co-picks" role="group" aria-label={xt('xo.focus')}>
      <span className="co-sub">{xt('xo.focus')}</span>
      {day.till_flags.map((flag) => (
        <button
          key={flag.id}
          type="button"
          className={`sm co-pick${sameFocus(focus, { kind: 'till', id: flag.id }) ? ' on' : ''}`}
          aria-pressed={sameFocus(focus, { kind: 'till', id: flag.id })}
          onClick={() => onFocus({ kind: 'till', id: flag.id })}
        >
          <span className="badge t-info">RULE</span> {flag.id} · {district(flag.id)} · {flag.seed_accounts.length} {xt('xo.seeds.short')}
        </button>
      ))}
      {day.clusters.map((cluster) => (
        <button
          key={cluster.cluster_id}
          type="button"
          className={`sm co-pick${sameFocus(focus, { kind: 'cluster', id: cluster.cluster_id }) ? ' on' : ''}`}
          aria-pressed={sameFocus(focus, { kind: 'cluster', id: cluster.cluster_id })}
          onClick={() => onFocus({ kind: 'cluster', id: cluster.cluster_id })}
          title={cluster.cluster_id}
        >
          <span className="badge t-warn">{cluster.mode === 'replay' ? 'REPLAY' : 'LIVE'}</span> {district(cluster.tills[0] ?? '')} ·{' '}
          {stamp(cluster.opened_at).slice(5, 10)} {hm(cluster.opened_at)}
        </button>
      ))}
    </div>
  )
}

function Legend({ config }: { config: Record<string, unknown> }) {
  const xt = useXT()
  const items: [string, string][] = [
    ['seed', xt('xo.lg.seed')],
    ['candidate', xt('xo.lg.cand')],
    ['inside', xt('xo.lg.inside')],
    ['ordinary', xt('xo.lg.ord')],
    ['till', xt('xo.lg.till')],
    ['circle', xt('xo.lg.circle', { km: configNumber(config, 'CLUSTER_RADIUS_KM', 2.5), min: configNumber(config, 'CLUSTER_WINDOW_MIN', 90) })],
    ['earlier', xt('xo.lg.earlier', { days: configNumber(config, 'TILL_REUSE_DAYS', 30) })],
  ]
  return (
    <div className="co-legend" aria-hidden="true">
      {items.map(([key, label]) => (
        <span key={key}>
          <i className={`co-sw co-sw-${key}`} />
          {label}
        </span>
      ))}
    </div>
  )
}

export function CashoutView() {
  const { t } = useT()
  const xt = useXT()
  const [whole, setWhole] = useState<CashoutWhole | null>(null)
  const [wholeError, setWholeError] = useState<string | null>(null)
  const [date, setDate] = useState<string | null>(null)
  const [loaded, setLoaded] = useState<Record<string, CashoutDayView>>({})
  const [lastShown, setLastShown] = useState<CashoutDayView | null>(null)
  const [dayError, setDayError] = useState<string | null>(null)
  const [focus, setFocus] = useState<Focus | null>(null)
  const [minute, setMinute] = useState(MINUTES)

  const days = useMemo(() => (whole?.days ?? []).filter(busy).reverse(), [whole])

  const loadWhole = useCallback(async () => {
    setWholeError(null)
    try {
      const body = await getCashout()
      setWhole(body)
      const newest = body.days.filter(busy).at(-1)
      if (body.available && newest) setDate(newest.date)
    } catch (err) {
      setWholeError((err as Error).message)
    }
  }, [])

  useEffect(() => {
    void loadWhole()
  }, [loadWhole])

  const loadDay = useCallback(async (value: string) => {
    setDayError(null)
    try {
      const body = await getCashoutDay(value)
      setLoaded((previous) => ({ ...previous, [value]: body }))
    } catch (err) {
      setDayError((err as Error).message)
    }
  }, [])

  useEffect(() => {
    if (date && !loaded[date]) void loadDay(date)
  }, [date, loaded, loadDay])

  const fresh = date ? loaded[date] ?? null : null
  const seedsDate = (fresh ?? lastShown)?.date ?? null
  const seeds = useMemo(
    () => (whole && seedsDate ? seedsAsOf(whole.events, whole.days, seedsDate) : new Set<string>()),
    [whole, seedsDate],
  )
  useEffect(() => {
    if (!fresh) return
    setLastShown(fresh)
    setFocus(defaultFocus(fresh))
    setMinute(MINUTES)
  }, [fresh])

  const pickFocus = (next: Focus) => {
    setFocus(next)
    setMinute(MINUTES)
  }

  if (wholeError) {
    return (
      <div className="note bad">
        {wholeError}{' '}
        <button className="sm" onClick={() => void loadWhole()}>
          {xt('xo.retry')}
        </button>
      </div>
    )
  }
  if (!whole) return <div className="loading">{t('loading')}</div>
  if (!whole.available) {
    return (
      <Panel title={xt('xo.unavailable')} badge="NO DATA">
        <p className="co-sub">{whole.reason}</p>
        <button className="sm" onClick={() => void loadWhole()}>
          {xt('xo.retry')}
        </button>
      </Panel>
    )
  }
  if (!days.length) return <Panel title={xt('xo.title')} badge="NO DATA"><p className="co-sub">{xt('xo.none')}</p></Panel>

  // The last day stays on screen, dimmed, while the next one loads or if it fails: no flash of empty panels.
  const unavailable = fresh !== null && !fresh.available
  const shown = fresh && fresh.available ? fresh : lastShown?.available ? lastShown : null
  const stale = shown !== null && shown !== fresh
  const resolved = shown ? resolve(shown, focus) ?? resolve(shown, defaultFocus(shown)) : null
  const at = resolved ? frame(resolved.lat, resolved.lon) : null
  const drawn = shown && resolved ? marksFor(shown, resolved, seeds) : []
  const axisDate = shown && resolved ? axisDay(shown, resolved) : null
  const axisStart = axisDate ? dayStart(axisDate) : 0
  const lastAsOf = whole.days.at(-1)?.as_of ?? null
  const reuseDays = configNumber(whole.config, 'TILL_REUSE_DAYS', 30)

  return (
    <>
      <h2 className="co-title">{xt('xo.title')}</h2>
      <p className="co-lede">{xt('xo.lede')}</p>
      <div className="co-toolbar">
        <DayPicker days={days} value={date} onChange={setDate} />
        {shown && shown.date && (
          <span className="co-sub">
            {xt('xo.run', { date: shown.date, seeds: shown.seeds ?? '—', cashouts: shown.cashouts ?? '—', closed: closedDay(shown.date) })}
          </span>
        )}
      </div>
      {dayError && (
        <div className="note bad" style={{ marginBottom: 12 }}>
          {xt('xo.stale')} {dayError}{' '}
          <button className="sm" onClick={() => date && void loadDay(date)}>
            {xt('xo.retry')}
          </button>
        </div>
      )}
      {unavailable && (
        <div className="note bad" style={{ marginBottom: 12 }}>
          {xt('xo.unavailable')}: {fresh?.reason}
        </div>
      )}
      {!shown && !dayError && !unavailable && <div className="loading">{t('loading')}</div>}
      {shown && resolved && at && (
        <div className={stale ? 'co-stale' : undefined}>
          <FocusPicker day={shown} focus={resolved.focus} onFocus={pickFocus} />
          <div className="co-grid">
            <div className="co-ov">
              <Panel title={xt('xo.overview')} badge="SYNTHETIC">
                <CashoutOverview tills={shown.tills} flags={shown.till_flags} clusters={shown.clusters} box={at} focus={resolved.focus} onFocus={pickFocus} />
                <p className="co-sub">{xt('xo.overview.note', { n: shown.tills.length })}</p>
              </Panel>
            </div>
            <div className="co-zm">
              <Panel title={resolved.cluster ? xt('xo.zoom.cluster') : xt('xo.zoom.till', { id: resolved.focus.id })} badge="RULE">
                <CashoutZoom day={shown} focus={resolved} at={at} drawn={drawn} minute={minute} axisStart={axisStart} onFocus={pickFocus} />
                <Legend config={whole.config} />
                <p className="co-sub">{xt('xo.zoom.note')}</p>
              </Panel>
            </div>
            <aside className="co-side">
              <Panel title={xt('xo.incident')} badge="RULE">
                <CashoutPanel day={shown} focus={resolved} seeds={seeds} evaluation={whole.evaluation} config={whole.config} lastAsOf={lastAsOf} />
              </Panel>
            </aside>
            <div className="co-st">
              <Panel title={xt('xo.strip')} badge="RULE" question={axisDate ?? undefined}>
                <CashoutStrip
                  rows={stripRows(drawn, resolved)}
                  axisStart={axisStart}
                  cluster={resolved.cluster}
                  windowMin={configNumber(whole.config, 'CLUSTER_WINDOW_MIN', 90)}
                  minute={minute}
                  setMinute={setMinute}
                />
                <p className="co-sub">
                  {resolved.cluster
                    ? xt('xo.strip.cluster', { date: axisDate ?? '—' })
                    : xt('xo.strip.till', { id: resolved.focus.id, date: axisDate ?? '—', days: reuseDays })}
                </p>
              </Panel>
            </div>
          </div>
        </div>
      )}
    </>
  )
}
