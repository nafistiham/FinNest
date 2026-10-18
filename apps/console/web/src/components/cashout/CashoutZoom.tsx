/**
 * The zoomed map: an 18 km square around the flagged till or the cluster in focus, on a
 * 1-km grid. Tills at their coordinates; cash-outs up to the scrubber's time, spread in a spiral
 * around their till: a confirmed mule (seed) filled --bad, a candidate an amber ring, a cash-out at
 * the flagged till or in the circle that is not a candidate outlined grey, everything else grey.
 * Cash-outs from before the axis day (the 30-day evidence a flag rests on) are drawn from the start,
 * faded. A replayed cluster is a dashed circle that appears when the scrubber reaches the moment it
 * opened (one from another day stays drawn); the focused one is solid, the others faint and can be
 * clicked to look at them.
 */

import { useContext, useId, useMemo } from 'react'
import { stamp } from '../../lib/campaigns'
import { taka } from '../../lib/format'
import type { CashoutCluster, CashoutDayView, CashoutTillFlag } from '../../lib/types'
import type { Drawn, Focus, Frame, Resolved } from './cashoutMath'
import { MARGIN, MINUTES, SIZE, distanceKm, minuteOf, sameFocus, spiral } from './cashoutMath'
import { useXT } from './cashoutStrings'
import { BD_BOUNDS, BD_DISTRICTS, ringPath } from '../../lib/bdDistricts'
import { districtAt } from '../../lib/bdLookup'
import { LangContext } from '../../lib/i18n'
import { BD_LOCAL_SOURCE, LOCAL_ROADS, MAJOR_ROADS, MINOR_ROADS, PLACES, WATERWAYS, type Line } from '../../lib/bdLocal'

const RADIUS: Record<Drawn['mark'], number> = { seed: 6.2, candidate: 6.2, inside: 4.8, ordinary: 4 }
/** Room a circle's date label needs; past this from the right edge it flips to the other side. */
const LABEL_W = 104
/** How far a till's spiral can reach past the box edge and still be partly drawn. */
const SPIRAL_KM = 2

/** A road or river as an SVG path, in the zoom's own projection. */
function line(points: Line, at: Frame): string {
  return points.map(([lon, lat], i) => `${i ? 'L' : 'M'}${at.x(lon).toFixed(1)} ${at.y(lat).toFixed(1)}`).join('')
}

/**
 * Whether this line is worth drawing at all.
 *
 * Its bounding box against the frame's, not its vertices against the frame: a motorway simplified
 * to two distant points can cross the whole box without either end being anywhere near it, and
 * testing vertices would drop exactly the roads that matter most. False positives are free - they
 * are clipped - so the test errs towards drawing.
 */
function reaches(points: Line, at: Frame): boolean {
  let west = Infinity
  let east = -Infinity
  let south = Infinity
  let north = -Infinity
  for (const [lon, lat] of points) {
    if (lon < west) west = lon
    if (lon > east) east = lon
    if (lat < south) south = lat
    if (lat > north) north = lat
  }
  return west <= at.lon1 && east >= at.lon0 && south <= at.lat1 && north >= at.lat0
}

/**
 * The ground the tills sit on: real roads, rivers and place names from OpenStreetMap.
 *
 * This is what the zoom was missing. District boundaries are useless at eighteen kilometres - a
 * district is tens of kilometres across, so its outline encloses the whole frame and never enters
 * it - and without them the box was graph paper that could have been anywhere. Roads and village
 * names are the scale a person actually reads a neighbourhood at.
 *
 * Drawn under everything, clipped to the frame, and quiet: this is the page the evidence is
 * written on, not the evidence. Roads carry three weights so the shape of a place reads at a
 * glance; rivers are separate because in this delta they are the thing that divides one
 * neighbourhood from the next.
 *
 * The extract ships in the bundle - nothing is fetched when the page loads. See
 * tools/build_bd_local.py. OpenStreetMap's licence requires attribution, which the map carries.
 */
function Ground({ at }: { at: Frame }) {
  const lang = useContext(LangContext)
  /* Thousands of lines against one box, on every scrubber tick otherwise. The frame is rebuilt
     on each render of the view, so this keys off the box's actual extent rather than the object:
     scrubbing time does not move the box, and the ground under it does not change. */
  const { water, local, minor, major, places } = useMemo(() => {
    const near = (lines: Line[]) => lines.filter((points) => reaches(points, at)).map((points) => line(points, at))
    return {
      water: near(WATERWAYS),
      local: near(LOCAL_ROADS),
      minor: near(MINOR_ROADS),
      major: near(MAJOR_ROADS),
      places: PLACES.filter((place) => at.inside(place.lat, place.lon)),
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [at.lat0, at.lat1, at.lon0, at.lon1, at.pxPerKm])
  return (
    <g className="co-ground" aria-hidden="true">
      {water.map((d, i) => (
        <path key={`w${i}`} className="co-water" d={d} />
      ))}
      {local.map((d, i) => (
        <path key={`l${i}`} className="co-road co-road-local" d={d} />
      ))}
      {minor.map((d, i) => (
        <path key={`m${i}`} className="co-road co-road-minor" d={d} />
      ))}
      {major.map((d, i) => (
        <path key={`j${i}`} className="co-road co-road-major" d={d} />
      ))}
      {places.map((place) => {
        const px = at.x(place.lon)
        /* A name near an edge grows inwards instead of off the frame. */
        const anchor = px > SIZE - MARGIN - 70 ? 'end' : px < MARGIN + 70 ? 'start' : 'middle'
        return (
          <text
            key={`${place.lon},${place.lat}`}
            className="co-place"
            x={px}
            y={Math.min(Math.max(at.y(place.lat), MARGIN + 10), SIZE - MARGIN - 6)}
            textAnchor={anchor}
          >
            {lang === 'bn' ? place.name : place.en || place.name}
          </text>
        )
      })}
    </g>
  )
}

/** Inset geometry: a small Bangladesh in the corner of the frame, fitted to this box. */
const INSET = { w: 104, h: 132, x: MARGIN + 16, y: MARGIN + 16 }
const INSET_PAD = 9
const INSET_SCALE = Math.min(
  INSET.w / (BD_BOUNDS.east - BD_BOUNDS.west),
  INSET.h / (BD_BOUNDS.north - BD_BOUNDS.south),
)
const insetAt = (lon: number, lat: number): [number, number] => [
  INSET.x + (lon - BD_BOUNDS.west) * INSET_SCALE,
  INSET.y + (BD_BOUNDS.north - lat) * INSET_SCALE,
]

/**
 * Where in the country this box is.
 *
 * Eighteen kilometres is far too small for a district border to cross the frame - the district
 * holding a till is tens of kilometres wide, so its outline encloses the whole view and never
 * enters it. Drawing the real boundaries here therefore shows nothing, and the frame alone cannot
 * say where you are looking. This says it: the country, the district holding the focus filled, a
 * dot on the focus, and the district's name. The box itself would be about two pixels wide at this
 * scale, which is why the focus is a dot and not a rectangle.
 *
 * It is a card laid over the map rather than part of it, so it keeps its own opaque ground and
 * never has to compete with whatever tills happen to sit under this corner.
 */
function Locator({ lon, lat, here }: { lon: number; lat: number; here: string | null }) {
  const [dx, dy] = insetAt(lon, lat)
  return (
    <g className="co-locator">
      <rect
        className="co-locator-bg"
        x={INSET.x - INSET_PAD}
        y={INSET.y - INSET_PAD}
        width={INSET.w + 2 * INSET_PAD}
        height={INSET.h + 2 * INSET_PAD + (here ? 15 : 0)}
      />
      {Object.entries(BD_DISTRICTS).map(([shape, ring]) => (
        <path
          key={shape}
          className={shape === here ? 'co-locator-dist co-locator-here' : 'co-locator-dist'}
          d={ringPath(ring, insetAt)}
        />
      ))}
      <circle className="co-locator-halo" cx={dx} cy={dy} r={6} />
      <circle className="co-locator-dot" cx={dx} cy={dy} r={3.2} />
      {here && (
        <text className="co-locator-name" x={INSET.x + INSET.w / 2} y={INSET.y + INSET.h + 11} textAnchor="middle">
          {here}
        </text>
      )}
    </g>
  )
}

function Grid({ at, xt }: { at: Frame; xt: ReturnType<typeof useXT> }) {
  const lines: number[] = []
  for (let offset = 0; offset <= SIZE - 2 * MARGIN + 0.5; offset += at.pxPerKm) lines.push(MARGIN + offset)
  const end = SIZE - MARGIN
  return (
    <g>
      {lines.map((p) => (
        <g key={p}>
          <line className="co-gridline" x1={p} y1={MARGIN} x2={p} y2={end} />
          <line className="co-gridline" x1={MARGIN} y1={p} x2={end} y2={p} />
        </g>
      ))}
      <rect className="co-frame" x={MARGIN} y={MARGIN} width={end - MARGIN} height={end - MARGIN} />
      <line className="co-scale" x1={MARGIN + 14} y1={end - 14} x2={MARGIN + 14 + at.pxPerKm} y2={end - 14} />
      <text className="co-caption" x={MARGIN + 14} y={end - 22}>
        {xt('xo.km')}
      </text>
      {/* ODbL requires attribution on the map that uses the data. */}
      <text className="co-credit" x={end - 8} y={end - 7} textAnchor="end">
        {BD_LOCAL_SOURCE}
      </text>
    </g>
  )
}

function Circle({
  cluster,
  at,
  focused,
  shown,
  onFocus,
  xt,
}: {
  cluster: CashoutCluster
  at: Frame
  focused: boolean
  shown: boolean
  onFocus: (focus: Focus) => void
  xt: ReturnType<typeof useXT>
}) {
  if (!shown) return null
  const cx = at.x(cluster.centre_lon)
  const cy = at.y(cluster.centre_lat)
  const r = cluster.radius_km * at.pxPerKm
  return (
    <g
      className={`co-circle${focused ? ' co-on' : ''}${focused ? '' : ' co-clickable'}`}
      onClick={focused ? undefined : () => onFocus({ kind: 'cluster', id: cluster.cluster_id })}
    >
      <title>{`${cluster.cluster_id} · ${cluster.mode} · ${stamp(cluster.window_start)} – ${stamp(cluster.window_end)}`}</title>
      <circle cx={cx} cy={cy} r={r} />
      {/* The label hangs off the upper right of the circle, and flips to the upper left when a
          circle sits near the right edge - otherwise it runs out of the frame and is cut. */}
      <text
        x={cx + r * 0.62 + LABEL_W > SIZE - MARGIN ? cx - r * 0.62 : cx + r * 0.62}
        y={Math.max(MARGIN + 12, cy - r * 0.82)}
        textAnchor={cx + r * 0.62 + LABEL_W > SIZE - MARGIN ? 'end' : 'start'}
      >
        {xt('xo.circle.label', { when: stamp(cluster.opened_at).slice(5, 16) })}
      </text>
    </g>
  )
}

export function CashoutZoom({
  day,
  focus,
  at,
  drawn,
  minute,
  axisStart,
  onFocus,
}: {
  day: CashoutDayView
  focus: Resolved
  at: Frame
  drawn: Drawn[]
  minute: number
  axisStart: number
  onFocus: (focus: Focus) => void
}) {
  const xt = useXT()
  const clip = useId().replace(/:/g, '')
  const place = spiral(drawn, at)
  const flagged = new Map<string, CashoutTillFlag>(day.till_flags.map((f) => [f.id, f]))
  const tills = day.tills.filter((t) => at.inside(t.lat, t.lon))
  const reach = (Math.SQRT2 * (SIZE - 2 * MARGIN)) / 2 / at.pxPerKm
  const circles = day.clusters.filter((c) => distanceKm(c.centre_lat, c.centre_lon, focus.lat, focus.lon) < reach + c.radius_km)
  /* A circle that opens on the axis day appears when the scrubber reaches that moment; one from
     another day is context and stays drawn, faint. */
  const opened = (cluster: CashoutCluster): boolean => {
    const moment = minuteOf(cluster.opened_at, axisStart)
    return moment < 0 || moment > MINUTES || moment <= minute
  }
  const visible = drawn.filter(
    (row) => at.near(row.lat, row.lon, SPIRAL_KM) && (row.earlier || minuteOf(row.ts, axisStart) <= minute),
  )
  const title = focus.cluster ? xt('xo.zoom.cluster') : xt('xo.zoom.till', { id: focus.focus.id })
  /* Where this box is. At eighteen kilometres a border rarely crosses the frame, so the name is
     what the real boundaries can actually tell a reader here. */
  const here = districtAt(focus.lon, focus.lat)

  return (
    <svg className="co-svg co-zoom" viewBox={`0 0 ${SIZE} ${SIZE}`} role="img" aria-label={title}>
      <defs>
        <clipPath id={clip}>
          <rect x={MARGIN} y={MARGIN} width={SIZE - 2 * MARGIN} height={SIZE - 2 * MARGIN} />
        </clipPath>
      </defs>
      {/* The ground this box sits on, under the grid and clipped to it. The district boundaries
          that used to be here never showed: at eighteen kilometres a district encloses the frame
          instead of crossing it. Roads and place names are the scale that reads here. */}
      <g clipPath={`url(#${clip})`}>
        <Ground at={at} />
      </g>
      <Grid at={at} xt={xt} />
      <Locator lon={focus.lon} lat={focus.lat} here={here} />
      <g clipPath={`url(#${clip})`}>
        {circles.map((cluster) => (
          <Circle
            key={cluster.cluster_id}
            cluster={cluster}
            at={at}
            focused={sameFocus(focus.focus, { kind: 'cluster', id: cluster.cluster_id })}
            shown={opened(cluster)}
            onFocus={onFocus}
            xt={xt}
          />
        ))}
        {visible.map((row) => {
          const [cx, cy] = place.get(row.txn_id) ?? [at.x(row.lon), at.y(row.lat)]
          return (
            <circle key={row.txn_id} className={`co-dot co-${row.mark}${row.earlier ? ' co-earlier' : ''}`} cx={cx} cy={cy} r={RADIUS[row.mark]}>
              <title>{`${row.acct} · ${row.till} · ${stamp(row.ts)} · ${taka(row.amount_bdt)} · ${row.mark}`}</title>
            </circle>
          )
        })}
        {tills.map((till) => {
          const tx = at.x(till.lon)
          const ty = at.y(till.lat)
          const on = focus.tills.includes(till.id)
          return (
            <g key={till.id} className={flagged.has(till.id) ? 'co-clickable' : undefined} onClick={flagged.has(till.id) ? () => onFocus({ kind: 'till', id: till.id }) : undefined}>
              <title>{`${till.id} · ${till.district ?? '—'}${flagged.has(till.id) ? ` · ${xt('xo.day.flagged')}` : ''}`}</title>
              {flagged.has(till.id) && <circle className="co-flag-ring" cx={tx} cy={ty} r={13} />}
              <rect className="co-till" x={tx - 6} y={ty - 6} width={12} height={12} rx={2} />
              <text className={`co-till-label${on ? ' co-on' : ''}`} x={tx + 12} y={ty - 9}>
                {till.id}
              </text>
            </g>
          )
        })}
      </g>
    </svg>
  )
}
