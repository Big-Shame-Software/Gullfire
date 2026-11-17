#!/usr/bin/env python3
"""Prepare a city package's raw inputs.

Usage:  uv run --with overturemaps --with shapely Tools/fetch_city.py chicago

Downloads four Overture Maps layers for the city's bounding box (skipped when
already present), clips water to the box, derives the river centreline chains
and writes raw/source.json. The app never runs this; it is a preparation step.
Output lives in Cities/<city>/ which is git-ignored.
"""
import collections
import datetime
import json
import math
import os
import subprocess
import sys

import numpy as np
import shapely
from shapely.geometry import MultiLineString, box, mapping, shape
from shapely.ops import linemerge, unary_union

CITIES = {
    "chicago": {
        "name": "Chicago",
        "bbox": (-87.670, 41.850, -87.600, 41.920),
        "origin": (-87.635, 41.885),  # lon0, lat0
    },
    "chicagowide": {
        "name": "ChicagoWide",
        "bbox": (-87.720, 41.848, -87.600, 41.925),   # about 85 km², lakefront, Cermak to Fullerton
        "origin": (-87.635, 41.885),                  # the same origin as Chicago, so the two share a frame
    },
    "chicagowider": {
        "name": "ChicagoWider",
        "bbox": (-87.740, 41.848, -87.600, 41.935),   # about 112 km²: ChicagoWide plus 2 km west and 1 km north (rung A, next ring)
        "origin": (-87.635, 41.885),
    },
    "chicagocity": {
        "name": "ChicagoCity",
        "bbox": (-87.945, 41.640, -87.520, 42.025),   # about 1,450 km²: the city limits and the suburbs in the rectangle (rung B)
        "origin": (-87.635, 41.885),
    },
    "cookcounty": {
        "name": "CookCounty",
        "bbox": (-88.270, 41.465, -87.520, 42.160),   # about 4,500 km²: Cook County and the neighbours inside the rectangle (rung C)
        "origin": (-87.635, 41.885),
    },
    "vienna": {
        "name": "Vienna",
        "bbox": (16.3396, 48.1788, 16.4204, 48.2512),  # 6 x 8 km about the origin
        "origin": (16.380, 48.215),
        # The Donaukanal runs along the old centre. It arrives as two chains with a gap of about
        # 60 m at the Wien junction, so the path is joined by name (see river_path).
        "river": "Donaukanal",
    },
}

LAYERS = ["building", "building_part", "water", "segment"]
WATER_POLY = ("lake", "river", "water", "canal")
RIVER_LINE = ("river", "canal")
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))


def local_frame(origin):
    """Return a function mapping an (N, 2) lon/lat array to metres east/north."""
    lon0, lat0 = origin
    kx = math.cos(math.radians(lat0)) * 111320.0
    ky = 110574.0

    def to_local(coords):
        arr = np.asarray(coords, dtype=float)
        return np.column_stack([(arr[:, 0] - lon0) * kx, (arr[:, 1] - lat0) * ky])

    return to_local


def read_lines(path):
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if line:
                yield json.loads(line)


def download(city, layer, raw_dir):
    out = os.path.join(raw_dir, f"{layer}.geojsonl")
    if os.path.exists(out):
        return out
    minx, miny, maxx, maxy = city["bbox"]
    cmd = [
        "overturemaps", "download",
        f"--bbox={minx},{miny},{maxx},{maxy}",
        "-f", "geojsonseq",
        f"--type={layer}",
        "-o", out,
    ]
    print("downloading", layer, flush=True)
    subprocess.run(cmd, check=True)
    return out


def release_from_state(raw_dir):
    """Read the Overture release name from the .state file written by the download."""
    state = os.path.join(raw_dir, "building.geojsonl.state")
    with open(state) as fh:
        return json.load(fh)["last_release"]


def clip_water(city, raw_dir, to_local):
    """Write raw/water_clipped.geojsonl: water features clipped to the box, in lon/lat."""
    clip = box(*city["bbox"])
    kept = collections.Counter()
    out_path = os.path.join(raw_dir, "water_clipped.geojsonl")
    with open(out_path, "w") as out:
        for feat in read_lines(os.path.join(raw_dir, "water.geojsonl")):
            props = feat["properties"]
            subtype = props.get("subtype")
            geom = shape(feat["geometry"])
            is_poly = geom.geom_type in ("Polygon", "MultiPolygon") and subtype in WATER_POLY
            is_line = geom.geom_type == "LineString" and subtype in RIVER_LINE
            if not (is_poly or is_line):  # human_made, reservoir, pond and others are excluded
                continue
            clipped = geom.intersection(clip)
            if clipped.is_empty:
                continue
            kept[(subtype, clipped.geom_type)] += 1
            out.write(json.dumps({
                "type": "Feature",
                "properties": {"subtype": subtype,
                               "name": (props.get("names") or {}).get("primary")},
                "geometry": mapping(clipped),
            }) + "\n")
    print("water kept:", dict(kept), flush=True)
    return out_path


def resample(line, step):
    n = int(line.length // step)
    return [line.interpolate(i * step) for i in range(n + 1)]


def chaikin(points, rounds=3):
    for _ in range(rounds):
        out = [points[0]]
        for a, b in zip(points, points[1:]):
            out.append((0.75 * a[0] + 0.25 * b[0], 0.75 * a[1] + 0.25 * b[1]))
            out.append((0.25 * a[0] + 0.75 * b[0], 0.25 * a[1] + 0.75 * b[1]))
        points = out + [points[-1]]
    return points


def derive_river(city, raw_dir, to_local, out_dir):
    """Chain river centrelines into runs.

    Writes routes/river_chains.json. Closing the loop (8.3 step 4) and the
    tall-building check (step 5) belong to the M4 route work; they are not here.
    """
    (x0, y0), (x1, y1) = to_local(np.array([city["bbox"][:2], city["bbox"][2:]]))
    clip_local = box(x0, y0, x1, y1)
    lines = []
    for feat in read_lines(os.path.join(raw_dir, "water_clipped.geojsonl")):
        if feat["geometry"]["type"] != "LineString" or feat["properties"]["subtype"] not in RIVER_LINE:
            continue
        ls = shapely.transform(shape(feat["geometry"]), to_local)
        clipped = ls.intersection(clip_local)
        if not clipped.is_empty:
            lines.append((feat["properties"].get("name"), clipped))
    # unary_union dissolves duplicated and overlapping centrelines before merging,
    # as the verified river spike does; without it the chain lengths differ.
    merged = linemerge(unary_union([l for _, l in lines])) if lines else None
    chains = []
    if merged is not None:
        parts = list(merged.geoms) if merged.geom_type == "MultiLineString" else [merged]
        for part in sorted(parts, key=lambda l: -l.length):
            pts = [(p.x, p.y) for p in resample(part, 60.0)]
            smooth = chaikin(pts)
            chains.append({
                "lengthM": round(part.length),
                "points": [[round(x, 1), round(y, 1)] for x, y in smooth],
            })
    names = sorted({n for n, _ in lines if n})
    route_dir = os.path.join(out_dir, "routes")
    os.makedirs(route_dir, exist_ok=True)
    doc = {"formatVersion": 1, "status": "centreline only; loop closure is M4",
           "riverNames": names, "chains": chains}
    path, shift = river_path(city, lines, (x0, y0, x1, y1))
    if path:
        doc["riverName"] = city["river"]
        doc["path"] = path
        doc["returnShift"] = shift
    with open(os.path.join(route_dir, "river_chains.json"), "w") as fh:
        json.dump(doc, fh, indent=1)
    print("river chains (m):", [c["lengthM"] for c in chains], flush=True)
    return len(chains)


PATH_MARGIN = 600.0      # River low leg stays this far inside the edge (the boundary guard acts within 400 m)
JOIN_GAP = 120.0         # chains of the named river closer than this are joined end to end
RETURN_SHIFT = 600.0     # sideways distance of the high return leg


def river_path(city, lines, extent):
    """One path for the river named in the city config, plus the shift of the return leg.

    `lines` is a list of (name, local LineString). Chains of that name are merged, joined end to end
    where they lie within JOIN_GAP, smoothed like the other chains, trimmed to PATH_MARGIN inside the
    package edge and oriented to start at the eastern end. The return shift is perpendicular to the
    chord from start to end, on the side where the shifted path stays inside the package.
    Returns (path, shift) or (None, None) when the config names no river.
    """
    name = city.get("river")
    if not name:
        return None, None
    named = [l for n, l in lines if n == name]
    if not named:
        raise SystemExit(f"river {name!r} not found in the water layer")
    dissolved = unary_union(named)
    merged = linemerge(dissolved) if dissolved.geom_type == "MultiLineString" else dissolved
    parts = sorted(merged.geoms if merged.geom_type == "MultiLineString" else [merged], key=lambda l: -l.length)

    def smooth(part):
        return chaikin([(p.x, p.y) for p in resample(part, 60.0)])

    path = smooth(parts[0])
    rest = [smooth(p) for p in parts[1:] if p.length > 200]
    joined = True
    while joined and rest:
        joined = False
        for r in list(rest):
            for cand in (r, r[::-1]):
                if math.dist(path[-1], cand[0]) < JOIN_GAP:
                    path = path + cand
                elif math.dist(cand[-1], path[0]) < JOIN_GAP:
                    path = cand + path
                else:
                    continue
                rest.remove(r)
                joined = True
                break
    if rest:
        print(f"note: {len(rest)} chain(s) of {name} not joined (more than {JOIN_GAP:.0f} m away)", flush=True)

    inner = (extent[0] + PATH_MARGIN, extent[1] + PATH_MARGIN, extent[2] - PATH_MARGIN, extent[3] - PATH_MARGIN)
    inside = [inner[0] <= x <= inner[2] and inner[1] <= y <= inner[3] for x, y in path]
    best, run = (0, 0), None   # longest run of points inside the margin
    for i, ok in enumerate(inside + [False]):
        if ok and run is None:
            run = i
        elif not ok and run is not None:
            if i - run > best[1] - best[0]:
                best = (run, i)
            run = None
    path = path[best[0]:best[1]]
    if path[0][0] < path[-1][0]:
        path = path[::-1]
    (ax, ay), (bx, by) = path[0], path[-1]
    chord = math.hypot(bx - ax, by - ay)
    nx, ny = -(by - ay) / chord, (bx - ax) / chord
    margin = PATH_MARGIN + 100.0

    def fits(sx, sy):
        return sum(extent[0] + margin <= x + sx <= extent[2] - margin and extent[1] + margin <= y + sy <= extent[3] - margin
                   for x, y in path)
    shift = max(((RETURN_SHIFT * nx, RETURN_SHIFT * ny), (-RETURN_SHIFT * nx, -RETURN_SHIFT * ny)), key=lambda t: fits(*t))
    outside = len(path) - fits(*shift)
    print(f"river path {name}: {len(path)} points, {round(sum(math.dist(a, b) for a, b in zip(path, path[1:])))} m, "
          f"shift ({shift[0]:.0f}, {shift[1]:.0f}), {outside} return points outside the margin", flush=True)
    return [[round(x, 1), round(y, 1)] for x, y in path], [round(shift[0], 1), round(shift[1], 1)]


def scan_licences(raw_dir):
    """Collect every distinct source dataset in the data, with its licence.

    A source with no licence string is kept and marked "unstated": USGS Lidar
    supplies most building heights and carries none, so dropping it hid it
    from the credits.
    """
    found = collections.Counter()
    for layer in ("building.geojsonl", "building_part.geojsonl", "segment.geojsonl", "water.geojsonl"):
        path = os.path.join(raw_dir, layer)
        if not os.path.exists(path):
            continue
        for feat in read_lines(path):
            for src in (feat["properties"].get("sources") or []):
                found[(src.get("dataset"), src.get("license"))] += 1
    entries = [{"dataset": d or "unnamed", "license": l or "unstated", "count": n}
               for (d, l), n in found.items()]
    return sorted(entries, key=lambda e: (str(e["dataset"]), str(e["license"])))


def attribution(licences):
    """The credit line, built from the sources actually present in the data.

    OpenStreetMap and Overture are always credited. Each stated licence is named with the
    datasets under it (ODbL-1.0 covers OpenStreetMap, Microsoft ML Buildings and TomTom in
    Chicago). Any source whose licence is unstated (USGS Lidar in Chicago) is named on its own,
    because it needs crediting. The USGS 3DEP program page (usgs.gov/3d-elevation-program) says its
    products are free of charge and without use restrictions; it does not call the data public domain,
    so no licence is claimed here. The About window shows this line.
    """
    text = "Map data \u00a9 OpenStreetMap contributors, Overture Maps Foundation."
    by_licence = collections.defaultdict(set)
    for e in licences:
        if e["license"] != "unstated":
            by_licence[e["license"]].add(str(e["dataset"]))
    for lic in sorted(by_licence):
        text += f" {lic} ({', '.join(sorted(by_licence[lic]))})."
    unstated = sorted({str(e["dataset"]) for e in licences if e["license"] == "unstated"})
    if unstated:
        text += f" Building heights include {' and '.join(unstated)} data."
    return text


def main(argv):
    if len(argv) != 2 or argv[1] not in CITIES:
        print("usage: fetch_city.py <" + "|".join(CITIES) + ">", file=sys.stderr)
        return 2
    city = CITIES[argv[1]]
    city_dir = os.path.join(ROOT, "Cities", city["name"])
    raw_dir = os.path.join(city_dir, "raw")
    os.makedirs(raw_dir, exist_ok=True)
    to_local = local_frame(city["origin"])

    for layer in LAYERS:
        download(city, layer, raw_dir)
    release = release_from_state(raw_dir)
    clip_water(city, raw_dir, to_local)
    chains = derive_river(city, raw_dir, to_local, city_dir)

    minx, miny, maxx, maxy = city["bbox"]
    licences = scan_licences(raw_dir)
    source = {
        "city": city["name"],
        "bbox": {"minLon": minx, "minLat": miny, "maxLon": maxx, "maxLat": maxy},
        "origin": {"lon": city["origin"][0], "lat": city["origin"][1]},
        "overtureRelease": release,
        "generatedUtc": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "layers": LAYERS,
        "attribution": attribution(licences),
        "licences": licences,
        "riverChains": chains,
    }
    with open(os.path.join(raw_dir, "source.json"), "w") as fh:
        json.dump(source, fh, indent=2)
        fh.write("\n")
    print("wrote", os.path.join(raw_dir, "source.json"), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
