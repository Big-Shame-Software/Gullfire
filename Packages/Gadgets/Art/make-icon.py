#!/usr/bin/env python3
"""Builds the Image Optimizer gadget icon from the 32 x 32 pixel grid below.

Big Shame Software pixel icon (styleguide sections 6-7): 32-px grid, three colours plus plum outline,
Media family (Hot Magenta, Aqua Cyan) because its first home is Pål. Writes an SVG (the source of truth,
one rect per run of pixels) and PNGs at integer scales, with no metadata.

  python3 Art/make-icon.py      writes Art/ImageOptimizer.svg and Sources/BSSImageOptimizer/Resources/ImageOptimizer*.png
"""
import struct, zlib
from pathlib import Path

PALETTE = {
    "P": (0x2A, 0x0B, 0x1E),  # Plum Ink: outline and squeeze arrows
    "C": (0xFF, 0xF4, 0xDE),  # Cream: photo border, sun, highlight
    "A": (0x22, 0xC7, 0xD9),  # Aqua Cyan: sky
    "M": (0xFF, 0x2D, 0x6F),  # Hot Magenta: hills
}

GRID = """
................................
................................
................................
................................
................................
................................
.......PPPPPPPPPPPPPPPPPP.......
.......PCCCCCCCCCCCCCCCCP.......
.......PCPPPPPPPPPPPPPPCP.......
.......PCPCCAAAAAAAAAAPCP.......
.......PCPCAAAAAAAACCAPCP.......
.P.....PCPAAAAAAAACCCCPCP.....P.
.PP....PCPAAAAAAAACCCCPCP....PP.
.PPP...PCPAAAAAAAAACCAPCP...PPP.
.PPPP..PCPAAAAAMAAAAAAPCP..PPPP.
.PPPPP.PCPAAAAMMMAAAAAPCP.PPPPP.
.PPPPP.PCPAAAMMMMMAAMAPCP.PPPPP.
.PPPP..PCPAAMMMMMMMMMMPCP..PPPP.
.PPP...PCPAMMMMMMMMMMMPCP...PPP.
.PP....PCPMMMMMMMMMMMMPCP....PP.
.P.....PCPMMMMMMMMMMMMPCP.....P.
.......PCPMMMMMMMMMMMMPCP.......
.......PCPPPPPPPPPPPPPPCP.......
.......PCCCCCCCCCCCCCCCCP.......
.......PPPPPPPPPPPPPPPPPP.......
................................
................................
................................
................................
................................
................................
................................
"""

rows = [r for r in GRID.strip("\n").split("\n")]
assert len(rows) == 32 and all(len(r) == 32 for r in rows), [len(r) for r in rows]
here = Path(__file__).resolve().parent
out_png = here.parent / "Sources/BSSImageOptimizer/Resources"
out_png.mkdir(parents=True, exist_ok=True)

# SVG: one rect per horizontal run, crisp at any size.
rects = []
for y, row in enumerate(rows):
    x = 0
    while x < 32:
        c = row[x]
        if c == ".":
            x += 1; continue
        run = x
        while run < 32 and row[run] == c: run += 1
        r, g, b = PALETTE[c]
        rects.append(f'<rect x="{x}" y="{y}" width="{run - x}" height="1" fill="#{r:02X}{g:02X}{b:02X}"/>')
        x = run
svg = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32" width="256" height="256" shape-rendering="crispEdges">\n'
       + "\n".join(rects) + "\n</svg>\n")
(here / "ImageOptimizer.svg").write_text(svg)

def png(scale):
    w = 32 * scale
    raw = bytearray()
    for row in rows:
        line = bytearray([0])
        for c in row:
            px = (0, 0, 0, 0) if c == "." else (*PALETTE[c], 255)
            line += bytes(px) * scale
        raw += bytes(line) * scale
    def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, w, 8, 6, 0, 0, 0))
            + chunk(b"sRGB", b"\x00") + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))

for scale, suffix in [(1, ""), (2, "@2x"), (4, "@4x"), (8, "@8x")]:
    (out_png / f"ImageOptimizer{suffix}.png").write_bytes(png(scale))
print("wrote", here / "ImageOptimizer.svg", "and", out_png)
