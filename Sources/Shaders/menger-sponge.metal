// Menger Sponge — original shader written for Lerping@Home (AGPL-3.0, like
// the rest of this project). Fractal cubes: a slow camera drifting around, or
// flying through the tunnels of, a raymarched Menger sponge and its relatives.
//
// Written from published mathematics, not from anyone's code:
//   - the Menger sponge (Karl Menger, 1926): a cube split into 27, the centre
//     and six face-centre cubes removed, repeated on the 20 that remain;
//   - the Jerusalem cube (Eric Baird, 2011): 8 corner cubes of edge
//     k = sqrt(2) - 1 and 12 edge cubes of edge k^2, so that k + k^2 + k = 1;
//   - distance estimation by folding space, as explained in Inigo Quilez's
//     "Menger Fractal" article (https://iquilezles.org/articles/menger) and in
//     Mikael Hvidtfeldt Christensen's "Distance Estimated 3D Fractals" series
//     (http://blog.hvidtfeldts.net), including Knighty's kaleidoscopic IFS idea
//     of a rotation between folds;
//   - cosine palettes a + b·cos(2π(c·t + d))  (iquilezles.org/articles/palettes)
//     and penumbra soft shadows              (iquilezles.org/articles/rmshadows).
// No code is copied from those pages or from any Shadertoy.
//
// How the distance works. Both fractals are a cube replaced by two kinds of
// child — corner cubes and edge cubes — so one routine draws both. Each level
// folds the point into the positive octant with abs(), which leaves four
// children to consider: one corner cube centred at (1-k1)(1,1,1) and three
// edge cubes centred on the axes. The point descends into the nearest, and the
// second nearest's box bounds everything not descended into, so the untwisted
// distance is a true bound and the march needs no fudge factor. `shape` slides
// the child sizes from Menger (k1 = k2 = 1/3) to Jerusalem (k1 = sqrt2-1,
// k2 = 1 - 2·k1), keeping k1 + k1 + k2 = 1 throughout. `twist` rotates space
// before every fold, Knighty's kaleidoscopic-IFS move.
//
// Cost control (full screen for hours, up to 5K):
//   - the march measures distance in a max-norm weighted by 1/|ray direction|
//     per axis, which for a union of axis-aligned boxes is a lower bound on
//     the distance *along the ray* to the next face it can enter. So each step
//     lands on the next face instead of creeping past walls that run beside
//     the ray, which is what plain sphere tracing does in a tunnel: about a
//     quarter of the evaluations in the tunnels and half outside (mgMap);
//   - normals come from the same evaluation (every face is flat, and the fold
//     records which one was measured), so there are no gradient taps;
//   - level of detail: a level stops descending once its cubes are under a
//     pixel at that distance, so 5K costs ~pixel-ratio times 1200x750, not
//     more iterations; and a level also stops once the point is well outside
//     the chosen child (deeper levels cannot matter);
//   - outside views clip the ray to the sponge's bounding cube first, so sky
//     pixels never march; tunnel views end in fog at a fixed depth;
//   - shadows are only traced in outside views, where the key light is off
//     axis; tunnels are lit from the camera, whose shadows are invisible.
// dusk-terrain's 2x2-quad shared march was tried here too; once steps jump
// face to face it no longer paid for itself, so it is gone.
// GPU cost, LerpPreview --bench --looks at 3840x2160 on an Apple M5 (best of
// four runs; fractal-multiverse 8.4 ms and paper-texture 11.9 ms alongside):
// defaults 8.5 ms, Corridor 9.4, Folded Cube 9.2, Jerusalem Halls 9.9,
// Jerusalem Cube 10.6. Plain sphere tracing with gradient normals measured
// 15–37 ms for the same looks.
//
// Seed: picks the orbit's axis, phase and swoop, the fold's rotation axis,
// and in tunnel mode the start point along the corridor and the sway phases.
// Tunnel coordinates wrap by the lattice period, so float precision holds
// however long the look stays on screen.
//
// lerp-param: shape      float 0 1   = 0.0  "Menger to Jerusalem"
// lerp-param: twist      float 0 1   = 0.0  "Fold twist"
// lerp-param: tunnel     bool        = false "Infinite tunnel"
// lerp-param: iterations int   2 6   = 5    "Detail levels"
// lerp-param: speed      float 0 3   = 1.0  "Camera speed"
// lerp-param: palette    float 0 1   = 0.15 "Palette"
// lerp-param: metal      float 0 1   = 0.65 "Metallic"
// lerp-param: fog        float 0 1   = 0.4  "Fog"
//
// lerp-preset: "Jerusalem Cube"   shape=1.0, palette=0.62, metal=0.55, fog=0.35
// lerp-preset: "Folded Cube"      twist=0.6, iterations=3, palette=0.5, metal=0.85, speed=0.8
// lerp-preset: "Corridor"         tunnel=true, palette=1.0, metal=0.7, fog=0.55
// lerp-preset: "Jerusalem Halls"  tunnel=true, shape=1.0, palette=0.0, fog=0.5
// lerp-preset: "Jerusalem Halls"  metal=0.9, speed=0.7, iterations=4

constant int   MG_STEPS      = 80;     // per-pixel sphere-tracing steps
constant int   MG_SHADOW_STEPS = 12;
constant float MG_SQRT3      = 1.7320508;
constant float MG_TWIST_DAMP = 0.62;    // twisted mode's distance is an estimate, not a bound
constant float MG_FAR_TUNNEL = 9.0;    // tunnel depth; fog is near total by then

struct MgShape {
    float k1, k2;      // corner / edge child half-size, as a fraction of the parent
    float c1, c2;      // their centre offsets, 1 - k
    float ik1, ik2;    // 1 / k
    float3x3 rot;      // fold rotation (identity when twist is 0)
    bool  twisted;
    bool  tiled;
    int   iters;
};

// Rodrigues rotation matrix.
static inline float3x3 mgRotation(float3 axis, float a) {
    float3 n = normalize(axis);
    float s = sin(a), c = cos(a), r = 1.0 - c;
    return float3x3(float3(n.x * n.x * r + c,       n.y * n.x * r + n.z * s, n.z * n.x * r - n.y * s),
                    float3(n.x * n.y * r - n.z * s, n.y * n.y * r + c,       n.z * n.y * r + n.x * s),
                    float3(n.x * n.z * r + n.y * s, n.y * n.z * r - n.x * s, n.z * n.z * r + c));
}

struct MgSample {
    float  d;     // distance, in the max-norm weighted by `iw` (see mgMap)
    float  id;    // which top-level children were taken, for colour
    float3 n;     // normal of the face the distance was measured to
};

// Outward face normal of the box whose per-axis gaps are `g`, for a point at
// `q` from its centre; `sg` maps local axis directions back to world ones.
static inline float3 mgFace(float3 g, float3 q, float3 sg) {
    float3 m = (g.x >= g.y && g.x >= g.z) ? float3(1.0, 0.0, 0.0)
             : (g.y >= g.z ? float3(0.0, 1.0, 0.0) : float3(0.0, 0.0, 1.0));
    return m * select(sg, -sg, q < 0.0);
}

// Distance to the fractal, an id for the leaf cube reached, and the normal of
// the face the distance was measured to. `lod` is the world size below which
// a cube counts as solid.
//
// Every distance here is a max-norm with per-axis weights `iw`: the largest
// of a box's per-axis gaps, each multiplied by its weight. With iw = (1,1,1)
// that is the plain max-norm, a lower bound on Euclidean distance. With
// iw = 1/|rd| it is, for each box, a lower bound on how far a ray along rd
// must travel before it can enter the box (it has to close every gap, at
// |rd_a| per unit of travel on axis a) — so the march steps straight to the
// next face along the ray instead of creeping past walls that run parallel
// to it, which is what made sphere tracing slow in the tunnels.
//
// The fold is abs() alone, which flips axes but never swaps them, so the
// weights stay valid in every child's frame; that leaves four children per
// octant to consider: the corner cube at (c1,c1,c1) and the three edge cubes
// centred on the axes, at (0,c2,c2), (c2,0,c2) and (c2,c2,0). The point
// descends into the nearest, and the second nearest's box bounds every other
// child (a mirrored child is never nearer than its copy in this octant).
// Untwisted, each child's contents lie inside its box, so the result is a
// true bound and the march needs no fudge factor.
//
// Twisted, a rotation precedes every fold: a rotated subtree pokes out of
// its box (it stays inside a sphere of radius sqrt(3)·k, since R = |c| + k·R)
// and those spheres overlap, so siblings cannot serve as bounds and the axes
// no longer line up with the ray. That mode is a plain kaleidoscopic IFS —
// rotate, fold, descend — in the unweighted max-norm, damped by MG_TWIST_DAMP.
static MgSample mgMap(float3 p, thread const MgShape& S, float lod, float3 iw) {
    MgSample r;
    r.id = 0.0;
    r.n = float3(0.0, 0.0, 1.0);
    if (S.twisted) iw = float3(1.0);
    if (S.tiled) p = glmod3(p + 1.0, 2.0) - 1.0;   // lattice of sponges, period 2

    // The whole sponge's bound: for a lone sponge, the early exit far from it;
    // for a twisted lattice, the cell wall that keeps each sponge in its cell.
    // An untwisted lattice cell is filled edge to edge and needs neither.
    float top = -1.0;
    if (S.twisted && !S.tiled) {
        top = length(p) - MG_SQRT3;
    } else if (S.twisted || !S.tiled) {
        float3 g = (abs(p) - 1.0) * iw;
        top = max(g.x, max(g.y, g.z));
    }
    if (!S.tiled && top > 0.6) { r.d = top; return r; }

    float d = 1e9;
    float3 dn = float3(0.0, 0.0, 1.0);
    float3 sg = float3(1.0);       // untwisted: each axis's flip back to world
    float3x3 J = float3x3(1.0);    // twisted: the folds' rotations and flips
    float scale = 1.0;
    float id = 0.0;
    for (int i = 0; i < S.iters; i++) {
        if (S.twisted) p = S.rot * p;
        float3 s = select(float3(1.0), float3(-1.0), p < 0.0);
        if (S.twisted) {
            J = S.rot * J;
            J = float3x3(J[0] * s, J[1] * s, J[2] * s);   // diag(s) · J
        }
        sg *= s;
        p = abs(p);
        // Per-axis gaps to the four children: g1 for the corner cube on every
        // axis; g2 and g0 for an edge cube on an axis where it sits at c2 and
        // on the axis it straddles.
        float3 g1 = (abs(p - S.c1) - S.k1) * iw;
        float3 g2 = (abs(p - S.c2) - S.k2) * iw;
        float3 g0 = (p - S.k2) * iw;
        float dX = max(g0.x, max(g2.y, g2.z));
        float dY = max(g2.x, max(g0.y, g2.z));
        float dZ = max(g2.x, max(g2.y, g0.z));
        float dC = max(g1.x, max(g1.y, g1.z));
        // Nearest (descended into) and second nearest (bounds the rest).
        bool xy = dX < dY, zc = dZ < dC;
        float a = xy ? dX : dY, A = xy ? dY : dX;
        float b = zc ? dZ : dC, B = zc ? dC : dZ;
        bool ab = a < b;
        int pick = ab ? (xy ? 0 : 1) : (zc ? 2 : 3);
        float dMin = ab ? a : b;
        float dSec = ab ? min(A, b) : min(a, B);
        int sec = ab ? (A < b ? (xy ? 1 : 0) : (zc ? 2 : 3))
                     : (a < B ? (xy ? 0 : 1) : (zc ? 3 : 2));
        if (!S.twisted && dSec * scale < d) {
            d = dSec * scale;
            float3 cs = sec == 3 ? float3(S.c1) : float3(sec == 0 ? 0.0 : S.c2, sec == 1 ? 0.0 : S.c2, sec == 2 ? 0.0 : S.c2);
            float3 gs = sec == 3 ? g1 : float3(sec == 0 ? g0.x : g2.x, sec == 1 ? g0.y : g2.y, sec == 2 ? g0.z : g2.z);
            dn = mgFace(gs, p - cs, sg);
        }
        bool corner = pick == 3;
        float3 c = corner ? float3(S.c1) : float3(pick == 0 ? 0.0 : S.c2, pick == 1 ? 0.0 : S.c2, pick == 2 ? 0.0 : S.c2);
        float k = corner ? S.k1 : S.k2;
        p = (p - c) * (corner ? S.ik1 : S.ik2);
        if (i < 2) id = id * 2.618 + (corner ? 0.31 : 0.77);
        // Deeper levels only carve holes the size of this child: if the point
        // is already well outside it (by 0.8 of its half-size), or the child
        // is under a pixel, stop here.
        bool done = dMin > 0.8 * k || scale * k < lod;
        scale *= k;
        if (done) break;
    }
    // The deepest child reached is solid.
    float3 gl = (abs(p) - 1.0) * iw;
    float dl = max(gl.x, max(gl.y, gl.z)) * scale;    if (dl < d) {
        d = dl;
        // Twisted, the leaf is a box in its own rotated frame; its face normal
        // goes back to world space through the transpose of the folds' Jacobian.
        dn = S.twisted ? normalize(transpose(J) * mgFace(gl, p, float3(1.0))) : mgFace(gl, p, sg);
    }
    if (S.twisted) d *= MG_TWIST_DAMP;
    if (S.tiled && S.twisted) d = max(d, top);
    r.d = d;
    r.id = fract(id);
    r.n = dn;
    return r;
}

// Ray against the cube [-1,1]^3, slightly padded. Returns (tnear, tfar).
static inline float2 mgSlab(float3 ro, float3 rd, float pad) {
    float3 inv = 1.0 / rd;
    float3 t0 = (-1.0 - pad - ro) * inv;
    float3 t1 = ( 1.0 + pad - ro) * inv;
    float3 tmin = min(t0, t1), tmax = max(t0, t1);
    return float2(max(max(tmin.x, tmin.y), tmin.z), min(min(tmax.x, tmax.y), tmax.z));
}

// The march. Untwisted, mgMap's distances are already distances along this
// ray (see there), so each step lands on or before the next box face the ray
// can meet; twisted, it is plain sphere tracing. Returns distance and leaf id,
// or t < 0 for a miss.
static inline float3 mgRayWeights(float3 rd) { return 1.0 / max(abs(rd), 1e-4); }

static float2 mgMarch(float3 ro, float3 rd, float t0, float tmax, float px, thread const MgShape& S) {
    float3 iw = mgRayWeights(rd);
    float t = t0;
    for (int i = 0; i < MG_STEPS; i++) {
        if (t > tmax) break;
        float eps = px * t;
        MgSample h = mgMap(ro + rd * t, S, eps, iw);
        if (h.d < eps) return float2(t, h.id);
        t += h.d;
    }
    return float2(-1.0, 0.0);
}

// Surface normal, from one evaluation: every face is flat, so mgMap reports
// the one it measured to. Untwisted that is in the ray's own weighting, which
// names the face the ray is about to enter (not the nearest face: a hit is
// accepted within a pixel along the ray, and in a hole a few pixels wide
// several faces are that close). Its sign can come out flipped where a fold
// plane meets the face, so the caller turns it toward the ray.
static float3 mgNormal(float3 p, float3 rd, thread const MgShape& S, float lod) {
    return mgMap(p, S, lod, mgRayWeights(rd)).n;
}

// Shadow toward the light, marched like the camera ray (in the light ray's
// weighting, so it too jumps face to face). The penumbra term uses that
// along-ray distance, which overstates the clearance from walls the ray runs
// beside, so shadow edges stay fairly crisp — right for hard-edged cubes.
static float mgShadow(float3 p, float3 l, float tmax, float lod, thread const MgShape& S) {
    float3 iw = mgRayWeights(l);
    float res = 1.0;
    float t = 0.01;
    for (int i = 0; i < MG_SHADOW_STEPS; i++) {
        float h = mgMap(p + l * t, S, lod, iw).d;
        res = min(res, 6.0 * h / t);
        t += clamp(h, 0.01, 0.5);
        if (res < 0.02 || t > tmax) break;
    }
    return smoothstep(0.0, 1.0, clamp(res, 0.0, 1.0));
}

// Cosine palette, three looks blended by `sel`: brass/teal, steel/violet, ember.
static float3 mgPal(float t, float sel) {
    float3 a0 = float3(0.50, 0.42, 0.32), b0 = float3(0.40, 0.32, 0.22), c0 = float3(1.0), d0 = float3(0.00, 0.08, 0.22);
    float3 a1 = float3(0.38, 0.40, 0.52), b1 = float3(0.28, 0.30, 0.38), c1 = float3(1.0), d1 = float3(0.55, 0.62, 0.72);
    float3 a2 = float3(0.55, 0.32, 0.25), b2 = float3(0.45, 0.25, 0.20), c2 = float3(1.0, 0.9, 0.8), d2 = float3(0.00, 0.12, 0.25);
    float k = clamp(sel, 0.0, 1.0) * 2.0;
    float3 a = k < 1.0 ? mix(a0, a1, k) : mix(a1, a2, k - 1.0);
    float3 b = k < 1.0 ? mix(b0, b1, k) : mix(b1, b2, k - 1.0);
    float3 c = k < 1.0 ? mix(c0, c1, k) : mix(c1, c2, k - 1.0);
    float3 d = k < 1.0 ? mix(d0, d1, k) : mix(d1, d2, k - 1.0);
    return clamp(a + b * cos(TWO_PI * (c * t + d)), 0.0, 1.0);
}

struct MgLook {
    float  sel;
    bool   tunnel;
    float3 bgLow, bgHigh;
    float3 keyDir, fillDir, keyCol, fillCol;
    float3 up, fwd;
};

// The backdrop behind the sponge: a dark vertical gradient with a faint
// glow toward the key light. In the tunnel, the colour of the fog.
static float3 mgBackdrop(float3 rd, thread const MgLook& L) {
    if (L.tunnel) return mgPal(0.62, L.sel) * 0.05;
    float g = 0.5 + 0.5 * dot(rd, L.up);
    float3 c = mix(L.bgLow, L.bgHigh, g * g);
    c += mgPal(0.35, L.sel) * 0.035 * pow(max(dot(rd, L.keyDir), 0.0), 4.0);
    return c;
}

// What a metal surface reflects: a soft "softbox" around the key light, a
// dimmer one around the fill, and a bright band at the horizon, over the
// backdrop. Rougher surfaces see wider, dimmer boxes. In the tunnel the lamp
// sits behind the viewer and the far end of the tunnel glows faintly.
static float3 mgEnvironment(float3 r, float rough, thread const MgLook& L) {
    float w = 0.25 + 0.6 * rough;
    if (L.tunnel) {
        float3 c = mgPal(0.62, L.sel) * 0.02;
        c += L.keyCol * 0.35 * smoothstep(1.0 - w, 1.0, dot(r, -L.fwd)) / (1.0 + 2.0 * rough);
        c += mgPal(0.62, L.sel) * 0.12 * smoothstep(0.6, 1.0, dot(r, L.fwd));
        return c;
    }
    float3 c = mgBackdrop(r, L) * 1.6;
    float k = dot(r, L.keyDir);
    // A broad wash, so every face orientation reads as its own tone, and the
    // softbox itself on top.
    c += L.keyCol * 0.28 * pow(clamp(0.5 + 0.5 * k, 0.0, 1.0), 3.0);
    c += L.keyCol * 0.85 * smoothstep(1.0 - w, 1.0 - 0.3 * w, k) / (1.0 + 2.0 * rough);
    c += L.fillCol * 0.9 * smoothstep(1.0 - 1.2 * w, 1.0, dot(r, L.fillDir));
    float hz = dot(r, L.up);
    c += mgPal(0.45, L.sel) * 0.10 * exp(-10.0 * hz * hz);
    return c;
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float2 uv = lerpUV(pos, u.resolution);
    float tm = u.time * u.speed;

    // --- Seeded constants.
    float s0 = hash11(u.seed * 91.7 + 1.3);
    float s1 = hash11(u.seed * 53.1 + 7.9);
    float s2 = hash11(u.seed * 17.3 + 4.1);

    // --- Fractal shape.
    MgShape S;
    float m = smoothstep(0.0, 1.0, u.shape);
    S.k1 = mix(1.0 / 3.0, 0.41421356, m);
    S.k2 = 1.0 - 2.0 * S.k1;
    S.c1 = 1.0 - S.k1;
    S.c2 = 1.0 - S.k2;
    S.ik1 = 1.0 / S.k1;
    S.ik2 = 1.0 / S.k2;
    S.tiled = u.tunnel != 0;
    S.iters = clamp(u.iterations, 2, 6);
    S.twisted = u.twist > 0.001;
    float3 twAxis = normalize(float3(s0 - 0.5, 1.0, s1 - 0.5) + float3(0.3, 0.0, 0.2));
    float twAng = u.twist * (0.42 + 0.18 * sin(0.031 * tm + 6.2831 * s2));
    S.rot = mgRotation(twAxis, twAng);

    // --- Camera.
    const float focal = 1.75;
    float3 ro, fwd, upHint;
    if (S.tiled) {
        // Down the central tunnel of a lattice of sponges, through a cross-
        // shaped hall every 2 units, swaying gently and rolling slowly.
        float z = 0.16 * tm + s0 * 2.0;
        float a = 0.05 * tm + s1 * 6.2831;
        float sway = 0.18 * (1.0 - S.k1 * 1.5);           // keep clear of the tunnel wall
        ro = float3(sway * sin(1.3 * a), sway * 0.8 * sin(0.9 * a + 1.7), glmod(z, 2.0));
        float3 look = float3(0.25 * sin(0.7 * a + 0.4), 0.18 * sin(0.53 * a + 2.3), 1.0);
        fwd = normalize(look);
        float roll = 0.6 * sin(0.21 * a + s2 * 6.2831);
        upHint = float3(sin(roll), cos(roll), 0.0);
    } else {
        // A slow orbit on a tilted plane that swoops in and out.
        float a = 0.045 * tm + s0 * 6.2831;
        float r = (3.05 + 0.65 * sin(0.37 * a + s1 * 6.2831)) * (S.twisted ? 1.3 : 1.0);   // a twisted cluster reaches radius sqrt(3)
        float h = 1.15 * sin(0.29 * a + s2 * 6.2831);
        float3 orb = float3(r * cos(a), h, r * sin(a));
        float3x3 tilt = mgRotation(float3(1.0, 0.0, 0.3), (s1 - 0.5) * 0.9);
        ro = tilt * orb;
        float3 target = 0.25 * float3(sin(0.21 * a), sin(0.17 * a + 1.0), cos(0.19 * a));
        fwd = normalize(target - ro);
        upHint = tilt * float3(0.0, 1.0, 0.0);
    }
    float3 right = normalize(cross(upHint, fwd));
    float3 up = cross(fwd, right);
    float3 rd = normalize(uv.x * right + uv.y * up + focal * fwd);
    float px = 2.0 / (focal * min(u.resolution.x, u.resolution.y));   // one pixel, as an angle

    // --- Colours and lights. The key light rides with the camera (upper
    // right, a little behind the viewer) so the faces in view are always lit
    // and the holes fall into shadow; a weak complementary fill comes from
    // the left.
    MgLook L;
    L.sel = u.palette;
    L.tunnel = S.tiled;
    L.bgLow  = mgPal(0.05, u.palette) * 0.045;
    L.bgHigh = mgPal(0.55, u.palette) * 0.10;
    L.keyDir = normalize(0.62 * right + 0.62 * up - 0.48 * fwd);
    L.fillDir = normalize(-0.85 * right - 0.15 * up + 0.1 * fwd);
    L.keyCol = mgPal(0.10, u.palette) * 1.6 + 0.35;
    L.fillCol = mgPal(0.62, u.palette) * 0.35;
    L.up = up; L.fwd = fwd;
    float3 sky = mgBackdrop(rd, L);

    // --- Trace.
    float t0 = 0.0, tmax = MG_FAR_TUNNEL;
    bool live = true;
    if (!S.tiled) {
        float2 sl = mgSlab(ro, rd, S.twisted ? 0.74 : 0.01);
        t0 = max(sl.x, 0.0);
        tmax = sl.y;
        live = sl.x < sl.y && sl.y > 0.0;
    }
    float2 hit = mgMarch(ro, rd, t0, live ? tmax : -1.0, px, S);
    if (!live) hit.x = -1.0;

    float3 col = sky;
    if (hit.x > 0.0) {
        float t = hit.x;
        float3 p = ro + rd * t;
        float lod = px * t;
        int zero = min(int(u.seed), 0);
        float3 n = mgNormal(p, rd, S, lod);
        n = dot(n, rd) > 0.0 ? -n : n;   // a face the ray hit faces the ray

        // Ambient occlusion from two probes along the normal: cheap, and
        // enough to darken every hole by its depth.
        float occ = 0.0;
        for (int i = zero; i < 2; i++) {
            float h = i == 0 ? 0.02 : 0.08;
            occ += (h - mgMap(p + n * h, S, lod, float3(1.0)).d) * (i == 0 ? 1.0 : 0.5);
        }
        float ao = clamp(1.0 - 8.0 * occ, 0.0, 1.0);
        ao = 0.12 + 0.88 * ao * ao;

        // Material: palette metal, each leaf cube nudged in hue and roughness.
        float metal = u.metal;
        float3 base = mgPal(0.16 + 0.05 * hit.y, u.palette);
        float rough = mix(0.32, 0.5, fract(hit.y * 3.7));
        float3 f0 = mix(float3(0.04), base, metal);
        float3 alb = base * (1.0 - metal);
        float3 v = -rd;
        float nv = max(dot(n, v), 1e-3);

        // Key light: directional outside (with a soft shadow), the camera's
        // lamp in the tunnel (whose shadows the camera can't see).
        float3 l = L.keyDir;
        float3 lc = L.keyCol;
        float sh = 1.0;
        if (S.tiled) {
            float3 lv = ro + 0.10 * up + 0.12 * right - p;
            float ld = length(lv);
            l = lv / ld;
            lc = L.keyCol * 2.4 / (1.0 + 7.0 * ld * ld);
        } else if (dot(n, l) > 0.0) {
            sh = mgShadow(p + n * 2.0 * lod, l, 2.0, 3.0 * lod, S);
        }
        float dif = max(dot(n, l), 0.0) * sh;
        float3 hv = normalize(l + v);
        float shin = 2.0 / max(pow(rough, 4.0), 1e-4) - 2.0;
        float3 fres = f0 + (1.0 - f0) * pow(1.0 - max(dot(hv, v), 0.0), 5.0);
        float3 spec = lc * fres * dif * pow(max(dot(n, hv), 0.0), shin) * (shin + 8.0) / 25.0;
        float3 diff = lc * dif * alb;

        // Fill and ambient, then a reflection of the studio backdrop that
        // gives each face orientation its own tone.
        float envAtt = 1.0;
        if (!S.tiled) {
            diff += L.fillCol * max(dot(n, L.fillDir), 0.0) * alb * ao;
        } else {
            // In a tunnel, what a wall reflects is more wall, lit by the same
            // lamps, so reflections fade with depth like the lamps do.
            envAtt = 1.0 / (1.0 + 0.8 * t * t);
            // A second, complementary light a little way down the tunnel, so
            // walls ahead and walls alongside take different colours.
            float3 bv = ro + 2.6 * fwd - p;
            float bd = length(bv);
            float3 bl = bv / bd;
            float3 bc = mgPal(0.12 + 0.5, u.palette) * 1.2 / (1.0 + 1.5 * bd * bd);
            float bdif = max(dot(n, bl), 0.0);
            float3 bh = normalize(bl + v);
            diff += bc * bdif * (alb + 0.25 * metal * base) * ao;
            spec += bc * fres * bdif * pow(max(dot(n, bh), 0.0), shin) * (shin + 8.0) / 25.0;
        }
        diff += (S.tiled ? L.bgHigh * 0.5 : L.bgHigh * 2.0 + 0.02) * (0.6 + 0.4 * dot(n, up)) * alb * ao;
        float3 r = reflect(rd, n);
        float3 env = mgEnvironment(r, rough, L);
        float3 fenv = f0 + (1.0 - f0) * pow(1.0 - nv, 5.0) * (1.0 - rough);
        spec += env * fenv * ao * mix(1.0, sh, 0.5) * envAtt;

        col = diff + spec * mix(0.6, 1.0, ao);

        // Depth fog toward the backdrop.
        float fogK = mix(0.01, S.tiled ? 0.11 : 0.05, u.fog);
        float fogT = 1.0 - exp(-fogK * t * t);
        if (S.tiled) fogT = max(fogT, smoothstep(0.7 * MG_FAR_TUNNEL, MG_FAR_TUNNEL, t));
        else fogT = 1.0 - exp(-fogK * max(t - 1.5, 0.0) * 6.0);
        col = mix(col, sky, clamp(fogT, 0.0, 1.0));
    }

    // Tonemap and back to display space.
    col = 1.0 - exp(-1.1 * col);
    col = sqrt(max(col, 0.0));
    col = lerpDither(col, pos);
    return half4(half3(col), 1.0h);
}
