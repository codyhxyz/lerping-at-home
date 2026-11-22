// Block River — original shader written for Lerping@Home (AGPL-3.0, like the
// rest of this project). A boat ride down a Minecraft river: you drift
// downstream at boat height and the land it winds through keeps changing
// biome — plains, birch forest, snowy taiga with the river iced over, jagged
// snowy peaks, desert with cactus, and badlands whose terracotta walls rise
// straight out of the water.
// Every surface is the game's own block texture, and the water, sun, clouds
// and biome tints are the game's too. Those textures are Mojang's: they are
// read at run time from the copy of the game installed on this Mac and are not
// in this file or this repository.
//
// lerp-category: Living Worlds
// lerp-requires: minecraft
//
// How it is built:
//   - the world is a heightfield of whole blocks plus one floating span per
//     column (a trunk, a cactus or a tree's leaves), traced with a 2D grid walk
//     over columns and slab tests in y. Water is a plane at the river's level,
//     drawn as the game draws it: the still-water texture, tinted and 70%
//     opaque, over the river bed. (The game's water has no mirror, so neither
//     does this.)
//   - regions are slow fields (temperature, humidity, ruggedness) of the
//     distance along the river, so the journey crosses them in turn; heights
//     blend between region shapes, while blocks switch with a clumped
//     per-block jitter so the borders are ragged and blocky.
//   - the river and its fields are evaluated at knots every twelve rows and
//     interpolated between them: the river is a polyline of twelve-block
//     reaches, and a walk pays for the sines once per knot, not per column.
//   - the world repeats every BN_P blocks along the river (every field is
//     periodic in z), so coordinates stay small however long it runs and the
//     drift never re-rolls: it loops once an hour, seamlessly.
//   - light is the game's: no sun shading, the fixed per-face shade, smooth
//     lighting (vertex ambient occlusion from the neighbouring blocks, as the
//     game computes it) out to BN_NEAR, and the daylight level falling under
//     leaves. Leaves and cactus are cut out by their alpha: a near ray that
//     lands on a clear texel walks on from there (at most three times).
//
// Cost, at 3456x2234: about 12.1 ms a frame on an M5 against 10.0 for maze in
// the same minute. The walk is the cost. It is in three bands: single blocks
// out to the first 2x2 grid line past BN_T1, then BN_STEPS2 steps over 2x2
// cells, then 4x4 cells to BN_FAR (which every ray's steps reach, so the fog
// is whole where a walk ends). A far cell's ground stands for its centre
// column and is drawn two or four wide; trees are tested whole wherever they
// are. Bands change on grid lines, so where a coarse cell stands above the
// fine ground it replaces it shows a block face. Three things keep the steps
// few: a ray starts walking where the open water round the boat ends, the far
// walk stops at the water surface (the bed beyond the near band is found from
// the river's depth profile), and every lane changes band at nearly the same
// step. Textures are sampled only at hits (a clear leaf texel ends one walk
// and starts the next), never inside a walk. There are no sun shadows, as
// there are none in the game.
// The integer hash is the "lowbias32" mix published by Chris Wellons
// (hash-prospector, public domain / Unlicense).
//
// lerp-param: speed    float 0 3      = 1   "Drift speed"
// lerp-param: region   int 0 6        = 0   "Region (0 = the whole journey)"
// lerp-param: yaw      float -180 180 = 0   "Turn"
// lerp-param: pitch    float -60 60   = 0   "Tilt"
// lerp-param: magnify  float -1 1.2   = 0   "Zoom"
//
// lerp-preset: "Birch Wood" region=2
// lerp-preset: "Snowy Taiga" region=3
// lerp-preset: Badlands region=6

constant int   BN_P      = 3840;     // world period along the river, in blocks
constant float BN_K      = 6.28318530718 / 3840.0;
constant float BN_WL     = -0.125;   // water surface (water fills blocks y < 0, 14/16 high)
constant float BN_HMAX   = 36.0;     // nothing solid reaches above this
constant float BN_FAR    = 48.0;     // view distance (every ray's walk reaches it)
constant float BN_FOG0   = 14.0;     // fog starts
constant float BN_NEAR   = 10.0;     // smooth lighting fades out by here
constant float BN_T1     = 8.0;      // single blocks out to here (and on to a 2x2 line),
constant int   BN_STEPS  = 18;       // single-block steps (to BN_T1)
constant int   BN_STEPS2 = 9;        // 2x2 steps, then
constant int   BN_STEPS4 = 8;        // 4x4 steps (to BN_FAR)
constant int   BN_CUTS   = 3;        // clear leaf texels a near ray may pass through

constant float BN_FOCAL  = 1.55;
constant float BN_SPEED  = 1.05;     // blocks a second at speed 1
constant float BN_CLOUDY = 128.0;    // the cloud layer above the water (y 192 over sea level 63)

// Blocks.
constant int M_GRASS = 0, M_DIRT = 1, M_STONE = 2, M_SAND = 3, M_SANDSTONE = 4,
             M_SNOWGRASS = 5, M_SNOW = 6, M_GRAVEL = 7, M_CLAY = 8, M_TERRA = 9,
             M_OAKLOG = 10, M_OAKLEAF = 11, M_BIRCHLOG = 12, M_BIRCHLEAF = 13,
             M_SPRUCELOG = 14, M_SPRUCELEAF = 15, M_CACTUS = 16, M_REDSAND = 17;

// Regions, each one of the game's biomes: plains, birch forest, snowy taiga,
// jagged peaks, desert, badlands.
constant int B_MEADOW = 0, B_FOREST = 1, B_TAIGA = 2, B_PEAKS = 3, B_DESERT = 4, B_MESA = 5;

// ---------------------------------------------------------------------------
// Hashing and noise.

static inline uint bnHash(uint x) {
    x ^= x >> 16; x *= 0x7feb352du;
    x ^= x >> 15; x *= 0x846ca68bu;
    x ^= x >> 16;
    return x;
}
static inline uint bnH3(int a, int b, uint c) {
    return bnHash(uint(a) * 0x9E3779B1u + bnHash(uint(b) ^ c));
}
static inline float bnR(uint h) { return float(h >> 8) * (1.0 / 16777216.0); }

// Integer division is slow on the GPU; these are exact for |z| < 2^23.
// (The half keeps an exact multiple off the rounding edge.)
static inline int bnWrapZ(int z) { return z - BN_P * int(floor((float(z) + 0.5) * (1.0 / float(BN_P)))); }
static inline int bnDiv6(int a)  { return int(floor((float(a) + 0.5) * (1.0 / 6.0))); }
static inline int bnDiv12(int a) { return int(floor((float(a) + 0.5) * (1.0 / 12.0))); }

// ---------------------------------------------------------------------------
// The world: one river, three slow fields, a heightfield and trees.

struct BnWorld {
    float4 rp;     // river phases (three meanders) and width phase, in cycles
    float4 fp;     // temperature and humidity phases, in cycles
    float4 gp;     // ruggedness phases (cycles), sun side, cloud drift
    float2 so;     // salt as an offset for the float hash
    uint   salt;
    int    region;
};

struct BnF { float tm, hu, rug, dn; };

// Value noise on the prelude's scalar float hash (much cheaper than the
// integer one, in the walk's inner loop); the lattice repeats every perZ cells
// in z.
static inline float bnNoiseF(float2 p, float perZ, float2 so) {
    float2 i = floor(p);
    float2 f = p - i;
    float z0 = i.y - perZ * floor(i.y / perZ);
    float z1 = z0 + 1.0;
    if (z1 >= perZ) z1 = 0.0;
    // One scalar hash per corner, on a linear index (exact integers < 2^24).
    float n0 = i.x + z0 * 157.0 + so.x, n1 = i.x + z1 * 157.0 + so.x;
    float a = hash11(n0), b = hash11(n0 + 1.0);
    float c = hash11(n1), d = hash11(n1 + 1.0);
    float2 s = f * f * (3.0 - 2.0 * f);
    return mix(mix(a, b, s.x), mix(c, d, s.x), s.y);
}

// sin(2 pi c), to about 0.1%: a parabola per half cycle with one correction.
// Every phase in this file is counted in cycles. The library sin is far
// dearer, and the river and its regions call it often enough that it was
// most of this look's frame; the world is defined by this curve, so the
// camera uses it too.
static inline float bnSinC(float c) {
    float u = 1.0 - 2.0 * fract(c);
    float y = 4.0 * u * (1.0 - abs(u));
    return y * (0.775 + 0.225 * abs(y));
}
static inline float bnCosC(float c) { return bnSinC(c + 0.25); }

static inline float bnRiverX(float z, BnWorld w, thread float& slope) {
    float q = z * (1.0 / float(BN_P));
    float a1 = 37.0 * q + w.rp.x, a2 = 15.0 * q + w.rp.y;
    slope = 9.0 * 37.0 * BN_K * bnCosC(a1) + 13.0 * 15.0 * BN_K * bnCosC(a2);
    return 9.0 * bnSinC(a1) + 13.0 * bnSinC(a2);
}

// Everything that varies along the river is a function of z alone, evaluated
// exactly at knots every BN_KN rows and interpolated between them. The knots
// define the world (the river is a polyline of twelve-block segments), so
// every ray sees the same land, and a walk pays for the sines once per twelve
// rows instead of at every column.
constant int BN_KN = 12;            // knot spacing: two tree cells; divides BN_P
constant int BN_NK = 320;           // BN_P / BN_KN

struct BnRow {
    float4 a;   // river centre x, 1/sqrt(1 + slope^2) of the segment, half-width, bank width
    float4 b;   // amp, peak weight, canyon weight, highest ground at full bank
    float4 c;   // temperature, humidity, ruggedness, unused
};

static inline BnRow bnKnot(int k, BnWorld w) {
    float q = float(k) * (1.0 / float(BN_NK));           // cycles of the world period
    float rx = 9.0 * bnSinC(37.0 * q + w.rp.x) + 13.0 * bnSinC(15.0 * q + w.rp.y);
    float tm, hu, rug;
    if (w.region == 0) {
        tm  = 0.5 + 0.36 * bnSinC(4.0 * q + w.fp.x) + 0.16 * bnSinC(11.0 * q + w.fp.y);
        hu  = 0.5 + 0.38 * bnSinC(13.0 * q + w.fp.z) + 0.14 * bnSinC(31.0 * q + w.fp.w);
        rug = 0.5 + 0.36 * bnSinC(9.0 * q + w.gp.x) + 0.16 * bnSinC(27.0 * q + w.gp.y);
    } else {
        // A pinned region: its centre values, with a little wander.
        int g = w.region;
        float3 c = g == 1 ? float3(0.50, 0.30, 0.40) : g == 2 ? float3(0.50, 0.85, 0.45)
                 : g == 3 ? float3(0.14, 0.50, 0.40) : g == 4 ? float3(0.14, 0.50, 0.88)
                 : g == 5 ? float3(0.86, 0.50, 0.30) : float3(0.86, 0.50, 0.86);
        float wob = 0.06 * bnSinC(13.0 * q + w.fp.z);
        tm = c.x + wob * 0.5; hu = c.y + wob; rug = c.z + 0.08 * bnSinC(9.0 * q + w.gp.x);
    }
    // The three land shapes and how much of each applies. The weights switch
    // over the same field values as the region blocks, so a canyon's walls
    // are terracotta and a peak is stone, not tall dirt.
    float amp   = mix(3.0, 11.0, smoothstep(0.3, 0.85, rug));
    float wPeak = (1.0 - smoothstep(0.27, 0.33, tm)) * smoothstep(0.55, 0.68, rug);
    float wMesa = smoothstep(0.66, 0.70, tm) * smoothstep(0.50, 0.60, rug);
    float bw    = mix(9.0, 1.8, smoothstep(0.35, 0.8, rug));
    float top   = mix(mix(0.8 + amp, 32.0, wPeak), 21.0, wMesa);
    BnRow r;
    r.a = float4(rx, 0.0, 4.3 + 1.5 * bnSinC(23.0 * q + w.rp.w), bw);   // .y: set per segment
    r.b = float4(amp, wPeak, wMesa, top);
    r.c = float4(tm, hu, rug, 0.0);
    return r;
}

struct BnZ { int k; float invs; BnRow k0, k1; };   // invs: the segment's 1/sqrt(1 + slope^2)

// Row rz (0..11) of knot interval k.
static inline BnRow bnRowAt(int k, int rz, BnWorld w, thread BnZ& zc) {
    if (k != zc.k) {
        // Stepping to a neighbouring interval keeps the shared knot; one call
        // site for bnKnot keeps the inlined code small.
        int kn = k + 1 == BN_NK ? 0 : k + 1;
        bool fwd  = zc.k >= 0 && k == (zc.k + 1 == BN_NK ? 0 : zc.k + 1);
        bool back = zc.k >= 0 && zc.k == kn;
        if (fwd)  zc.k0 = zc.k1;
        if (back) zc.k1 = zc.k0;
        int j1 = back ? 1 : 2;
        for (int j = fwd ? 1 : 0; j < j1; ++j) {
            BnRow r = bnKnot(j == 0 ? k : kn, w);
            if (j == 0) zc.k0 = r; else zc.k1 = r;
        }
        zc.k = k;
        float sl = (zc.k1.a.x - zc.k0.a.x) * (1.0 / float(BN_KN));
        zc.invs = rsqrt(1.0 + sl * sl);
    }
    float f = (float(rz) + 0.5) * (1.0 / float(BN_KN));
    BnRow r;
    r.a = mix(zc.k0.a, zc.k1.a, f);
    r.a.y = zc.invs;
    r.b = mix(zc.k0.b, zc.k1.b, f);
    // This row's own ceiling, from its own interpolated shape: interpolating
    // the knots' ceilings instead could undercut it by a few blocks.
    r.b.w = mix(mix(0.8 + r.b.x, 32.0, r.b.y), 21.0, r.b.z);
    r.c = float4(0.0, 0.0, 0.0, f);   // the slow fields, interpolated only on request (bnFOf)
    return r;
}

static inline BnRow bnRowAtZ(int zw, BnWorld w, thread BnZ& zc) {
    int k = bnDiv12(zw);
    return bnRowAt(k, zw - k * BN_KN, w, zc);
}

static inline float bnDn(int x, BnRow r) { return abs(float(x) + 0.5 - r.a.x) * r.a.y - r.a.z; }

// The slow fields at row r, which must be the row zc last handed out.
static inline BnF bnFOf(BnRow r, float dn, thread BnZ& zc) {
    float4 c = mix(zc.k0.c, zc.k1.c, r.c.w);
    BnF f; f.tm = c.x; f.hu = c.y; f.rug = c.z; f.dn = dn;
    return f;
}

static inline int bnBiome(BnF f, float j) {
    float tm = f.tm + j, rug = f.rug + 0.7 * j, hu = f.hu - j;
    if (tm < 0.30) return rug > 0.62 ? B_PEAKS : B_TAIGA;
    if (tm > 0.68) return rug > 0.55 ? B_MESA : B_DESERT;
    return hu > 0.55 ? B_FOREST : B_MEADOW;
}

// Ground height: blocks y < h are solid, the top face is at y = h.
// `lod`: the far 4x4 walk, which samples every fourth column and would only
// alias the eight-block octave, takes its mean instead.
static inline int bnGroundH(int x, int zw, float dn, BnRow r, BnWorld w, bool lod = false) {
    if (dn < 0.0) return -1 - int(2.2 * saturate(-dn / 2.5));      // the river bed
    float2 p = float2(float(x), float(zw)) + 0.5;
    float n = 0.65 * bnNoiseF(p * (1.0 / 24.0), 160.0, w.so)
            + 0.35 * (lod ? 0.5 : bnNoiseF(p * 0.125, 480.0, w.so + 17.0));
    float h = 0.8 + r.b.x * n;
    h = mix(h, 2.0 + 30.0 * n * n, r.b.y);
    h = mix(h, 2.0 + 14.0 * smoothstep(0.30, 0.38, n) + 5.0 * smoothstep(0.58, 0.64, n), r.b.z);
    return int(floor(h * smoothstep(0.0, r.a.w, dn)));
}

static inline float bnJitter(int x, int zw, BnWorld w) {
    // Clumps a few blocks across, so a border is a ragged blocky line rather
    // than a scatter of single blocks.
    float2 p = float2(float(x), float(zw));
    return (bnNoiseF(p * 0.25, float(BN_P / 4), w.so + 31.0) - 0.5) * 0.05
         + (hash21(p + w.so + 57.0) - 0.5) * 0.008;
}

// Trees: at most one per 6x6 cell, canopy radius 2, so a column only ever
// asks its own cell; a cell's rows share one pair of knots.
struct BnTree { int2 cell; int kind; int2 c; int hb; int L; uint hs; };

static inline BnTree bnTreeAt(int2 cell, BnWorld w, thread BnZ& zc, bool lod = false) {
    BnTree t;
    t.cell = cell; t.kind = -1; t.c = int2(0); t.hb = 0; t.L = 0;
    uint hs = bnH3(cell.x, cell.y, w.salt ^ 0x51ED27u);
    t.hs = hs;
    int2 o = int2(2 + int(hs & 1u), 2 + int((hs >> 1) & 1u));
    int2 c = cell * 6 + o;
    BnRow r = bnRowAt(cell.y >> 1, (cell.y & 1) * 6 + o.y, w, zc);   // two tree cells a knot interval
    float dn = bnDn(c.x, r);
    if (dn < 2.2) return t;
    int b = bnBiome(bnFOf(r, dn, zc), 0.0);          // (unjittered: a tree costs no noise to reject)
    float dens = b == B_MEADOW ? 0.12 : b == B_FOREST ? 0.85 : b == B_TAIGA ? 0.7
               : b == B_PEAKS ? 0.2 : b == B_DESERT ? 0.2 : 0.0;
    if (bnR(bnHash(hs ^ 0x7777u)) >= dens) return t;
    int hb = bnGroundH(c.x, c.y, dn, r, w, lod);
    if (hb < 1) return t;
    if (b == B_PEAKS && hb > 9) return t;          // above the tree line
    int v = int((hs >> 2) & 1u);
    if (b == B_DESERT)                    { t.kind = 3; t.L = 1 + int((hs >> 3) % 3u); }
    else if (b == B_TAIGA || b == B_PEAKS) { t.kind = 2; t.L = 6 + v; }
    else if (b == B_FOREST && ((hs >> 5) & 3u) != 0u) { t.kind = 1; t.L = 5 + v; }
    else                                  { t.kind = 0; t.L = 4 + v; }
    t.c = c; t.hb = hb;
    return t;
}

struct BnCol { int h; int s0; int s1; int split; int tree; };

// What column x holds that a ray whose lowest point in it is yLo could reach.
// Ground: only under the column's ceiling does it cost noise. Trees: the
// cell's cached tree, and only under its top, gets its canopy worked out.
static inline BnCol bnColumn(int x, int zw, int tz, BnRow r, int tx, float dn, float ceil, float yLo,
                             BnWorld w, thread BnZ& zc, thread BnTree& tc, bool lod = false) {
    BnCol c;
    c.s0 = 0; c.s1 = 0; c.split = 0; c.tree = -1;
    c.h = yLo >= ceil ? -64 : bnGroundH(x, zw, dn, r, w, lod);
    if (dn < -0.7 || yLo > r.b.w + 8.5) return c;
    if (tx != tc.cell.x || tz != tc.cell.y) tc = bnTreeAt(int2(tx, tz), w, zc, lod);
    if (tc.kind < 0 || yLo >= float(tc.hb + tc.L + 1)) return c;
    int dx = x - tc.c.x, dz = zw - tc.c.y;
    int ax = abs(dx), az = abs(dz);
    int cheb = max(ax, az), man = ax + az;
    if (cheb > 2) return c;
    int T = tc.hb + tc.L - 1;                     // top trunk block
    c.tree = tc.kind;
    if (tc.kind == 3) {                           // cactus
        if (cheb == 0) { c.s0 = tc.hb; c.s1 = tc.hb + tc.L; c.split = 999; }
        return c;
    }
    if (tc.kind == 2) {                           // spruce: a stepped cone
        if (cheb == 0)      { c.s0 = tc.hb; c.s1 = T + 2; c.split = T + 1; }
        else if (cheb == 1) { c.s0 = T - 4; c.s1 = man == 1 ? T + 1 : T - 1; c.split = -999; }
        else if (man < 4)   { c.s0 = T - 4; c.s1 = T - 2; c.split = -999; }
        return c;
    }
    // Oak and birch: a broad block of leaves, narrower on top, corners trimmed.
    if (cheb == 0)      { c.s0 = tc.hb; c.s1 = T + 2; c.split = T + 1; }
    else if (cheb == 1) { c.s0 = T - 2; c.s1 = man == 1 ? T + 2 : T + 1; c.split = -999; }
    else if (man < 4)   { c.s0 = T - 2; c.s1 = T; c.split = -999; }
    else if (bnR(bnH3(dx, dz, tc.hs)) < 0.5) { c.s0 = T - 2; c.s1 = T - 1; c.split = -999; }
    return c;
}

// ---------------------------------------------------------------------------
// The grid walk.

struct BnHit {
    float  t;
    float3 n;
    int2   cell;
    int    by;       // the block's y
    int    prevH;    // ground height of the column the ray came from
    int    span;     // 0 ground, 1 the column's span
    int    split;
    int    top;      // the span's top
    int    tree;
    int    canopy;   // a ground hit with leaves overhead in its own column
    int    lod;      // found by the 4x4 walk, on its smoothed ground
    int    h;        // a ground hit: its column's height, as the walk found it
};

// The near walk. A ray that has just seen through a clear texel of leaves or
// cactus at tMin starts again from there (tStart just short of tMin): in that
// first column it is inside the span, and the next face it can meet is the
// next block boundary in y (the top or bottom of the leaf or log block
// beyond, which the game draws between leaves) or the next column.
static inline bool bnTrace(float3 ro, float3 rd, float tStart, float tMin, int budget, float tFar, BnWorld w,
                           thread BnZ& zc, thread BnHit& hit, thread int& used, thread float& tReach) {
    BnTree tc;
    tc.cell = int2(-1 << 20); tc.kind = -1; tc.c = int2(0); tc.hb = 0; tc.L = 0; tc.hs = 0u;
    float2 d2 = select(rd.xz, float2(1e-6), abs(rd.xz) < 1e-6);
    float2 inv = 1.0 / d2;
    int2 cell = int2(floor(ro.xz + rd.xz * tStart));
    int2 st = int2(d2.x > 0.0 ? 1 : -1, d2.y > 0.0 ? 1 : -1);
    float2 tDelta = abs(inv);
    float2 tMax = (float2(cell) + select(float2(0.0), float2(1.0), d2 > 0.0) - ro.xz) * inv;
    float tIn = tStart;
    int axis = abs(d2.x) > abs(d2.y) ? 0 : 1;
    int prevH = -3;
    float ry = abs(rd.y) < 1e-6 ? 1e-6 : rd.y;
    int zw = bnWrapZ(cell.y);
    int k = bnDiv12(zw), rz = zw - 12 * k;
    int tx = bnDiv6(cell.x), ox = cell.x - 6 * tx;
    BnRow row = bnRowAt(k, rz, w, zc);
    float tLim = min(tFar, rd.y > 0.0 ? (BN_HMAX - ro.y) / rd.y : 1e9);
    used = 0;
    tReach = tStart;
    for (int i = 0; i < BN_STEPS + 2 * BN_CUTS; ++i) {
        if (i >= budget) break;
        used = i + 1;
        float tOut = min(tMax.x, tMax.y);
        bool inside = tIn < tMin;
        float tA = inside ? tMin : tIn;
        float yA = ro.y + rd.y * tA, yB = ro.y + rd.y * tOut;
        float yLo = min(yA, yB);
        // Most columns hold nothing the ray could reach: over the water, or
        // under a ray passing above the land's ceiling and any tree.
        float dn = abs(float(cell.x) + 0.5 - row.a.x) * row.a.y - row.a.z;
        float ceil = row.b.w * smoothstep(0.0, row.a.w, dn);
        BnCol c = bnColumn(cell.x, zw, 2 * k + (rz >= 6 ? 1 : 0), row, tx, dn, ceil, yLo, w, zc, tc);
        if (c.h > -64 || c.s1 > c.s0) {
        float3 side = axis == 0 ? float3(-float(st.x), 0.0, 0.0) : float3(0.0, 0.0, -float(st.y));
        float best = 1e9;
        float3 n = float3(0.0, 1.0, 0.0);
        int span = 0;
        float fh = float(c.h);
        if (yA < fh)      { best = tA; n = side; }
        else if (yB < fh) { best = (fh - ro.y) / ry; }
        if (c.s1 > c.s0) {
            float s0 = float(c.s0), s1 = float(c.s1);
            float ts = 1e9;
            float3 ns = side;
            if (yA >= s0 && yA <= s1) {
                if (!inside) ts = tIn;
                else if (c.tree != 3) {
                    float kb = ry < 0.0 ? metal::ceil(yA) - 1.0 : floor(yA) + 1.0;
                    if (kb > s0 && kb < s1) { ts = (kb - ro.y) / ry; ns = float3(0.0, ry < 0.0 ? 1.0 : -1.0, 0.0); }
                }
            }
            else if (yA < s0 && yB >= s0)   { ts = (s0 - ro.y) / ry; ns = float3(0.0, -1.0, 0.0); }
            else if (yA > s1 && yB <= s1)   { ts = (s1 - ro.y) / ry; ns = float3(0.0, 1.0, 0.0); }
            if (ts <= tOut && ts < best) { best = ts; n = ns; span = 1; }
        }
        if (best < 1e8) {
            hit.t = best; hit.n = n; hit.cell = cell; hit.prevH = prevH;
            hit.span = span; hit.split = c.split; hit.top = c.s1; hit.tree = c.tree;
            hit.canopy = (span == 0 && c.s1 > c.s0 && c.split < 0) ? 1 : 0;
            hit.lod = 0;
            float y = ro.y + rd.y * best;
            int by;
            if (n.y > 0.5)       by = int(round(y)) - 1;
            else if (n.y < -0.5) by = int(round(y));
            else                 by = int(floor(y));
            if (span == 1) by = clamp(by, c.s0, c.s1 - 1);
            else           by = min(by, c.h - 1);
            hit.by = by; hit.h = c.h;
            return true;
        }
        prevH = max(c.h, -3);
        } else prevH = -3;
        tIn = tOut;
        if (tIn > tLim) break;
        if (tMax.x < tMax.y) {
            tMax.x += tDelta.x; cell.x += st.x; axis = 0;
            ox += st.x;
            if (ox == 6) { ox = 0; tx += 1; } else if (ox < 0) { ox = 5; tx -= 1; }
        } else {
            tMax.y += tDelta.y; cell.y += st.y; axis = 1;
            zw += st.y; rz += st.y;
            if (zw == BN_P) zw = 0; else if (zw < 0) zw = BN_P - 1;
            if (rz == 12) { rz = 0; k = k + 1 == BN_NK ? 0 : k + 1; }
            else if (rz < 0) { rz = 11; k = k == 0 ? BN_NK - 1 : k - 1; }
            row = bnRowAt(k, rz, w, zc);
        }
        tReach = tIn;
    }
    return false;
}

// A tree, block for block, as boxes (each a run of whole blocks): the trunk,
// then the leaves layer by layer, a 5x5 layer as a 5x3 and a 3x5 box so its
// corners stay open. Relative to the trunk's foot; T is the top trunk block.
// The same shapes as bnColumn's spans (less an oak's random corner leaves).
static inline void bnTreeBox(int kind, int L, int i, thread float3& lo, thread float3& hi) {
    float T = float(L - 1), l = float(L);
    lo = float3(0.0); hi = float3(1.0, l, 1.0);                    // 0: trunk (or cactus)
    if (kind == 2) {                                                // spruce, a stepped cone
        switch (i) {
        case 1: lo = float3(-2.0, T - 4.0, -1.0); hi = float3(3.0, T - 2.0, 2.0); break;
        case 2: lo = float3(-1.0, T - 4.0, -2.0); hi = float3(2.0, T - 2.0, 3.0); break;
        case 3: lo = float3(-1.0, T - 2.0, -1.0); hi = float3(2.0, T - 1.0, 2.0); break;
        case 4: lo = float3(-1.0, T - 1.0,  0.0); hi = float3(2.0, T + 1.0, 1.0); break;
        case 5: lo = float3( 0.0, T - 1.0, -1.0); hi = float3(1.0, T + 1.0, 2.0); break;
        case 6: lo = float3( 0.0, T + 1.0,  0.0); hi = float3(1.0, T + 2.0, 1.0); break;
        default: break;
        }
    } else {                                                        // oak and birch
        switch (i) {
        case 1: lo = float3(-2.0, T - 2.0, -1.0); hi = float3(3.0, T, 2.0); break;
        case 2: lo = float3(-1.0, T - 2.0, -2.0); hi = float3(2.0, T, 3.0); break;
        case 3: lo = float3(-1.0, T, -1.0);       hi = float3(2.0, T + 1.0, 2.0); break;
        case 4: lo = float3(-1.0, T + 1.0,  0.0); hi = float3(2.0, T + 2.0, 1.0); break;
        case 5: lo = float3( 0.0, T + 1.0, -1.0); hi = float3(1.0, T + 2.0, 2.0); break;
        default: break;
        }
    }
}

// Where a ray leaves the S-wide grid cell it is in at t. The bands change at
// these lines, not at a fixed distance: a coarse cell standing higher than
// the fine ground it replaces then shows a block face, not a sphere.
static inline float bnGridExit(float3 ro, float3 rd, float t, float S) {
    float2 d2 = select(rd.xz, float2(1e-6), abs(rd.xz) < 1e-6);
    float2 c = floor((ro.xz + d2 * t) / S);
    float2 tx = ((c + select(float2(0.0), float2(1.0), d2 > 0.0)) * S - ro.xz) / d2;
    return min(tx.x, tx.y);
}

// The far walk: the same world on a coarser grid. Past the near band the walk
// takes BN_STEPS2 steps over 2x2-block cells and then 4x4 ones, each cell's ground standing
// for its centre column; far ground is drawn two and four blocks wide, at
// distances where a block is a few pixels and the fog is already thick. Trees
// are not coarsened: each tree cell the walk enters has its tree tested whole,
// box by box, so a far tree is still a trunk and a canopy of single blocks.
// Every lane changes grid at nearly the same step, so the SIMD group keeps
// walking together.
static inline bool bnTraceFar(float3 ro, float3 rd, float tStart, float tFar, BnWorld w,
                              thread BnZ& zc, thread BnHit& hit) {
    float2 d2 = select(rd.xz, float2(1e-6), abs(rd.xz) < 1e-6);
    float2 inv = 1.0 / d2;
    int2 st = int2(d2.x > 0.0 ? 1 : -1, d2.y > 0.0 ? 1 : -1);
    float2 up = select(float2(0.0), float2(1.0), d2 > 0.0);
    float ry = abs(rd.y) < 1e-6 ? 1e-6 : rd.y;
    float3 inv3 = 1.0 / float3(d2.x, ry, d2.y);
    float tLim = min(tFar, rd.y > 0.0 ? (BN_HMAX - ro.y) / rd.y : 1e9);
    float tIn = tStart;
    int2 lastTC = int2(-1 << 20);
    float tTree = 1e9;
    float3 nTree = float3(0.0, 1.0, 0.0);
    int kTree = -1, partTree = 0;
    for (int lv = 0; lv < 2; ++lv) {
        int   Si = lv == 0 ? 2 : 4;
        float S = float(Si);
        float tEnd = tLim;
        int steps = lv == 0 ? BN_STEPS2 : BN_STEPS4;
        if (tIn >= tEnd) continue;
        int2 cc = int2(floor((ro.xz + d2 * (tIn + 1e-3)) / S));
        float2 tMax = ((float2(cc) + up) * S - ro.xz) * inv;
        float2 tDelta = abs(inv) * S;
        // The face a ray starting inside a coarse cell's ground meets is the
        // grid line it has just crossed.
        float2 pc = floor((ro.xz + d2 * (tIn - 1e-3)) / S);
        float2 ptx = ((pc + up) * S - ro.xz) * inv;
        int axis = ptx.x < ptx.y ? 0 : 1;
        int lastZ = -1 << 20, zw = 0, k = 0, rz = 0;
        BnRow row;
        for (int i = 0; i < steps; ++i) {
            float tOut = min(tMax.x, tMax.y);
            float yA = ro.y + rd.y * tIn, yB = ro.y + rd.y * tOut;
            float yLo = min(yA, yB);
            int x = cc.x * Si + Si / 2, z = cc.y * Si + Si / 2;
            if (z != lastZ) {                     // a new row only on a step in z
                lastZ = z;
                zw = bnWrapZ(z);
                k = bnDiv12(zw); rz = zw - 12 * k;
                row = bnRowAt(k, rz, w, zc);
            }
            float dn = bnDn(x, row);
            float ceil = row.b.w * smoothstep(0.0, row.a.w, dn);
            int h = yLo >= ceil ? -64 : bnGroundH(x, zw, dn, row, w, lv == 1);
            // The tree of this column's tree cell, once per cell.
            int2 tcell = int2(bnDiv6(x), 2 * k + (rz >= 6 ? 1 : 0));
            if (dn > -0.7 && yLo < row.b.w + 8.5 && any(tcell != lastTC)) {
                lastTC = tcell;
                BnTree tr = bnTreeAt(tcell, w, zc, lv == 1);
                float3 base = float3(float(tr.c.x), float(tr.hb), float(tr.c.y + (z - zw)));
                // First the tree's bounding box: most rays that enter its cell miss it.
                float3 b0 = (base + float3(-2.0, 0.0, -2.0) - ro) * inv3;
                float3 b1 = (base + float3(3.0, float(tr.L + 1), 3.0) - ro) * inv3;
                float3 bn = min(b0, b1), bf = max(b0, b1);
                float be = max(max(bn.x, bn.y), bn.z), bx = min(min(bf.x, bf.y), bf.z);
                if (tr.kind >= 0 && be < bx && bx > tStart && be < tTree) {
                    int nb = tr.kind == 3 ? 1 : tr.kind == 2 ? 7 : 6;
                    for (int b = 0; b < nb; ++b) {
                        float3 lo, hi;
                        bnTreeBox(tr.kind, tr.L, b, lo, hi);
                        float3 t0 = (base + lo - ro) * inv3, t1 = (base + hi - ro) * inv3;
                        float3 tn = min(t0, t1), tf = max(t0, t1);
                        float te = max(max(tn.x, tn.y), tn.z);
                        if (te < min(min(tf.x, tf.y), tf.z) && te > tStart && te < tTree) {
                            tTree = te; kTree = tr.kind; partTree = b;
                            nTree = te == tn.x ? float3(-float(st.x), 0.0, 0.0)
                                  : te == tn.y ? float3(0.0, rd.y > 0.0 ? -1.0 : 1.0, 0.0)
                                  : float3(0.0, 0.0, -float(st.y));
                        }
                    }
                }
            }
            float3 side = axis == 0 ? float3(-float(st.x), 0.0, 0.0) : float3(0.0, 0.0, -float(st.y));
            float best = 1e9;
            float3 n = float3(0.0, 1.0, 0.0);
            float fh = float(h);
            if (yA < fh)      { best = tIn; n = side; }
            else if (yB < fh) { best = (fh - ro.y) / ry; }
            if (tTree < best && tTree <= tOut) {
                float3 P = ro + rd * tTree;
                int3 blk = int3(floor(P - nTree * 0.5));
                hit.t = tTree; hit.n = nTree; hit.cell = blk.xz; hit.by = blk.y; hit.prevH = -3;
                hit.span = 1; hit.tree = kTree;
                hit.split = partTree == 0 ? blk.y + 1 : -999;
                hit.top = nTree.y > 0.5 ? blk.y + 1 : 999;      // a top face carries the snow
                hit.canopy = 0; hit.lod = 1;
                return true;
            }
            if (best < 1e8) {
                float y = ro.y + rd.y * best;
                int by = n.y > 0.5 ? int(round(y)) - 1 : int(floor(y));
                // The block under the hit takes its own biome and block, at
                // the coarse cell's height: the same block the near walk
                // would show there, so the bands meet without a seam.
                float3 P = ro + rd * best;
                hit.t = best; hit.n = n; hit.cell = int2(floor(P.xz - n.xz * 0.5)); hit.prevH = -3;
                hit.by = min(by, h - 1); hit.h = h;
                hit.span = 0; hit.split = 0; hit.top = 0; hit.tree = -1; hit.canopy = 0;
                hit.lod = lv + 1;
                return true;
            }
            tIn = tOut;
            if (tIn > tEnd) break;
            if (tMax.x < tMax.y) { tMax.x += tDelta.x; cc.x += st.x; axis = 0; }
            else                 { tMax.y += tDelta.y; cc.y += st.y; axis = 1; }
        }
    }
    if (tTree < 1e8) {                            // a tree past the last ground cell walked
        float3 P = ro + rd * tTree;
        int3 blk = int3(floor(P - nTree * 0.5));
        hit.t = tTree; hit.n = nTree; hit.cell = blk.xz; hit.by = blk.y; hit.prevH = -3;
        hit.span = 1; hit.tree = kTree;
        hit.split = partTree == 0 ? blk.y + 1 : -999;
        hit.top = nTree.y > 0.5 ? blk.y + 1 : 999;
        hit.canopy = 0; hit.lod = 1;
        return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Blocks and their textures.

// Badlands: the game's terracotta bands, one colour a y level.
static inline int bnTerraBand(int y, uint salt) {
    const int bands[7] = { MC_TERRACOTTA, MC_ORANGE_TERRACOTTA, MC_YELLOW_TERRACOTTA, MC_BROWN_TERRACOTTA,
                           MC_RED_TERRACOTTA, MC_WHITE_TERRACOTTA, MC_LIGHT_GRAY_TERRACOTTA };
    uint h = bnH3(y, 77, salt ^ 0xBAD5u);
    int k = bnR(h) < 0.45 ? 0 : 1 + int(bnR(bnHash(h)) * 5.99);
    return bands[k];
}

// The block of a ground cell, `depth` blocks below its column's top.
static inline int bnGroundMat(int biome, int h, int depth, int y, float dn, uint bh) {
    if (h <= 0) {                                         // bed and shore
        if (biome == B_TAIGA || biome == B_PEAKS) return dn < -1.0 && bnR(bh) < 0.3 ? M_CLAY : M_GRAVEL;
        if (biome == B_MESA) return dn < -1.5 && bnR(bh) < 0.4 ? M_GRAVEL : M_REDSAND;
        return dn < -1.5 ? (bnR(bh) < 0.35 ? M_CLAY : M_GRAVEL) : M_SAND;
    }
    switch (biome) {
    case B_DESERT: return depth < 3 ? M_SAND : M_SANDSTONE;
    case B_MESA:   return (h <= 2 && depth < 2) ? M_REDSAND : M_TERRA;
    case B_TAIGA:  return depth == 0 ? M_SNOWGRASS : depth < 3 ? M_DIRT : M_STONE;
    case B_PEAKS:
        if (depth == 0) return h > 8 ? M_SNOW : h > 4 ? M_STONE : M_SNOWGRASS;
        return (depth < 3 && h <= 4) ? M_DIRT : M_STONE;
    default:
        if (depth == 0) return (h == 1 && dn < 2.5) ? M_SAND : M_GRASS;
        return depth < 3 ? M_DIRT : M_STONE;
    }
}

// The game's temperature and downfall for each region's biome, for the
// grass and foliage colormaps: plains, birch forest, snowy taiga, jagged
// peaks, desert, badlands.
static inline float2 bnClimate(int biome) {
    return biome == B_MEADOW ? float2(0.8, 0.4) : biome == B_FOREST ? float2(0.6, 0.6)
         : biome == B_TAIGA ? float2(-0.5, 0.4) : biome == B_PEAKS ? float2(-0.7, 0.9)
         : float2(2.0, 0.0);
}

// Which face of which texture a hit shows, and its tint. face: 0 top, 1 side, 2 bottom.
// `cap`: the top of a spruce's leaves, under the snow layer that lies on them.
static inline float4 bnAlbedo(int mat, int face, int biome, bool cap, int y, uint salt,
                              float2 uv, float2 dx, float2 dy,
                              texture2d_array<float> mcTiles, texture2d_array<float> mcMaps) {
    int layer;
    float3 tint = float3(1.0);
    bool grass = false;
    switch (mat) {
    case M_GRASS:      layer = face == 0 ? MC_GRASS_BLOCK_TOP : face == 2 ? MC_DIRT : MC_GRASS_BLOCK_SIDE;
                       grass = true; break;
    case M_SNOWGRASS:  layer = face == 0 ? MC_SNOW : face == 2 ? MC_DIRT : MC_GRASS_BLOCK_SNOW; break;
    case M_DIRT:       layer = MC_DIRT; break;
    case M_STONE:      layer = MC_STONE; break;
    case M_SAND:       layer = MC_SAND; break;
    case M_REDSAND:    layer = MC_RED_SAND; break;
    case M_SANDSTONE:  layer = face == 0 ? MC_SANDSTONE_TOP : face == 2 ? MC_SANDSTONE_BOTTOM : MC_SANDSTONE; break;
    case M_SNOW:       layer = MC_SNOW; break;
    case M_GRAVEL:     layer = MC_GRAVEL; break;
    case M_CLAY:       layer = MC_CLAY; break;
    case M_TERRA:      layer = bnTerraBand(y, salt); break;
    case M_OAKLOG:     layer = face == 1 ? MC_OAK_LOG : MC_OAK_LOG_TOP; break;
    case M_BIRCHLOG:   layer = face == 1 ? MC_BIRCH_LOG : MC_BIRCH_LOG_TOP; break;
    case M_SPRUCELOG:  layer = face == 1 ? MC_SPRUCE_LOG : MC_SPRUCE_LOG_TOP; break;
    case M_OAKLEAF:    layer = MC_OAK_LEAVES; {
                           float2 cl = bnClimate(biome);
                           tint = mcFoliageTint(mcMaps, cl.x, cl.y);
                       } break;
    case M_BIRCHLEAF:  layer = MC_BIRCH_LEAVES; tint = mcFromSRGB(float3(0x80, 0xA7, 0x55) / 255.0); break;
    case M_SPRUCELEAF: layer = cap ? MC_SNOW : MC_SPRUCE_LEAVES;
                       if (!cap) tint = mcFromSRGB(float3(0x61, 0x99, 0x61) / 255.0); break;
    default:           layer = face == 1 ? MC_CACTUS_SIDE : face == 0 ? MC_CACTUS_TOP : MC_CACTUS_BOTTOM; break;
    }
    if (grass && face == 1) {
        // The bank's grass side, seen edge-on as often as not.
        float2 cl = bnClimate(biome);
        return float4(mcGrassSideAniso(mcTiles, uv, dx, dy, mcGrassTint(mcMaps, cl.x, cl.y)), 1.0);
    }
    float4 c = mcTileAniso(mcTiles, layer, uv, dx, dy);
    c.rgb *= tint;
    if (grass && face == 0) {
        float2 cl = bnClimate(biome);
        c.rgb *= mcGrassTint(mcMaps, cl.x, cl.y);
    }
    return c;
}

static inline int bnHitMat(BnHit hit, BnWorld w, thread BnZ& zc, thread int& biomeOut) {
    int x = hit.cell.x, zw = bnWrapZ(hit.cell.y);
    BnRow r = bnRowAtZ(zw, w, zc);
    float dn = bnDn(x, r);
    if (hit.span == 1) {
        biomeOut = bnBiome(bnFOf(r, dn, zc), 0.0);
        bool log = hit.by < hit.split;
        switch (hit.tree) {
        case 0:  return log ? M_OAKLOG : M_OAKLEAF;
        case 1:  return log ? M_BIRCHLOG : M_BIRCHLEAF;
        case 2:  return log ? M_SPRUCELOG : M_SPRUCELEAF;
        default: return M_CACTUS;
        }
    }
    int b = bnBiome(bnFOf(r, dn, zc), bnJitter(x, zw, w));
    biomeOut = b;
    int h = hit.h;
    uint bh = bnH3(x, zw, w.salt ^ 0x3C3Cu);
    return bnGroundMat(b, h, h - 1 - hit.by, hit.by, dn, bh);
}

// A face's texture coordinates, top row of the picture at v = 0, and their
// change across one screen pixel from the ray differentials dRx, dRy.
static inline float2 bnFaceUV(float3 P, float3 n, int by, float3 rd, float t, float3 dRx, float3 dRy,
                              thread float2& dx, thread float2& dy) {
    float dd = dot(rd, n);
    dd = abs(dd) < 1e-3 ? (dd < 0.0 ? -1e-3 : 1e-3) : dd;
    float3 px = t * (dRx - rd * (dot(dRx, n) / dd));
    float3 py = t * (dRy - rd * (dot(dRy, n) / dd));
    if (abs(n.y) > 0.5) { dx = px.xz; dy = py.xz; return P.xz; }
    float v = 1.0 - (P.y - float(by));
    if (abs(n.x) > 0.5) { dx = px.zy; dy = py.zy; return float2(P.z, v); }
    dx = px.xy; dy = py.xy;
    return float2(P.x, v);
}

// Leaves and cactus carry their shape in alpha (a spruce's snow cap does not).
static inline bool bnCutout(BnHit h) {
    if (h.span != 1 || h.tree < 0) return false;
    if (h.tree == 3) return true;
    if (h.by < h.split) return false;
    return !(h.tree == 2 && h.n.y > 0.5 && h.by == h.top - 1);
}

// ---------------------------------------------------------------------------
// Light, sky and fog, as the game draws a clear day.

// The game's lightmap at noon for sky light `level`, no block light.
static inline float3 bnLightmap(float level) { return mcLightmap(0.0, level, 1.0, 0.0); }

static inline float bnGroundAt(int x, int z, BnWorld w, thread BnZ& zc) {
    int zw = bnWrapZ(z);
    BnRow r = bnRowAtZ(zw, w, zc);
    return float(bnGroundH(x, zw, bnDn(x, r), r, w));
}

// Smooth lighting: each corner of a face takes the mean of four light
// samples, the open block in front of the face and the two edge and one
// corner neighbours beside that corner, an opaque one counting 0.2 (the
// corner too when both edges are opaque); the face blends its corners.
static inline float bnAOv(bool a, bool b, bool c) {
    return (1.0 + (a ? 0.2 : 1.0) + (b ? 0.2 : 1.0) + ((a && b) || c ? 0.2 : 1.0)) * 0.25;
}

static inline float bnTopAO(float3 P, int2 cell, int h, BnWorld w, thread BnZ& zc) {
    float fh = float(h);
    bool o[9];
    for (int j = 0; j < 9; ++j) {                 // rows in z order, so the knot cache holds
        int dx = j % 3 - 1, dz = j / 3 - 1;
        o[j] = j != 4 && bnGroundAt(cell.x + dx, cell.y + dz, w, zc) > fh;
    }
    float2 f = P.xz - float2(cell);
    float v00 = bnAOv(o[3], o[1], o[0]), v10 = bnAOv(o[5], o[1], o[2]);
    float v01 = bnAOv(o[3], o[7], o[6]), v11 = bnAOv(o[5], o[7], o[8]);
    return mix(mix(v00, v10, f.x), mix(v01, v11, f.x), f.y);
}

// A ground side face of block (cell, by), facing column F (the one the ray
// came from, ground height hF <= by): the block under the face's front is
// solid when hF == by, and the columns either side of F decide the rest.
static inline float bnSideAO(float3 P, BnHit hit, BnWorld w, thread BnZ& zc) {
    int2 nd = int2(int(round(hit.n.x)), int(round(hit.n.z)));
    int2 F = hit.cell + nd, l = int2(abs(nd.y), abs(nd.x));
    float by = float(hit.by);
    float hm = bnGroundAt(F.x - l.x, F.y - l.y, w, zc), hp = bnGroundAt(F.x + l.x, F.y + l.y, w, zc);
    bool B = hit.prevH >= hit.by;
    float vbm = bnAOv(B, hm > by, hm >= by),       vbp = bnAOv(B, hp > by, hp >= by);
    float vtm = bnAOv(false, hm > by, hm > by + 1.0), vtp = bnAOv(false, hp > by, hp > by + 1.0);
    float u = dot(P.xz - float2(hit.cell), float2(l)), v = P.y - by;
    return mix(mix(vbm, vbp, u), mix(vtm, vtp, u), v);
}

// The sky's gradient: the fog colour at the horizon to the sky colour above.
// The fog colour is the game's, blended toward the sky as the game does at a
// short render distance.
static inline float3 bnSkyBase(float3 rd) {
    float3 sky = mcSkyAt(1.0);
    float3 fog = mix(mcFogAt(1.0), sky, 0.23);
    return mix(fog, sky, smoothstep(-0.02, 0.30, rd.y));
}

static inline float3 bnSky(float3 rd, float3 L, float3 ro, BnWorld w, float now, float pxAngle,
                           texture2d_array<float> mcSkins, texture2d_array<float> mcMaps) {
    float3 col = bnSkyBase(rd);
    // The sun: the game's square texture on a quad 30 wide at 100 away,
    // added to the sky.
    float cs = dot(rd, L);
    if (cs > 0.9) {
        float3 sx = normalize(cross(float3(0.0, 1.0, 0.0), L));
        float3 sy = cross(L, sx);
        float2 q = float2(dot(rd, sx), dot(rd, sy)) / cs;
        if (max(abs(q.x), abs(q.y)) < 0.15) {
            float2 px = (q / 0.3 + 0.5) * MCS_ENVIRONMENT_CELESTIAL_SUN_SIZE;
            col += mcSkin(mcSkins, MCS_ENVIRONMENT_CELESTIAL_SUN, px,
                          pxAngle * MCS_ENVIRONMENT_CELESTIAL_SUN_SIZE.x / 0.3).rgb;
        }
    }
    // The flat cloud layer: one pixel of clouds.png is twelve blocks, white
    // at 80%, drifting with the wind.
    if (rd.y > 0.0) {
        float tc = (BN_CLOUDY - ro.y) / rd.y;
        float2 cp = (ro.xz + rd.xz * tc + float2(now * 0.6 + w.gp.w, 0.0)) / 12.0;
        cp = float2(glmod(cp.x, 256.0), glmod(cp.y, 256.0));
        float pw = tc * pxAngle / (12.0 * sqrt(max(rd.y, 0.02)));
        float a = mcMap(mcMaps, MCM_ENVIRONMENT_CLOUDS, cp, pw).a;
        col = mix(col, float3(1.0), 0.8 * a * smoothstep(0.03, 0.12, rd.y));
    }
    return col;
}

// How much fog lies over something t away: none near, total at the view
// distance, and steepening late so the near banks keep their contrast.
static inline float bnFogAmt(float t) { return pow(smoothstep(BN_FOG0, BN_FAR, t), 1.4); }

// A solid hit, lit as the game lights it by day: the face's texture, its
// fixed face shade, smooth lighting near, and the sky light under leaves.
// `blur` widens the footprint (leaves seen through too many clear texels
// show their mean, as a dense canopy does).
static inline float3 bnShade(BnHit hit, float3 ro, float3 rd, float3 dRx, float3 dRy, BnWorld w,
                             thread BnZ& zc, float blur,
                             texture2d_array<float> mcTiles, texture2d_array<float> mcMaps) {
    float3 P = ro + rd * hit.t;
    float3 n = hit.n;
    int face = n.y > 0.5 ? 0 : n.y < -0.5 ? 2 : 1;
    int biome;
    int mat = bnHitMat(hit, w, zc, biome);
    float2 dx, dy;
    float2 uv = bnFaceUV(P, n, hit.by, rd, hit.t, dRx, dRy, dx, dy);
    bool cap = mat == M_SPRUCELEAF && face == 0 && hit.by == hit.top - 1;
    float3 alb = bnAlbedo(mat, face, biome, cap, hit.by, w.salt, uv, dx * blur, dy * blur, mcTiles, mcMaps).rgb;

    // Smooth lighting, near the eye and above the water (under it the water
    // covers it, and far off the fog does).
    float ao = 1.0;
    float nearW = 1.0 - smoothstep(BN_NEAR - 4.0, BN_NEAR, hit.t);
    if (P.y > BN_WL && nearW > 0.0 && hit.span == 0 && hit.lod == 0) {
        if (face == 0) ao = bnTopAO(P, hit.cell, hit.by + 1, w, zc);
        else if (face == 1) ao = bnSideAO(P, hit, w, zc);
        ao = mix(1.0, ao, nearW);
    }
    // Leaves let sky light through less a block, and it spreads back in from
    // the open sides: ground under a canopy sits about two levels down.
    float3 light = bnLightmap(hit.canopy == 1 ? 13.0 : 15.0);
    return alb * mcFaceShade(n) * ao * light;
}

// ---------------------------------------------------------------------------

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]],
                        texture2d_array<float> mcTiles [[texture(8)]],
                        texture2d_array<float> mcSkins [[texture(10)]],
                        texture2d_array<float> mcMaps  [[texture(11)]]) {
    BnWorld w;
    uint salt = bnHash(uint(u.seed * 4294967040.0) ^ 0x2545F491u);
    w.salt = salt;
    // Phases in cycles (see bnSinC).
    w.rp = float4(bnR(bnHash(salt + 1u)), bnR(bnHash(salt + 2u)), bnR(bnHash(salt + 3u)), bnR(bnHash(salt + 4u)));
    w.fp = float4(bnR(bnHash(salt + 5u)), bnR(bnHash(salt + 6u)), bnR(bnHash(salt + 7u)), bnR(bnHash(salt + 8u)));
    w.gp = float4(bnR(bnHash(salt + 9u)), bnR(bnHash(salt + 10u)),
                  bnR(bnHash(salt + 11u)), bnR(bnHash(salt + 12u)) * 400.0);
    w.region = u.region;
    w.so = float2(float(salt & 1023u), float((salt >> 10) & 1023u)) * 0.6180339;
    BnZ zc;
    zc.k = -1;
    float now = u.time;

    // The sun, high in the afternoon over one shoulder.
    float side = w.gp.z < 0.5 ? -1.0 : 1.0;
    float3 L = normalize(float3(0.72 * side, 0.66, -0.36));

    // --- Camera: drifting down the middle of the river, looking along it.
    float s = glmod(now * u.speed * BN_SPEED + u.seed * float(BN_P), float(BN_P));
    float sl;
    float x0 = bnRiverX(s, w, sl);
    float za = s + 6.0, zb = s + 14.0;
    float xa = bnRiverX(za, w, sl), xb = bnRiverX(zb, w, sl);
    float3 ro = float3(x0 + 0.6 * bnSinC(now * (0.043 / TWO_PI) + w.rp.w),
                       1.65 + 0.05 * bnSinC(now * (0.7 / TWO_PI)), s);
    float3 tgt = float3(0.5 * (xa + xb), -0.15, 0.5 * (za + zb));
    float3 fwd = normalize(tgt - ro);
    float3 upHint = float3(0.0, 1.0, 0.0);
    float3 right = normalize(cross(upHint, fwd));
    float lens = lerpLook(u.yaw, u.pitch, u.magnify, upHint, right, fwd);
    float3 up = cross(fwd, right);
    float2 uv = lerpUV(pos, u.resolution);
    float3 dv = uv.x * right + uv.y * up + lens * BN_FOCAL * fwd;
    float dl = length(dv);
    float3 rd = dv / dl;
    float minRes = min(u.resolution.x, u.resolution.y);
    float pxAngle = 2.0 / (lens * BN_FOCAL * minRes);
    // The ray's change across one pixel, for the texture footprints.
    float3 dRx = (right - rd * dot(rd, right)) * (2.0 / (minRes * dl));
    float3 dRy = (up - rd * dot(rd, up)) * (2.0 / (minRes * dl));

    // --- The walk. The bed is never more than three blocks down, so a ray
    // that has gone that far under the surface has nothing left to find.
    float tW = rd.y < 0.0 ? (BN_WL - ro.y) / rd.y : 1e9;
    BnHit hit;
    float tFar = min(BN_FAR, tW - 3.2 / min(rd.y, -1e-3));
    float tB = bnGridExit(ro, rd, BN_T1, 2.0);
    float tNear = min(tFar, tB - 1e-4);
    bool solid = false;
    float blur = 1.0;
    // The boat is in open water: the columns nearer than the banks hold
    // nothing above the surface (no bank, no tree), so a ray starts walking
    // where they end, or where it meets the water if sooner. The margin
    // covers the knots' kinks in the bank line and the boat's own column; a
    // ray that starts inside a bank anyway is walked again from the boat.
    BnRow cr = bnRowAtZ(bnWrapZ(int(floor(ro.z))), w, zc);
    float clear = max((-bnDn(int(floor(ro.x)), cr) - 2.0) / 1.25, 0.0);
    float tS = min(clear / max(length(rd.xz), 1e-3), tW), tM = -1.0;
    int budget = BN_STEPS;
    float tReach = 0.0;
    for (int cut = 0; cut <= BN_CUTS; ++cut) {
        int used;
        solid = bnTrace(ro, rd, tS, tM, budget, tNear, w, zc, hit, used, tReach);
        if (cut == 0 && solid && tS > 0.0 && hit.t <= tS + 1e-4) {
            tS = 0.0; solid = false; continue;
        }
        if (!solid || !bnCutout(hit)) break;
        if (cut == BN_CUTS) { blur = 16.0; break; }
        // Leaves and cactus: a clear texel lets the ray on to the next face.
        float3 P = ro + rd * hit.t;
        float2 ddx, ddy;
        float2 fuv = bnFaceUV(P, hit.n, hit.by, rd, hit.t, dRx, dRy, ddx, ddy);
        int layer = hit.tree == 3 ? (hit.n.y > 0.5 ? MC_CACTUS_TOP : hit.n.y < -0.5 ? MC_CACTUS_BOTTOM : MC_CACTUS_SIDE)
                  : hit.tree == 2 ? MC_SPRUCE_LEAVES : hit.tree == 1 ? MC_BIRCH_LEAVES : MC_OAK_LEAVES;
        if (mcTileAniso(mcTiles, layer, fuv, ddx, ddy).a >= 0.5) break;
        tS = hit.t + 1e-3; tM = hit.t + 2e-3;
        budget = budget - used + 2;
        solid = false;
    }
    // The far walk stops at the water: under it there is only the bed.
    float tFarW = min(tFar, tW + 0.5);
    // (It starts where the near walk stopped, which is the 2x2 line unless
    // the near walk's steps ran out first.)
    float tF0 = min(tB, tReach);
    if (!solid && tFarW > tF0) solid = bnTraceFar(ro, rd, tF0, tFarW, w, zc, hit);

    float tHit = solid ? hit.t : 1e9;
    bool water = tW < tHit && tW < BN_FAR;
    if (water && !solid) {
        // The bed beyond the near walk: under the water the world is the
        // river's depth profile, a function of the distance from its centre
        // alone, so the top it shows is found by following the ray down
        // column to column twice. Its step faces are lost; at this distance
        // they are a few pixels under the water and the fog.
        float3 Q = ro + rd * tW;
        float hb = -1.0;
        for (int j = 0; j < 2; ++j) {
            int2 qc = int2(floor(Q.xz));
            BnRow qr = bnRowAtZ(bnWrapZ(qc.y), w, zc);
            hb = min(float(bnGroundH(qc.x, 0, bnDn(qc.x, qr), qr, w)), -1.0);
            Q = ro + rd * ((hb - ro.y) / rd.y);
        }
        hit.t = (hb - ro.y) / rd.y; hit.n = float3(0.0, 1.0, 0.0);
        hit.cell = int2(floor(Q.xz)); hit.by = int(hb) - 1; hit.h = int(hb); hit.prevH = -3;
        hit.span = 0; hit.split = 0; hit.top = 0; hit.tree = -1; hit.canopy = 0; hit.lod = 2;
        solid = hit.t < BN_FAR;
    }
    float3 fogCol = bnSkyBase(rd);

    float3 col;
    if (solid) {
        col = bnShade(hit, ro, rd, dRx, dRy, w, zc, blur, mcTiles, mcMaps);
        col = mix(col, fogCol, bnFogAmt(hit.t));
    } else if (water) {
        col = fogCol;                                     // a bed past the view distance
    } else {
        col = bnSky(rd, L, ro, w, now, pxAngle, mcSkins, mcMaps);
    }

    // --- The water: the game's still-water texture, tinted for the river
    // (the frozen river's tint in the cold) and 70% opaque over the bed.
    // Ice shelves out from the banks in the cold; lily pads float in the
    // slack water by temperate banks.
    if (water) {
        float3 Pw = ro + rd * tW;
        int2 wc = int2(floor(Pw.xz));
        int wzw = bnWrapZ(wc.y);
        BnRow wr = bnRowAtZ(wzw, w, zc);
        BnF f = bnFOf(wr, bnDn(wc.x, wr), zc);
        float jit = f.tm < 0.36 ? bnJitter(wc.x, wzw, w) : 0.0;   // (it matters only near freezing)
        float3 nUp = float3(0.0, 1.0, 0.0);
        float2 ddx, ddy;
        float2 wuv = bnFaceUV(Pw, nUp, 0, rd, tW, dRx, dRy, ddx, ddy);
        float fogW = bnFogAmt(tW);
        float3 lightW = bnLightmap(15.0);

        int frame = mcFrame(MC_WATER_STILL, MC_WATER_STILL_FRAMES, MC_WATER_STILL_TICKS, now);
        float4 wt = mcTileAniso(mcTiles, frame, wuv, ddx, ddy);
        float3 tint = mix(mcFromSRGB(float3(0x39, 0x38, 0xC9) / 255.0), MC_WATER_TINT,
                          smoothstep(0.26, 0.32, f.tm + jit));
        col = mix(col, mix(wt.rgb * tint * lightW, fogCol, fogW), wt.a);

        float freeze = 0.29 - (f.tm + jit);
        if (freeze > 0.0 && f.dn > -0.6 - 16.0 * freeze) {
            float4 it = mcTileAniso(mcTiles, MC_ICE, wuv, ddx, ddy);
            col = mix(col, mix(it.rgb * lightW, fogCol, fogW), it.a);
        } else {
            // A lily pad lies a sliver above the water block's top.
            float tL = (0.016 - ro.y) / rd.y;
            float3 Pl = ro + rd * tL;
            int2 lc = int2(floor(Pl.xz));
            int lzw = bnWrapZ(lc.y);
            uint ph = bnH3(lc.x, lzw, w.salt ^ 0x1E1Eu);
            if (tL < 24.0 && bnR(ph) < 0.16) {
                BnRow lr = bnRowAtZ(lzw, w, zc);
                BnF lf = bnFOf(lr, bnDn(lc.x, lr), zc);
                int b = bnBiome(lf, bnJitter(lc.x, lzw, w));
                if (lf.dn > -1.8 && lf.dn < -0.2 && (b == B_MEADOW || b == B_FOREST)) {
                    float2 q = fract(Pl.xz) - 0.5;
                    int rot = int((ph >> 9) & 3u);
                    if (rot & 1) q = float2(-q.y, q.x);
                    if (rot & 2) q = -q;
                    float2 lx, ly;
                    bnFaceUV(Pl, nUp, 0, rd, tL, dRx, dRy, lx, ly);
                    float4 lp = mcTileAniso(mcTiles, MC_LILY_PAD, q + 0.5, lx, ly);
                    float3 pc = lp.rgb * mcFromSRGB(float3(0x20, 0x80, 0x30) / 255.0) * lightW;
                    col = mix(col, mix(pc, fogCol, bnFogAmt(tL)), step(0.5, lp.a));
                }
            }
        }
    }

    col = lerpDither(saturate(col), pos);
    return half4(half3(col), 1.0h);
}
