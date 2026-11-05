// Dusk Terrain — original shader written for Lerping@Home (AGPL-3.0, like the
// rest of this project). A slow, calm fly-over of an endless procedural
// mountain range, low sun, with a sea of cloud filling the valleys.
//
// Built from the techniques Inigo Quilez explains in his articles
// (https://iquilezles.org/articles), written from those explanations — no
// code is copied from the articles or from any Shadertoy:
//   - value noise with analytic derivatives, and fBm whose octaves are damped
//     by the running gradient, which reads as erosion   (articles/morenoise)
//   - heightfield raymarching with a distance-relaxed step and a linear
//     refinement of the crossing                          (articles/terrainmarching)
//   - penumbra soft shadows from the closest miss along the shadow ray
//                                                         (articles/rmshadows)
//   - analytic exponential height fog with sun in-scatter (articles/fog)
//   - cosine colour palettes a + b·cos(2π(c·t + d))       (articles/palettes)
// The lattice hash scatters with the golden-ratio constant 0x9E3779B1 and
// xxHash's 0x85EBCA77, then applies the first round of the "lowbias32" mix
// published by Chris Wellons (hash-prospector, public domain / Unlicense).
//
// Cost control, because this runs full-screen for hours on laptops (about
// 13 ms a frame at 2704x1756 on an M5, inside a 60 fps frame):
//   - the 2x2 pixel quad crosses empty space together: each lane samples a
//     different stride along the quad's centre ray, so the shared part of the
//     march costs a quarter as much (see dtMarch).
//   - fBm octave count is a continuous function of distance (no LOD seams);
//     the silhouette carries every octave taller than about a pixel (so
//     distant ridges are the real ridges, not blobs that morph as they near),
//     behind envelope tests after octaves 2, 4 and 6; shading normals up to 9,
//     shadow rays 2 (only on slopes that face the sun).
//   - the march starts at the top of the terrain's bounding slab, quits as soon
//     as the ray leaves it upward, and below the cloud sea only marches as deep
//     as the cloud can still be seen through.
//   - the LOD is tied to distance, not to the drawable's pixel size, so a 5K
//     frame costs at most the 1200x750 frame times the pixel ratio.
//
// Seed: picks the noise lattice itself (it salts the hash), so every
// activation is a different landscape, route and sun bearing, while noise
// coordinates stay small. The route also re-rolls every DT_SEG seconds behind
// a few seconds of mist, which keeps coordinates — and float precision —
// bounded however long the look stays on screen.
//
// lerp-param: timeOfDay  float 0 1 = 0.30 "Time of day"
// lerp-animate: timeOfDay  0.22 0.4 period=300
// lerp-param: palette    float 0 1 = 0.0  "Palette"
// lerp-param: speed      float 0 3 = 1.0  "Camera speed"
// lerp-param: cloudCover float 0 1 = 0.45 "Cloud cover"
// lerp-param: cloudSea   float 0 1 = 0.45 "Cloud sea"
// lerp-param: altitude   float 0 1 = 0.35 "Flight altitude"
// lerp-param: haze       float 0 1 = 0.5  "Haze"
//
// Blue Hour flies at the default camera speed: at 0.7, over a dark, misty
// scene, 1-11% of the frame changed per 2 s and most windows read as still.
// lerp-preset: "Blue Hour"      timeOfDay=0.12, palette=1.0, cloudSea=0.6, cloudCover=0.3
// lerp-preset: "Blue Hour"      haze=0.65
// lerp-preset: "Golden Hour"    timeOfDay=0.55, cloudSea=0.15, cloudCover=0.35, haze=0.4
// lerp-preset: "Above the Clouds" timeOfDay=0.24, palette=0.5, cloudSea=0.85, altitude=0.75
// lerp-preset: "Above the Clouds" cloudCover=0.6, speed=0.8

// --- World scale. Heights are in world units; DT_F maps world to noise.
constant float DT_F      = 0.28;   // base terrain frequency
constant float DT_H      = 1.15;   // terrain height scale
constant float DT_HMAX   = 1.75;   // bounding slab of DT_H * fbm (measured 99.99th percentile ~1.5)
constant float DT_FAR    = 38.0;   // far clip; fog is total well before it
constant int   DT_STEPS  = 64;     // per-pixel march iterations
constant int   DT_QUAD_ITERS = 20; // shared 2x2 iterations, four strides each
constant float DT_QUAD_SLACK = 0.6; // how far a shared stride may outrun a sample's own
constant int   DT_SHADOW_STEPS = 10;
constant int   DT_MAX_OCT = 9;
constant float DT_GAIN   = 0.47;   // per-octave amplitude
constant float DT_SEG    = 540.0;  // seconds per route before it re-rolls
constant float DT_MIST   = 5.0;    // half-width of the mist at a re-roll
constant float DT_FOCAL  = 1.8;    // ~58 degree vertical field of view
constant float DT_SPEED  = 0.075;  // world units per second at speed 1

// Per-octave rotation (≈36.87°) so the lattices of successive octaves don't line up.
constant float2x2 DT_ROT = float2x2(float2(0.80, 0.60), float2(-0.60, 0.80));

// ---------------------------------------------------------------------------
// Noise

static inline float dtHash(int2 c, uint salt) {
    uint h = (uint(c.x) * 0x9E3779B1u) ^ (uint(c.y) * 0x85EBCA77u + salt);
    h ^= h >> 16; h *= 0x7feb352du;
    h ^= h >> 15;
    return float(h) * (1.0 / 4294967296.0);
}

// The same mix on an already-scattered lattice value, so the four corners of
// a cell share the two coordinate multiplies.
static inline float dtMix(uint h) {
    h ^= h >> 16; h *= 0x7feb352du;
    h ^= h >> 15;
    return float(h) * (1.0 / 4294967296.0);
}

// Value noise in [-1, 1] with its analytic gradient: (value, d/dx, d/dy).
// Quintic fade, so the gradient is continuous too.
static inline float3 dtNoised(float2 x, uint salt) {
    float2 i = floor(x);
    float2 f = x - i;
    float2 w  = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float2 dw = 30.0 * f * f * (f * (f - 2.0) + 1.0);
    int2 c = int2(i);
    uint hx0 = uint(c.x) * 0x9E3779B1u, hx1 = hx0 + 0x9E3779B1u;
    uint hy0 = uint(c.y) * 0x85EBCA77u + salt, hy1 = hy0 + 0x85EBCA77u;
    float a = dtMix(hx0 ^ hy0);
    float b = dtMix(hx1 ^ hy0);
    float e = dtMix(hx0 ^ hy1);
    float d = dtMix(hx1 ^ hy1);
    float k1 = b - a, k2 = e - a, k3 = a - b - e + d;
    float v = a + k1 * w.x + k2 * w.y + k3 * w.x * w.y;
    float2 g = dw * float2(k1 + k3 * w.y, k2 + k3 * w.x);
    return float3(2.0 * v - 1.0, 2.0 * g);
}

// Running state of the terrain fBm, so an evaluation can stop after a few
// octaves and later carry on to more.
struct DtFbm { float2 p; float2 d; float h; float amp; };

static inline DtFbm dtFbmStart(float2 xz) {
    DtFbm s;
    s.p = xz * DT_F; s.d = float2(0.0); s.h = 0.0; s.amp = 1.0;
    return s;
}

// Octaves i0 … lod of the terrain fBm, continuing from `s`, with a fractional
// octave count. Each octave is divided by (1 + |running gradient|²): slopes
// get less fine detail than flats and ridges, which is what makes the fBm look
// eroded. The last octave is weighted by the fraction of `lod`, so a change in
// LOD with distance never shows as a seam.
static inline void dtOctaves(thread DtFbm& s, int i0, float lod, uint salt) {
    for (int i = i0; i < DT_MAX_OCT; i++) {
        float wgt = clamp(lod - float(i), 0.0, 1.0);
        if (wgt <= 0.0) break;
        float3 n = dtNoised(s.p, salt);
        s.d += n.yz * wgt;
        s.h += wgt * s.amp * n.x / (1.0 + dot(s.d, s.d));
        s.amp *= DT_GAIN;
        s.p = DT_ROT * s.p * 2.03 + float2(1.7, -9.2);
    }
}

// Terrain height in world units at world xz.
static inline float dtTerrain(float2 xz, float lod, uint salt) {
    DtFbm s = dtFbmStart(xz);
    dtOctaves(s, 0, lod, salt);
    return DT_H * s.h;
}

// Octaves worth evaluating at distance t: an octave stops at roughly six
// pixel footprints of a 1600-px-tall view. Fixed, not per-drawable, so cost
// scales with pixel count only.
static inline float dtShadeLod(float t) { return clamp(10.7 - log2(t + 0.3), 3.0, float(DT_MAX_OCT)); }
// The silhouette gets the same detail less 1.5 octaves. It used to stop at
// 2-3.5 octaves: the distant range drew as smooth stand-in blobs whose crags
// (octaves 3-5, 20-30 px tall at 5-15 units) only grew in as the camera
// approached, so every far mountain visibly morphed. The octave that fades
// with distance now is about 2 px tall wherever it fades.
static inline float dtMarchLod(float t) { return clamp(dtShadeLod(t) - 1.5, 2.0, float(DT_MAX_OCT) - 1.5); }

// ---------------------------------------------------------------------------
// Ray functions

// Height of the ray above the terrain at distance t. Two octaves first:
// everything above them is bounded by the sum of their amplitudes (each octave
// is |n| ≤ 1 over a divisor ≥ 1), so while the ray clears that envelope by
// `near` the remaining octaves are skipped and the envelope clearance returned.
// The same test repeats after octaves 4 and 6 against what is left, so a ray
// passing a few pixels over a ridge pays for its coarse octaves only.
static inline float dtRest(int i0, float lod) {
    return DT_H * pow(DT_GAIN, float(i0)) * (1.0 - pow(DT_GAIN, max(lod - float(i0), 0.0))) / (1.0 - DT_GAIN);
}

static inline float dtClearance(float3 p, float t, float near, uint salt) {
    float lod = dtMarchLod(t);
    DtFbm s = dtFbmStart(p.xz);
    dtOctaves(s, 0, 2.0, salt);
    float dy = p.y - DT_H * s.h - 0.75 * dtRest(2, lod);
    if (dy >= near) return dy;
    dtOctaves(s, 2, min(lod, 4.0), salt);
    dy = p.y - DT_H * s.h - 0.75 * dtRest(4, lod);
    if (dy >= near) return dy;
    dtOctaves(s, 4, min(lod, 6.0), salt);
    dy = p.y - DT_H * s.h - 0.75 * dtRest(6, lod);
    if (dy >= near) return dy;
    dtOctaves(s, 6, lod, salt);
    return p.y - DT_H * s.h;
}

// Stride for a clearance dy: vertical clearance over a slope bound, so a
// rising ray takes longer strides than a falling one; far samples relax since
// detail there is sub-pixel and fogged anyway.
static inline float dtStride(float dy, float t, float rdy) {
    float k = min(0.6 + 0.035 * t, 1.1) * 1.4 / max(1.4 - rdy, 0.7);
    return max(dy * k, 0.018 + 0.0085 * t);
}

// Distance to the terrain along the ray, or -1 for a miss before tmax.
//
// Two phases. The four pixels of a 2x2 quad look along almost the same ray,
// so first they cross the empty space together: each lane tests a different
// one of the next four strides along the quad's centre ray, and the quad
// advances past all four at once while every sample is clear by more than the
// quad's footprint. Then each pixel finishes its own ray from there. Control
// flow in the shared phase depends only on quad-reduced values, so all four
// lanes run it in lockstep (helper lanes at the screen edge included).
static float dtMarch(float3 ro, float3 rd, float tmax, float px, uint salt) {

    // --- Shared phase, on the quad's centre ray.
    float3 rq = normalize(quad_sum(rd));
    float tqMax = quad_max(tmax);
    ushort rank = quad_prefix_exclusive_sum(ushort(1));
    float tq = 0.02;
    bool qMiss = false;
    if (ro.y > DT_HMAX) {
        if (rq.y >= 0.0) qMiss = true;
        else tq = (DT_HMAX - ro.y) / rq.y;
    }
    if (rq.y > 0.0) tqMax = min(tqMax, (DT_HMAX - ro.y) / rq.y);
    float cone = 2.5 * px;                       // lanes' rays sit within ~0.7 px of the centre
    float stride = 0.06;
    if (!qMiss) {
        for (int i = 0; i < DT_QUAD_ITERS; i++) {
            // Sample k sits k+1 strides out. The gap up to sample 0 is known
            // to be clear; the gap after sample k is clear only if sample k's
            // own clearance (less the quad's spread) would allow that stride.
            float ti = tq + stride * float(rank + 1);
            float dy = dtClearance(ro + rq * ti, ti, cone * ti + 0.04, salt) - cone * ti;
            bool tight = dy < 0.0015 * ti + 0.01;
            bool gapOK = !tight && dtStride(dy, ti, rq.y) >= DT_QUAD_SLACK * stride;
            ushort firstTight = quad_min(tight ? rank : ushort(4));
            ushort firstGap   = quad_min(gapOK ? ushort(4) : rank);
            if (firstTight == 0) break;
            // Furthest sample reachable through clear gaps, and clear itself.
            ushort m = min(ushort(firstTight - 1), firstGap);
            float dyM = quad_shuffle(dy, m);
            tq += stride * float(m + 1);
            if (firstTight < 4 || tq > tqMax) break;
            stride = dtStride(dyM, tq, rq.y);
        }
    }

    // --- Each lane on its own ray.
    float t = max(tq, 0.02);
    if (ro.y > DT_HMAX) {
        if (rd.y >= 0.0) return -1.0;
        t = max(t, (DT_HMAX - ro.y) / rd.y);
    }
    if (rd.y > 0.0) tmax = min(tmax, (DT_HMAX - ro.y) / rd.y);

    float lastT = t, lastDy = 1.0;
    for (int i = 0; i < DT_STEPS; i++) {
        if (t > tmax) break;
        float dy = dtClearance(ro + rd * t, t, 0.0015 * t + 0.02, salt);
        if (dy < 0.002 * t) {
            // Refine between the last sample above and this one.
            return (i == 0) ? t : mix(lastT, t, lastDy / max(lastDy - dy, 1e-5));
        }
        lastT = t; lastDy = dy;
        t += dtStride(dy, t, rd.y);
    }
    return -1.0;
}

// Penumbra shadow toward the sun: the narrowest miss, as an angle, along the
// ray. Ends as soon as the ray clears the slab.
static float dtShadow(float3 p, float3 l, uint salt) {
    float res = 1.0;
    float t = 0.04;
    for (int i = 0; i < DT_SHADOW_STEPS; i++) {
        float3 q = p + l * t;
        if (q.y > DT_HMAX) break;
        float dy = q.y - dtTerrain(q.xz, 2.0, salt);
        res = min(res, 10.0 * dy / t);
        if (res < 0.005) break;
        t += clamp(0.8 * dy, 0.1, 1.5);
    }
    return smoothstep(0.0, 1.0, clamp(res, 0.0, 1.0));
}

// ---------------------------------------------------------------------------
// Colour

// Cosine palette.
static inline float3 dtPal(float t, float3 a, float3 b, float3 c, float3 d) {
    return a + b * cos(TWO_PI * (c * t + d));
}

// Three dusk palettes, horizon at t=0, zenith at t=0.5. `palette` slides
// Ember (0) → Violet (0.5) → Arctic (1) by blending their coefficients.
static float3 dtSkyRamp(float t, float sel) {
    float3 a0 = float3(0.50, 0.33, 0.30), b0 = float3(0.45, 0.25, 0.22), d0 = float3(0.00, 0.08, 0.45);
    float3 a1 = float3(0.45, 0.25, 0.42), b1 = float3(0.42, 0.22, 0.25), d1 = float3(0.00, 0.15, 0.30);
    float3 a2 = float3(0.25, 0.45, 0.50), b2 = float3(0.22, 0.35, 0.35), d2 = float3(0.10, 0.02, -0.05);
    float k = clamp(sel, 0.0, 1.0) * 2.0;
    float3 a = k < 1.0 ? mix(a0, a1, k) : mix(a1, a2, k - 1.0);
    float3 b = k < 1.0 ? mix(b0, b1, k) : mix(b1, b2, k - 1.0);
    float3 d = k < 1.0 ? mix(d0, d1, k) : mix(d1, d2, k - 1.0);
    return clamp(dtPal(t, a, b, float3(1.0), d), 0.0, 1.0);
}

struct DtLight {
    float3 sun;      // direction
    float3 sunCol;   // linear radiance
    float  elev;     // radians
    float  skyLum;   // overall sky brightness
    float  day;      // 0 dusk palette … 1 daylight blue
    float  sel;      // palette selector
};

// Sky colour (linear) along rd, without clouds. Also the fog colour when
// called with a horizontal rd.
static float3 dtSky(float3 rd, DtLight L) {
    float y = max(rd.y, 0.0);
    float sd = max(dot(rd, L.sun), 0.0);
    float tau = 0.5 * (1.0 - exp(-4.5 * y));
    tau = max(tau - 0.07 * sd * sd, 0.0);           // warmer under the sun
    float3 dusk = dtSkyRamp(tau, L.sel);
    float3 dayc = mix(float3(0.66, 0.74, 0.82), float3(0.20, 0.38, 0.72), tau * 2.0);
    float3 c = mix(dusk, dayc, L.day);
    c = c * c * L.skyLum;                           // to linear
    // Glow around the sun, broad and low.
    c += L.sunCol * (0.10 * pow(sd, 3.0) + 0.35 * pow(sd, 24.0)) * (1.0 - 0.6 * y);
    return c;
}

// High cloud deck, composited over the sky.
static float3 dtSkyClouds(float3 rd, float3 sky, DtLight L, float cover, float time, uint salt) {
    if (rd.y <= 0.0 || cover <= 0.001) return sky;
    // Drift 3x what it first was, so the deck visibly moves at Blue Hour.
    float2 cp = rd.xz / (rd.y + 0.06) * 1.6 + float2(0.06, 0.03) * time;
    float n = 0.0, amp = 0.55;
    for (int i = 0; i < 5; i++) {
        n += amp * dtNoised(cp, salt + 77u).x;
        amp *= 0.5;
        cp = DT_ROT * cp * 2.1;
    }
    float thr = mix(0.55, -0.35, cover);
    float dens = smoothstep(thr, thr + 0.45, n) * smoothstep(0.0, 0.12, rd.y);
    float sd = max(dot(rd, L.sun), 0.0);
    float3 base = dtSky(float3(0.0, 1.0, 0.0), L) * 0.55;
    float3 lit = base + L.sunCol * (0.18 + 0.9 * pow(sd, 6.0)) * (1.1 - 0.7 * dens);
    return mix(sky, lit, 0.85 * dens);
}

// Camera route: a slow meander around the +z axis.
static inline float2 dtPath(float ph, float s) {
    return float2(2.6 * sin(0.105 * s + ph) + 1.3 * sin(0.047 * s + 2.0 * ph), s);
}

// Analytic fog for a density c·exp(-b·y) that falls off with height,
// integrated along the ray from ro to distance t.
static inline float dtFog(float3 ro, float3 rd, float t, float c) {
    const float b = 0.9;
    float k = abs(rd.y) < 1e-4 ? t : (1.0 - exp(-b * rd.y * t)) / (b * rd.y);
    return 1.0 - exp(-c * exp(-b * (ro.y + 0.3)) * k);
}

// ---------------------------------------------------------------------------

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float2 uv = lerpUV(pos, u.resolution);

    // --- Route segment. The route re-rolls at each multiple of DT_SEG, hidden
    // in mist; the first segment starts clear so activation isn't a fade-in.
    float segIdx = floor(u.time / DT_SEG);
    float local = u.time - segIdx * DT_SEG;
    float nearest = floor(u.time / DT_SEG + 0.5);
    float mist = nearest >= 1.0 ? 1.0 - smoothstep(0.0, DT_MIST, abs(u.time - nearest * DT_SEG)) : 0.0;
    uint salt = uint(u.seed * 16777216.0) * 0x2C1B3C6Du + uint(segIdx) * 0x297A2D39u;
    float rnd0 = dtHash(int2(3, 7), salt);
    float rnd1 = dtHash(int2(11, 5), salt);

    // --- Light. Time of day sets the sun's elevation; seed sets its bearing,
    // within ±65° of the route's mean heading so the view is toward the light.
    DtLight L;
    L.elev = -0.12 + pow(u.timeOfDay, 1.4);
    float az = (rnd0 - 0.5) * 2.3;
    L.sun = normalize(float3(sin(az) * cos(L.elev), sin(L.elev), cos(az) * cos(L.elev)));
    float airmass = 1.0 / (max(sin(L.elev), 0.0) + 0.035);
    L.sunCol = 3.2 * exp(-float3(0.030, 0.085, 0.21) * airmass)
             * smoothstep(-0.07, 0.02, L.elev);
    L.skyLum = mix(0.05, 1.0, smoothstep(-0.2, 0.1, L.elev));
    L.day = smoothstep(0.15, 0.75, L.elev);
    L.sel = u.palette;

    // --- Camera. Distance along a gently meandering path; height follows a
    // smoothed, low-octave terrain profile ahead so it never clips a ridge.
    float z = local * u.speed * DT_SPEED + rnd1 * 40.0;
    float ph = rnd1 * 6.2831;
    float2 c0 = dtPath(ph, z);
    float2 c1 = dtPath(ph, z + 0.9);
    float2 c2 = dtPath(ph, z + 2.2);
    float2 c3 = dtPath(ph, z + 4.0);
    float h0 = dtTerrain(c0, 3.0, salt);
    float h1 = dtTerrain(c1, 3.0, salt);
    float h2 = dtTerrain(c2, 3.0, salt);
    float h3 = dtTerrain(c3, 3.0, salt);
    // Smooth maximum (log-sum-exp) so the height has no kinks.
    const float K = 6.0;
    float hm = max(max(h0, h1), max(h2, h3));
    float hs = hm + log(exp(K * (h0 - hm)) + exp(K * (h1 - hm)) + 0.7 * exp(K * (h2 - hm))
                        + 0.4 * exp(K * (h3 - hm))) / K;
    float seaY = mix(-0.75, 0.40, u.cloudSea) * DT_H;
    bool seaOn = u.cloudSea > 0.001;
    float camY = hs + mix(0.22, 1.25, u.altitude);
    if (seaOn) camY = max(camY, seaY + mix(0.12, 0.6, u.altitude));

    float3 ro = float3(c0.x, camY, c0.y);
    float2 ahead = normalize(dtPath(ph, z + 1.6) - c0);
    float2 turn = dtPath(ph, z + 3.2) - 2.0 * dtPath(ph, z + 1.6) + c0;   // curvature for bank
    float pitch = -0.10 - 0.10 * u.altitude;
    float3 fwd = normalize(float3(ahead.x, pitch, ahead.y));
    float roll = clamp(-3.0 * (turn.x * ahead.y - turn.y * ahead.x), -0.12, 0.12);
    float3 upw = float3(sin(roll), cos(roll), 0.0);
    float3 right = normalize(cross(upw, fwd));
    float3 up = cross(fwd, right);
    float3 rd = normalize(uv.x * right + uv.y * up + DT_FOCAL * fwd);

    // --- Trace.
    float tSea = 1e9;
    if (seaOn && rd.y < 0.0 && ro.y > seaY) tSea = (seaY - ro.y) / rd.y;
    const float seaDepth = 1.0;      // ray length through cloud before it's opaque
    float tmax = min(DT_FAR, tSea + seaDepth);
    float pixelAngle = 2.0 / (DT_FOCAL * min(u.resolution.x, u.resolution.y));
    float t = dtMarch(ro, rd, tmax, pixelAngle, salt);

    float3 fogDir = normalize(float3(rd.x, 0.0, rd.z));
    float3 horizon = dtSky(fogDir, L);
    float3 skyUp = dtSky(float3(0.0, 1.0, 0.0), L);

    float3 col = float3(0.0);
    // Sky only where nothing opaque covers it.
    if (t < 0.0 && tSea >= DT_FAR) {
        col = dtSky(rd, L);
        // Night: a sparse star field that only exists once the sun is down.
        float night = 1.0 - smoothstep(-0.10, 0.02, L.elev);
        if (night > 0.0 && rd.y > 0.0) {
            float2 sp = rd.xz / (rd.y + 0.35) * 180.0;
            float2 cell = floor(sp);
            float r = dtHash(int2(cell), salt + 5u);
            float2 off = float2(dtHash(int2(cell) + 9, salt), dtHash(int2(cell) + 17, salt)) - 0.5;
            float star = step(0.985, r) * smoothstep(0.35, 0.0, length(sp - cell - 0.5 - 0.6 * off));
            col += night * star * (0.15 + 0.6 * fract(r * 97.0)) * smoothstep(0.05, 0.3, rd.y);
        }
        col = dtSkyClouds(rd, col, L, u.cloudCover, u.time, salt);
    }
    float haze = mix(0.015, 0.11, u.haze);
    float sdv = max(dot(rd, L.sun), 0.0);
    float3 fogCol = horizon + L.sunCol * 0.25 * pow(sdv, 8.0);

    // Terrain, if it's visible in front of (or through) the cloud.
    if (t > 0.0) {
        float3 p = ro + rd * t;
        float lod = dtShadeLod(t);
        float e = max(0.002, 0.0012 * t);
        // Low-octave height first (for occlusion), then carry on to full detail.
        DtFbm fs = dtFbmStart(p.xz);
        dtOctaves(fs, 0, 2.0, salt);
        float hl = DT_H * fs.h;
        dtOctaves(fs, 2, lod, salt);
        float hc = DT_H * fs.h;
        float hx = dtTerrain(p.xz + float2(e, 0.0), lod, salt);
        float hz = dtTerrain(p.xz + float2(0.0, e), lod, salt);
        // (Finite differences rather than the analytic gradient: the gradient
        // damping makes the fBm's true derivative need second derivatives.)
        float3 n = normalize(float3(hc - hx, e, hc - hz));
        p.y = hc;

        // Cheap occlusion: how far below its own low-octave surface a point sits.
        float occ = clamp(0.75 + 1.6 * (hc - hl), 0.35, 1.0);

        // Material: dark forest low, rock on slopes, snow on high flats.
        float hn = hc / DT_H;
        float3 rock = float3(0.16, 0.13, 0.115);
        float3 grass = float3(0.045, 0.06, 0.035);
        float3 alb = mix(rock, grass, smoothstep(0.6, 0.9, n.y) * (1.0 - smoothstep(0.0, 0.45, hn)));
        float snow = smoothstep(0.30, 0.55, hn + 0.12 * (hc - hl) * 10.0) * smoothstep(0.55, 0.8, n.y);
        alb = mix(alb, float3(0.80, 0.82, 0.86), snow);

        // Only slopes that face the sun need a shadow ray.
        float dif = max(dot(n, L.sun), 0.0);
        if (dif > 0.0 && t < 30.0) {
            // Start above the shadow's own (two-octave) surface, or hollows
            // in the detailed surface self-shadow under it.
            dif *= dtShadow(float3(p.x, max(p.y, hl) + 0.01, p.z), L.sun, salt);
        }
        float3 lin = L.sunCol * dif
                   + skyUp * (0.55 + 0.45 * n.y) * occ * 0.6
                   + horizon * 0.25 * clamp(-dot(n.xz, L.sun.xz), 0.0, 1.0) * occ;  // back fill
        float3 tc = alb * lin;
        float fogT = dtFog(ro, rd, t, haze);
        fogT = max(fogT, smoothstep(0.6 * DT_FAR, DT_FAR, t));
        col = mix(tc, fogCol, fogT);
    }

    // Cloud sea in front of the terrain: opacity from the length of ray below
    // its top, so cloud thins out where peaks rise just under it.
    if (tSea < DT_FAR && (t < 0.0 || t > tSea)) {
        float3 sp = ro + rd * tSea;
        float path = (t < 0.0) ? seaDepth : (t - tSea);
        // The sea flows 3x its first rate: at 0.015 it read as frozen.
        float2 q = sp.xz * 0.55 + float2(0.045, 0.024) * u.time;
        // Billows from four octaves; their analytic gradients tilt the
        // lighting normal, so the tops shade without any extra samples.
        float3 n1 = dtNoised(q, salt + 31u);
        float3 n2 = dtNoised(DT_ROT * q * 2.3, salt + 53u);
        float3 n3 = dtNoised(DT_ROT * q * 5.1, salt + 71u);
        float3 n4 = dtNoised(DT_ROT * q * 11.3, salt + 97u);
        float puff = 0.45 * n1.x + 0.28 * n2.x + 0.17 * n3.x + 0.10 * n4.x;
        float2 g = 0.55 * (0.45 * n1.yz + 0.28 * 2.3 * n2.yz + 0.17 * 5.1 * n3.yz + 0.10 * 11.3 * n4.yz);
        float3 cn = normalize(float3(-0.16 * g.x, 1.0, -0.16 * g.y));

        float dens = 6.0 * (0.75 + 0.35 * puff);
        float a = 1.0 - exp(-dens * path);
        float sh = (a > 0.02 && tSea < 30.0) ? dtShadow(sp + float3(0.0, 0.03, 0.0), L.sun, salt) : 1.0;
        float wrap = clamp(0.5 + 0.5 * dot(cn, L.sun), 0.0, 1.0);
        float3 cc = L.sunCol * (0.35 * wrap * wrap + 0.6 * pow(sdv, 10.0)) * sh
                  + skyUp * (0.75 + 0.25 * puff)
                  + horizon * 0.35;
        cc *= 0.78 + 0.22 * puff;
        float fogT = max(dtFog(ro, rd, tSea, haze), smoothstep(0.6 * DT_FAR, DT_FAR, tSea));
        cc = mix(cc, fogCol, fogT);
        col = mix(col, cc, a);
    }

    // Route re-roll: everything dissolves into the horizon mist and back.
    col = mix(col, 0.5 * (horizon + skyUp), mist);

    // Tonemap and back to display space.
    col = 1.0 - exp(-0.95 * col);
    col = sqrt(max(col, 0.0));
    col = lerpDither(col, pos);
    return half4(half3(col), 1.0h);
}
