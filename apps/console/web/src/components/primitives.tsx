/**
 * The pieces every panel is built from.
 *
 * `Tile` takes `badge` as a required prop and `Rate` takes `denominator` as a required prop. That
 * is deliberate: the console's rule is that every figure must say what stands behind it and what it was
 * divided by, and a rule the type checker enforces survives a deadline better than a rule in a
 * document.
 */

import type { ReactNode } from 'react'
import type { Badge as BadgeKind } from '../lib/types'
import { n, pct, tone } from '../lib/format'
import { useT } from '../lib/i18n'
import { Info } from './Info'
import { Rolling } from './Rolling'
import { Icon } from './Wordmark'
import { PRESETS, type Preset } from '../lib/ui'

/** Provenance, in words in the active language. The wire value stays in the tooltip for anyone
    reading the API side by side. */
export function Badge({ kind }: { kind: BadgeKind }) {
  const { t } = useT()
  return (
    <span className={`badge t-${tone(kind)}`} title={kind}>
      {t(`badge.${kind}`)}
    </span>
  )
}

const TONES = new Set(['good', 'info', 'warn', 'high', 'bad', 'violet', 'muted', 'brand'])

/** `kind` is a tone (`bad`) or a wire value to look one up for (`hold`, `MODEL`). It used to go
    through `tone()` either way, which maps an unknown key to `info` - so every chip asked to be
    `bad`, `good` or `warn` rendered blue. */
export function Chip({ children, kind }: { children: ReactNode; kind: string }) {
  return <span className={`chip t-${TONES.has(kind) ? kind : tone(kind)}`}>{children}</span>
}

export function Panel({
  title,
  question,
  badge,
  right,
  info,
  children,
}: {
  title: string
  question?: string
  badge?: BadgeKind
  right?: ReactNode
  /** Key into the `info.*` strings: renders the ⓘ beside the heading. */
  info?: string
  children: ReactNode
}) {
  return (
    <section className="panel">
      <div className="panel-head">
        <h2>{title}</h2>
        {info && <Info k={info} />}
        {badge && <Badge kind={badge} />}
        {question && <span className="q">{question}</span>}
        <span className="spacer" />
        {right}
      </div>
      {children}
    </section>
  )
}

/** A single figure. `badge` is required; there is no way to render a number with no provenance. */
export function Tile({
  label,
  value,
  sub,
  badge,
  small,
  info,
  onClick,
}: {
  label: string
  value: ReactNode
  sub?: ReactNode
  badge: BadgeKind
  small?: boolean
  info?: string
  onClick?: () => void
}) {
  return (
    <div
      className={`tile${onClick ? ' clickable' : ''}`}
      onClick={onClick}
      role={onClick ? 'button' : undefined}
      tabIndex={onClick ? 0 : undefined}
      onKeyDown={onClick ? (event) => (event.key === 'Enter' || event.key === ' ') && (event.preventDefault(), onClick()) : undefined}
    >
      <div className="label">
        {label}
        {info && <Info k={info} />}
        <Badge kind={badge} />
      </div>
      <div className={`value${small ? ' small' : ''}`}>
        {typeof value === 'string' && !small ? <Rolling text={value} /> : value}
      </div>
      {sub && <div className="sub">{sub}</div>}
    </div>
  )
}

/**
 * A rate and the denominator it came from, rendered together. There is no API for rendering one
 * without the other, which is the only reliable way to stop it happening.
 */
export function Rate({
  label,
  value,
  denominator,
  numerator,
  badge,
  info,
}: {
  label: string
  value: number | null
  denominator: number
  numerator: number
  badge: BadgeKind
  info?: string
}) {
  const { t } = useT()
  return (
    <Tile
      label={label}
      value={pct(value)}
      sub={`${n(numerator)} ${t('kpi.of')} ${n(denominator)}`}
      badge={badge}
      info={info}
    />
  )
}

export function BarRow({
  name,
  count,
  max,
  toneKey = 'info',
  suffix,
}: {
  name: string
  count: number
  max: number
  toneKey?: string
  suffix?: ReactNode
}) {
  const width = max > 0 ? Math.max(1.5, (100 * count) / max) : 0
  return (
    <div className="bar-row">
      <span className="name" title={name}>
        {name}
      </span>
      <div className="bar">
        <i style={{ width: `${width}%`, background: `var(--${toneKey}-fill)` }} />
      </div>
      <span className="count">
        {n(count)}
        {suffix}
      </span>
    </div>
  )
}

/** Square-root heights: a bucket holding nine rows next to one holding two thousand is otherwise invisible. */
export function Spark({
  values,
  hotFrom,
  titles,
  height,
}: {
  values: number[]
  hotFrom?: number
  titles?: string[]
  height?: number
}) {
  const max = Math.max(...values, 1)
  return (
    <div className="spark" style={height ? { height } : undefined}>
      {values.map((value, index) => (
        <i
          key={index}
          className={hotFrom !== undefined && index >= hotFrom ? 'hot' : undefined}
          style={{ height: value ? `${Math.max(4, 100 * Math.sqrt(value / max))}%` : 0 }}
          title={titles?.[index] ?? String(value)}
        />
      ))}
    </div>
  )
}

/**
 * Two or three mutually exclusive choices, small enough to live in a sidebar.
 *
 * Language and theme sat in Settings, two clicks and a scroll away from anyone who wanted them.
 * They are preferences people change often and early, so they belong where the eye already is.
 */
export function Segmented<T extends string>({
  value,
  options,
  onChange,
  label,
}: {
  value: T
  options: { value: T; label: string; title?: string; icon?: string }[]
  onChange: (value: T) => void
  label?: string
}) {
  return (
    <div className="segmented" role="group" aria-label={label}>
      {options.map((option) => (
        <button
          key={option.value}
          type="button"
          className={option.value === value ? 'on' : undefined}
          aria-pressed={option.value === value}
          title={option.title ?? option.label}
          onClick={() => onChange(option.value)}
        >
          {option.icon && <Icon name={option.icon} filled={option.value === value} />}
          <span>{option.label}</span>
        </button>
      ))}
    </div>
  )
}

/** Skeleton lines for a drawer still loading: the design system wants the shape of the content,
    not a spinner, while it arrives. */
export function DrawerSkeleton() {
  return (
    <div className="skeleton" aria-busy="true">
      <div className="skel-line" style={{ width: '60%' }} />
      <div className="skel-tile" />
      <div className="skel-line" style={{ width: '40%' }} />
      <div className="skel-panel" />
    </div>
  )
}

/**
 * The colour palette: the design system's five presets, each shown with its own swatch
 * (`--fn-preset-<name>`, that preset's primary in the current mode), so every choice reads right
 * whichever one is active. `full` names each option (Settings); `compact` is swatches only, named
 * in the tooltip and to screen readers (the sidebar).
 */
export function PresetPicker({
  value,
  onChange,
  variant = 'full',
}: {
  value: Preset
  onChange: (value: Preset) => void
  variant?: 'full' | 'compact'
}) {
  const { t } = useT()
  return (
    <div className={`presets presets--${variant}`} role="radiogroup" aria-label={t('settings.palette')}>
      {PRESETS.map((preset) => {
        const on = preset === value
        return (
          <button
            key={preset}
            type="button"
            role="radio"
            aria-checked={on}
            className={`preset${on ? ' on' : ''}`}
            title={t(`preset.${preset}`)}
            aria-label={variant === 'compact' ? t(`preset.${preset}`) : undefined}
            onClick={() => onChange(preset)}
          >
            <span className="swatch" style={{ background: `var(--fn-preset-${preset})` }} aria-hidden="true">
              {on && <Icon name="check" />}
            </span>
            {variant === 'full' && <span className="preset-name">{t(`preset.${preset}`)}</span>}
          </button>
        )
      })}
    </div>
  )
}

/**
 * The longer note under a panel (method, caveats, where a number comes from), folded away by
 * default. It is still one click from the figure it explains, but the page leads with the figures.
 */
export function Explainer({ children }: { children: ReactNode }) {
  const { t } = useT()
  return (
    <details className="panel-note explainer">
      <summary>
        <Icon name="info" />
        {t('more.about')}
      </summary>
      <div className="explainer-body">{children}</div>
    </details>
  )
}
