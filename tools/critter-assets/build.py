# Builds the critter's models and writes them as .usdz for SceneKit.
#
#   Blender -b --factory-startup --python tools/critter-assets/build.py -- OUT_DIR [--sheet DIR]
#
# OUT_DIR receives critter.usdz, egg.usdz, trees.usdz, flowers.usdz,
# clouds.usdz, butterfly.usdz, props.usdz. --sheet also renders Workbench
# contact sheets (600x375) of every model into DIR, after the export, with
# preview-only poses that are not written to the files.
import os
import sys

sys.dont_write_bytecode = True   # no __pycache__ in the source tree

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bpy  # noqa: E402
from mathutils import Vector  # noqa: E402
import lib  # noqa: E402
import models as M  # noqa: E402

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
OUT = os.path.abspath(argv[0] if argv else "Sources/Critter")
SHEET = None
if "--sheet" in argv:
    SHEET = os.path.abspath(argv[argv.index("--sheet") + 1])
VIEWS = None   # --views critter,face,trees,small,flowers (default: all)
if "--views" in argv:
    VIEWS = set(argv[argv.index("--views") + 1].split(","))


def want(v):
    return VIEWS is None or v in VIEWS

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene

GROUPS = [
    ("critter", [M.build_critter]),
    ("egg", [M.build_egg, M.build_nest]),
    ("trees", [M.build_tree_round, M.build_tree_pine, M.build_tree_fruit]),
    ("flowers", [M.build_flower_daisy, M.build_flower_tulip, M.build_flower_bell]),
    ("clouds", [M.build_cloud_puff, M.build_cloud_storm]),
    ("butterfly", [M.build_butterfly]),
    ("props", [M.build_castle, M.build_rock_a, M.build_rock_b]),
]

os.makedirs(OUT, exist_ok=True)
ROOTS = {}
total = 0
for fname, builders in GROUPS:
    col = bpy.data.collections.new(fname)
    scene.collection.children.link(col)
    roots = [b(col) for b in builders]
    for r in roots:
        ROOTS[lib.uname(r)] = r
    path = os.path.join(OUT, fname + ".usdz")
    tris = lib.export_usdz(path, roots)
    total += tris
    print(f"wrote {path}: {tris} triangles, {os.path.getsize(path) / 1024:.0f} KB")
print(f"total triangles: {total}")


# ---------------------------------------------------------------- contact sheets

def dup_tree(root, offset=(0, 0, 0)):
    """Linked copy of a hierarchy (preview only)."""
    def rec(ob, parent):
        c = ob.copy()
        scene.collection.objects.link(c)
        c.parent = parent
        for k in ob.children:
            rec(k, c)
        return c
    c = rec(root, None)
    c.location = Vector(offset)
    return c


def child(root, name):
    for o in root.children_recursive:
        if lib.uname(o) == name:
            return o
    raise KeyError(name)


def pose_critter(r, arm=0.55):
    # +Y rotation swings armL (at -X) outward; tip it forward a little too
    child(r, "armL").rotation_euler = (0.3, arm, 0)
    child(r, "armR").rotation_euler = (0.3, -arm, 0)


def setup_render():
    scene.render.engine = 'BLENDER_WORKBENCH'
    scene.render.resolution_x, scene.render.resolution_y = 600, 375
    scene.render.resolution_percentage = 100
    sh = scene.display.shading
    sh.light = 'STUDIO'
    sh.color_type = 'MATERIAL'
    sh.show_object_outline = True
    sh.object_outline_color = (0.12, 0.09, 0.16)
    sh.show_cavity = True
    sh.cavity_type = 'BOTH'
    sh.show_shadows = True
    sh.shadow_intensity = 0.35
    scene.display.light_direction = (0.45, -0.35, 0.82)
    if scene.world is None:
        scene.world = bpy.data.worlds.new("w")
    scene.world.color = (0.62, 0.8, 0.92)
    scene.render.image_settings.file_format = 'PNG'
    scene.view_settings.view_transform = 'Standard'


def camera(loc, target, lens=50, ortho=None):
    cam = bpy.data.objects.get("cam")
    if cam is None:
        cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
        scene.collection.objects.link(cam)
    cam.location = Vector(loc)
    d = Vector(target) - Vector(loc)
    cam.rotation_euler = d.to_track_quat('-Z', 'Y').to_euler()
    cam.data.lens = lens
    if ortho:
        cam.data.type = 'ORTHO'
        cam.data.ortho_scale = ortho
    else:
        cam.data.type = 'PERSP'
    scene.camera = cam


def ground(size=40):
    if bpy.data.objects.get("ground"):
        return
    import bmesh
    bm = bmesh.new()
    bmesh.ops.create_grid(bm, x_segments=1, y_segments=1, size=size)
    me = bpy.data.meshes.new("ground")
    bm.to_mesh(me)
    mat = bpy.data.materials.new("groundPreview")
    mat.diffuse_color = (0.25, 0.6, 0.18, 1)
    me.materials.append(mat)
    ob = bpy.data.objects.new("ground", me)
    scene.collection.objects.link(ob)


def show_only(objs):
    keep = set()
    for o in objs:
        keep.add(o.name)
        for c in o.children_recursive:
            keep.add(c.name)
    keep |= {"cam", "ground"}
    for o in scene.objects:
        o.hide_render = o.name not in keep


def render(path):
    scene.render.filepath = path
    bpy.ops.render.render(write_still=True)
    print("rendered", path)


if SHEET:
    os.makedirs(SHEET, exist_ok=True)
    setup_render()
    ground()
    for col in bpy.data.collections:
        for o in col.objects:
            pass
    R = ROOTS

    # 1: the critter, three-quarter and side, grown (blossom) with posed arms
    c1 = R["critter"]
    pose_critter(c1)
    c1.location = (0, 0, 0)
    c1.rotation_euler = (0, 0, -0.45)
    c2 = dup_tree(c1, (2.6, 0.6, 0))
    c2.rotation_euler = (0, 0, -1.57)
    pose_critter(c2, 1.2)
    c3 = dup_tree(c1, (-2.5, 0.6, 0))
    c3.rotation_euler = (0, 0, 2.6)
    child(c3, "blossom").hide_render = True
    show_only([c1, c2, c3])
    child(c3, "blossom").hide_render = True
    camera((0.2, -7.2, 2.6), (0.05, 0, 1.0), lens=42)
    if want("critter"):
        render(os.path.join(SHEET, "critter.png"))

    # 2: close on the face
    show_only([c1])
    c1.rotation_euler = (0, 0, -0.25)
    camera((0.4, -3.4, 1.7), (0.0, 0, 1.15), lens=50)
    if want("face"):
        render(os.path.join(SHEET, "face.png"))
    c1.rotation_euler = (0, 0, -0.45)

    # 3: trees, castle, rocks
    R["treeRound"].location = (-1.9, 0, 0)
    R["treePine"].location = (0, 0.4, 0)
    R["treeFruit"].location = (1.9, 0, 0)
    R["rockA"].location = (-1.0, -1.1, 0)
    R["rockA"].scale = (0.35,) * 3
    R["rockB"].location = (1.05, -1.1, 0)
    R["rockB"].scale = (0.35,) * 3
    R["castle"].location = (0.0, -1.2, 0)
    R["castle"].scale = (1.3,) * 3
    show_only([R[k] for k in ("treeRound", "treePine", "treeFruit", "rockA", "rockB", "castle")])
    camera((0, -6.8, 2.2), (0, 0, 0.95), lens=40)
    if want("trees"):
        render(os.path.join(SHEET, "trees.png"))

    # 4: flowers, butterfly, egg+nest, clouds (each scaled to read)
    for k, x, s in (("flowerDaisy", -1.25, 3.4), ("flowerTulip", -0.7, 3.4), ("flowerBell", -0.15, 3.4)):
        R[k].location = (x, 0, 0)
        R[k].scale = (s,) * 3
    R["egg"].location = (0.55, 0, 0)
    R["nest"].location = (0.55, 0, 0)
    R["butterfly"].location = (1.35, -0.1, 0.45)
    R["butterfly"].scale = (3.0,) * 3
    R["butterfly"].rotation_euler = (0.5, 0, 0.3)
    child(R["butterfly"], "wingL").rotation_euler = (0, 0.45, 0)
    child(R["butterfly"], "wingR").rotation_euler = (0, -0.45, 0)
    R["cloudPuff"].location = (-0.75, 1.8, 1.45)
    R["cloudPuff"].scale = (0.42,) * 3
    R["cloudStorm"].location = (0.9, 1.6, 1.55)
    R["cloudStorm"].scale = (0.75,) * 3
    show_only([R[k] for k in ("flowerDaisy", "flowerTulip", "flowerBell", "egg", "nest",
                              "butterfly", "cloudPuff", "cloudStorm")])
    camera((0.05, -4.6, 1.5), (0.05, 0.5, 0.75), lens=40)
    if want("small"):
        render(os.path.join(SHEET, "small.png"))

    # 5: the egg, nest and flowers close
    show_only([R[k] for k in ("flowerDaisy", "flowerTulip", "flowerBell", "egg", "nest")])
    camera((-0.3, -2.4, 0.95), (-0.3, 0, 0.35), lens=50)
    if want("flowers"):
        render(os.path.join(SHEET, "flowers.png"))
