/**
 * Where the incident's senders are, on the real map of Bangladesh.
 *
 * This used to be a hand-made twenty-four point outline with eight circles on it, and its own
 * caption admitted it was a sketch. The country is now its sixty-four districts as they actually
 * are: geoBoundaries gbOpen BGD ADM2, simplified at build time into SVG paths by
 * tools/build_bd_districts.py, with the attribution the CC BY licence requires shown on the map.
 *
 * The encodings are unchanged, because they were right. A district is shaded by how many distinct
 * senders it holds - senders, never attempts, which is what makes a campaign a campaign. Every
 * district a payee sits in is outlined. A sender whose district is unknown goes into a labelled
 * count rather than onto a position the data does not support.
 */

import { useT } from '../../lib/i18n'
import type { CampaignAttempt } from '../../lib/campaigns'
import { DISTRICT_BN, useCT } from '../../lib/campaignStrings'
import { BD_BOUNDS, BD_DISTRICTS, BD_DISTRICTS_SOURCE, ringPath, type Ring } from '../../lib/bdDistricts'

/* The synth world spells two districts the way the boundary file does not. Mapping them here
   rather than renaming either source keeps both readable as what they are. */
const ALIAS: Record<string, string> = {
  Chattogram: 'Chittagong',
  Barishal: 'Barisal',
  Cumilla: 'Comilla',
  Jashore: 'Jessore',
  Bogura: 'Bogra',
}

const onMap = (district: string) => ALIAS[district] ?? district

/* The shapes arrive in degrees; this map fits the whole country to its own box, with one scale on
   both axes so the country is not stretched. */
const W = 420
const H = 340
const PAD = 10
const SCALE = Math.min(
  (W - 2 * PAD) / (BD_BOUNDS.east - BD_BOUNDS.west),
  (H - 2 * PAD) / (BD_BOUNDS.north - BD_BOUNDS.south),
)
const OX = (W - (BD_BOUNDS.east - BD_BOUNDS.west) * SCALE) / 2
const OY = (H - (BD_BOUNDS.north - BD_BOUNDS.south) * SCALE) / 2
const project = (lon: number, lat: number): [number, number] => [
  OX + (lon - BD_BOUNDS.west) * SCALE,
  OY + (BD_BOUNDS.north - lat) * SCALE,
]

/** The centroid of a ring, for placing a label without a second table of coordinates. */
function centroid(ring: Ring): [number, number] {
  let sx = 0
  let sy = 0
  for (const [lon, lat] of ring) {
    const [px, py] = project(lon, lat)
    sx += px
    sy += py
  }
  return ring.length ? [sx / ring.length, sy / ring.length] : [0, 0]
}

export function CampaignMap({ attempts }: { attempts: CampaignAttempt[] }) {
  const ct = useCT()
  const { lang } = useT()

  const senders = new Map<string, Set<string>>()
  const tries = new Map<string, number>()
  for (const a of attempts) {
    const district = a.sender_district ?? ''
    senders.set(district, (senders.get(district) ?? new Set<string>()).add(a.sender))
    tries.set(district, (tries.get(district) ?? 0) + 1)
  }
  const payeeDistricts = new Set(
    attempts.map((a) => a.payee_district).filter((d): d is string => Boolean(d)).map(onMap),
  )
  const unknown = senders.get('')?.size ?? 0

  // Counts keyed by the name the map uses, so a renamed district still finds its shape.
  const byShape = new Map<string, { count: number; attempts: number; label: string }>()
  for (const [district, set] of senders) {
    if (!district) continue
    const key = onMap(district)
    byShape.set(key, { count: set.size, attempts: tries.get(district) ?? 0, label: district })
  }
  const busiest = Math.max(1, ...[...byShape.values()].map((v) => v.count))
  const name = (district: string) => (lang === 'bn' ? DISTRICT_BN[district] ?? district : district)

  return (
    <svg className="cv-svg" viewBox="0 0 420 340" role="img" aria-label={`${ct('cv.map')}: ${ct('cv.map.legend')}`}>
      <title>{ct('cv.map.note')}</title>

      {Object.entries(BD_DISTRICTS).map(([shape, ring]) => {
        const hit = byShape.get(shape)
        // Shade by share of the busiest district, so the scale is the incident's own.
        const strength = hit ? 0.22 + (hit.count / busiest) * 0.58 : 0
        return (
          <path
            key={shape}
            className={`cv-dist${hit ? ' on' : ''}${payeeDistricts.has(shape) ? ' payee' : ''}`}
            d={ringPath(ring, project)}
            style={hit ? { fillOpacity: strength } : undefined}
          >
            {hit && (
              <title>
                {`${hit.label}: ${hit.count} distinct senders, ${hit.attempts} attempts${
                  payeeDistricts.has(shape) ? '; payees here' : ''
                }`}
              </title>
            )}
          </path>
        )
      })}

      {/* Only the districts in the incident are named: sixty-four labels would be a wall of text
          over the thing they are labelling. Adjacent small districts - Dhaka and Gazipur, say -
          have centroids close enough that their labels land on each other, so each one that would
          collide is pushed down until it does not. */}
      {(() => {
        const placed: [number, number][] = []
        return [...byShape.entries()].map(([shape, hit]) => {
          const ring = BD_DISTRICTS[shape]
          if (!ring) return null
          const [cx, cy0] = centroid(ring)
          let cy = cy0
          while (placed.some(([px, py]) => Math.abs(px - cx) < 46 && Math.abs(py - cy) < 11)) cy += 11
          placed.push([cx, cy])
          return (
            <text key={shape} className="cv-distlabel" x={cx} y={cy} textAnchor="middle">
              {name(hit.label)} <tspan className="cv-label">{hit.count}</tspan>
            </text>
          )
        })
      })()}

      {unknown > 0 && (
        <text className="cv-distlabel" x={10} y={326} textAnchor="start">
          {ct('cv.unknown')} {unknown}
        </text>
      )}
      <text className="cv-credit" x={410} y={334} textAnchor="end">
        {BD_DISTRICTS_SOURCE}
      </text>
    </svg>
  )
}
