#!/usr/bin/env python3
"""Convert a trained 3D Gaussian splat capture into Lerping's .lsplat format.

    scripts/splat-convert.py convert  CAPTURE_ID   (reads Sources/Splats/captures.json)
    scripts/splat-convert.py inspect  FILE [--views OUT_PREFIX] [--config CAPTURE_ID]

Input formats: standard 3DGS binary .ply (x y z f_dc_* opacity scale_* rot_*),
antimatter15 .splat (32 bytes a splat), and Niantic .spz (v2/v3).

.lsplat is what `SplatData.swift` loads. Header (little endian, 48 bytes):

    char[4]  "LSPL"
    u32      version (1)
    u32      count
    u32      flags (0)
    f32[3]   bounds min      positions are quantized inside these bounds
    f32[3]   bounds max
    u32      payload bytes (compressed)
    u32      reserved

then a raw-DEFLATE payload (Apple's COMPRESSION_ZLIB) of planes, splat-major
within each plane so neighbours compress together:

    u16[count] x, y, z      0..65535 across the bounds
    u8[count]  r, g, b, a   colour from SH band 0, opacity through the sigmoid
    u8[count]  sx, sy, sz   log scale, -10..2 over 0..255
    u8[count]  qw, qx, qy, qz  unit quaternion, -1..1 over 0..255

Only SH band 0 is kept: view-dependent colour is dropped, as most web
viewers' compressed formats do.

The transform in captures.json is applied here, once, so the runtime sees every
capture the same way: y up, the subject at the origin, the subject's radius 1.
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


def read_any(path):
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
    pos, rgb, alpha, log_scale, quat = splats
    ok = np.isfinite(pos).all(1) & np.isfinite(log_scale).all(1) & np.isfinite(quat).all(1) & np.isfinite(alpha)
    pos, rgb, alpha, log_scale, quat = pos[ok], rgb[ok], alpha[ok], log_scale[ok], quat[ok]
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
    pos, rgb, alpha, log_scale, quat = pos[keep], rgb[keep], alpha[keep], log_scale[keep], quat[keep]

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
        pos, rgb, alpha, log_scale, quat = pos[idx], rgb[idx], alpha[idx], log_scale[idx], quat[idx]
    return pos, rgb, alpha, log_scale, quat


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
    pos, rgb, alpha, log_scale, quat = splats
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
    comp = zlib.compressobj(9, zlib.DEFLATED, -15)
    payload = comp.compress(planes) + comp.flush()
    header = struct.pack("<4sIII3f3fII", b"LSPL", 1, n, 0, *lo.astype(np.float32), *hi.astype(np.float32),
                         len(payload), 0)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path + ".tmp", "wb") as f:
        f.write(header)
        f.write(payload)
    os.replace(path + ".tmp", path)
    return n, len(header) + len(payload)


# ---------------------------------------------------------------- inspect ----

def render_views(prefix, splats, extent=None):
    from PIL import Image
    pos, rgb, alpha, log_scale, quat = splats
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
    pos, rgb, alpha, log_scale, quat = splats
    print(f"{path}: {len(pos):,} splats")
    for p in (1, 5, 50, 95, 99):
        print(f"  p{p:<2} pos {np.percentile(pos, p, 0).round(3)}")
    print(f"  mean alpha {alpha.mean():.3f}, median scale {np.exp(np.median(log_scale, 0)).round(4)}")
    if prefix:
        render_views(prefix, splats, cfg.get("view_extent") if cfg else None)


def splat_transform():
    """PlayCanvas's splat-transform (MIT), pinned, installed under build/."""
    import subprocess
    tools = os.path.join(ROOT, "build", "node-tools")
    exe = os.path.join(tools, "node_modules", ".bin", "splat-transform")
    if not os.path.exists(exe):
        subprocess.run(["npm", "install", "--silent", "--no-audit", "--no-fund", "--prefix", tools,
                        "@playcanvas/splat-transform@" + SPLAT_TRANSFORM_VERSION], check=True)
    return exe


SPLAT_TRANSFORM_VERSION = "3.10.3"


def fetch(cid, cfg, src_dir):
    """The capture as a local .ply, downloaded and decoded once.

    SuperSplat serves SOG (a meta.json plus WebP planes); a level of a
    streamed level-of-detail scene is several such chunks, merged here.
    Spherical harmonics past band 0 are dropped at this step.
    """
    import subprocess
    path = os.path.join(src_dir, cid + ".ply")
    if os.path.exists(path):
        return path
    os.makedirs(src_dir, exist_ok=True)
    cmd = [splat_transform(), "-q", "-w"]
    for url in cfg["sources"]:
        cmd.append(url)
    cmd += ["-H", "0", "-N"]
    if cfg.get("decimate"):
        cmd += ["--decimate-adaptive", str(cfg["decimate"])]
    cmd.append(path + ".part.ply")
    print(f"{cid}: fetching {len(cfg['sources'])} file(s)")
    subprocess.run(cmd, check=True)
    os.replace(path + ".part.ply", path)
    return path


def convert_all(configs):
    src_dir = os.path.join(ROOT, "build", "splats-src")
    out_dir = os.path.join(ROOT, "build", "splats")
    newest_input = max(os.path.getmtime(CONFIG), os.path.getmtime(os.path.abspath(__file__)))
    wanted = set()
    for cid, cfg in configs["captures"].items():
        wanted.add(cid + ".lsplat")
        src = fetch(cid, cfg, src_dir)
        out = os.path.join(out_dir, cid + ".lsplat")
        if os.path.exists(out) and os.path.getmtime(out) >= max(newest_input, os.path.getmtime(src)):
            continue
        n, size = write_lsplat(out, apply_config(read_any(src), cfg))
        print(f"{cid}: {n:,} splats, {size / 1e6:.1f} MB")
    # A capture dropped from captures.json leaves the bundle too.
    for name in os.listdir(out_dir) if os.path.isdir(out_dir) else []:
        if name.endswith(".lsplat") and name not in wanted:
            os.remove(os.path.join(out_dir, name))


def main():
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
