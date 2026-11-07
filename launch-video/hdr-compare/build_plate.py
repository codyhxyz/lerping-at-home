"""The static layers of the SDR/HDR comparison, Cap-style: the wallpaper, two
real macOS windows (chrome/, from grab.sh) with their system shadow, and a
caption under each. Writes:

    plate.png   3840x2160 RGB, everything except window content
    mask.png    3840x2160 L, where window content shows (antialiased corners)
    layout.json content rects in pixels, left (SDR) then right (HDR)

The captures are of inactive windows (grey lights, grey title: macOS would not
hand focus to a scripted app), so they are recoloured to the active state.
"""
import json
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
W, H = 3840, 2160
WALL = os.path.expanduser('~/Library/Application Support/Lerping/wallpaper/current.png')
GAP = 96
CAPTIONS = ['SDR', 'HDR']

# Active traffic lights (macOS 26): fill, rim.
LIGHTS = [((255, 95, 87), (224, 68, 62)), ((254, 188, 46), (222, 161, 35)), ((40, 200, 64), (26, 171, 41))]
LIGHT_X = [31.5, 77.5, 123.5]   # centres in the 2x frame capture
LIGHT_Y, LIGHT_D = 32, 28


def magenta(a):
    return (a[..., 0] > 200) & (a[..., 1] < 90) & (a[..., 2] > 200)


def activate(img, ox, oy, title_top):
    """Recolour lights and title text of a capture whose window frame starts at (ox, oy)."""
    a = np.asarray(img).astype(np.float32)
    # Title: inactive grey (~180) -> active near-black (~38), same antialiasing.
    band = a[oy:oy + title_top, ox + 160:ox + 1500, :3]
    lum = band.mean(-1, keepdims=True)
    ink = np.clip((255 - lum) / (255 - 180), 0, 1)       # 0 = background, 1 = full text
    band[:] = band * (1 - ink) + 38 * ink
    out = Image.fromarray(a.clip(0, 255).astype(np.uint8), 'RGBA')
    S = 4
    layer = Image.new('RGBA', (out.width * S, out.height * S), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    r = LIGHT_D / 2 * S
    for (fill, rim), x in zip(LIGHTS, LIGHT_X):
        cx, cy = (ox + x) * S, (oy + LIGHT_Y) * S
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=rim + (255,))
        d.ellipse([cx - r + 1.5 * S, cy - r + 1.5 * S, cx + r - 1.5 * S, cy + r - 1.5 * S], fill=fill + (255,))
    layer = layer.resize(out.size, Image.LANCZOS)
    return Image.alpha_composite(out, layer)


def main():
    wall = Image.open(WALL).convert('RGB')
    s = max(W / wall.width, H / wall.height)
    wall = wall.resize((round(wall.width * s), round(wall.height * s)), Image.LANCZOS)
    wall = wall.crop(((wall.width - W) // 2, (wall.height - H) // 2, (wall.width - W) // 2 + W, (wall.height - H) // 2 + H))
    plate = wall.convert('RGBA')
    mask = np.zeros((H, W), np.float32)

    frame0 = np.asarray(Image.open(f'{HERE}/chrome/window0-frame.png').convert('RGBA'))
    fw, fh = frame0.shape[1], frame0.shape[0]
    x0 = (W - (2 * fw + GAP)) // 2
    y0 = (H - fh) // 2 - 40
    rects = []
    font = ImageFont.truetype('/System/Library/Fonts/SFNS.ttf', 46)
    font.set_variation_by_axes([100, 28, 400, 600])   # width, optical size, grade, weight: SF Pro Display Semibold
    for i in range(2):
        frame = np.asarray(Image.open(f'{HERE}/chrome/window{i}-frame.png').convert('RGBA'))
        shadow = Image.open(f'{HERE}/chrome/window{i}-shadow.png').convert('RGBA')
        sm = np.nonzero(magenta(np.asarray(shadow)))
        fm = np.nonzero(magenta(frame))
        # Align the shadow capture on the frame capture by their content boxes.
        dx, dy = sm[1].min() - fm[1].min(), sm[0].min() - fm[0].min()
        title_top = fm[0].min()
        shadow = activate(shadow, dx, dy, title_top)
        sa = np.asarray(shadow).copy()
        # Cut the content hole out of the chrome: the renderer paints it.
        hole = np.zeros(sa.shape[:2], np.float32)
        fa = frame[..., 3].astype(np.float32) / 255 * magenta(frame)
        hole[dy:dy + fh, dx:dx + fw] = fa
        sa[..., 3] = (sa[..., 3] * (1 - hole)).astype(np.uint8)
        wx = x0 + i * (fw + GAP)
        plate.alpha_composite(Image.fromarray(sa, 'RGBA'), (wx - dx, y0 - dy))
        mask[y0:y0 + fh, wx:wx + fw] = np.maximum(mask[y0:y0 + fh, wx:wx + fw], fa)
        cx0, cy0 = fm[1].min(), fm[0].min()
        rects.append({'x': int(wx + cx0), 'y': int(y0 + cy0), 'w': int(fm[1].max() - cx0 + 1), 'h': int(fm[0].max() - cy0 + 1)})
        # Caption, centred under the window.
        tw = ImageDraw.Draw(plate).textlength(CAPTIONS[i], font=font)
        pos = (wx + (fw - tw) / 2, y0 + fh + 64)
        glow = Image.new('RGBA', plate.size, (0, 0, 0, 0))
        ImageDraw.Draw(glow).text((pos[0], pos[1] + 4), CAPTIONS[i], font=font, fill=(0, 0, 0, 110))
        plate.alpha_composite(glow.filter(ImageFilter.GaussianBlur(10)))
        ImageDraw.Draw(plate).text(pos, CAPTIONS[i], font=font, fill=(255, 255, 255, 245))

    plate.convert('RGB').save(f'{HERE}/plate.png')
    Image.fromarray((mask * 255).round().astype(np.uint8), 'L').save(f'{HERE}/mask.png')
    json.dump(rects, open(f'{HERE}/layout.json', 'w'), indent=1)
    print(rects)


main()
