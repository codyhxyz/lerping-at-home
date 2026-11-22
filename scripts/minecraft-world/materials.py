"""Block states -> drawing recipes, from the game's own data.

A `Table` turns a block state found in a save into a material: the exact
faces the game draws for it (its blockstate JSON, model JSON with parents,
texture variables, elements, face uv / rotation / tint / cullface, element
rotation, the blockstate's x/y/z rotation and uvlock), with every texture
resolved to a layer of the packed atlas (`atlas.txt`). What the game knows only
in code (light emission and dampening, full opaque cubes, fluids, tint
sources, occlusion, plant offsets, the model baker's rotation matrices) comes
from running the jar's own classes headless (`BlockDump.java`), cached per jar.

`write(out_dir)` writes `materials.u32`, `elements.u32` and `materials.json`;
the byte layout and the shader decode are in FORMAT.md, "Materials and
elements". Nothing here is drawn as a stand-in: a state that cannot be drawn
exactly is listed by `unhandled()` with the reason, and draws nothing.

    table = materials.Table(jar_path, atlas_dir)
    mid = table.resolve("minecraft:oak_stairs", {"facing": "east", ...}, pos=(x, y, z))
"""

import hashlib
import io
import json
import math
import os
import re
import struct
import subprocess
import sys
import tempfile
import zipfile

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
DUMP_VERSION = 2

DIRS = ["down", "up", "north", "south", "west", "east"]
DIR_INDEX = {d: i for i, d in enumerate(DIRS)}
DIR_VEC = [(0, -1, 0), (0, 1, 0), (0, 0, -1), (0, 0, 1), (-1, 0, 0), (1, 0, 0)]

# The game's FaceInfo: for each face, its four corners as (x from/to, y, z),
# 0 = from (min), 1 = to (max), in vertex order 0..3.
FACE_INFO = {
    "down":  [(0, 0, 1), (0, 0, 0), (1, 0, 0), (1, 0, 1)],
    "up":    [(0, 1, 0), (0, 1, 1), (1, 1, 1), (1, 1, 0)],
    "north": [(1, 1, 0), (1, 0, 0), (0, 0, 0), (0, 1, 0)],
    "south": [(0, 1, 1), (0, 0, 1), (1, 0, 1), (1, 1, 1)],
    "west":  [(0, 1, 0), (0, 0, 0), (0, 0, 1), (0, 1, 1)],
    "east":  [(1, 1, 1), (1, 0, 1), (1, 0, 0), (1, 1, 0)],
}

TINT_CODES = {None: 0, "grass": 1, "foliage": 2, "water": 3, "dry_foliage": 4}
KIND_EMPTY, KIND_CUBE, KIND_ELEMENTS = 0, 1, 2
MAX_ELEMENTS = 64
MAX_ELEMENT_ROWS = 16384
MAX_MATERIALS = 4096
MAT_WORDS, ELEM_WORDS = 32, 80

F_OPAQUE, F_CUTOUT, F_TRANSLUCENT, F_FULLBRIGHT, F_NO_AO = 1 << 2, 1 << 3, 1 << 4, 1 << 5, 1 << 6
F_ENTITY, F_SHADOW = 1 << 22, 1 << 23
RENDER_SOLID, RENDER_CUTOUT, RENDER_TRANSLUCENT = 0, 1, 2


class Unhandled(Exception):
    """A state the table cannot draw exactly; the message is the reason."""


def fail(message):
    sys.stderr.write("materials: " + message + "\n")
    sys.exit(1)


# ---------------------------------------------------------------- the game's code

def _java_and_classpath(jar_path):
    """The launcher's Java and the version's libraries (as scripts/minecraft-mobs/build.sh finds them)."""
    jar_path = os.path.abspath(jar_path)
    version_json = jar_path[:-4] + ".json"
    if not os.path.exists(version_json):
        raise RuntimeError(f"no version JSON beside the jar ({version_json})")
    mc = os.path.dirname(os.path.dirname(os.path.dirname(jar_path)))
    j = json.load(open(version_json))
    paths = [jar_path]
    for lib in j.get("libraries", []):
        a = lib.get("downloads", {}).get("artifact")
        if not a or "natives" in a["path"]:
            continue
        p = os.path.join(mc, "libraries", a["path"])
        if os.path.exists(p):
            paths.append(p)
    need = j.get("javaVersion", {}).get("majorVersion", 21)
    candidates = []
    if os.environ.get("JAVA_HOME"):
        candidates.append(os.path.join(os.environ["JAVA_HOME"], "bin", "java"))
    runtime = os.path.join(mc, "runtime")
    for root, dirs, files in os.walk(runtime):
        if root.endswith("/bin") and "java" in files:
            candidates.append(os.path.join(root, "java"))
    for c in candidates:
        if not os.access(c, os.X_OK):
            continue
        out = subprocess.run([c, "-XshowSettings:properties", "-version"], capture_output=True, text=True).stderr
        m = re.search(r"java\.specification\.version = (?:1\.)?(\d+)", out)
        if not m or int(m.group(1)) < need:
            continue
        mods = subprocess.run([c, "--list-modules"], capture_output=True, text=True).stdout
        if "jdk.compiler@" not in mods:
            continue
        return c, ":".join(paths)
    raise RuntimeError(f"no Java {need} or newer with jdk.compiler (set JAVA_HOME, or start the game once so the launcher installs its runtime)")


def load_dump(jar_path, cache_dir):
    """BlockDump.java's output for this jar, run once and cached beside the atlas."""
    st = os.stat(jar_path)
    src = open(os.path.join(HERE, "BlockDump.java"), "rb").read()
    key = hashlib.sha256(f"{DUMP_VERSION}|{os.path.abspath(jar_path)}|{st.st_size}|{int(st.st_mtime)}|".encode() + src).hexdigest()[:16]
    cache = os.path.join(cache_dir, f"blockdump-{key}.txt")
    if os.path.exists(cache):
        return open(cache).read()
    java, cp = _java_and_classpath(jar_path)
    with tempfile.TemporaryDirectory(prefix="minecraft-world-") as tmp:   # Bootstrap writes logs into the cwd
        r = subprocess.run([java, "-cp", cp, os.path.join(HERE, "BlockDump.java")], cwd=tmp, capture_output=True, text=True)
    if r.returncode != 0:
        line = next((l for l in r.stderr.splitlines() if l.startswith("minecraft-world:")), None)
        err = next((l for l in r.stderr.splitlines() if "error:" in l), None)
        raise RuntimeError(line or (f"BlockDump does not compile against this jar ({err})" if err else "BlockDump failed: " + r.stderr[-400:]))
    os.makedirs(cache_dir, exist_ok=True)
    tmp = cache + ".tmp"
    open(tmp, "w").write(r.stdout)
    os.replace(tmp, cache)
    for old in os.listdir(cache_dir):          # dumps of an older jar or dumper
        if old.startswith("blockdump-") and old.endswith(".txt") and os.path.join(cache_dir, old) != cache:
            os.remove(os.path.join(cache_dir, old))
    return r.stdout


class StateInfo:
    __slots__ = ("emission", "dampening", "solid", "occlude", "sky_down", "shape", "fullbright", "fluid",
                 "amount", "falling", "self_skip", "face_full", "offset", "max_h", "max_v", "shade",
                 "block_entity", "collision", "tints")


def parse_dump(text):
    states, matrices, rng, offsets, entity_lines = {}, {}, [], [], []
    for line in text.splitlines():
        f = line.split("\t")
        if f[0] == "S":
            s = StateInfo()
            (s.emission, s.dampening, s.solid, s.occlude, s.sky_down) = (int(f[3]), int(f[4]), f[5] == "1", f[6] == "1", f[7] == "1")
            s.shape, s.fullbright, s.fluid = f[8], f[9] == "1", f[10]
            s.amount, s.falling, s.self_skip, s.face_full = int(f[11]), f[12] == "1", int(f[13]), int(f[14])
            s.offset, s.max_h, s.max_v, s.shade = f[15], float(f[16]), float(f[17]), float(f[18])
            s.block_entity, s.collision = f[19] == "1", f[20] == "1"
            s.tints = {}
            states[(f[1], f[2])] = s
        elif f[0] == "T":
            states[(f[1], f[2])].tints[int(f[3])] = (f[4], f[5])
        elif f[0] == "M":
            vals = [[float(v) for v in col.split(",")] for col in f[5:]]
            def m4(v):   # JOML get(column, row) order -> row-major 4x4
                return np.array(v, dtype=np.float64).reshape(4, 4).T
            matrices[(int(f[1]), int(f[2]), int(f[3]), f[4] == "1")] = (m4(vals[0]), [m4(v) for v in vals[1:]])
        elif f[0] == "G":
            rng.append(tuple(int(v) for v in f[1:]))
        elif f[0] == "O":
            offsets.append((f[1], int(f[2]), int(f[3]), int(f[4]), float(f[5]), float(f[6]), float(f[7])))
        elif f[0] in "PQXKD":
            entity_lines.append(f)
    return states, matrices, rng, offsets, entity_lines


# ---------------------------------------------------------------- the game's random numbers

def _s64(v):
    v &= (1 << 64) - 1
    return v - (1 << 64) if v >> 63 else v


def _s32(v):
    v &= 0xFFFFFFFF
    return v - (1 << 32) if v >> 31 else v


def mth_get_seed(x, y, z):
    """net.minecraft.util.Mth.getSeed(x, y, z)."""
    l = _s64(_s32(x * 3129871)) ^ _s64(z * 116129781) ^ y
    l = _s64(l * l * 42317861 + l * 11)
    return l >> 16


class LegacyRandom:
    """The renderer's RandomSource (the java.util.Random LCG), as far as the model code uses it."""
    M = (1 << 48) - 1

    def __init__(self, seed):
        self.s = (seed ^ 0x5DEECE66D) & self.M

    def _next(self, bits):
        self.s = (self.s * 0x5DEECE66D + 0xB) & self.M
        v = self.s >> (48 - bits)
        return _s32(v) if bits == 32 else v

    def next_int(self, bound):
        if bound & (bound - 1) == 0:
            return _s32((bound * self._next(31)) >> 31)
        while True:
            bits = self._next(31)
            val = bits % bound
            if bits - val + (bound - 1) < (1 << 31):
                return val

    def next_long(self):
        return _s64((self._next(32) << 32) + self._next(32))


def _pick_weighted(entries, rnd):
    total = sum(e.get("weight", 1) for e in entries)
    i = rnd.next_int(total)
    for e in entries:
        i -= e.get("weight", 1)
        if i < 0:
            return e
    raise AssertionError("weighted pick ran past the list")


# ---------------------------------------------------------------- the atlas

ATLAS_LINE = re.compile(r"^(\S+)\s+(tiles|skins|items|maps)\[(\d+)\]\s+(\S+)(?:\s+(\d+)x(\d+))?(?:\s+(\d+) frames, (\d+) ticks each)?\s*$")


class AtlasEntry:
    __slots__ = ("name", "array", "layer", "path", "w", "h", "frames", "ticks")


def parse_atlas(text):
    entries = {}
    for line in text.splitlines():
        if not line or line.startswith("#"):
            continue
        m = ATLAS_LINE.match(line)
        if not m:
            raise RuntimeError(f"atlas.txt line not understood: {line!r}")
        e = AtlasEntry()
        e.name, e.array, e.layer, e.path = m.group(1), m.group(2), int(m.group(3)), m.group(4)
        if e.array == "tiles":
            e.w = e.h = 16
        elif m.group(5):
            e.w, e.h = int(m.group(5)), int(m.group(6))
        else:
            e.w = e.h = 16
        e.frames = int(m.group(7)) if m.group(7) else 1
        e.ticks = int(m.group(8)) if m.group(8) else 1
        entries[e.path] = e
    return entries


# ---------------------------------------------------------------- geometry helpers

def rot_axis(axis, deg):
    """org.joml.Matrix4f.rotation(angle, unit axis), as a 3x3."""
    a = math.radians(deg)
    c, s = math.cos(a), math.sin(a)
    if axis == "x":
        return np.array([[1, 0, 0], [0, c, -s], [0, s, c]])
    if axis == "y":
        return np.array([[c, 0, s], [0, 1, 0], [-s, 0, c]])
    return np.array([[c, -s, 0], [s, c, 0], [0, 0, 1]])


def element_rotation(rot):
    """CuboidRotation: (origin in block units, 3x3 transform) or None for none / identity."""
    if not rot:
        return None
    origin = np.array(rot.get("origin", [8, 8, 8]), dtype=np.float64) / 16.0
    if "axis" in rot:
        if float(rot["angle"]) == 0:
            return None
        m = rot_axis(rot["axis"], float(rot["angle"]))
    else:
        m = rot_axis("z", float(rot.get("z", 0))) @ rot_axis("y", float(rot.get("y", 0))) @ rot_axis("x", float(rot.get("x", 0)))
    if np.allclose(m, np.eye(3), atol=1e-7):
        return None
    if rot.get("rescale", False):
        scale = []
        for k in range(3):
            v = np.abs(m[:, k])
            scale.append(1.0 / v.max())
        m = m @ np.diag(scale)
    return origin, m


def nearest_dir(v):
    best, bd = None, 0.0
    for i, d in enumerate(DIR_VEC):
        dot = v[0] * d[0] + v[1] * d[1] + v[2] * d[2]
        if dot >= 0 and dot > bd:
            bd, best = dot, i
    return best


def fit_plane(points, values, normal):
    """Affine f(p) = dot(a, p) + b through three points of a face, with no slope along the normal."""
    p0, p1, p3 = points[0], points[1], points[3]
    e1, e2 = p1 - p0, p3 - p0
    A = np.array([e1, e2, normal])
    if abs(np.linalg.det(A)) < 1e-12:
        return None
    a = np.linalg.solve(A, np.array([values[1] - values[0], values[3] - values[0], 0.0]))
    return a, values[0] - a @ p0


def f32bits(v):
    return struct.unpack("<I", struct.pack("<f", float(v)))[0]


def srgb_to_linear(c):
    c = np.asarray(c, dtype=np.float64) / 255.0
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(c):
    c = np.clip(np.asarray(c, dtype=np.float64), 0, 1)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * c ** (1 / 2.4) - 0.055)


# ---------------------------------------------------------------- the table

class Face:
    """One baked face, ready for a record."""
    __slots__ = ("dir", "tex", "entry", "plane_u", "plane_v", "render", "tint", "shade", "emission", "cullface",
                 "full_d4", "uvrect")


class Element:
    __slots__ = ("lo", "hi", "xform", "faces", "source")


class Material:
    __slots__ = ("words", "elements", "opaque", "light_filter", "emission", "fluid", "map_color", "tint_kind",
                 "states", "key", "kind", "entity", "unhandled")


class Table:
    def __init__(self, jar_path, atlas_dir, max_materials=MAX_MATERIALS):
        self.max_materials = max_materials
        self.jar_path = os.path.abspath(os.path.expanduser(jar_path))
        self.atlas_dir = os.path.abspath(os.path.expanduser(atlas_dir))
        self.zip = zipfile.ZipFile(self.jar_path)
        atlas_txt = open(os.path.join(self.atlas_dir, "atlas.txt"), "rb").read()
        self.atlas_hash = hashlib.sha256(atlas_txt).hexdigest()
        self.atlas = parse_atlas(atlas_txt.decode())
        dump = load_dump(self.jar_path, self.atlas_dir)
        self.info, self.matrices, self.rng_checks, self.offset_checks, self.entity_lines = parse_dump(dump)
        self._check_rng()
        self._blockstates = {}
        self._models = {}
        self._png = {}
        self._transparency = {}
        self._materials = [self._air()]
        self._by_key = {}
        self._resolved = {}
        self._unhandled = {}
        self._cull_groups = {}
        from entities import EntityModels   # block-entity geometry (chests, bells, banners ...)
        self.entities = EntityModels(self, sys.modules[__name__])

    # ---- checks that our copies of the game's maths agree with the game
    def _check_rng(self):
        for (x, y, z, seed, p4, p16, p6, ml) in self.rng_checks:
            s = mth_get_seed(x, y, z)
            got = (s, LegacyRandom(s).next_int(4), LegacyRandom(s).next_int(16), LegacyRandom(s).next_int(6), LegacyRandom(s).next_long())
            if got != (seed, p4, p16, p6, ml):
                raise RuntimeError(f"the renderer's random numbers do not match the game's at {(x, y, z)}: {got} vs {(seed, p4, p16, p6, ml)}")
        for (name, x, y, z, dx, dy, dz) in self.offset_checks:
            info = next(v for (n, _), v in self.info.items() if n == name and v.offset != "none")
            got = plant_offset(x, z, info.offset, info.max_h, info.max_v)
            if max(abs(got[0] - dx), abs(got[1] - dy), abs(got[2] - dz)) > 1e-6:
                raise RuntimeError(f"plant offset of {name} at {(x, y, z)}: {got} vs the game's {(dx, dy, dz)}")

    # ---- jar access
    def _json(self, path):
        try:
            return json.loads(self.zip.read(path))
        except KeyError:
            return None

    def blockstate(self, name):
        if name not in self._blockstates:
            ns, path = name.split(":", 1)
            self._blockstates[name] = self._json(f"assets/{ns}/blockstates/{path}.json")
        return self._blockstates[name]

    def png(self, tex):
        """RGBA uint8 array of assets/minecraft/textures/<tex>.png (the whole strip)."""
        if tex not in self._png:
            ns, path = tex.split(":", 1) if ":" in tex else ("minecraft", tex)
            data = self.zip.read(f"assets/{ns}/textures/{path}.png")
            self._png[tex] = np.array(Image.open(io.BytesIO(data)).convert("RGBA"))
        return self._png[tex]

    def model(self, name):
        """A model with its parent chain merged: textures, elements, ambientocclusion."""
        name = name if ":" in name else "minecraft:" + name
        if name in self._models:
            return self._models[name]
        chain, n = [], name
        while n:
            ns, path = n.split(":", 1)
            m = self._json(f"assets/{ns}/models/{path}.json")
            if m is None:
                raise Unhandled(f"model {n} is not in the jar")
            chain.append(m)
            p = m.get("parent")
            n = (p if ":" in p else "minecraft:" + p) if p else None
            if len(chain) > 32:
                raise Unhandled(f"model {name} has a parent loop")
        textures, elements, ao = {}, None, True
        for m in reversed(chain):            # root first, child overrides
            textures.update(m.get("textures", {}))
            if "elements" in m:
                elements = m["elements"]
            if "ambientocclusion" in m:
                ao = m["ambientocclusion"]
        merged = {"textures": textures, "elements": elements or [], "ao": ao, "name": name}
        self._models[name] = merged
        return merged

    def texture_of(self, model, ref):
        """Resolve a face's '#var' through the model's texture map: (texture path, force_translucent)."""
        # A face names a slot, with or without '#' (TextureSlots.getMaterial strips it);
        # a slot's value is a sprite, or '#other' for another slot.
        seen = set()
        force = False
        ref = ref if ref.startswith("#") else "#" + ref
        while True:
            if isinstance(ref, dict):
                force = force or ref.get("force_translucent", False)
                ref = ref["sprite"]
            if not ref.startswith("#"):
                tex = ref if ":" in ref else "minecraft:" + ref
                return tex, force
            var = ref[1:]
            if var in seen or var not in model["textures"]:
                raise Unhandled(f"model {model['name']} leaves texture {ref} unset (the game draws its missing texture)")
            seen.add(var)
            ref = model["textures"][var]

    def atlas_entry(self, tex):
        path = tex.split(":", 1)[1] + ".png"
        e = self.atlas.get(path)
        if e is None:
            raise Unhandled(f"texture {tex} is not in the packed atlas")
        if e.array not in ("tiles", "skins"):
            raise Unhandled(f"texture {tex} is in {e.array}, which materials do not address")
        return e

    def transparency(self, tex, entry, rect):
        """The game's per-quad rule: (has alpha 0, has alpha strictly between) over the uv rect, all frames."""
        key = (tex, rect)
        if key in self._transparency:
            return self._transparency[key]
        img = self.png(tex)
        fw, fh = entry.w, entry.h
        u0, v0, u1, v1 = rect
        x0, y0 = math.floor(u0 * fw), math.floor(v0 * fh)
        x1, y1 = math.ceil(u1 * fw), math.ceil(v1 * fh)
        frames = img.shape[0] // fh
        transparent = translucent = False
        for f in range(frames):
            a = img[f * fh + y0: f * fh + y1, x0:x1, 3]
            transparent = transparent or bool((a == 0).any())
            translucent = translucent or bool(((a > 0) & (a < 255)).any())
        self._transparency[key] = (transparent, translucent)
        return transparent, translucent

    # ---- blockstate -> model parts
    def _props_key(self, name, props):
        info_props = [k for (n, k) in self.info if n == name]
        return info_props

    def state_key(self, name, props):
        """The game's property string for a state, in the game's order."""
        name = name if ":" in name else "minecraft:" + name
        props = {k: str(v).lower() if isinstance(v, bool) else str(v) for k, v in (props or {}).items()}
        # The dump writes properties in the game's order; find the matching line.
        if not hasattr(self, "_prop_orders"):
            self._build_prop_orders()
        cand = self._prop_orders.get(name)
        if cand is None:
            return name, None
        if not cand and not props:
            return name, "-"
        if set(cand) != set(props):
            return name, None
        return name, ",".join(f"{k}={props[k]}" for k in cand)

    def _build_prop_orders(self):
        self._prop_orders = {}
        for (n, p) in self.info:
            if n not in self._prop_orders:
                self._prop_orders[n] = [] if p == "-" else [kv.split("=", 1)[0] for kv in p.split(",")]

    def _parts(self, name, props):
        """The blockstate's model entries for a state: a list of lists (each inner list is one weighted choice)."""
        bs = self.blockstate(name)
        if bs is None:
            raise Unhandled(f"no blockstate file for {name}")
        def as_list(v):
            return v if isinstance(v, list) else [v]
        if "variants" in bs:
            for key, v in bs["variants"].items():
                if key == "" or all(props.get(k) == val for k, val in (kv.split("=", 1) for kv in key.split(","))):
                    return "variants", [as_list(v)]
            raise Unhandled(f"no variant of {name} matches {props}")
        parts = []
        for part in bs["multipart"]:
            if "when" not in part or _when(part["when"], props):
                parts.append(as_list(part["apply"]))
        return "multipart", parts

    def parts(self, name, props):
        """The blockstate's model entries for a state (see FORMAT.md, Python side)."""
        name = name if ":" in name else "minecraft:" + name
        return self._parts(name, {k: str(v).lower() if isinstance(v, bool) else str(v) for k, v in (props or {}).items()})

    def needs_pos(self, name, props):
        name = name if ":" in name else "minecraft:" + name
        try:
            _, parts = self._parts(name, {k: str(v).lower() if isinstance(v, bool) else str(v) for k, v in props.items()})
        except Unhandled:
            return False
        return any(len(p) > 1 for p in parts)

    # ---- the public interface
    def resolve(self, name, props=None, pos=None):
        name = name if ":" in name else "minecraft:" + name
        if name in ("minecraft:air", "minecraft:cave_air", "minecraft:void_air"):
            return 0
        props = {k: str(v).lower() if isinstance(v, bool) else str(v) for k, v in (props or {}).items()}
        name, pkey = self.state_key(name, props)
        state = f"{name}[{pkey}]" if pkey not in (None, "-") else name
        if pkey is None:
            return self._unhandled_id(state, f"not a block state of this game version ({name} {props})")
        info = self.info[(name, pkey)]
        try:
            kind, parts = self._parts(name, props)
        except Unhandled as e:
            if info.shape == "INVISIBLE" or name in ("minecraft:air", "minecraft:cave_air", "minecraft:void_air"):
                kind, parts = "variants", []
            else:
                return self._unhandled_id(state, str(e))
        choice = []
        if any(len(p) > 1 for p in parts):
            if pos is None:
                raise ValueError(f"{state} has random model variants: pass pos=(x, y, z) (see table.needs_pos)")
            seed = mth_get_seed(*pos)
            if kind == "multipart":
                seed = LegacyRandom(seed).next_long()
            for p in parts:
                if len(p) > 1:
                    e = _pick_weighted(p, LegacyRandom(seed))
                    choice.append(p.index(e))
                else:
                    choice.append(0)
        else:
            choice = [0] * len(parts)
        ckey = (name, pkey, tuple(choice))
        if ckey in self._resolved:
            return self._resolved[ckey]
        chosen = [p[c] for p, c in zip(parts, choice)]
        try:
            mat = self._build(name, pkey, props, info, chosen)
        except Unhandled as e:
            mid = self._unhandled_id(state, str(e), info)
            self._resolved[ckey] = mid
            return mid
        variant = f" variant {choice}" if any(len(p) > 1 for p in parts) else ""
        mid = self._intern(mat, state + variant)
        self._resolved[ckey] = mid
        return mid

    def opaque(self, mid):
        return self._materials[mid].opaque

    def light_filter(self, mid):
        return self._materials[mid].light_filter

    def emission(self, mid):
        return self._materials[mid].emission

    def fluid(self, mid):
        return self._materials[mid].fluid

    def map_color(self, mid):
        return self._materials[mid].map_color

    def tint_kind(self, mid):
        return self._materials[mid].tint_kind

    def unhandled(self):
        return dict(self._unhandled)

    def state_names(self, mid):
        return list(self._materials[mid].states)

    def __len__(self):
        return len(self._materials)

    # ---- building
    def _air(self):
        m = Material()
        m.words = [0] * MAT_WORDS
        m.elements = []
        m.opaque, m.light_filter, m.emission, m.fluid = False, 0, (0, (0.0, 0.0, 0.0)), None
        m.map_color, m.tint_kind, m.states, m.kind, m.entity, m.unhandled = (0, 0, 0), None, ["minecraft:air"], KIND_EMPTY, False, None
        m.key = ("air",)
        # Row 0 carries the fluid textures (FORMAT.md).
        for slot, tex, tint, render in ((8, "minecraft:block/water_still", "water", RENDER_TRANSLUCENT),
                                        (10, "minecraft:block/water_flow", "water", RENDER_TRANSLUCENT),
                                        (12, "minecraft:block/water_overlay", "water", RENDER_TRANSLUCENT),
                                        (14, "minecraft:block/lava_still", None, RENDER_SOLID),
                                        (16, "minecraft:block/lava_flow", None, RENDER_SOLID)):
            e = self.atlas_entry(tex)
            a, b = _descriptor(e, 0, TINT_CODES[tint], render, True, 0, 0)
            m.words[slot], m.words[slot + 1] = a, b
        return m

    def _unhandled_id(self, state, reason, info=None):
        self._unhandled[state] = reason
        m = Material()
        m.words = [0] * MAT_WORDS
        m.elements = []
        m.kind, m.entity, m.unhandled = KIND_EMPTY, False, reason
        m.opaque = bool(info and info.solid)
        m.light_filter = info.dampening if info else 0
        m.emission = (info.emission if info else 0, (1.0, 1.0, 1.0)) if info and info.emission else (0, (0.0, 0.0, 0.0))
        m.fluid = None
        m.map_color, m.tint_kind, m.states = (0, 0, 0), None, []
        if info:
            m.words[0] = F_OPAQUE if info.solid else 0
            m.words[3] = (min(15, info.emission) << 8) | (info.dampening << 12)
            if info.emission:
                # The light still floods (the bake needs it); its colour cannot come from a texture we cannot draw.
                m.emission = (info.emission, (1.0, 1.0, 1.0))
                m.words[6] = 0xFFFFFF
        m.key = ("unhandled", state)
        return self._intern(m, state)

    def _intern(self, mat, state):
        key = mat.key
        if key in self._by_key:
            mid = self._by_key[key]
            self._materials[mid].states.append(state)
            return mid
        mid = len(self._materials)
        if mid >= self.max_materials:
            raise RuntimeError(f"more than {self.max_materials - 1} materials; blocks.r16 has 12 bits of material id")
        mat.states = [state]
        self._materials.append(mat)
        self._by_key[key] = mid
        return mid

    def _bake_parts(self, name, info, chosen):
        """Every face of every chosen model part, in block space: a list of Elements."""
        elements = []
        ao = True
        for entry in chosen:
            model = self.model(entry["model"])
            ao = ao and model["ao"]
            rx, ry, rz = int(entry.get("x", 0)) % 360, int(entry.get("y", 0)) % 360, int(entry.get("z", 0)) % 360
            lock = bool(entry.get("uvlock", False))
            state_m, inv_face = self.matrices[(rx, ry, rz, lock)]
            S = state_m[:3, :3]
            for el in model["elements"]:
                elements.append(self._bake_element(name, info, model, el, S, inv_face))
        return elements, ao

    def _bake_element(self, name, info, model, el, S, inv_face):
        frm = np.array(el["from"], dtype=np.float64)
        to = np.array(el["to"], dtype=np.float64)
        erot = element_rotation(el.get("rotation"))
        state_rotated = not np.allclose(S, np.eye(3))
        xform = erot is not None
        shade = el.get("shade", True)
        light = int(el.get("light_emission", 0))
        out = Element()
        out.faces = {}
        out.source = model["name"]
        center = np.array([0.5, 0.5, 0.5])
        if xform:
            # local -> block: p = S (E (q - o) + o - c) + c ; record the inverse.
            o, E = erot
            A = S @ E
            t = S @ (o - E @ o - center) + center
            Ainv = np.linalg.inv(A)
            out.xform = (Ainv, -Ainv @ t)
            out.lo, out.hi = np.minimum(frm, to) / 16.0, np.maximum(frm, to) / 16.0
        else:
            corners = np.array([[x, y, z] for x in (frm[0], to[0]) for y in (frm[1], to[1]) for z in (frm[2], to[2])]) / 16.0
            moved = (corners - center) @ S.T + center
            out.xform = None
            out.lo, out.hi = moved.min(axis=0), moved.max(axis=0)
        for fname, face in el["faces"].items():
            d = DIR_INDEX[fname]
            uv = face.get("uv")
            if uv is None:
                uv = _default_uv(frm, to, fname)
            minU, minV, maxU, maxV = (float(v) for v in uv)
            quad = (int(face.get("rotation", 0)) // 90) % 4
            tex, force = self.texture_of(model, face["texture"])
            entry = self.atlas_entry(tex)
            pts, us, vs = face_corners(frm, to, fname, (minU, minV, maxU, maxV), quad, inv_face[d])
            if xform:
                space_pts = pts
                fdir = d
                normal = np.array(DIR_VEC[d], dtype=np.float64)
            else:
                space_pts = (pts - center) @ S.T + center
                normal = S @ np.array(DIR_VEC[d], dtype=np.float64)
                fdir = nearest_dir(normal)
            pu = fit_plane(space_pts, np.array(us) * entry.w, normal)
            pv = fit_plane(space_pts, np.array(vs) * entry.h, normal)
            if pu is None or pv is None:
                continue        # a face with no area draws nothing in the game either
            f = Face()
            f.dir, f.tex, f.entry = fdir, tex, entry
            f.plane_u, f.plane_v = pu, pv
            rect = (min(minU, maxU) / 16.0, min(minV, maxV) / 16.0, max(minU, maxU) / 16.0, max(minV, maxV) / 16.0)
            f.uvrect = rect
            if force:
                f.render = RENDER_TRANSLUCENT
            else:
                transparent, translucent = self.transparency(tex, entry, rect)
                f.render = RENDER_TRANSLUCENT if translucent else RENDER_CUTOUT if transparent else RENDER_SOLID
            f.tint = self._tint(name, info, int(face.get("tintindex", -1)))
            f.shade, f.emission = shade, light
            cf = face.get("cullface")
            if cf:
                cd = DIR_INDEX[cf]
                f.cullface = nearest_dir(S @ np.array(DIR_VEC[cd], dtype=np.float64))
            else:
                f.cullface = None
            f.full_d4 = None
            if fdir in out.faces:
                raise Unhandled(f"model {model['name']} has two faces on one side of an element")
            out.faces[fdir] = f
        return out

    def _tint(self, name, info, index):
        if index < 0:
            return None
        src = info.tints.get(index)
        if src is None:
            return None       # the game: no tint source at that index -> colour -1, untinted
        kind, colour = src
        if kind == "none":
            return None
        if kind in ("grass", "foliage", "water", "dry_foliage"):
            return kind
        if kind == "fixed":
            if colour.startswith("error"):
                raise Unhandled(f"the game's fixed tint for {name} index {index} could not be evaluated ({colour})")
            return ("fixed", int(colour, 16) & 0xFFFFFF)
        raise Unhandled(f"tint source {kind} of {name} index {index} is not one materials know")

    def _build(self, name, pkey, props, info, chosen):
        m = Material()
        m.entity = False
        m.unhandled = None
        elements, ao = self._bake_parts(name, info, chosen)
        ent = self.entities.elements(name, props, info)
        if ent is not None:
            elements = elements + ent
            m.entity = True
        elif info.block_entity and not any(e.faces for e in elements):
            raise Unhandled(self.entities.reason(name))
        elements = [e for e in elements if e.faces]
        fluid_name = info.fluid
        fluid = None
        if fluid_name != "none":
            ftype = "water" if "water" in fluid_name else "lava" if "lava" in fluid_name else None
            if ftype is None:
                raise Unhandled(f"fluid {fluid_name} is not water or lava")
            fluid = (ftype, info.amount)
        waterlogged = fluid is not None and bool(elements)
        extra = self.entities.unhandled_part(name, props, info)
        if extra:
            raise Unhandled(extra)

        # Tints: fixed colours get the two fixed slots.
        fixed = []
        for e in elements:
            for f in e.faces.values():
                if isinstance(f.tint, tuple):
                    if f.tint[1] not in fixed:
                        fixed.append(f.tint[1])
        if len(fixed) > 2:
            raise Unhandled(f"{name} uses {len(fixed)} fixed tint colours; a record holds 2")
        def tcode(t):
            if isinstance(t, tuple):
                return 5 + fixed.index(t[1])
            return TINT_CODES[t]

        words = [0] * MAT_WORDS
        cube = _as_cube(elements)
        flags = 0
        if cube is not None:
            kind = KIND_CUBE
            prim, over = cube
            for d in range(6):
                f = prim[d]
                words[8 + 2 * d], words[9 + 2 * d] = _descriptor(f.entry, f.full_d4, tcode(f.tint), f.render, f.shade, f.emission, f.cullface)
                if over.get(d):
                    g = over[d]
                    words[20 + 2 * d], words[21 + 2 * d] = _descriptor(g.entry, g.full_d4, tcode(g.tint), g.render, g.shade, g.emission, g.cullface)
            m.elements = []
        elif elements:
            kind = KIND_ELEMENTS
            if len(elements) > MAX_ELEMENTS:
                raise Unhandled(f"{len(elements)} elements; a material holds at most {MAX_ELEMENTS}")
            m.elements = [_element_words(e, tcode) for e in elements]
        else:
            kind = KIND_EMPTY
            m.elements = []
        renders = {f.render for e in elements for f in e.faces.values()}
        flags |= kind
        if info.solid:
            flags |= F_OPAQUE
        if RENDER_CUTOUT in renders:
            flags |= F_CUTOUT
        if RENDER_TRANSLUCENT in renders or (fluid and fluid[0] == "water"):
            flags |= F_TRANSLUCENT
        if info.fullbright:
            flags |= F_FULLBRIGHT
        if not ao:
            flags |= F_NO_AO
        flags |= (info.self_skip & 63) << 8
        flags |= (info.face_full & 63) << 14
        offs = {"none": 0, "xz": 1, "xyz": 2}[info.offset]
        flags |= offs << 20
        if m.entity:
            flags |= F_ENTITY
        if kind != KIND_EMPTY:
            flags |= F_SHADOW
        words[0] = flags
        group = 0
        if info.self_skip:
            group = self._cull_groups.setdefault(name, len(self._cull_groups) + 1)
        fl = 0
        if fluid:
            fl = (1 if fluid[0] == "water" else 2) | (min(8, max(1, info.amount)) << 2) | (int(info.falling) << 6) | (int(waterlogged) << 7)
        words[3] = fl | (min(15, info.emission) << 8) | (info.dampening << 12) | (group << 16)
        if fixed:
            words[4] = fixed[0]
        if len(fixed) > 1:
            words[5] = fixed[1]
        emission_rgb = (0.0, 0.0, 0.0)
        if info.emission:
            emission_rgb = self._light_colour(elements, fluid)
            words[6] = (round(emission_rgb[0] * 255) << 16) | (round(emission_rgb[1] * 255) << 8) | round(emission_rgb[2] * 255)
        words[7] = (round(info.max_h * 1000) & 0xFFFF) | ((round(info.max_v * 1000) & 0xFFFF) << 16)
        m.words = words
        m.kind = kind
        m.opaque = info.solid
        m.light_filter = info.dampening
        m.emission = (info.emission, emission_rgb)
        m.fluid = fluid
        m.map_color, m.tint_kind = self._map_colour(elements, fluid)
        m.key = (tuple(words), tuple(tuple(e) for e in m.elements), m.opaque, m.light_filter, m.emission, m.fluid, m.map_color, m.tint_kind)
        return m

    # ---- colours from the textures (sRGB out)
    def _pixels(self, face_or_tex, rect=None, entry=None):
        img = self.png(face_or_tex)
        fh = entry.h if entry else img.shape[1]
        frame = img[:fh]
        if rect is not None:
            fw = entry.w
            x0, y0 = math.floor(rect[0] * fw), math.floor(rect[1] * fh)
            x1, y1 = max(x0 + 1, math.ceil(rect[2] * fw)), max(y0 + 1, math.ceil(rect[3] * fh))
            frame = frame[y0:y1, x0:x1]
        px = frame.reshape(-1, 4)
        return px[px[:, 3] > 0]

    def _light_colour(self, elements, fluid):
        """The light's colour from the block's own texture. Per texture, the mean (linear light) of its
        brightest third of pixels; of those, the texture that is brightest and most coloured (a lit
        furnace's flame front, not its stone sides); sRGB, scaled so the largest channel is 1."""
        textures = {}
        for e in elements:
            for f in e.faces.values():
                p = self._pixels(f.tex, f.uvrect, f.entry)
                if len(p):
                    textures.setdefault(f.tex, []).append(p)
        if fluid and not textures:
            tex = "minecraft:block/water_still" if fluid[0] == "water" else "minecraft:block/lava_still"
            textures[tex] = [self._pixels(tex, None, self.atlas_entry(tex))]
        if not textures:
            return (1.0, 1.0, 1.0)      # an invisible light source (the light block): the game's light has no colour
        best = None
        for tex, parts in sorted(textures.items()):
            lin = srgb_to_linear(np.concatenate(parts)[:, :3])
            lum = 0.2126 * lin[:, 0] + 0.7152 * lin[:, 1] + 0.0722 * lin[:, 2]
            c = lin[lum >= np.quantile(lum, 2.0 / 3.0)].mean(axis=0)
            s = linear_to_srgb(c)
            sat = (s.max() - s.min()) / max(s.max(), 1e-6)
            score = (0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]) * (0.25 + sat)
            if best is None or score > best[0]:
                best = (score, s)
        s = best[1] / max(best[1].max(), 1e-6)
        return tuple(float(round(v, 4)) for v in s)

    def _map_colour(self, elements, fluid):
        """Mean colour of what is seen from straight above (before biome tint), and that face's tint kind."""
        best = None
        for e in elements:
            f = e.faces.get(1)
            if f is None:
                continue
            top = e.hi[1] if e.xform is None else None
            if top is None:
                continue
            if best is None or top > best[0]:
                best = (top, f)
        if best is None:
            for e in elements:      # rotated elements, flat plants: take any face
                for f in e.faces.values():
                    best = (0, f)
                    break
                if best:
                    break
        if best is None:
            if fluid:
                tex = "minecraft:block/water_still" if fluid[0] == "water" else "minecraft:block/lava_still"
                p = self._pixels(tex, None, self.atlas_entry(tex))
                c = linear_to_srgb(srgb_to_linear(p[:, :3]).mean(axis=0))
                return tuple(int(round(v * 255)) for v in c), ("water" if fluid[0] == "water" else None)
            return (0, 0, 0), None
        f = best[1]
        p = self._pixels(f.tex, f.uvrect, f.entry)
        if not len(p):
            return (0, 0, 0), None
        c = srgb_to_linear(p[:, :3]).mean(axis=0)
        tint = f.tint
        if isinstance(tint, tuple):
            c = c * srgb_to_linear([(tint[1] >> 16) & 255, (tint[1] >> 8) & 255, tint[1] & 255])
            tint = None
        c = linear_to_srgb(c)
        return tuple(int(round(v * 255)) for v in c), tint

    # ---- output
    def write(self, out_dir):
        if len(self._materials) > MAX_MATERIALS:
            raise RuntimeError(f"{len(self._materials)} materials; blocks.r16 addresses {MAX_MATERIALS}")
        os.makedirs(out_dir, exist_ok=True)
        rows = []
        index = {}
        first = []
        for m in self._materials:
            key = tuple(tuple(e) for e in m.elements)
            if not m.elements:
                first.append(0)
                continue
            if key not in index:
                index[key] = len(rows)
                rows.extend(m.elements)
            first.append(index[key])
        if len(rows) > MAX_ELEMENT_ROWS:
            raise RuntimeError(f"{len(rows)} element rows; elements.u32 holds {MAX_ELEMENT_ROWS} (a Metal texture's height)")
        mats = np.zeros((len(self._materials), MAT_WORDS), dtype="<u4")
        for i, m in enumerate(self._materials):
            w = list(m.words)
            if m.elements:
                w[1], w[2] = first[i], len(m.elements)
            mats[i] = w
        elems = np.array(rows, dtype="<u4").reshape(-1, ELEM_WORDS) if rows else np.zeros((1, ELEM_WORDS), dtype="<u4")
        _atomic(os.path.join(out_dir, "materials.u32"), mats.tobytes())
        _atomic(os.path.join(out_dir, "elements.u32"), elems.tobytes())
        meta = {
            "version": 1,
            "atlas_hash": self.atlas_hash,
            "jar": os.path.basename(self.jar_path),
            "materials": [
                {"id": i, "states": m.states, "kind": ["empty", "cube", "elements"][m.kind],
                 "elements": len(m.elements), "opaque": m.opaque, "light_filter": m.light_filter,
                 "emission": [m.emission[0], list(m.emission[1])], "fluid": list(m.fluid) if m.fluid else None,
                 "map_color": list(m.map_color), "tint_kind": m.tint_kind, "entity": m.entity,
                 **({"unhandled": m.unhandled} if m.unhandled else {})}
                for i, m in enumerate(self._materials)],
            "element_rows": len(rows),
            "unhandled": self._unhandled,
        }
        _atomic(os.path.join(out_dir, "materials.json"), json.dumps(meta, indent=1).encode())
        return {"materials": len(self._materials), "element_rows": len(rows), "unhandled": len(self._unhandled)}


def plant_offset(x, z, kind, max_h, max_v):
    """BlockBehaviour's XZ / XYZ offset function (Mth.getSeed(x, 0, z))."""
    l = mth_get_seed(x, 0, z)
    def f(v):
        return struct.unpack("<f", struct.pack("<f", v))[0]
    ox = min(max_h, max(-max_h, (f((l & 15) / 15.0) - 0.5) * 0.5))
    oz = min(max_h, max(-max_h, (f((l >> 8 & 15) / 15.0) - 0.5) * 0.5))
    oy = (f((l >> 4 & 15) / 15.0) - 1.0) * max_v if kind == "xyz" else 0.0
    return ox, oy, oz


def face_corners(frm, to, fname, uv, quad, inv_face):
    """FaceBakery.bakeVertex before any rotation: the face's corners in the element's
    space (block units, FaceInfo order) and their uv (0..1 of the sprite), with the
    face's quarter-turn rotation and the uvlock face transform applied."""
    minU, minV, maxU, maxV = uv
    pts = np.array([[(to if sel[k] else frm)[k] for k in range(3)] for sel in FACE_INFO[fname]], dtype=np.float64) / 16.0
    us, vs = [], []
    identity = np.allclose(inv_face, np.eye(4))
    for i in range(4):
        j = (i + quad) % 4
        u = (minU if j in (0, 1) else maxU) / 16.0
        v = (minV if j in (0, 3) else maxV) / 16.0
        if not identity:
            r = inv_face @ np.array([u - 0.5, v - 0.5, 0.0, 1.0])
            u, v = r[0] + 0.5, r[1] + 0.5
        us.append(u)
        vs.append(v)
    return pts, us, vs


def place(pts, S, erot):
    """Element rotation, then the blockstate rotation about the block's centre (FaceBakery order)."""
    out = np.array(pts, dtype=np.float64)
    if erot is not None:
        o, E = erot
        out = (out - o) @ E.T + o
    return (out - 0.5) @ S.T + 0.5


def _when(cond, props):
    if "OR" in cond:
        return any(_when(c, props) for c in cond["OR"])
    if "AND" in cond:
        return all(_when(c, props) for c in cond["AND"])
    for k, v in cond.items():
        val = props.get(k)
        v = str(v).lower() if isinstance(v, bool) else str(v)
        if v.startswith("!"):
            if val in v[1:].split("|"):
                return False
        elif val not in v.split("|"):
            return False
    return True


def _default_uv(frm, to, face):
    fx, fy, fz = frm
    tx, ty, tz = to
    return {
        "down": (fx, 16 - tz, tx, 16 - fz),
        "up": (fx, fz, tx, tz),
        "north": (16 - tx, 16 - ty, 16 - fx, 16 - fy),
        "south": (fx, 16 - ty, tx, 16 - fy),
        "west": (fz, 16 - ty, tz, 16 - fy),
        "east": (16 - tz, 16 - ty, 16 - fz, 16 - fy),
    }[face]


# Canonical (s, t) of a full cube face at block point p, as FORMAT.md defines it.
def canonical_st(d, p):
    x, y, z = p
    return [(x, 1 - z), (x, z), (1 - x, 1 - y), (x, 1 - y), (z, 1 - y), (1 - z, 1 - y)][d]


def apply_d4(o, s, t):
    u, v = (t, s) if o & 4 else (s, t)
    if o & 1:
        u = 1 - u
    if o & 2:
        v = 1 - v
    return u, v


def _cube_face_d4(f):
    """If face f covers the whole 16x16 tile of a full-cube face, its orientation code, else None."""
    if f.entry.array != "tiles":
        return None
    d = f.dir
    # three points of the face in block space
    probe = []
    for (s, t) in ((0.0, 0.0), (1.0, 0.0), (0.0, 1.0)):
        for p in _face_points(d):
            if np.allclose(canonical_st(d, p), (s, t)):
                probe.append(p)
                break
    got = [(float(f.plane_u[0] @ p + f.plane_u[1]) / 16.0, float(f.plane_v[0] @ p + f.plane_v[1]) / 16.0) for p in probe]
    for o in range(8):
        want = [apply_d4(o, s, t) for (s, t) in ((0.0, 0.0), (1.0, 0.0), (0.0, 1.0))]
        if all(abs(a[0] - b[0]) < 1e-4 and abs(a[1] - b[1]) < 1e-4 for a, b in zip(got, want)):
            return o
    return None


def _face_points(d):
    pts = []
    for a in (0.0, 1.0):
        for b in (0.0, 1.0):
            if d in (0, 1):
                pts.append(np.array([a, float(d == 1), b]))
            elif d in (2, 3):
                pts.append(np.array([a, b, float(d == 3)]))
            else:
                pts.append(np.array([float(d == 5), a, b]))
    return pts


def _as_cube(elements):
    """(primary faces by dir, overlay faces by dir) if the elements are one full cube (+ an overlay shell)."""
    if not elements or len(elements) > 2:
        return None
    for e in elements:
        if e.xform is not None or not (np.allclose(e.lo, 0) and np.allclose(e.hi, 1)):
            return None
    prim = elements[0].faces
    if len(prim) != 6:
        return None
    over = elements[1].faces if len(elements) == 2 else {}
    for f in list(prim.values()) + list(over.values()):
        f.full_d4 = _cube_face_d4(f)
        if f.full_d4 is None:
            return None
        if f.emission:
            return None
    return prim, over


def _descriptor(entry, d4, tint, render, shade, emission, cullface):
    a = (entry.layer & 0xFFF) | ((1 if entry.array == "skins" else 0) << 12) | (((d4 or 0) & 7) << 13)
    a |= (tint & 15) << 16 | (render & 3) << 20 | (int(bool(shade)) << 22) | (1 << 23)
    a |= (emission & 15) << 24 | ((0 if cullface is None else cullface + 1) & 7) << 28
    b = (entry.frames & 0xFF) | ((entry.ticks & 0xFFFF) << 8)
    return a, b


def _element_words(e, tcode):
    w = [0] * ELEM_WORDS
    w[0:3] = [f32bits(v) for v in e.lo]
    w[4:7] = [f32bits(v) for v in e.hi]
    mask = 0
    for d in e.faces:
        mask |= 1 << (1 + d)
    w[3] = (1 if e.xform is not None else 0) | mask
    if e.xform is not None:
        M, t = e.xform
    else:
        M, t = np.eye(3), np.zeros(3)
    for r in range(3):
        w[8 + 4 * r: 12 + 4 * r] = [f32bits(M[r, 0]), f32bits(M[r, 1]), f32bits(M[r, 2]), f32bits(t[r])]
    for d, f in e.faces.items():
        base = 20 + 8 * d
        (au, bu), (av, bv) = f.plane_u, f.plane_v
        w[base: base + 8] = [f32bits(au[0]), f32bits(au[1]), f32bits(au[2]), f32bits(bu),
                             f32bits(av[0]), f32bits(av[1]), f32bits(av[2]), f32bits(bv)]
        a, b = _descriptor(f.entry, 0, tcode(f.tint), f.render, f.shade, f.emission, f.cullface)
        w[68 + 2 * d], w[69 + 2 * d] = a, b
    return w


def _atomic(path, data):
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, path)


if __name__ == "__main__":
    # Resolve every state of every block in the jar and report.
    import argparse
    ap = argparse.ArgumentParser(description="Resolve every block state in the jar; print counts and the unhandled list.")
    ap.add_argument("--jar", default=os.path.expanduser("~/Library/Application Support/minecraft/versions/26.2/26.2.jar"))
    ap.add_argument("--atlas", default=os.path.expanduser("~/Library/Application Support/Lerping/Minecraft"))
    ap.add_argument("--out", help="also write materials.* / elements.* here")
    args = ap.parse_args()
    t = Table(args.jar, args.atlas, max_materials=1 << 20)
    n = 0
    maxel = (0, None)
    for (name, p) in list(t.info):
        props = {} if p == "-" else dict(kv.split("=", 1) for kv in p.split(","))
        if t.needs_pos(name, props):
            mids = {t.resolve(name, props, pos=(x, 64, z)) for x in range(-8, 8) for z in range(-8, 8)}
        else:
            mids = {t.resolve(name, props)}
        n += 1
        for mid in mids:
            k = len(t._materials[mid].elements)
            if k > maxel[0]:
                maxel = (k, t._materials[mid].states[0])
    un = t.unhandled()
    print(f"block states in the jar: {n}; drawn: {n - len(un)}; unhandled: {len(un)}; materials: {len(t)}; "
          f"largest element count: {maxel[0]} ({maxel[1]})")
    groups = {}
    for s, r in un.items():
        groups.setdefault(r, []).append(s)
    for r, ss in sorted(groups.items(), key=lambda kv: -len(kv[1])):
        blocks = sorted({s.split("[")[0].split(":", 1)[1] for s in ss})
        print(f"{len(ss):6d} states, {len(blocks)} blocks: {r}\n        {', '.join(blocks)}")
    if args.out:
        print(t.write(args.out))
