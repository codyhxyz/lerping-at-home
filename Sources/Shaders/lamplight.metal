// Lamplight — original work for Lerping@Home, not a port.
//
// A lamplighter in a tall hat walks a winding road across a block landscape
// at night, a hand lantern swinging at his side. Each lantern post he passes
// kindles, and its light spreads the way light spreads in a world of cubes:
// outwards from the source one block and one level at a time, fifteen levels
// down to nothing. So every pool of light is a stepped diamond, the dark
// between pools is solid, and the road behind him is a string of warm
// terraced pools fading into fog while the road ahead is black. Out in the
// hills wild lights (glow blocks, soul torches, violet crystal, stray
// torches) kindle and go out on their own slow clocks, and the lakes mirror
// whatever burns on their shores.
//
// Light here is the block-world model, not a physical one: each air cell's
// level is the brightest source's level minus its block (Manhattan) distance,
// and a face takes the level of the air cell in front of it, so shading is
// flat per face and falls off in steps. Levels map to brightness through the
// usual l / (4 - 3l) curve, which keeps the steps visible all the way down.
// Light does not route round hills (no flood fill), which a fragment shader
// cannot afford; at this camera height it does not read.
//
// lerp-category: Minecraft
//
// lerp-param: speed        float 0.25 3 = 1    "Walk speed"
// lerp-param: spacing      int 9 16     = 9    "Lantern spacing"
// lerp-param: wild         float 0 1    = 0.75 "Wild lights"
// lerp-param: moon         float 0 2    = 1    "Moonlight"
// lerp-param: colorLantern color        = (1.0, 0.58, 0.28) "Lantern light"
// lerp-param: yaw          float -180 180 = 0  "Turn"
// lerp-param: pitch        float -25 35   = 0  "Tilt"
// lerp-param: magnify      float -1 0.8   = 0  "Zoom"
//
// lerp-preset: "Soul Road" colorLantern=(0.30, 0.80, 1.0), wild=0.45
// lerp-preset: Moonless    moon=0.2, wild=1

// --- World, in blocks.
constant int   LL_COLS  = 100;      // columns a ray may cross
constant int   LL_HMAX  = 10;       // nothing on the ground reaches this y
constant int   LL_WATER = 5;        // air cells below this y hold water
constant int   LL_WILDR = 16;       // wild light lattice
constant float LL_WALK  = 0.6;      // walker speed, blocks per (speed-scaled) second
constant float LL_RING  = 0.7;      // seconds per level as a road lantern kindles
constant float LL_FOCAL = 2.4;
constant float LL_FOG0  = 36.0;
constant float LL_FOG1  = 58.0;
constant float LL_LK    = 1.5;      // block light gain
constant float LL_LANTERN_L = 13.0; // a road lantern's full level

constant float3 LL_FOGC = float3(0.0035, 0.0045, 0.011);
constant float3 LL_MOON = float3(0.30, 0.42, 1.0) * 0.045;
constant float3 LL_C_GLOW  = float3(1.00, 0.76, 0.40);
constant float3 LL_C_SOUL  = float3(0.28, 0.78, 1.00);
constant float3 LL_C_CRYS  = float3(0.70, 0.40, 1.00);
constant float3 LL_C_TORCH = float3(1.00, 0.55, 0.24);

enum LLMat {
    LM_GRASS = 0, LM_GSIDE, LM_DIRT, LM_STONE, LM_SAND, LM_PATH,
    LM_POST, LM_LANTERN, LM_IRON, LM_GLOW, LM_CRYSTAL, LM_STICK, LM_FLAME, LM_SOUL,
    LM_TERRAIN = 99
};

// Light-source kinds: 1 road lantern, 3 glow block, 4 soul torch, 5 crystal, 6 torch.

struct LLW {
    int   bx;        // world x of the local origin: the scene is drawn near x = 0
    int   sd;        // seed salt
    float ph1, ph2;  // road phases
    float T;         // the walker's clock
    int   spacing;
    float wild;
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
    return clamp((w.T - (float(xk) + 0.5) / LL_WALK) / LL_RING, 0.0, LL_LANTERN_L);
}

// The wild light of region `reg`, if it has one: column, kind and current
// level (it kindles a level at a time, burns, then fades a level at a time).
// The caller still checks the ground (dry, off the road).
static inline bool llWild(int2 reg, LLW w, thread int2& p, thread int& kind,
                          thread float& lv, thread float& mx) {
    if (llH(int3(reg, w.sd + 31)) >= w.wild) return false;
    float k = llH(int3(reg, w.sd + 34));
    kind = k < 0.3 ? 3 : (k < 0.55 ? 4 : (k < 0.75 ? 5 : 6));
    mx = kind == 3 ? 12.0 : (kind == 4 ? 10.0 : (kind == 5 ? 9.0 : 11.0));
    float P = 150.0 + 100.0 * fract(k * 7.7 + 0.2);
    float cyc = glmod(w.T + P * fract(k * 31.3 + 0.5), P);
    float on = 0.62 * P;
    lv = cyc < on ? min(cyc / 0.9, mx) : max(mx - (cyc - on) / 1.5, 0.0);
    // Kept to the middle of the region, which with a reach of 12 means a
    // point can only be lit from its own region and one neighbour per axis.
    int2 o = int2(int(fract(k * 57.1 + 0.3) * 5.999), int(fract(k * 91.7 + 0.9) * 5.999));
    p = reg * LL_WILDR + 5 + o;
    return true;
}

static inline float3 llKindCol(int kind) {
    return kind == 3 ? LL_C_GLOW : (kind == 4 ? LL_C_SOUL : (kind == 5 ? LL_C_CRYS : LL_C_TORCH));
}

// A light source as the gather sees it, packed so a quad of pixels can pass
// sources between its lanes: (light cell, level), (colour, glow strength
// 0..1), (glow size, glow height above the light cell).
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
// sixteen and reach at most 12, so that choice misses nothing for any point
// within a block and a half of a.
static inline LLPk llSlot(int i, float3 a, LLW w, float3 lantern,
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
        k.p = float4(lc.x, base + 1.5, lc.y, lv);
        k.c = float4(lantern, lv / LL_LANTERN_L);
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
    bool block = kind == 3 || kind == 5;
    k.p = float4(lc.x, float(h) + 0.5, lc.y, lv);
    k.c = float4(llKindCol(kind), lv / mx);
    k.g = float2(block ? 1.6 : 0.8, block ? 0.0 : 0.12);
    return k;
}

static inline float llBright(float l) {
    float f = saturate(l / 15.0);
    return f / (4.0 - 3.0 * f);
}

static inline float llFog(float t) { return smoothstep(LL_FOG0, LL_FOG1, t); }

// Glow in the night air round a source, seen along the ray [0, tEnd].
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

// What one pixel gathers: block light at its air cell a, and glow along its
// view ray, and on water the glow of each source's mirror image below the
// surface (nudged by the ripple), which is the reflection without a second ray.
struct LLLit {
    float  bmax, wsum;
    float3 csum, halo, rhalo;
};

static inline void llApply(thread LLLit& L, LLPk k, float3 a, float3 ro, float3 rd, float tEnd,
                           bool refl, float2 ripple) {
    float3 dd = abs(a - k.p.xyz);
    float l = k.p.w - (dd.x + dd.y + dd.z);
    if (l > 0.0) {
        // Whole levels; a moving source crosses each step in a short blend.
        float lq = floor(l) + smoothstep(0.8, 1.0, fract(l));
        float b = llBright(lq);
        L.bmax = max(L.bmax, b);
        L.csum += k.c.rgb * (b * b);
        L.wsum += b * b;
    }
    if (k.c.w > 0.0) {
        L.halo += llGlow(ro, rd, tEnd, k);
        if (refl) {
            const float wl = float(LL_WATER) - 0.125;
            k.p.y = 2.0 * wl - k.p.y - 2.0 * k.g.y;
            k.p.xz += ripple;
            L.rhalo += llGlow(ro, rd, tEnd + 40.0, k);
        }
    }
}

// ---------------------------------------------------------------------------
// The march.

struct LLHit {
    float  t;       // 1e9: nothing before the limit
    float  tw;      // the water surface on the way, 1e9: none
    float3 n;
    int3   cell;    // local cell
    int    mat;
    float  e;       // the column's source level, 0..1
    int    h;       // column ground height
    float  roadD;
};

static inline bool llBoxHit(float3 ro, float3 inv, float3 lo, float3 hi,
                            thread float& best, thread float3& nrm) {
    float3 t1 = (lo - ro) * inv, t2 = (hi - ro) * inv;
    float3 tn = min(t1, t2), tf = max(t1, t2);
    float tN = max(max(tn.x, tn.y), tn.z), tF = min(min(tf.x, tf.y), tf.z);
    if (tN > tF || tN < 0.0 || tN >= best) return false;
    best = tN;
    nrm = tN == tn.x ? float3(-sign(inv.x), 0.0, 0.0)
        : (tN == tn.y ? float3(0.0, -sign(inv.y), 0.0) : float3(0.0, 0.0, -sign(inv.z)));
    return true;
}

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

// The ground and what stands on it, walked column by column below the
// highest the ground can reach. In a column the ground is one solid run,
// so each step is the same few tests whatever the ray's slope. The noise
// caches are the caller's so corner shading can reuse them.
static inline LLHit llMarch(float3 ro, float3 rd, float tLimit, LLW w,
                            thread LLNoiseCache& ncLow, thread LLNoiseCache& ncRoad) {
    LLHit H;
    H.t = 1e9; H.tw = 1e9; H.n = float3(0.0, 1.0, 0.0); H.cell = int3(0);
    H.mat = -1; H.e = 0.0; H.h = 0; H.roadD = 9.0;
    float t0 = 0.0;
    if (ro.y > float(LL_HMAX)) {
        if (rd.y > -1e-4) return H;
        t0 = (float(LL_HMAX) - ro.y) / rd.y;
    }
    float2 rs = select(rd.xz, float2(1e-6), abs(rd.xz) < 1e-6);
    float2 inv = 1.0 / rs;
    float3 inv3 = 1.0 / select(rd, float3(1e-6), abs(rd) < 1e-6);
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
                lanE = lan.x == wc.x ? llLanternLevel(lan.x, w) / LL_LANTERN_L : -1.0;
            }
            if (lanE >= 0.0 && lan.y == wc.y) { sKind = 1; sE = lanE; }
        } else if (roadD > 3.5) {
            int2 reg = int2(floor(float2(wc) / float(LL_WILDR)));
            if (reg.x != wildReg.x || reg.y != wildReg.y) {
                wildReg = reg;
                wildOK = llWild(reg, w, wildP, wildKind, wildLv, wildMx);
            }
            if (wildOK && wildP.x == wc.x && wildP.y == wc.y) { sKind = wildKind; sE = wildLv / wildMx; }
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
        if (sKind == 1 || sKind == 4 || sKind == 6) {
            float3 o = float3(float(cell.x), float(h), float(cell.y));
            const float k = 1.0 / 16.0;
            float bt = 1e9; float3 bn; int bm = -1;
            if (sKind == 1) {
                if (llBoxHit(ro, inv3, o + float3(6, 0, 6) * k,  o + float3(10, 16, 10) * k, bt, bn)) bm = LM_POST;
                if (llBoxHit(ro, inv3, o + float3(5, 16, 5) * k, o + float3(11, 24, 11) * k, bt, bn)) bm = LM_LANTERN;
                if (llBoxHit(ro, inv3, o + float3(6, 24, 6) * k, o + float3(10, 26, 10) * k, bt, bn)) bm = LM_IRON;
            } else {
                if (llBoxHit(ro, inv3, o + float3(7, 0, 7) * k, o + float3(9, 8, 9) * k, bt, bn)) bm = LM_STICK;
                if (sE > 0.0 && llBoxHit(ro, inv3, o + float3(6.5, 8, 6.5) * k, o + float3(9.5, 11, 9.5) * k, bt, bn))
                    bm = sKind == 4 ? LM_SOUL : LM_FLAME;
            }
            if (bm >= 0) {
                H.t = bt; H.n = bn; H.cell = int3(floor(ro + rd * bt - bn * 0.01));
                H.mat = bm; H.e = sE; H.h = h; H.roadD = roadD;
                return H;
            }
        }
        // The water surface, where the ray crosses it over a low column.
        if (H.tw > 1e8 && rd.y < 0.0 && yIn >= wl && yOut < wl && h < LL_WATER)
            H.tw = (wl - ro.y) / rd.y;

        bool block = sKind == 3 || sKind == 5;
        int face;
        float tg = llSpan(-1e9, float(h + (block ? 1 : 0)), yIn, yOut, tIn, ro.y, rd.y, face);
        if (tg < 1e8) {
            int hitY = face == 1 ? h + (block ? 1 : 0) - 1 : int(floor(yIn));
            float3 nn = float3(0.0, 1.0, 0.0);
            if (face == 0) {
                nn = float3(0.0);
                if (axis == 0) nn.x = -float(stp.x); else nn.z = -float(stp.y);
            }
            H.t = tg; H.n = nn; H.cell = int3(cell.x, hitY, cell.y);
            H.mat = (block && hitY == h) ? (sKind == 3 ? LM_GLOW : LM_CRYSTAL) : LM_TERRAIN;
            H.e = sE; H.h = h; H.roadD = roadD;
            return H;
        }
        if (tMax.x < tMax.y) { axis = 0; tIn = tMax.x; tMax.x += tDel.x; cell.x += stp.x; }
        else                 { axis = 2; tIn = tMax.y; tMax.y += tDel.y; cell.y += stp.y; }
    }
    return H;
}

// ---------------------------------------------------------------------------
// Surfaces: 16 x 16 texels a face, all procedural. Colours are written in
// display values and squared into (roughly) linear light.

struct LLTex { float3 alb; float3 emi; };

static inline LLTex llTexel(int mat, int2 tx, int salt, float detail, float e, float3 lantern) {
    int2 lt = tx & 15;
    float r  = llH(int3(tx, salt));
    float r2 = fract(r * 11.37 + 0.31);
    float v = mix(1.0, 0.8 + 0.4 * r, detail);
    LLTex o;
    o.emi = float3(0.0);
    float3 c;
    switch (mat) {
    case LM_GRASS:
        c = float3(0.33, 0.52, 0.20) * v * (r2 > 0.9 ? mix(1.0, 1.18, detail) : 1.0);
        break;
    case LM_GSIDE: {
        int fr = 3 + int(llH(int3(tx.x, tx.y >> 4, salt + 3)) * 2.99);
        c = (lt.y >= 16 - fr ? float3(0.30, 0.48, 0.18) : float3(0.46, 0.32, 0.21)) * v;
        break;
    }
    case LM_DIRT:
        c = float3(0.46, 0.32, 0.21) * v * (r2 > 0.88 ? mix(1.0, 0.7, detail) : 1.0);
        break;
    case LM_STONE: {
        float rr = llH(int3(tx >> 1, salt + 5));
        c = float3(0.47, 0.47, 0.48) * mix(1.0, 0.72 + 0.4 * mix(r, rr, 0.6), detail);
        break;
    }
    case LM_SAND:
        c = float3(0.80, 0.73, 0.52) * mix(1.0, 0.9 + 0.18 * r, detail);
        break;
    case LM_PATH:
        c = (r2 > 0.72 ? float3(0.45, 0.43, 0.40) : float3(0.56, 0.44, 0.28)) * v;
        break;
    case LM_POST:
        c = float3(0.52, 0.39, 0.24) * v * (llH(int3(tx.x, 0, salt + 11)) < 0.3 ? 0.75 : 1.0);
        break;
    case LM_LANTERN: {
        bool frame = lt.x == 5 || lt.x == 10 || lt.y == 0 || lt.y == 7;
        if (frame) c = float3(0.20, 0.20, 0.22) * v;
        else {
            c = float3(0.30, 0.22, 0.12);
            float core = (lt.y >= 2 && lt.y <= 5 && lt.x >= 7 && lt.x <= 8) ? 1.4 : 1.0;
            o.emi = lantern * e * (1.7 + 0.6 * r) * core;
        }
        break;
    }
    case LM_IRON:
        c = float3(0.20, 0.20, 0.22) * v;
        break;
    case LM_GLOW: {
        float q = llH(int3(tx >> 1, salt + 13));
        c = float3(0.42, 0.34, 0.20) * v;
        o.emi = LL_C_GLOW * e * (q > 0.4 ? 1.0 + 0.9 * r : 0.18);
        break;
    }
    case LM_CRYSTAL: {
        bool facet = ((lt.x + lt.y) & 7) < 3 || ((lt.x - lt.y) & 7) == 0;
        c = float3(0.30, 0.20, 0.40) * v;
        o.emi = LL_C_CRYS * e * (facet ? 1.4 : 0.3) * (0.7 + 0.6 * r);
        break;
    }
    case LM_STICK:
        c = float3(0.45, 0.32, 0.18) * v;
        break;
    case LM_FLAME:
        c = float3(0.10, 0.09, 0.08);
        o.emi = (lt.y >= 10 ? float3(1.0, 0.85, 0.5) : LL_C_TORCH) * e * (1.5 + r);
        break;
    default: // LM_SOUL
        c = float3(0.10, 0.09, 0.08);
        o.emi = (lt.y >= 10 ? float3(0.7, 0.95, 1.0) : LL_C_SOUL) * e * (1.5 + r);
        break;
    }
    o.alb = c * c;
    return o;
}

// Crisp texels up close (each texel edge blended over one pixel), and the
// per-texel variation fading out once a texel is smaller than a pixel, so
// nothing crawls as the camera drifts.
static inline LLTex llTexF(int mat, float2 uvw, int2 shift, int salt, float fwT, float e, float3 lantern) {
    float detail = 1.0 - smoothstep(0.7, 2.2, fwT);
    float2 tp = uvw * 16.0 - 0.5;
    float2 i0 = floor(tp);
    float2 f = tp - i0;
    float2 wg = saturate((f - 0.5) / max(fwT, 1e-3) + 0.5);
    int2 b = int2(i0) + shift;
    LLTex a  = llTexel(mat, b,              salt, detail, e, lantern);
    LLTex bb = llTexel(mat, b + int2(1, 0), salt, detail, e, lantern);
    LLTex c  = llTexel(mat, b + int2(0, 1), salt, detail, e, lantern);
    LLTex d  = llTexel(mat, b + int2(1, 1), salt, detail, e, lantern);
    LLTex o;
    o.alb = mix(mix(a.alb, bb.alb, wg.x), mix(c.alb, d.alb, wg.x), wg.y);
    o.emi = mix(mix(a.emi, bb.emi, wg.x), mix(c.emi, d.emi, wg.x), wg.y);
    return o;
}

// Is terrain cell (world column c, height y) solid?
static inline float llSolid(int2 c, int y, LLW w, thread LLNoiseCache& ncLow, thread LLNoiseCache& ncRoad) {
    float roadD = abs(float(c.y) + 0.5 - llRoadZ(float(c.x) + 0.5, w));
    int b = max(int(floor(3.0 + 7.0 * llNoiseC((float2(c) + 0.5) / 24.0, w.sd, ncLow))), 1);
    if (roadD >= 5.5) return y < b ? 1.0 : 0.0;
    int rh = llRoadHC(c.x, w, ncRoad);
    int h = roadD < 2.5 ? rh : int(round(mix(float(rh), float(b), (roadD - 2.5) / 3.0)));
    return y < h ? 1.0 : 0.0;
}

// Darkening where a terrain face meets a wall or the ground. Only the
// nearer edge on each axis is looked up: two neighbours, not eight.
static inline float llAO(LLHit H, float3 P, LLW w, thread LLNoiseCache& ncLow, thread LLNoiseCache& ncRoad) {
    int3 a = H.cell + int3(H.n);
    int2 ac = int2(a.x + w.bx, a.z);
    bool top = H.n.y > 0.5;
    int2 e1 = top || abs(H.n.x) < 0.5 ? int2(1, 0) : int2(0, 1);
    float uu = top ? fract(P.x) : (abs(H.n.x) > 0.5 ? fract(P.z) : fract(P.x));
    float vv = top ? fract(P.z) : fract(P.y);
    // Each edge darkens the quarter block beside it; a pixel looks up only
    // the edges it is near.
    float du = smoothstep(0.35, 1.0, 1.0 - 2.0 * min(uu, 1.0 - uu));
    float dv = smoothstep(0.35, 1.0, 1.0 - 2.0 * min(vv, 1.0 - vv));
    float occ = 0.0;
    if (du > 0.0) occ += du * llSolid(ac + (uu < 0.5 ? -e1 : e1), a.y, w, ncLow, ncRoad);
    if (dv > 0.0) {
        if (top) occ += dv * llSolid(ac + int2(0, vv < 0.5 ? -1 : 1), a.y, w, ncLow, ncRoad);
        else if (vv < 0.5) occ += dv * llSolid(ac, a.y - 1, w, ncLow, ncRoad);   // the floor at a wall's foot
    }
    return 1.0 - 0.45 * min(occ, 1.0);
}

static inline float3 llShadeBlock(LLHit H, float3 ro, float3 rd, float pxA, LLW w,
                                  thread LLNoiseCache& ncLow, thread LLNoiseCache& ncRoad,
                                  float3 light, float moon, float3 lantern) {
    float3 P = ro + rd * H.t;
    float3 n = H.n;
    int mat = H.mat;
    bool terrain = mat == LM_TERRAIN;
    if (terrain) {
        bool sandy = H.h <= LL_WATER && H.roadD >= 1.5;
        int depth = H.h - 1 - H.cell.y;
        if (n.y > 0.5) mat = sandy ? LM_SAND : (H.roadD < 1.5 ? LM_PATH : LM_GRASS);
        else if (sandy) mat = depth < 3 ? LM_SAND : LM_STONE;
        else if (depth == 0) mat = H.roadD < 1.5 ? LM_DIRT : LM_GSIDE;
        else mat = depth < 4 ? LM_DIRT : LM_STONE;
    }
    float2 uvw; int2 shift; int plane;
    if (abs(n.y) > 0.5)      { uvw = P.xz; shift = int2(w.bx * 16, 0); plane = H.cell.y * 3; }
    else if (abs(n.x) > 0.5) { uvw = P.zy; shift = int2(0);           plane = (H.cell.x + w.bx) * 3 + 1; }
    else                     { uvw = P.xy; shift = int2(w.bx * 16, 0); plane = H.cell.z * 3 + 2; }
    int salt = w.sd + plane * 131 + mat * 7919 + (n.x + n.y + n.z > 0.0 ? 0 : 104729);
    float fwT = H.t * pxA * 16.0 / max(abs(dot(rd, n)), 0.2);
    LLTex tx = llTexF(mat, uvw, shift, salt, fwT, H.e, lantern);

    float ao = terrain ? llAO(H, P, w, ncLow, ncRoad) : 1.0;
    float fs = n.y > 0.5 ? 1.0 : (n.y < -0.5 ? 0.5 : (abs(n.z) > 0.5 ? 0.8 : 0.62));
    float mf = n.y > 0.5 ? 1.0 : (n.x > 0.5 ? 0.5 : 0.32);
    // Moonlight sees almost no colour; block light sees all of it.
    float3 night = mix(tx.alb, float3(dot(tx.alb, float3(0.3, 0.55, 0.15))), 0.85);
    return (night * LL_MOON * moon * mf + tx.alb * light * LL_LK * fs) * ao + tx.emi;
}

// ---------------------------------------------------------------------------
// The lamplighter: a few boxes in his own frame, hat to boots.

struct LLWalker { float3 W; float3 f; float3 s; float swing; };

static inline bool llWalkerHit(float3 ro, float3 rd, LLWalker k, thread float& t,
                               thread float3& n, thread int& part, thread float3& lp) {
    float3 oc = ro - (k.W + float3(0.0, 1.0, 0.0));
    float b = dot(oc, rd);
    if (b * b - (dot(oc, oc) - 1.7) < 0.0) return false;
    float3 o = ro - k.W;
    float3 lro = float3(dot(o, k.s), o.y, dot(o, k.f));
    float3 lrd = float3(dot(rd, k.s), rd.y, dot(rd, k.f));
    float3 inv = 1.0 / select(lrd, float3(1e-6), abs(lrd) < 1e-6);
    float best = 1e9; float3 nl = float3(0.0, 1.0, 0.0);
    part = -1;
    float sw = k.swing;
    if (llBoxHit(lro, inv, float3(-0.20, 0.00, -0.08 + sw), float3(-0.02, 0.62, 0.10 + sw), best, nl)) part = 0;
    if (llBoxHit(lro, inv, float3( 0.02, 0.00, -0.08 - sw), float3( 0.20, 0.62, 0.10 - sw), best, nl)) part = 0;
    if (llBoxHit(lro, inv, float3(-0.25, 0.55, -0.15), float3(0.25, 1.32, 0.15), best, nl)) part = 1;
    if (llBoxHit(lro, inv, float3(-0.37, 0.88, -0.07 + sw * 0.5), float3(-0.25, 1.28, 0.07 + sw * 0.5), best, nl)) part = 1;
    if (llBoxHit(lro, inv, float3( 0.25, 0.95, -0.06), float3( 0.37, 1.28, 0.30), best, nl)) part = 1;
    if (llBoxHit(lro, inv, float3( 0.21, 0.60, 0.14), float3( 0.41, 0.88, 0.34), best, nl)) part = 4;
    if (llBoxHit(lro, inv, float3(-0.17, 1.32, -0.17), float3(0.17, 1.64, 0.17), best, nl)) part = 2;
    if (llBoxHit(lro, inv, float3(-0.27, 1.62, -0.27), float3(0.27, 1.67, 0.27), best, nl)) part = 3;
    if (llBoxHit(lro, inv, float3(-0.16, 1.67, -0.16), float3(0.16, 1.98, 0.16), best, nl)) part = 3;
    if (part < 0) return false;
    t = best;
    n = nl.x * k.s + float3(0.0, nl.y, 0.0) + nl.z * k.f;
    lp = lro + lrd * best;
    if (part == 2 && nl.z > 0.5) part = 5;   // his face
    return true;
}

static inline float3 llShadeWalker(int part, float3 lp, float3 n, float3 P, float3 lamp,
                                   float3 light, float moon, float3 lantern, float flick) {
    float3 c; float3 emi = float3(0.0);
    switch (part) {
    case 0: c = float3(0.13, 0.11, 0.10); break;
    case 1: c = float3(0.42, 0.17, 0.12); if (abs(lp.y - 0.92) < 0.04) c = float3(0.25, 0.17, 0.10); break;
    case 2: c = float3(0.30, 0.20, 0.14); break;                         // hair at the back and sides
    case 3: c = abs(lp.y - 1.695) < 0.025 ? float3(0.50, 0.14, 0.11) : float3(0.09, 0.09, 0.10); break;
    case 4: {
        bool band = lp.y < 0.64 || lp.y > 0.84;
        c = band ? float3(0.20, 0.20, 0.22) : float3(0.3, 0.22, 0.12);
        if (!band) emi = lantern * 2.0 * flick;
        break;
    }
    default: {
        float ex = abs(lp.x);
        bool eye = ex > 0.04 && ex < 0.10 && lp.y > 1.45 && lp.y < 1.51;
        c = eye ? float3(0.06, 0.05, 0.05) : float3(0.86, 0.66, 0.50);
        break;
    }
    }
    float toward = max(dot(n, normalize(lamp - P)), 0.0);
    float mf = n.y > 0.5 ? 1.0 : 0.4;
    return c * c * (LL_MOON * moon * mf + light * LL_LK * (0.3 + 0.7 * toward)) + emi;
}

static inline float3 llSky(float3 rd) {
    float3 c = mix(LL_FOGC, LL_FOGC * 0.4, saturate(rd.y * 4.0));
    if (rd.y > 0.0) {
        float2 sp = rd.xz / (rd.y + 0.3) * 90.0;
        float2 ci = floor(sp), fr = sp - ci;
        int2 cc = int2(ci);
        float hh = llH(int3(cc, 77));
        if (hh > 0.93) {
            float2 sc = float2(llH(int3(cc, 78)), llH(int3(cc, 79))) * 0.6 + 0.2;
            float d = length(fr - sc);
            c += float3(0.7, 0.75, 1.0) * 0.25 * (hh - 0.93) / 0.07 * smoothstep(0.14, 0.0, d)
               * saturate(rd.y * 6.0);
        }
    }
    return c;
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    LLW w;
    w.T = u.time * u.speed + u.seed * 3000.0 + 40.0;
    w.sd = int(u.seed * 65536.0);
    w.ph1 = u.seed * TWO_PI * 3.0;
    w.ph2 = u.seed * 17.0;
    w.spacing = max(u.spacing, 2);
    w.wild = u.wild;
    float3 lantern = u.colorLantern.rgb;

    // The walker, in local coordinates (world x minus bx).
    float xw = LL_WALK * w.T;
    w.bx = int(floor(xw));
    float lx = xw - float(w.bx);
    float stride = xw * 2.6;
    float fy = xw - floor(xw);
    LLNoiseCache wc0 = llCache();
    // The next column's height only matters for the last stretch of a step.
    float y0 = float(llRoadHC(w.bx, w, wc0)), y1 = y0;
    if (fy > 0.6) y1 = float(llRoadHC(w.bx + 1, w, wc0));
    LLWalker K;
    K.W = float3(lx, mix(y0, y1, smoothstep(0.6, 1.0, fy)) + 0.03 * abs(sin(stride)), llRoadZ(xw, w));
    K.f = normalize(float3(1.0, 0.0, llRoadDZ(xw, w)));
    K.s = cross(float3(0.0, 1.0, 0.0), K.f);
    K.swing = 0.12 * sin(stride);
    float flick = 0.92 + 0.05 * sin(w.T * 7.3) + 0.03 * sin(w.T * 13.1);
    float3 lamp = K.W + K.s * 0.31 + float3(0.0, 0.74, 0.0) + K.f * (0.24 + 0.03 * sin(stride + 1.0));

    // Camera: high and to one side, keeping pace, the road crossing the frame.
    float zt = 3.5 * sin(xw * 0.043 + w.ph1);
    float3 target = float3(lx + 1.5, 7.0, zt);
    float sway = 0.12 * sin(w.T * 0.011 + u.seed * 6.0);
    float3 off = float3(0.0, 23.0, -18.0);
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
    float3 rd = normalize(uv.x * right + uv.y * up + LL_FOCAL * fwd);

    float tW = 1e9; float3 nW; int part; float3 lpW;
    bool wHit = llWalkerHit(ro, rd, K, tW, nW, part, lpW);
    float tLim = wHit ? tW : LL_FOG1;
    // The march's noise caches are kept for corner shading, whose
    // neighbour columns nearly always fall in the same lattice cells.
    LLNoiseCache mLow = llCache(), mRoad = llCache();
    LLHit H = llMarch(ro, rd, tLim, w, mLow, mRoad);
    bool walkerFront = wHit && tW <= H.t;
    float tSolid = walkerFront ? tW : H.t;

    // What this pixel shows (0 sky, 1 water, 2 the walker, 3 a block) and
    // the air cell its light is read from.
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
        a = ro + rd * tW + nW * 0.4;
    } else if (show == 3) {
        float3 P = ro + rd * H.t;
        bool small = H.mat >= LM_POST && H.mat <= LM_SOUL && H.mat != LM_GLOW && H.mat != LM_CRYSTAL;
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
    L.bmax = 0.0; L.wsum = 1e-6; L.csum = float3(0.0); L.halo = float3(0.0); L.rhalo = float3(0.0);
    LLPk walker;
    walker.p = float4(lamp, 11.0);
    walker.c = float4(lantern, flick);
    walker.g = float2(0.8, 0.0);
    bool refl = show == 1;
    llApply(L, walker, a, ro, rd, tEnd, refl, rp * 0.3);
    float3 anchor = quad_broadcast(a, 0);
    int q = (int(pos.x) & 1) + 2 * (int(pos.y) & 1);
    LLPk s0, s1;
    {
        LLNoiseCache ncLow = llCache(), ncRoad = llCache();
        s0 = q < 2 ? llSlot(q, anchor, w, lantern, ncLow, ncRoad) : llNone();
        s1 = llSlot(2 + q, anchor, w, lantern, ncLow, ncRoad);
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
            llApply(L, llSlot(i, a, w, lantern, ncLow, ncRoad), a, ro, rd, tEnd, refl, rp * 0.3);
    }
    float3 light = L.csum / L.wsum * L.bmax;

    float3 col;
    thread LLNoiseCache& ncLow = mLow;
    thread LLNoiseCache& ncRoad = mRoad;
    if (show == 1) {
        // Water: the lit surface, the bed seen through it, and the lights mirrored.
        float3 bed = H.t < 1e8 ? llShadeBlock(H, ro, rd, pxA, w, ncLow, ncRoad, light, u.moon, lantern) : LL_FOGC;
        float depth = (H.t < 1e8 ? H.t : H.tw + 6.0) - H.tw;
        float3 trans = exp(-depth * float3(0.9, 0.55, 0.4));
        float3 surf = float3(0.004, 0.025, 0.08) * (LL_MOON * u.moon + light * LL_LK);
        float3 rr = reflect(rd, normalize(float3(0.035 * rp.x, 1.0, 0.035 * rp.y)));
        float3 refc = llSky(rr) * 0.6 + L.rhalo * 0.55;
        col = bed * trans * 0.8 + surf + refc;
        float fg = llFog(H.tw);
        col = mix(col, LL_FOGC, fg) + L.halo * (1.0 - fg);
    } else if (show == 2) {
        float3 P = ro + rd * tW;
        col = llShadeWalker(part, lpW, nW, P, lamp, light, u.moon, lantern, flick);
        float fg = llFog(tW);
        col = mix(col, LL_FOGC, fg) + L.halo * (1.0 - fg);
    } else if (show == 3) {
        col = llShadeBlock(H, ro, rd, pxA, w, ncLow, ncRoad, light, u.moon, lantern);
        float fg = llFog(H.t);
        col = mix(col, LL_FOGC, fg) + L.halo * (1.0 - fg);
    } else {
        col = rd.y > 0.0 ? llSky(rd) : LL_FOGC;
    }

    col = 1.0 - exp(-1.3 * max(col, 0.0));
    col = pow(col, 1.0 / 2.2);
    col = lerpDither(col, pos);
    return half4(half3(col), 1.0h);
}
