#!/usr/bin/env python3
"""Write the two cruise routes for a city package.

Usage: python3 Tools/make_routes.py Cities/Chicago

Reads routes/river_chains.json and landmarks.json (both written by fetch_city.py and gullfire-pack),
and writes routes/river.json and routes/scenic.json. Nothing is typed from memory: every coordinate
comes from the river centreline or the landmark list.
"""
import json
import math
import os
import sys

KT = 0.514444


def resample(points, step):
    """Points every `step` metres of arc length along a polyline, including the last point."""
    out = [points[0]]
    carry = 0.0
    for (ax, ay), (bx, by) in zip(points, points[1:]):
        seg = math.hypot(bx - ax, by - ay)
        d = step - carry
        while d <= seg:
            f = d / seg
            out.append([ax + (bx - ax) * f, ay + (by - ay) * f])
            d += step
        carry = seg - (d - step)
    if math.hypot(out[-1][0] - points[-1][0], out[-1][1] - points[-1][1]) > 1:
        out.append(points[-1])
    return out


def load(path):
    with open(path) as fh:
        return json.load(fh)


def main_path(city):
    """Scenic for a city whose config names its river (Vienna), built from the joined river path.

    Inbound along the river at 70 m from its eastern end, then east at 450 m over the tallest named
    towers (visited nearest first from where the river ends), then back down to the start. Every
    waypoint is kept 600 m inside the package edge, and the river is followed only where it lies
    inside that margin.
    """
    routes = os.path.join(city, "routes")
    doc = load(os.path.join(routes, "river_chains.json"))
    landmarks = load(os.path.join(city, "landmarks.json"))["landmarks"]
    ext = load(os.path.join(city, "manifest.json"))["extentM"]
    margin = 600.0
    lo_e, hi_e = ext["minEast"] + margin, ext["maxEast"] - margin
    lo_n, hi_n = ext["minNorth"] + margin, ext["maxNorth"] - margin
    path = [p for p in resample(doc["path"], 420.0) if lo_e <= p[0] <= hi_e and lo_n <= p[1] <= hi_n]
    start, end = path[0], path[-1]
    wp = [{"east": start[0], "north": start[1], "alt": 250, "speedKt": 90}]
    wp += [{"east": e, "north": n, "alt": 70, "speedKt": 80} for e, n in path[1:]]
    left = sorted(landmarks, key=lambda l: -l["heightM"])[:4]
    here = end
    while left:
        lm = min(left, key=lambda l: math.dist(here, (l["east"], l["north"])))
        left.remove(lm)
        wp.append({"east": lm["east"], "north": lm["north"] + 200, "alt": 450, "speedKt": 90})
        here = (lm["east"], lm["north"])
    wp.append({"east": start[0] - 300, "north": start[1] + 2000, "alt": 300, "speedKt": 90})
    wp.append({"east": start[0], "north": start[1] + 900, "alt": 200, "speedKt": 90})
    for w in wp:
        w["east"] = min(max(w["east"], lo_e), hi_e)
        w["north"] = min(max(w["north"], lo_n), hi_n)
    with open(os.path.join(routes, "scenic.json"), "w") as fh:
        json.dump({"name": "Scenic", "closed": True, "waypoints": wp}, fh, indent=1)
        fh.write("\n")
    print("scenic.json", len(wp), "waypoints")


def main(city):
    routes = os.path.join(city, "routes")
    doc = load(os.path.join(routes, "river_chains.json"))
    if "path" in doc:
        return main_path(city)
    chains = doc["chains"]
    landmarks = load(os.path.join(city, "landmarks.json"))["landmarks"]
    # The main stem west from the lake to the fork, then the longer branch.
    # Chain 0 is the longest; its start is the fork. The main stem is the chain that ends at the fork.
    branch = chains[0]["points"]
    fork = branch[0]
    stem = next(c["points"] for c in chains[1:] if math.dist(c["points"][-1], fork) < 120)
    main_stem = stem + branch[1:]          # lake end, west to the fork, then down the branch

    east_end = main_stem[0]                # the lake end of the main stem (the river mouth)

    # Waypoints every ~420 m of arc length (the smoothed centreline has ~7 m between points).
    river_pts = resample(main_stem, 420.0)

    # --- River loop (8.3): down the stem at 60 m, back high along a line 600 m north.
    offset = 600.0
    river_wp = [{"east": e, "north": n, "alt": 60, "speedKt": 90} for e, n in river_pts]
    west_e, west_n = river_pts[-1]
    back = [{"east": e, "north": n + offset, "alt": 350, "speedKt": 90}
            for e, n in reversed(river_pts)]
    river = {"name": "River", "closed": True, "waypoints": river_wp + back}

    # --- Scenic (8.2): lake, the river at 70 m, over the tallest towers at 450 m, back along the lake.
    top = sorted(landmarks, key=lambda l: -l["heightM"])[:3]
    scenic_wp = [{"east": east_end[0] + 1500, "north": east_end[1], "alt": 250, "speedKt": 90},
                 {"east": east_end[0], "north": east_end[1], "alt": 80, "speedKt": 90}]
    # Scenic follows the main stem only, down to the fork.
    stem_pts = resample(stem, 420.0)[1:]
    scenic_wp += [{"east": e, "north": n, "alt": 70, "speedKt": 80} for e, n in stem_pts]
    for lm in top:
        # 200 m north of each tower, 450 m up: within 300 m of the tallest entries (8.2 step 4).
        scenic_wp.append({"east": lm["east"], "north": lm["north"] + 200, "alt": 450, "speedKt": 90})
    scenic_wp.append({"east": east_end[0] + 1200, "north": east_end[1] + 1400, "alt": 300, "speedKt": 90})
    scenic_wp.append({"east": east_end[0] + 1400, "north": east_end[1] - 400, "alt": 150, "speedKt": 90})
    # Keep every scenic waypoint 600 m inside the package edge (the boundary guard turns back within
    # 400 m, and the clamp must never move the aircraft). The lake start is clamped the same way.
    ext = load(os.path.join(city, "manifest.json"))["extentM"]
    margin = 600.0
    for w in scenic_wp:
        w["east"] = min(max(w["east"], ext["minEast"] + margin), ext["maxEast"] - margin)
        w["north"] = min(max(w["north"], ext["minNorth"] + margin), ext["maxNorth"] - margin)
    scenic = {"name": "Scenic", "closed": True, "waypoints": scenic_wp}

    # River is written by `gullfire-pack routes` (PLAN 8.3 step 5: its altitude profile comes from the
    # obstacle grid and FlightTuning, which Python cannot read). Only Scenic is written here.
    for name, data in (("scenic.json", scenic),):
        with open(os.path.join(routes, name), "w") as fh:
            json.dump(data, fh, indent=1)
            fh.write("\n")
        print(name, len(data["waypoints"]), "waypoints")


if __name__ == "__main__":
    main(sys.argv[1])
