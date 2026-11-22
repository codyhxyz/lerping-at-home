"""The game's biome colours: grass, foliage and water per block column.

Read from the installed jar, the way the client computes them (checked
against the 26.2 classes with javap):

- `Biome.getGrassColorFromTexture`: temperature and downfall (floats) clamped
  to 0..1, then `ColorMapColorUtil.get`: downfall *= temperature,
  x = (int)((1 - temperature) * 255), y = (int)((1 - downfall) * 255),
  pixel y * 256 + x of `colormap/grass.png` (foliage the same with
  `foliage.png`, dry foliage with `dry_foliage.png`). A biome's
  `grass_color` / `foliage_color` / `dry_foliage_color` replaces it.
- `GrassColorModifier`: `dark_forest` is ((c & 0xFEFEFE) + 0x28340A) >> 1;
  `swamp` ignores c and is 0x4C763C where `BIOME_INFO_NOISE` (one octave of
  `SimplexNoise` seeded by `LegacyRandomSource(2345)`) at
  (x * 0.0225, z * 0.0225) is below -0.1, else 0x6A7039.
- `BiomeManager.getBiome`: the block's biome is one of the 8 surrounding
  4x4x4 cells, chosen by a seeded jitter (`getFiddledDistance`), the seed
  being sha256 of the world seed.
- Blend: the client averages the 8-bit channels over the (2r+1)^2 columns
  around a block, r = 2 by default, with integer division.
"""

import hashlib
import io
import json
import struct
import zipfile

import numpy as np
from PIL import Image

MASK48 = (1 << 48) - 1


# ---------------------------------------------------------------- Java randoms

class LegacyRandom:
    def __init__(self, seed):
        self.seed = (seed ^ 0x5DEECE66D) & MASK48

    def next(self, bits):
        self.seed = (self.seed * 0x5DEECE66D + 0xB) & MASK48
        v = self.seed >> (48 - bits)
        if bits == 32 and v & (1 << 31):     # (int) cast: only a 32-bit draw can be negative
            v -= 1 << 32
        return v

    def next_int(self, bound):
        if bound & (bound - 1) == 0:
            return (bound * (self.next(31) & 0x7FFFFFFF)) >> 31
        while True:
            sample = self.next(31) & 0x7FFFFFFF
            modulo = sample % bound
            if sample - modulo + (bound - 1) < (1 << 31):
                return modulo

    def next_double(self):
        hi = self.next(26) & ((1 << 26) - 1)
        lo = self.next(27) & ((1 << 27) - 1)
        return ((hi << 27) + lo) * (1.0 / (1 << 53))


class Simplex2D:
    GRAD = np.array([[1, 1], [-1, 1], [1, -1], [-1, -1], [1, 0], [-1, 0], [1, 0], [-1, 0],
                     [0, 1], [0, -1], [0, 1], [0, -1]], dtype=np.float64)
    F2 = 0.5 * (np.sqrt(3.0) - 1.0)
    G2 = (3.0 - np.sqrt(3.0)) / 6.0

    def __init__(self, rnd):
        self.xo = rnd.next_double() * 256.0
        self.yo = rnd.next_double() * 256.0
        self.zo = rnd.next_double() * 256.0
        p = list(range(256))
        for i in range(256):
            off = rnd.next_int(256 - i)
            p[i], p[off + i] = p[off + i], p[i]
        self.p = np.array(p, dtype=np.int64)

    def value(self, x, y):
        x = np.asarray(x, dtype=np.float64)
        y = np.asarray(y, dtype=np.float64)
        s = (x + y) * self.F2
        i = np.floor(x + s).astype(np.int64)
        j = np.floor(y + s).astype(np.int64)
        t = (i + j) * self.G2
        x0 = x - (i - t)
        y0 = y - (j - t)
        i1 = (x0 > y0).astype(np.int64)
        j1 = 1 - i1
        x1 = x0 - i1 + self.G2
        y1 = y0 - j1 + self.G2
        x2 = x0 - 1.0 + 2.0 * self.G2
        y2 = y0 - 1.0 + 2.0 * self.G2
        ii = i & 255
        jj = j & 255
        P = lambda v: self.p[v & 255]
        gi0 = P(ii + P(jj)) % 12
        gi1 = P(ii + i1 + P(jj + j1)) % 12
        gi2 = P(ii + 1 + P(jj + 1)) % 12

        def corner(gi, cx, cy):
            t0 = 0.5 - cx * cx - cy * cy
            g = self.GRAD[gi]
            dot = g[..., 0] * cx + g[..., 1] * cy
            return np.where(t0 < 0, 0.0, (t0 * t0) * (t0 * t0) * dot)
        return 70.0 * (corner(gi0, x0, y0) + corner(gi1, x1, y1) + corner(gi2, x2, y2))


_BIOME_INFO_NOISE = None


def swamp_grass(x, z):
    global _BIOME_INFO_NOISE
    if _BIOME_INFO_NOISE is None:
        _BIOME_INFO_NOISE = Simplex2D(LegacyRandom(2345))
    v = _BIOME_INFO_NOISE.value(np.asarray(x) * 0.0225, np.asarray(z) * 0.0225)
    return np.where(v < -0.1, 0x4C763C, 0x6A7039).astype(np.int64)


# ---------------------------------------------------------------- biome zoom

def zoom_seed(world_seed):
    """BiomeManager.obfuscateSeed: Guava sha256().hashLong(seed).asLong()."""
    h = hashlib.sha256(struct.pack("<q", world_seed)).digest()
    return struct.unpack("<q", h[:8])[0]


_M = np.int64(6364136223846793005)
_A = np.int64(1442695040888963407)


def _lcg(r, c):
    with np.errstate(over="ignore"):
        return r * (r * _M + _A) + c


def _fiddle(r):
    return (((r >> 24) & 1023).astype(np.float64) / 1024.0 - 0.5) * 0.9


def zoomed_cells(seed, X, Y, Z):
    """Quart cell (qx, qy, qz) whose biome the game uses at blocks (X, Y, Z)."""
    X = np.asarray(X, np.int64) - 2
    Y = np.asarray(Y, np.int64) - 2
    Z = np.asarray(Z, np.int64) - 2
    px, py, pz = X >> 2, Y >> 2, Z >> 2
    fx, fy, fz = (X & 3) / 4.0, (Y & 3) / 4.0, (Z & 3) / 4.0
    s = np.int64(seed)
    best = np.full(X.shape, np.inf)
    bi = np.zeros(X.shape, np.int64)
    for i in range(8):
        cx = px + ((i >> 2) & 1)
        cy = py + ((i >> 1) & 1)
        cz = pz + (i & 1)
        dx = fx - ((i >> 2) & 1)
        dy = fy - ((i >> 1) & 1)
        dz = fz - (i & 1)
        r = _lcg(s, cx)
        r = _lcg(r, cy)
        r = _lcg(r, cz)
        r = _lcg(r, cx)
        r = _lcg(r, cy)
        r = _lcg(r, cz)
        ffx = _fiddle(r)
        r = _lcg(r, s)
        ffy = _fiddle(r)
        r = _lcg(r, s)
        ffz = _fiddle(r)
        d = (dz + ffz) ** 2 + (dy + ffy) ** 2 + (dx + ffx) ** 2
        better = best > d
        best = np.where(better, d, best)
        bi = np.where(better, i, bi)
    return px + ((bi >> 2) & 1), py + ((bi >> 1) & 1), pz + (bi & 1)


# ---------------------------------------------------------------- biome table

def _hex(s):
    return int(s.lstrip("#"), 16)


class Biomes:
    """Every overworld biome's colours, from the jar."""

    def __init__(self, jar_path):
        self.jar = zipfile.ZipFile(jar_path)
        self.grass_map = self._colormap("assets/minecraft/textures/colormap/grass.png")
        self.foliage_map = self._colormap("assets/minecraft/textures/colormap/foliage.png")
        self.dry_map = self._colormap("assets/minecraft/textures/colormap/dry_foliage.png")
        self.defs = {}
        prefix = "data/minecraft/worldgen/biome/"
        for n in self.jar.namelist():
            if n.startswith(prefix) and n.endswith(".json") and "/" not in n[len(prefix):]:
                self.defs["minecraft:" + n[len(prefix):-5]] = json.loads(self.jar.read(n))

    def _colormap(self, path):
        im = Image.open(io.BytesIO(self.jar.read(path))).convert("RGB")
        if im.size != (256, 256):
            raise ValueError(f"{path} is {im.size}, expected 256x256")
        a = np.asarray(im, dtype=np.int64)
        return (a[..., 0] << 16) | (a[..., 1] << 8) | a[..., 2]      # [y, x]

    def _from_map(self, cmap, temperature, downfall, default):
        t = float(np.clip(np.float32(temperature), 0, 1))
        d = float(np.clip(np.float32(downfall), 0, 1))
        d *= t
        x = int((1.0 - t) * 255.0)
        y = int((1.0 - d) * 255.0)
        if (y << 8 | x) >= 65536:
            return default
        return int(cmap[y, x])

    def colours(self, name):
        """(grass, foliage, water, dry_foliage, grass_modifier) as 0xRRGGBB ints."""
        d = self.defs.get(name)
        if d is None:
            raise KeyError(f"biome {name} is not in the jar's data/minecraft/worldgen/biome")
        eff = d.get("effects", {})
        t, df = d["temperature"], d["downfall"]
        grass = _hex(eff["grass_color"]) if "grass_color" in eff else self._from_map(self.grass_map, t, df, 0xFF00FF)
        foliage = _hex(eff["foliage_color"]) if "foliage_color" in eff else self._from_map(self.foliage_map, t, df, 0x48B518)
        dry = _hex(eff["dry_foliage_color"]) if "dry_foliage_color" in eff else self._from_map(self.dry_map, t, df, 0)
        water = _hex(eff["water_color"]) if "water_color" in eff else None
        if water is None:
            raise KeyError(f"biome {name} has no water_color")
        mod = eff.get("grass_color_modifier", "none")
        if mod == "dark_forest":
            grass = ((grass & 0xFEFEFE) + 0x28340A) >> 1
        elif mod not in ("none", "swamp"):
            raise ValueError(f"biome {name}: unknown grass_color_modifier {mod}")
        return grass, foliage, water, dry, mod


def blend(rgb_int, radius=2):
    """Mean of 8-bit channels over (2r+1)^2 columns, integer division; rgb_int [D, W] ints, -1 = unknown.

    Returns (blended [D, W] ints, unknown-sample count per column)."""
    D, W = rgb_int.shape
    known = rgb_int >= 0
    out = []
    for shift in (16, 8, 0):
        ch = np.where(known, (rgb_int >> shift) & 255, 0)
        out.append(ch)
    n = known.astype(np.int64)
    k = 2 * radius + 1

    def boxsum(a):
        p = np.pad(a, radius)
        c = np.cumsum(np.cumsum(p, 0), 1)
        c = np.pad(c, ((1, 0), (1, 0)))
        return c[k:, k:] - c[:-k, k:] - c[k:, :-k] + c[:-k, :-k]
    cnt = boxsum(n)
    res = np.zeros((D, W), np.int64)
    for ch, shift in zip(out, (16, 8, 0)):
        s = boxsum(ch)
        res |= (np.where(cnt > 0, s // np.maximum(cnt, 1), 0) & 255) << shift
    res = np.where(cnt > 0, res, -1)
    return res, (k * k - cnt)
