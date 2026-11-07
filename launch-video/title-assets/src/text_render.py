"""Headless-Chrome text rasteriser.

Chrome does the shaping (GPOS kerning, letter-spacing) exactly the way the
GitHub card does, so the letterforms here match the card. Everything after the
raster (bevels, metal, shadows) happens in numpy, see build.py.
"""
import html
import os
import subprocess
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
FONTS = Path(__file__).resolve().parent / "fonts"
SANS = FONTS / "Geist-VariableFont_wght.ttf"      # variable 100..900
MONO = FONTS / "geist-mono-latin-500.woff2"        # Geist Mono 500


def _chrome_png(page: str, w: int, h: int, dsf: float = 1.0) -> np.ndarray:
    with tempfile.TemporaryDirectory() as td:
        hp, pp = Path(td) / "t.html", Path(td) / "t.png"
        hp.write_text(page)
        cmd = [CHROME, "--headless=new", f"--screenshot={pp}", f"--window-size={w},{h}",
               "--default-background-color=00000000", "--hide-scrollbars",
               f"--force-device-scale-factor={dsf}", f"--user-data-dir={td}/profile",
               "--no-first-run", "--no-default-browser-check", f"file://{hp}"]
        for attempt in range(4):  # headless Chrome occasionally hangs; retry
            try:
                subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, timeout=30)
                if pp.exists():
                    break
            except subprocess.TimeoutExpired:
                pass
        else:
            raise RuntimeError("headless Chrome failed to render text")
        return np.asarray(Image.open(pp).convert("RGBA")).astype(np.float32) / 255.0


def render(text: str, size: float, *, mono=False, weight=700, tracking_em=-0.02,
           margin=None, dsf=1.0, probe=False):
    """Render `text` white-on-transparent. Returns float alpha (H, W).

    probe=True renders an invisible copy of `text` plus a visible "H" sharing
    its baseline, so the caller can read cap-top / baseline in the same frame.
    """
    font = MONO if mono else SANS
    margin = int(size * 0.6) if margin is None else margin
    w = int(len(text) * size * (0.66 if mono else 0.72) + 2 * margin)
    h = int(size * 1.4 + 2 * margin)
    common = (f"position:absolute;left:{margin}px;top:{margin}px;font-family:F;"
              f"font-weight:{weight};font-size:{size}px;letter-spacing:{tracking_em}em;"
              "line-height:1;white-space:nowrap;font-kerning:normal;")
    body = (f'<div style="{common}color:transparent">{html.escape(text)}</div>'
            f'<div style="{common}color:#fff">H</div>' if probe else
            f'<div style="{common}color:#fff">{html.escape(text)}</div>')
    page = (f"<!doctype html><html><head><style>@font-face{{font-family:F;"
            f"src:url('file://{font}');font-weight:100 900;}}"
            "html,body{margin:0;background:transparent}</style></head>"
            f"<body>{body}</body></html>")
    rgba = _chrome_png(page, w, h, dsf)
    return rgba[..., 3]


def ink_bbox(a: np.ndarray, thr=1 / 255):
    ys, xs = np.nonzero(a > thr)
    return xs.min(), ys.min(), xs.max() + 1, ys.max() + 1
