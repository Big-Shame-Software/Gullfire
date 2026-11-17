#!/usr/bin/env python3
"""Street-run routes: low flights along a city's straight streets, joined by climbs over the roofs.

Usage:
  uv run --with numpy --with shapely Tools/make_street_routes.py Cities/Chicago --seeds 1 2 3
  uv run --with numpy --with shapely Tools/make_street_routes.py Cities/Chicago --coverage 40

Design, in short:
  * Candidates are every open stretch of 600 m or more of a straight street (driving roads, joined straight on
    through intersections, minus anything within 8 m of a bridge or raised segment that is not the street itself)
    where no building taller than ALT - MARGIN stands within HALF_WIDTH of the centre line, by the obstacle grid
    and by the building footprints.
  * A route is a closed loop of some of those stretches. Between two stretches it climbs along the end of the
    street until it is above the roofs (River rule: the tallest obstacle within 20 m plus 30 m), turns above them,
    and descends along the start of the next street. There are no street-level corners.
  * Safety is proved when the route is written, on the whole sampled spline (every 10 m, as the app's Route
    samples it), not only at waypoints. A route that fails is not written: the failing stretch is dropped and the
    route is built again.
  * One seed always gives the same route. Output is the same route JSON as Scenic and River, plus a report.

Reads Cities/<City>/manifest.json, obstacles.bin and raw/ (the Overture segments and buildings). Writes
Cities/<City>/routes/street-<seed>.json and street-<seed>.report.json. Nothing here touches the network.
"""
import argparse
import collections
import json
import math
import os
import random
import subprocess
import sys

import numpy as np
from shapely.geometry import Point, Polygon
from shapely.strtree import STRtree

DRIVING = {"motorway", "trunk", "primary", "secondary", "tertiary", "residential", "unclassified", "living_street"}
G = 9.80665
KT = 0.514444
PITCH_LIMIT_DEG = 20.0            # FlightTuning.pitchLimit
PLAN_GRADIENT = 0.8 * math.tan(math.radians(PITCH_LIMIT_DEG))      # plan climbs and descents at 0.8 of the limit
CHECK_STEP = 10.0                 # Route samples every 10 m
CHAIN_TURN = 20.0                 # degrees: how straight "straight on" is at an intersection
RUN_STRAIGHT = 12.0               # metres: a run stays this close to its chord
OVERHEAD_R = 8.0                  # metres: closed within this of a bridge or raised segment (not the street itself)
BOUNDARY_MARGIN = 600.0           # keep the route this far inside the package edge (the guard acts within 400 m)
CLASS_ORDER = ["motorway", "trunk", "primary", "secondary", "tertiary", "unclassified", "residential", "living_street"]
GUARD_LINES = 50000               # read loops check the memory ceiling this often
GUARD_CHAINS = 200                # find_candidates checks it this often
GUARD_MAX_GB = 8.0                # default for --max-gb; the 27 GB run of 2026-11-15 is why this exists


# --------------------------------------------------------------------------- memory guard

def rss_gb():
    """Resident size of this process in GB (ps reports KB on macOS and Linux). 0 if ps is unavailable."""
    try:
        return int(subprocess.check_output(["ps", "-o", "rss=", "-p", str(os.getpid())]).strip()) / 1048576.0
    except (OSError, ValueError, subprocess.CalledProcessError):
        return 0.0


class MemoryGuard:
    """Stops the run, with a message naming the phase, when this process is above the ceiling. Never changes output."""

    def __init__(self, max_gb):
        self.max_gb = max_gb

    def check(self, phase):
        gb = rss_gb()
        if gb > self.max_gb:
            sys.exit(f"make_street_routes: stopped in phase '{phase}': resident {gb:.1f} GB is above --max-gb {self.max_gb:g}. "
                     f"Nothing was written for this phase.")


GUARD = MemoryGuard(GUARD_MAX_GB)


# --------------------------------------------------------------------------- data

def load_city(city):
    m = json.load(open(os.path.join(city, "manifest.json")))
    g = m["obstacleGrid"]
    grid = np.fromfile(os.path.join(city, "obstacles.bin"), dtype="<f4").reshape(g["rows"], g["cols"])
    lon0, lat0 = m["origin"]["lon"], m["origin"]["lat"]
    kx, ky = math.cos(math.radians(lat0)) * 111320.0, 110574.0

    def to_local(c):
        a = np.asarray(c, dtype=float)
        return np.column_stack([(a[:, 0] - lon0) * kx, (a[:, 1] - lat0) * ky])

    return m, g, grid, to_local


def height_near(grid, g, pts, w):
    """Tallest obstacle within about w metres of each point, from the grid."""
    c = g["cellSizeM"]
    k = int(math.ceil(w / c))
    ci = np.floor((pts[:, 0] - g["minEast"]) / c).astype(int)
    ri = np.floor((pts[:, 1] - g["minNorth"]) / c).astype(int)
    out = np.zeros(len(pts), dtype=np.float32)
    for dr in range(-k, k + 1):
        for dc in range(-k, k + 1):
            if (dr * c) ** 2 + (dc * c) ** 2 > (w + c) ** 2:
                continue
            r2, c2 = ri + dr, ci + dc
            ok = (r2 >= 0) & (r2 < g["rows"]) & (c2 >= 0) & (c2 < g["cols"])
            vals = np.zeros(len(pts), dtype=np.float32)
            vals[ok] = grid[r2[ok], c2[ok]]
            out = np.maximum(out, vals)
    return out


def flags_of(p):
    out = set()
    for key in ("road_flags", "rail_flags"):
        for r in p.get(key) or []:
            out |= set(r.get("values") or [])
    return out


def read_segments(city, m, to_local):
    e = m["extentM"]
    streets, over_pts, over_kind, over_id = [], [], [], []
    for n, line in enumerate(open(os.path.join(city, "raw", "segment.geojsonl")), 1):
        if n % GUARD_LINES == 0:
            GUARD.check("read segments")
        f = json.loads(line)
        p, geom = f["properties"], f["geometry"]
        if geom["type"] != "LineString":
            continue
        xy = to_local(geom["coordinates"])
        fl = flags_of(p)
        lv = max([r.get("value", 0) for r in (p.get("level_rules") or [])] or [0])
        overhead = ("is_tunnel" not in fl) and ("is_bridge" in fl or lv >= 1)
        near = (xy[:, 0] >= e["minEast"] - 60) & (xy[:, 0] <= e["maxEast"] + 60) & (xy[:, 1] >= e["minNorth"] - 60) & (xy[:, 1] <= e["maxNorth"] + 60)
        if overhead and near.any() and p.get("subtype") in ("road", "rail"):
            d = np.r_[0, np.cumsum(np.hypot(*np.diff(xy, axis=0).T))]
            if d[-1] > 0:
                t = np.arange(0, d[-1] + 1e-6, 2.0)
                dense = np.column_stack([np.interp(t, d, xy[:, 0]), np.interp(t, d, xy[:, 1])])
                over_pts.append(dense)
                over_kind += [0 if p["subtype"] == "rail" else 1] * len(dense)
                over_id += [f["id"]] * len(dense)
        if p.get("subtype") != "road" or p.get("class") not in DRIVING:
            continue
        inside = (xy[:, 0] >= e["minEast"]) & (xy[:, 0] <= e["maxEast"]) & (xy[:, 1] >= e["minNorth"]) & (xy[:, 1] <= e["maxNorth"])
        if inside.sum() < 2:
            continue
        best, start = (0, 0), None
        for i, ok in enumerate(list(inside) + [False]):
            if ok and start is None:
                start = i
            if not ok and start is not None:
                if i - start > best[1] - best[0]:
                    best = (start, i)
                start = None
        xy = xy[best[0]:best[1]]
        if len(xy) >= 2:
            streets.append({"xy": xy, "cls": p["class"], "name": (p.get("names") or {}).get("primary") or "", "id": f["id"]})
    over = {"pts": np.vstack(over_pts) if over_pts else np.zeros((0, 2)), "id": np.array(over_id)}
    return streets, over


def read_footprints(city, m, to_local):
    e = m["extentM"]
    polys, heights = [], []
    for n, line in enumerate(open(os.path.join(city, "raw", "building.geojsonl")), 1):
        if n % GUARD_LINES == 0:
            GUARD.check("read footprints")
        f = json.loads(line)
        g = f["geometry"]
        rings = [g["coordinates"]] if g["type"] == "Polygon" else (g["coordinates"] if g["type"] == "MultiPolygon" else [])
        p = f["properties"]
        h = p.get("height")
        if h is None and p.get("num_floors"):
            h = p["num_floors"] * 3.4
        if h is None:
            h = 6.0
        for poly in rings:
            xy = to_local(poly[0])
            if xy[:, 0].max() < e["minEast"] - 50 or xy[:, 0].min() > e["maxEast"] + 50 or xy[:, 1].max() < e["minNorth"] - 50 or xy[:, 1].min() > e["maxNorth"] + 50:
                continue
            if len(xy) >= 4:
                pg = Polygon(xy)
                if pg.is_valid and not pg.is_empty:
                    polys.append(pg)
                    heights.append(float(h))
    return polys, np.array(heights)


# --------------------------------------------------------------------------- streets to runs

def heading_of(a, b):
    return math.degrees(math.atan2(b[0] - a[0], b[1] - a[1]))


def turn_between(h1, h2):
    return abs((h2 - h1 + 180) % 360 - 180)


def chains(streets):
    key = lambda p: (round(p[0]), round(p[1]))
    ends = collections.defaultdict(list)
    for i, s in enumerate(streets):
        ends[key(s["xy"][0])].append((i, 0))
        ends[key(s["xy"][-1])].append((i, 1))

    def out_heading(i, which):
        xy = streets[i]["xy"]
        k = min(3, len(xy) - 1)
        return heading_of(xy[0], xy[k]) if which == 0 else heading_of(xy[-1], xy[-1 - k])

    link = {}
    for items in ends.values():
        for a in items:
            best, best_t = None, CHAIN_TURN
            for b in items:
                if a[0] == b[0]:
                    continue
                t = turn_between(out_heading(*a), out_heading(*b) + 180)
                if t <= best_t:
                    best, best_t = b, t
            if best is not None:
                link[a] = best
    used, out = set(), []
    for i in range(len(streets)):
        if i in used:
            continue
        cur, which, seen = i, 0, {i}
        while (cur, which) in link and link[(cur, which)] in link and link[link[(cur, which)]] == (cur, which):
            nxt = link[(cur, which)]
            if nxt[0] in seen:
                break
            seen.add(nxt[0])
            cur, which = nxt[0], 1 - nxt[1]
        pts, names, classes, ids, seen2 = [], [], [], [], set()
        c, leave = cur, 1 - which
        while True:
            seen2.add(c)
            xy = streets[c]["xy"] if leave == 1 else streets[c]["xy"][::-1]
            pts.append(xy if not pts else xy[1:])
            names.append(streets[c]["name"])
            classes.append(streets[c]["cls"])
            ids.append(streets[c]["id"])
            nxt = link.get((c, leave))
            if nxt is None or link.get(nxt) != (c, leave) or nxt[0] in seen2:
                break
            c, leave = nxt[0], 1 - nxt[1]
        used |= seen2
        out.append({"xy": np.vstack(pts), "names": names, "classes": classes, "ids": set(ids)})
    return out


def resample(xy, step):
    d = np.r_[0, np.cumsum(np.hypot(*np.diff(xy, axis=0).T))]
    t = np.arange(0, d[-1], step)
    return np.column_stack([np.interp(t, d, xy[:, 0]), np.interp(t, d, xy[:, 1])]), t


def straight_runs(xy):
    runs, i, n = [], 0, len(xy)
    while i < n - 1:
        j = i + 1
        while j + 1 < n:
            a, b = xy[i], xy[j + 1]
            chord = b - a
            L = np.hypot(*chord)
            if L == 0:
                break
            nrm = np.array([-chord[1], chord[0]]) / L
            if np.abs((xy[i:j + 2] - a) @ nrm).max() > RUN_STRAIGHT:
                break
            j += 1
        runs.append((i, j))
        i = j
    return runs


def overhead_closed(pts, ids, over):
    """True per point within OVERHEAD_R of a bridge or raised segment that is not one of `ids` (the street itself)."""
    if len(over["pts"]) == 0:
        return np.zeros(len(pts), bool)
    lo, hi = pts.min(axis=0) - OVERHEAD_R, pts.max(axis=0) + OVERHEAD_R
    sel = (over["pts"][:, 0] >= lo[0]) & (over["pts"][:, 0] <= hi[0]) & (over["pts"][:, 1] >= lo[1]) & (over["pts"][:, 1] <= hi[1])
    if not sel.any():
        return np.zeros(len(pts), bool)
    own = np.array([i in ids for i in over["id"][sel]], dtype=bool)
    cand = over["pts"][sel][~own]
    if len(cand) == 0:
        return np.zeros(len(pts), bool)
    d = np.hypot(pts[:, None, 0] - cand[None, :, 0], pts[:, None, 1] - cand[None, :, 1])
    return (d <= OVERHEAD_R).any(axis=1)


def overhead_within(points, over, radius):
    """Per point: True when an overhead point (bridge or raised segment, every 2 m) is within radius. Exact: only
    overhead points inside the points' box padded by radius can qualify, so the comparison is made on those alone,
    in chunks of 512 points so the distance temporaries stay small."""
    out = np.zeros(len(points), bool)
    if len(points) == 0 or len(over["pts"]) == 0:
        return out
    lo, hi = points.min(axis=0) - radius, points.max(axis=0) + radius
    op = over["pts"]
    sel = (op[:, 0] >= lo[0]) & (op[:, 0] <= hi[0]) & (op[:, 1] >= lo[1]) & (op[:, 1] <= hi[1])
    cand = op[sel]
    if len(cand) == 0:
        return out
    for s in range(0, len(points), 512):
        p = points[s:s + 512]
        d = np.hypot(p[:, None, 0] - cand[None, :, 0], p[:, None, 1] - cand[None, :, 1])
        out[s:s + 512] = (d <= radius).any(axis=1)
    return out


class Footprints:
    def __init__(self, polys, heights):
        self.polys, self.heights, self.tree = polys, heights, STRtree(polys)

    def blocked(self, pts, min_h, w):
        """True per point when a footprint taller than min_h stands within w metres."""
        out = np.zeros(len(pts), bool)
        for i, q in enumerate(pts):
            pt = Point(q)
            for k in self.tree.query(pt.buffer(w)):
                if self.heights[k] > min_h and self.polys[k].distance(pt) <= w:
                    out[i] = True
                    break
        return out


def find_candidates(streets, over, grid, g, fps, args, edge):
    """Every open stretch of at least args.min_run metres. Each is a dict with its centre line at 10 m."""
    cands = []
    min_h = args.alt - args.margin
    for k, ch in enumerate(chains(streets)):
        if k % GUARD_CHAINS == 0:
            GUARD.check("find candidates")
        for i, j in straight_runs(ch["xy"]):
            seg = ch["xy"][i:j + 1]
            if float(np.hypot(*np.diff(seg, axis=0).T).sum()) < args.min_run:
                continue
            pts, t = resample(seg, CHECK_STEP)
            if len(pts) < 3:
                continue
            ok = (height_near(grid, g, pts, args.halfwidth) <= min_h) & ~overhead_closed(pts, ch["ids"], over)
            ok &= (pts[:, 0] > edge[0]) & (pts[:, 0] < edge[1]) & (pts[:, 1] > edge[2]) & (pts[:, 1] < edge[3])
            # Footprints are slower, so only test where the grid says open.
            idx = np.where(ok)[0]
            if len(idx):
                ok[idx] &= ~fps.blocked(pts[idx], min_h, args.halfwidth)
            start = None
            for k, good in enumerate(list(ok) + [False]):
                if good and start is None:
                    start = k
                if not good and start is not None:
                    length = t[k - 1] - t[start]
                    if length >= args.min_run:
                        sub = pts[start:k]
                        cls = ch["classes"][0]
                        cands.append({"pts": sub, "len": float(length), "cls": cls, "names": sorted(set(n for n in ch["names"] if n))[:3],
                                      "id": f"{round(sub[0][0])}_{round(sub[0][1])}_{round(sub[-1][0])}_{round(sub[-1][1])}"})
                    start = None
    # Stable order, so a seed always sees the same list.
    cands.sort(key=lambda c: c["id"])
    return cands


# --------------------------------------------------------------------------- joins

def unit(v):
    n = float(np.hypot(*v))
    return v / n if n > 0 else v


def hermite_path(p0, d0, p1, d1, k):
    """A smooth path from p0 heading d0 to p1 heading d1, as points every CHECK_STEP metres."""
    n = 400
    u = np.linspace(0, 1, n)[:, None]
    h00, h10, h01, h11 = 2 * u**3 - 3 * u**2 + 1, u**3 - 2 * u**2 + u, -2 * u**3 + 3 * u**2, u**3 - u**2
    path = h00 * p0 + h10 * d0 * k + h01 * p1 + h11 * d1 * k
    d = np.r_[0, np.cumsum(np.hypot(*np.diff(path, axis=0).T))]
    t = np.arange(0, d[-1], CHECK_STEP)
    out = np.column_stack([np.interp(t, d, path[:, 0]), np.interp(t, d, path[:, 1])])
    return np.vstack([out, path[-1:]])


def min_radius(path):
    if len(path) < 3:
        return 1e9
    a, b, c = path[:-2], path[1:-1], path[2:]
    ab, bc = b - a, c - b
    cross = ab[:, 0] * bc[:, 1] - ab[:, 1] * bc[:, 0]
    dot = (ab * bc).sum(axis=1)
    ang = np.abs(np.arctan2(cross, dot))
    arc = np.hypot(*ab.T) + np.hypot(*bc.T)
    with np.errstate(divide="ignore"):
        r = np.where(ang > 1e-6, arc / np.maximum(ang, 1e-9), 1e9)
    return float(r.min())


def river_profile(path, grid, g, alt_floor):
    """The River rule on a join: altitude at least the tallest obstacle within 20 m plus 30 m (and the floor),
    gaps under 300 m raised together, then the least profile that never climbs or descends faster than the plan
    gradient. Returns the altitude at each point of the path."""
    req = np.maximum(alt_floor, height_near(grid, g, path, 20.0) + 33.0)       # 3 m over the rule, for the spline's own deviation
    base = np.full(len(path), alt_floor)
    raised = req > base + 0.5
    n = len(path)
    # Merge gaps under 300 m between raised points.
    idx = np.where(raised)[0]
    for a, b in zip(idx[:-1], idx[1:]):
        if 1 < b - a and (b - a) * CHECK_STEP < 300.0:
            req[a:b + 1] = np.maximum(req[a:b + 1], max(req[a], req[b]))
    alt = req.copy()
    step = PLAN_GRADIENT * CHECK_STEP
    for _ in range(2):
        for i in range(1, n):
            alt[i] = max(alt[i], alt[i - 1] - step)
        for i in range(n - 2, -1, -1):
            alt[i] = max(alt[i], alt[i + 1] - step)
    return alt


class Join:
    """A feasible join from the end of one stretch to the start of another, or None."""

    def __init__(self, path, alt):
        self.path, self.alt = path, alt
        self.start_alt, self.end_alt = float(alt[0]), float(alt[-1])
        self.length = float(np.hypot(*np.diff(path, axis=0).T).sum())


def make_join(a_end, a_dir, b_start, b_dir, grid, g, args, edge, cache):
    key = (round(a_end[0]), round(a_end[1]), round(b_start[0]), round(b_start[1]), round(math.degrees(math.atan2(*a_dir[::-1]))), round(math.degrees(math.atan2(*b_dir[::-1]))))
    if key in cache:
        return cache[key]
    result = None
    dist = float(np.hypot(*(b_start - a_end)))
    r_min = args.join_speed * KT * args.join_speed * KT / (G * math.tan(math.radians(30.0)))
    if 150.0 <= dist <= args.max_join:
        for k in (0.5 * dist, 0.8 * dist, 1.2 * dist):
            path = hermite_path(a_end, a_dir, b_start, b_dir, k)
            if min_radius(path) < r_min * 0.9:
                continue
            if (path[:, 0] <= edge[0]).any() or (path[:, 0] >= edge[1]).any() or (path[:, 1] <= edge[2]).any() or (path[:, 1] >= edge[3]).any():
                continue
            alt = river_profile(path, grid, g, args.alt)
            # The climb and the descent are flown along the streets: they must fit inside the stretches.
            if (alt[0] - args.alt) / PLAN_GRADIENT > args.max_climb or (alt[-1] - args.alt) / PLAN_GRADIENT > args.max_climb:
                continue
            if float(alt.max()) > args.max_top:
                continue                      # a join over the Loop's towers: leave those for a route that wants them
            result = Join(path, alt)
            break
    cache[key] = result
    return result


# --------------------------------------------------------------------------- route assembly and checks

def catmull_rom(p0, p1, p2, p3, t):
    def d(a, b):
        return max(1e-6, math.hypot(a[0] - b[0], a[1] - b[1]))
    t0 = 0.0
    t1 = t0 + math.sqrt(d(p0, p1))
    t2 = t1 + math.sqrt(d(p1, p2))
    t3 = t2 + math.sqrt(d(p2, p3))
    u = t1 + (t2 - t1) * t

    def lerp(a, b, ta, tb):
        f = (u - ta) / (tb - ta)
        return (a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f)
    b1, b2, b3 = lerp(p0, p1, t0, t1), lerp(p1, p2, t1, t2), lerp(p2, p3, t2, t3)
    c1, c2 = lerp(b1, b2, t0, t2), lerp(b2, b3, t1, t3)
    return lerp(c1, c2, t1, t2)


def route_samples(wp, spacing=CHECK_STEP):
    """The app's Route.build in Python: a closed centripetal Catmull-Rom spline through the waypoints (altitude and
    speed interpolated linearly per segment), resampled every `spacing` metres. Returns east, north, altitude, speed(kt),
    and the index of the waypoint each sample follows."""
    n = len(wp)
    dense = []
    per = 200
    for i in range(n):
        p0, p1, p2, p3 = wp[(i - 1) % n], wp[i], wp[(i + 1) % n], wp[(i + 2) % n]
        for k in range(per):
            t = k / per
            e, nn = catmull_rom((p0["east"], p0["north"]), (p1["east"], p1["north"]), (p2["east"], p2["north"]), (p3["east"], p3["north"]), t)
            dense.append((e, nn, p1["alt"] + (p2["alt"] - p1["alt"]) * t, p1["speedKt"] + (p2["speedKt"] - p1["speedKt"]) * t, i))
    dense = np.array(dense)
    cum = np.r_[0, np.cumsum(np.hypot(np.diff(np.r_[dense[:, 0], dense[0, 0]]), np.diff(np.r_[dense[:, 1], dense[0, 1]])))]
    total = cum[-1]
    count = int(total / spacing)
    s = np.arange(count) * spacing
    j = np.minimum(np.searchsorted(cum, s, side="right") - 1, len(dense) - 1)
    nxt = (j + 1) % len(dense)
    seg = cum[j + 1] - cum[j]
    f = np.where(seg > 0, (s - cum[j]) / np.where(seg > 0, seg, 1), 0)
    out = np.column_stack([dense[j, c] + (dense[nxt, c] - dense[j, c]) * f for c in range(4)])
    return out, dense[j, 4].astype(int)


class Assembly:
    def __init__(self):
        self.waypoints = []
        self.owner = []          # per waypoint: ("run", index) or ("join", index)


def assemble(seq, joins, args):
    """Waypoints for the closed loop. seq: list of (candidate, reversed); joins[i] goes from seq[i] to seq[i+1]."""
    a = Assembly()
    k = len(seq)
    for i, (cand, rev) in enumerate(seq):
        pts = cand["pts"][::-1] if rev else cand["pts"]
        d = np.r_[0, np.cumsum(np.hypot(*np.diff(pts, axis=0).T))]
        length = d[-1]
        join_in, join_out = joins[(i - 1) % k], joins[i]
        climb = (join_out.start_alt - args.alt) / PLAN_GRADIENT      # metres of street used to climb before the end
        descend = (join_in.end_alt - args.alt) / PLAN_GRADIENT       # metres of street used to descend after the start
        t = np.arange(0, length, 25.0)
        if length - t[-1] > 1.0:
            t = np.r_[t, length]
        for s in t:
            q = np.array([np.interp(s, d, pts[:, 0]), np.interp(s, d, pts[:, 1])])
            alt = args.alt
            if descend > 0 and s < descend:
                alt = args.alt + (join_in.end_alt - args.alt) * (1 - s / descend)
            if climb > 0 and s > length - climb:
                alt = max(alt, args.alt + (join_out.start_alt - args.alt) * (s - (length - climb)) / climb)
            a.waypoints.append({"east": float(q[0]), "north": float(q[1]), "alt": float(alt), "speedKt": float(args.speed)})
            a.owner.append(("run", i))
        # Join to the next stretch, every 10 m, excluding both ends (they are the stretches' own points).
        j = join_out
        for m_ in range(1, len(j.path) - 1):
            # Every 10 m, the profile's own spacing, so the altitude between waypoints is exact.
            a.waypoints.append({"east": float(j.path[m_][0]), "north": float(j.path[m_][1]), "alt": float(j.alt[m_]), "speedKt": float(args.join_speed)})
            a.owner.append(("join", i))
    return a


def polyline_distance(points, line):
    """Distance from each point to a polyline (to its segments, not only its vertices)."""
    a, b = line[:-1], line[1:]
    ab = b - a
    len2 = (ab ** 2).sum(axis=1)
    ap = points[:, None, :] - a[None, :, :]
    u = np.clip((ap * ab[None, :, :]).sum(axis=2) / np.where(len2 > 0, len2, 1)[None, :], 0, 1)
    proj = a[None, :, :] + u[:, :, None] * ab[None, :, :]
    return np.hypot(*(points[:, None, :] - proj).transpose(2, 0, 1)).min(axis=1)


def check_route(asm, seq, grid, g, fps, over, args, edge):
    """The proof, on the sampled spline. Returns a list of failures (owner index, message)."""
    samples, wp_index = route_samples(asm.waypoints)
    fails = []
    min_h = args.alt - args.margin
    # Which stretch each sample belongs to (within 3 m of its centre line): the corridor rule applies there.
    near_run = np.full(len(samples), -1)
    for i, (cand, _) in enumerate(seq):
        d = polyline_distance(samples[:, :2], cand["pts"])
        near_run[(d <= 3.0) & (near_run < 0)] = i
    pts = samples[:, :2]
    alt = samples[:, 2]
    tall6 = height_near(grid, g, pts, args.halfwidth)
    tall20 = height_near(grid, g, pts, 20.0)
    for i in range(len(samples)):
        e, n, a = samples[i, 0], samples[i, 1], alt[i]
        owner = asm.owner[wp_index[i]]
        if not (edge[0] < e < edge[1] and edge[2] < n < edge[3]):
            fails.append((owner, f"sample {i} outside the inner box"))
            continue
        if near_run[i] >= 0:
            if tall6[i] > a - args.margin:
                fails.append((("run", int(near_run[i])), f"sample {i}: grid has {tall6[i]:.0f} m within {args.halfwidth:.0f} m at {a:.0f} m up"))
        else:
            if a < tall20[i] + 30.0 - 1.5:
                fails.append((owner, f"sample {i}: {a:.0f} m up over {tall20[i]:.0f} m within 20 m (River rule)"))
        if i and abs(alt[i] - alt[i - 1]) / CHECK_STEP > math.tan(math.radians(PITCH_LIMIT_DEG)) * 0.95:
            fails.append((owner, f"sample {i}: gradient {abs(alt[i] - alt[i - 1]) / CHECK_STEP:.2f}"))
    # Footprints and the overhead mask, only for low samples inside a stretch.
    low = np.where((near_run >= 0) | (alt <= args.alt + 5))[0]
    low_pts = pts[low]
    blocked = np.zeros(len(low), bool)
    for q, idx in enumerate(low):
        thr = alt[idx] - args.margin
        pt = Point(low_pts[q])
        for k in fps.tree.query(pt.buffer(args.halfwidth)):
            if fps.heights[k] > thr and fps.polys[k].distance(pt) <= args.halfwidth:
                blocked[q] = True
                break
    for q in np.where(blocked)[0]:
        idx = low[q]
        fails.append((("run", int(near_run[idx])) if near_run[idx] >= 0 else asm.owner[wp_index[idx]], f"sample {idx}: a footprint taller than {alt[idx] - args.margin:.0f} m within {args.halfwidth:.0f} m"))
    # Overhead structures within OVERHEAD_R of the low samples (the stretch's own street excluded by construction of the candidates).
    for i, (cand, _) in enumerate(seq):
        sel = low[near_run[low] == i]
        if len(sel) and len(over["pts"]):
            # a stretch was already cleared against overhead structures along its own centre line, so only flag a structure
            # that comes within the radius of the sample and was not within it of the centre line.
            hit = overhead_within(pts[sel], over, OVERHEAD_R)
            if hit.any():
                if not overhead_within(cand["pts"], over, OVERHEAD_R).any() and hit.sum() > 0:
                    fails.append((("run", i), "a bridge or raised segment within 8 m of the spline"))
    # Turn radius on the joins.
    r_min = args.join_speed * KT * args.join_speed * KT / (G * math.tan(math.radians(30.0))) * 0.85
    mr = min_radius(pts[near_run < 0]) if (near_run < 0).sum() > 3 else 1e9
    return fails, {"samples": len(samples), "length_m": float(len(samples) * CHECK_STEP), "min_join_radius_m": round(mr), "join_radius_floor_m": round(r_min),
                   "max_alt_m": float(alt.max()), "low_samples": int(len(low)), "min_tall_beside_gap_m": None}


# --------------------------------------------------------------------------- selection

def pick_route(cands, rng, grid, g, args, edge, join_cache, banned):
    """A seeded sequence of stretches. Returns (seq, joins) or None."""
    pool = [c for c in cands if c["id"] not in banned]
    if len(pool) < 2:
        return None
    cell = lambda p: (int(p[0] // 1500), int(p[1] // 1500))
    for attempt in range(200):
        first = rng.choices(pool, weights=[c["len"] for c in pool])[0]
        rev = rng.random() < 0.5
        seq = [(first, rev)]
        joins = []
        used = {first["id"]}
        classes = collections.Counter({first["cls"]: 1})
        cells = collections.Counter({cell(first["pts"][len(first["pts"]) // 2]): 1})
        total = first["len"]
        while total < args.target_km * 1000:
            cur, crev = seq[-1]
            cpts = cur["pts"][::-1] if crev else cur["pts"]
            end, dend = cpts[-1], unit(cpts[-1] - cpts[-4])
            options = []
            for c in pool:
                if c["id"] in used:
                    continue
                for r in (False, True):
                    pts = c["pts"][::-1] if r else c["pts"]
                    dist = float(np.hypot(*(pts[0] - end)))
                    if 150.0 <= dist <= args.max_join:
                        options.append((c, r, dist))
            rng.shuffle(options)
            chosen = None
            weights = []
            for c, r, dist in options:
                w = c["len"] / (1.0 + dist / 1000.0)
                w *= 2.0 if classes[c["cls"]] == 0 else 1.0 / (1.0 + classes[c["cls"]])
                w /= 1.0 + 1.5 * cells[cell(c["pts"][len(c["pts"]) // 2])]
                weights.append(w)
            order = list(range(len(options)))
            # Weighted draw without replacement: try joins until one is feasible.
            tries = 0
            while order and tries < 25 and chosen is None:
                k = rng.choices(order, weights=[weights[i] for i in order])[0]
                order.remove(k)
                tries += 1
                c, r, dist = options[k]
                pts = c["pts"][::-1] if r else c["pts"]
                dstart = unit(pts[3] - pts[0])
                j = make_join(end, dend, pts[0], dstart, grid, g, args, edge, join_cache)
                if j is not None:
                    chosen = (c, r, j)
            if chosen is None:
                break
            c, r, j = chosen
            seq.append((c, r))
            joins.append(j)
            used.add(c["id"])
            classes[c["cls"]] += 1
            cells[cell(c["pts"][len(c["pts"]) // 2])] += 1
            total += c["len"] + j.length
        # Close the loop; drop stretches from the end until the closing join is feasible.
        while len(seq) >= 2:
            cur, crev = seq[-1]
            cpts = cur["pts"][::-1] if crev else cur["pts"]
            f0, frev = seq[0]
            fpts = f0["pts"][::-1] if frev else f0["pts"]
            j = make_join(cpts[-1], unit(cpts[-1] - cpts[-4]), fpts[0], unit(fpts[3] - fpts[0]), grid, g, args, edge, join_cache)
            if j is not None and sum(c["len"] for c, _ in seq) + sum(x.length for x in joins) + j.length >= 0.6 * args.target_km * 1000:
                return seq, joins + [j]
            seq.pop()
            joins.pop()
        # not enough: try again with the next random start
    return None


def build_route(cands, seed, grid, g, fps, over, args, edge):
    rng = random.Random(seed)
    banned = set()
    dropped = []
    join_cache = {}
    for attempt in range(args.tries):
        picked = pick_route(cands, rng, grid, g, args, edge, join_cache, banned)
        if picked is None:
            return None, {"error": "no feasible loop", "dropped": dropped}
        seq, joins = picked
        asm = assemble(seq, joins, args)
        fails, stats = check_route(asm, seq, grid, g, fps, over, args, edge)
        GUARD.check("check route")
        if not fails:
            return (seq, joins, asm, stats), {"dropped": dropped}
        # Drop every stretch named in a failure, and report it.
        bad = sorted({o[1] for o, _ in fails if o[0] == "run"} | {min(o[1] + 1, len(seq) - 1) % len(seq) for o, _ in fails if o[0] == "join"})
        for i in bad:
            banned.add(seq[i][0]["id"])
            dropped.append({"id": seq[i][0]["id"], "streets": seq[i][0]["names"], "reason": next((m for o, m in fails if (o[0] == "run" and o[1] == i) or (o[0] == "join" and (o[1] + 1) % len(seq) == i)), "failed the check")})
    return None, {"error": "gave up after %d tries" % args.tries, "dropped": dropped}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("city")
    ap.add_argument("--seeds", type=int, nargs="*", default=[1])
    ap.add_argument("--coverage", type=int, default=0, help="build routes for seeds 1..N in memory and report how much of the candidates they use")
    ap.add_argument("--alt", type=float, default=15.0)
    ap.add_argument("--margin", type=float, default=10.0)
    ap.add_argument("--halfwidth", type=float, default=6.0)
    ap.add_argument("--speed", type=float, default=40.0)
    ap.add_argument("--join-speed", type=float, default=60.0)
    ap.add_argument("--min-run", type=float, default=600.0)
    ap.add_argument("--max-join", type=float, default=2500.0)
    ap.add_argument("--max-climb", type=float, default=400.0, help="longest stretch of street used for a climb or descent, metres")
    ap.add_argument("--max-top", type=float, default=150.0, help="highest altitude of a join, metres; keeps routes out of the tallest towers")
    ap.add_argument("--target-km", type=float, default=12.0)
    ap.add_argument("--tries", type=int, default=12)
    ap.add_argument("--out", default=None)
    ap.add_argument("--max-gb", type=float, default=GUARD_MAX_GB, help="stop with a message if this process is resident above this many GB (checked after each phase, every 50,000 lines of a read, every 200 chains)")
    args = ap.parse_args()
    GUARD.max_gb = args.max_gb

    m, g, grid, to_local = load_city(args.city)
    GUARD.check("load grid")
    e = m["extentM"]
    edge = (e["minEast"] + BOUNDARY_MARGIN, e["maxEast"] - BOUNDARY_MARGIN, e["minNorth"] + BOUNDARY_MARGIN, e["maxNorth"] - BOUNDARY_MARGIN)
    streets, over = read_segments(args.city, m, to_local)
    GUARD.check("read segments")
    polys, heights = read_footprints(args.city, m, to_local)
    GUARD.check("read footprints")
    fps = Footprints(polys, heights)
    GUARD.check("build footprint index")
    cands = find_candidates(streets, over, grid, g, fps, args, edge)
    GUARD.check("find candidates")
    classes = collections.Counter(c["cls"] for c in cands)
    print(f"{args.city}: {len(cands)} candidate stretches of {args.min_run:.0f} m or more, {sum(c['len'] for c in cands) / 1000:.1f} km "
          f"(altitude {args.alt:.0f} m, margin {args.margin:.0f} m, half-width {args.halfwidth:.0f} m, {BOUNDARY_MARGIN:.0f} m inside the edge); by class {dict(classes)}")
    out_dir = args.out or os.path.join(args.city, "routes")
    os.makedirs(out_dir, exist_ok=True)

    seeds = list(range(1, args.coverage + 1)) if args.coverage else args.seeds
    used = collections.Counter()
    for seed in seeds:
        result, info = build_route(cands, seed, grid, g, fps, over, args, edge)
        GUARD.check(f"build route for seed {seed}")
        if result is None:
            print(f"seed {seed}: NOT WRITTEN ({info['error']}); dropped {len(info['dropped'])}")
            continue
        seq, joins, asm, stats = result
        for c, _ in seq:
            used[c["id"]] += 1
        report = {"seed": seed, "stretches": [{"id": c["id"], "class": c["cls"], "streets": c["names"], "length_m": round(c["len"]), "reversed": r,
                                               "line": [[round(float(x), 1), round(float(y), 1)] for x, y in c["pts"]]} for c, r in seq],
                  "joins": [{"length_m": round(j.length), "top_alt_m": round(float(j.alt.max())), "start_alt_m": round(j.start_alt), "end_alt_m": round(j.end_alt)} for j in joins],
                  "dropped": info["dropped"], "stats": stats, "settings": {k: v for k, v in vars(args).items() if k not in ("city", "seeds")}}
        print(f"seed {seed}: {len(seq)} stretches {sum(c['len'] for c, _ in seq) / 1000:.1f} km of street, {stats['length_m'] / 1000:.1f} km in all, "
              f"classes {dict(collections.Counter(c['cls'] for c, _ in seq))}, dropped {len(info['dropped'])}, top {stats['max_alt_m']:.0f} m")
        if not args.coverage:
            route = {"name": f"Street {seed}", "closed": True, "waypoints": asm.waypoints}
            json.dump(route, open(os.path.join(out_dir, f"street-{seed}.json"), "w"))
            json.dump(report, open(os.path.join(out_dir, f"street-{seed}.report.json"), "w"), indent=1)
    if args.coverage:
        total_len = sum(c["len"] for c in cands)
        used_len = sum(c["len"] for c in cands if used[c["id"]])
        print(f"seeds 1..{args.coverage}: {sum(1 for c in cands if used[c['id']])} of {len(cands)} candidates used "
              f"({100 * sum(1 for c in cands if used[c['id']]) / max(1, len(cands)):.0f} %), {used_len / 1000:.1f} of {total_len / 1000:.1f} km ({100 * used_len / max(1, total_len):.0f} %)")


if __name__ == "__main__":
    main()
