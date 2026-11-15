// Village Timelapse — a hamlet on a small island in a sunset sea, forever
// being built. Original work for Lerping@Home; every block, texture and
// building is procedural.
//
// lerp-category: Blocks
//
// The island is laid out as a three-by-three grid of plots between dirt
// roads. Each plot runs its own cycle: a house, a stone watchtower or a tree
// goes up one block at a time — layer by layer, the builder walking round
// each course and turning back on the next, so every course is a spiral —
// then stands with its windows lit, then is mined out from the top down, each
// block cracking before it goes, and something new is started in its place.
// The nine plots are staggered, so the village is always mostly standing and
// always somewhere under construction; a new block pops in with a flash and a
// thin outline, which is what draws the eye round the island.
//
// Purity: nothing is remembered. Which block exists at time t is decided by
// comparing that block's place in the build order — a function of its
// position — with how far the plot's cycle has run. A plot's design is a hash
// of (plot, cycle, seed).
//
// Texels are 16 to a block face and box-filtered to the pixel footprint (four
// texture taps, fading to the face's mean colour when a texel falls below a
// pixel), so faces stay crisp up close and calm in the distance.
//
// lerp-param: speed   float 0.25 3   = 1    "Build speed"
// lerp-param: sun     float 0 1      = 0.36 "Sun height"
// lerp-animate: sun 0.28 0.46 period=300
// lerp-param: orbit   float 0 3      = 1    "Orbit speed"
// lerp-param: yaw     float -180 180 = 0    "Turn"
// lerp-param: pitch   float -25 45   = 0    "Tilt"
// lerp-param: magnify float -1 1     = 0    "Zoom"
//
// lerp-preset: Noon     sun=0.85
// lerp-preset: Night    sun=0.03
// lerp-preset: Bustle   speed=2.5

// --- Timeline, in build-clock seconds (u.time × speed).
constant float VT_T    = 120.0;   // one plot's cycle
constant float VT_B1   = 0.5;     // building until here (fraction of a cycle)
constant float VT_D0   = 0.82;    // standing until here, then mined out
constant float VT_D1   = 0.975;   // gone; the plot stands empty until the cycle ends
constant float VT_POP  = 0.55;    // a new block settling into place
constant float VT_MINE = 0.8;     // one block's cracking

// --- World.
constant float VT_SEA   = 0.875;  // water surface
constant int   VT_STEPS = 120;    // primary DDA steps (worst case through the box)
constant int   VT_SHADOW_STEPS = 40;
constant float VT_FOCAL = 2.1;
constant float3 VT_BMIN = float3(-22.0, -7.0, -22.0);
constant float3 VT_BMAX = float3( 22.0, 11.0,  22.0);

// Materials.
constant int M_AIR = 0, M_GRASS = 1, M_DIRT = 2, M_STONE = 3, M_COBBLE = 4,
             M_PLANK = 5, M_LOG = 6, M_GLASS = 7, M_ROOF = 8, M_BRICK = 9,
             M_LEAVES = 10, M_PATH = 11, M_SAND = 12, M_LANTERN = 13;

struct VtWorld {
    float tt;      // build clock
    float now;     // wall clock, for water
    uint  seedBits;
    float2 noiseOff;
};

struct VtCell {
    int   m;
    float var;     // material variant 0..1
    float age;     // build-clock seconds since it was placed
    float crack;   // 0..1 while being mined
    float lit;     // windows lit
};

static inline VtCell vtEmpty() {
    VtCell v; v.m = M_AIR; v.var = 0.0; v.age = 1e3; v.crack = 0.0; v.lit = 0.0;
    return v;
}

static inline uint vtPcg(uint v) {
    uint s = v * 747796405u + 2891336453u;
    uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
    return (w >> 22u) ^ w;
}

static inline float vtHash2(int2 c, uint salt) {
    uint h = vtPcg(uint(c.x) * 73856093u ^ vtPcg(uint(c.y) * 19349663u ^ salt));
    return float(h) * (1.0 / 4294967296.0);
}

// Where a block falls in the build order within its course: the angle round
// the structure's centre, swept one way on even courses and back on odd.
static inline float vtSweep(int a, int b, int y, float ang0, uint salt) {
    float th = atan2(float(b) + 0.013, float(a) + 0.031) * (1.0 / TWO_PI);
    float dir = (y & 1) != 0 ? 1.0 : -1.0;
    float j = vtHash2(int2(a * 17 + b, y), salt);
    return fract(th * dir + ang0) * 0.94 + 0.04 * j;
}

// ---------------------------------------------------------------------------
// Structures. Local coordinates: a along the long axis, b across, y up from
// the ground course (y = 0 replaces the grass). Each returns a material and
// writes its build key o (0..1, build order) and removal key rk (0..1).

static inline int vtHouse(int a, int y, int b, int ha, int wh, bool chimney, float ang0,
                          uint salt, thread float& o, thread float& rk) {
    const int hb = 2;
    int aa = abs(a), ab = abs(b);
    int ridge = wh + 1 + hb + 1;                 // the ridge course
    if (aa > ha || ab > hb + 1 || y > ridge + 1) return M_AIR;
    int m = M_AIR;
    if (y == 0) {
        if (ab <= hb) m = M_COBBLE;
    } else if (y <= wh) {
        if (ab <= hb && (ab == hb || aa == ha)) {
            m = (ab == hb && aa == ha) ? M_LOG : M_PLANK;
            if (y == 2 && ((ab == hb && aa == 1) || (aa == ha && b == 0))) m = M_GLASS;
            if (b == -hb && a == 0 && y <= 2) m = M_AIR;    // the door
        }
    } else {
        int k = y - wh - 1;                          // roof course
        if (k <= hb + 1) {
            if (ab == hb + 1 - k) m = M_ROOF;
            else if (ab < hb + 1 - k && aa == ha) m = M_PLANK;   // gable
        }
    }
    if (chimney && a == ha - 1 && b == 1 && y > wh && y <= ridge + 1) m = M_COBBLE;
    if (m == M_AIR) return m;
    o = (float(y) + vtSweep(a, b, y, ang0, salt)) / float(ridge + 2);
    rk = 1.0 - o;
    return m;
}

static inline int vtTower(int a, int y, int b, int h, float ang0, uint salt,
                          thread float& o, thread float& rk) {
    int aa = abs(a), ab = abs(b);
    if (aa > 2 || ab > 2 || y > h + 1) return M_AIR;
    bool rim = aa == 2 || ab == 2;
    int m = M_AIR;
    if (y == 0) m = M_COBBLE;
    else if (y < h) {
        if (rim) {
            m = y == 1 ? M_COBBLE : M_BRICK;
            if (b == -2 && a == 0 && y <= 2) m = M_AIR;                  // door
            if (y % 3 == 0 && (a == 0 || b == 0)) m = M_AIR;             // arrow slits
        }
    } else if (y == h) m = M_BRICK;                                      // roof deck
    else {
        if (rim && ((a + b) & 1) == 0) m = M_BRICK;                     // merlons
        if (a == 0 && b == 0) m = M_LANTERN;
    }
    if (m == M_AIR) return m;
    o = (float(y) + vtSweep(a, b, y, ang0, salt)) / float(h + 2);
    rk = 1.0 - o;
    return m;
}

static inline int vtTree(int a, int y, int b, int th, uint salt,
                         thread float& o, thread float& rk) {
    if (abs(a) > 2 || abs(b) > 2 || y > th + 2) return M_AIR;
    if (a == 0 && b == 0 && y >= 1 && y <= th) {
        o = 0.28 * float(y) / float(th);
        rk = 0.72 + 0.27 * float(th - y) / float(th);
        return M_LOG;
    }
    float3 d = float3(float(a), float(y - th) - 0.3, float(b)) / float3(2.6, 2.1, 2.6);
    float dd = length(d);
    if (y < th - 2 || dd > 1.0) return M_AIR;
    float h = vtHash2(int2(a * 7 + b, y), salt);
    if (dd > 0.72 && h < 0.3) return M_AIR;                              // ragged edge
    o = 0.3 + 0.68 * saturate(dd + 0.08 * h);                            // crown swells outward
    rk = 0.7 * h;                                                        // leaves fall at random
    return M_LEAVES;
}

// One plot's block at plot-local (lx, y, lz).
static inline VtCell vtPlotCell(int j, int lx, int y, int lz, VtWorld W) {
    VtCell v = vtEmpty();
    if (y > 10 || abs(lx) > 3 || abs(lz) > 3) return v;
    float off = fract(float(j) * 0.6180339 + float(W.seedBits & 1023u) * (1.0 / 1024.0)) * VT_T;
    float cyc = (W.tt + off) * (1.0 / VT_T);
    float k = floor(cyc), ph = cyc - k;
    if (ph >= VT_D1) return v;
    uint hp = vtPcg(uint(j) * 2654435761u ^ vtPcg(uint(int(k)) * 2246822519u ^ W.seedBits));
    float pick = float(hp & 255u) / 256.0;
    int type = pick < 0.45 ? 1 : (pick < 0.66 ? 2 : 3);
    bool swap = (hp >> 8) & 1u, flip = (hp >> 9) & 1u;
    int ha = 2 + int((hp >> 10) & 1u);
    int varH = int((hp >> 11) & 3u);
    int offA = int((hp >> 13) % 3u) - 1, offB = int((hp >> 15) % 3u) - 1;
    float var = float((hp >> 17) & 255u) / 256.0;
    float ang0 = float((hp >> 25) & 127u) / 128.0;

    int a = swap ? lz : lx, b = swap ? lx : lz;
    if (flip) { a = -a; b = -b; }
    int m; float o = 0.0, rk = 0.0;
    if (type == 1) {
        a -= offA * (3 - ha);
        m = vtHouse(a, y, b, ha, 3 + (varH & 1), (hp >> 19) & 1u, ang0, hp, o, rk);
    } else if (type == 2) {
        a -= offA; b -= offB;
        m = vtTower(a, y, b, 6 + varH, ang0, hp, o, rk);
    } else {
        a -= offA; b -= offB;
        m = vtTree(a, y, b, 4 + varH % 3, hp, o, rk);
    }
    if (m == M_AIR) return v;

    float bp = saturate(ph * (1.0 / VT_B1));
    if (o >= bp) return v;
    v.age = (bp - o) * VT_B1 * VT_T;
    if (ph > VT_D0) {
        float span = (VT_D1 - VT_D0) * VT_T;
        float d = (ph - VT_D0) * VT_T / span;
        float w = VT_MINE / span;
        float cr = (d - rk * (1.0 - w)) / w;
        if (cr >= 1.0) return v;
        v.crack = saturate(cr);
        if (m == M_LEAVES) v.crack = 0.0;       // leaves just drop
    }
    v.m = m;
    v.var = var;
    v.lit = smoothstep(VT_B1 + 0.005, VT_B1 + 0.03, ph) * (1.0 - smoothstep(VT_D0 - 0.02, VT_D0, ph));
    return v;
}

static inline float vtIslandR(float2 pc, VtWorld W) {
    return 18.2 + 2.8 * valueNoise(pc * 0.085 + W.noiseOff);
}

static inline VtCell vtCell(int3 c, VtWorld W) {
    VtCell v = vtEmpty();
    if (c.y > 10 || c.y < -7) return v;
    float2 pc = float2(c.xz) + 0.5;
    bool town = c.x >= -13 && c.x <= 13 && c.z >= -13 && c.z <= 13;
    int lx = 0, lz = 0;
    if (town) {
        int px = (c.x + 13) / 9 - 1, pz = (c.z + 13) / 9 - 1;
        lx = c.x - px * 9; lz = c.z - pz * 9;
        if (c.y >= 0) {
            // Lantern posts at the four inner crossroads.
            if ((c.x == 5 || c.x == -5) && (c.z == 5 || c.z == -5) && c.y >= 1 && c.y <= 2) {
                v.m = c.y == 1 ? M_LOG : M_LANTERN; v.lit = 1.0; return v;
            }
            v = vtPlotCell((px + 1) * 3 + pz + 1, lx, c.y, lz, W);
            if (v.m != M_AIR || c.y > 0) return v;
        }
    } else if (c.y > 2) return v;

    float r = length(pc);
    float R = vtIslandR(pc, W);
    float colH = vtHash2(c.xz, 0x5bd1e995u ^ W.seedBits);
    if (r > R) {
        // Sea floor: sand shelving away in block terraces.
        int top = -1 - int(min((r - R) * 0.6 + colH * 0.7, 5.0));
        if (c.y > top) return v;
        v.m = c.y > top - 2 ? M_SAND : M_STONE;
        v.var = colH;
        return v;
    }
    int top = 0;
    if (!town) {
        float hill = valueNoise(pc * 0.2 + W.noiseOff * 1.7 + 11.0);
        top = hill > 0.6 ? (hill > 0.78 ? 2 : 1) : 0;
    }
    if (c.y > top) return v;
    bool beach = r > R - 1.6 && top == 0;
    if (c.y == top) {
        bool road = town && (abs(lx) == 4 || abs(lz) == 4);
        v.m = beach ? M_SAND : (road ? M_PATH : M_GRASS);
    } else if (beach && c.y >= -2) {
        v.m = M_SAND;
    } else {
        v.m = c.y >= top - 2 - int(colH * 2.0) ? M_DIRT : M_STONE;
    }
    v.var = colH;
    return v;
}

static inline bool vtSolid(int3 c, VtWorld W) { return vtCell(c, W).m != M_AIR; }

static inline float vtPopScale(float age) {
    if (age >= VT_POP) return 1.0;
    float x = age / VT_POP;
    return 0.3 + 0.7 * (1.0 - (1.0 - x) * (1.0 - x) * (1.0 - x));
}

// ---------------------------------------------------------------------------
// Tracing.

struct VtHit {
    bool   hit;
    float  t;
    float3 n;
    int3   c;
    float3 lo;     // the face's box: a popping block is smaller than its cell
    float  sz;
    VtCell v;
};

static inline bool vtBox(float3 ro, float3 inv, float3 lo, float3 hi, thread float2& tr) {
    float3 t1 = (lo - ro) * inv, t2 = (hi - ro) * inv;
    float3 tn = min(t1, t2), tf = max(t1, t2);
    tr = float2(max(max(tn.x, tn.y), tn.z), min(min(tf.x, tf.y), tf.z));
    return tr.x <= tr.y && tr.y > 0.0;
}

static inline VtHit vtTrace(float3 ro, float3 rd, VtWorld W) {
    VtHit h; h.hit = false; h.t = 1e9;
    float3 inv = 1.0 / select(rd, float3(1e-6), abs(rd) < 1e-6);
    float3 t1 = (VT_BMIN - ro) * inv, t2 = (VT_BMAX - ro) * inv;
    float3 tn = min(t1, t2), tf = max(t1, t2);
    float tEnter = max(max(tn.x, tn.y), max(tn.z, 0.0));
    float tExit = min(min(tf.x, tf.y), tf.z);
    if (tEnter >= tExit) return h;
    int axis = tn.x > tn.y ? (tn.x > tn.z ? 0 : 2) : (tn.y > tn.z ? 1 : 2);
    int3 c = int3(floor(ro + rd * (tEnter + 1e-4)));
    c = clamp(c, int3(VT_BMIN), int3(VT_BMAX) - 1);
    int3 st = int3(sign(rd));
    float3 tMax = (float3(c) + step(0.0, rd) - ro) * inv;
    float3 tDel = abs(inv);
    float tc = tEnter;
    for (int i = 0; i < VT_STEPS; ++i) {
        VtCell v = vtCell(c, W);
        if (v.m != M_AIR) {
            float s = vtPopScale(v.age);
            if (s >= 0.999) {
                h.hit = true; h.t = tc; h.c = c; h.v = v; h.lo = float3(c); h.sz = 1.0;
                h.n = float3(0.0); h.n[axis] = -float(st[axis]);
                return h;
            }
            float3 lo = float3(c) + 0.5 - 0.5 * s;
            float2 tr;
            if (vtBox(ro, inv, lo, lo + s, tr)) {
                float3 q = (ro + rd * tr.x - (lo + 0.5 * s)) / (0.5 * s);
                float3 aq = abs(q);
                int ax = aq.x > aq.y ? (aq.x > aq.z ? 0 : 2) : (aq.y > aq.z ? 1 : 2);
                h.hit = true; h.t = tr.x; h.c = c; h.v = v; h.lo = lo; h.sz = s;
                h.n = float3(0.0); h.n[ax] = sign(q[ax]);
                return h;
            }
        }
        if (tMax.x < tMax.y) {
            if (tMax.x < tMax.z) { tc = tMax.x; c.x += st.x; tMax.x += tDel.x; axis = 0; }
            else                 { tc = tMax.z; c.z += st.z; tMax.z += tDel.z; axis = 2; }
        } else {
            if (tMax.y < tMax.z) { tc = tMax.y; c.y += st.y; tMax.y += tDel.y; axis = 1; }
            else                 { tc = tMax.z; c.z += st.z; tMax.z += tDel.z; axis = 2; }
        }
        if (tc > tExit) break;
    }
    return h;
}

// 1 lit, 0 in shadow.
static inline float vtShadow(float3 ro, float3 rd, VtWorld W) {
    float3 inv = 1.0 / select(rd, float3(1e-6), abs(rd) < 1e-6);
    float3 t1 = (VT_BMIN - ro) * inv, t2 = (VT_BMAX - ro) * inv;
    float tExit = min(min(max(t1.x, t2.x), max(t1.y, t2.y)), max(t1.z, t2.z));
    int3 c = int3(floor(ro));
    int3 st = int3(sign(rd));
    float3 tMax = (float3(c) + step(0.0, rd) - ro) * inv;
    float3 tDel = abs(inv);
    for (int i = 0; i < VT_SHADOW_STEPS; ++i) {
        float tc;
        if (tMax.x < tMax.y) {
            if (tMax.x < tMax.z) { tc = tMax.x; c.x += st.x; tMax.x += tDel.x; }
            else                 { tc = tMax.z; c.z += st.z; tMax.z += tDel.z; }
        } else {
            if (tMax.y < tMax.z) { tc = tMax.y; c.y += st.y; tMax.y += tDel.y; }
            else                 { tc = tMax.z; c.z += st.z; tMax.z += tDel.z; }
        }
        if (tc > tExit) return 1.0;
        if (vtSolid(c, W)) return 0.0;
    }
    return 1.0;
}

// ---------------------------------------------------------------------------
// Textures: 16 × 16 texels a face. `face` 0 top, 1 side, 2 bottom. Colours
// are authored in sRGB and returned linear.

static inline float3 vtLin(float3 c) { return c * c * (0.3 + 0.7 * c); }   // ≈ pow 2.2, cheap

static inline float3 vtPlankCol(float var) {
    int k = int(var * 4.0) & 3;
    return k == 0 ? float3(0.66, 0.50, 0.31) : (k == 1 ? float3(0.80, 0.71, 0.50)
         : (k == 2 ? float3(0.45, 0.32, 0.19) : float3(0.62, 0.42, 0.28)));
}
static inline float3 vtRoofCol(float var) {
    int k = int(fract(var * 4.0) * 4.0) & 3;
    return k == 0 ? float3(0.60, 0.22, 0.16) : (k == 1 ? float3(0.30, 0.33, 0.42)
         : (k == 2 ? float3(0.26, 0.42, 0.28) : float3(0.36, 0.24, 0.17)));
}
static inline float3 vtLeafCol(float var) {
    return var < 0.62 ? float3(0.24, 0.47, 0.16) : (var < 0.84 ? float3(0.42, 0.58, 0.24)
         : float3(0.80, 0.42, 0.12));
}

constant float3 VT_GRASS = float3(0.37, 0.62, 0.24);
constant float3 VT_DIRT  = float3(0.53, 0.37, 0.25);
constant float3 VT_STONE = float3(0.50, 0.50, 0.50);
constant float3 VT_SANDC = float3(0.86, 0.79, 0.56);
constant float3 VT_PATHC = float3(0.60, 0.50, 0.31);

// Mean colour of a face, for the far distance.
static inline float3 vtMean(int m, int face, float var) {
    switch (m) {
    case M_GRASS:   return face == 0 ? VT_GRASS * 0.95 : (face == 1 ? mix(VT_DIRT, VT_GRASS, 0.25) * 0.95 : VT_DIRT * 0.95);
    case M_DIRT:    return VT_DIRT * 0.93;
    case M_STONE:   return VT_STONE * 0.92;
    case M_COBBLE:  return float3(0.47, 0.47, 0.46);
    case M_PLANK:   return vtPlankCol(var) * 0.9;
    case M_LOG:     return face == 1 ? float3(0.38, 0.29, 0.18) : float3(0.62, 0.50, 0.32);
    case M_GLASS:   return float3(0.35, 0.33, 0.32);
    case M_ROOF:    return vtRoofCol(var) * 0.88;
    case M_BRICK:   return float3(0.44, 0.44, 0.43);
    case M_LEAVES:  return vtLeafCol(var) * 0.72;
    case M_PATH:    return face == 0 ? VT_PATHC * 0.95 : VT_DIRT * 0.93;
    case M_SAND:    return VT_SANDC * 0.95;
    default:        return float3(0.6, 0.45, 0.25);
    }
}

static inline float3 vtTex(int m, int face, float2 uv, float var) {
    float2 t = floor(clamp(uv, 0.0, 0.9999) * 16.0);
    float n = hash21(t + float2(float(m) * 31.0, float(face) * 7.0 + 0.5));
    float n2 = hash21(t.yx * 1.7 + float2(float(m) * 13.0 + 5.0, 2.0));
    float3 c;
    switch (m) {
    case M_GRASS: {
        if (face == 0) { c = VT_GRASS * (0.78 + 0.34 * n); break; }
        float fr = 3.0 + step(0.5, hash21(float2(t.x, 91.0))) + step(0.8, hash21(float2(t.x, 17.0)));
        if (face == 1 && 15.0 - t.y < fr) c = VT_GRASS * (0.72 + 0.3 * n);
        else c = VT_DIRT * (0.8 + 0.3 * n) * (n2 > 0.9 ? 0.72 : 1.0);
        break;
    }
    case M_DIRT:
        c = VT_DIRT * (0.8 + 0.3 * n) * (n2 > 0.9 ? 0.72 : 1.0);
        break;
    case M_PATH:
        if (face == 0) c = VT_PATHC * (0.82 + 0.28 * n) * (n2 > 0.88 ? 0.8 : 1.0);
        else c = VT_DIRT * (0.8 + 0.3 * n);
        break;
    case M_SAND:
        c = VT_SANDC * (0.88 + 0.18 * n) * (n2 > 0.93 ? 0.85 : 1.0);
        break;
    case M_STONE: {
        float blot = valueNoise(t * 0.35 + 3.0);
        c = VT_STONE * (0.84 + 0.16 * n) * (0.82 + 0.3 * blot);
        if (n2 > 0.965) c = float3(0.28, 0.27, 0.27);   // coal specks
        break;
    }
    case M_COBBLE: {
        // Jittered 4-texel cells; the gap between nearest and second-nearest
        // seed is the mortar.
        float2 g = (t + 0.5) / 5.0, gi = floor(g);
        float d1 = 9.0, d2 = 9.0, id = 0.0;
        for (int yy = -1; yy <= 1; ++yy)
        for (int xx = -1; xx <= 1; ++xx) {
            float2 cc = gi + float2(xx, yy);
            float2 cw = glmod2(cc, 3.2);
            float2 pp = cc + 0.2 + 0.6 * hash22(cw + 7.0);
            float dd = length(g - pp);
            if (dd < d1) { d2 = d1; d1 = dd; id = hash21(cw + 1.3); }
            else if (dd < d2) d2 = dd;
        }
        c = (d2 - d1 < 0.17) ? float3(0.26, 0.26, 0.26)
                             : float3(0.5, 0.5, 0.49) * (0.75 + 0.45 * id) * (0.92 + 0.12 * n);
        break;
    }
    case M_PLANK: {
        float row = floor(t.y / 4.0);
        float sx = floor(hash11(row + 3.0) * 16.0);
        bool seam = fmod(t.y, 4.0) < 0.5 || fmod(t.x + sx, 16.0) < 0.5;
        float3 base = vtPlankCol(var);
        c = base * (0.88 + 0.16 * hash21(float2(floor(t.x / 3.0) + row * 5.0, row)) + 0.06 * n);
        if (seam) c = base * 0.58;
        break;
    }
    case M_LOG: {
        if (face == 1) {
            float s = hash21(float2(t.x, floor(t.y / 3.0 + t.x * 0.37)));
            c = float3(0.40, 0.30, 0.19) * (0.7 + 0.42 * s);
        } else {
            float d = max(abs(t.x - 7.5), abs(t.y - 7.5));
            if (d > 6.0) c = float3(0.38, 0.28, 0.17) * (0.8 + 0.3 * n);
            else c = float3(0.68, 0.55, 0.35) * (fmod(floor(d), 2.0) < 0.5 ? 1.0 : 0.82) * (0.94 + 0.1 * n);
        }
        break;
    }
    case M_GLASS: {
        bool frame = t.x < 0.5 || t.x > 14.5 || t.y < 0.5 || t.y > 14.5 || abs(t.x - 7.5) < 0.6 || abs(t.y - 7.5) < 0.6;
        c = frame ? float3(0.55, 0.42, 0.27) * (0.9 + 0.1 * n) : float3(0.16, 0.19, 0.24);
        break;
    }
    case M_ROOF: {
        float row = floor(t.y / 4.0);
        float x = t.x + fmod(row, 2.0) * 4.0;
        float col = floor(x / 8.0);
        float3 base = vtRoofCol(var) * (0.86 + 0.24 * hash21(float2(row, col) + 4.0));
        c = base * (0.95 + 0.08 * n);
        if (fmod(t.y, 4.0) < 0.5) c = base * 0.55;
        else if (fmod(x, 8.0) < 0.5) c = base * 0.7;
        break;
    }
    case M_BRICK: {
        float row = floor(t.y / 8.0);
        float x = t.x + row * 4.0;
        bool mortar = fmod(t.y, 8.0) < 0.5 || fmod(x, 8.0) < 0.5;
        c = float3(0.47, 0.47, 0.46) * (0.88 + 0.14 * n) * (0.92 + 0.1 * hash21(float2(floor(x / 8.0), row)));
        if (mortar) c = float3(0.27, 0.27, 0.27);
        else if (var > 0.55 && n2 < 0.35 * (1.0 - t.y / 16.0)) c = float3(0.30, 0.42, 0.20) * (0.8 + 0.3 * n);
        break;
    }
    case M_LEAVES: {
        float3 base = vtLeafCol(var);
        c = base * (0.55 + 0.6 * n);
        if (n2 < 0.13) c = base * 0.22;
        break;
    }
    case M_LANTERN: {
        bool frame = t.x < 1.5 || t.x > 13.5 || t.y < 1.5 || t.y > 13.5;
        c = frame ? float3(0.18, 0.17, 0.17) : float3(1.0, 0.82, 0.45);
        break;
    }
    default: c = float3(1.0, 0.0, 1.0);
    }
    return vtLin(c);
}

// The texture box-filtered over the pixel footprint `fw` (world units, which
// for a full block is face uv units).
static inline float3 vtTexF(int m, int face, float2 uv, float var, float fw) {
    float tx = fw * 16.0;                      // footprint in texels
    if (tx < 0.35) return vtTex(m, face, uv, var);
    float o = 0.25 * fw;
    float3 c = 0.25 * (vtTex(m, face, uv + float2(-o, -0.4 * o), var) + vtTex(m, face, uv + float2(o, 0.4 * o), var)
                     + vtTex(m, face, uv + float2(0.4 * o, -o), var) + vtTex(m, face, uv + float2(-0.4 * o, o), var));
    return mix(c, vtLin(vtMean(m, face, var)), smoothstep(0.8, 2.2, tx));
}

// Mining cracks: jagged radial lines from the centre, reaching further with
// each of ten stages.
static inline float vtCrackMask(float2 uv, float crack) {
    float2 t = floor(clamp(uv, 0.0, 0.9999) * 16.0) - 7.5;
    float stage = floor(crack * 9.0) + 1.0;
    float r = length(t);
    float a = atan2(t.y, t.x) * (5.0 / TWO_PI) + 0.35 * (hash21(t + 40.0) - 0.5) + 0.15 * sin(r * 1.3);
    float line = abs(fract(a) - 0.5) * r * (TWO_PI / 5.0);
    float on = (line < 0.75 && r < stage * 1.25) ? 1.0 : 0.0;
    on = max(on, (hash21(t + 77.0) < 0.06 * stage && r < stage * 1.1) ? 1.0 : 0.0);
    return on;
}

// ---------------------------------------------------------------------------
// Sky and sea.

struct VtLight {
    float3 L;          // key light direction (sun, or moon at night)
    float3 key;        // its colour × intensity
    float3 skyTop, horizon, away, amb;   // horizon: towards the sun; away: opposite
    float  night;      // 0 day .. 1 night
    float3 sunDir;
    float  sunUp;      // sun above horizon 0..1
};

static inline VtLight vtLighting(float sunParam) {
    VtLight l;
    float e = mix(-0.28, 1.25, sunParam);
    float az = 0.65;
    l.sunDir = normalize(float3(cos(e) * cos(az), sin(e), cos(e) * sin(az)));
    float3 moonDir = normalize(float3(-cos(az) * 0.6, 0.75, -sin(az) * 0.6));
    float dusk = smoothstep(-0.22, 0.06, e), day = smoothstep(0.12, 0.75, e);
    l.night = 1.0 - dusk;
    l.sunUp = smoothstep(-0.04, 0.06, e);
    l.skyTop  = mix(mix(float3(0.004, 0.008, 0.025), float3(0.018, 0.035, 0.11), dusk), float3(0.10, 0.25, 0.58), day);
    l.horizon = mix(mix(float3(0.015, 0.025, 0.06), float3(0.66, 0.26, 0.10), dusk), float3(0.55, 0.66, 0.80), day);
    l.away    = mix(mix(float3(0.010, 0.018, 0.045), float3(0.11, 0.075, 0.14), dusk), float3(0.40, 0.55, 0.75), day);
    float3 sunCol = mix(float3(1.0, 0.52, 0.26), float3(1.0, 0.94, 0.85), smoothstep(0.1, 0.7, e)) * 2.6;
    float mw = smoothstep(0.0, -0.12, e);
    l.L = normalize(mix(l.sunDir, moonDir, mw));
    l.key = mix(sunCol * l.sunUp, float3(0.30, 0.40, 0.65) * 0.55, mw);
    l.amb = mix(l.skyTop * 1.6 + (l.horizon + l.away) * 0.2, float3(0.03, 0.045, 0.09), l.night * 0.6);
    return l;
}

// A square sun, a square moon, stars.
static inline float3 vtHorizon(float3 rd, VtLight l) {
    float2 h = normalize(rd.xz + 1e-5), s = normalize(l.sunDir.xz);
    float sw = saturate(dot(h, s) * 0.5 + 0.5);
    return mix(l.away, l.horizon, sw * sw * sw);
}

// Flat square clouds high overhead, drifting; lit from below at sunset.
static inline float4 vtClouds(float3 rd, float pxAngle, VtLight l, float now) {
    if (rd.y < 0.02) return float4(0.0);
    const float H = 30.0, CELL = 9.0;
    float d = H / rd.y;
    float2 p = (rd.xz * d + float2(now * 0.35, now * 0.12)) / CELL;
    float2 ci = floor(p);
    float occ = step(0.6, valueNoise(ci * 0.43 + 5.0));
    // Far away the squares melt into a soft average instead of shimmering.
    float aa = d * pxAngle / rd.y / CELL;
    float2 q = p - 0.5, qi = floor(q), qf = q - qi;
    float o00 = step(0.6, valueNoise(qi * 0.43 + 5.0)), o10 = step(0.6, valueNoise((qi + float2(1, 0)) * 0.43 + 5.0));
    float o01 = step(0.6, valueNoise((qi + float2(0, 1)) * 0.43 + 5.0)), o11 = step(0.6, valueNoise((qi + 1.0) * 0.43 + 5.0));
    float soft = mix(mix(o00, o10, qf.x), mix(o01, o11, qf.x), qf.y);
    occ = mix(occ, soft, saturate(aa * 3.0 - 0.3));
    float fade = exp(-d * 0.006);
    float3 hz = vtHorizon(rd, l);
    float3 c = hz * 1.6 + l.skyTop * 0.4 + float3(0.02, 0.015, 0.03);
    return float4(c, occ * fade * 0.9);
}

static inline float3 vtSky(float3 rd, VtLight l, bool disc, float pxAngle, float now) {
    float y = max(rd.y, 0.0);
    float3 col = mix(vtHorizon(rd, l), l.skyTop, 1.0 - exp(-y * 6.0));
    float sd = dot(rd, l.sunDir);
    if (disc && sd > 0.0) {
        float3 su = normalize(cross(l.sunDir, float3(0.0, 1.0, 0.0)));
        float3 sv = cross(su, l.sunDir);
        float2 q = float2(dot(rd, su), dot(rd, sv)) / sd;
        float box = max(abs(q.x), abs(q.y));
        float3 sc = mix(float3(1.0, 0.55, 0.28), float3(1.0, 0.95, 0.85), saturate(l.sunDir.y * 2.0));
        col += sc * (0.55 * exp(-length(q) * 5.0) + 0.25 * exp(-length(q) * 1.4)) * (1.0 - l.night);
        if (box < 0.05) col = mix(col, sc * 3.0, 1.0 - l.night);
    }
    if (disc && y > 0.0 && l.night > 0.01) {
        float3 g = floor(rd * 300.0);
        float h = hash21(g.xy + g.z * 37.1);
        col += float3(0.8, 0.85, 1.0) * step(0.9965, h) * l.night * saturate(y * 4.0) * (0.4 + 0.6 * hash21(g.zx));
        float3 moonDir = normalize(float3(-cos(0.65) * 0.6, 0.75, -sin(0.65) * 0.6));
        float md = dot(rd, moonDir);
        if (md > 0.0) {
            float3 su = normalize(cross(moonDir, float3(0.0, 1.0, 0.0)));
            float3 sv = cross(su, moonDir);
            float2 q = float2(dot(rd, su), dot(rd, sv)) / md;
            float box = max(abs(q.x), abs(q.y));
            col += float3(0.5, 0.6, 0.8) * 0.12 * exp(-length(q) * 6.0) * l.night;
            if (box < 0.035) col = mix(col, float3(0.85, 0.88, 0.95), l.night);
        }
    }
    float4 cl = vtClouds(rd, pxAngle, l, now);
    col = mix(col, cl.rgb, cl.a);
    return col;
}

// ---------------------------------------------------------------------------
// Shading.

static inline float3 vtAO(VtHit h, float2 uv, VtWorld W) {
    int3 n = int3(h.n);
    int3 t1 = abs(n.y) > 0 ? int3(1, 0, 0) : (abs(n.x) > 0 ? int3(0, 0, 1) : int3(1, 0, 0));
    int3 t2 = abs(n.y) > 0 ? int3(0, 0, 1) : int3(0, 1, 0);
    int3 b = h.c + n;
    float s[8];
    s[0] = vtSolid(b - t1, W) ? 1.0 : 0.0;
    s[1] = vtSolid(b + t1, W) ? 1.0 : 0.0;
    s[2] = vtSolid(b - t2, W) ? 1.0 : 0.0;
    s[3] = vtSolid(b + t2, W) ? 1.0 : 0.0;
    s[4] = vtSolid(b - t1 - t2, W) ? 1.0 : 0.0;
    s[5] = vtSolid(b + t1 - t2, W) ? 1.0 : 0.0;
    s[6] = vtSolid(b - t1 + t2, W) ? 1.0 : 0.0;
    s[7] = vtSolid(b + t1 + t2, W) ? 1.0 : 0.0;
    // Vertex occlusion, classic voxel style.
    float a00 = (s[0] * s[2] > 0.5) ? 3.0 : s[0] + s[2] + s[4];
    float a10 = (s[1] * s[2] > 0.5) ? 3.0 : s[1] + s[2] + s[5];
    float a01 = (s[0] * s[3] > 0.5) ? 3.0 : s[0] + s[3] + s[6];
    float a11 = (s[1] * s[3] > 0.5) ? 3.0 : s[1] + s[3] + s[7];
    float occ = mix(mix(a00, a10, uv.x), mix(a01, a11, uv.x), uv.y);
    return float3(1.0 - 0.17 * occ);
}

static inline float3 vtShade(VtHit h, float3 ro, float3 rd, float pxAngle, VtLight l, VtWorld W) {
    float3 P = ro + rd * h.t;
    float3 lp = (P - h.lo) / h.sz;
    int face = h.n.y > 0.5 ? 0 : (h.n.y < -0.5 ? 2 : 1);
    float2 uv = face != 1 ? lp.xz : (abs(h.n.x) > 0.5 ? float2(lp.z, lp.y) : float2(lp.x, lp.y));
    if (h.n.x < -0.5 || h.n.z > 0.5) uv.x = 1.0 - uv.x;
    float cosi = max(abs(dot(rd, h.n)), 0.12);
    float fw = h.t * pxAngle / cosi / h.sz;
    int m = h.v.m;

    float3 alb = vtTexF(m, face, uv, h.v.var, fw);

    // Mining cracks and the outline on whatever is being worked on.
    float fresh = 1.0 - saturate(h.v.age / (VT_POP * 2.0));
    if (h.v.crack > 0.0) alb *= 1.0 - 0.8 * vtCrackMask(uv, h.v.crack);
    float work = max(fresh, h.v.crack > 0.0 ? 1.0 : 0.0);
    if (work > 0.0) {
        float e = min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y));
        float aa = max(fw, 0.004);
        float edge = 1.0 - smoothstep(0.022, 0.022 + aa, e);
        alb = mix(alb, float3(0.01), edge * work * 0.9);
    }

    float3 n = h.n;
    float ndl = max(dot(n, l.L), 0.0);
    float sh = ndl > 0.0 ? vtShadow(P + n * 0.002, l.L, W) : 0.0;
    float3 ao = (m == M_LEAVES) ? float3(1.0) : vtAO(h, uv, W);
    float faceAmb = face == 0 ? 1.0 : (face == 1 ? 0.72 : 0.5);
    float3 col = alb * (l.key * ndl * sh * 0.9 + l.amb * faceAmb * ao * 1.1);

    // Lantern pools of light at the crossroads, strongest at night.
    float glow = 0.35 + 0.65 * l.night;
    for (int i = 0; i < 4; ++i) {
        float3 lpp = float3((i & 1) != 0 ? 5.5 : -4.5, 2.5, (i & 2) != 0 ? 5.5 : -4.5);
        float3 dv = lpp - P;
        float d2 = dot(dv, dv);
        col += alb * float3(1.0, 0.62, 0.28) * 1.6 * glow * max(dot(n, dv) * rsqrt(d2 + 1e-4), 0.0) / (1.0 + d2 * 0.55);
    }

    // Emission: lit windows, lanterns, and the flash of a new block.
    if (m == M_GLASS) {
        float2 t = floor(clamp(uv, 0.0, 0.9999) * 16.0);
        bool frame = t.x < 0.5 || t.x > 14.5 || t.y < 0.5 || t.y > 14.5 || abs(t.x - 7.5) < 0.6 || abs(t.y - 7.5) < 0.6;
        float pane = frame ? 0.0 : 1.0;
        float flick = 0.9 + 0.1 * hash21(float2(h.c.xz) + floor(W.now * 0.7));
        col += pane * float3(1.0, 0.62, 0.25) * 1.3 * h.v.lit * (0.25 + 0.75 * l.night + 0.25) * flick;
    } else if (m == M_LANTERN) {
        col += alb * 2.2;
    }
    col += float3(1.0, 0.95, 0.85) * fresh * fresh * 0.3;
    return col;
}

// The sea: refraction down to whatever the trace hit underwater, sky
// reflection with blocky 16-texel ripples, and foam where the water is thin.
static inline float3 vtSea(float3 ro, float3 rd, float tw, VtHit h, float3 under, float pxAngle,
                           VtLight l, VtWorld W) {
    float3 P = ro + rd * tw;
    float fw = tw * pxAngle / max(-rd.y, 0.05);
    float2 tx = floor(P.xz * 16.0);
    float tt = W.now * 0.6;
    float rip = valueNoise(tx * 0.21 + float2(tt * 1.3, tt * 0.7)) - valueNoise(tx * 0.13 - float2(tt * 0.6, -tt));
    float rip2 = valueNoise(tx.yx * 0.17 + float2(-tt, tt * 0.9));
    float calm = 1.0 - smoothstep(0.3, 1.5, fw * 16.0);
    float3 n = normalize(float3(rip * 0.22 * calm, 1.0, (rip2 - 0.5) * 0.22 * calm));

    float path = h.hit ? (h.t - tw) : 60.0;
    float3 absorb = exp(-path * float3(1.4, 0.55, 0.42));
    float3 body = mix(float3(0.004, 0.02, 0.03), float3(0.01, 0.06, 0.08), smoothstep(0.3, 0.9, l.sunDir.y + 0.3)) * (0.3 + 0.7 * (1.0 - l.night));
    float3 refr = under * absorb + body * (1.0 - absorb);

    float3 R = reflect(rd, n);
    R.y = abs(R.y);
    float cosv = saturate(-dot(rd, n));
    float fres = 0.02 + 0.98 * pow(1.0 - cosv, 5.0);
    float3 refl = vtSky(R, l, false, pxAngle * 3.0, W.now) * 0.7;
    float3 col = mix(refr, refl, fres);
    // Blocky sun glitter.
    float g = pow(saturate(dot(R, l.sunDir)), 1500.0) * l.sunUp;
    float sheen = pow(saturate(dot(reflect(rd, float3(0.0, 1.0, 0.0)), l.sunDir)), 12.0) * l.sunUp;
    col += float3(1.0, 0.62, 0.35) * (g * 5.0 * calm + sheen * 0.12);
    // Foam where water meets a block.
    float vdepth = path * (-rd.y);
    float foam = h.hit ? (1.0 - smoothstep(0.02, 0.22, vdepth)) : 0.0;
    float fn = hash21(tx + floor(tt * 2.0));
    foam *= step(0.35, fn);
    col = mix(col, (l.amb * 1.2 + l.key * 0.5 * max(l.L.y, 0.0)) * float3(0.9, 0.95, 1.0), foam * 0.65);
    return col;
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    VtWorld W;
    W.tt = u.time * u.speed + u.seed * 977.0;
    W.now = u.time;
    W.seedBits = vtPcg(uint(u.seed * 4294967.0) + 17u);
    W.noiseOff = float2(float(W.seedBits & 255u), float((W.seedBits >> 8) & 255u)) * 0.37;
    VtLight l = vtLighting(u.sun);

    // Camera: a slow orbit round the island from 26° up, looking down a
    // little less than that, so the island sits low and the horizon high.
    float az = u.time * 0.018 * u.orbit + u.seed * TWO_PI;
    float el = 0.41 + 0.035 * sin(u.time * 0.011 + u.seed * 9.0);
    float look = el - 0.17;
    float dist = 60.0;
    float3 pivot = float3(0.0, 1.0, 0.0);
    float3 hz = float3(cos(az), 0.0, sin(az));
    float3 ro = pivot + dist * (hz * cos(el) + float3(0.0, sin(el), 0.0));
    float3 fwd = normalize(-hz * cos(look) - float3(0.0, sin(look), 0.0));
    float3 upHint = float3(0.0, 1.0, 0.0);
    float3 right = normalize(cross(upHint, fwd));
    lerpOrbit(u.yaw, u.pitch, u.magnify, pivot, upHint, ro, right, fwd);
    float3 up = cross(fwd, right);

    float minRes = min(u.resolution.x, u.resolution.y);
    float pxAngle = 2.0 / (minRes * VT_FOCAL);
    float2 uv = lerpUV(pos, u.resolution);
    float3 rd = normalize(uv.x * right + uv.y * up + VT_FOCAL * fwd);

    VtHit h = vtTrace(ro, rd, W);
    float tw = rd.y < 0.0 ? (VT_SEA - ro.y) / rd.y : 1e9;
    float3 col;
    if (h.hit && h.t < tw) {
        col = vtShade(h, ro, rd, pxAngle, l, W);
        col = mix(col, vtHorizon(rd, l) * 0.7, 1.0 - exp(-h.t * 0.0015));
    } else if (tw < 1e8) {
        float3 under = h.hit ? vtShade(h, ro, rd, pxAngle, l, W) : float3(0.0);
        col = vtSea(ro, rd, tw, h, under, pxAngle, l, W);
        col = mix(col, vtHorizon(rd, l) * 0.8, 1.0 - exp(-tw * 0.0018));
    } else {
        col = vtSky(rd, l, true, pxAngle, u.time);
    }

    col = col / (1.0 + col * 0.3);
    col = pow(max(col, 0.0), 1.0 / 2.2);
    col = lerpDither(col, pos);
    return half4(half3(col), 1.0h);
}
