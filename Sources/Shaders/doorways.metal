// Doorways — Nether portals standing in the open, each onto another world.
// Original work for Lerping@Home, drawn with Minecraft's own textures.
//
// lerp-category: Minecraft
// lerp-requires: minecraft
//
// An obsidian portal frame stands on its own in a field. Walk round it and it
// is only a frame; look through its faint purple sheet and there is somewhere
// else on the other side: a snowy taiga under the moon, a desert at dusk, an
// ocean of small islands, the End's islands hanging in the void, a Nether
// fortress bridge under a netherrack roof hung with glowstone. The camera
// follows a track to the portal, steps through, and the world it stepped into
// has its own portal further on. It never ends and never turns back.
//
// The trick is per ray, not per frame: a ray that crosses a portal's opening
// carries on in the next world, so a portal seen through a portal shows a
// third, and the next world's light falls through the opening onto this one.
// Near each threshold a few blocks of the other world's ground have spilled
// through. Everything is a column of unit blocks walked with a 2D grid march;
// each hit reads its block's real texture once.
//
// Cost: the march works a 6×6 cell at a time. Entering a cell works out
// bounds on everything solid in it (a floor band, a ceiling band and two
// boxes: doorframe, tree); each step then jumps straight to the first place
// the ray could touch any of them, so columns are only walked where
// something might be hit, and a cell holding nothing in reach is crossed in
// one step. Fog closes fully by 30 blocks. Light is the game's: fixed shading
// by face under each world's sky light; nothing casts a shadow.
//
// lerp-param: speed    float 0.4 4    = 1.6 "Walk speed (blocks/s)"
// lerp-param: yaw      float -180 180 = 0   "Turn"
// lerp-param: pitch    float -60 60   = 0   "Tilt"
// lerp-param: magnify  float -1 1     = 0   "Zoom"
// lerp-param: light    float 0.3 2    = 1   "Brightness"
//
// lerp-preset: Stroll   speed=0.9
// lerp-preset: Hurry    speed=3.2

// --- Layout, in blocks.
constant int   DW_DI     = 26;          // doorway spacing along the walk
constant float DW_D      = 26.0;
constant float DW_EYE    = 2.3;         // eye height above the track
constant float DW_FOCAL  = 1.25;
constant float DW_HALF_W = 2.5;         // opening: 5 wide…
constant float DW_OPEN_H = 6.0;         // …6 tall
constant int   DW_STEPS  = 64;         // march steps: a column, or a whole empty 6×6 cell
constant float DW_FOG0   = 12.0;        // fog, in effective distance
constant float DW_FOG1   = 30.0;
constant float DW_LAVA   = -10.0;       // the Nether's lava sea
constant float DW_THROUGH = 0.55;       // distance already travelled counts this much after a doorway

// --- Blocks.
constant int B_GRASS = 0, B_DIRT = 1, B_STONE = 2, B_SAND = 3, B_SANDSTONE = 4, B_SNOW = 5,
             B_LOG = 6, B_LEAVES = 7, B_CACTUS = 8, B_FRAME = 9, B_PATH = 10, B_WATER = 11,
             B_PLANK = 12;

// --- Column contents: up to three solid runs [lo, hi).
constant int K_NONE = 0, K_GROUND = 1, K_SILL = 2, K_FRAME = 3, K_TREE = 4, K_CACTUS = 5,
             K_ISLAND = 6, K_CEIL = 7, K_PLANK = 8, K_HANG = 9;

// Curated orders: neighbours always differ in light and in kind.
constant int DW_ORDERS[4][6] = { {0, 1, 2, 4, 3, 5}, {0, 4, 2, 5, 1, 3},
                                 {3, 1, 0, 5, 2, 4}, {2, 4, 0, 1, 5, 3} };

struct DwBiome {
    int    mode;        // 0 land, 1 sea, 2 floating isles, 3 hung upside down
    int    top, sub;    // surface block, the few beneath it
    int    tree;        // 0 none, 1 broadleaf, 2 conifer, 3 cactus
    float  density;     // trees per tree cell
    float  amp;         // terrain relief
    float3 skyTop, skyHor, skyLow;
    float3 sunDir, sunCol, amb;
    float3 clim;        // temperature, downfall: the grass and foliage colormaps
    float3 skyL;        // sky light on a top face (the game's face shading does the rest)
    float3 spare;
    float  stars, sunSize, moon, lamp;   // lamp: the portals' own glow
};

// The six worlds, in one table every caller reads (a switch here was
// inlined at every call site).
constant DwBiome DW_BIOMES[6] = {
    // plains at golden hour, sun low ahead
    { 0, B_GRASS, B_DIRT, 1, 0.55, 8.0, float3(0.0394, 0.1190, 0.4009), float3(0.8933, 0.4563, 0.1989), float3(0.3494, 0.2373, 0.1726), float3(-0.7791, 0.2397, 0.5793), float3(2.4000, 1.7280, 1.0800), float3(0.1305, 0.1536, 0.2510), float3(0.8, 0.4, 0.0), float3(1.15, 0.95, 0.78), float3(0.0), 0.0, 0.035, 0.0, 0.25 },
    // snowy taiga under the stars and the moon
    { 0, B_SNOW, B_DIRT, 2, 0.6, 11.0, float3(0.0001, 0.0003, 0.0029), float3(0.0078, 0.0203, 0.0707), float3(0.0029, 0.0063, 0.0203), float3(0.6291, 0.4566, 0.6291), float3(0.2100, 0.2688, 0.4200), float3(0.0092, 0.0155, 0.0392), float3(0.0, 0.4, 0.0), float3(0.10, 0.13, 0.24), float3(0.0), 1.0, 0.05, 1.0, 1.2 },
    // desert at dusk
    { 0, B_SAND, B_SANDSTONE, 3, 0.4, 6.0, float3(0.0177, 0.0154, 0.1190), float3(0.8524, 0.2373, 0.1190), float3(0.4009, 0.1483, 0.1056), float3(0.7841, 0.2614, 0.5629), float3(2.3000, 1.3340, 0.8280), float3(0.1747, 0.0994, 0.1342), float3(2.0, 0.0, 0.0), float3(1.00, 0.72, 0.60), float3(0.0), 0.0, 0.045, 0.0, 0.5 },
    // an ocean of small islands at blue hour
    { 1, B_GRASS, B_DIRT, 1, 0.5, 0.0, float3(0.0063, 0.0230, 0.1190), float3(0.7176, 0.3494, 0.4563), float3(0.1483, 0.1332, 0.2684), float3(-0.6191, 0.0999, 0.7789), float3(1.7000, 1.0540, 0.9860), float3(0.1088, 0.1187, 0.2427), float3(0.5, 0.5, 0.0), float3(0.75, 0.62, 0.75), float3(0.0), 0.0, 0.04, 0.0, 0.7 },
    // the End: end stone islands and chorus in the void
    { 2, B_GRASS, B_DIRT, 4, 0.6, 0.0, float3(0.0008, 0.0002, 0.0063), float3(0.0707, 0.0203, 0.1483), float3(0.0004, 0.0002, 0.0029), float3(-0.5515, 0.3810, 0.7420), float3(0.7410, 0.6840, 0.9500), float3(0.0552, 0.0381, 0.1460), float3(0.5, 0.5, 0.0), float3(0.42, 0.36, 0.55), float3(0.0), 0.0, 0.0, 0.0, 1.1 },
    // the Nether: a fortress bridge under the netherrack roof, lava below
    { 3, B_GRASS, B_DIRT, 1, 0.5, 0.0, float3(0.0300, 0.0040, 0.0030), float3(0.0600, 0.0080, 0.0050), float3(0.1600, 0.0350, 0.0100), float3(0.3015, -0.9045, 0.3015), float3(1.8000, 0.7500, 0.2000), float3(0.1600, 0.0800, 0.0600), float3(2.0, 0.0, 0.0), float3(0.55, 0.36, 0.28), float3(0.0), 0.0, 0.0, 0.0, 0.6 },
};

static inline constant DwBiome& dwBiome(int i) { return DW_BIOMES[i]; }

// --- The walk. Door k stands across the track at global z = k·D; its opening
// is centred on x = dwDoorX(k). World w lies between doors w and w+1, in its
// own local z (door w at zl = 0.5, door w+1 at zl = D + 0.5).

static inline float dwDoorX(int k, float salt) {
    return floor((hash11(float(k) * 0.7317 + salt) - 0.5) * 14.0) + 0.5;
}
static inline float dwDoorS(int k, float salt) {
    return (hash11(float(k) * 1.913 + salt + 3.1) - 0.5) * 0.5;
}

struct DwWorld {
    int     w;
    int     bi;              // biome index
    int     biA, biB;        // the worlds through door w and door w+1
    int     mode, top, sub, tree;
    float   density, amp;
    float2  off;
    float   cxA, cxB, sA, sB;
    float   yMax, yMin;
    float   yFog, yFogLo;    // sky rays are fogged up to where they pass these heights
    float   treeTop;         // tallest tree, from its base to its top
};

static inline int dwBiomeOf(int w, float seed) {
    int order = int(seed * 4.0) & 3;
    int start = int(seed * 24.0) % 6;
    int k = (w + start) % 6;
    if (k < 0) k += 6;
    return DW_ORDERS[order][k];
}

static inline DwWorld dwWorld(int w, float seed) {
    DwWorld W;
    float salt = seed * 37.0;
    W.w = w;
    W.bi = dwBiomeOf(w, seed);
    W.biA = dwBiomeOf(w - 1, seed);
    W.biB = dwBiomeOf(w + 1, seed);
    constant DwBiome& b = dwBiome(W.bi);
    W.mode = b.mode; W.top = b.top; W.sub = b.sub; W.tree = b.tree;
    W.density = b.density; W.amp = b.amp;
    W.off = float2(hash11(float(w) * 0.371 + salt), hash11(float(w) * 0.917 + salt + 1.7)) * 400.0;
    W.cxA = dwDoorX(w, salt);     W.sA = dwDoorS(w, salt);
    W.cxB = dwDoorX(w + 1, salt); W.sB = dwDoorS(w + 1, salt);
    W.yMin = -1e4; W.yMax = 1e4;
    // Nothing in a world stands higher than its highest ground plus its
    // tallest tree, so a ray rising past that has nothing left to meet.
    // (The noise peaks at 1; a conifer tops out 9 above its base, a
    // broadleaf 6, a cactus 3; a floating island's top is at most 10 and its
    // root no lower than -29.)
    W.treeTop = W.tree == 2 ? 9.0 : (W.tree == 3 ? 3.0 : (W.tree == 4 ? 8.0 : 6.0));
    if (W.mode == 0) W.yMax = max(8.0, floor(0.58 * W.amp * 2.2 + 0.5) + W.treeTop);
    if (W.mode == 1) W.yMax = 6.0 + W.treeTop;
    if (W.mode == 2) { W.yMax = 10.0 + W.treeTop; W.yMin = -30.0; }
    if (W.mode == 3) W.yMin = -1.0;
    // How far a ray into the sky is fogged: to where it rises past this.
    float treeFog = W.tree == 2 ? 10.0 : (W.tree == 3 ? 4.0 : 7.0);
    W.yFog = 1e4; W.yFogLo = W.yMin;
    if (W.mode == 2) W.yFogLo = -32.0;
    if (W.mode == 3) W.yFogLo = DW_LAVA;
    if (W.mode == 0) W.yFog = max(0.0, 0.58 * W.amp * 2.2) + 1.0 + treeFog;
    if (W.mode == 1) W.yFog = 7.0 + treeFog;
    if (W.mode == 2) W.yFog = 11.0 + treeFog;
    return W;
}

// The track: a cubic through each doorway's centre at that door's slope.
static inline float dwPathX(thread const DwWorld& W, float z, thread float& slope) {
    float s = (z - 0.5) / DW_D;
    if (s <= 0.0) { slope = W.sA; return W.cxA + W.sA * (z - 0.5); }
    if (s >= 1.0) { slope = W.sB; return W.cxB + W.sB * (z - 0.5 - DW_D); }
    float s2 = s * s, s3 = s2 * s;
    float x = (2.0 * s3 - 3.0 * s2 + 1.0) * W.cxA + (s3 - 2.0 * s2 + s) * DW_D * W.sA
            + (-2.0 * s3 + 3.0 * s2) * W.cxB + (s3 - s2) * DW_D * W.sB;
    slope = ((6.0 * s2 - 6.0 * s) * W.cxA + (3.0 * s2 - 4.0 * s + 1.0) * DW_D * W.sA
           + (-6.0 * s2 + 6.0 * s) * W.cxB + (3.0 * s2 - 2.0 * s) * DW_D * W.sB) / DW_D;
    return x;
}

// How far a column centre is from the track (dp) and from either doorway (dd).
static inline void dwClear(thread const DwWorld& W, float2 p, thread float& dp, thread float& dd) {
    float sl;
    dp = abs(p.x - dwPathX(W, p.y, sl));
    float zA = (p.y - 0.5) * 1.3, zB = (p.y - 0.5 - DW_D) * 1.3;
    dd = 99.0;
    if (abs(zA) < 16.0) dd = length(float2(p.x - W.cxA, zA));
    if (abs(zB) < 16.0) dd = min(dd, length(float2(p.x - W.cxB, zB)));
}
static inline float dwWild(float dp, float dd) {   // 0 on the track and round doors, 1 in the wild
    if (dp >= 9.0 && dd >= 11.0) return 1.0;
    return smoothstep(2.5, 9.0, dp) * smoothstep(4.5, 11.0, dd);
}

// sin(x) to about 0.001: wrap the phase in cycles, then a parabola with one
// correction. Metal's sin spends most of its time reducing the large
// arguments the world offsets make.
static inline float dwSin(float x) {
    float t = fract(x * 0.15915494 + 0.5) * 2.0 - 1.0;     // x = πt, mod 2π
    float y = 4.0 * t * (1.0 - abs(t));                    // ≈ sin(πt)
    y = 0.225 * (y * abs(y) - y) + y;
    return y;
}

static inline float dwNoise(thread const DwWorld& W, float2 p) {
    // Three rotated sines at unrelated angles and scales: cheap enough to run
    // at every column of the march, and once quantised to whole blocks it
    // reads as rolling ground rather than waves.
    float a = dwSin(dot(p, float2(0.061, 0.032)) + W.off.x);
    float b = dwSin(dot(p, float2(-0.027, 0.074)) + W.off.y);
    float c = dwSin(dot(p, float2(0.143, -0.118)) + W.off.x * 1.7);
    return 0.5 + 0.21 * a + 0.19 * b + 0.10 * c;
}

// Natural surface height (land, sea), island (floating) or ceiling (hung).
static inline float dwSurface(thread const DwWorld& W, float n, float wild) {
    int mode = W.mode;
    if (mode == 0) return floor(mix(0.0, (n - 0.42) * W.amp * 2.2, wild) + 0.5);
    if (mode == 1) return floor(mix(-3.0, -5.0 + 11.0 * smoothstep(0.46, 0.82, n), wild) + 0.5);
    if (mode == 3) return floor(mix(9.0, max(9.0 - (n - 0.40) * 15.0, 3.0), wild) + 0.5);
    return 0.0;
}

struct DwCol {
    float4 s0, s1, s2;    // solid runs: (lo, hi, aux, kind)
};

static inline void dwPut(thread float4& r, float lo, float hi, int kind, float aux) {
    r = float4(lo, hi, aux, float(kind));
}

constant int DW_ISLE = 18;

// One 6×6 cell of a world, as the march sees it. The march works a cell at a
// time: everything here is worked out once on entering the cell, every pixel
// of a SIMD group doing the same work together, and each column inside is
// then a few multiply-adds. The terrain noise and the signed offset from the
// track are interpolated from the cell's corners, so the cell's highest ground
// is exactly its highest corner. Tree cells are these cells, so each tree lies
// wholly inside one.
struct DwCell {
    int2   M;
    float4 nq, pq;     // corner noise; corner signed track offset
    float2 px;         // the track's x at the cell's two z edges (shared along a row)
    float4 tree;       // trunk x, trunk z, base, height (height 0: no tree)
    int2   I;          // the 18×18 island cell…
    float4 isle;       // …and its floating island: centre, radius, level
    // Bounds on everything solid in the cell: a floor band [fB, fT), a
    // ceiling band [cB, inf) and one box (tree, island or doorframe;
    // lo > hi for none), world-local.
    float  fB, fT, cB;
    float3 lo, hi;
};

static inline float dwBilerp(float4 q, float2 f) { return mix(mix(q.x, q.y, f.x), mix(q.z, q.w, f.x), f.y); }

// Distance to the nearer doorway, as a rounded box (cheaper than a circle).
static inline float dwDoorDist(thread const DwWorld& W, float2 p) {
    float2 a = abs(float2(p.x - W.cxA, (p.y - 0.5) * 1.3));
    float2 b = abs(float2(p.x - W.cxB, (p.y - 0.5 - DW_D) * 1.3));
    return min(max(a.x, a.y) + 0.3 * min(a.x, a.y), max(b.x, b.y) + 0.3 * min(b.x, b.y));
}

// The floating world's islands: at most one per 18×18 cell, kept inside it
// and clear of the track, each at its own height with a dome on top and a
// tapering root of rock below.
static inline float4 dwIsleOf(int2 M, thread const DwWorld& W) {
    int2 I = int2(floor(float2(M * 6) / float(DW_ISLE)));
    float2 h = hash22(float2(I) * 1.13 + W.off);
    float2 g = hash22(float2(I) * 0.71 + W.off.yx + 5.0);
    float r = 3.5 + 4.5 * g.x;
    float2 ctr = float2(I * DW_ISLE) + 0.5 * float(DW_ISLE) + (h - 0.5) * (float(DW_ISLE) - 2.0 * r - 2.0);
    float lvl = floor((g.y - 0.5) * 18.0);
    float dp, dd;
    dwClear(W, ctr, dp, dd);
    bool ok = h.x * 0.6 + g.y * 0.4 < 0.8 && dp > r + 3.0 && dd > r + 5.0;
    return ok ? float4(ctr, r, lvl) : float4(0.0);
}

static inline float2 dwIslandAt(float4 is, float2 p, thread const DwWorld& W) {
    if (is.z <= 0.0) return float2(-1.0, 1.0);
    float2 q = p - is.xy;
    float hc = hash21(floor(p) + W.off);
    float f = 1.0 - length(q) / is.z - 0.12 * hc;
    if (f <= 0.0) return float2(-1.0, 1.0);
    float top = is.w + floor(f * 2.6);
    float bot = top - 1.0 - floor(f * f * (3.0 + 1.8 * is.z) + hc * 1.5);
    return float2(top, bot);
}

static inline float dwTreeH(int2 T, thread const DwWorld& W) {
    if (W.tree == 2) return 6.0 + floor(hash21(float2(T) * 2.3 + W.off) * 3.0);
    if (W.tree == 3) return 1.0 + floor(hash21(float2(T) * 2.9 + W.off) * 3.0);
    if (W.tree == 4) return 4.0 + floor(hash21(float2(T) * 1.9 + W.off) * 4.0);
    return 4.0 + floor(hash21(float2(T) * 1.7 + W.off) * 2.0);
}

static inline void dwCellTree(thread DwCell& d, thread const DwWorld& W) {
    d.tree = float4(0.0);
    int2 T = d.M;
    float2 h = hash22(float2(T) + W.off * 1.31);
    if (h.x > W.density || W.tree == 0) return;
    int2 trunk = T * 6 + 2 + int2(h * 7.0) % 2;
    float2 f = (float2(trunk - T * 6) + 0.5) / 6.0;
    float wild = dwWild(abs(dwBilerp(d.pq, f)), dwDoorDist(W, float2(trunk) + 0.5));
    if (wild < 0.97) return;
    float tb;
    if (W.mode == 2) {
        float2 isl = dwIslandAt(d.isle, float2(trunk) + 0.5, W);
        if (isl.x < isl.y + 1.0) return;
        tb = isl.x;
    } else {
        tb = dwSurface(W, dwBilerp(d.nq, f), wild);
        if (W.mode == 1 && tb < 1.0) return;
    }
    d.tree = float4(float2(trunk), tb, dwTreeH(T, W));
}


// Entering cell M: its corner noise (only the two corners across the edge
// just crossed are new when it is the next cell along), its track corners
// (the track's x is shared along a row), its island (shared by the 3×3
// cells of an island cell) and tree, then the bounds the march skips by.
// Doorway distance is bounded from the cell's centre (it changes by at most
// 1.3·3.25 over a cell); wildness grows away from the track and the doors.
static inline void dwBoxAdd(thread DwCell& d, float3 lo, float3 hi) {
    d.lo = min(d.lo, lo); d.hi = max(d.hi, hi);
}

static inline void dwCellEnter(thread DwCell& d, int2 M, thread const DwWorld& W, float yLow) {
    int2 dm = M - d.M;
    float2 a = float2(M * 6);
    int mode = W.mode;
    if (mode != 2) {
        bool step = abs(dm.x) + abs(dm.y) == 1;
        bool mx = dm.x != 0;
        float2 P1 = step ? a + (mx ? float2(dm.x > 0 ? 6.0 : 0.0, 0.0) : float2(0.0, dm.y > 0 ? 6.0 : 0.0)) : a;
        float2 P2 = step ? P1 + (mx ? float2(0.0, 6.0) : float2(6.0, 0.0)) : a + float2(6.0, 0.0);
        float n1 = dwNoise(W, P1), n2 = dwNoise(W, P2);
        float4 o = d.nq;
        if (step) {
            d.nq = mx ? (dm.x > 0 ? float4(o.y, n1, o.w, n2) : float4(n1, o.x, n2, o.z))
                      : (dm.y > 0 ? float4(o.z, o.w, n1, n2) : float4(n1, n2, o.x, o.y));
        } else {
            d.nq = float4(n1, n2, dwNoise(W, a + float2(0.0, 6.0)), dwNoise(W, a + 6.0));
        }
    }
    if (dm.y != 0) {
        float sl;
        d.px = float2(dwPathX(W, a.y, sl), dwPathX(W, a.y + 6.0, sl));
    }
    d.M = M;
    d.pq = float4(a.x - d.px.x, a.x + 6.0 - d.px.x, a.x - d.px.y, a.x + 6.0 - d.px.y);
    if (mode == 2) {
        int2 I = int2(floor(float2(M) / 3.0));
        if (any(I != d.I)) { d.I = I; d.isle = dwIsleOf(M, W); }
    }

    float4 pq = d.pq;
    float pmin = min(min(pq.x, pq.y), min(pq.z, pq.w)), pmax = max(max(pq.x, pq.y), max(pq.z, pq.w));
    float dpMin = (pmin < 0.0 && pmax > 0.0) ? 0.0 : min(abs(pmin), abs(pmax));
    float dpMax = max(abs(pmin), abs(pmax));
    float ddC = dwDoorDist(W, a + 3.0);
    float wildMax = dwWild(dpMax, ddC + 4.6);

    d.fB = -1e4; d.fT = -1e4; d.cB = 1e4;
    d.lo = float3(1e9); d.hi = float3(-1e9);
    bool door = false;
    if (M.y == 0 || M.y == DW_DI / 6) {
        float cx = floor(M.y == 0 ? W.cxA : W.cxB);
        float zr = M.y == 0 ? 0.0 : DW_D;
        if (a.x <= cx + 3.0 && a.x + 5.0 >= cx - 3.0) {
            dwBoxAdd(d, float3(cx - 3.0, -1.0, zr), float3(cx + 4.0, 8.0, zr + 1.0));
            door = true;
        }
    }
    bool deck = dpMin < 1.6 || ddC < 9.2 || door;
    float n = max(max(d.nq.x, d.nq.y), max(d.nq.z, d.nq.w));
    if (mode == 0) {
        d.fT = floor(max(0.0, (n - 0.42) * W.amp * 2.2 * wildMax) + 0.5);
    } else if (mode == 1) {
        d.fT = max(deck ? 0.0 : -0.15, floor(max(-3.0, -5.0 + 11.0 * smoothstep(0.46, 0.82, n)) + 0.5));
    } else if (mode == 2) {
        if (deck) { d.fB = -2.0; d.fT = 0.0; }
        float4 is = d.isle;
        if (is.z > 0.0) {
            float2 lo = max(a, floor(is.xy - is.z - 1.0));
            float2 hi = min(a + 6.0, ceil(is.xy + is.z + 1.0));
            if (all(lo < hi))
                dwBoxAdd(d, float3(lo.x, is.w - 6.0 - floor(1.8 * is.z), lo.y), float3(hi.x, is.w + 2.0, hi.y));
        }
    } else {
        if (deck) { d.fB = -1.0; d.fT = 0.0; }
        float X = min(9.0, max(9.0 - (n - 0.40) * 15.0, 3.0));
        d.cB = floor(9.0 - (9.0 - X) * wildMax + 0.5);
    }
    // The tree, unless there is none to be had or the ray passes above
    // anything one could reach: a tree stands on ground no higher than the
    // cell's (on its island in the floating world), and in the sea only on
    // land.
    float base = mode == 2 ? d.isle.w + 2.0 : d.fT;
    bool reach = mode == 3 || yLow < base + W.treeTop;
    bool land = mode == 0 || mode == 3 || (mode == 1 && d.fT >= 1.0) || (mode == 2 && d.isle.z > 0.0);
    d.tree = float4(0.0);
    if (W.tree != 0 && wildMax >= 0.97 && land && reach) dwCellTree(d, W);
    if (d.tree.w > 0.0) {
        float2 t = d.tree.xy;
        float tb = d.tree.z, H = d.tree.w;
        float r = W.tree == 3 ? 0.0 : 2.0;
        float ylo = mode == 3 ? tb - H - 1.0 : tb;
        float yhi = mode == 3 ? tb : tb + H + 1.0;
        dwBoxAdd(d, float3(t.x - r, ylo, t.y - r), float3(t.x + r + 1.0, yhi, t.y + r + 1.0));
    }
}

static inline void dwTreeColumn(int2 c, thread const DwCell& cd, thread const DwWorld& W, thread float4& run) {
    int2 d = abs(c - int2(cd.tree.xy));
    int cheb = max(d.x, d.y);
    if (cheb > 2) return;
    bool corner = d.x == d.y && cheb > 0;
    float tb = cd.tree.z, H = cd.tree.w;
    float r = corner && cheb == 2 ? hash21(float2(c) + W.off * 0.7) : 0.0;
    if (W.tree == 3) {                          // cactus: one column
        if (cheb == 0) dwPut(run, tb, tb + H, K_CACTUS, 0.0);
        return;
    }
    if (W.mode == 3) {                          // hung: everything mirrored down from the ceiling
        if (cheb == 0)      dwPut(run, tb - H - 1.0, tb, K_HANG, tb - H);
        else if (cheb == 1) dwPut(run, tb - H - (corner ? 0.0 : 1.0), tb - H + 2.0, K_HANG, 1e4);
        else if (!corner || r < 0.4) dwPut(run, tb - H, tb - H + 2.0, K_HANG, 1e4);
        return;
    }
    if (W.tree == 4) {                          // chorus: a stalk, a flower, short arms
        if (cheb == 0) dwPut(run, tb, tb + H, K_TREE, tb + H - 1.0);
        else if (cheb == 1 && !corner && hash21(float2(c) + W.off * 0.7) < 0.5)
            dwPut(run, tb + H - 4.0, tb + H - 2.0, K_TREE, tb + H - 3.0);
        return;
    }
    if (W.tree == 2) {                          // conifer: a stepped cone
        if (cheb == 0)      dwPut(run, tb, tb + H + 1.0, K_TREE, tb + H - 1.0);
        else if (cheb == 1) dwPut(run, tb + 2.0, tb + H - (corner ? 1.0 : 0.0), K_TREE, -1e4);
        else if (!corner)   dwPut(run, tb + 2.0, tb + max(H - 4.0, 3.0), K_TREE, -1e4);
        return;
    }
    // broadleaf
    if (cheb == 0)      dwPut(run, tb, tb + H + 1.0, K_TREE, tb + H - 1.0);
    else if (cheb == 1) dwPut(run, tb + H - 2.0, tb + H + (corner ? 0.0 : 1.0), K_TREE, -1e4);
    else if (!corner || r < 0.45) dwPut(run, tb + H - 2.0, tb + H, K_TREE, -1e4);
}

// Track distance of column c, which lies in cell d.
static inline float dwTrackDist(int2 c, thread const DwCell& d) {
    return abs(dwBilerp(d.pq, (float2(c - d.M * 6) + 0.5) / 6.0));
}

// Everything solid in column c (world-local), which lies in cell d.
static inline DwCol dwColumn(int2 c, thread const DwCell& d, thread const DwWorld& W) {
    DwCol k;
    k.s0 = k.s1 = k.s2 = float4(0.0);
    int mode = W.mode;

    // The doorframes: identical in both worlds they join.
    bool rowA = c.y == 0, rowB = c.y == DW_DI;
    if (rowA || rowB) {
        float cx = rowA ? W.cxA : W.cxB;
        int dx = c.x - int(floor(cx));
        if (abs(dx) <= 3) {
            dwPut(k.s0, mode == 0 || mode == 1 ? -1e4 : -1.0, 0.0, K_SILL, 0.0);
            if (abs(dx) == 3) dwPut(k.s1, 0.0, 7.0, K_FRAME, 0.0);
            else              dwPut(k.s1, 6.0, 7.0, K_FRAME, 0.0);
            return k;
        }
    }

    float2 f = (float2(c - d.M * 6) + 0.5) / 6.0;
    float dp = abs(dwBilerp(d.pq, f));
    float dd = dwDoorDist(W, float2(c) + 0.5);
    float n = dwBilerp(d.nq, f);
    float wild = dwWild(dp, dd);
    bool deck = dp < 1.6 || dd < 4.6;

    if (mode == 0) {
        float h = dwSurface(W, n, wild);
        dwPut(k.s0, -1e4, h, K_GROUND, h);
    } else if (mode == 1) {
        float h = dwSurface(W, n, wild);
        dwPut(k.s0, -1e4, max(h, -0.15), K_GROUND, h);
        if (deck) dwPut(k.s2, -1.0, 0.0, K_PLANK, 0.0);
    } else if (mode == 2) {
        if (deck) dwPut(k.s0, -2.0, 0.0, K_PLANK, 0.0);
        else {
            float2 isl = dwIslandAt(d.isle, float2(c) + 0.5, W);
            if (isl.x > isl.y) dwPut(k.s2, isl.y, isl.x, K_ISLAND, isl.x);
        }
    } else {
        float cb = dwSurface(W, n, wild);
        dwPut(k.s0, cb, 1e4, K_CEIL, cb);
        if (deck) dwPut(k.s2, -1.0, 0.0, K_PLANK, 0.0);
    }
    if (wild > 0.5 && d.tree.w > 0.0) dwTreeColumn(c, d, W, k.s1);
    return k;
}

// The earliest t >= tIn at which the ray could touch something in the cell
// (1e9: never). `how`: 0 already touching, 1 from above, 2 from below, 3 a
// box side.
static inline float dwFirst(thread const DwCell& B, float3 ro, float3 rd, float3 inv3, float tIn,
                            float zOff, thread int& how) {
    float y = ro.y + rd.y * tIn;
    float best = 1e9; how = 3;
    // floor band [fB, fT)
    if (y >= B.fB && y < B.fT) { how = 0; return tIn; }
    if (rd.y < 0.0 && y >= B.fT) { float t = (B.fT - ro.y) * inv3.y; if (t < best) { best = t; how = 1; } }
    if (rd.y > 0.0 && y < B.fB)  { float t = (B.fB - ro.y) * inv3.y; if (t < best) { best = t; how = 2; } }
    // ceiling band [cB, inf)
    if (y >= B.cB) { how = 0; return tIn; }
    if (rd.y > 0.0) { float t = (B.cB - ro.y) * inv3.y; if (t < best) { best = t; how = 2; } }
    // the box
    float3 o = ro; o.z -= zOff;
    float3 t1 = (B.lo - o) * inv3, t2 = (B.hi - o) * inv3;
    float3 tn3 = min(t1, t2), tf3 = max(t1, t2);
    float tn = max(max(tn3.x, tn3.y), tn3.z), tf = min(min(tf3.x, tf3.y), tf3.z);
    if (B.lo.x < B.hi.x && tf >= max(tn, tIn) && tn < best) {
        if (tn <= tIn) { how = 0; return tIn; }
        best = tn;
        how = (tn3.y >= tn3.x && tn3.y >= tn3.z) ? (rd.y < 0.0 ? 1 : 2) : 3;
    }
    return best;
}


// ---------------------------------------------------------------------------
// Textures: each block is the game's own. Which tile a face shows (and its
// tint, and an overlay for the grass side) depends on the block and on the
// world whose palette it wears: the End's ground is end stone and its trees
// chorus, the Nether's netherrack, glowstone and nether bricks.

static inline int dwTex(int id, int face, int bi, float now, float3 grass, float3 foliage,
                        thread float3& tint, thread int& over, thread float3& otint, thread bool& glow) {
    tint = float3(1.0); over = -1; otint = float3(1.0); glow = false;
    if (bi == 4) {
        if (id == B_LOG)    return MC_CHORUS_PLANT;
        if (id == B_LEAVES) return MC_CHORUS_FLOWER;
        if (id == B_PLANK)  return MC_PURPUR_BLOCK;
        if (id == B_FRAME)  return MC_OBSIDIAN;
        return MC_END_STONE;
    }
    if (bi == 5) {
        if (id == B_LEAVES) { glow = true; return MC_GLOWSTONE; }
        if (id == B_PLANK)  return MC_NETHER_BRICKS;
        if (id == B_FRAME)  return MC_OBSIDIAN;
        return MC_NETHERRACK;
    }
    bool spruce = bi == 1;
    switch (id) {
    case B_GRASS:
        if (face == 0) { tint = grass; return MC_GRASS_BLOCK_TOP; }
        if (face == 1) { over = MC_GRASS_BLOCK_SIDE_OVERLAY; otint = grass; return MC_GRASS_BLOCK_SIDE; }
        return MC_DIRT;
    case B_SNOW:      return face == 0 ? MC_SNOW : (face == 1 ? MC_GRASS_BLOCK_SNOW : MC_DIRT);
    case B_DIRT:      return MC_DIRT;
    case B_SAND:      return MC_SAND;
    case B_SANDSTONE: return face == 0 ? MC_SANDSTONE_TOP : (face == 1 ? MC_SANDSTONE : MC_SANDSTONE_BOTTOM);
    case B_PATH:      return face == 0 ? MC_DIRT_PATH_TOP : (face == 1 ? MC_DIRT_PATH_SIDE : MC_DIRT);
    case B_LOG:
        if (face == 1) return spruce ? MC_SPRUCE_LOG : MC_OAK_LOG;
        return spruce ? MC_SPRUCE_LOG_TOP : MC_OAK_LOG_TOP;
    case B_LEAVES:
        tint = spruce ? mcFromSRGB(float3(0.3804, 0.6000, 0.3804)) : foliage;   // spruce: #619961
        return spruce ? MC_SPRUCE_LEAVES : MC_OAK_LEAVES;
    case B_CACTUS:    return face == 0 ? MC_CACTUS_TOP : (face == 1 ? MC_CACTUS_SIDE : MC_CACTUS_BOTTOM);
    case B_FRAME:     return MC_OBSIDIAN;
    case B_WATER:
        tint = MC_WATER_TINT;
        return mcFrame(MC_WATER_STILL, MC_WATER_STILL_FRAMES, MC_WATER_STILL_TICKS, now);
    case B_PLANK:     return MC_OAK_PLANKS;
    default:          return MC_STONE;
    }
}

// ---------------------------------------------------------------------------
// Which block a hit is, and whose palette it wears (a threshold block that
// has spilled through from the neighbouring world wears that world's).

static inline int dwTopBlock(int bi) {
    constant DwBiome& b = dwBiome(bi);
    if (b.mode == 1 || b.mode == 3) return B_PLANK;
    return b.top;
}

static inline int dwMaterial(float4 run, int y, int2 c, thread const DwWorld& W, thread const DwCell& cd,
                      thread int& palette, thread bool& flip) {
    palette = W.bi; flip = false;
    int kind = int(run.w + 0.5);
    float aux = run.z;
    bool surface = false;
    int id = B_STONE;
    switch (kind) {
    case K_FRAME: return B_FRAME;
    case K_SILL:  if (y == -1) return B_FRAME; aux = 0.0; // fallthrough to ground below the sill
    case K_GROUND: {
        if (W.mode == 1 && float(y) >= aux) return B_WATER;
        int depth = int(aux) - 1 - y;
        bool beach = W.mode == 1 && aux <= 1.0;
        int top = W.mode == 1 ? (beach ? B_SAND : B_GRASS) : W.top;
        int sub = W.mode == 1 ? (beach ? B_SAND : B_DIRT) : W.sub;
        id = depth <= 0 ? top : (depth <= 3 ? sub : (W.sub == B_SANDSTONE && depth < 7 ? B_SANDSTONE : B_STONE));
        surface = depth <= 0;
        if (surface && W.mode == 0) {
            float dp = dwTrackDist(c, cd);
            if (dp < 1.3 && hash21(float2(c) * 0.71 + 2.0) < 0.9 - 0.4 * saturate(dp - 0.6))
                id = W.top == B_SAND ? B_SANDSTONE : B_PATH;
        }
        break;
    }
    case K_ISLAND: {
        int depth = int(run.y) - 1 - y;
        id = depth <= 0 ? B_GRASS : (depth <= 2 ? B_DIRT : B_STONE);
        surface = depth <= 0;
        break;
    }
    case K_CEIL: {
        int depth = y - int(aux);
        flip = true;
        id = depth <= 0 ? B_GRASS : (depth <= 2 ? B_DIRT : B_STONE);
        return id;
    }
    case K_PLANK:  id = B_PLANK; surface = true; break;
    case K_CACTUS: return B_CACTUS;
    case K_TREE:   return float(y) < aux ? B_LOG : B_LEAVES;
    case K_HANG:   flip = true; return float(y) >= aux ? B_LOG : B_LEAVES;
    default: break;
    }
    // Spill: near a threshold, some of the other world's ground has come through.
    if (surface) {
        float2 p = float2(c) + 0.5;
        float zA = p.y - 0.5, zB = DW_D + 0.5 - p.y;
        float r = hash21(float2(c) * 1.37 + W.off);
        if (zA > 0.0 && zA < 5.0 && abs(p.x - W.cxA) < DW_HALF_W + 0.2 * zA && r < 1.05 - zA * 0.22) {
            palette = W.biA; id = dwTopBlock(W.biA);
        } else if (zB > 0.0 && zB < 5.0 && abs(p.x - W.cxB) < DW_HALF_W + 0.2 * zB && r < 1.05 - zB * 0.22) {
            palette = W.biB; id = dwTopBlock(W.biB);
        }
    }
    return id;
}

// ---------------------------------------------------------------------------
// The march. Columns are walked in the floor plane; each holds up to three
// solid runs, and a ray meets a run on a side (entering the column within
// it), its top (descending through hi) or its underside (rising through lo).

struct DwHit {
    float  t;
    float3 n;
    float4 run;      // the solid run that was hit
};

// Branch-free: every lane of a SIMD group does the same arithmetic.
static inline void dwRunHit(float4 r, float yA, float yB, float3 ro, float invy, float tIn, float3 sideN,
                            thread float& tHit, thread float3& nHit, thread float4& run) {
    bool side = yA >= r.x && yA < r.y;
    bool top = yA >= r.y && yB < r.y;           // only a descending ray can do this
    bool bot = yA < r.x && yB >= r.x;           // only a rising one this
    float th = side ? tIn : (top ? (r.y - ro.y) * invy : (bot ? (r.x - ro.y) * invy : 1e9));
    th = r.w > 0.5 ? th : 1e9;
    bool take = th < tHit;
    tHit = take ? th : tHit;
    nHit = take ? (side ? sideN : float3(0.0, top ? 1.0 : -1.0, 0.0)) : nHit;
    run = take ? r : run;
}
static inline bool dwColumnHit(thread const DwCol& k, float3 ro, float3 rd, float tIn, float tOut,
                               float3 sideN, thread float& tHit, thread float3& nHit, thread float4& run) {
    float yA = ro.y + rd.y * tIn, yB = ro.y + rd.y * tOut;
    float invy = 1.0 / rd.y;
    tHit = 1e9;
    dwRunHit(k.s0, yA, yB, ro, invy, tIn, sideN, tHit, nHit, run);
    dwRunHit(k.s1, yA, yB, ro, invy, tIn, sideN, tHit, nHit, run);
    dwRunHit(k.s2, yA, yB, ro, invy, tIn, sideN, tHit, nHit, run);
    return tHit < 1e8;
}

// Where the ray next passes through an opening of this world's two doors.
static inline float dwPortal(float3 ro, float3 rd, thread const DwWorld& W, int zOff, float tMin,
                             thread int& dir) {
    float best = 1e9; dir = 0;
    if (abs(rd.z) < 1e-6) return best;
    for (int k = 0; k < 2; ++k) {
        float zp = float(zOff) + (k == 0 ? 0.5 : DW_D + 0.5);
        float cx = k == 0 ? W.cxA : W.cxB;
        float t = (zp - ro.z) / rd.z;
        if (t > tMin + 1e-4 && t < best) {
            float3 p = ro + rd * t;
            if (abs(p.x - cx) < DW_HALF_W && p.y > 0.0 && p.y < DW_OPEN_H) { best = t; dir = k == 0 ? -1 : 1; }
        }
    }
    return best;
}

static inline float dwVis(float d) { return 1.0 - smoothstep(DW_FOG0, DW_FOG1, d); }

// Fog and the sky behind it, in one world's palette.
static inline float3 dwSkyBase(constant DwBiome& b, float3 rd) {
    float g = b.mode == 3 ? -rd.y : rd.y;
    float3 c = g > 0.0 ? mix(b.skyHor, b.skyTop, pow(saturate(g), 0.55))
                       : mix(b.skyHor, b.skyLow, pow(saturate(-g * 2.5), 0.6));
    float sd = max(dot(rd, b.sunDir), 0.0);
    c += b.sunCol * (0.05 * pow(sd, 4.0) + 0.12 * pow(sd, 32.0)) * (b.moon > 0.5 ? 0.5 : 1.0);
    return c;
}

static inline float3 dwSky(constant DwBiome& b, float3 ro, float3 rd, float pxA, float now, float2 off,
                           texture2d_array<float> skins, texture2d_array<float> maps) {
    float3 c = dwSkyBase(b, rd);
    float g = b.mode == 3 ? -rd.y : rd.y;

    // Stars: square points on a grid of directions, never on the horizon.
    if (b.stars > 0.0) {
        float2 a = float2(atan2(rd.z, rd.x), asin(clamp(rd.y, -1.0, 1.0))) * 160.0;
        float2 cell = floor(a);
        float hs = hash21(cell + 13.0);
        float2 f = a - cell - 0.5;
        if (hs > 0.985 && max(abs(f.x), abs(f.y)) < 0.28) {
            float tw = 0.65 + 0.35 * sin(now * (0.7 + hs * 3.0) + hs * 50.0);
            c += float3(0.9, 0.9, 1.0) * b.stars * tw * saturate(g * 5.0) * (hs - 0.985) * 70.0;
        }
    }

    // The End's sky: its own texture on the faces of a box round the world.
    if (b.mode == 2) {
        float3 ad = abs(rd);
        float2 fuv = ad.x > ad.y && ad.x > ad.z ? rd.yz / ad.x : (ad.y > ad.z ? rd.xz / ad.y : rd.xy / ad.z);
        float2 px = glmod2((fuv * 0.5 + 0.5) * 512.0, 128.0);
        float3 e = mcMap(maps, MCM_ENVIRONMENT_END_SKY, px, pxA * 256.0).rgb;
        c = c * 0.55 + pow(e, float3(2.2)) * 0.06;
    }

    // The sun or the moon: the game's own pictures, drawn on black and added.
    float3 sd = b.sunDir;
    float cs = dot(rd, sd);
    if (b.sunSize > 0.0 && cs > 0.0) {
        float3 su = normalize(cross(float3(0, 1, 0), sd)), sv = cross(sd, su);
        float s4 = 4.0 * b.sunSize;               // the disc is the middle quarter of the picture
        float2 q = float2(dot(rd, su), dot(rd, sv)) / cs / s4;
        if (max(abs(q.x), abs(q.y)) < 1.0) {
            float2 px = float2(q.x * 0.5 + 0.5, 0.5 - q.y * 0.5) * 32.0;
            int layer = b.moon > 0.5 ? MCS_ENVIRONMENT_CELESTIAL_MOON_FULL_MOON : MCS_ENVIRONMENT_CELESTIAL_SUN;
            float3 t = mcSkin(skins, layer, px, pxA * 16.0 / s4).rgb;
            c += pow(t, float3(2.2)) * (b.moon > 0.5 ? 2.0 : 4.0);
        }
    }

    // The flat cloud layer, from the game's clouds.png, drifting.
    float tc = (30.0 - ro.y) / rd.y;
    if (b.mode < 2 && tc > 0.0 && abs(rd.y) > 1e-4) {
        float fade = 1.0 - smoothstep(80.0, 260.0, tc);
        if (fade > 0.0) {
            float2 pc = (ro.xz + rd.xz * tc + float2(now * 0.6, 0.0) + off) / 6.0;
            float cl = mcMap(maps, MCM_ENVIRONMENT_CLOUDS, glmod2(pc, 256.0), tc * pxA / 6.0).a;
            float3 lit = mix(b.skyHor, float3(1.0), 0.5) * (b.moon > 0.5 ? 0.1 : 1.0);
            c = mix(c, lit, 0.62 * fade * cl);
        }
    }
    return c;
}

// The portals' own glow (a nether portal gives light 11), from the middle of
// each opening.
static inline float3 dwGlow(float3 P, float3 n, thread const DwWorld& W, float k) {
    float3 acc = float3(0.0);
    for (int d = 0; d < 2; ++d) {
        float3 L = float3(d == 0 ? W.cxA : W.cxB, 3.0, d == 0 ? 0.5 : DW_D + 0.5) - P;
        float r2 = dot(L, L);
        float lam = saturate(dot(n, L * rsqrt(max(r2, 1e-4))) * 0.75 + 0.25);
        acc += lam / (1.0 + r2 * 0.2);
    }
    return acc * float3(0.55, 0.22, 1.0) * k * 1.6;
}

// The other worlds' light, coming through the openings: the next world's sun
// throws a lit patch of its own colour onto this world's ground, and both
// doorways glow on whatever faces them with their world's sky.
static inline float dwOpening(float3 X, float cx, float soft) {
    float2 d = float2(abs(X.x - cx) - DW_HALF_W, max(-X.y, X.y - DW_OPEN_H));
    return 1.0 - smoothstep(-soft, soft, max(d.x, d.y));
}

static inline float3 dwSpill(float3 P, float3 n, thread const DwWorld& W) {
    float3 acc = float3(0.0);
    constant DwBiome& nb = dwBiome(W.biB);
    float3 Ls = nb.sunDir;
    float zB = DW_D + 0.5;
    if (P.z < zB && Ls.z > 0.02) {
        float s = (zB - P.z) / Ls.z;
        float lam = max(dot(n, Ls), 0.0);
        if (lam > 0.0) acc += nb.sunCol * lam * dwOpening(P + Ls * s, W.cxB, 0.04 + 0.015 * s);
    }
    for (int d = 0; d < 2; ++d) {
        constant DwBiome& ob = dwBiome(d == 0 ? W.biA : W.biB);
        float zp = d == 0 ? 0.5 : zB;
        float3 C = float3(d == 0 ? W.cxA : W.cxB, 3.0, zp) - P;
        float side = d == 0 ? -1.0 : 1.0;                   // the opening faces back into this world
        float r2 = dot(C, C);
        float3 Cn = C * rsqrt(max(r2, 1e-4));
        float k = max(dot(n, Cn), 0.0) * max(Cn.z * side, 0.0);
        acc += mix(ob.skyHor, ob.skyTop, 0.3) * k * 45.0 / (PI * (r2 + 8.0));
    }
    return acc;
}

static inline float3 dwShade(thread const DwHit& H, float3 ro, float3 rd, float pxAngle,
                      thread const DwWorld& W, thread const DwCell& cd, float now, int zOff,
                      texture2d_array<float> tiles, texture2d_array<float> maps) {
    float3 P = ro + rd * H.t;
    P.z -= float(zOff);                         // world-local
    float3 n = H.n;
    int3 V = int3(floor(P - n * 0.5));
    int2 cl = V.xz;
    int palette; bool flip;
    int id = dwMaterial(H.run, V.y, cl, W, cd, palette, flip);
    constant DwBiome& b = dwBiome(W.bi);

    int face = n.y > 0.5 ? 0 : (n.y < -0.5 ? 2 : 1);
    if (flip && face != 1) face = 2 - face;
    float2 uv;
    if (face != 1) uv = fract(P.xz);
    else uv = float2(abs(n.x) > 0.5 ? fract(P.z) : fract(P.x), 1.0 - fract(P.y));   // y = 0 at the top
    if (flip && face == 1) uv.y = 1.0 - uv.y;
    // Tops turn a quarter at random per block, as the game turns grass and sand.
    if (face != 1) {
        int rot = int(hash21(float2(cl) * 0.913 + float(V.y) * 3.1) * 4.0);
        if (rot & 1) uv = float2(uv.y, 1.0 - uv.x);
        if (rot & 2) uv = 1.0 - uv;
    }
    float cosi = max(abs(dot(rd, n)), 0.12);
    float fw = H.t * pxAngle / cosi;

    constant DwBiome& pb = dwBiome(palette);
    float3 grass = mcGrassTint(maps, pb.clim.x, pb.clim.y);
    float3 foliage = mcFoliageTint(maps, pb.clim.x, pb.clim.y);
    float3 tint, otint; int over; bool glow;
    int layer = dwTex(id, face, palette, now, grass, foliage, tint, over, otint, glow);
    float4 tx = mcTile(tiles, layer, uv, fw);
    float3 c = tx.rgb * tint;
    if (id == B_LEAVES && !glow) c = mix(tint * 0.16, c, tx.a);   // leaves solid, as on Fast graphics
    if (over >= 0) {
        float4 o = mcTile(tiles, over, uv, fw);
        c = mix(c, o.rgb * otint, o.a);
    }
    float3 alb = pow(c, float3(2.2));
    if (glow) return alb * 1.6;

    float3 light = b.skyL * mcFaceShade(n) + dwGlow(P, n, W, b.lamp) + dwSpill(P, n, W);
    float3 col = alb * light;
    if (id == B_WATER) {
        float3 R = reflect(rd, n);
        float fres = 0.08 + 0.92 * pow(1.0 - abs(dot(rd, n)), 5.0);
        col = mix(col, dwSkyBase(b, R), saturate(fres * 0.55 + 0.08));
    }
    return col;
}

static inline float3 dwScene(float3 ro, float3 rd, float pxAngle, int w0, float seed, float now,
                             texture2d_array<float> tiles, texture2d_array<float> skins,
                             texture2d_array<float> maps) {
    DwWorld W = dwWorld(w0, seed);
    int zOff = 0;

    float2 rd2 = select(rd.xz, float2(1e-6), abs(rd.xz) < 1e-6);
    float2 inv = 1.0 / rd2;
    int2 cell = int2(floor(ro.xz));
    int2 st = int2(sign(rd2));
    float2 tDel = abs(inv);
    float2 tMax2 = (float2(cell) + select(float2(0.0), float2(1.0), rd2 > 0.0) - ro.xz) * inv;
    float3 sideN = float3(0.0);

    int pdir;
    float tP = dwPortal(ro, rd, W, zOff, 0.0, pdir);

    float tIn = 0.0;
    float segT = 0.0, segE = 0.0;      // where this world's stretch began: real t, effective distance
    float R = 1.0;
    float3 acc = float3(0.0);
    bool hit = false;
    DwHit H;
    DwCell cd;

    // One step is either a whole empty 6×6 cell, jumped in one go, or one
    // column of a cell that may hold something. Entering a cell brings its
    // corners up to date and decides which it is. The inner loop never
    // changes world; the outer one (at most three times round) carries the
    // ray through a doorway, so the hot loop holds one world's code only.
    int steps = 0;
    float3 inv3 = float3(inv.x, 1.0 / select(rd.y, 1e-6, abs(rd.y) < 1e-6), inv.y);
    bool high = false;
    for (int seg = 0; seg < 3; ++seg) {
        cd.M = int2(0x40000000); cd.I = cd.M;
        int2 c0 = cd.M, c1 = c0;
        float tm = 0.0;
        float yMax = W.yMax, yMin = W.yMin;
        for (; steps < DW_STEPS; ++steps) {
            if (tIn >= tP) break;
            if (segE + (tIn - segT) > DW_FOG1) break;
            float y0 = ro.y + rd.y * tIn;
            if ((rd.y > 0.0 && y0 > yMax) || (rd.y < 0.0 && y0 < yMin)) { high = true; break; }
            int2 lc = cell - int2(0, zOff);
            if (any(lc < c0) || any(lc > c1)) {
                int2 M = int2(floor(float2(lc) / 6.0));
                float2 a = float2(M * 6) + float2(0.0, float(zOff));
                float2 tx = (select(a, a + 6.0, rd2 > 0.0) - ro.xz) * inv;
                tm = min(tx.x, tx.y);
                dwCellEnter(cd, M, W, min(y0, ro.y + rd.y * tm));
                c0 = cd.M * 6; c1 = c0 + 5;
            }
            // Jump to the first place in the cell the ray could touch
            // anything, or out of the cell (or to the doorway) if none.
            float tEnd = min(tm, tP);
            int how;
            float tN = dwFirst(cd, ro, rd, inv3, tIn, float(zOff), how);
            if (tN > tIn) {
                bool leave = tN >= tEnd - 1e-3;
                float tJ = leave ? tEnd : tN;
                float2 q = ro.xz + rd2 * (tJ + 1e-4);
                cell = int2(floor(q));
                tMax2 = (float2(cell) + select(float2(0.0), float2(1.0), rd2 > 0.0) - ro.xz) * inv;
                float2 tx2 = (float2(cell) + select(float2(1.0), float2(0.0), rd2 > 0.0) - ro.xz) * inv;
                sideN = tx2.x > tx2.y ? float3(-float(st.x), 0, 0) : float3(0, 0, -float(st.y));
                tIn = tJ;
                if (leave) continue;
                if (how == 1) sideN = float3(0.0, 1.0, 0.0);
                if (how == 2) sideN = float3(0.0, -1.0, 0.0);
                lc = cell - int2(0, zOff);
            }
            float tOut = min(tMax2.x, tMax2.y);
            DwCol k = dwColumn(lc, cd, W);
            float th; float3 nh; float4 rr;
            if (dwColumnHit(k, ro, rd, tIn, tOut, sideN, th, nh, rr)) {
                H.t = th; H.n = nh; H.run = rr;
                hit = true;
                break;
            }
            tIn = tOut;
            if (tMax2.x < tMax2.y) { tMax2.x += tDel.x; cell.x += st.x; sideN = float3(-float(st.x), 0, 0); }
            else                   { tMax2.y += tDel.y; cell.y += st.y; sideN = float3(0, 0, -float(st.y)); }
        }
        if (hit || tIn < tP) break;
        // Through the doorway: close this world's stretch of fog, open the next.
        float e1 = segE + (tP - segT);
        float ratio = dwVis(e1) / max(dwVis(segE), 1e-4);
        acc += R * (1.0 - ratio) * dwSkyBase(dwBiome(W.bi), rd);
        R *= ratio;
        // The portal's own sheet, the game's purple, kept faint so the world
        // beyond shows through it.
        {
            float3 X = ro + rd * tP;
            float2 puv = float2(fract(X.x), 1.0 - fract(X.y));
            int fr = mcFrame(MC_NETHER_PORTAL, MC_NETHER_PORTAL_FRAMES, MC_NETHER_PORTAL_TICKS, now);
            float4 pt = mcTile(tiles, fr, puv, tP * pxAngle / max(abs(rd.z), 0.2));
            float a = 0.28 * pt.a;
            acc += R * a * pow(pt.rgb, float3(2.2)) * 1.4;
            R *= 1.0 - a;
        }
        segT = tP; segE = e1 * DW_THROUGH;
        zOff += pdir * DW_DI;
        W = dwWorld(W.w + pdir, seed);
        tP = dwPortal(ro, rd, W, zOff, tP, pdir);
    }

    // A ray that rose (or, below the floating and hung worlds, fell) past
    // everything is fogged as far as the height it left by.
    float tEnd = hit ? H.t : tIn;
    if (!hit && high) tEnd = max(segT, ((rd.y > 0.0 ? W.yFog : W.yFogLo) - ro.y) * inv3.y);
    float e1 = segE + (tEnd - segT);
    float ratio = dwVis(e1) / max(dwVis(segE), 1e-4);
    acc += R * (1.0 - ratio) * dwSkyBase(dwBiome(W.bi), rd);
    R *= ratio;
    if (hit) {
        acc += R * dwShade(H, ro, rd, pxAngle, W, cd, now, zOff, tiles, maps);
    } else {
        float3 roW = ro; roW.z -= float(zOff);
        if (W.mode == 3 && rd.y < 0.0) {
            // Below the Nether's bridges, the lava sea.
            float tl = (DW_LAVA - ro.y) * inv3.y;
            float3 L = ro + rd * tl;
            int fr = mcFrame(MC_LAVA_STILL, MC_LAVA_STILL_FRAMES, MC_LAVA_STILL_TICKS, now);
            acc += R * pow(mcTile(tiles, fr, fract(L.xz), tl * pxAngle / max(-rd.y, 0.12)).rgb, float3(2.2)) * 1.5;
        } else {
            acc += R * dwSky(dwBiome(W.bi), roW, rd, pxAngle, now, W.off, skins, maps);
        }
    }
    return acc;
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]],
                        texture2d_array<float> mcTiles [[texture(8)]],
                        texture2d_array<float> mcSkins [[texture(10)]],
                        texture2d_array<float> mcMaps  [[texture(11)]]) {
    float minRes = min(u.resolution.x, u.resolution.y);

    // Where on the walk: q counts doorways passed. At t = 5 the next door is
    // 14 blocks ahead, whatever the speed, so stills always frame one.
    float k0 = floor(u.seed * 4096.0);
    float q = u.speed * u.time / DW_D + (DW_D - 14.0 - u.speed * 5.0) / DW_D;
    float qf = floor(q);
    int w = int(k0 + qf);
    float zl = 0.5 + (q - qf) * DW_D;

    DwWorld W = dwWorld(w, u.seed);
    float slope;
    float x = dwPathX(W, zl, slope);
    float3 ro = float3(x, DW_EYE, zl);
    float3 upHint = float3(0, 1, 0);
    float3 fwd = normalize(float3(slope, -0.07, 1.0));
    float3 right = normalize(cross(upHint, fwd));
    float lens = lerpLook(u.yaw, u.pitch, u.magnify, upHint, right, fwd);
    float3 up = cross(fwd, right);
    float pxAngle = 2.0 / (minRes * DW_FOCAL * lens);

    float2 uv = lerpUV(pos, u.resolution);
    float3 rd = normalize(uv.x * right + uv.y * up + lens * DW_FOCAL * fwd);
    float3 col = dwScene(ro, rd, pxAngle, w, u.seed, u.time, mcTiles, mcSkins, mcMaps) * u.light;

    col = col / (1.0 + col * 0.35);
    col = pow(max(col, 0.0), 1.0 / 2.2);
    col = lerpDither(col, pos);
    return half4(half3(col), 1.0h);
}
