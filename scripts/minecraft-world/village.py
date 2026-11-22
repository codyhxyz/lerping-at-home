"""What lives in a baked world: beds, job sites, bells, doors, the save's own mobs.

The bake writes these as tables in world.metal and world.json (FORMAT.md,
"Places and mobs") so a look can run a village's day, put the save's mobs where
the save has them and open a door a mob walks through, without scanning the
volume. Nothing here is village-only: a world with no beds, doors or mobs gets
tables with a count of zero.
"""

import glob
import math
import os

import numpy as np

import anvil
import blocknames as bn

# The job-site block -> the profession it gives, numbered in the game's
# job-site-block order (PoiTypes: armorer .. weaponsmith). 13 is the nitwit, -1 none.
JOB_BLOCKS = {
    "blast_furnace": 0, "smoker": 1, "cartography_table": 2, "brewing_stand": 3, "composter": 4,
    "barrel": 5, "fletching_table": 6, "cauldron": 7, "water_cauldron": 7, "lava_cauldron": 7,
    "powder_snow_cauldron": 7, "lectern": 8, "stonecutter": 9, "loom": 10, "smithing_table": 11,
    "grindstone": 12,
}
PROFESSIONS = ["armorer", "butcher", "cartographer", "cleric", "farmer", "fisherman", "fletcher",
               "leatherworker", "librarian", "mason", "shepherd", "toolsmith", "weaponsmith", "nitwit"]
VILLAGER_TYPES = ["desert", "jungle", "plains", "savanna", "snow", "swamp", "taiga"]

# Mob kinds. The first eight are the numbers one-world asked for; the rest follow. A mob
# not in this list is left out of the table and listed, with its count, in world.json.
MOB_KINDS = [
    "villager", "iron_golem", "cat", "cow", "sheep", "pig", "chicken", "horse",
    "wandering_trader", "trader_llama", "llama", "donkey", "mule", "rabbit", "wolf", "fox",
    "goat", "bee", "frog", "axolotl", "parrot", "polar_bear", "turtle", "squid", "glow_squid",
    "cod", "salmon", "tropical_fish", "pufferfish", "dolphin", "bat", "armadillo", "camel",
    "sniffer", "panda", "ocelot", "mooshroom", "allay", "pillager", "vindicator", "evoker",
    "witch", "zombie_villager", "zombie", "husk", "drowned", "skeleton", "stray", "creeper",
    "spider", "cave_spider", "enderman", "slime", "guardian", "elder_guardian", "snow_golem",
    "skeleton_horse", "zombie_horse", "strider", "tadpole", "happy_ghast", "warden",
    "nautilus", "zombie_nautilus", "copper_golem", "creaking", "breeze", "bogged", "phantom",
    "silverfish", "endermite", "ravager", "vex", "illusioner",
]
# Variant names, by the index MCW_MOB_INFO.y gives. Mobs whose save field is already a
# number (horse, sheep colour, rabbit, parrot, axolotl, llama) pass it through.
VARIANTS = {
    "cat": ["tabby", "black", "red", "siamese", "british_shorthair", "calico", "persian", "ragdoll",
            "white", "jellie", "all_black"],
    "cow": ["temperate", "warm", "cold"],
    "pig": ["temperate", "warm", "cold"],
    "chicken": ["temperate", "warm", "cold"],
    "frog": ["temperate", "warm", "cold"],
    "wolf": ["pale", "ashen", "black", "chestnut", "rusty", "snowy", "spotted", "striped", "woods"],
    "fox": ["red", "snow"],
    "mooshroom": ["red", "brown"],
}
NUMERIC_VARIANT = {"horse": "Variant", "sheep": "Color", "rabbit": "RabbitType", "parrot": "Variant",
                   "axolotl": "Variant", "llama": "Variant", "trader_llama": "Variant",
                   "tropical_fish": "Variant"}

# Horizontal directions in the game's 2D order (Direction.get2DDataValue): south, west, north, east.
FACING = {"south": 0, "west": 1, "north": 2, "east": 3}
# Heading as mcMobRay takes it: 0 faces +z, pi/2 faces +x.
HEADING = {"south": 0.0, "east": math.pi / 2, "north": math.pi, "west": -math.pi / 2}
# Door panel side, 0 -z, 1 +x, 2 +z, 3 -x. Closed: the side opposite the facing (the door
# models put the 3/16 panel at x 0..3 and the blockstate turns it by the facing). Open: a
# quarter turn on from closed, +1 with the hinge on the left, +3 with it on the right
# (checked against the 26.2 door blockstates: east/left/open is y 90 = -z).
CLOSED_SIDE = {"east": 3, "south": 0, "west": 1, "north": 2}
BELL_ATTACH = {"floor": 0, "ceiling": 1, "single_wall": 2, "double_wall": 3}


class TableError(Exception):
    pass


def places(gids, states):
    """Beds, job sites, bells and doors in the volume (volume-space cells), each list sorted by (x, y, z)."""
    keys = states.keys
    short = [bn.short(k[0]) for k in keys]
    want = np.array([n.endswith("_bed") or n in JOB_BLOCKS or n == "bell"
                     or (n.endswith("_door") and not n.endswith("trapdoor")) for n in short])
    beds, jobs, bells, doors = [], [], [], []
    for z, y, x in np.argwhere(want[gids]):
        g = int(gids[z, y, x])
        n = short[g]
        p = dict(keys[g][1])
        x, y, z = int(x), int(y), int(z)
        if n.endswith("_bed"):
            if p.get("part") == "head":
                beds.append(dict(cell=[x, y, z], block=n, facing=p["facing"],
                                 pos=[x + 0.5, y + 0.5625, z + 0.5], yaw=HEADING[p["facing"]]))
        elif n in JOB_BLOCKS:
            jobs.append(dict(cell=[x, y, z], block=n, profession=JOB_BLOCKS[n],
                             pos=[x + 0.5, y + 0.5, z + 0.5]))
        elif n == "bell":
            bells.append(dict(cell=[x, y, z], attachment=p.get("attachment", "floor"),
                              pos=[x + 0.5, y + 0.5, z + 0.5]))
        elif p.get("half") == "lower":
            f = p["facing"]
            closed = CLOSED_SIDE[f]
            right = p.get("hinge") == "right"
            opened = (closed + (3 if right else 1)) % 4
            is_open = p.get("open") == "true"
            code = FACING[f] | (int(right) << 2) | (int(is_open) << 3) | (closed << 4) | (opened << 6)
            doors.append(dict(cell=[x, y, z], block=n, facing=f, hinge=p.get("hinge"), open=is_open,
                              closed_side=closed, open_side=opened, code=code))
    for lst in (beds, jobs, bells, doors):
        lst.sort(key=lambda d: (d["cell"][0], d["cell"][1], d["cell"][2]))
    return beds, jobs, bells, doors


def stops(routes, beds, jobs, bells):
    """Per loop, one stop per bell, bed and job site it passes: the route point nearest the
    item among those within 2 blocks (Chebyshev, feet to the item's centre), and for beds and
    job sites only points the bake flagged as beside a waypoint (bit 2). A ceiling bell
    hangs 2 above the feet, so a bell stop need not carry the flag.
    Returns [(route, point index, kind 0 bell / 1 bed / 2 job site, item)]."""
    out = []
    for r, (kind_, pts, flags) in enumerate(routes):
        P = np.array([(x + 0.5, y, z + 0.5) for (z, y, x) in pts])
        F = np.array(flags)
        for kind, items in ((0, bells), (1, beds), (2, jobs)):
            for i, it in enumerate(items):
                q = np.array(it["pos"])
                d = np.abs(P - q).max(axis=1)
                ok = d < 2.1
                if kind:
                    ok &= (F & 4) != 0
                near = np.nonzero(ok)[0]
                if len(near):
                    j = near[np.argmin(np.linalg.norm(P[near] - q, axis=1))]
                    out.append((r, int(j), kind, i))
    return out


def _variant(kind, e):
    if kind in VARIANTS:
        v = e.get("variant") or e.get("Variant") or e.get("Type")
        if v is None:
            return -1
        if isinstance(v, (int, np.integer)):
            return int(v)
        v = str(v).replace("minecraft:", "")
        if v not in VARIANTS[kind]:
            raise TableError(f"{kind} variant {v!r} is not in village.VARIANTS; add it")
        return VARIANTS[kind].index(v)
    if kind in NUMERIC_VARIANT:
        return int(e.get(NUMERIC_VARIANT[kind], -1))
    return -1


def _memory_pos(e, key):
    m = e.get("Brain", {}).get("memories", {}).get(key)
    if not m:
        return None
    v = m.get("value", m)
    pos = v.get("pos") if isinstance(v, dict) else None
    return tuple(int(c) for c in pos) if pos is not None else None


def mobs(save, box, square=None):
    """The save's mobs inside the box, in save order (region file, chunk, list order).

    Returns (mobs, skipped) where skipped counts entities by id that are not in the table
    (outside the box, outside a generated save's square, or not mobs MOB_KINDS has)."""
    (ox, oy, oz), (W, H, D) = box["origin"], box["size"]
    edir = os.path.join(save.path, "dimensions", "minecraft", "overworld", "entities")
    if not os.path.isdir(edir):
        edir = os.path.join(save.path, "entities")
    out, skipped = [], {}

    def skip(why, eid):
        k = f"{why}: {eid}"
        skipped[k] = skipped.get(k, 0) + 1

    def region_key(p):
        _, rx, rz, _ = os.path.basename(p).split(".")
        return int(rz), int(rx)
    for path in sorted(glob.glob(os.path.join(edir, "r.*.mca")), key=region_key):
        reg = anvil.Region(path)
        for lx, lz in sorted(reg.chunks(), key=lambda t: (t[1], t[0])):
            root = reg.read(lx, lz)
            if root is None:
                continue
            cx, cz = reg.rx * 32 + lx, reg.rz * 32 + lz
            for e in root.get("Entities", []):
                eid = e.get("id", "?").replace("minecraft:", "")
                if square and not (square["x0"] <= cx <= square["x1"] and square["z0"] <= cz <= square["z1"]):
                    skip("outside the generated square", eid)
                    continue
                x, y, z = (float(v) for v in e["Pos"])
                vx, vy, vz = x - ox, y - oy, z - oz
                if not (0 <= vx < W and 0 <= vz < D and 0 <= vy < H):
                    skip("outside the box", eid)
                    continue
                if eid not in MOB_KINDS:
                    skip("not in the mob table", eid)
                    continue
                kind = MOB_KINDS.index(eid)
                yaw = -math.radians(float(e["Rotation"][0])) if "Rotation" in e else 0.0
                yaw = math.atan2(math.sin(yaw), math.cos(yaw))
                info = [kind, -1, -1, 1 if int(e.get("Age", 0)) < 0 or e.get("IsBaby") else 0]
                rec = dict(id=eid, pos=[round(vx, 3), round(vy, 3), round(vz, 3)], yaw=round(yaw, 4))
                if eid in ("villager", "zombie_villager"):
                    vd = e.get("VillagerData", {})
                    prof = str(vd.get("profession", "minecraft:none")).replace("minecraft:", "")
                    typ = str(vd.get("type", "minecraft:plains")).replace("minecraft:", "")
                    if prof != "none" and prof not in PROFESSIONS:
                        raise TableError(f"villager profession {prof!r} is not in village.PROFESSIONS")
                    if typ not in VILLAGER_TYPES:
                        raise TableError(f"villager type {typ!r} is not in village.VILLAGER_TYPES")
                    info[1] = -1 if prof == "none" else PROFESSIONS.index(prof)
                    info[2] = VILLAGER_TYPES.index(typ)
                    rec.update(profession=prof, type=typ, level=int(vd.get("level", 1)),
                               home_memory=_memory_pos(e, "minecraft:home"),
                               job_memory=_memory_pos(e, "minecraft:job_site"))
                else:
                    info[1] = _variant(eid, e)
                rec["info"] = info
                out.append(rec)
    return out, skipped


def claims(mob_list, beds, jobs, stop_list, box):
    """Which bed and job site each villager keeps (index, or -1), and by what rule.

    The game's own claims are the villager's `home` and `job_site` memories; a save that
    has them is used as is. A save that never ran a tick (a generated one) has none, so
    the bake hands them out nearest pair first (the game hands them out first come, first
    served; nearest first stands in for who would get there first), only beds and job sites
    a route reaches, and only job sites to villagers that can take one: an employed villager
    gets one of its own profession, an unemployed one any left, a nitwit none."""
    ox, oy, oz = box["origin"]
    home = [-1] * len(mob_list)
    job = [-1] * len(mob_list)
    rule = {"home": "none", "job": "none"}
    vill = [i for i, m in enumerate(mob_list) if m["id"] == "villager"]
    if not vill:
        return home, job, rule
    bed_cells = {tuple(b["cell"]): i for i, b in enumerate(beds)}
    job_cells = {tuple(j["cell"]): i for i, j in enumerate(jobs)}
    if any(mob_list[v].get("home_memory") or mob_list[v].get("job_memory") for v in vill):
        for v in vill:
            hm, jm = mob_list[v].get("home_memory"), mob_list[v].get("job_memory")
            if hm:
                c = (hm[0] - ox, hm[1] - oy, hm[2] - oz)
                home[v] = bed_cells.get(c, bed_cells.get((c[0], c[1], c[2]), -1))
            if jm:
                job[v] = job_cells.get((jm[0] - ox, jm[1] - oy, jm[2] - oz), -1)
        rule = {"home": "save memories", "job": "save memories"}
        return home, job, rule
    reach_bed = {it for (_, _, k, it) in stop_list if k == 1}
    reach_job = {it for (_, _, k, it) in stop_list if k == 2}

    def pairs(vs, items, ok):
        cand = sorted((float(np.linalg.norm(np.array(mob_list[v]["pos"]) - np.array(items[i]["pos"]))), v, i)
                      for v in vs for i in range(len(items)) if ok(v, i))
        got, used_v, used_i = {}, set(), set()
        for _, v, i in cand:
            if v in used_v or i in used_i:
                continue
            got[v] = i
            used_v.add(v)
            used_i.add(i)
        return got
    for v, i in pairs(vill, beds, lambda v, i: i in reach_bed).items():
        home[v] = i
    employed = [v for v in vill if 0 <= mob_list[v]["info"][1] < 13]
    got = pairs(employed, jobs, lambda v, i: i in reach_job and jobs[i]["profession"] == mob_list[v]["info"][1])
    taken = set(got.values())
    jobless = [v for v in vill if mob_list[v]["info"][1] == -1]
    got.update(pairs(jobless, jobs, lambda v, i: i in reach_job and i not in taken))
    for v, i in got.items():
        job[v] = i
    rule = {"home": "nearest pair first (the save has no claims)", "job": "nearest pair first (the save has no claims)"}
    return home, job, rule


def metal(beds, jobs, bells, doors, stop_list, mob_list, home, job):
    """MSL constants. Every array has at least one element so it compiles; read only below the count."""
    def arr(typ, name, items, fmt, empty):
        body = ", ".join(fmt(i) for i in items) if items else empty
        return f"constant {typ} {name}[] = {{{body}}};"
    f = lambda v: f"{v:.4f}".rstrip("0").rstrip(".") if isinstance(v, float) else str(v)
    L = ["// Places and mobs (FORMAT.md, \"Places and mobs\"). Arrays hold one zero entry when the count is 0.",
         f"constant int     MCW_BED_COUNT = {len(beds)};",
         arr("float4", "MCW_BEDS", beds, lambda b: "float4(%s, %s, %s, %s)" % tuple(f(v) for v in b["pos"] + [b["yaw"]]), "float4(0)"),
         f"constant int     MCW_JOB_COUNT = {len(jobs)};",
         arr("float4", "MCW_JOBS", jobs, lambda j: "float4(%s, %s, %s, %d)" % (f(j["pos"][0]), f(j["pos"][1]), f(j["pos"][2]), j["profession"]), "float4(0)"),
         f"constant int     MCW_BELL_COUNT = {len(bells)};",
         arr("float4", "MCW_BELLS", bells, lambda b: "float4(%s, %s, %s, %d)" % (f(b["pos"][0]), f(b["pos"][1]), f(b["pos"][2]), BELL_ATTACH.get(b["attachment"], 0)), "float4(0)"),
         f"constant int     MCW_STOP_COUNT = {len(stop_list)};",
         arr("ushort4", "MCW_STOPS", stop_list, lambda s: "ushort4(%d, %d, %d, %d)" % s, "ushort4(0)"),
         f"constant int     MCW_DOOR_COUNT = {len(doors)};",
         arr("int4", "MCW_DOORS", doors, lambda d: "int4(%d, %d, %d, %d)" % tuple(d["cell"] + [d["code"]]), "int4(0)"),
         f"constant int     MCW_MOB_COUNT = {len(mob_list)};",
         arr("float4", "MCW_MOB_POS", mob_list, lambda m: "float4(%s, %s, %s, %s)" % tuple(f(float(v)) for v in m["pos"] + [m["yaw"]]), "float4(0)"),
         arr("int4", "MCW_MOB_INFO", mob_list, lambda m: "int4(%d, %d, %d, %d)" % tuple(m["info"]), "int4(0)"),
         arr("int2", "MCW_MOB_PLACE", list(range(len(mob_list))), lambda i: "int2(%d, %d)" % (home[i], job[i]), "int2(-1)"),
         ]
    return L
