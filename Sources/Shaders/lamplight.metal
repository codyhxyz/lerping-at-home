// Lamplight — original work for Lerping@Home, not a port.
//
// A Minecraft night. A lamplighter, the game's wandering trader, walks a
// winding dirt path across a grassy block landscape carrying a lantern. Each lantern post he passes (an oak
// fence post with a lantern set on it) kindles, and its light spreads the way
// the game spreads light: outwards one block and one level at a time, fifteen
// levels down to nothing. So every pool of light is a stepped diamond, the
// dark between pools is solid, and the road behind him is a string of warm
// terraced pools fading into fog while the road ahead is black. Out in the
// hills wild lights come and go on their own slow clocks: glowstone, soul
// torches, torches, and budding amethyst growing its buds through the stages
// to a cluster. The lakes are the game's tinted water and mirror the moon.
//
// Drawn as the game draws it with Smooth Lighting off: each face takes the
// block-light and sky-light levels of the air cell in front of it through the
// game's lightmap (`mcLightmap`) and the fixed face shading, and nothing else.
// A cell's block light is the brightest source's level minus its block
// (Manhattan) distance. Light does not route round hills (no flood fill),
// which a fragment shader cannot afford; at this camera height it does not
// read. Every surface is the game's own texture; the sky is the game's night:
// black overhead, its fog at the horizon, its square stars, the moon's real
// phase textures and the flat cloud layer from clouds.png.
//
// Cost: the march walks at most LL_COLS columns with a few tests each and
// samples no texture, except inside the one column that holds a small model
// (the shared kit's lantern, torch and cross models test their cut-out
// texels), and one bounds test for the trader. A pixel then reads one to
// three textures at its hit. Measured 10.1 ms at 3456x2234 against maze's
// 10.0 in the same minute.
//
// lerp-category: Minecraft
// lerp-requires: minecraft mobs
//
// lerp-param: speed        float 0.25 3 = 1    "Walk speed"
// lerp-param: spacing      int 9 16     = 9    "Lantern spacing"
// lerp-param: wild         float 0 1    = 0.75 "Wild lights"
// lerp-param: moon         float 0 1    = 0.6  "Moonlight"
// lerp-param: soul         bool         = false "Soul lanterns"
// lerp-param: yaw          float -180 180 = 0  "Turn"
// lerp-param: pitch        float -25 35   = 0  "Tilt"
// lerp-param: magnify      float -1 0.8   = 0  "Zoom"
//
// lerp-preset: "Soul Road" soul=true, wild=0.45
// lerp-preset: Moonless    moon=0.2, wild=1

// --- World, in blocks.
constant int   LL_COLS  = 100;      // columns a ray may cross
constant int   LL_HMAX  = 10;       // nothing on the ground reaches this y
constant int   LL_WATER = 5;        // air cells below this y hold water
constant int   LL_WILDR = 16;       // wild light lattice
constant float LL_WALK  = 0.6;      // walker speed, blocks per (speed-scaled) second
constant float LL_RING  = 0.7;      // seconds per level as a road lantern kindles
constant float LL_FOCAL = 2.4;
constant float LL_FOG0  = 33.0;     // the game's render-distance fog, linear
constant float LL_FOG1  = 48.0;
constant float LL_CLOUD_Y = 136.0;  // the cloud layer, ~130 blocks over the ground as in the game
constant float LL_WALKER_L = 11.0;  // the carried lantern's level (lantern 15; kept lower so the road ahead stays dark)

// Glow colours of the sources' mirror images on the lakes. Light itself is
// uncoloured, as in the game: every pool goes through the same lightmap.
constant float3 LL_C_LANTERN = float3(1.00, 0.72, 0.38);
constant float3 LL_C_SOULL   = float3(0.30, 0.80, 1.00);
constant float3 LL_C_GLOW    = float3(1.00, 0.80, 0.45);
constant float3 LL_C_AME     = float3(0.70, 0.45, 1.00);
constant float3 LL_C_TORCH   = float3(1.00, 0.62, 0.30);

enum LLMat { LM_TERRAIN = 0, LM_GLOW, LM_MODEL };

// Light-source kinds: 1 road lantern, 3 glowstone, 4 soul torch, 5 budding amethyst, 6 torch.

struct LLW {
    int   bx;        // world x of the local origin: the scene is drawn near x = 0
    int   sd;        // seed salt
    float ph1, ph2;  // road phases
    float T;         // the walker's clock
    int   spacing;
    float wild;
    float lmax;      // a road lantern's full level: lantern 15, soul lantern 10
    float3 lcol;     // its mirror glow
};

// ---------------------------------------------------------------------------
// Hashes and noise on integer lattice points. Float arithmetic (32-bit
// integer multiplies are slow on these GPUs), on coordinates wrapped to
// 4096, so precision holds however far the walker has gone.

static inline float llH(int3 p) {
    float3 q = float3(p & 4095) + 0.5;
    q = fract(q * float3(0.1031, 0.1030, 0.0973));
    q += dot(q, q.yzx + 33.33);
    return fract((q.x + q.y) * q.z);
}

// The same noise for a ray walking column to column: a lattice cell's four
// corners are hashed once and reused until the walk leaves it.
struct LLNoiseCache { int2 key; float4 v; };

static inline LLNoiseCache llCache() {
    LLNoiseCache c;
    c.key = int2(-1000000);
    c.v = float4(0.0);
    return c;
}

static inline float llNoiseC(float2 p, int salt, thread LLNoiseCache& nc) {
    float2 i = floor(p);
    float2 f = p - i;
    int2 c = int2(i);
    if (c.x != nc.key.x || c.y != nc.key.y) {
        nc.key = c;
        nc.v = float4(llH(int3(c, salt)), llH(int3(c.x + 1, c.y, salt)),
                      llH(int3(c.x, c.y + 1, salt)), llH(int3(c.x + 1, c.y + 1, salt)));
    }
    float2 s = f * f * (3.0 - 2.0 * f);
    return mix(mix(nc.v.x, nc.v.y, s.x), mix(nc.v.z, nc.v.w, s.x), s.y);
}

static inline float3 llRotX(float3 v, float a) {
    float c = cos(a), s = sin(a);
    return float3(v.x, v.y * c - v.z * s, v.y * s + v.z * c);
}

// ---------------------------------------------------------------------------
// Terrain: rolling hills, lakes, and a road that keeps its own level.

static inline float llRoadZ(float x, LLW w) {
    return 7.0 * sin(x * 0.043 + w.ph1) + 3.5 * sin(x * 0.11 + w.ph2);
}
static inline float llRoadDZ(float x, LLW w) {
    return 7.0 * 0.043 * cos(x * 0.043 + w.ph1) + 3.5 * 0.11 * cos(x * 0.11 + w.ph2);
}

static inline int llRoadHC(int x, LLW w, thread LLNoiseCache& nc) {
    float xc = float(x) + 0.5;
    float2 p = float2(xc, llRoadZ(xc, w));
    // Never under water, and cut through the tops of the highest hills.
    return clamp(int(floor(3.0 + 7.0 * llNoiseC(p / 24.0, w.sd, nc))), LL_WATER, LL_WATER + 3);
}

// Ground height of world column c (cells below it are solid), through the
// caller's noise caches. `roadD` is the column's distance from the road.
static inline int llHeightC(int2 c, LLW w, thread LLNoiseCache& ncLow,
                            thread LLNoiseCache& ncRoad, thread float& roadD) {
    float2 p = float2(c) + 0.5;
    roadD = abs(p.y - llRoadZ(p.x, w));
    float base = 3.0 + 7.0 * llNoiseC(p / 24.0, w.sd, ncLow);
    int b = max(int(floor(base)), 1);
    if (roadD >= 5.5) return b;
    int rh = llRoadHC(c.x, w, ncRoad);
    if (roadD < 2.5) return rh;
    return int(round(mix(float(rh), float(b), (roadD - 2.5) / 3.0)));
}

// ---------------------------------------------------------------------------
// Light sources.

static inline int2 llLanternCol(int k, LLW w) {
    int xk = k * w.spacing + 3;
    float side = (k & 1) != 0 ? 1.0 : -1.0;
    return int2(xk, int(floor(llRoadZ(float(xk) + 0.5, w) + side * 2.0)));
}

// A road lantern starts to kindle as the walker draws level with it.
static inline float llLanternLevel(int xk, LLW w) {
    return clamp((w.T - (float(xk) + 0.5) / LL_WALK) / LL_RING, 0.0, w.lmax);
}

// The wild light of region `reg`, if it has one: column, kind and current
// level (it kindles a level at a time, burns, then fades a level at a time),
// at the game's own levels: glowstone 15, torch 14, soul torch 10. Budding
// amethyst grows its bud through the game's stages instead, each with the
// stage's own light: small 1, medium 2, large 4, cluster 5.
// The caller still checks the ground (dry, off the road).
static inline bool llWild(int2 reg, LLW w, thread int2& p, thread int& kind,
                          thread float& lv, thread float& mx) {
    if (llH(int3(reg, w.sd + 31)) >= w.wild) return false;
    float k = llH(int3(reg, w.sd + 34));
    kind = k < 0.3 ? 3 : (k < 0.55 ? 4 : (k < 0.75 ? 5 : 6));
    mx = kind == 3 ? 15.0 : (kind == 4 ? 10.0 : (kind == 5 ? 5.0 : 14.0));
    float P = 150.0 + 100.0 * fract(k * 7.7 + 0.2);
    float cyc = glmod(w.T + P * fract(k * 31.3 + 0.5), P);
    float on = 0.62 * P;
    if (kind == 5) {
        float g = cyc < on ? cyc / 6.0 : max(4.0 - (cyc - on) / 6.0, 0.0);   // 0 none .. 4 cluster
        lv = g >= 4.0 ? 5.0 : (g >= 3.0 ? 4.0 : (g >= 2.0 ? 2.0 : (g >= 1.0 ? 1.0 : 0.0)));
    } else {
        lv = cyc < on ? min(cyc / 0.9, mx) : max(mx - (cyc - on) / 1.5, 0.0);
    }
    // Kept to the middle of the region, which with a reach of 14 means a
    // point can only be lit from its own region and one neighbour per axis.
    int2 o = int2(int(fract(k * 57.1 + 0.3) * 5.999), int(fract(k * 91.7 + 0.9) * 5.999));
    p = reg * LL_WILDR + 5 + o;
    return true;
}

static inline float3 llKindCol(int kind) {
    return kind == 3 ? LL_C_GLOW : (kind == 4 ? LL_C_SOULL : (kind == 5 ? LL_C_AME : LL_C_TORCH));
}

// A light source as the gather sees it, packed so a quad of pixels can pass
// sources between its lanes: (light cell, level), (mirror-glow colour,
// strength 0..1), (glow size, glow height above the light cell).
struct LLPk { float4 p; float4 c; float2 g; };

static inline LLPk llNone() {
    LLPk k;
    k.p = float4(0.0, -1000.0, 0.0, 0.0);
    k.c = float4(0.0);
    k.g = float2(1.0, 0.0);
    return k;
}

// Slot i of the six sources that light point a besides the walker's
// lantern: the two road lanterns either side of a (a third, at least 9
// blocks further, is never the brightest, and light takes the brightest),
// then four wild regions: a's own and its neighbours on the side of each
// axis a is nearer. Wild lights stand in the middle six blocks of their
// sixteen, so that choice misses at most the last level of a glowstone.
static inline LLPk llSlot(int i, float3 a, LLW w,
                          thread LLNoiseCache& ncLow, thread LLNoiseCache& ncRoad) {
    LLPk k = llNone();
    float ax = a.x + float(w.bx);
    if (i < 2) {
        int kc = int(floor((ax - 3.0) / float(w.spacing))) + i;
        int xk = kc * w.spacing + 3;
        if (abs(float(xk) + 0.5 - ax) > 16.0) return k;
        float lv = llLanternLevel(xk, w);
        if (lv <= 0.0) return k;
        int2 c = llLanternCol(kc, w);
        float2 lc = float2(float(c.x - w.bx) + 0.5, float(c.y) + 0.5);
        if (abs(lc.x - a.x) + abs(lc.y - a.z) > 17.0) return k;
        float base = float(llRoadHC(c.x, w, ncRoad));
        // The lantern sits on the fence post: its cell is the one above the post's.
        k.p = float4(lc.x, base + 1.5, lc.y, lv);
        k.c = float4(w.lcol, lv / w.lmax);
        k.g = float2(1.0, -0.23);
        return k;
    }
    int j = i - 2;
    float2 q = float2(ax, a.z) / float(LL_WILDR);
    int2 reg = int2(floor(q));
    float2 lq = (q - float2(reg)) * float(LL_WILDR);
    int2 nb = int2(lq.x < 8.0 ? -1 : 1, lq.y < 8.0 ? -1 : 1);
    reg += int2((j & 1) != 0 ? nb.x : 0, (j & 2) != 0 ? nb.y : 0);
    int2 p; int kind; float lv, mx;
    if (!llWild(reg, w, p, kind, lv, mx) || lv <= 0.0) return k;
    float2 lc = float2(float(p.x - w.bx) + 0.5, float(p.y) + 0.5);
    if (abs(lc.x - a.x) + abs(lc.y - a.z) > 16.0) return k;
    float rd;
    int h = llHeightC(p, w, ncLow, ncRoad, rd);
    if (h < LL_WATER || rd <= 3.5) return k;
    bool block = kind == 3;
    k.p = float4(lc.x, float(h) + 0.5, lc.y, lv);
    k.c = float4(llKindCol(kind), lv / mx);
    k.g = float2(block ? 1.6 : 0.8, block ? 0.0 : 0.12);
    return k;
}

// The glow of a source's mirror image, seen along the ray [0, tEnd].
static inline float3 llGlow(float3 ro, float3 rd, float tEnd, LLPk k) {
    float3 v = k.p.xyz + float3(0.0, k.g.y, 0.0) - ro;
    float tc = clamp(dot(v, rd), 0.0, tEnd);
    float3 q = v - rd * tc;
    float d2 = dot(q, q);
    if (d2 > 16.0) return float3(0.0);
    float r = k.g.x;
    float fade = 1.0 - d2 / 16.0;
    float g = (0.018 * r / (d2 + 0.03 * r) + 0.07 * exp(-d2 * 0.3 / r)) * fade * fade;
    return k.c.rgb * (g * k.c.w);
}

// What one pixel gathers: the block-light level of its air cell a (the
// brightest source minus its block distance), and on water the glow of each
// source's mirror image below the surface (nudged by the ripple).
struct LLLit { float lv; float3 rhalo; };

static inline void llApply(thread LLLit& L, LLPk k, float3 a, float3 ro, float3 rd, float tEnd,
                           bool refl, float2 ripple) {
    float3 dd = abs(a - k.p.xyz);
    float l = k.p.w - (dd.x + dd.y + dd.z);
    if (l > 0.0) {
        // Whole levels; a moving source crosses each step in a short blend.
        L.lv = max(L.lv, floor(l) + smoothstep(0.8, 1.0, fract(l)));
    }
    if (refl && k.c.w > 0.0) {
        const float wl = float(LL_WATER) - 0.125;
        k.p.y = 2.0 * wl - k.p.y - 2.0 * k.g.y;
        k.p.xz += ripple;
        L.rhalo += llGlow(ro, rd, tEnd + 40.0, k);
    }
}

// ---------------------------------------------------------------------------
// The march.

struct LLHit {
    float  t;       // 1e9: nothing before the limit
    float  tw;      // the water surface on the way, 1e9: none
    float3 n;
    int3   cell;    // local cell; for a small model, its column at ground level
    int    mat;
    int    kind;    // the column's light-source kind, 0 none
    float  e;       // the column's source level
    int    h;       // column ground height
    float  roadD;
    float4 mcol;    // a small model's texel (the kit's McModelHit)
    float  mshade;  // and whether the game face-shades it
};

// A ray against one solid run [lo, hi) of a column it crosses over
// [tIn, tOut], entering at height yIn and leaving at yOut. Returns the hit
// t (1e9: none) and which face: 0 the side it came in by, 1 top, 2 bottom.
static inline float llSpan(float lo, float hi, float yIn, float yOut, float tIn,
                           float roy, float rdy, thread int& face) {
    if (yIn >= lo && yIn < hi) { face = 0; return tIn; }
    if (yIn >= hi && yOut < hi) { face = 1; return (hi - roy) / rdy; }
    if (yIn < lo && yOut >= lo) { face = 2; return (lo - roy) / rdy; }
    return 1e9;
}

static inline int llBudLayer(float lv) {
    return lv >= 5.0 ? MC_AMETHYST_CLUSTER : (lv >= 4.0 ? MC_LARGE_AMETHYST_BUD
         : (lv >= 2.0 ? MC_MEDIUM_AMETHYST_BUD : MC_SMALL_AMETHYST_BUD));
}

// The ground and what stands on it, walked column by column below the
// highest the ground can reach. In a column the ground is one solid run,
// so each step is the same few tests whatever the ray's slope.
static inline LLHit llMarch(float3 ro, float3 rd, float tLimit, LLW w,
                            thread LLNoiseCache& ncLow, thread LLNoiseCache& ncRoad,
                            texture2d_array<float> tiles, int lanLayer, float pxA) {
    LLHit H;
    H.t = 1e9; H.tw = 1e9; H.n = float3(0.0, 1.0, 0.0); H.cell = int3(0);
    H.mat = -1; H.kind = 0; H.e = 0.0; H.h = 0; H.roadD = 9.0; H.mcol = float4(0.0); H.mshade = 0.0;
    float t0 = 0.0;
    if (ro.y > float(LL_HMAX)) {
        if (rd.y > -1e-4) return H;
        t0 = (float(LL_HMAX) - ro.y) / rd.y;
    }
    float2 rs = select(rd.xz, float2(1e-6), abs(rd.xz) < 1e-6);
    float2 inv = 1.0 / rs;
    int2 cell = int2(floor(ro.xz + rd.xz * (t0 + 1e-4)));
    int2 stp = int2(sign(rs));
    float2 tDel = abs(inv);
    float2 tMax = (float2(cell) + select(float2(0.0), float2(1.0), rs > 0.0) - ro.xz) * inv;
    int axis = -1;
    float tIn = t0;
    const float wl = float(LL_WATER) - 0.125;

    int cx = -1000000; float rz = 0.0; int rh = 0; bool rhOK = false;
    int2 lan = int2(0); float lanE = -1.0;
    int2 wildReg = int2(-1000000); int2 wildP = int2(0); int wildKind = 0;
    float wildLv = 0.0, wildMx = 1.0; bool wildOK = false;

    for (int i = 0; i < LL_COLS; ++i) {
        if (tIn > tLimit) break;
        float tOut = min(tMax.x, tMax.y);
        float yIn = ro.y + rd.y * tIn, yOut = ro.y + rd.y * tOut;
        if (rd.y >= 0.0 && yIn >= float(LL_HMAX)) break;
        float yLo = min(yIn, yOut);
        int2 wc = int2(cell.x + w.bx, cell.y);
        // Everything about the road depends on x alone; a ray mostly steps in z.
        if (wc.x != cx) {
            cx = wc.x;
            rz = llRoadZ(float(wc.x) + 0.5, w);
            rhOK = false;
            lanE = -2.0;   // not looked up yet
        }
        float roadD = abs(float(wc.y) + 0.5 - rz);

        float2 pc = float2(wc) + 0.5;
        float low = 3.0 + 7.0 * llNoiseC(pc / 24.0, w.sd, ncLow);
        int hb = roadD >= 5.5 ? max(int(floor(low)), 1) : LL_HMAX;
        int sKind = 0; float sE = 0.0;
        if (roadD < 2.6) {
            if (lanE < -1.5) {
                int k = int(floor(float(wc.x - 3) / float(w.spacing) + 0.5));
                lan = llLanternCol(k, w);
                lanE = lan.x == wc.x ? llLanternLevel(lan.x, w) : -1.0;
            }
            if (lanE >= 0.0 && lan.y == wc.y) { sKind = 1; sE = lanE; }
        } else if (roadD > 3.5) {
            int2 reg = int2(floor(float2(wc) / float(LL_WILDR)));
            if (reg.x != wildReg.x || reg.y != wildReg.y) {
                wildReg = reg;
                wildOK = llWild(reg, w, wildP, wildKind, wildLv, wildMx);
            }
            if (wildOK && wildP.x == wc.x && wildP.y == wc.y) { sKind = wildKind; sE = wildLv; }
        }
        int h;
        if (yLo < float(hb) || sKind != 0) {
            h = max(int(floor(low)), 1);
            if (roadD < 5.5) {
                if (!rhOK) { rh = llRoadHC(wc.x, w, ncRoad); rhOK = true; }
                h = roadD < 2.5 ? rh : int(round(mix(float(rh), float(h), (roadD - 2.5) / 3.0)));
            }
            if (sKind != 1 && h < LL_WATER) sKind = 0;
        } else {
            h = hb;   // an upper bound, which is all a miss needs
        }
        // The game's small models, from the shared kit, in the one column that holds one.
        if (sKind == 1 || ((sKind == 4 || sKind == 6) && sE > 0.0) || (sKind == 5 && sE >= 1.0)) {
            float3 o = float3(float(cell.x), float(h), float(cell.y));
            float tm = tIn - 1e-4;
            McModelHit mh;
            mh.t = tOut + 1e-3;
            bool got;
            if (sKind == 1) {
                // The game's lamp post: an oak fence post, no arms, a lantern on it.
                got = mcFence(tiles, MC_OAK_PLANKS, o, 0, ro, rd, tm, mh.t, pxA, mh);
                McModelHit lh;
                if (sE > 0.0 && mcLantern(tiles, lanLayer, o + float3(0.0, 1.0, 0.0), false,
                                          ro, rd, tm, mh.t, pxA, lh)) { mh = lh; got = true; }
            } else if (sKind == 5) {
                got = mcCross(tiles, llBudLayer(sE), o, float3(1.0), ro, rd, tm, mh.t, pxA, mh);
            } else {
                got = mcTorch(tiles, sKind == 4 ? MC_SOUL_TORCH : MC_TORCH, o, ro, rd, tm, mh.t, pxA, mh);
            }
            if (got) {
                H.t = mh.t; H.n = mh.n; H.cell = int3(cell.x, h, cell.y);
                H.mat = LM_MODEL; H.kind = sKind; H.e = sE; H.h = h; H.roadD = roadD;
                H.mcol = mh.color; H.mshade = mh.shade;
                return H;
            }
        }
        // The water surface, where the ray crosses it over a low column.
        if (H.tw > 1e8 && rd.y < 0.0 && yIn >= wl && yOut < wl && h < LL_WATER)
            H.tw = (wl - ro.y) / rd.y;

        bool block = sKind == 3 && sE > 0.0;
        // A dirt path is a sixteenth lower than a full block.
        float top = float(h + (block ? 1 : 0)) - (roadD < 1.5 ? 0.0625 : 0.0);
        int face;
        float tg = llSpan(-1e9, top, yIn, yOut, tIn, ro.y, rd.y, face);
        if (tg < 1e8) {
            int hitY = face == 1 ? h + (block ? 1 : 0) - 1 : int(floor(yIn));
            float3 nn = float3(0.0, 1.0, 0.0);
            if (face == 0) {
                nn = float3(0.0);
                if (axis == 0) nn.x = -float(stp.x); else nn.z = -float(stp.y);
            }
            H.t = tg; H.n = nn; H.cell = int3(cell.x, hitY, cell.y);
            H.mat = (block && hitY == h) ? LM_GLOW : LM_TERRAIN;
            H.kind = sKind; H.e = sE; H.h = h; H.roadD = roadD;
            return H;
        }
        if (tMax.x < tMax.y) { axis = 0; tIn = tMax.x; tMax.x += tDel.x; cell.x += stp.x; }
        else                 { axis = 2; tIn = tMax.y; tMax.y += tDel.y; cell.y += stp.y; }
    }
    return H;
}

// ---------------------------------------------------------------------------
// Surfaces.

// Width of a screen pixel on a face, as uv change per pixel in x and y:
// the ray differentials projected onto the face plane.
static inline void llFaceGrad(float3 rd, float t, float3 n, float3 dRx, float3 dRy,
                              float3 U, float3 V, thread float2& gx, thread float2& gy) {
    float dn = min(dot(n, rd), -0.05);
    float3 px = t * (dRx - rd * (dot(n, dRx) / dn));
    float3 py = t * (dRy - rd * (dot(n, dRy) / dn));
    gx = float2(dot(px, U), dot(px, V));
    gy = float2(dot(py, U), dot(py, V));
}

static inline float3 llShadeBlock(LLHit H, float3 ro, float3 rd, float3 dRx, float3 dRy, float pxA,
                                  LLW w, float3 lm, float time,
                                  texture2d_array<float> tiles, texture2d_array<float> maps) {
    float3 P = ro + rd * H.t;
    float3 n = H.n;
    if (H.mat == LM_TERRAIN || H.mat == LM_GLOW) {
        // Face uv as the game lays textures: tops north up, sides upright.
        float2 uv; float3 U, V;
        if (abs(n.y) > 0.5)      { uv = P.xz; U = float3(1, 0, 0); V = float3(0, 0, 1); }
        else if (abs(n.x) > 0.5) { uv = float2(n.x > 0.0 ? -P.z : P.z, -P.y);
                                   U = float3(0, 0, n.x > 0.0 ? -1.0 : 1.0); V = float3(0, -1, 0); }
        else                     { uv = float2(n.z > 0.0 ? P.x : -P.x, -P.y);
                                   U = float3(n.z > 0.0 ? 1.0 : -1.0, 0, 0); V = float3(0, -1, 0); }
        float2 gx, gy;
        llFaceGrad(rd, H.t, n, dRx, dRy, U, V, gx, gy);

        int depth = H.h - 1 - H.cell.y;
        bool top = n.y > 0.5;
        bool sandy = H.h <= LL_WATER && H.roadD >= 1.5;
        int layer = MC_STONE;
        bool turn = false, grass = false, side = false;
        if (H.mat == LM_GLOW) layer = MC_GLOWSTONE;
        else if (depth == 0 && H.kind == 5) layer = MC_BUDDING_AMETHYST;
        else if (sandy) { layer = depth < 3 ? MC_SAND : MC_SANDSTONE; turn = top; }
        else if (depth == 0) {
            if (H.roadD < 1.5) { layer = top ? MC_DIRT_PATH_TOP : (n.y < -0.5 ? MC_DIRT : MC_DIRT_PATH_SIDE); turn = top; }
            else if (top) { layer = MC_GRASS_BLOCK_TOP; grass = true; turn = true; }
            else if (n.y < -0.5) layer = MC_DIRT;
            else side = true;
        } else layer = depth < 4 ? MC_DIRT : MC_STONE;

        float3 tint = (grass || side) ? mcGrassTint(maps, 0.8, 0.4) : float3(1.0);   // plains
        float3 alb;
        if (side) {
            alb = mcGrassSideAniso(tiles, uv, gx, gy, tint);
        } else {
            if (turn) {
                // The game turns these tops a random quarter per block.
                int r = int(llH(int3(H.cell.x + w.bx, H.cell.z, 911)) * 3.999);
                float2 f = fract(uv);
                if (r == 1)      { uv = float2(f.y, 1.0 - f.x); gx = float2(gx.y, -gx.x); gy = float2(gy.y, -gy.x); }
                else if (r == 2) { uv = 1.0 - f; gx = -gx; gy = -gy; }
                else if (r == 3) { uv = float2(1.0 - f.y, f.x); gx = float2(-gx.y, gx.x); gy = float2(-gy.y, gy.x); }
            }
            alb = mcTileAniso(tiles, layer, uv, gx, gy).rgb * tint;
        }
        return alb * mcFaceShade(n) * lm;
    }
    // Small models: the kit's texel, lit like any face.
    return H.mcol.rgb * (H.mshade > 0.5 ? mcFaceShade(n) : 1.0) * lm;
}

// ---------------------------------------------------------------------------
// The lamplighter.
//
// The wandering trader from the shared mob kit: the villager model with his
// own skin, walking (legs swing as cos(stride)) with his arms crossed, as the
// game draws villagers. K.W is his feet on the road, K.f his heading. The kit
// has no held items, so the lantern he carries in his crossed arms is drawn
// here, and it is also his light source.

struct LLWalker { float3 W; float3 f; float3 s; float stride; };

// The carried lantern: the kit's standing lantern at 5/8 scale, hanging in
// front of where his hands are.
constant float LL_LSCALE = 0.625;

static inline float3 llCarriedBase(LLWalker k) {
    return k.W + float3(0.0, 0.73, 0.0) + k.f * 0.44;   // the lantern's bottom centre
}

static inline bool llCarriedHit(float3 ro, float3 rd, LLWalker k, int lanLayer, float pxA,
                                texture2d_array<float> tiles, thread McModelHit& mh) {
    // Into a frame where the lantern is full size; t is unchanged.
    float3 ro2 = (ro - llCarriedBase(k)) / LL_LSCALE + float3(0.5, 0.0, 0.5);
    return mcLantern(tiles, lanLayer, float3(0.0), false, ro2, rd / LL_LSCALE, 0.0, 1e9,
                     pxA / LL_LSCALE, mh);
}

// ---------------------------------------------------------------------------
// The game's night sky: black overhead, its fog colour at the horizon, its
// square stars turning with the sky, the moon's phase texture added on, and
// the flat cloud layer over everything.

struct LLSkyP { float e; float az; int moonLayer; float moonAmt; float px; float drift; int bx; };

static inline float3 llSky(float3 rd, float3 ro, LLSkyP s,
                           texture2d_array<float> skins, texture2d_array<float> maps) {
    float3 fog = mcFogAt(0.0);
    if (rd.y <= 0.0) return fog;
    float3 c = mix(fog, mcSkyAt(0.0), smoothstep(0.0, 0.3, rd.y));

    // Stars: ~1500 small squares, each at its own angle, on a cube round the sky.
    float3 sd = llRotX(rd, -s.e);
    float3 aa = abs(sd);
    float2 f; float m; int fid;
    if (aa.x >= aa.y && aa.x >= aa.z) { f = sd.yz; m = aa.x; fid = sd.x > 0.0 ? 0 : 1; }
    else if (aa.y >= aa.z)            { f = sd.xz; m = aa.y; fid = sd.y > 0.0 ? 2 : 3; }
    else                              { f = sd.xy; m = aa.z; fid = sd.z > 0.0 ? 4 : 5; }
    float2 g = (f / m * 0.5 + 0.5) * 40.0;
    float2 gi = floor(g);
    int2 ci = int2(gi);
    float hh = llH(int3(ci, 200 + fid));
    if (hh > 0.84) {
        float2 ctr = 0.3 + 0.4 * float2(llH(int3(ci, 210 + fid)), llH(int3(ci, 220 + fid)));
        float2 d = rotate(g - gi - ctr, hh * 40.0);
        float half_ = 0.03 + 0.02 * fract(hh * 13.7);       // 0.15..0.25 at a hundred blocks
        float pxc = s.px * 20.0 * m;                        // a screen pixel, in cells
        float st = saturate((half_ - max(abs(d.x), abs(d.y))) / pxc + 0.5);
        c += 0.5 * st * smoothstep(0.0, 0.2, rd.y);
    }

    // The moon: a quad 40 wide at a hundred blocks, on the sun's arc.
    // The arc runs east to west over the zenith; the road's heading against
    // east is the seed's (az).
    float3 E = float3(cos(s.az), 0.0, -sin(s.az));
    float3 Hz = float3(sin(s.az), 0.0, cos(s.az));
    float3 M = Hz * cos(s.e) + float3(0.0, sin(s.e), 0.0);
    float3 Tn = float3(0.0, cos(s.e), 0.0) - Hz * sin(s.e);
    float dm = dot(rd, M);
    if (dm > 0.9) {
        float2 q = float2(dot(rd, E), dot(rd, Tn)) / dm;
        if (max(abs(q.x), abs(q.y)) < 0.2) {
            float4 mt = mcSkin(skins, s.moonLayer, float2(q.x / 0.4 + 0.5, 0.5 - q.y / 0.4) * 32.0, s.px * 80.0);
            c += mt.rgb * mt.a * s.moonAmt;
        }
    }

    // Clouds: clouds.png flat, 12 blocks a texel, drifting with the game's wind.
    if (rd.y > 0.03) {
        float tc = (LL_CLOUD_Y - ro.y) / rd.y;
        float2 cp = (ro.xz + rd.xz * tc + float2(float(s.bx) + s.drift, 0.0)) / 12.0;
        float4 cl = mcMap(maps, MCM_ENVIRONMENT_CLOUDS, fract(cp / 256.0) * 256.0, tc * s.px / (12.0 * rd.y));
        float fade = 1.0 - smoothstep(250.0, 700.0, tc);
        c = mix(c, float3(0.1, 0.1, 0.15), cl.a * 0.8 * fade);   // the game's cloud colour at midnight
    }
    return c;
}

static inline float llFog(float t) { return saturate((t - LL_FOG0) / (LL_FOG1 - LL_FOG0)); }

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]],
                        texture2d_array<float> mcTiles [[texture(8)]],
                        texture2d_array<float> mcSkins [[texture(10)]],   // moon and the trader
                        texture2d_array<float> mcMaps  [[texture(11)]]) {
    LLW w;
    w.T = u.time * u.speed + u.seed * 3000.0 + 40.0;
    w.sd = int(u.seed * 65536.0);
    w.ph1 = u.seed * TWO_PI * 3.0;
    w.ph2 = u.seed * 17.0;
    w.spacing = max(u.spacing, 2);
    w.wild = u.wild;
    bool soul = u.soul != 0;
    w.lmax = soul ? 10.0 : 15.0;
    w.lcol = soul ? LL_C_SOULL : LL_C_LANTERN;
    // Sky light: 15 * moon. The default, level 9 through the game's lightmap
    // at its default Brightness, is about what the game shows at full sky
    // light with Brightness at Moody; 1 is the default-brightness night.
    float skyLv = 15.0 * saturate(u.moon);

    // The walker, in local coordinates (world x minus bx).
    float xw = LL_WALK * w.T;
    w.bx = int(floor(xw));
    float lx = xw - float(w.bx);
    float fy = xw - floor(xw);
    LLNoiseCache wc0 = llCache();
    // The next column's height only matters for the last stretch of a step.
    float y0 = float(llRoadHC(w.bx, w, wc0)), y1 = y0;
    if (fy > 0.6) y1 = float(llRoadHC(w.bx + 1, w, wc0));
    LLWalker K;
    // On the dirt path, which is a sixteenth below the block top.
    K.W = float3(lx, mix(y0, y1, smoothstep(0.6, 1.0, fy)) - 0.0625, llRoadZ(xw, w));
    K.f = normalize(float3(1.0, 0.0, llRoadDZ(xw, w)));
    K.s = cross(float3(0.0, 1.0, 0.0), K.f);
    K.stride = xw * 2.6;
    float3 lamp = llCarriedBase(K) + float3(0.0, 0.2, 0.0);

    // Camera: high and to one side, keeping pace, the road crossing the frame,
    // near enough that the trader reads as a figure.
    float zt = 3.5 * sin(xw * 0.043 + w.ph1);
    float3 target = float3(lx + 1.5, 7.0, zt);
    float sway = 0.12 * sin(w.T * 0.011 + u.seed * 6.0);
    float3 off = float3(0.0, 18.4, -14.4);
    off.xz = rotate(off.xz, sway);
    float3 ro = target + off;
    float3 upHint = float3(0.0, 1.0, 0.0);
    float3 fwd = normalize(target - ro);
    float3 right = normalize(cross(upHint, fwd));
    lerpOrbit(u.yaw, u.pitch, u.magnify, target, upHint, ro, right, fwd);
    float3 up = cross(fwd, right);

    float minRes = min(u.resolution.x, u.resolution.y);
    float pxA = 2.0 / (minRes * LL_FOCAL);
    float2 uv = lerpUV(pos, u.resolution);
    float3 D = uv.x * right + uv.y * up + LL_FOCAL * fwd;
    float dl = length(D);
    float3 rd = D / dl;
    // The ray's change across one screen pixel, for texture footprints.
    float3 dRx = right * (2.0 / (minRes * dl)), dRy = up * (2.0 / (minRes * dl));

    // The sky: midnight with the moon on its arc, high in front of the camera,
    // so the lakes catch it; a phase for each activation (never the new moon).
    LLSkyP sp;
    // Its elevation sweeps slowly through the band the lakes reflect.
    sp.e = 0.92 + 0.2 * sin(w.T * 0.0021 + u.seed * 11.0);
    sp.az = 0.35 * sin(u.seed * 23.0);
    int ph = int(fract(u.seed * 7.31 + 0.13) * 6.999);
    sp.moonLayer = ph == 0 ? MCS_ENVIRONMENT_CELESTIAL_MOON_FULL_MOON
                 : ph == 1 ? MCS_ENVIRONMENT_CELESTIAL_MOON_WANING_GIBBOUS
                 : ph == 2 ? MCS_ENVIRONMENT_CELESTIAL_MOON_THIRD_QUARTER
                 : ph == 3 ? MCS_ENVIRONMENT_CELESTIAL_MOON_WANING_CRESCENT
                 : ph == 4 ? MCS_ENVIRONMENT_CELESTIAL_MOON_WAXING_CRESCENT
                 : ph == 5 ? MCS_ENVIRONMENT_CELESTIAL_MOON_FIRST_QUARTER
                           : MCS_ENVIRONMENT_CELESTIAL_MOON_WAXING_GIBBOUS;
    sp.moonAmt = saturate(u.moon * 1.7);
    sp.px = pxA;
    sp.drift = w.T * 0.6;
    sp.bx = w.bx;

    int lanLayer = soul
        ? mcFrame(MC_SOUL_LANTERN, MC_SOUL_LANTERN_FRAMES, MC_SOUL_LANTERN_TICKS, u.time)
        : mcFrame(MC_LANTERN, MC_LANTERN_FRAMES, MC_LANTERN_TICKS, u.time);
    McModelHit cw;
    bool lanHit = llCarriedHit(ro, rd, K, lanLayer, pxA, mcTiles, cw);
    float tLan = lanHit ? cw.t : 1e9;
    // The trader: one mob, so one bounds test a pixel.
    float heading = atan2(K.f.x, K.f.z);
    MCMOB_Skin skin = mcMobSkin(MCS_WANDERING_TRADER);
    MCMOB_Hit mh; mh.t = INFINITY;
    {
        float3 lro, lrd;
        mcMobRay(ro, rd, K.W, heading, lro, lrd);
        float2 bb = mcMobBounds(MCMOB_VILLAGER, lro, lrd);
        if (bb.x < bb.y && bb.x < tLan) {
            MCMOB_Pose pose = mcMobStill();
            pose.walk = K.stride / 0.6662;
            pose.speed = 0.5;
            mh = mcMobTrace(MCMOB_VILLAGER, pose, skin, lro, lrd, tLan, mcSkins, mcMaps);
        }
    }
    bool mobHit = mh.t < tLan;
    bool wHit = lanHit || mobHit;
    float tW = mobHit ? mh.t : tLan;
    float tLim = wHit ? tW : LL_FOG1;
    LLNoiseCache mLow = llCache(), mRoad = llCache();
    LLHit H = llMarch(ro, rd, tLim, w, mLow, mRoad, mcTiles, lanLayer, pxA);
    bool walkerFront = wHit && tW <= H.t;
    float tSolid = walkerFront ? tW : H.t;

    // What this pixel shows (0 sky, 1 water, 2 the trader or his lantern, 3 a
    // block) and the air cell its light is read from: for him, as the game
    // lights a mob, the cell at his eyes.
    int show = H.tw < tSolid ? 1 : (walkerFront ? 2 : (H.t < 1e8 ? 3 : 0));
    float3 Pw = ro + rd * H.tw, a;
    float2 rp = float2(0.0);
    float tEnd = tSolid;
    if (show == 1) {
        rp = float2(sin(Pw.x * 1.7 + w.T * 0.9 + sin(Pw.z * 1.3)),
                    sin(Pw.z * 1.9 - w.T * 0.8 + sin(Pw.x * 1.1)));
        a = float3(floor(Pw.x) + 0.5, float(LL_WATER) - 0.5, floor(Pw.z) + 0.5);
        tEnd = H.tw;
    } else if (show == 2) {
        a = mobHit ? floor(K.W + float3(0.0, 1.6, 0.0)) + 0.5 : floor(lamp) + 0.5;
    } else if (show == 3) {
        float3 P = ro + rd * H.t;
        bool small = H.mat == LM_MODEL;
        a = small ? floor(P + H.n * 0.3) + 0.5 : float3(H.cell) + 0.5 + H.n;
    } else {
        a = ro + rd * 30.0;
        tEnd = 30.0;
    }

    // The gather. Finding the sources (lattice hashes, ground heights) is
    // the costly part and is the same for every pixel of a 2x2 quad, so the
    // quad shares it: each lane works out at most one road lantern and one
    // wild region for the quad's first pixel, and every lane then reads all of
    // them. A lane whose cell is more than a block and a half from that
    // pixel's (an edge between near and far surfaces) works its own out.
    LLLit L;
    L.lv = 0.0; L.rhalo = float3(0.0);
    LLPk walker;
    walker.p = float4(lamp, LL_WALKER_L * w.lmax / 15.0);
    walker.c = float4(w.lcol, 0.9);
    walker.g = float2(0.8, 0.0);
    bool refl = show == 1;
    llApply(L, walker, a, ro, rd, tEnd, refl, rp * 0.3);
    float3 anchor = quad_broadcast(a, 0);
    int q = (int(pos.x) & 1) + 2 * (int(pos.y) & 1);
    LLPk s0, s1;
    {
        LLNoiseCache ncLow = llCache(), ncRoad = llCache();
        s0 = q < 2 ? llSlot(q, anchor, w, ncLow, ncRoad) : llNone();
        s1 = llSlot(2 + q, anchor, w, ncLow, ncRoad);
    }
    bool far = show != 0 && dot(abs(a - anchor), float3(1.0)) > 1.5;
    bool own = !far && show != 0;
    for (ushort j = 0; j < 4; ++j) {
        LLPk t;
        if (j < 2) {
            t.p = quad_shuffle(s0.p, j); t.c = quad_shuffle(s0.c, j); t.g = quad_shuffle(s0.g, j);
            if (own) llApply(L, t, a, ro, rd, tEnd, refl, rp * 0.3);
        }
        t.p = quad_shuffle(s1.p, j); t.c = quad_shuffle(s1.c, j); t.g = quad_shuffle(s1.g, j);
        if (own) llApply(L, t, a, ro, rd, tEnd, refl, rp * 0.3);
    }
    if (far) {
        LLNoiseCache ncLow = llCache(), ncRoad = llCache();
        for (int i = 0; i < 6; ++i)
            llApply(L, llSlot(i, a, w, ncLow, ncRoad), a, ro, rd, tEnd, refl, rp * 0.3);
    }

    float3 col;
    float3 lm = mcLightmap(L.lv, skyLv, 0.0, 0.0);
    float3 fogC = mcFogAt(0.0);
    if (show == 1) {
        // Water: the bed through the game's tinted, animated still water.
        // Sky light loses a level a block down through it.
        float3 bed = fogC;
        if (H.t < 1e8) {
            float dpt = float(LL_WATER) - 0.125 - (ro.y + rd.y * H.t);
            float3 lmBed = mcLightmap(L.lv, max(skyLv - ceil(max(dpt, 0.0)), 0.0), 0.0, 0.0);
            bed = llShadeBlock(H, ro, rd, dRx, dRy, pxA, w, lmBed, u.time, mcTiles, mcMaps);
        }
        float2 gx, gy;
        llFaceGrad(rd, H.tw, float3(0, 1, 0), dRx, dRy, float3(1, 0, 0), float3(0, 0, 1), gx, gy);
        int wf = mcFrame(MC_WATER_STILL, MC_WATER_STILL_FRAMES, MC_WATER_STILL_TICKS, u.time);
        float4 wt = mcTileAniso(mcTiles, wf, Pw.xz, gx, gy);
        col = mix(bed, wt.rgb * MC_WATER_TINT * lm, wt.a);
        // Not the game's: the lakes mirror the sky and the lights on their shores.
        float3 rr = float3(rd.x, -rd.y, rd.z);   // a flat mirror: the game's water has no waves
        col += llSky(rr, Pw, sp, mcSkins, mcMaps) * 0.6 + L.rhalo * 0.6;
        col = mix(col, fogC, llFog(H.tw));
    } else if (show == 2) {
        if (mobHit) {
            float4 c = mcMobColor(MCMOB_VILLAGER, mh, skin, mh.t * pxA * 16.0, mcSkins, mcMaps);
            col = c.rgb * mcFaceShade(mcMobNormal(mh.n, heading)) * lm;
        } else {
            col = cw.color.rgb * mcFaceShade(cw.n) * lm;
        }
        col = mix(col, fogC, llFog(tW));
    } else if (show == 3) {
        col = llShadeBlock(H, ro, rd, dRx, dRy, pxA, w, lm, u.time, mcTiles, mcMaps);
        col = mix(col, fogC, llFog(H.t));
    } else {
        col = llSky(rd, ro, sp, mcSkins, mcMaps);
    }

    col = lerpDither(col, pos);
    return half4(half3(col), 1.0h);
}
