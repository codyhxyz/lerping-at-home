#!/usr/bin/env python3 -I
# Flattens the game's own baked entity models (dumped by Dump.java from the
# installed client jar) into the MSL tables of the mobs kit, and writes the
# whole kit: header.metal, the tables, funcs.metal. Run by build.sh:
#
#   gen.py --layers                       the model layers Dump.java must dump
#   gen.py MODELS ATLAS TEXTURES VERSION OUT
#
# MODELS is Dump.java's output, ATLAS the atlas.txt of `make minecraft`,
# TEXTURES the unpacked assets/minecraft/textures directory, VERSION the
# game version named in the kit, OUT the mobs.metal to write.
import re, sys, math, os

def die(msg):
    sys.stderr.write('minecraft-mobs: ' + msg + '\n'); sys.exit(1)

HERE = os.path.dirname(os.path.abspath(__file__))
if sys.argv[1:] != ['--layers']:
    if len(sys.argv) != 6: die('usage: gen.py --layers | gen.py MODELS ATLAS TEXTURES VERSION OUT')
    try:
        import numpy as np
    except ImportError:
        die('numpy is missing (python3 -m pip install numpy)')
    try:
        from PIL import Image
    except ImportError:
        die('Pillow is missing (python3 -m pip install Pillow)')
    MODELS, ATLAS, TEXTURES, VERSION, OUT = sys.argv[1:]
    TEX = os.path.join(TEXTURES, 'entity') + '/'

# ---------------------------------------------------------------- parse dump
class Part:
    def __init__(s, name, pos, rot, scale, depth):
        s.name, s.pos, s.rot, s.scale, s.depth = name, pos, rot, scale, depth
        s.cubes, s.children = [], []

def floats(t): return [float(x) for x in t.split(',')]

layers = {}
cur = None; stack = []
for line in (open(MODELS) if sys.argv[1:] != ['--layers'] else []):
    if line.startswith('LAYER'):
        m = re.match(r'LAYER minecraft:(\S+) tex=(\d+)x(\d+)', line)
        cur = m.group(1); layers[cur] = {'tex': (int(m.group(2)), int(m.group(3))), 'root': None}
        stack = []; continue
    ind = len(line) - len(line.lstrip(' '))
    s = line.strip()
    if s.startswith('P '):
        m = re.match(r'P (\S+) pos=(\S+) rot=(\S+) scale=(\S+) vis=(\S+)', s)
        depth = ind // 2
        p = Part(m.group(1), floats(m.group(2)), floats(m.group(3)), floats(m.group(4)), depth)
        p.visible = m.group(5) == 'true'
        while stack and stack[-1].depth >= depth: stack.pop()
        if stack: stack[-1].children.append(p)
        else: layers[cur]['root'] = p
        stack.append(p)
    elif s.startswith('C '):
        m = re.match(r'C min=(\S+) max=(\S+)', s)
        stack[-1].cubes.append({'lo': floats(m.group(1)), 'hi': floats(m.group(2)), 'faces': []})
    elif s.startswith('F '):
        m = re.match(r'F n=(\S+) (.*)', s)
        n = floats(m.group(1))
        verts = []
        for v in re.findall(r'\[([^|]+)\|([^\]]+)\]', m.group(2)):
            verts.append((floats(v[0]), floats(v[1])))
        stack[-1].cubes[-1]['faces'].append((n, verts))
        allv = [v[0] for _, vs in stack[-1].cubes[-1]['faces'] for v in vs]
        stack[-1].cubes[-1]['lo'] = [min(v[i] for v in allv) for i in range(3)]
        stack[-1].cubes[-1]['hi'] = [max(v[i] for v in allv) for i in range(3)]

# ---------------------------------------------------------------- matrices
def T(p): m = np.eye(4); m[:3, 3] = p; return m
def Rx(a): c, s = math.cos(a), math.sin(a); return np.array([[1,0,0,0],[0,c,-s,0],[0,s,c,0],[0,0,0,1]])
def Ry(a): c, s = math.cos(a), math.sin(a); return np.array([[c,0,s,0],[0,1,0,0],[-s,0,c,0],[0,0,0,1]])
def Rz(a): c, s = math.cos(a), math.sin(a); return np.array([[c,-s,0,0],[s,c,0,0],[0,0,1,0],[0,0,0,1]])
def R(e): return Rz(e[2]) @ Ry(e[1]) @ Rx(e[0])
def Sc(s): return np.diag([s[0], s[1], s[2], 1.0])
def local(p): return T(p.pos) @ R(p.rot) @ Sc(p.scale)

# ---------------------------------------------------------------- atlas
def read_atlas():
    names = set()
    for line in open(ATLAS):
        m = re.match(r'(MC[SM]_\w+)\s', line)
        if m: names.add(m.group(1))
    return names

_alpha = {}
def tex_alpha(path):
    if path not in _alpha:
        if not os.path.exists(TEX + path): die('texture missing: entity/' + path + ' (run make minecraft for this version)')
        _alpha[path] = np.array(Image.open(TEX + path).convert('RGBA'))[:, :, 3]
    return _alpha[path]

# ---------------------------------------------------------------- the mobs
PI = math.pi
QUAD = {'right_hind_leg': [('swing', 1.4)], 'left_hind_leg': [('swing', -1.4)],
        'right_front_leg': [('swing', -1.4)], 'left_front_leg': [('swing', 1.4)]}
BIPED = {'right_leg': [('swing', 1.4)], 'left_leg': [('swing', -1.4)],
         'right_arm': [('swing', -1.0)], 'left_arm': [('swing', 1.0)]}
def head(graze=0.0): return [('head', graze)]
def merge(*ds):
    out = {}
    for d in ds:
        for k, v in d.items(): out[k] = out.get(k, []) + v
    return out

# name, layers (main, fur), skins to scan for alpha, anim map, notes
MOBS = [
 ('VILLAGER', ['villager#main'], None, ['villager/villager.png'],
    merge({'head': head(0.0)}, {'right_leg': [('swing', 0.7)], 'left_leg': [('swing', -0.7)]})),
 ('VILLAGER_BABY', ['villager_baby#main'], None, ['villager/villager_baby.png'],
    merge({'head': head(0.0)}, {'right_leg': [('swing', 1.4)], 'left_leg': [('swing', -1.4)]})),
 ('PIG', ['pig#main'], None, ['pig/pig_temperate.png', 'pig/pig_warm.png'], merge({'head': head(0.6)}, QUAD)),
 ('PIG_COLD', ['cold_pig#main'], None, ['pig/pig_cold.png'], merge({'head': head(0.6)}, QUAD)),
 ('PIG_BABY', ['pig_baby#main'], None, ['pig/pig_temperate_baby.png', 'pig/pig_cold_baby.png', 'pig/pig_warm_baby.png'], merge({'head': head(0.6)}, QUAD)),
 ('COW', ['cow#main'], None, ['cow/cow_temperate.png', 'cow/mooshroom_red.png', 'cow/mooshroom_brown.png'], merge({'head': head(0.9)}, QUAD)),
 ('COW_COLD', ['cold_cow#main'], None, ['cow/cow_cold.png'], merge({'head': head(0.9)}, QUAD)),
 ('COW_WARM', ['warm_cow#main'], None, ['cow/cow_warm.png'], merge({'head': head(0.9)}, QUAD)),
 ('COW_BABY', ['cow_baby#main'], None, ['cow/cow_temperate_baby.png', 'cow/mooshroom_red_baby.png', 'cow/mooshroom_brown_baby.png'], merge({'head': head(0.9)}, QUAD)),
 ('COW_COLD_BABY', ['cold_cow_baby#main'], None, ['cow/cow_cold_baby.png'], merge({'head': head(0.9)}, QUAD)),
 ('COW_WARM_BABY', ['warm_cow_baby#main'], None, ['cow/cow_warm_baby.png'], merge({'head': head(0.9)}, QUAD)),
 ('SHEEP', ['sheep#main'], 'sheep#wool', ['sheep/sheep.png'], merge({'head': head(1.0)}, QUAD), ['sheep/sheep_wool.png']),
 ('SHEEP_BABY', ['sheep_baby#main'], 'sheep_baby#wool', ['sheep/sheep_baby.png'], merge({'head': head(1.0)}, QUAD), ['sheep/sheep_wool_baby.png']),
 ('CHICKEN', ['chicken#main'], None, ['chicken/chicken_temperate.png', 'chicken/chicken_warm.png'],
    merge({'head': head(0.8), 'right_leg': [('swing', 1.4)], 'left_leg': [('swing', -1.4)],
           'right_wing': [('flap', (0, 0, 1.0))], 'left_wing': [('flap', (0, 0, -1.0))]})),
 ('CHICKEN_COLD', ['cold_chicken#main'], None, ['chicken/chicken_cold.png'],
    merge({'head': head(0.8), 'right_leg': [('swing', 1.4)], 'left_leg': [('swing', -1.4)],
           'right_wing': [('flap', (0, 0, 1.0))], 'left_wing': [('flap', (0, 0, -1.0))]})),
 ('CHICKEN_BABY', ['chicken_baby#main'], None, ['chicken/chicken_temperate_baby.png', 'chicken/chicken_cold_baby.png', 'chicken/chicken_warm_baby.png'],
    merge({'body': head(0.5), 'right_leg': [('swing', 1.4)], 'left_leg': [('swing', -1.4)],
           'right_wing': [('flap', (0, 0, -1.0))], 'left_wing': [('flap', (0, 0, 1.0))]})),
 ('WOLF', ['wolf#main'], None, ['wolf/wolf.png', 'wolf/wolf_black.png', 'wolf/wolf_snowy.png'],
    merge({'head': head(0.5), 'tail': [('wag', 0.6)]}, QUAD)),
 ('WOLF_BABY', ['wolf_baby#main'], None, ['wolf/wolf_baby.png', 'wolf/wolf_snowy_baby.png'],
    merge({'head': head(0.5), 'tail': [('wag', 0.6)]}, QUAD)),
 ('CAT', ['cat#main'], None, ['cat/cat_tabby.png', 'cat/cat_black.png', 'cat/cat_siamese.png', 'cat/ocelot.png'],
    merge({'head': head(0.4), 'tail1': [('wag', 0.3)], 'tail2': [('rest', (1.7279, 0, 0))]},
          {k: [('swing', v[0][1] / 1.4)] for k, v in QUAD.items()})),
 ('CAT_BABY', ['cat_baby#main'], None, ['cat/cat_tabby_baby.png', 'cat/cat_black_baby.png', 'cat/ocelot_baby.png'],
    merge({'head': head(0.4), 'tail1': [('wag', 0.3)]}, QUAD)),
 ('FOX', ['fox#main'], None, ['fox/fox.png', 'fox/fox_snow.png'],
    merge({'head': head(0.5), 'tail': [('wag', 0.4)]}, QUAD)),
 ('FOX_BABY', ['fox_baby#main'], None, ['fox/fox_baby.png', 'fox/fox_snow_baby.png'],
    merge({'head': head(0.5), 'tail': [('wag', 0.4)]}, QUAD)),
 ('BEE', ['bee#main'], None, ['bee/bee.png', 'bee/bee_nectar.png'],
    {'right_wing': [('rest', (0, -0.2618, 0)), ('flap', (0, 0, 0.47))], 'left_wing': [('rest', (0, 0.2618, 0)), ('flap', (0, 0, -0.47))],
     'front_legs': [('rest', (PI / 4, 0, 0))], 'middle_legs': [('rest', (PI / 4, 0, 0))], 'back_legs': [('rest', (PI / 4, 0, 0))]}),
 ('BEE_BABY', ['bee_baby#main'], None, ['bee/bee_baby.png', 'bee/bee_nectar_baby.png'],
    {'right_wing': [('flap', (0, 0, 0.47))], 'left_wing': [('flap', (0, 0, -0.47))]}),
 ('HORSE', ['horse#main'], None, ['horse/horse_white.png', 'horse/horse_brown.png', 'horse/horse_black.png', 'horse/horse_gray.png', 'horse/horse_creamy.png', 'horse/horse_chestnut.png', 'horse/horse_darkbrown.png'],
    merge({'head_parts': head(1.6), 'tail': [('wag', 0.3)]}, QUAD)),
 ('HORSE_BABY', ['horse_baby#main'], None, ['horse/horse_brown_baby.png', 'horse/horse_white_baby.png'],
    merge({'head_parts': head(1.4), 'tail': [('wag', 0.3)]}, QUAD)),
 ('DONKEY', ['donkey#main'], None, ['horse/donkey.png', 'horse/mule.png'],
    merge({'head_parts': head(1.6), 'tail': [('wag', 0.3)]}, QUAD)),
 ('DONKEY_BABY', ['donkey_baby#main'], None, ['horse/donkey_baby.png', 'horse/mule_baby.png'],
    merge({'head_parts': head(1.4), 'tail': [('wag', 0.3)]}, QUAD)),
 ('IRON_GOLEM', ['iron_golem#main'], None, ['iron_golem/iron_golem.png'],
    {'head': head(0.0), 'right_leg': [('swing', -1.0)], 'left_leg': [('swing', 1.0)],
     'right_arm': [('swing', 1.0)], 'left_arm': [('swing', -1.0)]}),
 ('ZOMBIE', ['zombie#main'], None, ['zombie/zombie.png', 'zombie/husk.png'],
    merge({'head': head(0.0)}, {'right_leg': [('swing', 1.4)], 'left_leg': [('swing', -1.4)],
           'right_arm': [('rest', (-1.45, -0.1, 0))], 'left_arm': [('rest', (-1.45, 0.1, 0))]})),
 ('ZOMBIE_BABY', ['zombie_baby#main'], None, ['zombie/zombie_baby.png', 'zombie/husk_baby.png'],
    merge({'head': head(0.0)}, {'right_leg': [('swing', 1.4)], 'left_leg': [('swing', -1.4)],
           'right_arm': [('rest', (-1.45, -0.1, 0))], 'left_arm': [('rest', (-1.45, 0.1, 0))]})),
 ('SKELETON', ['skeleton#main'], None, ['skeleton/skeleton.png', 'skeleton/stray.png', 'skeleton/wither_skeleton.png'],
    merge({'head': head(0.0)}, BIPED)),
 ('CREEPER', ['creeper#main'], None, ['creeper/creeper.png'], merge({'head': head(0.0)}, QUAD)),
 ('ENDERMAN', ['enderman#main'], None, ['enderman/enderman.png'],
    {'head': head(0.0), 'right_leg': [('swing', 0.7)], 'left_leg': [('swing', -0.7)],
     'right_arm': [('swing', -0.5)], 'left_arm': [('swing', 0.5)]}),
 ('ALLAY', ['allay#main'], None, ['allay/allay.png'],
    {'head': head(0.0), 'right_wing': [('rest', (0.4363, -0.7854, 0)), ('flap', (0, 0.6, 0))],
     'left_wing': [('rest', (0.4363, 0.7854, 0)), ('flap', (0, -0.6, 0))],
     'right_arm': [('rest', (0.6, 0, 0))], 'left_arm': [('rest', (0.6, 0, 0))]}),
 ('PARROT', ['parrot#main'], None, ['parrot/parrot_red_blue.png', 'parrot/parrot_blue.png', 'parrot/parrot_green.png', 'parrot/parrot_yellow_blue.png', 'parrot/parrot_grey.png'],
    {'head': head(0.0), 'right_wing': [('flap', (0, 0, 0.7))], 'left_wing': [('flap', (0, 0, -0.7))],
     'right_leg': [('swing', 1.0)], 'left_leg': [('swing', -1.0)], 'tail': [('wag', 0.2)]}),
 ('BAT', ['bat#main'], None, ['bat/bat.png'],
    {'head': head(0.0), 'right_wing': [('flap', (0, 1.1, 0))], 'left_wing': [('flap', (0, -1.1, 0))]}),
]

if sys.argv[1:] == ['--layers']:
    print(' '.join(sorted({'minecraft:' + l for spec in MOBS for l in spec[1] + ([spec[2]] if spec[2] else [])})))
    sys.exit(0)
for spec in MOBS:
    for l in spec[1] + ([spec[2]] if spec[2] else []):
        if l not in layers: die('the dump has no model layer ' + l + ' (the game\'s classes have moved)')
# every skin the kit's functions name must be in this atlas
_atlas = read_atlas()
for name in sorted(set(re.findall(r'\bMC[SM]_[A-Z0-9_]*[A-Z0-9]\b', re.sub(r'//[^\n]*', '', open(os.path.join(HERE, 'funcs.metal')).read())))):
    if name not in _atlas: die(name + ' is not in ' + ATLAS + ' (run make minecraft for this version)')

# ---------------------------------------------------------------- flatten
HIDDEN = {'right_chest', 'left_chest'}   # a donkey's chests show only when it carries them
def flatten(layer_name, anim, slot):
    """Bones keyed by (animated part path, post matrix); returns list of dicts."""
    root = layers[layer_name]['root']
    out = []
    def walk(p, path, static, anc):
        L = local(p)
        name = p.name
        if anc is None and name in anim:
            spec = anim[name]
            rest = list(p.rot)
            for k, v in spec:
                if k == 'rest': rest = [rest[i] + v[i] for i in range(3)]
            a = {'Q': static @ T(p.pos), 'rest': rest, 'spec': spec, 'key': path + '/' + name}
            post = Sc(p.scale)
            me = (a, post)
        elif anc is not None:
            a, ppost = anc
            post = ppost @ L
            me = (a, post)
        else:
            static2 = static @ L
            me = None
        for c in p.cubes:
            if not p.visible or p.name in HIDDEN: continue
            if me is None:
                out.append(({'Q': np.eye(4), 'rest': [0, 0, 0], 'spec': [], 'key': '<static>'}, static2, c, path + '/' + name))
            else:
                out.append((me[0], me[1], c, path + '/' + name))
        for ch in p.children:
            if me is None: walk(ch, path + '/' + name, static2, None)
            else: walk(ch, path + '/' + name, None, me)
    walk(root, '', np.eye(4), None)
    return [(a, post, c, path, slot) for (a, post, c, path) in out]

def face_fit(cube):
    """Per face (axis*2+side): (u0, v0, du, dv) with u = u0 + du*fa, v = v0 + dv*fb."""
    lo, hi = np.array(cube['lo']), np.array(cube['hi'])
    ext = np.where(hi - lo == 0, 1.0, hi - lo)
    PAIRS = {0: (2, 1), 1: (0, 2), 2: (0, 1)}
    fits = {}
    for n, verts in cube['faces']:
        axis = int(np.argmax(np.abs(n)))
        side = 1 if n[axis] > 0 else 0
        a, b = PAIRS[axis]
        if hi[a] - lo[a] == 0 or hi[b] - lo[b] == 0: continue   # zero-area side of a flat cube
        pts = [(np.array(p), np.array(uv)) for p, uv in verts]
        fa = [(p[a] - lo[a]) / ext[a] for p, _ in pts]
        fb = [(p[b] - lo[b]) / ext[b] for p, _ in pts]
        # u along a, v along b
        u0 = [uv[0] for (p, uv), f in zip(pts, fa) if abs(f) < 1e-3]
        u1 = [uv[0] for (p, uv), f in zip(pts, fa) if abs(f - 1) < 1e-3]
        v0 = [uv[1] for (p, uv), f in zip(pts, fb) if abs(f) < 1e-3]
        v1 = [uv[1] for (p, uv), f in zip(pts, fb) if abs(f - 1) < 1e-3]
        if not (u0 and u1 and v0 and v1):
            die('a face\'s skin mapping is not axis-aligned (normal %s): the model format has changed' % (n,))
        U0, V0 = u0[0], v0[0]
        dU, dV = u1[0] - U0, v1[0] - V0
        for (p, uv), x, y in zip(pts, fa, fb):
            if not (abs(U0 + dU * x - uv[0]) < 1e-2 and abs(V0 + dV * y - uv[1]) < 1e-2):
                die('a face\'s skin mapping does not match the game\'s corners (normal %s): the model format has changed' % (n,))
        fits[axis * 2 + side] = (U0, V0, dU, dV)
    return fits

def cutout(fits, skins):
    """Does any visible face show a texel that is not fully opaque in any of these skins?"""
    for path in skins:
        A = tex_alpha(path)
        for fi, (u0, v0, du, dv) in fits.items():
            ua, ub = sorted((u0, u0 + du)); va, vb = sorted((v0, v0 + dv))
            x0, x1 = int(math.floor(ua + 1e-3)), int(math.ceil(ub - 1e-3))
            y0, y1 = int(math.floor(va + 1e-3)), int(math.ceil(vb - 1e-3))
            if x1 <= x0: x1 = x0 + 1
            if y1 <= y0: y1 = y0 + 1
            if x0 < 0 or y0 < 0 or x1 > A.shape[1] or y1 > A.shape[0]: return True
            if (A[y0:y1, x0:x1] < 255).any(): return True
    return False

def to_kit(p):  # model px -> mob space in blocks (y up, facing +z)
    return np.array([p[0] / 16.0, (24.0 - p[1]) / 16.0, -p[2] / 16.0])

BONES, BOXES, UVS, TYPES, AABBS, REPORT = [], [], [], [], [], []
for spec in MOBS:
    name, mains, fur, skins, anim = spec[:5]
    furskins = spec[5] if len(spec) > 5 else []
    big = os.path.basename(skins[0]).startswith('iron_golem')
    items = []
    for l in mains: items += flatten(l, anim, 0)
    if fur: items += flatten(fur, anim, 1)
    # group into bones: same animated part and same post matrix
    groups = []
    for a, post, c, path, slot in items:
        for g in groups:
            if g['a']['key'] == a['key'] and np.allclose(g['post'], post, atol=1e-6):
                g['cubes'].append((c, path, slot)); break
        else:
            groups.append({'a': a, 'post': post, 'cubes': [(c, path, slot)]})
    bone0 = len(BONES) // 10
    lo_k, hi_k = np.full(3, 1e9), np.full(3, -1e9)
    ncubes = 0
    for g in groups:
        a = g['a']
        Qinv = np.linalg.inv(a['Q']); Pinv = np.linalg.inv(g['post'])
        swing = sum(v for k, v in a['spec'] if k == 'swing')
        graze = [v for k, v in a['spec'] if k == 'head']
        wag = sum(v for k, v in a['spec'] if k == 'wag')
        flap = [0.0, 0.0, 0.0]
        for k, v in a['spec']:
            if k == 'flap': flap = [flap[i] + v[i] for i in range(3)]
        isHead = bool(graze)
        cube0 = len(BOXES) // 2
        # bounding sphere in the pivot frame (before the bone turns): about the
        # pivot for a moving bone, about the boxes' centre for a still one
        pts = np.array([(g['post'] @ np.array([x, y, z, 1.0]))[:3] for c, _, _ in g['cubes']
                        for x in (c['lo'][0], c['hi'][0]) for y in (c['lo'][1], c['hi'][1]) for z in (c['lo'][2], c['hi'][2])])
        moving = a['key'] != '<static>'
        ctr = np.zeros(3) if moving else 0.5 * (pts.min(0) + pts.max(0))
        rad = max(np.linalg.norm(q - ctr) for q in pts) + 0.01
        for c, path, slot in g['cubes']:
            fits = face_fit(c)
            mask = sum(1 << fi for fi in fits)
            cut = cutout(fits, furskins if slot else skins)
            flags = mask | (64 if cut else 0) | (128 if slot else 0) | (256 if isHead else 0)
            BOXES.append((*c['lo'], flags)); BOXES.append((*c['hi'], 0.0))
            for fi in range(6):
                UVS.append(fits.get(fi, (0.0, 0.0, 0.0, 0.0)))
            # bounds: every pose the kit documents (|yaw| <= 1.2, |pitch| <= 0.8,
            # speed, graze, flap and wag over their whole ranges), sampled per bone
            corners = np.array([[x, y, z, 1.0] for x in (c['lo'][0], c['hi'][0]) for y in (c['lo'][1], c['hi'][1]) for z in (c['lo'][2], c['hi'][2])]).T
            ex = [0.0]; ey = [0.0]; ez = [0.0]
            if swing: ex = list(np.linspace(-abs(swing), abs(swing), 9))
            if graze: ex = [a + b for a in np.linspace(-0.8, 0.8, 7) for b in (0.0, graze[0])] ; ey = list(np.linspace(-1.2, 1.2, 9))
            if wag: ey = list(np.linspace(-abs(wag), abs(wag), 7))
            fl = [np.array(flap) * k for k in np.linspace(-1, 1, 7)] if any(flap) else [np.zeros(3)]
            for a_ in ex:
                for b_ in ey:
                    for f_ in fl:
                        e = [a['rest'][0] + a_ + f_[0], a['rest'][1] + b_ + f_[1], a['rest'][2] + f_[2]]
                        P = (a['Q'] @ R(e) @ g['post'] @ corners)[:3].T
                        for q in P:
                            k = to_kit(q); lo_k = np.minimum(lo_k, k); hi_k = np.maximum(hi_k, k)
            ncubes += 1
        cubeN = len(BOXES) // 2 - cube0
        for row in range(3): BONES.append(tuple(Qinv[row]))
        for row in range(3): BONES.append(tuple(Pinv[row]))
        BONES.append((*a['rest'], float(cube0)))
        BONES.append((swing, graze[0] if graze else -1.0, wag, float(cubeN)))
        BONES.append((*flap, 0.0))
        BONES.append((*ctr, rad))
    lo_k -= 0.02; hi_k += 0.02
    TYPES.append((bone0, len(groups), 1 if big else 0, ncubes))
    AABBS.append((*lo_k, 0.0)); AABBS.append((*hi_k, 0.0))
    # rest-pose extents for the report (exact, all bones at rest)
    REPORT.append((name, len(groups), ncubes, skins[0], fur))

def f(x): return ('%.6g' % x).replace('inf', 'INFINITY') if x == x else '0'
def f4(t): return 'float4(%s)' % ', '.join(f(x) for x in t)
def h4(t): return 'half4(%s)' % ', '.join(f(x) for x in t)

out = []
out.append('// ---- generated by scripts/minecraft-mobs/gen.py from the %s client\'s baked models: do not edit by hand' % VERSION)
for i, (name, nb, nc, sk, fur) in enumerate(REPORT):
    out.append('constant int MCMOB_%s = %d;' % (name, i))
out.append('constant int MCMOB_COUNT = %d;' % len(REPORT))
out.append('')
out.append('// per type: first bone, bone count, 1 if the skin is in mcMaps (128 px), cube count')
out.append('constant int4 MCMOB_TYPE[%d] = {' % len(TYPES))
out.append(',\n'.join('    int4(%d, %d, %d, %d)' % t for t in TYPES) + '};')
out.append('// per type: rest-and-swing bounding box in mob space (blocks), min then max')
out.append('constant float4 MCMOB_AABB[%d] = {' % len(AABBS))
out.append(',\n'.join('    ' + f4(t) for t in AABBS) + '};')
out.append('// per bone, 10 rows: model->pivot frame (3), part->bone frame inverse (3),')
out.append('// (rest euler xyz, first cube), (swing, graze or -1 if not a head, wag, cube count), (flap xyz, 0), (bounding sphere centre in the pivot frame, radius)')
out.append('constant float4 MCMOB_BONE[%d] = {' % len(BONES))
out.append(',\n'.join('    ' + f4(t) for t in BONES) + '};')
out.append('// per cube: (min xyz, flags), (max xyz, 0) in its bone frame, model pixels;')
out.append('// flags: bits 0-5 faces present (axis*2+side), 64 may be transparent, 128 fur model, 256 head')
out.append('constant float4 MCMOB_BOX[%d] = {' % len(BOXES))
out.append(',\n'.join('    ' + f4(t) for t in BOXES) + '};')
out.append('// per cube face (axis*2+side): skin pixel = (u0 + du*fa, v0 + dv*fb)')
out.append('constant half4 MCMOB_UV[%d] = {' % len(UVS))
out.append(',\n'.join('    ' + h4(t) for t in UVS) + '};')
header = open(os.path.join(HERE, 'header.metal')).read().replace('@VERSION@', VERSION)
kit = header + '\n'.join(out) + '\n' + open(os.path.join(HERE, 'funcs.metal')).read()
with open(OUT, 'w') as fh: fh.write(kit)
print('minecraft-mobs: %d mobs, %d parts, %d boxes from %s' % (len(REPORT), len(BONES) // 10, len(BOXES) // 2, VERSION))
