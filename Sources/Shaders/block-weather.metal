// Block Weather — the sky over a block world, keeping the Mac's hours.
// Original work for Lerping@Home; every texture, cloud and disc is procedural.
//
// lerp-category: Blocks
// lerp-data: clock
//
// You stand on a grassy knoll above a valley lake. Overhead a deck of flat
// cube clouds drifts with the wind, and their square shadows slide across
// the fields below. The square sun crosses the frame from the left horizon
// to the right between today's sunrise and sunset (`lerp-data: clock`), and
// the square moon does the same through the night in its phase, under a
// slowly turning field of pixel stars. Light follows: long block shadows
// and orange cloud sides at golden hour, a blue hour, moonlit fields.
//
// The weather keeps turning on its own, a few minutes a swing: clear spells,
// building overcast, and showers that hang under single dark cells as
// columns of rain (square ripples on the lake) or, when the days are short,
// snow over a white world and a frozen lake. Pure function of time.
//
// Stills (gallery, snapshots) are midnight on an equinox, as the clock
// provider gives them; `clock` pins the hour, `pace` runs the day faster.
//
// Cost: about 11 ms a frame at 3456x2234 on an M5 (bench, day and night).
// Worst pixel: up to 4 rounds of (14 march samples + 10 column cells) in
// the near field, 12 bands of 10 cells, 4 shadow samples and 8 corner
// lookups (near only), an 8-cell cloud walk, 5 rain-veil samples. Every
// height is three sines; no loop is unbounded; a rising ray stops as soon
// as it clears the tallest land can be.
//
// lerp-param: clock    float -1 24  = -1 "Hour (-1 = now)"
// lerp-param: pace     float 1 240  = 1  "Day speed"
// lerp-param: winter   int -1 1     = -1 "Winter (-1 = by day length)"
// lerp-param: showers  float 0 1    = 0.6 "Showers"
// lerp-param: wind     float 0 3    = 1  "Wind"
// lerp-param: yaw      float -180 180 = 0 "Turn"
// lerp-param: pitch    float -30 40  = 0 "Tilt"
// lerp-param: magnify  float -1 1.2  = 0 "Zoom"
// lerp-param: parallax float 0 2     = 1 "Head parallax"
//
// lerp-preset: "Day in Ten Minutes" pace=144
// lerp-preset: "Winter Day" winter=1, clock=11
// lerp-preset: "Summer Storms" winter=0, showers=1, clock=17

constant float BW_FOCAL   = 1.9;
constant float BW_PITCH   = 0.08;    // radians; horizon a little below centre
constant float BW_MAXH    = 24.0;     // no column is taller
constant float BW_WATER   = -0.12;    // lake surface
constant float BW_FOG0    = 64.0;
constant float BW_FOG1    = 140.0;

constant float BW_CY      = 44.0;     // cloud base
constant float BW_CT      = 4.0;      // cloud thickness
constant float BW_CELL    = 12.0;     // cloud cell
constant float BW_CFAR    = 520.0;
constant int   BW_CSTEPS  = 8;

constant float BW_AZMAX   = 0.52;     // sun/moon rise this far left, set this far right
constant float BW_DEG     = 0.0174533;

// ---------------------------------------------------------------------------
// The world's state at this instant.

struct BwEnv {
    float3 sunDir, moonDir, keyDir, keyCol, amb;
    float3 zen, hor, glow;          // sky
    float  sunEl;                   // degrees
    float  night, twilight;
    float  moonLit;                 // 0..1 lit fraction
    int    phase;
    float  winter;                  // 0..1
    float  cover;                   // global cloud cover
    float  storminess;
    float2 drift;                   // cloud advection offset (blocks)
    float2 off;                     // terrain seed offset
    float2 coff;                    // cloud pattern seed offset
    float  t;                       // seconds
    float  starTurn;
};

static inline float3 bwLin(float3 c) { return pow(max(c, 0.0), 2.2); }

static inline float bwFog(float t) {
    float f = saturate((t - BW_FOG0) / (BW_FOG1 - BW_FOG0));
    return f * f * (1.5 - 0.5 * f);
}

static inline float3 bwDir(float az, float el) {
    return float3(sin(az) * cos(el), sin(el), cos(az) * cos(el));
}

// ---------------------------------------------------------------------------
// Terrain: one column of blocks per integer cell, top face at y = height.
//
// Near the viewer (z < BW_ZB: the knoll and the lake) it is a full height
// field, walked cell by cell close to the ground and skipped through in
// open air. Beyond, the land is laid out in bands BW_BD deep across the
// view, each a ridge whose height varies along x only, like the flats of a
// stage receding into haze: a ray meets a band at its front face or walks a
// few cells along it, instead of crossing every column out to the horizon.
// (A full height field out to the fog cost four times the frame budget.)

constant float BW_ZB = 34.0;      // where the bands begin
constant float BW_BD = 9.0;       // band depth
constant int   BW_NB = 12;        // bands, out past the fog

// Linear ramps: the columns quantise them into terraces anyway.
static inline float bwBaseZ(float z) {
    float lake = -6.0 * saturate((z - 8.0) * (1.0 / 14.0)) * saturate((54.0 - z) * (1.0 / 18.0));
    return 2.5 + lake + 6.0 * saturate((z - 44.0) * (1.0 / 41.0));
}

static inline float bwSide(float x) { return 7.0 * saturate((abs(x - 6.0) - 18.0) * (1.0 / 42.0)); }

// Continuous height; a column's top is floor() of it.
static inline float bwHeightC(float2 p, float2 off) {
    float2 q = p + off;
    float n = 3.2 * sin(dot(q, float2(0.052, 0.021)))
            + 2.0 * sin(dot(q, float2(-0.030, 0.075)))
            + 1.0 * sin(dot(q, float2(0.130, 0.070)));
    float2 k = float2(p.x * (1.0 / 22.0), (p.y + 7.0) * (1.0 / 17.0));
    float ku = saturate(1.0 - dot(k, k));
    // the waves die down on the knoll, so the viewer always overlooks the lake
    float amp = 0.25 + 0.75 * saturate((dot(k, k) - 0.1) * 1.4);
    return min(bwBaseZ(p.y) + 6.5 * ku * ku + bwSide(p.x) + amp * n, BW_MAXH - 1.0);
}

// Band i's ridge: the field's shaping at the band's middle, with waves of
// its own (a shifted phase), so the far land reads as layered ridges.
static inline float bwBandHeight(float x, float i, float2 off) {
    float zm = BW_ZB + BW_BD * (i + 0.5);
    float2 q = float2(x, zm + i * 53.7) + off;
    float n = 3.2 * sin(dot(q, float2(0.052, 0.021)))
            + 2.0 * sin(dot(q, float2(-0.030, 0.075)))
            + 1.0 * sin(dot(q, float2(0.130, 0.070)));
    return floor(min(bwBaseZ(zm) + 0.5 * bwSide(x) + n, BW_MAXH - 1.0));
}

static inline float bwHeight(int2 c, float2 off) {
    float z = float(c.y) + 0.5;
    if (z > BW_ZB) return bwBandHeight(float(c.x) + 0.5, floor((z - BW_ZB) / BW_BD), off);
    return floor(bwHeightC(float2(float(c.x) + 0.5, z), off));
}

// The near field. Returns the hit distance, 1e9 for none before tMax, or a
// deep-water hit (n = 0) once the ray is well under the lake's surface.
//
// Two plain loops a round, so the lanes of a SIMD group stay in step: march
// over the smooth field until the ray is within a block of it, then walk the
// columns exactly for a few cells from there.
static inline float bwTraceNear(float3 ro, float3 rd, float tMax, float2 off,
                                thread float3& n, thread int2& cellOut) {
    float t = 0.0;
    float hl = max(length(rd.xz), 1e-4);
    float sd = max(-rd.y / hl, 0.0);            // descent per block across
    float2 d = select(rd.xz, float2(1e-6), abs(rd.xz) < 1e-6);
    float2 inv = 1.0 / d;
    int2 stp = int2(sign(d));
    float2 tDelta = abs(inv);
    for (int round = 0; round < 4; ++round) {
        // March.
        for (int i = 0; i < 14; ++i) {
            if (t > tMax) return 1e9;
            float3 p = ro + rd * t;
            if (rd.y > 0.0 && p.y > BW_MAXH) return 1e9;
            if (p.y < BW_WATER - 1.5) { n = float3(0.0); cellOut = int2(0); return t; }
            float gap = p.y - bwHeightC(p.xz, off);
            if (gap < 1.3) break;
            t += clamp((gap - 1.0) / (0.7 + sd), 0.5, 16.0) / hl;
        }
        // Walk.
        int2 cell = int2(floor(ro.xz + rd.xz * t));
        float2 tNext = (float2(cell) + select(float2(0.0), float2(1.0), d > 0.0) - ro.xz) * inv;
        float tEnter = t;
        int axis = -1;
        for (int i = 0; i < 10; ++i) {
            float h = bwHeight(cell, off);
            float yEnter = ro.y + rd.y * tEnter;
            if (yEnter < h) {
                n = axis == 0 ? float3(-float(stp.x), 0.0, 0.0)
                  : axis == 1 ? float3(0.0, 0.0, -float(stp.y)) : float3(0.0, 1.0, 0.0);
                cellOut = cell;
                return tEnter;
            }
            float tExit = min(tNext.x, tNext.y);
            float yExit = ro.y + rd.y * tExit;
            if (yExit < h) {
                n = float3(0.0, 1.0, 0.0);
                cellOut = cell;
                return (h - ro.y) / rd.y;
            }
            if (tExit > tMax) return 1e9;
            if (yExit < BW_WATER - 1.5) { n = float3(0.0); cellOut = int2(0); return tExit; }
            if (yExit > h + 2.5) { tEnter = tExit; break; }   // clear of the ground: march again
            if (tNext.x < tNext.y) { tEnter = tNext.x; tNext.x += tDelta.x; cell.x += stp.x; axis = 0; }
            else                   { tEnter = tNext.y; tNext.y += tDelta.y; cell.y += stp.y; axis = 1; }
        }
        t = tEnter;
    }
    // Out of steps while skimming the land: close enough to call it a top.
    float3 p = ro + rd * t;
    n = float3(0.0, 1.0, 0.0);
    cellOut = int2(floor(p.xz));
    return t;
}

// The bands, from tStart (where the ray crosses z = BW_ZB).
static inline float bwTraceBands(float3 ro, float3 rd, float tStart, float tMax, float2 off,
                                 thread float3& n, thread int2& cellOut) {
    float invZ = 1.0 / rd.z;
    float invX = 1.0 / (abs(rd.x) > 1e-5 ? rd.x : 1e-5);
    int sx = rd.x >= 0.0 ? 1 : -1;
    for (int i = 0; i < BW_NB; ++i) {
        float z0 = BW_ZB + BW_BD * float(i), zm = z0 + 0.5 * BW_BD;
        float ta = max((z0 - ro.z) * invZ, tStart), tb = (z0 + BW_BD - ro.z) * invZ;
        if (tb < tStart) continue;
        if (ta > tMax) return 1e9;
        float ya = ro.y + rd.y * ta, yb = ro.y + rd.y * tb;
        float xa = ro.x + rd.x * ta, xb = ro.x + rd.x * tb;
        float top = bwBaseZ(zm) + bwSide(max(abs(xa - 6.0), abs(xb - 6.0)) + 6.0) + 6.3;
        if (min(ya, yb) >= top) {
            if (rd.y >= 0.0 && ya > 22.0) return 1e9;   // above every band left
            continue;                                   // passes over this one
        }
        int cx = int(floor(xa));
        float bi = float(i);
        float h = bwBandHeight(float(cx) + 0.5, bi, off);
        if (ya < h) {
            n = float3(0.0, 0.0, -1.0);
            cellOut = int2(cx, int(z0));
            return ta;
        }
        float tX = (float(cx + (sx > 0 ? 1 : 0)) - ro.x) * invX;
        for (int k = 0; k < 10; ++k) {
            float tE = min(tX, tb);
            if (ro.y + rd.y * tE < h) {
                float th = (h - ro.y) / rd.y;
                n = float3(0.0, 1.0, 0.0);
                cellOut = int2(cx, int(clamp(floor(ro.z + rd.z * th), z0, z0 + BW_BD - 1.0)));
                return th;
            }
            if (tX >= tb) break;
            cx += sx;
            h = bwBandHeight(float(cx) + 0.5, bi, off);
            if (ro.y + rd.y * tX < h) {
                n = float3(-float(sx), 0.0, 0.0);
                cellOut = int2(cx, int(clamp(floor(ro.z + rd.z * tX), z0, z0 + BW_BD - 1.0)));
                return tX;
            }
            tX += abs(invX);
        }
    }
    return 1e9;
}

static inline float bwTrace(float3 ro, float3 rd, float tMax, float2 off,
                            thread float3& n, thread int2& cellOut) {
    float tZ = rd.z > 0.02 ? (BW_ZB - ro.z) / rd.z : 1e9;
    // A rising ray is done once it clears the tallest the land can be along
    // its way: near field and bands, each bounded by its own shaping terms.
    float xFar = abs(ro.x + rd.x * min(tZ, tMax) - 6.0);
    float tNear = min(tMax, tZ), tBands = tMax;
    if (rd.y > 0.0) {
        float hNear = 2.5 + 6.5 + 6.2 + bwSide(xFar + 6.0) + 0.5;
        tNear = min(tNear, max(hNear - ro.y, 0.0) / rd.y);
        float hBand = 2.5 + 6.0 + 6.3 + 7.0 + 0.5;
        tBands = min(tBands, max(hBand - ro.y, 0.0) / rd.y);
    }
    float t = bwTraceNear(ro, rd, tNear, off, n, cellOut);
    if (t < 1e8 || tZ > tBands) return t;
    return bwTraceBands(ro, rd, tZ, tBands, off, n, cellOut);
}

// ---------------------------------------------------------------------------
// Weather. Showers are sites on a coarse lattice carried by the wind; each
// one darkens and fills the cloud cells over it and rains from them.

// One shower site: centre, radius and how far it has built (0 = none).
static inline float4 bwStormSite(float2 s, float storminess) {
    const float G = 170.0;
    float2 h = hash22(s + 31.7);
    float2 c = (s + 0.5 + (h.yx - 0.5) * 0.25) * G;
    float r = 26.0 + 20.0 * fract(h.x * 7.31 + h.y * 3.7);
    float on = smoothstep(h.x - 0.15, h.x + 0.15, storminess * 1.15 - 0.05);
    return float4(c, r, on);
}

static inline float bwStormAt(float2 q, float4 site) {
    return site.w * (1.0 - smoothstep(site.z * 0.45, site.z, length(q - site.xy)));
}

static inline float bwStorm(float2 q, float storminess) {
    return bwStormAt(q, bwStormSite(floor(q / 170.0), storminess));
}

// Cloud cell occupancy, 0..1 (a cell fades in or out over half a minute
// rather than popping), and the shower strength over it.
// Occupancy given the shower strength over the cell.
static inline float bwCloudOccS(int2 cell, BwEnv E, float storm) {
    float2 fc = float2(cell);
    float v = 0.5 + 0.24 * sin(dot(fc, float2(0.61, 0.37)) + E.coff.x)
                  + 0.20 * sin(dot(fc, float2(-0.29, 0.73)) + E.coff.y)
                  + 0.30 * (hash21(fc + E.coff * 1.7) - 0.5);
    float cov = E.cover + 0.95 * storm;
    return smoothstep(1.0 - cov - 0.035, 1.0 - cov + 0.035, v);
}

static inline float bwCloudOcc(int2 cell, BwEnv E, thread float& storm) {
    storm = bwStorm((float2(cell) + 0.5) * BW_CELL, E.storminess);
    return bwCloudOccS(cell, E, storm);
}

static inline float bwCloudOcc(int2 cell, BwEnv E) {
    float s;
    return bwCloudOcc(cell, E, s);
}

// World xz to cloud-cell space (the deck drifts with the wind).
static inline float2 bwCloudSpace(float2 xz, BwEnv E) { return (xz - E.drift) / BW_CELL; }

// Occupancy over a world point, box-filtered by w blocks: hard-edged squares
// up close, no stair-stepping as they slide.
static inline float bwCloudOver(float2 xz, float w, BwEnv E) {
    float2 g = bwCloudSpace(xz, E) - 0.5;
    float2 i = floor(g), f = g - i;
    float2 k = saturate((f - 0.5) * (BW_CELL / max(w, 1e-3)) + 0.5);
    int2 c = int2(i);
    float a = bwCloudOcc(c, E), b = bwCloudOcc(c + int2(1, 0), E);
    float cc = bwCloudOcc(c + int2(0, 1), E), d = bwCloudOcc(c + int2(1, 1), E);
    return mix(mix(a, b, k.x), mix(cc, d, k.x), k.y);
}

// Rain (or snow) density at a world point under the deck: whole cloud cells
// rain, so the shafts are square columns.
static inline float bwRainCell(int2 c, BwEnv E) {
    float r = smoothstep(0.3, 0.75, bwStorm((float2(c) + 0.5) * BW_CELL, E.storminess));
    if (r <= 0.0) return 0.0;                  // no shower here: skip the cell
    float s;
    return bwCloudOcc(c, E, s) * r;
}

static inline float bwRainAt(float2 xz, BwEnv E) {
    return bwRainCell(int2(floor(bwCloudSpace(xz, E))), E);
}

// ---------------------------------------------------------------------------
// Sky.

static inline float3 bwSkyBase(float3 rd, BwEnv E) {
    float y = max(rd.y, 0.0);
    float y1 = (1.0 - y) * (1.0 - y);
    float3 c = mix(E.hor, E.zen, 1.0 - y1 * y1);
    if (E.twilight > 0.0) {
        float2 h = normalize(rd.xz + 1e-5), s = normalize(E.sunDir.xz + 1e-5);
        float a = max(dot(h, s), 0.0);
        float b = max(dot(rd, E.sunDir), 0.0);
        float b2 = b * b, b4 = b2 * b2, b8 = b4 * b4;
        c += E.glow * (a * a * a * exp(-y * 5.0) + 0.6 * b8 * b8 * b8);
    }
    // overcast greys it
    float l = dot(c, float3(0.3, 0.55, 0.15));
    return mix(c, float3(l) * float3(0.95, 0.98, 1.03), 0.65 * saturate(E.cover * 1.4 - 0.25));
}

// Gnomonic coordinates of rd in a disc's own frame, in disc half-sizes.
static inline float2 bwDiscUV(float3 rd, float3 dir, float size) {
    float3 r = normalize(cross(float3(0.0, 1.0, 0.0), dir));
    float3 up = cross(dir, r);
    float z = dot(rd, dir);
    if (z <= 0.0) return float2(9.0);
    return float2(dot(rd, r), dot(rd, up)) / (z * size);
}

static inline float bwBox(float2 p, float half_, float aa) {
    float d = max(abs(p.x), abs(p.y)) - half_;
    return saturate(0.5 - d / aa);
}

static inline float3 bwDiscs(float3 rd, BwEnv E, float px) {
    float3 c = float3(0.0);
    // Sun: an 8x8 block of light inside two stepped halo squares.
    const float SS = 0.058;
    float2 su = bwDiscUV(rd, E.sunDir, SS);
    float aa = px / SS;
    float sunUp = smoothstep(-3.0, 1.0, E.sunEl);
    if (max(abs(su.x), abs(su.y)) < 3.0 && sunUp > 0.0) {
        float3 warm = mix(float3(1.0, 0.45, 0.15), float3(1.0, 0.8, 0.45), smoothstep(0.0, 18.0, E.sunEl));
        c += warm * 0.06 * bwBox(su, 2.3, aa);
        c += warm * 0.14 * bwBox(su, 1.55, aa);
        float core = bwBox(su, 1.0, aa);
        int2 tx = int2(floor((su + 1.0) * 4.0));
        bool rim = tx.x == 0 || tx.y == 0 || tx.x == 7 || tx.y == 7;
        float3 face = rim ? mix(warm, float3(1.0, 0.9, 0.6), 0.5) * 3.0 : float3(1.0, 0.96, 0.82) * 5.0;
        face = mix(face, warm * 4.0, smoothstep(6.0, -1.0, E.sunEl) * 0.6);
        c += face * core;
        c *= sunUp;
    }
    // Moon: 8x8 texels, craters, phase drawn by whole texel columns.
    const float MS = 0.044;
    float2 mu = bwDiscUV(rd, E.moonDir, MS);
    if (max(abs(mu.x), abs(mu.y)) < 2.0) {
        float aam = px / MS;
        float core = bwBox(mu, 1.0, aam);
        int2 tx = clamp(int2(floor((mu + 1.0) * 4.0)), int2(0), int2(7));
        float cr = hash21(float2(tx) + 7.7);
        float3 face = float3(0.80, 0.83, 0.90) * (cr < 0.22 ? 0.62 : (cr < 0.4 ? 0.86 : 1.0));
        // phase: columns in shadow
        int p = E.phase, col = tx.x;
        // waning (1..3) loses columns from the left, waxing (5..7) grows from it
        bool dark = (p >= 1 && p <= 3) ? col < 2 * p : (p >= 5 ? col >= 2 * (p - 4) : false);
        float lit = dark ? 0.035 : 1.0;
        float vis = smoothstep(-2.0, 2.0, asin(E.moonDir.y) / BW_DEG) * smoothstep(-2.0, -8.0, E.sunEl) * 0.85 + 0.15;
        c += face * lit * core * 1.1 * vis;
        c += float3(0.5, 0.6, 0.9) * 0.012 * bwBox(mu, 1.5, aam) * E.moonLit * vis;
    }
    return c;
}

static inline float3 bwStars(float3 rd, BwEnv E, float3 right, float3 up, float px) {
    if (E.night <= 0.0 || rd.y < -0.02) return float3(0.0);
    // turn about the pole (behind the viewer, 40 degrees up)
    float3 ax = normalize(float3(0.0, 0.64, -0.77));
    float a = E.starTurn;
    float3 d = rd * cos(a) + cross(ax, rd) * sin(a) + ax * dot(ax, rd) * (1.0 - cos(a));
    const float K = 55.0;
    float3 cell = floor(d * K);
    float h = hash21(cell.xy * 1.3 + cell.z * 7.1 + 0.3);
    if (h > 0.16) return float3(0.0);
    float3 j = float3(hash22(cell.xz + 3.3), hash21(cell.yz + 9.1));
    float3 sd = normalize((cell + 0.2 + 0.6 * j) / K);
    // measure in screen pixels so every star is a crisp square
    float3 diff = d - sd;
    float2 s = float2(dot(diff, right), dot(diff, up)) / px;
    float b = hash21(cell.zx + 1.9);
    float sz = b > 0.93 ? 1.3 : 0.75;
    float cov = saturate(sz + 0.5 - abs(s.x)) * saturate(sz + 0.5 - abs(s.y));
    float tw = 0.75 + 0.25 * sin(E.t * (0.6 + 1.3 * b) + h * 60.0);
    float3 tint = mix(float3(0.75, 0.82, 1.0), float3(1.0, 0.88, 0.7), hash21(cell.yx));
    return tint * cov * (0.15 + 0.85 * b * b) * tw * E.night * 0.9 * smoothstep(-0.02, 0.12, rd.y);
}

// ---------------------------------------------------------------------------
// Clouds: walk the deck's cells; each face entered from empty air adds a
// layer, front to back. Returns premultiplied colour, .w = transmittance.

static inline float3 bwCloudFace(float3 n, float storm, BwEnv E) {
    float3 base = E.amb * 1.25 + E.keyCol * 0.18 + E.glow * 0.18;
    float shade;
    if (n.y < -0.5) shade = 0.78;
    else shade = (abs(n.x) > 0.5 ? 0.9 : 0.96) + 0.55 * max(dot(n, normalize(float3(E.keyDir.x, 0.0, E.keyDir.z) + 1e-5)), 0.0) * smoothstep(-2.0, 10.0, E.sunEl);
    float3 c = base * shade;
    if (n.y > -0.5) c += E.keyCol * 0.32 * max(dot(n, E.keyDir), 0.0);
    return c * mix(1.0, 0.3, smoothstep(0.1, 0.6, storm));
}

static inline float4 bwClouds(float3 ro, float3 rd, BwEnv E, float px) {
    float4 acc = float4(0.0, 0.0, 0.0, 1.0);
    if (rd.y < 0.012) return acc;
    float t0 = (BW_CY - ro.y) / rd.y;
    float t1 = (BW_CY + BW_CT - ro.y) / rd.y;
    if (t0 > BW_CFAR) return acc;
    float3 p0 = ro + rd * t0;
    float2 g = bwCloudSpace(p0.xz, E);
    int2 cell = int2(floor(g));
    float2 d = select(rd.xz, float2(1e-6), abs(rd.xz) < 1e-6);
    int2 stp = int2(sign(d));
    float2 tDelta = abs(BW_CELL / d);
    float2 tNext = t0 + (float2(cell) + select(float2(0.0), float2(1.0), d > 0.0) - g) * BW_CELL / d;
    float3 fogc = bwSkyBase(normalize(float3(rd.x, 0.02, rd.z)), E);
    float prev = 0.0;
    float2 siteId = float2(-1e9);
    float4 site = float4(0.0);
    float tEnter = t0;
    int axis = -1;
    for (int i = 0; i < BW_CSTEPS; ++i) {
        float2 q = (float2(cell) + 0.5) * BW_CELL;
        float2 sid = floor(q / 170.0);
        if (any(sid != siteId)) { siteId = sid; site = bwStormSite(sid, E.storminess); }
        float storm = bwStormAt(q, site);
        float o = bwCloudOccS(cell, E, storm);
        float a = max(o - prev, 0.0);
        if (a > 0.0) {
            float3 n = axis == 0 ? float3(-float(stp.x), 0.0, 0.0)
                     : axis == 1 ? float3(0.0, 0.0, -float(stp.y)) : float3(0.0, -1.0, 0.0);
            float tExit = min(min(tNext.x, tNext.y), t1);
            float edge = 1.0;
            float fw = tEnter * px;
            if (axis < 0) {
                // far edges of a bottom face, against sky
                float2 f = (g - float2(cell)) * BW_CELL;
                float2 toEdge = select(f, BW_CELL - f, d > 0.0) ;
                float fwB = fw / max(rd.y, 0.05);
                if (bwCloudOccS(cell + int2(stp.x, 0), E, storm) < 0.5) edge *= smoothstep(0.0, fwB, toEdge.x);
                if (bwCloudOccS(cell + int2(0, stp.y), E, storm) < 0.5) edge *= smoothstep(0.0, fwB, toEdge.y);
            } else {
                // top edge of a side face
                float y = ro.y + rd.y * tEnter;
                edge = smoothstep(0.0, fw, BW_CY + BW_CT - y);
            }
            float3 c = bwCloudFace(n, storm, E);
            float far = smoothstep(BW_CFAR * 0.35, BW_CFAR, tEnter);
            c = mix(c, fogc, far * 0.85);
            a *= 0.88 * edge * (1.0 - far * far);
            acc.rgb += acc.w * a * c;
            acc.w *= 1.0 - a;
            if (acc.w < 0.03) break;
        }
        prev = o;
        float tN = min(tNext.x, tNext.y);
        if (tN > t1) break;
        tEnter = tN;
        if (tNext.x < tNext.y) { tNext.x += tDelta.x; cell.x += stp.x; axis = 0; }
        else                   { tNext.y += tDelta.y; cell.y += stp.y; axis = 1; }
    }
    return acc;
}

// ---------------------------------------------------------------------------
// Block textures: 16x16 texels a face, faded to their average once a texel
// is smaller than a pixel.

static inline float bwTexelHash(int2 t, float salt) { return hash21(float2(t) * 1.17 + salt); }

// kind: 0 grass top, 1 grass side, 2 dirt, 3 stone, 4 sand, 5 snow top,
// 6 snow side, 7 gravel, 8 ice
static inline float3 bwAlbedo(int kind, int2 tx, float salt, float far, float lush) {
    float h = bwTexelHash(tx, salt);
    float h2 = bwTexelHash(tx / 2, salt + 5.0);
    float3 grass = mix(float3(0.36, 0.52, 0.18), float3(0.30, 0.58, 0.20), lush);
    float3 dirt  = float3(0.47, 0.33, 0.22);
    float3 stone = float3(0.50, 0.50, 0.51);
    float3 sand  = float3(0.86, 0.80, 0.58);
    float3 snow  = float3(0.97, 0.98, 1.0);
    float3 gravel = float3(0.50, 0.46, 0.43);
    float3 ice   = float3(0.42, 0.60, 0.80);
    float3 c, avg;
    float v = 0.84 + 0.24 * h;
    switch (kind) {
    case 0:  avg = grass; c = grass * (h < 0.15 ? 0.78 : v) * (h2 > 0.85 ? 1.1 : 1.0); break;
    case 1:
    case 6: {
        int depth = (kind == 6 ? 5 : 3) + int(bwTexelHash(int2(tx.x, 0), salt + 2.0) * 2.5);
        bool top = tx.y < depth || (tx.y == depth && bwTexelHash(int2(tx.x, 1), salt) > 0.6);
        float3 f = kind == 1 ? grass : snow;
        c = top ? f * v : dirt * (h < 0.12 ? 0.7 : v);
        avg = mix(dirt, f, kind == 6 ? 0.36 : 0.22);
        break;
    }
    case 2:  avg = dirt;  c = dirt * (h < 0.12 ? 0.7 : v); break;
    case 3:  avg = stone; c = stone * (h2 < 0.22 ? 0.72 : v) * (h > 0.92 ? 1.12 : 1.0); break;
    case 4:  avg = sand;  c = sand * (0.92 + 0.12 * h) * (h2 < 0.1 ? 0.85 : 1.0); break;
    case 5:  avg = snow;  c = snow * (0.94 + 0.08 * h) * float3(h2 < 0.15 ? 0.94 : 1.0, 1.0, 1.0); break;
    case 7:  avg = gravel; c = gravel * (0.7 + 0.5 * h); break;
    default: avg = ice;   c = ice * ((tx.x + tx.y * 3) % 11 == 0 && h > 0.4 ? 1.18 : 0.95 + 0.08 * h); break;
    }
    return bwLin(mix(c, avg, far));
}

// ---------------------------------------------------------------------------

// Where the sun and moon are: stylised arcs across the frame, the sun from
// sunrise to sunset, the moon through the night. Elevation follows day length.
struct BwArc {
    float3 sunDir, moonDir;
    float  e;          // sun elevation, degrees
    float  moonElDeg;
    float  hour, dayLen;
};

static inline BwArc bwArc(constant LerpUniforms& u, constant LerpClock& clock) {
    BwArc A;
    float hour = glmod(clock.hourAtZero + u.time * u.pace / 3600.0, 24.0);
    float rise = clock.sunrise, set = clock.sunset;
    float dayLen = set - rise;
    float maxEl = mix(24.0, 40.0, saturate((dayLen - 9.0) / 6.0)) * BW_DEG;
    float sd = (hour - rise) / dayLen;                   // 0..1 by day
    float sn = glmod(hour - set, 24.0) / (24.0 - dayLen); // 0..1 by night
    float sunEl, moonEl, sunAz, moonAz;
    // the arc spans the frame's width, narrower on a portrait screen
    float BW_AZ = min(BW_AZMAX, atan(0.8 * u.resolution.x / min(u.resolution.x, u.resolution.y) / BW_FOCAL));
    if (sd >= 0.0 && sd <= 1.0) {
        sunEl = maxEl * sin(PI * sd) + 2.5 * BW_DEG;
        sunAz = mix(-BW_AZ, BW_AZ, sd);
        moonEl = -0.3 * sin(PI * sd) + 2.5 * BW_DEG;
        moonAz = mix(BW_AZ, -BW_AZ, sd);   // back below the horizon
    } else {
        sunEl = -0.42 * sin(PI * sn) + 2.5 * BW_DEG;
        sunAz = mix(BW_AZ, -BW_AZ, sn);
        moonEl = maxEl * 0.72 * sin(PI * sn) + 2.5 * BW_DEG;
        moonAz = mix(-BW_AZ, BW_AZ, sn);
    }
    A.sunDir = bwDir(sunAz, sunEl);
    A.moonDir = bwDir(moonAz, moonEl);
    A.e = sunEl / BW_DEG;
    A.moonElDeg = moonEl / BW_DEG;
    A.hour = hour;
    A.dayLen = dayLen;
    return A;
}

// Key light: the sun by day, the moon by night, both faint near the horizon
// so the hand-over happens in the blue hour.
static inline float bwSunVis(BwArc A) { return smoothstep(-1.0, 7.0, A.e); }
static inline float bwMoonVis(BwArc A) {
    return smoothstep(0.0, 10.0, A.moonElDeg) * (1.0 - smoothstep(-6.0, -1.0, A.e));
}
static inline bool bwSunKeys(BwArc A) { return bwSunVis(A) >= bwMoonVis(A) || A.e > -1.0; }
static inline float3 bwKeyDir(BwArc A) {
    float3 k = bwSunKeys(A) ? A.sunDir : A.moonDir;
    k.y = max(k.y, 0.02);
    return normalize(k);
}

static inline float bwWinter(constant LerpUniforms& u, BwArc A) {
    return u.winter < 0 ? smoothstep(10.6, 10.0, A.dayLen) : float(u.winter);
}

static inline float2 bwTerrainOff(float seed) {
    return float2(fract(seed * 3.7), fract(seed * 9.13)) * 900.0 + 40.0;
}

static inline BwEnv bwEnv(constant LerpUniforms& u, BwArc A) {
    BwEnv E;
    E.winter = bwWinter(u, A);
    E.sunDir = A.sunDir;
    E.moonDir = A.moonDir;
    float e = A.e;
    E.sunEl = e;

    // Sky colours by the sun's height (sRGB, linearised).
    float3 zen = float3(0.03, 0.05, 0.12), hor = float3(0.08, 0.11, 0.20);
    float a = smoothstep(-14.0, -6.0, e), b = smoothstep(-6.0, 0.0, e);
    float c = smoothstep(0.0, 8.0, e), d = smoothstep(8.0, 22.0, e);
    zen = mix(zen, float3(0.07, 0.10, 0.24), a);  hor = mix(hor, float3(0.30, 0.22, 0.36), a);
    zen = mix(zen, float3(0.20, 0.25, 0.50), b);  hor = mix(hor, float3(0.98, 0.56, 0.32), b);
    zen = mix(zen, float3(0.30, 0.46, 0.80), c);  hor = mix(hor, float3(0.95, 0.80, 0.60), c);
    zen = mix(zen, float3(0.28, 0.50, 0.88), d);  hor = mix(hor, float3(0.68, 0.81, 0.95), d);
    float twi = smoothstep(-10.0, -2.0, e) * (1.0 - smoothstep(4.0, 16.0, e));
    E.zen = bwLin(zen); E.hor = bwLin(hor);
    E.glow = bwLin(float3(1.0, 0.42, 0.16)) * (0.8 * twi * twi);
    E.twilight = twi;
    E.night = 1.0 - smoothstep(-13.0, -5.0, e);

    // Moon phase from the seed (never new: there would be nothing to see by).
    E.phase = int(floor(fract(u.seed * 7.31 + 0.13) * 7.0));
    if (E.phase >= 4) E.phase += 1;
    int p = E.phase;
    E.moonLit = p == 0 ? 1.0 : (p < 4 ? 1.0 - 0.25 * float(p) : 0.25 * float(p - 4));

    float3 sunCol = mix(float3(1.0, 0.50, 0.24), float3(1.0, 0.93, 0.82), smoothstep(2.0, 24.0, e)) * 1.85;
    float3 moonCol = float3(0.42, 0.52, 0.85) * 0.6 * (0.3 + 0.7 * E.moonLit);
    E.keyDir = bwKeyDir(A);
    E.keyCol = bwSunKeys(A) ? sunCol * bwSunVis(A) : moonCol * bwMoonVis(A);
    E.amb = mix(E.hor, E.zen, 0.55) * 0.6 + float3(0.008, 0.012, 0.03);

    // Weather: two slow swings, never quite repeating.
    float t = u.time;
    E.t = t;
    float ph = u.seed * 37.0;
    float w1 = sin(t * TWO_PI / 430.0 + ph), w2 = sin(t * TWO_PI / 1130.0 + ph * 1.7);
    float wx = saturate(0.5 + 0.38 * w1 + 0.22 * w2);
    E.cover = mix(0.16, 0.56, wx);
    E.storminess = u.showers * smoothstep(0.35, 0.95, saturate(0.5 + 0.45 * sin(t * TWO_PI / 610.0 + ph * 2.3) + 0.15 * w2));
    // overcast light is greyer and dimmer
    float oc = smoothstep(0.3, 0.7, E.cover);
    E.amb = mix(E.amb, float3(dot(E.amb, float3(0.3, 0.55, 0.15))) * 1.05, 0.6 * oc) * mix(1.0, 0.8, oc);
    float wa = 0.35 + 0.5 * (hash11(u.seed * 13.1) - 0.5);
    E.drift = float2(cos(wa), -sin(wa)) * (u.wind * 1.1 * t) + float2(u.seed * 5000.0, u.seed * 3100.0);
    E.off = bwTerrainOff(u.seed);
    E.coff = float2(fract(u.seed * 5.3), fract(u.seed * 1.91)) * 300.0;
    E.starTurn = A.hour * (TWO_PI / 24.0);
    return E;
}

// ---------------------------------------------------------------------------
// Corner shading: on tops from the eight neighbours (the per-vertex scheme
// block games use), on sides towards the foot of the face.

static inline float bwCorner(float a, float b, float c) {
    return 3.0 - (a + b + (a + b > 1.5 ? 1.0 : c));
}

static inline float bwOcclusion(float3 P, float3 n, int2 cell, float h, float t, float2 off) {
    if (n.y > 0.5) {
        if (t > 13.0) return 1.0;
        float x0 = bwHeight(cell + int2(-1, 0), off) > h ? 1.0 : 0.0;
        float x1 = bwHeight(cell + int2( 1, 0), off) > h ? 1.0 : 0.0;
        float z0 = bwHeight(cell + int2(0, -1), off) > h ? 1.0 : 0.0;
        float z1 = bwHeight(cell + int2(0,  1), off) > h ? 1.0 : 0.0;
        float d00 = bwHeight(cell + int2(-1, -1), off) > h ? 1.0 : 0.0;
        float d10 = bwHeight(cell + int2( 1, -1), off) > h ? 1.0 : 0.0;
        float d01 = bwHeight(cell + int2(-1,  1), off) > h ? 1.0 : 0.0;
        float d11 = bwHeight(cell + int2( 1,  1), off) > h ? 1.0 : 0.0;
        float2 f = fract(P.xz);
        float v = mix(mix(bwCorner(x0, z0, d00), bwCorner(x1, z0, d10), f.x),
                      mix(bwCorner(x0, z1, d01), bwCorner(x1, z1, d11), f.x), f.y) / 3.0;
        return mix(1.0, 0.55 + 0.45 * v, 1.0 - smoothstep(8.0, 13.0, t));
    }
    float hn = bwHeight(cell + int2(int(n.x), int(n.z)), off);
    return 1.0 - 0.38 * exp(-(P.y - hn) * 1.8);
}

// The lit colour of a block face. `ao` and `sh` (terrain shadow) come from
// the caller, so no walk happens in here.
static inline float3 bwShadeTerrain(float3 P, float3 rd, float t, float3 n, int2 cell, float h,
                                    BwEnv E, float px, float ao, float sh) {
    bool top = n.y > 0.5;
    float fw = t * px / max(abs(dot(n, rd)), 0.12);
    float far = smoothstep(0.035, 0.09, fw);
    float salt = hash21(float2(cell) * 0.73 + 1.3) * 40.0;

    float2 fuv = top ? P.xz : (abs(n.x) > 0.5 ? float2(P.z * -n.x, P.y) : float2(P.x * n.z, P.y));
    int2 tx = clamp(int2(floor(fract(fuv) * 16.0)), int2(0), int2(15));
    if (!top) tx.y = 15 - tx.y;          // row 0 at the top of each block

    float lush = valueNoise((float2(cell) + E.off) * 0.05);
    bool snowy = E.winter > 0.5 || h >= 30.0;
    int kind;
    if (top) {
        if (h < 0.0) kind = (hash21(float2(cell)) > 0.5) ? 7 : 4;
        else if (h < 1.0) kind = snowy ? 5 : 4;
        else if (h >= 27.0 && !snowy) kind = 3;
        else kind = snowy ? 5 : 0;
    } else {
        float depth = h - floor(P.y) - 1.0;   // 0 for the top block
        salt += floor(P.y) * 3.1;
        if (h < 1.0) kind = depth < 2.0 ? 4 : 3;
        else if (depth < 0.5) kind = h >= 27.0 && !snowy ? 3 : (snowy ? 6 : 1);
        else if (depth < 3.5) kind = 2;
        else kind = 3;
    }
    float3 alb = bwAlbedo(kind, tx, salt, far, lush);

    // Wet ground under a shower.
    float rain = bwRainAt(P.xz, E) * step(BW_WATER, P.y);
    alb *= mix(1.0, E.winter > 0.5 ? 1.0 : 0.72, rain);

    // Key light with block shadows and cloud shadows.
    float3 L = E.keyDir;
    float diff = max(dot(n, L), 0.0);
    if (diff > 0.0) {
        float2 q = P.xz + L.xz * ((BW_CY + 1.0 - P.y) / L.y);
        sh *= 1.0 - 0.82 * bwCloudOver(q, max(fw, 0.35 + 0.012 * (BW_CY - P.y)), E);
    }
    // Block-game face shading: a side is a fixed step darker than a top
    // whichever way the sun is, so a face turned from the light is still its
    // own dirt or stone, lit by the sky and by light bounced off the ground.
    float face = top ? 1.0 : (abs(n.x) > 0.5 ? 0.72 : 0.82);
    float bounce = top ? 0.0 : 0.3 * saturate(E.keyDir.y * 2.5);
    return alb * (E.amb * (top ? 1.0 : 1.3) * face * ao
                  + E.keyCol * (diff * sh + bounce) * face * mix(0.8, 1.0, ao));
}

static inline float3 bwSkyAll(float3 ro, float3 rd, BwEnv E, float px, float3 right, float3 up) {
    float3 sky = bwSkyBase(rd, E) + bwStars(rd, E, right, up, px) * (1.0 - 0.9 * saturate(E.cover * 1.6 - 0.3));
    sky += bwDiscs(rd, E, px);
    float4 cl = bwClouds(ro, rd, E, px);
    return sky * cl.w + cl.rgb;
}

// Rain or snow seen along the ray up to tEnd: returns the veil's opacity.
// The shower is whole cloud cells raining, so the ray walks those columns
// exactly (cell to cell in the drifting deck) and adds the length it spends
// in each: crisp-sided shafts, no sampling noise.
static inline float bwVeil(float3 ro, float3 rd, float tEnd, BwEnv E) {
    if (E.storminess < 0.01) return 0.0;
    float tTop = rd.y > 1e-4 ? (BW_CY - ro.y) / rd.y : 1e9;
    tEnd = min(min(tEnd, 200.0), tTop);
    if (tEnd <= 0.0) return 0.0;
    float2 g = bwCloudSpace(ro.xz, E);
    int2 cell = int2(floor(g));
    float2 d = select(rd.xz, float2(1e-6), abs(rd.xz) < 1e-6);
    int2 stp = int2(sign(d));
    float2 tDelta = abs(BW_CELL / d);
    float2 tNext = (float2(cell) + select(float2(0.0), float2(1.0), d > 0.0) - g) * BW_CELL / d;
    float t = 0.0, od = 0.0;
    float2 siteId = float2(-1e9);
    float4 site = float4(0.0);
    for (int i = 0; i < 18; ++i) {
        float tN = min(min(tNext.x, tNext.y), tEnd);
        // the shower site over this cell, looked up once per site
        float2 q = (float2(cell) + 0.5) * BW_CELL;
        float2 sid = floor(q / 170.0);
        if (any(sid != siteId)) { siteId = sid; site = bwStormSite(sid, E.storminess); }
        if (site.w > 0.0) {
            float r = smoothstep(0.3, 0.75, bwStormAt(q, site));
            if (r > 0.0) { float st; od += bwCloudOcc(cell, E, st) * r * (tN - t); }
        }
        if (tN >= tEnd) break;
        t = tN;
        if (tNext.x < tNext.y) { tNext.x += tDelta.x; cell.x += stp.x; }
        else                   { tNext.y += tDelta.y; cell.y += stp.y; }
    }
    return 1.0 - exp(-od * 0.11);
}

static inline float bwStreaks(float2 uv, BwEnv E, float wind, bool snow) {
    float t = E.t;
    float s = 0.0;
    if (!snow) {
        for (int l = 0; l < 2; ++l) {
            float w = l == 0 ? 0.0046 : 0.0031;
            float spd = l == 0 ? 2.1 : 1.5;
            float x = uv.x + uv.y * 0.12 * wind;
            float ci = floor(x / w);
            float h = hash11(ci * 0.37 + float(l) * 17.0);
            float y = uv.y + t * spd * (0.85 + 0.3 * h) + h * 13.0;
            float seg = floor(y * 5.0);
            float on = step(hash21(float2(ci, seg) + float(l) * 3.0), 0.3);
            float f = fract(y * 5.0);
            s += on * step(f, 0.16) * (l == 0 ? 0.7 : 0.45);
        }
    } else {
        for (int l = 0; l < 3; ++l) {
            float cs = 0.045 + 0.03 * float(l);
            float spd = 0.07 + 0.04 * float(l);
            float2 q = uv + float2(sin(t * 0.3 + float(l)) * 0.02 - t * 0.01 * wind, t * spd);
            float2 ci = floor(q / cs);
            float2 f = q / cs - ci;
            float2 j = hash22(ci + float(l) * 9.0);
            if (j.x < 0.55) {
                float2 c = 0.25 + 0.5 * hash22(ci + 3.1 + float(l));
                float sz = (0.045 + 0.025 * float(l));
                float2 d = abs(f - c);
                s += step(max(d.x, d.y), sz) * (0.5 + 0.2 * float(l));
            }
        }
    }
    return saturate(s);
}

// Every walk runs once, at one call site, and the walks over the terrain run
// before the sky's state is built, so they hold few registers.
fragment half4 lerpMain(float4 pos [[position]],
                        constant LerpUniforms& u [[buffer(0)]],
                        constant LerpClock& clock [[buffer(1)]]) {
    float minRes = min(u.resolution.x, u.resolution.y);
    float2 uv = lerpUV(pos, u.resolution);
    float2 off = bwTerrainOff(u.seed);

    // Camera: on the knoll, looking out over the lake.
    float3 ro = float3(0.5, 0.0, -8.5);
    ro.y = max(bwHeight(int2(0, -9), off), bwHeight(int2(0, -8), off)) + 2.8;
    float3 upHint = float3(0.0, 1.0, 0.0);
    float3 fwd = normalize(float3(0.0, sin(BW_PITCH), cos(BW_PITCH)));
    float3 right = normalize(cross(upHint, fwd));
    float lens = lerpLook(u.yaw, u.pitch, u.magnify, upHint, right, fwd);
    float3 up = cross(fwd, right);
    float focal = lens * BW_FOCAL;
    float px = 2.0 / (focal * minRes);
    float3 rd = lerpViewerRay(u, u.parallax, uv, focal, right, up, fwd, ro);

    // 1. The ground.
    float3 n; int2 cell;
    float t = bwTrace(ro, rd, BW_FOG1 + 10.0, off, n, cell);
    float tw = (BW_WATER - ro.y) / rd.y;
    bool water = rd.y < 0.0 && tw > 0.0 && tw < t && tw < BW_FOG1;
    bool hit = t < 1e8 && dot(n, n) > 0.5;

    BwArc A = bwArc(u, clock);
    bool ice = water && bwWinter(u, A) > 0.5;
    float3 P = ro + rd * t;
    float h = hit ? bwHeight(cell, off) : 0.0;
    float ao = 1.0, sh = 1.0;
    if (hit && !water) {
        ao = bwOcclusion(P, n, cell, h, t, off);
        float3 L = bwKeyDir(A);
        if (dot(n, L) > 0.0) {
            // Block shadows from the terrain towards the light, sampled at
            // the column tops a few distances out rather than walked.
            float2 Lh = L.xz / max(length(L.xz), 1e-3);
            float slope = L.y / max(length(L.xz), 1e-3);
            float3 Q = P + n * 0.01;
            const float D[4] = { 1.0, 2.5, 5.0, 10.0 };
            for (int i = 0; i < 4; ++i) {
                float2 c = Q.xz + Lh * D[i];
                if (bwHeight(int2(floor(c)), off) > Q.y + slope * D[i]) { sh = 0.0; break; }
            }
        }
    }

    // 2. The sky, and whatever needs it: the open sky, or the lake's mirror.
    BwEnv E = bwEnv(u, A);
    float3 Pw = ro + rd * tw;
    float fwW = tw * px / max(-rd.y, 0.05);
    bool needSky = water || t >= 1e8;
    float3 sky = float3(0.0);
    if (needSky) {
        float3 so = water ? Pw : ro;
        float3 sdir = water ? reflect(rd, float3(0.0, 1.0, 0.0)) : rd;
        sky = bwSkyAll(so, sdir, E, px, right, up);
    }
    float3 ground = (hit && !ice) ? bwShadeTerrain(P, rd, t, n, cell, h, E, px, ao, sh) : float3(0.0);

    float3 col;
    float tEnd = min(t, 1e4);
    if (water) {
        tEnd = tw;
        float3 L = E.keyDir;
        float2 q = Pw.xz + L.xz * ((BW_CY + 1.0 - Pw.y) / L.y);
        float cl = bwCloudOver(q, max(fwW, 0.5), E);
        if (ice) {
            // Ice: a frozen texel floor that mirrors a little sky.
            int2 c = int2(floor(Pw.xz));
            int2 tx = int2(floor(fract(Pw.xz) * 16.0));
            float3 alb = bwAlbedo(8, tx, hash21(float2(c)) * 30.0, smoothstep(0.035, 0.09, fwW), 0.0);
            col = alb * (E.amb + E.keyCol * L.y * (1.0 - 0.8 * cl)) + 0.3 * sky;
        } else {
            // Water: the bed beneath, tinted by depth, and the sky above.
            float depth = hit ? (t - tw) * (-rd.y) : 4.0;
            float3 deep = bwLin(float3(0.10, 0.24, 0.50)) * (E.amb * 1.1 + E.keyCol * 0.25);
            float3 body = mix(ground, deep, 1.0 - exp(-depth * 0.55));
            // texel ripples: a slow per-texel shimmer, and square rings under rain
            int2 tx = int2(floor(Pw.xz * 16.0));
            float shim = hash21(float2(tx) + floor(E.t * 0.8 + hash21(float2(tx / 4)) * 3.0) * 0.17);
            float rain = bwRainAt(Pw.xz, E);
            float ring = 0.0;
            if (rain > 0.01 && fwW < 0.12) {
                int2 bc = int2(floor(Pw.xz * 0.5));
                float hb = hash21(float2(bc) + 0.7);
                float ph = fract(E.t * 0.9 + hb);
                float2 cen = (float2(bc) + 0.3 + 0.4 * hash22(float2(bc) + floor(E.t * 0.9 + hb))) * 32.0;
                float2 dd = abs(float2(tx) + 0.5 - cen);
                ring = step(abs(max(dd.x, dd.y) - ph * 9.0), 0.6) * (1.0 - ph) * rain;
            }
            float fres = 0.04 + 0.96 * pow(1.0 - saturate(-rd.y), 5.0);
            col = mix(body, sky, mix(0.12, 0.85, fres));
            col *= 0.94 + 0.1 * mix(shim, 0.5, smoothstep(0.03, 0.08, fwW));
            col += ring * (E.amb * 1.5 + E.keyCol * 0.2);
            col *= 1.0 - 0.25 * cl * smoothstep(0.0, 0.2, dot(E.keyCol, float3(0.33)));
        }
        col = mix(col, bwSkyBase(normalize(float3(rd.x, 0.07, rd.z)), E), bwFog(tw));
    } else if (t < 1e8) {
        float fog = max(bwFog(t), 0.36 * (1.0 - exp(-max(t - 18.0, 0.0) * (1.0 / 70.0))));
        col = mix(ground, bwSkyBase(normalize(float3(rd.x, max(rd.y, 0.07), rd.z)), E), fog);
        col += bwDiscs(rd, E, px) * fog * fog * fog * fog;   // a low sun or moon through the haze
    } else {
        col = sky;
        tEnd = 1e4;
    }

    // 3. Rain or snow between the eye and what it sees.
    float veil = bwVeil(ro, rd, tEnd, E);
    if (veil > 0.0) {
        // A shaft is the dark of its cloud's underside, the land behind
        // dimmed through it; the streaks catch the light, falling.
        bool snow = E.winter > 0.5;
        float3 dark = (E.amb * 1.25 + E.keyCol * 0.18) * 0.78 * 0.3;
        float3 vc = snow ? (E.amb * 1.4 + E.keyCol * 0.15) : dark;
        col = mix(col, vc, veil * (snow ? 0.55 : 0.88));
        float3 sc = snow ? float3(1.0) * (E.amb * 2.0 + E.keyCol * 0.4)
                         : (E.amb * 1.3 + E.keyCol * 0.25);
        col = mix(col, sc, bwStreaks(uv, E, u.wind, snow) * saturate(veil * 2.5) * (snow ? 0.9 : 0.55));
    }

    col = max(col, 0.0);
    col = col / (1.0 + col * 0.28);
    col = pow(col, 1.0 / 2.2);
    col = lerpDither(col, pos);
    return half4(half3(col), 1.0h);
}
