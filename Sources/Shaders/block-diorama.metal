// Block Diorama — one Minecraft chunk, lifted out whole and floating above
// the cloud layer, with the game's sun and moon going round it.
// Drawn with the game's own textures from the copy installed on this Mac
// (`make minecraft`); none of them are in this file or this repo.
//
// lerp-category: Minecraft
// lerp-requires: minecraft
//
// On top: a plank cottage with glass windows, an oak door, a lamp by the
// path and smoke from its cobblestone chimney; trees; a spring pond and the
// stream it feeds, which runs to one cut edge and pours off it as falling
// water into the clouds. In the cut faces: grass, dirt, stone and deepslate,
// bedrock at the bottom, granite, andesite, diorite and tuff, ore seams, a
// tunnel or two, and a cave with a lava floor that glows out through the
// side. The day turns over it: the sky darkens, the moon goes through its
// phases, and at dusk the redstone lamp, the windows and the cave come up.
// Each seed digs a different chunk, in plains, cherry grove or snowy taiga.
//
// Lit as the game lights: fixed per-face shading, smooth-lighting corners,
// sky light and block light by level (a level a block from the source), the
// biome's grass, foliage and water tints, leaves, glass and plants cut out
// by their alpha. No sun shadows: the game has none.
//
// lerp-param: yaw      float -180 180 = 0  "Turn"
// lerp-param: pitch    float -90 90   = 0  "Tilt"
// lerp-param: magnify  float -1 1.2   = 0  "Zoom"
// lerp-param: spin     float 0 3      = 1  "Turn speed"
// lerp-param: daySpeed float 0 4      = 1  "Day speed"
// lerp-param: hour     float 0 24     = 9  "Time of day"
// lerp-param: biome    int 0 3        = 0  "Biome (0 = by seed)"
//
// lerp-preset: Plains   biome=1
// lerp-preset: Cherry   biome=2
// lerp-preset: Taiga    biome=3
// lerp-preset: Evening  daySpeed=0, hour=21.5

constant float DM_FOCAL   = 2.0;
constant float DM_DIST    = 37.0;     // eye to pivot, blocks
constant float DM_DAY     = 300.0;    // seconds per day at daySpeed 1
constant float DM_SUN_R   = 23.0;     // the sun's orbit round the pivot
constant int   DM_STEPS   = 72;       // primary voxel walk
constant int   DM_FALL_LO = -16;      // the waterfall's last block, in the clouds
constant float DM_CLOUD_Y = -16.0;    // the cloud layer
constant float DM_CLOUD_PX = 8.0;     // blocks per pixel of clouds.png

// Box the walk is clipped to: the chunk, and the waterfall's column beside it.
constant float3 DM_BOX_LO  = float3(0.0, 0.0, 0.0);
constant float3 DM_BOX_HI  = float3(16.0, 23.0, 16.0);
constant float3 DM_FALL_BOX_LO = float3(16.0, -16.0, 0.0);
constant float3 DM_FALL_BOX_HI = float3(17.0, 9.0, 16.0);

// Block ids.
constant int B_AIR = 0, B_GRASS = 1, B_DIRT = 2, B_STONE = 3, B_DEEP = 4,
             B_BEDROCK = 5, B_SAND = 6, B_GRAVEL = 7, B_CLAY = 8,
             B_ORE = 9,          // 9..15 ores in stone, 16..22 the same in deepslate
             B_GRANITE = 23, B_ANDESITE = 24, B_DIORITE = 25, B_TUFF = 26,
             B_LOG = 27,         // 27..30 oak, birch, spruce, cherry
             B_LEAVES = 31,      // 31..34 the same
             B_PLANKS = 35, B_COBBLE = 36, B_GLASS = 37, B_ROOF = 38,
             B_DOOR_LO = 39, B_DOOR_HI = 40, B_LAMP = 41, B_WATER = 42,
             B_LAVA = 43, B_FALL = 44, B_ICE = 45, B_PATH = 46,
             B_CRAFT = 47, B_FURNACE = 48, B_PLANT = 49, B_POST = 50;

constant int DM_ORE_STONE[7] = { MC_COAL_ORE, MC_IRON_ORE, MC_COPPER_ORE, MC_GOLD_ORE,
                                 MC_REDSTONE_ORE, MC_LAPIS_ORE, MC_DIAMOND_ORE };
constant int DM_ORE_DEEP[7]  = { MC_DEEPSLATE_COAL_ORE, MC_DEEPSLATE_IRON_ORE, MC_DEEPSLATE_COPPER_ORE,
                                 MC_DEEPSLATE_GOLD_ORE, MC_DEEPSLATE_REDSTONE_ORE, MC_DEEPSLATE_LAPIS_ORE,
                                 MC_DEEPSLATE_DIAMOND_ORE };
constant int DM_LOG_SIDE[4]  = { MC_OAK_LOG, MC_BIRCH_LOG, MC_SPRUCE_LOG, MC_CHERRY_LOG };
constant int DM_LOG_TOP[4]   = { MC_OAK_LOG_TOP, MC_BIRCH_LOG_TOP, MC_SPRUCE_LOG_TOP, MC_CHERRY_LOG_TOP };
constant int DM_LEAVES[4]    = { MC_OAK_LEAVES, MC_BIRCH_LEAVES, MC_SPRUCE_LEAVES, MC_CHERRY_LEAVES };
constant int DM_PLANKS[3]    = { MC_OAK_PLANKS, MC_CHERRY_PLANKS, MC_SPRUCE_PLANKS };
constant int DM_ROOFS[3]     = { MC_DARK_OAK_PLANKS, MC_SPRUCE_PLANKS, MC_BRICKS };
constant int DM_FLOWERS[4]   = { MC_POPPY, MC_DANDELION, MC_OXEYE_DAISY, MC_CORNFLOWER };
constant int DM_MOON[8]      = { MCS_ENVIRONMENT_CELESTIAL_MOON_FULL_MOON, MCS_ENVIRONMENT_CELESTIAL_MOON_WANING_GIBBOUS,
                                 MCS_ENVIRONMENT_CELESTIAL_MOON_THIRD_QUARTER, MCS_ENVIRONMENT_CELESTIAL_MOON_WANING_CRESCENT,
                                 MCS_ENVIRONMENT_CELESTIAL_MOON_NEW_MOON, MCS_ENVIRONMENT_CELESTIAL_MOON_WAXING_CRESCENT,
                                 MCS_ENVIRONMENT_CELESTIAL_MOON_FIRST_QUARTER, MCS_ENVIRONMENT_CELESTIAL_MOON_WAXING_GIBBOUS };
constant int DM_SMOKE[12]    = { MCS_PARTICLE_BIG_SMOKE_0, MCS_PARTICLE_BIG_SMOKE_1, MCS_PARTICLE_BIG_SMOKE_2,
                                 MCS_PARTICLE_BIG_SMOKE_3, MCS_PARTICLE_BIG_SMOKE_4, MCS_PARTICLE_BIG_SMOKE_5,
                                 MCS_PARTICLE_BIG_SMOKE_6, MCS_PARTICLE_BIG_SMOKE_7, MCS_PARTICLE_BIG_SMOKE_8,
                                 MCS_PARTICLE_BIG_SMOKE_9, MCS_PARTICLE_BIG_SMOKE_10, MCS_PARTICLE_BIG_SMOKE_11 };

// ---------------------------------------------------------------------------
// The world, decided once per pixel from the seed.

struct DmWorld {
    float4 ph;         // terrain wave phases
    int    W;          // water level (top water block's y)
    float  sz, sp;     // stream centre line z = sz + 2.6 sin(0.37 x + sp)
    float2 pond;       // spring pond centre
    int3   house;      // x0, z0, floor y
    int    roof;       // roof material
    int    biome;      // 0 plains, 1 cherry grove, 2 snowy taiga
    float  ta, tap;    // tunnel along x
    float  tb, tbp;    // tunnel along z
    float3 cham;       // lava cave centre
    uint   tree[16];   // packed x | z<<4 | ground<<8 | height<<13 | kind<<16 | 1<<20; 0 = none
};

static inline float dmHash3(int3 c, float s) {
    return hash21(float2(float(c.x) + 31.7 * float(c.y) + s * 7.13,
                         float(c.z) - 17.3 * float(c.y) + s * 3.71));
}

static inline float dmStreamZ(float x, thread const DmWorld& w) {
    return w.sz + 2.6 * sin(0.37 * x + w.sp);
}

// Ground height (the y of the top solid block) of column c, before the house
// flattens its plot.
static inline int dmRawGround(int2 c, thread const DmWorld& w) {
    float2 q = float2(c) + 0.5;
    // A few crossed waves: as rolling as value noise at this size, and far cheaper.
    float n = 0.5 + 0.30 * sin(0.41 * q.x + w.ph.x) * sin(0.36 * q.y + w.ph.y)
                  + 0.14 * sin(0.27 * (q.x + q.y) + w.ph.z)
                  + 0.08 * sin(0.83 * q.x - 0.61 * q.y + w.ph.w);
    float W = float(w.W);
    // Meadow one block above the water, with hills rising out of it.
    float h = W + 1.0 + max(n - 0.32, 0.0) * 11.0;
    // The spring pond and the stream it feeds, out to the +x edge, with
    // banks that slope down to them.
    float dp = length(q - w.pond);
    if (q.x > w.pond.x) {
        float ds = abs(q.y - dmStreamZ(q.x, w));
        if (ds < 1.25) h = W - 1.0;
        else if (ds < 2.0) h = min(h, W);
        else if (ds < 4.5) h = min(h, W + 1.0 + (ds - 2.0) * 1.6);
    }
    if (dp < 2.3) h = W - 2.0;
    else if (dp < 3.0) h = min(h, W - 1.0);
    else if (dp < 3.6) h = min(h, W);
    else if (dp < 5.5) h = min(h, W + 1.0 + (dp - 3.6) * 1.6);
    return int(floor(h));
}

static inline int dmGround(int2 c, thread const DmWorld& w) {
    int lx = c.x - w.house.x, lz = c.y - w.house.y;
    if (lx >= 0 && lx <= 4 && lz >= 0 && lz <= 4) return w.house.z;
    int g = dmRawGround(c, w);
    // The plot's surroundings grade into it, a block per block of distance.
    int d = max(max(-lx, lx - 4), max(-lz, lz - 4));
    if (d <= 4) g = clamp(g, w.house.z - d, w.house.z + d - 1);
    return g;
}

// A column's terrain plus what grows on it.
struct DmCol {
    int  h;          // ground
    int  trunkTop;   // log blocks h+1..trunkTop (or none)
    int  trunkKind;  // 0 oak, 1 birch, 2 spruce, 3 cherry
    uint leaves;     // bit y set: leaves at y
    int  leafKind;
    int  plant;      // texture of the plant standing on the ground, or -1
};

static inline uint dmLeafMask(int dx, int dz, int kind, int g, int T) {
    int ax = abs(dx), az = abs(dz);
    uint m = 0u;
    if (kind == 2) {
        // Spruce: a stepped cone, top at g+T+1.
        int top = g + T + 1;
        for (int L = 0; L < 6; ++L) {
            int r = (L == 0) ? 0 : ((L == 3 || L == 5) ? 2 : 1);
            bool in = (L == 1) ? (ax + az <= 1)
                    : (r == 2 ? (ax <= 2 && az <= 2 && !(ax == 2 && az == 2)) : (ax <= r && az <= r));
            if (in) m |= 1u << uint(top - L);
        }
        return m;
    }
    int b = g + T - 1;
    if (ax <= 2 && az <= 2 && !(ax == 2 && az == 2)) m |= 3u << uint(b);
    if (ax <= 1 && az <= 1) m |= 1u << uint(b + 2);
    if (ax + az <= 1) m |= 1u << uint(b + 3);
    return m;
}

static inline DmCol dmColumn(int2 c, thread const DmWorld& w) {
    DmCol col;
    col.h = dmGround(c, w);
    col.trunkTop = -100; col.trunkKind = 0; col.leaves = 0u; col.leafKind = 0; col.plant = -1;
    // Tree i sits in grid cell (i & 3, i >> 2), within blocks 2+3k .. 4+3k on
    // each axis, so only the cells whose crowns can reach this column are read.
    int2 lo = select((c - 4) / 3, int2(0), c < 4), hi = min(c / 3, int2(3));
    for (int cz = lo.y; cz <= hi.y; ++cz)
    for (int cx = lo.x; cx <= hi.x; ++cx) {
        uint t = w.tree[cz * 4 + cx];
        if (t == 0u) continue;
        int dx = c.x - int(t & 15u), dz = c.y - int((t >> 4) & 15u);
        if (abs(dx) > 2 || abs(dz) > 2) continue;
        int g = int((t >> 8) & 31u), T = int((t >> 13) & 7u), kind = int((t >> 16) & 3u);
        if (dx == 0 && dz == 0) { col.trunkTop = g + T; col.trunkKind = kind; }
        uint m = dmLeafMask(dx, dz, kind, g, T);
        if (m != 0u && col.leaves == 0u) col.leafKind = kind;
        col.leaves |= m;
    }
    // Grass and flowers on dry open ground (none under snow).
    if (w.biome != 2 && col.h > w.W && col.trunkTop < 0) {
        int lx = c.x - w.house.x, lz = c.y - w.house.y;
        bool plot = lx >= -1 && lx <= 5 && lz >= -3 && lz <= 5;
        float hp = hash21(float2(c) * 1.37 + float(w.biome) * 5.1 + w.ph.x);
        if (!plot && c.x >= 0 && c.x <= 15 && c.y >= 0 && c.y <= 15 && hp < 0.34) {
            float k = hp / 0.34;
            col.plant = (w.biome == 0 && k < 0.3) ? DM_FLOWERS[int(k * 13.3) & 3] : MC_SHORT_GRASS;
        }
    }
    return col;
}

// Underground hollows: 1 = tunnel, 2 = the lava cave.
static inline int dmCave(int3 c, thread const DmWorld& w) {
    float3 q = float3(c) + 0.5;
    float3 e = (q - w.cham) / float3(3.3, 2.3, 2.7);
    if (dot(e, e) < 1.0) return 2;
    float2 dA = float2(q.z - w.ta - 2.2 * sin(0.31 * q.x + w.tap),
                       (q.y - 4.2 - 1.4 * sin(0.43 * q.x + 1.7 * w.tap)) * 1.25);
    if (dot(dA, dA) < 1.6) return 1;
    if (q.z > 5.5) {
        float2 dB = float2(q.x - w.tb - 2.0 * sin(0.33 * q.z + w.tbp),
                           (q.y - 5.0 - 1.2 * sin(0.41 * q.z + w.tbp)) * 1.25);
        if (dot(dB, dB) < 1.4) return 1;
    }
    return 0;
}

static inline int dmStoneAt(int3 c) {
    int y = c.y;
    float hj = hash21(float2(c.xz) * 0.71 + 3.3);
    bool deep = y <= 3 + int(hj * 2.0);
    int3 cl = int3(floor(float3(c) * 0.5));
    float hc = dmHash3(cl, 11.0);
    if (hc < 0.15 && dmHash3(c, 12.0) < 0.62) {
        float k = hc / 0.15;
        int ore = -1;
        if (k < 0.30 && y >= 4)       ore = 0;   // coal
        else if (k < 0.50 && y <= 10) ore = 1;   // iron
        else if (k < 0.62 && y >= 3)  ore = 2;   // copper
        else if (k < 0.70 && y <= 6)  ore = 3;   // gold
        else if (k < 0.82 && y <= 5)  ore = 4;   // redstone
        else if (k < 0.91 && y <= 7)  ore = 5;   // lapis
        else if (y <= 4)              ore = 6;   // diamond
        if (ore >= 0) return B_ORE + ore + (deep ? 7 : 0);
    }
    float hp = dmHash3(int3(floor(float3(c) / 3.0)), 13.0);
    if (deep) return hp < 0.14 ? B_TUFF : B_DEEP;
    if (hp < 0.07) return B_GRANITE;
    if (hp < 0.13) return B_ANDESITE;
    if (hp < 0.18) return B_DIORITE;
    if (hp > 0.94) return B_GRAVEL;
    if (hp > 0.89) return B_DIRT;
    return B_STONE;
}

// `full` false: only whether it is air, water, falling water, a cutout or
// solid, which is all the walk needs.
static inline int dmBlock(int3 c, DmCol col, thread const DmWorld& w, bool full) {
    int y = c.y;
    if (c.x == 16) {
        // Falling water against the +x cut face, under the stream's mouth.
        if (c.z < 0 || c.z > 15 || y > w.W || y < DM_FALL_LO) return B_AIR;
        float ds = abs(float(c.z) + 0.5 - dmStreamZ(15.5, w));
        return ds < 1.25 ? B_FALL : B_AIR;
    }
    if (c.x < 0 || c.x > 15 || c.z < 0 || c.z > 15 || y < 0) return B_AIR;

    if (y <= col.h) {
        if (y == 0) return B_BEDROCK;
        if (y <= col.h - 3) {
            int cave = dmCave(c, w);
            if (cave == 2 && y <= 1) return B_LAVA;
            if (cave != 0 && y >= 1) return B_AIR;
        }
        if (!full) return B_STONE;
        float hb = dmHash3(c, 1.0);
        if ((y == 1 && hb < 0.55) || (y == 2 && hb < 0.18)) return B_BEDROCK;
        bool wet = col.h <= w.W;
        int lx = c.x - w.house.x, lz = c.z - w.house.y;
        if (y == col.h) {
            if (col.h < w.W) return (hb < 0.3) ? B_GRAVEL : (hb < 0.55 ? B_CLAY : B_SAND);
            if (wet) return B_SAND;
            if (lx >= 0 && lx <= 4 && lz >= 0 && lz <= 4) return B_PLANKS;   // the cottage floor
            if (lx == 2 && lz < 0 && lz >= -3) return B_PATH;
            return B_GRASS;
        }
        if (y >= col.h - 2) return wet ? B_SAND : B_DIRT;
        return dmStoneAt(c);
    }

    if (y <= w.W && col.h < w.W) return (w.biome == 2 && y == w.W) ? B_ICE : B_WATER;

    // The cottage: 5×5, walls three high, a stepped gable along x.
    int lx = c.x - w.house.x, lz = c.z - w.house.y, ly = y - w.house.z;
    if (lx >= -1 && lx <= 5 && lz >= -2 && lz <= 5 && ly >= 1 && ly <= 8) {
        if (lx == 3 && lz == 3 && ly >= 4 && ly <= 7) return B_COBBLE;   // chimney
        if (lz >= -1) {
            int ry = 6 - abs(lz - 2);
            if (ly == ry) return B_ROOF;
            bool inX = lx >= 0 && lx <= 4, inZ = lz >= 0 && lz <= 4;
            if (inX && inZ && ly < ry) {
                bool ex = lx == 0 || lx == 4, ez = lz == 0 || lz == 4;
                if (ly <= 3) {
                    if (ex && ez) return B_POST;
                    if (ex || ez) {
                        if (lz == 0 && lx == 2) return ly == 1 ? B_DOOR_LO : (ly == 2 ? B_DOOR_HI : B_PLANKS);
                        if (ly == 2 && ((ez && lx != 2) || (ex && lz == 2))) return B_GLASS;
                        return ly == 1 ? B_COBBLE : B_PLANKS;
                    }
                    if (ly == 1 && lx == 1 && lz == 3) return B_CRAFT;
                    if (ly == 1 && lx == 3 && lz == 1) return B_FURNACE;
                    return B_AIR;
                }
                if (ex) return B_PLANKS;
                return B_AIR;
            }
        } else if (lx == 0 && ly <= 2) {
            return ly == 1 ? B_COBBLE : B_LAMP;   // a redstone lamp by the path
        }
    }

    if (y <= col.trunkTop) return B_LOG + col.trunkKind;
    if (y < 32 && ((col.leaves >> uint(y)) & 1u) != 0u) return B_LEAVES + col.leafKind;
    if (y == col.h + 1 && col.plant >= 0) return B_PLANT;
    return B_AIR;
}

// Blocks that hide what is behind them and darken their neighbours' corners.
static inline bool dmOpaque(int id) {
    return id != B_AIR && id != B_WATER && id != B_FALL && id != B_PLANT && id != B_GLASS && id != B_ICE;
}
// Blocks whose texture alpha decides where a ray stops.
static inline bool dmCutout(int id) {
    return (id >= B_LEAVES && id <= B_LEAVES + 3) || id == B_GLASS || id == B_DOOR_LO || id == B_DOOR_HI;
}

static inline int dmBlockAt(int3 c, thread const DmWorld& w) {
    return dmBlock(c, dmColumn(c.xz, w), w, false);
}

static DmWorld dmMakeWorld(float seed, int biomeParam) {
    DmWorld w;
    float s = seed * 97.13;
    w.ph = float4(hash11(s + 1.0), hash11(s + 2.0), hash11(s + 13.0), hash11(s + 14.0)) * TWO_PI;
    w.W = 8;
    w.sz = 6.0 + 4.0 * hash11(s + 3.0);
    w.sp = TWO_PI * hash11(s + 4.0);
    w.pond = float2(3.6 + hash11(s + 5.0), dmStreamZ(4.0, w));
    w.pond.y = clamp(w.pond.y, 4.0, 12.0);
    float hb = hash11(s + 6.0);
    w.biome = biomeParam > 0 ? biomeParam - 1 : (hb < 0.45 ? 0 : (hb < 0.7 ? 1 : 2));
    w.roof = int(hash11(s + 7.0) * 3.0);
    w.ta = 3.5 + 3.0 * hash11(s + 8.0);
    w.tap = TWO_PI * hash11(s + 9.0);
    w.tb = 6.0 + 5.0 * hash11(s + 10.0);
    w.tbp = TWO_PI * hash11(s + 11.0);
    w.cham = float3(5.0 + 6.0 * hash11(s + 12.0), 2.6, 1.2);

    // The cottage takes the best dry plot of four, away from the stream.
    w.house = int3(-100, -100, 0);
    float best = 1e9;
    for (int k = 0; k < 4; ++k) {
        int2 o = int2(2 + 7 * (k & 1), 3 + 6 * (k >> 1));
        o += int2(int(hash11(s + 20.0 + float(k)) * 2.0), int(hash11(s + 30.0 + float(k)) * 2.0));
        float2 mid = float2(o) + 2.5;
        float ds = abs(mid.y - dmStreamZ(mid.x, w));
        float dp = length(mid - w.pond);
        int g0 = dmRawGround(o, w), g3 = dmRawGround(o + int2(4, 4), w);
        int gm = dmRawGround(o + int2(2, 2), w);
        float spread = float(max(max(g0, g3), gm) - min(min(g0, g3), gm));
        float cost = spread + (gm <= w.W ? 50.0 : 0.0) + (ds < 4.5 ? 30.0 : 0.0) + (dp < 5.5 ? 30.0 : 0.0)
                   + hash11(s + 40.0 + float(k)) * 0.5;
        if (cost < best) { best = cost; w.house = int3(o, max(gm, w.W + 1)); }
    }

    // Trees, one chance per cell of a 4×4 grid, kept off the water and the plot.
    for (int i = 0; i < 16; ++i) {
        int cx = i & 3, cz = i >> 2;
        float h0 = hash11(s + 50.0 + float(i) * 3.1);
        float h1 = hash11(s + 51.0 + float(i) * 3.7);
        float h2 = hash11(s + 52.0 + float(i) * 4.3);
        int2 tp = int2(2 + cx * 3 + (cz & 1) + int(h1 * 2.0), 2 + cz * 3 + int(h2 * 2.0) + (cx & 1));
        tp = min(tp, int2(13));
        w.tree[i] = 0u;
        if (h0 > 0.85) continue;
        int lx = tp.x - w.house.x, lz = tp.y - w.house.y;
        if (lx >= -2 && lx <= 6 && lz >= -3 && lz <= 6) continue;
        int g = dmRawGround(tp, w);
        if (g <= w.W) continue;
        float2 q = float2(tp) + 0.5;
        if (q.x > w.pond.x - 1.0 && abs(q.y - dmStreamZ(q.x, w)) < 2.2) continue;
        int kind = w.biome == 2 ? 2 : (w.biome == 1 ? 3 : (h1 * 7.0 - floor(h1 * 7.0) < 0.3 ? 1 : 0));
        int T = (kind == 2 ? 5 : 4) + int(h2 * 7.0 - floor(h2 * 7.0) < 0.5);
        w.tree[i] = uint(tp.x) | (uint(tp.y) << 4) | (uint(g) << 8) | (uint(T) << 13) | (uint(kind) << 16) | (1u << 20);
    }
    return w;
}

// ---------------------------------------------------------------------------
// Textures: which of the game's tiles a face shows.

struct DmLook {
    float3 grass, foliage, water;   // biome tints
    float  now;
    bool   lampOn;
};

// The texture of block `id`'s face with normal `n` at face uv `fu` (0..1,
// v down the picture), tinted as the game tints it.
static float4 dmFace(int id, float3 n, float2 fu, float fp, int3 cell, thread const DmWorld& w,
                     DmLook K, texture2d_array<float> T) {
    bool top = n.y > 0.5, bottom = n.y < -0.5, side = !top && !bottom;
    switch (id) {
    case B_GRASS:
        if (w.biome == 2) {
            if (top) return mcTile(T, MC_SNOW, fu, fp);
            if (side) return mcTile(T, MC_GRASS_BLOCK_SNOW, fu, fp);
            return mcTile(T, MC_DIRT, fu, fp);
        }
        if (top) {
            float4 c = mcTile(T, MC_GRASS_BLOCK_TOP, fu, fp) * float4(K.grass, 1.0);
            if (w.biome == 1 && dmHash3(cell, 2.0) < 0.4) {
                // Pink petals strewn on the grass.
                float4 p = mcTile(T, MC_PINK_PETALS, fu, fp);
                c.rgb = mix(c.rgb, p.rgb, p.a);
            }
            return c;
        }
        if (side) return float4(mcGrassSide(T, fu, fp, K.grass), 1.0);
        return mcTile(T, MC_DIRT, fu, fp);
    case B_DIRT:     return mcTile(T, MC_DIRT, fu, fp);
    case B_PATH:     return mcTile(T, top ? MC_DIRT_PATH_TOP : (side ? MC_DIRT_PATH_SIDE : MC_DIRT), fu, fp);
    case B_STONE:    return mcTile(T, MC_STONE, fu, fp);
    case B_DEEP:     return mcTile(T, side ? MC_DEEPSLATE : MC_DEEPSLATE_TOP, fu, fp);
    case B_BEDROCK:  return mcTile(T, MC_BEDROCK, fu, fp);
    case B_SAND:     return mcTile(T, MC_SAND, fu, fp);
    case B_GRAVEL:   return mcTile(T, MC_GRAVEL, fu, fp);
    case B_CLAY:     return mcTile(T, MC_CLAY, fu, fp);
    case B_GRANITE:  return mcTile(T, MC_GRANITE, fu, fp);
    case B_ANDESITE: return mcTile(T, MC_ANDESITE, fu, fp);
    case B_DIORITE:  return mcTile(T, MC_DIORITE, fu, fp);
    case B_TUFF:     return mcTile(T, MC_TUFF, fu, fp);
    case B_PLANKS:   return mcTile(T, DM_PLANKS[w.biome], fu, fp);
    case B_POST:     return mcTile(T, side ? DM_LOG_SIDE[w.biome == 1 ? 3 : (w.biome == 2 ? 2 : 0)]
                                           : DM_LOG_TOP[w.biome == 1 ? 3 : (w.biome == 2 ? 2 : 0)], fu, fp);
    case B_COBBLE:   return mcTile(T, MC_COBBLESTONE, fu, fp);
    case B_ROOF:     return mcTile(T, DM_ROOFS[w.roof], fu, fp);
    case B_GLASS:    return mcTile(T, MC_GLASS, fu, fp);
    case B_DOOR_LO: case B_DOOR_HI:
        if (abs(n.z) > 0.5) return mcTile(T, id == B_DOOR_HI ? MC_OAK_DOOR_TOP : MC_OAK_DOOR_BOTTOM, fu, fp);
        return mcTile(T, MC_OAK_PLANKS, fu, fp);
    case B_LAMP:     return mcTile(T, K.lampOn ? MC_REDSTONE_LAMP_ON : MC_REDSTONE_LAMP, fu, fp);
    case B_CRAFT:    return mcTile(T, top ? MC_CRAFTING_TABLE_TOP : (bottom ? MC_OAK_PLANKS
                                     : (n.z < -0.5 ? MC_CRAFTING_TABLE_FRONT : MC_CRAFTING_TABLE_SIDE)), fu, fp);
    case B_FURNACE:  return mcTile(T, side ? (n.z < -0.5 ? (K.lampOn ? MC_FURNACE_FRONT_ON : MC_FURNACE_FRONT)
                                                         : MC_FURNACE_SIDE) : MC_FURNACE_TOP, fu, fp);
    case B_LAVA:     return mcTile(T, mcFrame(MC_LAVA_STILL, MC_LAVA_STILL_FRAMES, MC_LAVA_STILL_TICKS, K.now), fu, fp);
    case B_ICE:      return mcTile(T, MC_ICE, fu, fp);
    case B_WATER: {
        float4 c = mcTile(T, mcFrame(MC_WATER_STILL, MC_WATER_STILL_FRAMES, MC_WATER_STILL_TICKS, K.now), fu, fp);
        return float4(c.rgb * K.water, c.a);
    }
    }
    if (id >= B_ORE && id < B_ORE + 14) {
        int k = id - B_ORE;
        return mcTile(T, k < 7 ? DM_ORE_STONE[k] : DM_ORE_DEEP[k - 7], fu, fp);
    }
    if (id >= B_LOG && id < B_LOG + 4) {
        int k = id - B_LOG;
        return mcTile(T, side ? DM_LOG_SIDE[k] : DM_LOG_TOP[k], fu, fp);
    }
    if (id >= B_LEAVES && id < B_LEAVES + 4) {
        int k = id - B_LEAVES;
        float4 c = mcTile(T, DM_LEAVES[k], fu, fp);
        // Oak takes the biome's foliage colour; birch and spruce have fixed
        // tints; cherry blossom is already pink.
        float3 tint = k == 0 ? K.foliage : (k == 1 ? mcFromSRGB(float3(0.502, 0.655, 0.333))
                                          : (k == 2 ? mcFromSRGB(float3(0.380, 0.600, 0.380)) : float3(1.0)));
        return float4(c.rgb * tint, c.a);
    }
    return float4(1.0, 0.0, 1.0, 1.0);
}

// Face uv of a hit at P on the face of `cell` with normal axis `axis`: x, z on
// tops; along the face and down the picture on sides.
static inline float2 dmFaceUV(float3 P, int3 cell, int axis) {
    float3 l = P - float3(cell);
    if (axis == 1) return saturate(float2(l.x, l.z));
    return saturate(float2(axis == 0 ? l.z : l.x, 1.0 - l.y));
}

// ---------------------------------------------------------------------------
// Rays.

static inline float2 dmBox(float3 ro, float3 inv, float3 lo, float3 hi) {
    float3 a = (lo - ro) * inv, b = (hi - ro) * inv;
    float3 tn = min(a, b), tf = max(a, b);
    return float2(max(max(tn.x, tn.y), tn.z), min(min(tf.x, tf.y), tf.z));
}

static inline float3 dmSafeDir(float3 rd) {
    return select(rd, float3(1e-6), abs(rd) < 1e-6);
}

// Smooth lighting: each corner of a face darkens with the solid blocks round
// it, from the eight blocks about the air cell in front, blended across.
static float dmAO(int3 a, int axis, float2 uv, DmCol ca, thread const DmWorld& w) {
    int3 t1 = axis == 0 ? int3(0, 0, 1) : int3(1, 0, 0);
    int3 t2 = axis == 1 ? int3(0, 0, 1) : int3(0, 1, 0);
    float s[8];
    const int2 o[8] = { int2(-1, 0), int2(1, 0), int2(0, -1), int2(0, 1),
                        int2(-1, -1), int2(1, -1), int2(-1, 1), int2(1, 1) };
    if (axis == 1) {
        for (int i = 0; i < 8; ++i) s[i] = dmOpaque(dmBlockAt(a + t1 * o[i].x + t2 * o[i].y, w)) ? 1.0 : 0.0;
    } else {
        // A side face: the eight neighbours stand in three columns.
        const int lo[3] = { 4, 2, 5 }, mid[3] = { 0, 0, 1 }, hi[3] = { 6, 3, 7 };
        for (int k = 0; k < 3; ++k) {
            int3 b = a + t1 * (k - 1);
            DmCol cc = k == 1 ? ca : dmColumn(b.xz, w);
            s[lo[k]] = dmOpaque(dmBlock(b - int3(0, 1, 0), cc, w, false)) ? 1.0 : 0.0;
            s[hi[k]] = dmOpaque(dmBlock(b + int3(0, 1, 0), cc, w, false)) ? 1.0 : 0.0;
            if (k != 1) s[mid[k]] = dmOpaque(dmBlock(b, cc, w, false)) ? 1.0 : 0.0;
        }
    }
    // corners: (-,-) (+,-) (-,+) (+,+)
    float4 side1 = float4(s[0], s[1], s[0], s[1]);
    float4 side2 = float4(s[2], s[2], s[3], s[3]);
    float4 corn  = float4(s[4], s[5], s[6], s[7]);
    float4 occ = select(side1 + side2 + corn, float4(3.0), side1 * side2 > 0.5);
    float4 v = 1.0 - occ * 0.2;
    return mix(mix(v.x, v.y, uv.x), mix(v.z, v.w, uv.x), uv.y);
}

struct DmSky {
    float  day;          // the game's sky brightness, 0 night .. 1 day
    float3 sunPos, moonPos;
    float  sunUp;        // sun height on its orbit, -1..1
    bool   lampOn;
    int3   lamp;         // block positions of the lights
    float3 lavaLo, lavaHi;
};

// The air cell a's sky light and block light, as the game would have them.
static float2 dmLightLevels(int3 a, DmCol c, thread const DmWorld& w, DmSky L) {
    float sky = 15.0;
    bool inside = a.x >= 0 && a.x <= 15 && a.z >= 0 && a.z <= 15 && a.y >= 0;
    int lx = a.x - w.house.x, lz = a.z - w.house.y, ly = a.y - w.house.z;
    bool room = lx >= 1 && lx <= 3 && lz >= 1 && lz <= 3 && ly >= 1 && ly <= 4;
    if (inside) {
        int topY = max(c.h, c.trunkTop);
        if (c.leaves != 0u) topY = max(topY, 31 - int(clz(c.leaves)));
        if (lx >= -1 && lx <= 5 && lz >= -1 && lz <= 5) topY = max(topY, w.house.z + 6 - abs(lz - 2));
        if (a.y <= c.h) {
            // In a cave: daylight seeps in from the cut faces, a level a block.
            int edge = min(min(a.x, 15 - a.x), min(a.z, 15 - a.z));
            sky = max(14.0 - float(edge), 0.0);
        } else if (room) {
            sky = 9.0;
        } else if (a.y <= topY) {
            sky = 13.0;
        }
    }
    float blk = 0.0;
    // Lava: 15 at the pool, one less a block away.
    float3 q = float3(a) + 0.5;
    float3 d = max(max(L.lavaLo - q, q - L.lavaHi), 0.0);
    blk = max(blk, 15.0 - (d.x + d.y + d.z));
    // The redstone lamp, at night.
    if (L.lampOn) { int3 e = abs(a - L.lamp); blk = max(blk, 15.0 - float(e.x + e.y + e.z)); }
    // Torches inside the cottage: light through the windows and the door.
    if (room) blk = max(blk, 13.0);
    else {
        int3 hb = int3(w.house.x, w.house.z, w.house.y);
        const int3 win[7] = { int3(1, 2, 0), int3(3, 2, 0), int3(1, 2, 4), int3(3, 2, 4),
                              int3(0, 2, 2), int3(4, 2, 2), int3(2, 1, 0) };
        int3 al = int3(a.x, a.y, a.z) - hb;
        for (int i = 0; i < 7; ++i) {
            int3 e = abs(al - win[i]);
            blk = max(blk, 12.0 - float(e.x + e.y + e.z));
        }
    }
    return float2(sky, max(blk, 0.0));
}

// The game's lightmap: sky light dims by ten levels at night and
// turns blue; block light is warm. Brightness is the game's "Bright" setting,
// which a screensaver wants at night.
static float3 dmLightmap(float2 lv, float day) {
    float s = mcLight(max(lv.x - 10.0 * (1.0 - day), 0.0));
    float b = mcLight(lv.y);
    s = 1.0 - pow(1.0 - s, 4.0);
    b = 1.0 - pow(1.0 - b, 4.0);
    float3 sc = s * mix(float3(0.62, 0.66, 0.9), float3(1.0), day);
    float3 bc = b * float3(1.0, 0.9, 0.74);
    return max(max(sc, bc), float3(0.035, 0.035, 0.045));
}

// The sky behind everything: the game's sky and fog colours, a sunrise glow
// on the sun's side, and stars at night.
static float3 dmSkyColour(float3 rd, DmSky L, float3 pivot) {
    float3 sky = MC_SKY_DAY * L.day;
    float3 fog = MC_FOG_DAY * (L.day * 0.94 + 0.06);
    float3 c = rd.y > 0.0 ? mix(fog, sky, sqrt(rd.y)) : mix(fog, sky * 0.55, smoothstep(0.0, 0.5, -rd.y));
    float3 sd = normalize(L.sunPos - pivot);
    float glow = saturate(1.0 - abs(L.sunUp) * 2.6) * pow(saturate(dot(rd, sd)), 6.0);
    c = mix(c, mcFromSRGB(float3(0.98, 0.52, 0.22)), 0.75 * glow * smoothstep(-0.35, 0.25, rd.y) * (1.0 - smoothstep(0.1, 0.5, rd.y)));
    // Stars: small square points, brightening as the sky goes dark.
    float3 sc = rd * 150.0;
    float3 cell = floor(sc);
    float hs = hash21(cell.xy * 0.37 + cell.z * 1.71);
    float3 f = abs(sc - cell - 0.5);
    float star = step(0.986, hs) * step(max(f.x, max(f.y, f.z)), 0.22);
    c += star * saturate(1.0 - L.day * 1.6) * (0.4 + 0.5 * fract(hs * 91.0));
    return c;
}

// A camera-facing square at p of half-size hs: the point's (0..1, 0..1)
// position on it, with y down, or false.
static inline bool dmBillboard(float3 ro, float3 rd, float3 p, float hs, float3 right, float3 up,
                               float3 fwd, thread float& t, thread float2& st) {
    float den = dot(rd, fwd);
    t = dot(p - ro, fwd) / den;
    if (t <= 0.0) return false;
    float3 q = ro + rd * t - p;
    float2 l = float2(dot(q, right), dot(q, up)) / hs;
    if (any(abs(l) > 1.0)) return false;
    st = float2(l.x, -l.y) * 0.5 + 0.5;
    return true;
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]],
                        texture2d_array<float> mcTiles [[texture(8)]],
                        texture2d_array<float> mcSkins [[texture(10)]],
                        texture2d_array<float> mcMaps  [[texture(11)]]) {
    float2 uv = lerpUV(pos, u.resolution);
    float minRes = min(u.resolution.x, u.resolution.y);
    float pxAngle = 2.0 / (minRes * DM_FOCAL);
    float now = u.time;

    // --- Camera: a slow turn round the specimen, the elevation breathing.
    float3 pivot = float3(8.5, 8.0, 8.0);
    float az = 0.6 + u.seed * TWO_PI + now * 0.031 * u.spin;
    float el = 0.58 + 0.08 * sin(now * 0.0123 + u.seed * 11.0);
    float3 ro = pivot + DM_DIST * float3(cos(el) * sin(az), sin(el), cos(el) * cos(az));
    float3 fwd = normalize(pivot - ro);
    float3 right = normalize(cross(fwd, float3(0.0, 1.0, 0.0)));
    lerpOrbit(u.yaw, u.pitch, u.magnify, pivot, float3(0.0, 1.0, 0.0), ro, right, fwd);
    float3 up = cross(right, fwd);
    float3 rd = normalize(uv.x * right + uv.y * up + DM_FOCAL * fwd);

    // --- The day. The sun's orbit is tilted, so noon is high but not overhead.
    float dayClock = u.hour / 24.0 + u.daySpeed * (now + u.seed * DM_DAY) / DM_DAY;
    float th = TWO_PI * dayClock - 0.5 * PI;
    float3 dh = normalize(float3(1.0, 0.0, 0.45));
    float3 dv = normalize(float3(0.0, 1.0, 0.0) + 0.35 * cross(dh, float3(0.0, 1.0, 0.0)));
    float3 sunOff = DM_SUN_R * (cos(th) * dh + sin(th) * dv);
    DmSky L;
    L.sunPos = pivot + sunOff;
    L.moonPos = pivot - sunOff;
    L.sunUp = sunOff.y / DM_SUN_R;
    L.day = saturate(L.sunUp * 2.0 + 0.5);              // the game's own curve
    L.lampOn = L.day < 0.45;                             // a daylight detector's switch

    float3 rdS = dmSafeDir(rd);
    float3 inv = 1.0 / rdS;

    // --- The background: sky, then the cloud layer the chunk floats over.
    float3 col = dmSkyColour(rd, L, pivot);
    if (rd.y < -0.01) {
        float tc = (DM_CLOUD_Y - ro.y) / rd.y;
        float3 P = ro + rd * tc;
        float2 px = glmod2((P.xz + float2(now * 0.25 + u.seed * 400.0, u.seed * 300.0)) / DM_CLOUD_PX, 256.0);
        float wpx = tc * pxAngle / max(-rd.y, 0.15) / DM_CLOUD_PX;
        float4 cl = mcMap(mcMaps, MCM_ENVIRONMENT_CLOUDS, px, wpx);
        float3 cloudCol = mix(float3(0.06, 0.06, 0.1), float3(1.0), L.day);
        float a = cl.a * 0.8 * (1.0 - smoothstep(70.0, 160.0, tc));
        col = mix(col, cloudCol * mix(0.85, 1.0, L.day), a);
    }

    // --- Sun and moon, the game's textures, added to the sky as it does.
    {
        float tb; float2 st;
        if (dmBillboard(ro, rd, L.sunPos, 3.2, right, up, fwd, tb, st))
            col += mcSkin(mcSkins, MCS_ENVIRONMENT_CELESTIAL_SUN, st * 32.0, 0.0).rgb;
        int phase = int(glmod(floor(dayClock + 0.5), 8.0));
        if (dmBillboard(ro, rd, L.moonPos, 2.6, right, up, fwd, tb, st))
            col += mcSkin(mcSkins, DM_MOON[phase], st * 32.0, 0.0).rgb;
    }

    // --- The voxel walk.
    float2 tbM = dmBox(ro, inv, DM_BOX_LO, DM_BOX_HI);
    float2 tbF = dmBox(ro, inv, DM_FALL_BOX_LO, DM_FALL_BOX_HI);
    bool inM = tbM.y > max(tbM.x, 0.0), inF = tbF.y > max(tbF.x, 0.0);
    if (inM || inF) {
        DmWorld w = dmMakeWorld(u.seed, u.biome);
        L.lamp = int3(w.house.x, w.house.z + 2, w.house.y - 2);
        L.lavaLo = float3(w.cham.x - 3.0, 1.0, 0.0);
        L.lavaHi = float3(w.cham.x + 3.0, 2.0, w.cham.z + 2.2);
        DmLook K;
        K.now = now;
        K.lampOn = L.lampOn;
        float2 clim = w.biome == 0 ? float2(0.8, 0.4) : (w.biome == 1 ? float2(0.5, 0.8) : float2(0.25, 0.8));
        K.grass = mcGrassTint(mcMaps, clim.x, clim.y);
        K.foliage = mcFoliageTint(mcMaps, clim.x, clim.y);
        K.water = w.biome == 1 ? mcFromSRGB(float3(0.365, 0.718, 0.937)) : MC_WATER_TINT;
        float3 skyLight = dmLightmap(float2(15.0, 0.0), L.day);

        float2 tb = float2(min(inM ? tbM.x : 1e9, inF ? tbF.x : 1e9), max(inM ? tbM.y : -1e9, inF ? tbF.y : -1e9));
        float3 boxLo = (inM && tbM.x <= tb.x) ? DM_BOX_LO : DM_FALL_BOX_LO;
        float3 boxHi = (inM && tbM.x <= tb.x) ? DM_BOX_HI : DM_FALL_BOX_HI;
        float t = max(tb.x, 0.0);
        int3 c = clamp(int3(floor(ro + rdS * (t + 1e-4))), int3(boxLo), int3(boxHi) - 1);
        int3 stp = int3(sign(rdS));
        float3 tMax = (float3(c) + select(float3(0.0), float3(1.0), rdS > 0.0) - ro) * inv;
        float3 tDelta = abs(inv);
        float3 tn = min((boxLo - ro) * inv, (boxHi - ro) * inv);
        int axis = (tn.x > tn.y && tn.x > tn.z) ? 0 : (tn.y > tn.z ? 1 : 2);

        float3 accCol = float3(0.0);
        float accT = 1.0;
        bool hit = false;
        float tHit = 1e9;
        int3 hc = int3(0); int hid = 0; int haxis = 1;
        float3 hn = float3(0.0, 1.0, 0.0);
        float4 plantTex = float4(0.0);
        int2 colXZ = int2(-999);
        DmCol colInfo;
        int prev = B_AIR;
        for (int i = 0; i < DM_STEPS; ++i) {
            float tNext = min(tMax.x, min(tMax.y, tMax.z));
            int id;
            if (c.x > 15 || c.y < 0) {
                // Beside or below the chunk only the falling water exists.
                float ds = abs(float(c.z) + 0.5 - dmStreamZ(15.5, w));
                id = (c.x == 16 && c.y <= w.W && c.y >= DM_FALL_LO && ds < 1.25) ? B_FALL : B_AIR;
            } else {
                if (any(c.xz != colXZ)) { colInfo = dmColumn(c.xz, w); colXZ = c.xz; }
                id = dmBlock(c, colInfo, w, false);
            }
            float3 n = float3(0.0);
            n[axis] = -float(stp[axis]);
            float fp = t * pxAngle / max(abs(dot(rd, n)), 0.25);

            if ((id == B_WATER || id == B_ICE || id == B_FALL) && id != prev) {
                // Translucent skins: still water and ice tinted and lit by the
                // sky; falling water from the flow animation.
                float3 P = ro + rdS * t;
                float4 tex;
                if (id == B_FALL) {
                    int fr = mcFrame(MCS_BLOCK_WATER_FLOW, MCS_BLOCK_WATER_FLOW_FRAMES, MCS_BLOCK_WATER_FLOW_TICKS, now);
                    float2 fu = dmFaceUV(P, c, axis);
                    tex = mcSkin(mcSkins, fr, fu * 16.0 + float2(8.0, 0.0), fp * 16.0);
                    tex.rgb *= K.water;
                    tex.a *= smoothstep(float(DM_FALL_LO), -2.0, P.y);
                } else {
                    tex = dmFace(id, n, dmFaceUV(P, c, axis), fp, c, w, K, mcTiles);
                }
                float3 lit = tex.rgb * mcFaceShade(n) * skyLight;
                accCol += accT * tex.a * lit;
                accT *= 1.0 - tex.a;
            }
            if (id == B_PLANT) {
                // Two crossed quads, corner to corner, cut out by alpha.
                float3 o = ro - float3(c);
                float best = 1e9;
                for (int k = 0; k < 2; ++k) {
                    float3 pn = k == 0 ? float3(0.70710678, 0.0, -0.70710678) : float3(0.70710678, 0.0, 0.70710678);
                    float pd = k == 0 ? 0.0 : 0.70710678;
                    float tp = (pd - dot(o, pn)) / dot(rdS, pn);
                    if (tp < t || tp > tNext || tp > best) continue;
                    float3 l = o + rdS * tp;
                    float4 pt = mcTile(mcTiles, colInfo.plant, float2(l.x, 1.0 - l.y), tp * pxAngle * 1.6);
                    if (pt.a > 0.5) {
                        if (colInfo.plant == MC_SHORT_GRASS) pt.rgb *= K.grass;
                        best = tp; plantTex = pt;
                    }
                }
                if (best < 1e8) { hit = true; tHit = best; hc = c; hid = B_PLANT; hn = float3(0.0, 1.0, 0.0); break; }
            }
            if (dmCutout(id)) {
                // Leaves, glass and the door stop the ray only where their
                // texture is solid.
                int layer = id >= B_LEAVES && id < B_LEAVES + 4 ? DM_LEAVES[id - B_LEAVES]
                          : (id == B_GLASS ? MC_GLASS
                          : (abs(n.z) < 0.5 ? -1 : (id == B_DOOR_HI ? MC_OAK_DOOR_TOP : MC_OAK_DOOR_BOTTOM)));
                float alpha = layer < 0 ? 1.0 : mcTile(mcTiles, layer, dmFaceUV(ro + rdS * t, c, axis), fp).a;
                if (alpha > 0.5) { hit = true; tHit = t; hc = c; hid = id; haxis = axis; hn = n; break; }
            } else if (dmOpaque(id)) {
                hit = true; tHit = t; hc = c; hid = dmBlock(c, colInfo, w, true); haxis = axis; hn = n;
                break;
            }
            prev = id;
            if (tMax.x < tMax.y && tMax.x < tMax.z) { t = tMax.x; tMax.x += tDelta.x; c.x += stp.x; axis = 0; }
            else if (tMax.y < tMax.z)               { t = tMax.y; tMax.y += tDelta.y; c.y += stp.y; axis = 1; }
            else                                    { t = tMax.z; tMax.z += tDelta.z; c.z += stp.z; axis = 2; }
            if (t > tb.y) break;
        }

        float3 surf = col;
        if (hit) {
            float3 P = ro + rdS * tHit;
            float3 n = hn;
            float3 lit;
            if (hid == B_PLANT) {
                float2 lv = dmLightLevels(hc, colInfo, w, L);
                lit = plantTex.rgb * 0.9 * dmLightmap(lv, L.day);
            } else {
                float fp = tHit * pxAngle / max(abs(dot(rd, n)), 0.25);
                float4 tex = dmFace(hid, n, dmFaceUV(P, hc, haxis), fp, hc, w, K, mcTiles);
                int3 a = hc + int3(n);
                float3 l = P - float3(hc);
                float2 aoUV = haxis == 0 ? l.zy : (haxis == 1 ? l.xz : l.xy);
                // The air cell in front shares the hit's column on a top face.
                DmCol ca = haxis == 1 ? colInfo : dmColumn(a.xz, w);
                float ao = dmAO(a, haxis, saturate(aoUV), ca, w);
                float2 lv = dmLightLevels(a, ca, w, L);
                bool glow = hid == B_LAVA || (hid == B_LAMP && L.lampOn);
                float3 lm = glow ? float3(1.0) : dmLightmap(lv, L.day);
                lit = tex.rgb * mcFaceShade(n) * (glow ? 1.0 : ao) * lm;
            }
            surf = lit;
        }
        col = accCol + accT * surf;

        // Chimney smoke: the game's campfire smoke particles, rising and fading.
        float tNear = hit ? tHit : 1e9;
        float3 top = float3(float(w.house.x) + 3.5, float(w.house.z) + 8.2, float(w.house.y) + 3.5);
        for (int i = 3; i >= 0; --i) {
            float age = fract(now * 0.08 + float(i) * 0.25);
            float k = floor(now * 0.08 + float(i) * 0.25) + float(i) * 7.0;
            float3 p = top + float3(1.4 * age + 0.3 * sin(k * 2.3), 5.5 * age, 0.8 * age + 0.3 * cos(k * 1.7));
            float tq; float2 st;
            if (dmBillboard(ro, rd, p, 0.45 + 0.5 * age, right, up, fwd, tq, st) && tq < tNear) {
                float4 sm = mcSkin(mcSkins, DM_SMOKE[min(int(age * 12.0), 11)], st * 16.0, 0.0);
                col = mix(col, sm.rgb * skyLight, sm.a * 0.85 * (1.0 - age * age));
            }
        }
    }

    col = lerpDither(col, pos);
    return half4(half3(col), 1.0h);
}
