#!/usr/bin/env python3
"""Check pictures of a baked world, read back from its files' bytes.

    python3 scripts/minecraft-world/preview_world.py WORLD_DIR OUT_DIR [--compare-save SAVE_DIR]

Everything is decoded from the files as FORMAT.md describes them (sizes from
world.json, map colours from materials.json), not from the bake's Python
objects, so a picture that looks right means the bytes are right. Writes:

    map.png        top-down, the top block's map colour times its column tint, hill-shaded
    height.png     top-down surface height
    slice_*.png    vertical slices through the centre (x, z and diagonal): materials,
                   sky light, coloured block light, skip distance
    far.png        the far field, with the volume's box outlined
    overlay.png    routes and points of interest over the map

--compare-save compares the baked light with the light the game stored in the
save (SkyLight / BlockLight of each section), away from the box's edges.
"""

import argparse
import json
import os
import sys

import numpy as np
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))


def load(world):
    meta = json.load(open(os.path.join(world, "world.json")))
    W, H, D = meta["size"]
    blocks = np.fromfile(os.path.join(world, "blocks.r16"), "<u2")
    assert blocks.size == W * H * D, f"blocks.r16 has {blocks.size} texels, expected {W * H * D}"
    blocks = blocks.reshape(D, H, W)
    light = np.fromfile(os.path.join(world, "light.rgba8"), np.uint8)
    assert light.size == W * H * D * 4
    light = light.reshape(D, H, W, 4)
    tints = np.fromfile(os.path.join(world, "tints.rgba8"), np.uint8)
    layers = tints.size // (W * D * 4)
    assert tints.size == layers * W * D * 4
    tints = tints.reshape(layers, D, W, 4)
    FW, FD = meta["far"]["size"]
    far_h = np.fromfile(os.path.join(world, "far.rg16"), "<u2")
    assert far_h.size == FW * FD * 2
    far_h = far_h.reshape(FD, FW, 2)
    far_c = np.fromfile(os.path.join(world, "far.rgba8"), np.uint8)
    assert far_c.size == 2 * FW * FD * 4
    far_c = far_c.reshape(2, FD, FW, 4)
    r = np.fromfile(os.path.join(world, "routes.u16"), "<u2")
    nl, npt = int(r[0]), int(r[1])
    loops = r[2:2 + 4 * nl].reshape(nl, 4)
    pts = r[2 + 4 * nl:2 + 4 * nl + 4 * npt].reshape(npt, 4)
    assert r.size == 2 + 4 * nl + 4 * npt, "routes.u16 has trailing bytes"
    mats = json.load(open(os.path.join(world, "materials.json")))
    return meta, blocks, light, tints, far_h, far_c, loops, pts, mats


def material_colours(mats, n):
    rows = mats["materials"] if isinstance(mats, dict) and "materials" in mats else mats
    col = np.zeros((max(n, len(rows)), 3), np.float64)
    tk = np.zeros(max(n, len(rows)), np.int8)
    kinds = {None: 0, "grass": 1, "foliage": 2, "water": 3, "dry_foliage": 4}
    for i, m in enumerate(rows):
        mid = m.get("id", i)
        col[mid] = np.array(m["map_color"], np.float64) / 255.0
        tk[mid] = kinds[m.get("tint_kind")]
    return col, tk


def up(img, k):
    return img.resize((img.width * k, img.height * k), Image.NEAREST)


def save(img, path):
    img.save(path)
    print("wrote", path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("world")
    ap.add_argument("out")
    ap.add_argument("--compare-save")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    meta, blocks, light, tints, far_h, far_c, loops, pts, mats = load(a.world)
    W, H, D = meta["size"]
    mid = (blocks & 0x0FFF).astype(np.int64)
    skip = (blocks >> 12).astype(np.int64)
    assert ((skip == 0) | (mid == 0)).all(), "a non-air voxel has a skip distance"
    mcol, mtk = material_colours(mats, int(mid.max()) + 1)
    tint = np.ones((5, D, W, 3))
    for li in range(tints.shape[0]):
        tint[li + 1] = tints[li, ..., :3] / 255.0

    # Top-down map.
    nonair = mid != 0
    rev = nonair[:, ::-1, :]
    top = np.where(rev.any(axis=1), H - 1 - rev.argmax(axis=1), -1)          # [D, W]
    zz, xx = np.mgrid[0:D, 0:W]
    tm = mid[zz, np.maximum(top, 0), xx]
    c = mcol[tm] * tint[mtk[tm], zz, xx]
    shade = np.ones((D, W))
    dh = np.zeros((D, W))
    dh[1:] = top[1:] - top[:-1]                                                # higher than the block to the north: lighter
    shade = np.where(dh > 0, 1.0, np.where(dh < 0, 0.71, 0.86))
    c = c * shade[..., None] * (top >= 0)[..., None]
    mp = Image.fromarray(np.clip(c * 255, 0, 255).astype(np.uint8))
    save(up(mp, 2), os.path.join(a.out, "map.png"))
    h = np.where(top >= 0, top, 0).astype(np.float64)
    hn = (h - h[top >= 0].min()) / max(1, np.ptp(h[top >= 0]))
    save(up(Image.fromarray((hn * 255).astype(np.uint8)), 2), os.path.join(a.out, "height.png"))

    # Slices through the centre.
    cz, cx = D // 2, W // 2
    lit = [p for p in meta["poi"] if p["kind"] == "lit"]
    n = min(D, W)
    diag = (np.arange(n), np.arange(n))
    slices = {
        "x": (mid[cz], light[cz], skip[cz], (np.full(W, cz), np.arange(W))),         # along x at z = cz: [H, W]
        "z": (mid[:, :, cx].T, light[:, :, cx].transpose(1, 0, 2), skip[:, :, cx].T, (np.arange(D), np.full(D, cx))),
        "diag": (mid[diag[0], :, diag[1]].T, light[diag[0], :, diag[1]].transpose(1, 0, 2),
                 skip[diag[0], :, diag[1]].T, diag),
    }
    if lit:                     # one more along x through the brightest lit spot
        lz = int(lit[0]["pos"][2])
        slices["lit"] = (mid[lz], light[lz], skip[lz], (np.full(W, lz), np.arange(W)))
    for name, (m, L, sk, (cols_z, cols_x)) in slices.items():
        t = tint[mtk[m], cols_z[None, :].repeat(H, 0), cols_x[None, :].repeat(H, 0)]
        im = mcol[m] * t
        im[m == 0] = (0.55, 0.7, 0.95)
        flip = lambda a_: a_[::-1]
        save(up(Image.fromarray(np.clip(flip(im) * 255, 0, 255).astype(np.uint8)), 2),
             os.path.join(a.out, f"slice_{name}_materials.png"))
        sky = L[..., 3]
        save(up(Image.fromarray(flip(sky)), 2), os.path.join(a.out, f"slice_{name}_sky.png"))
        blk = L[..., :3].copy()
        # Unlit non-air dark grey so the shapes read; lit cells at their stored colour.
        dark = (m != 0) & (blk.max(-1) == 0)
        blk[dark] = (28, 28, 28)
        save(up(Image.fromarray(flip(blk)), 2), os.path.join(a.out, f"slice_{name}_blocklight.png"))
        sk_img = np.zeros(sk.shape + (3,), np.uint8)
        v = (sk * 17).astype(np.uint8)
        sk_img[..., 0] = v
        sk_img[..., 1] = (255 - v) // 2
        sk_img[..., 2] = 255 - v
        sk_img[m != 0] = (0, 0, 0)
        save(up(Image.fromarray(flip(sk_img)), 2), os.path.join(a.out, f"slice_{name}_skip.png"))

    # Far field.
    FW, FD = meta["far"]["size"]
    fh = far_h[..., 0].astype(np.float64)
    fw = far_h[..., 1]
    g = far_c[0, ..., :3] / 255.0
    wc = far_c[1, ..., :3] / 255.0
    has_w = far_c[1, ..., 3] > 0
    dep = np.clip((fw.astype(np.float64) - fh) / 12.0, 0, 1)
    col = np.where(has_w[..., None], g * (1 - (0.6 + 0.3 * dep[..., None])) + wc * (0.6 + 0.3 * dep[..., None]), g)
    d = np.zeros_like(fh)
    d[1:] = fh[1:] - fh[:-1]
    col = col * np.where(d > 0, 1.0, np.where(d < 0, 0.75, 0.88))[..., None]
    col[far_c[0, ..., 3] == 0] = (0.15, 0.0, 0.15)
    fim = Image.fromarray(np.clip(col * 255, 0, 255).astype(np.uint8))
    dr = ImageDraw.Draw(fim)
    ox, oz = meta["origin"][0] - meta["far"]["origin"][0], meta["origin"][2] - meta["far"]["origin"][1]
    dr.rectangle([ox, oz, ox + W - 1, oz + D - 1], outline=(255, 40, 40))
    save(fim, os.path.join(a.out, "far.png"))

    # Routes and points of interest.
    k = 2
    ov = up(mp, k).convert("RGB")
    dr = ImageDraw.Draw(ov)
    palette = [(255, 60, 60), (60, 220, 255), (255, 220, 40), (200, 80, 255), (80, 255, 120), (255, 140, 0)]
    for li, (first, count, kind, _) in enumerate(loops):
        P = pts[first:first + count]
        xy = [(int(p[0]) * k + k // 2, int(p[2]) * k + k // 2) for p in P] + [(int(P[0][0]) * k + k // 2, int(P[0][2]) * k + k // 2)]
        dr.line(xy, fill=palette[li % len(palette)], width=2)
        for p in P:
            if p[3] & 4:
                dr.rectangle([p[0] * k - 1, p[2] * k - 1, p[0] * k + 2, p[2] * k + 2], fill=(255, 255, 255))
    kc = {"cluster": (255, 0, 255), "structure": (255, 128, 0), "bell": (255, 255, 0), "hilltop": (0, 255, 0),
          "shore": (0, 160, 255), "lit": (255, 255, 255)}
    for i, p in enumerate(meta["poi"]):
        x, y, z = p["pos"]
        r = p["radius"]
        if p["kind"] in ("structure", "cluster", "bell"):
            (x0, _, z0), (x1, _, z1) = p["box"]
            dr.rectangle([x0 * k, z0 * k, x1 * k - 1, z1 * k - 1], outline=kc[p["kind"]], width=1)
            vx, _, vz = p["view"]
            if vx or vz:                      # where the camera goes: an arrow out of the box
                cx_, cz_ = (x0 + x1) / 2 * k, (z0 + z1) / 2 * k
                dr.line([cx_, cz_, cx_ + vx * 24 * k, cz_ + vz * 24 * k], fill=(255, 255, 255), width=2)
                dr.ellipse([cx_ + vx * 24 * k - 3, cz_ + vz * 24 * k - 3, cx_ + vx * 24 * k + 3, cz_ + vz * 24 * k + 3],
                           fill=(255, 255, 255))
        else:
            dr.ellipse([(x - r) * k, (z - r) * k, (x + r) * k, (z + r) * k], outline=kc[p["kind"]], width=2)
        dr.text((x * k + 3, z * k + 3), f"{i}:{p['kind']}", fill=kc[p["kind"]])
    save(ov, os.path.join(a.out, "overlay.png"))

    # Contract checks on the routes.
    for first, count, kind, _ in loops:
        P = pts[first:first + count].astype(np.int64)
        Q = np.roll(P, -1, axis=0)
        step = np.abs(P[:, 0] - Q[:, 0]) + np.abs(P[:, 2] - Q[:, 2])
        assert (step == 1).all() and (np.abs(P[:, 1] - Q[:, 1]) <= 1).all(), "route step breaks the format"
        below = mid[P[:, 2], P[:, 1] - 1, P[:, 0]]
        assert (below != 0).all(), "route point over air"
    print(f"routes: {len(loops)} loops, {len(pts)} points; steps and ground check out")

    # What is in the box, by block name (from materials.json's states), and what the routes reach.
    rows = mats["materials"]
    name_of = {}
    for i, m in enumerate(rows):
        st = m.get("states") or ["?"]
        name_of[m.get("id", i)] = st[0].split("[")[0].split(" ")[0].replace("minecraft:", "")
    counts = np.bincount(mid.reshape(-1))       # not np.unique: numpy 2.0's sort segfaults on this array
    ids = np.arange(len(counts))
    by = {}
    for i_, c_ in zip(ids, counts):
        if i_ and c_:
            n_ = name_of.get(int(i_), "?")
            by[n_] = by.get(n_, 0) + int(c_)
    jobs = ("composter", "lectern", "smithing_table", "fletching_table", "cartography_table", "brewing_stand",
            "barrel", "blast_furnace", "smoker", "loom", "stonecutter", "grindstone", "cauldron", "water_cauldron")
    bed_vox = sum(v for n_, v in by.items() if n_.endswith("_bed"))
    print("contents: bells %d, bed halves %d (%d beds), job sites %s, doors %d, lanterns %d, torches %d, farmland %d, "
          "crops %d, dirt_path %d, hay %d" % (
              by.get("bell", 0), bed_vox, bed_vox // 2, {j: by[j] for j in jobs if j in by},
              sum(v for n_, v in by.items() if n_.endswith("_door") and "trap" not in n_),
              by.get("lantern", 0), by.get("torch", 0) + by.get("wall_torch", 0), by.get("farmland", 0),
              sum(by.get(c_, 0) for c_ in ("wheat", "carrots", "potatoes", "beetroots")), by.get("dirt_path", 0),
              by.get("hay_block", 0)))
    names_arr = np.array([name_of.get(i_, "") for i_ in range(int(mid.max()) + 1)], dtype=object)
    wp = np.array([n_ == "bell" or n_.endswith("_bed") or n_ in jobs for n_ in names_arr])
    targets = np.argwhere(wp[mid])                       # z, y, x of every waypoint voxel
    reached = set()
    P = pts[:, :3].astype(np.int64)
    for z_, y_, x_ in targets:
        d = np.abs(P[:, 0] - x_) + np.abs(P[:, 2] - z_)
        if ((d <= 2) & (np.abs(P[:, 1] - y_) <= 2)).any():      # a ceiling bell hangs 2 above the feet
            reached.add((names_arr[mid[z_, y_, x_]], int(x_), int(z_)))
    kinds_ = {}
    for n_, _, _ in reached:
        k_ = "bell" if n_ == "bell" else "bed half" if n_.endswith("_bed") else "job site"
        kinds_[k_] = kinds_.get(k_, 0) + 1
    print(f"routes pass within 2 blocks of: {kinds_} (of {len(targets)} waypoint voxels)")

    if a.compare_save:
        opq = np.zeros(int(mid.max()) + 1, bool)
        for i, m in enumerate(mats["materials"]):
            if m.get("id", i) < len(opq):
                opq[m.get("id", i)] = bool(m.get("opaque"))
        compare(meta, light, mid, opq, a.compare_save)


def compare(meta, light, mid, opq, save_dir):
    """Opaque voxels are left out: the bake stores 0 there by design (FORMAT.md), where the game
    keeps an opaque emitter's own level (magma, crying obsidian) in its cell."""
    sys.path.insert(0, HERE)
    import anvil
    s = anvil.Save(save_dir)
    W, H, D = meta["size"]
    ox, oy, oz = meta["origin"]
    sky_ok = sky_n = blk_ok = blk_n = 0
    sky_d = blk_d = 0
    sky_near = blk_near = 0
    for cz in range(oz // 16 + 1, (oz + D) // 16 - 1):
        for cx in range(ox // 16 + 1, (ox + W) // 16 - 1):
            ch = s.overworld.read(cx, cz)
            if ch is None or ch.get("Status") != "minecraft:full":
                continue
            for sec in ch["sections"]:
                y0 = sec["Y"] * 16
                if y0 < oy + 16 or y0 + 16 > oy + H - 1:
                    continue
                for key, which in (("SkyLight", "sky"), ("BlockLight", "block")):
                    arr = sec.get(key)
                    if arr is None:
                        continue
                    b = np.asarray(arr).astype(np.uint8)
                    nib = np.stack([b & 15, b >> 4], -1).reshape(16, 16, 16)       # y, z, x
                    lz, lx, ly = cz * 16 - oz, cx * 16 - ox, y0 - oy
                    ours_c = light[lz:lz + 16, ly:ly + 16, lx:lx + 16].transpose(1, 0, 2, 3)
                    vm = mid[lz:lz + 16, ly:ly + 16, lx:lx + 16].transpose(1, 0, 2)
                    solid = vm != 0
                    clear = ~opq[vm]
                    if which == "sky":
                        ours = np.round(ours_c[..., 3] / 17.0).astype(int)
                        m = clear & (~solid | (ours > 0))
                        dd = np.abs(ours - nib)[m]
                        sky_ok += int((dd == 0).sum()); sky_near += int((dd <= 1).sum()); sky_n += dd.size; sky_d += int(dd.sum())
                    else:
                        ours = np.round(ours_c[..., :3].max(-1) / 17.0).astype(int)
                        m = clear & ((nib > 0) | (ours > 0))
                        dd = np.abs(ours - nib)[m]
                        blk_ok += int((dd == 0).sum()); blk_near += int((dd <= 1).sum()); blk_n += dd.size; blk_d += int(dd.sum())
    if sky_n:
        print(f"sky light vs the save: {sky_ok / sky_n:.4f} equal, {sky_near / sky_n:.4f} within 1, mean |diff| {sky_d / sky_n:.4f} over {sky_n} cells")
    if blk_n:
        print(f"block light vs the save (opaque voxels left out): {blk_ok / blk_n:.4f} equal, {blk_near / blk_n:.4f} within 1, mean |diff| {blk_d / blk_n:.4f} over {blk_n} lit cells")


if __name__ == "__main__":
    main()
