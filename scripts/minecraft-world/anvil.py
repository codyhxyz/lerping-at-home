"""Read a Minecraft 26.x save: region files, chunk NBT, level data.

Read only. Nothing here writes into a save. Layout of a 26.x save:

    level.dat                                 gzip NBT: Data.LevelName, Data.DataVersion, Data.Version.Name, spawn
    data/minecraft/world_gen_settings.dat     gzip NBT: the seed
    data/minecraft/world_clocks.dat           gzip NBT: time of day
    players/data/<uuid>.dat                   gzip NBT: each player's Pos
    dimensions/minecraft/overworld/region/r.X.Z.mca

A region file holds 32 x 32 chunks: a 4 KiB table of (3-byte sector offset,
1-byte sector count), a 4 KiB table of timestamps, then each chunk as
(u32 length, u8 compression, payload) in 4 KiB sectors. Compression 1 is gzip,
2 zlib, 3 none, 4 LZ4; +128 means the payload is in c.X.Z.mcc beside it.

A chunk's NBT has `sections`, one per 16-block slice of y, each with
`block_states` and `biomes` as (palette, packed long array). Entries do not
span longs (since 1.16): a long holds floor(64 / bits) entries from its low
bits up. Block states use at least 4 bits; biomes at least 1; a palette of one
entry has no data.
"""

import gzip
import json
import os
import struct
import zlib

import numpy as np

# NBT tag ids.
END, BYTE, SHORT, INT, LONG, FLOAT, DOUBLE, BYTE_ARRAY, STRING, LIST, COMPOUND, INT_ARRAY, LONG_ARRAY = range(13)


class NBTError(Exception):
    pass


def _read_string(buf, pos):
    (n,) = struct.unpack_from(">H", buf, pos)
    pos += 2
    return bytes(buf[pos:pos + n]).decode("utf-8", "surrogateescape"), pos + n


def _read_payload(buf, pos, tag):
    if tag == COMPOUND:
        out = {}
        while True:
            t = buf[pos]
            pos += 1
            if t == END:
                return out, pos
            name, pos = _read_string(buf, pos)
            out[name], pos = _read_payload(buf, pos, t)
    if tag == STRING:
        return _read_string(buf, pos)
    if tag == BYTE:
        return struct.unpack_from(">b", buf, pos)[0], pos + 1
    if tag == SHORT:
        return struct.unpack_from(">h", buf, pos)[0], pos + 2
    if tag == INT:
        return struct.unpack_from(">i", buf, pos)[0], pos + 4
    if tag == LONG:
        return struct.unpack_from(">q", buf, pos)[0], pos + 8
    if tag == FLOAT:
        return struct.unpack_from(">f", buf, pos)[0], pos + 4
    if tag == DOUBLE:
        return struct.unpack_from(">d", buf, pos)[0], pos + 8
    if tag == LIST:
        t = buf[pos]
        (n,) = struct.unpack_from(">i", buf, pos + 1)
        pos += 5
        items = []
        for _ in range(n):
            v, pos = _read_payload(buf, pos, t)
            items.append(v)
        return items, pos
    if tag == BYTE_ARRAY:
        (n,) = struct.unpack_from(">i", buf, pos)
        pos += 4
        return np.frombuffer(buf, ">i1", n, pos), pos + n
    if tag == INT_ARRAY:
        (n,) = struct.unpack_from(">i", buf, pos)
        pos += 4
        return np.frombuffer(buf, ">i4", n, pos), pos + 4 * n
    if tag == LONG_ARRAY:
        (n,) = struct.unpack_from(">i", buf, pos)
        pos += 4
        return np.frombuffer(buf, ">u8", n, pos), pos + 8 * n
    raise NBTError(f"unknown NBT tag {tag} at {pos}")


def parse_nbt(data):
    """Parse uncompressed NBT bytes; returns the root compound."""
    buf = memoryview(data)
    tag = buf[0]
    if tag != COMPOUND:
        raise NBTError(f"root tag is {tag}, not a compound")
    _, pos = _read_string(buf, 1)
    root, _ = _read_payload(buf, pos, COMPOUND)
    return root


def read_gzip_nbt(path):
    with open(path, "rb") as f:
        raw = f.read()
    if raw[:2] == b"\x1f\x8b":
        raw = gzip.decompress(raw)
    return parse_nbt(raw)


# ---------------------------------------------------------------- regions

class Region:
    """One r.X.Z.mca file. `chunks()` lists the local (cx, cz) present."""

    def __init__(self, path):
        self.path = path
        base = os.path.basename(path)
        _, rx, rz, _ = base.split(".")
        self.rx, self.rz = int(rx), int(rz)
        with open(path, "rb") as f:
            self.data = f.read()
        if len(self.data) < 8192:
            self.table = np.zeros(1024, dtype=np.uint32)
        else:
            self.table = np.frombuffer(self.data, ">u4", 1024, 0).astype(np.uint32)

    def chunks(self):
        out = []
        for i in np.nonzero(self.table)[0]:
            out.append((int(i) % 32, int(i) // 32))
        return out

    def read(self, lx, lz):
        """NBT root of local chunk (lx, lz), or None if absent."""
        entry = int(self.table[lx + 32 * lz])
        if entry == 0:
            return None
        offset = (entry >> 8) * 4096
        (length,) = struct.unpack_from(">I", self.data, offset)
        kind = self.data[offset + 4]
        payload = self.data[offset + 5: offset + 4 + length]
        if kind & 128:
            cx, cz = self.rx * 32 + lx, self.rz * 32 + lz
            ext = os.path.join(os.path.dirname(self.path), f"c.{cx}.{cz}.mcc")
            with open(ext, "rb") as f:
                payload = f.read()
            kind &= 127
        if kind == 2:
            raw = zlib.decompress(payload)
        elif kind == 1:
            raw = gzip.decompress(payload)
        elif kind == 3:
            raw = bytes(payload)
        else:
            raise NBTError(f"{self.path} chunk ({lx},{lz}): compression {kind} is not supported (LZ4 needs a library we do not have)")
        return parse_nbt(raw)


class Dimension:
    """All region files of one dimension, addressed by world chunk (cx, cz)."""

    def __init__(self, region_dir):
        if not os.path.isdir(region_dir):
            raise FileNotFoundError(f"no region folder at {region_dir}")
        self.dir = region_dir
        self.regions = {}
        for name in os.listdir(region_dir):
            if name.startswith("r.") and name.endswith(".mca"):
                r = Region(os.path.join(region_dir, name))
                self.regions[(r.rx, r.rz)] = r

    def chunk_coords(self):
        out = []
        for (rx, rz), r in self.regions.items():
            for lx, lz in r.chunks():
                out.append((rx * 32 + lx, rz * 32 + lz))
        return sorted(out)

    def read(self, cx, cz):
        r = self.regions.get((cx >> 5, cz >> 5))
        if r is None:
            return None
        return r.read(cx & 31, cz & 31)


# ---------------------------------------------------------------- packed arrays

def unpack(longs, bits, count):
    """Unpack `count` entries of `bits` bits from a long array (no spanning)."""
    per = 64 // bits
    longs = np.asarray(longs, dtype=np.uint64)
    shifts = (np.arange(per, dtype=np.uint64) * np.uint64(bits))
    mask = np.uint64((1 << bits) - 1)
    vals = (longs[:, None] >> shifts[None, :]) & mask
    flat = vals.reshape(-1)
    if flat.size < count:
        raise NBTError(f"packed array too short: {flat.size} < {count} at {bits} bits")
    return flat[:count]


def bits_for(n, minimum):
    return max(minimum, int(n - 1).bit_length())


def section_blocks(sec):
    """(palette list of compounds, uint16[4096] indices in y,z,x order) for a section, or None."""
    bs = sec.get("block_states")
    if bs is None:
        return None
    pal = bs["palette"]
    if len(pal) == 1 or "data" not in bs:
        return pal, np.zeros(4096, dtype=np.uint16)
    bits = bits_for(len(pal), 4)
    idx = unpack(bs["data"], bits, 4096).astype(np.uint16)
    if idx.max() >= len(pal):
        raise NBTError(f"block index {idx.max()} past palette of {len(pal)}")
    return pal, idx


def section_biomes(sec):
    """(palette list of names, uint8[64] indices in y,z,x order over 4x4x4 cells), or None."""
    b = sec.get("biomes")
    if b is None:
        return None
    pal = b["palette"]
    if len(pal) == 1 or "data" not in b:
        return pal, np.zeros(64, dtype=np.uint8)
    bits = bits_for(len(pal), 1)
    return pal, unpack(b["data"], bits, 64).astype(np.uint8)


def heightmap(chunk, name, min_y):
    """A chunk heightmap as int array [16 z, 16 x] of world y of the top face (y of highest block + 1)."""
    hm = chunk.get("Heightmaps", {}).get(name)
    if hm is None:
        return None
    # 9 bits for a 384-tall world: values are (top + 1 - min_y).
    vals = unpack(hm, 9, 256).astype(np.int32)
    return (vals + min_y).reshape(16, 16)


def state_key(entry):
    """Hashable block state from a palette compound: (name, ((k, v), ...))."""
    props = entry.get("Properties")
    if props:
        return entry["Name"], tuple(sorted(props.items()))
    return entry["Name"], ()


def state_string(key):
    name, props = key
    if not props:
        return name
    return name + "[" + ",".join(f"{k}={v}" for k, v in props) + "]"


# ---------------------------------------------------------------- level data

def _first(d, *paths):
    for p in paths:
        cur = d
        ok = True
        for k in p:
            if isinstance(cur, dict) and k in cur:
                cur = cur[k]
            else:
                ok = False
                break
        if ok:
            return cur
    return None


class Save:
    """A save folder: level data, players, seed, the overworld."""

    def __init__(self, path):
        self.path = os.path.abspath(path)
        level_path = os.path.join(self.path, "level.dat")
        if not os.path.isfile(level_path):
            raise FileNotFoundError(f"no level.dat in {self.path}")
        root = read_gzip_nbt(level_path)
        self.level = root.get("Data", root)
        d = self.level
        self.level_name = d.get("LevelName", os.path.basename(self.path))
        self.data_version = d.get("DataVersion")
        self.game_version = _first(d, ("Version", "Name"))
        spawn = _first(d, ("spawn", "pos"))
        if spawn is not None:
            self.spawn = tuple(int(v) for v in spawn)
        elif "SpawnX" in d:
            self.spawn = (d["SpawnX"], d["SpawnY"], d["SpawnZ"])
        else:
            self.spawn = None
        # A save written by generate.sh says which square it generated deterministically.
        gen = os.path.join(self.path, "lerping-generate.json")
        self.generated = json.load(open(gen)) if os.path.isfile(gen) else None
        self.seed = self._seed()
        self.day_time = self._day_time()
        self.player = self._player()
        region = os.path.join(self.path, "dimensions", "minecraft", "overworld", "region")
        if not os.path.isdir(region):
            region = os.path.join(self.path, "region")      # pre-26 layout
        self.overworld = Dimension(region)

    def _data_file(self, name):
        p = os.path.join(self.path, "data", "minecraft", name)
        return read_gzip_nbt(p) if os.path.isfile(p) else None

    def _seed(self):
        s = _first(self.level, ("WorldGenSettings", "seed"), ("RandomSeed",))
        if s is not None:
            return int(s)
        wg = self._data_file("world_gen_settings.dat")
        if wg is not None:
            s = _first(wg, ("data", "seed"), ("seed",))
            if s is not None:
                return int(s)
        return None

    def _day_time(self):
        t = self.level.get("DayTime")
        if t is not None:
            return int(t)
        clocks = self._data_file("world_clocks.dat")
        if clocks is None:
            return None
        self.clocks_raw = clocks
        # Find the overworld clock's total ticks wherever it sits.
        found = []

        def walk(node, path):
            if isinstance(node, dict):
                for k, v in node.items():
                    walk(v, path + (k,))
            elif isinstance(node, (int,)) and not isinstance(node, bool):
                found.append((path, node))
        walk(clocks, ())
        for path, v in found:
            if "overworld" in "/".join(path) and path[-1] in ("total_ticks", "ticks", "time"):
                return int(v)
        return None

    def _player(self):
        pos = _first(self.level, ("Player", "Pos"))
        if pos is not None:
            return tuple(float(v) for v in pos)
        pdir = os.path.join(self.path, "players", "data")
        if not os.path.isdir(pdir):
            return None
        best = None
        for name in os.listdir(pdir):
            if not name.endswith(".dat"):
                continue
            p = os.path.join(pdir, name)
            nbt = read_gzip_nbt(p)
            pos = nbt.get("Pos")
            dim = nbt.get("Dimension", "minecraft:overworld")
            if pos is None or dim != "minecraft:overworld":
                continue
            m = os.path.getmtime(p)
            if best is None or m > best[0]:
                best = (m, tuple(float(v) for v in pos))
        return best[1] if best else None
