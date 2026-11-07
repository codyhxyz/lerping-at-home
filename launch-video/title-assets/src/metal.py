"""Wordmark geometry + metal shading in numpy.

All shading happens at SS x the output resolution and is box-downsampled at
the end, so edges are clean and every wordmark file registers exactly.
"""
import numpy as np
from PIL import Image
from scipy import ndimage as ndi

import text_render as tr

SS = 2  # supersampling factor


# ---------------------------------------------------------------- geometry
class Wordmark:
    """Alpha of the text on the final canvas (at SS res) + type metrics."""

    def __init__(self, text, out_w=3840, pad_frac=0.04, weight=700, tracking_em=-0.02):
        pad = round(out_w * pad_frac)
        target_ink_w = (out_w - 2 * pad) * SS
        a0 = tr.render(text, 400, weight=weight, tracking_em=tracking_em)
        x0, y0, x1, y1 = tr.ink_bbox(a0)
        size = 400 * target_ink_w / (x1 - x0)
        a = tr.render(text, size, weight=weight, tracking_em=tracking_em)
        p = tr.render(text, size, weight=weight, tracking_em=tracking_em, probe=True)
        x0, y0, x1, y1 = tr.ink_bbox(a)
        _, cy0, _, cy1 = tr.ink_bbox(p, thr=0.5)
        ink_h = (y1 - y0) / SS
        out_h = int(np.ceil(ink_h + 2 * pad))
        out_h += out_h % 2
        W, H = out_w * SS, out_h * SS
        ox = (W - (x1 - x0)) // 2
        oy = (H - (y1 - y0)) // 2
        A = np.zeros((H, W), np.float32)
        A[oy:oy + (y1 - y0), ox:ox + (x1 - x0)] = a[y0:y1, x0:x1]
        self.A, self.W, self.H = A, W, H
        self.out_size = (out_w, out_h)
        self.cap_top = cy0 - y0 + oy          # SS-res canvas coords
        self.baseline = cy1 - y0 + oy
        self.cap = self.baseline - self.cap_top
        self.ink = (ox, oy, ox + (x1 - x0), oy + (y1 - y0))
        self.text, self.font_px = text, size / SS
        inside = A > 0.5
        self.d_in = ndi.distance_transform_edt(inside).astype(np.float32)
        self.d_out = ndi.distance_transform_edt(~inside).astype(np.float32)
        yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
        self.yn = (yy - self.cap_top) / self.cap      # 0 = cap top, 1 = baseline
        self.xn = (xx - ox) / (x1 - x0)               # 0..1 across ink
        self.stem = float(np.percentile(self.d_in[self.d_in > 0], 99.0)) * 2


def normals_from_height(h):
    gy, gx = np.gradient(h)
    n = np.stack([-gx, -gy, np.ones_like(h)], -1)
    return n / np.linalg.norm(n, axis=-1, keepdims=True)


def chamfer_normals(wm, width, edge_slope=2.0, falloff=2.5, blur=None):
    """Rounded chamfer: steep at the outline, flat face inside `width` px.
    The distance field is blurred so the pixel-quantised EDT doesn't ripple."""
    blur = 0.0065 * wm.cap if blur is None else blur
    d = ndi.gaussian_filter(wm.d_in, blur)
    t = np.clip(d / width, 0, 1)
    h = width * edge_slope * (1 - (1 - t) ** falloff) / falloff
    return normals_from_height(h)


def poisson_height(wm, scale=2, dome=0.8):
    """Membrane inflation: solve lap(P) = -c inside the glyphs (P = 0 outside)
    at 1/scale res, then h = sqrt(P). A stroke of half-width a becomes an
    ellipse of height dome*a, with no medial-axis creases."""
    from scipy.sparse import coo_matrix
    from scipy.sparse.linalg import spsolve
    H, W = wm.A.shape
    a_lo = wm.A.reshape(H // scale, scale, W // scale, scale).mean((1, 3))
    inside = a_lo > 0.5
    idx = -np.ones(inside.shape, np.int64)
    ys, xs = np.nonzero(inside)
    idx[ys, xs] = np.arange(len(ys))
    rows, cols, vals = [np.arange(len(ys))], [np.arange(len(ys))], [np.full(len(ys), 4.0)]
    for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        ny, nx = ys + dy, xs + dx
        j = idx[np.clip(ny, 0, inside.shape[0] - 1), np.clip(nx, 0, inside.shape[1] - 1)]
        ok = j >= 0
        rows.append(np.nonzero(ok)[0]); cols.append(j[ok]); vals.append(np.full(ok.sum(), -1.0))
    Lm = coo_matrix((np.concatenate(vals), (np.concatenate(rows), np.concatenate(cols))),
                    shape=(len(ys), len(ys))).tocsr()
    c = 2 * dome ** 2            # P = c(a^2-x^2)/2  ->  sqrt(P) peaks at dome*a
    p = spsolve(Lm, np.full(len(ys), c * scale ** 2))
    P = np.zeros(inside.shape, np.float32); P[ys, xs] = p
    P = ndi.gaussian_filter(P, 1.2)
    P = ndi.zoom(P, scale, order=3)[:H, :W]
    h = np.sqrt(np.clip(P, 0, None))
    # pin the silhouette to the true (full-res) outline with a small round-over
    re = 0.03 * wm.cap
    d = ndi.gaussian_filter(wm.d_in, 0.005 * wm.cap)
    e = np.sqrt(np.clip(1 - (1 - np.clip(d / re, 0, 1)) ** 2, 0, 1))
    return h * e


def inflated_normals(wm, dome=0.8):
    """Puffy, liquid letterforms: each stroke is a rounded tube."""
    return normals_from_height(poisson_height(wm, dome=dome))


def reflect_view(n):
    """Reflection of an orthographic view ray (0,0,1) about n. y is down."""
    nz = n[..., 2:3]
    r = 2 * nz * n
    r[..., 2] -= 1
    return r


def lamp(n, L):
    L = np.asarray(L, np.float32); L /= np.linalg.norm(L)
    return np.clip((n * L).sum(-1), 0, 1), L


def blinn(n, L, power):
    L = np.asarray(L, np.float32); L /= np.linalg.norm(L)
    Hv = L + np.array([0, 0, 1], np.float32); Hv /= np.linalg.norm(Hv)
    return np.clip((n * Hv).sum(-1), 0, 1) ** power


def ramp(v, stops):
    """Piecewise-linear RGB ramp. stops = [(pos, (r,g,b)), ...]."""
    xs = np.array([s[0] for s in stops], np.float32)
    cs = np.array([s[1] for s in stops], np.float32)
    return np.stack([np.interp(v, xs, cs[:, c]) for c in range(3)], -1).astype(np.float32)


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)


def fbm(shape, scales, seed=0, aniso=(1, 1)):
    rng = np.random.default_rng(seed)
    out = np.zeros(shape, np.float32)
    amp = 1.0
    for s in scales:
        n = ndi.gaussian_filter(rng.standard_normal(shape).astype(np.float32),
                                (s * aniso[0], s * aniso[1]))
        out += amp * n / (n.std() + 1e-8)
        amp *= 0.5
    return out / (out.std() + 1e-8)


# ---------------------------------------------------------------- layers
def outline_alpha(wm, radius, soft=1.0):
    """Hard-ish dark ring hugging the outside of the letterforms."""
    return np.clip((radius - wm.d_out) / soft + 0.5, 0, 1).astype(np.float32)


def shadow_alpha(wm, layers):
    """layers = [(sigma, dx, dy, opacity), ...] combined with screen-style union."""
    acc = np.zeros_like(wm.A)
    for sigma, dx, dy, op in layers:
        s = ndi.gaussian_filter(wm.A, sigma)
        s = ndi.shift(s, (dy, dx), order=1, mode="constant")
        acc = 1 - (1 - acc) * (1 - op * s)
    return acc


def over(dst_rgb, dst_a, src_rgb, src_a):
    """Porter-Duff over, straight (non-premultiplied) in and out."""
    sa = src_a[..., None]; da = dst_a[..., None]
    out_a = sa + da * (1 - sa)
    out_rgb = (src_rgb * sa + dst_rgb * da * (1 - sa)) / np.maximum(out_a, 1e-6)
    return out_rgb, out_a[..., 0]


def finish(wm, metal_rgb, outline=None, shadow=None):
    """Stack shadow -> dark outline -> metal. Returns straight RGBA (SS res)."""
    rgb = np.zeros(wm.A.shape + (3,), np.float32)
    a = np.zeros_like(wm.A)
    if shadow is not None:
        rgb, a = over(rgb, a, np.zeros_like(rgb), shadow)
    if outline is not None:
        rgb, a = over(rgb, a, np.zeros_like(rgb), outline)
    rgb, a = over(rgb, a, np.clip(metal_rgb, 0, 1), wm.A)
    return rgb, a


def downsample(rgb, a, f=SS):
    """Box-filter in premultiplied space; exact registration across files."""
    H, W = a.shape
    pm = np.concatenate([rgb * a[..., None], a[..., None]], -1)
    pm = pm.reshape(H // f, f, W // f, f, 4).mean((1, 3))
    a2 = pm[..., 3]
    rgb2 = pm[..., :3] / np.maximum(a2[..., None], 1e-6)
    return rgb2, a2


def save_rgba(path, rgb, a, ss=True):
    if ss:
        rgb, a = downsample(rgb, a)
    out = np.concatenate([np.clip(rgb, 0, 1), np.clip(a, 0, 1)[..., None]], -1)
    Image.fromarray((out * 255 + 0.5).astype(np.uint8), "RGBA").save(path, optimize=False)
    return path
