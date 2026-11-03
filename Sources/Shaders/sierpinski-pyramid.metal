// Fractal Pyramids — original shader written for Lerping@Home (AGPL-3.0, like
// the rest of this project). A slow orbit around a kaleidoscopic IFS (KIFS)
// polyhedral fractal: the Sierpinski tetrahedron by default, with octahedral,
// icosahedral and dodecahedral variants and a per-iteration rotation that
// blooms the solids into crystalline, architectural forms.
//
// Written from the published math, no code copied:
//   - Knighty's kaleidoscopic IFS (fractalforums.com, 2010): fold space by the
//     mirror planes of a symmetry group, optionally rotate, then scale about a
//     vertex, p -> s·p - (s-1)·c, and repeat; the distance estimate is the
//     final level's distance divided by s^n.
//   - Mikael Christensen (Syntopia), "Distance Estimated 3D Fractals (III):
//     Folding Space" (http://blog.hvidtfeldts.net/), for the tetrahedral fold
//     planes x+y, x+z, y+z and the octahedral abs-and-sort fold.
//   - The icosahedral fold is derived here from the icosahedral reflection
//     group H3, whose 15 mirrors are the coordinate planes and the planes
//     with unit normals (±φ, ±1, ±1/φ)/2 and their cyclic shifts. abs(p), two
//     of those mirrors, abs(p) again and a third mirror take every point into
//     the fundamental chamber (found by a brute-force search over mirror
//     sequences and checked on 200k random points). The chamber's corners are
//     the 5-fold (icosahedron vertex) and 3-fold (dodecahedron vertex) axes,
//     the scaling centres of the icosahedral and dodecahedral forms.
//   - Ray marching with a distance-relative hit threshold, penumbra soft
//     shadows from the closest miss along the shadow ray, and distance-sampled
//     ambient occlusion, as Inigo Quilez explains them (iquilezles.org/articles).
//
// GPU cost, LerpPreview --bench at 3840x2160 on an Apple M5, mean over four
// camera views: defaults ~5 ms, Rose Quartz Spiral ~4, Stone Dodecahedron ~6,
// Crystal Bloom ~6.5, Jade Octahedron ~7, Amethyst Icosahedron ~8.5 (worst
// view ~9); fractal-multiverse is 8.6 ms and paper-texture 12.5 ms in the
// same runs.
//
// Cost control, because this runs full-screen for hours:
//   - every ray is clipped to the attractor's bounding sphere; rays that miss
//     it never evaluate the fractal.
//   - the distance estimate bails out of the iteration as soon as the point
//     is outside the attractor's bound at that level, which is still a valid
//     lower bound, so empty space costs one or two iterations, not ten.
//   - the hit threshold and the iteration depth are tied to a fixed reference
//     resolution, not the drawable, so a 5K frame costs at most the 1200x750
//     frame times the pixel ratio.
//   - shadow and occlusion rays use fewer iterations than primary rays.
//
// Seed: the orbit's starting bearing, direction, tilt and zoom rhythm, and
// the axes of the per-iteration rotation (so a twisted form is a different
// crystal every activation).
//
// form: 0 tetrahedron, 1 octahedron, 2 icosahedron, 3 dodecahedron.
//
// lerp-param: form      int   0 3     = 0    "Form"
// lerp-param: scale     float 1.5 3.0 = 2.0  "Fold scale"
// lerp-param: twist     float 0 1     = 0.0  "Fold rotation"
// lerp-param: bloom     float 0 1     = 0.5  "Rotation drift"
// lerp-param: detail    float 0 1     = 0.5  "Detail"
// lerp-param: speed     float 0 3     = 1.0  "Camera speed"
// lerp-param: zoom      float 0 1     = 0.4  "Camera distance"
// lerp-param: metal     float 0 1     = 1.0  "Metalness"
// lerp-param: gloss     float 0 1     = 0.7  "Gloss"
// lerp-param: colorA    color         = (0.95, 0.72, 0.36) "Material"
// lerp-param: colorB    color         = (0.55, 0.22, 0.08) "Crevice tint"
// lerp-param: colorRim  color         = (0.35, 0.55, 0.95) "Rim light"
// lerp-param: colorBack color         = (0.075, 0.068, 0.085) "Background"
//
// lerp-preset: "Jade Octahedron"   form=1, scale=2.0, detail=0.4, metal=0.0, gloss=0.8, zoom=0.35
// lerp-preset: "Jade Octahedron"   colorA=(0.20, 0.55, 0.38), colorB=(0.02, 0.12, 0.08)
// lerp-preset: "Jade Octahedron"   colorRim=(0.85, 0.95, 0.75), colorBack=(0.050, 0.075, 0.068)
// lerp-preset: "Amethyst Icosahedron" form=2, scale=2.0, detail=0.4, metal=0.25, gloss=0.95, zoom=0.45
// lerp-preset: "Amethyst Icosahedron" colorA=(0.50, 0.24, 0.80), colorB=(0.10, 0.02, 0.22)
// lerp-preset: "Amethyst Icosahedron" colorRim=(0.95, 0.55, 0.75), colorBack=(0.070, 0.048, 0.095)
// lerp-preset: "Stone Dodecahedron" form=3, scale=2.5, metal=0.0, gloss=0.2, zoom=0.5
// lerp-preset: "Stone Dodecahedron" colorA=(0.62, 0.56, 0.48), colorB=(0.20, 0.16, 0.13)
// lerp-preset: "Stone Dodecahedron" colorRim=(1.0, 0.70, 0.45), colorBack=(0.085, 0.078, 0.070)
// lerp-preset: "Crystal Bloom"     form=3, scale=2.2, twist=0.3, bloom=0.8, detail=0.2
// lerp-preset: "Crystal Bloom"     metal=0.6, gloss=0.95, colorA=(0.45, 0.70, 0.92), colorB=(0.03, 0.10, 0.26)
// lerp-preset: "Crystal Bloom"     colorRim=(1.0, 0.62, 0.38), colorBack=(0.045, 0.058, 0.090)
// lerp-preset: "Rose Quartz Spiral" form=0, scale=1.8, twist=0.3, bloom=0.8, detail=0.2
// lerp-preset: "Rose Quartz Spiral" metal=0.1, gloss=0.85, colorA=(0.95, 0.62, 0.66), colorB=(0.45, 0.12, 0.22)
// lerp-preset: "Rose Quartz Spiral" colorRim=(0.55, 0.80, 1.0), colorBack=(0.080, 0.050, 0.070)

constant float SP_SQRT3 = 1.73205080757;
// Icosahedral mirrors (unit normals (±φ, ±1, ±1/φ)/2 and cyclic shifts).
// SP_N_C bounds the fundamental chamber together with x, y, z >= 0.
constant float3 SP_N_A = float3(0.80901699437, -0.5, -0.30901699437);
constant float3 SP_N_B = float3(0.30901699437, 0.80901699437, -0.5);
constant float3 SP_N_C = float3(0.80901699437, 0.5, -0.30901699437);
// Chamber corners: icosahedron vertex (5-fold) and face (3-fold) axes.
constant float3 SP_C5 = float3(0.0, 0.52573111212, 0.85065080835);
constant float3 SP_C3 = float3(0.35682208977, 0.0, 0.93417235896);
constant float SP_IN_ICO = 0.79465447229;   // inradius / circumradius of icosa and dodeca

constant int   SP_STEPS = 120;               // primary march budget
constant int   SP_SHADOW_STEPS = 16;
constant float SP_PIXEL = 1.0 / 1600.0;      // reference pixel footprint, in focal units
constant float SP_FOCAL = 2.0;

struct SpFrac {
    float3x3 rot;      // per-iteration rotation (identity when untwisted)
    float3   off;      // scaling centre times (scale - 1)
    float    scale;
    float    bound;    // attractor radius at every level
    int      form;
    int      iters;
    bool     twisted;
};

// One fold into the form's fundamental region.
static inline float3 spFold(float3 p, int form) {
    if (form == 0) {
        // Tetrahedral: mirrors x+y=0, x+z=0, y+z=0.
        if (p.x + p.y < 0.0) p.xy = -p.yx;
        if (p.x + p.z < 0.0) p.xz = -p.zx;
        if (p.y + p.z < 0.0) p.zy = -p.yz;
    } else if (form == 1) {
        // Octahedral: abs, then sort so x >= y >= z.
        p = abs(p);
        if (p.x < p.y) p.xy = p.yx;
        if (p.x < p.z) p.xz = p.zx;
        if (p.y < p.z) p.yz = p.zy;
    } else {
        // Icosahedral (H3): reaches the chamber from anywhere in five folds.
        p = abs(p);
        p -= 2.0 * max(dot(p, SP_N_A), 0.0) * SP_N_A;
        p -= 2.0 * max(dot(p, SP_N_B), 0.0) * SP_N_B;
        p = abs(p);
        p -= 2.0 * max(dot(p, SP_N_C), 0.0) * SP_N_C;
    }
    return p;
}

// Distance from p to the last level's solid, unscaled.
static inline float spSolid(float3 p, int form) {
    if (form == 0) {
        float m = max(max(-p.x - p.y - p.z, -p.x + p.y + p.z), max(p.x - p.y + p.z, p.x + p.y - p.z));
        return (m - 1.0) / SP_SQRT3;
    }
    if (form == 1) {
        p = abs(p);
        return (p.x + p.y + p.z - 1.0) / SP_SQRT3;
    }
    p = spFold(p, 2);
    return dot(p, form == 2 ? SP_C3 : SP_C5) - SP_IN_ICO;
}

// Distance estimate with up to `iters` levels. Bails out once the point is
// clear of the level's bounding sphere: the attractor lies within `bound` at
// every level, so (|p| - bound) / s^i is still a lower bound.
static float spDE(float3 p, thread const SpFrac& F, int iters) {
    float k = 1.0;
    float lim = 4.0 * F.bound * F.bound;
    for (int i = 0; i < iters; i++) {
        float r2 = dot(p, p);
        if (r2 > lim) return (sqrt(r2) - F.bound) * k;
        p = spFold(p, F.form);
        if (F.twisted) p = F.rot * p;
        p = p * F.scale - F.off;
        k /= F.scale;
    }
    return spSolid(p, F.form) * k;
}

// The same, run to full depth with orbit traps for colouring: x = the closest
// any level came to the origin (crevices), y = the deepest level's position
// on its solid (face shading).
static float2 spTrap(float3 p, thread const SpFrac& F) {
    float trap = 1e9;
    for (int i = 0; i < F.iters; i++) {
        p = spFold(p, F.form);
        if (F.twisted) p = F.rot * p;
        p = p * F.scale - F.off;
        trap = min(trap, dot(p, p) / (F.bound * F.bound));
    }
    return float2(sqrt(trap), clamp(length(p) / F.bound, 0.0, 1.5));
}

static inline float3 spNormal(float3 p, float e, thread const SpFrac& F) {
    const float2 k = float2(1.0, -1.0);
    return normalize(k.xyy * spDE(p + k.xyy * e, F, F.iters) +
                     k.yyx * spDE(p + k.yyx * e, F, F.iters) +
                     k.yxy * spDE(p + k.yxy * e, F, F.iters) +
                     k.xxx * spDE(p + k.xxx * e, F, F.iters));
}

static float spShadow(float3 p, float3 l, float tmax, thread const SpFrac& F) {
    float res = 1.0;
    float t = 0.01 * F.bound;
    int it = max(F.iters - 3, 3);
    for (int i = 0; i < SP_SHADOW_STEPS; i++) {
        float d = spDE(p + l * t, F, it);
        res = min(res, 9.0 * d / t);
        t += clamp(d, 0.004 * F.bound, 0.25 * F.bound);
        if (res < 0.01 || t > tmax) break;
    }
    return smoothstep(0.0, 1.0, clamp(res, 0.0, 1.0));
}

static float spOcclusion(float3 p, float3 n, thread const SpFrac& F) {
    float occ = 0.0, w = 1.0;
    int it = max(F.iters - 2, 3);
    for (int i = 1; i <= 4; i++) {
        float h = F.bound * 0.035 * float(i * i);
        occ += w * max(h - spDE(p + n * h, F, it), 0.0) / h;
        w *= 0.6;
    }
    return clamp(1.0 - 0.9 * occ, 0.0, 1.0);
}

// Linear-light colours of the look (the parameters are display-space).
struct SpLook { float3 a, b, rim, back; };

// Studio surround: a dark room, lighter overhead, with a soft key box and the
// rim light's glow behind the subject. The background is the dim version;
// reflections see the lit one, so metals have something to mirror.
static float3 spEnv(float3 d, float3 up, float3 key, float3 rimDir, thread const SpLook& L, bool refl) {
    float y = dot(d, up);
    float3 c = L.back * (0.55 + 0.9 * smoothstep(-0.7, 0.9, y));
    float rb = pow(max(dot(d, rimDir), 0.0), 6.0);
    if (refl) {
        float kb = smoothstep(0.55, 0.95, dot(d, key));
        c += float3(1.0, 0.95, 0.88) * (0.12 + 0.85 * smoothstep(-0.3, 0.9, y) + 3.0 * kb);
        c += L.rim * 1.2 * rb;
    } else {
        c += L.rim * 0.02 * rb;
    }
    return c;
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float2 uv = lerpUV(pos, u.resolution);
    float seed = u.seed;

    // --- Fractal.
    SpFrac F;
    F.form = clamp(u.form, 0, 3);
    F.scale = u.scale;
    float3 c = F.form == 0 ? float3(1.0) : (F.form == 1 ? float3(1.0, 0.0, 0.0)
                                                        : (F.form == 2 ? SP_C5 : SP_C3));
    F.off = c * (F.scale - 1.0);
    F.bound = length(c) * 1.02;
    // Depth: features down to the reference pixel at the closest framing.
    float target = mix(150.0, 2500.0, u.detail * u.detail);
    F.iters = clamp(int(log(target) / log(F.scale) + 0.5), 3, 16);

    // Per-iteration rotation about a seeded axis near the scaling centre
    // (which keeps the copies overlapping, so the form stays solid), drifting
    // slowly with the camera clock.
    float ct = u.time * u.speed;
    float tw = u.twist;
    F.twisted = tw > 0.001;
    F.rot = float3x3(1.0);
    if (F.twisted) {
        float3 ax = normalize(normalize(c) + 0.7 * (float3(hash11(seed * 13.1 + 0.7), hash11(seed * 7.9 + 2.3),
                                                          hash11(seed * 3.3 + 5.1)) - 0.5));
        float ang = tw * (0.55 + 0.35 * u.bloom * sin(0.031 * ct + seed * 40.0))
                  + 0.15 * u.bloom * tw * sin(0.013 * ct + seed * 17.0);
        float s = sin(ang), co = cos(ang), r = 1.0 - co;
        F.rot = float3x3(float3(ax.x * ax.x * r + co,        ax.y * ax.x * r + ax.z * s, ax.z * ax.x * r - ax.y * s),
                         float3(ax.x * ax.y * r - ax.z * s, ax.y * ax.y * r + co,        ax.z * ax.y * r + ax.x * s),
                         float3(ax.x * ax.z * r + ax.y * s, ax.y * ax.z * r - ax.x * s, ax.z * ax.z * r + co));
    }

    // World orientation: stand the solid on a face so it reads as a pyramid
    // (tetrahedron) or a double pyramid (octahedron). World y maps to `fu`.
    float3 fu = F.form == 0 ? float3(1.0, 1.0, 1.0) / SP_SQRT3
              : (F.form == 1 ? float3(1.0, 0.0, 0.0) : SP_C5);
    float3 fx = normalize(cross(fu, abs(fu.z) < 0.9 ? float3(0.0, 0.0, 1.0) : float3(1.0, 0.0, 0.0)));
    float3 fz = cross(fx, fu);
    float3x3 W = float3x3(fx, fu, fz);    // world -> fractal: W * world

    // --- Camera: a slow orbit; seed picks bearing, direction, tilt and rhythm.
    float dir = hash11(seed * 5.7 + 0.3) < 0.5 ? -1.0 : 1.0;
    float az = seed * 97.0 + dir * 0.045 * ct;
    float el = 0.22 + 0.28 * sin(0.019 * ct + seed * 31.0);
    float dist = F.bound * mix(1.8, 4.0, u.zoom) * (1.0 + 0.10 * sin(0.011 * ct + seed * 23.0));
    float3 ro = dist * float3(cos(el) * sin(az), sin(el), cos(el) * cos(az));
    float3 look = float3(0.0, F.form == 0 ? 0.2 * F.bound : 0.0, 0.0);
    float3 fwd = normalize(look - ro);
    float roll = 0.05 * sin(0.017 * ct + seed * 11.0);
    float3 right = normalize(cross(float3(sin(roll), cos(roll), 0.0), fwd));
    float3 up = cross(fwd, right);
    float3 rdw = normalize(uv.x * right + uv.y * up + SP_FOCAL * fwd);

    // Lights in world space, carried with the camera's bearing so the lit
    // side stays mostly toward the viewer.
    float3 keyW = normalize(-0.55 * right + 0.75 * float3(0.0, 1.0, 0.0) - 0.35 * fwd);
    float3 rimW = normalize(0.6 * right + 0.25 * float3(0.0, 1.0, 0.0) + 0.9 * fwd);

    SpLook L;
    L.a = pow(u.colorA.rgb, 2.2);
    L.b = pow(u.colorB.rgb, 2.2);
    L.rim = pow(u.colorRim.rgb, 2.2);
    L.back = pow(u.colorBack.rgb, 2.2);
    float3 col = spEnv(rdw, float3(0.0, 1.0, 0.0), keyW, rimW, L, false);

    // --- March, in fractal space.
    float3 roF = W * ro, rdF = W * rdw;
    float b = dot(roF, rdF);
    float cc = dot(roF, roF) - F.bound * F.bound;
    float disc = b * b - cc;
    float closest = 1e9;
    float tHit = -1.0;
    float tEnter = 0.0;
    if (disc > 0.0) {
        float sq = sqrt(disc);
        float t0 = max(-b - sq, 0.0), t1 = -b + sq;
        tEnter = t0;
        float t = t0;
        for (int i = 0; i < SP_STEPS; i++) {
            float d = spDE(roF + rdF * t, F, F.iters);
            closest = min(closest, d / t);
            if (d < SP_PIXEL * t) { tHit = t; break; }
            t += d;
            if (t > t1) break;
        }
    }

    if (tHit > 0.0) {
        float3 p = roF + rdF * tHit;
        float3 n = spNormal(p, max(0.25 * SP_PIXEL * tHit, 1e-5), F);
        float3 key = W * keyW, rim = W * rimW, v = -rdF, upF = fu;
        float2 tr = spTrap(p, F);

        // Material: colorA on the faces, colorB down in the crevices.
        float crev = smoothstep(0.15, 0.9, tr.x);
        float3 alb = mix(L.b, L.a, crev);
        alb *= 0.85 + 0.15 * smoothstep(0.2, 1.2, tr.y);

        float3 pb = p + n * (2.0 * SP_PIXEL * tHit);
        float occ = spOcclusion(p, n, F);
        float ndl = max(dot(n, key), 0.0);
        float sh = ndl > 0.0 ? spShadow(pb, key, 2.5 * F.bound, F) : 0.0;
        float3 h = normalize(key + v);
        float ndh = max(dot(n, h), 0.0);
        float ndv = max(dot(n, v), 0.0);
        float fres = pow(1.0 - ndv, 5.0);
        float pw = exp2(mix(3.0, 10.0, u.gloss));
        float3 f0 = mix(float3(0.04), alb, u.metal);
        float3 fr = f0 + (1.0 - f0) * fres;

        float3 keyCol = float3(1.0, 0.93, 0.82) * 2.6;
        float3 sky = 0.14 + 3.0 * L.back;
        float3 fillDir = normalize(-key + 0.3 * upF);
        float3 diff = alb * (1.0 - u.metal) * (keyCol * ndl * sh
                    + sky * (0.6 + 0.4 * dot(n, upF)) * occ
                    + float3(0.20, 0.22, 0.26) * max(dot(n, fillDir), 0.0) * occ
                    + 0.5 * L.rim * max(dot(n, rim), 0.0) * occ);
        float3 lin = diff + keyCol * fr * pow(ndh, pw) * (pw + 2.0) / 8.0 * sh;

        // Reflection of the studio, blurred toward the surround along the
        // normal as gloss drops, and occluded in crevices.
        float3 rf = reflect(-v, n);
        float3 env = mix(spEnv(n, upF, key, rim, L, true), spEnv(rf, upF, key, rim, L, true), u.gloss);
        lin += env * fr * occ * mix(0.4, 1.0, u.metal);

        // Rim: a coloured back light catching silhouettes.
        float rimT = pow(1.0 - ndv, 3.0) * smoothstep(-0.2, 0.6, dot(n, rim));
        lin += L.rim * 1.2 * rimT * occ;

        // Depth fog through the solid toward the background.
        float depth = clamp((tHit - tEnter) / (2.0 * F.bound), 0.0, 1.0);
        col = mix(lin, col, 0.65 * depth * depth);
    } else if (closest < 1e8) {
        // A thin halo of the rim light along near misses.
        col += L.rim * 0.08 * exp(-closest * 160.0);
    }

    // Tonemap and back to display space.
    col = 1.0 - exp(-1.1 * col);
    col = pow(max(col, 0.0), float3(1.0 / 2.2));
    col = lerpDither(col, pos);
    return half4(half3(col), 1.0h);
}
