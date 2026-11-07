"""Upstream's toProcessedLiquidMetal, applied to the wordmark.

paper-design/shaders solves a Poisson equation inside the silhouette with 40
red-black SOR iterations (omega 1.9, C 0.01, zero on the outline), normalises by
the maximum, and stores R = 1 - u/max (1 at the edge, 0 at the deepest
interior) with G = opacity. Upstream solves at 512 px on the long side; this
uses 1024 because a wordmark is 5:1 and its strokes would be ~7 px at 512.

    python3 recorder/process_wordmark.py title-assets/wordmark-mask.png OUT.png 2760
"""
import sys

import numpy as np
from PIL import Image

src, out, width = sys.argv[1], sys.argv[2], int(sys.argv[3])
alpha_full = Image.open(src).getchannel('A')
height = round(width * alpha_full.height / alpha_full.width)

WORK = 1024
wh = round(WORK * alpha_full.height / alpha_full.width)
a = np.asarray(alpha_full.resize((WORK, wh), Image.LANCZOS), dtype=np.float32) / 255
shape = a > 0.5

# Boundary: shape pixels with any non-shape 8-neighbour. Interior: the rest.
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
for _ in range(40):
    for sel in (red, black):
        p = np.pad(u, 1)
        s = p[1:-1, 2:] + p[1:-1, :-2] + p[2:, 1:-1] + p[:-2, 1:-1]
        u[sel] = omega * (C + s[sel]) / 4 + (1 - omega) * u[sel]

edge = 1 - u / u[interior].max()
edge[~shape] = 1
edge_full = np.asarray(Image.fromarray((edge * 255).astype(np.uint8)).resize((width, height), Image.BICUBIC))
g = np.asarray(alpha_full.resize((width, height), Image.LANCZOS))
rgba = np.dstack([edge_full, g, np.zeros_like(g), np.full_like(g, 255)])
Image.fromarray(rgba.astype(np.uint8), 'RGBA').save(out)
print(f'{out}: {width}x{height}, interior px {interior.sum()}, max u {u.max():.4f}')
