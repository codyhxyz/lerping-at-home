#!/usr/bin/env python3
"""Bake a Minecraft save into the files a Lerping world look traces.

    python3 scripts/minecraft-world/bake.py SAVE_DIR NAME [--center auto|X,Z] [--size 384]
        [--max-height 192] [--far-size 2048] [--jar JAR] [--out DIR]

Reads the save (never writes it) and writes
~/Library/Application Support/Lerping/Minecraft/Worlds/NAME/: blocks.r16,
light.rgba8, tints.rgba8, far.rg16, far.rgba8, routes.u16, world.metal, the
MATERIALS tables, and world.json last. FORMAT.md in this folder is the byte
layout of each file. The material ids come from materials.Table; the rest is
here: choosing the box, the game's light, biome tints, the far field, points
of interest and routes.
"""

import argparse
import datetime
import hashlib
import heapq
import json
import ctypes
import os
import shutil
import sys
import time
import zipfile

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import anvil  # noqa: E402
import biomecolor  # noqa: E402
import blocknames as bn  # noqa: E402
import village  # noqa: E402

FORMAT_VERSION = 1
MIN_Y = -64          # overworld bottom (26.x)
WORLD_H = 384
LIGHT_MAX = 15
SUPPORT = os.path.expanduser("~/Library/Application Support")
DEFAULT_JAR = os.path.join(SUPPORT, "minecraft/versions/26.2/26.2.jar")
ATLAS_DIR = os.path.join(SUPPORT, "Lerping/Minecraft")
WORLDS_DIR = os.path.join(ATLAS_DIR, "Worlds")
FAR_MIN_Y = MIN_Y

T0 = time.time()


def say(msg):
    print(f"[{time.time() - T0:6.1f}s] {msg}", flush=True)


class BakeError(Exception):
    pass


# ---------------------------------------------------------------- block states

class States:
    """Every block state seen, as a dense global id (gid). gid 0 is air."""

    def __init__(self, table):
        self.table = table
        self.keys = [("minecraft:air", ())]
        self.index = {self.keys[0]: 0}
        self.mid = [0]
        self.needs_pos = set()

    def gid(self, entry):
        key = anvil.state_key(entry)
        g = self.index.get(key)
        if g is not None:
            return g
        if bn.short(key[0]) in bn.AIR:
            self.index[key] = 0
            return 0
        g = len(self.keys)
        self.keys.append(key)
        self.index[key] = g
        props = dict(key[1])
        if self.table.needs_pos(key[0], props):
            # Weighted model variants: the id depends on the position (assign_variants). This
            # stand-in id, the variant at the origin, serves what is the same for every variant:
            # light, fluid, collision, map colour.
            self.needs_pos.add(g)
            mid = self.table.resolve(key[0], props, pos=(0, 0, 0))
        else:
            mid = self.table.resolve(key[0], props)
        if mid == 0:
            raise BakeError(f"materials resolved {anvil.state_string(key)} to air")
        self.mid.append(mid)
        return g

    def lut(self, fn, dtype):
        return np.array([fn(i, k) for i, k in enumerate(self.keys)], dtype=dtype)


def decode_chunk(chunk, states):
    """(gids [384, 16, 16] y,z,x uint16, biome names list, biome quart idx [96, 4, 4] int16 into that list)."""
    col = np.zeros((WORLD_H, 16, 16), np.uint16)
    bq = np.full((WORLD_H // 4, 4, 4), -1, np.int16)
    bnames = []
    bindex = {}
    for sec in chunk.get("sections", []):
        sy = sec["Y"] - MIN_Y // 16
        if sy < 0 or sy >= WORLD_H // 16:
            continue
        r = anvil.section_blocks(sec)
        if r is not None:
            pal, idx = r
            lut = np.array([states.gid(e) for e in pal], np.uint16)
            col[sy * 16:(sy + 1) * 16] = lut[idx].reshape(16, 16, 16)
        b = anvil.section_biomes(sec)
        if b is not None:
            pal, idx = b
            loc = []
            for name in pal:
                if name not in bindex:
                    bindex[name] = len(bnames)
                    bnames.append(name)
                loc.append(bindex[name])
            bq[sy * 4:(sy + 1) * 4] = np.array(loc, np.int16)[idx].reshape(4, 4, 4)
    return col, bnames, bq


def top_index(mask):
    """Highest y index where mask is true along axis 0, -1 where none."""
    rev = mask[::-1]
    any_ = rev.any(axis=0)
    t = mask.shape[0] - 1 - rev.argmax(axis=0)
    return np.where(any_, t, -1)


# ---------------------------------------------------------------- materials

def load_table(jar):
    import materials
    return materials.Table(jar, ATLAS_DIR)


# ---------------------------------------------------------------- pass 1: the whole save

class Summary:
    """Per-column facts for every finished chunk in the save, on one grid."""

    def __init__(self, save, states, biomes_registry):
        dim = save.overworld
        coords = dim.chunk_coords()
        self.status = {}
        full = []
        sq = save.generated["chunks"] if save.generated else None
        self.outside_square = 0
        for cx, cz in coords:
            if sq and not (sq["x0"] <= cx <= sq["x1"] and sq["z0"] <= cz <= sq["z1"]):
                # generate.sh: only its square is deterministic; the start-up spawn area and the
                # ring of partial chunks around the square are treated as absent.
                self.outside_square += 1
                continue
            ch = dim.read(cx, cz)
            st = ch.get("Status", "?")
            self.status[st] = self.status.get(st, 0) + 1
            if st == "minecraft:full":
                full.append((cx, cz, ch))
        if sq and len(full) != sq["count"]:
            raise BakeError(f"lerping-generate.json says {sq['count']} full chunks in its square; the save has {len(full)}")
        if not full:
            raise BakeError(f"{save.path}: no finished chunks (statuses {self.status})")
        self.chunks_in_save = len(coords)
        self.full = {(cx, cz) for cx, cz, _ in full}
        xs = [c[0] for c in full]
        zs = [c[1] for c in full]
        self.cx0, self.cz0 = min(xs), min(zs)
        self.ncx, self.ncz = max(xs) - self.cx0 + 1, max(zs) - self.cz0 + 1
        W, D = self.ncx * 16, self.ncz * 16
        self.x0, self.z0 = self.cx0 * 16, self.cz0 * 16
        self.exists = np.zeros((D, W), bool)
        self.top_any = np.full((D, W), -1, np.int16)      # world y of highest non-air, -1 index = none
        self.top_solid = np.full((D, W), -1, np.int16)    # highest non-air, non-pure-fluid
        self.gid_any = np.zeros((D, W), np.uint16)
        self.gid_solid = np.zeros((D, W), np.uint16)
        self.built = np.zeros((D, W), np.int32)
        self.biome_q = np.full((self.ncz * 4, self.ncx * 4, WORLD_H // 4), -1, np.int16)   # [qz, qx, qy]
        self.biomes = biomes_registry
        pure = None
        built_lut = None
        for cx, cz, ch in full:
            col, bnames, bq = decode_chunk(ch, states)
            if pure is None or len(pure) < len(states.keys):
                pure = states.lut(lambda i, k: bn.short(k[0]) in bn.PURE_FLUIDS, bool)
                built_lut = states.lut(lambda i, k: bn.is_built(k[0]), bool)
                water_lut = states.lut(lambda i, k: bn.short(k[0]) in ("water", "bubble_column"), bool)
            nonair = col != 0
            solid = nonair & ~pure[col]
            ta = top_index(nonair)
            ts = top_index(solid)
            ox, oz = (cx - self.cx0) * 16, (cz - self.cz0) * 16
            sl = (slice(oz, oz + 16), slice(ox, ox + 16))
            self.exists[sl] = True
            self.top_any[sl] = np.where(ta >= 0, ta + MIN_Y, MIN_Y - 1)
            self.top_solid[sl] = np.where(ts >= 0, ts + MIN_Y, MIN_Y - 1)
            zz, xx = np.mgrid[0:16, 0:16]
            self.gid_any[sl] = col[np.maximum(ta, 0), zz, xx] * (ta >= 0)
            self.gid_solid[sl] = col[np.maximum(ts, 0), zz, xx] * (ts >= 0)
            # Built blocks near the surface: at or above 8 below the chunk's lowest ground.
            ground = int(ts[ts >= 0].min()) if (ts >= 0).any() else 0
            b = built_lut[col]
            b[:max(0, ground - 8)] = False
            # Under water (below the column's highest water block) a camera in the air cannot see it.
            wt = top_index(water_lut[col])
            b &= np.arange(WORLD_H)[:, None, None] > wt[None]
            self.built[sl] = b.sum(axis=0)
            gl = np.array([biomes_registry.id(n) for n in bnames], np.int16) if bnames else np.zeros(0, np.int16)
            qb = np.where(bq >= 0, gl[np.maximum(bq, 0)] if len(gl) else -1, -1)   # [qy, qz, qx]
            self.biome_q[(cz - self.cz0) * 4:(cz - self.cz0) * 4 + 4,
                         (cx - self.cx0) * 4:(cx - self.cx0) * 4 + 4] = qb.transpose(1, 2, 0)
        self.n_full = len(full)

    def biome_at(self, X, Y, Z, seed):
        """Global biome id at world blocks (arrays), the game's zoomed lookup; -1 where unknown."""
        qx, qy, qz = biomecolor.zoomed_cells(seed, X, Y, Z)
        qx = qx - self.cx0 * 4
        qz = qz - self.cz0 * 4
        qy = qy - MIN_Y // 4
        ok = (qx >= 0) & (qx < self.biome_q.shape[1]) & (qz >= 0) & (qz < self.biome_q.shape[0])
        qy = np.clip(qy, 0, self.biome_q.shape[2] - 1)
        out = np.full(np.shape(X), -1, np.int16)
        out[ok] = self.biome_q[qz[ok], qx[ok], qy[ok]]
        return out


class BiomeRegistry:
    def __init__(self, biomes):
        self.biomes = biomes
        self.names = []
        self.index = {}
        self.colours = []

    def id(self, name):
        i = self.index.get(name)
        if i is None:
            i = len(self.names)
            self.names.append(name)
            self.index[name] = i
            self.colours.append(self.biomes.colours(name))
        return i


# ---------------------------------------------------------------- choosing the box

def box_sum(a, k):
    """Sum over k x k windows centred on each cell (zero outside)."""
    r = k // 2
    p = np.pad(a.astype(np.int64), ((r + 1, k - r - 1), (r + 1, k - r - 1)))
    c = np.cumsum(np.cumsum(p, 0), 1)
    return c[k:, k:] - c[:-k, k:] - c[k:, :-k] + c[:-k, :-k]


def choose_center(args, summ, save):
    total = int(summ.built.sum())
    if args.center != "auto":
        x, z = (int(v) for v in args.center.split(","))
        return x, z, "given", f"--center {x},{z}"
    g = save.generated
    if g and g.get("structure") and g.get("x") is not None:
        # generate.sh made this save to film one structure, and says where the game located it.
        k = 128
        s = box_sum(summ.built, k)
        j, i = g["z"] - summ.z0, g["x"] - summ.x0
        return g["x"], g["z"], "generated-structure", (
            f"{g['structure']} that generate.sh located at ({g['x']}, {g['z']}); "
            f"{int(s[j, i])} built blocks near the surface within {k}x{k} of it")
    # A village or a base spreads over 100 blocks or more; a 128-wide window weighs the whole
    # of it against a compact tower with as many blocks.
    k = 128
    s = box_sum(summ.built, k)
    j, i = np.unravel_index(int(s.argmax()), s.shape)
    best = int(s[j, i])
    if best >= 64:
        # Centre of mass of the built blocks within 64 blocks of the densest window.
        z0, z1 = max(0, j - 64), j + 65
        x0, x1 = max(0, i - 64), i + 65
        w = summ.built[z0:z1, x0:x1].astype(np.float64)
        zz, xx = np.mgrid[z0:z0 + w.shape[0], x0:x0 + w.shape[1]]
        cx = int(round((w * xx).sum() / w.sum())) + summ.x0
        cz = int(round((w * zz).sum() / w.sum())) + summ.z0
        return cx, cz, "built-blocks", (f"densest {k}x{k} window of built blocks near the surface and above water holds {best} "
                                        f"(of {total} in the save); centre of mass within 64 blocks")
    if save.player is not None:
        px, _, pz = save.player
        return int(np.floor(px)), int(np.floor(pz)), "player", (
            f"only {best} built blocks above water in the densest {k}x{k} window ({total} in the save): "
            f"the player's last position")
    if save.spawn is not None:
        return save.spawn[0], save.spawn[2], "spawn", f"only {best} built blocks and no player: world spawn"
    raise BakeError("no built blocks, no player and no spawn: give --center X,Z")


def choose_box(args, summ, cx, cz):
    size = (args.size + 15) // 16 * 16
    notes = []
    ext_x0, ext_x1 = summ.x0, summ.x0 + summ.ncx * 16
    ext_z0, ext_z1 = summ.z0, summ.z0 + summ.ncz * 16

    def place(c, lo, hi, axis):
        n = size
        if hi - lo < n:
            notes.append(f"the save is only {hi - lo} blocks across in {axis}: box is {hi - lo}, not {n}")
            return lo, hi - lo
        o = (c - n // 2) // 16 * 16
        o2 = min(max(o, lo), hi - n)
        if o2 != o:
            notes.append(f"box moved {o2 - o:+d} in {axis} to stay inside the save's finished chunks")
        return o2, n
    ox, W = place(cx, ext_x0, ext_x1, "x")
    oz, D = place(cz, ext_z0, ext_z1, "z")
    sl = (slice(oz - summ.z0, oz - summ.z0 + D), slice(ox - summ.x0, ox - summ.x0 + W))
    ex = summ.exists[sl]
    missing_chunks = int((~ex[::16, ::16]).sum())
    if missing_chunks:
        notes.append(f"{missing_chunks} chunks inside the box are not finished in the save: their columns are air")
    ta = summ.top_any[sl][ex]
    ts = summ.top_solid[sl][ex]
    lowest = int(ts.min())
    tallest = int(ta.max())
    bottom = lowest - 4
    top = tallest + 2                 # inclusive: at least one air cell above the tallest block
    H = top - bottom + 1
    capped, cut = False, {}
    if H > args.max_height:
        Hc = args.max_height
        best = None
        for b in range(bottom, top - Hc + 2):
            below = int((ts < b).sum())
            above = int((ta >= b + Hc).sum())
            cost = below + above
            if best is None or cost < best[0]:
                best = (cost, b, below, above)
        _, b, below, above = best
        capped = True
        cut = {"columns_floor_below": below, "columns_top_above": above,
               "content_min_y": bottom, "content_max_y": top}
        notes.append(f"content spans y {bottom}..{top} ({H} blocks) > --max-height {Hc}: kept y {b}..{b + Hc - 1}; "
                     f"{below} columns have their floor below the box, {above} columns have blocks above it")
        bottom, H = b, Hc
    return dict(origin=(ox, bottom, oz), size=(W, H, D), missing_chunks=missing_chunks,
                content=(lowest - 4, tallest + 2), capped=capped, cut=cut, notes=notes)


# ---------------------------------------------------------------- pass 2: the volume

def build_volume(save, states, summ, box):
    (ox, oy, oz), (W, H, D) = box["origin"], box["size"]
    vol = np.zeros((D, H, W), np.uint16)
    above = {}           # (cx, cz) -> gids above the box [h, 16, 16]
    y0 = oy - MIN_Y
    for cz in range(oz // 16, (oz + D) // 16):
        for cx in range(ox // 16, (ox + W) // 16):
            if (cx, cz) not in summ.full:
                continue
            col, _, _ = decode_chunk(save.overworld.read(cx, cz), states)
            lz, lx = cz * 16 - oz, cx * 16 - ox
            vol[lz:lz + 16, :, lx:lx + 16] = col[y0:y0 + H].transpose(1, 0, 2)
            if y0 + H < WORLD_H and col[y0 + H:].any():
                above[(cx, cz)] = col[y0 + H:]
    return vol, above


_LCG_MUL = np.uint64(0x5DEECE66D)
_LCG_ADD = np.uint64(0xB)
_MASK48 = np.uint64((1 << 48) - 1)


def _seed_random(seed):
    return (seed.astype(np.uint64) ^ _LCG_MUL) & _MASK48


def _next(s, bits):
    s = (s * _LCG_MUL + _LCG_ADD) & _MASK48
    return s, (s >> np.uint64(48 - bits)).astype(np.int64)


def _next_int_first(s, bound):
    """First draw of java.util.Random.nextInt(bound); also whether the game would have redrawn."""
    s, v = _next(s, 31)
    if bound & (bound - 1) == 0:
        return (bound * v) >> 31, np.zeros(v.shape, bool)
    val = v % bound
    return val, (v - val + (bound - 1)) >= (1 << 31)


def mth_seed(x, y, z):
    """Mth.getSeed(x, y, z), vectorised: (long)(x * 3129871) ^ z * 116129781L ^ y, mixed, >> 16."""
    with np.errstate(over="ignore"):
        x32 = (x.astype(np.int64) * 3129871).astype(np.int32).astype(np.int64)
        l = x32 ^ (z.astype(np.int64) * np.int64(116129781)) ^ y.astype(np.int64)
        l = l * l * np.int64(42317861) + l * np.int64(11)
    return l >> 16


def assign_variants(gids, mid, states, table, origin):
    """Give each voxel of a weighted-variant state the variant the game's renderer picks there.

    The picks are computed here in numpy (the renderer's Mth.getSeed and LCG, as
    MATERIALS documents them) and every distinct pick is resolved by table.resolve
    at a position that has it; 64 random voxels per state are then checked against
    table.resolve at their own position, and any disagreement stops the bake."""
    ox, oy, oz = origin
    # bincount, not np.unique: numpy 2.0's sort crashes (SIGSEGV) on some arrays this size here.
    present = np.nonzero(np.bincount(gids.reshape(-1)))[0]
    rng = np.random.default_rng(1)
    total = 0
    for g in present:
        g = int(g)
        if g not in states.needs_pos:
            continue
        name, props = states.keys[g][0], dict(states.keys[g][1])
        kind, parts = table.parts(name, props)
        idx = np.nonzero(gids.reshape(-1) == g)[0]
        D, H, W = gids.shape
        z, rem = np.divmod(idx, H * W)
        y, x = np.divmod(rem, W)
        wx, wy, wz = x + ox, y + oy, z + oz
        seed = mth_seed(wx, wy, wz)
        if kind == "multipart":
            s = _seed_random(seed)
            s, hi = _next(s, 32)
            s, lo = _next(s, 32)
            hi = hi.astype(np.int32).astype(np.int64)
            lo = lo.astype(np.int32).astype(np.int64)
            with np.errstate(over="ignore"):
                seed = (hi << 32) + lo
        sig = np.zeros(len(idx), np.int64)
        redraw = np.zeros(len(idx), bool)
        for p in parts:
            if len(p) <= 1:
                continue
            w = np.array([e.get("weight", 1) for e in p], np.int64)
            v, rd = _next_int_first(_seed_random(seed), int(w.sum()))
            choice = np.searchsorted(np.cumsum(w), v, side="right")
            sig = sig * 64 + choice
            redraw |= rd
        vm = np.zeros(len(idx), np.uint16)
        for sv in np.unique(sig[~redraw]):
            k = np.nonzero((sig == sv) & ~redraw)[0][0]
            vm[(sig == sv) & ~redraw] = table.resolve(name, props, pos=(int(wx[k]), int(wy[k]), int(wz[k])))
        for k in np.nonzero(redraw)[0]:          # the rare draw java.util.Random rejects: ask the table
            vm[k] = table.resolve(name, props, pos=(int(wx[k]), int(wy[k]), int(wz[k])))
        for k in rng.choice(len(idx), size=min(64, len(idx)), replace=False):
            want = table.resolve(name, props, pos=(int(wx[k]), int(wy[k]), int(wz[k])))
            if want != vm[k]:
                raise BakeError(f"variant pick for {anvil.state_string(states.keys[g])} at "
                                f"{(int(wx[k]), int(wy[k]), int(wz[k]))}: bake {vm[k]}, materials {want}")
        mid.reshape(-1)[idx] = vm
        total += len(idx)
    return total


def material_luts(states, table):
    mids = np.array(states.mid, np.uint16)
    n = len(table)
    if n > 4096:
        raise BakeError(f"{n - 1} materials: more than the 4095 blocks.r16 can index")
    opaque = np.zeros(n, bool)
    filt = np.zeros(n, np.int8)
    emit_level = np.zeros(n, np.int8)
    emit_col = np.zeros((n, 3), np.float64)
    fluid = np.zeros(n, np.int8)           # 0 none, 1 water, 2 lava (including waterlogged)
    for m in range(1, n):
        opaque[m] = bool(table.opaque(m))
        f = int(table.light_filter(m))
        if not 0 <= f <= 15:
            raise BakeError(f"material {m}: light_filter {f} outside 0..15")
        filt[m] = 15 if opaque[m] else f
        lv, c = table.emission(m)
        emit_level[m] = int(lv)
        if lv:
            c = np.asarray(c, np.float64)
            if c.max() <= 0:
                raise BakeError(f"material {m} emits level {lv} with colour {tuple(c)}")
            emit_col[m] = c / c.max()
        fl = table.fluid(m)
        if fl is not None:
            fluid[m] = 1 if fl[0] == "water" else 2
    face_full = np.zeros(len(states.keys), np.uint8)
    for i, (name, props) in enumerate(states.keys):
        if i == 0:
            continue
        nm, pk = table.state_key(name, dict(props))
        info = table.info.get((nm, pk))
        if info is None:
            raise BakeError(f"no game data for {anvil.state_string(states.keys[i])} (light occlusion)")
        face_full[i] = info.face_full & 63
    return dict(mids=mids, n=n, face_full=face_full, opaque=opaque, filt=filt, emit_level=emit_level, emit_col=emit_col, fluid=fluid)


# ---------------------------------------------------------------- skip distance

def dilate(a):
    out = a.copy()
    for ax in range(3):
        b = out.copy()
        sl_lo = [slice(None)] * 3
        sl_hi = [slice(None)] * 3
        sl_lo[ax] = slice(1, None)
        sl_hi[ax] = slice(None, -1)
        b[tuple(sl_lo)] |= out[tuple(sl_hi)]
        b[tuple(sl_hi)] |= out[tuple(sl_lo)]
        out = b
    return out


def skip_field(mid):
    occ = mid != 0
    dist = np.full(mid.shape, 15, np.uint8)
    cur = occ
    for k in range(1, 15):
        nxt = dilate(cur)
        dist[nxt & ~cur] = k
        cur = nxt
    dist[occ] = 0
    return dist


# ---------------------------------------------------------------- light

# Face bits as the game's Direction order (BlockDump's face_full): down, up, north (-z), south (+z), west (-x), east (+x).
F_DOWN, F_UP, F_NORTH, F_SOUTH, F_WEST, F_EAST = (1 << i for i in range(6))
# Travel directions as (axis of the [z, y, x] array, step, face the light leaves A by, face it enters B by).
TRAVEL = [(1, +1, F_UP, F_DOWN), (1, -1, F_DOWN, F_UP), (0, +1, F_SOUTH, F_NORTH), (0, -1, F_NORTH, F_SOUTH),
          (2, +1, F_EAST, F_WEST), (2, -1, F_WEST, F_EAST)]


def _sl(axis, a, b):
    s_ = [slice(None)] * 3
    s_[axis] = slice(a, b)
    return tuple(s_)


def open_masks(face):
    """For each travel direction, where light may pass from the neighbour into the cell: neither
    the neighbour's face it leaves by nor the cell's face it enters by is a full face
    (the game's shapeOccludes, with each face either full or not)."""
    out = []
    for axis, step, leave, enter in TRAVEL:
        m = np.zeros(face.shape, bool)
        dst = _sl(axis, 1, None) if step > 0 else _sl(axis, None, -1)
        src = _sl(axis, None, -1) if step > 0 else _sl(axis, 1, None)
        m[dst] = ((face[src] & leave) == 0) & ((face[dst] & enter) == 0)
        out.append((axis, step, m))
    return out


def flood(L, cost, masks, iters=LIGHT_MAX):
    """The game's spread: each cell takes max(own, neighbour - cost of entering it), where the faces between allow. int8 in place."""
    for _ in range(iters):
        nb = np.zeros_like(L)
        for axis, step, m in masks:
            dst = _sl(axis, 1, None) if step > 0 else _sl(axis, None, -1)
            src = _sl(axis, None, -1) if step > 0 else _sl(axis, 1, None)
            np.maximum(nb[dst], np.where(m[dst], L[src], 0), out=nb[dst])
        nb -= cost
        changed = nb > L
        if not changed.any():
            break
        np.maximum(L, nb, out=L)
    return L


def bake_light(mid, gids, luts, states, above, box):
    (ox, oy, oz), (W, H, D) = box["origin"], box["size"]
    opaque = luts["opaque"][mid]
    filt = luts["filt"][mid]
    cost = np.maximum(filt, 1).astype(np.int8)
    cost[opaque] = 64

    # Sky: what enters the top of the box, per column (reduced by blocks --max-height cut off above it).
    sky_top = np.full((D, W), 15, np.int8)
    if above:
        filt_g = luts["filt"][luts["mids"]]
        for (cx, cz), g in above.items():
            f = filt_g[g]                        # [h, 16, 16]
            s = np.full((16, 16), 15, np.int16)
            for y in range(f.shape[0] - 1, -1, -1):
                fy = f[y].astype(np.int16)
                stay = (s == 15) & (fy == 0)
                s = np.where(stay, 15, np.maximum(0, s - np.maximum(1, fy)))
            sky_top[cz * 16 - oz:cz * 16 - oz + 16, cx * 16 - ox:cx * 16 - ox + 16] = s
    # Partial blocks (stairs, slabs, paths, snow) block light through their full faces. An opaque
    # cell is already closed by its cost; its faces stay open so an opaque emitter (magma,
    # glowstone) still lights its neighbours, as in the game.
    face = luts["face_full"][gids]
    face[opaque] = 0
    masks = open_masks(face)
    # Straight down at 15: stops at a cell that filters light or that light cannot enter from above.
    down_open = np.ones(face.shape, bool)
    down_open[:, :-1, :] = ((face[:, 1:, :] & F_DOWN) == 0) & ((face[:, :-1, :] & F_UP) == 0)
    down_open[:, -1, :] = (face[:, -1, :] & F_UP) == 0
    blocked = (filt > 0) | ~down_open
    open_above = np.cumsum(blocked[:, ::-1, :], axis=1)[:, ::-1, :] == 0
    sky = np.where(open_above & (sky_top[:, None, :] == 15), 15, 0).astype(np.int8)
    cut = sky_top < 15
    if cut.any():
        top = sky[:, H - 1, :]
        top[cut] = np.where(opaque[:, H - 1, :][cut], 0, sky_top[cut])
    say(f"light: sky seeded in {int((sky == 15).sum())} cells; spreading")
    flood(sky, cost, masks)
    sky[opaque] = 0

    # Block light, one flood per colour of source, restricted to the emitters' reach.
    lv = luts["emit_level"][mid]
    em = np.nonzero(lv)
    out = np.zeros((D, H, W, 4), np.uint8)
    groups = {}
    if len(em[0]):
        cols = luts["emit_col"][mid[em]]
        keyed = [tuple(round(float(v), 4) for v in c) for c in cols]
        for i, k in enumerate(keyed):
            groups.setdefault(k, []).append(i)
    bcost = cost.copy()
    for colour, idx in groups.items():
        idx = np.array(idx)
        z, y, x = em[0][idx], em[1][idx], em[2][idx]
        lo = np.maximum([z.min() - 15, y.min() - 15, x.min() - 15], 0)
        hi = np.minimum([z.max() + 16, y.max() + 16, x.max() + 16], [D, H, W])
        sub = tuple(slice(a, b) for a, b in zip(lo, hi))
        L = np.zeros(tuple(hi - lo), np.int8)
        L[z - lo[0], y - lo[1], x - lo[2]] = lv[z, y, x]
        flood(L, bcost[sub], [(a_, s_, m[sub]) for a_, s_, m in masks])
        L[opaque[sub]] = 0
        for c in range(3):
            v = np.round(L.astype(np.float32) * np.float32(colour[c] * 255.0 / 15.0)).astype(np.uint8)
            np.maximum(out[sub + (c,)], v, out=out[sub + (c,)])
        say(f"light: {len(idx)} emitters of colour {colour} spread")
    out[..., 3] = (sky.astype(np.int16) * 17).astype(np.uint8)
    return out, len(em[0]), {str(k): len(v) for k, v in groups.items()}


# ---------------------------------------------------------------- tints

def column_tints(summ, breg, seed, x0, z0, W, D, ycol):
    """Blended (grass, foliage, water, dry foliage) 0xRRGGBB ints [D, W] for world columns x0.., z0.., at heights ycol."""
    pad = 2
    zz, xx = np.mgrid[z0 - pad:z0 + D + pad, x0 - pad:x0 + W + pad]
    yy = np.pad(ycol, pad, mode="edge")
    bid = summ.biome_at(xx, yy, zz, seed)
    cols = np.array([c[:4] for c in breg.colours] + [(-1, -1, -1, -1)], np.int64)
    swamp = np.array([c[4] == "swamp" for c in breg.colours] + [False])
    b = np.where(bid >= 0, bid, len(breg.colours))
    grass = cols[b, 0]
    sw = swamp[b]
    if sw.any():
        grass = np.where(sw, biomecolor.swamp_grass(xx, zz), grass)
    out = []
    unknown = 0
    for ch in (grass, cols[b, 1], cols[b, 2], cols[b, 3]):
        bl, unk = biomecolor.blend(ch)
        out.append(bl[pad:-pad, pad:-pad])
        unknown = max(unknown, int(unk[pad:-pad, pad:-pad].sum()))
    names = sorted({breg.names[i] for i in np.unique(bid[bid >= 0])})
    return out, unknown, names, bool(sw.any())


def int_to_rgb(a):
    return np.stack([(a >> 16) & 255, (a >> 8) & 255, a & 255], -1).astype(np.uint8)


# ---------------------------------------------------------------- far field

def bake_far(args, summ, states, luts, table, breg, seed, box):
    (ox, oy, oz), (W, H, D) = box["origin"], box["size"]
    half = args.far_size // 2
    cx, cz = ox + W // 2, oz + D // 2
    fx0 = max((cx - half) // 16 * 16, summ.x0)
    fz0 = max((cz - half) // 16 * 16, summ.z0)
    fx1 = min((cx + half + 15) // 16 * 16, summ.x0 + summ.ncx * 16)
    fz1 = min((cz + half + 15) // 16 * 16, summ.z0 + summ.ncz * 16)
    FW, FD = fx1 - fx0, fz1 - fz0
    sl = (slice(fz0 - summ.z0, fz1 - summ.z0), slice(fx0 - summ.x0, fx1 - summ.x0))
    ex = summ.exists[sl]
    ts = summ.top_solid[sl].astype(np.int32)
    ta = summ.top_any[sl].astype(np.int32)
    gs = summ.gid_solid[sl]
    ga = summ.gid_any[sl]
    (grass, foliage, water, dry), unknown, names, swamp = column_tints(summ, breg, seed, fx0, fz0, FW, FD, ta)
    mids = luts["mids"]
    n = luts["n"]
    mapc = np.zeros((n, 3), np.float64)
    tkind = np.zeros(n, np.int8)           # 0 none, 1 grass, 2 foliage, 3 water, 4 dry foliage
    kinds = {None: 0, "grass": 1, "foliage": 2, "water": 3, "dry_foliage": 4}
    for m in range(1, n):
        mapc[m] = np.asarray(table.map_color(m), np.float64) / 255.0
        k = table.tint_kind(m)
        if k not in kinds:
            raise BakeError(f"material {m}: tint kind {k!r} is not grass/foliage/water/dry_foliage/None")
        tkind[m] = kinds[k]
    tints = np.stack([np.zeros_like(grass) + 0xFFFFFF, grass, foliage, water, dry])     # by kind
    tint_rgb = int_to_rgb(tints).astype(np.float64) / 255.0                         # [4, FD, FW, 3]
    ms = mids[gs]
    kk = tkind[ms]
    zz, xx = np.mgrid[0:FD, 0:FW]
    ground = mapc[ms] * tint_rgb[kk, zz, xx]
    fl_gid = ga
    fl_m = mids[fl_gid]
    has_fluid = ex & (ta > ts) & (luts["fluid"][fl_m] > 0)
    fluid_rgb = mapc[fl_m] * np.where((luts["fluid"][fl_m] == 1)[..., None], tint_rgb[3], 1.0)
    rg = np.zeros((FD, FW, 2), "<u2")
    # FORMAT.md: value = top face y (block y + 1) - min_y + 1, so 0 can mean "no chunk".
    rg[..., 0] = np.where(ex & (ts >= FAR_MIN_Y), (ts + 1) - FAR_MIN_Y + 1, 0)
    rg[..., 1] = np.where(has_fluid, (ta + 1) - FAR_MIN_Y + 1, 0)
    rgba = np.zeros((2, FD, FW, 4), np.uint8)
    rgba[0, ..., :3] = np.clip(np.round(ground * 255), 0, 255)
    rgba[0, ..., 3] = np.where(ex, 255, 0)
    rgba[1, ..., :3] = np.clip(np.round(fluid_rgb * 255), 0, 255) * has_fluid[..., None]
    rgba[1, ..., 3] = np.where(has_fluid, 255, 0)
    info = {"origin": [int(fx0), int(fz0)], "size": [int(FW), int(FD)], "min_y": FAR_MIN_Y,
            "missing_columns": int((~ex).sum()), "chunks": int(ex[::16, ::16].sum()),
            "biomes": names, "unknown_biome_samples": unknown}
    return rg, rgba, info


# ---------------------------------------------------------------- points of interest

def max_filter2(a, r):
    out = a.copy()
    for ax in (0, 1):
        cur = out.copy()
        for s in range(1, r + 1):
            sh = np.full_like(out, np.iinfo(out.dtype).min if out.dtype.kind == "i" else -np.inf)
            idx = [slice(None)] * 2
            src = [slice(None)] * 2
            idx[ax], src[ax] = slice(s, None), slice(None, -s)
            sh[tuple(idx)] = out[tuple(src)]
            np.maximum(cur, sh, out=cur)
            idx[ax], src[ax] = slice(None, -s), slice(s, None)
            sh = np.full_like(out, np.iinfo(out.dtype).min if out.dtype.kind == "i" else -np.inf)
            sh[tuple(idx)] = out[tuple(src)]
            np.maximum(cur, sh, out=cur)
        out = cur
    return out


def peaks(score, r, n, minimum):
    """Up to n local maxima of a 2D score, at least r apart (greedy suppression)."""
    s = score.astype(np.float64).copy()
    out = []
    while len(out) < n:
        j, i = np.unravel_index(int(s.argmax()), s.shape)
        if s[j, i] < minimum:
            break
        out.append((int(i), int(j), float(score[j, i])))
        s[max(0, j - r):j + r + 1, max(0, i - r):i + r + 1] = -np.inf
    return out


def components2d(mask, gap):
    """Connected groups of true cells, treating cells within `gap` (Chebyshev) as touching."""
    ys, xs = np.nonzero(mask)
    cells = set(zip(ys.tolist(), xs.tolist()))
    seen = set()
    groups = []
    for c in cells:
        if c in seen:
            continue
        stack = [c]
        seen.add(c)
        g = []
        while stack:
            y, x = stack.pop()
            g.append((y, x))
            for dy in range(-gap, gap + 1):
                for dx in range(-gap, gap + 1):
                    nb = (y + dy, x + dx)
                    if nb in cells and nb not in seen:
                        seen.add(nb)
                        stack.append(nb)
        groups.append(g)
    return groups


DIRS8 = [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)]
DIR_NAMES = ["east", "south-east", "south", "south-west", "west", "north-west", "north", "north-east"]


def view_direction(openair, bmin, bmax, doors):
    """The horizontal direction from a box toward a good camera: the side with the most open air.

    For each of 8 directions, the fraction of passable cells in a slab 3..17 blocks out from
    the box, across its width, from its floor to 6 above its top. A door on that side adds 0.15
    per door (up to 0.3). Returns ([dx, 0, dz] unit, from the box toward the camera; note)."""
    D, H, W = openair.shape
    lo = np.array(bmin, np.float64)
    hi = np.array(bmax, np.float64)
    c = (lo + hi) / 2
    half = (hi - lo) / 2
    best = None
    scores = []
    for (dx, dz), name in zip(DIRS8, DIR_NAMES):
        d = np.array([dx, dz], np.float64)
        d /= np.linalg.norm(d)
        perp = np.array([-d[1], d[0]])
        ext = abs(d[0]) * half[0] + abs(d[1]) * half[2]          # box's reach along d
        wid = abs(perp[0]) * half[0] + abs(perp[1]) * half[2]
        t = np.arange(3, 18, 2, dtype=np.float64)[:, None, None]
        sl = np.linspace(-wid, wid, 7)[None, :, None]
        ys = np.arange(int(lo[1]), int(hi[1]) + 7, 2)[None, None, :]
        px = c[0] + d[0] * (ext + t) + perp[0] * sl + 0 * ys
        pz = c[2] + d[1] * (ext + t) + perp[1] * sl + 0 * ys
        py = ys + 0 * t + 0 * sl
        ix, iz, iy = np.floor(px).astype(int), np.floor(pz).astype(int), py.astype(int)
        ok = (ix >= 0) & (ix < W) & (iz >= 0) & (iz < D) & (iy >= 0) & (iy < H)
        if ok.sum() < 8:
            scores.append((-1.0, name, 0))
            continue
        frac = float(openair[iz[ok], iy[ok], ix[ok]].mean())
        nd = 0
        for (x_, y_, z_) in doors:
            o = np.array([(x_ - c[0]) / max(half[0], 0.5), (z_ - c[2]) / max(half[2], 0.5)])
            if np.linalg.norm(o) > 0 and float(o @ d) / np.linalg.norm(o) > 0.92:
                nd += 1
        sc = frac + min(0.3, 0.15 * nd)
        scores.append((sc, name, nd))
        if best is None or sc > best[0]:
            best = (sc, d, name, frac, nd)
    if best is None:
        return [0.0, 0.0, 0.0], "no view: box at the volume's edge"
    _, d, name, frac, nd = best
    note = f"view from the {name}: {frac:.0%} open" + (f", {nd} door{'s' if nd > 1 else ''}" if nd else "")
    return [round(float(d[0]), 4), 0.0, round(float(d[1]), 4)], note


def find_pois(mid, gids, states, luts, light, surf, surf_any, box):
    (ox, oy, oz), (W, H, D) = box["origin"], box["size"]
    names = [bn.short(k[0]) for k in states.keys]
    built_lut = np.array([bn.is_built(k[0]) for k in states.keys])
    bell_lut = np.array([n == "bell" for n in names])
    built = built_lut[gids]
    # Near the surface: at or above 8 below the lowest ground of the 16x16 block around it.
    ground = surf.copy().astype(np.int32)
    gmin = -max_filter2(-ground, 8)
    yy = np.arange(H)[None, :, None]
    built &= yy >= (gmin[:, None, :] - 8)
    # And open to the sky somewhere beside it (house interiors are, through doors and windows;
    # a buried mineshaft under a village is not), so a structure is what a camera can see.
    built &= dilate(light[..., 3] > 0)
    water_lut = np.array([bn.short(k[0]) in ("water", "bubble_column") for k in states.keys])
    wet = water_lut[gids]
    wtop = top_index(wet.transpose(1, 0, 2))
    dry = built & (yy > wtop[:, None, :])
    cnt = built.sum(axis=1)                         # [D, W]
    cnt_dry = dry.sum(axis=1)
    pois = []

    def ground_y(x, z):
        return float(surf[int(z), int(x)] + 1)

    # Structures: connected groups of columns with building blocks (gap 2 joins a house's walls
    # and roof); paths and fields count as built but do not join houses into one structure.
    bld_lut = np.array([bn.is_building(k[0]) for k in states.keys])
    bld3 = bld_lut[gids] & built
    bld = bld3.sum(axis=1)
    groups = components2d(bld > 0, 2)
    open_lut = np.array([bn.is_passable(k[0], k[1]) for k in states.keys])
    door_lut = np.array([n.endswith("_door") and not n.endswith("trapdoor") for n in names])
    openair = open_lut[gids]
    structs = []
    for g in groups:
        zs = np.array([p[0] for p in g])
        xs = np.array([p[1] for p in g])
        w = cnt[zs, xs].astype(np.float64)
        total = int(w.sum())
        n_dry = int(cnt_dry[zs, xs].sum())
        if total < 24:
            continue
        cx, cz = float((xs * w).sum() / w.sum()) + 0.5, float((zs * w).sum() / w.sum()) + 0.5
        bz, by, bx = np.nonzero(built[zs.min():zs.max() + 1, :, xs.min():xs.max() + 1])
        cy = float(np.median(by)) if len(by) else ground_y(cx, cz)
        rad = float(np.sqrt(((xs + 0.5 - cx) ** 2 + (zs + 0.5 - cz) ** 2).max())) + 2.0
        # What it is made of, for the note.
        sub = gids[zs.min():zs.max() + 1, :, xs.min():xs.max() + 1][built[zs.min():zs.max() + 1, :, xs.min():xs.max() + 1]]
        u, c = np.unique(sub, return_counts=True)
        top = ", ".join(f"{names[int(g_)]} {int(n_)}" for g_, n_ in sorted(zip(u, c), key=lambda t: -t[1])[:4])
        # Bounding box of its building blocks (paths and fields left out), in its own columns.
        colmask = np.zeros((zs.max() - zs.min() + 1, xs.max() - xs.min() + 1), bool)
        colmask[zs - zs.min(), xs - xs.min()] = True
        sub3 = bld3[zs.min():zs.max() + 1, :, xs.min():xs.max() + 1] & colmask[:, None, :]
        if not sub3.any():
            sub3 = built[zs.min():zs.max() + 1, :, xs.min():xs.max() + 1] & colmask[:, None, :]
        # Columns can stack unrelated things (a mineshaft in a cave under a house): keep the run of
        # heights, split at gaps of 6 or more empty levels, that holds the most building blocks.
        per_y = sub3.sum(axis=(0, 2))
        runs, cur = [], None
        for y_, n_ in enumerate(per_y):
            if n_:
                if cur is None or y_ - cur[1] > 6:
                    cur = [y_, y_, 0]
                    runs.append(cur)
                cur[1] = y_
                cur[2] += int(n_)
        y0_, y1_, _ = max(runs, key=lambda r_: r_[2])
        sub3[:, :y0_, :] = False
        sub3[:, y1_ + 1:, :] = False
        vz, vy, vx = np.nonzero(sub3)
        bmin = [int(vx.min() + xs.min()), int(vy.min()), int(vz.min() + zs.min())]
        bmax = [int(vx.max() + xs.min()) + 1, int(vy.max()) + 1, int(vz.max() + zs.min()) + 1]
        dsub = door_lut[gids[zs.min():zs.max() + 1, :, xs.min():xs.max() + 1]] & colmask[:, None, :]
        dz_, dy_, dx_ = np.nonzero(dsub)
        doors = [(int(x_ + xs.min()) + 0.5, int(y_), int(z_ + zs.min()) + 0.5) for z_, y_, x_ in zip(dz_, dy_, dx_)]
        view, vnote = view_direction(openair, bmin, bmax, doors)
        # Ranked by what a camera in the air sees: blocks under water count a quarter.
        structs.append(dict(kind="structure", pos=[cx, cy, cz], radius=rad, score=float(n_dry + 0.25 * (total - n_dry)),
                            box=[bmin, bmax], view=view,
                            note=f"{total} built blocks ({total - n_dry} under water): {top}; {vnote}"))
    structs.sort(key=lambda p: -p["score"])
    # Clusters: structures whose edges are within 24 blocks of each other.
    clusters = []
    if len(structs) >= 2:
        left = list(range(len(structs)))
        while left:
            seed_ = left.pop(0)
            grp = [seed_]
            changed = True
            while changed:
                changed = False
                for k in list(left):
                    pk = structs[k]["pos"]
                    if any(np.hypot(pk[0] - structs[g]["pos"][0], pk[2] - structs[g]["pos"][2]) <
                           structs[g]["radius"] + structs[k]["radius"] + 24 for g in grp):
                        grp.append(k)
                        left.remove(k)
                        changed = True
            if len(grp) >= 2:
                w = np.array([structs[g]["score"] for g in grp])
                P = np.array([structs[g]["pos"] for g in grp])
                c = (P * w[:, None]).sum(0) / w.sum()
                rad = max(np.hypot(*(P[i][[0, 2]] - c[[0, 2]])) + structs[g]["radius"] for i, g in enumerate(grp))
                bmin = [min(structs[g]["box"][0][i] for g in grp) for i in range(3)]
                bmax = [max(structs[g]["box"][1][i] for g in grp) for i in range(3)]
                view, vnote = view_direction(openair, bmin, bmax, [])
                clusters.append(dict(kind="cluster", pos=[float(c[0]), ground_y(c[0], c[2]), float(c[2])],
                                     radius=float(rad), score=float(w.sum()), box=[bmin, bmax], view=view,
                                     note=f"{len(grp)} structures, {int(w.sum())} built blocks; {vnote}"))
    clusters.sort(key=lambda p: -p["score"])
    # Bells.
    bells = []
    bz, by, bx = np.nonzero(bell_lut[gids])
    for z, y, x in zip(bz, by, bx):
        bmin, bmax = [int(x), int(y), int(z)], [int(x) + 1, int(y) + 1, int(z) + 1]
        view, vnote = view_direction(openair, bmin, bmax, [])
        bells.append(dict(kind="bell", pos=[x + 0.5, float(y), z + 0.5], radius=8.0, score=1.0, box=[bmin, bmax],
                          view=view, note=f"village bell; {vnote}"))
    # Lit spots: block light on the surface cell above each column.
    zz, xx = np.mgrid[0:D, 0:W]
    sy = np.clip(surf + 1, 0, H - 1)
    blk = light[zz, sy, xx, :3].max(-1).astype(np.int64)
    lit = box_sum(blk, 15)
    lits = [dict(kind="lit", pos=[i + 0.5, ground_y(i, j), j + 0.5], radius=10.0, score=s,
                 note=f"surface block light sum {int(s)} over 15x15") for i, j, s in peaks(lit, 24, 4, 255 * 12)]
    # Hilltops: highest point within 32 blocks, well above its surroundings.
    hs = surf.astype(np.int32)
    mx = max_filter2(hs, 32)
    mean = box_sum(hs, 65) / np.maximum(box_sum(np.ones_like(hs), 65), 1)
    prom = np.where(hs >= mx, hs - mean, -np.inf)
    hills = [dict(kind="hilltop", pos=[i + 0.5, ground_y(i, j), j + 0.5], radius=24.0, score=s,
                  note=f"{s:.0f} blocks above the 65x65 mean") for i, j, s in peaks(prom, 48, 4, 6)]
    # Shores: dry land beside water (or ice over water).
    wet_lut = np.array([bn.short(k[0]) in ("water", "ice", "packed_ice", "blue_ice", "bubble_column",
                                            "kelp", "kelp_plant", "seagrass", "tall_seagrass") for k in states.keys])
    topg = gids[zz, np.clip(surf_any, 0, H - 1), xx]
    wet = wet_lut[topg] & (surf_any >= 0)
    dry = ~wet & (surf >= 0)
    nbw = np.zeros_like(wet)
    nbw[1:] |= wet[:-1]
    nbw[:-1] |= wet[1:]
    nbw[:, 1:] |= wet[:, :-1]
    nbw[:, :-1] |= wet[:, 1:]
    shore = dry & nbw
    sh = box_sum(shore.astype(np.int64), 33)
    shores = [dict(kind="shore", pos=[i + 0.5, ground_y(i, j), j + 0.5], radius=16.0, score=s,
                   note=f"{int(s)} shore columns within 33x33") for i, j, s in peaks(sh, 48, 4, 20)]
    pois = clusters[:4] + bells[:4] + structs[:16] + lits + hills + shores
    for p in pois:
        if "box" not in p:            # hilltop, shore, lit: the circle, from 4 below to 12 above its height
            x, y, z = p["pos"]
            r = p["radius"]
            p["box"] = [[int(np.floor(x - r)), int(y) - 4, int(np.floor(z - r))],
                        [int(np.ceil(x + r)), int(y) + 12, int(np.ceil(z + r))]]
            p["view"] = [0.0, 0.0, 0.0]
        p["box"] = [[max(0, min(v, s_)) for v, s_ in zip(c_, (W, H, D))] for c_ in p["box"]]
        p["pos"] = [round(float(v), 2) for v in p["pos"]]
        p["radius"] = round(float(p["radius"]), 2)
        p["score"] = round(float(p["score"]), 2)
    if not pois:
        raise BakeError("no points of interest at all (no built blocks, hills, shores or light)")
    return pois, cnt



# ---------------------------------------------------------------- routes

def walk_grid(gids, states, luts):
    keys = states.keys
    passable = np.array([bn.is_passable(k[0], k[1]) for k in keys])
    mids = luts["mids"]
    ground_lut = np.array([(luts["opaque"][mids[i]] and luts["fluid"][mids[i]] == 0) or bn.is_ground_extra(k[0], k[1])
                           for i, k in enumerate(keys)])
    ground_lut[0] = False
    pas = passable[gids]
    gnd = ground_lut[gids]
    stand = np.zeros(gids.shape, bool)
    stand[:, 1:-1, :] = gnd[:, :-2, :] & pas[:, 1:-1, :] & pas[:, 2:, :]
    names = [bn.short(k[0]) for k in keys]
    # Swimming: the top water cell of a body of water, with air (or plants) above it. Mobs
    # cross a river this way; it costs more than walking, so a route swims only when it must.
    water_lut = np.array([n in ("water", "bubble_column") for n in names])
    wat = water_lut[gids]
    swim = np.zeros(gids.shape, bool)
    swim[:, :-1, :] = wat[:, :-1, :] & pas[:, 1:, :]
    stand |= swim
    path_lut = np.array([n == "dirt_path" for n in names])
    farm_lut = np.array([n == "farmland" for n in names])
    under = np.zeros(gids.shape, np.uint16)
    under[:, 1:, :] = gids[:, :-1, :]
    # A step up onto a bottom slab or stair is half a block: walked, not jumped, so no head room needed.
    half_lut = np.array([bn.foot_drop(k[0], k[1]) >= 4 and not bn.short(k[0]).startswith("snow") for k in keys])
    onpath = path_lut[under]
    cost = np.where(swim, 8, np.where(onpath, 1, 3)).astype(np.int8)
    return stand, pas, onpath, farm_lut[under], half_lut[under], cost, swim


def astar(stand, pas, cell_cost, half, start, goal, limit=40000):
    """Shortest walk between stand cells (z, y, x); steps of 1 in x or z, |dy| <= 1, at the cost of the cell entered."""
    D, H, W = stand.shape
    gz, gy, gx = goal

    def h(c):
        return abs(c[0] - gz) + abs(c[2] - gx)
    openq = [(h(start), 0, start)]
    came = {start: None}
    cost = {start: 0}
    n = 0
    while openq:
        f, g, c = heapq.heappop(openq)
        if c == goal:
            path = []
            while c is not None:
                path.append(c)
                c = came[c]
            return path[::-1]
        if g > cost.get(c, 1 << 30):
            continue
        n += 1
        if n > limit:
            return None
        z, y, x = c
        for dz, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            nz, nx = z + dz, x + dx
            if not (0 <= nz < D and 0 <= nx < W):
                continue
            for dy in (0, 1, -1):
                ny = y + dy
                if not (1 <= ny < H - 2) or not stand[nz, ny, nx]:
                    continue
                if dy == 1 and not half[nz, ny, nx] and not pas[z, y + 2, x]:       # head room to jump
                    continue
                step = int(cell_cost[nz, ny, nx]) + (1 if dy else 0)
                ng = g + step
                nc = (nz, ny, nx)
                if ng < cost.get(nc, 1 << 30):
                    cost[nc] = ng
                    came[nc] = c
                    heapq.heappush(openq, (ng + h(nc), ng, nc))
    return None


def nearest_stand(stand, z, y, x, r=3):
    D, H, W = stand.shape
    best = None
    for dz in range(-r, r + 1):
        for dx in range(-r, r + 1):
            for dy in range(-2, 3):
                c = (z + dz, y + dy, x + dx)
                if 0 <= c[0] < D and 1 <= c[1] < H - 2 and 0 <= c[2] < W and stand[c]:
                    d = abs(dz) + abs(dx) + abs(dy) * 0.5
                    if best is None or d < best[0]:
                        best = (d, c)
    return best[1] if best else None


def loop_through(stand, pas, cost, half, waypoints):
    """Closed walk visiting waypoints in order and back to the first; skipped ones are returned."""
    pts = []
    skipped = []
    seq = [w for w in waypoints]
    cur = seq[0]
    visited = [cur]
    for w in seq[1:] + [seq[0]]:
        p = astar(stand, pas, cost, half, cur, w)
        if p is None:
            if w is not seq[0]:
                skipped.append(w)
                continue
            return None, skipped
        pts.extend(p[:-1])
        cur = w
        visited.append(w)
    if len(pts) < 4:
        return None, skipped
    return pts, skipped


def euler_tour(cells, start, budget):
    """Out-and-back walk over a BFS tree of 4-connected (|dy|<=1) cells, at most `budget` points."""
    cellset = set(cells)
    order = []
    seen = {start}
    tree = {start: []}
    queue = [start]
    qi = 0
    while qi < len(queue) and len(seen) < budget // 2:
        c = queue[qi]
        qi += 1
        z, y, x = c
        for dz, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            for dy in (0, 1, -1):
                n = (z + dz, y + dy, x + dx)
                if n in cellset and n not in seen:
                    seen.add(n)
                    tree[c].append(n)
                    tree[n] = []
                    queue.append(n)
                    break
    def walk(c):
        order.append(c)
        for k in tree[c]:
            walk(k)
            order.append(c)
    sys.setrecursionlimit(100000)
    walk(start)
    return order[:-1]


def open_ground(stand, pas, half, cz, cx, R):
    """Largest set of stand cells within R of (cz, cx) connected on foot (top stand cell of each column)."""
    D, H, W = stand.shape
    z0, z1, x0, x1 = max(0, cz - R), min(D, cz + R + 1), max(0, cx - R), min(W, cx + R + 1)
    sub = stand[z0:z1, :, x0:x1]
    has = sub.any(axis=1)
    ys = H - 1 - np.argmax(sub[:, ::-1, :], axis=1)
    cells = {(int(z) + z0, int(ys[z, x]), int(x) + x0) for z, x in zip(*np.nonzero(has))}
    seen = set()
    best = None
    for c in cells:
        if c in seen:
            continue
        comp = [c]
        seen.add(c)
        i = 0
        while i < len(comp):
            z, y, x = comp[i]
            i += 1
            for dz, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                for dy in (0, 1, -1):
                    n = (z + dz, y + dy, x + dx)
                    if n in cells and n not in seen and (dy != 1 or half[n] or pas[z, y + 2, x]):
                        seen.add(n)
                        comp.append(n)
        if best is None or len(comp) > len(best):
            best = comp
    return best


def find_routes(gids, states, luts, surf, pois, box, centre):
    (ox, oy, oz), (W, H, D) = box["origin"], box["size"]
    stand, pas, onpath, onfarm, half, cost, swim = walk_grid(gids, states, luts)
    names = [bn.short(k[0]) for k in states.keys]
    bed_lut = np.array([bn.is_bed(n) for n in names])
    job_lut = np.array([bn.is_job_site(n) for n in names])
    bell_lut = np.array([n == "bell" for n in names])
    way_lut = bed_lut | job_lut | bell_lut
    door_lut = np.array([n.endswith("_door") and not n.endswith("trapdoor") and dict(k[1]).get("half") == "lower"
                         for n, k in zip(names, states.keys)])
    loops = []
    notes = []
    bells = list(zip(*np.nonzero(bell_lut[gids])))
    if bells:
        beds = list(zip(*np.nonzero(bed_lut[gids])))
        jobs = list(zip(*np.nonzero(job_lut[gids])))
        for bz, by, bx in bells[:4]:
            start = nearest_stand(stand, bz, by, bx)
            if start is None:
                notes.append(f"bell at volume ({bx},{by},{bz}) has nowhere to stand beside it")
                continue
            wps = []
            for (z, y, x) in beds + jobs:
                if abs(x - bx) > 72 or abs(z - bz) > 72:
                    continue
                s = nearest_stand(stand, z, y, x, 2)
                if s is not None and s not in wps:
                    wps.append(s)
            # Beds come in two halves: keep waypoints at least 3 apart.
            dedup = []
            for w in wps:
                if all(abs(w[0] - d[0]) + abs(w[2] - d[2]) >= 3 for d in dedup):
                    dedup.append(w)
            dedup.sort(key=lambda w: np.arctan2(w[0] - start[0], w[2] - start[2]))
            groups = [dedup[i:i + 5] for i in range(0, len(dedup), 5)] or [[]]
            for g in groups:
                if not g:
                    continue
                pts, skipped = loop_through(stand, pas, cost, half, [start] + g)
                if skipped:
                    notes.append(f"{len(skipped)} village waypoints unreachable on foot from the bell")
                if pts:
                    loops.append((0, pts))
        if not loops:
            notes.append("bells found but no village loop could be walked")
    if not loops:
        # Path networks.
        pcells = list(zip(*np.nonzero(stand & onpath)))
        if pcells:
            comps = []
            cellset = set(pcells)
            seen = set()
            for c in pcells:
                if c in seen:
                    continue
                comp = []
                stack = [c]
                seen.add(c)
                while stack:
                    z, y, x = stack.pop()
                    comp.append((z, y, x))
                    for dz, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                        for dy in (0, 1, -1):
                            n = (z + dz, y + dy, x + dx)
                            if n in cellset and n not in seen:
                                seen.add(n)
                                stack.append(n)
                comps.append(comp)
            comps.sort(key=len, reverse=True)
            for comp in comps[:6]:
                if len(comp) < 12:
                    break
                walk = euler_tour(comp, comp[0], 800)
                loops.append((1, walk))
            if loops:
                notes.append(f"no bell: loops follow {len(loops)} path networks ({len(pcells)} path cells)")
    if not loops:
        notes.append("no village and no paths: loops over open ground near the centre")
        comp = open_ground(stand & ~swim, pas, half, centre[1], centre[0], 64)
        if comp is None:
            raise BakeError("no stand cell within 64 blocks of the centre")
        P = np.array(comp)
        c = P.mean(axis=0)
        notes.append(f"open ground: {len(comp)} connected stand cells around ({c[2]:.0f}, {c[0]:.0f}) in volume space")
        for r in (8, 14, 22):
            wps = []
            for ang in np.linspace(0, 2 * np.pi, 9)[:-1]:
                tx, tz = c[2] + r * np.cos(ang), c[0] + r * np.sin(ang)
                k = int(np.argmin((P[:, 2] - tx) ** 2 + (P[:, 0] - tz) ** 2))
                w = tuple(int(v) for v in P[k])
                if w not in wps:
                    wps.append(w)
            if len(wps) >= 3:
                pts, skipped = loop_through(stand, pas, cost, half, wps)
                if pts:
                    loops.append((2, pts))
    if not loops:
        raise BakeError("no walkable loop at all near the centre: " + "; ".join(notes))
    # Flags and table. Standing height: how far below y the feet are (sixteenths) on what is
    # under them, and how far above y on what is in the feet cell (thin snow).
    drop_lut = np.array([bn.foot_drop(k[0], k[1]) for k in states.keys], np.int64)
    rise_lut = np.array([bn.foot_rise(k[0], k[1]) for k in states.keys], np.int64)
    total = 0
    out = []
    for kind, pts in loops:
        if total + len(pts) > 16000:
            notes.append("route points capped at 16000")
            break
        flags = []
        for (z, y, x) in pts:
            f = 0
            if onpath[z, y, x]:
                f |= 1
            if onfarm[z, y, x]:
                f |= 2
            zs, ys_, xs = slice(max(0, z - 1), z + 2), slice(max(0, y - 1), y + 2), slice(max(0, x - 1), x + 2)
            if way_lut[gids[zs, ys_, xs]].any():
                f |= 4
            f |= int(drop_lut[gids[z, y - 1, x]]) << 4
            f |= int(rise_lut[gids[z, y, x]]) << 8
            if door_lut[gids[z, y, x]]:
                f |= 8                  # feet in a door's lower cell: the look opens it
            if swim[z, y, x]:
                f |= 1 << 12            # swimming: feet in the top water cell
            flags.append(f)
        out.append((kind, pts, flags))
        total += len(pts)
    # Check the contract: steps of one in x or z, |dy| <= 1, closed.
    for kind, pts, _ in out:
        for a, b in zip(pts, pts[1:] + pts[:1]):
            if abs(a[0] - b[0]) + abs(a[2] - b[2]) != 1 or abs(a[1] - b[1]) > 1:
                raise BakeError(f"route step {a} -> {b} breaks the format")
    rule = {0: "village", 1: "path", 2: "open-ground"}[out[0][0]]
    return out, rule, notes


# ---------------------------------------------------------------- writing

def write_routes(path, routes):
    header = [len(routes), sum(len(p) for _, p, _ in routes)]
    table = []
    pts = []
    first = 0
    for kind, p, flags in routes:
        table += [first, len(p), kind, 0]
        for (z, y, x), f in zip(p, flags):
            pts += [x, y, z, f]
        first += len(p)
    arr = np.array(header + table + pts, "<u2")
    arr.tofile(path)


def metal_text(name, box, sea, nmat, far, center, day_time, pois, routes, extra):
    (ox, oy, oz), (W, H, D) = box["origin"], box["size"]
    kinds = {"cluster": 0, "structure": 1, "bell": 2, "hilltop": 3, "shore": 4, "lit": 5}
    L = [f"// Baked Minecraft world \"{name}\" for Lerping. Generated by scripts/minecraft-world/bake.py; do not edit.",
         "// Volume space: blocks, 0..MCW_SIZE; see scripts/minecraft-world/FORMAT.md.",
         f"#define MCW_NAME \"{name}\"",
         f"constant int3   MCW_SIZE       = int3({W}, {H}, {D});",
         f"constant int3   MCW_ORIGIN     = int3({ox}, {oy}, {oz});",
         f"constant int    MCW_SEA_LEVEL  = {sea};",
         f"constant int    MCW_MATERIALS  = {nmat};",
         f"constant int2   MCW_FAR_SIZE   = int2({far['size'][0]}, {far['size'][1]});",
         f"constant int2   MCW_FAR_ORIGIN = int2({far['origin'][0] - ox}, {far['origin'][1] - oz});",
         f"constant int    MCW_FAR_MIN_Y  = {far['min_y'] - oy};",
         f"constant float3 MCW_CENTER     = float3({center[0]:.2f}, {center[1]:.2f}, {center[2]:.2f});",
         f"constant float  MCW_DAY_TIME   = {float(day_time):.1f};",
         "#define MCW_POI_CLUSTER   0",
         "#define MCW_POI_STRUCTURE 1",
         "#define MCW_POI_BELL      2",
         "#define MCW_POI_HILLTOP   3",
         "#define MCW_POI_SHORE     4",
         "#define MCW_POI_LIT       5",
         f"constant int    MCW_POI_COUNT = {len(pois)};",
         "constant float4 MCW_POI[] = {"]
    L += [f"    float4({p['pos'][0]:.2f}, {p['pos'][1]:.2f}, {p['pos'][2]:.2f}, {p['radius']:.2f}),  // {p['kind']}: {p['note']}"
          for p in pois]
    L += ["};", "constant int    MCW_POI_KIND[] = {" + ", ".join(str(kinds[p["kind"]]) for p in pois) + "};"]
    L += ["// From each point toward a good camera (horizontal unit vector; 0 = any side), and its box.",
          "constant float4 MCW_POI_VIEW[] = {" + ", ".join(
              f"float4({p['view'][0]:.4f}, {p['view'][1]:.4f}, {p['view'][2]:.4f}, 0.0)" for p in pois) + "};",
          "constant float4 MCW_POI_BOX_MIN[] = {" + ", ".join(
              f"float4({p['box'][0][0]}, {p['box'][0][1]}, {p['box'][0][2]}, 0)" for p in pois) + "};",
          "constant float4 MCW_POI_BOX_MAX[] = {" + ", ".join(
              f"float4({p['box'][1][0]}, {p['box'][1][1]}, {p['box'][1][2]}, 0)" for p in pois) + "};"]
    L += [f"constant int     MCW_ROUTE_COUNT = {len(routes)};", "constant ushort4 MCW_ROUTES[] = {"]
    first = 0
    for kind, p, _ in routes:
        L.append(f"    ushort4({first}, {len(p)}, {kind}, 0),")
        first += len(p)
    L += ["};", f"constant int     MCW_ROUTE_POINT_COUNT = {first};", "constant ushort4 MCW_ROUTE_POINTS[] = {"]
    flat = []
    for kind, p, flags in routes:
        for (z, y, x), f in zip(p, flags):
            flat.append(f"ushort4({x},{y},{z},{f})")
    for i in range(0, len(flat), 8):
        L.append("    " + ", ".join(flat[i:i + 8]) + ",")
    L.append("};")
    L += extra
    # A look uses a few of these; the rest must not warn.
    L = [("[[maybe_unused]] " + l) if l.startswith("constant ") else l for l in L]
    return "\n".join(L) + "\n"


def swap_in(new_dir, final_dir):
    """Put the finished bake at final_dir in one step: an atomic exchange of the two folders
    (macOS renamex_np RENAME_SWAP), then the old one is deleted; a plain rename the first time."""
    if not os.path.exists(final_dir):
        os.rename(new_dir, final_dir)
        return
    libc = ctypes.CDLL(None, use_errno=True)
    RENAME_SWAP = 0x00000002
    if libc.renamex_np(new_dir.encode(), final_dir.encode(), RENAME_SWAP) != 0:
        err = ctypes.get_errno()
        raise BakeError(f"could not swap the new bake into {final_dir}: {os.strerror(err)} (it is in {new_dir})")
    shutil.rmtree(new_dir)          # now holds the previous bake


def sea_level(jar):
    with zipfile.ZipFile(jar) as z:
        d = json.loads(z.read("data/minecraft/worldgen/noise_settings/overworld.json"))
    return int(d["sea_level"])


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("save")
    ap.add_argument("name")
    ap.add_argument("--center", default="auto")
    ap.add_argument("--size", type=int, default=384)
    ap.add_argument("--max-height", type=int, default=192)
    ap.add_argument("--far-size", type=int, default=2048)
    ap.add_argument("--jar", default=DEFAULT_JAR)
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    out_dir = args.out or os.path.join(WORLDS_DIR, args.name)
    save_path = os.path.abspath(args.save)
    if os.path.abspath(out_dir).startswith(os.path.join(SUPPORT, "minecraft")):
        raise BakeError("refusing to write inside the game's folder")
    # Everything is written to a folder beside the world and swapped in whole at the end, so a
    # look or the runtime reading the world while it bakes sees the old one or the new one.
    final_dir = os.path.abspath(out_dir)
    os.makedirs(os.path.dirname(final_dir), exist_ok=True)
    out_dir = os.path.join(os.path.dirname(final_dir), f".{os.path.basename(final_dir)}.baking-{os.getpid()}")
    if os.path.exists(out_dir):
        shutil.rmtree(out_dir)
    os.makedirs(out_dir)

    save = anvil.Save(save_path)
    say(f"save {save.level_name!r}: data version {save.data_version} ({save.game_version}), seed {save.seed}, "
        f"spawn {save.spawn}, player {save.player}")
    if save.seed is None:
        raise BakeError("no seed in the save: the biome jitter needs it")
    table = load_table(args.jar)
    states = States(table)
    biomes = biomecolor.Biomes(args.jar)
    breg = BiomeRegistry(biomes)
    sea = sea_level(args.jar)

    summ = Summary(save, states, breg)
    say(f"chunks: {summ.chunks_in_save} in the save, {summ.n_full} finished; statuses {summ.status}"
        + (f"; {summ.outside_square} outside the generated square ignored" if save.generated else ""))
    if save.generated:
        g = save.generated
        if g.get("seed") != save.seed:
            raise BakeError(f"lerping-generate.json seed {g.get('seed')} != the save's seed {save.seed}")
        say(f"generated save: {g.get('structure')} at ({g.get('x')}, {g.get('z')}), seed {g.get('seed_text')!r} -> {g.get('seed')}, game {g.get('version')}")
    say(f"built blocks near the surface in the whole save: {int(summ.built.sum())}")

    cx, cz, rule, detail = choose_center(args, summ, save)
    say(f"centre ({cx}, {cz}) by rule '{rule}': {detail}")
    box = choose_box(args, summ, cx, cz)
    for n in box["notes"]:
        say("box: " + n)
    (ox, oy, oz), (W, H, D) = box["origin"], box["size"]
    say(f"box: origin {box['origin']}, size {box['size']}")

    gids, above = build_volume(save, states, summ, box)
    mid = np.array(states.mid, np.uint16)[gids]
    nvar = assign_variants(gids, mid, states, table, box["origin"])
    say(f"variants: {nvar} voxels of weighted-variant states given the game's pick")
    luts = material_luts(states, table)
    say(f"volume: {int((mid != 0).sum())} non-air voxels; {len(states.keys)} block states in the save, {len(table)} material ids")

    # Unhandled states, with voxel counts in the volume.
    unhandled = table.unhandled()
    vc = np.bincount(gids.reshape(-1), minlength=len(states.keys))
    by_string = {}
    for i, k in enumerate(states.keys):
        if hasattr(table, "state_key"):
            nm, pk = table.state_key(k[0], dict(k[1]))
            st = f"{nm}[{pk}]" if pk not in (None, "-") else nm
        else:
            st = anvil.state_string(k)
        by_string[st] = by_string.get(st, 0) + int(vc[i])
    by_mid = {}
    for i, k in enumerate(states.keys):
        by_mid[states.mid[i]] = by_mid.get(states.mid[i], 0) + int(vc[i])
    unh = []
    for state, reason in unhandled.items():
        n = by_string.get(state)
        if n is None and isinstance(state, int):
            n = by_mid.get(state)
        unh.append({"state": str(state), "reason": str(reason), "voxels": n})
    unh.sort(key=lambda u: -(u["voxels"] or 0))

    skip = skip_field(mid)
    blocks = (mid.astype(np.uint16) & 0x0FFF) | (skip.astype(np.uint16) << 12)
    say("skip distance done")

    light, n_emit, groups = bake_light(mid, gids, luts, states, above, box)
    say(f"light done: {n_emit} emitters in {len(groups)} colours")

    # Surfaces in the volume (volume y), used by tints, POIs and routes.
    nonair = mid != 0
    pure = np.array([bn.short(k[0]) in bn.PURE_FLUIDS for k in states.keys])[gids]
    surf_any = top_index(nonair.transpose(1, 0, 2))
    surf = top_index((nonair & ~pure).transpose(1, 0, 2))

    ycol = np.where(surf_any >= 0, surf_any + oy, oy)
    layers, unknown, bnames, swamp = column_tints(summ, breg, save.seed, ox, oz, W, D, ycol)
    tints = np.zeros((4, D, W, 4), np.uint8)
    col_exists = summ.exists[oz - summ.z0:oz - summ.z0 + D, ox - summ.x0:ox - summ.x0 + W]
    for li, a in enumerate(layers):
        if ((a < 0) & col_exists).any():
            raise BakeError(f"tint layer {li}: {int(((a < 0) & col_exists).sum())} columns of finished chunks with no biome")
        # Columns of chunks the save does not have hold no colour (a = 0); they are air.
        tints[li, ..., :3] = int_to_rgb(np.maximum(a, 0)) * col_exists[..., None]
        tints[li, ..., 3] = np.where(col_exists, 255, 0)
    say(f"tints: biomes {bnames}; swamp noise used: {swamp}; samples outside the save: {unknown}")

    far_rg, far_rgba, far_info = bake_far(args, summ, states, luts, table, breg, save.seed, box)
    say(f"far field: origin {far_info['origin']}, size {far_info['size']}, {far_info['chunks']} chunks, "
        f"{far_info['missing_columns']} columns missing")

    pois, built_cnt = find_pois(mid, gids, states, luts, light, surf, surf_any, box)
    say(f"points of interest: {len(pois)}: " + ", ".join(f"{p['kind']}" for p in pois))
    centre_xz = (min(max(cx - ox, 0), W - 1), min(max(cz - oz, 0), D - 1))
    routes, route_rule, route_notes = find_routes(gids, states, luts, surf, pois, box, centre_xz)
    for n in route_notes:
        say("routes: " + n)
    say(f"routes: {len(routes)} loops, {sum(len(p) for _, p, _ in routes)} points, rule {route_rule}")

    # Places and mobs.
    try:
        beds, jobs, bells, doors = village.places(gids, states)
        stop_list = village.stops(routes, beds, jobs, bells)
        mob_list, mob_skipped = village.mobs(save, box, save.generated["chunks"] if save.generated else None)
        home, job, claim_rule = village.claims(mob_list, beds, jobs, stop_list, box)
    except village.TableError as e:
        raise BakeError(str(e))
    door_steps = {}
    for r, (_, pts, _) in enumerate(routes):
        for j, (z, y, x) in enumerate(pts):
            door_steps.setdefault((x, y, z), []).append([r, j])
    for d in doors:
        d["route_steps"] = door_steps.get(tuple(d["cell"]), [])
    kinds = {}
    for m in mob_list:
        kinds[m["id"]] = kinds.get(m["id"], 0) + 1
    say(f"places: {len(beds)} beds, {len(jobs)} job sites, {len(bells)} bells, {len(doors)} doors "
        f"({sum(1 for d in doors if d['route_steps'])} on a route), {len(stop_list)} stops")
    say(f"mobs: {len(mob_list)} in the box {kinds}; claims: {claim_rule['home']}")
    if mob_skipped:
        say("entities not in the table: " + ", ".join(f"{k} x{v}" for k, v in sorted(mob_skipped.items())))

    # Write.
    files = {}

    def put(name, arr):
        p = os.path.join(out_dir, name)
        arr.tofile(p)
        files[name] = os.path.getsize(p)
    put("blocks.r16", blocks.astype("<u2"))
    put("light.rgba8", light)
    put("tints.rgba8", tints)
    put("far.rg16", far_rg.astype("<u2"))
    put("far.rgba8", far_rgba)
    write_routes(os.path.join(out_dir, "routes.u16"), routes)
    files["routes.u16"] = os.path.getsize(os.path.join(out_dir, "routes.u16"))
    table.write(out_dir)
    for f in sorted(os.listdir(out_dir)):
        if (f.startswith("materials.") or f.startswith("elements.")) and f not in files:
            files[f] = os.path.getsize(os.path.join(out_dir, f))
    centre_v = (cx - ox + 0.5, float(surf[min(max(cz - oz, 0), D - 1), min(max(cx - ox, 0), W - 1)] + 1), cz - oz + 0.5)
    day_time = (save.day_time or 0) % 24000
    metal = metal_text(args.name, box, sea, luts["n"], far_info, centre_v, day_time, pois, routes,
                       village.metal(beds, jobs, bells, doors, stop_list, mob_list, home, job))
    with open(os.path.join(out_dir, "world.metal"), "w") as f:
        f.write(metal)
    files["world.metal"] = os.path.getsize(os.path.join(out_dir, "world.metal"))

    atlas_txt = os.path.join(ATLAS_DIR, "atlas.txt")
    with open(atlas_txt, "rb") as f:
        atlas_hash = hashlib.sha256(f.read()).hexdigest()
    built_names = {}
    for i, k in enumerate(states.keys):
        if bn.is_built(k[0]) and vc[i]:
            built_names[bn.short(k[0])] = built_names.get(bn.short(k[0]), 0) + int(vc[i])
    meta = {
        "version": FORMAT_VERSION,
        "name": args.name,
        "source": {"save": save_path, "level_name": save.level_name, "seed": save.seed,
                   "data_version": save.data_version, "game_version": save.game_version,
                   "spawn": list(save.spawn) if save.spawn else None,
                   "player": [round(v, 2) for v in save.player] if save.player else None,
                   "generated": ({"version": save.generated.get("version"), "seed": save.generated.get("seed"),
                                  "seed_text": save.generated.get("seed_text"),
                                  "structure": save.generated.get("structure"),
                                  "structure_at": [save.generated.get("x"), save.generated.get("z")],
                                  "square_chunks": save.generated.get("chunks")} if save.generated else None)},
        "size": [W, H, D],
        "origin": [ox, oy, oz],
        "sea_level": sea,
        "day_time": day_time,
        "center": {"x": cx, "y": int(centre_v[1] + oy), "z": cz, "rule": rule, "detail": detail},
        "vertical": {"content_min_y": box["content"][0], "content_max_y": box["content"][1],
                     "capped": box["capped"], **box["cut"]},
        "box_notes": box["notes"],
        "chunks": {"in_box": (W // 16) * (D // 16) - box["missing_chunks"], "missing_in_box": box["missing_chunks"],
                   "in_save": summ.chunks_in_save, "finished_in_save": summ.n_full, "statuses": summ.status,
                   "in_far": far_info["chunks"]},
        "counts": {"non_air": int((mid != 0).sum()), "materials": int((np.bincount(mid.reshape(-1))[1:] > 0).sum()),
                   "material_ids": luts["n"], "emitters": n_emit, "light_colours": groups,
                   "water": int((luts["fluid"][mid] == 1).sum()), "lava": int((luts["fluid"][mid] == 2).sum()),
                   "built_near_surface_in_save": int(summ.built.sum()),
                   "built_in_box": dict(sorted(built_names.items(), key=lambda t: -t[1]))},
        "atlas": {"hash": atlas_hash, "path": ATLAS_DIR},
        "materials": {"count": luts["n"] - 1, "unhandled": unh},
        "tints": {"biomes": bnames, "swamp_noise": swamp, "blend_radius": 2},
        "far": far_info,
        "poi": pois,
        "routes": {"loops": len(routes), "points": sum(len(p) for _, p, _ in routes), "rule": route_rule,
                   "notes": route_notes},
        "places": {"beds": beds, "jobs": jobs, "bells": bells, "doors": doors,
                   "stops": [list(s_) for s_ in stop_list]},
        "mobs": {"list": [dict(m, home=home[i], job=job[i]) for i, m in enumerate(mob_list)],
                 "claims": claim_rule, "kinds": village.MOB_KINDS,
                 "not_in_table": dict(sorted(mob_skipped.items()))},
        "files": files,
        "bake": {"seconds": round(time.time() - T0, 1),
                 "date": datetime.datetime.now().astimezone().isoformat(timespec="seconds")},
    }
    with open(os.path.join(out_dir, "world.json.tmp"), "w") as f:
        json.dump(meta, f, indent=1)
    os.replace(os.path.join(out_dir, "world.json.tmp"), os.path.join(out_dir, "world.json"))
    swap_in(out_dir, final_dir)
    out_dir = final_dir
    say(f"unhandled block states: {len(unh)}" + "".join(f"\n    {u['voxels']:>8} {u['state']}: {u['reason']}" for u in unh[:40]))
    say("files: " + ", ".join(f"{k} {v / 1e6:.2f} MB" for k, v in files.items()))
    say(f"wrote {out_dir}")


if __name__ == "__main__":
    try:
        main()
    except BakeError as e:
        print(f"bake failed: {e}", file=sys.stderr)
        sys.exit(1)
    finally:
        # A failed bake leaves the world it was replacing untouched; drop its half-written folder.
        import glob as _glob
        for d in _glob.glob(os.path.join(WORLDS_DIR, f".*.baking-{os.getpid()}")):
            shutil.rmtree(d, ignore_errors=True)
