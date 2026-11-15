// Cascade — water stepping down a terraced quarry.
// Original work for Lerping@Home: an homage to the way water moves in block
// games. Every texture and rule here is written from scratch; nothing is
// taken from any game's art.
//
// lerp-category: Blocks
//
// A square quarry is cut into a grass plain in terraces, through beds of
// rock that band its walls, late in the day. Springs open on the plain near the rim one after another.
// Water from a spring spreads over the ground a block per tick and a level
// lower with each block (eight levels, so a spring's pool is a stepped
// diamond). Where the diamond reaches the edge with a level to spare it pours
// over as a sheet of falling blocks, falls a block per tick, lands at full
// strength and runs for the next edge, stepping down a level a block and
// widening by one each ledge, until it drops into the pool at the bottom.
// When the spring closes the water drains the way it came, top first, each
// block thinning a level a tick before it goes.
//
// It is all closed form, with no step of the flow stored: a cell's level is
// how far it sits from where its stream landed on that ledge, and its
// arrival tick is its plan distance from the spring plus the height fallen.
// The ground is hit exactly (each terrace is everything outside a square
// below its floor), shadows are the same boxes from the sun's side, and only
// the last few cells before the ground are walked looking for water.
//
// Water is drawn as water: you see the stone through a shallow step and not
// through the pool, streaks run the way it flows and pour down the falling
// sheets, a level nearly spent goes pale, white water churns where a sheet
// lands, and the low sky shows on the surface.
//
// lerp-param: speed   float 0.5 3   = 1    "Flow speed"
// lerp-param: springs int   1 4     = 3    "Springs"
// lerp-param: sun     float 0.05 0.9 = 0.14 "Sun height"
// lerp-animate: sun 0.1 0.2 period=300
// lerp-param: yaw     float -180 180 = 0   "Turn"
// lerp-param: pitch   float -25 30  = 0    "Tilt"
// lerp-param: magnify float -1 1    = 0    "Zoom"
//
// lerp-preset: Trickle springs=1
// lerp-preset: Flood   springs=4, speed=1.6
// lerp-preset: Dusk    sun=0.06
// lerp-preset: Noon    sun=0.62

constant int   CS_K     = 5;       // terraces below the rim (csPit is written for 5)
constant float CS_TICK  = 0.6;     // seconds per flow tick at speed 1
constant float CS_P     = 175.0;   // ticks between one slot's springs: never long dry
constant float CS_D     = 95.0;    // ticks a spring runs
constant float CS_TAIL  = 70.0;    // ticks the last of its water takes to drain
constant float CS_FOCAL = 1.8;
constant int   CS_WSTEPS = 12;    // cells a ray walks looking for water, bounded
constant int   CS_DRY   = 99;
constant int   CS_SPREAD = 1;     // blocks a stream widens per ledge

// ---------------------------------------------------------------------------
// The pit. Cells are centred on integer (x, z); a cell's ring is its
// Chebyshev radius max(|x|, |z|). Terrace k holds rings a[k] .. a[k-1]-1 with
// its floor (block tops) at H[k]; k = 0 is the plain, k = K+1 the pool.

struct CsPit {
    int4   a0, a1;     // a[0..3], a[4..7]
    float4 H0, H1;
};

static inline int csA(thread const CsPit& p, int k) {
    int4 v = k < 4 ? p.a0 : p.a1;
    int i = k & 3;
    return i == 0 ? v.x : (i == 1 ? v.y : (i == 2 ? v.z : v.w));
}
static inline float csHt(thread const CsPit& p, int k) {
    float4 v = k < 4 ? p.H0 : p.H1;
    int i = k & 3;
    return i == 0 ? v.x : (i == 1 ? v.y : (i == 2 ? v.z : v.w));
}

static inline CsPit csPit(float seed) {
    // Built in vector lanes, not arrays: a runtime-indexed array lives in
    // stack memory, which this look cannot afford.
    int4 w0 = int4(0), w1 = int4(0);
    float4 d0 = float4(0.0), d1 = float4(0.0);
    #pragma unroll
    for (int k = 1; k <= CS_K; ++k) {
        int wd = 2 + int(hash11(seed * 91.7 + float(k) * 3.17) * 2.99);   // 2..4 blocks wide
        float h = hash11(seed * 53.3 + float(k) * 7.71);
        float drop = h < 0.25 ? 2.0 : (h < 0.75 ? 3.0 : 4.0);
        if (k < 4) { w0[k] = wd; d0[k] = drop; } else { w1[k - 4] = wd; d1[k - 4] = drop; }
    }
    int sum = w0.y + w0.z + w0.w + w1.x + w1.y;
    CsPit p;
    p.a0.x = 6 + sum;          p.H0.x = 0.0;
    p.a0.y = p.a0.x - w0.y;    p.H0.y = p.H0.x - d0.y;
    p.a0.z = p.a0.y - w0.z;    p.H0.z = p.H0.y - d0.z;
    p.a0.w = p.a0.z - w0.w;    p.H0.w = p.H0.z - d0.w;
    p.a1.x = p.a0.w - w1.x;    p.H1.x = p.H0.w - d1.x;
    p.a1.y = p.a1.x - w1.y;    p.H1.y = p.H1.x - d1.y;
    p.a1.z = 0;                p.H1.z = p.H1.y - 2.0;   // the pool's surface block
    p.a1.w = 0;                p.H1.w = p.H1.z;
    return p;
}

// Everything a column needs to know about its terrace, found once so nothing
// downstream indexes the pit by a runtime terrace number.
struct CsTer {
    int   k;        // 0 plain .. CS_K, CS_K + 1 the pool
    float H;        // floor (the pool: its surface block)
    float ground;   // top of the solid column
    float Hup;      // floor of the terrace outside it
    float Hdn;      // floor of the terrace inside it
    int   a;        // inner ring
    int   aUp;      // inner ring of the terrace outside it
};

static inline CsTer csTer(int ring, thread const CsPit& p) {
    CsTer t;
    t.k = CS_K + 1; t.H = csHt(p, CS_K + 1); t.Hup = csHt(p, CS_K); t.Hdn = csHt(p, CS_K + 1);
    t.a = 0; t.aUp = csA(p, CS_K);
    #pragma unroll
    for (int kk = CS_K; kk >= 0; --kk) {
        if (ring >= csA(p, kk)) {
            t.k = kk; t.H = csHt(p, kk); t.Hdn = csHt(p, kk + 1); t.a = csA(p, kk);
            t.Hup = kk > 0 ? csHt(p, max(kk - 1, 0)) : 0.0;
            t.aUp = kk > 0 ? csA(p, max(kk - 1, 0)) : (1 << 20);
        }
    }
    t.ground = t.k <= CS_K ? t.H : t.H - 3.0;
    return t;
}

// ---------------------------------------------------------------------------
// Springs. Each slot opens a spring every CS_P ticks somewhere new on the rim.

struct CsSpring {
    int2  S;
    int   rho;      // its ring, two to four blocks back from the edge
    int   side;     // 0 east (+x), 1 north (+z), 2 west, 3 south
    int   along;    // its coordinate along that side
    float tau;      // ticks since it opened
};

static inline CsSpring csSpring(int j, float tick, int slots, int R, float seed) {
    CsSpring s;
    float off = (float(j) / float(slots) + seed * 7.0) * CS_P;
    float e = floor((tick + off) / CS_P);
    s.tau = tick + off - e * CS_P;
    float2 key = float2(e * 1.37 + float(j) * 17.1, seed * 113.0 + float(j) * 3.3);
    float h1 = hash21(key), h2 = hash21(key + 31.7), h3 = hash21(key * 1.71 + 5.3);
    int side = int(h1 * 3.999);
    int along = int(round((h2 * 2.0 - 1.0) * float(R - 9)));
    s.side = side;
    s.along = along;
    s.rho = R + 2 + int(h3 * 2.999);
    s.S = side == 0 ? int2(s.rho, along) : side == 1 ? int2(along, s.rho)
        : side == 2 ? int2(-s.rho, along) : int2(along, -s.rho);
    return s;
}

// Flow distance from the nearest cell this spring's water starts from on
// terrace k: the spring itself on the plain, else where it lands below a
// ledge. CS_DRY if its water never reaches this cell.
//
// The plain's spill along the edge is the cells of the diamond that reach it
// with a level to spare: the spring's own coordinate along that side, give or
// take r = 6 - (blocks from the spring to the edge). Below that, a ledge's
// drop is always nearer straight ahead than sideways, so water runs straight
// for the next edge and strays sideways by CS_SPREAD; it falls straight down,
// so the coordinate along the side carries through and the stream widens by
// CS_SPREAD a ledge. A stream that reaches a corner of the pit hugs it.
static inline int csLevelDist(int2 c, int ring, CsTer t, CsSpring sp, int R) {
    if (t.k == 0) return abs(c.x - sp.S.x) + abs(c.y - sp.S.y);
    int nrm = sp.side == 0 ? c.x : (sp.side == 1 ? c.y : (sp.side == 2 ? -c.x : -c.y));
    if (nrm != ring) return CS_DRY;                 // not on the spring's side
    int uc = (sp.side & 1) == 0 ? c.y : c.x;
    int b = t.aUp - 1;                              // the ring water lands on
    int hw = 6 - (sp.rho - R) + (t.k - 1) * CS_SPREAD;
    int lo = clamp(sp.along - hw, -b, b), hi = clamp(sp.along + hw, -b, b);
    int lateral = max(0, max(lo - uc, uc - hi));
    return lateral > CS_SPREAD ? CS_DRY : (b - ring) + lateral;
}

struct CsWater {
    float lo, hi;   // the wet span of this column
    float foam;     // a fall is landing here
    float fall;     // falling water occupies this column
    float flow;     // 1 while the cell carries moving water
    float lvl;      // its level, 1 (nearly spent) .. 8 (full)
};

constant int CS_SLOTS = 4;

static inline CsWater csWaterAt(int2 c, int ring, CsTer t, thread const CsPit& p,
                                float tick, int slots, float seed) {
    CsWater w;
    w.lo = 1e9; w.hi = -1e9; w.foam = 0.0; w.fall = 0.0; w.flow = 0.0; w.lvl = 0.0;
    int k = t.k;
    float Hk = t.H;
    if (k == CS_K + 1) { w.lo = Hk - 3.0; w.hi = Hk + 8.0 / 9.0; w.lvl = 8.0; }
    bool lip = k >= 1 && ring == t.aUp - 1;
    float topH = lip ? t.Hup : Hk;
    for (int j = 0; j < CS_SLOTS; ++j) {
        if (j >= slots) break;
        CsSpring sp = csSpring(j, tick, slots, csA(p, 0), seed);
        if (sp.tau > CS_D + CS_TAIL) continue;
        float man = float(abs(c.x - sp.S.x) + abs(c.y - sp.S.y));
        if (sp.tau < man - topH) continue;      // nothing has reached this column yet
        int d = csLevelDist(c, ring, t, sp, csA(p, 0));
        if (d > 7) continue;
        float arrive = man - Hk;
        if (k >= 1 && d == 1 && sp.tau >= arrive && sp.tau < CS_D + arrive) w.foam = 1.0;
        if (k <= CS_K && sp.tau >= arrive) {
            float n = 8.0 - float(d);
            float dry = sp.tau - (CS_D + arrive);
            if (dry >= 0.0) n -= floor(dry) + 1.0;
            if (n >= 1.0) {
                w.lo = min(w.lo, Hk);
                w.hi = max(w.hi, Hk + n / 9.0);
                w.flow = 1.0;
                w.lvl = max(w.lvl, n);
            }
        }
        if (lip && d == 0) {
            // A falling column: block y is wet from tick man - y until the
            // spring closes plus the same, so it fills top down and empties
            // top down.
            float yf = max(Hk, ceil(man - sp.tau));
            float yd = ceil(man - (sp.tau - CS_D));
            float yTop = min(topH, yd - 1.0);
            if (yTop >= yf) {
                w.lo = min(w.lo, yf);
                w.hi = max(w.hi, yTop >= topH ? topH + 8.0 / 9.0 : yTop + 1.0);
                w.fall = 1.0;
                w.lvl = 8.0;
            }
        }
    }
    return w;
}

// ---------------------------------------------------------------------------
// Textures: 16x16 texels a face, procedural. Values are sRGB.

constant int M_GRASS = 0, M_GSIDE = 1, M_DIRT = 2, M_STONE = 3, M_ANDES = 4,
             M_GRAN = 5, M_DIOR = 6, M_DEEP = 7, M_GRAVEL = 8, M_SAND = 9,
             M_TUFF = 10;

constant float3 CS_ORE[7] = {
    float3(0.16, 0.15, 0.15),   // coal
    float3(0.85, 0.66, 0.52),   // iron
    float3(0.80, 0.48, 0.32),   // copper
    float3(0.98, 0.84, 0.30),   // gold
    float3(0.86, 0.12, 0.10),   // redstone
    float3(0.22, 0.34, 0.82),   // lapis
    float3(0.46, 0.92, 0.86)    // diamond
};

static inline float3 csMatBase(int m) {
    switch (m) {
        case M_GRASS:  return float3(0.29, 0.46, 0.18);
        case M_GSIDE:  return float3(0.50, 0.40, 0.27);
        case M_DIRT:   return float3(0.53, 0.38, 0.26);
        case M_ANDES:  return float3(0.64, 0.64, 0.62);
        case M_GRAN:   return float3(0.64, 0.43, 0.35);
        case M_DIOR:   return float3(0.74, 0.74, 0.74);
        case M_DEEP:   return float3(0.29, 0.29, 0.33);
        case M_GRAVEL: return float3(0.50, 0.47, 0.45);
        case M_SAND:   return float3(0.86, 0.80, 0.60);
        case M_TUFF:   return float3(0.42, 0.44, 0.33);
        default:       return float3(0.46, 0.46, 0.47);
    }
}

static inline float3 csTexel(int m, int2 t, int ore) {
    t &= 15;
    float2 tf = float2(t);
    float h = hash21(tf * 1.013 + float(m) * 17.31 + 0.5);
    float n = valueNoise(tf * 0.43 + float(m) * 5.7);
    float3 base = csMatBase(m);
    float v;
    switch (m) {
        case M_GRASS:
            v = 0.80 + 0.11 * floor(h * 4.0) + 0.12 * (n - 0.5);
            return base * v;
        case M_GSIDE: {
            float hc = hash11(tf.x * 0.731 + 3.0);
            bool green = t.y < 3 || (t.y == 3 && hc > 0.4) || (t.y == 4 && hc > 0.85);
            v = 0.82 + 0.1 * floor(h * 4.0);
            if (green) return float3(0.29, 0.46, 0.18) * v;
            return float3(0.53, 0.38, 0.26) * (h < 0.12 ? 0.72 : (h > 0.93 ? 1.18 : v));
        }
        case M_DIRT:
            v = 0.84 + 0.1 * floor(h * 3.0);
            return base * (h < 0.12 ? 0.72 : (h > 0.93 ? 1.18 : v));
        case M_DEEP: {
            float s = valueNoise(float2(tf.x * 0.35, tf.y * 1.3) + 2.0);
            v = 0.78 + 0.14 * floor(s * 3.0) + 0.06 * h;
            return base * v;
        }
        case M_GRAVEL: {
            float g = valueNoise(tf * 0.7 + 11.0);
            v = 0.68 + 0.16 * floor(g * 4.0);
            return base * v * (0.94 + 0.12 * h);
        }
        case M_SAND:
            return base * (0.9 + 0.05 * floor(h * 4.0));
        case M_ANDES: case M_GRAN: case M_DIOR: case M_TUFF:
            v = 0.86 + 0.1 * floor(n * 3.0);
            return base * (h < 0.14 ? 0.7 : (h > 0.9 ? 1.15 : v));
        default: {   // stone, maybe with an ore
            v = 0.84 + 0.08 * floor(n * 4.0) + 0.05 * h;
            float3 c = base * v;
            if (ore > 0) {
                float o = valueNoise(tf * 0.62 + float(ore) * 9.1 + 1.7);
                float o2 = hash21(tf * 0.71 + float(ore));
                if (o > 0.6 && o2 > 0.25) c = CS_ORE[ore - 1] * (o2 > 0.7 ? 1.12 : 0.88);
            }
            return c;
        }
    }
}

// Crisp texels near the eye, a calm average far away: four texels blended
// only across a pixel-wide band at each texel edge, then faded to the
// material's mean as texels shrink under a pixel.
static inline float3 csTexture(int m, int ore, float2 uv, float fw) {
    float2 st = uv * 16.0 - 0.5;
    float2 i = floor(st);
    float2 f = st - i;
    float ft = max(fw * 16.0, 1e-3);
    float2 g = saturate((f - 0.5) / ft + 0.5);
    int2 ii = int2(i);
    float3 avg = csMatBase(m) * (m == M_GSIDE ? 1.0 : 0.95);
    float far = smoothstep(0.7, 2.5, ft);
    if (far >= 1.0) return avg;
    float3 c;
    if ((g.x <= 0.0 || g.x >= 1.0) && (g.y <= 0.0 || g.y >= 1.0)) {
        // Well inside one texel: the common case up close.
        c = csTexel(m, ii + int2(g >= 1.0), ore);
    } else {
        float3 c00 = csTexel(m, ii, ore), c10 = csTexel(m, ii + int2(1, 0), ore);
        float3 c01 = csTexel(m, ii + int2(0, 1), ore), c11 = csTexel(m, ii + int2(1, 1), ore);
        c = mix(mix(c00, c10, g.x), mix(c01, c11, g.x), g.y);
    }
    return mix(c, avg, far);
}

// Which block it is. The quarry is cut through strata: a skin of dirt under
// the grass, then beds of rock two or three blocks thick that run level all
// round the pit, so each wall shows its own bands, and deep slate at the
// bottom. A bed's edge wanders a block here and there; ores are rare
// accents. Sand and gravel line the pool.
constant int CS_BEDS[6] = { M_STONE, M_ANDES, M_GRAN, M_STONE, M_TUFF, M_ANDES };

static inline int csBlockMat(int3 b, bool topmost, bool topFace, int k, float sk, thread int& ore) {
    ore = 0;
    float2 bz = float2(b.xz) + sk;
    float hj = hash21(bz * 0.913 + 4.1);
    if (k == CS_K + 1 && topmost) return valueNoise(bz * 0.37) > 0.5 ? M_SAND : M_GRAVEL;
    // Bed edges wander on the walls; a ledge's floor stays one rock.
    float depth = -float(b.y) - 1.0 + (topFace ? 0.0 : (hj > 0.78 ? 1.0 : (hj < 0.12 ? -1.0 : 0.0)));
    if (depth < 3.0 || (topmost && depth < 4.5)) {
        if (topmost) return topFace ? M_GRASS : M_GSIDE;
        return M_DIRT;
    }
    float hb = hash21(float2(float(b.x) * 1.31 + float(b.y) * 7.13, float(b.z) * 1.73 - float(b.y) * 3.37) + sk);
    bool deep = depth >= 12.0;
    if (hb < 0.018) {
        float ho = hash11(hb * 431.0 + 0.3);
        ore = deep ? 4 + int(ho * 3.999) : 1 + int(ho * 3.999);   // deep: the rarer ores
        return M_STONE;
    }
    if (deep) return M_DEEP;
    float phase = floor(hash11(sk * 0.173 + 0.7) * 6.0);
    int bed = int(floor((depth - 3.0) / 2.5) + phase) % 6;
    return CS_BEDS[bed];
}

// ---------------------------------------------------------------------------
// Light.

// A low sun: warm along the horizon on its side, deep blue overhead.
static inline float3 csSky(float3 rd, float3 L) {
    float y = max(rd.y, 0.0);
    float toward = saturate(dot(normalize(rd.xz + 1e-5), normalize(L.xz + 1e-5)) * 0.5 + 0.5);
    float3 horizon = mix(float3(0.30, 0.26, 0.34), float3(0.95, 0.52, 0.28), toward * toward);
    float3 c = mix(horizon, float3(0.04, 0.07, 0.18), pow(y, 0.45));
    float s = max(dot(rd, L), 0.0);
    c += float3(1.0, 0.6, 0.3) * (0.35 * pow(s, 6.0) + 3.0 * pow(s, 1200.0));
    return c;
}

static inline float3 csFog(float3 rd, float3 L) {
    float toward = saturate(dot(normalize(rd.xz + 1e-5), normalize(L.xz + 1e-5)) * 0.5 + 0.5);
    return mix(float3(0.20, 0.19, 0.26), float3(0.62, 0.38, 0.24), toward * toward);
}

// Sun shadow: each terrace's ground is everything outside a square box below
// its floor, so the ray is blocked when it leaves a box below that floor.
static inline float csShadow(float3 P, float3 L, thread const CsPit& p) {
    float s = 1.0;
    float2 Ls = select(L.xz, float2(1e-5), abs(L.xz) < 1e-5);
    #pragma unroll
    for (int k = 0; k <= CS_K; ++k) {
        float h = float(csA(p, k)) - 0.5;
        if (max(abs(P.x), abs(P.z)) >= h - 1e-4) continue;
        float2 te2 = (sign(Ls) * h - P.xz) / Ls;
        float te = min(te2.x, te2.y);
        float y = P.y + L.y * te;
        s = min(s, saturate((y - csHt(p, k)) / (0.03 * te + 0.03) + 0.5));
    }
    return s;
}

static inline float csAoF(float d) { return 0.55 + 0.45 * saturate(d); }

// Smooth-lit corners: floors darken against the wall behind them, walls
// against the floor below and into the pit's inside corners.
static inline float csAO(float3 P, float3 n, CsTer t) {
    if (n.y > 0.5) {
        if (t.k < 1) return 1.0;
        float wall = float(t.aUp) - 0.5;
        return csAoF(wall - abs(P.x)) * csAoF(wall - abs(P.z));
    }
    if (t.k > CS_K) return 1.0;
    float wall = float(t.a) - 0.5;
    float along = abs(n.x) > 0.5 ? abs(P.z) : abs(P.x);
    return csAoF(P.y - t.Hdn) * csAoF(wall - along);
}

static inline float3 csLinear(float3 c) { return c * c; }

static inline float3 csLight(float3 alb, float3 P, float3 n, float ao, float3 L,
                             thread const CsPit& p, float shadowIn) {
    float face = n.y > 0.5 ? 1.0 : (n.y < -0.5 ? 0.5 : (abs(n.x) > 0.5 ? 0.62 : 0.8));
    float sky = mix(0.35, 1.0, saturate(1.0 + P.y / 14.0));   // less sky down the pit
    float sun = max(dot(n, L), 0.0) * shadowIn;
    float3 amb = float3(0.10, 0.14, 0.27) * face * ao * sky;
    float3 dir = float3(1.0, 0.6, 0.34) * 2.4 * sun * mix(0.85, 1.0, ao);
    return alb * (amb + dir);
}

// ---------------------------------------------------------------------------

static inline float3 csSurface(float3 P, float3 n, int2 cell, CsTer t, bool topmost, float fw,
                               float3 L, thread const CsPit& p, float sk) {
    int3 b;
    b.xz = cell;
    b.y = n.y > 0.5 ? int(round(P.y)) - 1 : int(floor(P.y));
    bool topFace = n.y > 0.5;
    int k = t.k;
    bool top = topmost || (!topFace && b.y == int(round(t.ground)) - 1);
    int ore;
    int m = csBlockMat(b, top, topFace, k, sk, ore);
    float2 uv;
    if (topFace) {
        uv = fract(P.xz + 0.5);
        // Ground tops turn a random quarter per block, as builders' worlds do.
        int rot = int(hash21(float2(cell) * 0.77 + sk) * 3.999);
        if (rot == 1) uv = float2(1.0 - uv.y, uv.x);
        else if (rot == 2) uv = 1.0 - uv;
        else if (rot == 3) uv = float2(uv.y, 1.0 - uv.x);
    } else {
        float s = abs(n.x) > 0.5 ? P.z : P.x;
        uv = float2(fract(s + 0.5), 1.0 - fract(P.y));
    }
    float3 alb = csLinear(csTexture(m, ore, uv, fw));
    if (m == M_GRASS) {
        // Meadow variation at the scale of blocks, which survives distance.
        float2 bc = float2(cell) + sk;
        float v = valueNoise(bc * 0.11) * 0.6 + valueNoise(bc * 0.37 + 5.0) * 0.4;
        alb *= mix(float3(0.72, 0.78, 0.62), float3(1.12, 1.08, 0.86), v) * (0.93 + 0.12 * hash21(bc * 1.7));
    }
    float ao = csAO(P, n, t);
    float sh = dot(n, L) > 0.0 ? csShadow(P + n * 0.002, L, p) : 0.0;
    return csLight(alb, P, n, ao, L, p, sh);
}

// First hit of a ray (going down) with the pit's nested boxes: terrace k is
// everything outside a square of half-size a[k] - 0.5 - shrink, up to height
// H[k] + lift. shrink = lift = 0 is the ground itself; shrink = lift = 1 is
// the shell water can occupy (a block above every floor, and the lip column
// in front of every wall up to the ledge above it).
static inline float csNested(float3 ro, float3 rd, float2 inv, thread const CsPit& p,
                             float shrink, float lift, thread float3& n) {
    float best = 1e9;
    n = float3(0.0, 1.0, 0.0);
    #pragma unroll
    for (int k = 0; k <= CS_K + 1; ++k) {
        float h = float(csA(p, k)) - 0.5 - shrink;
        float Hk = csHt(p, k) + lift - (k == CS_K + 1 && lift == 0.0 ? 3.0 : 0.0);
        float th = (Hk - ro.y) / rd.y;
        float cand = th;
        float3 nc = float3(0.0, 1.0, 0.0);
        if (h > 0.0) {
            float2 t1 = (-h - ro.xz) * inv, t2 = (h - ro.xz) * inv;
            float2 mn = min(t1, t2), mx = max(t1, t2);
            float tn = max(mn.x, mn.y), tf = min(mx.x, mx.y);
            if (tn <= tf && th >= tn && th <= tf) {
                cand = tf;
                nc = mx.x < mx.y ? float3(-sign(rd.x), 0.0, 0.0) : float3(0.0, 0.0, -sign(rd.z));
            }
        }
        if (cand < best) { best = cand; n = nc; }
    }
    return best;
}

// Lanes of brighter water two texels wide, dashes in each running along the
// flow a texel at a time. `across` and `along` are in blocks.
static inline float csStreak(float across, float along, float scroll, float fw) {
    float lane = floor(across * 8.0);
    float ph = hash11(lane * 0.37 + 1.3);
    float per = 5.0 + floor(ph * 6.0);
    float v = glmod(floor(along * 16.0 - scroll + ph * 37.0), per);
    float sv = v < 1.0 ? 1.0 : (v < 2.0 ? 0.45 : 0.0);
    return mix(sv, 1.45 / per, smoothstep(0.35, 1.2, fw * 8.0));
}

// Churned white water, boiling a texel at a time.
static inline float csFoam(float2 uv, float time, float fw) {
    float2 tt = floor(uv * 16.0);
    float fr = floor(time * 9.0);
    float f = hash21(tt + fr * 0.731) * 0.6 + hash21(floor(uv * 8.0) + fr * 0.317) * 0.4;
    return mix(smoothstep(0.42, 0.55, f), 0.55, smoothstep(0.5, 1.6, fw * 16.0));
}

static inline float3 csWaterShade(float3 behind, float3 ro, float3 rd, float tW, float3 nW, CsWater w,
                                  int2 cW, float tHit, float pxA, float time, float3 L,
                                  thread const CsPit& p) {
    float3 Pw = ro + rd * tW;
    float cosv = max(abs(dot(rd, nW)), 0.05);
    float fw = tW * pxA / cosv;
    float sh = csShadow(Pw + float3(0.0, 0.01, 0.0), L, p);
    bool top = nW.y > 0.5;
    bool sheet = w.fall > 0.0 && !top;
    float3 sunC = float3(1.0, 0.6, 0.34) * 2.4;
    float3 ambC = float3(0.10, 0.14, 0.27);
    float lit = max(dot(nW, L), 0.0) * sh;
    float3 light = ambC * mix(0.45, 1.0, saturate(1.0 + Pw.y / 14.0)) + sunC * (top ? lit : 0.6 * lit + 0.12);

    // How much water the eye looks through: shallow steps show the stone
    // under them, the pool and a full channel go deep blue.
    float path = top ? (w.hi - max(w.lo, Pw.y - 9.0)) / cosv : (sheet ? 0.5 : 0.3);
    path = min(path, 6.0);
    float3 T = exp(-path * float3(2.6, 1.05, 0.55));
    float3 body = float3(0.02, 0.13, 0.42);
    float a = max(1.0 - exp(-path * 1.6), sheet ? 0.6 : 0.42);
    float3 c = mix(behind * T, body * light, a);

    float3 pale = float3(0.30, 0.58, 0.92);
    float2 local = fract(Pw.xz + 0.5);
    if (top) {
        // Streaks travel the way the water goes: in, toward the pit.
        bool alongX = abs(cW.x) >= abs(cW.y);
        float sgn = alongX ? -sign(float(cW.x)) : -sign(float(cW.y));
        float along = (alongX ? Pw.x : Pw.z) * sgn, across = alongX ? Pw.z : Pw.x;
        float st = csStreak(across, along, floor(time * 10.0) * w.flow, fw);
        c += pale * light * st * (w.flow > 0.0 ? 0.16 : 0.05);
        // A level nearly spent is a thin pale film.
        float thin = saturate((3.5 - w.lvl) / 2.5);
        c = mix(c, pale * light * 0.6, thin * 0.3);
        if (w.foam > 0.0) c = mix(c, float3(0.9, 0.95, 1.0) * light * 0.75, 0.85 * csFoam(local, time, fw));
    } else if (sheet) {
        // A falling sheet: pale streaks pouring down, white where it lands.
        float acr = abs(nW.x) > 0.5 ? Pw.z : Pw.x;
        float st = csStreak(acr + 0.5, -Pw.y, floor(time * 14.0), fw);
        c += pale * light * st * 0.28;
        float base = 1.0 - smoothstep(0.0, 1.1, Pw.y - w.lo);
        float2 fuv = float2(fract(acr + 0.5), fract(Pw.y));
        c = mix(c, float3(0.9, 0.95, 1.0) * light * 0.7, base * csFoam(fuv, time, fw));
    } else {
        // The little face where one level steps down to the next.
        c = mix(c, pale * light * 0.55, 0.3);
    }

    // The sky on the surface, and the sun's glint.
    float fres = 0.03 + 0.97 * pow(1.0 - cosv, 5.0);
    float3 R = reflect(rd, nW);
    float3 refl = csSky(R, L) * (top ? 1.0 : 0.4);
    c = mix(c, refl, fres * (top ? 0.9 : 0.4));
    if (top) c += float3(1.0, 0.7, 0.45) * pow(max(dot(R, L), 0.0), 220.0) * sh * 2.5;
    return c;
}

static inline float3 csScene(float3 ro, float3 rd, float pxA, thread const CsPit& p,
                             float tick, int slots, float seed, float time, float3 L) {
    float3 sky = csSky(rd, L);
    if (rd.y > -1e-4) return sky;

    float sk = floor(seed * 997.0);
    int R = csA(p, 0);
    float2 inv = 1.0 / select(rd.xz, float2(1e-6), abs(rd.xz) < 1e-6);
    float3 inv3 = 1.0 / select(rd, float3(1e-6), abs(rd) < 1e-6);

    // The ground: exact, in one pass over the terraces.
    float3 nHit;
    float tHit = csNested(ro, rd, inv, p, 0.0, 0.0, nHit);

    float3 Ph = ro + rd * tHit;
    int2 cHit = int2(floor(Ph.xz - nHit.xz * 0.5 + 0.5));
    CsTer tHitT = csTer(max(abs(cHit.x), abs(cHit.y)), p);
    bool topmost = nHit.y > 0.5;

    // Water: walk the cells between entering the shell water can occupy
    // and the ground, testing only those the ray is low enough in.
    bool wet = false;
    float tW = 0.0;
    float3 nW = float3(0.0, 1.0, 0.0);
    CsWater wW;
    int2 cW = int2(0);
    float3 nShell;
    float tShell = csNested(ro, rd, inv, p, 1.0, 1.0, nShell);
    if (tShell < tHit) {
        float3 P0 = ro + rd * tShell;
        float2 q = P0.xz + 0.5;
        int2 cell = int2(floor(q));
        int2 stp = int2(rd.x > 0.0 ? 1 : -1, rd.z > 0.0 ? 1 : -1);
        float2 tDelta = abs(inv);
        float2 tMax = tShell + (float2(cell) + select(float2(0.0), float2(1.0), rd.xz > 0.0) - q) * inv;
        float tIn = tShell;
        float3 nSide = nShell;
        for (int i = 0; i < CS_WSTEPS; ++i) {
            float tOut = min(tMax.x, tMax.y);
            float yOut = ro.y + rd.y * min(tOut, tHit);
            int ring = max(abs(cell.x), abs(cell.y));
            CsTer t = csTer(ring, p);
            bool lip = t.k >= 1 && ring == t.aUp - 1;
            float band = (lip ? t.Hup : t.H) + 1.0;
            if (yOut < band) {
                CsWater w = csWaterAt(cell, ring, t, p, tick, slots, seed);
                if (w.hi > w.lo) {
                    float te = (w.hi - ro.y) / rd.y, tx = (w.lo - ro.y) / rd.y;
                    float tw = max(tIn, te);
                    if (tw < min(min(tOut, tx), tHit)) {
                        wet = true; tW = tw; wW = w; cW = cell;
                        nW = te >= tIn ? float3(0.0, 1.0, 0.0) : nSide;
                        break;
                    }
                }
            }
            if (tOut >= tHit) break;
            if (tMax.x < tMax.y) { tIn = tMax.x; tMax.x += tDelta.x; cell.x += stp.x; nSide = float3(-float(stp.x), 0.0, 0.0); }
            else                 { tIn = tMax.y; tMax.y += tDelta.y; cell.y += stp.y; nSide = float3(0.0, 0.0, -float(stp.y)); }
        }
    }
    float3 P = ro + rd * tHit;
    float fw = tHit * pxA / max(abs(dot(rd, nHit)), 0.08);
    float3 col = csSurface(P, nHit, cHit, tHitT, topmost, fw, L, p, sk);

    if (wet) col = csWaterShade(col, ro, rd, tW, nW, wW, cW, tHit, pxA, time, L, p);
    if (wet) tHit = tW;

    // A short view distance that fades into haze.
    float fog = 1.0 - exp(-max(tHit - 60.0, 0.0) * 0.022);
    return mix(col, csFog(rd, L), fog);
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    CsPit pit = csPit(u.seed);
    float R = float(pit.a0.x);
    int slots = clamp(u.springs, 1, 4);
    float tick = u.time * u.speed / CS_TICK;

    float az = u.seed * TWO_PI + u.time * 0.011;
    float el = 0.82 + 0.04 * sin(u.time * 0.017 + u.seed * 9.0);
    float3 pivot = float3(0.0, pit.H1.y * 0.6, 0.0);
    // Frame the whole pit: a narrow screen stands further back.
    float dist = 1.42 * R * clamp(1.6 * u.resolution.y / u.resolution.x, 1.0, 1.5);
    float3 ro = pivot + dist * float3(cos(el) * cos(az), sin(el), cos(el) * sin(az));
    float3 upHint = float3(0.0, 1.0, 0.0);
    float3 fwd = normalize(pivot - ro);
    float3 right = normalize(cross(fwd, upHint));
    lerpOrbit(u.yaw, u.pitch, u.magnify, pivot, upHint, ro, right, fwd);
    float3 up = cross(right, fwd);

    float sa = u.seed * 5.1 + 1.3;
    float se = u.sun;
    float3 L = normalize(float3(cos(sa) * cos(se), sin(se), sin(sa) * cos(se)));

    float minRes = min(u.resolution.x, u.resolution.y);
    float pxA = 2.0 / (minRes * CS_FOCAL);
    float2 uv = lerpUV(pos, u.resolution);
    float3 rd = normalize(uv.x * right + uv.y * up + CS_FOCAL * fwd);

    float3 col = csScene(ro, rd, pxA, pit, tick, slots, u.seed, u.time, L);
    col = col / (1.0 + col * 0.25);
    col = pow(max(col, 0.0), 1.0 / 2.2);
    col = lerpDither(col, pos);
    return half4(half3(col), 1.0h);
}
