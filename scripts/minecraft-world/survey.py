#!/usr/bin/env python3
"""Surveys auditioned villages to choose the shared world's home.

    python3 -I scripts/minecraft-world/survey.py VILLAGES.json SAVES_DIR OUT_DIR [--size 224]

VILLAGES.json is villages.sh's list (with an "id" per village, the folder
name audition.sh --places used). For each folder in SAVES_DIR that has a
village of that id, this bakes it with bake.py into OUT_DIR/<id>/world
(never into Worlds/), draws preview_world.py's pictures into
OUT_DIR/<id>/preview plus a close-up of the village (closeup.png), and
records:

- from the game's own jigsaw pieces (villages.sh): dwellings, job buildings
  by kind, farms, pens, the meeting point, abandoned (zombie) variant;
- from the bake's world.json: beds, bells, job-site blocks by kind,
  farmland, crops, path blocks, lit blocks (block-light emitters);
- from the save's chunks out to about 160 blocks from the village centre
  (heightmaps, biomes and structure starts of every chunk the save holds,
  most of them short of full status): the ground's height range in the
  village and around it, water in the village and around it, biomes around
  it, and other structures.

Writes OUT_DIR/survey.json (one record per village) and prints a table.
Baked folders that already exist are reused.
"""
import argparse
import collections
import json
import math
import os
import subprocess
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import compare  # noqa: E402  (region and NBT reading)

MIN_Y = -64
AROUND = 160

JOB_BLOCKS = {  # job-site block -> villager profession
    "composter": "farmer", "lectern": "librarian", "smithing_table": "toolsmith",
    "fletching_table": "fletcher", "cartography_table": "cartographer", "brewing_stand": "cleric",
    "barrel": "fisherman", "blast_furnace": "armorer", "smoker": "butcher", "loom": "shepherd",
    "stonecutter": "mason", "grindstone": "weaponsmith", "cauldron": "leatherworker",
    "water_cauldron": "leatherworker", "lava_cauldron": "leatherworker", "powder_snow_cauldron": "leatherworker",
}
JOB_TEMPLATES = {  # words in a houses-pool template name -> profession
    "armorer": "armorer", "butcher": "butcher", "cartographer": "cartographer", "fisher": "fisherman",
    "fletcher": "fletcher", "library": "librarian", "mason": "mason", "shepherd": "shepherd",
    "tannery": "leatherworker", "temple": "cleric", "tool_smith": "toolsmith", "weaponsmith": "weaponsmith",
    "weapon_smith": "weaponsmith",
}
LIGHTS = {"torch", "wall_torch", "lantern", "campfire", "soul_torch", "soul_wall_torch", "soul_lantern",
          "soul_campfire", "glowstone", "sea_lantern", "redstone_lamp", "jack_o_lantern", "furnace", "blast_furnace",
          "smoker", "candle", "end_rod"}  # placed light sources (furnaces only when lit, counted anyway)
CROPS = {"wheat", "carrots", "potatoes", "beetroots", "melon_stem", "pumpkin_stem", "attached_melon_stem",
         "attached_pumpkin_stem"}


def classify_templates(templates):
    c = collections.Counter()
    jobs = collections.Counter()
    centre = None
    for t, n in templates.items():
        name = t.split("/")[-1]
        if "/town_centers/" in t:
            centre = name
        if "/houses/" not in t:
            continue
        if "meeting_point" in name:
            c["meeting_point"] += n
            centre = centre or name
        elif "farm" in name:
            c["farms"] += n
        elif "animal_pen" in name or "stable" in name:
            c["pens"] += n
        elif "accessory" in name:
            c["accessories"] += n
        elif any(w in name for w in ("small_house", "medium_house", "big_house")):
            c["dwellings"] += n
        else:
            kind = next((v for k, v in JOB_TEMPLATES.items() if k in name), None)
            if kind is None:
                c["other_buildings"] += n
            else:
                c["job_buildings"] += n
                jobs[kind] += n
    return c, jobs, centre


def heightmap(longs, n=256, bits=9):
    a = np.frombuffer(longs, dtype=">u8").astype(np.uint64)
    per = 64 // bits
    i = np.arange(n)
    v = (a[i // per] >> ((i % per) * bits).astype(np.uint64)) & np.uint64((1 << bits) - 1)
    return v.astype(np.int64) + MIN_Y - 1  # top block y


def surroundings(save, cx, cz, bbox):
    """Ground and water per column, biomes and other structure starts, from
    every chunk of the save that has heightmaps, within AROUND of (cx, cz)."""
    region = os.path.join(save, "dimensions", "minecraft", "overworld", "region")
    chunks = compare.load_folder(region)
    ground, water, inside = [], [], []
    biomes = collections.Counter()
    vill_biomes = collections.Counter()
    structures = collections.Counter()
    for (x, z), c in chunks.items():
        bx, bz = x * 16 + 8, z * 16 + 8
        d = math.hypot(bx - cx, bz - cz)
        for sid, st in (c.get("structures", {}).get("starts", {}) or {}).items():
            if st.get("id") not in (None, "INVALID") and d <= AROUND + 8 and "village" not in sid:
                structures[sid] += 1
        if d > AROUND + 12:
            continue
        hm = c.get("Heightmaps", {})
        # Water stands where the top fluid-or-solid block is above the top
        # solid one. Full chunks have MOTION_BLOCKING for that; chunks short
        # of features have only the _WG maps, and nothing grows on them yet.
        floor = hm.get("OCEAN_FLOOR") or hm.get("OCEAN_FLOOR_WG")
        top = hm.get("MOTION_BLOCKING") if "OCEAN_FLOOR" in hm else hm.get("WORLD_SURFACE_WG")
        if not floor or not top:
            continue
        f, t = heightmap(floor[1]), heightmap(top[1])
        lx, lz = np.arange(256) % 16, np.arange(256) // 16
        X, Z = x * 16 + lx, z * 16 + lz
        dist = np.hypot(X - cx, Z - cz)
        keep = dist <= AROUND
        inv = (X >= bbox[0]) & (X <= bbox[3]) & (Z >= bbox[2]) & (Z <= bbox[5])
        ground.append(f[keep]); water.append((t > f)[keep]); inside.append(np.stack([f[inv], (t > f)[inv]]) if inv.any() else None)
        y = int(np.median(f))
        for s in c.get("sections", []):
            if s["Y"] == y >> 4 and "biomes" in s:
                cells = compare.unpack(s["biomes"], 64, 0, str)
                biomes.update(cells)
                if inv.any():
                    vill_biomes.update(cells)
    g = np.concatenate(ground)
    w = np.concatenate(water)
    vi = [a for a in inside if a is not None]
    vg = np.concatenate([a[0] for a in vi]) if vi else np.array([0])
    vw = np.concatenate([a[1] for a in vi]) if vi else np.array([0])
    return {
        "ground_around": [int(np.percentile(g, 2)), int(np.percentile(g, 98))],
        "relief_around": int(np.percentile(g, 98) - np.percentile(g, 2)),
        "water_around": round(float(w.mean()), 3),
        "ground_village": [int(np.percentile(vg, 5)), int(np.percentile(vg, 95))],
        "relief_village": int(np.percentile(vg, 95) - np.percentile(vg, 5)),
        "water_village": round(float(vw.mean()), 3),
        "biomes_around": {k.split(":")[-1]: round(v / sum(biomes.values()), 3) for k, v in biomes.most_common()},
        "biomes_village": {k.split(":")[-1]: round(v / sum(vill_biomes.values()), 3) for k, v in vill_biomes.most_common()},
        "structures_around": {k.split(":")[-1]: n for k, n in structures.items()},
        "columns_around": int(g.size),
    }


def closeup(preview, world, bbox, out):
    meta = json.load(open(os.path.join(world, "world.json")))
    ox, _, oz = meta["origin"]
    W, _, D = meta["size"]
    im = Image.open(os.path.join(preview, "map.png"))
    s = im.size[0] / W
    x0, z0 = max(0, bbox[0] - ox - 6), max(0, bbox[2] - oz - 6)
    x1, z1 = min(W, bbox[3] - ox + 7), min(D, bbox[5] - oz + 7)
    crop = im.crop((int(x0 * s), int(z0 * s), int(x1 * s), int(z1 * s)))
    k = max(1, int(round(600 / max(crop.size))))
    crop.resize((crop.size[0] * k, crop.size[1] * k), Image.NEAREST).save(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("villages")
    ap.add_argument("saves")
    ap.add_argument("out")
    ap.add_argument("--size", type=int, default=224)
    a = ap.parse_args()
    vs = json.load(open(a.villages))
    vs = vs["villages"] if isinstance(vs, dict) else vs
    records = []
    for v in vs:
        save = os.path.join(a.saves, v["id"])
        if not os.path.exists(os.path.join(save, "lerping-generate.json")):
            continue
        b = v["bbox"]
        cx, cz = (b[0] + b[3]) // 2, (b[2] + b[5]) // 2
        world = os.path.join(a.out, v["id"], "world")
        preview = os.path.join(a.out, v["id"], "preview")
        if not os.path.exists(os.path.join(world, "world.json")):
            log = os.path.join(a.out, v["id"], "bake.log")
            os.makedirs(os.path.dirname(log), exist_ok=True)
            with open(log, "w") as f:
                r = subprocess.run([sys.executable, "-I", os.path.join(HERE, "bake.py"), save, v["id"],
                                    f"--center={cx},{cz}", "--size", str(a.size), "--out", world],
                                   stdout=f, stderr=subprocess.STDOUT)
            if r.returncode:
                raise SystemExit(f"bake failed for {v['id']}: see {log}")
        if not os.path.exists(os.path.join(preview, "overlay.png")):
            subprocess.run([sys.executable, "-I", os.path.join(HERE, "preview_world.py"), world, preview],
                           check=True, stdout=subprocess.DEVNULL)
        closeup(preview, world, b, os.path.join(a.out, v["id"], "closeup.png"))
        meta = json.load(open(os.path.join(world, "world.json")))
        built = meta["counts"]["built_in_box"]
        short = {k.split(":")[-1]: n for k, n in built.items()}
        jobsites = collections.Counter()
        for k, n in short.items():
            if k in JOB_BLOCKS:
                jobsites[JOB_BLOCKS[k]] += n
        tc, tjobs, centre = classify_templates(v["templates"])
        rec = {
            "id": v["id"], "type": v["type"].split(":")[-1], "x": v["x"], "z": v["z"], "distance": v["distance"],
            "centre": [cx, cz], "bbox": b, "zombie": v["zombie"], "meeting_point": centre,
            "pieces": v["pieces"], **{k: tc.get(k, 0) for k in ("dwellings", "job_buildings", "farms", "pens",
                                                               "accessories", "other_buildings")},
            "job_buildings_by_kind": dict(tjobs),
            "beds": sum(n for k, n in short.items() if k.endswith("_bed")) // 2,
            "bells": short.get("bell", 0),
            "job_sites": dict(jobsites), "job_site_kinds": len(jobsites),
            "farmland": short.get("farmland", 0), "crops": sum(short.get(k, 0) for k in CROPS),
            "path": short.get("dirt_path", 0), "lights": sum(short.get(k, 0) for k in LIGHTS),
            "emitters": meta["counts"]["emitters"],
            "biomes_box": [s.split(":")[-1] for s in meta["tints"]["biomes"]],
            "box_notes": meta.get("box_notes", []), "routes": meta["routes"],
            "pictures": {"overlay": os.path.join(preview, "overlay.png"), "map": os.path.join(preview, "map.png"),
                         "closeup": os.path.join(a.out, v["id"], "closeup.png")},
        }
        rec.update(surroundings(save, cx, cz, b))
        records.append(rec)
        print(f"{rec['id']:28s} dw {rec['dwellings']:2d} beds {rec['beds']:2d} bell {rec['bells']} jobs {rec['job_site_kinds']:2d} "
              f"farms {rec['farms']:2d} path {rec['path']:4d} lights {rec['lights']:3d} relief v{rec['relief_village']:3d} "
              f"a{rec['relief_around']:3d} water v{rec['water_village']:.2f} a{rec['water_around']:.2f}", flush=True)
    json.dump(records, open(os.path.join(a.out, "survey.json"), "w"), indent=1)
    print(f"{len(records)} villages surveyed -> {os.path.join(a.out, 'survey.json')}", file=sys.stderr)


if __name__ == "__main__":
    main()
