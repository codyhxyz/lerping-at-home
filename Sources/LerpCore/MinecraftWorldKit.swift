import Foundation

/// The shared world tracer: MSL spliced into the prelude of a look that says
/// `// lerp-requires: minecraft world:<name>`, after the atlas helpers, the
/// kit (`MinecraftKit.swift`), the mobs if asked for, and the bake's own
/// `world.metal`. One copy for every world look, so every look traces, lights
/// and fogs the world the same way. PORTING.md "Worlds" is the guide; the
/// comments here are the reference.
extension LerpMinecraftWorld {
    static let kit = #"""

// ---- Worlds: the shared tracer (MinecraftWorldKit.swift) --------------------
// Volume space throughout: blocks, the box [0, MCW_SIZE), +x east, +y up,
// +z south, as world.metal's constants are. See PORTING.md "Worlds".

struct McWorldClock {
    int   day;      // whole UTC days since 2026-01-01 at u.time == 0
    float second;   // and seconds into that day
    float2 pad;
};

// Everything a world look draws with, gathered so the functions below take
// one argument. Make it at the top of lerpMain with MCW_WORLD and set pxA.
struct McWorld {
    texture2d_array<float> tiles;
    texture2d_array<float> skins;
    texture2d_array<float> maps;
    texture3d<ushort>      blocks;
    texture3d<float>       light;
    texture2d_array<float> tints;
    texture2d<ushort>      farH;
    texture2d_array<float> far;
    texture2d<uint>        mats;
    texture2d<uint>        elems;
    texture2d<ushort>      farMax;
    McWorldClock           clock;
    float time;   // u.time: animated textures
    float pxA;    // one screen pixel's width in radians (the footprint at distance t is t * pxA)
};

// The look's lerpMain takes these after LerpUniforms (and after its own
// provider's bindings, if it has one); they include mcTiles, mcSkins and
// mcMaps, so do not declare those again.
#define MCW_BINDINGS \
    texture2d_array<float> mcTiles      [[texture(8)]],  \
    texture2d_array<float> mcSkins      [[texture(10)]], \
    texture2d_array<float> mcMaps       [[texture(11)]], \
    texture3d<ushort>      mcwBlocks    [[texture(12)]], \
    texture3d<float>       mcwLight     [[texture(13)]], \
    texture2d_array<float> mcwTints     [[texture(14)]], \
    texture2d<ushort>      mcwFarH      [[texture(15)]], \
    texture2d_array<float> mcwFar       [[texture(16)]], \
    texture2d<uint>        mcwMaterials [[texture(17)]], \
    texture2d<uint>        mcwElements  [[texture(18)]], \
    texture2d<ushort>      mcwFarMax    [[texture(19)]], \
    constant McWorldClock& mcwClock     [[buffer(12)]]

#define MCW_WORLD mcwMake(mcTiles, mcSkins, mcMaps, mcwBlocks, mcwLight, mcwTints, mcwFarH, mcwFar, \
                          mcwMaterials, mcwElements, mcwFarMax, mcwClock, u.time)

static inline McWorld mcwMake(texture2d_array<float> tiles, texture2d_array<float> skins,
                              texture2d_array<float> maps, texture3d<ushort> blocks,
                              texture3d<float> light, texture2d_array<float> tints,
                              texture2d<ushort> farH, texture2d_array<float> far,
                              texture2d<uint> mats, texture2d<uint> elems, texture2d<ushort> farMax,
                              constant McWorldClock& clock, float time) {
    McWorld W = { tiles, skins, maps, blocks, light, tints, farH, far, mats, elems, farMax, clock, time, 0.001 };
    return W;
}

constexpr sampler mcwLinear(coord::normalized, address::clamp_to_edge, filter::linear);

constant float3 MCW_SIZEF = float3(MCW_SIZE);

// ---- Shared time ---------------------------------------------------------------
// Every Mac shows the same moment: the clock is UTC, read once per session and
// anchored to u.time == 0 (LerpWorldProvider; stills get 2026-01-01T00:00Z).

// Seconds into a repeating period of `period` whole seconds (1..65535) of
// shared UTC time, at u.time = time. Exact to the float's precision of the
// period, however far from the epoch.
static inline float mcWorldSeconds(McWorld W, float time, int period) {
    int P = max(period, 1);
    int d = ((W.clock.day % P) + P) % P;
    int dayPart = int((uint(d) * uint(86400 % P)) % uint(P));
    return glmod(float(dayPart) + glmod(W.clock.second, float(P)) + glmod(time, float(P)), float(P));
}

// The game's time of day in ticks (0..24000, 0 = sunrise, 6000 = noon), at
// the game's own rate (20 ticks a second, a 20-minute day), the same on every
// Mac. Add an offset (MCW_DAY_TIME, say) and wrap with glmod for a look that
// wants a different moment.
static inline float mcWorldTicks(McWorld W, float time) {
    return mcWorldSeconds(W, time, 1200) * 20.0;
}

// The moon's phase that night, 0..7 as the game counts them (0 full, 4 new).
static inline int mcWorldMoonPhase(McWorld W, float time) {
    return int(mcWorldSeconds(W, time, 9600) / 1200.0) & 7;
}

// The game's celestial angle (0 at noon, 0.5 at midnight) for a time of day.
static inline float mcWorldCelestial(float ticks) {
    float f = fract(ticks / 24000.0 - 0.25);
    float g = 0.5 - cos(f * M_PI_F) * 0.5;
    return (f * 2.0 + g) / 3.0;
}

// Unit vector toward the sun: up at noon, rising in the east (+x) and setting
// in the west, as in the game. The moon is opposite.
static inline float3 mcWorldSunDir(float ticks) {
    float a = mcWorldCelestial(ticks) * 6.28318531;
    return float3(-sin(a), cos(a), 0.0);
}

// ---- Volume reads -------------------------------------------------------------

static inline bool mcwInBox(int3 c) { return all(c >= 0) && all(c < MCW_SIZE); }

// The raw voxel: material id in the low 12 bits, air's skip distance above.
static inline uint mcwVoxel(McWorld W, int3 c) {
    return mcwInBox(c) ? uint(W.blocks.read(ushort3(c)).r) : 0u;
}

// The baked light at p (volume space), linearly filtered: block light rgb
// (sRGB-encoded) and sky light a, each level / 15.
static inline float4 mcwLightAt(McWorld W, float3 p) {
    return W.light.sample(mcwLinear, p / MCW_SIZEF);
}

// Column tints at (x, z): 0 grass, 1 foliage, 2 water (3 dry foliage when
// MCWK_TINT_LAYERS is 4); Display P3, as the loader re-encodes them.
static inline float3 mcWorldTint(McWorld W, float2 xz, int layer) {
    int2 c = clamp(int2(floor(xz)), int2(0), MCW_SIZE.xz - 1);
    return W.tints.read(uint2(c), uint(layer)).rgb;   // re-encoded in Display P3 at load
}

// ---- The hit record ---------------------------------------------------------------

constant uint MCW_HIT_WATER       = 1u;    // the ray crossed a water surface first (waterT)
constant uint MCW_HIT_EMISSIVE    = 2u;    // the surface gives light: draw it at full brightness
constant uint MCW_HIT_TRANSLUCENT = 4u;    // stained glass, ice, slime...: color.a is its opacity
constant uint MCW_HIT_FAR         = 8u;    // the horizon beyond the volume (far.*), not a block
constant uint MCW_HIT_MODEL       = 16u;   // a model element, not a full cube
constant uint MCW_HIT_LAVA        = 32u;   // a lava surface
constant uint MCW_HIT_FLAT        = 64u;   // no ambient occlusion (torches, plants): lit by its own cell's light
constant uint MCW_HIT_SHADE       = 128u;  // the game face-shades this face (mcFaceShade)
constant uint MCW_HIT_LAYER_SHADE = 1u << 18;   // and the translucent layer's face
// Packed in flags too: bits 8-11 the face's own light emission (mcWorldHitGlow),
// 12-14 the water surface's face and 15-17 the layer's face (MC_DIR_*).

// Kept small on purpose: everything here stays live through the shading and
// the shadow ray, and registers are what a world look runs short of. What can
// be worked out from it is a function below (mcWorldHitCell, mcWorldWaterN...).
struct McWorldHit {
    float  t;          // distance along rd; >= tMax on a miss (then color is unset)
    float3 p;          // where, volume space
    float3 n;          // the face's normal, toward the ray
    int    mid;        // material id (0 for the far field)
    float4 color;      // the texel: texture x biome tint, overlay laid on; Display P3
    uint   flags;      // MCW_HIT_*, and the packed fields above
    int    steps;      // cells visited, for a heat map
    float  waterT;     // the water surface crossed on the way, or -1
    float  layerT;     // a translucent face the ray passed through on the way (ice, stained
                       // glass, slime), or -1; t and color are then what is behind it
    float4 layerColor; // its texel, tinted; a is its opacity
    int    layerMid;   // its material
};

static inline McWorldHit mcwMiss(float tMax) {
    McWorldHit h;
    h.t = tMax; h.p = float3(0.0); h.n = float3(0.0, 1.0, 0.0); h.mid = 0;
    h.color = float4(0.0); h.flags = 0u; h.steps = 0;
    h.waterT = -1.0; h.layerT = -1.0; h.layerColor = float4(0.0); h.layerMid = 0;
    return h;
}

// The block the hit is on (volume space).
static inline int3 mcWorldHitCell(McWorldHit h) { return int3(floor(h.p - h.n * 1e-3)); }
// 1 if the game face-shades the face (mcFaceShade), 0 if not.
static inline float mcWorldHitShade(McWorldHit h) { return (h.flags & MCW_HIT_SHADE) != 0u ? 1.0 : 0.0; }
// The face's own light emission, 0..15: it is drawn at least this bright.
static inline float mcWorldHitGlow(McWorldHit h) { return float((h.flags >> 8) & 15u); }
// The water surface's normal and point (waterT >= 0).
static inline float3 mcWorldWaterN(McWorldHit h) { return mcDirVec(int((h.flags >> 12) & 7u)); }
static inline float3 mcWorldWaterP(McWorldHit h, float3 ro, float3 rd) { return ro + rd * h.waterT; }
// The translucent layer's normal (layerT >= 0).
static inline float3 mcWorldLayerN(McWorldHit h) { return mcDirVec(int((h.flags >> 15) & 7u)); }

static inline bool mcWorldHitSomething(McWorldHit h, float tMax) { return h.t < tMax; }

// How much sun a leaf block or a model lets through (mcWorldShadow).
constant float MCW_SHADOW_SOFT  = 0.45;

"""# + materials + #"""

// ---- The far field: the horizon beyond the volume -------------------------------
// far.rg16 and far.rgba8 cover a wider square than the volume, a texel a column.
// Marched at reduced detail (a step that grows with distance) and lit as open
// ground in daylight; it is there so the edge of the volume never shows as a
// cliff into void, and fog (mcWorldFog) takes it.

constant int MCW_FAR_STEPS = 128;

// Height of the top face of the far column at volume-space (x, z), and whether
// it is water; -1e4 where no chunk was saved.
static inline float mcwFarTop(McWorld W, int2 col, thread bool& wet) {
    int2 i = col - MCW_FAR_ORIGIN;
    wet = false;
    if (any(i < 0) || any(i >= MCW_FAR_SIZE)) return -1e4;
    ushort2 h = W.farH.read(uint2(i)).rg;
    if (h.r == 0) return -1e4;
    float ground = float(h.r) - 1.0 + float(MCW_FAR_MIN_Y);
    float water = h.g == 0 ? -1e4 : float(h.g) - 1.0 + float(MCW_FAR_MIN_Y);
    wet = water > ground;
    return max(ground, water);
}

// The highest surface in a 16 x 16 tile of far columns (tile = far texel / 16).
static inline float mcwFarTileTop(McWorld W, int2 tile) {
    if (any(tile < 0) || any(tile >= MCWK_FAR_TILES)) return -1e4;
    ushort m = W.farMax.read(uint2(tile)).r;
    return m == 0 ? -1e4 : float(m) - 1.0 + float(MCW_FAR_MIN_Y);
}

// The far field as columns, exactly: a tile the ray passes over is crossed in
// one step, otherwise the ray goes column by column, hitting a column's side
// or its top.
static inline McWorldHit mcwFarTrace(McWorld W, float3 ro, float3 rd, float t0, float tMax) {
    McWorldHit h = mcwMiss(tMax);
    float2 lo = float2(MCW_FAR_ORIGIN), hi = lo + float2(MCW_FAR_SIZE);
    float3 inv = mcModelInv(rd);
    float2 a = (lo - ro.xz) * inv.xz, b = (hi - ro.xz) * inv.xz;
    float tOut = min(min(max(a.x, b.x), max(a.y, b.y)), tMax);
    bool2 pos = rd.xz > 0.0;
    float t = max(t0, 0.0);
    int i = 0;
    for (; i < MCW_FAR_STEPS; ++i) {
        if (t >= tOut) break;
        float3 p = ro + rd * (t + 1e-3);
        if (rd.y >= 0.0 && p.y > MCWK_FAR_TOP) break;
        int2 col = int2(floor(p.xz));
        int2 rel = col - MCW_FAR_ORIGIN;
        int2 tile = rel >> 4;
        float2 tlo = lo + float2(tile * 16);
        float2 te = (select(tlo, tlo + 16.0, pos) - ro.xz) * inv.xz;
        float tTile = min(te.x, te.y);
        float yLow = rd.y < 0.0 ? ro.y + rd.y * tTile : p.y;
        if (yLow > mcwFarTileTop(W, tile)) { t = tTile; continue; }
        float2 clo = float2(col);
        float2 ce = (select(clo, clo + 1.0, pos) - ro.xz) * inv.xz;
        float tCol = min(ce.x, ce.y);
        bool wet;
        float top = mcwFarTop(W, col, wet);
        float yA = ro.y + rd.y * t, yB = ro.y + rd.y * tCol;
        if (min(yA, yB) < top) {
            float th;
            float3 n;
            if (yA < top) {
                // Into the column's side: the face whose slab the ray crossed last.
                float2 ci = (select(clo + 1.0, clo, pos) - ro.xz) * inv.xz;
                th = t;
                n = ci.x > ci.y ? float3(-sign(rd.x), 0.0, 0.0) : float3(0.0, 0.0, -sign(rd.z));
            } else {
                th = (top - ro.y) * inv.y;
                n = float3(0.0, 1.0, 0.0);
            }
            h.t = th; h.p = ro + rd * th; h.n = n;
            float4 c = W.far.read(uint2(rel), wet ? 1u : 0u);
            h.color = float4(c.rgb, 1.0);   // Display P3 since load
            h.flags = MCW_HIT_FAR | (wet ? MCW_HIT_WATER : 0u);
            h.steps = i + 1;
            return h;
        }
        t = tCol;
    }
    h.steps = i;
    return h;
}

// ---- The trace ------------------------------------------------------------------------
// mcWorldTrace(W, ro, rd, tMax): the first surface along the ray within tMax,
// in the volume and then the far field. Voxel DDA through blocks.r16: an air
// voxel's skip distance k means the cube [cell - (k-1), cell + k] is all air,
// so the ray jumps to that cube's far side in one step; a non-air voxel is
// tested (full cube, cut-out cube, model elements, fluid) and stepped past if
// the ray misses what is in it. Water is not a stop: the ray records the
// surface (waterT) and carries on to the bed, which the light bake has already
// darkened by depth as the game does.

constant int MCW_STEPS = 224;
// How far a ray goes into water before the bed is taken to be too deep in it
// to see, and the same behind a translucent layer (ice over a sea, where a
// ray at a slant would cross the sheet and the water under it a block at a
// time); it stops there and shows the water body, its tint x MCW_DEEP_WATER.
constant float MCW_WATER_REACH = 24.0;
constant float MCW_WATER_REACH_ICE = 6.0;
constant float MCW_DEEP_WATER = 0.25;

// One step of the skip DDA, written without indexing a vector by a variable
// (which can put it in memory): from cell c, whose cube of all-air cells
// reaches k - 1 cells out (k = 1: just the cell), to the cell beyond the
// cube's far side. Returns the distance there; `crossed` is the axis crossed.
static inline float mcwStep(thread int3& c, int k, float3 ro, float3 rd, float3 inv, int3 st,
                            thread bool3& crossed) {
    float3 lo = float3(c - (k - 1)), hi = float3(c + k);
    float3 tx = (select(lo, hi, st > 0) - ro) * inv;
    float tNext = min(min(tx.x, tx.y), tx.z);
    bool mx = tx.x == tNext, my = !mx && tx.y == tNext;
    crossed = bool3(mx, my, !mx && !my);
    int3 base = clamp(int3(floor(ro + rd * tNext)), int3(lo), int3(hi) - 1);
    c = select(base, select(int3(lo) - 1, int3(hi), st > 0), crossed);
    return tNext;
}

// The trace from tStart on, as if the ray had just left a cell of cull group
// `group`: how a look continues behind a translucent face (mcWorldTraceOn).
static inline McWorldHit mcwTraceFrom(McWorld W, float3 ro, float3 rd, float tStart, float tMax, uint group0,
                                      int maxSteps) {
    McWorldHit h = mcwMiss(tMax);
    // A degenerate camera (looking at a point it stands on) makes a NaN ray,
    // which would walk every step it is allowed on every pixel: it misses.
    if (!all(isfinite(rd)) || !all(isfinite(ro))) return h;
    float3 inv = mcModelInv(rd);
    float3 ta = (0.0 - ro) * inv, tb = (MCW_SIZEF - ro) * inv;
    float3 tn3 = min(ta, tb), tf3 = max(ta, tb);
    float tIn = max(max(tn3.x, tn3.y), tn3.z);
    float tOut = min(min(tf3.x, tf3.y), tf3.z);
    float tEnd = min(tOut, tMax);
    int steps = 0;
    if (tIn < tOut && tOut > tStart && tIn < tMax) {
        int3 st = int3(rd.x >= 0.0 ? 1 : -1, rd.y >= 0.0 ? 1 : -1, rd.z >= 0.0 ? 1 : -1);
        float t = max(tIn, tStart);
        int3 c = clamp(int3(floor(ro + rd * t)), int3(0), MCW_SIZE - 1);
        bool3 crossed = bool3(false);
        if (tIn > tStart) {
            bool mx = tn3.x >= tn3.y && tn3.x >= tn3.z, my = !mx && tn3.y >= tn3.z;
            crossed = bool3(mx, my, !mx && !my);
            c = select(c, select(MCW_SIZE - 1, int3(0), st > 0), crossed);
        }
        bool inWater = false;
        uint group = group0;   // the cull group of the cell the ray just left
        uint solid = 0u;       // an opaque full cube the ray stopped at, textured after the loop
        uint later = 0u;       // or a solid element face, the same
        bool deep = false;     // or the water's reach (MCW_WATER_REACH)
        for (; steps < maxSteps; ++steps) {
            if (t >= tEnd) break;
            uint v = uint(W.blocks.read(ushort3(c)).r);
            uint mid = v & 0x0FFFu;
            if (mid != 0u) {
                uint4 m0 = mcwMat(W, mid, 0u);
                // Most stops are an opaque full cube entered through a face:
                // leave the loop at once, so every lane textures together.
                if ((m0.x & (MCW_KIND_MASK | MCW_M_OPAQUE)) == (MCW_KIND_CUBE | MCW_M_OPAQUE)
                    && (m0.w & 3u) == 0u && any(crossed)) { solid = mid; break; }
                uint g = (m0.w >> 16) & 0xFFFu;
                // Inside the medium behind a translucent layer (the rest of an
                // ice sheet, or the water under it), well past the layer: a
                // ray at a slant crosses a one-block sheet a block at a time
                // for tens of blocks. Past MCW_WATER_REACH_ICE it shows
                // nothing more than the deep water's colour.
                if (h.layerT >= 0.0 && t - h.layerT > MCW_WATER_REACH_ICE
                    && ((g != 0u && g == group) || (m0.w & 3u) == 1u)) { deep = true; break; }
                // Open water under its surface: nothing to test, skip on.
                if (inWater && (m0.x & MCW_KIND_MASK) == 0u && (m0.w & 3u) == 1u) {
                    group = g;
                    t = mcwStep(c, max(int(v >> 12), 1), ro, rd, inv, st, crossed);
                    if (!mcwInBox(c)) break;
                    continue;
                }
                float3 nIn = select(float3(0.0), -float3(st), crossed);
                // A translucent full cube (ice, stained glass) as the first
                // layer: note it and go on; it is textured after the trace
                // (mcWorldTrace), so the lanes sample together. Its faces
                // against its own kind stay hidden (cull group).
                if (h.layerT < 0.0 && (m0.x & (MCW_KIND_MASK | MCW_M_TRANSLUCENT | MCW_M_CUTOUT))
                        == (MCW_KIND_CUBE | MCW_M_TRANSLUCENT) && (m0.w & 3u) == 0u && any(crossed)) {
                    uint d = mcwFaceOf(nIn);
                    if (!(g != 0u && g == group && ((m0.x >> (8u + d)) & 1u) != 0u)) {
                        h.layerT = t; h.layerMid = int(mid);
                        h.flags |= MCW_HIT_TRANSLUCENT | (d << 15);
                    }
                    group = g;
                    t = mcwStep(c, 1, ro, rd, inv, st, crossed);
                    if (!mcwInBox(c)) break;
                    continue;
                }
                McwCellHit ch = mcwCell(W, mid, m0, c, nIn, ro, rd, inv, t, tEnd, inWater, group, false);
                if (ch.water && h.waterT < 0.0) {
                    h.waterT = ch.waterT;
                    h.flags |= MCW_HIT_WATER | (ch.waterFace << 12);
                }
                inWater = ch.inWater;
                if (ch.hit && (ch.flags & MCW_HIT_TRANSLUCENT) != 0u && h.layerT < 0.0) {
                    // The first translucent face: keep it and go on through,
                    // past the faces it hides against its own kind.
                    // (an element's: textured after the trace, as a cube's is)
                    h.layerT = ch.t; h.layerMid = int(mid);
                    h.flags |= MCW_HIT_TRANSLUCENT | (mcwFaceOf(ch.n) << 15);
                } else if (ch.hit) {
                    h.t = ch.t; h.p = ro + rd * ch.t; h.n = ch.n; h.mid = int(mid);
                    h.color = ch.color; h.flags |= ch.flags & ~MCW_HIT_TRANSLUCENT;
                    if (ch.later != 0u) { later = ch.later; break; }
                    h.steps = steps + 1;
                    return h;
                }
                group = g;
            } else {
                inWater = false;
                group = 0u;
            }
            // Above everything in the volume and climbing: only the far
            // field (and the sky) is left.
            if (st.y > 0 && ro.y + rd.y * t >= MCWK_VOLUME_TOP) { tOut = t; break; }
            // Far under a water surface (under an ice sheet, seen at a slant,
            // a ray walks the water just below the ice a block at a time):
            // past MCW_WATER_REACH the bed is too deep in the water to show.
            if (inWater && t - h.waterT > (h.layerT >= 0.0 ? MCW_WATER_REACH_ICE : MCW_WATER_REACH)) { deep = true; break; }
            // Air's skip distance; water's too, once the ray is under its
            // surface (MinecraftWorld.swift derives it at load).
            int k = (mid == 0u || inWater) ? max(int(v >> 12), 1) : 1;
            t = mcwStep(c, k, ro, rd, inv, st, crossed);
            if (!mcwInBox(c)) break;
        }
        h.steps = steps;
        if (deep) {
            // The water body itself: its tint, dimmed as deep water is.
            h.t = t; h.p = ro + rd * t; h.n = -rd; h.mid = 0; h.steps = steps + 1;
            h.color = float4(mcWorldTint(W, h.p.xz, 2) * MCW_DEEP_WATER, 1.0);
            return h;
        }
        if (later != 0u) {
            h.steps = steps + 1;
            h.color = mcwElementTexel(W, uint(h.mid), c, later - 1u, ro, rd, h.t, h.n);
            return h;
        }
        if (solid != 0u) {
            float3 nIn = select(float3(0.0), -float3(st), crossed);
            uint d = mcwFaceOf(nIn), A;
            h.t = t; h.p = ro + rd * t; h.n = nIn; h.mid = int(solid); h.steps = steps + 1;
            float4 col = mcwCubeFace(W, solid, d, saturate(h.p - float3(c)), t * W.pxA, rd, nIn,
                                     float2(c.xz) + 0.5, A);
            h.color = float4(col.rgb, 1.0);
            h.flags |= mcwFaceFlags(A) | ((mcwMat(W, solid, 0u).x & MCW_M_FULLBRIGHT) != 0u ? MCW_HIT_EMISSIVE : 0u);
            return h;
        }
        if (steps >= maxSteps) {
            // Out of steps: say where the march stopped, and leave the rest to fog.
            h.t = min(t, tMax);
            h.p = ro + rd * h.t;
            h.flags |= MCW_HIT_FAR;
            h.color = float4(-1.0);
            return h;
        }
    }
    McWorldHit f = mcwFarTrace(W, ro, rd, max(tOut, tStart), tMax);
    f.steps += steps;
    f.waterT = h.waterT;
    f.flags |= h.flags & (MCW_HIT_WATER | MCW_HIT_TRANSLUCENT | (7u << 12) | (7u << 15));
    f.layerT = h.layerT; f.layerMid = h.layerMid;
    return f;
}

static inline McWorldHit mcWorldTrace(McWorld W, float3 ro, float3 rd, float tMax) {
    McWorldHit h = mcwTraceFrom(W, ro, rd, 0.0, tMax, 0u, MCW_STEPS);
    if (h.layerMid > 0) {
        // The translucent face noted on the way, textured now, so the lanes
        // sample together: a cube's face directly, an element's by testing
        // that cell again from just before it.
        float3 N = mcWorldLayerN(h);
        float3 P = ro + rd * h.layerT;
        int3 c = int3(floor(P - N * 1e-3));
        uint mid = uint(h.layerMid);
        uint4 m0 = mcwMat(W, mid, 0u);
        uint A;
        float4 col;
        if ((m0.x & MCW_KIND_MASK) == MCW_KIND_CUBE) {
            col = mcwCubeFace(W, mid, mcwFaceOf(N), saturate(P - float3(c)), h.layerT * W.pxA, rd, N,
                              float2(c.xz) + 0.5, A);
        } else {
            McwCellHit r = mcwCell(W, mid, m0, c, float3(0.0), ro, rd, mcModelInv(rd), h.layerT - 1e-4,
                                   h.layerT + 2.0, true, 0u, true);
            col = r.color;
            A = (r.flags & MCW_HIT_SHADE) != 0u ? (1u << 22) : 0u;
        }
        h.layerColor = col;
        h.flags |= ((A >> 22) & 1u) != 0u ? MCW_HIT_LAYER_SHADE : 0u;
    }
    return h;
}


// ---- Light ------------------------------------------------------------------------------

// The game's smooth lighting from the bake at a hit: block and sky light,
// linearly sampled half a block out from the face, so the four cells around
// each corner blend and corners against solid blocks darken. Coloured block
// light keeps its colour: each channel goes from the sky-only lightmap to the
// full one by the light's colour, so white and the game's warm torches give
// exactly the game's lightmap. `day` is mcLightDay(sun.y). `shadow` 1 is in
// the sun, 0 in shadow (mcWorldShadow): a shadowed face loses
// MCW_SHADOW_LEVELS of sky light in daylight, which the game does not do.
// Returns what to multiply the texel by, face shade included; emissive
// faces get full brightness.
constant float MCW_SHADOW_LEVELS = 4.0;

static inline float3 mcWorldLightAt(McWorld W, float3 p, float3 n, float day, float shadow) {
    float4 L = mcwLightAt(W, p + 0.5 * n);
    float sky = L.a * 15.0;
    sky = max(sky - MCW_SHADOW_LEVELS * (1.0 - shadow) * saturate(day * 1.25 - 0.25), 0.0);
    float m = max(L.r, max(L.g, L.b));
    float3 skyOnly = mcLightmap(0.0, sky, day, 0.0);
    if (m <= 0.002) return skyOnly;
    float3 full = mcLightmap(m * 15.0, sky, day, 0.0);
    float3 colour = mcFromSRGB(L.rgb / m);
    return mix(skyOnly, full, colour);
}

static inline float3 mcWorldLight(McWorld W, McWorldHit h, float day, float shadow) {
    if ((h.flags & MCW_HIT_EMISSIVE) != 0u) return float3(1.0);
    float shade = (h.flags & MCW_HIT_SHADE) != 0u ? mcFaceShade(h.n) : 1.0;
    if ((h.flags & MCW_HIT_FAR) != 0u) return mcLightmap(0.0, 15.0, day, 0.0) * mcFaceShade(h.n);
    // The game lights a model without ambient occlusion (a torch, a plant)
    // by the light of its own cell, flat; everything else smoothly.
    float3 l = (h.flags & MCW_HIT_FLAT) != 0u
             ? mcWorldLightAt(W, float3(mcWorldHitCell(h)) + 0.5, float3(0.0), day, shadow)
             : mcWorldLightAt(W, h.p, h.n, day, shadow);
    float glow = mcWorldHitGlow(h);
    if (glow > 0.0) l = max(l, mcLightmap(glow, 0.0, day, 0.0));
    return l * shade;
}

// ---- Shadows ----------------------------------------------------------------------------
// mcWorldShadow(W, p, n, L): 1 if the sun (or moon) along L reaches p, 0 if a
// block is in the way, between for leaves and models (each one the ray
// crosses lets MCW_SHADOW_SOFT through, without alpha testing). The same
// skip-DDA as the trace, from half a pixel off the face; a face turned away
// from L is in shadow. Cheap enough per pixel: open sky leaves the box in a
// few skips.
constant int   MCW_SHADOW_STEPS = 96;

// The shadow ray itself, from ro toward L, for at most maxSteps cells.
static inline float mcwShadowRay(McWorld W, float3 ro, float3 L, int maxSteps) {
    float3 inv = mcModelInv(L);
    int3 st = int3(L.x >= 0.0 ? 1 : -1, L.y >= 0.0 ? 1 : -1, L.z >= 0.0 ? 1 : -1);
    int3 c = int3(floor(ro));
    float lit = 1.0, t = 0.0;
    for (int i = 0; i < maxSteps; ++i) {
        if (!mcwInBox(c)) break;
        // Above everything in the volume and climbing: nothing left to block it.
        if (st.y > 0 && ro.y + L.y * t >= MCWK_VOLUME_TOP) break;
        uint v = uint(W.blocks.read(ushort3(c)).r);
        uint mid = v & 0x0FFFu;
        if (mid != 0u) {
            float o = mcwShadowOpacity(W, mid);
            lit *= 1.0 - o;
            if (lit < 0.02) return 0.0;
        }
        // Air's skip distance, and open water's (MinecraftWorld.swift gives
        // water one; every other block's is 0).
        int k = max(int(v >> 12), 1);
        bool3 crossed;
        t = mcwStep(c, k, ro, L, inv, st, crossed);
    }
    return lit;
}

static inline float mcWorldShadow(McWorld W, float3 p, float3 n, float3 L) {
    if (dot(n, L) <= 0.0) return 0.0;
    return mcwShadowRay(W, p + n * 0.002 + L * 0.001, L, MCW_SHADOW_STEPS);
}

// ---- Sky and fog ----------------------------------------------------------------------------

// The game's sky looking along rd, for a sun along `sun` (mcWorldSunDir): the
// sky colour over the fog colour at the horizon, warmed toward the sun at
// sunrise and sunset with the game's glow fan, stars at night, and the sun
// and moon from the game's textures (moon by phase, 0..7). Below the horizon
// it is the fog colour.
// Weather, as the game's client weighs it: `rain` and `thunder` 0..1 (the
// game's rain and thunder levels; thunder only ever comes with rain). They
// default to 0 in every function here that takes them, so a clear-sky look
// passes nothing. Rain greys the sky toward its luminance (0.6 of it, by
// 0.75 x rain) and thunder further (0.2, by 0.75 x thunder); the fog loses
// half its red and green and 0.4 of its blue in rain and half again in
// thunder; the sun, moon and stars fade out with rain.
static inline float3 mcwGrey(float3 c, float rain, float thunder) {
    float l = dot(c, float3(0.3, 0.59, 0.11));
    c = mix(c, float3(l * 0.6), rain * 0.75);
    float l2 = dot(c, float3(0.3, 0.59, 0.11));
    return mix(c, float3(l2 * 0.2), thunder * 0.75);
}

// The `day` the lightmap takes (mcLightDay), darkened by weather as the
// game darkens the sky: by 5/16 in full rain and 5/16 more in thunder.
static inline float mcWorldDay(float sunY, float rain = 0.0, float thunder = 0.0) {
    return mcLightDay(sunY) * (1.0 - rain * 5.0 / 16.0) * (1.0 - thunder * 5.0 / 16.0);
}

static inline float3 mcWorldSkyFog(float3 rd, float3 sun, float rain = 0.0, float thunder = 0.0) {
    float4 glow = mcSunsetAt(sun.y);
    glow.a *= 1.0 - rain;
    float3 f = mcFogToward(mcFogAt(mcSkyDay(sun.y)), glow, rd, sun);
    f *= float3(1.0 - rain * 0.5, 1.0 - rain * 0.5, 1.0 - rain * 0.4);
    return f * (1.0 - thunder * 0.5);
}

static inline float3 mcWorldSky(McWorld W, float3 rd, float3 sun, int moonPhase, float rain = 0.0,
                                float thunder = 0.0) {
    float day = mcSkyDay(sun.y);
    float4 glow = mcSunsetAt(sun.y);
    glow.a *= 1.0 - rain;
    float3 fog = mcWorldSkyFog(rd, sun, rain, thunder);
    float y = max(rd.y, 0.0);
    float3 col = mix(fog, mcwGrey(mcSkyAt(day), rain, thunder), 1.0 - exp(-y * 6.0));
    col = mix(col, glow.rgb, mcSunsetFan(rd, sun, glow));
    float night = (1.0 - day) * (1.0 - rain);
    if (night > 0.01 && rd.y > 0.0) {
        float3 g = floor(rd * 320.0);
        float s = hash21(g.xy + g.z * 37.1);
        col += step(0.9972, s) * night * night * (0.4 + 0.6 * hash21(g.zx)) * saturate(rd.y * 6.0);
    }
    for (int k = 0; k < 2; ++k) {
        float3 d = k == 0 ? sun : -sun;
        float hs = k == 0 ? 0.3 : 0.2;   // the game's 30 and 20 at a distance of 100
        float sd = dot(rd, d);
        if (sd <= 0.0) continue;
        float3 su = normalize(cross(d, float3(0.0, 0.0, 1.0)));
        float3 sv = cross(su, d);
        float2 q = float2(dot(rd, su), dot(rd, sv)) / sd / hs;
        if (max(abs(q.x), abs(q.y)) >= 1.0) continue;
        float2 px = (q * 0.5 + 0.5) * 32.0;
        float w = W.pxA / hs * 16.0;
        int layer = MCS_ENVIRONMENT_CELESTIAL_SUN;
        if (k == 1) {
            switch (moonPhase & 7) {
                case 0:  layer = MCS_ENVIRONMENT_CELESTIAL_MOON_FULL_MOON; break;
                case 1:  layer = MCS_ENVIRONMENT_CELESTIAL_MOON_WANING_GIBBOUS; break;
                case 2:  layer = MCS_ENVIRONMENT_CELESTIAL_MOON_THIRD_QUARTER; break;
                case 3:  layer = MCS_ENVIRONMENT_CELESTIAL_MOON_WANING_CRESCENT; break;
                case 4:  layer = MCS_ENVIRONMENT_CELESTIAL_MOON_NEW_MOON; break;
                case 5:  layer = MCS_ENVIRONMENT_CELESTIAL_MOON_WAXING_CRESCENT; break;
                case 6:  layer = MCS_ENVIRONMENT_CELESTIAL_MOON_FIRST_QUARTER; break;
                default: layer = MCS_ENVIRONMENT_CELESTIAL_MOON_WAXING_GIBBOUS; break;
            }
        }
        col += mcSkin(W.skins, layer, px, w).rgb * (k == 0 ? 1.0 : saturate((1.0 - day) * 1.5 + 0.2))
             * (1.0 - rain);
    }
    return col;
}

// The game's distance fog: linear from 90% of fogEnd to fogEnd (its fog for a
// render distance of fogEnd blocks), toward the fog colour along rd.
// mcWorldFogEnd() is the game's default render distance, 12 chunks. Nothing
// past the fog's end shows, so pass it as the trace's tMax: the march stops
// there and the sky takes the rest, as in the game.
constant float MCW_FOG_END = 192.0;
static inline float mcWorldFogEnd() { return MCW_FOG_END; }

static inline float3 mcWorldFog(float3 col, float3 rd, float t, float3 sun, float fogEnd, float rain = 0.0,
                                float thunder = 0.0) {
    float f = saturate((t - 0.9 * fogEnd) / (0.1 * fogEnd));
    return mix(col, mcWorldSkyFog(rd, sun, rain, thunder), f);
}

// ---- Water -----------------------------------------------------------------------------------
// What the water surface adds over what is seen through it (`under`, already
// lit): the animated still-water texture in the column's water tint, lit by
// the light above the surface, at the texture's own alpha, with a faint
// absorption toward the tint over `depth` blocks of water. `reflected` is the
// colour along the reflected ray if the look traced one (pass `under` to
// skip), weighted by a Schlick term; the game has no reflections.
static inline float3 mcWorldWater(McWorld W, McWorldHit h, float3 ro, float3 rd, float3 under, float depth,
                                  float day, float3 reflected) {
    float3 P = mcWorldWaterP(h, ro, rd);
    float3 N = mcWorldWaterN(h);
    int frame = mcFrame(MC_WATER_STILL, MC_WATER_STILL_FRAMES, MC_WATER_STILL_TICKS, W.time);
    float2 uv = mcBlockFaceUV(fract(P), N);
    float4 tex = mcTile(W.tiles, frame, uv, h.waterT * W.pxA);
    float3 tint = mcWorldTint(W, P.xz, 2);
    float3 lit = mcWorldLightAt(W, P, N, day, 1.0);
    float3 behind = mix(under, under * tint, saturate(depth / 12.0) * 0.6);
    float3 surf = tex.rgb * tint * lit;
    float3 col = mix(behind, surf, tex.a);
    float cosi = saturate(-dot(rd, N));
    float fres = 0.02 + 0.98 * pow(1.0 - cosi, 5.0);
    return mix(col, reflected, fres * 0.6);
}

// ---- One call for an ordinary look ----------------------------------------------------
// Trace, light (with sun shadows if `shadows`), water and fog, toward the sky:
// the colour a pixel shows along the ray. Everything it does is the functions
// above, so a look that wants more (reflections, mobs in the scene, its own
// fog) calls them itself.
// A hit's own colour, lit (and shadowed if `shadows`), before water and fog;
// the sky for a miss. A surface seen through water takes no sun shadow: the
// water's own darkening with depth (the light bake's, as the game does it)
// is what shows there, and a shadow ray from every pixel of a lake bed costs
// about as much as the whole trace.
static inline float3 mcWorldColor(McWorld W, McWorldHit h, float3 rd, float3 sun, int moonPhase,
                                    bool shadows, float tMax, float rain = 0.0, float thunder = 0.0) {
    if (h.t >= tMax) return mcWorldSky(W, rd, sun, moonPhase, rain, thunder);
    if (h.color.a < 0.0) return mcWorldSkyFog(rd, sun, rain, thunder);
    float3 L = sun.y > -0.05 ? sun : -sun;
    float sh = 1.0;
    // A flat model (a plant's crossed quads) is lit from either side.
    float3 sn = (h.flags & MCW_HIT_FLAT) != 0u && dot(h.n, L) < 0.0 ? -h.n : h.n;
    if (shadows && rain < 1.0 && h.waterT < 0.0 && (h.flags & (MCW_HIT_FAR | MCW_HIT_EMISSIVE)) == 0u)
        sh = mix(mcWorldShadow(W, h.p, sn, L), 1.0, rain);   // rain: no direct sun
    return h.color.rgb * mcWorldLight(W, h, mcWorldDay(sun.y, rain, thunder), sh);
}

// Water over `col` (what is seen through it) and the fog to the first surface.
static inline float3 mcwWaterFog(McWorld W, McWorldHit h, float3 col, float3 ro, float3 rd, float3 sun, float fogEnd,
                                 float tMax, float rain, float thunder, float3 reflected, bool reflect) {
    if (h.waterT < 0.0) return h.t >= tMax ? col : mcWorldFog(col, rd, h.t, sun, fogEnd, rain, thunder);
    float depth = h.t >= tMax ? 16.0 : h.t - h.waterT;
    col = mcWorldWater(W, h, ro, rd, col, depth, mcWorldDay(sun.y, rain, thunder), reflect ? reflected : col);
    return mcWorldFog(col, rd, h.waterT, sun, fogEnd, rain, thunder);
}

// The translucent layer a hit passed through (ice over water, a glass pane),
// lit, over `behind` (what mcWorldColor and the water made of the rest), at
// its texels' alpha, fogged to its distance.
static inline float3 mcWorldLayer(McWorld W, McWorldHit h, float3 ro, float3 rd, float3 behind, float3 sun,
                                  float fogEnd, float rain = 0.0, float thunder = 0.0) {
    float3 P = ro + rd * h.layerT;
    float3 N = mcWorldLayerN(h);
    float3 lit = mcWorldLightAt(W, P, N, mcWorldDay(sun.y, rain, thunder), 1.0)
               * ((h.flags & MCW_HIT_LAYER_SHADE) != 0u ? mcFaceShade(N) : 1.0);
    float3 front = mcWorldFog(h.layerColor.rgb * lit, rd, h.layerT, sun, fogEnd, rain, thunder);
    return mix(behind, front, h.layerColor.a);
}

static inline float3 mcWorldShade(McWorld W, McWorldHit h, float3 ro, float3 rd, float3 sun,
                                  int moonPhase, bool shadows, float fogEnd, float tMax, float rain = 0.0,
                                  float thunder = 0.0) {
    float3 col = mcwWaterFog(W, h, mcWorldColor(W, h, rd, sun, moonPhase, shadows, tMax, rain, thunder), ro, rd,
                             sun, fogEnd, tMax, rain, thunder, float3(0.0), false);
    if (h.layerT >= 0.0) col = mcWorldLayer(W, h, ro, rd, col, sun, fogEnd, rain, thunder);
    return col;
}

// ---- Reflections ------------------------------------------------------------------------------
// What a water surface reflects (the game has none): the reflected ray traced
// into the world for at most `maxSteps` cells (24 is a good start: near
// banks, boats, and the sky, which is most of a lake's reflection), lit
// without shadows, fogged, the sky where it leaves. A second trace costs
// about as much as the first where it runs, so a look decides where.
// mcWorldShadeReflect is mcWorldShade with it laid on the water.
static inline float3 mcWorldReflect(McWorld W, McWorldHit h, float3 ro, float3 rd, float3 sun, int moonPhase,
                                    float fogEnd, int maxSteps, float rain = 0.0, float thunder = 0.0) {
    float3 N = mcWorldWaterN(h);
    float3 P = mcWorldWaterP(h, ro, rd) + N * 0.002;
    float3 r = reflect(rd, N);
    McWorldHit g = mcwTraceFrom(W, P, r, 0.0, fogEnd, 0u, maxSteps);
    float3 c = mcWorldColor(W, g, r, sun, moonPhase, false, fogEnd, rain, thunder);
    return g.t >= fogEnd ? c : mcWorldFog(c, r, g.t + h.waterT, sun, fogEnd, rain, thunder);
}

static inline float3 mcWorldShadeReflect(McWorld W, McWorldHit h, float3 ro, float3 rd, float3 sun,
                                         int moonPhase, bool shadows, float fogEnd, float tMax, int maxSteps,
                                         float rain = 0.0, float thunder = 0.0) {
    float3 refl = h.waterT >= 0.0 ? mcWorldReflect(W, h, ro, rd, sun, moonPhase, fogEnd, maxSteps, rain, thunder)
                                  : float3(0.0);
    float3 col = mcwWaterFog(W, h, mcWorldColor(W, h, rd, sun, moonPhase, shadows, tMax, rain, thunder), ro, rd,
                             sun, fogEnd, tMax, rain, thunder, refl, h.waterT >= 0.0);
    if (h.layerT >= 0.0) col = mcWorldLayer(W, h, ro, rd, col, sun, fogEnd, rain, thunder);
    return col;
}

// ---- Light shafts -----------------------------------------------------------------------------
// How much of the view ray's first `reach` blocks (up to tEnd) is open to the
// sun along L, 0..1: `samples` points (4 to 8) jittered per pixel by `pos`,
// so banding turns into fine noise. Each point is judged by the baked sky
// light a few blocks toward the sun from it (open sky there reads 15; under a
// canopy, an overhang or a roof it reads less), one filtered read, not a
// shadow ray: shadow rays per sample cost 9 ms at 4 samples in the dense
// `mine` view, this about a texture read a sample. So the shafts follow the
// gaps in leaves and roofs toward the sun, but a lone pillar casts none. A
// look adds the fog colour (or the low sun's glow) times it times a strength:
//   col += mcWorldSkyFog(rd, sun) * 0.25 * mcWorldShafts(W, ro, rd, h.t, sun, pos, 6, 48.0);
constant float MCW_SHAFT_LOOK = 3.0;   // blocks toward the sun each sample looks

static inline float mcWorldShafts(McWorld W, float3 ro, float3 rd, float tEnd, float3 L, float4 pos,
                                  int samples, float reach) {
    float len = min(tEnd, reach);
    float j = fract(52.9829189 * fract(dot(pos.xy, float2(0.06711056, 0.00583715))));   // interleaved gradient noise
    float lit = 0.0;
    for (int i = 0; i < samples; ++i) {
        float3 p = ro + rd * (len * (float(i) + j) / float(samples)) + L * MCW_SHAFT_LOOK;
        lit += saturate((mcwLightAt(W, p).a - 0.8) * 5.0);
    }
    return lit / float(max(samples, 1));
}

// ---- Clouds -----------------------------------------------------------------------------------
// The game's clouds: clouds.png, a pixel a 12 x 12 block cell, 4 blocks thick
// from world y 192.33, drifting toward -x at 0.03 blocks a tick on the shared
// clock (the same sky on every Mac), drawn as the game's "fancy" boxes: tops
// 1, bottoms 0.7, x sides 0.9, z sides 0.8, white dimmed with the day and
// greyed by rain. Returns the colour and coverage (the game's 0.8, fading out
// toward `reach`) to lay over whatever the ray saw before tMax:
//   float4 cl = mcWorldClouds(W, ro, rd, h.t, sun, 0.0, 600.0); col = mix(col, cl.rgb, cl.a);
constant int MCW_CLOUD_STEPS = 24;

static inline float4 mcWorldClouds(McWorld W, float3 ro, float3 rd, float tMax, float3 sun, float rain,
                                   float reach) {
    float y0 = 192.33 - float(MCW_ORIGIN.y), y1 = y0 + 4.0;
    if (abs(rd.y) < 1e-5 && (ro.y < y0 || ro.y > y1)) return float4(0.0);
    float3 inv = mcModelInv(rd);
    float ta = (y0 - ro.y) * inv.y, tb = (y1 - ro.y) * inv.y;
    float tIn = max(min(ta, tb), 0.0), tOut = min(max(ta, tb), min(tMax, reach));
    if (tIn >= tOut) return float4(0.0);
    // Cloud space: world blocks, scrolled with the wind, in 12-block cells.
    float drift = mcWorldSeconds(W, W.time, 5120) * 0.6;   // 3072 blocks (the whole picture) every 5120 s
    float2 off = float2(MCW_ORIGIN.xz) + float2(drift, 0.0);   // sampled ahead in x: the clouds move toward -x
    float2 o = (ro.xz + off) / 12.0, d = rd.xz / 12.0;
    float2 di = 1.0 / select(d, float2(1e-9), abs(d) < 1e-9);
    float t = tIn;
    bool top = true;   // entered through the slab's top or bottom
    bool sideX = false;
    for (int i = 0; i < MCW_CLOUD_STEPS; ++i) {
        if (t >= tOut) break;
        float2 q = o + d * (t + 1e-3);
        float2 cell = floor(q);
        float2 px = glmod2(cell, 256.0) + 0.5;
        if (mcMap(W.maps, MCM_ENVIRONMENT_CLOUDS, px, 0.0).a > 0.5) {
            float shade = top ? (rd.y < 0.0 ? 1.0 : 0.7) : (sideX ? 0.9 : 0.8);
            float day = mcSkyDay(sun.y);
            float3 c = float3(day * 0.9 + 0.1);
            c = mix(c, float3(dot(c, float3(0.3, 0.59, 0.11)) * 0.6), rain * 0.95);
            float fade = 1.0 - smoothstep(0.6 * reach, reach, t);
            return float4(c * shade, 0.8 * fade);
        }
        float2 te = (select(cell, cell + 1.0, d > 0.0) - o) * di;
        sideX = te.x < te.y;
        t = min(te.x, te.y);
        top = false;
    }
    return float4(0.0);
}

// ---- For cameras ------------------------------------------------------------------------------

// Height of the ground at volume-space (x, z): the top face of the highest
// non-air, non-fluid block in that column (from far.rg16, which covers the
// volume too), or -1e4 where nothing was saved. `water` is the water surface
// above it, or the same height when dry.
static inline float mcWorldGround(McWorld W, float2 xz, thread float& water) {
    int2 i = int2(floor(xz)) - MCW_FAR_ORIGIN;
    if (any(i < 0) || any(i >= MCW_FAR_SIZE)) { water = -1e4; return -1e4; }
    ushort2 h = W.farH.read(uint2(i)).rg;
    float ground = h.r == 0 ? -1e4 : float(h.r) - 1.0 + float(MCW_FAR_MIN_Y);
    water = h.g == 0 ? ground : max(ground, float(h.g) - 1.0 + float(MCW_FAR_MIN_Y));
    return ground;
}

// The highest surface at (x, z), ground or water: where a camera must stay above.
static inline float mcWorldSurface(McWorld W, float2 xz) {
    float water;
    float g = mcWorldGround(W, xz, water);
    return max(g, water);
}

// Whether p (volume space) is inside a block a camera should not be in: any
// non-air voxel but water and the plants and small things a mob walks through.
static inline bool mcWorldSolid(McWorld W, float3 p) {
    int3 c = int3(floor(p));
    if (!mcwInBox(c)) return false;
    uint mid = uint(W.blocks.read(ushort3(c)).r) & 0x0FFFu;
    return mid != 0u && mcwSolid(W, mid);
}

// A mob walking route `r` (0..MCW_ROUTE_COUNT-1) at `speed` blocks a second:
// where its feet are at time t (volume space), standing on what is under them
// (half a block up on a slab, a sixteenth down on a path), and its heading
// (0 faces +z, pi/2 faces +x, as mcMobRay takes it). A step up is a hop.
static inline float3 mcWorldRoute(int r, float t, float speed, thread float& heading) {
    ushort4 R = MCW_ROUTES[clamp(r, 0, MCW_ROUTE_COUNT - 1)];
    float n = float(R.y);
    float s = glmod(t * speed, n);
    int k = int(s);
    float f = s - float(k);
    ushort4 a = MCW_ROUTE_POINTS[R.x + k];
    ushort4 b = MCW_ROUTE_POINTS[R.x + (k + 1 == int(R.y) ? 0 : k + 1)];
    // Standing height: a path, slab, stair or snow under the feet (FORMAT.md
    // routes: drop and rise, sixteenths, in the flags).
    float ya = (float((a.w >> 8) & 15u) - float((a.w >> 4) & 15u)) / 16.0;
    float yb = (float((b.w >> 8) & 15u) - float((b.w >> 4) & 15u)) / 16.0;
    float3 A = float3(a.xyz) + float3(0.5, ya, 0.5), B = float3(b.xyz) + float3(0.5, yb, 0.5);
    float2 d = B.xz - A.xz;
    heading = atan2(d.x, d.y);
    float3 p = mix(A, B, f);
    float dy = B.y - A.y;
    if (dy > 0.0) p.y = A.y + dy * smoothstep(0.1, 0.6, f) + 0.25 * sin(saturate(f) * M_PI_F);
    else if (dy < 0.0) p.y = A.y + dy * smoothstep(0.4, 0.9, f);
    return p;
}

// A position on a route, with what a walking mob needs to know about it.
struct McWorldRoutePos {
    float3 feet;      // volume space; a step up is a hop
    float  heading;   // 0 faces +z, pi/2 faces +x (mcMobRay)
    float  climb;     // the step under way: 1 up, -1 down, 0 level
    int    point;     // index into MCW_ROUTE_POINTS of the point it left
    uint   flags;     // that point's flags (FORMAT.md routes: 1 dirt path, 2 farmland, 4 by a waypoint)
};

static inline McWorldRoutePos mcWorldRouteAt(int r, float t, float speed) {
    McWorldRoutePos o;
    o.feet = mcWorldRoute(r, t, speed, o.heading);
    ushort4 R = MCW_ROUTES[clamp(r, 0, MCW_ROUTE_COUNT - 1)];
    int k = int(glmod(t * speed, float(R.y)));
    ushort4 a = MCW_ROUTE_POINTS[R.x + k];
    ushort4 b = MCW_ROUTE_POINTS[R.x + (k + 1 == int(R.y) ? 0 : k + 1)];
    o.climb = sign(float(b.y) - float(a.y));
    o.point = int(R.x) + k;
    o.flags = uint(a.w);
    return o;
}

// ---- end of the world tracer ------------------------------------------------------------------

"""#

    /// Reading MATERIALS' tables (`FORMAT.md` "Materials and elements"):
    /// what one non-air cell shows a ray. Spliced in before the trace.
    static let materials = #"""

// ---- Materials and elements (FORMAT.md "Materials and elements") ---------------
// materials.u32: a row of 8 rgba32Uint texels per material id; elements.u32: a
// row of 20 per model element. Words are read as texels: word k is texel
// k / 4, component k % 4.

constant uint MCW_KIND_MASK = 3u, MCW_KIND_CUBE = 1u, MCW_KIND_ELEMENTS = 2u;
constant uint MCW_M_OPAQUE = 1u << 2, MCW_M_CUTOUT = 1u << 3, MCW_M_TRANSLUCENT = 1u << 4,
              MCW_M_FULLBRIGHT = 1u << 5, MCW_M_NO_AO = 1u << 6, MCW_M_SHADOW = 1u << 23;

static inline uint4 mcwMat(McWorld W, uint mid, uint texel) { return W.mats.read(uint2(texel, mid)); }

// Which frame of a face's texture shows at `time` (seconds): consecutive layers.
static inline uint mcwLayerAt(uint A, uint B, float time) {
    uint frames = B & 0xFFu, ticks = max((B >> 8) & 0xFFFFu, 1u);
    uint base = A & 0xFFFu;
    if (frames <= 1u) return base;
    return base + (uint(max(time, 0.0) * 20.0) / ticks) % frames;
}

// A face's tint by code (FORMAT: 1 grass, 2 foliage, 3 water, 4 dry foliage,
// 5 and 6 the material's fixed colours), Display P3-encoded like the texels,
// which it multiplies as the game multiplies its encoded colours.
static inline float3 mcwTint(McWorld W, uint code, float2 xz, uint mid) {
    if (code == 0u) return float3(1.0);
    if (code <= 4u) return mcWorldTint(W, xz, int(code) - 1);
    uint rgb = code == 5u ? mcwMat(W, mid, 1u).x : mcwMat(W, mid, 1u).y;
    return mcFromSRGB(float3((rgb >> 16) & 0xFFu, (rgb >> 8) & 0xFFu, rgb & 0xFFu) / 255.0);
}

// A face's texel at `px` (pixels in its layer), tinted. `fp` is the width of
// a screen pixel at the hit, in blocks.
static inline float4 mcwFaceTexel(McWorld W, uint A, uint B, float2 px, float fp, float2 xz, uint mid) {
    uint layer = mcwLayerAt(A, B, W.time);
    float4 c = ((A >> 12) & 1u) != 0u ? mcSkin(W.skins, int(layer), px, fp * 16.0)
                                      : mcTile(W.tiles, int(layer), px / 16.0, fp);
    c.rgb *= mcwTint(W, (A >> 16) & 15u, xz, mid);
    return c;
}

// The face index (0 down, 1 up, 2 north, 3 south, 4 west, 5 east) of an
// outward normal.
static inline uint mcwFaceOf(float3 n) {
    if (n.y < -0.5) return 0u;
    if (n.y > 0.5)  return 1u;
    if (n.z < -0.5) return 2u;
    if (n.z > 0.5)  return 3u;
    return n.x < 0.0 ? 4u : 5u;
}

// FORMAT "Cube faces": a full tile's canonical (s, t) on face d at block-space p.
static inline float2 mcwCubeST(uint d, float3 p) {
    switch (d) {
        case 0u: return float2(p.x, 1.0 - p.z);
        case 1u: return float2(p.x, p.z);
        case 2u: return float2(1.0 - p.x, 1.0 - p.y);
        case 3u: return float2(p.x, 1.0 - p.y);
        case 4u: return float2(p.z, 1.0 - p.y);
        default: return float2(1.0 - p.z, 1.0 - p.y);
    }
}

static inline float2 mcwOrient(float2 st, uint A) {
    uint o = (A >> 13) & 7u;
    float2 uv = (o & 4u) != 0u ? st.yx : st;
    if ((o & 1u) != 0u) uv.x = 1.0 - uv.x;
    if ((o & 2u) != 0u) uv.y = 1.0 - uv.y;
    return uv;
}

// FORMAT "Random variants and offsets": the game's random shift of a plant in
// its cell (block units), from the world column.
static inline float3 mcwPlantOffset(int3 cell, uint w0, uint w7) {
    uint kind = (w0 >> 20) & 3u;
    if (kind == 0u) return float3(0.0);
    int3 wp = cell + MCW_ORIGIN;
    uint l = (uint(wp.x) * 3129871u) ^ (uint(wp.z) * 116129781u);
    l = l * l * 42317861u + l * 11u;
    uint h = l >> 16;
    float mh = float(w7 & 0xFFFFu) / 1000.0, mv = float(w7 >> 16) / 1000.0;
    float3 off;
    off.x = clamp((float(h & 15u) / 15.0 - 0.5) * 0.5, -mh, mh);
    off.z = clamp((float((h >> 8) & 15u) / 15.0 - 0.5) * 0.5, -mh, mh);
    off.y = kind == 2u ? (float((h >> 4) & 15u) / 15.0 - 1.0) * mv : 0.0;
    return off;
}

// How much of the sun a material stops, for mcWorldShadow: a full opaque block
// all of it, a cut-out cube (leaves, glass) some, a model (stairs, fences,
// plants) less, without testing texels; fluids and air nothing.
static inline float mcwShadowOpacity(McWorld W, uint mid) {
    uint w0 = mcwMat(W, mid, 0u).x;
    if ((w0 & MCW_M_SHADOW) == 0u) return 0.0;
    if ((w0 & MCW_M_OPAQUE) != 0u) return 1.0;
    return (w0 & MCW_KIND_MASK) == MCW_KIND_CUBE ? MCW_SHADOW_SOFT : MCW_SHADOW_SOFT * 0.6;
}

// Whether a camera should stay out of a material: it has geometry and is not a
// plant or a torch (cut out with no ambient occlusion, which is how the game's
// models mark them).
static inline bool mcwSolid(McWorld W, uint mid) {
    uint w0 = mcwMat(W, mid, 0u).x;
    if ((w0 & MCW_KIND_MASK) == 0u) return false;
    return (w0 & MCW_M_NO_AO) == 0u || (w0 & MCW_M_OPAQUE) != 0u;
}

// What a ray meets in one non-air cell, from t (where it entered, through the
// face with outward normal nIn; zero if it started inside) to the cell's exit.
struct McwCellHit {
    bool   hit;
    float  t;
    float3 n;
    float4 color;
    uint   flags;     // MCW_HIT_*, with the shade bit and glow packed as in McWorldHit
    bool   water;     // the ray entered water in this cell
    float  waterT;
    uint   waterFace; // the surface's face (MC_DIR_*)
    bool   inWater;   // and is in water as it leaves
    uint   later;     // a solid element face hit, not yet textured: (row << 3 | face) + 1, else 0
};

// A face descriptor's shade bit and light emission, as McWorldHit packs them.
static inline uint mcwFaceFlags(uint A) {
    return (((A >> 22) & 1u) != 0u ? MCW_HIT_SHADE : 0u) | (((A >> 24) & 15u) << 8);
}

// The geometry of a cube or element material in cell c (mcwCell's second half).
// A full cube's face d at block-space P: its texel with the overlay laid on
// (FORMAT "Cube faces"); A is the face's descriptor, or 0 if it has none.
static inline float4 mcwCubeFace(McWorld W, uint mid, uint d, float3 P, float fp, float3 rd, float3 nIn,
                                 float2 xz, thread uint& A) {
    uint4 fd = mcwMat(W, mid, 2u + d / 2u);
    A = (d & 1u) != 0u ? fd.z : fd.x;
    uint B = (d & 1u) != 0u ? fd.w : fd.y;
    if (((A >> 23) & 1u) == 0u) { A = 0u; return float4(0.0); }
    float2 st = mcwCubeST(d, P);
    float fpa = fp / sqrt(max(abs(dot(rd, nIn)), 0.05));
    float4 col = mcwFaceTexel(W, A, B, mcwOrient(st, A) * 16.0, fpa, xz, mid);
    uint4 od = mcwMat(W, mid, 5u + d / 2u);
    uint OA = (d & 1u) != 0u ? od.z : od.x, OB = (d & 1u) != 0u ? od.w : od.y;
    if (((OA >> 23) & 1u) != 0u) {
        float4 ov = mcwFaceTexel(W, OA, OB, mcwOrient(st, OA) * 16.0, fpa, xz, mid);
        col.rgb = mix(col.rgb, ov.rgb, ov.a);
    }
    return col;
}

static inline McwCellHit mcwGeometry(McWorld W, McwCellHit r, uint mid, uint4 m0, int3 c, float3 nIn, float3 o,
                                     float3 rd, float3 inv, float t, float tExit, float fp, float2 xz,
                                     uint prevGroup, bool texture) {
    uint w0 = m0.x, w3 = m0.w;
    uint kind = w0 & MCW_KIND_MASK;

    if (kind == MCW_KIND_CUBE) {
        if (all(nIn == 0.0)) return r;                       // started inside it
        uint d = mcwFaceOf(nIn);
        uint group = (w3 >> 16) & 0xFFFu;
        if (group != 0u && group == prevGroup && ((w0 >> (8u + d)) & 1u) != 0u) return r;
        uint A;
        float4 col = mcwCubeFace(W, mid, d, saturate(o + rd * t), fp, rd, nIn, xz, A);
        if (A == 0u) return r;
        uint render = (A >> 20) & 3u;
        if (render == 1u && col.a < 0.5) return r;
        if (render == 2u && col.a < 0.1) return r;
        r.hit = true; r.t = t; r.n = nIn;
        r.color = float4(col.rgb, render == 2u ? col.a : 1.0);
        r.flags = mcwFaceFlags(A) | (render == 2u ? MCW_HIT_TRANSLUCENT : 0u)
                | ((w0 & MCW_M_FULLBRIGHT) != 0u ? MCW_HIT_EMISSIVE : 0u);
        return r;
    }

    // Elements: the nearest entry face over all of them, within the cell.
    uint4 m1 = mcwMat(W, mid, 1u);
    float3 eo = o - mcwPlantOffset(c, w0, m1.w);
    uint first = m0.y, count = min(m0.z, 64u);
    float best = tExit;
    float tMin = all(nIn == 0.0) ? t : t - 1e-4;
    for (uint e = 0u; e < count; ++e) {
        uint row = first + e;
        uint4 a = W.elems.read(uint2(0u, row));
        uint4 b = W.elems.read(uint2(1u, row));
        float3 lo = as_type<float3>(a.xyz), hi = as_type<float3>(b.xyz);
        uint fl = a.w;
        float3 qo = eo, qd = rd;
        float4 R0 = float4(1, 0, 0, 0), R1 = float4(0, 1, 0, 0), R2 = float4(0, 0, 1, 0);
        bool xf = (fl & 1u) != 0u;
        if (xf) {
            R0 = as_type<float4>(W.elems.read(uint2(2u, row)));
            R1 = as_type<float4>(W.elems.read(uint2(3u, row)));
            R2 = as_type<float4>(W.elems.read(uint2(4u, row)));
            qo = float3(dot(R0.xyz, eo) + R0.w, dot(R1.xyz, eo) + R1.w, dot(R2.xyz, eo) + R2.w);
            qd = float3(dot(R0.xyz, rd), dot(R1.xyz, rd), dot(R2.xyz, rd));
        }
        float3 qi = 1.0 / select(qd, float3(1e-9), abs(qd) < 1e-9);
        float3 t0 = (lo - qo) * qi, t1 = (hi - qo) * qi;
        float3 tn = min(t0, t1), tf = max(t0, t1);
        float tNear = max(max(tn.x, tn.y), tn.z), tFar = min(min(tf.x, tf.y), tf.z);
        if (tNear > tFar + 1e-6 || tNear < tMin || tNear >= best) continue;
        bool ex = tn.x >= tn.y && tn.x >= tn.z, ey = !ex && tn.y >= tn.z;
        uint d = ex ? (qd.x > 0.0 ? 4u : 5u) : (ey ? (qd.y > 0.0 ? 0u : 1u) : (qd.z > 0.0 ? 2u : 3u));
        if (((fl >> (1u + d)) & 1u) == 0u) continue;
        uint4 fd = W.elems.read(uint2(17u + d / 2u, row));
        uint A = (d & 1u) != 0u ? fd.z : fd.x, B = (d & 1u) != 0u ? fd.w : fd.y;
        uint render = (A >> 20) & 3u;
        float3 nq = select(float3(0.0), select(float3(1.0), float3(-1.0), qd > 0.0), bool3(ex, ey, !ex && !ey));
        float3 n = xf ? normalize(nq.x * R0.xyz + nq.y * R1.xyz + nq.z * R2.xyz) : nq;
        r.later = 0u;
        if (render == 0u && !texture) {
            // A solid face needs no texel to know it stops the ray: textured
            // once the trace is over (mcwElementTexel), so lanes sample together.
            r.later = ((row << 3) | d) + 1u;
        } else {
            float3 q = qo + qd * tNear;
            float4 U = as_type<float4>(W.elems.read(uint2(5u + 2u * d, row)));
            float4 V = as_type<float4>(W.elems.read(uint2(6u + 2u * d, row)));
            float2 px = float2(dot(U.xyz, q) + U.w, dot(V.xyz, q) + V.w);
            float4 col = mcwFaceTexel(W, A, B, px, tNear * W.pxA / sqrt(max(abs(dot(rd, n)), 0.05)), xz, mid);
            if (render == 1u && col.a < 0.5) continue;
            if (render == 2u && col.a < 0.1) continue;
            r.color = float4(col.rgb, render == 2u ? col.a : 1.0);
        }
        best = tNear;
        r.hit = true; r.t = tNear; r.n = n;
        r.flags = mcwFaceFlags(A) | MCW_HIT_MODEL | (render == 2u ? MCW_HIT_TRANSLUCENT : 0u)
                | ((w0 & MCW_M_FULLBRIGHT) != 0u ? MCW_HIT_EMISSIVE : 0u)
                | ((w0 & MCW_M_NO_AO) != 0u ? MCW_HIT_FLAT : 0u);
    }
    return r;
}

// The texel of element face `code` (row << 3 | face) of material mid in cell
// c, where the ray meets it at t: what mcwCell left for later.
static inline float4 mcwElementTexel(McWorld W, uint mid, int3 c, uint code, float3 ro, float3 rd, float t,
                                     float3 n) {
    uint row = code >> 3, d = code & 7u;
    uint4 m0 = mcwMat(W, mid, 0u);
    float3 q = ro - float3(c) - mcwPlantOffset(c, m0.x, mcwMat(W, mid, 1u).w) + rd * t;
    if ((W.elems.read(uint2(0u, row)).w & 1u) != 0u) {
        float4 R0 = as_type<float4>(W.elems.read(uint2(2u, row)));
        float4 R1 = as_type<float4>(W.elems.read(uint2(3u, row)));
        float4 R2 = as_type<float4>(W.elems.read(uint2(4u, row)));
        q = float3(dot(R0.xyz, q) + R0.w, dot(R1.xyz, q) + R1.w, dot(R2.xyz, q) + R2.w);
    }
    float4 U = as_type<float4>(W.elems.read(uint2(5u + 2u * d, row)));
    float4 V = as_type<float4>(W.elems.read(uint2(6u + 2u * d, row)));
    uint4 fd = W.elems.read(uint2(17u + d / 2u, row));
    uint A = (d & 1u) != 0u ? fd.z : fd.x, B = (d & 1u) != 0u ? fd.w : fd.y;
    float2 px = float2(dot(U.xyz, q) + U.w, dot(V.xyz, q) + V.w);
    float4 col = mcwFaceTexel(W, A, B, px, t * W.pxA / sqrt(max(abs(dot(rd, n)), 0.05)),
                              float2(c.xz) + 0.5, mid);
    return float4(col.rgb, 1.0);
}

// `texture` false lets a solid element face come back untextured (`later`).
static inline McwCellHit mcwCell(McWorld W, uint mid, uint4 m0, int3 c, float3 nIn, float3 ro, float3 rd,
                                 float3 inv, float t, float tEnd, bool inWater, uint prevGroup, bool texture) {
    McwCellHit r;
    r.hit = false; r.t = tEnd; r.n = nIn; r.color = float4(0.0); r.flags = 0u;
    r.water = false; r.waterT = -1.0; r.waterFace = 1u; r.inWater = false; r.later = 0u;
    uint w0 = m0.x, w3 = m0.w;
    float3 o = ro - float3(c);                       // block space
    float3 cellHi = (select(float3(0.0), float3(1.0), rd > 0.0) - o) * inv;
    float tExit = min(min(cellHi.x, cellHi.y), cellHi.z);
    float fp = t * W.pxA;
    float2 xz = float2(c.xz) + 0.5;

    // Fluid first: its surface, then whatever geometry shares the cell.
    uint fluid = w3 & 3u;
    if (fluid != 0u) {
        float hgt = ((w3 >> 6) & 1u) != 0u ? 1.0 : float((w3 >> 2) & 15u) / 9.0;
        uint above = mcwVoxel(W, c + int3(0, 1, 0)) & 0x0FFFu;
        if (above != 0u && (mcwMat(W, above, 0u).w & 3u) == fluid) hgt = 1.0;
        float py = o.y + rd.y * t;
        float tw = -1.0;
        float3 wn = float3(0.0, 1.0, 0.0);
        bool entered = any(nIn != 0.0);
        if (py <= hgt + 1e-4) {
            if (entered && !inWater) { tw = t; wn = nIn; }
        } else if (rd.y < 0.0) {
            float tp = (hgt - o.y) * inv.y;
            if (tp < tExit) tw = tp;
        }
        if (fluid == 2u) {
            if (tw >= 0.0) {
                uint4 lava = mcwMat(W, 0u, 3u);   // w14, w15: lava still
                float3 P = o + rd * tw;
                float2 px = mcwCubeST(mcwFaceOf(wn), P) * 16.0;
                r.hit = true; r.t = tw; r.n = wn;
                r.color = float4(mcwFaceTexel(W, lava.z, lava.w, px, tw * W.pxA, xz, 0u).rgb, 1.0);
                r.flags = MCW_HIT_LAVA | MCW_HIT_EMISSIVE | (15u << 8);
                return r;
            }
        } else {
            r.inWater = tw >= 0.0 || inWater;
            if (tw >= 0.0) { r.water = true; r.waterT = tw; r.waterFace = mcwFaceOf(wn); }
        }
    }

    uint kind = w0 & MCW_KIND_MASK;
    if (kind == 0u) return r;
    r.inWater = r.inWater && ((w3 >> 7) & 1u) != 0u;
    r = mcwGeometry(W, r, mid, m0, c, nIn, o, rd, inv, t, tExit, fp, xz, prevGroup, texture);
    // A waterlogged block's faces in front of its water's surface, or on the
    // cell's boundary where the water's side would be, show dry.
    if (r.water && r.hit && r.t <= r.waterT + 1e-4) { r.water = false; r.waterT = -1.0; }
    return r;
}


"""#
}
