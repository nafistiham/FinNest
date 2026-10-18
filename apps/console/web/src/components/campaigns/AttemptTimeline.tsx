/**
 * The incident's attempts over time, against its baseline.
 *
 * One mark per attempt, placed by its Asia/Dhaka instant and laned by decision, labelled with the
 * console's own decision strings. Above them, the runs that fired: each dot is that run's count of
 * distinct senders in the incident's window, against the expected count held flat as a band. The
 * radar writes only the runs that fired, so nothing is interpolated between them. The opening line is
 * --info (violet means SYNTHETIC here and nowhere else). The tenth attempt in (time, id) order is
 * marked, since the detector cannot fire before ten distinct senders.
 */

import { useT } from '../../lib/i18n'
import { n, tone } from '../../lib/format'
import type { CampaignAttempt, RadarFiring, RadarIncident } from '../../lib/campaigns'
import { byTime, DHAKA_OFFSET, fmtCount, hm, hms, instant } from '../../lib/campaigns'
import { useCT } from '../../lib/campaignStrings'

const LEFT = 84
const RIGHT = 540
const TOP = 36
const BASE = 112
const LANES: Record<string, number> = { hold: 152, block: 152, delay: 188, step_up: 188, allow: 224 }
const LANE_ROWS: [number, string][] = [[152, 'hold'], [188, 'delay'], [224, 'allow']]

export function AttemptTimeline({
  incident,
  attempts,
  firings,
}: {
  incident: RadarIncident
  attempts: CampaignAttempt[]
  firings: RadarFiring[]
}) {
  const { t } = useT()
  const ct = useCT()
  const marks = [...attempts].sort(byTime)
  const runs = firings.filter((f) => f.window_min === incident.window_min).sort((a, b) => instant(a.run_ts) - instant(b.run_ts))
  const times = marks.map((a) => instant(a.ts))
  const lo = Math.min(...times, instant(incident.opened_at))
  const hi = Math.max(...times, instant(incident.last_fired_at))
  const pad = (hi - lo) * 0.03 || 60_000
  const [begin, end] = [lo - pad, hi + pad]
  const x = (ms: number) => LEFT + ((ms - begin) / (end - begin)) * (RIGHT - LEFT)
  const maxK = Math.max(incident.observed, ...runs.map((f) => f.k), 1)
  const yk = (value: number) => BASE - (value / maxK) * (BASE - TOP)
  const opened = x(instant(incident.opened_at))
  const first = runs.find((f) => f.run_ts === incident.opened_at) ?? runs[0]
  const tenth = marks[9]
  const label = (a: CampaignAttempt) =>
    `${a.attempt_id} · ${a.sender} → ${a.payee ?? '—'} · ৳${n(a.amount_bdt)} · ${t(`decisions.${a.decision}`)} · ${hms(a.ts)} ${DHAKA_OFFSET}`

  return (
    <>
      <svg className="cv-svg" viewBox="0 0 560 340" role="img" aria-label={`${ct('cv.timeline')}: ${marks.length}`}>
        <line className="cv-grid" x1={LEFT} y1={BASE} x2={RIGHT} y2={BASE} />
        <text x={LEFT - 8} y={TOP + 4} textAnchor="end">{maxK}</text>
        <text x={LEFT - 8} y={BASE + 4} textAnchor="end">0</text>
        <rect x={LEFT} y={yk(incident.expected) - 4} width={RIGHT - LEFT} height={8} fill="var(--info)" opacity={0.22}>
          <title>{`${ct('cv.band')}: ${ct('cv.expected')} ${fmtCount(incident.expected)}`}</title>
        </rect>
        <text x={LEFT + 6} y={yk(incident.expected) - 7}>
          {ct('cv.expected')} {fmtCount(incident.expected)} · {ct('cv.band')}
        </text>
        {runs.map((f) => (
          <circle key={f.run_ts} cx={x(instant(f.run_ts))} cy={yk(f.k)} r={3.5} fill="var(--warn)" tabIndex={0}>
            <title>{`${hm(f.run_ts)} ${DHAKA_OFFSET} · k ${f.k} · μ ${fmtCount(f.mu)} · p ${f.p.toExponential(2)} · ${f.reason}`}</title>
          </circle>
        ))}

        {LANE_ROWS.map(([y, key]) => (
          <g key={key}>
            <line className="cv-grid" x1={LEFT} y1={y} x2={RIGHT} y2={y} />
            <text x={8} y={y + 4}>{t(`decisions.${key}`)}</text>
          </g>
        ))}
        {marks.map((a) => {
          const cx = x(instant(a.ts))
          const cy = LANES[a.decision] ?? 188
          const fill = `var(--${tone(a.decision)})`
          return a.decision === 'delay' || a.decision === 'step_up' ? (
            <path key={a.attempt_id} d={`M${cx} ${cy - 5} l5 5 -5 5 -5 -5 Z`} fill={fill} tabIndex={0} role="img" aria-label={label(a)}>
              <title>{label(a)}</title>
            </path>
          ) : (
            <circle key={a.attempt_id} cx={cx} cy={cy} r={4} fill={fill} tabIndex={0} role="img" aria-label={label(a)}>
              <title>{label(a)}</title>
            </circle>
          )
        })}

        <line x1={opened} y1={26} x2={opened} y2={238} stroke="var(--info)" strokeWidth={2} />
        <text x={opened} y={24} textAnchor={opened > 420 ? 'end' : 'start'} dx={opened > 420 ? -4 : 4}>
          {ct('cv.opened.short')} {hm(incident.opened_at)}
          {first ? ` · k ${first.k} / μ ${fmtCount(first.mu)}` : ''}
        </text>
        {tenth && (
          <g>
            <path d={`M${x(instant(tenth.ts))} 242 l-5 8 h10 Z`} fill="var(--info)" />
            <text x={x(instant(tenth.ts))} y={264} textAnchor="middle">
              {ct('cv.tenth')} · {hms(tenth.ts)}
            </text>
          </g>
        )}

        {[0, 0.5, 1].map((share) => {
          const ms = begin + share * (end - begin)
          return (
            <text key={share} x={x(ms)} y={292} textAnchor={share === 0 ? 'start' : share === 1 ? 'end' : 'middle'}>
              {hm(new Date(ms).toISOString())}
            </text>
          )
        })}
        <text x={LEFT} y={312}>
          Asia/Dhaka ({DHAKA_OFFSET}) · k: {ct('cv.k')}, {incident.window_min} min
        </text>
      </svg>
      <div className="cv-legend">
        {(['hold', 'block', 'delay', 'step_up', 'allow'] as const).map((key) => {
          const count = marks.filter((a) => a.decision === key).length
          if (!count && key !== 'hold' && key !== 'allow') return null
          return (
            <span key={key} style={{ color: `var(--${tone(key)})` }}>
              {key === 'delay' || key === 'step_up' ? '◆' : '●'} {t(`decisions.${key}`)} <b>{count}</b>
            </span>
          )
        })}
      </div>
    </>
  )
}
