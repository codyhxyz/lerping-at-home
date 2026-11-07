"""The metal looks. Each function takes a Wordmark and returns metal RGB (SS res).

Sizes are expressed relative to the cap height (wm.cap) so the looks survive a
change of text or output size.
"""
import numpy as np
from scipy import ndimage as ndi

from metal import (blinn, chamfer_normals, fbm, inflated_normals, lamp, ramp,
                   reflect_view, smoothstep)

KEY = (-0.45, -0.85, 0.55)    # key light: upper left, image y is down


# ------------------------------------------------------------ bevel map
def bevel_map(wm):
    """Neutral 0.5 on the flat face; lit chamfer above, shaded chamfer below."""
    n = chamfer_normals(wm, width=0.055 * wm.cap, edge_slope=2.2, falloff=2.5)
    d, L = lamp(n, KEY)
    v = 0.5 + 0.5 * (d - L[2]) / (1 - L[2])
    v += 0.35 * blinn(n, KEY, 60)
    v = np.clip(v, 0, 1)
    return np.repeat(v[..., None], 3, -1)


# ------------------------------------------------------------ polished chrome
def chrome(wm):
    """Mirror chrome with a studio sky/ground horizon. Restrained palette."""
    n = chamfer_normals(wm, width=0.06 * wm.cap, edge_slope=2.4, falloff=2.6)
    r = reflect_view(n)
    # where in the environment each pixel looks: screen height + bevel tilt
    v = wm.yn + 0.55 * r[..., 1] + 0.03 * np.sin(wm.xn * 6.283 * 1.2 + 0.7)
    hz = 0.60
    sky = ramp(v, [(-1.5, (0.50, 0.54, 0.62)), (-0.2, (0.70, 0.74, 0.80)),
                   (0.30, (0.90, 0.92, 0.95)), (hz, (0.985, 0.99, 1.0))])
    ground = ramp(v, [(hz, (0.12, 0.122, 0.135)), (0.70, (0.17, 0.172, 0.185)),
                      (0.90, (0.36, 0.36, 0.375)), (1.10, (0.62, 0.62, 0.64)),
                      (1.5, (0.78, 0.78, 0.80)), (3.0, (0.55, 0.56, 0.60))])
    k = smoothstep(hz - 0.02, hz + 0.02, v)[..., None]
    col = sky * (1 - k) + ground * k
    # soft vertical softbox glints, sliding with the bevel x tilt
    u = wm.xn + 0.25 * r[..., 0]
    box = np.exp(-((u - 0.22) / 0.05) ** 2) + 0.7 * np.exp(-((u - 0.71) / 0.07) ** 2)
    col += 0.10 * box[..., None] * (1 - k)
    col += 0.95 * blinn(n, KEY, 120)[..., None]
    col += 0.25 * blinn(n, KEY, 18)[..., None] * (1 - n[..., 2:3])
    return col


# ------------------------------------------------------------ liquid metal
def _spectral_weights(m):
    o = np.linspace(-1, 1, m)
    g = lambda c, s: np.exp(-((o - c) / s) ** 2)
    w = np.stack([g(-0.72, 0.42) + 0.22 * g(1.0, 0.28),   # R (and a violet tail)
                  g(-0.02, 0.42),                           # G
                  g(0.70, 0.42)], -1)                       # B
    return o, w / w.sum(0, keepdims=True)


LM_STOPS = [  # palette sampled from the liquid-metal shader: silver + deep navy
    (-2.00, (0.50, 0.53, 0.64)),
    (-0.60, (0.92, 0.94, 0.98)),
    (0.10, (0.975, 0.98, 1.0)),
    (0.34, (0.86, 0.89, 0.94)),
    (0.40, (0.78, 0.82, 0.89)),
    (0.425, (0.15, 0.15, 0.32)),   # hard edge into the navy reflection
    (0.60, (0.045, 0.045, 0.11)),
    (0.80, (0.17, 0.19, 0.33)),
    (0.97, (0.55, 0.60, 0.70)),
    (1.00, (0.90, 0.92, 0.96)),    # hard edge back to silver
    (1.50, (0.86, 0.89, 0.94)),
    (2.60, (0.36, 0.38, 0.50)),
]


def liquid_metal(wm, dispersion=0.07, samples=17, fringe_boost=1.8):
    """Inflated letterforms reflecting the shader's silver/navy studio, with
    spectral dispersion so every bright/dark boundary grows a thin rainbow."""
    n = inflated_normals(wm, dome=0.75)
    r = reflect_view(n)
    warp = fbm(wm.A.shape, [0.45 * wm.cap, 0.22 * wm.cap], seed=7)
    v = 0.05 + 0.60 * wm.yn + 0.85 * r[..., 1] - 0.35 * r[..., 0] + 0.16 * warp
    tilt = np.sqrt(np.clip(1 - n[..., 2] ** 2, 0, 1))
    spread = 0.006 + dispersion * tilt
    o, w = _spectral_weights(samples)
    col = np.zeros(wm.A.shape + (3,), np.float32)
    for oi, wi in zip(o, w):
        col += ramp(v + spread * oi, LM_STOPS) * wi
    # the shader's fringes are vivid: boost only the chroma that dispersion
    # added, so the palette's own silver/navy tint is left alone
    diff = col - ramp(v, LM_STOPS)
    col = col + (fringe_boost - 1) * (diff - diff.mean(-1, keepdims=True))
    # thin light rim on the silhouette, as on the shader's blob
    rim = smoothstep(0.86, 0.985, tilt)[..., None]
    col = col * (1 - 0.8 * rim) + 0.8 * rim * np.array([0.80, 0.83, 0.90], np.float32)
    col += 0.7 * blinn(n, KEY, 220)[..., None]
    return col


# ------------------------------------------------------------ gunmetal
def gunmetal(wm):
    """Dark brushed metal, crisp bright chamfer catching the key light."""
    H, W = wm.A.shape
    n = chamfer_normals(wm, width=0.026 * wm.cap, edge_slope=2.0, falloff=3.0)
    d_s = ndi.gaussian_filter(wm.d_in, 1.5)
    base = ramp(wm.yn, [(-0.2, (0.40, 0.415, 0.44)), (0.5, (0.25, 0.26, 0.28)),
                        (1.3, (0.13, 0.135, 0.145))])
    brush = fbm((H, W), [0.6, 2.0, 6.0], seed=3, aniso=(1, 220))
    sheen_u = wm.xn - 0.35 * wm.yn
    sheen = 0.10 * np.exp(-((sheen_u - 0.28) / 0.09) ** 2) + \
        0.07 * np.exp(-((sheen_u - 0.80) / 0.13) ** 2)
    col = base * (1 + 0.08 * brush[..., None]) + sheen[..., None]
    d, L = lamp(n, KEY)
    edge = smoothstep(0.005, 0.05, 1 - n[..., 2])
    lit = np.clip((d - L[2]) / (1 - L[2]), 0, 1)
    shade = np.clip((L[2] - d) / L[2], 0, 1)
    col += (1.5 * lit)[..., None] * np.array([0.90, 0.94, 1.0])
    col *= (1 - 0.6 * shade * edge)[..., None]
    col += 1.2 * blinn(n, KEY, 90)[..., None]
    # one crisp hairline just inside the outline, all the way round
    rim = smoothstep(0.0, 1.0, wm.A) * (1 - smoothstep(1.5, 4.0, d_s))
    col += 0.32 * rim[..., None]
    return col


# ------------------------------------------------------------ specular sweep
def sweep_band(wm, center=0.5, angle_deg=22):
    """Diagonal light streak ('/'), as alpha. center = 0..1 across the ink.
    A bright core, a soft halo and a thin trailing glint."""
    H, W = wm.A.shape
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    x0, y0, x1, y1 = wm.ink
    cx = x0 + center * (x1 - x0)
    cy = (wm.cap_top + wm.baseline) / 2
    th = np.deg2rad(angle_deg)
    s = (xx - cx) * np.cos(th) + (yy - cy) * np.sin(th)
    c = wm.cap
    band = (0.90 * np.exp(-(s / (0.10 * c)) ** 2) +
            0.30 * np.exp(-(s / (0.42 * c)) ** 2) +
            0.60 * np.exp(-((s + 0.30 * c) / (0.025 * c)) ** 2))
    return np.clip(band, 0, 1).astype(np.float32)


def sweep_edge_boost(wm):
    """Catch the light a bit harder on the chamfer than on the face."""
    n = chamfer_normals(wm, width=0.055 * wm.cap, edge_slope=2.2, falloff=2.5)
    return np.clip(0.75 + 0.6 * (1 - n[..., 2]), 0, 1.0)
