// Cascade — water stepping down a terraced quarry.
// Lerping@Home, drawn with Minecraft's own textures (lerp-requires below).
//
// lerp-category: Minecraft
// lerp-requires: minecraft mobs
//
// A square quarry is cut into a plains meadow in terraces: grass and dirt at
// the rim, then stone with its pockets of granite, diorite, andesite, gravel
// and ore, then deepslate. Springs (water source blocks) open on the grass
// near the rim one after another. Water from a spring spreads over the ground
// a block per tick and a level lower with each block (eight levels, so a
// spring's pool is a stepped diamond). Where the diamond reaches the edge with
// a level to spare it pours over as a column of falling water, falls a block
// per tick, lands at full strength and runs for the next edge, stepping down a
// level a block and widening by one each ledge, until it drops into the pool
// at the bottom. When the spring closes the water drains the way it came, top
// first, each block thinning a level a tick before it goes. Oaks, short grass
// and flowers stand on the meadow; water washes the plants off while it runs.
// A little herd of sheep, cows, pigs or chickens grazes along each side,
// ambling somewhere new now and then, out of the way of the water.
//
// It is all closed form, with no step of the flow stored: a cell's level is
// how far it sits from where its stream landed on that ledge, and its
// arrival tick is its plan distance from the spring plus the height fallen.
// The ground is hit exactly (each terrace is everything outside a square
// below its floor), and only the last few cells before the ground are walked
// looking for water, the last few above it for plants, and the 7-block
// squares under the treetops for an oak (one at most in each).
//
// Drawn the way the game draws it: still water on sources and the pool, the
// flowing texture turned along the flow on running water and pouring down
// the falls, all of it tinted and translucent; fixed face shading and
// smooth-lit corners; skylight losing a level a block under water and under
// leaves; the lightmap dimming with the time of day; sky, fog and sunset
// glow; the square sun and the flat cloud layer. Cost is the water walk
// (CS_WSTEPS cells asked, each asking every spring slot, among CS_WCELLS stepped) plus at most CS_TSQ tree
// squares, each oak walked by the kit's mcTree (MC_TREE_STEPS blocks at most), CS_NHERD herd boxes and, inside one, up to
// CS_HERD animals each, and CS_PSTEPS plant cells; every texture is
// read once at the surface found, except a leaf face's alpha, which decides
// whether the ray goes on through the canopy.
//
// lerp-param: speed   float 0.5 3   = 1    "Flow speed"
// lerp-param: springs int   1 4     = 3    "Springs"
// lerp-param: sun     float 0.05 0.9 = 0.3  "Sun height"
// lerp-animate: sun 0.2 0.4 period=300
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
constant int   CS_WSTEPS = 12;    // cells a ray asks for water, bounded
constant int   CS_WCELLS = 40;    // cells it may step through to find them (cheap: over the
                                  // pit's air a tilted ray crosses many before it is low enough)
constant int   CS_DRY   = 99;
constant int   CS_SPREAD = 1;     // blocks a stream widens per ledge
constant int   CS_TG    = 7;       // one oak at most in each 7x7 square of the meadow
constant float CS_TREE_P = 0.45;   // the chance a square has one
constant float CS_TREE_Y = 7.0;    // no treetop is higher
constant int   CS_TSQ   = 16;      // tree squares a ray walks, bounded (the steep default view crosses 3 or 4)
constant int   CS_PSTEPS = 4;      // meadow cells a ray walks for plants, bounded
constant float CS_CLOUD_Y = 120.0; // the cloud layer, blocks above the meadow
constant float CS_FOG0  = 72.0;    // linear fog, as the game's render distance
constant float CS_FOG1  = 128.0;

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
    float  lo, hi;  // the wet span of this column
    float  fall;    // falling water occupies this column
    float  lvl;     // its level, 1 (nearly spent) .. 8 (full)
    float2 dir;     // the way its surface runs; zero on a source block
};

constant int CS_SLOTS = 4;

static inline CsWater csWaterAt(int2 c, int ring, CsTer t, thread const CsPit& p,
                                float tick, int slots, float seed) {
    CsWater w;
    w.lo = 1e9; w.hi = -1e9; w.fall = 0.0; w.lvl = 0.0; w.dir = float2(0.0);
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
        // On the meadow water runs away from its spring (diagonally off the
        // diamond's axes, as the game's flow vector does); below, into the pit.
        float2 inward = sp.side == 0 ? float2(-1.0, 0.0) : sp.side == 1 ? float2(0.0, -1.0)
                      : sp.side == 2 ? float2(1.0, 0.0) : float2(0.0, 1.0);
        float2 dir = k == 0 ? float2(sign(float(c.x - sp.S.x)), sign(float(c.y - sp.S.y))) : inward;
        if (k <= CS_K && sp.tau >= arrive) {
            float n = 8.0 - float(d);
            float dry = sp.tau - (CS_D + arrive);
            if (dry >= 0.0) n -= floor(dry) + 1.0;
            if (n >= 1.0) {
                w.lo = min(w.lo, Hk);
                w.hi = max(w.hi, Hk + n / 9.0);
                if (n > w.lvl) { w.lvl = n; w.dir = dir; }
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
                w.dir = inward;
            }
        }
    }
    return w;
}

// ---------------------------------------------------------------------------
// The rock. Below a skin of dirt under the grass, stone, with pockets of the
// game's other stones and veins of its ores, then deepslate under a ragged
// line, as the game lays them. Sand and gravel line the pool.

// One pocket in each 3D cell of `size` blocks, at a jittered centre: its hash
// in [0, 1) when block b is inside it, else -1.
static inline float csPocket(int3 b, float size, float chance, float salt) {
    float3 q = (float3(b) + 0.5) / size + salt;
    float3 ci = floor(q);
    float h0 = hash21(ci.xz + ci.y * float2(17.13, 31.71) + salt);
    if (h0 >= chance) return -1.0;
    float h1 = hash21(ci.zx * 1.37 + ci.y * float2(5.31, 2.17) + 3.1);
    float h2 = hash21(ci.xy * 0.71 + ci.z * float2(9.7, 4.3) + 7.7);
    float h3 = hash21(ci.yz * 1.91 + ci.x * float2(2.9, 6.1) + 1.3);
    float3 d = (q - (ci + 0.3 + 0.4 * float3(h1, h2, h3))) * float3(1.0, 1.3, 1.0);
    float r = 0.28 + 0.17 * h2;
    return dot(d, d) < r * r ? h0 / chance : -1.0;
}

// The block a face belongs to. kind: 0 its texture as is, 1 a grass top
// (grey, takes the biome tint), 2 a grass block's side.
static inline int csBlock(int3 b, bool topmost, bool topFace, int k, float sk, thread int& kind) {
    kind = 0;
    float2 bz = float2(b.xz) + sk;
    if (k == CS_K + 1 && topmost) return valueNoise(bz * 0.37) > 0.5 ? MC_SAND : MC_GRAVEL;
    float depth = -float(b.y) - 1.0;
    // A whole terrace is grass or not by its depth alone: exposed dirt near
    // the surface has long since grown grass.
    if (topmost && depth < 4.5) { kind = topFace ? 1 : 2; return MC_GRASS_BLOCK_TOP; }
    float soil = 3.0 + (hash21(bz * 0.913 + 4.1) > 0.55 ? 1.0 : 0.0);
    if (depth < soil) return MC_DIRT;
    float hd = hash21(float2(float(b.x) * 1.7 + float(b.y) * 3.1, float(b.z) * 1.3 - float(b.y) * 2.3) + sk);
    bool deep = depth >= 12.0 + floor(hd * 4.0);
    float ore = csPocket(b, 4.0, 0.15, sk * 0.031 + 0.5);
    if (ore >= 0.0) {
        if (deep) return ore < 0.22 ? MC_DEEPSLATE_IRON_ORE : ore < 0.45 ? MC_DEEPSLATE_REDSTONE_ORE
                       : ore < 0.6 ? MC_DEEPSLATE_GOLD_ORE : ore < 0.75 ? MC_DEEPSLATE_LAPIS_ORE
                       : ore < 0.88 ? MC_DEEPSLATE_DIAMOND_ORE : MC_DEEPSLATE_COAL_ORE;
        return ore < 0.42 ? MC_COAL_ORE : ore < 0.72 ? MC_IRON_ORE : ore < 0.9 ? MC_COPPER_ORE
             : ore < 0.95 ? MC_GOLD_ORE : MC_LAPIS_ORE;
    }
    float pk = csPocket(b, 8.0, 0.7, sk * 0.017 + 0.2);
    if (deep) return pk >= 0.0 && pk < 0.45 ? MC_TUFF : (topFace ? MC_DEEPSLATE_TOP : MC_DEEPSLATE);
    if (pk < 0.0) return MC_STONE;
    return pk < 0.27 ? MC_GRANITE : pk < 0.52 ? MC_DIORITE : pk < 0.78 ? MC_ANDESITE
         : pk < 0.9 ? MC_GRAVEL : MC_DIRT;
}

// ---------------------------------------------------------------------------
// The meadow: oaks, short grass and flowers.

struct CsTree { int2 c; bool ok; McTree m; };

static inline int csDistI(int v, int lo, int hi) { return max(0, max(lo - v, v - hi)); }

// An oak stands only where no spring's water can ever reach its trunk: more
// than the diamond's reach from every place a spring can open.
static inline CsTree csTreeIn(int2 g, float sk, int R) {
    CsTree t;
    float2 gf = float2(g) + sk * 0.37;
    float2 j = hash22(gf * 0.917 + 3.1);
    t.c = g * CS_TG + 2 + int2(j * 2.999);
    // The kit's oak, grown by the game's rule, its foot log on cell c.
    t.m = mcTreeGrow(MC_TREE_OAK, float3(float(t.c.x) - 0.5, 0.0, float(t.c.y) - 0.5), hash21(gf * 2.11 + 0.7) * 97.0);
    int m = R - 9, lo = R + 2, hi = R + 4;
    int reach = min(min(csDistI(t.c.x, lo, hi) + csDistI(t.c.y, -m, m),
                        csDistI(t.c.y, lo, hi) + csDistI(t.c.x, -m, m)),
                    min(csDistI(-t.c.x, lo, hi) + csDistI(t.c.y, -m, m),
                        csDistI(-t.c.y, lo, hi) + csDistI(t.c.x, -m, m)));
    t.ok = hash21(gf * 0.613 + 1.9) < CS_TREE_P && max(abs(t.c.x), abs(t.c.y)) >= R + 3 && reach > 8;
    return t;
}

static inline float2 csFaceUV(float3 P, float3 n) {
    if (abs(n.y) > 0.5) return fract(P.xz + 0.5);
    float s = abs(n.x) > 0.5 ? P.z : P.x;
    return float2(fract(s + 0.5), 1.0 - fract(P.y));
}

// Light levels the meadow loses in an oak's shade (the kit's rule).
static inline float csCanopyShade(float2 P, float sk, int R, thread float& ao) {
    CsTree tr = csTreeIn(int2(floor((P + 0.5) / float(CS_TG))), sk, R);
    return tr.ok ? mcTreeShade(tr.m, float3(P.x, 0.0, P.y), ao) : 0.0;
}

// ---------------------------------------------------------------------------
// The herds. Two herds graze along each side of the pit, between the rim and
// the edge of where water can run, which is the meadow the camera sees. Every
// CS_LEG seconds a herd picks somewhere new along its side: of CS_CAND spots, the
// first that stays well clear of every spring running during that leg (the
// spring footprints are as closed-form as the water), else the clearest. So a
// herd ambles off when a spring opens near it and comes back when it drains.
// Positions and poses are a pure function of time and seed.

constant float CS_LEG   = 16.0;   // seconds a herd stays at one spot, walking the first part
constant int   CS_NHERD = 8;      // two a side
constant int   CS_HERD  = 3;      // animals in a herd, at most
constant int   CS_CAND  = 6;      // spots a herd considers each leg

// Where the springs are during one leg: the spring each slot runs at its
// start and at its end (a spring runs longer than a leg, so one that wets
// the meadow during the leg is running at one of the two), or none.
struct CsLegSprings { int2 S[8]; bool on[8]; };

static inline CsLegSprings csLegSprings(float e, float off, float speed, float seed, int slots, int R) {
    CsLegSprings ls;
    #pragma unroll
    for (int j = 0; j < 8; ++j) {
        int jj = j & 3;
        float T = (e - off + float(j >> 2)) * CS_LEG * speed / CS_TICK;
        ls.on[j] = false; ls.S[j] = int2(0);
        if (jj < slots) {
            CsSpring sp = csSpring(jj, T, slots, R, seed);
            ls.on[j] = sp.tau <= CS_D + CS_TAIL;
            ls.S[j] = sp.S;
        }
    }
    return ls;
}

// Herd h's spot for leg e: on side h & 3, 1.8 to 2.4 blocks back from the
// rim, the strip of meadow the camera sees. Its animals spread along the side
// more than across it (0.4 across, and a cow reaches 1.22 from its feet, so
// none sets foot over the edge at ring R - 0.5).
static inline float2 csHerdSpot(int h, float e, thread const CsLegSprings& ls, float sk, int R, float2 cam) {
    int side = h & 3;
    float2 best = float2(0.0);
    float bestScore = -1e9;
    for (int k = 0; k < CS_CAND; ++k) {
        float2 hh = hash22(float2(e * 1.731 + float(k) * 0.37, float(h) * 5.13 + sk * 0.071));
        float along = (hh.x * 2.0 - 1.0) * float(R - 6);
        float out = float(R) + 1.8 + 0.6 * hh.y;
        float2 P = side == 0 ? float2(out, along) : side == 1 ? float2(along, out)
                 : side == 2 ? float2(-out, along) : float2(along, -out);
        float clear = 99.0;
        #pragma unroll
        for (int j = 0; j < 8; ++j)
            if (ls.on[j]) clear = min(clear, abs(P.x - float(ls.S[j].x)) + abs(P.y - float(ls.S[j].y)) - 7.0);
        // A herd drifts to the sides the camera can see: the strip under it,
        // on the near side, is out of frame.
        float score = min(clear, 5.0) - 0.01 * float(k) - 4.0 * saturate(dot(normalize(P), cam) - 0.25);
        if (score > bestScore) { bestScore = score; best = P; }
        if (score >= 4.9) break;
    }
    return best;
}

// What herd h is: 0 sheep, 1 cow, 2 pig, 3 chicken, and how many.
static inline int csHerdKind(int h, float sk, thread int& species) {
    float a = hash11(float(h) * 3.71 + sk * 0.137 + 0.4);
    species = a < 0.38 ? 0 : (a < 0.66 ? 1 : (a < 0.84 ? 2 : 3));
    return 2 + int(hash11(float(h) * 1.93 + sk * 0.211 + 7.7) * 1.999);
}

struct CsMob {
    int         type;
    float3      at;
    float       heading;   // 0 faces +z, pi/2 faces +x
    MCMOB_Pose  pose;
    MCMOB_Skin  skin;
};

// Animal i of herd h, which walks from spot a (last leg) to spot b (this
// one): each animal keeps its own place in the herd, starts a little after
// the others, grazes once there, then lifts its head and looks about.
static inline CsMob csMobAt(int h, int i, int species, float2 a, float2 b, float e, float f,
                            float time, float sk) {
    float2 along = (h & 1) == 0 ? float2(0.0, 1.0) : float2(1.0, 0.0);
    float2 across = float2(along.y, along.x);
    CsMob mb;
    float salt = float(i) * 7.31 + float(h) * 3.13 + sk * 0.29;
    bool baby = hash11(salt * 1.37 + 0.4) < 0.25;
    float hd = hash11(salt * 2.91 + 1.7);   // the game's natural fleeces
    float3 dye = mcFromSRGB(hd > 0.97 ? float3(0.514, 0.329, 0.196)       // brown
                          : hd > 0.92 ? float3(0.114, 0.114, 0.129)       // black
                          : hd > 0.87 ? float3(0.278, 0.310, 0.322)       // gray
                          : hd > 0.82 ? float3(0.616, 0.616, 0.592)       // light gray
                          : float3(0.976, 1.0, 0.996));                   // white
    if (species == 0) { mb.type = baby ? MCMOB_SHEEP_BABY : MCMOB_SHEEP; mb.skin = mcMobSheepSkin(baby, true, dye); }
    else if (species == 1) { mb.type = baby ? MCMOB_COW_BABY : MCMOB_COW;
                             mb.skin = mcMobSkin(baby ? MCS_COW_TEMPERATE_BABY : MCS_COW_TEMPERATE); }
    else if (species == 2) { mb.type = baby ? MCMOB_PIG_BABY : MCMOB_PIG;
                             mb.skin = mcMobSkin(baby ? MCS_PIG_TEMPERATE_BABY : MCS_PIG_TEMPERATE); }
    else { mb.type = baby ? MCMOB_CHICKEN_BABY : MCMOB_CHICKEN;
           mb.skin = mcMobSkin(baby ? MCS_CHICKEN_TEMPERATE_BABY : MCS_CHICKEN_TEMPERATE); }

    // Its place in the herd: a slot of a loose ring, shuffled each leg.
    float ang0 = (float(i) + hash11(salt + (e - 1.0) * 0.913)) * 2.0944;
    float ang1 = (float(i) + hash11(salt + e * 0.913)) * 2.0944;
    float2 p0 = a + along * (1.8 * cos(ang0)) + across * (0.4 * sin(ang0));
    float2 p1 = b + along * (1.8 * cos(ang1)) + across * (0.4 * sin(ang1));
    float start = 0.04 * float(i) + 0.05 * hash11(salt + e * 1.7);
    const float W = 0.3;                        // the share of a leg spent walking
    float u = saturate((f - start) / W);
    float s = smoothstep(0.0, 1.0, u);
    float2 d = p1 - p0;
    float len = length(d);
    mb.at = float3(mix(p0.x, p1.x, s), 0.0, mix(p0.y, p1.y, s));
    // It faces where it is going; a short hop just turns it a little.
    float2 dd = len > 0.3 ? d : float2(sin(salt), cos(salt));
    mb.heading = atan2(dd.x, dd.y);
    mb.pose = mcMobStill();
    mb.pose.walk = s * len * 4.0;
    mb.pose.speed = 0.5 * sin(3.14159265 * u) * step(0.0, f - start) * step(f, start + W);
    float g0 = start + W + 0.03;
    mb.pose.graze = smoothstep(g0, g0 + 0.06, f) * (1.0 - smoothstep(0.78, 0.85, f));
    mb.pose.yaw = 0.6 * sin(time * 0.45 + salt * 3.0) * smoothstep(0.82, 0.9, f);
    if (species == 3) mb.pose.graze *= step(0.45, fract(time * 1.3 + salt));   // chickens peck
    return mb;
}

// The plant on a meadow cell, if any: its tile, whether it takes the grass
// tint, and the game's random nudge off the cell's centre.
static inline int csPlant(int2 cell, float sk, thread bool& tinted, thread float2& off) {
    float2 cf = float2(cell) + sk * 0.71;
    float h = hash21(cf * 0.731 + 2.3);
    float meadow = valueNoise(cf * 0.13 + 4.0);
    off = (hash22(cf * 1.31 + 0.9) - 0.5) * 0.3;
    tinted = false;
    float g = 0.2 + 0.45 * meadow;
    if (h < g) { tinted = true; return MC_SHORT_GRASS; }
    if (h < g + 0.035) {
        float f = hash21(floor(cf / 5.0) + 9.1) * 0.6 + fract(h * 97.0) * 0.4;   // flowers grow in patches
        return f < 0.34 ? MC_DANDELION : f < 0.62 ? MC_POPPY : f < 0.74 ? MC_AZURE_BLUET
             : f < 0.86 ? MC_OXEYE_DAISY : MC_CORNFLOWER;
    }
    return -1;
}

// ---------------------------------------------------------------------------
// Light and sky, as the game makes them.

struct CsEnv {
    float3 L;          // toward the sun
    float  day;        // the lightmap's time of day, 1 at noon
    float3 sky, fog;   // sky and fog colours
    float4 sunrise;    // the sunset glow, rgb and strength
    float3 fogLook;    // the fog, warmed toward the sun by the camera's look
    float  bright;     // the sky's brightness
    float3 grass, foliage;
    float  time;
};

// Sky light alone: no block light in this look, Overworld ambient.
static inline float3 csLightmap(float level, thread const CsEnv& e) {
    return mcLightmap(0.0, level, e.day, 0.0);
}

// The time of day from the sun, by the kit: the lightmap and the sky colour
// dim by different curves of the sun's height, and the sunset glow.
static inline CsEnv csEnv(float3 L, float3 look, float time, texture2d_array<float> maps) {
    CsEnv e;
    e.L = L;
    e.time = time;
    e.day = mcLightDay(L.y);
    e.bright = mcSkyDay(L.y);
    e.sky = mcSkyAt(e.bright);
    e.fog = mcFogAt(e.bright);
    e.sunrise = mcSunsetAt(L.y);
    e.fogLook = mcFogToward(e.fog, e.sunrise, look, L);
    e.grass = mcGrassTint(maps, 0.8, 0.4);                  // plains
    e.foliage = mcFoliageTint(maps, 0.8, 0.4);
    return e;
}

static inline float3 csSky(float3 ro, float3 rd, float pxA, thread const CsEnv& e,
                           texture2d_array<float> skins, texture2d_array<float> maps) {
    float3 c = mix(e.fogLook, e.sky, smoothstep(0.0, 0.4, rd.y));
    // The sunset glow: the game's fan over the horizon under the sun.
    c = mix(c, e.sunrise.rgb, mcSunsetFan(rd, e.L, e.sunrise));
    // The sun: a 30-unit quad 100 away, added to the sky.
    float dl = dot(rd, e.L);
    if (dl > 0.0) {
        float3 e1 = normalize(cross(e.L, float3(0.0, 1.0, 0.0)));
        float3 e2 = cross(e1, e.L);
        float2 sp = float2(dot(rd, e1), dot(rd, e2)) / dl;
        if (max(abs(sp.x), abs(sp.y)) < 0.3)
            // Kept half a texel inside the 32 px picture, so the crisp blend
            // at the quad's edge never reaches the empty rest of its 64 px layer.
            c += mcSkin(skins, MCS_ENVIRONMENT_CELESTIAL_SUN,
                        clamp((sp / 0.3 * 0.5 + 0.5) * 32.0, 0.5, 31.5), pxA * 53.3).rgb;
    }
    // The flat cloud layer: a pixel of clouds.png is 12 blocks, drifting east.
    if (rd.y > 0.01 && ro.y < CS_CLOUD_Y) {
        float tc = (CS_CLOUD_Y - ro.y) / rd.y;
        float2 q = (ro.xz + rd.xz * tc + float2(e.time * 0.6, 0.0)) / 12.0;
        float4 cl = mcMap(maps, MCM_ENVIRONMENT_CLOUDS, glmod2(q, 256.0), tc * pxA / (rd.y * 12.0));
        float a = cl.a * 0.8 * (1.0 - smoothstep(CS_FOG1 * 2.0, CS_FOG1 * 8.0, tc));
        c = mix(c, float3(e.bright * 0.9 + 0.1), a);
    }
    return c;
}

// Smooth lighting: a face's corner beside a solid block takes 0.6 of the
// light, an inside corner about 0.4, blended across the face.
static inline float csAoF(float d) { return 0.6 + 0.4 * saturate(d); }

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

// A face of the quarry or the meadow, before light.
static inline float3 csGround(float3 P, float3 n, int2 cell, CsTer t, bool topmost, float fw, float sk,
                              float3 grass, texture2d_array<float> tiles) {
    int3 b;
    b.xz = cell;
    b.y = n.y > 0.5 ? int(round(P.y)) - 1 : int(floor(P.y));
    bool topFace = n.y > 0.5;
    bool top = topmost || (!topFace && b.y == int(round(t.ground)) - 1);
    int kind;
    int m = csBlock(b, top, topFace, t.k, sk, kind);
    float2 uv = csFaceUV(P, n);
    if (topFace && (kind == 1 || m == MC_DIRT || m == MC_SAND)) {
        // These blocks turn a random quarter per block, as the game's models do.
        int rot = int(hash21(float2(cell) * 0.77 + sk) * 3.999);
        if (rot == 1) uv = float2(1.0 - uv.y, uv.x);
        else if (rot == 2) uv = 1.0 - uv;
        else if (rot == 3) uv = float2(uv.y, 1.0 - uv.x);
    }
    float3 alb = kind == 2 ? mcGrassSide(tiles, uv, fw, grass)
                           : mcTile(tiles, m, uv, fw).rgb * (kind == 1 ? grass : float3(1.0));
    return alb * mcFaceShade(n) * csAO(P, n, t);
}

// Water as the game draws it: the still texture on a source, the flowing one
// (the 16-texel middle of its 32, turned so it runs along the flow) on
// running water and down every side, tinted, at the texture's own alpha.
static inline float3 csWaterShade(float3 behind, float3 Pw, float3 nW, CsWater w, int2 cW,
                                  float fw, thread const CsEnv& e,
                                  texture2d_array<float> tiles, texture2d_array<float> skins) {
    bool top = nW.y > 0.5;
    float4 tex;
    if (top && all(w.dir == 0.0)) {
        tex = mcTile(tiles, mcFrame(MC_WATER_STILL, MC_WATER_STILL_FRAMES, MC_WATER_STILL_TICKS, e.time),
                     fract(Pw.xz + 0.5), fw);
    } else {
        float2 px;
        if (top) {
            float2 d = normalize(w.dir);
            float2 l = Pw.xz - float2(cW);
            px = 16.0 + 16.0 * float2(dot(l, float2(-d.y, d.x)), dot(l, d));
        } else {
            float s = abs(nW.x) > 0.5 ? Pw.z : Pw.x;
            px = 16.0 * float2(fract(s + 0.5), fract(-Pw.y));
        }
        int fr = mcFrame(MCS_BLOCK_WATER_FLOW, MCS_BLOCK_WATER_FLOW_FRAMES, MCS_BLOCK_WATER_FLOW_TICKS, e.time);
        tex = mcSkin(skins, fr, px, fw * 16.0);
    }
    float3 c = tex.rgb * MC_WATER_TINT * mcFaceShade(nW) * csLightmap(15.0, e);
    return mix(behind, c, tex.a);
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

static inline float3 csScene(float3 ro, float3 rd, float pxA, thread const CsPit& p,
                             float tick, float speed, int slots, float seed, thread const CsEnv& e,
                             texture2d_array<float> mcTiles, texture2d_array<float> mcSkins,
                             texture2d_array<float> mcMaps) {
    float sk = floor(seed * 997.0);
    int R = csA(p, 0);
    float2 inv = 1.0 / select(rd.xz, float2(1e-6), abs(rd.xz) < 1e-6);
    float3 inv3 = 1.0 / select(rd, float3(1e-6), abs(rd) < 1e-6);

    // The ground: exact, in one pass over the terraces.
    float tHit = 1e9;
    float3 nHit = float3(0.0, 1.0, 0.0);
    if (rd.y < -1e-4) tHit = csNested(ro, rd, inv, p, 0.0, 0.0, nHit);
    int kind = 0;                       // 0 ground, 1 log, 2 leaves, 3 plant, 4 animal
    float4 tex = float4(0.0);
    float passed = 0.0;
    CsMob mob;
    MCMOB_Hit mobHit;

    // The oaks: walk the 7-block squares the ray crosses below the treetops.
    {
        float t0 = -ro.y * inv3.y, t7 = (CS_TREE_Y - ro.y) * inv3.y;
        float tA = max(min(t0, t7), 0.0), tB = min(max(t0, t7), min(tHit, CS_FOG1));
        float2 pa = ro.xz + rd.xz * tA, pb = ro.xz + rd.xz * tB;
        float clear = float(R) + 0.5;     // a segment wholly over the pit meets no tree
        if (tA < tB && max(max(abs(pa.x), abs(pa.y)), max(abs(pb.x), abs(pb.y))) >= clear) {
            const float G = float(CS_TG);
            float2 q = (pa + 0.5) / G;
            int2 g = int2(floor(q));
            int2 stp = int2(rd.x > 0.0 ? 1 : -1, rd.z > 0.0 ? 1 : -1);
            float2 tDelta = abs(inv) * G;
            float2 tMax = tA + (float2(g) + select(float2(0.0), float2(1.0), rd.xz > 0.0) - q) * inv * G;
            for (int i = 0; i < CS_TSQ; ++i) {
                CsTree tr = csTreeIn(g, sk, R);
                if (tr.ok) {
                    McModelHit th; float ps;
                    int kd = mcTree(mcTiles, tr.m, mcTreeLeafTint(MC_TREE_OAK, e.foliage), ro, rd, 0.0, tHit, pxA, th, ps);
                    if (kd != 0) { tHit = th.t; nHit = th.n; kind = kd; passed = ps; tex = th.color; break; }
                }
                float tOut = min(tMax.x, tMax.y);
                if (tOut > tB) break;
                if (tMax.x < tMax.y) { tMax.x += tDelta.x; g.x += stp.x; }
                else                 { tMax.y += tDelta.y; g.y += stp.y; }
            }
        }
    }
    if (tHit > 1e8) return csSky(ro, rd, pxA, e, mcSkins, mcMaps);

    // The herds: only a ray that reaches the meadow below 1.8 blocks, beside
    // the pit, can meet one; each herd is boxed first, its animals after.
    {
        float tA = max((1.8 - ro.y) * inv3.y, 0.0), tB = min(tHit, -ro.y * inv3.y);
        float2 pa = ro.xz + rd.xz * tA, pb = ro.xz + rd.xz * tB;
        // Each side's herds keep to a strip: 0.15 to 4.05 blocks out from the
        // rim's ring R, and within R - 2.95 of the side's middle along it.
        int sides = 0;
        if (rd.y < 0.0 && tA < tB) {
            float r0 = float(R) + 0.15, r1 = float(R) + 4.05, w = float(R) - 2.95;
            #pragma unroll
            for (int sd = 0; sd < 4; ++sd) {
                float2 lo = sd == 0 ? float2(r0, -w) : sd == 1 ? float2(-w, r0) : sd == 2 ? float2(-r1, -w) : float2(-w, -r1);
                float2 hi = sd == 0 ? float2(r1, w) : sd == 1 ? float2(w, r1) : sd == 2 ? float2(-r0, w) : float2(w, -r0);
                float2 t1 = (lo - ro.xz) * inv, t2 = (hi - ro.xz) * inv;
                float2 mn = min(t1, t2), mx = max(t1, t2);
                if (max(max(mn.x, mn.y), tA) <= min(min(mx.x, mx.y), tB)) sides |= 1 << sd;
            }
        }
        if (sides != 0) {
            float off = hash11(sk * 0.31 + 0.17);
            float ph = e.time / CS_LEG + off;
            float le = floor(ph), lf = ph - le;
            CsLegSprings sPrev = csLegSprings(le - 1.0, off, speed, seed, slots, R);
            CsLegSprings sNow  = csLegSprings(le, off, speed, seed, slots, R);
            // Where the camera stands (its azimuth, as lerpMain orbits it) at each leg's start.
            float azPrev = seed * TWO_PI + (le - 1.0 - off) * CS_LEG * 0.011;
            float azNow  = seed * TWO_PI + (le - off) * CS_LEG * 0.011;
            for (int h = 0; h < CS_NHERD; ++h) {
                if ((sides & (1 << (h & 3))) == 0) continue;
                float2 a = csHerdSpot(h, le - 1.0, sPrev, sk, R, float2(cos(azPrev), sin(azPrev)));
                float2 b = csHerdSpot(h, le, sNow, sk, R, float2(cos(azNow), sin(azNow)));
                float2 lo = min(a, b) - 3.1, hi = max(a, b) + 3.1;
                float2 t1 = (lo - ro.xz) * inv, t2 = (hi - ro.xz) * inv;
                float2 mn = min(t1, t2), mx = max(t1, t2);
                if (max(max(mn.x, mn.y), tA) > min(min(mx.x, mx.y), tB)) continue;
                int species;
                int n = csHerdKind(h, sk, species);
                for (int i = 0; i < CS_HERD; ++i) {
                    if (i >= n) break;
                    CsMob mb = csMobAt(h, i, species, a, b, le, lf, e.time, sk);
                    float3 lro, lrd;
                    mcMobRay(ro, rd, mb.at, mb.heading, lro, lrd);
                    float2 bb = mcMobBounds(mb.type, lro, lrd);
                    if (bb.x < bb.y && bb.x < tHit) {
                        MCMOB_Hit hm = mcMobTrace(mb.type, mb.pose, mb.skin, lro, lrd, tHit, mcSkins, mcMaps);
                        if (hm.t < tHit) { tHit = hm.t; kind = 4; mob = mb; mobHit = hm; }
                    }
                }
            }
        }
    }

    // Plants: walk the meadow cells the ray crosses in the block above the
    // grass, in front of an animal too.
    if (kind == 0 || kind == 4) {
        float tA = max((1.0 - ro.y) * inv3.y, 0.0), tB = min(tHit, -ro.y * inv3.y);
        if (rd.y < 0.0 && tA < tB) {
            float2 q = ro.xz + rd.xz * tA + 0.5;
            int2 cell = int2(floor(q));
            int2 stp = int2(rd.x > 0.0 ? 1 : -1, rd.z > 0.0 ? 1 : -1);
            float2 tDelta = abs(inv);
            float2 tMax = tA + (float2(cell) + select(float2(0.0), float2(1.0), rd.xz > 0.0) - q) * inv;
            for (int i = 0; i < CS_PSTEPS; ++i) {
                int ring = max(abs(cell.x), abs(cell.y));
                bool tinted = false; float2 off = float2(0.0);
                int lay = ring >= R ? csPlant(cell, sk, tinted, off) : -1;
                if (lay >= 0) {
                    // The kit's cross model, nudged off the cell's centre as
                    // the game nudges it. tMin is the band's entry, not the
                    // cell's, so a nudged quad leaning into an earlier cell
                    // still counts.
                    McModelHit mh;
                    float3 origin = float3(float(cell.x) - 0.5 + off.x, 0.0, float(cell.y) - 0.5 + off.y);
                    if (mcCross(mcTiles, lay, origin, tinted ? e.grass : float3(1.0), ro, rd,
                                tA - 1e-4, tHit, pxA, mh)) {
                        // Running water washes a plant off its block, and
                        // an oak's trunk has none.
                        CsTree tr = csTreeIn(int2(floor((float2(cell) + 0.5) / float(CS_TG))), sk, R);
                        bool gone = tr.ok && all(tr.c == cell);
                        if (!gone && ring <= R + 11) {
                            CsWater w = csWaterAt(cell, ring, csTer(ring, p), p, tick, slots, seed);
                            gone = w.hi > w.lo;
                        }
                        if (!gone) { tHit = mh.t; kind = 3; tex = mh.color; break; }
                    }
                }
                float tOut = min(tMax.x, tMax.y);
                if (tOut >= tB) break;
                if (tMax.x < tMax.y) { tMax.x += tDelta.x; cell.x += stp.x; }
                else                 { tMax.y += tDelta.y; cell.y += stp.y; }
            }
        }
    }

    // Water: walk the cells between entering the shell water can occupy
    // and the nearest solid thing, testing only those the ray is low enough in.
    bool wet = false;
    float tW = 0.0;
    float3 nW = float3(0.0, 1.0, 0.0);
    CsWater wW;
    int2 cW = int2(0);
    float3 nShell;
    float tShell = rd.y < -1e-4 ? csNested(ro, rd, inv, p, 1.0, 1.0, nShell) : 1e9;
    if (tShell < tHit) {
        float3 P0 = ro + rd * tShell;
        float2 q = P0.xz + 0.5;
        int2 cell = int2(floor(q));
        int2 stp = int2(rd.x > 0.0 ? 1 : -1, rd.z > 0.0 ? 1 : -1);
        float2 tDelta = abs(inv);
        float2 tMax = tShell + (float2(cell) + select(float2(0.0), float2(1.0), rd.xz > 0.0) - q) * inv;
        float tIn = tShell;
        float3 nSide = nShell;
        int asked = 0;
        for (int i = 0; i < CS_WCELLS; ++i) {
            float tOut = min(tMax.x, tMax.y);
            float yOut = ro.y + rd.y * min(tOut, tHit);
            int ring = max(abs(cell.x), abs(cell.y));
            CsTer t = csTer(ring, p);
            bool lip = t.k >= 1 && ring == t.aUp - 1;
            float band = (lip ? t.Hup : t.H) + 1.0;
            if (yOut < band) {
                if (++asked > CS_WSTEPS) break;
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
    // Skylight lost on the way down: a level a block of water above the face
    // (a falling column has open air beside it), and under an oak's leaves.
    float level = 15.0;
    if (wet) level -= wW.fall > 0.0 && wW.lo > csTer(max(abs(cW.x), abs(cW.y)), p).ground - 0.5
                      ? 1.0 : clamp(ceil(wW.hi - P.y - 1e-3), 1.0, 15.0);
    float3 col;
    if (kind == 0) {
        int2 cHit = int2(floor(P.xz - nHit.xz * 0.5 + 0.5));
        CsTer tHitT = csTer(max(abs(cHit.x), abs(cHit.y)), p);
        bool topmost = nHit.y > 0.5;
        float fw = tHit * pxA / max(abs(dot(rd, nHit)), 0.08);
        float ao = 1.0;
        if (topmost && tHitT.k == 0) level -= csCanopyShade(P.xz, sk, R, ao);
        col = csGround(P, nHit, cHit, tHitT, topmost, fw, sk, e.grass, mcTiles) * ao;
    } else if (kind == 4) {
        // The game lights an entity by the light where it stands; face
        // shading as for blocks, its normal turned back to the world.
        float4 c = mcMobColor(mob.type, mobHit, mob.skin, tHit * pxA * 16.0, mcSkins, mcMaps);
        col = c.rgb * mcFaceShade(mcMobNormal(mobHit.n, mob.heading));
    } else if (kind == 3) {
        col = tex.rgb;                    // tinted by the kit; plants take no face shade
        float ao = 1.0;
        level -= csCanopyShade(P.xz, sk, R, ao);
    } else {
        col = tex.rgb * mcFaceShade(nHit);       // leaves come tinted from the kit
        level -= kind == 2 ? min(passed, 3.0) : clamp(3.0 - P.y * 0.5, 0.0, 2.0);
        if (passed > 0.0) col *= 0.8;
    }
    col *= csLightmap(level, e);

    if (wet) {
        float3 Pw = ro + rd * tW;
        float fw = tW * pxA / max(abs(dot(rd, nW)), 0.05);
        col = csWaterShade(col, Pw, nW, wW, cW, fw, e, mcTiles, mcSkins);
        tHit = tW;
    }

    // The game's linear fog at the end of its render distance.
    return mix(col, e.fogLook, saturate((tHit - CS_FOG0) / (CS_FOG1 - CS_FOG0)));
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]],
                        texture2d_array<float> mcTiles [[texture(8)]],
                        texture2d_array<float> mcSkins [[texture(10)]],
                        texture2d_array<float> mcMaps  [[texture(11)]]) {
    CsPit pit = csPit(u.seed);
    float R = float(pit.a0.x);
    int slots = clamp(u.springs, 1, 4);
    float tick = u.time * u.speed / CS_TICK;

    float az = u.seed * TWO_PI + u.time * 0.011;   // the herds read this too (csScene)
    float el = 0.82 + 0.04 * sin(u.time * 0.017 + u.seed * 9.0);
    float3 pivot = float3(0.0, pit.H1.y * 0.6, 0.0);
    // Frame the whole pit: a narrow screen stands further back.
    float dist = 1.42 * R * clamp(1.6 * u.resolution.y / u.resolution.x, 1.0, 1.5);
    float3 ro = pivot + dist * float3(cos(el) * cos(az), sin(el), cos(el) * sin(az));
    float3 upHint = float3(0.0, 1.0, 0.0);
    float3 fwd = normalize(pivot - ro);
    float3 right = normalize(cross(fwd, upHint));
    lerpOrbit(u.yaw, u.pitch, u.magnify, pivot, upHint, ro, right, fwd);
    // Tilted toward the horizon the orbit would sink into the meadow and the
    // oaks; stand over the treetops instead, looking the same way.
    ro.y = max(ro.y, CS_TREE_Y + 2.5);
    float3 up = cross(right, fwd);

    float sa = u.seed * 5.1 + 1.3;
    float se = u.sun;
    float3 L = normalize(float3(cos(sa) * cos(se), sin(se), sin(sa) * cos(se)));
    CsEnv env = csEnv(L, fwd, u.time, mcMaps);

    float minRes = min(u.resolution.x, u.resolution.y);
    float pxA = 2.0 / (minRes * CS_FOCAL);
    float2 uv = lerpUV(pos, u.resolution);
    float3 rd = normalize(uv.x * right + uv.y * up + CS_FOCAL * fwd);

    // Colours stay in the textures' own encoding and multiply there, as the game's do.
    float3 col = csScene(ro, rd, pxA, pit, tick, u.speed, slots, u.seed, env, mcTiles, mcSkins, mcMaps);
    col = lerpDither(col, pos);
    return half4(half3(col), 1.0h);
}
