#!/usr/bin/env python3
"""Writes Examples/example-glider.json, the generic example sailplane for Gullfire.

It is a plain, made-up sailplane: a tapered, high-aspect wing, a slim fuselage box and a T-tail, all from the round
numbers below. It is not based on any aircraft, drawing or photograph. Run it again and the file comes out the same,
byte for byte.

    python3 Tools/make_example_glider.py [OUTPUT]

Units are metres. Axes match the app's model format: x forward, y up, z to the right, origin at the wing root.
Triangles only hide the lines behind them; the lines are what you see.
"""
import json
import sys
from pathlib import Path

# Round-number parameters, metres.
SPAN_HALF = 5.0          # half span: 10 m in all
ROOT_LE, ROOT_TE = 0.8, -0.4     # root chord 1.2 m, leading edge forward
TIP_LE, TIP_TE = 0.4, -0.1       # tip chord 0.5 m
FUSE_NOSE, FUSE_TAIL = 2.5, -2.5 # fuselage 5 m long
FUSE_HALF_W = 0.3                # fuselage 0.6 m wide
FUSE_HALF_H = 0.4                # fuselage 0.8 m high
TAIL_X_LE, TAIL_X_TE = -1.9, -2.5 # tailplane: 0.6 m chord
TAIL_HALF = 1.8                  # tailplane half span
FIN_TOP = 1.2                    # fin reaches 1.2 m above the wing
NAME = "Example sailplane (generic)"
DECIMALS = 3


def r(v):
    return round(v, DECIMALS) + 0.0  # + 0.0 turns -0.0 into 0.0


def quad(a, b, c, d):
    """Two triangles for the quad a b c d (in order round its edge)."""
    return [a, b, c, a, c, d]


def outline(points):
    """The line segments round a closed polygon."""
    return [(points[i], points[(i + 1) % len(points)]) for i in range(len(points))]


def mirror(p):
    x, y, z = p
    return (x, y, -z)


def box(x0, x1, y0, y1, z0, z1):
    """The six faces of a box as triangles, and its twelve edges as lines."""
    c = {
        "a": (x0, y0, z0), "b": (x1, y0, z0), "c": (x1, y1, z0), "d": (x0, y1, z0),
        "e": (x0, y0, z1), "f": (x1, y0, z1), "g": (x1, y1, z1), "h": (x0, y1, z1),
    }
    faces = [("a", "b", "c", "d"), ("e", "h", "g", "f"), ("a", "e", "f", "b"),
             ("b", "f", "g", "c"), ("c", "g", "h", "d"), ("d", "h", "e", "a")]
    tris = []
    for f in faces:
        tris += quad(*(c[k] for k in f))
    edges = [("a", "b"), ("b", "c"), ("c", "d"), ("d", "a"),
             ("e", "f"), ("f", "g"), ("g", "h"), ("h", "e"),
             ("a", "e"), ("b", "f"), ("c", "g"), ("d", "h")]
    return tris, [(c[p], c[q]) for p, q in edges]


def build():
    tris, lines = [], []

    # Wing: one planform, mirrored. Root leading edge, tip leading edge, tip trailing edge, root trailing edge.
    root_l = (ROOT_LE, 0.0, 0.0)
    root_t = (ROOT_TE, 0.0, 0.0)
    tip_l = (TIP_LE, 0.0, SPAN_HALF)
    tip_t = (TIP_TE, 0.0, SPAN_HALF)
    right = [root_l, tip_l, tip_t, root_t]
    left = [mirror(p) for p in right]
    tris += quad(*right)
    tris += quad(*left)
    lines += outline(right)
    lines += outline(left)

    # Fuselage: a box, from the nose to the tail, at the wing's height.
    fuse_tris, fuse_lines = box(FUSE_TAIL, FUSE_NOSE, -FUSE_HALF_H, FUSE_HALF_H, -FUSE_HALF_W, FUSE_HALF_W)
    tris += fuse_tris
    lines += fuse_lines

    # Tailplane: a flat planform at the tail, and a fin on top of the fuselage.
    tail_r = [(TAIL_X_LE, 0.0, 0.0), (TAIL_X_LE, 0.0, TAIL_HALF),
              (TAIL_X_TE, 0.0, TAIL_HALF), (TAIL_X_TE, 0.0, 0.0)]
    tail_l = [mirror(p) for p in tail_r]
    tris += quad(*tail_r)
    tris += quad(*tail_l)
    lines += outline(tail_r)
    lines += outline(tail_l)
    fin = [(TAIL_X_LE, FUSE_HALF_H, 0.0), (TAIL_X_LE, FIN_TOP, 0.0),
           (TAIL_X_TE, FUSE_HALF_H, 0.0)]
    tris += fin
    lines += outline(fin)

    return tris, lines


def main(argv):
    out = Path(argv[1]) if len(argv) > 1 else Path("Examples/example-glider.json")
    tris, lines = build()
    xs = [p[0] for t in [tris] for p in t] + [p[0] for seg in lines for p in seg]
    ys = [p[1] for p in tris] + [p[1] for seg in lines for p in seg]
    zs = [p[2] for p in tris] + [p[2] for seg in lines for p in seg]
    length = max(xs) - min(xs)
    span = max(zs) - min(zs)
    flat_tris = [r(v) for p in tris for v in p]
    flat_lines = [r(v) for seg in lines for p in seg for v in p]
    assert len(flat_tris) % 9 == 0 and len(flat_lines) % 6 == 0
    model = {
        "name": NAME,
        "spanM": r(span),
        "lengthM": r(length),
        "triangles": flat_tris,
        "lines": flat_lines,
    }
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(model, indent=1) + "\n")
    print(f"wrote {out}: span {r(span)} m, length {r(length)} m, "
          f"{len(flat_tris) // 9} triangles, {len(flat_lines) // 6} line segments")


if __name__ == "__main__":
    main(sys.argv)
