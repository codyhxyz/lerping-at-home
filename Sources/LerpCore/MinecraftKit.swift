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
    const float h = 11.3137085;   // half the diagonal, 8 * sqrt 2
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
}
