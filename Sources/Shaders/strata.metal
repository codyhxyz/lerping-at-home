// Strata — a block world cut open like an ant farm.
// Original work for Lerping@Home: every block, texture and structure here is
// procedural and written for this file; no texture data or artwork from any
// game. It is a homage to the block-world idea of a ground you can dig into.
//
// lerp-category: Blocks
//
// The world is sliced along one vertical plane and the screen is the glass laid
// against the cut. You drift along it: grass and topsoil at the top, then
// stone with its seams of ore and pockets of granite and gravel, deepslate
// below that, lava pooled over bedrock at the bottom. Wherever the cut opens a
// cave you look into it. There is no sky down there: the only light is a lamp
// held up to the glass, wandering slowly about the middle of the view, so the
// caves fade into the rock the deeper they run, except where a mine gallery
// keeps its torches lit or lava glows at the bottom. Flooded caves stand
// against the glass like an aquarium.
//
// Buried in the rock, one or two to a screen: amethyst geodes sliced through
// the middle, the bones of something long, a cobblestone vault with a chest,
// timbered mine galleries (one running along the glass, one running away from
// it into the dark, torch after torch), and now and then a cellar under the
// grass with a ladder up to the light.
//
// The drift along the cut is also a slow dive: it starts at the grass, so the
// first thing you see is the ground cut open under the sky, sinks to the lava
// over five minutes and comes back up over five more. `depth` is where along
// the column the dive starts (or, with the dive off, where the camera stays),
// from the surface (0) to bedrock (1).
//
// lerp-param: depth    float 0 1     = 0    "Depth"
// lerp-param: dive     bool          = true "Dive and return"
// lerp-param: speed    float 0 2     = 0.45 "Drift (blocks/s)"
// lerp-param: light    float 0.3 2   = 1    "Brightness"
// lerp-param: parallax float 0 2     = 1    "Head parallax"
// lerp-param: yaw      float -70 70  = 0    "Turn"
// lerp-param: pitch    float -60 60  = 0    "Tilt"
// lerp-param: magnify  float -1 1.2  = 0    "Zoom"
//
// lerp-preset: Topsoil  depth=0.06, dive=false
// lerp-preset: Caves    depth=0.45, dive=false
// lerp-preset: Deep     depth=0.85, dive=false
// lerp-preset: Column   magnify=-0.7, speed=0.7
// lerp-preset: Close    magnify=0.6, speed=0.3

// --- Camera, in blocks.
constant float ST_D      = 44.0;   // eye to the glass
constant float ST_FOCAL  = 2.0;    // ~44 blocks of cut top to bottom
constant float ST_TOP    = -1.0;   // camera height at depth 0: grass in the top quarter
constant float ST_DIVE   = 600.0;  // seconds for the dive down and back
constant float ST_BOTTOM = -84.0;  // and at depth 1
constant float ST_ZMAX   = 18.0;   // how far behind the glass anything is drawn

// --- Strata, in block y.
constant int ST_DEEP    = -48;     // stone gives way to deepslate
constant int ST_LAVA    = -91;     // cave air at or below this is lava
constant int ST_BEDROCK = -100;    // solid bedrock at or below this

// --- Materials.
constant int M_AIR = 0, M_GRASS = 1, M_DIRT = 2, M_STONE = 3, M_GRANITE = 4, M_DIORITE = 5,
             M_ANDESITE = 6, M_GRAVEL = 7, M_DEEP = 8, M_BEDROCK = 9, M_TUFF = 10,
             M_COBBLE = 11, M_MOSSY = 12, M_PLANKS = 13, M_LOG = 14, M_BONE = 15,
             M_CALCITE = 16, M_AMETHYST = 17, M_BASALT = 18, M_CHEST = 19, M_CAGE = 20,
             M_LAVA = 22, M_LEAVES = 23, M_LADDER = 24, M_DRIP = 25,
             M_ORE = 32;   // + ore kind, + 8 when set in deepslate


// ---------------------------------------------------------------------------
// Hashing and noise.

static inline uint stHash(int3 p, uint s) {
    uint h = as_type<uint>(p.x) * 0x8da6b343u ^ as_type<uint>(p.y) * 0xd8163841u
           ^ as_type<uint>(p.z) * 0xcb1ab31fu ^ s * 0x9e3779b9u;
    h ^= h >> 16; h *= 0x7feb352du; h ^= h >> 15; h *= 0x846ca68bu; h ^= h >> 16;
    return h;
}
static inline float stRnd(int3 p, uint s) { return float(stHash(p, s) >> 8) * (1.0 / 16777216.0); }

// Value noise hashes in float arithmetic, four lattice corners at once: on
// this GPU 32-bit integer multiplies and divides cost several float ops. The
// salt moves each noise to its own stretch of the hash.
static inline float3 stSaltOff(uint s) {
    return float3(float(s & 1023u), float((s >> 10) & 1023u), float((s >> 20) & 1023u)) * 1.37;
}
static inline float4 stH4(float4 x, float4 y, float4 z) {
    x = fract(x * 0.1031); y = fract(y * 0.1031); z = fract(z * 0.1031);
    float4 d = x * (z + 31.32) + y * (y + 31.32) + z * (x + 31.32);
    x += d; y += d; z += d;
    return fract((x + y) * z);
}

// Value noise.
static inline float stN2(float2 q, uint s) {
    float2 i = floor(q), f = q - i;
    f = f * f * (3.0 - 2.0 * f);
    float3 o = stSaltOff(s) + float3(i, 0.0);
    float4 h = stH4(o.x + float4(0, 1, 0, 1), o.y + float4(0, 0, 1, 1), float4(o.z));
    float2 y = mix(h.xz, h.yw, f.x);
    return mix(y.x, y.y, f.y);
}

static inline float stN3(float3 q, uint s) {
    float3 i = floor(q), f = q - i;
    f = f * f * (3.0 - 2.0 * f);
    float3 o = stSaltOff(s) + i;
    float4 xs = o.x + float4(0, 1, 0, 1), ys = o.y + float4(0, 0, 1, 1);
    float4 z = mix(stH4(xs, ys, float4(o.z)), stH4(xs, ys, float4(o.z + 1.0)), f.z);
    float2 y = mix(z.xz, z.yw, f.x);
    return mix(y.x, y.y, f.y);
}

static inline float stBits(uint h, int k) { return float((h >> (8 * k)) & 255u) * (1.0 / 256.0) + (1.0 / 512.0); }

static inline int stDiv(int a, int b) { return int(floor((float(a) + 0.5) / float(b))); }

// ---------------------------------------------------------------------------
// The world.

// Ground level: the y of the grass block at column (x, z).
static inline int stHeight(int x, int z, uint s) {
    float2 q = float2(float(x), float(z));
    float h = 8.0 + 10.0 * (stN2(q / 52.0, s + 1u) - 0.5) + 4.0 * (stN2(q / 15.0, s + 2u) - 0.5);
    return int(floor(h));
}

// The cut is not perfectly flat: here and there a block or two stands proud
// of it, so the face has edges and corners like a hand-dug wall.
static inline int stCut(int x, int y, uint s) {
    uint h = stHash(int3(x >> 1, y >> 1, 5), s + 3u);
    return (stBits(h, 0) < 0.12 && ((h >> (8 + (x & 1) + 2 * (y & 1))) & 1u) != 0u) ? -1 : 0;
}

// Buried features: one or none per 26 x 18 cell of the cut.
constant int ST_FW = 26, ST_FH = 18;
constant int F_NONE = 0, F_DUNGEON = 1, F_MINE_Z = 2, F_MINE_X = 3, F_FOSSIL = 4, F_GEODE = 5;

struct StFeat { int kind; int3 o; float r; float ph; uint h; };

static inline StFeat stFeatAt(int2 cell, uint s) {
    StFeat f;
    f.kind = F_NONE;
    int yc = cell.y * ST_FH + ST_FH / 2;
    if (yc > -12 || yc < ST_BEDROCK + 12) return f;
    f.h = stHash(int3(cell, 7), s + 100u);
    float r0 = stBits(f.h, 0), r1 = stBits(f.h, 1), r2 = stBits(f.h, 2), r3 = stBits(f.h, 3);
    bool deep = yc < -60;
    // Cumulative odds: dungeon, mine along z, mine along x, fossil, geode.
    float4 cut = deep ? float4(0.09, 0.17, 0.24, 0.32) : float4(0.11, 0.22, 0.32, 0.42);
    float top = deep ? 0.48 : 0.50;
    if      (r0 < cut.x) f.kind = F_DUNGEON;
    else if (r0 < cut.y) f.kind = F_MINE_Z;
    else if (r0 < cut.z) f.kind = F_MINE_X;
    else if (r0 < cut.w) f.kind = F_FOSSIL;
    else if (r0 < top)   f.kind = F_GEODE;
    int hw = f.kind == F_MINE_X ? 12 : (f.kind == F_FOSSIL ? 11 : 6);
    int x0 = cell.x * ST_FW + hw + 1 + int(r1 * float(max(ST_FW - 2 * hw - 2, 1)));
    int y0 = cell.y * ST_FH + 5 + int(r2 * float(ST_FH - 11));
    f.o = int3(x0, y0, 0);
    f.r = 4.1 + 1.5 * r3;
    f.ph = r3 * 6.283;
    return f;
}

// What a feature puts at p: -1 nothing, M_AIR for a hollow, else a material.
static inline int stFeature(int3 p, StFeat f) {
    int3 q = p - f.o;
    if (f.kind == F_DUNGEON) {
        if (abs(q.x) > 4 || q.y < -1 || q.y > 5 || q.z < -1 || q.z > 7) return -1;
        if (abs(q.x) <= 3 && q.y >= 0 && q.y <= 4 && q.z >= 0 && q.z <= 6) {
            if (q.y == 0 && q.x == 0 && q.z == 3) return M_CAGE;
            if (q.y == 0 && ((q.x == 2 && q.z == 5) || (q.x == -3 && q.z == 2))) return M_CHEST;
            return M_AIR;
        }
        float moss = stRnd(p, f.h) + (q.y == -1 ? 0.3 : 0.0);
        return moss > 0.62 ? M_MOSSY : M_COBBLE;
    }
    if (f.kind == F_MINE_Z) {
        if (abs(q.x) > 2 || q.y < 0 || q.y > 3 || q.z < 0 || q.z > 60 || (q.z & 3) != 2) return -1;
        if (q.y == 3) return M_PLANKS;
        return abs(q.x) == 2 ? M_LOG : -1;
    }
    if (f.kind == F_MINE_X) {
        if (abs(q.x) > 12 || q.y < 0 || q.y > 2 || q.z != 2 || (q.x & 3) != 0) return -1;
        return q.y == 2 ? M_PLANKS : M_LOG;
    }
    if (f.kind == F_FOSSIL) {
        if (q.z < 0 || q.z > 1 || q.x < -10 || q.x > 11 || q.y < -5 || q.y > 4) return -1;
        int ys = int(round(1.4 * sin(float(q.x) * 0.3 + f.ph)));
        if (q.x <= 8 && q.y == ys) return M_BONE;                       // spine
        if (q.x >= -7 && q.x <= 5 && (q.x & 1) == 0) {                  // ribs
            int len = 4 - abs(q.x + 1) / 3;
            if (q.y < ys && q.y >= ys - len) return M_BONE;
        }
        int ysk = int(round(1.4 * sin(9.0 * 0.3 + f.ph)));
        if (q.x >= 9 && q.y >= ysk - 1 && q.y <= ysk + 1) {             // skull
            if (q.x == 10 && q.y == ysk) return -1;                     // eye
            return M_BONE;
        }
        return -1;
    }
    if (f.kind == F_GEODE) {
        float3 c = float3(f.o) + float3(0.5, 0.5, 0.9 + 0.6 * fract(f.ph * 3.1));
        float d = length(float3(p) + 0.5 - c);
        if (d >= f.r) return -1;
        if (d < f.r - 2.0) return M_AIR;
        if (d < f.r - 1.2) return M_AMETHYST;
        if (d < f.r - 0.55) return M_CALCITE;
        return M_BASALT;
    }
    return -1;
}

static inline StFeat stFeatOf(int3 p, uint s) {
    return stFeatAt(int2(stDiv(p.x, ST_FW), stDiv(p.y, ST_FH)), s);
}

// A cellar under the grass, with a ladder shaft up to the surface. One cell
// in two of 52 blocks has one.
struct StCellar { bool on; int3 o; int top; };
static inline StCellar stCellarOf(int x, uint s) {
    StCellar c;
    int cell = stDiv(x, 52);
    uint h = stHash(int3(cell, 0, 9), s + 120u);
    c.on = stBits(h, 0) < 0.5;
    if (!c.on) return c;
    int x0 = cell * 52 + 8 + int(stBits(h, 1) * 36.0);
    c.top = stHeight(x0 + 3, 0, s);
    c.o = int3(x0, c.top - 8, 0);
    return c;
}
static inline int stCellar(int3 p, StCellar c) {
    if (!c.on) return -1;
    int3 q = p - c.o;
    if (q.x == 3 && q.z <= 1 && q.z >= 0 && q.y >= 3 && q.y <= c.top - c.o.y) {
        return q.z == 0 ? M_AIR : M_LADDER;                              // shaft
    }
    if (abs(q.x) > 4 || q.y < -1 || q.y > 3 || q.z < -1 || q.z > 5) return -1;
    if (abs(q.x) <= 3 && q.y >= 0 && q.y <= 2 && q.z >= 0 && q.z <= 4) {
        if (q.y == 0 && q.x == -2 && q.z == 3) return M_CHEST;
        if (q.x == 2 && q.z == 4 && q.y <= 1) return M_LOG;              // barrels
        return M_AIR;
    }
    return M_PLANKS;
}

// Trees on the surface: one per 7 x 7 column cell at most, trunk inside the
// cell so the leaves never cross into the next.
static inline int stTree(int3 p, int H, uint s) {
    int2 cell = int2(stDiv(p.x, 7), stDiv(p.z, 7));
    uint h = stHash(int3(cell, 5), s + 130u);
    if (stBits(h, 0) > 0.45) return -1;
    int2 t = cell * 7 + 2 + int2(int(stBits(h, 1) * 3.0), int(stBits(h, 2) * 3.0));
    int tall = 4 + int(h >> 31);
    // Cheap reject before the ground height under the trunk is looked up.
    int2 rq = p.xz - t;
    if (abs(rq.x) > 2 || abs(rq.y) > 2 || p.y > H + tall + 4) return -1;
    int g = stHeight(t.x, t.y, s);
    int3 q = int3(p.x - t.x, p.y - g, p.z - t.y);
    if (q.x == 0 && q.z == 0 && q.y >= 1 && q.y <= tall) return M_LOG;
    int ly = q.y - tall;
    if (ly < -2 || ly > 1) return -1;
    int rad = ly >= 0 ? 1 : 2;
    if (abs(q.x) > rad || abs(q.z) > rad) return -1;
    if (abs(q.x) == rad && abs(q.z) == rad && stRnd(p, s + 131u) < 0.6) return -1;
    return M_LEAVES;
}

// --- What the glass looks into.
//
// Below ground the world behind the cut is kept as a relief: for each block
// (x, y) of the cut, how far back the first solid block lies (0 = the cut
// itself is rock, -1 = a block standing proud of it). The ray then walks the
// cut's grid in x and y, one column at a time, instead of every block in
// depth: a cave seen through the glass is its back wall and the sides of the
// columns round it, which is all a view this near head-on can show. What a
// surface is made of is still decided in three dimensions, block by block.

constant int ST_FAR  = 60;   // a passage that runs on out of sight
constant int K_ROCK = 0, K_WATER = 1, K_LAVA = 2;

struct StCol { int d; int kind; };

// How far back a feature's hollow reaches at (x, y) of the cut, or -1000 if
// (x, y) is outside it.
static inline int stFeatDepth(int x, int y, StFeat f) {
    int2 q = int2(x, y) - f.o.xy;
    if (f.kind == F_DUNGEON) {
        if (abs(q.x) > 4 || q.y < -1 || q.y > 5) return -1000;
        if (abs(q.x) > 3 || q.y < 0 || q.y > 4) return 0;
        if (q.y == 0) {
            if (q.x == 0) return 3;
            if (q.x == 2) return 5;
            if (q.x == -3) return 2;
        }
        return 7;
    }
    if (f.kind == F_MINE_Z) {
        if (abs(q.x) > 2 || q.y < -1 || q.y > 3) return -1000;
        if (abs(q.x) <= 1 && q.y >= 0 && q.y <= 2) return ST_FAR;
        return q.y == -1 ? 0 : 2;
    }
    if (f.kind == F_MINE_X) {
        if (abs(q.x) > 12 || q.y < 0 || q.y > 2) return -1000;
        return (q.x & 3) == 0 ? 2 : 3;
    }
    if (f.kind == F_GEODE) {
        float2 c = float2(f.o.xy) + 0.5;
        float d = length(float2(x, y) + 0.5 - c);
        if (d >= f.r) return -1000;
        float ri = f.r - 2.0;
        if (d >= ri) return 0;
        float zc = 0.9 + 0.6 * fract(f.ph * 3.1);
        return int(floor(zc + sqrt(ri * ri - d * d)));
    }
    return -1000;
}

static inline int stCellarDepth(int x, int y, StCellar c) {
    if (!c.on) return -1000;
    int2 q = int2(x, y) - c.o.xy;
    if (q.x == 3 && q.y >= 3 && q.y <= c.top - c.o.y) return 1;          // shaft
    if (abs(q.x) > 4 || q.y < -1 || q.y > 3) return -1000;
    if (abs(q.x) > 3 || q.y < 0 || q.y > 2) return 0;
    if (q.y == 0 && q.x == -2) return 3;                                  // chest
    if (q.x == 2 && q.y <= 1) return 4;                                   // barrels
    return 5;
}

// Ravines: one cell in three of 64 columns has a deep crack running back from
// the glass, open to the sky.
static inline bool stRavine(int x, int y, uint s) {
    int cell = stDiv(x, 64);
    uint h = stHash(int3(cell, 0, 11), s + 140u);
    if (stBits(h, 0) > 0.33) return false;
    int bottom = -26 - int(stBits(h, 2) * 22.0);
    if (y < bottom) return false;
    float xc = float(cell * 64 + 12) + stBits(h, 1) * 40.0 + 2.5 * sin(float(y) * 0.17 + float(cell));
    float w = 0.6 + 2.0 * saturate(float(y - bottom) / 36.0) + 0.5 * (stBits(stHash(int3(x, y, 3), s + 141u), 0) - 0.5);
    return abs(float(x) + 0.5 - xc) < w;
}

// Aquifers: in one 32-wide slab of the world in two, every cave below a water
// table is flooded, held at the slab's sides by a column of stone and kept
// off the lava by a floor of it.
static inline int stWaterTable(int x, uint s) {
    int cell = stDiv(x, 32);
    uint h = stHash(int3(cell, 0, 13), s + 150u);
    if (stBits(h, 0) > 0.5) return -1000;
    return -22 - int(stBits(h, 1) * 52.0);
}

// The column of the cut at (x, y), for a block below ground (y <= Hc, the
// ground level at the glass).
static inline StCol stColumn(int x, int y, int Hc, uint s) {
    StCol c; c.d = 0; c.kind = K_ROCK;
    if (y <= ST_BEDROCK) return c;
    if (y <= ST_BEDROCK + 4 && stBits(stHash(int3(x, y, 0), s + 160u), 0) < float(ST_BEDROCK + 5 - y) / 5.0) return c;
    if (y > Hc - 12) {
        int cd = stCellarDepth(x, y, stCellarOf(x, s));
        if (cd > -1000) { c.d = cd; return c; }
    }
    int fd = stFeatDepth(x, y, stFeatAt(int2(stDiv(x, ST_FW), stDiv(y, ST_FH)), s));
    if (fd > -1000) { c.d = fd; return c; }
    if (stRavine(x, y, s)) { c.d = ST_FAR; return c; }

    bool open = false;
    if (y < Hc - 3) {
        float2 q = float2(float(x), float(y)) + 0.5;
        float deep = saturate(-q.y / 80.0);
        // Chambers: the deeper into a patch of the cave field, the further
        // back its wall.
        float C = 0.62 * stN2(q / float2(17.0, 10.0), s + 20u) + 0.38 * stN2(q / float2(7.0, 4.5), s + 21u);
        float th = 0.64 - 0.02 * deep;
        if (C > th) {
            float k = (C - th) / (1.0 - th);
            c.d = 1 + int(3.0 * smoothstep(0.0, 0.1, k) + 26.0 * k + 3.0 * stN2(q / 2.6, s + 22u));
            open = true;
        } else if (C > th - 0.2) {
            // Tunnels: thin winding passages, only in the neighbourhood of
            // the chambers they lead off.
            float T = stN2(q / float2(12.0, 6.5) + 31.7, s + 23u);
            if (abs(T - 0.5) < 0.026) {
                c.d = 2 + int(9.0 * stN2(q / 4.0, s + 24u));
                open = true;
            }
        }
    }
    if (!open) { c.d = stCut(x, y, s); return c; }
    if (y <= ST_LAVA) { c.d = 0; c.kind = K_LAVA; return c; }
    int wt = stWaterTable(x, s);
    if (y <= wt) {
        int wx = x & 31;
        if (wx == 0 || wx == 31 || y <= ST_LAVA + 3) { c.d = 0; return c; }
        c.kind = K_WATER;
    }
    return c;
}

// How strongly the lava at the bottom lights the rock at (x, y). The lava
// lies where the cave field opens along the lava level, so the same field,
// read along that level, says where the glow comes from.
static inline float stLavaGlow(float x, float y, uint s) {
    if (y > float(ST_LAVA) + 30.0) return 0.0;
    float2 q = float2(x, float(ST_LAVA) - 1.5);
    float C = 0.62 * stN2(q / float2(17.0, 10.0), s + 20u) + 0.38 * stN2(q / float2(7.0, 4.5), s + 21u);
    return smoothstep(0.48, 0.64, C) * exp(-0.12 * max(y - float(ST_LAVA), 0.0));
}

static inline int stGroundAtGlass(int x, int y, uint s) {
    return y > -16 ? stHeight(x, 0, s) : 100;
}

// Above the ground the world is plain terrain and trees, walked block by block.
static inline bool stOutdoorSolid(int3 p, uint s) {
    if (p.z < 0) return false;
    int H = stHeight(p.x, p.z, s);
    if (p.y <= H) return true;
    return p.y <= H + 10 && stTree(p, H, s) >= 0;
}

// Is the block at p solid, as the trace sees it?
static inline bool stSolid(int3 p, uint s) {
    int Hc = stGroundAtGlass(p.x, p.y, s);
    if (p.y > Hc) return stOutdoorSolid(p, s);
    return p.z >= stColumn(p.x, p.y, Hc, s).d;
}

static inline int stOreKind(float y, float r) {
    // coal, iron, copper, gold, redstone, lapis, diamond, emerald
    if (y > -8.0)  return r < 0.6 ? 0 : 1;
    if (y > -32.0) return r < 0.38 ? 0 : (r < 0.66 ? 1 : (r < 0.86 ? 2 : (r < 0.93 ? 5 : 3)));
    if (y > -62.0) return r < 0.15 ? 0 : (r < 0.42 ? 1 : (r < 0.52 ? 2 : (r < 0.66 ? 5 : (r < 0.8 ? 3 : (r < 0.94 ? 4 : 7)))));
    return r < 0.14 ? 1 : (r < 0.34 ? 3 : (r < 0.62 ? 4 : (r < 0.72 ? 5 : 6)));
}

// The material of a solid block.
static inline int stMaterial(int3 p, uint s) {
    if (p.y <= ST_BEDROCK + 4) {
        if (p.y <= ST_BEDROCK || stRnd(p, s + 160u) < float(ST_BEDROCK + 5 - p.y) / 5.0) return M_BEDROCK;
    }
    int H = p.y > -16 ? stHeight(p.x, p.z, s) : 100;
    if (p.y > H) { int t = stTree(p, H, s); return t >= 0 ? t : M_LEAVES; }
    if (p.y > H - 11 && p.z <= 6) {
        int c = stCellar(p, stCellarOf(p.x, s));
        if (c > 0) return c;
    }
    int fm = stFeature(p, stFeatOf(p, s));
    if (fm > 0) return fm;
    if (p.y == H) return M_GRASS;
    // One hash per column and one per 5-block cell carry every choice below
    // (hashes are dear here; see stH4).
    uint hcol = stHash(int3(p.x, 0, p.z), s + 170u);
    if (p.y > H - 3 - int(hcol & 1u)) return M_DIRT;

    bool deep = p.y < ST_DEEP + int((hcol >> 1) & 3u);
    int base = deep ? M_DEEP : M_STONE;

    // Ore clusters, a few blocks each, in 5-block cells.
    int3 cell = int3(stDiv(p.x, 5), stDiv(p.y, 5), stDiv(p.z, 5));
    uint hc = stHash(cell, s + 180u);
    if (stBits(hc, 0) < 0.3) {
        int3 c = cell * 5 + int3(1 + int((hc >> 8) % 3u), 1 + int((hc >> 10) % 3u), int((hc >> 12) % 3u));
        int3 d = p - c;
        int r2 = 1 + int(stBits(hc, 2) * 2.6);
        if (d.x * d.x + d.y * d.y + d.z * d.z <= r2 && ((hcol >> (8 + ((p.y + p.x * 3) & 15))) & 7u) != 0u) {
            int kind = stOreKind(float(p.y), stBits(hc, 3));
            return M_ORE + kind + (deep ? 8 : 0);
        }
    }
    // Pockets of other rock.
    float3 q = float3(p) + 0.5;
    if (stN2(float2(q.x + 0.61 * q.z, q.y) / 6.0, s + 190u) > 0.79) {
        float k = stRnd(int3(stDiv(p.x, 14), stDiv(p.y, 14), stDiv(p.z, 14)), s + 191u);
        if (deep) return k < 0.35 ? M_TUFF : (k < 0.6 ? M_GRAVEL : M_CALCITE);
        if (p.y > -24 && k < 0.18) return M_DIRT;
        return k < 0.4 ? M_GRANITE : (k < 0.62 ? M_DIORITE : (k < 0.84 ? M_ANDESITE : M_GRAVEL));
    }
    // Beds: the rock is laid down in gently folded layers, a few blocks
    // thick, some of them a stone that stands out from the country rock.
    float2 xz = float2(float(p.x), float(p.z));
    float yy = float(p.y) + 18.0 * (stN2(xz / 90.0, s + 30u) - 0.5)
             + 1.4 * sin(xz.x * 0.19 + xz.y * 0.17) + 0.7 * sin(xz.x * 0.47 - xz.y * 0.4);
    int band = int(floor(yy / 7.0));
    uint hb = stHash(int3(band, 0, 21), s + 192u);
    float bk = stBits(hb, 0), bt = stBits(hb, 1);
    float within = yy / 7.0 - float(band);
    if (bk < 0.42 && within < 0.3 + 0.4 * bt) {
        float kk = bk / 0.42;
        if (deep) return kk < 0.3 ? M_CALCITE : (kk < 0.65 ? M_DRIP : M_TUFF);
        if (kk < 0.1 && within < 0.2) return M_ORE;                       // a coal seam
        return kk < 0.45 ? M_GRANITE : (kk < 0.68 ? M_DIORITE : (kk < 0.9 ? M_DRIP : M_ANDESITE));
    }
    return base;
}

// ---------------------------------------------------------------------------
// Textures: 16 x 16 texels a face, sRGB. t.y runs up the face.

static inline float stT(int2 t, uint bh, uint k) {
    uint h = (as_type<uint>(t.x) * 0x9E3779B1u) ^ (as_type<uint>(t.y) * 0x85EBCA77u) ^ (k * 0xC2B2AE3Du) ^ bh;
    h ^= h >> 15; h *= 0x2C1B3C6Du; h ^= h >> 12;
    return float(h >> 8) * (1.0 / 16777216.0);
}

static inline float3 stSpeck(float3 base, int2 t, uint bh, float amp) {
    float n1 = stT(t, bh, 0u);
    float n2 = stT(t >> 1, bh, 1u);
    return base * (1.0 - amp + amp * (1.2 * n2 + 0.8 * n1));
}

static inline float3 stStoneTex(int2 t, uint bh) {
    float3 c = stSpeck(float3(0.50, 0.50, 0.51), t, bh, 0.22);
    if (stT(int2(t.x / 3, t.y), bh, 5u) > 0.9) c *= 0.8;
    return c;
}

static inline float3 stDeepTex(int2 t, uint bh) {
    float row = stT(int2(0, t.y), bh, 6u);
    float3 c = float3(0.42, 0.42, 0.47) * (0.86 + 0.16 * row + 0.12 * stT(t, bh, 0u));
    if (stT(int2(t.x / 4, t.y), bh, 7u) > 0.78) c *= 0.75;
    return c;
}

static inline float3 stDirtTex(int2 t, uint bh) {
    float3 c = stSpeck(float3(0.53, 0.38, 0.26), t, bh, 0.25);
    float n = stT(t, bh, 8u);
    if (n > 0.92) c *= 0.68;
    if (n < 0.05) c = float3(0.62, 0.50, 0.38);
    return c;
}

static inline float3 stCobbleTex(int2 t, uint bh, bool mossy) {
    float2 p = float2(t) + 0.5;
    int2 cc = t >> 2;
    float d1 = 1e9, d2 = 1e9; float id = 0.0;
    for (int j = -1; j <= 1; ++j)
    for (int i = -1; i <= 1; ++i) {
        int2 c = cc + int2(i, j);
        int2 w = c & 3;
        float2 o = float2(c * 4) + 0.6 + 2.8 * float2(stT(w, bh, 20u), stT(w, bh, 21u));
        float d = length(p - o);
        if (d < d1) { d2 = d1; d1 = d; id = stT(w, bh, 22u); }
        else if (d < d2) d2 = d;
    }
    float3 c = float3(0.36 + 0.26 * id) * float3(1.0, 1.0, 1.02);
    if (d2 - d1 < 0.85) c = float3(0.20, 0.20, 0.21);
    if (mossy) {
        float m = stT(t >> 2, bh, 23u) * 0.7 + stT(t, bh, 24u) * 0.3 + id * 0.2;
        if (m > 0.6) c = float3(0.30, 0.42, 0.19) * (0.8 + 0.4 * stT(t, bh, 25u));
    }
    return c;
}

static inline float3 stPlankTex(int2 t, uint bh) {
    int row = t.y >> 2;
    float3 c = float3(0.62, 0.47, 0.28);
    c *= 0.88 + 0.16 * stT(int2(t.x / 3 + row * 7, row), bh, 30u) + 0.06 * stT(t, bh, 31u);
    if ((t.y & 3) == 0) c *= 0.55;
    if (t.x == int(glmod(float(row * 7 + int(bh & 7u)), 16.0))) c *= 0.6;
    return c;
}

static inline float3 stLogTex(int2 t, uint bh, int face) {
    if (face != 0) {
        float d = length(float2(t) + 0.5 - 8.0);
        if (d > 6.6) return float3(0.36, 0.27, 0.17);
        return (int(d) & 1) ? float3(0.62, 0.49, 0.30) : float3(0.53, 0.40, 0.24);
    }
    float s = stT(int2(t.x, t.y / 5 + t.x), bh, 32u);
    return float3(0.38, 0.29, 0.18) * (0.7 + 0.45 * s);
}

static inline float3 stOreColor(int kind) {
    switch (kind) {
        case 0:  return float3(0.12, 0.12, 0.13);
        case 1:  return float3(0.84, 0.68, 0.53);
        case 2:  return float3(0.80, 0.47, 0.29);
        case 3:  return float3(0.99, 0.84, 0.26);
        case 4:  return float3(0.92, 0.10, 0.07);
        case 5:  return float3(0.18, 0.32, 0.82);
        case 6:  return float3(0.47, 0.95, 0.90);
        default: return float3(0.26, 0.86, 0.46);
    }
}

static inline float3 stOreTex(int2 t, uint bh, int ore, bool deep, float now) {
    float3 c = deep ? stDeepTex(t, bh) : stStoneTex(t, bh);
    float3 oc = stOreColor(ore);
    for (int k = 0; k < 4; ++k) {
        uint ob = bh >> (k * 8);
        int2 o = int2(2 + int((ob & 15u) * 11u / 16u), 2 + int(((ob >> 4) & 15u) * 11u / 16u));
        int2 d = t - o;
        int2 a = abs(d);
        if (a.x <= 1 && a.y <= 1 && (a.x + a.y <= 1 || stT(t, bh, 42u) < 0.55)) {
            if (d.x == -1 && d.y == 1) {
                // Each nugget's highlight catches the lamp now and then.
                float g = pow(0.5 + 0.5 * sin(now * 0.5 + float(ob & 255u) * 0.37), 12.0);
                return min(oc * 1.25 + 0.15 + 0.6 * g, 1.6);
            }
            return oc * (0.78 + 0.22 * stT(t, bh, 41u));
        }
        if (a.x <= 2 && a.y <= 2) c *= 0.8;
    }
    return c;
}

static inline float3 stTex(int mat, int2 t, uint bh, int face, bool front, float now) {
    switch (mat) {
    case M_GRASS: {
        if (face == 1) return stSpeck(float3(0.35, 0.58, 0.24), t, bh, 0.3);
        if (face == 2) return stDirtTex(t, bh);
        int fringe = 12 + int(stT(int2(t.x, 0), bh, 50u) * 2.2);
        if (t.y >= fringe) return stSpeck(float3(0.35, 0.58, 0.24), t, bh, 0.3);
        return stDirtTex(t, bh);
    }
    case M_DIRT:     return stDirtTex(t, bh);
    case M_STONE:    return stStoneTex(t, bh);
    case M_DEEP:     return stDeepTex(t, bh);
    case M_GRANITE: {
        float n = stT(t, bh, 0u);
        float3 c = stSpeck(float3(0.62, 0.43, 0.36), t, bh, 0.2);
        if (n > 0.86) c = float3(0.76, 0.60, 0.55);
        if (n < 0.08) c = float3(0.42, 0.26, 0.22);
        return c;
    }
    case M_DIORITE: {
        float3 c = stSpeck(float3(0.76, 0.76, 0.77), t, bh, 0.12);
        if (stT(t, bh, 0u) > 0.8) c = float3(0.42, 0.42, 0.44);
        return c;
    }
    case M_ANDESITE: return stSpeck(float3(0.54, 0.54, 0.53), t, bh, 0.16);
    case M_TUFF: {
        float3 c = stSpeck(float3(0.43, 0.44, 0.38), t, bh, 0.22);
        if (stT(t, bh, 0u) > 0.9) c = float3(0.58, 0.58, 0.50);
        return c;
    }
    case M_GRAVEL: {
        int2 g = int2((t.x + ((t.y >> 1) & 1)) >> 1, t.y >> 1);
        float p = stT(g, bh, 60u);
        float3 c = mix(float3(0.34, 0.32, 0.31), float3(0.66, 0.62, 0.58), p);
        if (stT(t, bh, 61u) < 0.16) c = float3(0.24, 0.23, 0.22);
        return c;
    }
    case M_BEDROCK: {
        float p = stT(t >> 1, bh, 62u) * 0.7 + stT(t, bh, 63u) * 0.3;
        return float3(p < 0.35 ? 0.07 : (p < 0.6 ? 0.2 : (p < 0.8 ? 0.34 : 0.5)));
    }
    case M_COBBLE:   return stCobbleTex(t, bh, false);
    case M_MOSSY:    return stCobbleTex(t, bh, true);
    case M_PLANKS:   return stPlankTex(t, bh);
    case M_LOG:      return stLogTex(t, bh, face);
    case M_BONE: {
        if (face != 0) {
            float d = length(float2(t) + 0.5 - 8.0);
            return float3(0.88, 0.85, 0.74) * (d < 3.0 ? 0.78 : 1.0);
        }
        float3 c = float3(0.88, 0.85, 0.74) * (0.93 + 0.1 * stT(t, bh, 0u));
        if ((t.x & 3) == 0) c *= 0.84;
        if (stT(t, bh, 64u) > 0.94) c *= 0.7;
        return c;
    }
    case M_CALCITE: {
        float3 c = stSpeck(float3(0.88, 0.89, 0.87), t, bh, 0.08);
        if (stT(t, bh, 0u) > 0.9) c *= 0.86;
        return c;
    }
    case M_AMETHYST: {
        int k = (t.x + t.y + int(bh % 7u)) % 6;
        const float sh[6] = { 0.78, 0.9, 1.0, 1.16, 1.02, 0.88 };
        float3 c = float3(0.54, 0.34, 0.74) * sh[k];
        if (stT(t, bh, 65u) > 0.93) c = float3(0.86, 0.72, 0.96);
        return c;
    }
    case M_BASALT:   return stSpeck(float3(0.29, 0.29, 0.32), t, bh, 0.1);
    case M_DRIP: {
        float3 c = float3(0.55, 0.42, 0.33) * (0.84 + 0.2 * stT(int2(t.x, t.y / 4), bh, 69u) + 0.08 * stT(t, bh, 0u));
        if (stT(int2(t.x, t.y / 6), bh, 70u) > 0.85) c *= 0.78;
        return c;
    }
    case M_CHEST: {
        if (t.x == 0 || t.x == 15 || t.y == 0 || t.y == 15) return float3(0.26, 0.17, 0.08);
        if (face == 0 && (t.y == 9 || t.y == 10)) {
            if (front && (t.x == 7 || t.x == 8)) return float3(0.80, 0.80, 0.83);
            return float3(0.30, 0.20, 0.10);
        }
        if (front && (t.x == 7 || t.x == 8) && t.y == 8) return float3(0.55, 0.55, 0.58);
        return float3(0.68, 0.47, 0.21) * (0.88 + 0.14 * stT(int2(t.x / 4, t.y / 3), bh, 66u));
    }
    case M_CAGE: {
        bool bar = (t.x % 5) == 0 || (t.y % 5) == 0;
        return bar ? float3(0.27, 0.29, 0.34) : float3(0.05, 0.05, 0.06);
    }
    case M_LEAVES: {
        float3 c = float3(0.20, 0.40, 0.15) * (0.65 + 0.55 * stT(t >> 1, bh, 67u));
        if (stT(t, bh, 68u) < 0.14) c = float3(0.07, 0.14, 0.05);
        return c;
    }
    case M_LADDER: {
        bool rail = t.x == 2 || t.x == 3 || t.x == 12 || t.x == 13;
        bool rung = (t.y & 3) == 1 && t.x > 1 && t.x < 14;
        if (rail || rung) return float3(0.56, 0.42, 0.24) * (rail ? 0.85 : 1.0);
        return stDirtTex(t, bh) * 0.8;
    }
    case M_LAVA: {
        float n = stN3(float3(float(t.x) * 0.31, float(t.y) * 0.31 + now * 0.07, now * 0.05 + float(bh & 255u)), 77u);
        float3 c = mix(float3(0.72, 0.16, 0.02), float3(1.0, 0.55, 0.10), smoothstep(0.4, 0.72, n));
        if (n > 0.78) c = float3(1.0, 0.80, 0.35);
        return c;
    }
    default: break;
    }
    if (mat >= M_ORE) {
        int k = mat - M_ORE;
        return stOreTex(t, bh, k & 7, k >= 8, now);
    }
    return float3(1.0, 0.0, 1.0);
}

static inline float3 stMean(int mat) {
    switch (mat) {
        case M_GRASS:    return float3(0.45, 0.42, 0.27);
        case M_DIRT:     return float3(0.53, 0.38, 0.26);
        case M_DEEP:     return float3(0.41, 0.41, 0.46);
        case M_GRANITE:  return float3(0.62, 0.43, 0.36);
        case M_DIORITE:  return float3(0.68, 0.68, 0.69);
        case M_TUFF:     return float3(0.43, 0.44, 0.38);
        case M_GRAVEL:   return float3(0.48, 0.45, 0.43);
        case M_BEDROCK:  return float3(0.2);
        case M_COBBLE:   return float3(0.42);
        case M_MOSSY:    return float3(0.38, 0.42, 0.3);
        case M_PLANKS:   return float3(0.56, 0.42, 0.25);
        case M_LOG:      return float3(0.38, 0.29, 0.18);
        case M_BONE:     return float3(0.84, 0.81, 0.7);
        case M_CALCITE:  return float3(0.87, 0.88, 0.86);
        case M_AMETHYST: return float3(0.53, 0.34, 0.73);
        case M_BASALT:   return float3(0.29, 0.29, 0.32);
        case M_DRIP:     return float3(0.53, 0.41, 0.32);
        case M_CHEST:    return float3(0.6, 0.41, 0.19);
        case M_LEAVES:   return float3(0.18, 0.35, 0.13);
        default:         return mat >= M_ORE + 8 ? float3(0.28, 0.28, 0.32) : float3(0.5);
    }
}

// The face's texture, crisp up close and averaged out once a texel is smaller
// than a pixel. `fwT` is the pixel's footprint in texels.
static inline float3 stSample(int mat, float2 uv, float fwT, uint bh, int face, bool front, float now) {
    float3 mean = stMean(mat);
    if (fwT > 2.0 && mat != M_LAVA) return mean;
    float2 tc = uv * 16.0 - 0.5;
    float2 i = floor(tc), f = tc - i;
    float2 w = saturate((f - 0.5) / max(fwT, 1e-3) + 0.5);
    int2 a = int2(i) + 16;
    // Two taps: the texel under most of the pixel, and the one across
    // whichever texel edge the pixel straddles more. Only where two edges
    // cross (a texel corner) is the third texel left out, which no one sees.
    int2 main = a + int2(w > 0.5);
    float2 m = select(w, 1.0 - w, w > 0.5);        // the other side's share
    bool alongX = m.x >= m.y;
    int2 other = main + (alongX ? int2(w.x > 0.5 ? -1 : 1, 0) : int2(0, w.y > 0.5 ? -1 : 1));
    float share = alongX ? m.x : m.y;
    float3 c = float3(0.0);
    #pragma clang loop unroll(disable)
    for (int k = 0; k < 2; ++k)
        c += (k == 0 ? 1.0 - share : share) * stTex(mat, (k == 0 ? main : other) & 15, bh, face, front, now);
    return mix(c, mean, smoothstep(0.7, 2.0, fwT));
}

// ---------------------------------------------------------------------------
// The ray.

struct StHit {
    bool  hit;
    int3  v;        // the block hit
    int   axis;     // the axis of the face it entered through
    float3 n;       // that face's normal
    float t;        // distance along the ray
    int   kind;     // K_ROCK or K_LAVA
    bool  outdoor;  // walked above ground
    float water;    // distance travelled through water
    float wTop;     // t where the ray crossed a water surface from above, or -1
    float wIn;      // t where the ray first entered water, or -1
};

constant int ST_COLS = 18;   // columns of the cut per ray, at most
constant int ST_OUT  = 24;
constant int ST_OUTZ = 13;   // the land behind the cut is gone into the evening by here   // blocks per ray above ground, at most

// Above ground: an ordinary block walk from t.
static inline void stTraceOut(float3 ro, float3 rd, float t, uint s, thread StHit& h) {
    h.outdoor = true;
    float3 p = ro + rd * (t + 1e-4);
    int3 v = int3(floor(p));
    float3 inv = 1.0 / select(rd, float3(1e-6), abs(rd) < 1e-6);
    int3 st = int3(rd.x > 0.0 ? 1 : -1, rd.y > 0.0 ? 1 : -1, rd.z > 0.0 ? 1 : -1);
    float3 tMax = (float3(v) + select(float3(0.0), float3(1.0), rd > 0.0) - ro) * inv;
    float3 tDelta = abs(inv);
    int axis = h.axis;
    for (int i = 0; i < ST_OUT; ++i) {
        if (stOutdoorSolid(v, s)) {
            h.hit = true; h.v = v; h.axis = axis; h.t = t;
            float3 n = float3(0.0);
            n[axis] = -float(st[axis]);
            h.n = n;
            return;
        }
        axis = tMax.x < tMax.y ? (tMax.x < tMax.z ? 0 : 2) : (tMax.y < tMax.z ? 1 : 2);
        t = tMax[axis];
        v[axis] += st[axis];
        tMax[axis] += tDelta[axis];
        if (v.z > ST_OUTZ || v.y < -20 || (v.y > 22 && rd.y > 0.0)) break;   // nothing stands above 22
    }
    h.t = t; h.v = v;
}

static inline StHit stTrace(float3 ro, float3 rd, uint s) {
    StHit h;
    h.hit = false; h.water = 0.0; h.wTop = -1.0; h.wIn = -1.0; h.kind = K_ROCK; h.axis = 2;
    h.outdoor = false; h.n = float3(0.0, 0.0, -1.0); h.t = 0.0; h.v = int3(0);
    float invz = 1.0 / max(rd.z, 1e-4);
    float t = max((-1.5 - ro.z) * invz, 0.0);
    float tGlass = -ro.z * invz;
    float3 p = ro + rd * t;
    int2 c = int2(floor(p.xy));
    float2 inv = 1.0 / select(rd.xy, float2(1e-6), abs(rd.xy) < 1e-6);
    int2 st = int2(rd.x > 0.0 ? 1 : -1, rd.y > 0.0 ? 1 : -1);
    float2 tMax = (float2(c) + select(float2(0.0), float2(1.0), rd.xy > 0.0) - ro.xy) * inv;
    float2 tDelta = abs(inv);
    int axis = 2;
    int prevKind = K_ROCK;
    bool above = false;
    for (int i = 0; i < ST_COLS; ++i) {
        int Hc = stGroundAtGlass(c.x, c.y, s);
        if (c.y > Hc) { above = true; break; }
        StCol col = stColumn(c.x, c.y, Hc, s);
        float tz = (float(col.d) - ro.z) * invz;
        float tExit = min(tMax.x, tMax.y);
        if (col.kind == K_WATER) {
            float a = max(t, tGlass), b = min(tExit, tz);
            if (b > a) {
                if (h.wIn < 0.0) h.wIn = a;
                if (prevKind != K_WATER && axis == 1 && st.y < 0) h.wTop = a;
                h.water += b - a;
            }
        }
        prevKind = col.kind;
        if (tz <= tExit) {
            h.hit = true; h.kind = col.kind;
            if (tz <= t + 1e-5 && axis != 2) {
                // Into the side of this column.
                h.t = t; h.axis = axis;
                h.v = int3(c, int(floor(ro.z + rd.z * t + 1e-4)));
                float3 n = float3(0.0);
                n[axis] = -float(st[axis]);
                h.n = n;
            } else {
                h.t = max(tz, t); h.axis = 2;
                h.v = int3(c, col.d);
                h.n = float3(0.0, 0.0, -1.0);
            }
            return h;
        }
        axis = tMax.x < tMax.y ? 0 : 1;
        t = tMax[axis];
        c[axis] += st[axis];
        tMax[axis] += tDelta[axis];
        if (ro.z + rd.z * t > ST_ZMAX) break;
    }
    if (above) { h.axis = axis; stTraceOut(ro, rd, t, s, h); return h; }
    h.t = t;
    h.v = int3(c, int(ro.z + rd.z * t));
    return h;
}

// Shading where a face meets a neighbouring block. Each edge neighbour of
// the face's air cell darkens the strip along its edge; only the nearer
// neighbour on each axis is looked up, since the far one's strip carries at
// most a quarter of the weight here (that halves the cost of the corner
// shading inside caves, the dearest thing in the look after the ray).
static inline float stAO(int3 v, float3 n, int axis, float2 uv, uint s) {
    int3 q = v + int3(n);
    int3 du = axis == 0 ? int3(0, 0, 1) : int3(1, 0, 0);
    int3 dv = axis == 1 ? int3(0, 0, 1) : int3(0, 1, 0);
    float2 e = max(uv, 1.0 - uv);                 // 1 at the nearer edge
    float sn[2];
    #pragma clang loop unroll(disable)
    for (int k = 0; k < 2; ++k) {
        int3 o = k == 0 ? (uv.x < 0.5 ? -du : du) : (uv.y < 0.5 ? -dv : dv);
        sn[k] = stSolid(q + o, s) ? 1.0 : 0.0;
    }
    float su = sn[0], sv = sn[1];
    float2 w = saturate(e * 2.0 - 1.0);           // 0 mid-face, 1 at the edge
    return 1.0 - 0.45 * saturate(su * w.x * w.x + sv * w.y * w.y);
}

// Warm light from the torches in a mine gallery near P.
static inline float stTorches(float3 P, StFeat f) {
    float3 q = P - float3(f.o);
    float L = 0.0;
    if (f.kind == F_MINE_Z) {
        if (abs(q.x - 0.5) > 3.6 || q.y < -1.0 || q.y > 4.5) return 0.0;
        float z0 = floor((q.z - 2.0) / 8.0) * 8.0 + 2.0;
        for (int k = 0; k < 2; ++k) {
            float3 tp = float3(-0.8, 1.6, z0 + 8.0 * float(k) + 0.5);
            float3 d = q - tp;
            L += 1.0 / (1.0 + 0.55 * dot(d, d));
        }
    } else if (f.kind == F_DUNGEON) {
        if (abs(q.x) > 5.0 || q.y < -1.0 || q.y > 6.0 || q.z > 8.0) return 0.0;
        float3 d = q - float3(0.5, 3.5, 6.8);
        L += 1.6 / (1.0 + 0.3 * dot(d, d));
    } else if (f.kind == F_MINE_X) {
        if (abs(q.x) > 13.0 || q.y < -1.0 || q.y > 3.5 || q.z > 3.5) return 0.0;
        float x0 = floor(q.x / 8.0 + 0.5) * 8.0;
        for (int k = -1; k <= 1; k += 2) {
            float xs = x0 + 4.0 * float(k);
            if (abs(xs) > 12.0) continue;
            float3 d = q - float3(xs + 0.5, 1.6, 1.85);
            L += 1.0 / (1.0 + 0.55 * dot(d, d));
        }
    }
    return L;
}

// Torch flames drawn on the faces they hang from.
static inline bool stTorchSprite(int3 v, float3 n, float2 uv, StFeat f, thread float3& col) {
    int3 q = v - f.o;
    bool on = false;
    if (f.kind == F_MINE_Z && n.x > 0.5 && q.x == -2 && q.y == 1 && (q.z & 7) == 2) on = true;
    if (f.kind == F_DUNGEON && n.z < -0.5 && q.x == 0 && q.y == 3 && q.z == 7) on = true;
    if (f.kind == F_MINE_X && n.z < -0.5 && q.z == 2 && q.y == 1 && (q.x & 7) == 4 && abs(q.x) <= 12) on = true;
    if (!on) return false;
    int2 t = int2(floor(uv * 16.0));
    if (t.x >= 7 && t.x <= 8 && t.y >= 2 && t.y <= 9) { col = float3(0.42, 0.30, 0.16); return true; }
    if (t.x >= 6 && t.x <= 9 && t.y >= 10 && t.y <= 13) {
        col = (t.y >= 12 || t.x == 6 || t.x == 9) ? float3(1.0, 0.62, 0.15) : float3(1.0, 0.92, 0.6);
        col *= 3.0;
        return true;
    }
    return false;
}

static inline float3 stSky(float3 rd) {
    float h = saturate(rd.y * 1.6 + 0.35);
    float3 c = mix(float3(0.62, 0.47, 0.40), float3(0.13, 0.19, 0.36), h);
    return pow(c, 2.2);
}

static inline float3 stShade(float3 ro, float3 rd, float3 lamp, float pxAngle, uint s, float now, float bright) {
    StHit h = stTrace(ro, rd, s);
    const float3 glass = float3(1.0, 0.95, 0.88);
    float3 col;
    float3 P = ro + rd * h.t;
    if (!h.hit) {
        col = h.outdoor ? stSky(rd) : float3(0.0025, 0.003, 0.0045);
    } else {
        int3 v = h.v;
        int axis = h.axis;
        float3 n = h.n;
        float2 uv = axis == 0 ? float2(P.z - float(v.z), P.y - float(v.y))
                  : (axis == 1 ? float2(P.x - float(v.x), P.z - float(v.z))
                               : float2(P.x - float(v.x), P.y - float(v.y)));
        uv = saturate(uv);
        int face = axis == 1 ? (n.y > 0.0 ? 1 : 2) : 0;
        // The buried feature (if any) of the cell the face looks out into:
        // its rails, torches and torchlight.
        StFeat fa = stFeatOf(v + int3(n), s);
        int mat = h.kind == K_LAVA ? M_LAVA : stMaterial(v, s);
        uint bh = stHash(v, s + 200u);
        float cosi = max(abs(dot(rd, n)), 0.08);
        float fwT = h.t * pxAngle / cosi * 16.0;
        float3 alb = stSample(mat, uv, fwT, bh, face, n.z < -0.5, now);
        // Rails along a gallery floor.
        if (face == 1) {
            StFeat f = fa;
            int3 q = v - f.o;
            bool railZ = f.kind == F_MINE_Z && q.x == 0 && q.y == -1 && q.z >= 0 && q.z <= 34;
            bool railX = f.kind == F_MINE_X && q.z == 1 && q.y == -1 && abs(q.x) <= 12;
            if (railZ || railX) {
                int2 tt = int2(floor(uv * 16.0));
                int across = railZ ? tt.x : tt.y, along = railZ ? tt.y : tt.x;
                bool tie = (along & 3) < 2 && across >= 2 && across <= 13;
                bool rail = across == 3 || across == 4 || across == 11 || across == 12;
                if (rail) alb = float3(0.62, 0.62, 0.64) * (across & 1 ? 0.8 : 1.0);
                else if (tie) alb = float3(0.44, 0.31, 0.17);
            }
        }
        alb *= 0.96 + 0.08 * float(bh & 255u) / 255.0;
        alb *= alb;   // to linear (gamma 2, near enough)

        if (mat == M_LAVA) {
            col = alb * 1.5;
        } else {
            float3 air = float3(v) + n;
            int3 av = int3(air);
            bool outdoor = h.outdoor && av.y > stHeight(av.x, av.z, s);
            // Corner shading: on the cut face only the blocks standing proud
            // of it can shade it, so only they are looked up.
            float ao;
            if (h.axis == 2 && v.z <= 0) {
                float o0 = float(stCut(v.x - 1, v.y, s) < 0), o1 = float(stCut(v.x + 1, v.y, s) < 0);
                float o2 = float(stCut(v.x, v.y - 1, s) < 0), o3 = float(stCut(v.x, v.y + 1, s) < 0);
                float2 e0 = 1.0 - uv, e1 = uv;
                ao = v.z < 0 ? 1.0 : 1.0 - 0.5 * saturate(o0 * e0.x * e0.x + o1 * e1.x * e1.x + o2 * e0.y * e0.y + o3 * e1.y * e1.y);
            } else if (P.z < 7.0) {
                ao = stAO(v, n, axis, uv, s);
            } else {
                ao = 1.0;   // too far into the dark for it to show
            }
            float3 light;
            if (outdoor) {
                float3 sun = normalize(float3(-0.55, 0.62, 0.56));
                float sd = max(dot(n, sun), 0.0);
                light = float3(1.0, 0.82, 0.62) * 1.25 * sd + float3(0.42, 0.48, 0.65) * (0.45 + 0.25 * n.y);
                light = mix(light, glass * 0.9, saturate(1.0 - P.z * 0.5));
            } else {
                // A lamp held up to the glass, a little way out from it,
                // and the cool spill of it off everything else.
                float3 Ld = lamp - P;
                float dl = length(Ld);
                float lamb = max(dot(n, Ld / dl), 0.0);
                float zf = max(P.z, 0.0);
                float orient = n.z < -0.5 ? 1.0 : (n.y > 0.5 ? 0.8 : (n.y < -0.5 ? 0.45 : 0.62));
                // The face itself is lit well; the light dies quickly inside,
                // so the rock always reads lighter than the holes in it.
                light = float3(1.0, 0.8, 0.56) * 1.25 * lamb / (1.0 + dl * dl / 330.0) * exp(-0.3 * zf)
                      + float3(0.55, 0.66, 0.85) * 0.3 * orient * exp(-0.6 * zf);
                // The lava's glow, on everything near the bottom.
                light += float3(1.0, 0.36, 0.07) * 2.4 * stLavaGlow(P.x, P.y, s) * (0.55 + 0.45 * max(-n.y, 0.0) + 0.3 * max(-n.z, 0.0));
                light += float3(1.0, 0.66, 0.32) * 1.7 * stTorches(P, fa);
            }
            // Caustics under water.
            if (h.water > 0.0) {
                float2 cq = floor(P.xz * 16.0) / 16.0;
                float k = sin(cq.x * 2.1 + now * 0.6) * sin(cq.y * 2.6 - now * 0.45)
                        + sin((cq.x + cq.y) * 1.3 + now * 0.35);
                light *= 1.0 + 0.35 * smoothstep(0.6, 1.6, k) * step(0.5, n.y);
            }
            col = alb * light * ao;
            // Things down there that give their own light: the brighter ores
            // and the amethyst.
            if (mat >= M_ORE) {
                int k = (mat - M_ORE) & 7;
                float g = k == 4 ? 0.7 : (k == 6 ? 0.5 : (k == 7 ? 0.4 : (k == 3 || k == 5 ? 0.25 : 0.0)));
                float3 m = stMean(mat);
                col += max(alb - m * m * 1.3, 0.0) * g;
            } else if (mat == M_AMETHYST) {
                col += alb * 0.22;
            }
            float3 tc;
            if (stTorchSprite(v, n, uv, fa, tc)) col = tc;
            // Outdoors, the land fades into the evening.
            if (outdoor) col = mix(col, stSky(rd), smoothstep(3.5, float(ST_OUTZ) - 0.5, P.z));
            else col *= 1.0 - smoothstep(ST_ZMAX - 7.0, ST_ZMAX, P.z);
        }
    }
    if (h.water > 0.0) {
        float tr = 0.8 * exp(-0.09 * h.water);
        float3 wc = pow(float3(0.10, 0.24, 0.42), float3(2.2)) * glass;
        // The water line on the glass, and the water darkening below it.
        float3 E = ro + rd * h.wIn;
        float below = max(float(stWaterTable(int(floor(E.x)), s)) + 1.0 - E.y, 0.0);
        wc *= 1.25 * exp(-0.075 * below);
        int3 ev = int3(floor(E + rd * 1e-3));
        int3 above = ev + int3(0, 1, 0);
        if (E.z < 0.6 && fract(E.y) > 0.86 && stColumn(above.x, above.y, stGroundAtGlass(above.x, above.y, s), s).kind != K_WATER)
            col += float3(0.10, 0.17, 0.24) * 1.4;
        col = col * tr * float3(0.55, 0.8, 1.0) + wc * (1.0 - tr);
        if (h.wTop > 0.0) {
            float3 W = ro + rd * h.wTop;
            float2 cq = floor(W.xz * 16.0) / 16.0;
            float k = sin(cq.x * 3.1 + now * 0.8) + sin(cq.y * 2.3 - now * 0.6);
            col += float3(0.05, 0.09, 0.13) * (1.0 + 0.6 * k) * exp(-0.1 * max(W.z, 0.0));
        }
    }
    return col * bright;
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    uint s = uint(u.seed * 1048576.0) * 747796405u + 2891336453u;
    float now = u.time;
    float minRes = min(u.resolution.x, u.resolution.y);

    float sink = u.dive != 0 ? 0.5 - 0.5 * cos(now * (TWO_PI / ST_DIVE)) : 0.0;
    float frac = u.depth + (1.0 - u.depth) * sink;
    float3 target = float3(now * u.speed + u.seed * 5000.0, mix(ST_TOP, ST_BOTTOM, frac), 0.0);
    float3 upHint = float3(0.0, 1.0, 0.0);
    float3 ro = target - float3(0.0, 0.0, ST_D);
    float3 base = target;
    float3 fwd = float3(0.0, 0.0, 1.0);
    float3 right = normalize(cross(upHint, fwd));
    lerpOrbit(u.yaw, u.pitch, u.magnify, target, upHint, ro, right, fwd);
    float3 up = cross(fwd, right);
    float dist = length(target - ro);

    // The screen is the glass: head tracking pins the cut and swings the
    // caves behind it.
    float2 uv = lerpUV(pos, u.resolution);
    float3 rd = lerpViewerRay(u, u.parallax * 0.4, uv * (dist / ST_FOCAL), dist, right, up, fwd, ro);
    float pxAngle = 2.0 / (minRes * ST_FOCAL);

    // The lamp wanders slowly about the middle of the view.
    float3 lamp = target + float3(7.0 * sin(now * 0.043 + u.seed * 6.0), 4.0 * sin(now * 0.031 + 1.0), -14.0);
    float3 col = stShade(ro, rd, lamp, pxAngle, s, now, u.light);

    col = col / (1.0 + col * 0.3);
    col = pow(max(col, 0.0), 1.0 / 2.2);
    col = lerpDither(col, pos);
    return half4(half3(col), 1.0h);
}
