// Block River — original shader written for Lerping@Home (AGPL-3.0, like the
// rest of this project). An homage to the block-built sandbox worlds: you
// drift downstream at raft height along a river that winds through a world of
// unit cubes, and the land it runs through keeps changing — meadow, birch
// wood, snowy spruce taiga with the river iced over, bare snow-capped peaks,
// sand dunes with cactus, and striped badlands canyons whose walls rise
// straight out of the water. All art is procedural and written for this file:
// no textures, characters or artwork from any game.
//
// lerp-category: Blocks
//
// How it is built:
//   - the world is a heightfield of whole blocks plus one floating span per
//     column (a trunk, a cactus or a tree's leaves), traced with a 2D grid walk
//     over columns and slab tests in y. Water is a plane at the river's level,
//     so the bed is seen through it and the banks mirrored in it.
//   - regions are slow fields (temperature, humidity, ruggedness) of the
//     distance along the river, so the journey crosses them in turn; heights
//     blend between region shapes, while materials switch with a clumped
//     per-block jitter so the borders are ragged and blocky.
//   - the river and its fields are evaluated at knots every twelve rows and
//     interpolated between them: the river is a polyline of twelve-block
//     reaches, and a walk pays for the sines once per knot, not per column.
//   - the world repeats every BN_P blocks along the river (every field is
//     periodic in z), so coordinates stay small however long it runs and the
//     drift never re-rolls: it loops once an hour, seamlessly.
//   - 16x16 texels a face, sharp up close; each texture fades to its own
//     average as a texel shrinks below a pixel, so nothing crawls at distance.
//
// Cost, at 3456x2234, about 13.5 ms a frame on an M5. The walk is in three
// bands: single blocks to BN_T1, then 2x2-block cells to BN_T2, then 4x4 to
// BN_FAR, each far cell standing for its centre column (with that column's
// tree), so thirty-odd steps reach fifty-odd blocks and every lane changes
// band at nearly the same step. Far blocks are drawn two and four wide under
// a sky-coloured haze. Water adds a short mirror walk (BN_RFAR blocks, then
// sky). There are no sun shadows: the ground under a canopy is shaded, as
// these worlds shade it.
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
constant float BN_WL     = -0.125;   // water surface (water fills blocks y < 0)
constant float BN_HMAX   = 36.0;     // nothing solid reaches above this
constant float BN_FAR    = 56.0;     // view distance
constant float BN_FOG0   = 14.0;     // haze starts
constant float BN_NEAR   = 9.0;      // corner shading fades out by here
constant float BN_T1     = 10.0;     // single blocks out to here,
constant float BN_T2     = 28.0;     // 2x2-block cells to here, then 4x4
constant int   BN_STEPS  = 14;       // single-block steps (to BN_T1)
constant int   BN_STEPS2 = 8;        // 2x2 steps (to BN_T2)
constant int   BN_STEPS4 = 7;        // 4x4 steps (to BN_FAR)
constant int   BN_RSTEPS = 8;        // reflection grid steps
constant float BN_RFAR   = 6.0;      // how far the mirror looks

constant float BN_FOCAL  = 1.55;
constant float BN_SPEED  = 1.05;     // blocks a second at speed 1
constant float BN_CLOUDY = 52.0;     // cloud layer height

// Materials.
constant int M_GRASS = 0, M_DIRT = 1, M_STONE = 2, M_SAND = 3, M_SANDSTONE = 4,
             M_SNOWGRASS = 5, M_SNOW = 6, M_GRAVEL = 7, M_CLAY = 8, M_TERRA = 9,
             M_OAKLOG = 10, M_OAKLEAF = 11, M_BIRCHLOG = 12, M_BIRCHLEAF = 13,
             M_SPRUCELOG = 14, M_SPRUCELEAF = 15, M_CACTUS = 16, M_REDSAND = 17;

// Regions.
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

// Value noise whose lattice repeats every perZ cells in z.
static inline float bnNoise(float2 p, int perZ, uint salt) {
    float2 i = floor(p);
    float2 f = p - i;
    int ix = int(i.x);
    int z0 = int(i.y) % perZ; if (z0 < 0) z0 += perZ;
    int z1 = z0 + 1;          if (z1 >= perZ) z1 = 0;
    uint hx0 = uint(ix) * 0x9E3779B1u, hx1 = hx0 + 0x9E3779B1u;
    uint hz0 = uint(z0) * 0x85EBCA77u + salt, hz1 = uint(z1) * 0x85EBCA77u + salt;
    float a = bnR(bnHash(hx0 ^ hz0)), b = bnR(bnHash(hx1 ^ hz0));
    float c = bnR(bnHash(hx0 ^ hz1)), d = bnR(bnHash(hx1 ^ hz1));
    float2 s = f * f * (3.0 - 2.0 * f);
    return mix(mix(a, b, s.x), mix(c, d, s.x), s.y);
}

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
// define the world (the river is a polyline of six-block segments), so every
// ray sees the same land, and a walk pays for the sines once per six rows
// instead of at every column.
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
    // over the same field values as the region materials, so a canyon's walls
    // are striped and a peak is stone, not tall dirt.
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
    int    tree;
    int    canopy;   // a ground hit with leaves overhead in its own column
    int    lod;      // found by the 4x4 walk, on its smoothed ground
};

static inline bool bnTrace(float3 ro, float3 rd, float tStart, int steps, float tFar, BnWorld w,
                           thread BnZ& zc, thread BnHit& hit) {
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
    for (int i = 0; i < steps; ++i) {
        float tOut = min(tMax.x, tMax.y);
        float yA = ro.y + rd.y * tIn, yB = ro.y + rd.y * tOut;
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
        if (yA < fh)      { best = tIn; n = side; }
        else if (yB < fh) { best = (fh - ro.y) / ry; }
        if (c.s1 > c.s0) {
            float s0 = float(c.s0), s1 = float(c.s1);
            float ts = 1e9;
            float3 ns = side;
            if (yA >= s0 && yA <= s1)       { ts = tIn; }
            else if (yA < s0 && yB >= s0)   { ts = (s0 - ro.y) / ry; ns = float3(0.0, -1.0, 0.0); }
            else if (yA > s1 && yB <= s1)   { ts = (s1 - ro.y) / ry; ns = float3(0.0, 1.0, 0.0); }
            if (ts < best) { best = ts; n = ns; span = 1; }
        }
        if (best < 1e8) {
            hit.t = best; hit.n = n; hit.cell = cell; hit.prevH = prevH;
            hit.span = span; hit.split = c.split; hit.tree = c.tree;
            hit.canopy = (span == 0 && c.s1 > c.s0 && c.split < 0) ? 1 : 0;
            hit.lod = 0;
            float y = ro.y + rd.y * best;
            int by;
            if (n.y > 0.5)       by = int(round(y)) - 1;
            else if (n.y < -0.5) by = int(round(y));
            else                 by = int(floor(y));
            if (span == 1) by = clamp(by, c.s0, c.s1 - 1);
            else           by = min(by, c.h - 1);
            hit.by = by;
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
    }
    return false;
}

// The far walk: the same world on a coarser grid. From BN_T1 the walk steps
// over 2x2-block cells and from BN_T2 over 4x4, each cell standing for its
// centre column: that column's ground, with its tree (if any) folded in as a
// solid box up to the canopy top. Far blocks are drawn two and four wide, at
// distances where a block is a few pixels and the haze is already thick,
// which is how these worlds draw their own distance; every lane changes grid
// at nearly the same step, so the SIMD group keeps walking together.
static inline bool bnTraceFar(float3 ro, float3 rd, float tStart, float tFar, BnWorld w,
                              thread BnZ& zc, thread BnHit& hit) {
    BnTree tc;
    tc.cell = int2(-1 << 20); tc.kind = -1; tc.c = int2(0); tc.hb = 0; tc.L = 0; tc.hs = 0u;
    float2 d2 = select(rd.xz, float2(1e-6), abs(rd.xz) < 1e-6);
    float2 inv = 1.0 / d2;
    int2 st = int2(d2.x > 0.0 ? 1 : -1, d2.y > 0.0 ? 1 : -1);
    float2 up = select(float2(0.0), float2(1.0), d2 > 0.0);
    float ry = abs(rd.y) < 1e-6 ? 1e-6 : rd.y;
    float tLim = min(tFar, rd.y > 0.0 ? (BN_HMAX - ro.y) / rd.y : 1e9);
    float tIn = tStart;
    for (int lv = 0; lv < 2; ++lv) {
        int   Si = lv == 0 ? 2 : 4;
        float S = float(Si);
        float tEnd = lv == 0 ? min(tLim, BN_T2) : tLim;
        int steps = lv == 0 ? BN_STEPS2 : BN_STEPS4;
        if (tIn >= tEnd) continue;
        int2 cc = int2(floor((ro.xz + d2 * tIn) / S));
        float2 tMax = ((float2(cc) + up) * S - ro.xz) * inv;
        float2 tDelta = abs(inv) * S;
        int axis = abs(d2.x) > abs(d2.y) ? 0 : 1;
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
            int tx = bnDiv6(x);
            float dn = bnDn(x, row);
            float ceil = row.b.w * smoothstep(0.0, row.a.w, dn);
            BnCol c = bnColumn(x, zw, 2 * k + (rz >= 6 ? 1 : 0), row, tx, dn, ceil, yLo, w, zc, tc, lv == 1);
            float3 side = axis == 0 ? float3(-float(st.x), 0.0, 0.0) : float3(0.0, 0.0, -float(st.y));
            float best = 1e9;
            float3 n = float3(0.0, 1.0, 0.0);
            int span = 0;
            float fh = float(c.h);
            if (yA < fh)      { best = tIn; n = side; }
            else if (yB < fh) { best = (fh - ro.y) / ry; }
            if (c.s1 > c.s0) {
                float s0 = float(c.s0), s1 = float(c.s1);
                float ts = 1e9;
                float3 ns = side;
                if (yA >= s0 && yA <= s1)       { ts = tIn; }
                else if (yA < s0 && yB >= s0)   { ts = (s0 - ro.y) / ry; ns = float3(0.0, -1.0, 0.0); }
                else if (yA > s1 && yB <= s1)   { ts = (s1 - ro.y) / ry; ns = float3(0.0, 1.0, 0.0); }
                if (ts < best) { best = ts; n = ns; span = 1; }
            }
            if (best < 1e8) {
                float y = ro.y + rd.y * best;
                int by = n.y > 0.5 ? int(round(y)) - 1 : n.y < -0.5 ? int(round(y)) : int(floor(y));
                by = span == 1 ? clamp(by, c.s0, c.s1 - 1) : min(by, c.h - 1);
                hit.t = best; hit.n = n; hit.cell = int2(x, z); hit.prevH = -3;
                // A far cell that samples a trunk shows bark only at its
                // foot: two blocks wide, a whole trunk reads as a pillar.
                hit.span = span; hit.split = min(c.split, c.s0 + 2); hit.tree = c.tree; hit.canopy = 0;
                hit.lod = lv;
                hit.by = by;
                return true;
            }
            tIn = tOut;
            if (tIn > tEnd) break;
            if (tMax.x < tMax.y) { tMax.x += tDelta.x; cc.x += st.x; axis = 0; }
            else                 { tMax.y += tDelta.y; cc.y += st.y; axis = 1; }
        }
        tIn = max(tIn, tEnd);
    }
    return false;
}

// ---------------------------------------------------------------------------
// Materials and textures. Colours are sRGB here; bnLin converts.

static inline float3 bnLin(float3 c) { return pow(c, 2.2); }

static inline float3 bnTerraBand(int y, uint salt) {
    const float3 bands[7] = {
        float3(0.60, 0.35, 0.25), float3(0.72, 0.42, 0.17), float3(0.80, 0.68, 0.60),
        float3(0.53, 0.42, 0.38), float3(0.60, 0.27, 0.20), float3(0.78, 0.57, 0.22),
        float3(0.38, 0.26, 0.20) };
    uint h = bnH3(y, 77, salt ^ 0xBAD5u);
    int k = bnR(h) < 0.45 ? 0 : 1 + int(bnR(bnHash(h)) * 5.99);
    return bands[k];
}

// The material of a ground block, `depth` blocks below its column's top.
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

// One face texel of a material. ti is the texel (v counts up from the bottom
// on side faces), face 0 top, 1 side, 2 bottom. `avg` gets the texture's mean.
static inline float3 bnTexel(int mat, int face, int2 ti, uint bh, int y, uint salt,
                             thread float3& avg) {
    uint v4 = bh & 3u;                                    // four variants a material
    float r  = bnR(bnH3(ti.x + 16 * ti.y, int(v4) + 4 * mat, 0x9E37u));
    float r2 = bnR(bnH3(ti.y + 16 * ti.x, int(v4) + 4 * mat, 0x1234u));
    float rc = bnR(bnH3(ti.x, int(v4) + 4 * mat, 0x55AAu));   // per texel column
    const float3 dirt = float3(0.53, 0.38, 0.26), grass = float3(0.42, 0.62, 0.26);
    float3 c;
    switch (mat) {
    case M_GRASS:
    case M_SNOWGRASS: {
        bool snow = mat == M_SNOWGRASS;
        float3 top = snow ? float3(0.93, 0.95, 0.98) : grass;
        if (face == 0) {
            c = top * (snow ? 0.94 + 0.08 * r : 0.80 + 0.32 * r);
            if (!snow && r2 < 0.08) c = float3(0.55, 0.70, 0.30);
            avg = top * (snow ? 0.98 : 0.97);
        } else if (face == 2) {
            c = dirt * (0.78 + 0.36 * r); avg = dirt * 0.96;
        } else {
            int fh = 13 - int(rc * 2.99) + (snow ? 1 : 0);
            bool fr = ti.y >= fh;
            c = fr ? top * (snow ? 0.92 + 0.08 * r : 0.72 + 0.26 * r) : dirt * (0.78 + 0.36 * r);
            if (!fr && r2 < 0.07) c = dirt * 0.55;
            avg = mix(dirt * 0.94, top * 0.88, snow ? 0.12 : 0.17);
        }
        break;
    }
    case M_DIRT:
        c = dirt * (0.78 + 0.36 * r); if (r2 < 0.07) c = dirt * 0.55;
        avg = dirt * 0.94; break;
    case M_STONE: {
        float b = bnNoise(float2(ti) * 0.45 + float2(float(v4) * 9.0), 1 << 20, 0x5707u);
        c = float3(0.50, 0.50, 0.51) * (0.78 + 0.30 * b + 0.12 * r);
        avg = float3(0.50, 0.50, 0.51) * 0.99; break;
    }
    case M_SAND:
    case M_REDSAND: {
        float3 b = mat == M_SAND ? float3(0.86, 0.80, 0.60) : float3(0.74, 0.43, 0.22);
        c = b * (0.90 + 0.14 * r); if (r2 < 0.05) c *= 0.85;
        avg = b * 0.96; break;
    }
    case M_SANDSTONE: {
        float3 b = float3(0.85, 0.76, 0.55);
        if (face == 1) {
            c = b * (0.92 + 0.08 * r);
            if (ti.y >= 13) c = b * 1.04;
            if (ti.y == 12 || ti.y == 4) c = b * 0.82;
        } else c = b * (0.95 + 0.07 * r);
        avg = b * 0.97; break;
    }
    case M_SNOW:
        c = float3(0.93, 0.95, 0.98) * (0.94 + 0.08 * r); avg = float3(0.93, 0.95, 0.98) * 0.98; break;
    case M_GRAVEL: {
        float g = bnR(bnH3(ti.x >> 1, (ti.y >> 1) + 8 * int(v4), 0x6A7Eu));
        float3 b = g < 0.33 ? float3(0.62, 0.60, 0.58) : g < 0.66 ? float3(0.45, 0.43, 0.42) : float3(0.55, 0.49, 0.44);
        c = b * (0.9 + 0.2 * r); avg = float3(0.54, 0.51, 0.48); break;
    }
    case M_CLAY:
        c = float3(0.62, 0.65, 0.71) * (0.92 + 0.12 * r); avg = float3(0.62, 0.65, 0.71) * 0.98; break;
    case M_TERRA: {
        float3 b = bnTerraBand(y, salt);
        c = b * (0.93 + 0.10 * r); avg = b * 0.98; break;
    }
    case M_OAKLOG:
    case M_BIRCHLOG:
    case M_SPRUCELOG: {
        float3 bark = mat == M_OAKLOG ? float3(0.42, 0.32, 0.20)
                    : mat == M_BIRCHLOG ? float3(0.86, 0.85, 0.80) : float3(0.30, 0.21, 0.13);
        float3 core = mat == M_SPRUCELOG ? float3(0.50, 0.38, 0.24) : float3(0.68, 0.55, 0.34);
        if (face != 1) {
            float2 q = float2(ti) - 7.5;
            float d = max(abs(q.x), abs(q.y));
            c = d > 6.5 ? bark * 0.9 : core * (int(d) % 2 == 0 ? 1.0 : 0.85);
            avg = mix(core * 0.92, bark * 0.9, 0.2);
        } else if (mat == M_BIRCHLOG) {
            c = bark * (0.92 + 0.08 * r);
            float m = bnR(bnH3(ti.x >> 2, ti.y, 0xB1C4u + v4));
            if (m < 0.16) c = float3(0.16, 0.15, 0.14);
            avg = bark * 0.85;
        } else {
            c = bark * (0.70 + 0.45 * rc) * (0.92 + 0.12 * r);
            avg = bark * 0.95;
        }
        break;
    }
    case M_OAKLEAF:
    case M_BIRCHLEAF:
    case M_SPRUCELEAF: {
        float3 b = mat == M_OAKLEAF ? float3(0.26, 0.48, 0.16)
                 : mat == M_BIRCHLEAF ? float3(0.42, 0.58, 0.26) : float3(0.20, 0.34, 0.24);
        c = b * (0.62 + 0.62 * r);
        if (r2 < 0.2) c = b * 0.35;
        avg = b * 0.80;
        if (mat == M_SPRUCELEAF) {
            // Spruce only grows in the cold: snow lies on its tiers.
            const float3 snow = float3(0.90, 0.93, 0.97);
            int sh = 14 - int(rc * 2.99);
            if (face == 0 && r2 > 0.12)  c = snow * (0.92 + 0.08 * r);
            if (face == 1 && ti.y >= sh) c = snow * (0.90 + 0.08 * r);
            avg = face == 0 ? mix(avg, snow * 0.96, 0.88) : face == 1 ? mix(avg, snow * 0.94, 0.13) : avg;
        }
        break;
    }
    default: {   // cactus
        float3 b = float3(0.33, 0.55, 0.22);
        if (face == 1) {
            c = b * ((ti.x & 3) == 0 ? 0.7 : 0.95 + 0.1 * r);
            if (r2 < 0.04) c = float3(0.85, 0.85, 0.65);
            avg = b * 0.9;
        } else { c = b * (0.9 + 0.15 * r); avg = b * 0.95; }
        break;
    }
    }
    return c;
}

// ---------------------------------------------------------------------------
// Sky, light and fog.

struct BnLight { float3 L; float3 sun; float3 amb; float3 hor; float3 zen; };

// The sky's gradient and the glow round the sun, without sun or clouds.
static inline float3 bnSkyBase(float3 rd, BnLight lt) {
    float h = saturate(rd.y);
    float3 col = mix(lt.hor, lt.zen, pow(h, 0.6));
    if (rd.y < 0.0) col = lt.hor * (1.0 + 0.6 * rd.y);
    float sd = max(dot(rd, lt.L), 0.0);
    return col + float3(1.0, 0.75, 0.45) * (0.18 * pow(sd, 6.0) + 0.25 * pow(sd, 60.0));
}

static inline float3 bnSky(float3 rd, BnLight lt, float3 ro, BnWorld w, float now, bool clouds) {
    float3 col = bnSkyBase(rd, lt);
    // A square sun.
    float3 sx = normalize(cross(float3(0.0, 1.0, 0.0), lt.L));
    float3 sy = cross(lt.L, sx);
    float2 q = float2(dot(rd, sx), dot(rd, sy));
    if (dot(rd, lt.L) > 0.0 && max(abs(q.x), abs(q.y)) < 0.045) col = float3(1.6, 1.45, 1.1);
    if (clouds && rd.y > 0.01) {
        float tc = (BN_CLOUDY - ro.y) / rd.y;
        float2 cp = ro.xz + rd.xz * tc + float2(now * 0.6 + w.gp.w, 0.0);
        float2 cc = floor(cp / 12.0);
        float2 cg = float2(glmod(cc.x, 4096.0), glmod(cc.y, 4096.0));
        float cov = bnNoiseF(cg * 0.21, 1e9, w.so + 9.0) + 0.35 * hash21(cg + w.so);
        // Far cells shrink below a pixel and would sparkle (most of all in the
        // water's grazing mirror), so the layer thins out with distance.
        // Judged per cell, so whole blocks of cloud thin out, not a circle.
        float2 cd = (cc + 0.5) * 12.0 - (ro.xz + float2(now * 0.6 + w.gp.w, 0.0));
        float a = step(0.9, cov) * step(hash21(cg + w.so + 3.0), 1.0 - smoothstep(80.0, 240.0, length(cd)));
        col = mix(col, float3(0.98, 0.98, 1.0) * mix(0.9, 1.15, saturate(dot(lt.L, float3(0, 1, 0)))), a * 0.9);
    }
    return col;
}

// How much haze lies over something t away: none near, total at the view
// distance, and steepening late so the near banks keep their contrast.
static inline float bnFogAmt(float t) { return pow(smoothstep(BN_FOG0, BN_FAR, t), 1.4); }

// The haze is the sky's own colour in that direction, so what reaches the
// view distance has already dissolved into the sky behind it: no edge where
// the walk stops.
static inline float3 bnFog(float3 rd, BnLight lt) { return bnSkyBase(rd, lt); }

// Classic per-face light: tops brightest, the two side axes apart, bottoms dim.
static inline float bnFaceShade(float3 n) {
    return n.y > 0.5 ? 1.0 : n.y < -0.5 ? 0.55 : abs(n.x) > 0.5 ? 0.72 : 0.86;
}

static inline int bnHitMat(BnHit hit, BnWorld w, thread BnZ& zc, thread int& biomeOut) {
    int x = hit.cell.x, zw = bnWrapZ(hit.cell.y);
    if (hit.span == 1) {
        biomeOut = -1;
        bool log = hit.by < hit.split;
        switch (hit.tree) {
        case 0:  return log ? M_OAKLOG : M_OAKLEAF;
        case 1:  return log ? M_BIRCHLOG : M_BIRCHLEAF;
        case 2:  return log ? M_SPRUCELOG : M_SPRUCELEAF;
        default: return M_CACTUS;
        }
    }
    BnRow r = bnRowAtZ(zw, w, zc);
    float dn = bnDn(x, r);
    int b = bnBiome(bnFOf(r, dn, zc), bnJitter(x, zw, w));
    biomeOut = b;
    int h = bnGroundH(x, zw, dn, r, w, hit.lod == 1);
    uint bh = bnH3(x, zw, w.salt ^ 0x3C3Cu);
    return bnGroundMat(b, h, h - 1 - hit.by, hit.by, dn, bh);
}

static inline float bnGroundAt(int x, int z, BnWorld w, thread BnZ& zc) {
    int zw = bnWrapZ(z);
    BnRow r = bnRowAtZ(zw, w, zc);
    return float(bnGroundH(x, zw, bnDn(x, r), r, w));
}

// Darkening on a ground top along the edges that a higher neighbour stands
// over; where two such edges meet, the corner gets both.
static inline float bnTopAO(float3 P, int2 cell, int h, BnWorld w, thread BnZ& zc) {
    float2 f = P.xz - float2(cell);
    float fh = float(h);
    float occ = 0.0;
    float e[4] = { 1.0 - f.x, f.x, 1.0 - f.y, f.y };
    const int2 o[4] = { int2(1, 0), int2(-1, 0), int2(0, 1), int2(0, -1) };
    for (int k = 0; k < 4; ++k)
        if (bnGroundAt(cell.x + o[k].x, cell.y + o[k].y, w, zc) > fh)
            occ += 1.0 - smoothstep(0.0, 0.55, e[k]);
    return 1.0 - 0.42 * saturate(occ);
}

// What a solid hit looks like before light: albedo (linear), normal and
// occlusion. `full` is the textured, occluded form for the pixel's own
// surface; the mirrored world in the water uses each texture's average.
struct BnSurf { float3 alb; float3 n; float ao; float3 P; };

static inline BnSurf bnSurface(BnHit hit, float3 ro, float3 rd, float pxAngle, BnWorld w,
                               bool full, thread BnZ& zc) {
    BnSurf s;
    float3 P = ro + rd * hit.t;
    float3 n = hit.n;
    int face = n.y > 0.5 ? 0 : n.y < -0.5 ? 2 : 1;
    int biome;
    int mat = bnHitMat(hit, w, zc, biome);
    int zw = bnWrapZ(hit.cell.y);
    uint bh = bnH3(hit.cell.x * 31 + hit.by, zw, w.salt ^ 0xF00Du);

    float2 uv;
    // Within the block under the hit (a far cell is several blocks wide).
    if (face != 1)            uv = fract(P.xz);
    else if (abs(n.x) > 0.5)  uv = float2(fract(P.z), P.y - float(hit.by));
    else                      uv = float2(fract(P.x), P.y - float(hit.by));
    int2 ti = clamp(int2(floor(uv * 16.0)), int2(0), int2(15));
    float3 avg;
    float3 alb = bnTexel(mat, face, ti, bh, hit.by, w.salt, avg);
    float cosi = max(abs(dot(rd, n)), 0.12);
    float fwTex = hit.t * pxAngle / cosi * 16.0;
    s.alb = bnLin(mix(alb, avg, full ? smoothstep(0.45, 1.3, fwTex) : 1.0));

    // Occlusion: under water the bed gets none, and far off it fades out
    // (the fog is thick there) so its lookups are not paid for.
    float ao = 1.0;
    float nearW = 1.0 - smoothstep(BN_NEAR - 8.0, BN_NEAR, hit.t);
    if (full && P.y > BN_WL && nearW > 0.0 && hit.span == 0) {
        if (face == 0) ao = bnTopAO(P, hit.cell, hit.by + 1, w, zc);
        else if (face == 1)
            ao = 1.0 - 0.38 * (1.0 - smoothstep(0.0, 0.6, P.y - max(float(hit.prevH), BN_WL)));
        ao = mix(1.0, ao, nearW);
    }
    s.n = n; s.ao = ao; s.P = P;
    return s;
}

static inline float3 bnLit(BnSurf s, float shadow, BnLight lt) {
    float lam = max(dot(s.n, lt.L), 0.0) * shadow;
    return s.alb * (lt.amb * bnFaceShade(s.n) * s.ao + lt.sun * lam * mix(0.6, 1.0, s.ao));
}

// ---------------------------------------------------------------------------
//
// Each pixel walks the grid at most twice: once for what it sees, and once
// more for either the sun (on land, to find its shadow) or the mirror (on
// water, to find what is reflected). A pixel never needs both, so there is
// one call site for each walk and the shader stays small.

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
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

    // Light: a high-afternoon sun over one shoulder, so the faces you see are lit.
    BnLight lt;
    float side = w.gp.z < 0.5 ? -1.0 : 1.0;
    lt.L = normalize(float3(0.72 * side, 0.66, -0.36));
    lt.sun = float3(1.0, 0.90, 0.74) * 1.55;
    lt.amb = float3(0.58, 0.68, 0.86) * 0.62;
    lt.hor = bnLin(float3(0.62, 0.71, 0.82));
    lt.zen = bnLin(float3(0.26, 0.42, 0.74));

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
    float3 rd = normalize(uv.x * right + uv.y * up + lens * BN_FOCAL * fwd);
    float pxAngle = 2.0 / (lens * BN_FOCAL * min(u.resolution.x, u.resolution.y));

    // --- First walk. The bed is never more than three blocks down, so a ray
    // that has gone that far under the surface has nothing left to find.
    float tW = rd.y < 0.0 ? (BN_WL - ro.y) / rd.y : 1e9;
    BnHit hit;
    float tFar = min(BN_FAR, tW - 3.2 / min(rd.y, -1e-3));
    bool solid = bnTrace(ro, rd, 0.0, BN_STEPS, min(tFar, BN_T1), w, zc, hit);
    if (!solid && tFar > BN_T1) solid = bnTraceFar(ro, rd, BN_T1, tFar, w, zc, hit);

    float tHit = solid ? hit.t : 1e9;
    bool water = tW < tHit && tW < BN_FAR;

    // --- The water's surface: ice or ripples, the mirror ray, Fresnel.
    float3 Pw = ro + rd * min(tW, BN_FAR);
    int2 wc = int2(floor(Pw.xz));
    int wzw = bnWrapZ(wc.y);
    float fwTexW = tW * pxAngle / max(-rd.y, 0.05) * 16.0;
    bool ice = false;
    float3 nW = float3(0.0, 1.0, 0.0), R = rd;
    float fres = 0.0;
    BnF f;
    float2 tq = float2(0.0), tpos = float2(0.0);
    if (water) {
        BnRow wr = bnRowAtZ(wzw, w, zc);
        f = bnFOf(wr, bnDn(wc.x, wr), zc);
        // Ice shelves out from the banks as it gets colder, leaving an open
        // channel down the middle.
        float freeze = 0.29 - (f.tm + bnJitter(wc.x, wzw, w));
        ice = freeze > 0.0 && f.dn > -0.6 - 16.0 * freeze;
        // Ripples: one tilt per texel, drifting downstream, calmer as texels shrink.
        tq = floor(Pw.xz * 16.0 + float2(0.0, -now * 4.0));
        tpos = float2(tq.x, float(int(tq.y) % (BN_P * 16)));
        float tnow = glmod(now, 1000.0);   // keeps the noise coordinates small; the seam is a ripple's twitch
        float rn = bnNoiseF(float2(tpos.x * 0.19 + tnow * 0.35, glmod(tpos.y * 0.19 + tnow * 0.2, 1e4)), 1e9, w.so + 3.0);
        float rm = bnNoiseF(float2(tpos.x * 0.23 + 57.0, glmod(tpos.y * 0.23 + tnow * 0.3, 1e4)), 1e9, w.so + 5.0);
        float amp = (ice ? 0.0 : 0.022) * (1.0 - smoothstep(0.4, 1.6, fwTexW));
        nW = normalize(float3((rn - 0.5) * amp * 2.0, 1.0, (rm - 0.5) * amp * 2.0));
        R = reflect(rd, nW);
        R.y = max(R.y, 0.004);
        fres = saturate(0.03 + 0.97 * pow(1.0 - dot(-rd, nW) * 0.999, 5.0));
    }
    // The bed shows only in clear, shallow-looking water.
    float kBed = (water && solid && !ice) ? exp(-(hit.t - tW) * 0.9) : 0.0;
    bool main = solid && (!water || kBed * (1.0 - fres) > 0.01);

    // --- The pixel's own surface, textured.
    BnSurf ms;
    ms.alb = float3(0.0); ms.n = float3(0.0, 1.0, 0.0); ms.ao = 1.0; ms.P = ro;
    if (main) ms = bnSurface(hit, ro, rd, pxAngle, w, true, zc);

    // --- Light. No shadow walk (it did not fit the frame budget): the ground
    // under a canopy is shaded, as block worlds shade it, and faces turned
    // from the sun take sky light only.
    float shadow = main && hit.canopy == 1 ? 0.25 : 1.0;
    float3 mainCol = bnLit(ms, shadow, lt);

    // --- Second walk, from water: what the mirror shows. Looking steeply
    // down, the mirror carries under a sixth of the light and shows sky only.
    bool wantMirror = water && rd.y > -0.35;
    float3 o2 = Pw + float3(0.0, 0.003, 0.0);
    float3 d2 = R;
    BnHit h2;
    bool hit2 = wantMirror && bnTrace(o2, d2, 0.0, BN_RSTEPS, min(BN_FAR - tW, BN_RFAR), w, zc, h2);

    // --- What the mirror shows, or the sky above.
    float3 col;
    bool skyNeeded = water ? !hit2 : !solid;
    float3 skyCol = float3(0.0);
    if (skyNeeded) skyCol = bnSky(water ? R : rd, lt, water ? Pw : ro, w, now, true);
    float3 refl = skyCol;
    if (water && hit2) {
        BnSurf rs = bnSurface(h2, o2, d2, pxAngle, w, false, zc);
        refl = mix(bnLit(rs, 1.0, lt), bnFog(R, lt), bnFogAmt(tW + h2.t));
    }

    float tFog;
    if (water) {
        if (ice) {
            // Pale, faintly cracked ice; a dim mirror.
            int2 ti = int2(floor(fract(Pw.xz) * 16.0));
            uint ih = bnH3(wc.x, wzw, w.salt ^ 0x1CEu);
            float r = bnR(bnH3(ti.x + 16 * ti.y, int(ih & 3u), 0x1CE5u));
            const float3 iceC = float3(0.52, 0.66, 0.86);
            float3 ic = iceC * (0.93 + 0.08 * r);
            if (bnR(bnH3(ti.x + 3 * ti.y, int(ih & 3u), 0xC4Au)) < 0.05) ic *= 1.12;
            ic = mix(ic, iceC * 0.97, smoothstep(0.45, 1.3, fwTexW));
            float3 base = bnLin(ic) * (lt.amb * 0.9 + 0.5 * lt.sun * max(lt.L.y, 0.0));
            col = mix(base, refl, 0.22 + 0.5 * fres);
        } else {
            // Through the water: the bed, darkening with depth.
            float3 body = bnLin(float3(0.15, 0.32, 0.52)) * (lt.amb + 0.4 * lt.sun * lt.L.y);
            float3 below = main ? mix(body, mainCol * float3(0.55, 0.8, 0.9), kBed) : body;
            // The water's own lighter texels, like a painted surface.
            float tex = bnR(bnH3(int(tq.x), int(tpos.y), w.salt ^ 0x77u));
            below *= mix(1.0, 0.92 + 0.16 * tex, 1.0 - smoothstep(0.45, 1.3, fwTexW));
            col = mix(below, refl, fres);
            // Sun glints.
            float g = pow(max(dot(R, lt.L), 0.0), 900.0);
            col += lt.sun * g * (1.0 - smoothstep(0.6, 2.0, fwTexW));

            // Lily pads in the slack water near temperate banks.
            uint ph = bnH3(wc.x, wzw, w.salt ^ 0x1E1Eu);
            if (f.dn > -1.8 && bnR(ph) < 0.16) {
                int b = bnBiome(f, bnJitter(wc.x, wzw, w));
                if (b == B_MEADOW || b == B_FOREST) {
                    float2 q = fract(Pw.xz) * 16.0 - 8.0;
                    int rot = int((ph >> 9) & 3u);
                    if (rot & 1) q = float2(-q.y, q.x);
                    if (rot & 2) q = -q;
                    float2 qt = floor(q) + 0.5;                     // texel centres
                    float rr = length(qt);
                    bool notch = qt.x > 0.0 && abs(qt.y) < 0.6 + 0.35 * qt.x;
                    if (rr < 6.6 && !notch) {
                        float pr = bnR(bnH3(int(qt.x + 8.0), int(qt.y + 8.0), ph & 0xFFu));
                        float3 pc = float3(0.28, 0.50, 0.17) * (0.8 + 0.3 * pr);
                        if (abs(qt.y) < 0.6 || abs(qt.x) < 0.6) pc *= 0.82;   // veins
                        pc = mix(pc, float3(0.28, 0.50, 0.17) * 0.9, smoothstep(0.45, 1.3, fwTexW));
                        col = bnLin(pc) * (lt.amb + lt.sun * max(lt.L.y, 0.0));
                    }
                }
            }
        }
        tFog = tW;
    } else if (solid) {
        col = mainCol;
        tFog = hit.t;
    } else {
        col = skyCol;
        tFog = -1.0;
    }
    if (tFog > 0.0) col = mix(col, bnFog(rd, lt), bnFogAmt(tFog));

    col = col / (1.0 + col * 0.25);
    col = pow(max(col, 0.0), 1.0 / 2.2);
    col = lerpDither(col, pos);
    return half4(half3(col), 1.0h);
}
