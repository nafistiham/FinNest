/**
 * The country at a glance: every FinNest agent till at its seed coordinates on the real
 * map of Bangladesh, a ring on each till the day's run flagged, a dashed ring on each replayed
 * cluster, and the box the zoomed map shows.
 *
 * The country is its sixty-four real districts - geoBoundaries gbOpen BGD ADM2, CC BY 4.0,
 * simplified at build time by tools/build_bd_districts.py and attributed on screen. It used to be
 * a hand-simplified outline whose own comment called the district file "a later swap"; this is
 * that swap. Nothing is fetched at request time: the shapes ship with the bundle.
 *
 * The districts are drawn with the same projection as the tills on top of them, so a till sits in
 * the district it is actually in.
 */

import { useT } from '../../lib/i18n'
import { DISTRICT_BN } from '../../lib/campaignStrings'
import { BD_DISTRICTS, BD_DISTRICTS_SOURCE, ringPath } from '../../lib/bdDistricts'
import type { CashoutCluster, CashoutTill, CashoutTillFlag } from '../../lib/types'
import type { Focus, Frame } from './cashoutMath'
import { sameFocus } from './cashoutMath'
import { useXT } from './cashoutStrings'

const x = (lon: number): number => 10 + (lon - 88.0) * 83.3
const y = (lat: number): number => 10 + (26.7 - lat) * 91

/* The synth world spells some districts the way the boundary file does not. */
const ALIAS: Record<string, string> = {
  Chattogram: 'Chittagong',
  Barishal: 'Barisal',
  Cumilla: 'Comilla',
  Jashore: 'Jessore',
  Bogura: 'Bogra',
}
const onMap = (district: string) => ALIAS[district] ?? district

/** name, lat, lon, label dx, label dy: the synth district centroids, labels nudged off the tills. */
const DISTRICTS: [string, number, number, number, number][] = [
  ['Dhaka', 23.81, 90.41, -58, 4],
  ['Gazipur', 23.99, 90.42, 10, -6],
  ['Narayanganj', 23.62, 90.5, 10, 12],
  ['Chattogram', 22.35, 91.83, 10, 4],
  ['Rangpur', 25.74, 89.27, 10, 4],
  ['Sylhet', 24.9, 91.87, -30, -14],
  ['Bhola', 22.69, 90.64, 10, 4],
  ['Khulna', 22.85, 89.54, -52, 4],
]

export function CashoutOverview({
  tills,
  flags,
  clusters,
  box,
  focus,
  onFocus,
}: {
  tills: CashoutTill[]
  flags: CashoutTillFlag[]
  clusters: CashoutCluster[]
  box: Frame | null
  focus: Focus | null
  onFocus: (focus: Focus) => void
}) {
  const xt = useXT()
  const { lang } = useT()
  const byId = new Map(tills.map((t) => [t.id, t]))
  const name = (district: string) => (lang === 'bn' ? DISTRICT_BN[district] ?? district : district)
  const seeded = new Set(DISTRICTS.map(([district]) => onMap(district)))
  return (
    <svg className="co-svg" viewBox="0 0 420 590" role="img" aria-label={xt('xo.overview.note', { n: tills.length })}>
      {/* Every district, drawn with the tills' own projection. The ones the seed world puts
          tills in are picked out, so the country reads as a country and the eight that matter
          still stand out. */}
      {Object.entries(BD_DISTRICTS).map(([shape, ring]) => (
        <path
          key={shape}
          className={`co-dist${seeded.has(shape) ? ' co-seeded' : ''}`}
          d={ringPath(ring, (lon, lat) => [x(lon), y(lat)])}
        />
      ))}
      {DISTRICTS.map(([district, lat, lon, dx, dy]) => (
        <text key={district} className="co-district" x={x(lon) + dx} y={y(lat) + dy}>
          {name(district)}
        </text>
      ))}
      {tills.map((till) => (
        <rect key={till.id} className="co-till-s" x={x(till.lon) - 2.5} y={y(till.lat) - 2.5} width={5} height={5}>
          <title>{`${till.id} · ${till.district ?? '—'} · ${till.lat.toFixed(4)}, ${till.lon.toFixed(4)}`}</title>
        </rect>
      ))}
      {clusters.map((cluster) => (
        <circle
          key={cluster.cluster_id}
          className={`co-ov-cluster${sameFocus(focus, { kind: 'cluster', id: cluster.cluster_id }) ? ' co-on' : ''}`}
          cx={x(cluster.centre_lon)}
          cy={y(cluster.centre_lat)}
          r={7}
          onClick={() => onFocus({ kind: 'cluster', id: cluster.cluster_id })}
        >
          <title>{`${cluster.cluster_id} · ${cluster.mode}`}</title>
        </circle>
      ))}
      {flags.map((flag) => {
        const till = byId.get(flag.id)
        if (!till) return null
        const on = sameFocus(focus, { kind: 'till', id: flag.id })
        return (
          <g key={flag.id} className="co-clickable" onClick={() => onFocus({ kind: 'till', id: flag.id })}>
            <title>{`${flag.id} · ${xt('xo.day.flagged')}`}</title>
            <circle className={`co-ov-flag${on ? ' co-on' : ''}`} cx={x(till.lon)} cy={y(till.lat)} r={on ? 10 : 8} />
          </g>
        )
      })}
      {box && (
        <rect
          className="co-ov-box"
          x={x(box.lon0)}
          y={y(box.lat1)}
          width={x(box.lon1) - x(box.lon0)}
          height={y(box.lat0) - y(box.lat1)}
        />
      )}
      <text className="co-credit" x={410} y={584} textAnchor="end">
        {BD_DISTRICTS_SOURCE}
      </text>
    </svg>
  )
}
