#!/usr/bin/env python3
"""Convert a trained 3D Gaussian splat capture into Lerping's .lsplat format.

    scripts/splat-convert.py all              fetch and convert every capture in
                                              Sources/Splats/captures.json
    scripts/splat-convert.py fetch  ID        download one capture's SOG files
    scripts/splat-convert.py convert ID       convert one capture
    scripts/splat-convert.py inspect FILE|ID [--views OUT_PREFIX] [--config ID]
    scripts/splat-convert.py unlicensed       "<shader> <capture>" for every look
                                              drawing a capture published with
                                              no licence (`make package` drops
                                              them)
    scripts/splat-convert.py photo PLY OUT [--glass near|median|far|METRES]
                                              one Apple SHARP prediction (a
                                              single photo's splats) into the
                                              `splat:window:` frame; prints its
                                              framing as JSON (`make
                                              photo-window` calls this)

Inputs: PlayCanvas SOG v2 (what SuperSplat serves; one or more chunks),
standard 3DGS binary .ply, antimatter15 .splat, Niantic .spz. Only SOG keeps
view-dependent colour.

.lsplat is what `SplatData.swift` loads. Header (little endian, 48 bytes):

    char[4]  "LSPL"
    u32      version (1, or 2 with view-dependent colour)
    u32      count
    u32      flags: bit 0 = positions are f32 (always set now; files without
             it, from before, hold u16 positions quantized inside the bounds)
    f32[3]   bounds min
    f32[3]   bounds max
    u32      payload bytes (compressed)
    u32      extra header bytes that follow (0 for version 1)

version 2's extra header:

    f32[9]   rotation, row-major, that took the capture into this frame
    u32      SH coefficients per channel past band 0 (3, 8 or 15)
    u32      palette entries
    f32[256] codebook for the palette

then a raw-DEFLATE payload (Apple's COMPRESSION_ZLIB) of planes, splat-major
within each plane so neighbours compress together:

    f32[count] x, y, z      exact (flag bit 0) — or u16 0..65535 across the
                            bounds in files written before it. 16 bits across
                            a whole scene's bounds was coarser than the
                            source's own per-chunk precision: up to half a
                            small splat's size on the large scenes.
    u8[count]  r, g, b, a   colour from SH band 0, opacity through the sigmoid
    u8[count]  sx, sy, sz   log scale, -10..2 over 0..255
    u8[count]  qw, qx, qy, qz  unit quaternion, -1..1 over 0..255
  version 2 only:
    u8[count]  label bits 0-7, 8-15, 16-23   palette entry per splat
    u8[entries][coeffs][3]                   codebook index per coefficient

Beside it, for a SuperSplat scene whose author drew a camera path (the
fly-through its viewer plays on opening), `<id>.path.json`: that path's keys,
taken into the same frame as the splats, for `LerpSplatPath` to play.

The transform in captures.json is applied here, once, so the runtime sees every
capture the same way: y up, the subject at the origin, the subject's radius 1.
The view-dependent colour stays in the capture's own frame; the renderer turns
each view direction back with the stored rotation.
"""
import json
import math
import os
import re
import struct
import sys
import zlib
import gzip

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONFIG = os.path.join(ROOT, "Sources", "Splats", "captures.json")
SH_C0 = 0.28209479177387814
LOG_MIN, LOG_MAX = -10.0, 2.0


# ---------------------------------------------------------------- readers ----

def read_ply(path):
    with open(path, "rb") as f:
        header = b""
        while not header.endswith(b"end_header\n"):
            line = f.readline()
            if not line:
                raise ValueError("no end_header")
            header += line
        text = header.decode("ascii", "replace")
        if "binary_little_endian" not in text:
            raise ValueError("only binary_little_endian .ply is supported")
        count = None
        props = []
        in_vertex = False
        types = {"float": "f4", "float32": "f4", "double": "f8", "uchar": "u1", "uint8": "u1",
                 "char": "i1", "int8": "i1", "short": "i2", "int16": "i2", "ushort": "u2",
                 "uint16": "u2", "int": "i4", "int32": "i4", "uint": "u4", "uint32": "u4"}
        for line in text.splitlines():
            parts = line.split()
            if not parts:
                continue
            if parts[0] == "element":
                in_vertex = parts[1] == "vertex"
                if in_vertex:
                    count = int(parts[2])
                elif count is not None and props:
                    # Elements after the vertex block are not read.
                    pass
            elif parts[0] == "property" and in_vertex:
                if parts[1] == "list":
                    raise ValueError("list property in vertex element")
                props.append((parts[2], "<" + types[parts[1]]))
        dtype = np.dtype(props)
        data = np.fromfile(f, dtype=dtype, count=count)
    names = data.dtype.names
    need = ["x", "y", "z", "f_dc_0", "f_dc_1", "f_dc_2", "opacity",
            "scale_0", "scale_1", "scale_2", "rot_0", "rot_1", "rot_2", "rot_3"]
    missing = [n for n in need if n not in names]
    if missing:
        raise ValueError(f"not a 3DGS .ply, missing {missing}; has {names[:20]}")
    pos = np.stack([data["x"], data["y"], data["z"]], 1).astype(np.float64)
    dc = np.stack([data["f_dc_0"], data["f_dc_1"], data["f_dc_2"]], 1).astype(np.float64)
    rgb = 0.5 + SH_C0 * dc
    alpha = 1.0 / (1.0 + np.exp(-data["opacity"].astype(np.float64)))
    log_scale = np.stack([data["scale_0"], data["scale_1"], data["scale_2"]], 1).astype(np.float64)
    quat = np.stack([data["rot_0"], data["rot_1"], data["rot_2"], data["rot_3"]], 1).astype(np.float64)
    return pos, rgb, alpha, log_scale, quat


def read_splat(path):
    raw = np.fromfile(path, dtype=np.uint8)
    n = raw.size // 32
    raw = raw[: n * 32].reshape(n, 32)
    pos = raw[:, 0:12].copy().view("<f4").reshape(n, 3).astype(np.float64)
    scale = raw[:, 12:24].copy().view("<f4").reshape(n, 3).astype(np.float64)
    rgba = raw[:, 24:28].astype(np.float64) / 255.0
    quat = (raw[:, 28:32].astype(np.float64) - 128.0) / 128.0
    return pos, rgba[:, :3], rgba[:, 3], np.log(np.maximum(scale, 1e-12)), quat


def read_spz(path):
    blob = open(path, "rb").read()
    if blob[:2] == b"\x1f\x8b":
        blob = gzip.decompress(blob)
    magic, version, n, sh_degree, frac_bits, flags, _ = struct.unpack_from("<IIIBBBB", blob, 0)
    if magic != 0x5053474E:
        raise ValueError("not an .spz")
    off = 16
    p = np.frombuffer(blob, np.uint8, n * 9, off).reshape(n, 3, 3).astype(np.int32)
    off += n * 9
    fixed = p[:, :, 0] | (p[:, :, 1] << 8) | (p[:, :, 2] << 16)
    fixed = np.where(fixed & 0x800000, fixed - (1 << 24), fixed)
    pos = fixed.astype(np.float64) / (1 << frac_bits)
    alpha = np.frombuffer(blob, np.uint8, n, off).astype(np.float64) / 255.0
    off += n
    col = np.frombuffer(blob, np.uint8, n * 3, off).reshape(n, 3).astype(np.float64)
    off += n * 3
    rgb = 0.5 + ((col / 255.0 - 0.5) / 0.15) * SH_C0
    sc = np.frombuffer(blob, np.uint8, n * 3, off).reshape(n, 3).astype(np.float64)
    off += n * 3
    log_scale = sc / 16.0 - 10.0
    if version >= 3:
        r = np.frombuffer(blob, np.uint8, n * 4, off).reshape(n, 4).astype(np.uint32)
        off += n * 4
        packed = r[:, 0] | (r[:, 1] << 8) | (r[:, 2] << 16) | (r[:, 3] << 24)
        largest = packed >> 30
        quat = np.zeros((n, 4))
        mask = (1 << 9) - 1
        rem = packed.copy()
        sum_sq = np.zeros(n)
        comps = np.zeros((n, 4))
        for i in range(3, -1, -1):
            is_largest = largest == i
            mag = (rem & mask).astype(np.float64)
            neg = (rem >> 9) & 1
            val = (math.sqrt(0.5) * mag / mask) * np.where(neg == 1, -1.0, 1.0)
            comps[:, i] = np.where(is_largest, 0.0, val)
            rem = np.where(is_largest, rem, rem >> 10)
        sum_sq = (comps ** 2).sum(1)
        for i in range(4):
            comps[:, i] = np.where(largest == i, np.sqrt(np.maximum(0.0, 1.0 - sum_sq)), comps[:, i])
        # spz stores x, y, z, w
        quat = np.stack([comps[:, 3], comps[:, 0], comps[:, 1], comps[:, 2]], 1)
    else:
        r = np.frombuffer(blob, np.uint8, n * 3, off).reshape(n, 3).astype(np.float64)
        off += n * 3
        xyz = r / 127.5 - 1.0
        w = np.sqrt(np.maximum(0.0, 1.0 - (xyz ** 2).sum(1)))
        quat = np.stack([w, xyz[:, 0], xyz[:, 1], xyz[:, 2]], 1)
    return pos, rgb, alpha, log_scale, quat


SH_COEFFS = {0: 0, 1: 3, 2: 8, 3: 15}


def read_sog(meta_paths):
    """PlayCanvas SOG v2 (meta.json + WebP planes), one or more chunks merged.

    Mirrors splat-transform's reader (src/lib/readers/read-sog.ts). Unlike
    the .ply path it keeps the higher spherical-harmonic bands, as they are
    stored: a palette of centroids plus a 16-bit label per splat. Each chunk's
    palette is kept whole and the labels are offset into the merged palette.
    """
    from PIL import Image

    def rgba(path):
        im = Image.open(path).convert("RGBA")
        return np.asarray(im, dtype=np.uint8).reshape(-1, 4)

    parts = []
    palettes = []
    offset = 0
    coeffs = None
    for mp in meta_paths:
        d = os.path.dirname(mp)
        m = json.load(open(mp))
        if m.get("version") != 2:
            raise ValueError(f"{mp}: only SOG v2 is supported")
        n = m["count"]
        lo = rgba(os.path.join(d, m["means"]["files"][0]))[:n].astype(np.uint32)
        hi = rgba(os.path.join(d, m["means"]["files"][1]))[:n].astype(np.uint32)
        v = (lo[:, :3] | (hi[:, :3] << 8)).astype(np.float64) / 65535
        mins, maxs = np.array(m["means"]["mins"]), np.array(m["means"]["maxs"])
        t = mins + (maxs - mins) * v
        pos = np.sign(t) * (np.exp(np.abs(t)) - 1)

        q = rgba(os.path.join(d, m["quats"]["files"][0]))[:n].astype(np.float64)
        tag = q[:, 3].astype(np.int64) - 252
        abc = (q[:, :3] / 255 * 2 - 1) / math.sqrt(2)
        quat = np.zeros((n, 4))
        order = np.array([[1, 2, 3], [0, 2, 3], [0, 1, 3], [0, 1, 2]])
        valid = (tag >= 0) & (tag <= 3)
        tagc = np.clip(tag, 0, 3)
        rows = np.arange(n)
        for j in range(3):
            quat[rows, order[tagc, j]] = abc[:, j]
        quat[rows, tagc] = np.sqrt(np.maximum(0, 1 - (abc ** 2).sum(1)))
        quat[~valid] = [1, 0, 0, 0]

        sc = rgba(os.path.join(d, m["scales"]["files"][0]))[:n]
        log_scale = np.array(m["scales"]["codebook"])[sc[:, :3]]
        c0 = rgba(os.path.join(d, m["sh0"]["files"][0]))[:n]
        dc = np.array(m["sh0"]["codebook"])[c0[:, :3]]
        rgb = 0.5 + SH_C0 * dc
        alpha = c0[:, 3].astype(np.float64) / 255

        shn = m.get("shN")
        if shn and SH_COEFFS.get(shn["bands"], 0) > 0:
            c = SH_COEFFS[shn["bands"]]
            if coeffs is not None and coeffs != c:
                raise ValueError("chunks disagree on SH bands")
            coeffs = c
            cen = rgba(os.path.join(d, shn["files"][0]))
            width = 64 * c
            book = np.array(shn["codebook"])
            count = shn["count"]
            # palette[entry, coeff, channel]
            ent = np.arange(count)
            cols = (ent % 64)[:, None] * c + np.arange(c)[None, :]
            idx = (ent // 64)[:, None] * width + cols
            idx = np.minimum(idx, len(cen) - 1)
            palettes.append(book[cen[idx][:, :, :3]].astype(np.float32))
            lab = rgba(os.path.join(d, shn["files"][1]))[:n].astype(np.int64)
            labels = (lab[:, 0] | (lab[:, 1] << 8)) + offset
            offset += count
        else:
            # A chunk with no view-dependent colour (some level-of-detail
            # chunks are saved without): points at an all-zero entry below.
            labels = np.full(n, -1, dtype=np.int64)
        parts.append((pos, rgb, alpha, log_scale, quat, labels))

    cat = lambda k: np.concatenate([p[k] for p in parts])
    splats = [cat(0), cat(1), cat(2), cat(3), cat(4)]
    if coeffs:
        palette = np.concatenate(palettes + [np.zeros((1, coeffs, 3), np.float32)])
        labels = cat(5)
        labels[labels < 0] = len(palette) - 1
        splats.append({"labels": labels, "palette": palette, "coeffs": coeffs})
    return splats


def read_any(path):
    if isinstance(path, list):
        return read_sog(path)
    ext = os.path.splitext(path)[1].lower()
    if ext == ".ply":
        return read_ply(path)
    if ext == ".splat":
        return read_splat(path)
    if ext == ".spz":
        return read_spz(path)
    raise ValueError(f"unsupported input {ext}")


# ------------------------------------------------------------- transforms ----

def euler_matrix(deg):
    rx, ry, rz = [math.radians(a) for a in deg]
    cx, sx, cy, sy, cz, sz = math.cos(rx), math.sin(rx), math.cos(ry), math.sin(ry), math.cos(rz), math.sin(rz)
    X = np.array([[1, 0, 0], [0, cx, -sx], [0, sx, cx]])
    Y = np.array([[cy, 0, sy], [0, 1, 0], [-sy, 0, cy]])
    Z = np.array([[cz, -sz, 0], [sz, cz, 0], [0, 0, 1]])
    return Z @ Y @ X


def matrix_to_quat(m):
    t = np.trace(m)
    if t > 0:
        s = math.sqrt(t + 1.0) * 2
        return np.array([0.25 * s, (m[2, 1] - m[1, 2]) / s, (m[0, 2] - m[2, 0]) / s, (m[1, 0] - m[0, 1]) / s])
    i = int(np.argmax(np.diag(m)))
    if i == 0:
        s = math.sqrt(1.0 + m[0, 0] - m[1, 1] - m[2, 2]) * 2
        return np.array([(m[2, 1] - m[1, 2]) / s, 0.25 * s, (m[0, 1] + m[1, 0]) / s, (m[0, 2] + m[2, 0]) / s])
    if i == 1:
        s = math.sqrt(1.0 + m[1, 1] - m[0, 0] - m[2, 2]) * 2
        return np.array([(m[0, 2] - m[2, 0]) / s, (m[0, 1] + m[1, 0]) / s, 0.25 * s, (m[1, 2] + m[2, 1]) / s])
    s = math.sqrt(1.0 + m[2, 2] - m[0, 0] - m[1, 1]) * 2
    return np.array([(m[1, 0] - m[0, 1]) / s, (m[0, 2] + m[2, 0]) / s, (m[1, 2] + m[2, 1]) / s, 0.25 * s])


def quat_mul(a, b):
    aw, ax, ay, az = a
    bw, bx, by, bz = b[:, 0], b[:, 1], b[:, 2], b[:, 3]
    return np.stack([aw * bw - ax * bx - ay * by - az * bz,
                     aw * bx + ax * bw + ay * bz - az * by,
                     aw * by - ax * bz + ay * bw + az * bx,
                     aw * bz + ax * by - ay * bx + az * bw], 1)


def apply_config(splats, cfg, frame=None):
    """The capture in Lerping's frame. `frame`, if given, is filled with the
    affine that took it there (pos' = m @ (pos - center) * k + shift), so a
    camera path published beside the capture can be taken there too."""
    pos, rgb, alpha, log_scale, quat = splats[:5]
    sh = dict(splats[5]) if len(splats) > 5 else None
    labels = sh["labels"] if sh else np.zeros(len(pos), dtype=np.int64)
    ok = np.isfinite(pos).all(1) & np.isfinite(log_scale).all(1) & np.isfinite(quat).all(1) & np.isfinite(alpha)
    pos, rgb, alpha, log_scale, quat, labels = pos[ok], rgb[ok], alpha[ok], log_scale[ok], quat[ok], labels[ok]
    quat = quat / np.maximum(np.linalg.norm(quat, axis=1, keepdims=True), 1e-12)
    # Source-space subject centre, then rotation, then uniform scale.
    center = np.array(cfg.get("center", [0, 0, 0]), dtype=np.float64)
    m = euler_matrix(cfg.get("rotate", [0, 0, 0]))
    if cfg.get("flip_y_z"):
        m = m @ np.array([[1, 0, 0], [0, 0, 1], [0, -1, 0]])
    k = float(cfg.get("scale", 1.0))
    pos = ((pos - center) @ m.T) * k + np.array(cfg.get("shift", [0, 0, 0]), dtype=np.float64)
    quat = quat_mul(matrix_to_quat(m), quat)
    log_scale = log_scale + math.log(k)

    keep = alpha >= float(cfg.get("min_alpha", 0.02))
    crop = cfg.get("crop")
    if crop:
        if "sphere" in crop:
            keep &= np.linalg.norm(pos, axis=1) <= float(crop["sphere"])
        if "box" in crop:
            lo, hi = np.array(crop["box"][0]), np.array(crop["box"][1])
            keep &= np.all((pos >= lo) & (pos <= hi), axis=1)
        if "cylinder" in crop:
            r, y0, y1 = crop["cylinder"]
            keep &= (np.hypot(pos[:, 0], pos[:, 2]) <= r) & (pos[:, 1] >= y0) & (pos[:, 1] <= y1)
    # Splats far bigger than the subject are background haze from training.
    keep &= log_scale.max(1) <= float(cfg.get("max_log_scale", 1.5))
    pos, rgb, alpha, log_scale, quat, labels = pos[keep], rgb[keep], alpha[keep], log_scale[keep], quat[keep], labels[keep]

    if cfg.get("center_xz"):
        # Put the middle of the solid part of the capture on the turntable axis.
        solid = alpha > 0.3
        lo = np.percentile(pos[solid][:, [0, 2]], 2, 0)
        hi = np.percentile(pos[solid][:, [0, 2]], 98, 0)
        mid = (lo + hi) / 2
        pos[:, 0] -= mid[0]
        pos[:, 2] -= mid[1]
    if frame is not None:
        offset = np.array(cfg.get("shift", [0, 0, 0]), dtype=np.float64)
        if cfg.get("center_xz"):
            offset = offset - np.array([mid[0], 0, mid[1]])
        frame.update(m=m, center=center, k=k, shift=offset)

    if sh is None:
        return pos, rgb, alpha, log_scale, quat
    # The SH stay in the capture's own frame; the renderer turns each view
    # direction back into that frame with this rotation's transpose.
    sh["labels"] = labels
    sh["rotation"] = m
    return pos, rgb, alpha, log_scale, quat, sh


# ----------------------------------------------------------------- writer ----

def morton_order(q):
    def spread(v):
        v = v.astype(np.uint64) & 0x3FF
        v = (v | (v << 16)) & 0x30000FF
        v = (v | (v << 8)) & 0x300F00F
        v = (v | (v << 4)) & 0x30C30C3
        v = (v | (v << 2)) & 0x9249249
        return v
    code = spread(q[:, 0] >> 6) | (spread(q[:, 1] >> 6) << 1) | (spread(q[:, 2] >> 6) << 2)
    return np.argsort(code, kind="stable")


FLAG_FLOAT_POSITIONS = 1


def write_lsplat(path, splats):
    pos, rgb, alpha, log_scale, quat = splats[:5]
    sh = splats[5] if len(splats) > 5 else None
    n = len(pos)
    lo = pos.min(0)
    hi = pos.max(0)
    span = np.maximum(hi - lo, 1e-6)
    qp = np.clip(np.round((pos - lo) / span * 65535), 0, 65535).astype(np.uint16)
    order = morton_order(qp)          # the 16-bit grid only orders; positions stay exact
    fp = pos[order].astype("<f4")
    col = np.clip(np.round(np.concatenate([rgb, alpha[:, None]], 1)[order] * 255), 0, 255).astype(np.uint8)
    sc = np.clip(np.round((log_scale[order] - LOG_MIN) / (LOG_MAX - LOG_MIN) * 255), 0, 255).astype(np.uint8)
    q = quat[order]
    q = q / np.maximum(np.linalg.norm(q, axis=1, keepdims=True), 1e-12)
    q = np.where(q[:, :1] < 0, -q, q)
    qq = np.clip(np.round((q + 1) * 127.5), 0, 255).astype(np.uint8)

    planes = b"".join([fp[:, i].tobytes() for i in range(3)]
                      + [col[:, i].tobytes() for i in range(4)]
                      + [sc[:, i].tobytes() for i in range(3)]
                      + [qq[:, i].tobytes() for i in range(4)])
    extra = b""
    version = 1
    if sh is not None:
        # Only the palette entries still referenced after cropping, renumbered.
        used, labels = np.unique(sh["labels"][order], return_inverse=True)
        palette = sh["palette"][used]                      # [entry, coeff, channel]
        c = sh["coeffs"]
        # One shared 256-level codebook for every coefficient: quantiles of
        # the values, so the levels sit where the values are.
        vals = palette.reshape(-1)
        book = np.quantile(vals, np.linspace(0, 1, 256)).astype(np.float32)
        book = np.unique(book)
        book = np.concatenate([book, np.full(256 - len(book), book[-1], np.float32)])
        mids = (book[1:] + book[:-1]) / 2
        pidx = np.searchsorted(mids, vals).astype(np.uint8).reshape(palette.shape)
        lab = labels.astype(np.uint32)
        planes += b"".join([(lab & 0xFF).astype(np.uint8).tobytes(),
                            ((lab >> 8) & 0xFF).astype(np.uint8).tobytes(),
                            ((lab >> 16) & 0xFF).astype(np.uint8).tobytes(),
                            pidx.tobytes()])
        extra = struct.pack("<9fII", *np.asarray(sh["rotation"], dtype=np.float32).reshape(-1), c, len(used))
        extra += book.astype("<f4").tobytes()
        version = 2
    comp = zlib.compressobj(9, zlib.DEFLATED, -15)
    payload = comp.compress(planes) + comp.flush()
    header = struct.pack("<4sIII3f3fII", b"LSPL", version, n, FLAG_FLOAT_POSITIONS, *lo.astype(np.float32), *hi.astype(np.float32),
                         len(payload), len(extra))
    header += extra
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path + ".tmp", "wb") as f:
        f.write(header)
        f.write(payload)
    os.replace(path + ".tmp", path)
    return n, len(header) + len(payload)


# ---------------------------------------------------------------- inspect ----

def render_views(prefix, splats, extent=None):
    from PIL import Image
    pos, rgb, alpha, log_scale, quat = splats[:5]
    if extent is None:
        lo, hi = np.percentile(pos, 1, 0), np.percentile(pos, 99, 0)
    else:
        lo, hi = np.full(3, -extent), np.full(3, extent)
    size = 700
    views = {"front_xy": (0, 1, 2, False), "top_xz": (0, 2, 1, True), "side_zy": (2, 1, 0, False)}
    for name, (a, b, depth_axis, top) in views.items():
        img = np.zeros((size, size, 3))
        wsum = np.zeros((size, size))
        span = max(hi[a] - lo[a], hi[b] - lo[b])
        u = ((pos[:, a] - lo[a]) / span * (size - 1)).astype(int)
        v = ((pos[:, b] - lo[b]) / span * (size - 1)).astype(int)
        v = v if top else (size - 1 - v)
        ok = (u >= 0) & (u < size) & (v >= 0) & (v < size)
        # Paint far to near so nearer splats win (depth = +axis toward viewer).
        order = np.argsort(pos[ok, depth_axis])
        uu, vv, cc, aa = u[ok][order], v[ok][order], np.clip(rgb[ok][order], 0, 1), alpha[ok][order]
        img[vv, uu] = cc
        wsum[vv, uu] = 1
        Image.fromarray((img * 255).astype(np.uint8)).save(f"{prefix}_{name}.png")
        print(f"wrote {prefix}_{name}.png  (axes {'xyz'[a]} right, {'xyz'[b]} {'down' if top else 'up'})")


def inspect(path, prefix=None, cfg=None):
    splats = read_any(path)
    if cfg:
        splats = apply_config(splats, cfg)
    pos, rgb, alpha, log_scale, quat = splats[:5]
    print(f"{path}: {len(pos):,} splats")
    for p in (1, 5, 50, 95, 99):
        print(f"  p{p:<2} pos {np.percentile(pos, p, 0).round(3)}")
    print(f"  mean alpha {alpha.mean():.3f}, median scale {np.exp(np.median(log_scale, 0)).round(4)}")
    if prefix:
        render_views(prefix, splats, cfg.get("view_extent") if cfg else None)


def check_full_quality(cid, cfg):
    """Refuses a capture configured below the quality it was published at.

    Two settings once thinned captures without anyone being told: a
    `max_splats` cap that kept the largest splats (so the fine detail went
    first), and sources pointing at a coarser level of a streamed
    level-of-detail scene (`v1/<level>_<chunk>/meta.json` with level > 0).
    Both now stop the build instead.
    """
    if "max_splats" in cfg:
        raise SystemExit(f"{cid}: max_splats is not supported; every capture is used whole")
    for url in cfg["sources"]:
        m = re.search(r"/v1/(\d+)_\d+/meta\.json$", url)
        if m and int(m.group(1)) != 0:
            raise SystemExit(f"{cid}: {url} is level-of-detail level {m.group(1)}; "
                             "use level 0, the full capture (see its lod-meta.json)")


def fetch(cid, cfg, src_dir):
    """The capture's SOG chunks, downloaded once into src_dir/<id>/<n>/.

    Returns the local meta.json paths. SuperSplat serves SOG (a meta.json and
    WebP planes); one level of a streamed level-of-detail scene is several
    such chunks, which read_sog merges.
    """
    import subprocess
    check_full_quality(cid, cfg)
    metas = []
    for k, url in enumerate(cfg["sources"]):
        d = os.path.join(src_dir, cid, str(k))
        meta = os.path.join(d, "meta.json")
        done = os.path.join(d, ".complete")
        source = os.path.join(d, ".source")
        metas.append(meta)
        # The cache is kept per chunk index, so it has to know which URL it
        # holds: changing a capture's sources (to a finer level, say) once
        # reused the old chunks under the new list without a word, and
        # merged two levels into one capture. A chunk cached before this was
        # recorded is checked against the server's meta.json once.
        if os.path.exists(done):
            if os.path.exists(source) and open(source).read() == url:
                continue
            if not os.path.exists(source):
                remote = subprocess.run(["curl", "-fsSL", "--retry", "3", url], capture_output=True, check=True).stdout
                if open(meta, "rb").read() == remote:
                    open(source, "w").write(url)
                    continue
            print(f"{cid}: chunk {k + 1} was cached from another source; fetching {url}")
            os.remove(done)
        os.makedirs(d, exist_ok=True)
        base = url.rsplit("/", 1)[0]
        subprocess.run(["curl", "-fsSL", "--retry", "3", "-o", meta, url], check=True)
        m = json.load(open(meta))
        files = [f for key in ("means", "scales", "quats", "sh0", "shN") if key in m for f in m[key]["files"]]
        args = ["curl", "-fsSL", "--retry", "3", "-Z"]
        for f in files:
            args += ["-o", os.path.join(d, f), base + "/" + f]
        print(f"{cid}: chunk {k + 1}/{len(cfg['sources'])}, {len(files)} files")
        subprocess.run(args, check=True)
        open(source, "w").write(url)
        open(done, "w").close()
    return metas


def fetch_settings(cid, cfg, src_dir):
    """The scene's settings.json from SuperSplat (its camera path, if the
    author drew one), or None for a capture published without one."""
    import subprocess
    if not cfg.get("sources") or "cloudfront" not in cfg["sources"][0]:
        return None
    path = os.path.join(src_dir, cid, "settings.json")
    if not os.path.exists(path):
        url = cfg["sources"][0].rsplit("/", 1)[0] + "/settings.json"
        code = subprocess.run(["curl", "-sSL", "--retry", "3", "-o", path + ".part", "-w", "%{http_code}", url],
                              check=True, capture_output=True, text=True).stdout
        if code == "200":
            os.replace(path + ".part", path)
        elif code in ("403", "404"):
            os.remove(path + ".part")
            with open(path, "w") as f:
                f.write("{}")   # none published; don't ask again
        else:
            raise RuntimeError(f"{cid}: settings.json answered HTTP {code}")
    return json.load(open(path))


def write_path(out, settings, frame):
    """The author's camera path (SuperSplat's first animTrack), taken into the
    capture's Lerping frame, as `SplatData`'s `splat:path:` move plays it.

    SuperSplat's viewer turns every splat 180° about z before placing its
    cameras, so a camera point goes back through that turn, then through the
    same affine as the splats. Its "up" is the viewer's +y, taken the same
    way. Removes `out` when the scene has no path."""
    tracks = (settings or {}).get("animTracks") or []
    track = next((t for t in tracks if len(t.get("keyframes", {}).get("times", [])) >= 2), None)
    if track is None:
        if os.path.exists(out):
            os.remove(out)
        return False
    m, center, k, shift = frame["m"], frame["center"], frame["k"], frame["shift"]
    viewer = np.diag([-1.0, -1.0, 1.0])     # Rz(180°), its own inverse

    def place(flat):
        p = np.asarray(flat, dtype=np.float64).reshape(-1, 3) @ viewer.T
        return (((p - center) @ m.T) * k + shift).round(6).tolist()

    up = m @ viewer @ np.array([0.0, 1.0, 0.0])
    values = track["keyframes"]["values"]
    n = len(track["keyframes"]["times"])
    path = {
        "duration": float(track["duration"]),
        "frameRate": float(track.get("frameRate", 30)),
        "loopMode": track.get("loopMode", "repeat"),
        "smoothness": float(track.get("smoothness", 1)) if track.get("interpolation", "spline") == "spline" else 0.0,
        "up": (up / np.linalg.norm(up)).round(6).tolist(),
        "times": [float(t) for t in track["keyframes"]["times"]],
        "position": place(values["position"]),
        "target": place(values["target"]),
        "fov": [float(f) for f in values.get("fov", [60] * n)],
    }
    with open(out, "w") as f:
        json.dump(path, f, separators=(",", ":"))
    return True


def convert(cid, cfg, src_dir, out_dir):
    src = fetch(cid, cfg, src_dir)
    settings = fetch_settings(cid, cfg, src_dir)
    frame = {}
    n, size = write_lsplat(os.path.join(out_dir, cid + ".lsplat"), apply_config(read_any(src), cfg, frame))
    pathed = write_path(os.path.join(out_dir, cid + ".path.json"), settings, frame)
    print(f"{cid}: {n:,} splats, {size / 1e6:.1f} MB" + (", with its camera path" if pathed else ""))


def source_mtime(src):
    paths = src if isinstance(src, list) else [src]
    return max(os.path.getmtime(p) for p in paths)


def convert_all(configs):
    src_dir = os.path.join(ROOT, "build", "splats-src")
    out_dir = os.path.join(ROOT, "build", "splats")
    newest_input = max(os.path.getmtime(CONFIG), os.path.getmtime(os.path.abspath(__file__)))
    wanted = set()
    for cid, cfg in configs["captures"].items():
        wanted.add(cid + ".lsplat")
        src = fetch(cid, cfg, src_dir)
        out = os.path.join(out_dir, cid + ".lsplat")
        if os.path.exists(out) and os.path.getmtime(out) >= max(newest_input, source_mtime(src)):
            continue
        convert(cid, cfg, src_dir, out_dir)
    # A capture dropped from captures.json leaves the bundle too.
    for name in os.listdir(out_dir) if os.path.isdir(out_dir) else []:
        if name.endswith(".path.json") and name[:-len(".path.json")] + ".lsplat" not in wanted:
            os.remove(os.path.join(out_dir, name))
        if name.endswith(".lsplat") and name not in wanted:
            os.remove(os.path.join(out_dir, name))


def unlicensed(configs):
    """Looks whose capture was published with no licence ("license": "none").

    Those captures are fetched for this machine's own saver, which is what the
    viewer on SuperSplat streams anyway, but they are not ours to pass on: a
    distributed package leaves them, and the looks drawing them, out.
    """
    ids = {cid for cid, cfg in configs["captures"].items() if cfg.get("license", "none") == "none"}
    shaders = os.path.join(ROOT, "Sources", "Shaders")
    for name in sorted(os.listdir(shaders)):
        if not name.endswith(".metal"):
            continue
        for line in open(os.path.join(shaders, name), encoding="utf-8").read().splitlines()[:40]:
            body = line.strip().lstrip("/").strip()
            if body.startswith("lerp-data:"):
                spec = body[len("lerp-data:"):].strip().split(":")
                if len(spec) >= 3 and spec[0] == "splat" and spec[2] in ids:
                    print(name[:-len(".metal")], spec[2])
                break


# ------------------------------------------------------------ photo window ----

def read_ply_extras(path):
    """The small elements a .ply carries after its vertex block, by name, as
    flat arrays. Apple's SHARP writes the photo's camera there: `intrinsic`
    (3×3, row-major, pixels), `image_size` (width, height), `disparity` (its
    10th and 90th percentiles) and `color_space`."""
    types = {"float": "f4", "float32": "f4", "double": "f8", "uchar": "u1", "uint8": "u1",
             "char": "i1", "int8": "i1", "short": "i2", "int16": "i2", "ushort": "u2",
             "uint16": "u2", "int": "i4", "int32": "i4", "uint": "u4", "uint32": "u4"}
    elements = []
    with open(path, "rb") as f:
        while True:
            line = f.readline()
            if not line:
                raise ValueError("no end_header")
            parts = line.decode("ascii", "replace").split()
            if parts and parts[0] == "element":
                elements.append((parts[1], int(parts[2]), []))
            elif parts and parts[0] == "property" and elements:
                if parts[1] == "list":
                    raise ValueError(f"list property in {elements[-1][0]}")
                elements[-1][2].append((parts[2], "<" + types[parts[1]]))
            elif parts == ["end_header"]:
                break
        out = {}
        for name, count, props in elements:
            dtype = np.dtype(props)
            data = np.fromfile(f, dtype=dtype, count=count)
            if name != "vertex" and len(props) == 1:
                out[name] = data[props[0][0]].astype(np.float64)
    return out


def photo(ply, out, glass="median"):
    """A SHARP prediction in the frame the `window` camera (SplatData.swift)
    expects, written whole, and that frame's numbers for the look's header.

    SHARP predicts in OpenCV camera axes — x right, y down, z forward, the
    photo's camera at the origin — in metres. Here it is turned 180° about x
    (y up, looking down -z, as every capture is) and scaled so that the
    *glass*, a plane through the scene at one chosen depth, sits on z = 0
    with the photo spanning y = ±1 across it. The photo's camera is then at
    z = 1/tan(fovy/2), which is exactly where the window camera stands, so a
    centred viewer sees the photo as it was taken: the glass's points stay
    put as the head moves, nearer ones swing against it, farther ones follow.

    `glass` picks that depth: "median" (the default: the median disparity of
    the solid splats, which keeps the most of the scene near the glass and so
    the least void showing at the frame's edges as the head moves), "near" or
    "far" (the 90th / 10th percentile of disparity, so most of the scene sits
    behind / in front of the glass), or a distance in metres.

    Nothing is thinned. The only splats left out are those whose opacity
    rounds to 0 in the file's 8 bits and so could never be drawn; the usual
    haze cull (`max_log_scale`) is off, since a photo's far background is
    meant to be large.
    """
    extras = read_ply_extras(ply)
    splats = read_ply(ply)
    pos, alpha = splats[0], splats[2]
    if "intrinsic" not in extras or "image_size" not in extras:
        raise SystemExit(f"{ply}: no intrinsic/image_size elements; is this a SHARP prediction?")
    K = extras["intrinsic"].reshape(3, 3)
    width, height = (float(v) for v in extras["image_size"][:2])
    fy = float(K[1, 1])
    fovy = 2 * math.atan(0.5 * height / fy)
    aspect = width / height

    ahead = pos[:, 2] > 1e-6
    solid = ahead & (alpha > 0.5)
    disparity = 1.0 / pos[solid if solid.any() else ahead, 2]
    if glass == "median":
        depth = 1.0 / float(np.median(disparity))
    elif glass == "near":
        depth = 1.0 / float(np.percentile(disparity, 90))
    elif glass == "far":
        depth = 1.0 / float(np.percentile(disparity, 10))
    else:
        depth = float(glass)
        if not depth > 0:
            raise SystemExit(f"--glass {glass}: want near, median, far or a distance in metres")

    t = math.tan(fovy / 2)
    k = 1.0 / (depth * t)
    eye = 1.0 / t
    cfg = {
        "sources": [ply],
        "rotate": [180, 0, 0],
        "scale": k,
        "shift": [0, 0, eye],
        # Only what 8-bit opacity would store as 0.
        "min_alpha": 0.5 / 255,
        "max_log_scale": float("inf"),
    }
    check_full_quality(os.path.basename(out), cfg)
    placed = apply_config(splats, cfg)
    log_scale = placed[3]
    clamped = int(((log_scale > LOG_MAX) | (log_scale < LOG_MIN)).any(1).sum())
    n, size = write_lsplat(out, placed)
    info = {
        "count": n,
        "source_count": int(len(pos)),
        "dropped_invisible": int(len(pos) - n),
        "bytes": size,
        "fovy_degrees": round(math.degrees(fovy), 4),
        "aspect": round(aspect, 5),
        "image_size": [int(width), int(height)],
        "focal_px": round(fy, 3),
        "glass": glass,
        "glass_metres": round(depth, 4),
        "scale": k,
        "eye_z": eye,
        "scale_clamped": clamped,
    }
    print(json.dumps(info))
    print(f"{os.path.basename(out)}: {n:,} of {len(pos):,} splats (dropped {len(pos) - n:,} with "
          f"opacity 0), {size / 1e6:.1f} MB, fovy {info['fovy_degrees']}°, glass at {depth:.3f} m",
          file=sys.stderr)
    if clamped:
        print(f"warning: {clamped:,} splats have a scale outside the format's e^{LOG_MIN:g}..e^{LOG_MAX:g} "
              "and are stored clamped to it", file=sys.stderr)


def main():
    if len(sys.argv) >= 4 and sys.argv[1] == "photo":
        args = sys.argv[4:]
        glass = args[args.index("--glass") + 1] if "--glass" in args else "median"
        photo(sys.argv[2], sys.argv[3], glass)
        return
    if len(sys.argv) == 2 and sys.argv[1] == "unlicensed":
        unlicensed(json.load(open(CONFIG)))
        return
    if len(sys.argv) < 2 or (len(sys.argv) < 3 and sys.argv[1] != "all"):
        print(__doc__)
        sys.exit(2)
    cmd = sys.argv[1]
    configs = json.load(open(CONFIG)) if os.path.exists(CONFIG) else {}
    if cmd == "fetch":
        cid = sys.argv[2]
        fetch(cid, configs["captures"][cid], os.path.join(ROOT, "build", "splats-src"))
    elif cmd == "all":
        convert_all(configs)
    elif cmd == "convert":
        cid = sys.argv[2]
        convert(cid, configs["captures"][cid], os.path.join(ROOT, "build", "splats-src"),
                os.path.join(ROOT, "build", "splats"))
    elif cmd == "inspect":
        path = sys.argv[2]
        prefix = None
        cfg = None
        if path in configs.get("captures", {}):
            cfg = configs["captures"][path]
            path = fetch(path, cfg, os.path.join(ROOT, "build", "splats-src"))
        args = sys.argv[3:]
        if "--views" in args:
            prefix = args[args.index("--views") + 1]
        if "--config" in args:
            cfg = configs["captures"][args[args.index("--config") + 1]]
        inspect(path, prefix, cfg)
    else:
        print(__doc__)
        sys.exit(2)


if __name__ == "__main__":
    main()
