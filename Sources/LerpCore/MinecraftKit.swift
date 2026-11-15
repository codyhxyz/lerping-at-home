import Foundation

/// The shared Minecraft kit beyond textures: MSL spliced into the prelude of
/// every look that says `// lerp-requires: minecraft`, after the sampling
/// helpers in `MinecraftAssets.swift`. One copy for every look, so a lantern
/// is the same lantern everywhere.
extension LerpMinecraft {
    /// Small block models: lantern, torch, cross plants, crops, beacon.
    static let models = #"""

// ---- Small block models -----------------------------------------------------
// Ray intersection and texturing for the game's small block models: lanterns
// (standing, hanging; soul lanterns by layer), torches (standing, on a wall;
// soul and copper torches by layer), cross plants (short grass, flowers,
// saplings, ferns), crops (wheat, carrots, potatoes, beetroots by stage) and
// the beacon. Dimensions and UV rectangles follow the game's block models, in
// sixteenths of a block, checked against the texture PNGs.
//
// Every function takes the block's origin (its minimum corner, in blocks), the
// ray, the range (tMin, tMax) to accept a hit in — from a march, pass the
// cell's entry distance less a hair (1e-4), since a model face can lie on the
// cell's boundary and tMin is exclusive — and `pxA`, the width of a
// screen pixel in radians (the footprint at distance t is t * pxA). It does a
// bounding test first, so it is cheap to call from a march whenever a ray
// enters a cell that holds the model. On a hit it fills McModelHit with the
// nearest opaque surface — cut-out texels (alpha < 0.5) are passed through to
// whatever of the model lies behind — and returns true.
//
// Light is the caller's: multiply `color.rgb` by the lightmap (lanterns,
// torches and the beacon give light 15, so mcLightmap(15, sky, day, 0)), and by
// mcFaceShade(n) when `shade` is 1. Torches and plants are drawn unshaded.
// Depends only on the prelude's mcCrisp and mcRepeat.

struct McModelHit {
    float  t;       // distance along rd
    float3 n;       // the face's normal, towards the ray
    float4 color;   // the texel, straight alpha (>= 0.5 on a hit), tint applied
    float  shade;   // 1: apply mcFaceShade(n); 0: the game draws it unshaded
    float2 px;      // where on the texture, in pixels: for an overlay or an
                    // emissive layer laid on the same face (mcModelTexel)
    float4 rect;    // and the UV rectangle that face uses
};

// A texel inside a model's UV rectangle: `px` in texture pixels, kept inside
// the rectangle [r.xy, r.zw] (either order) so edges do not bleed.
static inline float4 mcModelTexel(texture2d_array<float> tiles, int layer, float2 px, float4 r,
                                  float footprint) {
    float w = footprint * 16.0;
    float2 lo = min(r.xy, r.zw), hi = max(r.xy, r.zw);
    float2 p = clamp(mcCrisp(px, w), lo + 0.5, hi - 0.5);
    return tiles.sample(mcRepeat, p / 16.0, layer, level(log2(max(w, 1.0))));
}

static inline float3 mcModelInv(float3 rd) {
    return 1.0 / select(rd, float3(1e-7), abs(rd) < 1e-7);
}

// Entry into the box [lo, hi] (pixels, model space) within (tMin, tMax).
static inline bool mcModelBox(float3 o, float3 inv, float3 lo, float3 hi, float tMin, float tMax,
                              thread float& t, thread float3& n) {
    float3 t1 = (lo - o) * inv, t2 = (hi - o) * inv;
    float3 tn = min(t1, t2), tf = max(t1, t2);
    float a = max(max(tn.x, tn.y), tn.z), z = min(min(tf.x, tf.y), tf.z);
    if (a > z || a <= tMin || a >= tMax) return false;
    t = a;
    n = a == tn.x ? float3(-sign(inv.x), 0.0, 0.0)
      : (a == tn.y ? float3(0.0, -sign(inv.y), 0.0) : float3(0.0, 0.0, -sign(inv.z)));
    return true;
}

// Whether the ray meets the box at all before tMax (a bounding test).
static inline bool mcModelBounds(float3 o, float3 inv, float3 lo, float3 hi, float tMin, float tMax) {
    float3 t1 = (lo - o) * inv, t2 = (hi - o) * inv;
    float3 tn = min(t1, t2), tf = max(t1, t2);
    float a = max(max(tn.x, tn.y), tn.z), z = min(min(tf.x, tf.y), tf.z);
    return a <= z && z > tMin && a < tMax;
}

// The texture pixel at point p (pixels) on face n of box [lo, hi], as the
// game maps an element's faces: `side` for north/south/east/west, `up` and
// `down` for the top and bottom, each [u0, v0, u1, v1] in texture pixels.
static inline float2 mcModelFaceUV(float3 p, float3 lo, float3 hi, float3 n,
                                   float4 side, float4 up, float4 down) {
    float3 s = hi - lo;
    float2 f; float4 r;
    if (n.y > 0.5)       { f = float2((p.x - lo.x) / s.x, (p.z - lo.z) / s.z); r = up; }
    else if (n.y < -0.5) { f = float2((p.x - lo.x) / s.x, (hi.z - p.z) / s.z); r = down; }
    else {
        float v = (hi.y - p.y) / s.y;
        if (n.z < -0.5)      f = float2((hi.x - p.x) / s.x, v);   // north
        else if (n.z > 0.5)  f = float2((p.x - lo.x) / s.x, v);   // south
        else if (n.x < -0.5) f = float2((p.z - lo.z) / s.z, v);   // west
        else                 f = float2((hi.z - p.z) / s.z, v);   // east
        r = side;
    }
    return mix(r.xy, r.zw, saturate(f));
}

// A vertical quad through c (pixels), running along the horizontal unit
// vector a for ±hw and from y0 to y1, seen from either side. f is 0..1 along
// it and from its top down.
static inline bool mcModelQuad(float3 o, float3 rd, float3 c, float2 a, float hw, float y0, float y1,
                               float tMin, float tMax, thread float& t, thread float2& f,
                               thread float3& n) {
    float3 nz = float3(-a.y, 0.0, a.x);
    float dn = dot(rd, nz);
    if (abs(dn) < 1e-6) return false;
    t = dot(c - o, nz) / dn;
    if (t <= tMin || t >= tMax) return false;
    float3 q = o + rd * t - c;
    float s = dot(q.xz, a);
    float y = q.y + c.y;
    if (abs(s) > hw || y < y0 || y > y1) return false;
    f = float2((s + hw) / (2.0 * hw), (y1 - y) / (y1 - y0));
    n = dn > 0.0 ? -nz : nz;
    return true;
}

// Model space is pixels from the block's origin: o = (ro - origin) * 16, and
// t stays in the caller's units because rd is not rescaled (t_px = 16 t).

// A box element: tests, maps and samples it, and keeps it if it is nearer
// than `hit` and opaque there.
static inline void mcModelBoxElem(texture2d_array<float> tiles, int layer, float3 o, float3 rd, float3 inv,
                                  float3 lo, float3 hi, float4 side, float4 up, float4 down,
                                  float tMin, float pxA, float shade, thread McModelHit& hit) {
    float t; float3 n;
    if (!mcModelBox(o, inv, lo, hi, tMin * 16.0, hit.t * 16.0, t, n)) return;
    float2 px = mcModelFaceUV(o + rd * t, lo, hi, n, side, up, down);
    float4 r = n.y > 0.5 ? up : (n.y < -0.5 ? down : side);
    float4 c = mcModelTexel(tiles, layer, px, r, t / 16.0 * pxA);
    if (c.a < 0.5) return;
    hit.t = t / 16.0; hit.n = n; hit.color = c; hit.shade = shade; hit.px = px; hit.rect = r;
}

static inline void mcModelQuadElem(texture2d_array<float> tiles, int layer, float3 o, float3 rd,
                                   float3 c, float2 a, float hw, float y0, float y1, float4 r,
                                   float tMin, float pxA, float shade, float3 tint,
                                   thread McModelHit& hit) {
    float t; float2 f; float3 n;
    if (!mcModelQuad(o, rd, c, a, hw, y0, y1, tMin * 16.0, hit.t * 16.0, t, f, n)) return;
    float2 px = mix(r.xy, r.zw, f);
    float4 col = mcModelTexel(tiles, layer, px, r, t / 16.0 * pxA);
    if (col.a < 0.5) return;
    hit.t = t / 16.0; hit.n = n; hit.color = float4(col.rgb * tint, col.a); hit.shade = shade;
    hit.px = px; hit.rect = r;
}

// --- Lantern, standing on a block or hanging from one. `layer` is the frame
// (mcFrame(MC_LANTERN, MC_LANTERN_FRAMES, MC_LANTERN_TICKS, time), or the soul
// lantern's). Body 6x7x6, cap 4x2x4, and a handle (standing) or chain
// (hanging) of two crossed quads turned 45°.
static inline bool mcLantern(texture2d_array<float> tiles, int layer, float3 origin, bool hanging,
                             float3 ro, float3 rd, float tMin, float tMax, float pxA,
                             thread McModelHit& hit) {
    float3 o = (ro - origin) * 16.0;
    float3 inv = mcModelInv(rd);
    if (!mcModelBounds(o, inv, float3(4.5, 0.0, 4.5), float3(11.5, 16.0, 11.5), tMin * 16.0, tMax * 16.0))
        return false;
    hit.t = tMax;
    float y = hanging ? 1.0 : 0.0;
    mcModelBoxElem(tiles, layer, o, rd, inv, float3(5.0, y, 5.0), float3(11.0, y + 7.0, 11.0),
                   float4(0, 2, 6, 9), float4(0, 9, 6, 15), float4(0, 9, 6, 15), tMin, pxA, 1.0, hit);
    mcModelBoxElem(tiles, layer, o, rd, inv, float3(6.0, y + 7.0, 6.0), float3(10.0, y + 9.0, 10.0),
                   float4(1, 0, 5, 2), float4(1, 10, 5, 14), float4(1, 10, 5, 14), tMin, pxA, 1.0, hit);
    const float2 d1 = float2(0.70710678, 0.70710678), d2 = float2(-0.70710678, 0.70710678);
    float3 c = float3(8.0, 0.0, 8.0);
    if (hanging) {
        mcModelQuadElem(tiles, layer, o, rd, c, d1, 1.5, 10.0, 14.0, float4(11, 1, 14, 5),
                        tMin, pxA, 1.0, float3(1.0), hit);
        mcModelQuadElem(tiles, layer, o, rd, c, d2, 1.5, 10.0, 16.0, float4(11, 6, 14, 12),
                        tMin, pxA, 1.0, float3(1.0), hit);
    } else {
        mcModelQuadElem(tiles, layer, o, rd, c, d1, 1.5, 9.0, 11.0, float4(11, 1, 14, 3),
                        tMin, pxA, 1.0, float3(1.0), hit);
        mcModelQuadElem(tiles, layer, o, rd, c, d2, 1.5, 9.0, 11.0, float4(11, 10, 14, 12),
                        tMin, pxA, 1.0, float3(1.0), hit);
    }
    return hit.t < tMax;
}

// --- Torch, standing: a 2x10x2 stick whose sides show the torch texture's
// middle columns (7..9, rows 6..16), its top rows 6..8 and bottom 13..15.
// Unshaded, as the game draws it. Soul, copper and redstone torches by layer.
static inline bool mcTorch(texture2d_array<float> tiles, int layer, float3 origin,
                           float3 ro, float3 rd, float tMin, float tMax, float pxA,
                           thread McModelHit& hit) {
    float3 o = (ro - origin) * 16.0;
    float3 inv = mcModelInv(rd);
    hit.t = tMax;
    mcModelBoxElem(tiles, layer, o, rd, inv, float3(7.0, 0.0, 7.0), float3(9.0, 10.0, 9.0),
                   float4(7, 6, 9, 16), float4(7, 6, 9, 8), float4(7, 13, 9, 15), tMin, pxA, 0.0, hit);
    return hit.t < tMax;
}

// --- Torch on a wall. `facing` is the way it leans out: 0 +x, 1 +z, 2 -x,
// 3 -z; the wall it hangs on is the neighbouring block the other way. The
// same stick, its foot 3.5 px up against the wall, tilted 22.5° out.
static inline bool mcWallTorch(texture2d_array<float> tiles, int layer, float3 origin, int facing,
                               float3 ro, float3 rd, float tMin, float tMax, float pxA,
                               thread McModelHit& hit) {
    // Into the model's frame: turn about the block's vertical axis so the
    // torch leans towards +x, then undo its tilt about z at (0, 3.5).
    float ang = -float(facing & 3) * 1.57079633;
    float cy = cos(ang), sy = sin(ang);
    float3 o = (ro - origin) * 16.0 - float3(8.0, 0.0, 8.0);
    o = float3(cy * o.x - sy * o.z, o.y, sy * o.x + cy * o.z) + float3(8.0, 0.0, 8.0);
    float3 d = float3(cy * rd.x - sy * rd.z, rd.y, sy * rd.x + cy * rd.z);
    const float tilt = 0.39269908;   // undo -22.5°
    float cz = cos(tilt), sz = sin(tilt);
    float2 q = o.xy - float2(0.0, 3.5);
    o.xy = float2(cz * q.x - sz * q.y, sz * q.x + cz * q.y) + float2(0.0, 3.5);
    d.xy = float2(cz * d.x - sz * d.y, sz * d.x + cz * d.y);
    hit.t = tMax;
    mcModelBoxElem(tiles, layer, o, d, mcModelInv(d), float3(-1.0, 3.5, 7.0), float3(1.0, 13.5, 9.0),
                   float4(7, 6, 9, 16), float4(7, 6, 9, 8), float4(7, 13, 9, 15), tMin, pxA, 0.0, hit);
    if (hit.t >= tMax) return false;
    // The normal back to world space: redo the tilt, then the turn.
    float3 n = hit.n;
    n.xy = float2(cz * n.x + sz * n.y, -sz * n.x + cz * n.y);
    hit.n = float3(cy * n.x + sy * n.z, n.y, -sy * n.x + cy * n.z);
    return true;
}

// --- Cross plants: two quads on the block's diagonals, the full texture on
// each (short grass, ferns, flowers, saplings, dead bushes...). `tint` is the
// biome tint for grass and ferns, 1 otherwise.
static inline bool mcCross(texture2d_array<float> tiles, int layer, float3 origin, float3 tint,
                           float3 ro, float3 rd, float tMin, float tMax, float pxA,
                           thread McModelHit& hit) {
    float3 o = (ro - origin) * 16.0;
    float3 inv = mcModelInv(rd);
    if (!mcModelBounds(o, inv, float3(0.0), float3(16.0), tMin * 16.0, tMax * 16.0)) return false;
    hit.t = tMax;
    const float h = 10.1823376;   // 7.2 * sqrt 2: the game's cross, 0.8 to 15.2 turned 45 degrees
    float3 c = float3(8.0, 0.0, 8.0);
    mcModelQuadElem(tiles, layer, o, rd, c, float2(0.70710678, 0.70710678), h, 0.0, 16.0,
                    float4(0, 0, 16, 16), tMin, pxA, 0.0, tint, hit);
    mcModelQuadElem(tiles, layer, o, rd, c, float2(0.70710678, -0.70710678), h, 0.0, 16.0,
                    float4(0, 0, 16, 16), tMin, pxA, 0.0, tint, hit);
    return hit.t < tMax;
}

// --- Crops: four quads 4 px in from each side, sunk 1 px into the farmland
// (wheat_stage0..7, carrots, potatoes, beetroots by layer).
static inline bool mcCrop(texture2d_array<float> tiles, int layer, float3 origin,
                          float3 ro, float3 rd, float tMin, float tMax, float pxA,
                          thread McModelHit& hit) {
    float3 o = (ro - origin) * 16.0;
    float3 inv = mcModelInv(rd);
    if (!mcModelBounds(o, inv, float3(0.0, -1.0, 0.0), float3(16.0, 15.0, 16.0), tMin * 16.0, tMax * 16.0))
        return false;
    hit.t = tMax;
    const float4 r = float4(0, 0, 16, 16);
    mcModelQuadElem(tiles, layer, o, rd, float3(4.0, 0.0, 8.0),  float2(0.0, 1.0), 8.0, -1.0, 15.0, r, tMin, pxA, 0.0, float3(1.0), hit);
    mcModelQuadElem(tiles, layer, o, rd, float3(12.0, 0.0, 8.0), float2(0.0, 1.0), 8.0, -1.0, 15.0, r, tMin, pxA, 0.0, float3(1.0), hit);
    mcModelQuadElem(tiles, layer, o, rd, float3(8.0, 0.0, 4.0),  float2(1.0, 0.0), 8.0, -1.0, 15.0, r, tMin, pxA, 0.0, float3(1.0), hit);
    mcModelQuadElem(tiles, layer, o, rd, float3(8.0, 0.0, 12.0), float2(1.0, 0.0), 8.0, -1.0, 15.0, r, tMin, pxA, 0.0, float3(1.0), hit);
    return hit.t < tMax;
}

// --- Beacon: a glass shell round an obsidian plinth (12x2.9x12, from 0.1 up)
// and the beacon core (10x11x10, from 3 up). Through the glass's clear texels
// the ray reaches the core; past both it leaves the block. Full bright: the
// beacon gives light 15.
static inline bool mcBeacon(texture2d_array<float> tiles, float3 origin,
                            float3 ro, float3 rd, float tMin, float tMax, float pxA,
                            thread McModelHit& hit) {
    float3 o = (ro - origin) * 16.0;
    float3 inv = mcModelInv(rd);
    hit.t = tMax;
    const float4 full = float4(0, 0, 16, 16);
    mcModelBoxElem(tiles, MC_GLASS, o, rd, inv, float3(0.0), float3(16.0), full, full, full,
                   tMin, pxA, 1.0, hit);
    if (hit.t < tMax) return true;
    if (!mcModelBounds(o, inv, float3(0.0), float3(16.0), tMin * 16.0, tMax * 16.0)) return false;
    mcModelBoxElem(tiles, MC_OBSIDIAN, o, rd, inv, float3(2.0, 0.1, 2.0), float3(14.0, 3.0, 14.0),
                   float4(2, 13, 14, 16), float4(2, 2, 14, 14), float4(2, 2, 14, 14), tMin, pxA, 1.0, hit);
    mcModelBoxElem(tiles, MC_BEACON, o, rd, inv, float3(3.0, 3.0, 3.0), float3(13.0, 14.0, 13.0),
                   float4(3, 3, 13, 14), float4(3, 3, 13, 13), float4(3, 3, 13, 13), tMin, pxA, 1.0, hit);
    return hit.t < tMax;
}
// ---- end of small block models ----------------------------------------------

"""#

    /// Sunset glow, slanted grass sides, facing crosses and face plates
    /// (amethyst, glow lichen, vines), the chest, fences, and small trees.
    static let extras = #"""


// ---- Kit extras --------------------------------------------------------------
// Appended after the sampling helpers (MinecraftAssets.swift) and the small
// block models (MinecraftKit.swift); uses mcTile, mcTileAniso, mcModelBox,
// mcModelQuadElem, mcModelTexel and McModelHit from them, and hash11 / hash21
// from the prelude.
//
//   Sunset and sunrise   mcSkyDay, mcLightDay, mcSunsetAt, mcSunsetFan, mcFogToward
//   Grass side, slanted  mcGrassSideAniso
//   Directions           MC_DIR_*, mcDirVec, mcBlockFaceUV
//   Facing models        mcCrossFacing (amethyst), mcFacePlate, mcGlowLichen, mcVine
//   Chest                mcChest, and mcModelCubeElem for any entity-texture box
//   Fence                mcFence (post, arms by neighbour), mcModelBoxWorldElem
//   Small trees          McTree, mcTreeGrow, mcTreeVox, mcTree, mcTreeShade, mcTreeLeafTint

// --- Sunset and sunrise ------------------------------------------------------
// Everything here is driven by the sun's height: sunY is the y of the unit
// vector toward the sun, the sine of its elevation, which is what the game's
// cos(2 pi timeOfDay) is. Noon 1, sunset and sunrise 0, midnight -1.

// The `day` that mcSkyAt and mcFogAt take (the game's sky brightness) ...
static inline float mcSkyDay(float sunY)   { return saturate(sunY * 2.0 + 0.5); }
// ... and the `day` that mcLightmap takes (the game's sky darkening). They
// are different curves of the same angle: the lightmap dims sooner.
static inline float mcLightDay(float sunY) { return saturate(sunY * 2.0 + 0.2); }

// The sunrise and sunset glow: its colour (rgb, Display P3) and strength (a)
// for a sun at height sunY. Zero while the sun is more than 0.4 above or
// below the horizon (about 23.6 degrees); strongest with the sun on it.
static inline float4 mcSunsetAt(float sunY) {
    if (abs(sunY) > 0.4) return float4(0.0);
    float f = sunY / 0.4 * 0.5 + 0.5;
    float a = 1.0 - (1.0 - sin(f * M_PI_F)) * 0.99;
    return float4(mcFromSRGB(float3(f * 0.3 + 0.7, f * f * 0.7 + 0.2, 0.2)), a * a);
}

// How much of the glow the sky shows along rd: the game draws it as a fan of
// triangles from the horizon 100 blocks out under the sun to a ring 120
// round, the ring raised 40 x strength on the sun's side (so the glow climbs
// about 15 degrees there) and lowered as much behind; the colour fades from
// the centre to nothing at the ring. Mix it over the sky, under the sun:
//   sky = mix(sky, glow.rgb, mcSunsetFan(rd, sun, glow));
// `sun` is the direction to the sun (any length); only its heading is used.
static inline float mcSunsetFan(float3 rd, float3 sun, float4 glow) {
    if (glow.a <= 0.0) return 0.0;
    float2 S = normalize(sun.xz + float2(1e-6, 0.0));
    float along = dot(rd.xz, S);
    float across = rd.x * S.y - rd.z * S.x;
    float beta = max(40.0 * glow.a / 120.0, 1e-4);
    float q = length(float2(across, rd.y / beta));
    float den = along - rd.y / beta + (100.0 / 120.0) * q;
    if (den <= 0.0) return 0.0;
    return glow.a * saturate(1.0 - (100.0 / 120.0) * q / den);
}

// The fog colour warmed toward the sun as the game warms it: by how far
// `look` points toward the sun's side, times the glow's strength. The game
// uses the camera's look direction, so the whole view gets one fog colour;
// pass the camera's forward for that, or rd for a fog that warms only on the
// sun's side of the screen. Feed the result to the horizon and to distance fog.
static inline float3 mcFogToward(float3 fog, float4 glow, float3 look, float3 sun) {
    float2 S = normalize(sun.xz + float2(1e-6, 0.0));
    return mix(fog, glow.rgb, max(dot(look.xz, S), 0.0) * glow.a);
}

// --- The side of a grass block seen at a slant -------------------------------
// mcGrassSide with the uv change across one screen pixel in x and in y, as
// mcTileAniso takes them, for hill sides and banks seen edge-on.
static inline float3 mcGrassSideAniso(texture2d_array<float> tiles, float2 uv, float2 duvdx, float2 duvdy,
                                      float3 tint) {
    float3 base = mcTileAniso(tiles, MC_GRASS_BLOCK_SIDE, uv, duvdx, duvdy).rgb;
    float4 fringe = mcTileAniso(tiles, MC_GRASS_BLOCK_SIDE_OVERLAY, uv, duvdx, duvdy);
    return mix(base, fringe.rgb * tint, fringe.a);
}

// --- Directions ----------------------------------------------------------------
// The six directions, numbered as the game numbers them. North is -z, south
// +z, west -x, east +x. A set of them is a mask of (1 << MC_DIR_*).
constant int MC_DIR_DOWN = 0, MC_DIR_UP = 1, MC_DIR_NORTH = 2, MC_DIR_SOUTH = 3,
             MC_DIR_WEST = 4, MC_DIR_EAST = 5;

static inline float3 mcDirVec(int dir) {
    switch (dir) {
        case 0:  return float3(0.0, -1.0, 0.0);
        case 1:  return float3(0.0, 1.0, 0.0);
        case 2:  return float3(0.0, 0.0, -1.0);
        case 3:  return float3(0.0, 0.0, 1.0);
        case 4:  return float3(-1.0, 0.0, 0.0);
        default: return float3(1.0, 0.0, 0.0);
    }
}

// Where on a full block's face the point f (0..1 in the block) is, in the
// picture's orientation (uv.y = 0 the top row), as the game maps a cube's
// faces: the sides upright and read from outside, the top with north up.
// n is the face's outward normal.
static inline float2 mcBlockFaceUV(float3 f, float3 n) {
    if (n.y > 0.5)  return float2(f.x, f.z);
    if (n.y < -0.5) return float2(f.x, 1.0 - f.z);
    if (n.z < -0.5) return float2(1.0 - f.x, 1.0 - f.y);   // north
    if (n.z > 0.5)  return float2(f.x, 1.0 - f.y);         // south
    if (n.x < -0.5) return float2(f.z, 1.0 - f.y);         // west
    return float2(1.0 - f.z, 1.0 - f.y);                   // east
}

// --- Cross models facing any way: amethyst clusters and buds ------------------
// The cross (two quads on the diagonals, 14.4 px of the block's 16 each way
// after the game's 45-degree rescale), turned as the game's blockstate turns
// it so that its top points `dir`: MC_DIR_UP stands on a floor, MC_DIR_DOWN
// hangs from a ceiling, the four sides grow out of a wall (the wall is the
// neighbouring block the other way). Pass the cluster or bud's layer
// (MC_AMETHYST_CLUSTER, MC_LARGE_ / MC_MEDIUM_ / MC_SMALL_AMETHYST_BUD).
// Unshaded, as the game draws a cross; amethyst clusters give light 5,
// large buds 4, medium 2, small 1.
static inline bool mcCrossFacing(texture2d_array<float> tiles, int layer, float3 origin, int dir, float3 tint,
                                 float3 ro, float3 rd, float tMin, float tMax, float pxA,
                                 thread McModelHit& hit) {
    // The model's x, up and z in the world.
    float3 F = mcDirVec(dir), A, B;
    if (dir == MC_DIR_UP)        { A = float3(1.0, 0.0, 0.0); B = float3(0.0, 0.0, 1.0); }
    else if (dir == MC_DIR_DOWN) { A = float3(1.0, 0.0, 0.0); B = float3(0.0, 0.0, -1.0); }
    else                         { B = float3(0.0, 1.0, 0.0); A = cross(F, B); }
    float3 w = (ro - origin) * 16.0 - 8.0;
    float3 o = float3(dot(w, A), dot(w, F), dot(w, B)) + 8.0;
    float3 d = float3(dot(rd, A), dot(rd, F), dot(rd, B));
    float3 inv = mcModelInv(d);
    if (!mcModelBounds(o, inv, float3(0.0), float3(16.0), tMin * 16.0, tMax * 16.0)) return false;
    hit.t = tMax;
    const float h = 10.1823376;   // 7.2 * sqrt 2
    float3 c = float3(8.0, 0.0, 8.0);
    mcModelQuadElem(tiles, layer, o, d, c, float2(0.70710678, 0.70710678), h, 0.0, 16.0,
                    float4(0, 0, 16, 16), tMin, pxA, 0.0, tint, hit);
    mcModelQuadElem(tiles, layer, o, d, c, float2(0.70710678, -0.70710678), h, 0.0, 16.0,
                    float4(0, 0, 16, 16), tMin, pxA, 0.0, tint, hit);
    if (hit.t >= tMax) return false;
    hit.n = hit.n.x * A + hit.n.y * F + hit.n.z * B;
    return true;
}

// --- Face plates: glow lichen, vines ------------------------------------------
// A full-face picture lying `inset` pixels off side `dir` of the block (the
// neighbour it clings to is that way: MC_DIR_NORTH is on the north wall,
// MC_DIR_UP on the ceiling, MC_DIR_DOWN on the floor). Seen from the open
// side the picture reads the right way round, upright on a wall, as the
// game's uv-locked models show it. `shade` 1 takes mcFaceShade, 0 not.
static inline bool mcFacePlate(texture2d_array<float> tiles, int layer, float3 origin, int dir, float inset,
                               float3 tint, float shade, float3 ro, float3 rd, float tMin, float tMax,
                               float pxA, thread McModelHit& hit) {
    float3 o = (ro - origin) * 16.0;
    int k = dir < 2 ? 1 : (dir < 4 ? 2 : 0);
    float dk = rd[k];
    if (abs(dk) < 1e-7) return false;
    float plane = (dir & 1) != 0 ? 16.0 - inset : inset;
    float t = (plane - o[k]) / dk;
    if (t <= tMin * 16.0 || t >= tMax * 16.0) return false;
    float3 p = o + rd * t;
    if (any(p < 0.0) || any(p > 16.0)) return false;
    float2 px;
    switch (dir) {
        case 2:  px = float2(p.x, 16.0 - p.y); break;          // north wall
        case 3:  px = float2(16.0 - p.x, 16.0 - p.y); break;   // south wall
        case 4:  px = float2(16.0 - p.z, 16.0 - p.y); break;   // west wall
        case 5:  px = float2(p.z, 16.0 - p.y); break;          // east wall
        case 1:  px = float2(p.x, 16.0 - p.z); break;          // ceiling
        default: px = float2(p.x, p.z); break;                 // floor
    }
    const float4 r = float4(0, 0, 16, 16);
    float4 c = mcModelTexel(tiles, layer, px, r, t / 16.0 * pxA);
    if (c.a < 0.5) return false;
    float3 n = float3(0.0);
    n[k] = dk > 0.0 ? -1.0 : 1.0;
    hit.t = t / 16.0; hit.n = n; hit.color = float4(c.rgb * tint, c.a); hit.shade = shade;
    hit.px = px; hit.rect = r;
    return true;
}

// Glow lichen on the faces of the block in `faces` (a mask of 1 << MC_DIR_*),
// 0.1 px off each. Face-shaded; it gives light 7.
static inline bool mcGlowLichen(texture2d_array<float> tiles, float3 origin, int faces,
                                float3 ro, float3 rd, float tMin, float tMax, float pxA,
                                thread McModelHit& hit) {
    bool got = false;
    for (int d = 0; d < 6; ++d) {
        if ((faces & (1 << d)) == 0) continue;
        if (mcFacePlate(tiles, MC_GLOW_LICHEN, origin, d, 0.1, float3(1.0), 1.0, ro, rd, tMin,
                        got ? hit.t : tMax, pxA, hit)) got = true;
    }
    return got;
}

// Vines on the walls and ceiling in `faces` (not the floor: vines never lie
// there), 0.8 px off each, in the biome's foliage `tint`. Unshaded.
static inline bool mcVine(texture2d_array<float> tiles, float3 origin, int faces, float3 tint,
                          float3 ro, float3 rd, float tMin, float tMax, float pxA,
                          thread McModelHit& hit) {
    bool got = false;
    for (int d = 1; d < 6; ++d) {
        if ((faces & (1 << d)) == 0) continue;
        if (mcFacePlate(tiles, MC_VINE, origin, d, 0.8, tint, 0.0, ro, rd, tMin,
                        got ? hit.t : tMax, pxA, hit)) got = true;
    }
    return got;
}

// --- Entity-texture boxes, and the chest ---------------------------------------
// One box of an entity model as the game maps its texture onto it
// (ModelPart's cube unwrap): `uv` is the box's texture offset in pixels and
// [lo, hi] the box, model pixels, y up, as block entities are built. Samples
// `skins` (an MCS_* layer), keeps the texel inside the face's rectangle, and
// keeps the face if it is nearer than `hit` and opaque there. In the PNG each
// side strip reads upside down and right-to-left: the game's model space runs
// y down, and a block entity is drawn with y up.
static inline void mcModelCubeElem(texture2d_array<float> skins, int layer, float3 o, float3 rd, float3 inv,
                                   float3 lo, float3 hi, float2 uv, float tMin, float pxA,
                                   thread McModelHit& hit) {
    float t; float3 n;
    if (!mcModelBox(o, inv, lo, hi, tMin * 16.0, hit.t * 16.0, t, n)) return;
    float3 s = hi - lo;
    float3 p = clamp(o + rd * t - lo, 0.0, s);
    float w = s.x, h = s.y, d = s.z;
    float4 r; float2 px;
    if (n.y < -0.5)      { r = float4(uv.x + d, uv.y, uv.x + d + w, uv.y + d);                 px = float2(p.x, d - p.z); }
    else if (n.y > 0.5)  { r = float4(uv.x + d + w, uv.y, uv.x + d + 2.0 * w, uv.y + d);       px = float2(p.x, d - p.z); }
    else if (n.x < -0.5) { r = float4(uv.x, uv.y + d, uv.x + d, uv.y + d + h);                 px = float2(d - p.z, p.y); }
    else if (n.z < -0.5) { r = float4(uv.x + d, uv.y + d, uv.x + d + w, uv.y + d + h);         px = float2(p.x, p.y); }
    else if (n.x > 0.5)  { r = float4(uv.x + d + w, uv.y + d, uv.x + 2.0 * d + w, uv.y + d + h); px = float2(p.z, p.y); }
    else                 { r = float4(uv.x + 2.0 * d + w, uv.y + d, uv.x + 2.0 * (d + w), uv.y + d + h); px = float2(w - p.x, p.y); }
    px += r.xy;
    float fw = t / 16.0 * pxA * 16.0;
    float2 q = clamp(mcCrisp(px, fw), r.xy + 0.5, r.zw - 0.5);
    float4 c = skins.sample(mcClamp, q / MC_SKIN, layer, level(log2(max(fw, 1.0))));
    if (c.a < 0.5) return;
    hit.t = t / 16.0; hit.n = n; hit.color = c; hit.shade = 1.0; hit.px = px; hit.rect = r;
}

// A chest: the game's 14x10x14 base, 14x5x14 lid and 2x4x1 latch (14 px
// tall in all, a pixel in from each side), from an entity/chest texture
// (MCS_CHEST_NORMAL, _TRAPPED, _ENDER, _CHRISTMAS, the copper ones).
// `facing` is the way the latch faces, one of the four sides MC_DIR_*. The
// game lights it as an entity; shade 1 (mcFaceShade) is close.
static inline bool mcChest(texture2d_array<float> skins, int layer, float3 origin, int facing,
                           float3 ro, float3 rd, float tMin, float tMax, float pxA,
                           thread McModelHit& hit) {
    float3 Z = mcDirVec(facing);         // the model's front (+z) in the world
    float3 X = float3(Z.z, 0.0, -Z.x);
    float3 w = (ro - origin) * 16.0 - float3(8.0, 0.0, 8.0);
    float3 o = float3(dot(w, X), w.y, dot(w, Z)) + float3(8.0, 0.0, 8.0);
    float3 d = float3(dot(rd, X), rd.y, dot(rd, Z));
    float3 inv = mcModelInv(d);
    if (!mcModelBounds(o, inv, float3(1.0, 0.0, 1.0), float3(15.0, 14.0, 16.0), tMin * 16.0, tMax * 16.0))
        return false;
    hit.t = tMax;
    mcModelCubeElem(skins, layer, o, d, inv, float3(1.0, 0.0, 1.0), float3(15.0, 10.0, 15.0), float2(0.0, 19.0),
                    tMin, pxA, hit);   // base
    mcModelCubeElem(skins, layer, o, d, inv, float3(1.0, 9.0, 1.0), float3(15.0, 14.0, 15.0), float2(0.0, 0.0),
                    tMin, pxA, hit);   // lid
    mcModelCubeElem(skins, layer, o, d, inv, float3(7.0, 7.0, 15.0), float3(9.0, 11.0, 16.0), float2(0.0, 0.0),
                    tMin, pxA, hit);   // latch
    if (hit.t >= tMax) return false;
    hit.n = hit.n.x * X + float3(0.0, hit.n.y, 0.0) + hit.n.z * Z;
    return true;
}

// --- Fences ----------------------------------------------------------------------
// A box whose faces show the texture locked to the block grid, as the game
// draws a uv-locked model: each face samples the part of the full-block
// face it covers (mcBlockFaceUV). For planks this is how fences, and any
// cut-down piece of a full block, look.
static inline void mcModelBoxWorldElem(texture2d_array<float> tiles, int layer, float3 o, float3 rd, float3 inv,
                                       float3 lo, float3 hi, float tMin, float pxA, thread McModelHit& hit) {
    float t; float3 n;
    if (!mcModelBox(o, inv, lo, hi, tMin * 16.0, hit.t * 16.0, t, n)) return;
    float2 px = mcBlockFaceUV(clamp(o + rd * t, lo, hi) / 16.0, n) * 16.0;
    float4 r = float4(mcBlockFaceUV(lo / 16.0, n), mcBlockFaceUV(hi / 16.0, n)) * 16.0;
    float4 c = mcModelTexel(tiles, layer, px, r, t / 16.0 * pxA);
    if (c.a < 0.5) return;
    hit.t = t / 16.0; hit.n = n; hit.color = c; hit.shade = 1.0; hit.px = px; hit.rect = r;
}

// A fence: the 4x16x4 post, and two bars (y 6..9 and 12..15, 2 px thick)
// toward each neighbour in `arms`, a mask of (1 << MC_DIR_NORTH) and the
// other sides; 0 is the lone post a lantern stands on in a lamp post
// (mcLantern at origin + (0, 1, 0)). `layer` is the wood's planks
// (MC_OAK_PLANKS, MC_SPRUCE_PLANKS, ..., MC_NETHER_BRICKS for the nether brick
// fence; bamboo's fence has its own model and is not this).
static inline bool mcFence(texture2d_array<float> tiles, int layer, float3 origin, int arms,
                           float3 ro, float3 rd, float tMin, float tMax, float pxA,
                           thread McModelHit& hit) {
    float3 o = (ro - origin) * 16.0;
    float3 inv = mcModelInv(rd);
    bool n = (arms & (1 << MC_DIR_NORTH)) != 0, s = (arms & (1 << MC_DIR_SOUTH)) != 0;
    bool wv = (arms & (1 << MC_DIR_WEST)) != 0, e = (arms & (1 << MC_DIR_EAST)) != 0;
    float3 blo = float3(wv ? 0.0 : 6.0, 0.0, n ? 0.0 : 6.0);
    float3 bhi = float3(e ? 16.0 : 10.0, 16.0, s ? 16.0 : 10.0);
    if (!mcModelBounds(o, inv, blo, bhi, tMin * 16.0, tMax * 16.0)) return false;
    hit.t = tMax;
    mcModelBoxWorldElem(tiles, layer, o, rd, inv, float3(6.0, 0.0, 6.0), float3(10.0, 16.0, 10.0), tMin, pxA, hit);
    for (int k = 0; k < 2; ++k) {
        float y0 = k == 0 ? 12.0 : 6.0, y1 = y0 + 3.0;
        if (n)  mcModelBoxWorldElem(tiles, layer, o, rd, inv, float3(7.0, y0, 0.0), float3(9.0, y1, 9.0), tMin, pxA, hit);
        if (s)  mcModelBoxWorldElem(tiles, layer, o, rd, inv, float3(7.0, y0, 7.0), float3(9.0, y1, 16.0), tMin, pxA, hit);
        if (wv) mcModelBoxWorldElem(tiles, layer, o, rd, inv, float3(0.0, y0, 7.0), float3(9.0, y1, 9.0), tMin, pxA, hit);
        if (e)  mcModelBoxWorldElem(tiles, layer, o, rd, inv, float3(7.0, y0, 7.0), float3(16.0, y1, 9.0), tMin, pxA, hit);
    }
    return hit.t < tMax;
}

// --- Small trees ---------------------------------------------------------------
// The game's small oak, birch and spruce, block by block, as its tree
// features grow them. The look decides where trees stand (one per region of
// its own lattice, say) and, when a ray enters a tree's bounds, calls
// mcTree to walk it; mcTreeShade darkens the ground under it.
//
//   oak    trunk 4..6 logs; leaves in four layers from the trunk's top down:
//          the block above the top log and the top log's layer 3x3, the two
//          below 5x5; corners kept at even odds, never on the top layer.
//   birch  the same crown on a trunk of 5..7.
//   spruce trunk 5..8; a cone of rows from 0..2 above the top log down to
//          4..7 below it, the radius climbing 0,1 / 0,1,2 / 1,2,3 ... to 2 or
//          3 down the tree, corners always off.

constant int MC_TREE_OAK = 0, MC_TREE_BIRCH = 1, MC_TREE_SPRUCE = 2;
constant int MC_TREE_STEPS = 26;   // the most blocks a ray crosses in a tree's bounds

struct McTree {
    float3 origin;   // the minimum corner of the trunk's bottom log, in blocks
    int    kind;     // MC_TREE_*
    int    h;        // logs in the trunk
    int    top;      // leaves reach up to y = h + top above the foot
    int    rows;     // leaf rows, counted down from there
    uint   radii;    // each row's radius, 2 bits a row from the top
    int    reach;    // the widest row's radius
    float  salt;     // which corners are kept
};

// A tree of `kind` standing on origin, grown from `seed` (any float; the
// same seed grows the same tree) with the game's odds for every choice.
static inline McTree mcTreeGrow(int kind, float3 origin, float seed) {
    McTree t;
    t.origin = origin;
    t.kind = kind;
    t.salt = hash11(seed * 1.731 + 0.37) * 61.0;
    float r1 = hash11(seed * 3.117 + 1.3), r2 = hash11(seed * 5.471 + 2.9);
    if (kind != MC_TREE_SPRUCE) {
        t.h = (kind == MC_TREE_OAK ? 4 : 5) + int(r1 * 2.999);
        t.top = 0; t.rows = 4; t.reach = 2;
        t.radii = 1u | (1u << 2) | (2u << 4) | (2u << 6);
        return t;
    }
    float r3 = hash11(seed * 7.913 + 4.1), r4 = hash11(seed * 9.337 + 5.3);
    float r5 = hash11(seed * 11.71 + 6.7), r6 = hash11(seed * 13.19 + 7.9);
    t.h = 5 + int(r1 * 2.999) + int(r2 * 1.999);
    int R = 2 + int(r3 * 1.999);
    t.top = int(r4 * 2.999);
    int fh = max(4, t.h - (1 + int(r5 * 1.999)));
    t.rows = t.top + fh + 1;
    t.reach = R;
    t.radii = 0u;
    int i = int(r6 * 1.999), j = 1, k = 0;
    for (int row = 0; row < t.rows; ++row) {
        t.radii |= uint(i) << (2 * row);
        if (i >= j) { i = k; k = 1; j = min(j + 1, R); }
        else ++i;
    }
    return t;
}

// What is at d (blocks from the foot log): 0 air, 1 log, 2 leaves.
static inline int mcTreeVox(McTree tr, int3 d) {
    if (d.y < 0) return 0;
    if (d.x == 0 && d.z == 0 && d.y < tr.h) return 1;
    int row = tr.h + tr.top - d.y;
    if (row < 0 || row >= tr.rows) return 0;
    int r = int((tr.radii >> uint(2 * row)) & 3u);
    int ax = abs(d.x), az = abs(d.z);
    if (max(ax, az) > r) return 0;
    if (r > 0 && ax == r && az == r) {
        if (tr.kind == MC_TREE_SPRUCE || row == 0) return 0;
        if (hash21(float2(float(d.x * 3 + d.y * 17), float(d.z * 5 - d.y * 7)) + tr.salt) < 0.5) return 0;
    }
    return 2;
}

// The leaves' tint: oak's is the biome's foliage colour (mcFoliageTint);
// birch and spruce leaves take fixed colours whatever the biome.
static inline float3 mcTreeLeafTint(int kind, float3 foliage) {
    if (kind == MC_TREE_BIRCH)  return mcFromSRGB(float3(0x80, 0xA7, 0x55) / 255.0);
    if (kind == MC_TREE_SPRUCE) return mcFromSRGB(float3(0x61, 0x99, 0x61) / 255.0);
    return foliage;
}

// The tree's bounds, in blocks.
static inline void mcTreeBounds(McTree tr, thread float3& lo, thread float3& hi) {
    float r = float(tr.reach);
    lo = tr.origin - float3(r, 0.0, r);
    hi = tr.origin + float3(r + 1.0, float(tr.h + tr.top + 1), r + 1.0);
}

// The first face of the tree the ray stops at, within (tMin, tMax); a ray
// that starts inside the bounds should start on a block boundary, as a
// march's cell entry is. Leaves are
// the game's fancy leaves: every leaf block's faces, the inner ones too, cut
// out by the texture's alpha, so the ray goes on through the gaps and may
// pass a few leaf blocks before one stops it; `passed` counts them (the game
// takes a sky-light level for each: `sky -= min(passed, 3.0)` is close).
// Returns 0 on a miss, 1 on a log, 2 on leaves (which carry `leafTint`,
// mcTreeLeafTint). Logs and leaves take mcFaceShade (hit.shade is 1).
static inline int mcTree(texture2d_array<float> tiles, McTree tr, float3 leafTint,
                         float3 ro, float3 rd, float tMin, float tMax, float pxA,
                         thread McModelHit& hit, thread float& passed) {
    passed = 0.0;
    float3 lo, hi;
    mcTreeBounds(tr, lo, hi);
    float3 inv = mcModelInv(rd);
    float3 t1 = (lo - ro) * inv, t2 = (hi - ro) * inv;
    float3 mn = min(t1, t2), mx = max(t1, t2);
    float tn = max(max(mn.x, mn.y), mn.z), tf = min(min(mx.x, mx.y), mx.z);
    if (tn > tf || tf <= tMin || tn >= tMax) return 0;
    int3 st = int3(rd.x > 0.0 ? 1 : -1, rd.y > 0.0 ? 1 : -1, rd.z > 0.0 ? 1 : -1);
    float3 nIn = mn.x >= mn.y && mn.x >= mn.z ? float3(-float(st.x), 0.0, 0.0)
               : (mn.y >= mn.z ? float3(0.0, -float(st.y), 0.0) : float3(0.0, 0.0, -float(st.z)));
    float t = max(tn, tMin);
    if (t > tn) {
        // Starting inside the bounds (a march's cell entry): the face entered
        // is the block boundary nearest the start.
        float3 f = ro + rd * t - tr.origin;
        float3 e = abs(f - round(f));
        nIn = e.x <= e.y && e.x <= e.z ? float3(-float(st.x), 0.0, 0.0)
            : (e.y <= e.z ? float3(0.0, -float(st.y), 0.0) : float3(0.0, 0.0, -float(st.z)));
    }
    int3 v = int3(floor(ro + rd * (t + 1e-4) - tr.origin));
    float3 tM = (tr.origin + float3(v) + select(float3(0.0), float3(1.0), st > 0) - ro) * inv;
    float3 tD = abs(inv);
    int logL = tr.kind == MC_TREE_BIRCH ? MC_BIRCH_LOG : (tr.kind == MC_TREE_SPRUCE ? MC_SPRUCE_LOG : MC_OAK_LOG);
    int topL = tr.kind == MC_TREE_BIRCH ? MC_BIRCH_LOG_TOP : (tr.kind == MC_TREE_SPRUCE ? MC_SPRUCE_LOG_TOP : MC_OAK_LOG_TOP);
    int leafL = tr.kind == MC_TREE_BIRCH ? MC_BIRCH_LEAVES : (tr.kind == MC_TREE_SPRUCE ? MC_SPRUCE_LEAVES : MC_OAK_LEAVES);
    float tEnd = min(tMax, tf);
    for (int i = 0; i < MC_TREE_STEPS; ++i) {
        if (t >= tEnd) break;
        int cls = mcTreeVox(tr, v);
        if (cls != 0) {
            float3 P = ro + rd * t;
            float2 uv = mcBlockFaceUV(saturate(P - tr.origin - float3(v)), nIn);
            float fw = t * pxA / max(abs(dot(rd, nIn)), 0.1);
            float4 c = mcTile(tiles, cls == 1 ? (nIn.y != 0.0 ? topL : logL) : leafL, uv, fw);
            if (cls == 1 || c.a > 0.5) {
                hit.t = t; hit.n = nIn; hit.shade = 1.0;
                hit.color = float4(c.rgb * (cls == 2 ? leafTint : float3(1.0)), 1.0);
                hit.px = uv * 16.0; hit.rect = float4(0, 0, 16, 16);
                return cls;
            }
            passed += 1.0;
        }
        if (tM.x < tM.y && tM.x < tM.z)  { t = tM.x; tM.x += tD.x; v.x += st.x; nIn = float3(-float(st.x), 0.0, 0.0); }
        else if (tM.y < tM.z)            { t = tM.y; tM.y += tD.y; v.y += st.y; nIn = float3(0.0, -float(st.y), 0.0); }
        else                             { t = tM.z; tM.z += tD.z; v.z += st.z; nIn = float3(0.0, 0.0, -float(st.z)); }
    }
    return 0;
}

// Sky-light levels the ground at P loses in the tree's shade (subtract from
// 15 before mcLightmap): up to two under the crown, falling off a level a
// block past its edge as smooth lighting blends it, since sky light reaches
// under the canopy from the side. `ao` is darkened round the trunk's foot.
// P is on the ground the tree stands on.
static inline float mcTreeShade(McTree tr, float3 P, thread float& ao) {
    float2 d = abs(P.xz - (tr.origin.xz + 0.5));
    float e = max(d.x, d.y);
    ao *= 0.6 + 0.4 * saturate(e - 0.5);
    return clamp((float(tr.reach) + 0.6 - e) * 1.25, 0.0, 2.0);
}
// ---- end of kit extras --------------------------------------------------------

"""#
}
