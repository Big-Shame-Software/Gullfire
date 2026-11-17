#!/usr/bin/env python3
"""Build the Gullfire app icon: a fire-winged seagull in 8-bit pixel art (M5, owner-approved exception).

Writes .github/brand/gullfire-icon-master.svg (the same form as BestImage's icon-master.svg: a 1024
canvas, a squircle clip, a 32-cell pixel grid of 32 units each) and PNG renders at 1024, 128 and 32 px.
Everything is drawn from one grid, so the SVG and the PNGs cannot drift apart. Run: python3 Tools/make_icon.py
"""
import math, os, sys
from PIL import Image, ImageDraw

N = 32                       # pixel grid: 32 x 32 cells
CELL = 32                    # units per cell in the 1024 inner space
SCALE = 0.8046875            # as in the BestImage master
OFFSET = 100

PLUM = "#2A0B1E"
CREAM = "#FFF4DE"
BEIGE = "#EAD2A8"
SUNSET = "#FF7A1F"
GOLD = "#E8B04A"
YELLOW = "#FFD43B"
MAGENTA = "#FF2D6F"
EYE = PLUM

def inside(poly, x, y):
    """Even-odd point-in-polygon for a cell centre (x, y) in grid units."""
    c = False
    j = len(poly) - 1
    for i in range(len(poly)):
        xi, yi = poly[i]
        xj, yj = poly[j]
        if (yi > y) != (yj > y) and x < (xj - xi) * (y - yi) / (yj - yi) + xi:
            c = not c
        j = i
    return c

def ellipse(cx, cy, rx, ry, n=28):
    return [(cx + rx * math.cos(2 * math.pi * k / n), cy + ry * math.sin(2 * math.pi * k / n)) for k in range(n)]

def pull_in(poly, k=0.92):
    """Pull a left-hand shape toward the centre line, so the wing tips and flames clear the squircle corners."""
    return [(16 + (x - 16) * k, y) for x, y in poly]

def mirror(poly):
    return [(N - x, y) for x, y in poly]

# Left-hand shapes (cell-centre coordinates, 0..32). Each is mirrored for the right side.
LEFT_WING = [(14.5, 15), (11, 11.5), (7, 8.5), (3.5, 6.5), (1.2, 5.6), (2.6, 9), (4.6, 12),
             (6.2, 15.5), (8, 18.5), (11.5, 20.2), (14.5, 19.5)]
LEFT_WING_SHADE = [(13.5, 17.5), (10.5, 15.8), (7.5, 14.2), (5.8, 16.2), (8.6, 18.6), (11.2, 19.6)]
LEFT_FLAME_OUTER = [(1.6, 8.0), (0.0, 4.0), (0.8, 1.6), (2.4, 0.0), (3.2, 2.0), (4.6, 0.2), (6.0, 2.4), (5.8, 5.0), (5.0, 8.0), (3.2, 9.0)]
LEFT_FLAME_INNER = [(2.0, 7.4), (1.2, 4.6), (1.8, 2.6), (2.8, 1.6), (3.4, 3.4), (4.6, 2.2), (5.0, 4.8), (4.2, 7.0)]
LEFT_FLAME_CORE = [(2.8, 6.0), (2.6, 4.2), (3.6, 4.0), (3.8, 5.6)]

LEFT_WING = pull_in(LEFT_WING)
LEFT_WING_SHADE = pull_in(LEFT_WING_SHADE)
LEFT_FLAME_OUTER = pull_in(LEFT_FLAME_OUTER)
LEFT_FLAME_INNER = pull_in(LEFT_FLAME_INNER)
LEFT_FLAME_CORE = pull_in(LEFT_FLAME_CORE)

# Centre shapes.
BODY = ellipse(16, 18.5, 5.2, 7.5)
BELLY = ellipse(16, 22.0, 3.2, 3.8)
HEAD = ellipse(16, 10.5, 4.2, 3.8)
BEAK = [(14.6, 13.6), (17.4, 13.6), (16.0, 16.2)]
EYE_L = [(14.2, 9.8), (15.4, 9.8), (15.4, 10.9), (14.2, 10.9)]
EYE_R = [(16.6, 9.8), (17.8, 9.8), (17.8, 10.9), (16.6, 10.9)]
TAIL = [(13.0, 23.0), (19.0, 23.0), (21.0, 30.0), (18.5, 27.0), (16.0, 30.5), (13.5, 27.0), (11.0, 30.0)]

def layers():
    """Shapes in draw order: (colour, polygon, group). Right-side shapes are mirrored copies.
    The three flame colours share the group 'fire', so no outline is drawn between them."""
    out = []
    for poly in (LEFT_WING, mirror(LEFT_WING)):
        out.append((CREAM, poly, "wing"))
    for poly in (LEFT_WING_SHADE, mirror(LEFT_WING_SHADE)):
        out.append((BEIGE, poly, "shade"))
    for outer, inner, core in ((LEFT_FLAME_OUTER, LEFT_FLAME_INNER, LEFT_FLAME_CORE),
                               (mirror(LEFT_FLAME_OUTER), mirror(LEFT_FLAME_INNER), mirror(LEFT_FLAME_CORE))):
        out.append((MAGENTA, outer, "fire"))
        out.append((YELLOW, inner, "fire"))
        out.append((CREAM, core, "fire"))
    out += [(CREAM, TAIL, "tail"), (CREAM, BODY, "body"), (BEIGE, BELLY, "belly"),
            (CREAM, HEAD, "head"), (YELLOW, BEAK, "beak"), (EYE, EYE_L, "eye"), (EYE, EYE_R, "eye")]
    return out

def background(y):
    """Sunset Orange above, Prairie Gold below, with a dithered band between (family rule, styleguide 8)."""
    if y < 15:
        return SUNSET
    if y >= 20:
        return GOLD
    return SUNSET if (y + 0) % 2 == 0 else GOLD

def grid():
    """Return a 32 x 32 list of (colour, shape id). Shape id -1 is background, >= 0 a shape."""
    shapes = layers()
    cells = [[(background(y), -1, None) for x in range(N)] for y in range(N)]
    for sid, (colour, poly, group) in enumerate(shapes):
        for y in range(N):
            for x in range(N):
                if inside(poly, x + 0.5, y + 0.5):
                    cells[y][x] = (colour, sid, group)
    # Highlight: one cream stroke, top-left, on the background only.
    for (x, y) in [(9, 1), (8, 2), (7, 3)]:
        if cells[y][x][1] == -1:
            cells[y][x] = (CREAM, -2, None)
    # Outline: a shape cell next to background or a different group is plum. Cells of the same
    # group (the flames) are not outlined against each other.
    out = [[c for c in row] for row in cells]
    for y in range(N):
        for x in range(N):
            colour, sid, group = cells[y][x]
            if sid < 0:
                continue
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                nx, ny = x + dx, y + dy
                if not (0 <= nx < N and 0 <= ny < N):
                    out[y][x] = (PLUM, sid, group); break
                n_colour, n_sid, n_group = cells[ny][nx]
                if n_sid < 0 or n_group != group:
                    out[y][x] = (PLUM, sid, group); break
    return out

def grey(v):
    return f"#{v:02X}{v:02X}{v:02X}"

# Tinted: one grey per palette colour. The system tints the grey artwork, so only the value matters.
# Background is mid grey, the figure is light, the flames are dark, and the outline is near black.
TINT = {PLUM: grey(20), SUNSET: grey(150), GOLD: grey(150), CREAM: grey(250), BEIGE: grey(210),
        YELLOW: grey(240), MAGENTA: grey(70)}

def variant_cells(cells, variant):
    """Dark: the same artwork on the Plum Ink dark brand surface (the sky and ground become plum).
    Tinted: the same artwork in single-channel grey, with the silhouette kept strong."""
    out = []
    for row in cells:
        new = []
        for colour, sid, group in row:
            if variant == "dark" and colour in (SUNSET, GOLD):
                colour = PLUM
            elif variant == "tinted":
                colour = TINT.get(colour, colour)
            new.append((colour, sid, group))
        out.append(new)
    return out

def svg(cells):
    rects = []
    for y in range(N):
        for x in range(N):
            colour, sid, _ = cells[y][x]
            rects.append(f'<rect x="{x * CELL}" y="{y * CELL}" width="{CELL}" height="{CELL}" fill="{colour}"/>')
    body = "\n".join(rects)
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" shape-rendering="crispEdges">
<defs><clipPath id="sq"><rect x="100" y="100" width="824" height="824" rx="185"/></clipPath></defs>
<g clip-path="url(#sq)"><g transform="translate(100 100) scale({SCALE})">
{body}
</g></g>
</svg>
'''

def png(cells, size):
    """Render at `size` px. The canvas is 1024 units; the squircle sits inside a 100-unit margin."""
    big = 1024
    img = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    cell = CELL * SCALE
    for y in range(N):
        for x in range(N):
            colour, _, _ = cells[y][x]
            x0 = round(OFFSET + x * cell); y0 = round(OFFSET + y * cell)
            x1 = round(OFFSET + (x + 1) * cell); y1 = round(OFFSET + (y + 1) * cell)
            draw.rectangle([x0, y0, x1 - 1, y1 - 1], fill=colour)
    mask = Image.new("L", (big, big), 0)
    ImageDraw.Draw(mask).rounded_rectangle([OFFSET, OFFSET, OFFSET + 824 - 1, OFFSET + 824 - 1], radius=185, fill=255)
    img.putalpha(Image.composite(img.getchannel("A"), Image.new("L", (big, big), 0), mask))
    if size == big:
        return img
    # Area-average (premultiplied, so the squircle edge does not darken): nearest-neighbour drops
    # cells that are under one pixel wide at 16 and 32 px, which would misstate the silhouette.
    return img.convert("RGBa").resize((size, size), Image.BOX).convert("RGBA")

SIZES = (1024, 512, 256, 128, 64, 32, 16)
VARIANTS = ("light", "dark", "tinted")

def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    base = grid()
    out = os.path.join(root, "renders/icon")
    os.makedirs(out, exist_ok=True)
    for variant in VARIANTS:
        cells = variant_cells(base, variant) if variant != "light" else base
        tag = "" if variant == "light" else f"-{variant}"
        with open(os.path.join(root, f".github/brand/gullfire-icon-master{tag}.svg"), "w") as fh:
            fh.write(svg(cells))
        for size in SIZES:
            name = f"icon_{size}.png" if variant == "light" else f"icon_{variant}_{size}.png"
            png(cells, size).save(os.path.join(out, name))
    print("wrote master SVGs and renders in renders/icon for", ", ".join(VARIANTS))

if __name__ == "__main__":
    main()
