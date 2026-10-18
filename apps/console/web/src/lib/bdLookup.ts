/**
 * Which district a point is in, from the boundary rings.
 *
 * The country view shades whole districts, so it never needs this. The cash-out zoom does: an
 * eighteen-kilometre box is almost always inside one district with no border crossing it, so
 * drawing the boundaries there shows nothing at all. What it can say is the name of the place you
 * are looking at, which the zoom otherwise never does.
 */

import { BD_DISTRICTS, type Ring } from './bdDistricts'

/** Ray casting. The rings are simplified, so a point within a few hundred metres of a border can
    land either side - which is why this is used for a caption and never for a decision. */
function inside(lon: number, lat: number, ring: Ring): boolean {
  let hit = false
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i, i += 1) {
    const [xi, yi] = ring[i]!
    const [xj, yj] = ring[j]!
    if (yi > lat !== yj > lat && lon < ((xj - xi) * (lat - yi)) / (yj - yi) + xi) hit = !hit
  }
  return hit
}

/** The district containing this point, or null when it falls outside every ring. */
export function districtAt(lon: number, lat: number): string | null {
  for (const [name, ring] of Object.entries(BD_DISTRICTS)) {
    if (inside(lon, lat, ring)) return name
  }
  return null
}
