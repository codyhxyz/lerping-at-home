// Strata — a Minecraft world cut open like an ant farm.
// The world generation is original work for Lerping@Home; every surface is
// drawn with the game's own textures, bound from the copy installed on this
// Mac (see the "Minecraft looks" section of PORTING.md).
//
// lerp-category: Living Worlds
// lerp-requires: minecraft mobs
//
// The world is sliced along one vertical plane and the screen is the glass laid
// against the cut. You drift along it: grass and dirt at the top, then stone
// with its ores and its blobs of granite, diorite, andesite, dirt and gravel,
// deepslate and tuff below that, lava pooled over bedrock at the bottom, each
// ore at the depths the game puts it. Wherever the cut opens a cave you look
// into it.
//
// It is lit as the game lights it, through its lightmap: the slab taken away
// in front of the cut leaves the whole face open to the evening sky (sky light
// 15), and that light falls a level a block into the caves behind it, so they
// fade to the game's dark the deeper they run, except where a mineshaft keeps
// its torches (14) or lava (15) glows at the bottom. Faces take the game's
// fixed shading and smooth-lighting corners. Above the grass is the game's
// evening: sky and fog colours at the hour the sun touches the hills, ahead of
// the camera, with the orange sunset fan, the square sun and the flat cloud
// layer from clouds.png. Flooded caves show the animated, tinted water face.
//
// Buried in the rock, one or two to a screen: amethyst geodes sliced through
// the middle (smooth basalt, calcite, amethyst, budding amethyst with its
// clusters), a fossil of bone blocks, a cobblestone dungeon with its spawner
// (a small zombie or skeleton turning inside, from the mob kit)
// and chests, mineshafts of oak with rails, cobwebs and torches (one running
// along the glass, one running away from it into the dark), and now and then
// a cellar under the grass with a chest, barrels and a ladder up to the light.
// Glow lichen grows on the walls of the deeper caves.
// Oak trees with cut-out leaves stand on the grass.
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
             M_CALCITE = 16, M_AMETHYST = 17, M_BASALT = 18, M_CHEST = 19, M_SPAWNER = 20,
             M_LAVA = 22, M_LEAVES = 23, M_LADDER = 24, M_BUDDING = 25,
             M_BONE_X = 26,   // a bone block lying along x
             M_BARREL = 27,
             M_ORE = 32;   // + ore kind, + 8 when set in deepslate

// --- The hour: the sun is just touching the hills ahead (celestial angle
// 0.23, a little before the game's sunset), so its fan of orange is up. The
// kit turns the sun's height into the sky's and the lightmap's `day` and the
// sunset glow.
constant float3 ST_SUN    = float3(0.0, 0.1253, 0.9921);     // 7.2 degrees up, straight ahead
static inline float stLDay() { return mcLightDay(ST_SUN.y); }
constant float  ST_CLOUDS = 136.0;                           // y 192 in the game's heights


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
            if (q.y == 0 && q.x == 0 && q.z == 3) return M_SPAWNER;
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
        if (q.x <= 8 && q.y == ys) return M_BONE_X;                     // spine
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
        if (d < f.r - 1.2) return stRnd(p, f.h) < 0.14 ? M_BUDDING : M_AMETHYST;
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
        if (q.x == 2 && q.z == 4 && q.y <= 1) return M_BARREL;           // barrels
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
    StFeat ft = stFeatOf(p, s);
    int fm = stFeature(p, ft);
    if (fm > 0) return fm;
    // The walk finds the geode's back wall a block nearer, now and then, than
    // the sphere puts it: that block is still the amethyst lining.
    if (fm == M_AIR && ft.kind == F_GEODE) return M_AMETHYST;
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
    // Blobs of the other rocks the game scatters through stone: granite,
    // diorite, andesite, dirt and gravel above the deepslate, tuff and gravel
    // in it.
    float3 q = float3(p) + 0.5;
    if (stN2(float2(q.x + 0.61 * q.z, q.y) / 6.0, s + 190u) > 0.79) {
        float k = stRnd(int3(stDiv(p.x, 14), stDiv(p.y, 14), stDiv(p.z, 14)), s + 191u);
        if (deep) return k < 0.6 ? M_TUFF : M_GRAVEL;
        if (p.y > -24 && k < 0.18) return M_DIRT;
        return k < 0.4 ? M_GRANITE : (k < 0.62 ? M_DIORITE : (k < 0.84 ? M_ANDESITE : M_GRAVEL));
    }
    // The larger bodies of the same rocks, long and flat, folded gently: the
    // strata of the name.
    float2 xz = float2(float(p.x), float(p.z));
    float yy = float(p.y) + 18.0 * (stN2(xz / 90.0, s + 30u) - 0.5)
             + 1.4 * sin(xz.x * 0.19 + xz.y * 0.17) + 0.7 * sin(xz.x * 0.47 - xz.y * 0.4);
    int band = int(floor(yy / 7.0));
    uint hb = stHash(int3(band, 0, 21), s + 192u);
    float bk = stBits(hb, 0), bt = stBits(hb, 1);
    float within = yy / 7.0 - float(band);
    if (bk < 0.42 && within < 0.3 + 0.4 * bt) {
        float kk = bk / 0.42;
        if (deep) return kk < 0.6 ? M_TUFF : base;
        return kk < 0.4 ? M_GRANITE : (kk < 0.7 ? M_DIORITE : M_ANDESITE);
    }
    return base;
}

// ---------------------------------------------------------------------------
// The game's textures.

// Ore tiles: coal, iron, copper, gold, redstone, lapis, diamond, emerald, in
// stone and then (k + 8) in deepslate.
static inline int stOreLayer(int k) {
    switch (k) {
        case 0:  return MC_COAL_ORE;
        case 1:  return MC_IRON_ORE;
        case 2:  return MC_COPPER_ORE;
        case 3:  return MC_GOLD_ORE;
        case 4:  return MC_REDSTONE_ORE;
        case 5:  return MC_LAPIS_ORE;
        case 6:  return MC_DIAMOND_ORE;
        case 7:  return MC_EMERALD_ORE;
        case 8:  return MC_DEEPSLATE_COAL_ORE;
        case 9:  return MC_DEEPSLATE_IRON_ORE;
        case 10: return MC_DEEPSLATE_COPPER_ORE;
        case 11: return MC_DEEPSLATE_GOLD_ORE;
        case 12: return MC_DEEPSLATE_REDSTONE_ORE;
        case 13: return MC_DEEPSLATE_LAPIS_ORE;
        case 14: return MC_DEEPSLATE_DIAMOND_ORE;
        default: return MC_DEEPSLATE_EMERALD_ORE;
    }
}

// The tile a block shows on a face of the given axis (0, 1, 2 = x, y, z).
// Grass, chests and lava are drawn apart.
static inline int stLayer(int mat, int axis) {
    bool end = axis == 1;   // a pillar block's end faces
    switch (mat) {
        case M_DIRT:     return MC_DIRT;
        case M_STONE:    return MC_STONE;
        case M_GRANITE:  return MC_GRANITE;
        case M_DIORITE:  return MC_DIORITE;
        case M_ANDESITE: return MC_ANDESITE;
        case M_GRAVEL:   return MC_GRAVEL;
        case M_DEEP:     return end ? MC_DEEPSLATE_TOP : MC_DEEPSLATE;
        case M_BEDROCK:  return MC_BEDROCK;
        case M_TUFF:     return MC_TUFF;
        case M_COBBLE:   return MC_COBBLESTONE;
        case M_MOSSY:    return MC_MOSSY_COBBLESTONE;
        case M_PLANKS:   return MC_OAK_PLANKS;
        case M_LADDER:   return MC_OAK_PLANKS;     // the shaft's lining, under the ladder
        case M_LOG:      return end ? MC_OAK_LOG_TOP : MC_OAK_LOG;
        case M_BONE:     return end ? MC_BONE_BLOCK_TOP : MC_BONE_BLOCK_SIDE;
        case M_BONE_X:   return axis == 0 ? MC_BONE_BLOCK_TOP : MC_BONE_BLOCK_SIDE;
        case M_CALCITE:  return MC_CALCITE;
        case M_AMETHYST: return MC_AMETHYST_BLOCK;
        case M_BUDDING:  return MC_BUDDING_AMETHYST;
        case M_BASALT:   return MC_SMOOTH_BASALT;
        case M_SPAWNER:  return MC_SPAWNER;
        case M_LEAVES:   return MC_OAK_LEAVES;
        case M_BARREL:   return end ? MC_BARREL_TOP : MC_BARREL_SIDE;
        default:         return stOreLayer(mat - M_ORE);
    }
}

// Where on a face of block v the point P is: 0..1 across it, y up (corner
// shading reads it this way).
static inline float2 stFaceL(float3 P, int3 v, int axis) {
    float3 l = saturate(P - float3(v));
    return axis == 0 ? l.zy : (axis == 1 ? l.xz : l.xy);
}
// The same in the picture's orientation, uv.y = 0 its top row, as mcTile reads.
static inline float2 stPic(float2 l, int axis) { return axis == 1 ? l : float2(l.x, 1.0 - l.y); }

// The uv change across one screen pixel both ways, for a face seen at a
// slant: `d` is the pixel's width at the hit, across the ray. Along the
// face's slope the footprint stretches by 1 / cos, across it it does not.
static inline void stGrad(float3 rd, float3 n, int axis, float d, thread float2& gx, thread float2& gy) {
    float c = max(abs(dot(rd, n)), 0.06);
    float3 par = rd - n * dot(rd, n);
    float lp = length(par);
    float3 e1 = lp > 1e-4 ? par / lp : (axis == 0 ? float3(0.0, 0.0, 1.0) : float3(1.0, 0.0, 0.0));
    float3 e2 = cross(n, e1) * d;
    e1 *= d / c;
    gx = axis == 0 ? e1.zy : (axis == 1 ? e1.xz : e1.xy);
    gy = axis == 0 ? e2.zy : (axis == 1 ? e2.xz : e2.xy);
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
    float wIn;      // t where the ray first entered water, or -1
    int   wAxis;    // the axis of the water face it entered through
};

constant int ST_COLS = 18;   // columns of the cut per ray, at most
constant int ST_OUT  = 24;   // blocks per ray above ground, at most
constant int ST_OUTZ = 13;   // the land behind the cut is gone into the fog by here

// Above ground: an ordinary block walk from t. With `past`, the block at t
// is skipped (the walk goes on through a clear texel of a leaf).
static inline void stTraceOut(float3 ro, float3 rd, float t, uint s, thread StHit& h, bool past) {
    h.outdoor = true;
    float3 p = ro + rd * (t + 1e-4);
    int3 v = int3(floor(p));
    float3 inv = 1.0 / select(rd, float3(1e-6), abs(rd) < 1e-6);
    int3 st = int3(rd.x > 0.0 ? 1 : -1, rd.y > 0.0 ? 1 : -1, rd.z > 0.0 ? 1 : -1);
    float3 tMax = (float3(v) + select(float3(0.0), float3(1.0), rd > 0.0) - ro) * inv;
    float3 tDelta = abs(inv);
    int axis = h.axis;
    for (int i = 0; i < ST_OUT; ++i) {
        if (!(past && i == 0) && stOutdoorSolid(v, s)) {
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
    h.hit = false; h.water = 0.0; h.wIn = -1.0; h.wAxis = 2; h.kind = K_ROCK; h.axis = 2;
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
                if (h.wIn < 0.0) { h.wIn = a; h.wAxis = tGlass >= t ? 2 : axis; }
                h.water += b - a;
            }
        }
        if (tz <= tExit) {
            h.hit = true; h.kind = col.kind;
            if (tz < t - 1e-3 && axis != 2) {
                // Into the side of this column. (A ray that meets the
                // column's front right at its edge takes the front face: a
                // side there is a one-pixel line where block edges fall on
                // pixel centres.)
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
    // Above ground the caller walks on block by block (stTraceOut) from t.
    if (above) { h.axis = axis; h.outdoor = true; h.t = t; return h; }
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

// --- Light, in the game's levels (0..15) of the air in front of a face.

// Torches are level 14 and the light falls a level a block, by Manhattan
// distance as the game spreads it: the block light at P from the torches of
// the mineshaft f. A Z shaft has one on its left post every 8 blocks, an X
// shaft one on every other post.
static inline float stTorchLevel(float3 P, StFeat f) {
    float3 q = P - float3(f.o);
    float L = 0.0;
    if (f.kind == F_MINE_Z) {
        float z0 = floor((q.z - 2.0) / 8.0) * 8.0 + 2.0;
        for (int k = 0; k < 2; ++k) {
            float zt = z0 + 8.0 * float(k);
            if (zt < 0.0 || zt > 60.0) continue;
            float3 d = abs(q - float3(-0.5, 1.5, zt + 0.5));
            L = max(L, 14.0 - (d.x + d.y + d.z));
        }
    } else if (f.kind == F_MINE_X) {
        float x0 = floor(q.x / 8.0 + 0.5) * 8.0;
        for (int k = -1; k <= 1; k += 2) {
            float xs = x0 + 4.0 * float(k);
            if (abs(xs) > 12.0) continue;
            float3 d = abs(q - float3(xs + 0.5, 1.5, 1.5));
            L = max(L, 14.0 - (d.x + d.y + d.z));
        }
    }
    return L;
}

// The game's number (MC_DIR_*) for an axis direction.
static inline int stDir(float3 d) {
    return d.y < -0.5 ? MC_DIR_DOWN : (d.y > 0.5 ? MC_DIR_UP : (d.z < -0.5 ? MC_DIR_NORTH
         : (d.z > 0.5 ? MC_DIR_SOUTH : (d.x < -0.5 ? MC_DIR_WEST : MC_DIR_EAST))));
}

// Where a ray is inside the box lo..hi: (enter, leave).
static inline float2 stBox(float3 ro, float3 rd, float3 lo, float3 hi) {
    float3 inv = 1.0 / select(rd, float3(1e-6), abs(rd) < 1e-6);
    float3 a = (lo - ro) * inv, b = (hi - ro) * inv;
    float3 mn = min(a, b), mx = max(a, b);
    return float2(max(max(mn.x, mn.y), mn.z), min(min(mx.x, mx.y), mx.z));
}

// Lava is level 15. It lies where the cave field opens along the lava level,
// so the same field, read along that level, says how far off it is.
static inline float stLavaLevel(float3 P, uint s) {
    float above = max(P.y - float(ST_LAVA) - 1.0, 0.0);
    if (above > 15.0) return 0.0;
    float2 q = float2(P.x, float(ST_LAVA) - 1.5);
    float C = 0.62 * stN2(q / float2(17.0, 10.0), s + 20u) + 0.38 * stN2(q / float2(7.0, 4.5), s + 21u);
    return 15.0 - above - 8.0 * (1.0 - smoothstep(0.5, 0.64, C));
}

// A ravine runs on, open to the sky, further back than the walk goes: past
// it, the colour of its sky-lit stone walls (stone.png's mean, x-face shade).
static inline float3 stRavineFar() {
    return float3(0.49) * mcLightmap(0.0, 15.0, stLDay(), 0.0) * 0.6;
}

// Did a ray that found nothing go down a ravine? Where it stopped, or where
// it came through the cut.
static inline bool stRavineRay(float3 ro, float3 rd, int3 last, uint s) {
    if (last.y > -50 && stRavine(last.x, last.y, s)) return true;
    int2 g = int2(floor((ro + rd * (-ro.z / max(rd.z, 1e-4))).xy));
    return g.y > -50 && stRavine(g.x, g.y, s);
}

// --- The evening sky, as the game draws it.

// The fog colour: the game's at this hour, pulled toward the sunset colour as
// the camera faces the sun (it is one colour for the whole view, as there).
static inline float3 stFogColor(float3 fwd) {
    return mcFogToward(mcFogAt(mcSkyDay(ST_SUN.y)), mcSunsetAt(ST_SUN.y), fwd, ST_SUN);
}

static inline float3 stSky(float3 ro, float3 rd, float3 fogC, float pxAngle, float now,
                           texture2d_array<float> skins, texture2d_array<float> maps) {
    // The sky plane, 16 blocks up, fogged over a 12-chunk render distance.
    float skyDay = mcSkyDay(ST_SUN.y);
    float3 c = rd.y > 0.0 ? mix(mcSkyAt(skyDay), fogC, saturate(16.0 / max(rd.y, 1e-3) / 192.0)) : fogC;

    // The sunset fan over it.
    float4 glow = mcSunsetAt(ST_SUN.y);
    c = mix(c, glow.rgb, mcSunsetFan(rd, ST_SUN, glow));

    // The sun: its 32-pixel picture on a quad 30 either side at distance 100,
    // added to the sky.
    float ds = dot(rd, ST_SUN);
    if (ds > 0.9) {
        float3 sy = normalize(cross(ST_SUN, float3(1.0, 0.0, 0.0)));
        float2 q = float2(rd.x, dot(rd, sy)) / ds * 100.0;
        if (all(abs(q) < 30.0)) {
            float2 px = (float2(q.x, -q.y) / 60.0 + 0.5) * float2(MCS_ENVIRONMENT_CELESTIAL_SUN_SIZE);
            c += mcSkin(skins, MCS_ENVIRONMENT_CELESTIAL_SUN, px, pxAngle * 100.0 / 60.0 * 32.0).rgb;
        }
    }

    // The flat cloud layer at the game's cloud height: one pixel of
    // clouds.png to 12 blocks, drifting 0.6 blocks a second, the evening's
    // grey, fogged with distance.
    if (rd.y > 0.02) {
        float tc = (ST_CLOUDS - ro.y) / rd.y;
        float3 X = ro + rd * tc;
        float2 px = float2(X.x + now * 0.6, X.z) / 12.0;
        px -= 256.0 * floor(px / 256.0);
        float w = tc * pxAngle / (12.0 * sqrt(rd.y));
        float a = mcMap(maps, MCM_ENVIRONMENT_CLOUDS, px, w).a;
        float3 cc = mix(float3(skyDay * 0.9 + 0.1), fogC, saturate((tc - 120.0) / 480.0));
        c = mix(c, cc, a * 0.8 * (1.0 - smoothstep(400.0, 800.0, tc)));
    }
    return c;
}

// ---------------------------------------------------------------------------
// The picture.

static inline float3 stShade(float3 ro, float3 rd, float pxAngle, uint s, float now, float3 fogC,
                             texture2d_array<float> tiles, texture2d_array<float> skins,
                             texture2d_array<float> maps) {
    StHit h = stTrace(ro, rd, s);
    int mat = M_AIR;
    if (h.outdoor) {
        // Above ground. Leaves are cut out by their alpha: through a clear
        // texel the walk goes on once more, so the gaps in a crown show the
        // leaves inside it, and at its edge the sky.
        for (int k = 0; k < 2; ++k) {
            stTraceOut(ro, rd, h.t, s, h, k > 0);
            if (!h.hit) break;
            mat = stMaterial(h.v, s);
            if (mat != M_LEAVES || k == 1) break;
            float2 ll = stFaceL(ro + rd * h.t, h.v, h.axis);
            if (mcTile(tiles, MC_OAK_LEAVES, stPic(ll, h.axis), h.t * pxAngle).a > 0.5) break;
            h.hit = false;
        }
    } else if (h.hit) {
        mat = h.kind == K_LAVA ? M_LAVA : stMaterial(h.v, s);
    }

    float3 col;
    float3 P = ro + rd * h.t;
    if (!h.hit) {
        col = h.outdoor ? stSky(ro, rd, fogC, pxAngle, now, skins, maps)
            : (stRavineRay(ro, rd, h.v, s) ? stRavineFar() : float3(0.0));
    } else {
        int3 v = h.v;
        int axis = h.axis;
        float3 n = h.n;
        float2 l = stFaceL(P, v, axis);
        float2 uv = stPic(l, axis);
        float2 gx, gy;
        stGrad(rd, n, axis, h.t * pxAngle, gx, gy);
        float fp = sqrt(length(gx) * length(gy));           // the footprint, for isotropic lookups
        int3 av = v + int3(n);
        bool outdoor = h.outdoor && av.y > stHeight(av.x, av.z, s);
        // The buried feature (if any) of the air the face looks out into: its
        // rails, torches and torchlight.
        StFeat fa = stFeatOf(av, s);

        // --- What the face is.
        float3 alb;
        if (mat == M_LAVA) {
            alb = mcTileAniso(tiles, mcFrame(MC_LAVA_STILL, MC_LAVA_STILL_FRAMES, MC_LAVA_STILL_TICKS, now), uv, gx, gy).rgb;
        } else if (mat == M_GRASS) {
            float3 tint = mcGrassTint(maps, 0.8, 0.4);              // plains
            if (axis != 1)     alb = mcGrassSideAniso(tiles, uv, gx, gy, tint);
            else if (n.y > 0.) alb = mcTileAniso(tiles, MC_GRASS_BLOCK_TOP, uv, gx, gy).rgb * tint;
            else               alb = mcTileAniso(tiles, MC_DIRT, uv, gx, gy).rgb;
        } else {
            // A bone block lying along x turns its side texture on its side.
            bool turn = mat == M_BONE_X && axis != 0;
            float4 t = mcTileAniso(tiles, stLayer(mat, axis), turn ? uv.yx : uv,
                                   turn ? gx.yx : gx, turn ? gy.yx : gy);
            alb = t.rgb;
            if (mat == M_LEAVES) alb *= mcFoliageTint(maps, 0.8, 0.4);
            if (mat == M_SPAWNER && t.a < 0.5) {
                // Through the cage to its far side, a block further on ...
                float3 dd = rd / max(abs(dot(rd, n)), 0.2);
                float2 off = axis == 0 ? float2(dd.z, -dd.y) : (axis == 1 ? dd.xz : float2(dd.x, -dd.y));
                float4 b = mcTileAniso(tiles, MC_SPAWNER, uv + off, gx, gy);
                alb = b.a > 0.5 ? b.rgb * 0.5 : float3(0.02, 0.02, 0.03);
                // ... and in front of it the dungeon's mob, small and turning,
                // as the game shows it in a spawner (scaled to 0.53125 of a
                // block over its height; the game also tips it 30 degrees,
                // which the kit's mob ray cannot). A quarter are skeletons,
                // the rest zombies; the game's spider is not in the kit.
                bool skel = ((fa.h >> 26) & 3u) == 0u;
                int type = skel ? MCMOB_SKELETON : MCMOB_ZOMBIE;
                const float k = 0.53125 / 1.95;
                float head = now * 1.2;
                float3 lro, lrd;
                mcMobRay(ro, rd, float3(v) + float3(0.5, 0.2, 0.5), head, lro, lrd);
                lro /= k;
                float tFar = (h.t + 1.8) / k;
                float2 mb = mcMobBounds(type, lro, lrd);
                if (mb.x < mb.y && mb.x < tFar) {
                    MCMOB_Skin sk = mcMobSkin(skel ? MCS_SKELETON : MCS_ZOMBIE);
                    MCMOB_Hit mh = mcMobTrace(type, mcMobStill(), sk, lro, lrd, tFar, skins, maps);
                    if (mh.t < tFar) {
                        float4 c = mcMobColor(type, mh, sk, mh.t * pxAngle * 16.0, skins, maps);
                        alb = c.rgb * mcFaceShade(mcMobNormal(mh.n, head)) / mcFaceShade(n);
                    }
                }
            }
        }

        // Things lying on a face: rails on a mineshaft floor, the ladder up
        // the cellar shaft, cobwebs in the mineshafts' upper corners.
        int3 fq = v - fa.o;
        if (n.y > 0.5) {
            bool railZ = fa.kind == F_MINE_Z && fq.x == 0 && fq.y == -1 && fq.z >= 0 && fq.z <= 34;
            bool railX = fa.kind == F_MINE_X && fq.z == 1 && fq.y == -1 && abs(fq.x) <= 12;
            if (railZ || railX) {
                float4 r = mcTileAniso(tiles, MC_RAIL, railZ ? uv : uv.yx, railZ ? gx : gx.yx, railZ ? gy : gy.yx);
                alb = mix(alb, r.rgb, r.a);
            }
        }
        if (mat == M_LADDER && n.z < -0.5) {
            float4 r = mcTileAniso(tiles, MC_LADDER, uv, gx, gy);
            alb = mix(alb, r.rgb, r.a);
        }

        // --- How it is lit. The air in front of the face, smoothly: sky
        // light 15 in front of the cut (the slab taken away leaves it open to
        // the sky) and down a ravine, falling a level a block back from the
        // cut; block light from torches and lava.
        float3 Pa = P + n * 0.5;
        float sky = outdoor ? 15.0 : 15.0 - max(Pa.z + 0.5, 0.0);
        bool rav = !outdoor && av.z >= 0 && av.y > -50 && stRavine(av.x, av.y, s);
        if (rav) sky = 15.0;
        float blk = max(stTorchLevel(Pa, fa), stLavaLevel(Pa, s));
        float shade = mcFaceShade(n);

        if (mat == M_LAVA) {
            col = alb * mcLightmap(15.0, sky, stLDay(), 0.0) * shade;
        } else {
            // Smooth lighting's corners. On the cut face only the blocks
            // standing proud of it can shade it, so only they are looked up.
            float ao;
            if (h.axis == 2 && v.z <= 0) {
                float o0 = float(stCut(v.x - 1, v.y, s) < 0), o1 = float(stCut(v.x + 1, v.y, s) < 0);
                float o2 = float(stCut(v.x, v.y - 1, s) < 0), o3 = float(stCut(v.x, v.y + 1, s) < 0);
                float2 e0 = 1.0 - l, e1 = l;
                ao = v.z < 0 ? 1.0 : 1.0 - 0.4 * saturate(o0 * e0.x * e0.x + o1 * e1.x * e1.x + o2 * e0.y * e0.y + o3 * e1.y * e1.y);
            } else if (P.z < 7.0) {
                ao = stAO(v, n, axis, l, s);
            } else {
                ao = 1.0;   // too far into the dark for it to show
            }
            col = alb * mcLightmap(blk, sky, stLDay(), 0.0) * shade * ao;

            // Glow lichen (light 7) on the walls of the deeper caves.
            McModelHit lh;
            if (!outdoor && av.z >= 0 && v.y < -4 && fa.kind == F_NONE
                && stRnd(av >> 2, s + 40u) < 0.3 && stRnd(v * 2 + int3(n), s + 41u) < 0.5
                && mcGlowLichen(tiles, float3(av), 1 << stDir(-n), ro, rd, h.t - 0.05, h.t + 1e-3, pxAngle, lh))
                col = lh.color.rgb * mcLightmap(max(blk, 7.0), sky, stLDay(), 0.0) * mcFaceShade(lh.n);
        }

        // The models in the air before the face, the kit's: chests in a
        // dungeon or cellar, amethyst on a geode's budding blocks, wall
        // torches and cobwebs in a mineshaft.
        float tEnd = h.t + 1e-3;
        McModelHit mh;
        if (!outdoor && av.z >= 0) {
            // Chests, latch to the glass. A dungeon has two, a cellar one.
            int3 ch[2];
            int nc = 0;
            if (fa.kind == F_DUNGEON) {
                ch[0] = fa.o + int3(2, 0, 5); ch[1] = fa.o + int3(-3, 0, 2); nc = 2;
            } else if (av.y > -12 && av.z <= 4) {
                StCellar ce = stCellarOf(av.x, s);
                if (ce.on) { ch[0] = ce.o + int3(-2, 0, 3); nc = 1; }
            }
            for (int i = 0; i < nc; ++i) {
                float2 cb = stBox(ro, rd, float3(ch[i]), float3(ch[i]) + 1.0);
                if (cb.x < cb.y && cb.x < tEnd
                    && mcChest(skins, MCS_CHEST_NORMAL, float3(ch[i]), MC_DIR_NORTH, ro, rd, cb.x - 1e-4, tEnd, pxAngle, mh)) {
                    tEnd = mh.t;
                    float cs = 15.0 - (float(ch[i].z) + 0.5);
                    col = mh.color.rgb * mcLightmap(blk, cs, stLDay(), 0.0) * mcFaceShade(mh.n);
                }
            }
        }
        if (fa.kind == F_GEODE) {
            // A budding block grows a cluster or a bud from its face toward
            // the geode's middle. The ray may cross the one on the block it
            // hit, or on one of that block's neighbours in the face.
            float3 gc = float3(fa.o) + float3(0.5, 0.5, 0.9 + 0.6 * fract(fa.ph * 3.1));
            int3 du = axis == 0 ? int3(0, 0, 1) : int3(1, 0, 0);
            int3 dv = axis == 1 ? int3(0, 0, 1) : int3(0, 1, 0);
            for (int i = 0; i < 5; ++i) {
                int3 b = v + (i == 1 ? du : (i == 2 ? -du : (i == 3 ? dv : (i == 4 ? -dv : int3(0)))));
                if (stFeature(b, fa) != M_BUDDING) continue;
                float3 w = gc - (float3(b) + 0.5), aw = abs(w);
                int dir = aw.x > aw.y && aw.x > aw.z ? (w.x > 0.0 ? MC_DIR_EAST : MC_DIR_WEST)
                        : (aw.y > aw.z ? (w.y > 0.0 ? MC_DIR_UP : MC_DIR_DOWN)
                                       : (w.z > 0.0 ? MC_DIR_SOUTH : MC_DIR_NORTH));
                int3 c = b + int3(mcDirVec(dir));
                if (stFeature(c, fa) != M_AIR) continue;
                float r = stRnd(b, s + 220u);
                int layer = r < 0.5 ? MC_AMETHYST_CLUSTER : (r < 0.75 ? MC_LARGE_AMETHYST_BUD : MC_MEDIUM_AMETHYST_BUD);
                float lv  = r < 0.5 ? 5.0 : (r < 0.75 ? 4.0 : 2.0);
                float2 cb = stBox(ro, rd, float3(c), float3(c) + 1.0);
                if (cb.x < cb.y && cb.x < tEnd
                    && mcCrossFacing(tiles, layer, float3(c), dir, float3(1.0), ro, rd, cb.x - 1e-4, tEnd, pxAngle, mh)) {
                    tEnd = mh.t;
                    col = mh.color.rgb * mcLightmap(max(blk, lv), 15.0 - max(float(c.z) + 0.5, 0.0), stLDay(), 0.0);
                }
            }
        }
        // The mineshafts' models in the air before the face: wall torches
        // and cobwebs, the kit's.
        if (fa.kind == F_MINE_Z || fa.kind == F_MINE_X) {
            // The torch nearest the face.
            int3 tc;
            int facing;
            if (fa.kind == F_MINE_Z) {
                int zt = clamp(int(floor((Pa.z - float(fa.o.z) - 2.0) / 8.0 + 0.5)), 0, 7) * 8 + 2;
                tc = fa.o + int3(-1, 1, zt); facing = 0;           // on the left post, leaning +x
            } else {
                int xt = clamp(int(floor((Pa.x - float(fa.o.x) - 4.0) / 8.0 + 0.5)), -2, 1) * 8 + 4;
                tc = fa.o + int3(xt, 1, 1); facing = 3;            // on a post, leaning to the glass
            }
            float2 cb = stBox(ro, rd, float3(tc), float3(tc) + 1.0);
            if (cb.x < cb.y && cb.x < tEnd
                && mcWallTorch(tiles, MC_TORCH, float3(tc), facing, ro, rd, cb.x - 1e-4, tEnd, pxAngle, mh)) {
                tEnd = mh.t;
                col = mh.color.rgb * mcLightmap(15.0, sky, stLDay(), 0.0) * (mh.shade > 0.5 ? mcFaceShade(mh.n) : 1.0);
            }
            // Cobwebs hang in the corners under the timbers: in a Z shaft along
            // both top corners, in an X shaft along the back. The first two
            // cells of each corner the ray crosses are tried.
            for (int b = 0; b < 2; ++b) {
                if (fa.kind == F_MINE_X && b == 1) break;
                float3 lo = fa.kind == F_MINE_Z ? float3(fa.o + int3(b == 0 ? -1 : 1, 2, 0))
                                                : float3(fa.o + int3(-12, 2, 2));
                float3 hi = lo + (fa.kind == F_MINE_Z ? float3(1.0, 1.0, 61.0) : float3(25.0, 1.0, 1.0));
                float2 r = stBox(ro, rd, lo, hi);
                if (!(r.x < r.y && r.x < tEnd)) continue;
                float3 E = ro + rd * (r.x + 1e-4);
                int3 c0 = int3(floor(E));
                for (int k = 0; k < 2; ++k) {
                    int3 c = c0;
                    if (fa.kind == F_MINE_Z) c.z += k * (rd.z > 0.0 ? 1 : -1);
                    else c.x += k * (rd.x > 0.0 ? 1 : -1);
                    int3 cq = c - fa.o;
                    bool post = fa.kind == F_MINE_X && (cq.x & 3) == 0;
                    if (post || stRnd(c, s + 210u) > 0.14 || all(c == tc)) continue;
                    float2 cr = stBox(ro, rd, float3(c), float3(c) + 1.0);
                    if (cr.x < cr.y && cr.x < tEnd
                        && mcCross(tiles, MC_COBWEB, float3(c), float3(1.0), ro, rd, cr.x - 1e-4, tEnd, pxAngle, mh)) {
                        tEnd = mh.t;
                        col = mh.color.rgb * mcLightmap(blk, sky, stLDay(), 0.0);
                    }
                }
            }
        }
        // Outdoors, the land goes into the fog; underground, into the dark.
        if (outdoor) col = mix(col, fogC, smoothstep(3.5, float(ST_OUTZ) - 0.5, P.z));
        else col = mix(col, rav ? stRavineFar() : float3(0.0), smoothstep(ST_ZMAX - 7.0, ST_ZMAX, P.z));
    }

    // A flooded cave: the face of the water where the ray went in, the
    // game's still water, animated and tinted, over whatever is behind it.
    if (h.water > 0.0) {
        float3 E = ro + rd * h.wIn;
        int wa = h.wAxis;
        float3 wn = float3(0.0);
        wn[wa] = rd[wa] > 0.0 ? -1.0 : 1.0;
        float2 wl = wa == 0 ? fract(E.zy) : (wa == 1 ? fract(E.xz) : fract(E.xy));
        float2 wgx, wgy;
        stGrad(rd, wn, wa, h.wIn * pxAngle, wgx, wgy);
        float4 w = mcTileAniso(tiles, mcFrame(MC_WATER_STILL, MC_WATER_STILL_FRAMES, MC_WATER_STILL_TICKS, now),
                               stPic(wl, wa), wgx, wgy);
        float wsky = 15.0 - max(E.z + 0.5 * wn.z + 0.5, 0.0);
        float3 wc = w.rgb * MC_WATER_TINT * mcLightmap(0.0, wsky, stLDay(), 0.0) * mcFaceShade(wn);
        col = mix(col, wc, w.a);
    }
    return col;
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]],
                        texture2d_array<float> mcTiles [[texture(8)]],
                        texture2d_array<float> mcSkins [[texture(10)]],
                        texture2d_array<float> mcMaps  [[texture(11)]]) {
    uint s = uint(u.seed * 1048576.0) * 747796405u + 2891336453u;
    float now = u.time;
    float minRes = min(u.resolution.x, u.resolution.y);

    float sink = u.dive != 0 ? 0.5 - 0.5 * cos(now * (TWO_PI / ST_DIVE)) : 0.0;
    float frac = u.depth + (1.0 - u.depth) * sink;
    float3 target = float3(now * u.speed + u.seed * 5000.0, mix(ST_TOP, ST_BOTTOM, frac), 0.0);
    float3 upHint = float3(0.0, 1.0, 0.0);
    float3 ro = target - float3(0.0, 0.0, ST_D);
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

    float3 col = stShade(ro, rd, pxAngle, s, now, stFogColor(fwd), mcTiles, mcSkins, mcMaps);
    col = lerpDither(saturate(col * u.light), pos);
    return half4(half3(col), 1.0h);
}
