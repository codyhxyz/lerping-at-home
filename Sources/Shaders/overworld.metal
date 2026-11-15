// Overworld — the block world drawn as a top-down pixel-art map.
// Original work for Lerping@Home: every texture, building and creature here is
// procedural and written for this file; no texture data or artwork from any
// game. It is a homage to the block-world idea, drawn the way old top-down
// adventure maps were: no perspective, just tops and the south faces under
// them.
//
// lerp-category: Blocks
//
// The screen is a picture plane in cabinet oblique: one block is 16×16 texels
// on top and 16×16 on its south face, and a block one level higher sits one
// block further up the screen. Texels land on whole screen pixels (the texel
// size is rounded to an integer for the display, and the pan moves in whole
// pixels), so the pixel art stays crisp at every size and never shimmers.
//
// The map pans slowly over a seeded world of grassland, birch and oak woods,
// snowy spruce taiga, desert with cacti, rocky peaks, lakes and rivers, and
// every visit opens on a village: gabled houses along dirt paths, wheat fields
// on irrigation channels that ripen and are cut, hay, pumpkins, lamp posts.
// Sheep, cows, pigs and hens of this file's own design wander and graze. The
// sun crosses behind the map, so shadows fall toward the viewer and stretch
// toward dawn and dusk; cloud shadows drift over; at dusk the windows and
// lamps come on one by one and light the ground in stepped pools.
//
// Rendering: each pixel walks the 45° line of sight through the block columns
// in front of it, two voxels a column (that is all one column can hold of a
// 45° line), so a frame is a fixed, short loop with no step size and no
// misses. A SIMD group nearly always looks down one or two such lines, so its
// lanes build the line's columns in parallel, one each, and walk and probe
// them by shuffle; groups that cannot (a screen edge, sub-pixel texels) walk
// serially through the same functions. Worst case about 12 ms at 3456×2234.
//
// lerp-param: blocks    float 10 32     = 22   "Blocks tall"
// lerp-param: speed     float 0 1.5     = 0.4  "Pan speed"
// lerp-param: dayLength float 120 1200  = 480  "Day length (s)"
// lerp-param: clouds    float 0 1       = 0.35 "Clouds"
//
// lerp-preset: "Close In"  blocks=12, speed=0.3
// lerp-preset: "Wide Map"  blocks=28, speed=0.6
// lerp-preset: "Long Day"  dayLength=1200, clouds=0.25

constant int OW_W    = 4;    // water fills every column below this level
constant int OW_YMAX = 18;   // nothing solid reaches this level
constant float OW_YC = 24.0; // height of the clouds whose shadows cross the map

// Materials.
constant int OW_AIR = 0, OW_GRASS = 1, OW_DIRT = 2, OW_STONE = 3, OW_SAND = 4,
             OW_SANDSTONE = 5, OW_SNOW = 6, OW_WATER = 7, OW_LOG = 8, OW_LEAVES = 9,
             OW_BIRCH = 10, OW_BLEAVES = 11, OW_SPRUCE = 12, OW_SLEAVES = 13,
             OW_CACTUS = 14, OW_WALL = 15, OW_ROOF = 16, OW_COBBLE = 17, OW_FARM = 18,
             OW_WHEAT = 19, OW_PATH = 20, OW_GRAVEL = 21, OW_POST = 22, OW_TORCH = 23,
             OW_TALLGRASS = 24, OW_FLOWER = 25, OW_ICE = 26, OW_DEADBUSH = 27,
             OW_PUMPKIN = 28, OW_HAY = 29;

constant int OW_PLAINS = 0, OW_FOREST = 1, OW_SNOWY = 2, OW_DESERT = 3, OW_MOUNT = 4;

// ---------------------------------------------------------------------------
// Hashes.

static inline uint owHash(uint x) {
    x ^= x >> 16; x *= 0x7feb352dU; x ^= x >> 15; x *= 0x846ca68bU; x ^= x >> 16;
    return x;
}
static inline uint owH3(int a, int b, int c) {
    return owHash(uint(a) * 0x8da6b343U ^ uint(b) * 0xd8163841U ^ uint(c) * 0xcb1ab31fU);
}
static inline float owU(uint h) { return float(h >> 8) * (1.0 / 16777216.0); }

// ---------------------------------------------------------------------------
// The world: a height field, rivers, climate, villages, trees.

static inline float owBaseH(float2 p) {
    float b = valueNoise(p * (1.0 / 24.0)) * 0.65 + valueNoise(p * (1.0 / 9.5) + 31.7) * 0.35;
    return 1.0 + b * 9.0 + 6.0 * smoothstep(0.62, 0.86, b);
}
static inline float owRiver(float2 p) { return abs(valueNoise(p * (1.0 / 52.0) + 77.7) - 0.5); }

static inline int owRiverCarve(int h, float r) {
    if (r < 0.035) return min(h, OW_W - 2);
    if (r < 0.052) return min(h, OW_W - 1);
    if (r < 0.068) return min(h, OW_W);
    return h;
}

struct OwVil { int on; float2 c; float R; int vb; uint hs; };

// Village cells are 45 blocks, so every 5×5 tree cell lies inside exactly one.
static inline OwVil owVillage(int2 p) {
    int2 vc = int2(floor(float2(p) / 45.0));
    uint hs = owH3(vc.x, vc.y, 4049);
    OwVil v; v.on = owU(hs) < 0.55 ? 1 : 0; v.hs = hs;
    // One hash, sliced: bits 0-7 jitter x, 8-15 jitter z (the top 24 decide 'on').
    v.c = float2(vc) * 45.0 + 22.5 + (float2(float(hs & 255u), float((hs >> 8) & 255u)) / 255.0 - 0.5) * 10.0;
    v.R = 11.0 + 6.0 * float((hs >> 16) & 63u) / 63.0;
    v.vb = OW_W + 1 + int((hs >> 22) & 1u);
    return v;
}

static inline int owBiome(float hf, float temp, float moist) {
    if (hf >= 10.5) return OW_MOUNT;
    if (temp > 0.58 && moist < 0.52) return OW_DESERT;
    if (temp < 0.34) return OW_SNOWY;
    if (moist > 0.53) return OW_FOREST;
    return OW_PLAINS;
}

// Temperature and moisture from one two-channel value noise.
static inline float2 owClimateAt(float2 cc) {
    float2 st = cc * (1.0 / 96.0) + 13.1;
    float2 i = floor(st), f = fract(st);
    float2 a = hash22(i), b = hash22(i + float2(1.0, 0.0)), c = hash22(i + float2(0.0, 1.0)), d = hash22(i + float2(1.0, 1.0));
    float2 w = f * f * (3.0 - 2.0 * f);
    return mix(mix(a, b, w.x), mix(c, d, w.x), w.y);
}

// A village cell with its validity (the land at its centre must be middling).
struct OwVC { int2 id; OwVil v; int vOK; int2 sc; };   // sc: the opening village's cell

static inline int2 owVCell(int2 p) { return int2(floor(float2(p) / 45.0)); }

// The opening village is taken as it is found (an island, or a terrace cut
// into a hill); every other one needs middling land at its centre.
static inline OwVC owVilCell(int2 p, int2 sc) {
    OwVC r;
    r.id = owVCell(p);
    r.sc = sc;
    r.v = owVillage(p);
    r.vOK = 0;
    if (r.v.on == 1) {
        if (all(r.id == sc)) r.vOK = 1;
        else {
            float vbh = owBaseH(r.v.c);
            r.vOK = (vbh > 4.4 && vbh < 9.5) ? 1 : 0;
        }
    }
    return r;
}

static inline void owEnsureV(int2 p, thread OwVC& kv) {
    if (any(owVCell(p) != kv.id)) kv = owVilCell(p, kv.sc);
}

// Everything shared by a 5×5 cell: its climate, its one tree, its village.
// The walk along a line of sight crosses only three or four cells, so it
// keeps the last one and rebuilds it only on entering the next.
struct OwCell {
    int2 id;
    float temp, moist;
    int kind;          // tree: -1 none, 0 oak, 1 birch, 2 spruce, 3 cactus
    int2 ctr; int g; uint th;
    OwVil v; int vOK;
};

// kv must be the village cell holding tcl (45 is a multiple of 5, so one does).
static OwCell owCellInfo(int2 tcl, thread const OwVC& kv) {
    OwCell k;
    k.id = tcl;
    float2 cl = owClimateAt(float2(tcl) * 5.0 + 2.5);
    k.temp = cl.x; k.moist = cl.y;
    k.v = kv.v;
    k.vOK = kv.vOK;
    k.kind = -1; k.g = 0;
    k.th = owH3(tcl.x, tcl.y, 911);
    k.ctr = tcl * 5 + int2(1 + int((k.th >> 4) % 3u), 1 + int((k.th >> 12) % 3u));
    int bi = owBiome(7.0, cl.x, cl.y);
    float dens = bi == OW_FOREST ? 0.6 : bi == OW_PLAINS ? 0.12 : bi == OW_SNOWY ? 0.5 : 0.2;
    if (owU(k.th) < dens && !(k.vOK == 1 && length(float2(k.ctr) + 0.5 - k.v.c) < k.v.R + 7.0)) {
        float2 fc = float2(k.ctr) + 0.5;
        float hc = owBaseH(fc);
        int g = owRiverCarve(int(floor(hc)), owRiver(fc));
        if (g > OW_W && g <= 10) {
            k.g = g;
            k.kind = bi == OW_DESERT ? 3 : (bi == OW_SNOWY || hc >= 9.0) ? 2 :
                     (bi == OW_FOREST && ((k.th >> 20) & 3u) == 0u) ? 1 : 0;
        }
    }
    return k;
}

struct OwCol {
    int h, wTop, top, sub, deco;
    int oLo, oHi, oMat, tTop, tMat;
    int biome, style, lx, lz, vb, plot;
    uint id, vh;
    float temp, moist;
};

// An upper bound on every solid level in column p. With its cell in hand the
// bound is exact for trees and villages; without, it is the base height plus a
// hash-only allowance, so open air costs two noise lookups.
static inline int owBound(int2 p, float hf, thread const OwCell& k, thread const OwVC& kv) {
    int h = int(floor(hf));
    int b = h;
    int2 tcl = int2(floor((float2(p) + 0.5) / 5.0));
    if (all(tcl == k.id)) {
        int2 d = p - k.ctr;
        if (k.kind >= 0 && abs(d.x) <= 1 && abs(d.y) <= 1) b = max(b, k.g + 7);
    } else {
        uint th = owH3(tcl.x, tcl.y, 911);
        int2 ctr = tcl * 5 + int2(1 + int((th >> 4) % 3u), 1 + int((th >> 12) % 3u));
        int2 d = p - ctr;
        if (owU(th) < 0.6 && abs(d.x) <= 1 && abs(d.y) <= 1) b = max(b, min(h, 10) + 9);
    }
    if (kv.vOK == 1 && length(float2(p) + 0.5 - kv.v.c) < kv.v.R + 6.0) b = max(b, kv.v.vb + 6);
    return min(b, OW_YMAX);
}

static inline void owEnsure(int2 p, thread OwCell& k, thread const OwVC& kv) {
    int2 tcl = int2(floor((float2(p) + 0.5) / 5.0));
    if (any(tcl != k.id)) k = owCellInfo(tcl, kv);
}

// Village ground is laid as grass and given its style (sand, snow, oak or
// sandstone) only for the column that is drawn: style is material, not shape.
static OwCol owColumn(int2 p, float hf, thread const OwCell& k) {
    OwCol c;
    float2 fp = float2(p) + 0.5;
    int h = int(floor(hf));
    c.temp = k.temp; c.moist = k.moist;
    int biome = owBiome(hf, k.temp, k.moist);
    c.id = owH3(p.x, p.y, 17);
    c.wTop = 0; c.deco = 0; c.oLo = 0; c.oHi = 0; c.oMat = 0; c.tTop = 0; c.tMat = 0;
    c.style = -1; c.lx = 0; c.lz = 0; c.vb = 0; c.plot = 0; c.vh = 0u;

    float vd = k.vOK == 1 ? length(fp - k.v.c) : 1e9;
    bool inV = vd < k.v.R;
    if (inV) {
        h = k.v.vb;
    } else {
        if (vd < k.v.R + 5.0) h = int(round(mix(float(k.v.vb), floor(hf), (vd - k.v.R) / 5.0)));
        h = owRiverCarve(h, owRiver(fp));
    }

    int top, sub;
    if (h <= OW_W) {
        top = (h < OW_W && (c.id & 7u) == 0u) ? OW_GRAVEL : (h < OW_W - 1 && biome == OW_FOREST ? OW_DIRT : OW_SAND);
        if (h == OW_W && biome == OW_SNOWY) top = OW_SNOW;
        sub = OW_SAND;
    } else if (biome == OW_DESERT) { top = OW_SAND; sub = OW_SANDSTONE; }
    else if (biome == OW_SNOWY)  { top = OW_SNOW; sub = OW_DIRT; }
    else if (biome == OW_MOUNT)  {
        top = h >= 13 ? OW_SNOW : ((c.id % 11u) == 0u ? OW_GRAVEL : OW_STONE);
        sub = OW_STONE;
    } else { top = OW_GRASS; sub = OW_DIRT; }
    if (h < OW_W) {
        if (biome == OW_SNOWY) { c.oLo = OW_W - 1; c.oHi = OW_W; c.oMat = OW_ICE; c.tTop = c.oLo; c.wTop = OW_W - 1; }
        else c.wTop = OW_W;
    }

    if (inV) {
        OwVil v = k.v;
        float2 vcen = floor(v.c);
        c.style = -2; c.vb = v.vb; c.vh = v.hs;
        top = OW_GRASS; sub = OW_DIRT;
        int2 q = p - int2(vcen) + 32;
        int2 pi = q / 8, l = q - pi * 8;
        c.lx = l.x; c.lz = l.y;
        float2 pc = vcen - 32.0 + float2(pi) * 8.0 + 4.0;
        uint ph = owH3(pi.x + int(v.hs & 1023u), pi.y, 77);
        if ((l.x == 0 || l.y == 0) && vd < v.R - 1.0) top = OW_PATH;
        if (length(pc - v.c) < v.R - 4.0) {
            float pt = owU(ph);
            int vb0 = v.vb;
            if (pt < 0.5) {
                c.plot = 1;
                if (l.x >= 2 && l.x <= 6 && l.y >= 2 && l.y <= 5) {
                    c.oLo = vb0; c.tTop = vb0 + 3; c.tMat = OW_WALL; c.oMat = OW_ROOF;
                    c.oHi = (l.y == 3 || l.y == 4) ? vb0 + 5 : vb0 + 4;
                    top = OW_COBBLE;
                } else if (l.x == 1 && l.y == 1) {
                    c.oLo = vb0; c.tTop = vb0 + 1; c.tMat = OW_POST; c.oMat = OW_TORCH; c.oHi = vb0 + 2;
                }
            } else if (pt < 0.8) {
                c.plot = 2;
                if (l.x >= 1 && l.y >= 1) {
                    if (l.y == 4) { h = vb0 - 1; c.wTop = vb0; top = OW_DIRT; }
                    else { top = OW_FARM; c.deco = OW_WHEAT; }
                }
            } else {
                c.plot = 3;
                if (l.x >= 1 && l.y >= 1) {
                    float r = owU(c.id);
                    if (r < 0.10) { c.oLo = vb0; c.oHi = vb0 + 1; c.oMat = OW_HAY; c.tTop = vb0; }
                    else if (r < 0.14) { c.oLo = vb0; c.oHi = vb0 + 1; c.oMat = OW_PUMPKIN; c.tTop = vb0; }
                    else if (r < 0.30) c.deco = OW_FLOWER;
                }
            }
        }
    } else if (k.kind >= 0 && h > OW_W) {
        int2 d = p - k.ctr;
        if (abs(d.x) <= 1 && abs(d.y) <= 1) {
            int g = k.g;
            int man = abs(d.x) + abs(d.y);
            uint bit = (owHash(k.th + uint(d.x * 3 + d.y + 4)) >> 9) & 1u;
            if (k.kind == 3) {
                if (man == 0) { c.oLo = g; c.oHi = g + 2 + int(bit); c.oMat = OW_CACTUS; c.tTop = g; }
            } else if (k.kind == 2) {
                c.oMat = OW_SLEAVES; c.tMat = OW_SPRUCE; c.oLo = man == 0 ? g : g + 2; c.tTop = g + 2;
                c.oHi = man == 0 ? g + 7 : (man == 1 ? g + 5 : g + 3);
            } else {
                int up = k.kind == 1 ? 1 : 0;
                c.oMat = k.kind == 1 ? OW_BLEAVES : OW_LEAVES; c.tMat = k.kind == 1 ? OW_BIRCH : OW_LOG;
                c.oLo = man == 0 ? g : g + 2 + up; c.tTop = g + 2 + up;
                c.oHi = (man == 0 ? g + 5 : (man == 1 ? g + 4 + int(bit) : g + 3 + int(bit))) + up;
            }
        }
    }

    // Ground cover.
    if (c.deco == 0 && !(c.oLo == h && c.oHi > h) && !inV) {
        float r = owU(owHash(c.id + 99u));
        if (top == OW_GRASS) {
            float tg = biome == OW_PLAINS ? 0.22 : 0.09;
            if (r < tg) c.deco = OW_TALLGRASS;
            else if (r < tg + (biome == OW_PLAINS ? 0.06 : 0.025)) c.deco = OW_FLOWER;
            else if (r < tg + 0.065 && biome == OW_PLAINS) { c.oLo = h; c.oHi = h + 1; c.oMat = OW_PUMPKIN; c.tTop = h; }
        } else if (top == OW_SAND && biome == OW_DESERT && r < 0.03) c.deco = OW_DEADBUSH;
        else if (top == OW_SNOW && biome == OW_SNOWY && r < 0.015) c.deco = OW_TALLGRASS;
    }

    c.h = h; c.top = top; c.sub = sub; c.biome = biome;
    return c;
}

static inline int owVox(thread const OwCol& c, int Y) {
    if (Y < c.h) return Y == c.h - 1 ? c.top : (Y >= c.h - 4 ? c.sub : OW_STONE);
    if (Y >= c.oLo && Y < c.oHi) return Y < c.tTop ? c.tMat : c.oMat;
    if (Y < c.wTop) return OW_WATER;
    if (Y == c.h && c.deco != 0) return c.deco;
    return OW_AIR;
}

static inline bool owCutout(int m) {
    return m == OW_WHEAT || m == OW_TALLGRASS || m == OW_FLOWER || m == OW_DEADBUSH;
}

// Opaque, shadow-casting voxel at v? Bounded first, so open air costs two lookups.
static inline bool owSolid(int3 v, thread OwCell& k, thread OwVC& kv) {
    int2 p = int2(v.x, v.z);
    float hf = owBaseH(float2(p) + 0.5);
    owEnsureV(p, kv);
    if (v.y >= owBound(p, hf, k, kv)) return false;
    if (v.y < 0) return true;
    owEnsure(p, k, kv);
    if (v.y >= owBound(p, hf, k, kv)) return false;
    OwCol c = owColumn(p, hf, k);
    int m = owVox(c, v.y);
    return m != OW_AIR && m != OW_WATER && !owCutout(m) && m != OW_TORCH && m != OW_POST;
}

// The voxel's solid box in its own unit cube.
static inline void owShape(int m, thread float3& lo, thread float3& hi) {
    lo = float3(0.0); hi = float3(1.0);
    if (m == OW_FARM || m == OW_PATH) hi.y = 15.0 / 16.0;
    else if (m == OW_POST) { lo = float3(6.0, 0.0, 6.0) / 16.0; hi = float3(10.0, 16.0, 10.0) / 16.0; }
    else if (m == OW_TORCH) { lo = float3(7.0, 0.0, 7.0) / 16.0; hi = float3(9.0, 10.0, 9.0) / 16.0; }
    else if (m == OW_CACTUS) { lo = float3(1.0, 0.0, 1.0) / 16.0; hi = float3(15.0, 16.0, 15.0) / 16.0; }
    else if (m == OW_PUMPKIN) { lo = float3(1.0, 0.0, 1.0) / 16.0; hi = float3(15.0, 14.0, 15.0) / 16.0; }
}

// The 45° line z + y = s (in the voxel's own coordinates) at x = fx against a
// box: its south face first, then its top. face 1 = south, 0 = top.
static inline bool owBoxHit(float s, float fx, float3 lo, float3 hi,
                            thread int& face, thread float2& uv, thread float& zl) {
    if (fx < lo.x || fx > hi.x) return false;
    float y = s - lo.z;
    if (y >= lo.y && y <= hi.y) { face = 1; uv = float2(fx, y); zl = lo.z; return true; }
    float z = s - hi.y;
    if (z >= lo.z && z <= hi.z) { face = 0; uv = float2(fx, z); zl = z; return true; }
    return false;
}

// ---------------------------------------------------------------------------
// Pixel art. tc is the texel (x right, y up the face / north across a top).

static inline float owT(uint bh, int2 tc, uint k) {
    return owU(owHash(bh ^ uint(tc.x * 16 + tc.y) * 0x9E3779B1U ^ k * 0x85ebca6bU));
}

static inline float3 owGrassTint(float temp, float moist) {
    float3 g = mix(float3(0.30, 0.52, 0.19), float3(0.56, 0.60, 0.25), saturate((temp - 0.47) * 3.5));
    g = mix(g, float3(0.36, 0.54, 0.40), saturate((0.47 - temp) * 4.0));
    return g * mix(1.06, 0.88, moist);
}

static inline float3 owDirt(uint bh, int2 tc) {
    float r = owT(bh, tc, 1u);
    float3 c = float3(0.54, 0.38, 0.25) * (r < 0.2 ? 0.84 : (r < 0.85 ? 1.0 : 1.1));
    if (owT(bh, tc, 2u) < 0.04) c = float3(0.52, 0.50, 0.47);
    return c;
}

static inline float3 owStone(uint bh, int2 tc, bool ores) {
    float blot = owT(bh, tc / 3, 3u);
    float r = owT(bh, tc, 4u);
    float3 c = float3(0.49, 0.49, 0.51) * (blot < 0.3 ? 0.88 : (blot < 0.8 ? 1.0 : 1.07));
    if (r < 0.07) c *= 0.8;
    if (ores) {
        uint ob = owHash(bh + 5u) % 23u;
        if (ob < 2u) {
            int2 o = int2(int(owHash(bh + 6u) % 10u) + 3, int(owHash(bh + 7u) % 10u) + 3);
            int2 dd = abs(tc - o);
            if (dd.x + dd.y <= 2 && owT(bh, tc, 8u) < 0.8)
                c = ob == 0u ? float3(0.13, 0.12, 0.12) : float3(0.78, 0.58, 0.44);
        }
    }
    return c;
}

static inline float3 owPlanks(uint bh, int2 tc, float3 base) {
    int row = tc.y / 4;
    float3 c = base * (0.94 + 0.12 * owT(bh, int2(row, tc.x / 3), 9u));
    if ((tc.y & 3) == 0) c *= 0.72;
    int joint = int(owHash(bh + uint(row) * 31u) % 16u);
    if (tc.x == joint) c *= 0.74;
    if (owT(bh, tc, 10u) < 0.08) c *= 0.88;
    return c;
}

static inline float3 owCobble(uint bh, int2 tc) {
    int row = (tc.y + 1) / 4;
    int off = int(owHash(bh + uint(row) * 7u) % 5u);
    int sx = (tc.x + off) / 5;
    int lx = (tc.x + off) - sx * 5, ly = (tc.y + 1) - row * 4;
    float stone = owT(bh, int2(sx, row), 11u);
    float3 c = float3(0.52, 0.51, 0.50) * (0.82 + 0.3 * stone);
    if (lx == 0 || ly == 0) c = float3(0.30, 0.30, 0.31);
    else if (lx == 1 && ly == 3) c *= 1.15;
    return c;
}

static inline float3 owLogSide(uint bh, int2 tc, int m) {
    if (m == OW_BIRCH) {
        float3 c = float3(0.86, 0.85, 0.80) * (0.95 + 0.07 * owT(bh, tc, 12u));
        int mark = int(owHash(bh + uint(tc.y) * 13u) % 7u);
        int mx = int(owHash(bh + uint(tc.y) * 17u) % 12u);
        if (mark == 0 && tc.x >= mx && tc.x < mx + 3) c = float3(0.20, 0.19, 0.17);
        return c;
    }
    float3 base = m == OW_SPRUCE ? float3(0.29, 0.20, 0.12) : float3(0.42, 0.31, 0.18);
    float s = owU(owHash(bh + uint(tc.x) * 29u));
    float3 c = base * (s < 0.3 ? 0.78 : (s < 0.8 ? 1.0 : 1.12));
    if (owT(bh, tc, 13u) < 0.06) c *= 0.75;
    return c;
}

static inline float3 owLogTop(int2 tc, int m) {
    float2 d = float2(tc) - 7.5;
    float r = max(abs(d.x), abs(d.y));
    float3 bark = m == OW_BIRCH ? float3(0.80, 0.79, 0.74) : (m == OW_SPRUCE ? float3(0.29, 0.20, 0.12) : float3(0.40, 0.30, 0.17));
    if (r > 6.0) return bark;
    float3 wood = float3(0.70, 0.56, 0.34);
    return (int(r) & 1) == 0 ? wood : wood * 0.82;
}

// Leaves in 2×2 clusters, a few dark gaps between them and a few bright tips.
static inline float3 owLeaves(uint bh, int2 tc, float3 tint) {
    float cl = owT(bh, tc / 2, 15u), r = owT(bh, tc, 14u);
    float v = cl < 0.3 ? 0.80 : (cl < 0.78 ? 1.0 : 1.14);
    if (r < 0.09) v *= 0.62;
    else if (r > 0.94) v *= 1.15;
    return tint * v;
}


// Wheat growth stage 0…7 for a farm plot: rows ripen together and are cut.
static inline int owWheatStage(uint vh, int lz, float t) {
    float cyc = 150.0;
    float ph = fract(t / cyc + owU(owHash(vh + 31u)) + float(lz) * 0.015);
    return min(7, int(ph * 9.5));   // the last stretch is stubble (stage 8 → bare)
}

// Which texels of a cut-out plant are solid. owCutTex colours only these.
static bool owCutAlpha(int m, int face, int2 tc, uint bh, int st) {
    if (m == OW_WHEAT) {
        if (face == 1) {
            if ((tc.x & 1) == 1) return false;
            int ht = 2 + int(float(st) * 1.75) + int(owHash(bh + uint(tc.x)) % 3u) - 1;
            return tc.y < ht;
        }
        bool dot = ((tc.x + 2 * tc.y) % 4) == 0 && (tc.y & 3) != 0;
        if (st >= 3) dot = dot || ((tc.x + 2 * tc.y) % 4) == 2;
        return dot;
    }
    if (m == OW_TALLGRASS) {
        if (face == 1) {
            uint ch = owHash(bh + uint(tc.x) * 47u);
            if ((ch & 3u) == 0u) return false;
            return tc.y < 2 + int((ch >> 4) % 7u);
        }
        int2 d = tc - int2(4 + int(bh % 8u), 4 + int((bh >> 3) % 8u));
        return (d.x == 0 && d.y >= -1 && d.y <= 1) || (d.y == 0 && abs(d.x) == 1) || (abs(d.x) == 2 && d.y == 1);
    }
    if (m == OW_FLOWER) {
        int2 d = abs(tc - int2(7, 7));
        if (face == 1) return (tc.x == 7 && tc.y < 6) || (tc.x == 8 && tc.y == 3) || (d.x <= 1 && d.y <= 1 && !(d.x == 1 && d.y == 1));
        return d.x + d.y <= 1;
    }
    if (m == OW_DEADBUSH) {
        if (face != 1) return false;
        int x = tc.x - 8;
        return (tc.y < 4 && x == 0) || (tc.y >= 3 && tc.y < 9 && (x == tc.y - 4 || -x == tc.y - 3));
    }
    return true;
}

// One column of a shared line of sight, packed for shuffling. V: the voxels
// at levels n, n - 1 and n + 1 (the line enters at n; a line one block row up
// enters at n + 1) and the wheat stage. S: the solid profile for shadow and
// corner probes (ground below h, object in [lo, hi) unless it is a lamp).
// I/Id/Vh/T/M: what texturing needs, for whichever lane's pixel hits it.
struct OwProd { uint V, S, I, Id, Vh; float T, M; int top; };

static OwProd owProduce(int2 p, int n, float t, thread OwCell& kc, thread OwVC& kv) {
    float hf = owBaseH(float2(p) + 0.5);
    owEnsureV(p, kv);
    owEnsure(p, kc, kv);
    OwCol c = owColumn(p, hf, kc);
    OwProd r;
    r.V = uint(owVox(c, n)) | (uint(owVox(c, n - 1)) << 5) | (uint(owWheatStage(c.vh, c.lz, t)) << 10) |
          (uint(owVox(c, n + 1)) << 14);
    uint solidObj = (c.oHi > c.oLo && c.oMat != OW_TORCH) ? 1u : 0u;
    r.S = uint(clamp(c.h, 0, 31)) | (uint(clamp(c.oLo, 0, 31)) << 5) | (uint(clamp(c.oHi, 0, 31)) << 10) | (solidObj << 15);
    r.I = uint(c.top) | (uint(c.sub) << 5) | (uint(c.lx) << 10) | (uint(c.lz) << 13) |
          (uint(clamp(c.vb, 0, 31)) << 16) | (uint(c.style + 2) << 21) | (uint(clamp(c.h, 0, 31)) << 24) | (uint(c.biome) << 29);
    r.Id = c.id; r.Vh = c.vh; r.T = c.temp; r.M = c.moist;
    r.top = max(max(c.h, c.oHi), max(c.wTop, c.h + (c.deco != 0 ? 1 : 0)));   // first open level
    return r;
}

static inline bool owPackSolid(uint q, int Y) {
    if (Y < int(q & 31u)) return true;
    return ((q >> 15) & 1u) == 1u && Y >= int((q >> 5) & 31u) && Y < int((q >> 10) & 31u);
}

// The four cut-out plants, apart from the rest so the walk that tests their
// alpha does not carry every texture with it.
static float4 owCutTex(int m, int face, int2 tc, uint bh, thread const OwCol& c, float t) {
    float3 gt = owGrassTint(c.temp, c.moist);
    switch (m) {
    case OW_WHEAT: {
        int st = owWheatStage(c.vh, c.lz, t);
        float3 green = float3(0.36, 0.56, 0.18), gold = float3(0.82, 0.68, 0.30);
        float3 col = mix(green, gold, saturate(float(st - 3) / 3.0));
        if (face == 1) {
            if ((tc.x & 1) == 1) return float4(0.0);
            int ht = 2 + int(float(st) * 1.75) + int(owHash(bh + uint(tc.x)) % 3u) - 1;
            if (tc.y >= ht) return float4(0.0);
            float3 cc = col * (tc.y >= ht - 2 && st >= 5 ? 0.82 : 1.0) * (0.9 + 0.2 * owT(bh, tc, 32u));
            return float4(cc, 1.0);
        }
        bool dot = ((tc.x + 2 * tc.y) % 4) == 0 && (tc.y & 3) != 0;
        if (st >= 3) dot = dot || ((tc.x + 2 * tc.y) % 4) == 2;
        return dot ? float4(col * (0.85 + 0.25 * owT(bh, tc, 33u)), 1.0) : float4(0.0);
    }
    case OW_TALLGRASS: {
        bool snowy = c.top == OW_SNOW;
        float3 g = snowy ? float3(0.42, 0.50, 0.42) : gt;
        if (face == 1) {
            uint ch = owHash(bh + uint(tc.x) * 47u);
            if ((ch & 3u) == 0u) return float4(0.0);
            int ht = 2 + int((ch >> 4) % 7u);
            if (tc.y >= ht) return float4(0.0);
            return float4(g * (tc.y < 2 ? 0.75 : (0.9 + 0.25 * float(tc.y) / float(ht))), 1.0);
        }
        int2 d = tc - int2(4 + int(bh % 8u), 4 + int((bh >> 3) % 8u));
        bool on = (d.x == 0 && d.y >= -1 && d.y <= 1) || (d.y == 0 && abs(d.x) == 1) || (abs(d.x) == 2 && d.y == 1);
        return on ? float4(g * (d.y > 0 ? 1.15 : 0.95), 1.0) : float4(0.0);
    }
    case OW_FLOWER: {
        uint k = owHash(bh + 3u) % 4u;
        float3 pet = k == 0u ? float3(0.85, 0.18, 0.15) : (k == 1u ? float3(0.95, 0.82, 0.22) : (k == 2u ? float3(0.40, 0.48, 0.92) : float3(0.95, 0.93, 0.90)));
        if (face == 1) {
            if (tc.x == 7 && tc.y < 6) return float4(gt * 0.8, 1.0);
            if (tc.x == 8 && tc.y == 3) return float4(gt, 1.0);
            int2 d = abs(tc - int2(7, 7));
            if (d.x <= 1 && d.y <= 1 && !(d.x == 1 && d.y == 1)) return float4(d.x + d.y == 0 ? float3(0.95, 0.80, 0.25) : pet, 1.0);
            return float4(0.0);
        }
        int2 d = abs(tc - int2(7, 7));
        if (d.x + d.y == 0) return float4(0.95, 0.80, 0.25, 1.0);
        if (d.x + d.y == 1) return float4(pet, 1.0);
        return float4(0.0);
    }
    case OW_DEADBUSH: {
        float3 b = float3(0.48, 0.34, 0.18);
        if (face == 1) {
            int x = tc.x - 8;
            bool on = (tc.y < 4 && abs(x) <= 0) || (tc.y >= 3 && tc.y < 9 && (x == tc.y - 4 || -x == tc.y - 3));
            return on ? float4(b, 1.0) : float4(0.0);
        }
        return float4(0.0);
    }
    default: break;
    }
    return float4(0.0);
}

// Albedo and cut-out of a texel. em gets any light the texel gives off.
static float4 owTex(int m, int face, int2 tc, uint bh, thread const OwCol& c, int Y,
                    float t, float night, thread float3& em) {
    em = float3(0.0);
    float3 gt = owGrassTint(c.temp, c.moist);
    switch (m) {
    case OW_GRASS: {
        float r = owT(bh, tc, 20u);
        float clump = owT(bh, tc / 2, 19u);
        // Each block a shade apart from its neighbours, so the grid reads.
        float3 g = gt * (r < 0.16 ? 0.86 : (r < 0.88 ? 1.0 : 1.09)) * (0.96 + 0.06 * clump) * (0.95 + 0.08 * owU(bh));
        if (face == 0) return float4(g, 1.0);
        uint ch = owHash(bh + uint(tc.x) * 41u);
        int d = 2 + int(ch % 3u) + ((ch >> 8) % 6u == 0u ? 2 : 0);
        return float4(tc.y >= 16 - d ? g : owDirt(bh, tc), 1.0);
    }
    case OW_DIRT: return float4(owDirt(bh, tc), 1.0);
    case OW_STONE: return float4(owStone(bh, tc, face == 1), 1.0);
    case OW_SAND: {
        float r = owT(bh, tc, 21u);
        float3 s = float3(0.85, 0.79, 0.57) * (r < 0.15 ? 0.93 : (r > 0.93 ? 1.05 : 1.0)) * (0.96 + 0.06 * owU(bh));
        if (owT(bh, tc, 22u) < 0.03) s = float3(0.70, 0.62, 0.44);
        return float4(s, 1.0);
    }
    case OW_SANDSTONE: {
        float3 s = float3(0.82, 0.74, 0.52) * (0.96 + 0.06 * owT(bh, tc, 23u));
        if (tc.y <= 2) s *= 0.9;
        if (tc.y == 12) s *= 0.88;
        if (tc.y >= 13) s *= 1.04;
        return float4(s, 1.0);
    }
    case OW_SNOW: {
        float3 w = float3(0.90, 0.94, 0.99) * (owT(bh, tc, 24u) < 0.15 ? 0.93 : 1.0);
        if (face == 0) return float4(w, 1.0);
        uint ch = owHash(bh + uint(tc.x) * 43u);
        int d = 3 + int(ch % 2u) + ((ch >> 8) % 7u == 0u ? 2 : 0);
        return float4(tc.y >= 16 - d ? w : owDirt(bh, tc), 1.0);
    }
    case OW_ICE: {
        float3 i = float3(0.52, 0.72, 0.98) * (0.95 + 0.06 * owT(bh, tc, 25u));
        int dg = (tc.x + tc.y + int(bh % 13u)) % 11;
        if (dg == 0 && tc.x > 2 && tc.x < 13) i = float3(0.80, 0.90, 1.0);
        else if (dg == 1 && tc.x > 4 && tc.x < 11) i *= 1.08;
        return float4(i, 1.0);
    }
    case OW_LOG: case OW_BIRCH: case OW_SPRUCE:
        return float4(face == 0 ? owLogTop(tc, m) : owLogSide(bh, tc, m), 1.0);
    case OW_LEAVES: return float4(owLeaves(bh, tc, gt * float3(0.80, 0.88, 0.78)), 1.0);
    case OW_BLEAVES: return float4(owLeaves(bh, tc, gt * float3(1.05, 1.08, 0.80)), 1.0);
    case OW_SLEAVES: return float4(owLeaves(bh, tc, float3(0.17, 0.32, 0.24)), 1.0);
    case OW_CACTUS: {
        float3 g = float3(0.27, 0.50, 0.19);
        if (face == 0) {
            int2 d = abs(tc - 7);
            g *= (max(d.x, d.y) >= 6) ? 0.8 : (d.x + d.y < 3 ? 1.2 : 1.0);
        } else {
            if ((tc.x % 4) == 1) g *= 0.75;
            if (owT(bh, tc, 26u) < 0.05) g = float3(0.86, 0.85, 0.62);
        }
        return float4(g, 1.0);
    }
    case OW_WALL: {
        int st = c.style;
        int lv = Y - c.vb;
        if (face == 0) return float4(float3(0.4), 1.0);
        bool pillar = c.lx == 2 || c.lx == 6;
        float3 plank = st == 2 ? float3(0.40, 0.29, 0.17) : float3(0.66, 0.50, 0.30);
        if (st == 1) {
            // Sandstone house: smooth walls, a carved band.
            float3 s = float3(0.84, 0.76, 0.54) * (0.97 + 0.05 * owT(bh, tc, 27u));
            if (pillar) s *= (tc.x == 0 || tc.x == 15) ? 0.86 : 0.95;
            if (lv == 2 && (tc.y == 13 || tc.y == 14)) s *= 0.82;
            plank = s;
        }
        bool door = c.lx == 4 && lv <= 1;
        bool win = lv == 1 && (c.lx == 3 || c.lx == 5);
        uint hh = owHash(c.vh + uint(c.lx * 7 + c.lz * 131) + uint(Y) * 5u);
        if (door) {
            float3 d = st == 2 ? float3(0.30, 0.21, 0.13) : float3(0.45, 0.32, 0.18);
            if (tc.x < 2 || tc.x > 13) return float4(pillar ? plank : (st == 1 ? plank : owPlanks(bh, tc, plank)), 1.0);
            float3 dc = d * ((tc.x == 2 || tc.x == 13 || (tc.y & 7) == 0) ? 0.7 : 1.0);
            if (lv == 1 && tc.x >= 5 && tc.x <= 10 && tc.y >= 7 && tc.y <= 11) {
                float lit = smoothstep(owU(hh) * 0.5 + 0.1, owU(hh) * 0.5 + 0.25, night);
                dc = mix(float3(0.16, 0.20, 0.26), float3(1.0, 0.72, 0.36), lit);
                em = float3(1.0, 0.62, 0.28) * lit * 0.9;
            }
            if (lv == 0 && tc.x == 11 && tc.y == 8) dc = float3(0.75, 0.70, 0.40);
            return float4(dc, 1.0);
        }
        if (pillar && st != 1) return float4(owLogSide(bh, tc, st == 2 ? OW_SPRUCE : OW_LOG), 1.0);
        if (lv == 0 && st != 1) return float4(owCobble(bh, tc), 1.0);
        if (win && tc.x >= 3 && tc.x <= 12 && tc.y >= 3 && tc.y <= 12) {
            bool frame = tc.x == 3 || tc.x == 12 || tc.y == 3 || tc.y == 12 || tc.x == 7 || tc.x == 8 || tc.y == 8;
            if (frame) return float4(st == 1 ? float3(0.62, 0.52, 0.34) : plank * 0.7, 1.0);
            float lit = smoothstep(owU(hh) * 0.5 + 0.1, owU(hh) * 0.5 + 0.25, night);
            float3 glass = mix(float3(0.24, 0.33, 0.42) + 0.12 * float(tc.x + tc.y == 16), float3(1.0, 0.76, 0.40), lit);
            em = float3(1.0, 0.64, 0.30) * lit;
            return float4(glass, 1.0);
        }
        return float4(st == 1 ? plank : owPlanks(bh, tc, plank), 1.0);
    }
    case OW_ROOF: {
        if (face == 0 && c.style == 2) return float4(float3(0.90, 0.94, 0.99) * (owT(bh, tc, 28u) < 0.15 ? 0.93 : 1.0), 1.0);
        if (c.style == 1) {
            float3 s = float3(0.86, 0.78, 0.56) * (0.97 + 0.05 * owT(bh, tc, 29u));
            if (face == 1 && tc.y >= 12) s *= 0.9;
            return float4(s, 1.0);
        }
        float3 base = c.style == 2 ? float3(0.30, 0.21, 0.14) : float3(0.55, 0.26, 0.19);
        int ry = face == 0 ? tc.y : tc.y + 2;
        int row = ry / 4;
        float3 r = base * (0.92 + 0.14 * owT(bh, int2(row, (tc.x + row * 3) / 5), 30u));
        if ((ry & 3) == 0) r *= 0.66;
        if (((tc.x + row * 3) % 5) == 0) r *= 0.8;
        return float4(r, 1.0);
    }
    case OW_COBBLE: return float4(owCobble(bh, tc), 1.0);
    case OW_FARM: {
        if (face == 1) return float4(owDirt(bh, tc), 1.0);
        float3 f = float3(0.34, 0.22, 0.13) * (0.9 + 0.2 * owT(bh, tc, 31u));
        if ((tc.y & 3) == 0) f *= 0.68;
        return float4(f, 1.0);
    }
    case OW_PATH: {
        if (face == 1) return float4(owDirt(bh, tc), 1.0);
        float r = owT(bh, tc, 34u);
        float3 p = (c.style == 1 ? float3(0.74, 0.64, 0.44) : float3(0.60, 0.49, 0.31)) * (r < 0.2 ? 0.9 : (r > 0.9 ? 1.08 : 1.0));
        return float4(p, 1.0);
    }
    case OW_GRAVEL: {
        float r = owT(bh, tc / 2, 35u);
        float3 g = r < 0.3 ? float3(0.42, 0.40, 0.40) : (r < 0.6 ? float3(0.56, 0.53, 0.52) : (r < 0.85 ? float3(0.50, 0.45, 0.42) : float3(0.66, 0.64, 0.62)));
        return float4(g, 1.0);
    }
    case OW_POST: return float4(float3(0.36, 0.26, 0.15) * ((tc.x == 7 || tc.x == 8) ? 1.0 : 0.85), 1.0);
    case OW_TORCH: {
        int top = 9;
        if (face == 1 && tc.y >= top - 1) {
            float fl = 0.85 + 0.15 * sin(t * 7.0 + float(bh % 17u));
            em = float3(1.0, 0.7, 0.3) * 1.4 * fl;
            return float4(tc.y == top ? float3(1.0, 0.9, 0.5) : float3(1.0, 0.6, 0.2), 1.0);
        }
        if (face == 0) { em = float3(1.0, 0.8, 0.4) * 1.4; return float4(1.0, 0.9, 0.5, 1.0); }
        return float4(0.40, 0.29, 0.16, 1.0);
    }
    case OW_WHEAT: case OW_TALLGRASS: case OW_FLOWER: case OW_DEADBUSH:
        return owCutTex(m, face, tc, bh, c, t);
    case OW_PUMPKIN: {
        float3 o = float3(0.86, 0.50, 0.12);
        if (face == 0) {
            int2 d = abs(tc - 7);
            if (d.x <= 1 && d.y <= 1) return float4(0.38, 0.30, 0.12, 1.0);
            return float4(o * (((tc.x + 1) % 4) == 0 ? 0.78 : 1.0), 1.0);
        }
        return float4(o * (((tc.x + 1) % 4) == 0 ? 0.76 : 1.0) * (tc.y < 2 ? 0.85 : 1.0), 1.0);
    }
    case OW_HAY: {
        float3 h = float3(0.80, 0.66, 0.24) * (0.9 + 0.2 * owT(bh, tc, 37u));
        if (face == 1 && (tc.y == 3 || tc.y == 4 || tc.y == 11 || tc.y == 12)) h = float3(0.52, 0.30, 0.15);
        if (face == 0 && (tc.y == 3 || tc.y == 4 || tc.y == 11 || tc.y == 12)) h = float3(0.52, 0.30, 0.15);
        return float4(h, 1.0);
    }
    default: break;
    }
    return float4(1.0, 0.0, 1.0, 1.0);
}

// ---------------------------------------------------------------------------
// Animals. One may live in each 9×9 cell, strolling east and west around its
// spot, stopping to graze.

struct OwMob { int kind; float3 o; float dir; float graze; float step; };

static bool owMobAt(int2 cell, float t, float2 w, thread OwMob& mb) {
    float hr = hash21(float2(cell) + 0.37);
    if (hr > 0.42) return false;
    uint h = uint(hr * 4294967040.0 / 0.42);
    int2 a = cell * 12 + int2(5 + int((h >> 3) % 3u), 3 + int((h >> 11) % 6u));
    float T = t * 0.9 + owU(owHash(h + 1u)) * 400.0;
    float seg = floor(T / 9.0), ft = T - seg * 9.0;
    float x0 = (hash21(float2(seg, hr * 97.0)) - 0.5) * 6.0;
    float x1 = (hash21(float2(seg + 1.0, hr * 97.0)) - 0.5) * 6.0;
    float k = smoothstep(0.0, 4.0, ft);
    float x = float(a.x) + 0.5 + mix(x0, x1, k);
    x = floor(x * 16.0 + 0.5) / 16.0;
    if (abs(w.x - x) > 0.9) return false;
    float z = float(a.y) + 0.25;
    // Quick reject on the screen line before any noise: feet at y in [5, 10].
    if (w.y < z + 4.5 || w.y > z + 12.5) return false;
    float2 fa = float2(a) + 0.5;
    float ha = owBaseH(fa);
    if (ha < 5.0 || ha >= 10.0) return false;
    if (owRiver(fa) < 0.075) return false;
    float2 cl = owClimateAt(floor(fa / 5.0) * 5.0 + 2.5);
    int bi = owBiome(ha, cl.x, cl.y);
    if (bi == OW_DESERT || bi == OW_MOUNT) return false;
    OwVil v = owVillage(a);
    if (v.on == 1 && length(fa - v.c) < v.R + 6.0) return false;
    float hx = owBaseH(float2(x, z + 0.25));
    float g = floor(hx);
    if (g <= float(OW_W)) return false;
    mb.kind = bi == OW_SNOWY ? 0 : int((h >> 19) % 4u);
    if (bi == OW_FOREST && mb.kind == 1) mb.kind = 2;
    mb.dir = (x1 - x0) >= 0.0 ? 1.0 : -1.0;
    bool walking = ft < 4.0 && abs(x1 - x0) > 0.2;
    mb.graze = (!walking && fract(ft * 0.23 + owU(h)) < 0.55) ? 1.0 : 0.0;
    mb.step = walking ? floor(fract(T * 2.2) * 2.0) : 0.0;
    mb.o = float3(x, g, z);
    return true;
}

// Box i (in 1/16 block, x forward from the body's middle) of a creature kind.
// part: 0 body, 1 head, 2 leg, 3 snout/beak, 4 comb.
static inline bool owMobBox(int kind, int i, float graze, float stp,
                            thread float3& lo, thread float3& hi, thread int& part) {
    float g = graze * 5.0;
    float ls = stp;   // legs shuffle one texel while walking
    if (kind == 0) {        // woolly
        switch (i) {
        case 0: lo = float3(-7, 5, 1); hi = float3(7, 13, 9); part = 0; return true;
        case 1: lo = float3(5, 9 - g, 2); hi = float3(11, 15 - g, 8); part = 1; return true;
        case 2: lo = float3(-6 + ls, 0, 1); hi = float3(-3 + ls, 5, 3); part = 2; return true;
        case 3: lo = float3(3 - ls, 0, 1); hi = float3(6 - ls, 5, 3); part = 2; return true;
        default: return false;
        }
    } else if (kind == 1) { // spotted grazer
        switch (i) {
        case 0: lo = float3(-8, 6, 0); hi = float3(8, 15, 10); part = 0; return true;
        case 1: lo = float3(7, 10 - g, 2); hi = float3(13, 16 - g, 8); part = 1; return true;
        case 2: lo = float3(-7 + ls, 0, 0); hi = float3(-4 + ls, 6, 3); part = 2; return true;
        case 3: lo = float3(4 - ls, 0, 0); hi = float3(7 - ls, 6, 3); part = 2; return true;
        case 4: lo = float3(9, 16 - g, 2); hi = float3(10, 17 - g, 8); part = 4; return true;
        default: return false;
        }
    } else if (kind == 2) { // snuffler
        switch (i) {
        case 0: lo = float3(-6, 3, 1); hi = float3(6, 10, 8); part = 0; return true;
        case 1: lo = float3(5, 4 - g * 0.4, 1); hi = float3(10, 10 - g * 0.4, 8); part = 1; return true;
        case 2: lo = float3(10, 4 - g * 0.4, 3); hi = float3(11, 7 - g * 0.4, 6); part = 3; return true;
        case 3: lo = float3(-5 + ls, 0, 1); hi = float3(-3 + ls, 3, 3); part = 2; return true;
        case 4: lo = float3(3 - ls, 0, 1); hi = float3(5 - ls, 3, 3); part = 2; return true;
        default: return false;
        }
    } else {                // hen
        switch (i) {
        case 0: lo = float3(-3, 2, 3); hi = float3(3, 7, 7); part = 0; return true;
        case 1: lo = float3(1, 6 - g * 0.6, 4); hi = float3(4, 10 - g * 0.6, 6); part = 1; return true;
        case 2: lo = float3(4, 7 - g * 0.6, 4); hi = float3(5, 8 - g * 0.6, 6); part = 3; return true;
        case 3: lo = float3(2, 10 - g * 0.6, 4); hi = float3(3, 11 - g * 0.6, 6); part = 4; return true;
        case 4: lo = float3(-1, 0, 4); hi = float3(0, 2, 5); part = 2; return true;
        default: return false;
        }
    }
}

static inline float3 owMobTex(int kind, int part, int face, int2 tc, int2 sz, float dir, uint mh) {
    // tf counts texels from the creature's tail end of this box toward its nose.
    int tf = dir > 0.0 ? tc.x : sz.x - 1 - tc.x;
    if (kind == 0) {
        if (part == 0) return float3(0.88, 0.86, 0.80) * (0.9 + 0.15 * owU(owHash(mh ^ uint(tc.x * 31 + tc.y * 7 + face))));
        if (part == 1) {
            if (face == 1 && tf == sz.x - 2 && tc.y == sz.y - 3) return float3(0.05);
            if (face == 1 && tf == sz.x - 3 && tc.y == sz.y - 3) return float3(0.9);
            if (tf <= 1) return float3(0.86, 0.84, 0.78);
            return float3(0.30, 0.25, 0.22);
        }
        return float3(0.30, 0.25, 0.22);
    }
    if (kind == 1) {
        float3 brown = float3(0.33, 0.22, 0.15);
        if (part == 4) return float3(0.85, 0.82, 0.72);
        if (part == 0 || part == 2) {
            uint p = owHash(mh ^ uint((tc.x / 3) * 13 + (tc.y / 3) * 101 + face * 7));
            return (p % 3u == 0u) ? float3(0.88, 0.86, 0.82) : brown;
        }
        if (face == 1 && tf == sz.x - 3 && tc.y == sz.y - 2) return float3(0.05);
        if (tf >= sz.x - 2 && tc.y < 3) return float3(0.80, 0.70, 0.62);
        return brown;
    }
    if (kind == 2) {
        float3 pink = float3(0.90, 0.62, 0.60);
        if (part == 3) return (face == 1 && tc.y == 1) ? float3(0.55, 0.30, 0.30) : float3(0.95, 0.70, 0.68);
        if (part == 1 && face == 1 && tf == sz.x - 2 && tc.y == sz.y - 2) return float3(0.05);
        if (part == 2) return pink * 0.85;
        return pink * (0.95 + 0.08 * owU(owHash(mh ^ uint(tc.x * 31 + tc.y))));
    }
    if (part == 3) return float3(0.95, 0.72, 0.15);
    if (part == 4) return float3(0.85, 0.12, 0.10);
    if (part == 2) return float3(0.90, 0.70, 0.20);
    if (part == 1 && face == 1 && tf == sz.x - 1 && tc.y == sz.y - 2) return float3(0.05);
    return float3(0.94, 0.93, 0.90) * (part == 0 && face == 1 && tc.y > 1 && tc.y < 4 && tf < 4 ? 0.85 : 1.0);
}

// ---------------------------------------------------------------------------
// Cloud shadows: the clouds themselves are above the picture; only their
// shadows cross the map, blown east, stepped to the texel like everything else.

static inline float owCloudShade(float2 xz, float t, float cover) {
    float2 q = float2((xz.x - t * 0.6) * (1.0 / 19.0), xz.y * (1.0 / 9.0));
    float n = valueNoise(q + 200.0);
    return smoothstep(mix(0.95, 0.5, cover), mix(0.95, 0.5, cover) + 0.015, n);
}

// ---------------------------------------------------------------------------

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float2 res = u.resolution;
    float t = u.time;
    float rr = res.y / (u.blocks * 16.0);
    float T = rr >= 1.0 ? round(rr) : rr;          // screen pixels per texel
    float B = 16.0 * T;

    // The pan: east, meandering north and south. Whole pixels only.
    float pt = t * u.speed;
    float2 cam = float2(pt + u.seed * 4111.0,
                        18.0 * sin(pt / 90.0 + u.seed * 6.2832) + 8.0 * sin(pt / 40.0 + 1.3 + u.seed * 17.0) + u.seed * 2333.0);
    // Every visit opens on a village: the world is shifted so the first valid
    // one along the path sits at the centre of the screen at t = 5 s.
    int2 startCell = int2(-999999);
    {
        float2 c5 = float2(5.0 * u.speed + u.seed * 4111.0, cam.y);
        float2 shift = float2(0.0);
        for (int i = 0; i < 3; i++) {
            int2 probe = int2(floor(c5)) + int2(i * 45, 22);
            int2 vc = owVCell(probe);
            if (owU(owH3(vc.x, vc.y, 4049)) >= 0.55) continue;
            OwVil v = owVillage(probe);
            shift = floor(v.c - float2(c5.x, c5.y - 2.0));
            startCell = vc;
            break;
        }
        cam += shift;
    }
    float2 origin = floor(cam * B - 0.5 * res);
    float2 pix = float2(floor(pos.x), floor(res.y - pos.y));
    float2 tex = floor((pix + origin) / T);
    float2 w = (tex + 0.5) / 16.0;                 // (world x, screen-up v) in blocks

    int X = int(floor(w.x));
    float fx = w.x - float(X);
    int vi = int(floor(w.y));
    float f = w.y - float(vi);

    // --- Walk the line of sight from the nearest column back.
    int hm = OW_AIR, hface = 0, hY = 0, hZ = 0;
    float2 huv = float2(0.0);
    float hz = 1e9;                                 // world z of the hit
    float wEntry = -1.0;
    OwCell kc;
    kc.id = int2(-999999);
    OwVC kv;
    kv.id = int2(-999999);
    kv.sc = startCell;
    // Lanes of a SIMD group run in lockstep. At display sizes a group sits
    // inside one block or across one block edge, so its lanes look down at
    // most two lines (x and x + 1) from at most two block rows, and would
    // walk the same columns one after another. Instead lane k builds column k
    // of each line once and packs it; every lane then walks its line, and
    // probes it for shadow and corners, by shuffles. Anything else (a group
    // cut by the screen edge, or texels under a pixel) walks serially below;
    // the two paths read the same world through the same functions.
    uint lane = simd_prefix_exclusive_sum(1u);
    int Xm = simd_min(X), vm = simd_min(vi);
    bool coop = simd_sum(1u) == 32u && simd_all(X - Xm <= 1 && vi - vm <= 1);
    bool two = coop && simd_any(X != Xm);
    bool mine0 = X == Xm;
    int dv = vi - vm;
    int ZB = vm - OW_YMAX;                          // lane 0's column
    OwProd P0, P1;
    P0.V = P0.S = P0.I = P0.Id = P0.Vh = 0u; P0.T = P0.M = 0.0; P0.top = 0; P1 = P0;
    if (coop) {
        int Zl = ZB + int(lane);
        P0 = owProduce(int2(Xm, Zl), vm - Zl, t, kc, kv);
        if (two) P1 = owProduce(int2(Xm + 1, Zl), vm - Zl, t, kc, kv);
        // Nothing in the group's columns reaches level 'top', so the walk
        // starts where the highest line first meets it, and stops once every
        // lane has its hit.
        int top = simd_max(max(P0.top, P1.top));
        int k0 = clamp(OW_YMAX - top - 1, 0, OW_YMAX - 1);
        for (int k = k0; k < OW_YMAX; k++) {
            if (simd_all(hm != OW_AIR)) break;
            ushort src = ushort(min(k + dv, 31));
            uint q0 = simd_shuffle(P0.V, src);
            uint q1 = two ? simd_shuffle(P1.V, src) : 0u;
            uint q = mine0 ? q0 : q1;
            if (hm != OW_AIR) continue;
            int n = OW_YMAX - k;
            int Z = vi - n;
            for (int j = 0; j < 2; j++) {
                int Y = n - j;
                // The producer's own entry level is n - dv.
                int m = dv == 0 ? int((q >> (5 * j)) & 31u) : (j == 0 ? int((q >> 14) & 31u) : int(q & 31u));
                if (m == OW_AIR) continue;
                if (m == OW_WATER) {
                    if (wEntry < 0.0) wEntry = float(Z) + (j == 0 ? 0.0 : f);
                    continue;
                }
                float3 lo, hi;
                owShape(m, lo, hi);
                int face; float2 uv; float zl;
                if (!owBoxHit(f + float(j), fx, lo, hi, face, uv, zl)) continue;
                if (owCutout(m) && !owCutAlpha(m, face, clamp(int2(floor(uv * 16.0)), 0, 15), owH3(X, Y, Z), int((q >> 10) & 15u))) continue;
                hm = m; hface = face; huv = uv; hY = Y; hZ = Z; hz = float(Z) + zl;
                break;
            }
        }
    } else {
        // Along one line of sight x is fixed, so each octave of the base height's
        // value noise is one interpolation in z between edge values that change
        // only every 9.5 or 24 columns: a few hashes per pixel instead of eight
        // per column. (Same arithmetic as owBaseH, so the two agree.)
        float sx1 = (float(X) + 0.5) * (1.0 / 24.0), sx2 = (float(X) + 0.5) * (1.0 / 9.5) + 31.7;
        float ix1 = floor(sx1), ix2 = floor(sx2);
        float ux1 = fract(sx1), ux2 = fract(sx2);
        ux1 = ux1 * ux1 * (3.0 - 2.0 * ux1); ux2 = ux2 * ux2 * (3.0 - 2.0 * ux2);
        float j1 = -1e9, j2 = -1e9, e1a = 0.0, e1b = 0.0, e2a = 0.0, e2b = 0.0;
        int2 tId = int2(-999999); uint tTh = 0u; int2 tCtr = int2(0);
        // Value noise is a convex blend of its lattice values, so the edge values
        // spanning this line bound its base height; every level above that bound
        // (plus the tallest tree, or a village roof) is open air and is skipped.
        int nStart = OW_YMAX;
        {
            float zl = (float(vi - OW_YMAX) + 0.5), zh = (float(vi) + 0.5);
            // m: this line; w: raw lattice values for x - 1 … x + 1, where tree
            // centres whose crowns reach this line can stand.
            float m1 = 0.0, m2 = 0.0, w1 = 0.0, w2 = 0.0;
            float a1 = floor(zl * (1.0 / 24.0)), a2 = floor(zl * (1.0 / 9.5) + 31.7);
            float b1 = floor(zh * (1.0 / 24.0)), b2 = floor(zh * (1.0 / 9.5) + 31.7);
            float l1 = floor((float(X) - 0.5) * (1.0 / 24.0)), l2 = floor((float(X) - 0.5) * (1.0 / 9.5) + 31.7);
            float r1 = floor((float(X) + 1.5) * (1.0 / 24.0)) + 1.0, r2 = floor((float(X) + 1.5) * (1.0 / 9.5) + 31.7) + 1.0;
            for (int i = 0; i < 3; i++) {
                float jn = min(a1 + float(i), b1 + 1.0);
                float h0 = hash21(float2(ix1, jn)), h1 = hash21(float2(ix1 + 1.0, jn));
                m1 = max(m1, mix(h0, h1, ux1));
                w1 = max(w1, max(max(h0, h1), max(hash21(float2(l1, jn)), hash21(float2(r1, jn)))));
            }
            for (int i = 0; i < 4; i++) {
                float jn = min(a2 + float(i), b2 + 1.0);
                float h0 = hash21(float2(ix2, jn)), h1 = hash21(float2(ix2 + 1.0, jn));
                m2 = max(m2, mix(h0, h1, ux2));
                w2 = max(w2, max(max(h0, h1), max(hash21(float2(l2, jn)), hash21(float2(r2, jn)))));
            }
            float bm = m1 * 0.65 + m2 * 0.35, bw = w1 * 0.65 + w2 * 0.35;
            int hmax = int(floor(1.0 + bm * 9.0 + 6.0 * smoothstep(0.62, 0.86, bm)));
            int hwide = int(floor(1.0 + bw * 9.0 + 6.0 * smoothstep(0.62, 0.86, bw)));
            int top = max(hmax, min(hwide, 10) + 7);
            top = max(top, OW_W + 7);   // village roofs and lamps never pass this
            nStart = min(OW_YMAX, top + 1);
        }
        for (int k = OW_YMAX - nStart; k < OW_YMAX; k++) {
            int n = OW_YMAX - k;
            int Z = vi - n;
            int2 p = int2(X, Z);
            float sy1 = (float(Z) + 0.5) * (1.0 / 24.0), sy2 = (float(Z) + 0.5) * (1.0 / 9.5) + 31.7;
            float jj1 = floor(sy1), jj2 = floor(sy2);
            if (jj1 != j1) {
                e1a = jj1 == j1 + 1.0 ? e1b : mix(hash21(float2(ix1, jj1)), hash21(float2(ix1 + 1.0, jj1)), ux1);
                e1b = mix(hash21(float2(ix1, jj1 + 1.0)), hash21(float2(ix1 + 1.0, jj1 + 1.0)), ux1);
                j1 = jj1;
            }
            if (jj2 != j2) {
                e2a = jj2 == j2 + 1.0 ? e2b : mix(hash21(float2(ix2, jj2)), hash21(float2(ix2 + 1.0, jj2)), ux2);
                e2b = mix(hash21(float2(ix2, jj2 + 1.0)), hash21(float2(ix2 + 1.0, jj2 + 1.0)), ux2);
                j2 = jj2;
            }
            float uy1 = fract(sy1), uy2 = fract(sy2);
            uy1 = uy1 * uy1 * (3.0 - 2.0 * uy1); uy2 = uy2 * uy2 * (3.0 - 2.0 * uy2);
            float b = mix(e1a, e1b, uy1) * 0.65 + mix(e2a, e2b, uy2) * 0.35;
            float hf = 1.0 + b * 9.0 + 6.0 * smoothstep(0.62, 0.86, b);
            owEnsureV(p, kv);
            // Cheap bound: base height, this cell's tree footprint, the village.
            int2 tcl = int2(floor((float2(p) + 0.5) / 5.0));
            int bnd = int(floor(hf));
            if (all(tcl == kc.id)) {
                int2 d = p - kc.ctr;
                if (kc.kind >= 0 && abs(d.x) <= 1 && abs(d.y) <= 1) bnd = max(bnd, kc.g + 7);
            } else {
                if (any(tcl != tId)) {
                    tId = tcl; tTh = owH3(tcl.x, tcl.y, 911);
                    tCtr = tcl * 5 + int2(1 + int((tTh >> 4) % 3u), 1 + int((tTh >> 12) % 3u));
                }
                int2 d = p - tCtr;
                if (owU(tTh) < 0.6 && abs(d.x) <= 1 && abs(d.y) <= 1) bnd = max(bnd, min(bnd, 10) + 9);
            }
            if (kv.vOK == 1 && length(float2(p) + 0.5 - kv.v.c) < kv.v.R + 6.0) bnd = max(bnd, kv.v.vb + 6);
            if (n - 1 >= bnd) continue;
            owEnsure(p, kc, kv);
            if (n - 1 >= owBound(p, hf, kc, kv)) continue;
            OwCol c = owColumn(p, hf, kc);
            bool done = false;
            for (int j = 0; j < 2; j++) {
                int Y = n - j;
                int m = owVox(c, Y);
                if (m == OW_AIR) continue;
                float s = f + float(j);
                if (m == OW_WATER) {
                    if (wEntry < 0.0) wEntry = float(Z) + (j == 0 ? 0.0 : f);
                    continue;
                }
                float3 lo, hi;
                owShape(m, lo, hi);
                int face; float2 uv; float zl;
                if (!owBoxHit(s, fx, lo, hi, face, uv, zl)) continue;
                if (owCutout(m)) {
                    float3 em;
                    int2 tc = clamp(int2(floor(uv * 16.0)), 0, 15);
                    if (!owCutAlpha(m, face, tc, owH3(X, Y, Z), owWheatStage(c.vh, c.lz, t))) continue;
                }
                hm = m; hface = face; huv = uv; hY = Y; hZ = Z; hz = float(Z) + zl;
                done = true;
                break;
            }
            if (done) break;
        }

    }

    OwCol hc;
    if (coop) {
        ushort src = ushort(clamp(hZ - ZB, 0, 31));
        uint qi = simd_shuffle(P0.I, src), id = simd_shuffle(P0.Id, src), vh = simd_shuffle(P0.Vh, src);
        float te = simd_shuffle(P0.T, src), mo = simd_shuffle(P0.M, src);
        if (two) {
            uint qi1 = simd_shuffle(P1.I, src), id1 = simd_shuffle(P1.Id, src), vh1 = simd_shuffle(P1.Vh, src);
            float te1 = simd_shuffle(P1.T, src), mo1 = simd_shuffle(P1.M, src);
            if (!mine0) { qi = qi1; id = id1; vh = vh1; te = te1; mo = mo1; }
        }
        hc.id = id; hc.vh = vh; hc.temp = te; hc.moist = mo;
        hc.top = int(qi & 31u); hc.sub = int((qi >> 5) & 31u);
        hc.lx = int((qi >> 10) & 7u); hc.lz = int((qi >> 13) & 7u);
        hc.vb = int((qi >> 16) & 31u); hc.style = int((qi >> 21) & 7u) - 2;
        hc.h = int((qi >> 24) & 31u); hc.biome = int((qi >> 29) & 7u);
        hc.wTop = 0; hc.deco = 0; hc.oLo = 0; hc.oHi = 0; hc.oMat = 0; hc.tTop = 0; hc.tMat = 0; hc.plot = 0;
    } else {
        int2 p = int2(X, hZ);
        owEnsureV(p, kv);
        owEnsure(p, kc, kv);
        hc = owColumn(p, owBaseH(float2(p) + 0.5), kc);
    }

    // --- Day and night.
    float phase = fract(t / u.dayLength + 0.05 + 0.3 * u.seed);
    const float dayF = 0.66;
    float e, az;
    if (phase < dayF) { float a = phase / dayF; e = sin(PI * a); az = cos(PI * a); }
    else { float a = (phase - dayF) / (1.0 - dayF); e = -sin(PI * a); az = -cos(PI * a); }
    float sunUp = smoothstep(-0.04, 0.22, e);
    float night = 1.0 - smoothstep(-0.12, 0.16, e);
    // The sun crosses behind the map (north), so shadows fall toward the
    // viewer and lengthen toward dawn and dusk. Keeping it in the x = const
    // plane keeps every shadow probe on the pixel's own line of sight.
    (void)az;
    float3 Ls = normalize(float3(0.0, max(e, 0.0) + 0.32, 0.42));
    float3 Lm = normalize(float3(0.0, 0.85, 0.42));
    float3 L = e > -0.03 ? Ls : Lm;
    float3 sunCol = mix(float3(1.0, 0.58, 0.32), float3(1.0, 0.95, 0.86), smoothstep(0.08, 0.5, e)) * 0.72 * sunUp;
    float3 moonCol = float3(0.20, 0.25, 0.40) * night;
    float3 amb = mix(float3(0.06, 0.075, 0.15), float3(0.30, 0.35, 0.46), smoothstep(-0.18, 0.3, e));
    amb = mix(amb, amb * float3(1.15, 0.9, 0.8), (1.0 - smoothstep(0.05, 0.4, e)) * sunUp);

    // --- Animals in front of the hit?
    OwMob mb; bool mobHit = false; int mPart = 0, mFace = 0; int2 mtc = int2(0), msz = int2(1);
    float mz = hz; uint mHash = 0u;
    float shadowMob = 1.0;
    {
        // A creature roams x in [5, 8] ± 3 of its 12-wide cell, so only this
        // pixel's own cell column can hold one; two cells cover the depths.
        int cx0 = int(floor(w.x / 12.0));
        int cz0 = int(floor((w.y - 17.0) / 12.0));
        for (int ci = 0; ci < 2; ci++) {
            int2 cell = int2(cx0, cz0 + ci);
            OwMob m;
            if (!owMobAt(cell, t, w, m)) continue;
            // Contact shadow on the ground just south of the body.
            if (hface == 0 && abs(float(hY + 1) - (hm == OW_FARM || hm == OW_PATH ? 1.0 / 16.0 : 0.0) - m.o.y) < 0.01) {
                float px = w.x, pz = hz;
                if (abs(px - m.o.x) < 0.42 && pz > m.o.z - 0.2 && pz < m.o.z + 0.6) shadowMob = 0.6;
            }
            for (int i = 0; i < 5; i++) {
                float3 lo, hi; int part;
                if (!owMobBox(m.kind, i, m.graze, m.step, lo, hi, part)) break;
                float x0 = m.o.x + m.dir * lo.x / 16.0, x1 = m.o.x + m.dir * hi.x / 16.0;
                float3 wlo = float3(min(x0, x1), m.o.y + lo.y / 16.0, m.o.z + lo.z / 16.0);
                float3 whi = float3(max(x0, x1), m.o.y + hi.y / 16.0, m.o.z + hi.z / 16.0);
                if (w.x < wlo.x || w.x > whi.x) continue;
                float y = w.y - wlo.z, zz;
                int fc;
                float2 uvb;
                if (y >= wlo.y && y <= whi.y) { fc = 1; zz = wlo.z; uvb = float2(w.x - wlo.x, y - wlo.y); }
                else {
                    zz = w.y - whi.y;
                    if (zz < wlo.z || zz > whi.z) continue;
                    fc = 0; uvb = float2(w.x - wlo.x, zz - wlo.z);
                }
                if (zz < mz) {
                    mz = zz; mobHit = true; mb = m; mPart = part; mFace = fc;
                    msz = int2(round((whi.x - wlo.x) * 16.0), round((fc == 1 ? whi.y - wlo.y : whi.z - wlo.z) * 16.0));
                    mtc = clamp(int2(floor(uvb * 16.0)), int2(0), msz - 1);
                    mHash = uint(hash21(float2(cell) + 0.37) * 4294967040.0 / 0.42);
                }
            }
        }
    }

    // --- Shade the hit.
    float3 P, N;
    if (mobHit) {
        P = float3(w.x, w.y - mz, mz);
        N = mFace == 1 ? float3(0.0, 0.0, -1.0) : float3(0.0, 1.0, 0.0);
    } else {
        P = float3(w.x, w.y - hz, hz);
        N = hface == 1 ? float3(0.0, 0.0, -1.0) : float3(0.0, 1.0, 0.0);
    }

    if (hc.style == -2 && !mobHit) {
        OwVil v = owVillage(int2(X, hZ));
        float2 vcl = owClimateAt(floor(v.c));
        int vb = owBiome(7.0, vcl.x, vcl.y);
        hc.style = vb == OW_DESERT ? 1 : (vb == OW_SNOWY ? 2 : 0);
        if (hc.top == OW_GRASS) hc.top = hc.style == 1 ? OW_SAND : (hc.style == 2 ? OW_SNOW : OW_GRASS);
        if (hc.style == 1) hc.sub = OW_SANDSTONE;
        if (hm == OW_GRASS && hY == hc.h - 1) hm = hc.top;
    }
    float3 em = float3(0.0);
    float3 alb;
    if (mobHit) alb = owMobTex(mb.kind, mPart, mFace, mtc, msz, mb.dir, mHash);
    else {
        int2 tc = clamp(int2(floor(huv * 16.0)), 0, 15);
        alb = owTex(hm, hface, tc, owH3(X, hY, hZ), hc, hY, t, night, em).rgb;
    }

    // Sun (or moon) shadow on tops: six probes up the light, every one on
    // this line (shared by shuffle when cooperative). South faces take a fill
    // light and are not probed.
    float sh = 1.0;
    float aoT = 1.0;
    {
        float3 q0 = P + N * 0.02;
        bool top = N.y > 0.5;
        for (int i = 0; i < 5; i++) {
            float dy = 0.35 + 0.95 * float(i);
            float3 q = q0 + L * (dy / L.y);
            int Zq = int(floor(q.z)), Yq = int(floor(q.y));
            bool solid;
            if (coop) {
                int ln = Zq - ZB;
                ushort src = ushort(clamp(ln, 0, 31));
                uint s0 = simd_shuffle(P0.S, src);
                uint s1 = two ? simd_shuffle(P1.S, src) : 0u;
                solid = ln >= 0 && ln < 32 && owPackSolid(mine0 ? s0 : s1, Yq);
            } else {
                solid = top && sh > 0.0 && owSolid(int3(X, Yq, Zq), kc, kv);
            }
            if (top && solid) sh = 0.0;
        }
        // Corners: a top's north edge against a wall, a face's foot on the ground.
        int2 tc = clamp(int2(floor(huv * 16.0)), 0, 15);
        int Za = hface == 0 ? hZ + 1 : hZ - 1;
        int Ya = hface == 0 ? hY + 1 : hY - 1;
        bool want = !mobHit && ((hface == 0 && tc.y > 12) || (hface == 1 && tc.y < 3 && hm != OW_TORCH && hm != OW_POST));
        bool solidA;
        if (coop) {
            int ln = Za - ZB;
            ushort src = ushort(clamp(ln, 0, 31));
            uint s0 = simd_shuffle(P0.S, src);
            uint s1 = two ? simd_shuffle(P1.S, src) : 0u;
            solidA = ln >= 0 && ln < 32 && owPackSolid(mine0 ? s0 : s1, Ya);
        } else {
            solidA = want && owSolid(int3(X, Ya, Za), kc, kv);
        }
        if (want && solidA) aoT = hface == 0 ? 0.70 + 0.1 * float(15 - tc.y) : 0.72 + 0.09 * float(tc.y);
    }
    // Cloud shadows.
    float cover = u.clouds;
    if (cover > 0.0 && sh > 0.0) {
        float3 q = P + L * ((OW_YC - P.y) / L.y);
        sh *= 1.0 - 0.32 * owCloudShade(q.xz, t, cover);
    }
    sh *= shadowMob;

    float ao = aoT;

    bool plant = !mobHit && (owCutout(hm) || hm == OW_TORCH);
    if (plant) { N = float3(0.0, 1.0, 0.0); ao = 1.0; }
    // Tops take the light; south faces a fill, so cliffs read but never go black.
    float ndl = N.y > 0.5 ? max(L.y, 0.0) : 0.6 * max(L.y, 0.0) + max(-L.z, 0.0);
    float faceAmb = N.y > 0.5 ? 1.0 : 0.9;
    float3 lightCol = sunCol + moonCol;
    float3 light = amb * faceAmb * ao + lightCol * ndl * sh * mix(1.0, ao, 0.5);

    // Lamps and windows at night: stepped warm pools around each lit house.
    if (night > 0.01) {
        owEnsureV(int2(floor(P.xz)), kv);
        OwVil v = kv.v;
        if (kv.vOK == 1) {
            float2 vcen = floor(v.c);
            float2 q = P.xz - vcen + 32.0;
            // The four plots whose lamps and doors are nearest.
            int2 pi0 = int2(floor((q - float2(3.0, 1.5)) / 8.0));
            float tl = 0.0;
            for (int i = 0; i < 4; i++) {
                int2 pi = pi0 + int2(i & 1, i >> 1);
                float2 pc = vcen - 32.0 + float2(pi) * 8.0 + 4.0;
                if (length(pc - v.c) >= v.R - 4.0) continue;
                uint ph = owH3(pi.x + int(v.hs & 1023u), pi.y, 77);
                if (owU(ph) >= 0.5) continue;
                float2 o = vcen - 32.0 + float2(pi) * 8.0;
                float3 lamp = float3(o.x + 1.5, float(v.vb) + 1.6, o.y + 1.5);
                float3 door = float3(o.x + 4.5, float(v.vb) + 1.0, o.y + 1.4);
                float d1 = length(P - lamp), d2 = length(P - door);
                tl += max(0.0, 1.0 - d1 / 7.0) + 0.6 * max(0.0, 1.0 - d2 / 5.0);
            }
            tl = floor(saturate(tl) * 7.0) / 7.0;
            light += float3(1.0, 0.62, 0.30) * tl * 1.1 * night * (faceAmb > 0.9 ? 1.0 : 0.8);
        }
    }

    float3 col = alb * light + em * night + (hm == OW_TORCH && !mobHit ? em * 0.6 : float3(0.0));

    // Water between the eye and the hit: clear in the shallows, deep blue beyond.
    if (wEntry >= 0.0 && (!mobHit || mz > wEntry)) {
        float depth = max(float(OW_W) - P.y, 0.0);
        float3 wc = float3(0.08, 0.20, 0.40) * (amb * 1.2 + lightCol * 0.6);
        float tr = exp(-1.3 * depth) * 0.8;
        col = mix(wc, col * float3(0.75, 0.9, 1.0), tr);
        // Surface ripples: short one-texel crests drifting north.
        float2 sp = floor(float2(w.x, wEntry) * 16.0);
        float wv = fract((sp.y + 3.0 * sin(sp.x * 0.11 + t * 0.35)) / 23.0 - t * 0.012);
        uint seg = owH3(int(floor(sp.x / 5.0)), int(floor((sp.y + 3.0 * sin(sp.x * 0.11 + t * 0.35)) / 23.0 - t * 0.012)), 3);
        if (wv < 0.045 && owU(seg) < 0.45) col += float3(0.11, 0.15, 0.19) * (amb + lightCol * 0.7);
        if (hz - wEntry < 0.9 && owU(owH3(int(tex.x), int(floor(wEntry * 16.0)), int(floor(t * 1.5)))) < 0.18)
            col += float3(0.07, 0.08, 0.09) * (amb + lightCol);
    }

    col = lerpDither(col, pos);
    return half4(half3(saturate(col)), 1.0h);
}
