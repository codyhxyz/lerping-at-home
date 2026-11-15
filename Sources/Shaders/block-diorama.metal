// Block Diorama — one square chunk of a block world, lifted out whole and hung
// in the dark like a museum specimen, with its own little sun going round it.
// Original work for Lerping@Home: every block, texture and building here is
// procedural and written for this file. What it borrows from the voxel
// sandbox games is the vocabulary: unit cubes, 16×16 texel faces, a cut
// chunk's cross-section.
//
// lerp-category: Blocks
//
// On top: a cottage with a lamp by its door, a few trees, a spring-fed pond
// and the stream it feeds, which runs to one cut edge and pours off it as a
// waterfall into nothing. In the cut faces: grass, dirt, stone and deep
// slate in their strata, ore seams, a tunnel or two, and a cave chamber with
// a lava floor that glows out through the side. A small block sun and moon
// circle the specimen, so the day turns over it: shadows swing, the stream
// catches the light, and at dusk the windows, the lamp and the cave come up.
// Each seed digs a different chunk, in meadow, autumn or winter.
//
// Texels are drawn sharp-bilinear against the pixel footprint: hard edges up
// close, one pixel of blend at the texel boundary, never shimmering.
//
// lerp-param: yaw      float -180 180 = 0  "Turn"
// lerp-param: pitch    float -90 90   = 0  "Tilt"
// lerp-param: magnify  float -1 1.2   = 0  "Zoom"
// lerp-param: spin     float 0 3      = 1  "Turn speed"
// lerp-param: daySpeed float 0 4      = 1  "Day speed"
// lerp-param: hour     float 0 24     = 9  "Time of day"
// lerp-param: biome    int 0 3        = 0  "Season (0 = by seed)"
//
// lerp-preset: Meadow    biome=1
// lerp-preset: Autumn    biome=2
// lerp-preset: Winter    biome=3
// lerp-preset: Evening   daySpeed=0, hour=21.5

constant float DM_FOCAL   = 2.0;
constant float DM_DIST    = 37.0;     // eye to pivot, blocks
constant float DM_DAY     = 300.0;    // seconds per day at daySpeed 1
constant float DM_SUN_R   = 23.0;     // the sun's orbit round the pivot
constant int   DM_STEPS   = 76;       // primary voxel walk
constant int   DM_SHADOW  = 36;       // shadow voxel walk
constant int   DM_FALL_LO = -12;      // where the waterfall has faded out

// Box the walk is clipped to: the chunk (x, z 0..16) plus the waterfall's
// column at x = 16 and the fall below.
constant float3 DM_BOX_LO  = float3(0.0, 0.0, 0.0);
constant float3 DM_BOX_HI  = float3(16.0, 23.0, 16.0);
constant float3 DM_FALL_BOX_LO = float3(16.0, -12.0, 0.0);
constant float3 DM_FALL_BOX_HI = float3(17.0, 9.0, 16.0);

// Block ids.
constant int B_AIR = 0, B_GRASS = 1, B_DIRT = 2, B_STONE = 3, B_DEEP = 4,
             B_BEDROCK = 5, B_SAND = 6, B_GRAVEL = 7, B_COAL = 8, B_IRON = 9,
             B_GOLD = 10, B_RED = 11, B_DIAMOND = 12, B_LAPIS = 13,
             B_GRANITE = 14, B_LOG = 15, B_BIRCH = 16, B_LEAVES = 17,
             B_PLANKS = 18, B_COBBLE = 19, B_GLASS = 20, B_ROOF = 21,
             B_DOOR_LO = 22, B_DOOR_HI = 23, B_LAMP = 24, B_WATER = 25,
             B_LAVA = 26, B_FALL = 27, B_ICE = 28, B_SPRUCE = 29, B_PATH = 30,
             B_CLAY = 31;

// ---------------------------------------------------------------------------
// The world, decided once per pixel from the seed.

struct DmWorld {
    float4 ph;         // terrain wave phases
    int    W;          // water level (top water block's y)
    float  sz, sp;     // stream centre line z = sz + 2.6 sin(0.37 x + sp)
    float2 pond;       // spring pond centre
    int3   house;      // x0, z0, floor y
    int    roof;       // roof colour
    int    biome;      // 0 meadow, 1 autumn, 2 winter
    float  ta, tap;    // tunnel along x
    float  tb, tbp;    // tunnel along z
    float3 cham;       // lava chamber centre
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
    int  trunkKind;  // 0 oak, 1 birch, 2 spruce
    uint leaves;     // bit y set: leaves at y
    int  leafKind;
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
    col.trunkTop = -100; col.trunkKind = 0; col.leaves = 0u; col.leafKind = 0;
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
    return col;
}

// Underground hollows: 1 = tunnel, 2 = the lava chamber.
static inline int dmCave(int3 c, DmCol col, thread const DmWorld& w) {
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
    int base = (y <= 3 + int(hj * 2.0)) ? B_DEEP : B_STONE;
    int3 cl = int3(floor(float3(c) * 0.5));
    float hc = dmHash3(cl, 11.0);
    if (hc < 0.15 && dmHash3(c, 12.0) < 0.62) {
        float k = hc / 0.15;
        if (k < 0.36 && y >= 4)  return B_COAL;
        if (k < 0.60 && y <= 10) return B_IRON;
        if (k < 0.70 && y <= 6)  return B_GOLD;
        if (k < 0.82 && y <= 5)  return B_RED;
        if (k < 0.90 && y <= 4)  return B_DIAMOND;
        if (k < 1.00 && y <= 7)  return B_LAPIS;
    }
    float hp = dmHash3(int3(floor(float3(c) / 3.0)), 13.0);
    if (base == B_STONE && hp < 0.10) return B_GRANITE;
    if (base == B_STONE && hp > 0.93) return B_GRAVEL;
    return base;
}

// `full` false: only whether it is air, water, falling water or solid, for the walks.
static inline int dmBlock(int3 c, DmCol col, thread const DmWorld& w, bool full) {
    int y = c.y;
    if (c.x == 16) {
        // The waterfall: one column of falling water against the +x cut face.
        if (c.z < 0 || c.z > 15 || y > w.W || y < DM_FALL_LO) return B_AIR;
        float ds = abs(float(c.z) + 0.5 - dmStreamZ(15.5, w));
        return ds < 1.25 ? B_FALL : B_AIR;
    }
    if (c.x < 0 || c.x > 15 || c.z < 0 || c.z > 15 || y < 0) return B_AIR;

    if (y <= col.h) {
        if (y == 0) return B_BEDROCK;
        if (y <= col.h - 3) {
            int cave = dmCave(c, col, w);
            if (cave == 2 && y <= 1) return B_LAVA;
            if (cave != 0 && y >= 1) return B_AIR;
        }
        if (!full) return B_STONE;
        float hb = dmHash3(c, 1.0);
        if ((y == 1 && hb < 0.55) || (y == 2 && hb < 0.18)) return B_BEDROCK;
        bool wet = col.h <= w.W;
        if (y == col.h) {
            if (col.h < w.W) return (hb < 0.3) ? B_GRAVEL : (hb < 0.55 ? B_CLAY : B_SAND);
            if (wet) return B_SAND;
            int lx = c.x - w.house.x, lz = c.z - w.house.y;
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
                    if (ex && ez) return B_LOG;
                    if (ex || ez) {
                        if (lz == 0 && lx == 2) return ly == 1 ? B_DOOR_LO : (ly == 2 ? B_DOOR_HI : B_PLANKS);
                        if (ly == 2 && ((ez && lx != 2) || (ex && lz == 2))) return B_GLASS;
                        return ly == 1 ? B_COBBLE : B_PLANKS;
                    }
                    return B_AIR;
                }
                if (ex) return B_PLANKS;
                return B_AIR;
            }
        } else if (lx == 0 && ly <= 2) {
            return ly == 1 ? B_COBBLE : B_LAMP;   // lamp on a post by the path
        }
    }

    if (y <= col.trunkTop) return col.trunkKind == 1 ? B_BIRCH : (col.trunkKind == 2 ? B_SPRUCE : B_LOG);
    if (y < 32 && ((col.leaves >> uint(y)) & 1u) != 0u) return B_LEAVES;
    return B_AIR;
}

static inline bool dmOpaque(int id) { return id != B_AIR && id != B_WATER && id != B_FALL; }

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

    // Trees, one chance per cell of a 3×3 grid, kept off the water and the plot.
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
        int kind = w.biome == 2 ? 2 : (h1 * 7.0 - floor(h1 * 7.0) < 0.3 ? 1 : 0);
        int T = (kind == 2 ? 5 : 4) + int(h2 * 7.0 - floor(h2 * 7.0) < 0.5);
        w.tree[i] = uint(tp.x) | (uint(tp.y) << 4) | (uint(g) << 8) | (uint(T) << 13) | (uint(kind) << 16) | (1u << 20);
    }
    return w;
}

// ---------------------------------------------------------------------------
// Textures: 16×16 texels a face, all procedural. `tx.y` runs down a side face.

static inline float dmH(int2 t, float s) { return hash21(float2(t) * float2(1.13, 0.97) + float2(s * 17.31, s * 5.17 + 0.5)); }
static inline float3 dmL(float r, float g, float b) { return pow(float3(r, g, b), 2.2); }

static inline int2 dmRot(int2 t, int r) {
    if (r == 1) return int2(15 - t.y, t.x);
    if (r == 2) return int2(15 - t.x, 15 - t.y);
    if (r == 3) return int2(t.y, 15 - t.x);
    return t;
}

struct DmShade {
    float  now;        // texture animation clock
    float  lights;     // 0 day .. 1 night (windows, lamp)
    int    biome;
    int    roof;
};

static float3 dmGrassTop(int2 t, float rh, int biome) {
    float h = dmH(t, 1.0);
    if (biome == 2) {
        float3 c = dmL(0.90, 0.93, 0.97) * (0.93 + 0.07 * h);
        if (h < 0.12) c = dmL(0.78, 0.84, 0.92);
        return c;
    }
    float3 dark  = biome == 1 ? dmL(0.50, 0.52, 0.22) : dmL(0.27, 0.46, 0.16);
    float3 mid   = biome == 1 ? dmL(0.62, 0.62, 0.27) : dmL(0.36, 0.57, 0.21);
    float3 light = biome == 1 ? dmL(0.72, 0.66, 0.30) : dmL(0.46, 0.67, 0.27);
    float3 c = h < 0.3 ? dark : (h > 0.82 ? light : mid);
    if (rh < 0.16 && biome == 0) {
        // A flower, on one block in six.
        int2 f = int2(3 + int(rh * 61.0) % 9, 3 + int(rh * 113.0) % 9);
        int2 d = abs(t - f);
        float pick = fract(rh * 37.0);
        float3 petal = pick < 0.33 ? dmL(0.85, 0.2, 0.18) : (pick < 0.66 ? dmL(0.95, 0.85, 0.3) : dmL(0.55, 0.6, 0.95));
        if (d.x + d.y == 0) c = dmL(0.98, 0.85, 0.35);
        else if (d.x + d.y == 1) c = petal;
    }
    return c;
}

static float3 dmDirt(int2 t) {
    float h = dmH(t, 2.0);
    float3 c = dmL(0.53, 0.38, 0.26);
    if (h < 0.25) c *= 0.74;
    else if (h > 0.86) c *= 1.18;
    if (h > 0.975) c = dmL(0.55, 0.53, 0.5);
    return c;
}

static float3 dmStone(int2 t, float3 base, float s) {
    float h = dmH(t, s);
    float st = dmH(int2(t.x / 3, t.y / 2), s + 1.0);
    float v = 0.76 + 0.2 * h + 0.16 * st;
    if (h < 0.1) v = 0.62;
    else if (h > 0.94) v = 1.12;
    return base * v;
}

static float3 dmOre(int2 t, float3 ore, float rh) {
    float3 c = dmStone(t, dmL(0.52, 0.52, 0.53), 3.0);
    float blob = dmH(int2(t.x / 3, t.y / 3), 9.0 + floor(rh * 4.0));
    if (blob < 0.4 && dmH(t, 10.0) < 0.72 && t.x > 0 && t.y > 0 && t.x < 15 && t.y < 15)
        c = ore * (0.75 + 0.45 * dmH(t, 11.0));
    return c;
}

static float3 dmTex(int id, int2 t, int face, float rh, DmShade S, thread float3& emit) {
    emit = float3(0.0);
    int rot = int(rh * 4.0) & 3;
    switch (id) {
    case B_GRASS:
        if (face == 0) return dmGrassTop(dmRot(t, rot), rh, S.biome);
        if (face == 1) {
            int fringe = 2 + int(dmH(int2(t.x, 0), 4.0) * 2.5);
            if (t.y < fringe) return S.biome == 2 ? dmL(0.9, 0.93, 0.97) * (0.94 + 0.06 * dmH(t, 5.0))
                                                  : dmGrassTop(t, 1.0, S.biome);
        }
        return dmDirt(t);
    case B_DIRT:    return dmDirt(dmRot(t, rot));
    case B_PATH:
        if (face == 0) return dmL(0.62, 0.5, 0.32) * (0.86 + 0.18 * dmH(dmRot(t, rot), 6.0));
        if (t.y < 1) return dmL(0.62, 0.5, 0.32);
        return dmDirt(t);
    case B_STONE:   return dmStone(dmRot(t, rot), dmL(0.52, 0.52, 0.53), 3.0);
    case B_DEEP: {
        float h = dmH(int2(t.x / 4 + (t.y & 1) * 7, t.y), 7.0);
        return dmL(0.30, 0.30, 0.34) * (0.78 + 0.36 * h);
    }
    case B_BEDROCK: {
        float h = dmH(t, 8.0) * 0.5 + dmH(t / 2, 8.5) * 0.5;
        return dmL(0.42, 0.42, 0.43) * (h < 0.35 ? 0.35 : (h < 0.7 ? 0.75 : 1.25));
    }
    case B_SAND:    return dmL(0.86, 0.79, 0.57) * (0.9 + 0.12 * dmH(dmRot(t, rot), 9.0));
    case B_CLAY:    return dmL(0.62, 0.64, 0.70) * (0.9 + 0.1 * dmH(t, 9.5));
    case B_GRAVEL: {
        float h = dmH(int2(t.x / 2, t.y / 2) + int2(t.y / 4, 0), 12.0);
        float3 c = h < 0.33 ? dmL(0.56, 0.52, 0.5) : (h < 0.66 ? dmL(0.42, 0.4, 0.39) : dmL(0.64, 0.57, 0.52));
        return c * (dmH(t, 13.0) < 0.15 ? 0.7 : 1.0);
    }
    case B_COAL:    return dmOre(t, dmL(0.12, 0.12, 0.13), rh);
    case B_IRON:    return dmOre(t, dmL(0.85, 0.66, 0.52), rh);
    case B_GOLD:    return dmOre(t, dmL(0.98, 0.84, 0.28), rh);
    case B_DIAMOND: return dmOre(t, dmL(0.45, 0.93, 0.9), rh);
    case B_LAPIS:   return dmOre(t, dmL(0.18, 0.3, 0.75), rh);
    case B_RED: {
        float3 c = dmOre(t, dmL(0.9, 0.12, 0.08), rh);
        if (c.r > 0.3 && c.g < 0.1) emit = c * 0.25;
        return c;
    }
    case B_GRANITE: {
        float h = dmH(t, 14.0);
        return dmL(0.62, 0.44, 0.38) * (h < 0.2 ? 0.75 : (h > 0.85 ? 1.2 : 0.95));
    }
    case B_LOG: case B_SPRUCE: {
        bool spruce = id == B_SPRUCE;
        if (face != 1) {
            int2 d = abs(t * 2 - 15);
            int ring = max(d.x, d.y) / 2;
            if (ring >= 7) return spruce ? dmL(0.25, 0.18, 0.12) : dmL(0.4, 0.3, 0.19);
            return (ring & 1) ? dmL(0.72, 0.57, 0.36) : dmL(0.62, 0.48, 0.3);
        }
        float groove = dmH(int2(t.x, t.y / 4 + t.x), 15.0);
        float3 bark = spruce ? dmL(0.3, 0.21, 0.14) : dmL(0.43, 0.32, 0.2);
        return bark * (groove < 0.3 ? 0.62 : 0.85 + 0.3 * dmH(t, 16.0));
    }
    case B_BIRCH: {
        if (face != 1) {
            int2 d = abs(t * 2 - 15);
            int ring = max(d.x, d.y) / 2;
            if (ring >= 7) return dmL(0.84, 0.83, 0.78);
            return (ring & 1) ? dmL(0.82, 0.72, 0.52) : dmL(0.74, 0.64, 0.45);
        }
        float m = dmH(int2(t.x / 3, t.y), 17.0);
        return m < 0.13 ? dmL(0.18, 0.17, 0.16) : dmL(0.86, 0.85, 0.8) * (0.92 + 0.08 * dmH(t, 18.0));
    }
    case B_LEAVES: {
        int2 tr = dmRot(t, rot);
        float h = dmH(tr, 19.0);
        float3 c;
        if (S.biome == 2) {
            c = dmL(0.16, 0.32, 0.22);
            if (face == 0 && dmH(tr, 20.0) < 0.7) return dmL(0.9, 0.93, 0.97) * (0.92 + 0.08 * h);
        } else if (S.biome == 1) {
            float pick = fract(rh * 3.7);
            c = pick < 0.4 ? dmL(0.85, 0.42, 0.12) : (pick < 0.75 ? dmL(0.78, 0.22, 0.1) : dmL(0.9, 0.7, 0.2));
        } else {
            c = rh > 0.75 ? dmL(0.42, 0.58, 0.24) : dmL(0.24, 0.48, 0.16);
        }
        if (h < 0.2) c *= 0.42;
        else if (h > 0.84) c *= 1.25;
        return c;
    }
    case B_PLANKS: {
        int row = t.y / 4;
        if ((t.y & 3) == 3) return dmL(0.36, 0.26, 0.15);
        if (t.x == (row * 5 + 3) % 16) return dmL(0.42, 0.3, 0.18);
        float g = dmH(int2(t.x / 4, t.y), 21.0 + float(row));
        return dmL(0.69, 0.53, 0.33) * (0.88 + 0.16 * g);
    }
    case B_COBBLE: {
        int sh = ((t.y / 4) & 1) * 2;
        int2 cell = int2((t.x + sh) / 4, t.y / 4);
        int lx = (t.x + sh) & 3, ly = t.y & 3;
        if ((lx == 0 || ly == 0) && dmH(t, 22.0) > 0.15) return dmL(0.27, 0.27, 0.28);
        float h = dmH(cell, 23.0);
        return dmL(0.5, 0.5, 0.5) * (0.82 + 0.3 * h) * (0.94 + 0.1 * dmH(t, 24.0));
    }
    case B_GLASS: {
        if (face != 1) return dmL(0.36, 0.25, 0.15);
        bool frame = t.x == 0 || t.x == 15 || t.y == 0 || t.y == 15 || t.x == 7 || t.x == 8 || t.y == 7 || t.y == 8;
        if (frame) return dmL(0.36, 0.25, 0.15);
        int2 p = t & 7;
        float3 day = (p.x + p.y == 6 || p.x + p.y == 7) ? dmL(0.5, 0.58, 0.62) : dmL(0.13, 0.17, 0.22);
        float3 warm = dmL(1.0, 0.72, 0.4) * (0.82 + 0.18 * dmH(t / 2, 25.0));
        if (t.y > 9 && t.x > 10 && t.x < 14) warm *= 0.55;   // something on the sill
        emit = warm * 2.2 * S.lights;
        return mix(day, warm * 0.3, S.lights);
    }
    case B_ROOF: {
        int row = t.y / 4;
        float3 base = S.roof == 0 ? dmL(0.55, 0.24, 0.18) : (S.roof == 1 ? dmL(0.3, 0.32, 0.38) : dmL(0.36, 0.42, 0.28));
        if (face == 0 && S.biome == 2) return dmL(0.9, 0.93, 0.97) * (0.94 + 0.06 * dmH(t, 26.0));
        if ((t.y & 3) == 3) return base * 0.55;
        if (((t.x + row * 3) & 7) == 0) return base * 0.65;
        return base * (0.8 + 0.07 * float(t.y & 3)) * (0.92 + 0.14 * dmH(int2((t.x + row * 3) / 8, row), 27.0));
    }
    case B_DOOR_LO: case B_DOOR_HI: {
        if (face != 1) return dmL(0.45, 0.32, 0.19);
        bool hi = id == B_DOOR_HI;
        float3 wood = dmL(0.47, 0.33, 0.19) * (0.86 + 0.16 * dmH(int2(t.x / 3, 0), 28.0));
        if (t.x == 0 || t.x == 15 || (!hi && t.y == 15) || (hi && t.y == 0)) return wood * 0.6;
        if (hi && t.y >= 3 && t.y <= 9 && t.x >= 3 && t.x <= 12 && t.x != 7 && t.x != 8 && t.y != 6) {
            float3 warm = dmL(1.0, 0.72, 0.4);
            emit = warm * 1.6 * S.lights;
            return mix(dmL(0.13, 0.17, 0.22), warm * 0.3, S.lights);
        }
        if (!hi && t.x == 12 && (t.y == 1 || t.y == 2)) return dmL(0.75, 0.7, 0.55);
        if ((t.x & 3) == 3) return wood * 0.75;
        return wood;
    }
    case B_LAMP: {
        int2 d = abs(t * 2 - 15);
        bool frame = max(d.x, d.y) >= 13 || t.x == 7 || t.x == 8 || (face == 1 && (t.y == 7 || t.y == 8));
        if (frame) return dmL(0.16, 0.15, 0.15);
        float3 glow = dmL(1.0, 0.8, 0.45) * (0.85 + 0.15 * dmH(t, 29.0));
        emit = glow * (0.15 + 3.0 * S.lights);
        return glow * 0.6;
    }
    case B_WATER: {
        int fr = int(floor(S.now * 3.0));
        float h = dmH(int2(t.x, (t.y + fr) & 15), 30.0);
        float rip = ((t.x / 3 + t.y + fr) % 7 == 0) ? 1.25 : 1.0;
        return dmL(0.2, 0.36, 0.72) * (0.85 + 0.2 * h) * rip;
    }
    case B_ICE: {
        float h = dmH(t, 31.0);
        bool crack = (t.x + t.y * 3) % 11 == 0 || (t.x * 2 - t.y) % 13 == 0;
        return dmL(0.62, 0.76, 0.92) * (crack ? 1.15 : 0.9 + 0.1 * h);
    }
    case B_LAVA: {
        float2 q = float2(t) / 4.0 + float2(S.now * 0.18, S.now * 0.11) + rh * 9.0;
        float n = valueNoise(q) * 0.65 + valueNoise(q * 2.1 + 3.0) * 0.35;
        n = floor(n * 6.0) / 5.0;
        float3 c = mix(dmL(0.6, 0.1, 0.02), dmL(0.98, 0.45, 0.06), saturate(n * 1.5));
        c = mix(c, dmL(1.0, 0.86, 0.35), saturate(n * 2.0 - 1.1));
        emit = c * 2.4;
        return c * 0.4;
    }
    case B_FALL: {
        int fr = int(floor(S.now * 26.0));
        float col = dmH(int2(t.x, 0), 32.0);
        float sk = dmH(int2(t.x, ((t.y - fr) >> 2) & 1023), 33.0);
        float3 c = dmL(0.24, 0.42, 0.8) * (0.8 + 0.3 * col);
        if (sk > 0.72) c = dmL(0.62, 0.78, 0.98);
        return c;
    }
    }
    return float3(1.0, 0.0, 1.0);
}

// The block's average, which the texels fade to when they shrink below a pixel.
static float3 dmMean(int id, int face, float rh, DmShade S, thread float3& emit) {
    float3 c = float3(0.0), e = float3(0.0), ee;
    const int2 taps[4] = { int2(3, 4), int2(11, 2), int2(5, 12), int2(13, 10) };
    for (int i = 0; i < 4; ++i) { c += dmTex(id, taps[i], face, rh, S, ee); e += ee; }
    emit = e * 0.25;
    return c * 0.25;
}

// Sharp-bilinear: within a texel the colour is flat; across a texel edge it
// blends over one pixel's footprint, and when texels shrink past a pixel the
// face settles to its mean.
static float3 dmSample(int id, float2 uv, int face, float rh, float fwT, DmShade S, thread float3& emit) {
    float2 x = uv * 16.0 - 0.5;
    float2 i = floor(x), f = x - i;
    float2 k = saturate((f - 0.5) / max(fwT, 0.02) + 0.5);
    int2 a = clamp(int2(i), 0, 15), b = clamp(int2(i) + 1, 0, 15);
    float3 e00, e10, e01, e11;
    float3 c00 = dmTex(id, int2(a.x, a.y), face, rh, S, e00);
    float3 c10 = dmTex(id, int2(b.x, a.y), face, rh, S, e10);
    float3 c01 = dmTex(id, int2(a.x, b.y), face, rh, S, e01);
    float3 c11 = dmTex(id, int2(b.x, b.y), face, rh, S, e11);
    float3 c = mix(mix(c00, c10, k.x), mix(c01, c11, k.x), k.y);
    emit = mix(mix(e00, e10, k.x), mix(e01, e11, k.x), k.y);
    float far = smoothstep(1.2, 3.5, fwT);
    if (far > 0.0) {
        float3 em;
        float3 m = dmMean(id, face, rh, S, em);
        c = mix(c, m, far);
        emit = mix(emit, em, far);
    }
    return c;
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

// 1 if the light reaches ro along rd, 0 if a block is in the way.
static float dmShadow(float3 ro, float3 rd, thread const DmWorld& w) {
    rd = dmSafeDir(rd);
    float3 inv = 1.0 / rd;
    float2 tb = dmBox(ro, inv, float3(0.0, 0.0, 0.0), float3(16.0, 23.0, 16.0));
    if (tb.y <= max(tb.x, 0.0)) return 1.0;
    float t = max(tb.x, 0.0);
    int3 c = int3(floor(ro + rd * (t + 1e-4)));
    int3 stp = int3(sign(rd));
    float3 tMax = (float3(c) + select(float3(0.0), float3(1.0), rd > 0.0) - ro) * inv;
    float3 tDelta = abs(inv);
    int2 colXZ = int2(-999);
    DmCol col;
    for (int i = 0; i < DM_SHADOW; ++i) {
        if (any(c.xz != colXZ)) { col = dmColumn(c.xz, w); colXZ = c.xz; }
        if (dmOpaque(dmBlock(c, col, w, false))) return 0.0;
        if (tMax.x < tMax.y && tMax.x < tMax.z) { t = tMax.x; tMax.x += tDelta.x; c.x += stp.x; }
        else if (tMax.y < tMax.z)               { t = tMax.y; tMax.y += tDelta.y; c.y += stp.y; }
        else                                    { t = tMax.z; tMax.z += tDelta.z; c.z += stp.z; }
        if (t > tb.y) return 1.0;
    }
    return 1.0;
}

// Per-corner occlusion of a face, from the eight blocks around the air cell
// in front of it, blended across the face.
static float dmAO(int3 a, int axis, float2 uv, thread const DmWorld& w) {
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
            DmCol cc = dmColumn(b.xz, w);
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
    float4 v = 1.0 - occ * 0.22;
    return mix(mix(v.x, v.y, uv.x), mix(v.z, v.w, uv.x), uv.y);
}

struct DmLight {
    float3 sunPos, moonPos;
    float3 sunCol, moonCol;
    float  sunI, moonI;
    float3 amb;          // sky light from above
    float  lights;
    float3 lampPos, homePos, lavaPos;
};

static float3 dmBackground(float3 rd, float2 uv, DmLight Lt) {
    float day = Lt.sunI;
    float3 lo = mix(float3(0.004, 0.005, 0.010), float3(0.030, 0.040, 0.058), day);
    float3 hi = mix(float3(0.010, 0.013, 0.028), float3(0.060, 0.080, 0.115), day);
    float3 c = mix(lo, hi, saturate(rd.y * 0.8 + 0.5));
    // A soft pool of light behind the specimen, falling off to the corners.
    c += mix(float3(0.008, 0.010, 0.020), float3(0.035, 0.040, 0.050), day) * exp(-dot(uv, uv) * 1.4);
    c *= 1.0 - 0.1 * dot(uv, uv);
    // Dusk warms the side of the sky the sun is on.
    float3 sd = normalize(Lt.sunPos - float3(8.5, 7.0, 8.0));
    float dusk = saturate(1.0 - abs(sd.y) * 3.0);
    c += float3(0.09, 0.035, 0.015) * dusk * pow(saturate(dot(rd, sd) * 0.5 + 0.5), 3.0);
    // Stars, fading in as the light goes.
    float3 sc = rd * 170.0;
    float3 cell = floor(sc);
    float hs = hash21(cell.xy * 0.37 + cell.z * 1.71);
    float3 f = sc - cell - 0.5;
    float star = step(0.985, hs) * smoothstep(0.32, 0.0, length(f));
    c += float3(0.7, 0.75, 0.9) * star * (1.0 - day) * (0.4 + 0.6 * fract(hs * 91.0));
    return c;
}

// The sun and moon: small glowing blocks on the specimen's orbit.
static bool dmOrb(float3 ro, float3 rd, float3 cen, float hsz, float spin, thread float& tHit,
                  thread float3& nrm, thread float2& fuv) {
    float c = cos(spin), s = sin(spin);
    float3 o = ro - cen;
    float3 lo = float3(c * o.x - s * o.z, o.y, s * o.x + c * o.z);
    float3 ld = float3(c * rd.x - s * rd.z, rd.y, s * rd.x + c * rd.z);
    float3 inv = 1.0 / dmSafeDir(ld);
    float2 tb = dmBox(lo, inv, float3(-hsz), float3(hsz));
    if (tb.y < max(tb.x, 0.0) || tb.x < 0.0) return false;
    tHit = tb.x;
    float3 p = (lo + ld * tb.x) / hsz;
    float3 ap = abs(p);
    if (ap.x > ap.y && ap.x > ap.z) { nrm = float3(sign(p.x), 0, 0); fuv = p.zy; }
    else if (ap.y > ap.z)           { nrm = float3(0, sign(p.y), 0); fuv = p.xz; }
    else                            { nrm = float3(0, 0, sign(p.z)); fuv = p.xy; }
    fuv = fuv * 0.5 + 0.5;
    return true;
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
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

    // --- The day: the sun's orbit is tilted, so noon is high but not overhead.
    float phase = u.hour / 24.0 + u.daySpeed * (now + u.seed * DM_DAY) / DM_DAY;
    float th = TWO_PI * phase - 0.5 * PI;
    float3 dh = normalize(float3(1.0, 0.0, 0.45));
    float3 dv = normalize(float3(0.0, 1.0, 0.0) + 0.35 * cross(dh, float3(0.0, 1.0, 0.0)));
    float3 sunOff = DM_SUN_R * (cos(th) * dh + sin(th) * dv);
    DmLight Lt;
    Lt.sunPos = pivot + sunOff;
    Lt.moonPos = pivot - sunOff;
    float sy = sunOff.y / DM_SUN_R;
    Lt.sunI = smoothstep(-0.28, 0.12, sy);
    Lt.moonI = smoothstep(-0.05, -0.35, sy);
    float lowSun = 1.0 - smoothstep(0.05, 0.5, sy);
    Lt.sunCol = mix(float3(1.0, 0.93, 0.82) * 2.4, float3(1.0, 0.52, 0.26) * 2.0, lowSun);
    Lt.moonCol = float3(0.32, 0.42, 0.66) * 0.75;
    Lt.amb = mix(float3(0.05, 0.066, 0.115), float3(0.30, 0.37, 0.48), Lt.sunI);
    Lt.amb = mix(Lt.amb, float3(0.32, 0.26, 0.26), 0.4 * lowSun * Lt.sunI);
    Lt.lights = 1.0 - smoothstep(-0.12, 0.22, sy);

    float3 bg = dmBackground(rd, uv, Lt);

    // --- Sun and moon.
    float tOrb = 1e9; float3 orbCol = float3(0.0);
    {
        float th1; float3 n1; float2 f1;
        if (dmOrb(ro, rd, Lt.sunPos, 1.1, now * 0.21, th1, n1, f1)) {
            int2 tt = int2(clamp(f1 * 8.0, 0.0, 7.99));
            int2 d = abs(tt * 2 - 7);
            float ring = float(max(d.x, d.y));
            tOrb = th1;
            orbCol = mix(float3(1.0, 0.95, 0.7) * 5.0, float3(1.0, 0.62, 0.2) * 3.0, saturate((ring - 3.0) / 4.0));
        }
        if (dmOrb(ro, rd, Lt.moonPos, 0.85, now * 0.17 + 1.0, th1, n1, f1) && th1 < tOrb) {
            int2 tt = int2(clamp(f1 * 8.0, 0.0, 7.99));
            float cr = hash21(float2(tt) + n1.xy * 3.0 + n1.z * 7.0);
            tOrb = th1;
            orbCol = float3(0.78, 0.8, 0.88) * (cr < 0.25 ? 0.75 : 1.3);
        }
    }

    // --- The voxel walk.
    float3 rdS = dmSafeDir(rd);
    float3 inv = 1.0 / rdS;
    // Two boxes: the chunk, and the waterfall's column beside and below it.
    // Only rays that reach one of them need the world built.
    float2 tbM = dmBox(ro, inv, DM_BOX_LO, DM_BOX_HI);
    float2 tbF = dmBox(ro, inv, DM_FALL_BOX_LO, DM_FALL_BOX_HI);
    bool inM = tbM.y > max(tbM.x, 0.0), inF = tbF.y > max(tbF.x, 0.0);
    bool inBox = inM || inF;
    float2 tb = float2(min(inM ? tbM.x : 1e9, inF ? tbF.x : 1e9), max(inM ? tbM.y : -1e9, inF ? tbF.y : -1e9));
    DmWorld w;
    if (inBox) w = dmMakeWorld(u.seed, u.biome);
    Lt.lampPos = float3(float(w.house.x) + 0.5, float(w.house.z) + 2.5, float(w.house.y) - 1.5);
    Lt.homePos = float3(float(w.house.x) + 2.5, float(w.house.z) + 2.5, float(w.house.y) + 2.5);
    Lt.lavaPos = float3(w.cham.x, 2.3, w.cham.z);

    DmShade S;
    S.now = now; S.lights = Lt.lights; S.biome = w.biome; S.roof = w.roof;
    float3 accCol = float3(0.0);
    float3 accT = float3(1.0);
    float3 col;
    bool hit = false;
    float tHit = 1e9;
    int3 hc = int3(0); int hid = 0; int haxis = 1;
    float3 hn = float3(0.0, 1.0, 0.0);
    if (inBox) {
        float t = max(tb.x, 0.0);
        float3 boxLo = (inM && tbM.x <= tb.x) ? DM_BOX_LO : DM_FALL_BOX_LO;
        float3 boxHi = (inM && tbM.x <= tb.x) ? DM_BOX_HI : DM_FALL_BOX_HI;
        int3 c = clamp(int3(floor(ro + rdS * (t + 1e-4))), int3(boxLo), int3(boxHi) - 1);
        int3 stp = int3(sign(rdS));
        float3 tMax = (float3(c) + select(float3(0.0), float3(1.0), rdS > 0.0) - ro) * inv;
        float3 tDelta = abs(inv);
        // Which face the walk entered through.
        float3 ta = (boxLo - ro) * inv, tbb = (boxHi - ro) * inv;
        float3 tn = min(ta, tbb);
        int axis = (tn.x > tn.y && tn.x > tn.z) ? 0 : (tn.y > tn.z ? 1 : 2);
        int2 colXZ = int2(-999);
        DmCol colInfo;
        int prev = B_AIR;
        float tWater = 0.0;
        for (int i = 0; i < DM_STEPS; ++i) {
            int id;
            if (c.x > 15 || c.y < 0) {
                // Beside or below the chunk only the waterfall exists.
                float ds = abs(float(c.z) + 0.5 - dmStreamZ(15.5, w));
                id = (c.x == 16 && c.y <= w.W && ds < 1.25) ? B_FALL : B_AIR;
            } else {
                if (any(c.xz != colXZ)) { colInfo = dmColumn(c.xz, w); colXZ = c.xz; }
                id = dmBlock(c, colInfo, w, false);
            }
            float3 n = float3(0.0);
            n[axis] = -float(stp[axis]);
            if (id == B_WATER && prev != B_WATER) {
                // The water's skin: its own texels, half see-through.
                float3 P = ro + rdS * t;
                float2 fu = axis == 0 ? P.zy : (axis == 1 ? P.xz : P.xy);
                fu = fract(fu);
                float3 e;
                float fw = t * pxAngle / max(abs(dot(rd, n)), 0.2);
                float3 alb = dmSample(B_WATER, fu, axis == 1 ? 0 : 1, 0.0, fw * 16.0, S, e);
                float3 L = normalize(Lt.sunPos - P);
                float3 hv = normalize(L - rd);
                float spec = pow(saturate(dot(n, hv)), 60.0) * Lt.sunI;
                float3 lit = alb * (Lt.amb * 1.3 + Lt.sunCol * Lt.sunI * saturate(dot(n, L)) * 0.6) + spec * Lt.sunCol * 0.7;
                lit += alb * Lt.lights * 0.9 * float3(1.0, 0.7, 0.4) / (1.0 + 0.4 * length_squared(P - Lt.lampPos));
                accCol += accT * 0.55 * lit;
                accT *= 0.45;
                tWater = t;
            }
            if (prev == B_WATER && id != B_WATER) {
                float d = t - tWater;
                float3 ext = exp(-d * float3(0.55, 0.22, 0.14));
                accCol += accT * (1.0 - ext) * float3(0.02, 0.05, 0.09) * (0.3 + Lt.sunI);
                accT *= ext;
            }
            if (id == B_FALL && prev != B_FALL) {
                float3 P = ro + rdS * t;
                float2 fu = fract(axis == 0 ? P.zy : (axis == 1 ? P.xz : P.xy));
                if (axis == 0 || axis == 2) fu.y = 1.0 - fu.y;
                float3 e;
                float fw = t * pxAngle / max(abs(dot(rd, n)), 0.2);
                float3 alb = dmSample(B_FALL, fu, 1, 0.0, fw * 16.0, S, e);
                float fade = smoothstep(float(DM_FALL_LO) + 2.0, 1.0, P.y); fade *= fade;
                float a = 0.78 * fade;
                float3 lit = alb * (Lt.amb * 1.4 + Lt.sunCol * Lt.sunI * 0.35 + 0.06);
                accCol += accT * a * lit;
                accT *= 1.0 - a;
            }
            if (dmOpaque(id)) {
                hit = true; tHit = t; hc = c; hid = dmBlock(c, colInfo, w, true); haxis = axis; hn = n;
                if (prev == B_WATER) {
                    float d = t - tWater;
                    float3 ext = exp(-d * float3(0.55, 0.22, 0.14));
                    accCol += accT * (1.0 - ext) * float3(0.02, 0.05, 0.09) * (0.3 + Lt.sunI);
                    accT *= ext;
                }
                break;
            }
            prev = id;
            if (tMax.x < tMax.y && tMax.x < tMax.z) { t = tMax.x; tMax.x += tDelta.x; c.x += stp.x; axis = 0; }
            else if (tMax.y < tMax.z)               { t = tMax.y; tMax.y += tDelta.y; c.y += stp.y; axis = 1; }
            else                                    { t = tMax.z; tMax.z += tDelta.z; c.z += stp.z; axis = 2; }
            if (t > tb.y) break;
        }
    }

    if (hit && tHit < tOrb) {
        float3 P = ro + rdS * tHit;
        float3 n = hn;
        float2 fu;
        if (haxis == 0)      fu = float2(P.z - float(hc.z), 1.0 - (P.y - float(hc.y)));
        else if (haxis == 1) fu = float2(P.x - float(hc.x), P.z - float(hc.z));
        else                 fu = float2(P.x - float(hc.x), 1.0 - (P.y - float(hc.y)));
        fu = saturate(fu);
        int face = haxis == 1 ? (n.y > 0.0 ? 0 : 2) : 1;
        float rh = dmHash3(hc, 5.0);
        float fw = tHit * pxAngle / max(abs(dot(rd, n)), 0.2);
        float3 emit;
        float3 alb = dmSample(hid, fu, face, rh, fw * 16.0, S, emit);

        // Occlusion, and how much sky the air in front of this face can see.
        int3 a = hc + int3(n);
        float2 aoUV = haxis == 0 ? float2(P.z - float(hc.z), P.y - float(hc.y))
                    : (haxis == 1 ? float2(P.x - float(hc.x), P.z - float(hc.z))
                                  : float2(P.x - float(hc.x), P.y - float(hc.y)));
        float ao = dmAO(a, haxis, saturate(aoUV), w);
        float sky = 1.0;
        bool inside = a.x >= 0 && a.x <= 15 && a.z >= 0 && a.z <= 15;
        if (inside && a.y <= dmGround(a.xz, w)) {
            float edge = min(min(float(a.x) + 0.5, 15.5 - float(a.x)), min(float(a.z) + 0.5, 15.5 - float(a.z)));
            sky = exp(-0.55 * edge);
        }

        float3 L = normalize(Lt.sunPos - P);
        float3 Lm = normalize(Lt.moonPos - P);
        bool sunKey = Lt.sunI >= Lt.moonI;
        float3 Lk = sunKey ? L : Lm;
        float ndk = dot(n, Lk);
        float shadow = ndk > 0.0 ? dmShadow(P + n * 2e-3, Lk, w) : 0.0;
        float3 direct = Lt.sunCol * Lt.sunI * saturate(dot(n, L)) * (sunKey ? shadow : 0.3 * sky)
                      + Lt.moonCol * Lt.moonI * saturate(dot(n, Lm)) * (sunKey ? 0.3 * sky : shadow);
        float3 ambient = Lt.amb * (0.62 + 0.38 * n.y) * ao * sky;
        // A soft display light from the viewer's side, so the cut faces still
        // read at midnight.
        ambient += float3(0.035, 0.038, 0.05) * (0.35 + 0.65 * saturate(dot(n, -rd))) * ao;

        // Local lights: the lamp, the windows, the lava.
        float3 local = float3(0.0);
        {
            float3 d = Lt.lampPos - P; float dd = dot(d, d);
            local += float3(1.0, 0.68, 0.36) * 2.6 * Lt.lights * saturate(dot(n, d * rsqrt(dd)) * 0.8 + 0.2) / (1.0 + 0.45 * dd);
            d = Lt.homePos - P; dd = dot(d, d);
            local += float3(1.0, 0.62, 0.3) * 1.4 * Lt.lights * saturate(dot(n, d * rsqrt(dd))) / (1.0 + 0.12 * dd * dd * 0.1);
            d = Lt.lavaPos - P; dd = dot(d, d);
            local += float3(1.0, 0.36, 0.08) * 3.5 * saturate(dot(n, d * rsqrt(dd)) * 0.7 + 0.3) / (1.0 + 0.35 * dd);
        }
        col = alb * (direct + ambient * 1.0 + local * ao) + emit;
        col = accCol + accT * col;
    } else if (tOrb < 1e8) {
        col = orbCol;
    } else {
        col = accCol + accT * bg;
    }

    // Chimney smoke: little grey cubes that rise, drift, grow and thin out.
    if (inBox) {
        float3 top = float3(float(w.house.x) + 3.5, float(w.house.z) + 8.0, float(w.house.y) + 3.5);
        float3 puffLit = float3(0.5, 0.5, 0.53) * (Lt.amb * 1.1 + Lt.sunCol * Lt.sunI * 0.45 + Lt.moonCol * Lt.moonI * 0.3)
                       + float3(0.05, 0.03, 0.02) * Lt.lights;
        float tNear = (hit && tHit < tOrb) ? tHit : tOrb;
        for (int i = 3; i >= 0; --i) {
            float a = fract(now * 0.09 + float(i) * 0.25);
            float k = floor(now * 0.09 + float(i) * 0.25) + float(i) * 7.0;
            float3 p = top + float3(1.6 * a + 0.3 * sin(k * 2.3), 5.0 * a, 0.9 * a + 0.3 * cos(k * 1.7));
            float sz = 0.16 + 0.32 * a;
            float2 pt = dmBox(ro, inv, p - sz, p + sz);
            if (pt.y > max(pt.x, 0.0) && pt.x < tNear) {
                float alpha = 0.75 * smoothstep(0.0, 0.08, a) * (1.0 - a);
                col = mix(col, puffLit, alpha);
            }
        }
    }

    // Halos round the sun and moon.
    {
        float tc = dot(Lt.sunPos - ro, rd);
        float d2 = length_squared(ro + rd * tc - Lt.sunPos);
        if (tc > 0.0 && (tc < tHit || !hit)) col += float3(1.0, 0.7, 0.35) * 0.9 / (1.0 + d2 * 0.9) * (0.4 + 0.6 * Lt.sunI);
        tc = dot(Lt.moonPos - ro, rd);
        d2 = length_squared(ro + rd * tc - Lt.moonPos);
        if (tc > 0.0 && (tc < tHit || !hit)) col += float3(0.5, 0.6, 0.9) * 0.18 / (1.0 + d2 * 1.2);
    }

    // Filmic shoulder, then display gamma.
    col = 1.0 - exp(-col * 1.15);
    col = pow(max(col, 0.0), 1.0 / 2.2);
    col = lerpDither(col, pos);
    return half4(half3(col), 1.0h);
}
