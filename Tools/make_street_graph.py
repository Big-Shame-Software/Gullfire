#!/usr/bin/env python3
"""Writes <city>/streets.json: the vetted straight stretches of a city package.

Uses the generator's own candidate search (make_street_routes.find_candidates), unchanged, with the same
default arguments as Spikes/engine/scale_count.py. Each stretch is open, straight, at least 600 m, and clear
at 15 m altitude. The file is optional; the app reads it when present.

Usage (from the repo root):
  uv run --offline --with numpy --with shapely python -I Tools/make_street_graph.py <city folder> [--max-gb 12]
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import numpy as np                                              # noqa: E402,F401
import make_street_routes as M                                  # noqa: E402


class A:                   # the generator's default arguments (as in Spikes/engine/scale_count.py)
    alt, margin, halfwidth, speed, join_speed = 15.0, 10.0, 6.0, 40.0, 60.0
    # Wider than the street routes' 600 m / 150 m: stretches of 300 m or more (the stretch-length rule in the app drops any that
    # are too short for the climbs a join asks of them), joins over towers up to 450 m, and bends of up to 30 m from a straight line.
    min_run, max_join, max_climb, max_top = 300.0, 2500.0, 400.0, 450.0


FORMAT = 1
M.RUN_STRAIGHT = 30.0      # metres a stretch may stray from its chord (the street routes use 12)


def r1(x):
    return round(float(x), 4)


def main(city, max_gb, min_run=None, bend=None, out_path=None):
    city = os.path.abspath(city)
    M.GUARD.max_gb = max_gb
    args = A()
    if min_run is not None:
        args.min_run = min_run
    if bend is not None:
        M.RUN_STRAIGHT = bend
    m, g, grid, to_local = M.load_city(city)
    e = m["extentM"]
    edge = (e["minEast"] + M.BOUNDARY_MARGIN, e["maxEast"] - M.BOUNDARY_MARGIN,
            e["minNorth"] + M.BOUNDARY_MARGIN, e["maxNorth"] - M.BOUNDARY_MARGIN)
    streets, over = M.read_segments(city, m, to_local)
    polys, heights = M.read_footprints(city, m, to_local)
    fps = M.Footprints(polys, heights)
    cands = M.find_candidates(streets, over, grid, g, fps, args, edge)

    stretches = []
    for c in cands:
        flat = []
        for east, north in c["pts"]:
            flat.append(r1(east))
            flat.append(r1(north))
        stretches.append({
            "id": c["id"],
            "class": c["cls"],
            "names": list(c["names"]),
            "length": r1(c["len"]),
            "points": flat,
        })

    out = {"format": FORMAT, "altitude": args.alt, "spacing": 10.0, "stretches": stretches}
    path = out_path or os.path.join(city, "streets.json")
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w") as f:
        json.dump(out, f, separators=(",", ":"))

    km = sum(c["len"] for c in cands) / 1000
    size_kb = os.path.getsize(path) / 1024
    print(f"{os.path.basename(city)}: {len(stretches)} stretches, {km:.1f} km, {size_kb:.0f} KB written to {path}")


if __name__ == "__main__":
    a = sys.argv[1:]
    if not a or a[0].startswith("--"):
        sys.exit("usage: make_street_graph.py <city folder> [--max-gb 12] [--min-run 300] [--bend 30] [--out file]")
    opt = lambda name, cast: cast(a[a.index(name) + 1]) if name in a else None
    main(a[0], opt("--max-gb", float) or 12.0, opt("--min-run", float), opt("--bend", float), opt("--out", str))
