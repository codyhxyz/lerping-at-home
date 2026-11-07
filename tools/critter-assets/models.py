# The critter's models, built procedurally. Blender coordinates throughout:
# Z up, the critter's face (and every template's front) toward -Y. lib's
# writer turns that into SceneKit's Y up, +Z front.
#
# Sizes follow the old raymarched shader (Sources/Shaders/critter.metal at
# 6b776ec), so the scene lane can reuse its offsets: the critter at body
# radius 1, trees at size 1 (trunk to ~1, canopy ~2 tall), flowers ~0.25,
# the castle ~0.5 across, the storm cloud ~1.1 across.
import math
import random
from mathutils import Vector, Matrix
from mathutils.bvhtree import BVHTree

from lib import (TAU, MB, orient_outward, node, uvsphere, ellipsoid, lathe, tube, grid, xform, deform,
                 bisect_keep_above, convex_hull, solidify, subsurf, bevel)
import bmesh


def rotz(a):
    return Matrix.Rotation(a, 4, 'Z')


def rotx(a):
    return Matrix.Rotation(a, 4, 'X')


def roty(a):
    return Matrix.Rotation(a, 4, 'Y')


def T(v):
    return Matrix.Translation(Vector(v))


def frame(x, y, z, o=(0, 0, 0)):
    """4x4 with columns x, y, z and origin o."""
    M = Matrix.Identity(4)
    for i in range(3):
        M[i][0], M[i][1], M[i][2], M[i][3] = x[i], y[i], z[i], o[i]
    return M


# ------------------------------------------------------------ shared pieces

def blade(length, width, fold=0.3, curl=0.0, nu=14, nv=6, thick=0.012,
          shape=(0.6, 0.8), droop=0.0):
    """A leaf/petal blade in its own frame: base at the origin, running along
    +X, width along Y, its face up (+Z). fold raises the edges (a V about the
    midrib), curl bends it along its length (+ up), droop bends it down at the
    tip. shape = exponents of the outline u^a (1-u)^b."""
    a, b = shape
    um = a / (a + b)
    norm = um ** a * (1 - um) ** b

    def w(u):
        return width * 0.5 * (u ** a) * ((1 - u) ** b) / norm

    def fn(u, v):
        s = (v - 0.5) * 2.0
        x = u * length
        y = s * w(u)
        z = fold * abs(s) ** 1.4 * w(u) + (curl - droop) * (u * u) * length
        return (x, y, z)

    bm = grid(fn, nu, nv)
    if thick > 0:
        bm = solidify(bm, thick, 0.0)
    return bm


def vein(length, fold_lift, r=0.008, n=8, curl=0.0, droop=0.0):
    pts = [((u := 0.03 + 0.8 * i / (n - 1)) * length, 0.0,
            fold_lift + (curl - droop) * u * u * length) for i in range(n)]
    radii = [r * (1 - 0.6 * i / (n - 1)) for i in range(n)]
    return tube(pts, radii, sides=5)


# ================================================================ critter

BODY_C = Vector((0, 0, 0.95))
EW, ED, EH = 0.132, 0.08, 0.185   # eye half-sizes: width, depth, height


def body_shape(co):
    """Unit-sphere point -> the mochi bean: a touch pear-shaped (fuller low,
    narrower crown), a soft flat seat."""
    nx, ny, nz = co.normalized()
    h = nz
    k = 1.0 - 0.1 * h + 0.04 * max(0.0, -h) * (1 + h) * 2.0
    x = nx * 1.0 * k
    y = ny * 0.92 * k
    if nz < 0:
        z = 0.95 + nz * 0.95 * (1.0 - 0.11 * nz ** 4)
    else:
        z = 0.95 + nz * 0.95
    return (x, y, z)


def build_critter(col=None):
    root = node("critter", None, pivot=(0, 0, 0), collection=col)

    # ---- body
    bm = uvsphere(1.0, 64, 40)
    deform(bm, body_shape)
    body_bm = bm.copy()
    node("body", MB().add(bm, "body"), parent=root, pivot=(0, 0, 0), collection=col)

    bvh = BVHTree.FromBMesh(body_bm)

    # ---- eyes: big glossy ovals set into the face, the pivot at the centre
    for side, nm in ((-1, "eyeL"), (1, "eyeR")):
        hit = bvh.ray_cast(Vector((side * 0.35, -3.0, 1.02)), Vector((0, 1, 0)))
        P, N = hit[0], hit[1].normalized()
        r = (Vector((1, 0, 0)) - N * N.x).normalized()
        u = N.cross(r).normalized()
        if u.z < 0:
            u = -u
        # tilt the eye slightly so its top leans outward (friendlier)
        C = P - N * 0.035
        M = frame(r, N, u, C)
        mb = MB()
        e = ellipsoid((0, 0, 0), (EW, ED, EH), 32, 20, M)
        orient_outward(e)
        mb.add(e, "eye")
        for (su, sw, rad) in ((0.38, 0.42, (0.048, 0.014, 0.056)), (-0.32, -0.45, (0.022, 0.012, 0.024))):
            ly = ED * math.sqrt(max(0.0, 1 - su * su - sw * sw)) + 0.002
            lc = Vector((su * EW, ly, sw * EH))
            s = ellipsoid((0, 0, 0), rad, 16, 10, M @ T(lc))
            orient_outward(s)
            mb.add(s, "eyeShine")
        node(nm, mb, parent=root, pivot=C, collection=col)

    # ---- arms: pivot at the shoulder, hanging straight down (-Z here, -Y in SceneKit)
    for side, nm in ((-1, "armL"), (1, "armR")):
        S = Vector((side * 0.74, -0.08, 1.03))
        mb = MB()
        pts = [S + Vector((0, 0, -0.66 * i / 6)) for i in range(7)]
        mb.add(tube(pts, [0.112 - 0.016 * i / 6 for i in range(7)], sides=16), "body")
        mitt = ellipsoid(S + Vector((0, -0.005, -0.8)), (0.13, 0.12, 0.155), 24, 16)
        mb.add(mitt, "body")
        thumb = ellipsoid((0, 0, 0), (0.055, 0.05, 0.075), 16, 10,
                          T(S + Vector((-side * 0.045, -0.095, -0.72))) @ rotx(-0.5))
        mb.add(thumb, "body")
        node(nm, mb, parent=root, pivot=S, collection=col)

    # ---- feet: the pivot at the foot's centre (the old shader's foot centre)
    for side, nm in ((-1, "footL"), (1, "footR")):
        F = Vector((side * 0.42, -0.24, 0.12))
        bm = uvsphere(1.0, 24, 14)

        def foot(co, F=F):
            x, y, z = co
            z = z * 0.13 if z > 0 else z * 0.13 * 0.55
            y = y * 0.27
            x = x * 0.205 * (1.0 - 0.15 * max(0.0, co.y))  # a little narrower at the heel
            return (F.x + x, F.y + y, F.z + z - 0.055)

        deform(bm, foot)
        node(nm, MB().add(bm, "body"), parent=root, pivot=F, collection=col)

    # ---- sprout: pivot on top of the head; leaves and blossom at the stem tip
    top = Vector((0, 0, 1.87))
    tip = Vector((0, -0.035, 2.17))
    stem_pts = [top + Vector((0, 0, -0.06)), top + Vector((0, 0.004, 0.08)),
                top + Vector((0, -0.006, 0.18)), top + Vector((0, -0.025, 0.26)), tip]
    stem = tube(stem_pts, [0.045, 0.042, 0.038, 0.034, 0.03], sides=12)
    # the stem is the sprout's own geometry; leaves and blossom hang off it
    sp = node("sprout", MB().add(stem, "leaf"), parent=root, pivot=top, collection=col)

    L, W = 0.52, 0.29
    for side, nm in ((-1, "leafL"), (1, "leafR")):
        ang = 0.5
        d = Vector((side * math.cos(ang), 0, math.sin(ang)))
        n = Vector((-side * math.sin(ang), 0, math.cos(ang)))
        # turn the blade's face toward the front so it reads from the camera
        twist = 0.55
        n = (n * math.cos(twist) - Vector((0, 1, 0)) * math.sin(twist)).normalized()
        acr = n.cross(d).normalized()
        M = frame(d, acr, n, tip)
        mb = MB()
        b = blade(L, W, fold=0.32, curl=0.10, nu=16, nv=8, thick=0.016, shape=(0.55, 0.85))
        xform(b, M)
        mb.add(b, "leaf")
        v = vein(L, 0.012, r=0.009, curl=0.10)
        xform(v, M)
        mb.add(v, "leafVein")
        node(nm, mb, parent=sp, pivot=tip, collection=col)

    # blossom: five rounded petals and a centre, sitting on the tip
    mb = MB()
    bc = tip + Vector((0, -0.03, 0.25))
    mb.add(tube([tip, tip + Vector((0, 0.0, 0.1)), tip + Vector((0, -0.015, 0.19)), bc],
                [0.03, 0.028, 0.026, 0.024], sides=10), "leaf")
    for i in range(5):
        p = blade(0.22, 0.2, fold=-0.12, curl=0.3, nu=10, nv=6, thick=0.014, shape=(0.42, 0.42))
        # face tipped toward the front so the flower reads from the camera
        xform(p, T(bc) @ rotx(0.35) @ rotz(-math.pi / 2 + TAU * i / 5) @ roty(-0.2) @ T((0.02, 0, 0)))
        mb.add(p, "blossom")
    mb.add(ellipsoid((0, 0, 0), (0.07, 0.07, 0.048), 20, 12, T(bc) @ rotx(0.35) @ T((0, 0, 0.02))), "petalCenter")
    node("blossom", mb, parent=sp, pivot=tip, collection=col)
    return root


# ================================================================ egg + nest

def egg_profile(n=28):
    prof = []
    for i in range(n + 1):
        s = math.pi * i / n
        z = 0.4 - 0.4 * math.cos(s)
        r = 0.29 * math.sin(s) * (1.0 + 0.14 * math.cos(s))
        prof.append((r if 0 < i < n else 0.0, z))
    return prof


def build_egg(col=None):
    mb = MB()
    egg = lathe(egg_profile(30), seg=40)
    mb.add(egg, "egg")
    # speckles: lenses on the shell, spread on a golden spiral, two sizes
    rng = random.Random(7)
    bvh = BVHTree.FromPolygons(*_lathe_polys(egg_profile(30), 40))
    ga = math.pi * (3 - math.sqrt(5))
    count = 24
    for i in range(count):
        zf = 0.22 + 0.72 * (i + 0.5) / count
        th = i * ga + rng.uniform(-0.3, 0.3)
        z = 0.8 * zf
        origin = Vector((0, 0, z))
        dirv = Vector((math.cos(th), math.sin(th), 0.0))
        hit = bvh.ray_cast(origin + dirv * 1.0, -dirv)
        if hit[0] is None:
            continue
        P, N = hit[0], hit[1].normalized()
        rad = rng.choice((0.026, 0.036, 0.05, 0.03)) * (1.1 - 0.35 * zf)
        t1 = N.cross(Vector((0, 0, 1))).normalized()
        t2 = N.cross(t1)
        s = ellipsoid((0, 0, 0), (rad, rad * rng.uniform(0.7, 1.0), 0.006), 14, 6,
                      frame(t1, t2, N, P + N * 0.001))
        orient_outward(s)
        mb.add(s, "eggSpot")
    return node("egg", mb, pivot=(0, 0, 0), collection=col)


def _lathe_polys(profile, seg):
    verts, polys, rings = [], [], []
    for (r, z) in profile:
        if r <= 1e-7:
            rings.append([len(verts)])
            verts.append((0, 0, z))
        else:
            ring = []
            for j in range(seg):
                th = TAU * j / seg
                ring.append(len(verts))
                verts.append((r * math.cos(th), r * math.sin(th), z))
            rings.append(ring)
    for a, b in zip(rings, rings[1:]):
        if len(a) == 1:
            for j in range(seg):
                polys.append((a[0], b[j], b[(j + 1) % seg]))
        elif len(b) == 1:
            for j in range(seg):
                polys.append((a[j], a[(j + 1) % seg], b[0]))
        else:
            for j in range(seg):
                polys.append((a[j], a[(j + 1) % seg], b[(j + 1) % seg], b[j]))
    return verts, polys


def build_nest(col=None):
    mb = MB()
    R, r, zc = 0.32, 0.085, 0.085
    # a solid core so nothing shows through the weave, and a floor
    core = lathe([(R - 0.07 * math.cos(a), zc + 0.07 * math.sin(a)) for a in
                  [(-math.pi / 2 + math.pi * i / 10) for i in range(11)]]
                 + [(R + 0.07 * math.cos(a), zc + 0.07 * math.sin(a)) for a in
                    [(math.pi / 2 - math.pi * i / 10) for i in range(11)]][1:-1], seg=40)
    mb.add(core, "nest")
    mb.add(lathe([(0.0, 0.012), (0.25, 0.018), (0.29, 0.03), (0.0, 0.035)], seg=32), "nest")
    # woven strands: helices round the ring, alternately handed, so they cross
    ns, m, n = 8, 6, 96
    for k in range(ns):
        hand = 1 if k % 2 == 0 else -1
        ph = TAU * (k // 2) / (ns // 2) + (0.4 if hand < 0 else 0.0)
        pts = []
        for i in range(n + 1):
            th = TAU * i / n
            ph2 = hand * m * th + ph
            rr = r * (1.0 + 0.08 * math.sin(3 * th + k))
            pts.append(((R + rr * math.cos(ph2)) * math.cos(th),
                        (R + rr * math.cos(ph2)) * math.sin(th),
                        zc + rr * 0.95 * math.sin(ph2)))
        mb.add(tube(pts, 0.024, sides=5, caps=False), "nest")
    # stray twigs poking out of the rim
    rng = random.Random(3)
    for i in range(7):
        th = TAU * i / 7 + rng.uniform(-0.2, 0.2)
        rad = Vector((math.cos(th), math.sin(th), 0))
        tan = Vector((-math.sin(th), math.cos(th), 0))
        p0 = rad * (R + 0.03) + Vector((0, 0, zc + 0.05))
        p1 = p0 + tan * rng.choice((-1, 1)) * 0.07 + rad * 0.07 + Vector((0, 0, 0.04))
        mb.add(tube([p0, (p0 + p1) / 2 + Vector((0, 0, 0.01)), p1], [0.012, 0.011, 0.009], sides=5), "nest")
    return node("nest", mb, pivot=(0, 0, 0), collection=col)


# ================================================================ trees

def trunk(height, r0, r1, flare=0.09, roots=5, seg=20, rows=16, sink=0.06):
    prof = []
    for i in range(rows + 1):
        t = i / rows
        z = -sink + (height + sink) * t
        zz = max(z, 0.0)
        r = r0 + (r1 - r0) * min(1.0, zz / height) + flare * math.exp(-zz / 0.09)
        prof.append((r, z))

    def mod(th, t, r, z):
        zz = max(z, 0.0)
        bump = max(0.0, math.cos(roots * th)) ** 3 * math.exp(-zz / 0.13)
        return r * (1.0 + 0.55 * bump), z

    return lathe(prof, seg=seg, mod=mod)


def lobe(c, r, seg=24, ring=14, flat=0.7):
    """A leaf clump: a sphere with a flatter underside."""
    bm = uvsphere(1.0, seg, ring)

    def f(co):
        x, y, z = co
        if z < 0:
            z *= flat
        return (c[0] + x * r, c[1] + y * r, c[2] + z * r)

    return deform(bm, f)


def branch(p0, p1, r0, r1):
    mid = (Vector(p0) + Vector(p1)) / 2 + Vector((0, 0, 0.04))
    return tube([Vector(p0), mid, Vector(p1)], [r0, (r0 + r1) / 2, r1], sides=10)


def build_tree_round(col=None):
    root = node("treeRound", None, pivot=(0, 0, 0), collection=col)
    mb = MB()
    mb.add(trunk(1.15, 0.105, 0.07), "bark")
    mb.add(branch((0, 0, 0.8), (0.3, -0.08, 1.15), 0.05, 0.03), "bark")
    mb.add(branch((0, 0, 0.88), (-0.28, 0.1, 1.2), 0.045, 0.03), "bark")
    node("trunk", mb, parent=root, pivot=(0, 0, 0), collection=col)
    mb = MB()
    lobes = [((0.0, 0.0, 1.42), 0.48)]
    for i in range(5):
        a = TAU * i / 5 + 0.35
        lobes.append(((0.45 * math.cos(a), 0.45 * math.sin(a), 1.2 + 0.05 * math.sin(3 * a)), 0.33))
    for i in range(4):
        a = TAU * i / 4 + 0.1
        lobes.append(((0.27 * math.cos(a), 0.27 * math.sin(a), 1.66), 0.3))
    lobes.append(((0.02, -0.02, 1.92), 0.24))
    for c, r in lobes:
        mb.add(lobe(c, r), "canopy")
    node("canopy", mb, parent=root, pivot=(0, 0, 1.3), collection=col)
    return root


def pine_tier(zb, R, h, n=9, seg=54, phase=0.0):
    prof = [
        (0.0, zb + 0.12),
        (R * 0.5, zb + 0.05),
        (R * 0.86, zb - 0.015),
        (R * 0.98, zb - 0.005),
        (R * 1.0, zb + 0.025),
        (R * 0.93, zb + 0.06),
        (R * 0.72, zb + 0.06 + h * 0.22),
        (R * 0.46, zb + 0.06 + h * 0.5),
        (R * 0.22, zb + h * 0.8),
        (R * 0.07, zb + h * 0.96),
        (0.0, zb + h),
    ]
    n_rows = len(prof)

    def mod(th, t, r, z):
        i = round(t * (n_rows - 1))
        wgt = {1: 0.5, 2: 1.0, 3: 1.0, 4: 1.0, 5: 0.9, 6: 0.55, 7: 0.3, 8: 0.12}.get(i, 0.0)
        c = math.cos(n * th + phase)
        r2 = r * (1.0 + 0.15 * wgt * c)
        z2 = z - 0.07 * wgt * (1 - c) * 0.5 * (1 if i <= 5 else 0.3)
        return r2, z2

    return lathe(prof, seg=seg, mod=mod)


def build_tree_pine(col=None):
    root = node("treePine", None, pivot=(0, 0, 0), collection=col)
    node("trunk", MB().add(trunk(0.7, 0.085, 0.06, flare=0.07), "bark"),
         parent=root, pivot=(0, 0, 0), collection=col)
    mb = MB()
    tiers = [(0.34, 0.74, 0.78), (0.74, 0.6, 0.68), (1.1, 0.46, 0.6), (1.42, 0.32, 0.62)]
    for i, (zb, R, h) in enumerate(tiers):
        mb.add(pine_tier(zb, R, h, n=9 - i, seg=(9 - i) * 6, phase=0.6 * i), "needles")
    node("canopy", mb, parent=root, pivot=(0, 0, 1.2), collection=col)
    return root


def pillow(zc, R, hb, ht, n, seg=60, rows=18, amp=0.075, p=2.4, phase=0.0):
    prof = []
    for i in range(rows + 1):
        s = -math.pi / 2 + math.pi * i / rows
        c = max(0.0, math.cos(s))
        r = R * c ** (2.0 / p) if 0 < i < rows else 0.0
        z = zc + (ht if s > 0 else hb) * math.sin(s)
        prof.append((r, z))

    def mod(th, t, r, z):
        s = -math.pi / 2 + math.pi * t
        w = max(0.0, math.cos(s)) ** 2
        return r * (1.0 + amp * w * math.cos(n * th + phase)), z

    return lathe(prof, seg=seg, mod=mod)


def apple(c, r):
    prof = []
    for i in range(17):
        s = math.pi * i / 16
        rr = r * math.sin(s) * (1.0 + 0.08 * math.sin(s))
        z = -r * math.cos(s) * 0.92
        # dimples top and bottom
        z += 0.25 * r * (math.exp(-((s) / 0.35) ** 2) - math.exp(-((math.pi - s) / 0.35) ** 2))
        prof.append((rr if 0 < i < 16 else 0.0, z))
    bm = lathe(prof, seg=20)
    xform(bm, T(c))
    return bm


def build_tree_fruit(col=None):
    root = node("treeFruit", None, pivot=(0, 0, 0), collection=col)
    mb = MB()
    mb.add(trunk(1.05, 0.11, 0.075), "bark")
    node("trunk", mb, parent=root, pivot=(0, 0, 0), collection=col)
    mb = MB()
    tiers = [(1.08, 0.8, 0.17, 0.27, 11), (1.44, 0.6, 0.13, 0.24, 9), (1.76, 0.36, 0.1, 0.22, 7)]
    for i, (zc, R, hb, ht, n) in enumerate(tiers):
        mb.add(pillow(zc, R, hb, ht, n, seg=n * 6, phase=0.3 * i), "canopy")
    node("canopy", mb, parent=root, pivot=(0, 0, 1.3), collection=col)
    fr = node("fruit", None, parent=root, pivot=(0, 0, 0), collection=col)
    # set into the scallop crests round the tiers' bulging sides
    spots = [(-1.15, 0), (0.1, 0), (1.25, 0), (2.4, 0), (3.7, 0), (-0.45, 1), (0.95, 1)]
    rad = 0.082
    for i, (a, tier) in enumerate(spots):
        zc, R, hb, ht, n = tiers[tier]
        a = a - math.pi / 2  # angle 0 faces the front (-Y)
        k = round((a - 0.3 * tier) * n / TAU)       # snap to a crest
        a = (TAU * k + 0.3 * tier) / n
        rr = R * 1.075 - rad * 0.35
        C = Vector((rr * math.cos(a), rr * math.sin(a), zc - 0.02))
        mbf = MB()
        mbf.add(apple(C, rad), "fruit")
        mbf.add(tube([C + Vector((0, 0, rad * 0.55)), C + Vector((0.008, 0, rad * 1.2))], 0.009, sides=5), "bark")
        lf = blade(0.07, 0.04, fold=0.2, curl=0.2, nu=6, nv=4, thick=0.008)
        xform(lf, T(C + Vector((0.005, 0, rad * 1.0))) @ rotz(a + 1.2) @ roty(-0.5))
        mbf.add(lf, "leaf")
        node(f"fruit{i}", mbf, parent=fr, pivot=C, collection=col)
    return root


# ================================================================ flowers

def stem_leaf(base, ang, length=0.07, width=0.03, up=0.6, curl=0.25):
    b = blade(length, width, fold=0.3, curl=curl, nu=8, nv=4, thick=0.004, shape=(0.6, 0.9))
    xform(b, T(base) @ rotz(ang) @ roty(-up))
    return b


def build_flower_daisy(col=None):
    root_pts = [Vector(p) for p in ((0, 0, -0.02), (0.006, 0, 0.07), (0.003, 0, 0.14), (-0.003, -0.004, 0.2))]
    top = Vector((-0.003, -0.006, 0.205))
    mb = MB()
    mb.add(tube(root_pts + [top], 0.0065, sides=6), "leaf")
    mb.add(stem_leaf(Vector((0.002, 0, 0.0)), 0.3, 0.075, 0.032), "leaf")
    mb.add(stem_leaf(Vector((0.002, 0, 0.03)), 0.3 + math.pi * 0.9, 0.065, 0.028), "leaf")
    root = node("flowerDaisy", mb, pivot=(0, 0, 0), collection=col)
    hm = MB()
    tilt = rotx(0.45)   # face turned up and toward the front
    for i in range(13):
        p = blade(0.068, 0.022, fold=0.25, curl=0.12, nu=7, nv=3, thick=0.004, shape=(0.35, 0.3))
        xform(p, T(top) @ tilt @ rotz(TAU * i / 13) @ roty(-0.12) @ T((0.014, 0, 0)))
        hm.add(p, "petal")
    c = uvsphere(1.0, 16, 10)
    deform(c, lambda co: (co.x * 0.026, co.y * 0.026, co.z * (0.018 if co.z > 0 else 0.008)))
    xform(c, T(top) @ tilt @ T((0, 0, 0.004)))
    hm.add(c, "petalCenter")
    node("head", hm, parent=root, pivot=top, collection=col)
    return root


def build_flower_tulip(col=None):
    top = Vector((0.0, 0.0, 0.17))
    mb = MB()
    mb.add(tube([Vector((0, 0, -0.02)), Vector((0.004, 0, 0.08)), top + Vector((0, 0, 0.01))], 0.0075, sides=6), "leaf")
    # long strap leaves that arch outward
    mb.add(stem_leaf(Vector((0, 0, 0.0)), 0.5, 0.13, 0.034, up=1.15, curl=-0.35), "leaf")
    mb.add(stem_leaf(Vector((0, 0, 0.0)), 0.5 + math.pi * 1.05, 0.11, 0.03, up=1.2, curl=-0.4), "leaf")
    root = node("flowerTulip", mb, pivot=(0, 0, 0), collection=col)
    hm = MB()
    H = 0.088
    # two nested cups, each with three rounded-point petals on its rim; the
    # inner one turned 60 degrees so its petals show between the outer's
    prof = [(0.0, 0.0), (0.016, 0.004), (0.03, 0.014), (0.038, 0.03), (0.04, 0.048),
            (0.038, 0.064), (0.034, 0.078), (0.031, 0.088)]
    for k, (sc, ph) in enumerate(((1.0, 0.0), (0.9, math.pi / 3))):
        def mod(th, t, r, z, sc=sc, ph=ph):
            c = (1 + math.cos(3 * (th - ph))) * 0.5          # 1 mid-petal, 0 between
            crest = 0.72 + 0.28 * c ** 0.8                     # petal tips stand up
            crease = 1.0 - 0.07 * (1 - c) ** 6 * min(1.0, t * 2)
            return r * sc * crease, z * sc * (1 - t * t + t * t * crest) / 1.0

        cup = lathe(prof, seg=36, mod=mod)
        bmesh.ops.delete(cup, geom=[f for f in cup.faces if len(f.verts) > 4], context='FACES_ONLY')
        cup = solidify(cup, 0.003)
        xform(cup, T(top))
        hm.add(cup, "petal")
    node("head", hm, parent=root, pivot=top, collection=col)
    return root


def build_flower_bell(col=None):
    pts = [Vector(p) for p in ((0, 0.01, -0.02), (0, 0.012, 0.08), (0, 0.0, 0.17), (0, -0.03, 0.225),
                               (0, -0.065, 0.24), (0, -0.09, 0.225))]
    top = Vector((0, -0.097, 0.212))
    mb = MB()
    mb.add(tube(pts + [top], [0.0065, 0.006, 0.0058, 0.0052, 0.0048, 0.0045, 0.0045], sides=6), "leaf")
    mb.add(stem_leaf(Vector((0, 0.01, 0.0)), 0.8, 0.075, 0.034), "leaf")
    mb.add(stem_leaf(Vector((0, 0.01, 0.02)), 0.8 + math.pi, 0.07, 0.03), "leaf")
    # a little calyx where the bell hangs
    mb.add(ellipsoid(top + Vector((0, 0, 0.003)), (0.011, 0.011, 0.009), 10, 6), "leaf")
    root = node("flowerBell", mb, pivot=(0, 0, 0), collection=col)
    hm = MB()
    prof = [(0.004, 0.0), (0.014, -0.003), (0.022, -0.01), (0.027, -0.021), (0.028, -0.034),
            (0.029, -0.047), (0.032, -0.058), (0.037, -0.066), (0.043, -0.0705), (0.047, -0.069)]
    n = len(prof)

    def mod(th, t, r, z):
        lip = t ** 4
        c = math.cos(5 * th)
        return r * (1.0 + 0.13 * lip * c), z + 0.007 * lip * (c + 1) * 0.5

    bell = lathe(prof, seg=40, mod=mod)
    # open mouth: drop the bottom cap
    bmesh.ops.delete(bell, geom=[f for f in bell.faces if len(f.verts) > 4], context='FACES_ONLY')
    bell = solidify(bell, 0.003)
    tilt = rotx(-0.35)  # mouth tipped toward the front
    xform(bell, T(top) @ tilt)
    hm.add(bell, "petal")
    clap = ellipsoid((0, 0, -0.058), (0.007, 0.007, 0.012), 10, 6)
    xform(clap, T(top) @ tilt)
    hm.add(clap, "petalCenter")
    hm.add(tube([top + Vector((0, 0, -0.01)), top + (tilt @ Vector((0, 0, -0.05)))], 0.0022, sides=4), "petalCenter")
    node("head", hm, parent=root, pivot=top, collection=col)
    return root


# ================================================================ clouds

def cloud(lobes, seg=28, ring=16, zcut=0.0):
    mb = MB()
    for (x, y, z, r) in lobes:
        b = uvsphere(1.0, seg, ring)
        xform(b, T((x, y, z)) @ Matrix.Diagonal((r, r, r * 0.92, 1)))
        bisect_keep_above(b, zcut)
        mb.add(b, "cloud")
    return mb


def build_cloud_puff(col=None):
    lobes = [
        (0.0, 0.0, 0.3, 0.62),
        (-0.62, 0.04, 0.16, 0.46),
        (0.64, -0.03, 0.18, 0.48),
        (-1.08, 0.0, 0.04, 0.3),
        (1.12, 0.05, 0.05, 0.31),
        (-0.26, 0.32, 0.24, 0.46),
        (0.34, 0.28, 0.2, 0.42),
        (0.18, -0.1, 0.62, 0.36),
        (-0.34, -0.14, 0.5, 0.3),
    ]
    return node("cloudPuff", cloud(lobes), pivot=(0, 0, 0), collection=col)


def build_cloud_storm(col=None):
    # heavier: a broad flat base and tight, crowded lobes; flat bottom at -0.09
    lobes = [
        (0.0, 0.0, 0.02, 0.3),
        (0.28, 0.02, -0.02, 0.25),
        (-0.3, -0.02, -0.03, 0.24),
        (0.5, 0.0, -0.06, 0.15),
        (-0.52, 0.02, -0.06, 0.15),
        (0.1, -0.12, 0.13, 0.22),
        (-0.15, 0.1, 0.1, 0.22),
        (0.04, 0.02, 0.26, 0.17),
    ]
    mb = cloud(lobes, seg=24, ring=14, zcut=-0.09)
    return node("cloudStorm", mb, pivot=(0, 0, 0), collection=col)


# ================================================================ butterfly

def _ray_ellipse(phi, c, ax, rot):
    """Far intersection distance of a ray from the origin at angle phi with a
    rotated ellipse (centre c, semi-axes ax), or 0."""
    d = Vector((math.cos(phi), math.sin(phi)))
    cr, sr = math.cos(-rot), math.sin(-rot)
    def loc(v):
        return Vector((v.x * cr - v.y * sr, v.x * sr + v.y * cr))
    o = loc(-Vector(c))
    dd = loc(d)
    A = (dd.x / ax[0]) ** 2 + (dd.y / ax[1]) ** 2
    B = 2 * (o.x * dd.x / ax[0] ** 2 + o.y * dd.y / ax[1] ** 2)
    C = (o.x / ax[0]) ** 2 + (o.y / ax[1]) ** 2 - 1
    disc = B * B - 4 * A * C
    if disc < 0:
        return 0.0
    return max(0.0, (-B + math.sqrt(disc)) / (2 * A))


FORE = ((0.072, -0.03), (0.075, 0.048), -0.42)
HIND = ((0.045, 0.045), (0.045, 0.042), 0.5)


def wing_outline(phi):
    return max(_ray_ellipse(phi, *FORE), _ray_ellipse(phi, *HIND), 0.006)


def build_butterfly(col=None):
    root = node("butterfly", None, pivot=(0, 0, 0), collection=col)
    mb = MB()
    mb.add(ellipsoid((0, -0.006, 0), (0.013, 0.03, 0.013), 14, 10), "bbody")
    mb.add(ellipsoid((0, 0.045, -0.002), (0.0095, 0.045, 0.0095), 14, 10), "bbody")
    mb.add(ellipsoid((0, -0.041, 0.003), (0.011, 0.011, 0.011), 12, 8), "bbody")
    for s in (-1, 1):
        ant = [Vector((s * 0.004, -0.048, 0.008)), Vector((s * 0.012, -0.07, 0.02)),
               Vector((s * 0.022, -0.088, 0.03)), Vector((s * 0.03, -0.1, 0.036))]
        mb.add(tube(ant, 0.0016, sides=4), "bbody")
        mb.add(ellipsoid(ant[-1], (0.0042, 0.0042, 0.0042), 8, 6), "bbody")
    node("bbody", mb, parent=root, pivot=(0, 0, 0), collection=col)

    nphi, nt = 56, 10
    phis = [-math.radians(108) + math.radians(212) * i / nphi for i in range(nphi + 1)]
    for side, nm in ((-1, "wingL"), (1, "wingR")):
        wm = MB()
        for band, (t0, t1) in (("wing", (0.0, 0.8)), ("wingEdge", (0.8, 1.0))):
            def fn(u, v, t0=t0, t1=t1):
                phi = phis[0] + (phis[-1] - phis[0]) * u
                t = t0 + (t1 - t0) * v
                r = wing_outline(phi) * t
                x, y = r * math.cos(phi), r * math.sin(phi)
                z = 0.12 * r * r / 0.15 + 0.004 * t
                return (side * (x + 0.004), y, z)
            p = grid(fn, nphi, 6 if band == "wing" else 2)
            if side < 0:
                bmesh.ops.reverse_faces(p, faces=p.faces)
            wm.add(solidify(p, 0.003), band)
        # white spots in the forewing's dark border, both faces
        for (phi_deg, t, rr) in ((-40, 0.9, 0.0075), (-25, 0.9, 0.0065), (-55, 0.9, 0.0065),
                                 (-10, 0.92, 0.0055), (10, 0.88, 0.005)):
            phi = math.radians(phi_deg)
            r = wing_outline(phi) * t
            x, y = r * math.cos(phi) + 0.004, r * math.sin(phi)
            z = 0.12 * r * r / 0.15 + 0.004 * t
            for zs in (1, -1):
                d = ellipsoid((0, 0, 0), (rr, rr, 0.0009), 12, 4)
                xform(d, T((side * x, y, z + zs * 0.0021)))
                wm.add(d, "wingSpot")
        node(nm, wm, parent=root, pivot=(side * 0.004, 0, 0), collection=col)
    return root


# ================================================================ castle + rocks

def merlon(c, ang, w, d, h):
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    xform(bm, T(c) @ rotz(ang) @ Matrix.Diagonal((d, w, h, 1)) @ T((0, 0, 0.5)))
    return bevel(bm, 0.004, 2, 30)


def tower(cx, cy, r, ztop, z0=0.06, n_merl=6, seg=40):
    """A bucket-moulded tower: slight taper, a ridge where the bucket's rim
    pressed, a wider crown with merlons."""
    prof = [
        (r * 1.1, z0),
        (r * 1.06, z0 + (ztop - z0) * 0.45),
        (r * 1.1, z0 + (ztop - z0) * 0.47),
        (r * 1.1, z0 + (ztop - z0) * 0.53),
        (r * 1.03, z0 + (ztop - z0) * 0.55),
        (r * 0.98, ztop - 0.045),
        (r * 1.18, ztop - 0.035),
        (r * 1.18, ztop),
        (r * 0.9, ztop),
        (0.0, ztop),
    ]
    bm = lathe(prof, seg=seg)
    xform(bm, T((cx, cy, 0)))
    parts = [bm]
    ring = r * 1.06
    for i in range(n_merl):
        a = TAU * (i + 0.5) / n_merl
        c = Vector((cx + ring * math.cos(a), cy + ring * math.sin(a), ztop - 0.002))
        parts.append(merlon(c, a, 2 * math.pi * ring / n_merl * 0.5, 0.25 * r + 0.012, 0.042))
    return parts


def build_castle(col=None):
    mb = MB()
    mb.add(lathe([(0.0, -0.02), (0.45, -0.02), (0.45, 0.02), (0.43, 0.055), (0.39, 0.075),
                  (0.0, 0.075)], seg=56), "sand")
    # the keep
    for p in tower(0.0, 0.04, 0.17, 0.33, seg=48, n_merl=8):
        mb.add(p, "sand")
    # towers: two flanking the gate, two at the back (one taller with the flag)
    for (x, y, r, zt, nm) in ((-0.23, -0.12, 0.085, 0.43, 6), (0.23, -0.12, 0.085, 0.43, 6),
                              (0.2, 0.2, 0.095, 0.52, 6), (-0.21, 0.19, 0.08, 0.39, 6)):
        for p in tower(x, y, r, zt, n_merl=nm):
            mb.add(p, "sand")
    # front wall between the front towers, merlons along its top
    wall = bmesh.new()
    bmesh.ops.create_cube(wall, size=1.0)
    xform(wall, T((0, -0.13, 0.06)) @ Matrix.Diagonal((0.42, 0.08, 0.2, 1)) @ T((0, 0, 0.5)))
    mb.add(bevel(wall, 0.006, 2, 30), "sand")
    for i in range(5):
        x = -0.14 + 0.07 * i
        mb.add(merlon(Vector((x, -0.13, 0.258)), math.pi / 2, 0.035, 0.07, 0.04), "sand")
    # the gate: a dark arched door set into the wall, a raised sand frame round it
    gw, gh = 0.052, 0.12
    outline = [Vector((-gw, 0, 0.06))]
    outline += [Vector((-gw * math.cos(math.pi * i / 12), 0, 0.06 + gh - gw + gw * math.sin(math.pi * i / 12)))
                for i in range(13)]
    outline += [Vector((gw, 0, 0.06))]
    door = bmesh.new()
    vs = [door.verts.new(p + Vector((0, -0.171, 0))) for p in outline]
    door.faces.new(vs)
    door = solidify(door, 0.006)
    mb.add(door, "gate", smooth=False)
    frame_pts = [Vector((-gw - 0.012, -0.172, 0.06))]
    frame_pts += [Vector((-(gw + 0.012) * math.cos(math.pi * i / 12), -0.172,
                          0.06 + gh - gw + (gw + 0.012) * math.sin(math.pi * i / 12))) for i in range(13)]
    frame_pts += [Vector((gw + 0.012, -0.172, 0.06))]
    mb.add(tube(frame_pts, 0.011, sides=8), "sand")
    # a little round window on the keep
    mb.add(ellipsoid((0.0, 0.04 - 0.178, 0.29), (0.022, 0.006, 0.026), 12, 8), "gate")
    # flag on the tall tower
    px, py, pz = 0.2, 0.2, 0.52
    mb.add(tube([Vector((px, py, pz - 0.02)), Vector((px, py, pz + 0.17))], 0.0055, sides=6), "bark")
    mb.add(ellipsoid((px, py, pz + 0.175), (0.011, 0.011, 0.011), 10, 6), "flag")

    def ffn(u, v):
        L, H = 0.11, 0.065
        x = u * L
        z = (v - 0.5) * H * (1 - u * 0.92)
        y = 0.01 * math.sin(u * TAU * 1.1) * u
        return (px + 0.004 + x, py + y, pz + 0.135 + z - 0.008 * u)

    flag = grid(ffn, 10, 3)
    mb.add(solidify(flag, 0.003), "flag")
    return node("castle", mb, pivot=(0, 0, 0), collection=col)


def rock_points(rng, n, radii, zsink):
    pts = []
    for i in range(n):
        # Fibonacci directions, jittered, so the hull is chunky but even
        z = 1 - 2 * (i + 0.5) / n
        th = i * math.pi * (3 - math.sqrt(5)) + rng.uniform(-0.25, 0.25)
        rr = math.sqrt(1 - z * z)
        s = rng.uniform(0.86, 1.0)
        p = Vector((rr * math.cos(th) * radii[0], rr * math.sin(th) * radii[1], z * radii[2])) * s
        if p.z > radii[2] * 0.55:
            p.z = radii[2] * 0.55 + (p.z - radii[2] * 0.55) * 0.4   # a flattish top
        pts.append(p + Vector((0, 0, zsink)))
    return pts


def build_rock_a(col=None):
    rng = random.Random(11)
    b = convex_hull(rock_points(rng, 22, (1.0, 0.85, 0.66), 0.38))
    b = bevel(b, 0.09, 3, 25)
    b = bisect_keep_above(b, -0.25)
    return node("rockA", MB().add(b, "rock"), pivot=(0, 0, 0), sharp=32, collection=col)


def build_rock_b(col=None):
    rng = random.Random(5)
    mb = MB()
    b = convex_hull(rock_points(rng, 20, (0.68, 0.62, 0.86), 0.55))
    b = bevel(b, 0.07, 3, 25)
    b = bisect_keep_above(b, -0.25)
    mb.add(b, "rock")
    s = convex_hull([p * 0.45 + Vector((0.62, -0.28, 0.0)) for p in rock_points(rng, 16, (1.0, 0.9, 0.7), 0.3)])
    s = bevel(s, 0.04, 3, 25)
    s = bisect_keep_above(s, -0.2)
    mb.add(s, "rock")
    return node("rockB", mb, pivot=(0, 0, 0), sharp=32, collection=col)
