"""Geometry for blocks the game draws with a block-entity renderer instead of a
JSON model: chests, the bell's body, banners and shulker boxes. Each is built
from the game's own baked entity model (the cubes, their part poses and skin
uvs, dumped from the jar by BlockDump.java), placed by the renderer's own
per-facing transform (also dumped), on the real entity texture in `skins`.

What is not built is reported by `reason` / `unhandled_part`, never faked.
Posed as the renderer poses them at rest: chest and shulker lids closed, the
bell still, a banner's flag at the middle of its sway. A banner shows its base
colour only (patterns live in the block entity, not the block state).
"""

import numpy as np

M = None   # the materials module, set by EntityModels (it may be running as __main__)

DYES = ["white", "orange", "magenta", "light_blue", "yellow", "lime", "pink", "gray", "light_gray",
        "cyan", "purple", "blue", "brown", "green", "red", "black"]

CHEST_MATERIAL = {
    "minecraft:chest": "REGULAR",
    "minecraft:trapped_chest": "TRAPPED",
    "minecraft:ender_chest": "ENDER_CHEST",
    "minecraft:copper_chest": "COPPER_UNAFFECTED",
    "minecraft:exposed_copper_chest": "COPPER_EXPOSED",
    "minecraft:weathered_copper_chest": "COPPER_WEATHERED",
    "minecraft:oxidized_copper_chest": "COPPER_OXIDIZED",
    "minecraft:waxed_copper_chest": "COPPER_UNAFFECTED",
    "minecraft:waxed_exposed_copper_chest": "COPPER_EXPOSED",
    "minecraft:waxed_weathered_copper_chest": "COPPER_WEATHERED",
    "minecraft:waxed_oxidized_copper_chest": "COPPER_OXIDIZED",
}

# Placed mob heads by block-name prefix -> SkullBlock.Type. The dragon head's skin
# is 256 px (in maps, which materials do not address) and a player head's skin
# comes from its block entity's profile: those two stay unhandled.
SKULLS = {"skeleton": "SKELETON", "wither_skeleton": "WITHER_SKELETON", "zombie": "ZOMBIE",
          "creeper": "CREEPER", "piglin": "PIGLIN"}

# Blocks whose JSON model is only part of what the game draws.
PARTIAL = {
    "minecraft:enchanting_table": "the floating book is drawn by the block-entity renderer, not built",
}


def _m4(text):
    return np.array([float(v) for v in text.split(",")], dtype=np.float64).reshape(4, 4).T


class EntityModels:
    def __init__(self, table, materials_module):
        global M
        M = materials_module
        self.table = table
        self.cubes = {}        # job -> [(pose 4x4, min px, max px, [(normal, [(xyz px, uv px)] x4)])]
        self.transforms = {}   # (name, key) -> 4x4
        self.sprites = {}      # name -> texture id
        self.dyes = {}         # dye -> 0xRRGGBB
        for f in table.entity_lines:
            if f[0] == "P":
                lo = np.array([float(v) for v in f[4].split(",")])
                hi = np.array([float(v) for v in f[5].split(",")])
                self.cubes.setdefault(f[1], []).append((_m4(f[3]), lo, hi, []))
            elif f[0] == "Q":
                cube = self.cubes[f[1]][int(f[2])]
                n = np.array([float(v) for v in f[3].split(",")])
                verts = []
                for v in f[4:8]:
                    x, y, z, u, w = (float(t) for t in v.split(","))
                    verts.append((np.array([x, y, z]), (u, w)))
                cube[3].append((n, verts))
            elif f[0] == "X":
                self.transforms[(f[1], f[2])] = _m4(f[3])
            elif f[0] == "K":
                self.sprites[f[1]] = f[2]
            elif f[0] == "D":
                self.dyes[f[1]] = int(f[2], 16)

    # ---- what each block is
    def _jobs(self, name, props):
        """[(job, renderer transform, texture, tint)] for an entity-drawn block, or None."""
        if name in CHEST_MATERIAL:
            mat = CHEST_MATERIAL[name]
            ctype = props.get("type", "single").upper()
            job = {"SINGLE": "chest", "LEFT": "chest_left", "RIGHT": "chest_right"}[ctype]
            return [(job, self.transforms[("chest", props["facing"])], self.sprites[f"chest/{mat}/{ctype}"], None)]
        if name == "minecraft:bell":
            return [("bell", np.eye(4), self.sprites["bell"], None)]
        short = name.split(":", 1)[1]
        if short.endswith("_wall_banner") and short[:-len("_wall_banner")] in DYES:
            dye = short[:-len("_wall_banner")]
            r = self.transforms[("banner_wall", props["facing"])]
            return [("wall_banner", r, self.sprites["banner_base"], None),
                    ("wall_banner_flag", r, self.sprites["banner_pattern_base"], ("fixed", self.dyes[dye]))]
        if short.endswith("_banner") and short[:-len("_banner")] in DYES:
            dye = short[:-len("_banner")]
            r = self.transforms[("banner_ground", props["rotation"])]
            return [("standing_banner", r, self.sprites["banner_base"], None),
                    ("standing_banner_flag", r, self.sprites["banner_pattern_base"], ("fixed", self.dyes[dye]))]
        for prefix, kind in SKULLS.items():
            if short in (prefix + "_skull", prefix + "_head"):
                return [(f"skull/{kind}", self.transforms[("skull_ground", props["rotation"])], self.sprites[f"skull/{kind}"], None)]
            if short in (prefix + "_wall_skull", prefix + "_wall_head"):
                return [(f"skull/{kind}", self.transforms[("skull_wall", props["facing"])], self.sprites[f"skull/{kind}"], None)]
        if short == "shulker_box" or (short.endswith("_shulker_box") and short[:-len("_shulker_box")] in DYES):
            colour = "default" if short == "shulker_box" else short[:-len("_shulker_box")]
            return [("shulker_box", self.transforms[("shulker_box", props["facing"])], self.sprites[f"shulker_box/{colour}"], None)]
        return None

    def elements(self, name, props, info):
        """Elements (materials.Element) for the entity-drawn part of a state, or None."""
        jobs = self._jobs(name, props)
        if jobs is None:
            return None
        out = []
        for job, R, tex, tint in jobs:
            tex = tex if ":" in tex else "minecraft:" + tex
            entry = self.table.atlas_entry(tex)
            for pose, lo, hi, polys in self.cubes[job]:
                out.append(self._element(R @ pose, lo, hi, polys, tex, entry, tint, job))
        return out

    def _element(self, A, lo, hi, polys, tex, entry, tint, job):
        """One entity cube as an element: its box in its own space q = pixels / 16, A: q -> block."""
        e = M.Element()
        e.faces = {}
        e.source = job
        # The box from the polygons: an inflated cube (a zombie's hat) keeps its
        # un-inflated min/max in the model; its vertices carry the inflation.
        allq = np.array([v[0] for _, verts in polys for v in verts]) / 16.0
        lo, hi = allq.min(axis=0), allq.max(axis=0)
        for n, verts in polys:
            q = np.array([v[0] for v in verts]) / 16.0
            us = np.array([v[1][0] for v in verts])
            vs = np.array([v[1][1] for v in verts])
            d = _slot(q, lo, hi, n)
            normal = np.array(M.DIR_VEC[d], dtype=np.float64)
            pu = M.fit_plane(q, us, normal)
            pv = M.fit_plane(q, vs, normal)
            if pu is None or pv is None:
                continue
            f = M.Face()
            f.dir, f.tex, f.entry = d, tex, entry
            f.plane_u, f.plane_v = pu, pv
            rect = (us.min() / entry.w, vs.min() / entry.h, us.max() / entry.w, vs.max() / entry.h)
            f.uvrect = rect
            transparent, translucent = self.table.transparency(tex, entry, rect)
            f.render = M.RENDER_TRANSLUCENT if translucent else M.RENDER_CUTOUT if transparent else M.RENDER_SOLID
            f.tint = tint
            f.shade, f.emission, f.cullface, f.full_d4 = True, 0, None, None
            if d in e.faces:
                raise M.Unhandled(f"entity model {job} has two faces on one side of a cube")
            e.faces[d] = f
        e.lo, e.hi = lo, hi
        e.xform = None
        return _flatten(e, A)

    def reason(self, name):
        short = name.split(":", 1)[1]
        if short in ("dragon_head", "dragon_wall_head"):
            return "drawn by the block-entity renderer on a 256 px skin (in maps, which materials do not address)"
        if short in ("player_head", "player_wall_head"):
            return "drawn by the block-entity renderer with the skin of the head's profile (block-entity data)"
        if short == "decorated_pot":
            return "drawn by the block-entity renderer with sherds from block-entity data"
        if short in ("end_portal", "end_gateway"):
            return "drawn by the block-entity renderer as a screen-space starfield"
        if short == "moving_piston":
            return "drawn by the block-entity renderer while a piston moves it (a transient block)"
        return "drawn by the game's block-entity renderer, not built"

    def unhandled_part(self, name, props, info):
        """A reason when the JSON model is only part of what the game draws for this state."""
        if name == "minecraft:lectern" and props.get("has_book") == "true":
            return "the book on a lectern is drawn by the block-entity renderer, not built"
        return PARTIAL.get(name)


def _slot(q, lo, hi, n):
    """Which side of the box a polygon is on, from its corners (a flat box: from its normal)."""
    for axis in range(3):
        c = q[:, axis]
        if np.allclose(c, c[0], atol=1e-6):
            if abs(hi[axis] - lo[axis]) < 1e-9:
                positive = n[axis] > 0
            else:
                positive = abs(c[0] - hi[axis]) < abs(c[0] - lo[axis])
            return [4, 0, 2][axis] + (1 if positive else 0)
    raise M.Unhandled("an entity polygon is not on a side of its cube")


def _flatten(e, A):
    """Place an element given in q space by A (q -> block). A signed permutation with no
    scale keeps it axis-aligned: bake it into block space. Anything else carries the map."""
    R, t = A[:3, :3], A[:3, 3]
    if np.allclose(np.abs(R).sum(axis=0), 1) and np.allclose(np.abs(R).sum(axis=1), 1) and np.allclose(np.abs(R), np.round(np.abs(R))):
        corners = np.array([[x, y, z] for x in (e.lo[0], e.hi[0]) for y in (e.lo[1], e.hi[1]) for z in (e.lo[2], e.hi[2])])
        moved = corners @ R.T + t
        Rinv = np.linalg.inv(R)
        faces = {}
        for d, f in e.faces.items():
            # f(p) = U . q + c with q = Rinv (p - t)
            (au, bu), (av, bv) = f.plane_u, f.plane_v
            f.plane_u = (au @ Rinv, bu - au @ Rinv @ t)
            f.plane_v = (av @ Rinv, bv - av @ Rinv @ t)
            f.dir = M.nearest_dir(R @ np.array(M.DIR_VEC[d], dtype=np.float64))
            faces[f.dir] = f
        e.faces = faces
        e.lo, e.hi = moved.min(axis=0), moved.max(axis=0)
        e.xform = None
        return e
    Ainv = np.linalg.inv(A)
    e.xform = (Ainv[:3, :3], Ainv[:3, 3])
    return e
