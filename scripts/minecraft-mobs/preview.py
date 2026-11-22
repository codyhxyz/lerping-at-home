#!/usr/bin/env python3 -I
"""Software-render mobs from a generated mobs.metal, to check them by eye
without a GPU. It decodes the MCMOB_* tables and traces them the way
funcs.metal's mcMobTrace, mcMobColor and mcMobLead do (a port, not gen.py's own
model objects), and samples the packed atlas (skins.rgba, maps.rgba), so a
picture that looks like the game means the tables and the layer numbers are
right.

    python3 -I preview.py OUT.png TYPE[:BASE[:FUR]] ...
        --dir DIR     folder with mobs.metal, atlas.txt, atlas.json, skins.rgba, maps.rgba
                      (default ~/Library/Application Support/Lerping/Minecraft)
        --walk W      walk phase (default 0: standing); --speed S stride (default 0.6 when walking)
        --yaw Y --pitch P   head turn, radians
        --lead        add a scene: two of the first mob led by a holder MCMOB_TRADER_HOLD up,
                      with their ground shadows (needs MCS_MISC_SHADOW in the atlas)

TYPE is an MCMOB_* name without the prefix; BASE and FUR are atlas constants
(MCS_*/MCM_*), FUR the second model's skin. Each mob gets a row of four views,
from its front, its left, its back and its front right, 20 degrees above level.
Nearest texels, face shade only, no lighting.
"""
import argparse, math, os, re, sys
import numpy as np
from PIL import Image, ImageDraw

DIR = os.path.expanduser('~/Library/Application Support/Lerping/Minecraft')

def die(msg):
    sys.stderr.write('preview: ' + msg + '\n'); sys.exit(1)

def load(folder):
    src = open(os.path.join(folder, 'mobs.metal')).read()
    tables = {}
    for m in re.finditer(r'constant (half4|float4|int4|float) (MCMOB_\w+)\[(\d+)\] = \{\n(.*?)\};', src, re.S):
        rows = re.findall(r'\(([^)]*)\)', m.group(4)) if m.group(1) != 'float' else m.group(4).split(',')
        a = np.array([[float(x) for x in r.split(',')] for r in rows])
        if len(a) != int(m.group(3)): die('%s has %d rows, says %s' % (m.group(2), len(a), m.group(3)))
        tables[m.group(2)] = a
    consts = {k: float(v) for k, v in re.findall(r'^constant (?:int|float) (MCMOB_\w+) = ([-\d.e]+);', src, re.M)}
    vecs = {k: np.array([float(x) for x in v.split(',')]) for k, v in re.findall(r'^constant float3 (MCMOB_\w+) = float3\(([^)]*)\);', src, re.M)}
    layers = {}
    for line in open(os.path.join(folder, 'atlas.txt')):
        m = re.match(r'(MC[SM]_\w+)\s+(skins|maps)\[(\d+)\]', line)
        if m: layers[m.group(1)] = (m.group(2), int(m.group(3)))
    import json
    meta = json.load(open(os.path.join(folder, 'atlas.json')))
    arrays = {'skins': np.memmap(os.path.join(folder, 'skins.rgba'), np.uint8, 'r', shape=(meta['skins'], 64, 64, 4)),
              'maps': np.memmap(os.path.join(folder, 'maps.rgba'), np.uint8, 'r', shape=(meta['maps'], 256, 256, 4))}
    return tables, consts, vecs, layers, arrays

def rot(e):
    """R = Rz Ry Rx per pixel; e is (N, 3)."""
    c, s = np.cos(e), np.sin(e)
    N = len(e); o, z = np.ones(N), np.zeros(N)
    Rx = np.stack([np.stack([o, z, z], -1), np.stack([z, c[:, 0], -s[:, 0]], -1), np.stack([z, s[:, 0], c[:, 0]], -1)], 1)
    Ry = np.stack([np.stack([c[:, 1], z, s[:, 1]], -1), np.stack([z, o, z], -1), np.stack([-s[:, 1], z, c[:, 1]], -1)], 1)
    Rz = np.stack([np.stack([c[:, 2], -s[:, 2], z], -1), np.stack([s[:, 2], c[:, 2], z], -1), np.stack([z, z, o], -1)], 1)
    return Rz @ Ry @ Rx

class Kit:
    def __init__(self, folder):
        self.T, self.C, self.V, self.layers, self.arrays = load(folder)

    def texel(self, layer, px):
        arr, i = self.layers[layer] if isinstance(layer, str) else layer
        a = self.arrays[arr]
        size = 128 if arr == 'maps' else 64      # the kit's clamp (funcs.metal mcMobAlpha)
        q = np.clip(px, 0, size - 1).astype(int)
        return a[i, q[:, 1], q[:, 0]].astype(np.float64) / 255.0

    def trace(self, t, pose, base, fur, ro, rd, tmax):
        """mcMobTrace for N rays in mob space. Returns t, normal (mob space), px, flags."""
        T = self.T; N = len(ro)
        ty = T['MCMOB_TYPE'][t].astype(int)
        big = ty[2] != 0
        om = np.stack([16 * ro[:, 0], 24 - 16 * ro[:, 1], -16 * ro[:, 2]], -1)
        dm = np.stack([16 * rd[:, 0], -16 * rd[:, 1], -16 * rd[:, 2]], -1)
        best = np.full(N, tmax, float)
        hitN = np.zeros((N, 3)); hitPx = np.zeros((N, 2)); hitFlags = np.zeros(N, int); hit = np.zeros(N, bool)
        c0 = math.cos(pose['walk'] * 0.6662) * pose['speed']
        B = T['MCMOB_BONE']; BOX = T['MCMOB_BOX']; UV = T['MCMOB_UV']
        for b in range(ty[0], ty[0] + ty[1]):
            k = b * 10
            Q = B[k:k + 3]; Pm = B[k + 3:k + 6]; rest, an, fl, sph = B[k + 6], B[k + 7], B[k + 8], B[k + 9]
            o1 = om @ Q[:, :3].T + Q[:, 3]; d1 = dm @ Q[:, :3].T
            oc = o1 - sph[:3]
            sa = (d1 * d1).sum(1); sb = (oc * d1).sum(1); sc = (oc * oc).sum(1) - sph[3] ** 2
            disc = sb * sb - sa * sc
            sq = np.sqrt(np.maximum(disc, 0))
            live = (disc >= 0) & ~((-sb - sq) > best * sa) & ~((-sb + sq) < 0)
            if not live.any(): continue
            e = rest[:3] + np.array([an[0] * c0, 0, 0]) + fl[:3] * pose['flap'] + np.array([0, an[2] * pose['wag'], 0])
            if an[1] >= 0: e = e + np.array([pose['pitch'] + an[1] * pose['graze'], -pose['yaw'], 0])
            Rm = rot(np.tile(e, (N, 1)))[0]
            o1 = o1 @ Rm; d1 = d1 @ Rm            # Rt * o1
            o = o1 @ Pm[:, :3].T + Pm[:, 3]; d = d1 @ Pm[:, :3].T
            dd = np.where(np.abs(d) < 1e-9, 1e-9, d); inv = 1 / dd
            for ci in range(int(rest[3]), int(rest[3]) + int(an[3])):
                lo, hi = BOX[ci * 2], BOX[ci * 2 + 1]
                flags = int(lo[3])
                if (flags & 128) and fur is None: continue
                ta = (lo[:3] - o) * inv; tb = (hi[:3] - o) * inv
                tn3 = np.minimum(ta, tb); tf3 = np.maximum(ta, tb)
                tn = tn3.max(1); tf = tf3.min(1)
                cand = live & ~((tn > tf) | (tf <= 0) | (tn >= best) | (tn <= 0))
                if not cand.any(): continue
                ext = np.maximum(hi[:3] - lo[:3], 1e-6)
                def face_at(tt, entry):
                    if entry:
                        ax = np.where((tn3[:, 0] >= tn3[:, 1]) & (tn3[:, 0] >= tn3[:, 2]), 0, np.where(tn3[:, 1] >= tn3[:, 2], 1, 2))
                    else:
                        ax = np.where((tf3[:, 0] <= tf3[:, 1]) & (tf3[:, 0] <= tf3[:, 2]), 0, np.where(tf3[:, 1] <= tf3[:, 2], 1, 2))
                    dax = d[np.arange(N), ax]
                    face = ax * 2 + (((dax < 0) if entry else (dax > 0))).astype(int)
                    f = np.clip((o + d * tt[:, None] - lo[:3]) / ext, 0, 1)
                    m = UV[ci * 6 + face]
                    ab = np.where(ax[:, None] == 0, f[:, [2, 1]], np.where(ax[:, None] == 1, f[:, [0, 2]], f[:, [0, 1]]))
                    px = m[:, :2] + m[:, 2:] * ab
                    ok = ((flags >> face) & 1) != 0
                    if flags & 64:
                        ok = ok & (self.alpha(flags, px, big, base, fur) > 0.5)
                    return face, px, ok
                face, px, ok = face_at(tn, True)
                t_ = tn.copy()
                retry = cand & ~ok & (tf < best)
                if retry.any():
                    face2, px2, ok2 = face_at(tf, False)
                    face = np.where(retry, face2, face); px = np.where(retry[:, None], px2, px)
                    t_ = np.where(retry, tf, t_); ok = np.where(retry, ok2, ok)
                won = cand & ok & (t_ < best)
                if not won.any(): continue
                best = np.where(won, t_, best)
                sg = np.where(face & 1, 1.0, -1.0); fa = face >> 1
                nb = np.zeros((N, 3)); nb[np.arange(N), fa] = sg
                n1 = (nb @ Pm[:, :3]) @ Rm.T
                hn = n1 @ Q[:, :3]
                hitN = np.where(won[:, None], hn, hitN); hitPx = np.where(won[:, None], px, hitPx)
                hitFlags = np.where(won, flags, hitFlags); hit |= won
        n = np.stack([hitN[:, 0], -hitN[:, 1], -hitN[:, 2]], -1)
        n /= np.maximum(np.linalg.norm(n, axis=1, keepdims=True), 1e-9)
        return np.where(hit, best, np.inf), n, hitPx, hitFlags

    def alpha(self, flags, px, big, base, fur):
        if flags & 128: return self.texel(fur, px)[:, 3]
        return self.texel(base, px)[:, 3]

    def color(self, base, fur, px, flags):
        c = self.texel(base, px)[:, :3]
        if fur is not None:
            c = np.where((flags & 128)[:, None] != 0, self.texel(fur, px)[:, :3], c)
        return c

    def lead(self, ro, rd, a, b, tmax):
        """mcMobLead for N world rays: t, rgb (game sRGB, unlit)."""
        N = len(ro); d = b - a; h = math.hypot(d[0], d[2])
        best = np.full(N, tmax, float); rgb = np.zeros((N, 3))
        m = np.array([-d[2], 0, d[0]]) / h
        def at(f):
            y = d[1] * f * f if d[1] > 0 else d[1] - d[1] * (1 - f) ** 2
            return a + np.array([d[0] * f, y, d[2] * f])
        for s in range(24):      # no slab cull here: every segment, so the cull in funcs.metal is checked by agreement
            p0 = at(s / 24); e2 = at((s + 1) / 24) - p0
            for sg in (1.0, -1.0):
                c = p0 - sg * 0.025 * m; e1 = sg * 0.05 * m + np.array([0, 0.05, 0])
                pv = np.cross(rd, e2); det = pv @ e1
                tv = ro - c; u = (tv * pv).sum(1) / det
                qv = np.cross(tv, e1); v = (rd * qv).sum(1) / det; t = qv @ e2 / det
                won = (u >= 0) & (u <= 1) & (v >= 0) & (v <= 1) & (t > 0) & (t < best)
                best = np.where(won, t, best)
                rgb = np.where(won[:, None], np.array([0.5, 0.4, 0.3]) * (0.7 if s & 1 else 1.0), rgb)
        return np.where(best < tmax, best, np.inf), rgb

    def shadow(self, t, at, p, cam, light):
        """mcMobShadow for N ground points p (nearest texel)."""
        r = min(self.T['MCMOB_SHADOW'][t][0], 32.0)
        s = 1.0 - ((at - cam) ** 2).sum() / 256.0
        if s <= 0 or light <= 3: return np.zeros(len(p))
        cell = np.floor(p[:, [0, 2]])
        ok = ((cell >= np.floor(at[[0, 2]] - r)) & (cell <= np.floor(at[[0, 2]] + r))).all(1)
        top = np.round(p[:, 1])
        ok &= (top >= math.floor(at[1] - min(s / 0.5 - 1.0, r))) & (top <= math.floor(at[1]))
        b = light / 15.0
        a = np.clip((s - (at[1] - top) * 0.5) * 0.5 * (b / (4 - 3 * b)), 0, 1)
        uv = np.clip(0.5 - (p[:, [0, 2]] - at[[0, 2]]) / (2 * r), 0, 1)
        return np.where(ok, a * self.texel('MCS_MISC_SHADOW', uv * 64)[:, 3], 0.0)

def p3_to_srgb(c):
    lin = np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)
    M = np.linalg.inv(np.array([[0.8224621, 0.1775380, 0.0], [0.0331941, 0.9668058, 0.0], [0.0170827, 0.0723974, 0.9105199]]))
    lin = np.clip(lin @ M.T, 0, 1)
    return np.where(lin <= 0.0031308, lin * 12.92, 1.055 * lin ** (1 / 2.4) - 0.055)

def shade(n):
    a = np.abs(n)
    return np.where(a[:, 1] > 0.5, np.where(n[:, 1] > 0, 1.0, 0.5), np.where(a[:, 2] > 0.5, 0.8, 0.6))

def camera(eye, target, W, H, fov=40):
    f = target - eye; f /= np.linalg.norm(f)
    r = np.cross(f, [0, 1, 0]); r /= np.linalg.norm(r); u = np.cross(r, f)
    j, i = np.mgrid[0:H, 0:W]
    k = math.tan(math.radians(fov) / 2)
    x = (2 * (i + 0.5) / W - 1) * k * W / H; y = (1 - 2 * (j + 0.5) / H) * k
    rd = (x.reshape(-1, 1) * r + y.reshape(-1, 1) * u + f)
    rd /= np.linalg.norm(rd, axis=1, keepdims=True)
    return np.tile(eye, (W * H, 1)), rd

def to_mob(ro, rd, at, heading):
    c, s = math.cos(heading), math.sin(heading)
    p = ro - at
    return (np.stack([c * p[:, 0] - s * p[:, 2], p[:, 1], s * p[:, 0] + c * p[:, 2]], -1),
            np.stack([c * rd[:, 0] - s * rd[:, 2], rd[:, 1], s * rd[:, 0] + c * rd[:, 2]], -1))

def to_world_n(n, heading):
    c, s = math.cos(heading), math.sin(heading)
    return np.stack([c * n[:, 0] + s * n[:, 2], n[:, 1], -s * n[:, 0] + c * n[:, 2]], -1)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('out'); ap.add_argument('mobs', nargs='+')
    ap.add_argument('--dir', default=DIR); ap.add_argument('--size', type=int, default=220)
    ap.add_argument('--walk', type=float, default=0.0); ap.add_argument('--speed', type=float, default=None)
    ap.add_argument('--yaw', type=float, default=0.0); ap.add_argument('--pitch', type=float, default=0.0)
    ap.add_argument('--lead', action='store_true')
    a = ap.parse_args()
    kit = Kit(a.dir)
    pose = {'walk': a.walk, 'speed': a.speed if a.speed is not None else (0.6 if a.walk else 0.0),
            'yaw': a.yaw, 'pitch': a.pitch, 'graze': 0.0, 'flap': 0.0, 'wag': 0.0}
    W = H = a.size
    rows = []
    for spec in a.mobs:
        parts = spec.split(':')
        name = 'MCMOB_' + parts[0]
        if name not in kit.C: die('no ' + name + ' in mobs.metal')
        t = int(kit.C[name])
        base = parts[1] if len(parts) > 1 else None
        fur = parts[2] if len(parts) > 2 and parts[2] else None
        for l in (base, fur):
            if l is not None and l not in kit.layers: die('no layer ' + l + ' in atlas.txt')
        lo, hi = kit.T['MCMOB_AABB'][2 * t][:3], kit.T['MCMOB_AABB'][2 * t + 1][:3]
        ctr = (lo + hi) / 2; rad = np.linalg.norm(hi - lo) / 2
        views = []
        for az in (0, 90, 180, 45):       # front, its left, back, front right
            th = math.radians(az); el = math.radians(20); dist = rad / math.tan(math.radians(20)) * 1.05
            eye = ctr + dist * np.array([math.cos(el) * math.sin(th), math.sin(el), math.cos(el) * math.cos(th)])
            ro, rd = camera(eye, ctr, W, H)
            # bounds first, as a look does; a pixel outside them must not show the mob
            inv = 1 / np.where(np.abs(rd) < 1e-9, 1e-9, rd)
            ta, tb = (lo - ro) * inv, (hi - ro) * inv
            enter = np.maximum(np.minimum(ta, tb).max(1), 0); leave = np.maximum(ta, tb).min(1)
            tt, n, px, fl = kit.trace(t, pose, base, fur, ro, rd, 1e9)
            outside = np.isfinite(tt) & ~(enter < leave)
            if outside.any(): die('%s: %d hits outside MCMOB_AABB' % (name, outside.sum()))
            img = np.tile(np.array([0.78, 0.84, 0.9]), (W * H, 1))
            m = np.isfinite(tt)
            if m.any():
                img[m] = p3_to_srgb(kit.color(base, fur, px[m], fl[m])) * shade(n[m])[:, None]
            views.append((img.reshape(H, W, 3) * 255).astype(np.uint8))
        rows.append((spec, np.concatenate(views, 1)))
    if a.lead:
        t = int(kit.C['MCMOB_' + a.mobs[0].split(':')[0]])
        parts = a.mobs[0].split(':'); base = parts[1]; fur = parts[2] if len(parts) > 2 and parts[2] else None
        holder = np.array([0.0, 0.0, 0.0]); hold = holder + np.array([0, kit.C['MCMOB_TRADER_HOLD'], 0])
        llamas = [(np.array([-2.2, 0.0, 1.6]), math.radians(120)), (np.array([2.6, 0.0, -0.8]), math.radians(-80))]
        scene = []
        for eye in (np.array([0.5, 3.0, 9.0]), np.array([9.0, 2.0, 1.0])):
            ro, rd = camera(eye, np.array([0.0, 1.0, 0.4]), 2 * W, H, fov=55)
            best = np.full(len(ro), np.inf); img = np.tile(np.array([0.78, 0.84, 0.9]), (len(ro), 1))
            g = rd[:, 1] < 0; tg = np.where(g, -ro[:, 1] / np.where(g, rd[:, 1], -1), np.inf)
            best = np.minimum(best, tg); gr = np.isfinite(tg); img[gr] = [0.45, 0.6, 0.3]
            gp = ro[gr] + rd[gr] * tg[gr][:, None]
            for at, hd in llamas:    # the ground shadow, light 15, the camera where this eye is
                img[gr] *= 1 - kit.shadow(t, at, gp, eye, 15)[:, None]
            for at, hd in llamas:
                lro, lrd = to_mob(ro, rd, at, hd)
                tt, n, px, fl = kit.trace(t, pose, base, fur, lro, lrd, 1e9)
                w = tt < best
                if w.any():
                    best = np.where(w, tt, best)
                    img[w] = p3_to_srgb(kit.color(base, fur, px[w], fl[w])) * shade(to_world_n(n[w], hd))[:, None]
                leash = at + to_world_n(kit.V['MCMOB_LLAMA_LEASH'][None, :], hd)[0]
                tl, rgb = kit.lead(ro, rd, leash, hold, 1e9)
                w = tl < best
                best = np.where(w, tl, best); img[w] = rgb[w]
            # the holder's hand: a small post so the far end is visible
            inv = 1 / np.where(np.abs(rd) < 1e-9, 1e-9, rd)
            lo, hi = holder + np.array([-0.06, 0, -0.06]), hold + np.array([0.06, 0.0, 0.06])
            ta, tb = (lo - ro) * inv, (hi - ro) * inv
            en = np.minimum(ta, tb).max(1); lv = np.maximum(ta, tb).min(1)
            w = (en < lv) & (en > 0) & (en < best); img[w] = [0.2, 0.2, 0.6]
            scene.append((img.reshape(H, 2 * W, 3) * 255).astype(np.uint8))
        rows.append(('lead: ' + a.mobs[0] + ' (blue post: the holder, MCMOB_TRADER_HOLD tall)', np.concatenate(scene, 1)))
    width = max(r[1].shape[1] for r in rows)
    out = Image.new('RGB', (width, sum(r[1].shape[0] + 16 for r in rows)), (255, 255, 255))
    y = 0; dr = ImageDraw.Draw(out)
    for label, im in rows:
        dr.text((4, y + 2), label, fill=(0, 0, 0)); out.paste(Image.fromarray(im), (0, y + 16)); y += im.shape[0] + 16
    out.save(a.out); print('preview: wrote', a.out)

if __name__ == '__main__':
    with np.errstate(all='ignore'):   # numpy's Accelerate matmul raises spurious FP warnings on clean data
        main()
