/**
 * The charts that are worth having.
 *
 * Three, not thirty. A share bar for where decisions land, a per-typology bar for where the model
 * is weak, and a daily chart you can actually read a number off. Every one of them is hoverable,
 * and the typology bars are clickable - which is the point of a chart in an operations console:
 * it is a filter you can see.
 */

import { useState } from 'react'
import { digits, fx, n, ratio, tone } from '../lib/format'
import { useT } from '../lib/i18n'

/* --- decision mix as one bar -------------------------------------------- */

const DECISION_ORDER = ['allow', 'step_up', 'delay', 'hold', 'block'] as const

export function ShareBar({ mix, total }: { mix: Record<string, number>; total: number }) {
  const { t } = useT()
  const [hover, setHover] = useState<string | null>(null)
  const parts = DECISION_ORDER.map((key) => ({ key, value: mix[key] ?? 0 })).filter((part) => part.value > 0)

  return (
    <div>
      <div className="share">
        {parts.map((part) => (
          <div
            key={part.key}
            className={`share-seg${hover === part.key ? ' hot' : ''}`}
            style={{ width: `${(100 * part.value) / total}%`, background: `var(--${tone(part.key)}-fill)` }}
            onMouseEnter={() => setHover(part.key)}
            onMouseLeave={() => setHover(null)}
            title={`${t(`decisions.${part.key}`)} — ${n(part.value)} (${ratio(part.value, total)})`}
          />
        ))}
      </div>
      <div className="share-legend">
        {parts.map((part) => (
          <span
            key={part.key}
            className={hover === part.key ? 'hot' : undefined}
            onMouseEnter={() => setHover(part.key)}
            onMouseLeave={() => setHover(null)}
          >
            <i style={{ background: `var(--${tone(part.key)}-fill)` }} />
            {t(`decisions.${part.key}`)} <b>{n(part.value)}</b>
            <em>{ratio(part.value, total)}</em>
          </span>
        ))}
      </div>
    </div>
  )
}

/* --- per-typology recall, clickable ------------------------------------- */

export function TypologyBars({
  segments,
  label,
  onPick,
  active,
}: {
  segments: Record<string, number>
  label: string
  onPick?: (typology: string) => void
  active?: string | null
}) {
  const { t } = useT()
  const rows = Object.entries(segments).sort((a, b) => a[1] - b[1])
  const band = (value: number): string => (value >= 0.9 ? 'good' : value >= 0.6 ? 'warn' : value >= 0.4 ? 'high' : 'bad')

  return (
    <div className="typology">
      <div className="typology-label">{label}</div>
      {rows.map(([name, value]) => (
        <div
          key={name}
          className={`typology-row${onPick ? ' clickable' : ''}${active === name ? ' active' : ''}`}
          onClick={() => onPick?.(name)}
        >
          <span className="mono name" title={name}>{name}</span>
          <div className="track">
            <i style={{ width: `${Math.max(2, value * 100)}%`, background: `var(--${band(value)}-fill)` }} />
            {/* The 0.75 line is the spec's bar for calling a ring recovered. */}
            <span className="target" style={{ left: '75%' }} />
          </div>
          <span className={`mono value t-text-${band(value)}`}>{fx(value, 2)}</span>
        </div>
      ))}
      <div className="typology-foot">
        <span />
        <span>{t('typology.foot')}</span>
      </div>
    </div>
  )
}

/* --- daily volume you can read a number off ------------------------------ */

export function DailyChart({ days }: { days: { day: string; scored: number; stopped: number }[] }) {
  const { t } = useT()
  const [at, setAt] = useState<number | null>(null)
  const max = Math.max(...days.map((day) => day.scored), 1)
  const current = at === null ? null : days[at]

  return (
    <div>
      <div className="daily" onMouseLeave={() => setAt(null)}>
        {days.map((day, index) => (
          <div
            key={day.day}
            className={`daily-col${at === index ? ' hot' : ''}`}
            onMouseEnter={() => setAt(index)}
          >
            <i className="scored" style={{ height: `${(100 * (day.scored - day.stopped)) / max}%` }} />
            <i className="stopped" style={{ height: `${(100 * day.stopped) / max}%` }} />
          </div>
        ))}
      </div>
      <div className="daily-read">
        {current ? (
          <>
            <b className="mono">{digits(current.day)}</b>
            <span>
              <i style={{ background: 'var(--info-fill)' }} /> {n(current.scored)} {t('daily.scored')}
            </span>
            <span>
              <i style={{ background: 'var(--high-fill)' }} /> {n(current.stopped)} {t('daily.stopped')}
            </span>
          </>
        ) : (
          <>
            <span className="mono dim">{digits(days[0]?.day ?? '')}</span>
            <span className="dim">{t('daily.hover')}</span>
            <span className="mono dim">{digits(days[days.length - 1]?.day ?? '')}</span>
          </>
        )}
      </div>
    </div>
  )
}
