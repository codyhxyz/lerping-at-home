// Village Timelapse — a village on a small island in the ocean, forever being
// built, in the game's own blocks. For Lerping@Home; every surface is a real
// block drawn with the game's textures, and everyone in it one of the game's
// mobs (`lerp-requires: minecraft mobs`).
//
// lerp-category: Living Worlds
// lerp-requires: minecraft mobs
// lerp-data: clock
//
// The island is a three-by-three grid of plots between dirt paths, with an
// oak fence and lantern at each inner crossroads. Each plot runs its own
// cycle: a village house (cobblestone footing, log corners, plank walls,
// glass windows, a door, a stair roof, a torch inside), a stone-brick tower,
// a wheat farm or a tree goes up one block at a time — course by course, the
// work going round each course and turning back on the next — then
// stands (the wheat ripening through its eight stages), then is mined out
// from the top down through the ten breaking stages, and something new is
// started in its place. The nine plots are staggered, so the village is
// always mostly standing and always somewhere under construction. The block
// being worked carries the game's thin black selection outline. The
// villagers live on the roads, which nothing is ever built on: two walk
// round the middle plot, and each road out from it belongs to one
// inhabitant who wanders it end to end, stopping to look about — villagers
// at their trades, two children running, an iron golem and a stray cat, all
// the game's mobs on its own models. Lanterns, torches and wheat are the
// kit's models, and light is the kit's lightmap.
//
// Purity: nothing is remembered. Which block exists at time t is decided by
// comparing that block's place in the build order — a function of its
// position — with how far the plot's cycle has run. A plot's design is a hash
// of (plot, cycle, seed).
//
// Light follows the game: fixed per-face shading, smooth-lighting corner
// occlusion, sky light dimmed under cover and by depth of water, torch and
// lantern light falling a level a block, the sky darkening the sky light at
// dusk, sky and fog colours with the sunset glow toward the sun, the sun and
// moon textures, and the flat cloud layer from clouds.png.
//
// The sky keeps the Mac's hours (the clock provider): the sun rises at
// today's sunrise, is highest at midday and sets at today's sunset, and the
// lanterns and torches carry the village through the night under the moon.
// The building runs at timelapse speed under a real-time sky. `clock` pins
// the hour on an equinox day; stills are midnight, as the provider gives.
// Golden Hour is the low late-afternoon sun this look used to drift in all
// day (sun 0.3-0.42); pinned at 17:00 it sets about an hour into a session.
//
// lerp-param: speed   float 0.25 3   = 1    "Build speed"
// lerp-param: clock   float -1 24    = -1   "Hour (-1 = now)"
// lerp-param: orbit   float 0 3      = 1    "Orbit speed"
// lerp-param: yaw     float -180 180 = 0    "Turn"
// lerp-param: pitch   float -25 45   = 0    "Tilt"
// lerp-param: magnify float -1 1     = 0    "Zoom"
//
// lerp-preset: "Golden Hour" clock=17
// lerp-preset: Noon     clock=12
// lerp-preset: Night    clock=0
// lerp-preset: Bustle   speed=2.5

// --- Timeline, in build-clock seconds (u.time × speed).
constant float VT_T    = 120.0;   // one plot's cycle
constant float VT_B1   = 0.5;     // building until here (fraction of a cycle)
constant float VT_D0   = 0.82;    // standing until here, then mined out
constant float VT_D1   = 0.975;   // gone; the plot stands empty until the cycle ends
constant float VT_MINE = 0.8;     // one block's breaking, all ten stages
constant float VT_MARK = 0.9;     // the outline stays on a new block this long
constant float VT_WHEAT_STAGE = 5.5;   // seconds per wheat growth stage

// --- World.
constant float VT_SEA   = 0.875;  // water surface: a source block is 14/16 high
constant int   VT_STEPS = 120;
constant int   VT_CUTOUTS = 6;    // see-through texels (leaves, glass, door, wheat) a ray may pass
constant float VT_FOCAL = 2.1;
constant float3 VT_BMIN = float3(-22.0, -7.0, -22.0);
constant float3 VT_BMAX = float3( 22.0, 11.0,  22.0);

// Blocks.
constant int M_AIR = 0, M_GRASS = 1, M_DIRT = 2, M_STONE = 3, M_COBBLE = 4,
             M_MOSSY_COBBLE = 5, M_PLANKS = 6, M_LOG = 7, M_GLASS = 8, M_STAIRS = 9,
             M_SLAB = 10, M_BRICKS = 11, M_LEAVES = 12, M_PATH = 13, M_SAND = 14,
             M_GRAVEL = 15, M_LANTERN = 16, M_FENCE = 17, M_DOOR = 18, M_TORCH = 19,
             M_FARMLAND = 20, M_WHEAT = 21, M_WATER = 22;
// Woods: 0 oak, 1 spruce, 2 birch, 3 dark oak.

struct VtWorld {
    float  tt;      // build clock
    float  now;     // wall clock: water, lantern flicker, clouds
    uint   seedBits;
    float2 noiseOff;
};

struct VtCell {
    int   m;
    int   w;       // wood, brick variant
    int   aux;     // stairs/door facing (0 -x, 1 +x, 2 -z, 3 +z; door +4 for the upper half),
                   // log axis (0 y, 1 x, 2 z), wheat stage
    float age;     // build-clock seconds since it was placed
    float crack;   // 0..1 while being mined
};

static inline VtCell vtEmpty() {
    VtCell v; v.m = M_AIR; v.w = 0; v.aux = 0; v.age = 1e3; v.crack = 0.0;
    return v;
}

static inline uint vtPcg(uint v) {
    uint s = v * 747796405u + 2891336453u;
    uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
    return (w >> 22u) ^ w;
}

static inline float vtHash2(int2 c, uint salt) {
    uint h = vtPcg(uint(c.x) * 73856093u ^ vtPcg(uint(c.y) * 19349663u ^ salt));
    return float(h) * (1.0 / 4294967296.0);
}

// Where a block falls in the build order within its course: the angle round
// the structure's centre, swept one way on even courses and back on odd.
static inline float vtSweep(int a, int b, int y, float ang0, uint salt) {
    float th = atan2(float(b) + 0.013, float(a) + 0.031) * (1.0 / TWO_PI);
    float dir = (y & 1) != 0 ? 1.0 : -1.0;
    float j = vtHash2(int2(a * 17 + b, y), salt);
    return fract(th * dir + ang0) * 0.94 + 0.04 * j;
}

// ---------------------------------------------------------------------------
// Structures, in plot-local coordinates: a along the long axis, b across, y up
// from the ground course (y = 0 replaces the grass). Each fills `v` (m, w and a
// local facing in aux: 0 -a, 1 +a, 2 -b, 3 +b) and writes its build key o and
// removal key rk, both 0..1.

static inline void vtHouse(int a, int y, int b, int ha, int wh, int style, bool chimney,
                           float ang0, uint salt, thread VtCell& v, thread float& o, thread float& rk) {
    const int hb = 2;
    int aa = abs(a), ab = abs(b);
    int ridge = wh + 1 + hb + 1;
    if (aa > ha || ab > hb + 1 || y > ridge) return;
    // Plains oak, taiga spruce, or oak walls under a dark-oak roof.
    int plank = style == 1 ? 1 : 0, logW = style == 1 ? 1 : (style == 2 ? 1 : 0), roof = style == 2 ? 3 : plank;
    int m = M_AIR, w = 0, aux = 0;
    if (y == 0) {
        if (ab <= hb) m = M_COBBLE;
    } else if (y <= wh) {
        if (ab <= hb && (ab == hb || aa == ha)) {
            bool corner = ab == hb && aa == ha;
            m = corner ? M_LOG : M_PLANKS; w = corner ? logW : plank;
            if (y == 2 && ((ab == hb && aa == 1) || (aa == ha && b == 0))) m = M_GLASS;
            if (b == -hb && a == 0 && y <= 2) { m = M_DOOR; w = plank; aux = 2 + (y == 2 ? 4 : 0); }
        } else if (y == 1 && a == -(ha - 1) && b == hb - 1) {
            m = M_TORCH;                                         // inside, by the back wall
        }
    } else {
        int k = y - wh - 1;                                      // roof course
        if (k <= hb && ab == hb + 1 - k) { m = M_STAIRS; w = roof; aux = b > 0 ? 2 : 3; }   // high side inward
        else if (k == hb + 1 && b == 0) { m = M_SLAB; w = roof; }
        else if (k <= hb && ab < hb + 1 - k && aa == ha) { m = M_PLANKS; w = plank; }       // gable
    }
    if (chimney && a == ha - 1 && b == 1 && y > wh && y <= ridge) { m = M_COBBLE; w = 0; }
    if (m == M_AIR) return;
    v.m = m; v.w = w; v.aux = aux;
    o = (float(y) + vtSweep(a, b, y, ang0, salt)) / float(ridge + 1);
    if (m == M_TORCH) o = (float(wh) + 0.99) / float(ridge + 1);   // lit once the walls are up
    rk = 1.0 - o;
}

static inline void vtTower(int a, int y, int b, int h, float ang0, uint salt,
                           thread VtCell& v, thread float& o, thread float& rk) {
    int aa = abs(a), ab = abs(b);
    if (aa > 2 || ab > 2 || y > h + 1) return;
    bool rim = aa == 2 || ab == 2;
    int m = M_AIR;
    if (y == 0) m = M_COBBLE;
    else if (y < h) {
        if (rim) {
            m = y == 1 ? M_COBBLE : M_BRICKS;
            if (b == -2 && a == 0 && y <= 2) m = M_AIR;                  // doorway
            if (y % 3 == 0 && (a == 0 || b == 0)) m = M_AIR;             // arrow slits
        }
    } else if (y == h) m = M_BRICKS;                                     // roof deck
    else {
        if (rim && ((a + b) & 1) == 0) m = M_BRICKS;                     // merlons
        if (a == 0 && b == 0) m = M_LANTERN;
    }
    if (m == M_AIR) return;
    v.m = m;
    if (m == M_BRICKS) {
        float hh = vtHash2(int2(a * 5 + b, y), salt ^ 0x9e37u);
        v.w = hh < 0.16 ? 1 : (hh < 0.24 ? 2 : 0);                      // some mossy, some cracked
    } else if (m == M_COBBLE && vtHash2(int2(a, b), salt) < 0.3) v.m = M_MOSSY_COBBLE;
    o = (float(y) + vtSweep(a, b, y, ang0, salt)) / float(h + 2);
    rk = 1.0 - o;
}

// The game's oak and birch shape (two wide leaf courses, two narrow, corners
// clipped at random) and its spruce cone.
static inline void vtTree(int a, int y, int b, int th, int kind, uint salt,
                          thread VtCell& v, thread float& o, thread float& rk) {
    int aa = abs(a), ab = abs(b);
    if (aa > 2 || ab > 2 || y > th + 1 || y < 1) return;
    int wood = kind == 2 ? 1 : (kind == 1 ? 2 : 0);
    if (a == 0 && b == 0 && y <= th) {
        v.m = M_LOG; v.w = wood;
        o = 0.28 * float(y) / float(th);
        rk = 0.72 + 0.27 * float(th - y) / float(th);
        return;
    }
    float h = vtHash2(int2(a * 7 + b, y), salt);
    bool corner = aa == ab && aa > 0;
    bool leaf;
    int r;
    if (kind == 2) {                                   // spruce: alternating rings
        int fromTop = th + 1 - y;
        r = fromTop == 0 ? 0 : (fromTop == 1 ? 1 : ((fromTop & 1) == 0 ? 2 : 1));
        if (y < 2) r = -1;
        leaf = max(aa, ab) <= r && !(r == 2 && corner && aa == 2) && !(r == 1 && fromTop == 1 && corner);
    } else {
        r = y >= th ? 1 : (y >= th - 2 ? 2 : -1);
        leaf = max(aa, ab) <= r;
        if (leaf && corner && aa == r) leaf = (y == th + 1) ? false : h > 0.5;
    }
    if (!leaf) return;
    v.m = M_LEAVES; v.w = wood;
    float dd = length(float3(float(a), float(y - th) * 1.2, float(b))) / 3.0;
    o = 0.3 + 0.68 * saturate(dd + 0.05 * h);          // the crown fills out from the trunk top
    rk = 0.7 * h;                                      // leaves go at random, then the trunk
}

// A village farm: a log border, moist farmland either side of a water channel,
// wheat planted last and ripening through its stages while the farm stands.
static inline void vtFarm(int a, int y, int b, float ang0, uint salt,
                          thread VtCell& v, thread float& o, thread float& rk) {
    int aa = abs(a), ab = abs(b);
    if (aa > 3 || ab > 3 || y > 1) return;
    bool border = aa == 3 || ab == 3;
    float s = vtSweep(a, b, 0, ang0, salt);
    if (y == 0) {
        if (border) { v.m = M_LOG; v.w = 0; v.aux = ab == 3 ? 1 : 2; o = 0.22 * s; rk = 0.9 + 0.09 * s; }
        else if (b == 0) { v.m = M_WATER; o = 0.4 + 0.08 * float(a + 3) / 6.0; rk = 0.75 + 0.1 * s; }
        else { v.m = M_FARMLAND; o = 0.22 + 0.17 * (float(a + 3) + 6.0 * float(b + 3)) / 42.0; rk = 0.6 + 0.12 * s; }
        return;
    }
    if (border || b == 0) return;
    v.m = M_WHEAT;
    o = 0.5 + 0.48 * (float(a + 3) + 6.0 * float(b + 3)) / 42.0;   // sown row by row
    rk = 0.55 * (float(3 - a) + 6.0 * float(3 - b)) / 42.0;        // harvested first
}

// Local facing (0 -a, 1 +a, 2 -b, 3 +b) to world (0 -x, 1 +x, 2 -z, 3 +z).
static inline int vtWorldDir(int d, bool swap, bool flip) {
    int axisLocal = d >> 1;                    // 0 a, 1 b
    int sgn = (d & 1) != 0 ? 1 : -1;
    if (flip) sgn = -sgn;
    int axisWorld = (axisLocal == 0) != swap ? 0 : 1;   // a is x unless swapped
    return axisWorld * 2 + (sgn > 0 ? 1 : 0);
}

// One plot's current design, decoded from its hash.
struct VtPlan {
    float ph;          // how far the cycle has run, 0..1
    uint  hp;
    int   type;        // 1 house, 2 tower, 3 tree, 4 farm
    bool  swap, flip;
    int   ha, varH, offA, offB, style;
    float ang0;
};

static inline VtPlan vtPlan(int j, VtWorld W) {
    VtPlan p;
    float off = fract(float(j) * 0.6180339 + float(W.seedBits & 1023u) * (1.0 / 1024.0)) * VT_T;
    float cyc = (W.tt + off) * (1.0 / VT_T);
    float k = floor(cyc);
    p.ph = cyc - k;
    uint hp = vtPcg(uint(j) * 2654435761u ^ vtPcg(uint(int(k)) * 2246822519u ^ W.seedBits));
    p.hp = hp;
    float pick = float(hp & 255u) / 256.0;
    p.type = pick < 0.4 ? 1 : (pick < 0.55 ? 2 : (pick < 0.8 ? 3 : 4));
    p.swap = (hp >> 8) & 1u; p.flip = (hp >> 9) & 1u;
    p.ha = 2 + int((hp >> 10) & 1u);
    p.varH = int((hp >> 11) & 3u);
    p.offA = int((hp >> 13) % 3u) - 1; p.offB = int((hp >> 15) % 3u) - 1;
    int style = int((hp >> 17) % 5u);                       // 0..2 oak, 3 spruce, 4 dark roof
    p.style = style < 3 ? 0 : style - 2;
    p.ang0 = float((hp >> 25) & 127u) / 128.0;
    return p;
}

// Structure-local (a, b) back to plot-local (lx, lz).
static inline int2 vtToPlot(int a, int b, VtPlan p) {
    if (p.type == 1) a += p.offA * (3 - p.ha);
    else if (p.type != 4) { a += p.offA; b += p.offB; }
    if (p.flip) { a = -a; b = -b; }
    return p.swap ? int2(b, a) : int2(a, b);
}

// One plot's block at plot-local (lx, y, lz).
static inline VtCell vtPlotCell(int j, int lx, int y, int lz, VtWorld W) {
    VtCell v = vtEmpty();
    if (y > 10 || abs(lx) > 3 || abs(lz) > 3) return v;
    VtPlan P = vtPlan(j, W);
    float ph = P.ph;
    if (ph >= VT_D1) return v;
    uint hp = P.hp;
    int type = P.type;
    bool swap = P.swap, flip = P.flip;
    int ha = P.ha, varH = P.varH, offA = P.offA, offB = P.offB, style = P.style;
    float ang0 = P.ang0;

    int a = swap ? lz : lx, b = swap ? lx : lz;
    if (flip) { a = -a; b = -b; }
    float o = 0.0, rk = 0.0;
    if (type == 1) {
        a -= offA * (3 - ha);
        vtHouse(a, y, b, ha, 3 + (varH & 1), style, (hp >> 19) & 1u, ang0, hp, v, o, rk);
    } else if (type == 2) {
        a -= offA; b -= offB;
        vtTower(a, y, b, 6 + varH, ang0, hp, v, o, rk);
    } else if (type == 3) {
        a -= offA; b -= offB;
        int kind = int((hp >> 20) % 3u);
        vtTree(a, y, b, kind == 2 ? 6 + (varH & 1) : 4 + varH % 3, kind, hp, v, o, rk);
    } else {
        vtFarm(a, y, b, ang0, hp, v, o, rk);
    }
    if (v.m == M_AIR) return v;

    float bp = saturate(ph * (1.0 / VT_B1));
    if (o >= bp) return vtEmpty();
    v.age = (ph - o * VT_B1) * VT_T;
    if (ph > VT_D0) {
        float span = (VT_D1 - VT_D0) * VT_T;
        float d = (ph - VT_D0) * VT_T / span;
        float w = VT_MINE / span;
        float cr = (d - rk * (1.0 - w)) / w;
        if (cr >= 1.0) return vtEmpty();
        v.crack = (v.m == M_LEAVES || v.m == M_WHEAT || v.m == M_TORCH) ? 0.0 : saturate(cr);   // these break at once
    }
    if (v.m == M_WHEAT) v.aux = min(int(v.age / VT_WHEAT_STAGE), 7);
    if (v.m == M_STAIRS || v.m == M_DOOR) v.aux = vtWorldDir(v.aux & 3, swap, flip) + (v.aux & 4);
    if (v.m == M_LOG && v.aux != 0) {
        bool alongA = v.aux == 1;                     // farm border logs lie along a or b
        v.aux = (alongA != swap) ? 1 : 2;
    }
    return v;
}

static inline float vtIslandR(float2 pc, VtWorld W) {
    return 18.2 + 2.8 * valueNoise(pc * 0.085 + W.noiseOff);
}

static inline VtCell vtCell(int3 c, VtWorld W) {
    VtCell v = vtEmpty();
    if (c.y > 10 || c.y < -7) return v;
    float2 pc = float2(c.xz) + 0.5;
    bool town = c.x >= -13 && c.x <= 13 && c.z >= -13 && c.z <= 13;
    int lx = 0, lz = 0;
    if (town) {
        int px = (c.x + 13) / 9 - 1, pz = (c.z + 13) / 9 - 1;
        lx = c.x - px * 9; lz = c.z - pz * 9;
        if (c.y >= 0) {
            // An oak fence and a lantern at each inner crossroads.
            if ((c.x == 5 || c.x == -5) && (c.z == 5 || c.z == -5) && c.y >= 1 && c.y <= 2) {
                v.m = c.y == 1 ? M_FENCE : M_LANTERN; return v;
            }
            v = vtPlotCell((px + 1) * 3 + pz + 1, lx, c.y, lz, W);
            if (v.m != M_AIR || c.y > 0) return v;
        }
    } else if (c.y > 2) return v;

    float r = length(pc);
    float R = vtIslandR(pc, W);
    float colH = vtHash2(c.xz, 0x5bd1e995u ^ W.seedBits);
    if (r > R) {
        // Sea floor: sand shelving away in terraces, gravel deeper down.
        int top = -1 - int(min((r - R) * 0.6 + colH * 0.7, 5.0));
        if (c.y > top) return v;
        v.m = (top < -3 && colH > 0.35) ? M_GRAVEL : (c.y > top - 2 ? M_SAND : M_STONE);
        return v;
    }
    int top = 0;
    if (!town) {
        float hill = valueNoise(pc * 0.2 + W.noiseOff * 1.7 + 11.0);
        top = hill > 0.6 ? (hill > 0.78 ? 2 : 1) : 0;
    }
    if (c.y > top) return v;
    bool beach = r > R - 1.6 && top == 0;
    if (c.y == top) {
        bool road = town && (abs(lx) == 4 || abs(lz) == 4);
        v.m = beach ? M_SAND : (road ? M_PATH : M_GRASS);
    } else if (beach && c.y >= -2) {
        v.m = M_SAND;
    } else {
        v.m = c.y >= top - 2 - int(colH * 2.0) ? M_DIRT : M_STONE;
    }
    return v;
}

static inline bool vtSolid(int3 c, VtWorld W) { return vtCell(c, W).m != M_AIR; }
static inline bool vtFullBlock(int m) {
    return m != M_STAIRS && m != M_SLAB && m != M_LANTERN && m != M_FENCE && m != M_DOOR
        && m != M_TORCH && m != M_WHEAT && m != M_WATER && m != M_AIR;
}
static inline bool vtCutout(int m) { return m == M_LEAVES || m == M_GLASS || m == M_DOOR; }
static inline bool vtKitModel(int m) { return m == M_LANTERN || m == M_TORCH || m == M_WHEAT; }

// ---------------------------------------------------------------------------
// Surfaces: which texture a face shows and where.

constant int VT_TINT_NONE = 0, VT_TINT_GRASS = 1, VT_TINT_GRASS_SIDE = 2, VT_TINT_FOLIAGE = 3,
             VT_TINT_BIRCH = 4, VT_TINT_SPRUCE = 5, VT_TINT_WATER = 6;

struct VtSurf {
    int    layer;
    float2 uv;
    int    tint;
    bool   emit;
};

static inline int vtPlanks(int w) { return w == 1 ? MC_SPRUCE_PLANKS : (w == 2 ? MC_BIRCH_PLANKS : (w == 3 ? MC_DARK_OAK_PLANKS : MC_OAK_PLANKS)); }
static inline int vtLogSide(int w) { return w == 1 ? MC_SPRUCE_LOG : (w == 2 ? MC_BIRCH_LOG : (w == 3 ? MC_DARK_OAK_LOG : MC_OAK_LOG)); }
static inline int vtLogTop(int w) { return w == 1 ? MC_SPRUCE_LOG_TOP : (w == 2 ? MC_BIRCH_LOG_TOP : (w == 3 ? MC_DARK_OAK_LOG_TOP : MC_OAK_LOG_TOP)); }

static inline VtSurf vtSurface(VtCell v, int3 c, float3 P, float3 n, float now) {
    VtSurf s; s.tint = VT_TINT_NONE; s.emit = false;
    float3 lp = P - float3(c);
    int ax = abs(n.x) > 0.5 ? 0 : (abs(n.y) > 0.5 ? 1 : 2);
    float2 side = float2(ax == 0 ? lp.z : lp.x, 1.0 - lp.y);
    if ((ax == 0 && n.x > 0.0) || (ax == 2 && n.z < 0.0)) side.x = 1.0 - side.x;
    s.uv = ax == 1 ? lp.xz : side;
    bool top = ax == 1 && n.y > 0.0;
    switch (v.m) {
    case M_GRASS:
        if (ax == 1) { s.layer = top ? MC_GRASS_BLOCK_TOP : MC_DIRT; s.tint = top ? VT_TINT_GRASS : VT_TINT_NONE; }
        else { s.layer = MC_GRASS_BLOCK_SIDE; s.tint = VT_TINT_GRASS_SIDE; }
        break;
    case M_DIRT:          s.layer = MC_DIRT; break;
    case M_STONE:         s.layer = MC_STONE; break;
    case M_COBBLE:        s.layer = MC_COBBLESTONE; break;
    case M_MOSSY_COBBLE:  s.layer = MC_MOSSY_COBBLESTONE; break;
    case M_SAND:          s.layer = MC_SAND; break;
    case M_GRAVEL:        s.layer = MC_GRAVEL; break;
    case M_PATH:          s.layer = ax == 1 ? (top ? MC_DIRT_PATH_TOP : MC_DIRT) : MC_DIRT_PATH_SIDE; break;
    case M_PLANKS: case M_STAIRS: case M_SLAB: case M_FENCE:
        s.layer = vtPlanks(v.w); break;
    case M_LOG: {
        int axis = v.aux == 1 ? 0 : (v.aux == 2 ? 2 : 1);
        if (ax == axis) { s.layer = vtLogTop(v.w); s.uv = axis == 0 ? lp.zy : (axis == 2 ? lp.xy : lp.xz); }
        else {
            s.layer = vtLogSide(v.w);
            if (axis != 1) {
                float along = axis == 0 ? lp.x : lp.z;
                float across = ax == 1 ? (axis == 0 ? lp.z : lp.x) : lp.y;
                s.uv = float2(across, along);       // grain runs along the log
            }
        }
        break;
    }
    case M_GLASS:   s.layer = MC_GLASS; break;
    case M_BRICKS:  s.layer = v.w == 1 ? MC_MOSSY_STONE_BRICKS : (v.w == 2 ? MC_CRACKED_STONE_BRICKS : MC_STONE_BRICKS); break;
    case M_LEAVES:
        s.layer = v.w == 1 ? MC_SPRUCE_LEAVES : (v.w == 2 ? MC_BIRCH_LEAVES : MC_OAK_LEAVES);
        s.tint = v.w == 1 ? VT_TINT_SPRUCE : (v.w == 2 ? VT_TINT_BIRCH : VT_TINT_FOLIAGE);
        break;
    case M_DOOR: {
        bool upper = (v.aux & 4) != 0;
        s.layer = v.w == 1 ? (upper ? MC_SPRUCE_DOOR_TOP : MC_SPRUCE_DOOR_BOTTOM) : (upper ? MC_OAK_DOOR_TOP : MC_OAK_DOOR_BOTTOM);
        break;
    }
    case M_FARMLAND: s.layer = top ? MC_FARMLAND_MOIST : MC_DIRT; break;
    case M_WATER:
        s.layer = mcFrame(MC_WATER_STILL, MC_WATER_STILL_FRAMES, MC_WATER_STILL_TICKS, now);
        s.tint = VT_TINT_WATER;
        break;
    default: s.layer = MC_STONE;
    }
    return s;
}

// ---------------------------------------------------------------------------
// Tracing.

struct VtHit {
    bool   hit;
    float  t;
    float3 n;
    int3   c;
    VtCell v;
    bool   model;     // a kit model (lantern, torch, wheat): its texel is in mcol
    float4 mcol;
    float  mshade;
};

// Ray against a box; the near face's t and normal if it is at or after tMin.
static inline bool vtBoxN(float3 ro, float3 inv, float3 lo, float3 hi, float tMin,
                          thread float& t, thread float3& n) {
    float3 t1 = (lo - ro) * inv, t2 = (hi - ro) * inv;
    float3 tn = min(t1, t2), tf = max(t1, t2);
    float tNear = max(max(tn.x, tn.y), tn.z), tFar = min(min(tf.x, tf.y), tf.z);
    if (tNear > tFar || tNear < tMin - 1e-4) return false;
    int a = tn.x > tn.y ? (tn.x > tn.z ? 0 : 2) : (tn.y > tn.z ? 1 : 2);
    n = float3(0.0); n[a] = -sign(1.0 / inv[a]);
    t = tNear;
    return true;
}

// The model inside a cell that is not a whole block and not one of the kit's
// small models: its first face after tc.
static inline bool vtModel(VtCell v, int3 c, float3 ro, float3 rd, float3 inv, float tc,
                           thread float& t, thread float3& n) {
    float3 o = float3(c);
    float best = 1e9; float3 bn = float3(0.0); float tt; float3 nn;
    float3 lo0, hi0, lo1 = float3(0.0), hi1 = float3(-1.0);
    switch (v.m) {
    case M_STAIRS: {
        lo0 = float3(0.0); hi0 = float3(1.0, 0.5, 1.0);
        int d = v.aux & 3;
        lo1 = float3(d == 1 ? 0.5 : 0.0, 0.5, d == 3 ? 0.5 : 0.0);
        hi1 = float3(d == 0 ? 0.5 : 1.0, 1.0, d == 2 ? 0.5 : 1.0);
        break;
    }
    case M_SLAB:    lo0 = float3(0.0); hi0 = float3(1.0, 0.5, 1.0); break;
    case M_FENCE:   lo0 = float3(6.0, 0.0, 6.0) / 16.0; hi0 = float3(10.0, 16.0, 10.0) / 16.0; break;
    case M_WATER:   lo0 = float3(0.0); hi0 = float3(1.0, 14.0 / 16.0, 1.0); break;
    case M_DOOR: {
        // 3/16 thick, against the outer face of its opening.
        int d = v.aux & 3;
        const float th = 3.0 / 16.0;
        lo0 = float3(d == 1 ? 1.0 - th : 0.0, 0.0, d == 3 ? 1.0 - th : 0.0);
        hi0 = float3(d == 0 ? th : 1.0, 1.0, d == 2 ? th : 1.0);
        if (d >= 2) { lo0.x = 0.0; hi0.x = 1.0; } else { lo0.z = 0.0; hi0.z = 1.0; }
        break;
    }
    default: return false;
    }
    if (vtBoxN(ro, inv, o + lo0, o + hi0, tc, tt, nn) && tt < best) { best = tt; bn = nn; }
    if (hi1.y > 0.0 && vtBoxN(ro, inv, o + lo1, o + hi1, tc, tt, nn) && tt < best) { best = tt; bn = nn; }
    if (best > 1e8) return false;
    t = best; n = bn;
    return true;
}

static inline VtHit vtTrace(float3 ro, float3 rd, float pxAngle, VtWorld W,
                            texture2d_array<float> mcTiles) {
    VtHit h; h.hit = false; h.t = 1e9; h.model = false; h.mcol = float4(0.0); h.mshade = 0.0;
    float3 inv = 1.0 / select(rd, float3(1e-6), abs(rd) < 1e-6);
    float3 t1 = (VT_BMIN - ro) * inv, t2 = (VT_BMAX - ro) * inv;
    float3 tn = min(t1, t2), tf = max(t1, t2);
    float tEnter = max(max(tn.x, tn.y), max(tn.z, 0.0));
    float tExit = min(min(tf.x, tf.y), tf.z);
    if (tEnter >= tExit) return h;
    int axis = tn.x > tn.y ? (tn.x > tn.z ? 0 : 2) : (tn.y > tn.z ? 1 : 2);
    int3 c = int3(floor(ro + rd * (tEnter + 1e-4)));
    c = clamp(c, int3(VT_BMIN), int3(VT_BMAX) - 1);
    int3 st = int3(sign(rd));
    float3 tMax = (float3(c) + step(0.0, rd) - ro) * inv;
    float3 tDel = abs(inv);
    float tc = tEnter;
    int cutouts = 0;
    for (int i = 0; i < VT_STEPS; ++i) {
        VtCell v = vtCell(c, W);
        if (v.m != M_AIR && vtKitModel(v.m)) {
            // The kit's lantern, torch and crop models, cut-outs included.
            McModelHit mh;
            float3 org = float3(c);
            bool got = v.m == M_LANTERN
                ? mcLantern(mcTiles, mcFrame(MC_LANTERN, MC_LANTERN_FRAMES, MC_LANTERN_TICKS, W.now), org, false, ro, rd, tc - 1e-4, 1e9, pxAngle, mh)
                : (v.m == M_TORCH ? mcTorch(mcTiles, MC_TORCH, org, ro, rd, tc - 1e-4, 1e9, pxAngle, mh)
                                  : mcCrop(mcTiles, MC_WHEAT_STAGE0 + clamp(v.aux, 0, 7), org, ro, rd, tc - 1e-4, 1e9, pxAngle, mh));
            if (got) {
                h.hit = true; h.t = mh.t; h.c = c; h.v = v; h.n = mh.n;
                h.model = true; h.mcol = mh.color; h.mshade = mh.shade;
                return h;
            }
        } else if (v.m != M_AIR) {
            float th = tc; float3 nh = float3(0.0);
            bool got;
            if (vtFullBlock(v.m)) { got = true; nh[axis] = -float(st[axis]); }
            else got = vtModel(v, c, ro, rd, inv, tc, th, nh);
            // See-through texels: sample at the hit and walk on if clear.
            if (got) {
                if (!vtCutout(v.m) || cutouts >= VT_CUTOUTS) {
                    h.hit = true; h.t = th; h.c = c; h.v = v; h.n = nh;
                    return h;
                }
                ++cutouts;
                VtSurf s = vtSurface(v, c, ro + rd * th, nh, W.now);
                if (mcTile(mcTiles, s.layer, s.uv, th * pxAngle).a > 0.5) {
                    h.hit = true; h.t = th; h.c = c; h.v = v; h.n = nh;
                    return h;
                }
            }
        }
        if (tMax.x < tMax.y) {
            if (tMax.x < tMax.z) { tc = tMax.x; c.x += st.x; tMax.x += tDel.x; axis = 0; }
            else                 { tc = tMax.z; c.z += st.z; tMax.z += tDel.z; axis = 2; }
        } else {
            if (tMax.y < tMax.z) { tc = tMax.y; c.y += st.y; tMax.y += tDel.y; axis = 1; }
            else                 { tc = tMax.z; c.z += st.z; tMax.z += tDel.z; axis = 2; }
        }
        if (tc > tExit) break;
    }
    return h;
}

// ---------------------------------------------------------------------------
// Sky: the game's sky and fog colours, the sunset glow toward the sun, the
// sun and moon textures, stars, and the cloud layer.

struct VtLight {
    float3 sunDir;
    float  bright;     // daylight 0..1, the game's cos(angle)·2 + 0.5
    float3 sky, fog;
    float3 glow;       // sunrise/sunset colour
    float  glowA;      // and its strength
};

// The clock as `vtLighting`'s sun height. On a sine from sunrise to sunset
// the sun climbs to 1.21 rad at midday (the old Noon preset, sun=0.9) and
// sinks to -0.44 rad at the middle of the night (the old Night, sun=0.03).
static inline float vtSunFromClock(constant LerpUniforms& u, constant LerpClock& clock) {
    float hour = glmod(clock.hourAtZero + u.time / 3600.0, 24.0);
    float rise = clock.sunrise, set = clock.sunset;
    float e;
    if (hour >= rise && hour <= set) {
        e = 1.21 * sin(PI * (hour - rise) / (set - rise));
    } else {
        e = -0.443 * sin(PI * glmod(hour - set, 24.0) / (24.0 - (set - rise)));
    }
    return (e + 0.5) / 1.9;
}

static inline VtLight vtLighting(float sunParam) {
    VtLight l;
    float e = mix(-0.5, 1.4, sunParam);            // sun elevation, radians
    float az = 0.65;
    l.sunDir = normalize(float3(cos(e) * cos(az), sin(e), cos(e) * sin(az)));
    float f = sin(e);
    l.bright = clamp(f * 2.0 + 0.5, 0.0, 1.0);
    l.sky = mcSkyAt(l.bright);
    l.fog = mcFogAt(l.bright);
    l.glowA = 0.0; l.glow = float3(0.0);
    if (abs(f) <= 0.4) {
        float g = f / 0.4 * 0.5 + 0.5;
        float a = 1.0 - (1.0 - sin(g * PI)) * 0.99;
        l.glowA = a * a;
        l.glow = float3(g * 0.3 + 0.7, g * g * 0.7 + 0.2, 0.2);
    }
    return l;
}

// The fog colour looking along rd: warmed toward the sun at dusk.
static inline float3 vtFog(float3 rd, VtLight l) {
    float2 h = normalize(rd.xz + 1e-5), s = normalize(l.sunDir.xz);
    float toward = saturate(dot(h, s));
    return mix(l.fog, l.glow, l.glowA * toward * toward * 0.7);
}

static inline float3 vtSky(float3 rd, VtLight l, float pxAngle, float now, float moonPhase,
                           texture2d_array<float> mcSkins, texture2d_array<float> mcMaps) {
    float y = max(rd.y, 0.0);
    float3 fogC = vtFog(rd, l);
    float3 col = mix(fogC, l.sky, 1.0 - exp(-y * 5.0));
    // The sunset fan, low and wide on the sun's side.
    float2 hdir = normalize(rd.xz + 1e-5), sdir = normalize(l.sunDir.xz);
    float fan = pow(saturate(dot(hdir, sdir)), 3.0) * exp(-y * 4.0);
    col = mix(col, l.glow, l.glowA * fan);

    // Stars, at night.
    float night = 1.0 - l.bright;
    if (night > 0.01 && rd.y > 0.0) {
        float3 g = floor(rd * 300.0);
        float h = hash21(g.xy + g.z * 37.1);
        col += step(0.9968, h) * night * night * (0.5 + 0.5 * hash21(g.zx)) * saturate(rd.y * 5.0);
    }

    // Sun and moon: the game's textures on black, added to the sky.
    for (int k = 0; k < 2; ++k) {
        float3 d = k == 0 ? l.sunDir : -l.sunDir;
        float hs = k == 0 ? 0.3 : 0.2;
        float sd = dot(rd, d);
        if (sd <= 0.0) continue;
        float3 su = normalize(cross(d, float3(0.0, 1.0, 0.0)));
        float3 sv = cross(su, d);
        float2 q = float2(dot(rd, su), dot(rd, sv)) / sd / hs;
        if (max(abs(q.x), abs(q.y)) >= 1.0) continue;
        float2 px = (q * float2(1.0, -1.0) * 0.5 + 0.5) * 32.0;
        float w = pxAngle / hs * 16.0;
        int layer = k == 0 ? MCS_ENVIRONMENT_CELESTIAL_SUN
                  : (moonPhase < 0.5 ? MCS_ENVIRONMENT_CELESTIAL_MOON_FULL_MOON : MCS_ENVIRONMENT_CELESTIAL_MOON_WANING_GIBBOUS);
        float3 tex = mcSkin(mcSkins, layer, px, w).rgb;
        col += tex * (k == 0 ? 1.0 : night);
    }

    // Clouds: clouds.png, twelve blocks a pixel, drifting with the wind.
    if (rd.y > 0.01) {
        const float H = 105.0;
        float d = H / rd.y;
        float2 p = (rd.xz * d + float2(now * 0.6, 0.0)) / 12.0;
        float2 px = p - 256.0 * floor(p / 256.0);
        float w = d * pxAngle / rd.y / 12.0;
        float a = mcMap(mcMaps, MCM_ENVIRONMENT_CLOUDS, px, w).a;
        float3 cc = float3(l.bright * 0.9 + 0.1) * mix(float3(1.0), l.glow * 1.1, l.glowA * fan * 0.8);
        float fade = 1.0 - smoothstep(250.0, 700.0, d);
        col = mix(col, cc, a * 0.8 * fade);
    }
    return col;
}

// ---------------------------------------------------------------------------
// Light: smooth-lighting corners, sky light under cover and under water,
// block light from torches and lanterns.

static inline float vtAO(VtHit h, float3 P, VtWorld W) {
    int3 n = int3(round(h.n));
    float3 lp = P - float3(h.c);
    int3 t1 = abs(n.y) > 0 ? int3(1, 0, 0) : (abs(n.x) > 0 ? int3(0, 0, 1) : int3(1, 0, 0));
    int3 t2 = abs(n.y) > 0 ? int3(0, 0, 1) : int3(0, 1, 0);
    float2 uv = abs(n.y) > 0 ? lp.xz : (abs(n.x) > 0 ? lp.zy : lp.xy);
    // A full block's face looks into the next cell; a model's into its own.
    int3 b = vtFullBlock(h.v.m) ? h.c + n : h.c;
    if (!vtFullBlock(h.v.m) && n.y > 0) b = h.c + int3(0, 1, 0);
    float s0 = vtSolid(b - t1, W) ? 1.0 : 0.0, s1 = vtSolid(b + t1, W) ? 1.0 : 0.0;
    float s2 = vtSolid(b - t2, W) ? 1.0 : 0.0, s3 = vtSolid(b + t2, W) ? 1.0 : 0.0;
    float s4 = vtSolid(b - t1 - t2, W) ? 1.0 : 0.0, s5 = vtSolid(b + t1 - t2, W) ? 1.0 : 0.0;
    float s6 = vtSolid(b - t1 + t2, W) ? 1.0 : 0.0, s7 = vtSolid(b + t1 + t2, W) ? 1.0 : 0.0;
    float a00 = (s0 * s2 > 0.5) ? 3.0 : s0 + s2 + s4;
    float a10 = (s1 * s2 > 0.5) ? 3.0 : s1 + s2 + s5;
    float a01 = (s0 * s3 > 0.5) ? 3.0 : s0 + s3 + s6;
    float a11 = (s1 * s3 > 0.5) ? 3.0 : s1 + s3 + s7;
    float occ = mix(mix(a00, a10, uv.x), mix(a01, a11, uv.x), uv.y);
    return 1.0 - 0.2 * occ;
}

// The block-light source this plot has, if it is placed: a house's torch
// or a tower's lantern. Its world cell and level (0 = none).
static inline float4 vtPlotSource(int3 c, VtWorld W) {
    if (c.x < -13 || c.x > 13 || c.z < -13 || c.z > 13) return float4(0.0);
    int px = (c.x + 13) / 9 - 1, pz = (c.z + 13) / 9 - 1;
    VtPlan p = vtPlan((px + 1) * 3 + pz + 1, W);
    int3 q;
    if (p.type == 1) { int2 l = vtToPlot(-(p.ha - 1), 1, p); q = int3(l.x, 1, l.y); }
    else if (p.type == 2) { int2 l = vtToPlot(0, 0, p); q = int3(l.x, 7 + p.varH, l.y); }
    else return float4(0.0);
    q.xz += int2(px, pz) * 9;
    VtCell v = vtCell(q, W);
    if (v.m == M_TORCH) return float4(float3(q), 14.0);
    if (v.m == M_LANTERN) return float4(float3(q), 15.0);
    return float4(0.0);
}

// Light reaching the point Q just in front of a face: sky light and block
// light, as the game's light map turns them into brightness.
static inline float3 vtLightAt(float3 Q, int3 qc, VtLight l, float4 src, VtWorld W) {
    // Sky light: open sky above is 15; under a roof or overhang it is lower.
    float sky = 15.0;
    for (int y = qc.y + 1; y <= 10; ++y) {
        VtCell v = vtCell(int3(qc.x, y, qc.z), W);
        if (v.m != M_AIR && v.m != M_LEAVES && v.m != M_GLASS && v.m != M_WHEAT && v.m != M_TORCH) { sky = 12.0; break; }
    }
    sky -= max(VT_SEA - Q.y, 0.0);                     // water takes one level a block

    // Block light falls one level a block (taxicab), from the crossroads
    // lanterns and this plot's own torch or lantern.
    float lvl = 0.0;
    for (int i = 0; i < 4; ++i) {
        float3 s = float3((i & 1) != 0 ? 5.5 : -4.5, 2.5, (i & 2) != 0 ? 5.5 : -4.5);
        float3 d = abs(Q - s);
        lvl = max(lvl, 15.0 - (d.x + d.y + d.z));
    }
    if (src.w > 0.0) {
        float3 d = abs(Q - (src.xyz + 0.5));
        lvl = max(lvl, src.w - (d.x + d.y + d.z));
    }
    return mcLightmap(max(lvl, 0.0), max(sky, 0.0), l.bright, 0.0);
}

static inline float3 vtShade(VtHit h, float3 ro, float3 rd, float pxAngle, VtLight l, VtWorld W,
                             texture2d_array<float> mcTiles, texture2d_array<float> mcMaps) {
    float3 P = ro + rd * h.t;
    if (h.model) {
        // Lantern and torch give light 15; wheat takes the light around it.
        float3 Q = h.v.m == M_WHEAT ? P + float3(0.0, 0.5, 0.0) : P;
        float3 lm = h.v.m == M_WHEAT ? vtLightAt(Q, int3(floor(Q)), l, vtPlotSource(int3(floor(Q)), W), W)
                                      : mcLightmap(15.0, 15.0, l.bright, 0.0);
        return h.mcol.rgb * (h.mshade > 0.5 ? mcFaceShade(h.n) : 1.0) * lm;
    }
    float fw = h.t * pxAngle / max(abs(dot(rd, h.n)), 0.15);
    VtSurf s = vtSurface(h.v, h.c, P, h.n, W.now);
    float3 grass = mcGrassTint(mcMaps, 0.8, 0.4);       // plains
    float3 alb;
    if (s.tint == VT_TINT_GRASS_SIDE) alb = mcGrassSide(mcTiles, s.uv, fw, grass);
    else {
        alb = mcTile(mcTiles, s.layer, s.uv, fw).rgb;
        if (s.tint == VT_TINT_GRASS) alb *= grass;
        else if (s.tint == VT_TINT_FOLIAGE) alb *= mcFoliageTint(mcMaps, 0.8, 0.4);
        else if (s.tint == VT_TINT_BIRCH) alb *= mcFromSRGB(float3(0x80, 0xA7, 0x55) / 255.0);
        else if (s.tint == VT_TINT_SPRUCE) alb *= mcFromSRGB(float3(0x61, 0x99, 0x61) / 255.0);
        else if (s.tint == VT_TINT_WATER) alb *= MC_WATER_TINT;
    }

    // Breaking: the game's crack stage, multiplied over the face.
    if (h.v.crack > 0.0) {
        int stage = clamp(int(h.v.crack * 10.0), 0, 9);
        float4 ck = mcTile(mcTiles, MC_DESTROY_STAGE_0 + stage, s.uv, fw);
        alb *= mix(float3(1.0), ck.rgb * 2.0, ck.a);
    }

    float3 col;
    if (s.emit) {
        col = alb;
    } else {
        float3 Q = P + h.n * 0.5;
        float4 src = vtPlotSource(int3(floor(Q)), W);
        float3 light = vtLightAt(Q, int3(floor(Q)), l, src, W);
        col = alb * mcFaceShade(h.n) * vtAO(h, P, W) * light;
    }

    // The selection outline round the block being placed or broken: thin
    // black lines, a pixel or two wide at any distance.
    bool marked = h.v.crack > 0.0 || h.v.age < VT_MARK;
    if (marked && vtFullBlock(h.v.m)) {
        float3 lp = P - float3(h.c);
        float2 e2 = abs(h.n.y) > 0.5 ? lp.xz : (abs(h.n.x) > 0.5 ? lp.zy : lp.xy);
        float e = min(min(e2.x, 1.0 - e2.x), min(e2.y, 1.0 - e2.y));
        float lw = max(h.t * pxAngle * 1.5, 0.004);
        col = mix(col, float3(0.0), 0.4 * (1.0 - smoothstep(lw, lw * 1.6, e)));
    }
    return col;
}

// ---------------------------------------------------------------------------
// Inhabitants: the game's mobs, from the kit, on the roads. The roads are
// the two-wide lanes centred on x, z = -4 and 5 and the ring at the town's
// edge; no plot ever builds on them, so nobody walks through a wall or a
// block going up. Two villagers walk round the middle plot at one pace, half
// the loop apart, so they never meet. Each stretch of road from a crossroads
// out to the ring (a spoke) belongs to one inhabitant, who wanders it end to
// end and stops at each end to look about. A spoke's ends stop short of the
// crossroads lantern post and of the town's edge, so no two inhabitants ever
// share ground. Where everyone is, is a function of the wall clock and seed.

constant int   VT_MOBS = 9;           // 0-1 round the middle, 2 golem, 3-5 villagers, 6-7 children, 8 cat
constant float VT_LOOP_LEN = 36.0;
constant float2 VT_LOOP[4] = { float2(-4.0, -4.0), float2(5.0, -4.0), float2(5.0, 5.0), float2(-4.0, 5.0) };
// Spokes: the road's fixed coordinate, 1 if it runs along x (else along z),
// and which side of the middle it lies on.
constant float3 VT_SPOKE[8] = {
    float3(-4.0, 0.0, -1.0), float3(5.0, 1.0, 1.0), float3(5.0, 0.0, -1.0), float3(-4.0, 1.0, 1.0),
    float3(-4.0, 0.0, 1.0),  float3(5.0, 1.0, -1.0), float3(5.0, 0.0, 1.0), float3(-4.0, 1.0, -1.0) };
// Per role (villager, child, iron golem, cat): speed in blocks a second, the
// pause at each end, reach (how far any part of it comes from the point it
// turns about, hat brims and swinging arms included), the stride (the pose's
// speed while walking).
constant float4 VT_ROLE[4] = {
    float4(1.0, 4.0, 0.72, 0.4), float4(2.4, 1.2, 0.66, 0.7), float4(0.45, 5.0, 1.0, 0.35), float4(0.7, 6.0, 0.76, 0.5) };
// And: walk phase per block walked (so feet do not slide), the half-width
// and height of a box that holds the mob at any heading, and how far ahead
// of the middle of its length its feet are (a cat's tail is longer than its
// head: it turns about its middle, or the tail would sweep off the road).
constant float4 VT_ROLE_B[4] = {
    float4(5.9, 0.78, 2.10, 0.0), float4(7.0, 0.68, 1.10, 0.0), float4(4.9, 1.58, 2.80, 0.0), float4(11.0, 1.12, 0.66, 0.2) };

struct VtMob {
    int    role;     // 0 villager, 1 child, 2 iron golem, 3 cat
    float3 at;       // feet
    float  head;     // heading: 0 faces +z, pi/2 faces +x
    float  walked;   // blocks walked, for the stride
    float  moving;   // 0 standing .. 1 walking
    float  look;     // head turn while it stands
};

static inline int vtMobRole(int i) { return i == 2 ? 2 : (i >= 8 ? 3 : (i >= 6 ? 1 : 0)); }

// The middle loop at arc length s.
static inline float2 vtLoopAt(float s) {
    s -= VT_LOOP_LEN * floor(s / VT_LOOP_LEN);
    int side = min(int(s / 9.0), 3);
    return mix(VT_LOOP[side], VT_LOOP[(side + 1) & 3], (s - float(side) * 9.0) / 9.0);
}

static inline VtMob vtMobAt(int i, float now, uint sb) {
    VtMob m;
    m.role = vtMobRole(i);
    float4 ra = VT_ROLE[m.role];
    uint hh = vtPcg(uint(i) * 2654435761u ^ sb);
    float j0 = float(hh & 0xffffu) * (1.0 / 65536.0), j1 = float(hh >> 16) * (1.0 / 65536.0);
    if (i < 2) {
        float s = now * ra.x + (float(i) * 0.5 + float(sb & 1023u) * (1.0 / 1024.0)) * VT_LOOP_LEN;
        float2 p = vtLoopAt(s);
        float2 d = vtLoopAt(s + 0.45) - vtLoopAt(s - 0.45);       // corners are walked round
        m.at = float3(p.x, 1.0, p.y);
        m.head = atan2(d.x, d.y);
        m.walked = s; m.moving = 1.0;
        m.look = 0.6 * sin(now * 0.37 + j0 * 6.3) * smoothstep(0.4, 0.9, sin(now * 0.13 + j1 * 6.3));
        return m;
    }
    // A spoke's ends: the town's edge (the ground past it can stand a block
    // higher) and the crossroads, where the loop's walkers reach 0.72 from
    // its centre and the lantern post stands. Nothing reaches past either.
    float3 sp = VT_SPOKE[(i - 2 + int((sb >> 10) & 7u)) & 7];
    float R = ra.z, dd = VT_ROLE_B[m.role].w;
    float a = sp.z < 0.0 ? -13.0 + R : 5.77 + R;
    float b = sp.z < 0.0 ? -4.77 - R : 14.0 - R;
    float L = b - a - 2.0 * dd, Tw = L / ra.x, p = ra.y * (0.75 + 0.5 * j0);
    float P = 2.0 * (Tw + p);
    float tl = now + j1 * P;
    float k = floor(tl / P), tau = tl - k * P;
    float s, q, walked = k * 2.0 * L, back = 0.0, turn = 0.0;
    bool standing = false;
    m.moving = 0.0; m.look = 0.0;
    if (tau < Tw) {
        q = tau; s = a + 2.0 * dd + ra.x * q; walked += ra.x * q;
        m.moving = saturate(q / 0.35) * saturate((Tw - q) / 0.35);
    } else if (tau < Tw + p) {
        q = tau - Tw; s = b; walked += L; standing = true;
    } else if (tau < 2.0 * Tw + p) {
        q = tau - Tw - p; s = b - 2.0 * dd - ra.x * q; walked += L + ra.x * q; back = 1.0;
        m.moving = saturate(q / 0.35) * saturate((Tw - q) / 0.35);
    } else {
        q = tau - 2.0 * Tw - p; s = a; walked += 2.0 * L; back = 1.0; standing = true;
    }
    if (standing) {
        // Standing at an end: look about, then turn round, stepping, to go back.
        turn = smoothstep(p - 0.7, p - 0.1, q);
        m.look = 0.9 * sin(q * 1.1 + j0 * 6.3) * saturate(q / 0.5) * saturate((p - 0.8 - q) / 0.5);
        m.moving = 0.6 * sin(PI * turn);
        walked += turn;
    }
    float lane = m.role >= 2 ? 0.0 : (j1 - 0.5) * 0.24;           // not all on the centre line
    float fixedC = sp.x + lane;
    m.at = sp.y > 0.5 ? float3(s, 1.0, fixedC) : float3(fixedC, 1.0, s);
    float h0 = (sp.y > 0.5 ? 0.5 * PI : 0.0) + PI * back;        // 0 / pi/2: walking toward + along the road
    m.head = h0 + PI * turn;
    if (standing) m.at.xz += dd * (float2(sin(m.head), cos(m.head)) - float2(sin(h0), cos(h0)));
    m.walked = walked;
    return m;
}

static inline int vtMobType(int role) {
    return role == 0 ? MCMOB_VILLAGER : (role == 1 ? MCMOB_VILLAGER_BABY : (role == 2 ? MCMOB_IRON_GOLEM : MCMOB_CAT));
}

static inline int vtProfession(int k) {
    switch (k) {
    case 0:  return MCS_VILLAGER_PROFESSION_FARMER;
    case 1:  return MCS_VILLAGER_PROFESSION_LIBRARIAN;
    case 2:  return MCS_VILLAGER_PROFESSION_MASON;
    case 3:  return -1;                                    // unemployed: the plains robe alone
    case 4:  return MCS_VILLAGER_PROFESSION_SHEPHERD;
    case 5:  return MCS_VILLAGER_PROFESSION_TOOLSMITH;
    case 6:  return MCS_VILLAGER_PROFESSION_CLERIC;
    default: return MCS_VILLAGER_PROFESSION_NITWIT;
    }
}

static inline int vtCatSkin(int k) {
    switch (k) {
    case 0:  return MCS_CAT_TABBY;
    case 1:  return MCS_CAT_BLACK;
    case 2:  return MCS_CAT_RED;
    case 3:  return MCS_CAT_SIAMESE;
    case 4:  return MCS_CAT_BRITISH_SHORTHAIR;
    case 5:  return MCS_CAT_CALICO;
    case 6:  return MCS_CAT_PERSIAN;
    case 7:  return MCS_CAT_RAGDOLL;
    case 8:  return MCS_CAT_WHITE;
    case 9:  return MCS_CAT_JELLIE;
    default: return MCS_CAT_ALL_BLACK;
    }
}

static inline MCMOB_Skin vtMobSkin(int i, int role, uint sb) {
    if (role == 2) return mcMobSkin(MCM_IRON_GOLEM);
    if (role == 3) return mcMobSkin(vtCatSkin(int((sb >> 13) % 11u)));
    if (role == 1) return mcMobVillagerSkin(MCS_VILLAGER_BABY, MCS_VILLAGER_BABY_PLAINS, -1, -1);
    int prof = vtProfession((min(i, 2) + max(i - 3, 0) + int((sb >> 17) & 7u)) & 7);   // five adults, five trades
    float lv = float(vtPcg(uint(i) ^ (sb * 3u)) & 255u) / 256.0;
    int level = (prof < 0 || prof == MCS_VILLAGER_PROFESSION_NITWIT) ? -1
              : (lv < 0.55 ? MCS_VILLAGER_PROFESSION_LEVEL_STONE : (lv < 0.85 ? MCS_VILLAGER_PROFESSION_LEVEL_IRON : MCS_VILLAGER_PROFESSION_LEVEL_GOLD));
    return mcMobVillagerSkin(MCS_VILLAGER, MCS_VILLAGER_TYPE_PLAINS, prof, level);
}

// Mob i along the ray, nearer than tMax: its distance, world normal, unlit
// colour and where its light is read (the game lights a mob as a whole).
static inline bool vtMobHit(int i, float now, uint sb, float3 ro, float3 rd, float tMax, float pxAngle,
                            texture2d_array<float> mcSkins, texture2d_array<float> mcMaps,
                            thread float& tHit, thread float3& nW, thread float3& rgb, thread float3& probe) {
    VtMob m = vtMobAt(i, now, sb);
    int type = vtMobType(m.role);
    float3 lro, lrd;
    mcMobRay(ro, rd, m.at, m.head, lro, lrd);
    float2 bb = mcMobBounds(type, lro, lrd);
    if (!(bb.x < bb.y && bb.x < tMax)) return false;
    MCMOB_Pose pose = mcMobStill();
    pose.walk = m.walked * VT_ROLE_B[m.role].x;
    pose.speed = m.moving * VT_ROLE[m.role].w;
    pose.yaw = m.look;
    MCMOB_Skin skin = vtMobSkin(i, m.role, sb);
    MCMOB_Hit h = mcMobTrace(type, pose, skin, lro, lrd, tMax, mcSkins, mcMaps);
    if (!(h.t < tMax)) return false;
    tHit = h.t;
    nW = mcMobNormal(h.n, m.head);
    rgb = mcMobColor(type, h, skin, h.t * pxAngle * 16.0, mcSkins, mcMaps).rgb;
    probe = m.at + float3(0.0, 1.5, 0.0);
    return true;
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]],
                        constant LerpClock& clock [[buffer(1)]],
                        texture2d_array<float> mcTiles [[texture(8)]],
                        texture2d_array<float> mcSkins [[texture(10)]],
                        texture2d_array<float> mcMaps  [[texture(11)]]) {
    VtWorld W;
    W.tt = u.time * u.speed + u.seed * 977.0;
    W.now = u.time;
    W.seedBits = vtPcg(uint(u.seed * 4294967.0) + 17u);
    W.noiseOff = float2(float(W.seedBits & 255u), float((W.seedBits >> 8) & 255u)) * 0.37;
    VtLight l = vtLighting(vtSunFromClock(u, clock));

    // Camera: a slow orbit round the island from about 23° up, looking down
    // a little less than that, so the island sits low and the horizon high.
    float az = u.time * 0.018 * u.orbit + u.seed * TWO_PI;
    float el = 0.41 + 0.035 * sin(u.time * 0.011 + u.seed * 9.0);
    float look = el - 0.17;
    float dist = 60.0;
    float3 pivot = float3(0.0, 1.0, 0.0);
    float3 hz = float3(cos(az), 0.0, sin(az));
    float3 ro = pivot + dist * (hz * cos(el) + float3(0.0, sin(el), 0.0));
    float3 fwd = normalize(-hz * cos(look) - float3(0.0, sin(look), 0.0));
    float3 upHint = float3(0.0, 1.0, 0.0);
    float3 right = normalize(cross(upHint, fwd));
    lerpOrbit(u.yaw, u.pitch, u.magnify, pivot, upHint, ro, right, fwd);
    float3 up = cross(fwd, right);

    float minRes = min(u.resolution.x, u.resolution.y);
    float pxAngle = 2.0 / (minRes * VT_FOCAL);
    float2 uv = lerpUV(pos, u.resolution);
    float3 rd = normalize(uv.x * right + uv.y * up + VT_FOCAL * fwd);

    // Where this pixel meets the sea plane, with its screen derivatives taken
    // here in uniform control flow, for the water texture's filtering.
    float tw = rd.y < -1e-4 ? (VT_SEA - ro.y) / rd.y : 1e5;
    float2 seaUV = (ro + rd * min(tw, 1e5)).xz;
    float2 dudx = dfdx(seaUV), dudy = dfdy(seaUV);

    VtHit h = vtTrace(ro, rd, pxAngle, W, mcTiles);
    float3 fogC = vtFog(rd, l);
    float3 col;

    // Inhabitants, in front of whatever the march found. Narrow first: one
    // box round the roads' walking height, then a box round each mob that
    // holds it at any heading; only the nearest two the ray enters are traced.
    float tMob = min(h.hit ? h.t : 1e9, tw);
    float3 mobN = float3(0.0), mobC = float3(0.0), mobQ = float3(0.0);
    bool mob = false;
    float3 rinv = 1.0 / select(rd, float3(1e-7), abs(rd) < 1e-7);
    float3 tb1 = (float3(-13.0, 1.0, -13.0) - ro) * rinv, tb2 = (float3(14.0, 3.9, 14.0) - ro) * rinv;
    float3 tbn = min(tb1, tb2), tbf = max(tb1, tb2);
    if (max(max(tbn.x, tbn.y), tbn.z) < min(min(min(tbf.x, tbf.y), tbf.z), tMob)) {
        int c0 = -1, c1 = -1; float t0 = tMob, t1 = tMob;
        for (int i = 0; i < VT_MOBS; ++i) {
            VtMob m = vtMobAt(i, u.time, W.seedBits);
            float4 rb = VT_ROLE_B[m.role];
            float3 b1 = (m.at - float3(rb.y, 0.05, rb.y) - ro) * rinv;
            float3 b2 = (m.at + float3(rb.y, rb.z, rb.y) - ro) * rinv;
            float3 bn = min(b1, b2), bf = max(b1, b2);
            float tN = max(max(bn.x, bn.y), bn.z), tF = min(min(bf.x, bf.y), bf.z);
            if (tN > tF || tF <= 0.0) continue;
            if (tN < t0) { c1 = c0; t1 = t0; c0 = i; t0 = tN; }
            else if (tN < t1) { c1 = i; t1 = tN; }
        }
        if (c0 >= 0) {
            float tf; float3 nf, cf, qf;
            if (vtMobHit(c0, u.time, W.seedBits, ro, rd, tMob, pxAngle, mcSkins, mcMaps, tf, nf, cf, qf)
                || (c1 >= 0 && vtMobHit(c1, u.time, W.seedBits, ro, rd, tMob, pxAngle, mcSkins, mcMaps, tf, nf, cf, qf))) {
                tMob = tf; mobN = nf; mobC = cf; mobQ = qf; mob = true;
            }
        }
    }

    if (mob) {
        col = mobC * mcFaceShade(mobN) * vtLightAt(mobQ, int3(floor(mobQ)), l, float4(0.0), W);
        col = mix(col, fogC, smoothstep(90.0, 260.0, tMob));
    } else if (h.hit && h.t < tw) {
        col = vtShade(h, ro, rd, pxAngle, l, W, mcTiles, mcMaps);
        col = mix(col, fogC, smoothstep(90.0, 260.0, h.t));
    } else if (tw < 1e4) {
        // Water: the game's animated still water, tinted, over whatever lies
        // below — lit by sky light that loses a level a block of depth.
        float3 under;
        if (h.hit) under = vtShade(h, ro, rd, pxAngle, l, W, mcTiles, mcMaps);
        else under = float3(0.18, 0.18, 0.2) * mcLightmap(0.0, 3.0, l.bright, 0.0);
        int frame = mcFrame(MC_WATER_STILL, MC_WATER_STILL_FRAMES, MC_WATER_STILL_TICKS, u.time);
        float4 wt = mcTileAniso(mcTiles, frame, seaUV, dudx, dudy);
        float3 surf = wt.rgb * MC_WATER_TINT * mcLightmap(0.0, 15.0, l.bright, 0.0);
        col = mix(under, surf, wt.a);
        col = mix(col, fogC, smoothstep(90.0, 260.0, tw));
    } else {
        col = vtSky(rd, l, pxAngle, u.time, fract(u.seed * 7.0), mcSkins, mcMaps);
    }

    col = lerpDither(col, pos);
    return half4(half3(col), 1.0h);
}
