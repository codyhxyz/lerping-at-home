// Sponge Descent — original shader written for Lerping@Home (AGPL-3.0, like
// the rest of this project). An endless dive down the tunnels of an infinite
// Menger sponge built from stone blocks, by the light of the torch you carry.
//
// Written from the published mathematics (Karl Menger, 1926: split a cube
// into 27, take out the centre and the six face centres, repeat on the 20
// that remain). All textures are procedural and written here; the block-world
// cues (16-ish texel faces, flat per-face shading, corner darkening, cracks
// that spread before a block breaks) are homage, not copied art.
//
// The world. Space is the sponge mirrored into all eight octants and grown
// outward without end, so it is the same under x -> x/3 about the origin.
// The camera follows a path of three tunnel legs that ends exactly where it
// began, a third the size: one leg along each axis, always towards the
// origin, so every period has one drop down a shaft and two runs through
// level tunnels. Each period is rendered in its own coordinates (scaled by
// 3^n), so float precision never runs out however long it plays, and the
// order of the three legs is drawn per period from the seed.
//
// Blocks. Nothing is subdivided to a fixed depth. A cube is split into its
// 20 children only while the camera is within `detail` of its own edge
// lengths; past that it is one solid block. So every block on screen spans
// between 1/(3·detail) and 1/detail radians whatever the zoom, texels stay
// a few pixels wide at any distance, and the sponge carves itself as you
// approach: over the last span of the approach the middle third of each
// face of a block parts along a seam, cracks and sinks (ten stepped stages),
// then its centre and face centres break out and the 20 smaller blocks
// behind them take its place. The camera also looks partly towards the
// origin (`gaze`), so tunnel walls turn to face it. Nothing is accumulated; the
// split is a function of where the camera is, and the camera of time.
//
// March: a hierarchical DDA. Each step finds the largest empty cube the point
// is in (or the solid block it hit) by descending the levels, then jumps to
// that cube's far face. No distance estimate, no creeping.
//
// Cost, worst pixel: SD_STEPS (64) steps of at most 11 level tests each, then
// at the hit 8 more level walks for corner darkening and one texture. Both
// restart from the deepest cube already known to be shared (SdStart), not
// from the root; that halved the corner-darkening cost. Typical rays take
// 10–25 steps (a step-count heat map was checked). LerpPreview --bench at
// 3456x2234: 8.1 ms mean at t=6.
//
// Light. Two sources and no shadow rays: the torch the camera carries, and
// the glow of the depths, which is also the haze, so far walls stand dark
// against it. What makes the holes read is "openness": a face is lit by the
// glow in proportion to the size of the empty cube in front of it (known for
// free from the march), so the floor of a one-block hole is dark, a hole
// within a hole darker, and the light steps down one level of the sponge at
// a time, the way block-world light steps down a block at a time.
//
// lerp-category: Blocks
//
// lerp-param: speed    float 0.25 3  = 1     "Speed"
// lerp-param: detail   float 4 12    = 6     "Detail"
// lerp-param: mining   float 0 1     = 0.4   "Cracking"
// lerp-param: torch    float 0 2     = 1     "Torch"
// lerp-param: gaze     float 0 0.8   = 0.5   "Look to the core"
// lerp-param: colorStone color       = (0.38, 0.35, 0.30) "Stone"
// lerp-param: colorTrim  color       = (0.29, 0.285, 0.29) "Trim"
// lerp-param: colorFog   color       = (0.10, 0.155, 0.24) "Depths"
// lerp-param: yaw      float -180 180 = 0 "Turn"
// lerp-param: pitch    float -90 90   = 0 "Tilt"
// lerp-param: magnify  float -1 1     = 0 "Zoom"
//
// lerp-preset: Deepslate  colorStone=(0.15, 0.155, 0.17), colorTrim=(0.10, 0.24, 0.20), colorFog=(0.05, 0.10, 0.10), torch=1.4
// lerp-preset: Sandstone  colorStone=(0.45, 0.34, 0.20), colorTrim=(0.20, 0.10, 0.06), colorFog=(0.22, 0.13, 0.07), torch=0.8
// lerp-preset: Quartz     colorStone=(0.56, 0.54, 0.51), colorTrim=(0.16, 0.17, 0.21), colorFog=(0.05, 0.06, 0.10), torch=0.8
// lerp-preset: Nether     colorStone=(0.20, 0.065, 0.06), colorTrim=(0.06, 0.035, 0.04), colorFog=(0.30, 0.09, 0.02), torch=1.0
// lerp-preset: "Fine Grain" detail=10, mining=0.2

constant float SD_PERIOD = 40.0;      // seconds per threefold zoom at speed 1
constant int   SD_STEPS  = 64;
constant int   SD_LMAX   = 8;         // deepest level ever tested
constant float SD_ROOT   = 9.0;       // edge of the coarsest cube considered
constant float SD_TEX    = 18.0;      // texels across a block face (thirds land on texel edges)
constant float SD_FOCAL  = 1.05;
constant float SD_FOG    = 0.85;      // haze distance, period units at scale 1
constant float SD_BAND   = 0.25;      // crack span, as a fraction of the split distance

constant int3 SD_PERM[6] = { int3(0,1,2), int3(0,2,1), int3(1,0,2),
                             int3(1,2,0), int3(2,0,1), int3(2,1,0) };

// ---------------------------------------------------------------------------
// The path.

// Leg order for period n: which axis each of its three legs runs along. The
// first leg never repeats the previous period's last axis, so a drop is
// always between two level runs. Swapping only the first two entries keeps
// every period's last axis its raw draw, so this needs no recursion.
static inline int3 sdRaw(float n, float salt) {
    return SD_PERM[min(int(hash11(n * 0.6180339 + salt) * 6.0), 5)];
}
static inline int3 sdOrder(float n, float salt) {
    int3 o = sdRaw(n, salt);
    if (o.x == sdRaw(n - 1.0, salt).z) o = int3(o.y, o.x, o.z);
    return o;
}

static inline float3 sdAxis(int a) {
    return float3(a == 0 ? 1.0 : 0.0, a == 1 ? 1.0 : 0.0, a == 2 ? 1.0 : 0.0);
}

struct SdPath {
    float3 W[6];      // W[0] = previous period's last corner, W[1..4] this period's, W[5] next's first
    float3 D[5];      // D[j] = direction of the leg from W[j] to W[j+1]
    float  R[6];      // corner radii
};

static inline SdPath sdPath(float n, float salt) {
    int3 o = sdOrder(n, salt), op = sdOrder(n - 1.0, salt), on = sdOrder(n + 1.0, salt);
    SdPath P;
    float3 c0 = float3(0.5);
    float3 a = c0 - sdAxis(o.x) / 3.0;
    float3 b = a - sdAxis(o.y) / 3.0;
    float3 c1 = c0 / 3.0;
    // previous period's b, in this period's coordinates (×3)
    float3 bp = 3.0 * (c0 - sdAxis(op.x) / 3.0 - sdAxis(op.y) / 3.0);
    // next period's a, in this period's coordinates (÷3)
    float3 an = (c0 - sdAxis(on.x) / 3.0) / 3.0;
    P.W[0] = bp; P.W[1] = c0; P.W[2] = a; P.W[3] = b; P.W[4] = c1; P.W[5] = an;
    P.D[0] = -sdAxis(op.z); P.D[1] = -sdAxis(o.x); P.D[2] = -sdAxis(o.y);
    P.D[3] = -sdAxis(o.z);  P.D[4] = -sdAxis(on.x);
    // Corner radii, as wide as each junction allows (a third of the room at
    // c0 and a, half the 1/9 cavity at b); W[4] is W[1] a third the size.
    P.R[0] = 0.15; P.R[1] = 0.15; P.R[2] = 0.14;
    P.R[3] = 0.05; P.R[4] = 0.05; P.R[5] = 0.14 / 3.0;
    return P;
}

// Horizontal heading of a leg: its own direction if level; across a drop it
// turns from the run before to the run after.
static inline float3 sdHeading(SdPath P, int j, float s) {
    if (P.D[j].y == 0.0) return P.D[j];
    // Turned through the whole drop by angle, so the view spins at an even
    // pace (a normalised linear mix spun three times faster mid-drop).
    float a = smoothstep(0.0, 1.0, s) * (0.5 * PI);
    return normalize(P.D[j - 1] * cos(a) + P.D[j + 1] * sin(a));
}

// Position, tangent and heading at arclength u in [0, 1] (period units).
static inline void sdCamera(SdPath P, float u, thread float3& pos, thread float3& tan,
                            thread float3& head) {
    const float L = 1.0 / 3.0;
    int j = clamp(int(floor(u * 3.0)), 0, 2) + 1;     // leg index into W/D
    float s = clamp(u * 3.0 - float(j - 1), 0.0, 1.0);
    float d = s * L;
    head = sdHeading(P, j, s);
    if (d < P.R[j]) {                                  // leaving the corner at W[j]
        float R = P.R[j], sb = (d + R) / (2.0 * R);
        float3 A = P.D[j - 1], B = P.D[j], W = P.W[j];
        float3 p0 = W - R * A, p2 = W + R * B;
        pos = (1.0 - sb) * (1.0 - sb) * p0 + 2.0 * sb * (1.0 - sb) * W + sb * sb * p2;
        tan = normalize((1.0 - sb) * A + sb * B);
    } else if (d > L - P.R[j + 1]) {                   // entering the corner at W[j+1]
        float R = P.R[j + 1], sb = (d - L + R) / (2.0 * R);
        float3 A = P.D[j], B = P.D[j + 1], W = P.W[j + 1];
        float3 p0 = W - R * A, p2 = W + R * B;
        pos = (1.0 - sb) * (1.0 - sb) * p0 + 2.0 * sb * (1.0 - sb) * W + sb * sb * p2;
        tan = normalize((1.0 - sb) * A + sb * B);
    } else {
        pos = P.W[j] + d * P.D[j];
        tan = P.D[j];
    }
}

// ---------------------------------------------------------------------------
// The sponge.

struct SdCell {
    int    solid;     // 0 empty cube, 1 solid block, 2 outside everything
    float  h;         // edge length
    float3 idx;       // integer index at its level, in |p| space
    int    level;     // level (edge 3^-level)
    float  crack;     // 0..1 for a block about to break
};

// Descend from the root: the first level at which `x` falls in a removed
// child gives an empty cube; the first cube too far from the camera to be
// split is a solid block.
// Where a descent starts: a cube known to be split and not removed, so any
// point inside it (same octant) shares every level above it. The march
// keeps the parent of the last empty cube here, which saves re-walking the
// coarse levels on most steps.
struct SdStart {
    float  H, invh;
    float3 P, sg;
    int    k;
};

static inline SdStart sdRoot() {
    SdStart a;
    a.H = SD_ROOT; a.invh = 3.0 / SD_ROOT; a.P = float3(0.0); a.sg = float3(0.0); a.k = -1;
    return a;
}

static inline SdCell sdQueryFrom(float3 x, float3 cam, float K, float band, thread SdStart& st) {
    SdCell c;
    float3 q = abs(x);
    float3 sg = select(float3(-1.0), float3(1.0), x >= 0.0);
    c.crack = 0.0;
    if (max(q.x, max(q.y, q.z)) >= SD_ROOT) {
        c.solid = 2; c.h = SD_ROOT; c.idx = float3(0.0); c.level = -2;
        return c;
    }
    float3 lo = st.P * st.H;
    if (any(sg != st.sg) || any(q < lo) || any(q >= lo + st.H)) st = sdRoot();
    float H = st.H, invh = st.invh;
    float3 P = st.P;
    // Cubes this large are always split: anything the march can reach lies
    // within 1.6 of the camera, so their centres are within K·H.
    float near = 1.6 / max(K - 0.9, 1.0);
    for (int k = st.k; k <= SD_LMAX; ++k) {
        if (H < near) {
            float3 pc = sg * (P + 0.5) * H - cam;
            float d2 = dot(pc, pc);
            float lim = K * H;
            if (d2 > lim * lim) {
                c.solid = 1; c.h = H; c.idx = P; c.level = k - 1;
                float r = sqrt(d2) / lim;
                c.crack = band > 0.0 ? saturate(1.0 - (r - 1.0) / band) : 0.0;
                return c;
            }
        }
        float3 d = clamp(floor(q * invh) - 3.0 * P, 0.0, 2.0);
        float3 C = 3.0 * P + d;
        float3 one = select(float3(0.0), float3(1.0), d == 1.0);
        float h = H * (1.0 / 3.0);
        if (one.x + one.y + one.z >= 2.0) {
            c.solid = 0; c.h = h; c.idx = C; c.level = k;
            st.H = H; st.invh = invh; st.P = P; st.sg = sg; st.k = k;
            return c;
        }
        P = C; H = h; invh *= 3.0;
    }
    c.solid = 1; c.h = H; c.idx = P; c.level = SD_LMAX;
    return c;
}

static inline float sdSolid(float3 x, float3 cam, float K, SdStart st) {
    return sdQueryFrom(x, cam, K, 0.0, st).solid == 1 ? 1.0 : 0.0;
}

// ---------------------------------------------------------------------------
// Block faces.

static inline float sdH(float3 p, float salt) {
    return hash21(p.xy * float2(1.0, 1.37) + float2(p.z * 0.731 + salt, p.z * 1.913 - salt * 0.37));
}

// Crack lines, grown from near the face centre outwards; `stage` in 0..1.
static inline float sdCrack(float2 tc, float stage, float id) {
    float hit = 0.0;
    float2 c0 = float2(9.0) + (float2(hash11(id * 3.1), hash11(id * 5.7)) - 0.5) * 3.0;
    for (int i = 0; i < 5; ++i) {
        float fi = float(i);
        float a = (fi + 0.6 * hash11(id + fi * 1.7)) * TWO_PI / 5.0;
        float a2 = a + (hash11(id * 2.3 + fi) - 0.5) * 1.4;
        float len1 = 3.5 + 2.5 * hash11(id + fi * 9.1);
        float2 m = c0 + len1 * float2(cos(a), sin(a));
        float2 e = m + 6.0 * float2(cos(a2), sin(a2));
        float reach = stage * 12.0;                       // texels from the centre so far
        // segment c0 -> m
        float2 pa = tc - c0, ba = m - c0;
        float hh = saturate(dot(pa, ba) / dot(ba, ba));
        float along = hh * len1;
        if (length(pa - ba * hh) < 0.62 && along < reach) hit = 1.0;
        // segment m -> e
        pa = tc - m; ba = e - m;
        hh = saturate(dot(pa, ba) / dot(ba, ba));
        along = len1 + hh * 6.0;
        if (length(pa - ba * hh) < 0.62 && along < reach) hit = 1.0;
    }
    return hit;
}

// Albedo (linear) of a block face at face coordinates uv in [0,1]^2; `fwT` is
// the pixel footprint in texels, against which texel detail fades out.
static inline float3 sdFace(float2 uv, SdCell b, float la, int axis, float fwT,
                            constant LerpUniforms& u, thread float3& emis) {
    float2 tex = clamp(floor(uv * SD_TEX), 0.0, SD_TEX - 1.0);
    float2 tc = tex + 0.5;
    float3 id = b.idx + float3(la * 7.0, la * 13.0, la * 3.0);
    float h0 = sdH(id, 0.0), h1 = sdH(id, 4.2), h2 = sdH(id, 9.7);
    float faceSalt = float(axis) * 17.0;

    // Corner blocks of their parent are stone brick, edge blocks are trim:
    // the sponge's own 3x3 pattern shows in the masonry.
    float3 dg = glmod3(b.idx, 3.0);
    bool trim = (dg.x == 1.0) || (dg.y == 1.0) || (dg.z == 1.0);

    float v, mean;
    float3 base;
    if (!trim) {
        // Stone brick: two courses of nine, the upper one offset.
        float row = floor(tex.y / 9.0);
        float ty = tex.y - row * 9.0;
        float bx = glmod(tex.x + row * 4.0, 18.0);
        float brick = floor(bx / 9.0);
        float tx = bx - brick * 9.0;
        float tone = 0.88 + 0.22 * sdH(float3(brick, row, faceSalt) + id, 2.0);
        v = tone;
        if (ty == 1.0 || tx == 1.0) v *= 1.09;
        if (ty == 8.0 || tx == 8.0) v *= 0.89;
        if (ty == 0.0 || tx == 0.0) v = 0.66;
        v *= 0.94 + 0.11 * sdH(float3(tex, faceSalt) + id * 1.3, 5.0);
        mean = 0.92;
        base = u.colorStone.rgb;
    } else {
        // Trim: a bevelled frame round a recessed square on the middle third.
        float2 e = min(tex, SD_TEX - 1.0 - tex);
        float ring = min(e.x, e.y);
        v = 1.0;
        if (ring == 0.0) v = 0.72;
        else if (ring == 1.0) v = (tex.x < 9.0 && tex.y < 9.0) ? 1.12 : 1.04;
        bool inner = all(tex >= 6.0) && all(tex <= 11.0);
        bool innerEdge = inner && (tex.x == 6.0 || tex.y == 6.0 || tex.x == 11.0 || tex.y == 11.0);
        if (inner) v = 0.86;
        if (innerEdge) v = (tex.x == 11.0 || tex.y == 11.0) ? 1.02 : 0.72;
        v *= 0.93 + 0.14 * sdH(float3(tex, faceSalt) + id * 1.7, 6.0);
        v *= 0.92 + 0.12 * h1;
        mean = 0.90;
        base = u.colorTrim.rgb;
    }

    float3 col = base * v;
    float3 colMean = base * mean;

    // Moss creeps over one block in five.
    if (h0 < 0.08) {
        float m = valueNoise(tc / 3.2 + id.xy * 0.37 + float2(faceSalt));
        m += 0.35 * hash21(tex + id.xz + faceSalt);
        float thr = axis == 1 ? 0.62 : 0.80;
        if (m > thr) {
            // as dark as the stone it grows on, so dark palettes keep dark moss
            float3 moss = float3(0.20, 0.33, 0.12) * (0.8 + 0.4 * hash21(tex * 1.31 + id.yz))
                        * clamp(dot(base, float3(0.3, 0.59, 0.11)) / 0.29, 0.3, 1.3);
            col = mix(col, moss, 0.9);
        }
        colMean = mix(colMean, colMean * float3(0.75, 1.15, 0.55), axis == 1 ? 0.3 : 0.12);
    }

    // A few blocks carry glowing crystal: emissive texels in a small cluster.
    emis = float3(0.0);
    if (h2 < 0.014) {
        float2 cc = float2(4.0, 4.0) + floor(float2(h1, hash11(h2 * 91.0)) * 10.0);
        float dd = length(tc - cc);
        float sp = hash21(tex + id.xy * 3.1);
        if (dd < 3.2 && sp > 0.35) {
            float3 glow = h1 < 0.5 ? float3(0.75, 0.32, 1.0) : float3(0.25, 0.85, 0.95);
            emis = glow * (0.6 + 0.6 * sp) * (1.0 - smoothstep(0.6, 1.4, fwT) * 0.6);
            col = glow * 0.25;
        }
    }

    // Giving way: the middle third, which is what breaks out, first parts
    // from the face along a seam, then cracks, then sinks into shadow.
    if (b.crack > 0.0) {
        float stage = floor(b.crack * 10.0) / 10.0;
        bool inC = all(tex >= 6.0) && all(tex <= 11.0);
        if (inC) {
            bool seam = tex.x == 6.0 || tex.y == 6.0 || tex.x == 11.0 || tex.y == 11.0;
            float k = seam ? 0.5 * smoothstep(0.0, 0.5, stage) : 0.0;
            if (!seam && stage > 0.25)
                k = 0.32 * sdCrack(tc, (stage - 0.25) * 0.45, h1 * 113.0 + float(axis) * 7.0);
            float sink = mix(1.0, 0.62, smoothstep(0.55, 1.0, stage));
            col *= (1.0 - k) * sink;
        }
        colMean *= 1.0 - 0.06 * stage;
    }

    // Fade texel detail to the face's mean once texels are under a pixel.
    float far = smoothstep(0.6, 1.6, fwT);
    return mix(col, colMean, far);
}

// ---------------------------------------------------------------------------

static inline float3 sdScene(float3 ro, float3 rd, float pxAngle, float s, float K,
                             float la0, float flick, constant LerpUniforms& u) {
    float3 fogC = u.colorFog.rgb;
    float band = SD_BAND * u.mining;
    float tMax = 2.0 * SD_FOG * s;
    float3 ird = 1.0 / select(rd, float3(1e-6), abs(rd) < 1e-6);

    float t = 0.0;
    int axis = 0;
    SdCell hit;
    bool found = false;
    float tFace = 0.0;
    float airH = s;          // edge of the last empty cube crossed before the hit
    SdStart st = sdRoot();
    for (int i = 0; i < SD_STEPS; ++i) {
        float3 x = ro + rd * t;
        SdCell c = sdQueryFrom(x, ro, K, band, st);
        if (c.solid == 1) { hit = c; found = true; tFace = t; break; }
        if (c.solid == 2) break;
        airH = c.h;
        // jump to the far face of this empty cube
        float3 sg = select(float3(-1.0), float3(1.0), x >= 0.0);
        float3 lo = c.idx * c.h, hi = lo + c.h;
        float3 a = sg * lo, b = sg * hi;
        float3 bmin = min(a, b), bmax = max(a, b);
        float3 tt = (select(bmin, bmax, rd > 0.0) - x) * ird;
        float te = tt.x; axis = 0;
        if (tt.y < te) { te = tt.y; axis = 1; }
        if (tt.z < te) { te = tt.z; axis = 2; }
        t += max(te, 0.0) + max(c.h * 2e-3, 2e-6);
        if (t > tMax) break;
    }

    // Gaussian: near walls stay clear, deep ones dissolve into the glow.
    float fogAmt = 1.0 - exp(-pow(t / (SD_FOG * s), 1.8));
    if (!found) return fogC;

    float3 n = float3(0.0);
    n[axis] = rd[axis] > 0.0 ? -1.0 : 1.0;
    // the exact face point (t landed a hair inside the block)
    float3 xh = ro + rd * tFace;
    float H = hit.h;
    float3 sgh = select(float3(-1.0), float3(1.0), (xh - n * 0.5 * H) >= 0.0);
    float3 ctr = sgh * (hit.idx + 0.5) * H;          // block centre, p space
    float3 loc = (xh - ctr) / H + 0.5;               // 0..1 inside the block
    int a1 = axis == 0 ? 2 : 0;                      // face u axis
    int a2 = axis == 1 ? 2 : 1;                      // face v axis (world up on walls)
    float2 uv = saturate(float2(loc[a1], loc[a2]));
    xh[axis] = ctr[axis] + n[axis] * 0.5 * H;        // snap onto the face plane

    // Corner darkening from the eight blocks round the face's air cell.
    float3 t1 = sdAxis(a1), t2 = sdAxis(a2);
    float3 ac = ctr + n * H;
    float s1n = sdSolid(ac - t1 * H, ro, K, st), s1p = sdSolid(ac + t1 * H, ro, K, st);
    float s2n = sdSolid(ac - t2 * H, ro, K, st), s2p = sdSolid(ac + t2 * H, ro, K, st);
    float cnn = sdSolid(ac - t1 * H - t2 * H, ro, K, st), cpn = sdSolid(ac + t1 * H - t2 * H, ro, K, st);
    float cnp = sdSolid(ac - t1 * H + t2 * H, ro, K, st), cpp = sdSolid(ac + t1 * H + t2 * H, ro, K, st);
    float4 vao;   // (--, +-, -+, ++)
    vao.x = (s1n * s2n > 0.5) ? 0.0 : 3.0 - (s1n + s2n + cnn);
    vao.y = (s1p * s2n > 0.5) ? 0.0 : 3.0 - (s1p + s2n + cpn);
    vao.z = (s1n * s2p > 0.5) ? 0.0 : 3.0 - (s1n + s2p + cnp);
    vao.w = (s1p * s2p > 0.5) ? 0.0 : 3.0 - (s1p + s2p + cpp);
    float ao = mix(mix(vao.x, vao.y, uv.x), mix(vao.z, vao.w, uv.x), uv.y) / 3.0;
    ao = 0.42 + 0.58 * ao;

    // Texture in |p| orientation so faces read the same in every octant.
    float cosI = max(abs(rd[axis]), 0.05);
    float fwT = t * pxAngle * pow(cosI, -0.35) / (H / SD_TEX);
    float2 uvt = uv;
    if (sgh[a1] < 0.0) uvt.x = 1.0 - uvt.x;
    if (sgh[a2] < 0.0 && axis != 1) uvt.y = 1.0 - uvt.y;
    float3 emis;
    float3 alb = sdFace(uvt, hit, la0 + float(hit.level), axis, fwT, u, emis);

    // Flat per-face light: tops brightest, then the two wall directions, then undersides.
    float shade = axis == 1 ? (n.y > 0.0 ? 1.0 : 0.42) : (axis == 0 ? 0.74 : 0.56);

    // The torch, warm and close; and the glow of the depths, which is also the
    // haze, so far walls stand dark against it and every hole is a lit square.
    float tr = t / (0.2 * s);
    float torch = u.torch * flick * 1.7 / (1.0 + tr * tr);
    float3 light = float3(1.0, 0.64, 0.34) * torch + fogC * 0.7;
    float lam = 0.6 + 0.4 * abs(rd[axis]);
    // Openness: a face looking into a big cavity sees the glow; one at the
    // bottom of a small hole does not. Measured by the size of the empty cube
    // in front of it, so light steps down one level of the sponge at a time
    // and holes within holes read as ever darker nested squares.
    float open = smoothstep(-4.2, -1.3, log2(airH / s));
    light *= mix(0.14, 1.0, open);
    float3 col = alb * shade * ao * lam * light + emis;
    return mix(col, fogC, fogAmt);
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float minRes = min(u.resolution.x, u.resolution.y);
    float salt = floor(u.seed * 977.0) * 0.137;

    // Period n, phase f. The seed also moves the start within a period.
    float tt = u.time * u.speed / SD_PERIOD + fract(u.seed * 7.31);
    float n = floor(tt) + floor(u.seed * 409.0);
    float f = fract(tt);
    float s = exp2(-f * log2(3.0));                 // the camera's scale, 1 -> 1/3
    float uu = (1.0 - s) * 1.5;                     // arclength: world speed falls as 3^-f

    SdPath P = sdPath(n, salt);
    float3 ro, tng, head;
    sdCamera(P, uu, ro, tng, head);

    // The travel frame: level runs keep world up; on a drop, up is the heading.
    float3 upT = normalize(float3(0.0, 1.0, 0.0) + head * 2.0 * max(0.0, -tng.y));
    upT = normalize(cross(normalize(cross(tng, upT)), tng));
    // Look partly towards the origin, the point the whole dive closes on: the
    // tunnel walls turn to face the eye and the nested holes line up on it.
    float3 fwd = normalize(tng + u.gaze * normalize(-ro));
    float3 upHint = upT;
    float3 right = normalize(cross(fwd, upHint));
    // A slow drift off the tunnel's centre line, in proportion to the scale,
    // so the view is never dead symmetric.
    float3 up0 = cross(right, fwd);
    float sw = u.time * 0.11 + u.seed * 40.0;
    ro += 0.022 * s * (right * sin(sw) + up0 * sin(sw * 0.77 + 1.9));
    fwd = normalize(fwd + 0.05 * (right * sin(sw * 0.61 + 0.4) + up0 * sin(sw * 0.53 + 2.6)));
    right = normalize(cross(fwd, upHint));
    float lens = lerpLook(u.yaw, u.pitch, u.magnify, upHint, right, fwd);
    float3 up = cross(right, fwd);
    float pxAngle = 2.0 / (minRes * SD_FOCAL * lens);

    float flick = 1.0 + 0.035 * sin(u.time * 7.3) + 0.025 * sin(u.time * 12.9 + 1.3);

    float2 uv = lerpUV(pos, u.resolution);
    float3 rd = normalize(uv.x * right + uv.y * up + lens * SD_FOCAL * fwd);
    float3 col = sdScene(ro, rd, pxAngle, s, u.detail, n, flick, u);

    col = col / (1.0 + col * 0.35);
    col = pow(max(col, 0.0), 1.0 / 2.2);
    col = lerpDither(col, pos);
    return half4(half3(col), 1.0h);
}
