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

Inputs: PlayCanvas SOG v2 (what SuperSplat serves; one or more chunks),
standard 3DGS binary .ply, antimatter15 .splat, Niantic .spz. Only SOG keeps
view-dependent colour.

.lsplat is what `SplatData.swift` loads. Header (little endian, 48 bytes):

    char[4]  "LSPL"
    u32      version (1, or 2 with view-dependent colour)
    u32      count
    u32      flags (0)
    f32[3]   bounds min      positions are quantized inside these bounds
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

    u16[count] x, y, z      0..65535 across the bounds
    u8[count]  r, g, b, a   colour from SH band 0, opacity through the sigmoid
    u8[count]  sx, sy, sz   log scale, -10..2 over 0..255
    u8[count]  qw, qx, qy, qz  unit quaternion, -1..1 over 0..255
  version 2 only:
    u8[count]  label bits 0-7, 8-15, 16-23   palette entry per splat
    u8[entries][coeffs][3]                   codebook index per coefficient

The transform in captures.json is applied here, once, so the runtime sees every
capture the same way: y up, the subject at the origin, the subject's radius 1.
The view-dependent colour stays in the capture's own frame; the renderer turns
each view direction back with the stored rotation.
"""
import json
import math
import os
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


def apply_config(splats, cfg):
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

    limit = int(cfg.get("max_splats", 50_000_000))
    if len(pos) > limit:
        importance = alpha * np.exp(log_scale.sum(1) / 3.0)
        idx = np.argsort(-importance)[:limit]
        pos, rgb, alpha, log_scale, quat, labels = pos[idx], rgb[idx], alpha[idx], log_scale[idx], quat[idx], labels[idx]
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


def write_lsplat(path, splats):
    pos, rgb, alpha, log_scale, quat = splats[:5]
    sh = splats[5] if len(splats) > 5 else None
    n = len(pos)
    lo = pos.min(0)
    hi = pos.max(0)
    span = np.maximum(hi - lo, 1e-6)
    qp = np.clip(np.round((pos - lo) / span * 65535), 0, 65535).astype(np.uint16)
    order = morton_order(qp)
    qp = qp[order]
    col = np.clip(np.round(np.concatenate([rgb, alpha[:, None]], 1)[order] * 255), 0, 255).astype(np.uint8)
    sc = np.clip(np.round((log_scale[order] - LOG_MIN) / (LOG_MAX - LOG_MIN) * 255), 0, 255).astype(np.uint8)
    q = quat[order]
    q = q / np.maximum(np.linalg.norm(q, axis=1, keepdims=True), 1e-12)
    q = np.where(q[:, :1] < 0, -q, q)
    qq = np.clip(np.round((q + 1) * 127.5), 0, 255).astype(np.uint8)

    planes = b"".join([qp[:, i].astype("<u2").tobytes() for i in range(3)]
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
    header = struct.pack("<4sIII3f3fII", b"LSPL", version, n, 0, *lo.astype(np.float32), *hi.astype(np.float32),
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


def fetch(cid, cfg, src_dir):
    """The capture's SOG chunks, downloaded once into src_dir/<id>/<n>/.

    Returns the local meta.json paths. SuperSplat serves SOG (a meta.json and
    WebP planes); one level of a streamed level-of-detail scene is several
    such chunks, which read_sog merges.
    """
    import subprocess
    metas = []
    for k, url in enumerate(cfg["sources"]):
        d = os.path.join(src_dir, cid, str(k))
        meta = os.path.join(d, "meta.json")
        done = os.path.join(d, ".complete")
        metas.append(meta)
        if os.path.exists(done):
            continue
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
        open(done, "w").close()
    return metas


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
        n, size = write_lsplat(out, apply_config(read_any(src), cfg))
        print(f"{cid}: {n:,} splats, {size / 1e6:.1f} MB")
    # A capture dropped from captures.json leaves the bundle too.
    for name in os.listdir(out_dir) if os.path.isdir(out_dir) else []:
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


def main():
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
        cfg = configs["captures"][cid]
        src = fetch(cid, cfg, os.path.join(ROOT, "build", "splats-src"))
        out = os.path.join(ROOT, "build", "splats", cid + ".lsplat")
        n, size = write_lsplat(out, apply_config(read_any(src), cfg))
        print(f"{cid}: {n:,} splats, {size / 1e6:.1f} MB -> {out}")
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
