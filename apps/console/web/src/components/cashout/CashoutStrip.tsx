/**
 * The time scrubber and the 15-minute strip.
 *
 * The axis is one Dhaka calendar day: the day a run closes for a flagged till, the cluster's own day
 * for a cluster. Bars stack the cash-outs counted in each 15 minutes: confirmed mules, candidates,
 * the rest. A cluster brings its expected count as a band over its window and the moment it opened;
 * a till flag has no per-hour baseline in the fixture, so none is drawn and the note says why.
 */

import { useEffect, useState } from 'react'
import { hm } from '../../lib/campaigns'
import type { CashoutCluster } from '../../lib/types'
import type { Drawn } from './cashoutMath'
import { BIN_MIN, MINUTES, bins, minuteOf } from './cashoutMath'
import { useXT } from './cashoutStrings'

const LEFT = 40
const WIDTH = 940
const TOP = 22
const BASE = 118
const STEP_MIN = 4
const TICK_MS = 40

const sx = (minute: number): number => LEFT + (minute / MINUTES) * WIDTH
const clock = (minute: number): string =>
  `${String(Math.floor(minute / 60)).padStart(2, '0')}:${String(Math.round(minute % 60)).padStart(2, '0')}`

function usePlayer(minute: number, setMinute: (value: number) => void): [boolean, () => void] {
  const [playing, setPlaying] = useState(false)
  useEffect(() => {
    if (!playing) return
    const timer = window.setInterval(() => {
      setMinute(Math.min(MINUTES, minute + STEP_MIN))
      if (minute + STEP_MIN >= MINUTES) setPlaying(false)
    }, TICK_MS)
    return () => window.clearInterval(timer)
  }, [minute, playing, setMinute])
  const toggle = () => {
    if (!playing && minute >= MINUTES) setMinute(0)
    setPlaying(!playing)
  }
  return [playing, toggle]
}

export function CashoutStrip({
  rows,
  axisStart,
  cluster,
  windowMin,
  minute,
  setMinute,
}: {
  rows: Drawn[]
  axisStart: number
  cluster: CashoutCluster | null
  windowMin: number
  minute: number
  setMinute: (value: number) => void
}) {
  const xt = useXT()
  const [playing, toggle] = usePlayer(minute, setMinute)
  const counted = bins(rows, axisStart)
  const max = Math.max(4, ...counted.map((b) => b.seed + b.candidate + b.other))
  const sy = (count: number): number => BASE - (count / max) * (BASE - TOP)
  const mu = cluster ? cluster.expected / (windowMin / BIN_MIN) : null
  const band = mu === null ? null : mu + 2 * Math.sqrt(mu)
  const opened = cluster ? minuteOf(cluster.opened_at, axisStart) : null
  const barWidth = WIDTH / counted.length - 2

  return (
    <>
      <div className="co-controls">
        <button type="button" className="sm" onClick={toggle} aria-pressed={playing}>
          {playing ? xt('xo.pause') : xt('xo.play')}
        </button>
        <label className="co-scrub">
          <span>
            {xt('xo.time')} <output className="co-now">{clock(minute)} +06:00</output>
          </span>
          <input
            type="range"
            min={0}
            max={MINUTES}
            step={1}
            value={minute}
            onChange={(event) => setMinute(Number(event.target.value))}
            aria-label={xt('xo.time')}
          />
        </label>
      </div>
      <svg className="co-svg" viewBox="0 0 1000 150" role="img" aria-label={xt('xo.strip')}>
        {cluster && band !== null && (
          <g>
            <rect
              className="co-band"
              x={sx(minuteOf(cluster.window_start, axisStart))}
              y={sy(band)}
              width={sx(minuteOf(cluster.window_end, axisStart)) - sx(minuteOf(cluster.window_start, axisStart))}
              height={BASE - sy(band)}
            />
            <title>{`${xt('xo.expected.band')}: ${cluster.expected.toFixed(3)} / ${windowMin} min`}</title>
          </g>
        )}
        <line className="co-axis" x1={LEFT} y1={BASE} x2={LEFT + WIDTH} y2={BASE} />
        <text className="co-caption" x={LEFT - 6} y={TOP + 4} textAnchor="end">
          {max}
        </text>
        <text className="co-caption" x={LEFT - 6} y={BASE} textAnchor="end">
          0
        </text>
        {counted.map((bin) => {
          const total = bin.seed + bin.candidate + bin.other
          if (!total) return null
          const x = sx(bin.minute) + 1
          const later = bin.minute >= minute
          const parts = (['other', 'candidate', 'seed'] as const).map((k, i, all) => {
            const below = all.slice(0, i).reduce((sum, key) => sum + bin[key], 0)
            return { k, y: sy(below + bin[k]), height: sy(below) - sy(below + bin[k]) }
          })
          return (
            <g key={bin.minute} opacity={later ? 0.2 : 1}>
              <title>{`${clock(bin.minute)}–${clock(bin.minute + BIN_MIN)}: ${total} (${bin.seed} seed, ${bin.candidate} candidate)`}</title>
              {parts
                .filter((part) => part.height > 0)
                .map((part) => (
                  <rect key={part.k} className={`co-bar co-bar-${part.k}`} x={x} y={part.y} width={barWidth} height={part.height} />
                ))}
            </g>
          )
        })}
        {Array.from({ length: 13 }, (_, i) => i * 2).map((hour) => (
          <text key={hour} className="co-caption" x={sx(hour * 60)} y={138} textAnchor="middle">
            {String(hour).padStart(2, '0')}:00
          </text>
        ))}
        {cluster && opened !== null && opened >= 0 && opened <= MINUTES && (
          <g opacity={minute >= opened ? 1 : 0.35}>
            <line className="co-open" x1={sx(opened)} y1={8} x2={sx(opened)} y2={BASE} />
            <text className="co-open-label" x={sx(opened) + 6} y={16}>
              {xt('xo.opens', { t: hm(cluster.opened_at) })}
            </text>
          </g>
        )}
        <line className="co-nowline" x1={sx(minute)} y1={6} x2={sx(minute)} y2={BASE} />
      </svg>
    </>
  )
}
