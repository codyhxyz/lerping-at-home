"""3D Lerping@Home wordmark: extruded, bevelled Geist Bold in a studio of
softbox strips, rendered with a transparent background over the grid.

    Blender -b -P title3d/wordmark.py -- --look chrome --still 300 --out OUT.png
    Blender -b -P title3d/wordmark.py -- --look chrome --anim --out DIR/

Frames are 60 fps. Frame 0 is the title's first frame (16 beats = 433 frames).
The key strip crosses the letters once, between beats 6 and 14: that slow
glide is the only "shimmer".
"""
import argparse
import math
import os
import sys

import bpy
from mathutils import Vector

argv = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []
ap = argparse.ArgumentParser()
ap.add_argument('--look', default='chrome')
ap.add_argument('--still', type=int)
ap.add_argument('--anim', action='store_true')
ap.add_argument('--out', required=True)
ap.add_argument('--samples', type=int, default=96)
ap.add_argument('--size', default='1920x1080')
ap.add_argument('--bevel', type=float, default=0.022)
ap.add_argument('--extrude', type=float, default=0.07)
ap.add_argument('--env', default='studio')     # studio (procedural) or a Blender studiolight: city, interior, ...
ap.add_argument('--env-strength', type=float, default=1.0)
ap.add_argument('--elev', type=float, default=0.0)  # camera elevation, degrees
ap.add_argument('--rough', type=float)
ap.add_argument('--from', dest='first', type=int, default=0)
ap.add_argument('--pct', type=int, default=100)
ap.add_argument('--yaw', type=float, default=9.0)
ap.add_argument('--card', type=float, default=0.0)  # strength of the near-field gradient card; 0 = off
args = ap.parse_args(argv)

FONT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'title-assets', 'src', 'fonts', 'Geist-Bold.ttf')
FPS = 60
SPB = 60 / 133
FRAMES = round(16 * SPB * FPS)
beat = lambda n: round(n * SPB * FPS)

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
W, H = (int(v) for v in args.size.split('x'))
scene.render.resolution_x, scene.render.resolution_y = W, H
scene.render.fps = FPS
scene.frame_start, scene.frame_end = 0, FRAMES - 1
scene.render.engine = 'CYCLES'
scene.cycles.device = 'GPU'
prefs = bpy.context.preferences.addons['cycles'].preferences
prefs.compute_device_type = 'METAL'
prefs.get_devices()
for d in prefs.devices:
    d.use = True
scene.cycles.samples = args.samples
scene.cycles.use_denoising = True
scene.render.film_transparent = True
scene.render.resolution_percentage = args.pct
# Only the band the word (and its turn) can reach; the rest stays transparent.
scene.render.use_border, scene.render.use_crop_to_border = True, False
scene.render.border_min_y, scene.render.border_max_y = 0.26, 0.74
scene.view_settings.view_transform = 'AgX'
scene.view_settings.look = 'AgX - Medium High Contrast'
scene.render.image_settings.file_format = 'PNG'
scene.render.image_settings.color_mode = 'RGBA'

# ─── Text ────────────────────────────────────────────────────────────────────
curve = bpy.data.curves.new('wordmark', 'FONT')
curve.body = 'Lerping@Home'
curve.font = bpy.data.fonts.load(FONT)
curve.align_x, curve.align_y = 'CENTER', 'CENTER'
curve.space_character = 0.98
curve.size = 1.0
curve.extrude = args.extrude
curve.bevel_depth = args.bevel
curve.bevel_resolution = 8
curve.offset = -args.bevel
curve.resolution_u = 24
text = bpy.data.objects.new('wordmark', curve)
scene.collection.objects.link(text)
text.rotation_euler = (math.radians(90), 0, 0)   # stand up, facing -Y

# Fit: measure the ink width and scale so it spans a fixed world width.
bpy.context.view_layer.update()
xs = [(text.matrix_world @ Vector(c)).x for c in text.bound_box]
zs = [(text.matrix_world @ Vector(c)).z for c in text.bound_box]
INK = 6.0
s = INK / (max(xs) - min(xs))
text.scale = (s, s, s)
bpy.context.view_layer.update()
zs = [(text.matrix_world @ Vector(c)).z for c in text.bound_box]
text.location.z -= (max(zs) + min(zs)) / 2

# ─── Camera: ink spans 1380 of 1920 px ───────────────────────────────────────
cam_data = bpy.data.cameras.new('cam')
cam_data.lens = 85
cam_data.sensor_width = 36
cam = bpy.data.objects.new('cam', cam_data)
scene.collection.objects.link(cam)
scene.camera = cam
half_fov = math.atan(cam_data.sensor_width / 2 / cam_data.lens)
dist = (INK / 2) / math.tan(half_fov) * (1920 / 1380)
e = math.radians(args.elev)
cam.location = (0, -dist * math.cos(e), dist * math.sin(e))
cam.rotation_euler = (math.radians(90) - e, 0, 0)

# ─── Studio ──────────────────────────────────────────────────────────────────
def strip(name, loc, size, strength, color=(1, 1, 1)):
    bpy.ops.mesh.primitive_plane_add(size=1, location=loc)
    o = bpy.context.active_object
    o.name = name
    o.scale = (size[0], size[1], 1)
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    em = nt.nodes.new('ShaderNodeEmission')
    em.inputs['Color'].default_value = (*color, 1)
    em.inputs['Strength'].default_value = strength
    out = nt.nodes.new('ShaderNodeOutputMaterial')
    nt.links.new(em.outputs[0], out.inputs[0])
    o.data.materials.append(m)
    o.visible_camera = False
    o.visible_shadow = False
    # face the wordmark
    d = Vector((0, 0, 0)) - o.location
    o.rotation_euler = d.to_track_quat('Z', 'Y').to_euler()
    return o

world = bpy.data.worlds.new('world')
scene.world = world
world.use_nodes = True
wn = world.node_tree
wn.nodes.clear()
tc = wn.nodes.new('ShaderNodeTexCoord')
sep = wn.nodes.new('ShaderNodeSeparateXYZ')
ramp = wn.nodes.new('ShaderNodeValToRGB')
bg = wn.nodes.new('ShaderNodeBackground')
wo = wn.nodes.new('ShaderNodeOutputWorld')
wn.links.new(tc.outputs['Generated'], sep.inputs[0])
mr = wn.nodes.new('ShaderNodeMapRange')
mr.inputs['From Min'].default_value = -1.0
wn.links.new(sep.outputs['Z'], mr.inputs['Value'])
wn.links.new(mr.outputs[0], ramp.inputs[0])
if args.env == 'studio':
    wn.links.new(ramp.outputs[0], bg.inputs[0])
else:
    import glob
    env = wn.nodes.new('ShaderNodeTexEnvironment')
    env.image = bpy.data.images.load(glob.glob(f'/Applications/Blender.app/Contents/Resources/*/datafiles/studiolights/world/{args.env}.exr')[0])
    wn.links.new(env.outputs[0], bg.inputs[0])
wn.links.new(bg.outputs[0], wo.inputs[0])
# A dark floor, a horizon that is barely there and a soft grey sky: the flat
# faces read as metal because they reflect this gradient, not a single colour.
el = ramp.color_ramp.elements
el[0].position, el[0].color = 0.30, (0.004, 0.004, 0.005, 1)
el[1].position, el[1].color = 0.62, (0.55, 0.56, 0.6, 1)
mid = el.new(0.495)
mid.color = (0.035, 0.036, 0.04, 1)
bg.inputs['Strength'].default_value = args.env_strength

key = strip('key', (-9, -14, 4.5), (0.9, 14), 22)          # tall strip, slides across
top = strip('top', (0, -6, 9), (24, 1.2), 9)                # long overhead strip: lit top bevels
rim = strip('rim', (0, 7, 1.5), (24, 0.6), 30)              # behind: edge highlight
low = strip('low', (0, -10, -6), (24, 2.5), 1.2, (0.75, 0.82, 1.0))  # faint cool bounce

# The key strip glides left to right once, beats 6 → 14, and keeps facing the word.
key.location = (-12, -14, 4.5)
key.keyframe_insert('location', frame=beat(6))
key.location = (12, -14, 4.5)
key.keyframe_insert('location', frame=beat(14))
for fc in key.animation_data.action.fcurves if hasattr(key.animation_data.action, 'fcurves') else []:
    for kp in fc.keyframe_points:
        kp.interpolation = 'SINE'
        kp.easing = 'EASE_IN_OUT'
con = key.constraints.new('TRACK_TO')
con.target = text
con.track_axis, con.up_axis = 'TRACK_Z', 'UP_Y'

def card(name, loc, size, rot_y, strength, stops, soft_x=False):
    """An emissive plane between camera and word (invisible to the camera).
    The flat letter faces mirror it almost 1:1, so `stops` (world-z, value),
    top to bottom, become a vertical gradient painted across every letter."""
    bpy.ops.mesh.primitive_plane_add(size=1, location=loc, rotation=(math.radians(-90), math.radians(rot_y), 0))
    o = bpy.context.active_object
    o.name = name
    o.scale = (size[0], size[1], 1)
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    tcn = nt.nodes.new('ShaderNodeTexCoord')
    sp = nt.nodes.new('ShaderNodeSeparateXYZ')
    nt.links.new(tcn.outputs['Generated'], sp.inputs[0])
    rp = nt.nodes.new('ShaderNodeValToRGB')
    rp.color_ramp.interpolation = 'B_SPLINE'
    # Generated Y is 0 at the top edge after the -90° turn; convert to world z.
    els = rp.color_ramp.elements
    for i, (z, v) in enumerate(stops):
        pos = 0.5 - z / size[1]
        e = els[i] if i < 2 else els.new(pos)
        e.position, e.color = pos, (v, v, v, 1)
    nt.links.new(sp.outputs['Y'], rp.inputs[0])
    em = nt.nodes.new('ShaderNodeEmission')
    em.inputs['Strength'].default_value = strength
    nt.links.new(rp.outputs[0], em.inputs['Color'])
    out = nt.nodes.new('ShaderNodeOutputMaterial')
    if soft_x:
        # Feathered sides: transparent at the edges, full at the centre.
        mth = nt.nodes.new('ShaderNodeMath'); mth.operation = 'PINGPONG'; mth.inputs[1].default_value = 0.5
        nt.links.new(sp.outputs['X'], mth.inputs[0])
        sm = nt.nodes.new('ShaderNodeMapRange'); sm.interpolation_type = 'SMOOTHERSTEP'
        sm.inputs['From Max'].default_value = 0.5
        nt.links.new(mth.outputs[0], sm.inputs['Value'])
        tr = nt.nodes.new('ShaderNodeBsdfTransparent')
        mix = nt.nodes.new('ShaderNodeMixShader')
        nt.links.new(sm.outputs[0], mix.inputs[0])
        nt.links.new(tr.outputs[0], mix.inputs[1])
        nt.links.new(em.outputs[0], mix.inputs[2])
        nt.links.new(mix.outputs[0], out.inputs[0])
    else:
        nt.links.new(em.outputs[0], out.inputs[0])
    o.data.materials.append(m)
    o.visible_camera = False
    o.visible_shadow = False
    return o

if args.card:
    # Bright sky over the top third, a soft dark "horizon" just above the
    # midline, a grey floor glow below: the classic read of polished metal,
    # but as smooth bands rather than a busy environment.
    card('card', (0, -3.2, 0), (16, 3.2), 0, args.card, [
        (1.6, 0.55), (0.75, 1.0), (0.38, 0.85), (0.12, 0.05), (-0.18, 0.03), (-0.5, 0.22), (-1.6, 0.5)])
    # The one shimmer: a soft diagonal sheet of light glides across, beats 6 → 14.
    sweep = card('sweep', (-7, -3.0, 0), (1.1, 3.2), -18, args.card * 2.2,
                 [(1.6, 1.0), (-1.6, 1.0)], soft_x=True)
    sweep.keyframe_insert('location', frame=beat(6))
    sweep.location.x = 7
    sweep.keyframe_insert('location', frame=beat(14))

# The word turns slowly to face the camera (yaw 9° → 0) as the title lands
# and settles, which shows its depth and makes the reflections travel.
text.rotation_euler.z = math.radians(args.yaw)
text.keyframe_insert('rotation_euler', frame=beat(4))
text.rotation_euler.z = 0
text.keyframe_insert('rotation_euler', frame=FRAMES - 1)

# Barely-there camera drift so the reflections never freeze.
cam.keyframe_insert('location', frame=0)
cam.location = Vector(cam.location) * 0.985
cam.keyframe_insert('location', frame=FRAMES - 1)

# ─── Materials ───────────────────────────────────────────────────────────────
mat = bpy.data.materials.new('metal')
mat.use_nodes = True
p = mat.node_tree.nodes['Principled BSDF']
p.inputs['Metallic'].default_value = 1.0
LOOKS = {
    # polished, neutral: product-render chrome
    'chrome':   dict(base=(0.96, 0.96, 0.97), rough=0.06),
    # iPhone Pro titanium: warm grey, brushed (anisotropic), satin
    'titanium': dict(base=(0.70, 0.67, 0.63), rough=0.22, aniso=0.85),
    # black chrome: dark, high contrast, lacquered
    'black':    dict(base=(0.16, 0.16, 0.17), rough=0.08, coat=1.0),
    # bead-blasted aluminium: bright, soft, the MacBook shell
    'aluminium': dict(base=(0.91, 0.92, 0.93), rough=0.32),
    # chrome with a thin-film sheen: faint oil-on-water colour on the turns
    'spectral': dict(base=(0.93, 0.93, 0.95), rough=0.07, film=420),
}
L = LOOKS[args.look]
p.inputs['Base Color'].default_value = (*L['base'], 1)
p.inputs['Roughness'].default_value = args.rough if args.rough is not None else L['rough']
if 'aniso' in L:
    p.inputs['Anisotropic'].default_value = L['aniso']
if 'coat' in L:
    p.inputs['Coat Weight'].default_value = L['coat']
    p.inputs['Coat Roughness'].default_value = 0.02
if 'film' in L:
    p.inputs['Thin Film Thickness'].default_value = L['film']
    p.inputs['Thin Film IOR'].default_value = 1.45
text.data.materials.append(mat)

if args.still is not None:
    scene.frame_set(args.still)
    scene.render.filepath = args.out
    bpy.ops.render.render(write_still=True)
elif args.anim:
    scene.frame_start = args.first
    scene.render.filepath = args.out.rstrip('/') + '/f'
    bpy.ops.render.render(animation=True)
