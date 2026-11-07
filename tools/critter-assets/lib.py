# Shared helpers for the critter asset build: mesh construction in bmesh,
# node creation with explicit pivots, and a USD writer that emits Y-up
# SceneKit-friendly .usdz files.
#
# Modelling space is Blender's: Z up, the critter's face toward -Y. The writer
# converts every point, normal and pivot with (x, y, z) -> (x, z, -y), so in
# the .usdz (and SceneKit) Y is up and the face is +Z. Nodes carry a
# translation only (no rotation, no scale): the scene lane owns every
# rotation, and a node's local axes are always the world's.
import bpy
import bmesh
import math
import os
import shutil
import tempfile
from mathutils import Vector, Matrix

TAU = 2.0 * math.pi

# ---------------------------------------------------------------- materials
# sRGB hex. Roughness only matters to the default SceneKit preview: Lane LOOK
# replaces the lighting model.
MATERIALS = {
    "body":        ("#FFDCC6", 0.75),
    "eye":         ("#2A2136", 0.15),
    "eyeShine":    ("#FFFFFF", 0.10),
    "leaf":        ("#5DBA5A", 0.60),
    "leafVein":    ("#A9DE8A", 0.60),
    "blossom":     ("#FFC4D6", 0.60),
    "bark":        ("#9A6A45", 0.80),
    "canopy":      ("#5DBA5A", 0.70),
    "needles":     ("#3F9152", 0.70),
    "fruit":       ("#E9473E", 0.30),
    "petal":       ("#FFFFFF", 0.60),
    "petalCenter": ("#FFC93C", 0.60),
    "cloud":       ("#FFFFFF", 0.80),
    "wing":        ("#5AA9FF", 0.50),
    "wingEdge":    ("#2E2440", 0.50),
    "wingSpot":    ("#FFFFFF", 0.50),
    "bbody":       ("#2E2440", 0.60),
    "sand":        ("#F2DDA4", 0.90),
    "gate":        ("#B88A58", 0.90),
    "flag":        ("#E9473E", 0.60),
    "rock":        ("#A7A3B4", 0.85),
    "egg":         ("#FFF5E3", 0.50),
    "eggSpot":     ("#8CCB7E", 0.50),
    "nest":        ("#B98A52", 0.90),
}


def hex_rgb(h):
    return tuple(int(h[i:i + 2], 16) / 255.0 for i in (1, 3, 5))


def srgb_to_linear(c):
    return tuple(x / 12.92 if x <= 0.04045 else ((x + 0.055) / 1.055) ** 2.4 for x in c)


def material(name):
    m = bpy.data.materials.get(name)
    if m is None:
        m = bpy.data.materials.new(name)
        lin = srgb_to_linear(hex_rgb(MATERIALS[name][0]))
        m.diffuse_color = (*lin, 1.0)
        m.roughness = MATERIALS[name][1]
    return m


# ---------------------------------------------------------------- bmesh parts

def new_bm():
    return bmesh.new()


def orient_outward(bm):
    """Point a closed part's faces outward. Deterministic, unlike
    bmesh.ops.recalc_face_normals, whose pointer-keyed traversal makes the
    winding (and so the exported triangle order) differ run to run. Every
    part here is built with consistent winding, so a single global flip on
    a negative signed volume is all that is needed."""
    vol = 0.0
    for f in bm.faces:
        vs = [v.co for v in f.verts]
        for i in range(1, len(vs) - 1):
            vol += vs[0].dot(vs[i].cross(vs[i + 1]))
    if vol < 0:
        bmesh.ops.reverse_faces(bm, faces=bm.faces)
    bm.normal_update()
    return bm


def xform(bm, M):
    bmesh.ops.transform(bm, matrix=M, verts=bm.verts)
    bm.normal_update()
    return bm


def deform(bm, fn):
    for v in bm.verts:
        v.co = Vector(fn(v.co.copy()))
    bm.normal_update()
    return bm


def uvsphere(r=1.0, seg=32, ring=16):
    # Not bmesh.ops.create_uvsphere: its face winding varies run to run.
    return lathe([(r * math.sin(math.pi * i / ring), -r * math.cos(math.pi * i / ring))
                  for i in range(ring + 1)], seg=seg)


def ellipsoid(c, radii, seg=32, ring=16, M=None):
    bm = uvsphere(1.0, seg, ring)
    xform(bm, Matrix.Diagonal((*radii, 1.0)))
    if M is not None:
        xform(bm, M)
    xform(bm, Matrix.Translation(Vector(c)))
    return bm


def lathe(profile, seg=32, mod=None, phase=0.0):
    """Surface of revolution about Z. profile: [(r, z), …] bottom to top.
    A zero radius makes a pole. Open ends with r > 0 are capped flat.
    mod(theta, t, r, z) -> (r, z) reshapes each vertex (t = profile index /
    (n - 1))."""
    bm = bmesh.new()
    rings = []
    n = len(profile)
    for i, (r, z) in enumerate(profile):
        t = i / (n - 1)
        if r <= 1e-7:
            rings.append([bm.verts.new((0.0, 0.0, z))])
            continue
        ring = []
        for j in range(seg):
            th = phase + TAU * j / seg
            rr, zz = (mod(th, t, r, z) if mod else (r, z))
            ring.append(bm.verts.new((rr * math.cos(th), rr * math.sin(th), zz)))
        rings.append(ring)
    for a, b in zip(rings, rings[1:]):
        if len(a) == 1 and len(b) == 1:
            continue
        if len(a) == 1:
            for j in range(seg):
                bm.faces.new((a[0], b[j], b[(j + 1) % seg])[::-1])
        elif len(b) == 1:
            for j in range(seg):
                bm.faces.new((a[j], a[(j + 1) % seg], b[0]))
        else:
            for j in range(seg):
                bm.faces.new((a[j], a[(j + 1) % seg], b[(j + 1) % seg], b[j]))
    if len(rings[0]) > 1:
        bm.faces.new(rings[0][::-1])
    if len(rings[-1]) > 1:
        bm.faces.new(rings[-1])
    orient_outward(bm)
    return bm


def _frames(pts):
    """Parallel-transport frames along a polyline."""
    tans = []
    for i in range(len(pts)):
        a = pts[max(i - 1, 0)]
        b = pts[min(i + 1, len(pts) - 1)]
        tans.append((b - a).normalized())
    up = Vector((0, 0, 1)) if abs(tans[0].z) < 0.9 else Vector((1, 0, 0))
    n = tans[0].cross(up).normalized()
    out = []
    for i, t in enumerate(tans):
        if i > 0:
            n = (n - t * n.dot(t)).normalized()
        out.append((t, n, t.cross(n).normalized()))
    return out


def tube(pts, radii, sides=8, caps=True, round_caps=True):
    """Sweep a circle along pts. radii: float or per-point list.
    round_caps closes each end with a small dome instead of a flat fan."""
    pts = [Vector(p) for p in pts]
    if not isinstance(radii, (list, tuple)):
        radii = [radii] * len(pts)
    fr = _frames(pts)
    bm = bmesh.new()
    rings = []

    def ring_at(p, n, b, r):
        return [bm.verts.new(p + (n * math.cos(TAU * k / sides) + b * math.sin(TAU * k / sides)) * r)
                for k in range(sides)]

    # optional domed caps: extra shrinking rings beyond each end
    cap0, cap1 = [], []
    if caps and round_caps:
        t, n, b = fr[0]
        for a in (0.75, 0.4):
            ang = math.acos(a)
            cap0.append(ring_at(pts[0] - t * radii[0] * math.sin(ang), n, b, radii[0] * a))
        cap0 = cap0[::-1]
    for p, (t, n, b), r in zip(pts, fr, radii):
        rings.append(ring_at(p, n, b, r))
    if caps and round_caps:
        t, n, b = fr[-1]
        for a in (0.75, 0.4):
            ang = math.acos(a)
            cap1.append(ring_at(pts[-1] + t * radii[-1] * math.sin(ang), n, b, radii[-1] * a))
    allr = cap0 + rings + cap1
    for a, c in zip(allr, allr[1:]):
        for k in range(sides):
            bm.faces.new((a[k], a[(k + 1) % sides], c[(k + 1) % sides], c[k]))
    if caps:
        t0 = fr[0][0]
        t1 = fr[-1][0]
        e0 = pts[0] - t0 * (radii[0] if round_caps else 0)
        e1 = pts[-1] + t1 * (radii[-1] if round_caps else 0)
        v0 = bm.verts.new(e0)
        v1 = bm.verts.new(e1)
        f = allr[0]
        l = allr[-1]
        for k in range(sides):
            bm.faces.new((v0, f[(k + 1) % sides], f[k]))
            bm.faces.new((v1, l[k], l[(k + 1) % sides]))
    orient_outward(bm)
    return bm


def grid(fn, nu, nv):
    """Open parametric patch: fn(u, v) -> point, u, v in [0, 1]."""
    bm = bmesh.new()
    vs = [[bm.verts.new(fn(i / nu, j / nv)) for j in range(nv + 1)] for i in range(nu + 1)]
    for i in range(nu):
        for j in range(nv):
            bm.faces.new((vs[i][j], vs[i + 1][j], vs[i + 1][j + 1], vs[i][j + 1]))
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-6)
    return bm


def bisect_keep_above(bm, z=0.0, fill=True):
    """Cut at height z, delete below, cap the hole flat."""
    geom = bm.verts[:] + bm.edges[:] + bm.faces[:]
    res = bmesh.ops.bisect_plane(bm, geom=geom, plane_co=(0, 0, z), plane_no=(0, 0, 1),
                                 clear_inner=True)
    if fill:
        edges = [e for e in res["geom_cut"] if isinstance(e, bmesh.types.BMEdge)]
        if edges:
            bmesh.ops.holes_fill(bm, edges=edges, sides=0)
    orient_outward(bm)
    return bm


def convex_hull(points):
    bm = bmesh.new()
    vs = [bm.verts.new(p) for p in points]
    res = bmesh.ops.convex_hull(bm, input=vs)
    bmesh.ops.delete(bm, geom=res["geom_interior"] + res["geom_unused"], context='VERTS')
    orient_outward(bm)
    return bm


def modified(bm, mtype, **props):
    """Apply one Blender modifier to a bmesh (consumes it, returns a new one)."""
    me = bpy.data.meshes.new("_tmp")
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new("_tmp", me)
    bpy.context.scene.collection.objects.link(ob)
    m = ob.modifiers.new("m", mtype)
    for k, v in props.items():
        setattr(m, k, v)
    dg = bpy.context.evaluated_depsgraph_get()
    me2 = bpy.data.meshes.new_from_object(ob.evaluated_get(dg))
    out = bmesh.new()
    out.from_mesh(me2)
    bpy.data.objects.remove(ob)
    bpy.data.meshes.remove(me)
    bpy.data.meshes.remove(me2)
    return out


def subsurf(bm, levels=2):
    return modified(bm, 'SUBSURF', levels=levels, render_levels=levels)


def solidify(bm, thickness, offset=0.0):
    return modified(bm, 'SOLIDIFY', thickness=thickness, offset=offset, use_even_offset=True)


def bevel(bm, width, segments=2, angle=30):
    return modified(bm, 'BEVEL', width=width, segments=segments, limit_method='ANGLE',
                    angle_limit=math.radians(angle))


class MB:
    """Accumulates bmesh parts, each with a material name, into one mesh."""

    def __init__(self):
        self.bm = bmesh.new()
        self.mats = []

    def add(self, part, mat, smooth=True):
        if mat not in self.mats:
            self.mats.append(mat)
        mi = self.mats.index(mat)
        tmp = bpy.data.meshes.new("_part")
        part.to_mesh(tmp)
        part.free()
        n0 = len(self.bm.faces)
        self.bm.from_mesh(tmp)
        self.bm.faces.ensure_lookup_table()
        for f in self.bm.faces[n0:]:
            f.material_index = mi
            f.smooth = smooth
        bpy.data.meshes.remove(tmp)
        return self


# ---------------------------------------------------------------- nodes

PIVOT = {}   # object -> world-space pivot (Blender coords)


def node(name, mb=None, parent=None, pivot=(0, 0, 0), sharp=40.0, collection=None):
    """A named node with its origin at `pivot` (world, Blender coords). Its
    mesh (from `mb`, built in world coords) is re-centred on the pivot."""
    pivot = Vector(pivot)
    tag = (PIVOT_ROOT_NAME(parent) + "/" if parent else "") + name
    if mb is not None:
        me = bpy.data.meshes.new(tag)
        bmesh.ops.translate(mb.bm, verts=mb.bm.verts, vec=-pivot)
        mb.bm.to_mesh(me)
        mb.bm.free()
        for m in mb.mats:
            me.materials.append(material(m))
        if sharp is not None:
            me.set_sharp_from_angle(angle=math.radians(sharp))
        ob = bpy.data.objects.new(tag, me)
    else:
        ob = bpy.data.objects.new(tag, None)
        ob.empty_display_size = 0.1
    (collection or bpy.context.scene.collection).objects.link(ob)
    ob["uname"] = name
    if parent is not None:
        ob.parent = parent
        ob.location = pivot - PIVOT[parent.name]
    else:
        ob.location = pivot
    PIVOT[ob.name] = pivot
    return ob


def PIVOT_ROOT_NAME(parent):
    return parent.name


def uname(ob):
    return ob.get("uname", ob.name)


# ---------------------------------------------------------------- USD writer

def _c(v):
    """Blender (Z up, face -Y) -> USD/SceneKit (Y up, face +Z)."""
    return (round(v[0], 6), round(v[2], 6), round(-v[1], 6))


def export_usdz(path, roots):
    from pxr import Usd, UsdGeom, UsdShade, UsdUtils, Sdf, Gf, Vt

    tmpdir = tempfile.mkdtemp(prefix="critter-usd-")
    base = os.path.splitext(os.path.basename(path))[0]
    usdc = os.path.join(tmpdir, base + ".usdc")
    st = Usd.Stage.CreateNew(usdc)
    UsdGeom.SetStageUpAxis(st, UsdGeom.Tokens.y)
    UsdGeom.SetStageMetersPerUnit(st, 1.0)
    UsdGeom.Scope.Define(st, "/materials")
    mats = {}
    dg = bpy.context.evaluated_depsgraph_get()
    stats = {"tris": 0}

    def usd_material(name):
        if name in mats:
            return mats[name]
        m = UsdShade.Material.Define(st, f"/materials/{name}")
        sh = UsdShade.Shader.Define(st, f"/materials/{name}/surface")
        sh.CreateIdAttr("UsdPreviewSurface")
        lin = srgb_to_linear(hex_rgb(MATERIALS[name][0]))
        sh.CreateInput("diffuseColor", Sdf.ValueTypeNames.Color3f).Set(Gf.Vec3f(*lin))
        sh.CreateInput("roughness", Sdf.ValueTypeNames.Float).Set(MATERIALS[name][1])
        sh.CreateInput("metallic", Sdf.ValueTypeNames.Float).Set(0.0)
        m.CreateSurfaceOutput().ConnectToSource(sh.ConnectableAPI(), "surface")
        mats[name] = m
        return m

    def write_mesh(ob, mpath):
        ev = ob.evaluated_get(dg)
        me = ev.to_mesh()
        me.calc_loop_triangles()
        cn = me.corner_normals
        keys = {}
        pts, nrm, idx, tmat = [], [], [], []
        for lt in me.loop_triangles:
            for li in lt.loops:
                vi = me.loops[li].vertex_index
                n = cn[li].vector
                key = (vi, round(n.x, 3), round(n.y, 3), round(n.z, 3))
                k = keys.get(key)
                if k is None:
                    k = keys[key] = len(pts)
                    pts.append(_c(me.vertices[vi].co))
                    nrm.append(_c(n.normalized()))
                idx.append(k)
            tmat.append(me.polygons[lt.polygon_index].material_index)
        mesh = UsdGeom.Mesh.Define(st, mpath)
        mesh.CreatePointsAttr(Vt.Vec3fArray([Gf.Vec3f(*p) for p in pts]))
        mesh.CreateNormalsAttr(Vt.Vec3fArray([Gf.Vec3f(*n) for n in nrm]))
        mesh.SetNormalsInterpolation(UsdGeom.Tokens.vertex)
        mesh.CreateFaceVertexCountsAttr(Vt.IntArray([3] * len(tmat)))
        mesh.CreateFaceVertexIndicesAttr(Vt.IntArray(idx))
        mesh.CreateSubdivisionSchemeAttr(UsdGeom.Tokens.none)
        lo = [min(p[i] for p in pts) for i in range(3)]
        hi = [max(p[i] for p in pts) for i in range(3)]
        mesh.CreateExtentAttr(Vt.Vec3fArray([Gf.Vec3f(*lo), Gf.Vec3f(*hi)]))
        names = [s.material.name if s.material else "body" for s in ob.material_slots]
        api = UsdShade.MaterialBindingAPI.Apply(mesh.GetPrim())
        used = sorted(set(tmat))
        if len(used) == 1:
            api.Bind(usd_material(names[used[0]]))
        else:
            for mi in used:
                faces = Vt.IntArray([i for i, m in enumerate(tmat) if m == mi])
                sub = api.CreateMaterialBindSubset(names[mi], faces)
                UsdShade.MaterialBindingAPI.Apply(sub.GetPrim()).Bind(usd_material(names[mi]))
        stats["tris"] += len(tmat)
        ev.to_mesh_clear()

    def write(ob, p):
        x = UsdGeom.Xform.Define(st, p)
        x.AddTranslateOp().Set(Gf.Vec3d(*_c(ob.location)))
        if ob.type == 'MESH':
            write_mesh(ob, p + "/" + uname(ob) + "_geo")
        for c in sorted(ob.children, key=lambda o: uname(o)):
            write(c, p + "/" + uname(c))

    for r in roots:
        write(r, "/" + uname(r))
    st.SetDefaultPrim(st.GetPrimAtPath("/" + uname(roots[0])))
    st.GetRootLayer().Save()
    if os.path.exists(path):
        os.remove(path)
    # the zip records the file's mtime: pin it, so a rebuild is byte-identical
    os.utime(usdc, (1767225600, 1767225600))
    UsdUtils.CreateNewUsdzPackage(Sdf.AssetPath(usdc), path)
    shutil.rmtree(tmpdir)
    return stats["tris"]
