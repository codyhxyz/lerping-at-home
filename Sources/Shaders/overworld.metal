// Overworld — a Minecraft world drawn as a top-down map, in the game's own
// textures (bound from the copy installed on this Mac; see PORTING.md).
//
// lerp-category: Minecraft
// lerp-requires: minecraft mobs
//
// The screen is a picture plane in cabinet oblique: one block is 16×16 texels
// on top and 16×16 on its south face, and a block one level higher sits one
// block further up the screen. Texels land on whole screen pixels (the texel
// size is rounded to an integer for the display, and the pan moves in whole
// pixels), so every 16×16 face of the game's art maps texel for texel and
// never shimmers. mcTile is used for every face: at a whole-pixel texel size
// and a sample on a texel centre (which this projection always gives) it is
// exactly a nearest lookup; where texels fall under a pixel (thumbnails) it
// mip-filters instead of aliasing. Alpha tests use read(), one exact texel.
//
// The map pans slowly over a seeded world of plains, birch and oak woods,
// snowy spruce taiga, desert with cacti, stone peaks, lakes and rivers, and
// every visit opens on a village: houses of cobblestone, planks and logs (cut
// sandstone in the desert, spruce under snow) with glass windows and doors,
// dirt paths, lamp posts (a fence post and a torch), moist farmland on
// irrigation channels where wheat grows through its eight stages and is
// replanted, hay bales, pumpkins and flowers. Light is the game's: fixed face
// shading (tops 1, south faces 0.8), smooth-lighting corner occlusion, sky
// light dimmed a level a leaf under tree canopies, the lightmap through the
// day, and torch light falling a level a block, so at dusk the lamps and the
// lit windows come up as the sky darkens. Water is the animated, tinted
// still-water texture over the lit river bed; the game's flat cloud layer
// from clouds.png drifts over the map, with its south sides showing.
//
// Rendering: each pixel walks the 45° line of sight through the block columns
// in front of it, two voxels a column (that is all one column can hold of a
// 45° line), so a frame is a fixed, short loop with no step size and no
// misses. A SIMD group nearly always looks down one or two such lines, so its
// lanes build the line's columns in parallel, one each, and walk and probe
// them by shuffle; groups that cannot (a screen edge, sub-pixel texels) walk
// serially through the same functions. The walk reads a texture only to test
// a cut-out candidate (a leaf face: one read(); wheat, plants and the torch
// are the kit's models, mcCrop, mcCross and mcTorch, handed this projection
// as a parallel ray, which sample their own); everything else is sampled
// once, at the hit. At 3456×2234 the opening (t = 6) costs about 5% over
// `maze` (10.9 against 10.4 ms), a field with five animals about 13% over.
//
// Sheep, cows, pigs and chickens wander and graze over the grass: the shared
// mob kit's models and skins, walking and grazing in the kit's poses, traced
// along the same parallel ray. A pixel tests at most three of them (its own
// cell column), each only past a cheap screen-position reject and the kit's
// bounds box. Having the kit's tracer in the shader at all costs about 1 ms
// even where no animal stands (measured; moving it out of line did not help).
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
constant float OW_YC = 24.0; // the cloud layer's underside (in this projection only an offset)

// Materials.
constant int OW_AIR = 0, OW_GRASS = 1, OW_DIRT = 2, OW_STONE = 3, OW_SAND = 4,
             OW_SANDSTONE = 5, OW_SNOW = 6, OW_WATER = 7, OW_LOG = 8, OW_LEAVES = 9,
             OW_BIRCH = 10, OW_BLEAVES = 11, OW_SPRUCE = 12, OW_SLEAVES = 13,
             OW_CACTUS = 14, OW_WALL = 15, OW_ROOF = 16, OW_COBBLE = 17, OW_FARM = 18,
             OW_WHEAT = 19, OW_PATH = 20, OW_GRAVEL = 21, OW_POST = 22, OW_TORCH = 23,
             OW_TALLGRASS = 24, OW_FLOWER = 25, OW_ICE = 26, OW_DEADBUSH = 27,
             OW_PUMPKIN = 28, OW_HAY = 29, OW_FERN = 30;

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
        else if (top == OW_SNOW && biome == OW_SNOWY && r < 0.015) c.deco = OW_FERN;
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
    return m == OW_WHEAT || m == OW_TALLGRASS || m == OW_FLOWER || m == OW_DEADBUSH || m == OW_FERN;
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
    else if (m == OW_CACTUS) { lo = float3(1.0, 0.0, 1.0) / 16.0; hi = float3(15.0, 16.0, 15.0) / 16.0; }
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
// Faces and small models. uv runs 0..1 across a face with y up the face (a
// south face) or north across it (a top); the game's pictures have row 0 at
// the top, hence the flip.

static inline float4 owTile(texture2d_array<float> tiles, int L, float2 uv, float fp) {
    return mcTile(tiles, L, float2(uv.x, 1.0 - uv.y), fp);
}

// One exact texel's alpha, for deciding whether a cut-out face is hit.
static inline float owAlpha(texture2d_array<float> tiles, int L, float2 uv) {
    int2 t = clamp(int2(floor(float2(uv.x, 1.0 - uv.y) * 16.0)), 0, 15);
    return tiles.read(uint2(t), uint(L)).a;
}

// Wheat growth stage 0…7 for a farm plot: rows ripen together, then the plot
// is harvested and replanted.
static inline int owWheatStage(uint vh, int lz, float t) {
    float cyc = 150.0;
    float ph = fract(t / cyc + owU(owHash(vh + 31u)) + float(lz) * 0.015);
    return min(7, int(ph * 9.5));   // the last stretch holds ripe wheat
}

static inline int owPlantLayer(int m, uint bh, int st) {
    if (m == OW_WHEAT) return MC_WHEAT_STAGE0 + st;   // stage0..7 are consecutive layers
    if (m == OW_TALLGRASS) return MC_SHORT_GRASS;
    if (m == OW_FERN) return MC_FERN;
    if (m == OW_DEADBUSH) return MC_DEAD_BUSH;
    switch (owHash(bh + 3u) % 6u) {
    case 0u: return MC_DANDELION;
    case 1u: return MC_POPPY;
    case 2u: return MC_CORNFLOWER;
    case 3u: return MC_OXEYE_DAISY;
    case 4u: return MC_AZURE_BLUET;
    default: return MC_ALLIUM;
    }
}

static inline bool owLeaves(int m) { return m == OW_LEAVES || m == OW_BLEAVES || m == OW_SLEAVES; }
static inline int owLeafLayer(int m) {
    return m == OW_BLEAVES ? MC_BIRCH_LEAVES : (m == OW_SLEAVES ? MC_SPRUCE_LEAVES : MC_OAK_LEAVES);
}

// Where the line z + y = s (in the voxel's own coordinates, at x = fx) meets
// voxel material m. face 1 is a face looking south (or a plant's plane), 0 a
// top. Leaves and plants are cut out by their texture's alpha, so a line
// through a hole walks on to whatever is behind. kc gets the texel of a kit
// model (wheat, plants, the torch), which samples its own.
//
// The kit's small models are ray-based; this projection is a parallel ray,
// direction (0, -1, 1)/√2 at x = fx, so the line is handed to them as a ray
// from D blocks back, and the footprint of a pixel (fp, constant here) as
// fp / t at that distance. The cross plant is set half a texel north: its
// diagonal planes would otherwise put every sample on a texel edge in this
// projection, where the crisp filter blends two texels.
static bool owHitVox(int m, int st, uint bh, float s, float fx, float fp, texture2d_array<float> tiles,
                     thread int& face, thread float2& uv, thread float& zl, thread float3& kc) {
    if (m == OW_WHEAT || m == OW_TORCH || owCutout(m)) {
        const float D = 4.0;
        const float3 rd = float3(0.0, -0.70710678, 0.70710678);
        float3 ro = float3(fx, s + D, -D);
        float pxA = fp / (D * 1.41421356);
        McModelHit mh;
        bool ok;
        if (m == OW_WHEAT) ok = mcCrop(tiles, MC_WHEAT_STAGE0 + st, float3(0.0), ro, rd, 0.0, 1e3, pxA, mh);
        else if (m == OW_TORCH) ok = mcTorch(tiles, MC_TORCH, float3(0.0), ro, rd, 0.0, 1e3, pxA, mh);
        else ok = mcCross(tiles, owPlantLayer(m, bh, st), float3(0.0, 0.0, 1.0 / 32.0), float3(1.0),
                          ro, rd, 0.0, 1e3, pxA, mh);
        if (!ok) return false;
        float3 p = ro + rd * mh.t;
        face = mh.n.y > 0.5 ? 0 : 1;
        uv = float2(fx, face == 1 ? p.y : p.z);
        zl = p.z;
        kc = mh.color.rgb;
        return true;
    }
    float3 lo, hi;
    owShape(m, lo, hi);
    if (!owBoxHit(s, fx, lo, hi, face, uv, zl)) return false;
    if (owLeaves(m) && owAlpha(tiles, owLeafLayer(m), uv) < 0.5) return false;
    return true;
}

// The colour of a face texel before light. add: light that is already lit
// (a room seen through glass); lamp: the texel is a torch, drawn full bright.
static float3 owAlbedo(int m, int face, float2 uv, float fp, uint bh, int Y, thread const OwCol& c,
                       int st, float3 gt, float3 ft, float3 inLight, float3 kc, texture2d_array<float> tiles,
                       thread float3& add, thread bool& lamp) {
    add = float3(0.0); lamp = false;
    bool top = face == 0;
    switch (m) {
    case OW_GRASS:
        if (top) return owTile(tiles, MC_GRASS_BLOCK_TOP, uv, fp).rgb * gt;
        return mcGrassSide(tiles, float2(uv.x, 1.0 - uv.y), fp, gt);
    case OW_DIRT: return owTile(tiles, MC_DIRT, uv, fp).rgb;
    case OW_STONE: {
        uint o = bh % 41u;   // ore shows where the stone is cut
        return owTile(tiles, o < 2u ? MC_COAL_ORE : (o == 2u ? MC_IRON_ORE : MC_STONE), uv, fp).rgb;
    }
    case OW_SAND: return owTile(tiles, MC_SAND, uv, fp).rgb;
    case OW_SANDSTONE: return owTile(tiles, top ? MC_SANDSTONE_TOP : MC_SANDSTONE, uv, fp).rgb;
    case OW_SNOW:
        return owTile(tiles, top ? MC_SNOW : (c.sub == OW_DIRT ? MC_GRASS_BLOCK_SNOW : MC_SNOW), uv, fp).rgb;
    case OW_ICE: {
        float4 i = owTile(tiles, MC_ICE, uv, fp);
        return mix(MC_WATER_TINT * 0.3, i.rgb, i.a);
    }
    case OW_LOG:    return owTile(tiles, top ? MC_OAK_LOG_TOP : MC_OAK_LOG, uv, fp).rgb;
    case OW_BIRCH:  return owTile(tiles, top ? MC_BIRCH_LOG_TOP : MC_BIRCH_LOG, uv, fp).rgb;
    case OW_SPRUCE: return owTile(tiles, top ? MC_SPRUCE_LOG_TOP : MC_SPRUCE_LOG, uv, fp).rgb;
    case OW_LEAVES: return owTile(tiles, MC_OAK_LEAVES, uv, fp).rgb * ft;
    case OW_BLEAVES: return owTile(tiles, MC_BIRCH_LEAVES, uv, fp).rgb * mcFromSRGB(float3(0x80, 0xA7, 0x55) / 255.0);
    case OW_SLEAVES: return owTile(tiles, MC_SPRUCE_LEAVES, uv, fp).rgb * mcFromSRGB(float3(0x61, 0x99, 0x61) / 255.0);
    case OW_CACTUS: return owTile(tiles, top ? MC_CACTUS_TOP : MC_CACTUS_SIDE, uv, fp).rgb;
    case OW_WALL: {
        int sty = c.style;
        int lv = Y - c.vb;
        int wallL = sty == 1 ? MC_CUT_SANDSTONE : (sty == 2 ? MC_SPRUCE_PLANKS : MC_OAK_PLANKS);
        if (top) return owTile(tiles, wallL, uv, fp).rgb;
        bool pillar = c.lx == 2 || c.lx == 6;
        bool door = c.lx == 4 && lv <= 1;
        bool win = lv == 1 && (c.lx == 3 || c.lx == 5);
        // The room behind glass and the door's window: its far wall, lit by
        // the torch inside.
        float3 room = owTile(tiles, wallL, uv + float2(0.5, 0.3125), fp).rgb * inLight;
        if (door) {
            int L = sty == 2 ? (lv == 0 ? MC_SPRUCE_DOOR_BOTTOM : MC_SPRUCE_DOOR_TOP)
                             : (lv == 0 ? MC_OAK_DOOR_BOTTOM : MC_OAK_DOOR_TOP);
            float4 d = owTile(tiles, L, uv, fp);
            add = room * (1.0 - d.a);
            return d.rgb * d.a;
        }
        if (win) {
            float4 g = owTile(tiles, MC_GLASS, uv, fp);
            add = room * (1.0 - g.a);
            return g.rgb * g.a;
        }
        if (pillar) return owTile(tiles, sty == 1 ? MC_SANDSTONE : (sty == 2 ? MC_SPRUCE_LOG : MC_OAK_LOG), uv, fp).rgb;
        if (lv == 0) return owTile(tiles, sty == 1 ? MC_SANDSTONE : MC_COBBLESTONE, uv, fp).rgb;
        return owTile(tiles, wallL, uv, fp).rgb;
    }
    case OW_ROOF:
        if (c.style == 1) return owTile(tiles, top ? MC_SANDSTONE_TOP : MC_CUT_SANDSTONE, uv, fp).rgb;
        if (c.style == 2 && top) return owTile(tiles, MC_SNOW, uv, fp).rgb;
        return owTile(tiles, MC_SPRUCE_PLANKS, uv, fp).rgb;
    case OW_COBBLE: return owTile(tiles, MC_COBBLESTONE, uv, fp).rgb;
    case OW_FARM: return owTile(tiles, top ? MC_FARMLAND_MOIST : MC_DIRT, uv, fp).rgb;
    case OW_PATH: return owTile(tiles, top ? MC_DIRT_PATH_TOP : MC_DIRT_PATH_SIDE, uv, fp).rgb;
    case OW_GRAVEL: return owTile(tiles, MC_GRAVEL, uv, fp).rgb;
    case OW_POST: return owTile(tiles, MC_OAK_PLANKS, uv, fp).rgb;   // an oak fence post
    case OW_TORCH: lamp = true; return kc;   // the kit's torch, full bright
    case OW_WHEAT: case OW_TALLGRASS: case OW_FERN: case OW_FLOWER: case OW_DEADBUSH:
        return (m == OW_TALLGRASS || m == OW_FERN) ? kc * gt : kc;
    case OW_PUMPKIN: return owTile(tiles, top ? MC_PUMPKIN_TOP : MC_PUMPKIN_SIDE, uv, fp).rgb;
    case OW_HAY: return owTile(tiles, top ? MC_HAY_BLOCK_TOP : MC_HAY_BLOCK_SIDE, uv, fp).rgb;
    default: break;
    }
    return float3(1.0, 0.0, 1.0);
}

// One column of a shared line of sight, packed for shuffling. V: the voxels
// at levels n, n - 1 and n + 1 (the line enters at n; a line one block row up
// enters at n + 1) and the wheat stage. S: the solid profile for shadow and
// corner probes (ground below h, object in [lo, hi) unless it is a lamp).
// I/Id/Vh/T/M: what texturing needs, for whichever lane's pixel hits it.
struct OwProd { uint V, S, I, Id, Vh; float T, M; int top; };

static inline uint owPackS(thread const OwCol& c) {
    uint solidObj = (c.oHi > c.oLo && c.oMat != OW_TORCH) ? 1u : 0u;
    return uint(clamp(c.h, 0, 31)) | (uint(clamp(c.oLo, 0, 31)) << 5) | (uint(clamp(c.oHi, 0, 31)) << 10) | (solidObj << 15);
}

static OwProd owProduce(int2 p, int n, float t, thread OwCell& kc, thread OwVC& kv) {
    float hf = owBaseH(float2(p) + 0.5);
    owEnsureV(p, kv);
    owEnsure(p, kc, kv);
    OwCol c = owColumn(p, hf, kc);
    OwProd r;
    r.V = uint(owVox(c, n)) | (uint(owVox(c, n - 1)) << 5) | (uint(owWheatStage(c.vh, c.lz, t)) << 10) |
          (uint(owVox(c, n + 1)) << 14);
    r.S = owPackS(c);
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
// ---------------------------------------------------------------------------
// Animals: the game's sheep, cows, pigs and chickens, drawn by the shared mob
// kit. One may live in each 12×12 cell, strolling east and west around its
// spot and stopping to graze. Cold variants live in the snow and warm ones
// where it is hot, as the game picks them; sheep take the game's wool colours
// in its proportions, and a few of each are babies.

struct OwMob { int type; float3 o; float dir; MCMOB_Pose pose; MCMOB_Skin skin; };

// The kit's bounds for these mobs reach 1.22 blocks along the body, 0.69
// across it and 1.81 up, for every pose; the quick rejects below use that.
constant float OW_MOB_LEN = 1.25, OW_MOB_WIDE = 0.7, OW_MOB_TALL = 1.85;

static bool owMobAt(int2 cell, float t, float2 w, thread OwMob& mb) {
    float hr = hash21(float2(cell) + 0.37);
    if (hr > 0.7) return false;
    uint h = uint(hr * 4294967040.0 / 0.7);
    int2 a = cell * 12 + int2(5 + int((h >> 3) % 3u), 3 + int((h >> 11) % 6u));
    // Cheap rejects first: it strolls at most 3 blocks either side of its spot.
    if (abs(w.x - (float(a.x) + 0.5)) > 3.1 + OW_MOB_LEN) return false;
    float zc = float(a.y) + 0.5;
    if (w.y < zc - OW_MOB_WIDE + 5.0 || w.y > zc + OW_MOB_WIDE + OW_MOB_TALL + 10.0) return false;
    float T = t * 0.9 + owU(owHash(h + 1u)) * 400.0;
    float seg = floor(T / 9.0), ft = T - seg * 9.0;
    float x0 = (hash21(float2(seg, hr * 97.0)) - 0.5) * 6.0;
    float x1 = (hash21(float2(seg + 1.0, hr * 97.0)) - 0.5) * 6.0;
    float k = smoothstep(0.0, 4.0, ft);
    float x = float(a.x) + 0.5 + mix(x0, x1, k);
    x = floor(x * 16.0 + 0.5) / 16.0;
    if (abs(w.x - x) > OW_MOB_LEN) return false;
    float z = float(a.y) + 0.5;                   // the body's centre line
    // Quick reject on the screen line before any noise: feet at y in [5, 10).
    if (w.y < z - OW_MOB_WIDE + 5.0 || w.y > z + OW_MOB_WIDE + OW_MOB_TALL + 10.0) return false;
    float2 fa = float2(a) + 0.5;
    float ha = owBaseH(fa);
    if (ha < 5.0 || ha >= 10.0) return false;
    if (owRiver(fa) < 0.075) return false;
    float2 cl = owClimateAt(floor(fa / 5.0) * 5.0 + 2.5);
    int bi = owBiome(ha, cl.x, cl.y);
    if (bi == OW_DESERT || bi == OW_MOUNT) return false;
    OwVil v = owVillage(a);
    if (v.on == 1 && length(fa - v.c) < v.R + 6.0) return false;
    float hx = owBaseH(float2(x, z));
    float g = floor(hx);
    if (g <= float(OW_W)) return false;
    // 0 sheep, 1 cow, 2 pig, 3 chicken; woods have pigs where plains have cows.
    int kind = int((h >> 19) % 4u);
    if (bi == OW_FOREST && kind == 1) kind = 2;
    bool cold = bi == OW_SNOWY, warm = !cold && cl.x > 0.56;
    bool baby = ((h >> 23) % 9u) == 0u;
    uint r = owHash(h + 7u) % 1000u;
    if (kind == 0) {
        // White 81.8%, light grey, grey and black 5% each, brown 3%, pink 0.2%.
        float3 dye = r < 818u ? float3(0xF9, 0xFF, 0xFE) : r < 868u ? float3(0x9D, 0x9D, 0x97) :
                     r < 918u ? float3(0x47, 0x4F, 0x52) : r < 968u ? float3(0x1D, 0x1D, 0x21) :
                     r < 998u ? float3(0x83, 0x54, 0x32) : float3(0xF3, 0x8B, 0xAA);
        mb.type = baby ? MCMOB_SHEEP_BABY : MCMOB_SHEEP;
        mb.skin = mcMobSheepSkin(baby, true, mcFromSRGB(dye / 255.0));
    } else if (kind == 1) {
        mb.type = cold ? (baby ? MCMOB_COW_COLD_BABY : MCMOB_COW_COLD)
                : warm ? (baby ? MCMOB_COW_WARM_BABY : MCMOB_COW_WARM)
                       : (baby ? MCMOB_COW_BABY : MCMOB_COW);
        mb.skin = mcMobSkin(cold ? (baby ? MCS_COW_COLD_BABY : MCS_COW_COLD)
                          : warm ? (baby ? MCS_COW_WARM_BABY : MCS_COW_WARM)
                                 : (baby ? MCS_COW_TEMPERATE_BABY : MCS_COW_TEMPERATE));
    } else if (kind == 2) {
        mb.type = baby ? MCMOB_PIG_BABY : (cold ? MCMOB_PIG_COLD : MCMOB_PIG);
        mb.skin = mcMobSkin(cold ? (baby ? MCS_PIG_COLD_BABY : MCS_PIG_COLD)
                          : warm ? (baby ? MCS_PIG_WARM_BABY : MCS_PIG_WARM)
                                 : (baby ? MCS_PIG_TEMPERATE_BABY : MCS_PIG_TEMPERATE));
    } else {
        mb.type = baby ? MCMOB_CHICKEN_BABY : (cold ? MCMOB_CHICKEN_COLD : MCMOB_CHICKEN);
        mb.skin = mcMobSkin(cold ? (baby ? MCS_CHICKEN_COLD_BABY : MCS_CHICKEN_COLD)
                          : warm ? (baby ? MCS_CHICKEN_WARM_BABY : MCS_CHICKEN_WARM)
                                 : (baby ? MCS_CHICKEN_TEMPERATE_BABY : MCS_CHICKEN_TEMPERATE));
    }
    mb.dir = (x1 - x0) >= 0.0 ? 1.0 : -1.0;
    bool walking = ft < 4.0 && abs(x1 - x0) > 0.2;
    float gp = fract(ft * 0.23 + owU(h));
    mb.pose = mcMobStill();
    // The walk phase advances with the distance covered, as the game's does.
    mb.pose.walk = (seg * 3.0 + abs(x1 - x0) * k) * 4.0;
    mb.pose.speed = walking ? 0.5 * sin(PI * saturate(ft / 4.0)) : 0.0;
    mb.pose.graze = walking ? 0.0 : smoothstep(0.0, 0.08, gp) * (1.0 - smoothstep(0.47, 0.55, gp));
    mb.o = float3(x, g, z);
    return true;
}

// The nearest animal on this pixel's line in front of the terrain hit (world z
// hz), lit; false if none.
static bool owMobs(float2 w, float hz, float t, float fp, float day,
                   texture2d_array<float> mcSkins, texture2d_array<float> mcMaps, thread float3& col) {
    const float3 rd = float3(0.0, -0.70710678, 0.70710678);
    bool hit = false;
    float zFar = hz;
    int cx = int(floor(w.x / 12.0));
    int cz0 = int(floor((w.y - (10.0 + OW_MOB_TALL + OW_MOB_WIDE) - 8.5) / 12.0));
    int cz1 = int(floor((w.y - (5.0 - OW_MOB_WIDE) - 3.5) / 12.0));
    for (int cz = cz0; cz <= cz1; cz++) {
        OwMob m;
        if (!owMobAt(int2(cx, cz), t, w, m)) continue;
        float3 ro = float3(w.x, w.y - (m.o.z - 3.0), m.o.z - 3.0);
        float tMax = (zFar - ro.z) * 1.41421356;
        float heading = m.dir > 0.0 ? 0.5 * PI : -0.5 * PI;
        float3 lro, lrd;
        mcMobRay(ro, rd, m.o, heading, lro, lrd);
        float2 b = mcMobBounds(m.type, lro, lrd);
        if (!(b.x < b.y && b.x < tMax)) continue;
        MCMOB_Hit mh = mcMobTrace(m.type, m.pose, m.skin, lro, lrd, tMax, mcSkins, mcMaps);
        if (!(mh.t < tMax)) continue;
        zFar = ro.z + mh.t * 0.70710678;
        float4 c = mcMobColor(m.type, mh, m.skin, fp * 16.0, mcSkins, mcMaps);
        col = c.rgb * mcFaceShade(mcMobNormal(mh.n, heading)) * mcLightmap(0.0, 15.0, day, 0.0) + c.rgb * c.a;
        hit = true;
    }
    return hit;
}

// ---------------------------------------------------------------------------
// The game's flat cloud layer: clouds.png, one pixel to a 12×12-block cell,
// 4 blocks thick, drifting east.

static inline bool owCloudAt(texture2d_array<float> maps, float i, float j) {
    uint2 p = uint2(glmod(i, 256.0), glmod(j, 256.0));
    return maps.read(p, uint(MCM_ENVIRONMENT_CLOUDS)).a > 0.5;
}

// Solid object levels above the air voxel at Yair in a packed column (sky
// light loses a level to each leaf it passes).
static inline int owCover(uint S, int Yair) {
    if (((S >> 15) & 1u) == 0u) return 0;
    int lo = int((S >> 5) & 31u), hi = int((S >> 10) & 31u);
    return max(0, hi - max(lo, Yair));
}

// ---------------------------------------------------------------------------

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]],
                        texture2d_array<float> mcTiles [[texture(8)]],
                        texture2d_array<float> mcSkins [[texture(10)]],
                        texture2d_array<float> mcMaps  [[texture(11)]]) {
    float2 res = u.resolution;
    float t = u.time;
    float rr = res.y / (u.blocks * 16.0);
    float T = rr >= 1.0 ? round(rr) : rr;          // screen pixels per texel
    float B = 16.0 * T;
    float fp = 1.0 / B;                             // one screen pixel, in blocks

    // The pan: east, meandering north and south. Whole pixels only.
    float pt = t * u.speed, pt5 = 5.0 * u.speed;
    float2 cam = float2(pt + u.seed * 4111.0,
                        18.0 * sin(pt / 90.0 + u.seed * 6.2832) + 8.0 * sin(pt / 40.0 + 1.3 + u.seed * 17.0) + u.seed * 2333.0);
    float2 c5 = float2(pt5 + u.seed * 4111.0,
                       18.0 * sin(pt5 / 90.0 + u.seed * 6.2832) + 8.0 * sin(pt5 / 40.0 + 1.3 + u.seed * 17.0) + u.seed * 2333.0);
    // Every visit opens on a village: the world is shifted so the first valid
    // one along the path sits at the centre of the screen at t = 5 s. (The
    // shift is taken from the camera at 5 s, so it is fixed for the visit.)
    int2 startCell = int2(-999999);
    float2 shift = float2(0.0);
    {
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
    int hm = OW_AIR, hface = 0, hY = 0, hZ = 0, hSt = 0;
    float2 huv = float2(0.0);
    float3 hKc = float3(0.0);                      // a kit model's texel at the hit
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
    // probes it for light and corners, by shuffles. Anything else (a group
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
            int st = int((q >> 10) & 15u);
            for (int j = 0; j < 2; j++) {
                int Y = n - j;
                // The producer's own entry level is n - dv.
                int m = dv == 0 ? int((q >> (5 * j)) & 31u) : (j == 0 ? int((q >> 14) & 31u) : int(q & 31u));
                if (m == OW_AIR) continue;
                if (m == OW_WATER) {
                    if (wEntry < 0.0) wEntry = float(Z) + (j == 0 ? 0.0 : f);
                    continue;
                }
                int face; float2 uv; float zl; float3 kcol;
                if (!owHitVox(m, st, owH3(X, Y, Z), f + float(j), fx, fp, mcTiles, face, uv, zl, kcol)) continue;
                hm = m; hface = face; huv = uv; hY = Y; hZ = Z; hz = float(Z) + zl; hSt = st; hKc = kcol;
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
            int st = owWheatStage(c.vh, c.lz, t);
            bool done = false;
            for (int j = 0; j < 2; j++) {
                int Y = n - j;
                int m = owVox(c, Y);
                if (m == OW_AIR) continue;
                if (m == OW_WATER) {
                    if (wEntry < 0.0) wEntry = float(Z) + (j == 0 ? 0.0 : f);
                    continue;
                }
                int face; float2 uv; float zl; float3 kcol;
                if (!owHitVox(m, st, owH3(X, Y, Z), f + float(j), fx, fp, mcTiles, face, uv, zl, kcol)) continue;
                hm = m; hface = face; huv = uv; hY = Y; hZ = Z; hz = float(Z) + zl; hSt = st; hKc = kcol;
                done = true;
                break;
            }
            if (done) break;
        }

    }

    OwCol hc;
    uint sHit;                                      // the hit column's solid profile
    if (coop) {
        ushort src = ushort(clamp(hZ - ZB, 0, 31));
        uint qi = simd_shuffle(P0.I, src), id = simd_shuffle(P0.Id, src), vh = simd_shuffle(P0.Vh, src);
        uint qs = simd_shuffle(P0.S, src);
        float te = simd_shuffle(P0.T, src), mo = simd_shuffle(P0.M, src);
        if (two) {
            uint qi1 = simd_shuffle(P1.I, src), id1 = simd_shuffle(P1.Id, src), vh1 = simd_shuffle(P1.Vh, src);
            uint qs1 = simd_shuffle(P1.S, src);
            float te1 = simd_shuffle(P1.T, src), mo1 = simd_shuffle(P1.M, src);
            if (!mine0) { qi = qi1; id = id1; vh = vh1; te = te1; mo = mo1; qs = qs1; }
        }
        hc.id = id; hc.vh = vh; hc.temp = te; hc.moist = mo;
        hc.top = int(qi & 31u); hc.sub = int((qi >> 5) & 31u);
        hc.lx = int((qi >> 10) & 7u); hc.lz = int((qi >> 13) & 7u);
        hc.vb = int((qi >> 16) & 31u); hc.style = int((qi >> 21) & 7u) - 2;
        hc.h = int((qi >> 24) & 31u); hc.biome = int((qi >> 29) & 7u);
        hc.wTop = 0; hc.deco = 0; hc.oLo = 0; hc.oHi = 0; hc.oMat = 0; hc.tTop = 0; hc.tMat = 0; hc.plot = 0;
        sHit = qs;
    } else {
        int2 p = int2(X, hZ);
        owEnsureV(p, kv);
        owEnsure(p, kc, kv);
        hc = owColumn(p, owBaseH(float2(p) + 0.5), kc);
        sHit = owPackS(hc);
    }

    // --- Day and night: the sun's height e and the game's daylight factor.
    float phase = fract(t / u.dayLength + 0.05 + 0.3 * u.seed);
    const float dayF = 0.66;
    float e;
    if (phase < dayF) e = sin(PI * phase / dayF);
    else e = -sin(PI * (phase - dayF) / (1.0 - dayF));
    float day = saturate(2.0 * e + 0.2);           // the game's sky darkening, from the sun's height

    // --- Animals in front of the hit?
    // A mob roams x in [2.5, 10.5] of its 12-wide cell and reaches 1.25 either
    // side, so only this pixel's own cell column can hold one; its centre line
    // z lies 3.5 to 8.5 into its cell, and the line meets it for z in
    // [w.y - 12.6, w.y - 4.3], which is two cells, or now and then three. Each
    // is handed to the kit as the parallel ray of this projection, from 3
    // blocks south of it, and only up to the terrain's hit.
    float3 mobCol = float3(0.0);
    bool mobHit = owMobs(w, hz, t, fp, day, mcSkins, mcMaps, mobCol);
    // KIT: mobs — the game's round shadow under each mob (misc/shadow.png) is
    // not in the kit or the packed textures yet; requested in KIT-REQUESTS.md.

    // --- Shade the hit.
    float3 P = float3(w.x, w.y - hz, hz);
    float3 N = hface == 1 ? float3(0.0, 0.0, -1.0) : float3(0.0, 1.0, 0.0);

    if (hc.style == -2) {
        OwVil v = owVillage(int2(X, hZ));
        float2 vcl = owClimateAt(floor(v.c));
        int vb = owBiome(7.0, vcl.x, vcl.y);
        hc.style = vb == OW_DESERT ? 1 : (vb == OW_SNOWY ? 2 : 0);
        if (hc.top == OW_GRASS) hc.top = hc.style == 1 ? OW_SAND : (hc.style == 2 ? OW_SNOW : OW_GRASS);
        if (hc.style == 1) hc.sub = OW_SANDSTONE;
        if (hm == OW_GRASS && hY == hc.h - 1) hm = hc.top;
    }

    bool plant = owCutout(hm) || hm == OW_TORCH;

    // Light levels of the air the face looks into, and the corner shading of
    // smooth lighting: a top against a block to its north, a face's foot on
    // the ground in front, darken towards that edge from 1 to 0.6 as the game's
    // vertex occlusion does.
    float skyLv = 15.0, blkLv = 0.0, ao = 1.0;
    {
        int Za = hface == 0 ? hZ + 1 : hZ - 1;
        int Ya = hface == 0 ? hY + 1 : hY - 1;
        int Yair = hface == 0 ? hY + 1 : hY;
        bool want = !plant && hm != OW_POST;
        bool solidA;
        uint sFront = 0u;
        if (coop) {
            int ln = Za - ZB;
            ushort src = ushort(clamp(ln, 0, 31));
            uint s0 = simd_shuffle(P0.S, src);
            uint s1 = two ? simd_shuffle(P1.S, src) : 0u;
            sFront = (ln >= 0 && ln < 32) ? (mine0 ? s0 : s1) : 0u;
            solidA = ln >= 0 && ln < 32 && owPackSolid(sFront, Ya);
        } else {
            solidA = want && owSolid(int3(X, Ya, Za), kc, kv);
            if (hface == 1) {
                int2 p = int2(X, hZ - 1);
                owEnsureV(p, kv);
                owEnsure(p, kc, kv);
                sFront = owPackS(owColumn(p, owBaseH(float2(p) + 0.5), kc));
            }
        }
        if (want && solidA) ao = hface == 0 ? mix(1.0, 0.6, huv.y) : mix(0.6, 1.0, huv.y);
        skyLv = 15.0 - float(min(owCover(hface == 0 ? sHit : sFront, Yair), 2));
    }

    // Torch light, a level a block (taxicab, as the game spreads it) from
    // each lamp post's torch (14) and from each house's door, which passes the
    // light of the torch inside (13 there). It is always on; it shows as the
    // sky darkens.
    if (day < 0.999) {
        float3 Pa = P + N * 0.5;
        owEnsureV(int2(floor(Pa.xz)), kv);
        OwVil v = kv.v;
        if (kv.vOK == 1) {
            float2 vcen = floor(v.c);
            int2 pc0 = int2(floor((Pa.xz - vcen + 32.0) / 8.0));
            for (int i = 0; i < 9; i++) {
                int2 pi = pc0 + int2(i % 3 - 1, i / 3 - 1);
                float2 o = vcen - 32.0 + float2(pi) * 8.0;
                if (length(o + 4.0 - v.c) >= v.R - 4.0) continue;
                uint ph = owH3(pi.x + int(v.hs & 1023u), pi.y, 77);
                if (owU(ph) >= 0.5) continue;
                float3 lamp = float3(o.x + 1.5, float(v.vb) + 1.5, o.y + 1.5);
                float3 door = float3(o.x + 4.5, float(v.vb) + 1.5, o.y + 2.5);
                float3 d1 = abs(Pa - lamp), d2 = abs(Pa - door);
                blkLv = max(blkLv, max(14.0 - (d1.x + d1.y + d1.z), 13.0 - (d2.x + d2.y + d2.z)));
            }
        }
    }

    // Water over the hit: the bed loses a level of sky light a block down.
    bool underWater = wEntry >= 0.0;
    float depth = max(float(OW_W) - P.y, 0.0);
    if (underWater) skyLv = min(skyLv, 15.0 - depth);

    // Climate per block (the game blends its biome tints per block too).
    float2 clm = owClimateAt(float2(float(X), float(hZ)) + 0.5);
    float tg = saturate((clm.x - 0.28) * 3.0 + 0.1), dg = saturate(0.2 + 0.75 * clm.y);
    float3 gt = mcGrassTint(mcMaps, tg, dg);
    float3 ft = owLeaves(hm) && hm == OW_LEAVES ? mcFoliageTint(mcMaps, tg, dg) : float3(1.0);

    float3 inLight = mcLightmap(13.0, 11.0, day, 0.0) * 0.8;
    float3 add; bool lamp;
    float3 alb = owAlbedo(hm, hface, huv, fp, owH3(X, hY, hZ), hY, hc, hSt, gt, ft, inLight, hKc, mcTiles, add, lamp);

    float shade = plant ? 1.0 : mcFaceShade(N);
    float3 col = lamp ? alb : alb * shade * ao * mcLightmap(blkLv, skyLv, day, 0.0) + add;

    if (underWater) {
        int fr = mcFrame(MC_WATER_STILL, MC_WATER_STILL_FRAMES, MC_WATER_STILL_TICKS, t);
        float4 wt = mcTile(mcTiles, fr, float2(fract(w.x), 1.0 - fract(wEntry)), fp);
        float3 tint = hc.biome == OW_SNOWY ? mcFromSRGB(float3(0x3D, 0x57, 0xD6) / 255.0) : MC_WATER_TINT;
        col = mix(col, wt.rgb * tint * mcLightmap(blkLv, 15.0, day, 0.0), wt.a);
    }
    if (mobHit) col = mobCol;

    // The cloud layer above it all: its tops, and the south sides of its edges.
    if (u.clouds > 0.0) {
        float drift = floor(t * 0.6 * 16.0) / 16.0;
        // The layer is placed so the opening village lies under one of eight
        // wide gaps in clouds.png (each at least 10×7 cells clear), picked by seed.
        const int2 gaps[8] = { int2(36, 0), int2(118, 0), int2(198, 0), int2(156, 3),
                               int2(83, 6), int2(2, 7), int2(227, 28), int2(130, 29) };
        int2 g = gaps[int(fract(u.seed * 7.13) * 8.0) & 7];
        float2 o5 = c5 + shift;
        float2 coff = float2(g) - floor(float2(o5.x - floor(5.0 * 0.6 * 16.0) / 16.0, o5.y - (OW_YC + 4.0)) / 12.0);
        float ci = floor((w.x - drift) / 12.0) + coff.x;
        float zt = w.y - (OW_YC + 4.0);
        bool on = owCloudAt(mcMaps, ci, floor(zt / 12.0) + coff.y);
        float csh = 1.0;
        if (!on) {
            float zb = 12.0 * ceil(zt / 12.0);
            if (zb <= w.y - OW_YC && owCloudAt(mcMaps, ci, zb / 12.0 + coff.y)) { on = true; csh = 0.8; }
        }
        if (on) {
            float cb = saturate(e * 2.0 + 0.5) * 0.85 + 0.15;
            float3 cc = float3(cb, cb, cb * 0.85 + 0.15) * csh;
            col = mix(col, cc, u.clouds);
        }
    }

    col = lerpDither(col, pos);
    return half4(half3(saturate(col)), 1.0h);
}
