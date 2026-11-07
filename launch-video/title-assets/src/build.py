#!/usr/bin/env python3
"""Render every Lerping@Home title asset.

    python3 build.py                         # everything, default copy
    python3 build.py --title "Other@Name"    # different wordmark text
    python3 build.py --only wordmark         # wordmark | closing | preview

Needs: Google Chrome (text shaping), numpy, scipy, Pillow.
Pipeline: Chrome rasterises the text in Geist at 2x -> numpy builds height
fields (chamfer / Poisson inflation) -> normals -> environment-mapped metal ->
dark outline + shadow -> box-downsampled to the output size.
"""
import argparse
import pickle
import time
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage as ndi

import metal as M
import text_render as tr
import treatments as T

HERE = Path(__file__).resolve().parent
OUT = HERE.parent
REF = HERE / "ref"
BG = (7, 8, 10)

TREATMENTS = {               # file suffix -> shading function
    "chrome": T.chrome,
    "liquid-metal": T.liquid_metal,
    "gunmetal": T.gunmetal,
}
BEST = "liquid-metal"        # used for closing-name


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


# ------------------------------------------------------------------ helpers
def baked_shadow(wm):
    """Shadow + hairline dark outline baked under every metal treatment."""
    sh = M.shadow_alpha(wm, [(0.025 * wm.cap, 0, 0.020 * wm.cap, 0.75),
                             (0.090 * wm.cap, 0, 0.045 * wm.cap, 0.50)])
    ol = M.outline_alpha(wm, 0.008 * wm.cap)
    return sh, ol


def load_rgba(p):
    return np.asarray(Image.open(p).convert("RGBA")).astype(np.float32) / 255


def resize_rgba(img: Image.Image, w):
    h = round(img.height * w / img.width)
    return img.convert("RGBa").resize((w, h), Image.LANCZOS).convert("RGBA")


def text_png(text, size, *, mono=False, weight=500, tracking=0.0, color=(1, 1, 1),
             opacity=1.0, dsf=1):
    """Flat-colour text, tight crop + 0.4em transparent margin."""
    a = tr.render(text, size, mono=mono, weight=weight, tracking_em=tracking, dsf=dsf)
    x0, y0, x1, y1 = tr.ink_bbox(a)
    m = int(0.4 * size * dsf)
    a = np.pad(a[y0:y1, x0:x1], m)
    rgba = np.zeros(a.shape + (4,), np.float32)
    rgba[..., :3] = color
    rgba[..., 3] = a * opacity
    return Image.fromarray((rgba * 255 + 0.5).astype(np.uint8), "RGBA")


# ------------------------------------------------------------------ wordmark
def build_wordmark(title, cache):
    if cache and cache.exists():
        wm = pickle.loads(cache.read_bytes())
        if wm.text != title:
            wm = None
    else:
        wm = None
    if wm is None:
        log("rasterising", repr(title))
        wm = M.Wordmark(title)
        if cache:
            cache.write_bytes(pickle.dumps(wm))
    log("canvas", wm.out_size, "cap(2x)", wm.cap)
    white = np.ones(wm.A.shape + (3,), np.float32)

    M.save_rgba(OUT / "wordmark-mask.png", white, wm.A)

    log("bevel")
    M.save_rgba(OUT / "wordmark-bevel.png", T.bevel_map(wm), wm.A)

    log("shadow")
    sh = M.shadow_alpha(wm, [(0.035 * wm.cap, 0, 0.020 * wm.cap, 0.80),
                             (0.120 * wm.cap, 0, 0.040 * wm.cap, 0.55)])
    edge = max(sh[0].max(), sh[-1].max(), sh[:, 0].max(), sh[:, -1].max())
    log(f"  shadow alpha at canvas border: {edge:.4f}")
    M.save_rgba(OUT / "wordmark-shadow.png", np.zeros_like(white), sh)

    bsh, bol = baked_shadow(wm)
    for name, fn in TREATMENTS.items():
        log(name)
        rgb, a = M.finish(wm, fn(wm), bol, bsh)
        M.save_rgba(OUT / f"wordmark-{name}.png", rgb, a)

    log("specular sweep")
    band = T.sweep_band(wm, center=0.5)
    M.save_rgba(OUT / "specular-band.png", white, band)
    M.save_rgba(OUT / "specular-sweep.png", white, band * wm.A * T.sweep_edge_boost(wm))
    return wm


# ------------------------------------------------------------------ closing
CLOSE = dict(name_w=1000, byline_px=46, url_px=30)


def build_closing(url, byline):
    best = Image.open(OUT / f"wordmark-{BEST}.png")
    for scale, suffix in ((1, ""), (2, "@2x")):
        name = resize_rgba(best, CLOSE["name_w"] * scale)
        name.save(OUT / f"closing-name{suffix}.png")
        text_png(url, CLOSE["url_px"], mono=True, weight=500, color=(0.78, 0.80, 0.83),
                 dsf=scale).save(OUT / f"closing-url{suffix}.png")
        text_png(byline, CLOSE["byline_px"], weight=500, tracking=-0.01, opacity=0.8,
                 dsf=scale).save(OUT / f"closing-byline{suffix}.png")

    # 1920x1080 composition. closing-name's canvas carries padding + shadow,
    # so position by its ink box (alpha of the mask, scaled the same way).
    card = Image.new("RGBA", (1920, 1080), BG + (255,))
    name = Image.open(OUT / "closing-name.png")
    mask = resize_rgba(Image.open(OUT / "wordmark-mask.png"), name.width)
    nx0, ny0, nx1, ny1 = tr.ink_bbox(np.asarray(mask)[..., 3] / 255, thr=0.5)
    byl = Image.open(OUT / "closing-byline.png")
    url_ = Image.open(OUT / "closing-url.png")
    m_b, m_u = int(0.4 * CLOSE["byline_px"]), int(0.4 * CLOSE["url_px"])
    ink_h = [ny1 - ny0, byl.height - 2 * m_b, url_.height - 2 * m_u]
    gaps = [58, 30]
    total = sum(ink_h) + sum(gaps)
    y = (1080 - total) // 2 - 10
    card.alpha_composite(name, ((1920 - name.width) // 2, y - ny0))
    y += ink_h[0] + gaps[0]
    card.alpha_composite(byl, ((1920 - byl.width) // 2, y - m_b))
    y += ink_h[1] + gaps[1]
    card.alpha_composite(url_, ((1920 - url_.width) // 2, y - m_u))
    card.convert("RGB").save(OUT / "closing-card.png")


# ------------------------------------------------------------------ preview
def overlay(base, blend):
    return np.where(base < 0.5, 2 * base * blend, 1 - 2 * (1 - base) * (1 - blend))


def video_fill_demo():
    """What the mask + bevel do to real shader footage (preview only)."""
    mask = load_rgba(OUT / "wordmark-mask.png")
    bevel = load_rgba(OUT / "wordmark-bevel.png")
    H, W = mask.shape[:2]
    fill = np.asarray(Image.open(REF / "mesh-gradient-fill.png").convert("RGB")
                      .resize((W, H), Image.LANCZOS)).astype(np.float32) / 255
    lit = np.clip(overlay(fill, bevel[..., :3]), 0, 1)
    shadow = load_rgba(OUT / "wordmark-shadow.png")
    out = np.zeros((H, W, 4), np.float32)
    rgb, a = M.over(out[..., :3], out[..., 3], np.zeros_like(lit), shadow[..., 3])
    rgb, a = M.over(rgb, a, lit, mask[..., 3])
    return Image.fromarray((np.dstack([rgb, a]) * 255 + 0.5).astype(np.uint8), "RGBA")


def busy_backgrounds(w, h):
    show = Image.open(REF / "shader-showcase.jpg").convert("RGB")
    tile = show.resize((round(show.width * h / show.height * 1.6), round(h * 1.6)))
    b1 = Image.new("RGB", (w, h))
    for x in range(-tile.width // 3, w, tile.width):
        b1.paste(tile, (x, -h // 4))
    grid = Image.open(REF / "shader-grid-1920.png").convert("RGB")
    s = max(w / grid.width, h / grid.height) * 1.0
    g = grid.resize((round(grid.width * s), round(grid.height * s)))
    b2 = g.crop(((g.width - w) // 2, (g.height - h) // 2,
                 (g.width - w) // 2 + w, (g.height - h) // 2 + h))
    return b1.convert("RGBA"), b2.convert("RGBA")


def label(text, size=26, color=(0.75, 0.77, 0.8)):
    return text_png(text, size, mono=True, color=color)


def build_preview():
    rows = [
        ("wordmark-mask.png", None), ("wordmark-bevel.png", None),
        ("wordmark-chrome.png", None), ("wordmark-liquid-metal.png", None),
        ("wordmark-gunmetal.png", None), ("wordmark-shadow.png", None),
        ("specular-sweep.png", None),
        ("demo: mask + bevel (overlay) + shadow on mesh-gradient footage", video_fill_demo()),
        ("demo: wordmark-shadow + liquid-metal + specular-sweep (screen)", None),
        ("closing-name.png", None), ("closing-byline.png", None), ("closing-url.png", None),
        ("closing-card.png", None),
    ]
    cw, gap, lw = 1100, 36, 0
    cols = ["(a) over black", "(b) over shader-showcase.jpg", "(c) over a 6x5 shader grid"]
    cells = []
    for name, img in rows:
        if img is None and name.startswith("demo: wordmark-shadow"):
            base = Image.open(OUT / "wordmark-shadow.png")
            base.alpha_composite(Image.open(OUT / "wordmark-liquid-metal.png"))
            sw = load_rgba(OUT / "specular-sweep.png")
            arr = np.asarray(base).astype(np.float32) / 255
            arr[..., :3] = 1 - (1 - arr[..., :3]) * (1 - sw[..., :3] * sw[..., 3:4] * 0.9)
            img = Image.fromarray((arr * 255 + 0.5).astype(np.uint8), "RGBA")
        elif img is None:
            img = Image.open(OUT / name).convert("RGBA")
        if name.startswith("closing-") and name != "closing-card.png":
            # show closing pieces at their real 1080p size, centred
            fit = img
        else:
            fit = resize_rgba(img, cw - 40)
        cells.append((name, fit))
    row_h = [max(c[1].height + 40, 120) for c in cells]
    head = 150
    W = 3 * cw + 4 * gap
    H = head + sum(row_h) + len(cells) * (gap + 46) + gap
    sheet = Image.new("RGBA", (W, H), (18, 19, 22, 255))
    sheet.alpha_composite(label("Lerping@Home title assets", 40, (0.95, 0.95, 0.97)), (gap, 30))
    for i, c in enumerate(cols):
        sheet.alpha_composite(label(c, 28), (gap + i * (cw + gap), 95))
    y = head
    for (name, img), rh in zip(cells, row_h):
        sheet.alpha_composite(label(name, 26), (gap, y))
        y += 46
        bgs = [Image.new("RGBA", (cw, rh), (0, 0, 0, 255)), *busy_backgrounds(cw, rh)]
        for i, bg in enumerate(bgs):
            bg.alpha_composite(img, ((cw - img.width) // 2, (rh - img.height) // 2))
            sheet.alpha_composite(bg, (gap + i * (cw + gap), y))
        y += rh + gap
    sheet.convert("RGB").save(OUT / "assets-preview.png")


# ------------------------------------------------------------------ main
if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--title", default="Lerping@Home")
    ap.add_argument("--url", default="github.com/codyhxyz/lerping-at-home")
    ap.add_argument("--byline", default="Screensavers for Apple Silicon.")
    ap.add_argument("--only", choices=["wordmark", "closing", "preview"])
    ap.add_argument("--cache", type=Path, help="pickle the rasterised wordmark here")
    args = ap.parse_args()
    if args.only in (None, "wordmark"):
        build_wordmark(args.title, args.cache)
    if args.only in (None, "closing"):
        build_closing(args.url, args.byline)
    if args.only in (None, "preview"):
        build_preview()
    log("done")
