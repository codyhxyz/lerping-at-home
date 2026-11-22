"""Software-render block states from a bake's materials.u32 / elements.u32, to
check them by eye without a GPU. It decodes the bytes the way FORMAT.md says a
shader does (not from materials.py's Python objects) and samples the packed
atlas (tiles.rgba, skins.rgba), so a picture that looks like the game means
the files are right.

    python3 preview_block.py OUT.png 'minecraft:oak_stairs[facing=east,half=bottom,shape=straight,waterlogged=false]' ...
        --dir DIR      folder with materials.u32 / elements.u32 / materials.json (a bake, or a materials.py --out)
        --atlas DIR    the packed atlas (default ~/Library/Application Support/Lerping/Minecraft)

Each state gets a row of four views (from the north-west, north-east,
south-east and south-west, 30 degrees above the horizon), under the state's
name. A state with random variants is drawn with its first listed id; pass
'#<id>' to draw an id directly. Tints use the plains biome from the jar's
colormaps (grass, foliage) and plains water; this is a preview, the world uses
the bake's per-column tints.
"""

import argparse
import json
import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw

MAT_WORDS, ELEM_WORDS = 32, 80
DIR_N = np.array([(0, -1, 0), (0, 1, 0), (0, 0, -1), (0, 0, 1), (-1, 0, 0), (1, 0, 0)], dtype=np.float64)
# Plains: GrassColor / FoliageColor at temperature 0.8, downfall 0.4; plains water_color.
PLAINS = {1: (0x91, 0xBD, 0x59), 2: (0x77, 0xAB, 0x2F), 3: (0x3F, 0x76, 0xE4), 4: (0x95, 0x6B, 0x3E)}


def p3_to_srgb_bytes(rgb):
    """The atlas stores Display P3; the PNG is sRGB."""
    c = rgb.astype(np.float64) / 255.0
    lin = np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)
    m = np.linalg.inv(np.array([[0.8224621, 0.1775380, 0.0], [0.0331941, 0.9668058, 0.0], [0.0170827, 0.0723974, 0.9105199]]))
    lin = np.clip(lin @ m.T, 0, 1)
    e = np.where(lin <= 0.0031308, lin * 12.92, 1.055 * lin ** (1 / 2.4) - 0.055)
    return e


def srgb_bytes_to_float(rgb):
    return np.asarray(rgb, dtype=np.float64) / 255.0


class Atlas:
    def __init__(self, folder):
        meta = json.load(open(os.path.join(folder, "atlas.json")))
        self.tiles = np.fromfile(os.path.join(folder, "tiles.rgba"), dtype=np.uint8).reshape(meta["tiles"], 16, 16, 4)
        self.skins = np.fromfile(os.path.join(folder, "skins.rgba"), dtype=np.uint8).reshape(meta["skins"], 64, 64, 4)

    def sample(self, array, layer, texel):
        """Nearest texel; texel in layer pixels. Returns sRGB float rgb and alpha."""
        arr = self.tiles if array == 0 else self.skins
        size = arr.shape[1]
        x = np.clip(np.floor(texel[..., 0]).astype(int), 0, size - 1)
        y = np.clip(np.floor(texel[..., 1]).astype(int), 0, size - 1)
        px = arr[layer, y, x]
        return p3_to_srgb_bytes(px[..., :3]), px[..., 3] / 255.0


class Files:
    def __init__(self, folder):
        self.mat = np.fromfile(os.path.join(folder, "materials.u32"), dtype="<u4").reshape(-1, MAT_WORDS)
        self.el = np.fromfile(os.path.join(folder, "elements.u32"), dtype="<u4").reshape(-1, ELEM_WORDS)
        self.meta = json.load(open(os.path.join(folder, "materials.json")))
        self.by_state = {}
        for m in self.meta["materials"]:
            for s in m["states"]:
                self.by_state.setdefault(s.split(" variant ")[0], m["id"])
                self.by_state.setdefault(s, m["id"])


def f(word):
    return np.frombuffer(np.uint32(word).tobytes(), dtype="<f4")[0].astype(np.float64)


def decode_face(A, B):
    return {
        "layer": A & 0xFFF, "array": (A >> 12) & 1, "o": (A >> 13) & 7, "tint": (A >> 16) & 15,
        "render": (A >> 20) & 3, "shade": (A >> 22) & 1, "present": (A >> 23) & 1,
        "emission": (A >> 24) & 15, "cull": (A >> 28) & 7, "frames": B & 0xFF, "ticks": (B >> 8) & 0xFFFF,
    }


def canonical_st(d, p):
    x, y, z = p[..., 0], p[..., 1], p[..., 2]
    return [(x, 1 - z), (x, z), (1 - x, 1 - y), (x, 1 - y), (z, 1 - y), (1 - z, 1 - y)][d]


def face_shade(n):
    """mcFaceShade: top 1, bottom 0.5, z faces 0.8, x faces 0.6 (weighted by the normal for tilted faces)."""
    return n[..., 0] ** 2 * 0.6 + n[..., 2] ** 2 * 0.8 + np.where(n[..., 1] > 0, 1.0, 0.5) * n[..., 1] ** 2


def tint_rgb(code, mat):
    if code == 0:
        return np.ones(3)
    if code in PLAINS:
        return srgb_bytes_to_float(PLAINS[code])
    w = mat[4] if code == 5 else mat[5]
    return srgb_bytes_to_float(((w >> 16) & 255, (w >> 8) & 255, w & 255))


def box_hit(o, d, lo, hi):
    """Slab test for many rays: tNear, entry face (0..5), hit mask."""
    with np.errstate(divide="ignore", invalid="ignore"):
        inv = 1.0 / np.where(np.abs(d) < 1e-12, 1e-12, d)
        t0 = (lo - o) * inv
        t1 = (hi - o) * inv
    tn = np.minimum(t0, t1)
    tf = np.maximum(t0, t1)
    tnear = tn.max(axis=-1)
    tfar = tf.min(axis=-1)
    axis = tn.argmax(axis=-1)
    hit = (tnear <= tfar + 1e-9) & (tfar > 0)
    face = np.where(axis == 0, np.where(d[..., 0] > 0, 4, 5),
           np.where(axis == 1, np.where(d[..., 1] > 0, 0, 1), np.where(d[..., 2] > 0, 2, 3)))
    return tnear, face, hit


def trace_material(files, atlas, mid, o, d):
    """Candidate surface hits for every ray: list of (t, rgb, alpha, render)."""
    mat = files.mat[mid]
    kind = mat[0] & 3
    cands = []
    if kind == 1:
        tn, face, hit = box_hit(o, d, np.zeros(3), np.ones(3))
        p = o + d * tn[..., None]
        rgb = np.zeros(o.shape[:-1] + (3,))
        alpha = np.zeros(o.shape[:-1])
        render = np.zeros(o.shape[:-1], dtype=int)
        for dd in range(6):
            sel = hit & (face == dd)
            if not sel.any():
                continue
            for slot, over in ((8, False), (20, True)):
                A, B = int(mat[slot + 2 * dd]), int(mat[slot + 1 + 2 * dd])
                if not (A >> 23) & 1:
                    continue
                fd = decode_face(A, B)
                s, t = canonical_st(dd, p[sel])
                o3 = fd["o"]
                u, v = (t, s) if o3 & 4 else (s, t)
                if o3 & 1:
                    u = 1 - u
                if o3 & 2:
                    v = 1 - v
                c, a = atlas.sample(fd["array"], fd["layer"], np.stack([u * 16, v * 16], -1))
                c = c * tint_rgb(fd["tint"], mat)
                sh = face_shade(DIR_N[dd]) if fd["shade"] else 1.0
                c = c * sh
                if not over:
                    rgb[sel], alpha[sel], render[sel] = c, a, fd["render"]
                else:
                    ao = a[:, None]
                    rgb[sel] = rgb[sel] * (1 - ao) + c * ao
        cands.append((np.where(hit, tn, np.inf), rgb, alpha, render))
    elif kind == 2:
        first, count = int(mat[1]), int(mat[2])
        for r in range(first, first + count):
            e = files.el[r]
            lo = np.array([f(e[0]), f(e[1]), f(e[2])])
            hi = np.array([f(e[4]), f(e[5]), f(e[6])])
            xform = e[3] & 1
            M = np.array([[f(e[8 + 4 * i + j]) for j in range(4)] for i in range(3)])
            if xform:
                qo = (o[..., None, :] * M[:, :3]).sum(-1) + M[:, 3]
                qd = (d[..., None, :] * M[:, :3]).sum(-1)
            else:
                qo, qd = o, d
            tn, face, hit = box_hit(qo, qd, lo, hi)
            q = qo + qd * tn[..., None]
            rgb = np.zeros(o.shape[:-1] + (3,))
            alpha = np.zeros(o.shape[:-1])
            render = np.zeros(o.shape[:-1], dtype=int)
            ok = np.zeros(o.shape[:-1], dtype=bool)
            for dd in range(6):
                if not (e[3] >> (1 + dd)) & 1:
                    continue
                sel = hit & (face == dd)
                if not sel.any():
                    continue
                U = np.array([f(e[20 + 8 * dd + k]) for k in range(4)])
                V = np.array([f(e[24 + 8 * dd + k]) for k in range(4)])
                fd = decode_face(int(e[68 + 2 * dd]), int(e[69 + 2 * dd]))
                qs = q[sel]
                tex = np.stack([(qs * U[:3]).sum(-1) + U[3], (qs * V[:3]).sum(-1) + V[3]], -1)
                c, a = atlas.sample(fd["array"], fd["layer"], tex)
                c = c * tint_rgb(fd["tint"], mat)
                nq = DIR_N[dd]
                n = nq @ M[:, :3] if xform else nq
                n = n / np.linalg.norm(n)
                if fd["shade"]:
                    c = c * face_shade(n)
                rgb[sel], alpha[sel], render[sel] = c, a, fd["render"]
                ok[sel] = True
            cands.append((np.where(ok, tn, np.inf), rgb, alpha, render))
    fl = mat[3] & 3
    if fl:
        amount = (mat[3] >> 2) & 15
        h = 1.0 if (mat[3] >> 6) & 1 else amount / 9.0
        air = files.mat[0]
        tn, face, hit = box_hit(o, d, np.zeros(3), np.array([1.0, h, 1.0]))
        p = o + d * tn[..., None]
        rgb = np.zeros(o.shape[:-1] + (3,))
        alpha = np.zeros(o.shape[:-1])
        render = np.zeros(o.shape[:-1], dtype=int)
        for dd in range(6):
            sel = hit & (face == dd)
            if not sel.any():
                continue
            slot = (8 if dd in (0, 1) else 10) if fl == 1 else (14 if dd in (0, 1) else 16)
            fd = decode_face(int(air[slot]), int(air[slot + 1]))
            s, t = canonical_st(dd, p[sel])
            size = 16 if fd["array"] == 0 else 32
            c, a = atlas.sample(fd["array"], fd["layer"], np.stack([s * size, t * size], -1))
            c = c * tint_rgb(fd["tint"], mat) * face_shade(DIR_N[dd])
            rgb[sel], alpha[sel], render[sel] = c, a, fd["render"]
        cands.append((np.where(hit, tn, np.inf), rgb, alpha, render))
    return cands


def composite(cands, shape, bg):
    """Nearest-first: cut out below the game's thresholds, blend translucent, stop at the first solid."""
    if not cands:
        return np.broadcast_to(bg, shape + (3,)).copy()
    T = np.stack([c[0] for c in cands], 0)
    order = np.argsort(T, axis=0)
    out = np.zeros(shape + (3,))
    trans = np.ones(shape)
    for k in range(len(cands)):
        idx = order[k]
        t = np.take_along_axis(T, idx[None], 0)[0]
        rgb = np.choose(idx[..., None], [c[1] for c in cands]) if len(cands) > 1 else cands[0][1]
        a = np.choose(idx, [c[2] for c in cands]) if len(cands) > 1 else cands[0][2]
        r = np.choose(idx, [c[3] for c in cands]) if len(cands) > 1 else cands[0][3]
        valid = np.isfinite(t)
        keep = valid & np.where(r == 1, a >= 0.5, np.where(r == 2, a >= 0.1, True))
        alpha = np.where(r == 2, a, 1.0) * keep
        out += trans[..., None] * alpha[..., None] * rgb
        trans *= 1 - alpha
    out += trans[..., None] * bg
    return out


def render_view(files, atlas, mid, azimuth, size=160, elevation=30.0):
    az, el = math.radians(azimuth), math.radians(elevation)
    fwd = -np.array([math.cos(el) * math.sin(az), math.sin(el), math.cos(el) * math.cos(az)])
    right = np.cross(fwd, [0, 1, 0])
    right /= np.linalg.norm(right)
    up = np.cross(right, fwd)
    span = 1.9
    ys, xs = np.mgrid[0:size, 0:size]
    sx = (xs + 0.5) / size * 2 - 1
    sy = 1 - (ys + 0.5) / size * 2
    center = np.array([0.5, 0.5, 0.5])
    o = center + (sx[..., None] * right + sy[..., None] * up) * span / 2 - fwd * 4
    d = np.broadcast_to(fwd, o.shape)
    cands = trace_material(files, atlas, mid, o, d)
    bg = np.array([0.55, 0.62, 0.7])
    img = composite(cands, (size, size), bg)
    # faint unit-cell outline: ground square
    return (np.clip(img, 0, 1) * 255).astype(np.uint8)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("states", nargs="+")
    ap.add_argument("--dir", required=True)
    ap.add_argument("--atlas", default=os.path.expanduser("~/Library/Application Support/Lerping/Minecraft"))
    ap.add_argument("--size", type=int, default=160)
    args = ap.parse_args()
    files = Files(args.dir)
    atlas = Atlas(args.atlas)
    rows = []
    for s in args.states:
        mid = int(s[1:]) if s.startswith("#") else files.by_state.get(s)
        if mid is None:
            sys.exit(f"preview_block: {s} is not in {args.dir}/materials.json")
        views = [render_view(files, atlas, mid, a, args.size) for a in (225, 135, 45, 315)]
        row = np.concatenate(views, axis=1)
        label = Image.new("RGB", (row.shape[1], 16), (20, 20, 20))
        ImageDraw.Draw(label).text((4, 2), f"#{mid} {s}"[:110], fill=(230, 230, 230))
        rows.append(np.concatenate([np.array(label), row], axis=0))
    Image.fromarray(np.concatenate(rows, axis=0)).save(args.out)
    print(args.out)


if __name__ == "__main__":
    main()
