"""Pull the real streets and place names around the agent tills, for the cash-out zoom.

The zoomed map is an eighteen-kilometre box around one till. District boundaries cannot help it:
a district is tens of kilometres across, so its outline encloses the whole box and never crosses
it - the frame stayed empty graph paper no matter how good the boundary file was. What a reader
needs at this scale is what is actually on the ground: roads, rivers, and the names of the places
the tills sit in.

Source: OpenStreetMap, ODbL 1.0.  https://www.openstreetmap.org/copyright
The licence requires attribution, which the map carries on screen.

Run:  python3 tools/build_bd_local.py > web/src/lib/bdLocal.ts

Nothing is fetched at request time - same rule the district file follows. This script runs by hand
when the seed moves, and its output ships in the bundle.

What it does, and why:

* reads the points the zoom can actually be pointed at out of the cash-out fixture - the flagged
  tills and the replayed cluster centres - rather than all forty agent tills. There are eight of
  them and they sit in two places, Sylhet and Bhola, so this is three boxes instead of twenty-one.
  Ground no one can navigate to is ground nobody should pay to download;
* groups tills that are near each other into one query box, because the eight places they sit in
  overlap heavily and querying forty boxes would fetch the same roads forty times;
* snaps those boxes to a coarse grid and drops the duplicates, so two flags in the same
  neighbourhood fetch that neighbourhood once;
* asks for them one at a time, with a pause between. Three at once had the mirrors returning 500
  and 429 more often than data - Overpass is a shared public service, and this is a build step
  that can afford to be slow;
* caches each answer on disk, and when a mirror will not answer for a box it says so loudly and
  carries on with the rest. The public instances go down and come back through the day; a box
  that failed this afternoon is one `python3 tools/build_bd_local.py` away from being filled in,
  because every box that did work is still in the cache. The emitted header counts what is
  missing, so a thin file can never pass for a complete one. Delete the cache to force a fresh
  pull;
* keeps only the roads that read at this scale - motorway down to tertiary - and the waterways,
  which in this delta are how you tell one place from the next. Residential streets are dropped on
  purpose: they were two thirds of every point fetched, and at 33 metres to the pixel they are a
  grey mush rather than information;
* simplifies with Douglas-Peucker at about one pixel and rounds to four decimals, for the same
  reason - finer than that is detail nobody can see and bytes everybody pays for;
* keeps both the local name and the English one where OSM has them, because the console is
  bilingual and a Bangla label on an English page helps nobody.
"""

from __future__ import annotations

import hashlib
import json
import math
import subprocess
import sys
import time
from pathlib import Path

FIXTURE = "fixtures/cashout.json"

# Public Overpass instances, tried in turn. The main endpoint is often at capacity and the
# mirrors take turns being down, so a failure moves to the next one rather than giving up. Note
# that overpass.osm.ch is NOT usable here: it carries Switzerland only and answers a Bangladesh
# box with a cheerful empty list rather than an error.
ENDPOINTS = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
    "https://overpass.private.coffee/api/interpreter",
]
AGENT = "finnest-admin-build/1.0 (one-off extract for a hackathon console)"

# Answers land here so a re-run picks up where a dead mirror left off. Not checked in.
CACHE = Path(__file__).with_name(".osm-cache")

# How far the zoom can see from its focus: half the diagonal of the 18 km box, plus the two
# kilometres a till's spiral of cash-outs is allowed to reach past the edge.
REACH_KM = math.sqrt(2) * 18 / 2 + 2
# About 33 m, which is one pixel of the 540 px box the zoom draws into.
TOLERANCE = 0.0003
PRECISION = 4              # degrees; about 11 m, finer than the simplification above

ROADS = "motorway|trunk|primary|secondary|tertiary"
WATER = "river|stream|canal"
PLACES = "city|town|village|suburb|neighbourhood|hamlet|quarter"

# Roads are drawn in three weights. Anything not named here is the thin one.
MAJOR = {"motorway", "trunk", "primary"}
MINOR = {"secondary", "tertiary"}


def km_per_degree(lat: float) -> tuple[float, float]:
    """Longitude degrees shrink towards the poles; at this latitude the difference is about 9%."""
    return 111.32 * math.cos(math.radians(lat)), 110.57


def distance_km(a: tuple[float, float], b: tuple[float, float]) -> float:
    kx, ky = km_per_degree((a[1] + b[1]) / 2)
    return math.hypot((a[0] - b[0]) * kx, (a[1] - b[1]) * ky)


def simplify(points: list[tuple[float, float]], tol: float) -> list[tuple[float, float]]:
    """Douglas-Peucker, the same one the district file uses, at a far finer tolerance."""
    if len(points) < 3:
        return points
    first, last = points[0], points[-1]
    dx, dy = last[0] - first[0], last[1] - first[1]
    norm = math.hypot(dx, dy)
    worst, index = 0.0, 0
    for i in range(1, len(points) - 1):
        px, py = points[i]
        if norm == 0:
            d = math.hypot(px - first[0], py - first[1])
        else:
            d = abs(dy * px - dx * py + last[0] * first[1] - last[1] * first[0]) / norm
        if d > worst:
            worst, index = d, i
    if worst <= tol:
        return [first, last]
    return simplify(points[: index + 1], tol)[:-1] + simplify(points[index:], tol)


# Box centres are snapped to this grid before being deduplicated: two tills in the same
# neighbourhood then ask for the same box, and it is only fetched once. About 11 km, comfortably
# inside the box's own reach, so snapping never moves ground out of a till's view.
SNAP = 0.1


def box(centre: tuple[float, float]) -> tuple[float, float, float, float]:
    """The query box for one centre: everything a zoom there can see, and nothing else."""
    lon, lat = centre
    kx, ky = km_per_degree(lat)
    return (lat - REACH_KM / ky, lon - REACH_KM / kx, lat + REACH_KM / ky, lon + REACH_KM / kx)


def boxes(tills: list[tuple[float, float]]) -> list[tuple[float, float]]:
    """One box centre per neighbourhood: snap to the grid, drop the duplicates, keep the order."""
    seen: dict[tuple[float, float], tuple[float, float]] = {}
    for lon, lat in tills:
        key = (round(lon / SNAP) * SNAP, round(lat / SNAP) * SNAP)
        seen.setdefault(key, key)
    return sorted(seen.values())


def ask(bbox: tuple[float, float, float, float], first: int = 0) -> dict:
    """One Overpass call, with the backoff the endpoint asks automated clients to use.

    Through curl rather than urllib: this endpoint serves a chain Python's bundled trust store
    rejects ("Missing Authority Key Identifier") while the system one accepts it, and borrowing the
    system store is the fix that does not involve turning verification off.
    """
    south, west, north, east = bbox
    area = f"{south:.4f},{west:.4f},{north:.4f},{east:.4f}"
    query = (
        "[out:json][timeout:180];("
        f'way["highway"~"^({ROADS})$"]({area});'
        f'way["waterway"~"^({WATER})$"]({area});'
        f'node["place"~"^({PLACES})$"]["name"]({area});'
        ");out geom;"
    )
    CACHE.mkdir(exist_ok=True)
    cached = CACHE / f"{hashlib.sha1(query.encode()).hexdigest()[:16]}.json"
    if cached.exists():
        print("  (cached)", file=sys.stderr)
        return json.loads(cached.read_text())

    for attempt in range(12):
        endpoint = ENDPOINTS[(first + attempt) % len(ENDPOINTS)]
        done = subprocess.run(
            ["curl", "-sS", "-m", "300", "-A", AGENT, "-X", "POST", endpoint,
             "--data-urlencode", f"data={query}"],
            capture_output=True,
            text=True,
        )
        if done.returncode == 0 and done.stdout.lstrip().startswith("{"):
            answer = json.loads(done.stdout)
            if answer.get("elements"):
                cached.write_text(json.dumps(answer))
                return answer
            why = f"{endpoint} returned nothing for this box"
        else:
            why = (done.stderr or done.stdout[:120]).strip().replace("\n", " ")[:90]
        wait = min(10 * 2 ** (attempt // len(ENDPOINTS)), 60)
        print(f"  attempt {attempt + 1}/30: {why}; next mirror in {wait}s", file=sys.stderr)
        time.sleep(wait)
    return {}  # the caller reports the gap; the boxes that worked are cached and still good


def main() -> None:
    fixture = json.load(open(FIXTURE))
    tills = {t["id"]: (t["lon"], t["lat"]) for t in fixture["tills"]}
    clusters = {c["cluster_id"]: (c["centre_lon"], c["centre_lat"]) for c in fixture["clusters"]}
    focus: set[tuple[float, float]] = set()
    for day in fixture["days"]:
        focus.update(tills[flag["id"]] for flag in day.get("till_flags", []) if flag["id"] in tills)
        focus.update(clusters[cid] for cid in day.get("clusters", []) if cid in clusters)
    points = sorted(focus)
    print(f"{len(points)} points the zoom can be pointed at", file=sys.stderr)

    roads: dict[int, tuple[str, list[tuple[float, float]]]] = {}
    water: dict[int, list[tuple[float, float]]] = {}
    places: dict[int, tuple[float, float, str, str, str]] = {}

    centres = boxes(points)
    print(f"  {len(centres)} boxes after snapping to {SNAP} degrees", file=sys.stderr)

    missed: list[tuple[float, float]] = []
    for index, centre in enumerate(centres, 1):
        print(f"  box {index}/{len(centres)}", file=sys.stderr)
        answer = ask(box(centre), first=index % len(ENDPOINTS))
        if not answer:
            missed.append(centre)
            print(f"  !! box {index} unanswered: {centre[1]:.2f}, {centre[0]:.2f}", file=sys.stderr)
            continue
        for element in answer["elements"]:
            tags = element.get("tags", {})
            if element["type"] == "node":
                name = tags.get("name:en") or tags.get("name", "")
                places[element["id"]] = (element["lon"], element["lat"], tags.get("name", name), name, tags["place"])
                continue
            geometry = [(point["lon"], point["lat"]) for point in element.get("geometry", [])]
            if len(geometry) < 2:
                continue
            if "waterway" in tags:
                water[element["id"]] = geometry
            else:
                roads[element["id"]] = (tags["highway"], geometry)
        time.sleep(5)  # a shared public service; do not stand on it

    def thin(line: list[tuple[float, float]]) -> list[list[float]]:
        return [[round(x, PRECISION), round(y, PRECISION)] for x, y in simplify(line, TOLERANCE)]

    major = [thin(line) for kind, line in roads.values() if kind in MAJOR]
    minor = [thin(line) for kind, line in roads.values() if kind in MINOR]
    local = [thin(line) for kind, line in roads.values() if kind not in MAJOR | MINOR]
    rivers = [thin(line) for line in water.values()]
    named = sorted(places.values(), key=lambda p: (p[4], p[3]))

    total = sum(len(line) for group in (major, minor, local, rivers) for line in group)
    print(
        f"{len(major)} major, {len(minor)} minor, {len(local)} local roads, "
        f"{len(rivers)} waterways, {len(named)} places, {total} points",
        file=sys.stderr,
    )

    out = sys.stdout
    out.write('/**\n')
    out.write(' * The ground around the agent tills: roads, waterways and place names.\n')
    out.write(' *\n')
    out.write(' * Generated by tools/build_bd_local.py from OpenStreetMap, ODbL 1.0 -\n')
    out.write(' * https://www.openstreetmap.org/copyright. Do not edit by hand; re-run the script.\n')
    out.write(' *\n')
    if missed:
        out.write(' * INCOMPLETE: no mirror answered for ')
        out.write(", ".join(f"{lat:.2f},{lon:.2f}" for lon, lat in missed))
        out.write('.\n * Re-run the script to fill those in; everything else is cached and will not be refetched.\n *\n')
    out.write(f' * {len(major)} major, {len(minor)} minor and {len(local)} local roads,\n')
    out.write(f' * {len(rivers)} waterways and {len(named)} named places, {total} points in all,\n')
    out.write(f' * simplified at {TOLERANCE} degrees - about 33 m, one pixel of the zoomed box.\n')
    out.write(f' * Covers only what a zoom can see from the {len(points)} points it can be pointed at.\n')
    out.write(' *\n')
    out.write(' * Degrees, not pixels: the zoom shares its projection with the tills it draws.\n')
    out.write(' */\n\n')
    out.write('export type Line = [number, number][]\n')
    out.write('export type Place = { lon: number; lat: number; name: string; en: string; kind: string }\n\n')
    for label, group in (("MAJOR_ROADS", major), ("MINOR_ROADS", minor), ("LOCAL_ROADS", local), ("WATERWAYS", rivers)):
        out.write(f'export const {label}: Line[] = {json.dumps(group, separators=(",", ":"))}\n\n')
    out.write('export const PLACES: Place[] = ')
    out.write(
        json.dumps(
            [{"lon": lon, "lat": lat, "name": name, "en": en, "kind": kind} for lon, lat, name, en, kind in named],
            ensure_ascii=False,
            separators=(",", ":"),
        )
    )
    out.write('\n\n')
    out.write("export const BD_LOCAL_SOURCE = 'Map data: OpenStreetMap contributors, ODbL'\n")


if __name__ == "__main__":
    main()
