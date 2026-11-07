"""The wordmark processed one glyph at a time, for liquid-metal-glyphs.metal.

Upstream's LiquidMetal is made for a single compact logo: its chrome bands and
its dome ("bump") are laid out across the whole image. Across a 5:1 wordmark
that stretches every band five times wider, so each letter sits inside one band
and reads as a flat grey fill. This gives every glyph its own square cell
instead, so each letter is a little LiquidMetal logo of its own.

    R = edge field (upstream's Poisson solve, normalised per glyph: 1 at the
        outline, 0 at that glyph's deepest interior)
    G = opacity
    B = the glyph's cell centre, in image UV x (every column belongs to its
        nearest glyph, so the value only jumps where opacity is 0)

    python3 recorder/process_glyphs.py title-assets/wordmark-mask.png OUT.png 2760
"""
import sys

import numpy as np
from PIL import Image

src, out, width = sys.argv[1], sys.argv[2], int(sys.argv[3])
alpha_full = Image.open(src).getchannel('A')
height = round(width * alpha_full.height / alpha_full.width)

# 2048 rather than upstream's 512: the solve is per glyph, and a glyph's stroke
# should still be ~40 px wide in it.
WORK = 2048
wh = round(WORK * alpha_full.height / alpha_full.width)
a = np.asarray(alpha_full.resize((WORK, wh), Image.LANCZOS), dtype=np.float32) / 255
shape = a > 0.5

pad = np.pad(shape, 1)
nb_all = np.ones_like(shape)
for dy in (-1, 0, 1):
    for dx in (-1, 0, 1):
        nb_all &= pad[1 + dy:1 + dy + wh, 1 + dx:1 + dx + WORK]
interior = shape & nb_all

yy, xx = np.mgrid[0:wh, 0:WORK]
red = interior & ((xx + yy) % 2 == 0)
black = interior & ((xx + yy) % 2 == 1)
u = np.zeros((wh, WORK), np.float32)
C, omega = 0.01, 1.9
for _ in range(160):   # 4x upstream's 40: the grid is 4x finer
    for sel in (red, black):
        p = np.pad(u, 1)
        s = p[1:-1, 2:] + p[1:-1, :-2] + p[2:, 1:-1] + p[:-2, 1:-1]
        u[sel] = omega * (C + s[sel]) / 4 + (1 - omega) * u[sel]

# Glyphs are the runs of inked columns (the i's dot shares its stem's columns).
cols = shape.any(0)
runs, start = [], None
for x, c in enumerate(list(cols) + [False]):
    if c and start is None:
        start = x
    elif not c and start is not None:
        runs.append((start, x))
        start = None
centres = np.array([(s + e) / 2 for s, e in runs])
owner = np.abs(np.arange(WORK)[:, None] - centres[None, :]).argmin(1)

edge = np.ones_like(u)
for i, (s, e) in enumerate(runs):
    sl = np.s_[:, s:e]
    peak = u[sl][interior[sl]].max()
    edge[sl] = 1 - u[sl] / peak
edge[~shape] = 1
centre = (centres[owner] / WORK)[None, :].repeat(wh, 0)

def up(x, filt):
    return np.asarray(Image.fromarray(x.astype(np.float32), 'F').resize((width, height), filt))

edge_full = (up(edge, Image.BICUBIC).clip(0, 1) * 255).round()
centre_full = (up(centre, Image.NEAREST) * 255).round()
g = np.asarray(alpha_full.resize((width, height), Image.LANCZOS))
rgba = np.dstack([edge_full, g, centre_full, np.full_like(g, 255)])
Image.fromarray(rgba.astype(np.uint8), 'RGBA').save(out)
print(f'{out}: {width}x{height}, {len(runs)} glyphs, centres {np.round(centres / WORK, 3).tolist()}')
