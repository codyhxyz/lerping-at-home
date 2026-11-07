// Mandelbulb — original shader written for Lerping@Home (AGPL-3.0, like the
// rest of this project). A slow orbit around the White–Nylander Mandelbulb
// while its power breathes, so the surface keeps re-growing its buds.
//
// Written from the published mathematics; no code is copied from any article
// or Shadertoy:
//   - the spherical-coordinate power z -> z^n + c, with z^n taken as
//     r^n (sin nθ cos nφ, cos nθ, sin nθ sin nφ)    (Daniel White and Paul
//     Nylander, 2009)
//   - the distance estimate 0.5·r·ln r / |dz| with the running derivative
//     |dz| -> n·r^(n-1)·|dz| + 1 (Hart, Sandin and Kauffman, "Ray tracing
//     deterministic 3-D fractals", SIGGRAPH 1989), as explained in Inigo
//     Quilez's "Mandelbulb" article (https://iquilezles.org/articles/mandelbulb/)
//     and Mikael Hvidtfeldt Christensen's "Distance Estimated 3D Fractals (V):
//     The Mandelbulb" (http://blog.hvidtfeldts.net/)
//   - for the Julia bulb the constant c replaces the sample position and the
//     +1 drops out of the derivative
//   - over-relaxed sphere tracing with a fallback step (Keinert et al.,
//     "Enhanced Sphere Tracing", 2014)
//   - orbit-trap colouring (the orbit's closest approach to the origin and to
//     the coordinate planes)
//   - tetrahedral-difference normals and multi-scale occlusion probes along
//     the normal, as in Inigo Quilez's articles on normals for SDFs and on
//     distance-field ambient occlusion
//   - Schlick's Fresnel approximation, and a two-beam thin-film interference
//     tint for the shell material
//
// Breathing without a seam: a non-integer power taken literally cuts the bulb
// along the half-plane where atan2 wraps. Here only the polar exponent (θ,
// which acos keeps in [0, π]) and the radial one breathe; the azimuthal
// exponent m is the power rounded to an integer, so cos mφ, sin mφ are exact
// polynomials of (x, z)/ρ — no atan2, no seam, and cheaper. With breathing
// off and a whole-number power (the Classic preset) the polar part is a
// polynomial too, the trig-free form of the formula.
//
// Surface detail. Each iteration of z -> z^n + c multiplies the running
// derivative by about n, so iteration k resolves features about n^-k across.
// The iteration cap is set per sample from the pixel footprint at that
// distance, log(1 / footprint) / log(n) plus a margin, and is fractional: the
// estimate (and the orbit trap) blends floor and floor + 1 iterations, so
// detail fades in as the camera nears instead of popping. Points a pixel off
// the surface escape after about that many iterations anyway, so the cap
// costs little; what it buys is that hits and normals are never cut short.
// (An earlier version used four iterations everywhere and a hit tolerance no
// finer than a 900-px view: power 4 and the Julia bulb read as smooth clay,
// and the four-iteration level set laid false ripples over the buds.)
//
// Cost control, because this runs full-screen for hours. Nearly all the work
// is fractal iterations on samples within a few pixels of the surface, so
// what matters is how close the march gets and how many probes follow it:
//   - a bounding sphere fitted to the measured extent of the set per power;
//     rays that miss it cost almost nothing.
//   - the hit tolerance is a 1.25-px cone, from the real pixel size down to
//     a 1280-px-tall view's (finer drawables do not march deeper; 4K tested
//     indistinguishable from a 2160-px cap at a quarter less work), and it
//     widens a little with every step so grazing rays stop crawling along
//     silhouettes. Escape radius 2.5, not 4: one iteration fewer per sample,
//     no visible change.
//   - over-relaxed steps with a fallback. (Marching with fewer iterations to
//     an outer hull and refining from there was tried: since the cap rarely
//     binds it saved nothing and cost a re-evaluation per hit.)
//   - acos by polynomial (A&S 4.4.46) rather than the library call, ~10%.
//   - shading reuses the hit sample's distance and orbit trap: normal 3
//     taps, occlusion 2, soft shadow 2.
//   (A 2x2-quad shared march like dusk-terrain's was tried and cost more:
//   rays converge on the bulb head-on, so speculative strides rarely land.)
// GPU cost, LerpPreview --bench --looks at 3840x2160, Apple M5, mean ms per
// frame, best of interleaved runs on a shared GPU scaled to fractal-multiverse
// = 8.7: defaults 9.7, Classic 8.7, Organic 10.6, Julia Bulb 13.1, Surface
// Flight 13.0 (the four-iteration version: 8.8, 6.7, 9.4, 9.5, 11.7).
//
// Julia bulb: contact sheets over |c|, latitude, azimuth and power showed
// smooth lumpy balls below |c| ~ 0.6 and rings and cages of buds past ~0.9;
// in between, at powers 3-8, the set is porous and ridged all over, and at
// low powers it adds swirling folds. The preset runs power 4 there.
//
// Materials, picked by `palette` (0 → 1 slides through all four):
//   0     oxidised bronze — metallic, warm on the ridges, verdigris in creases
//   1/3   celadon glaze — glassy clear coat, the glaze pooling darker in creases
//   2/3   iridescent shell — nacre, thin-film colour shifting with view angle
//   1     coral — warm bone on the buds, deep red in the crevices, translucent
//
// lerp-param: power    float 2 12  = 8.0  "Power"
// lerp-param: breathe  float 0 3   = 2.0  "Power breathing"
// lerp-param: speed    float 0 3   = 1.0  "Speed"
// lerp-param: distance float 0 1   = 0.65 "Camera distance"
// lerp-param: julia    float 0 1   = 0.0  "Julia"
// lerp-param: palette  float 0 1   = 0.0  "Palette"
// lerp-param: glow     float 0 1   = 0.5  "Glow"
// lerp-param: yaw      float -180 180 = 0 "Turn"
// lerp-param: pitch    float -90 90   = 0 "Tilt"
// lerp-param: magnify  float -1 0.8 = 0 "Zoom"
//
// lerp-preset: Classic   breathe=0.0, distance=0.7, palette=0.333, glow=0.6
// lerp-preset: Organic   power=5.0, breathe=0.6, distance=0.65, palette=1.0, glow=0.8
// lerp-preset: "Surface Flight" distance=0.0, breathe=1.0, palette=0.0, glow=0.6
// lerp-preset: "Julia Bulb" julia=1.0, power=4.0, breathe=0.8, distance=0.6, palette=0.667

constant int   MB_ITERS   = 13;     // loop bound on fractal iterations
constant float MB_LOD_MIN = 3.0;    // fewest iterations any sample gets
constant float MB_LOD_ADD = 1.5;    // iterations past the footprint estimate
constant float MB_TOL     = 1.25;   // hit tolerance, in pixels
constant int   MB_STEPS   = 72;     // march steps per pixel
constant float MB_BAIL    = 2.5;    // escape radius
constant float MB_FOCAL   = 1.9;    // ~55 degree vertical field of view
constant float MB_REF_PX  = 1280.0; // finest tolerance: a view this many px tall

struct MbBulb {
    float n;        // radial / polar exponent (breathes)
    int   m;        // azimuthal exponent (integer)
    bool  whole;    // n == m: the polar part is a polynomial too
    float3 c;       // Julia constant
    float jul;      // 0 Mandelbulb … 1 Julia bulb
    float lodK;     // 1 / log2(n)
    float lodAdd;   // iterations past the footprint estimate
};

// The unit complex number b = (cos a, sin a) raised to an integer power
// m in 1…15, i.e. (cos ma, sin ma), by binary exponentiation.
static inline float2 mbCPow(float2 b, int m) {
    float2 w = float2(1.0, 0.0);
    for (int k = 0; k < 4; k++) {
        if ((m >> k) & 1) w = float2(w.x * b.x - w.y * b.y, w.x * b.y + w.y * b.x);
        b = float2(b.x * b.x - b.y * b.y, 2.0 * b.x * b.y);
    }
    return w;
}

// acos to ~2e-8 rad without the library call: Abramowitz & Stegun 4.4.46,
// mirrored for negative x (a0 is pi/2 to float precision, so no seam at 0).
static inline float mbAcos(float x) {
    float a = abs(x);
    float p = -0.0012624911;
    p = fma(p, a, 0.0066700901);
    p = fma(p, a, -0.0170881256);
    p = fma(p, a, 0.0308918810);
    p = fma(p, a, -0.0501743046);
    p = fma(p, a, 0.0889789874);
    p = fma(p, a, -0.2145988016);
    p = fma(p, a, 1.5707963050);
    p *= sqrt(max(1.0 - a, 0.0));
    return x < 0.0 ? PI - p : p;
}

// Iterations wanted where one pixel is `foot` world units across.
static inline float mbLod(MbBulb B, float foot) {
    float l = -log2(max(foot, 1e-7)) * B.lodK + B.lodAdd;
    return clamp(l, MB_LOD_MIN, float(MB_ITERS) - 1.001);
}

// Distance estimate at p after `lod` iterations, blended between floor(lod)
// and floor(lod) + 1; the orbit trap (min |x|, |y|, |z|, |z|^2) likewise.
static inline float mbDE(float3 p, MbBulb B, float lod, thread float4& trap) {
    float3 z = p;
    float dr = 1.0;
    float r2 = dot(z, z);
    float4 tr = float4(abs(z), r2);
    float3 cc = mix(p, B.c, B.jul);
    float plus = 1.0 - B.jul;
    int kf = int(lod);
    float r2f = r2, drf = dr;
    float4 trf = tr;
    for (int i = 0; i < MB_ITERS; i++) {
        if (i <= kf) { r2f = r2; drf = dr; trf = tr; }
        if (i > kf || r2 > MB_BAIL * MB_BAIL) break;
        float ir = rsqrt(r2);
        float r = r2 * ir;
        float rho2 = max(z.x * z.x + z.z * z.z, 1e-14);
        float irho = rsqrt(rho2);
        float2 az = mbCPow(float2(z.x, z.z) * irho, B.m);     // (cos mφ, sin mφ)
        float cth, sth;
        if (B.whole) {
            float2 pz = mbCPow(float2(z.y, rho2 * irho) * ir, B.m);  // (cos nθ, sin nθ)
            cth = pz.x; sth = pz.y;
        } else {
            sth = sincos(B.n * mbAcos(clamp(z.y * ir, -1.0, 1.0)), cth);
        }
        float rn1 = exp2((B.n - 1.0) * log2(r));               // r^(n-1)
        dr = B.n * rn1 * dr + plus;
        z = (rn1 * r) * float3(sth * az.x, cth, sth * az.y) + cc;
        r2 = dot(z, z);
        tr = min(tr, float4(abs(z), r2));
    }
    float w = lod - float(kf);
    trap = mix(trf, tr, w);
    float df = 0.25 * log(r2f) * sqrt(r2f) / drf;
    float dc = 0.25 * log(r2) * sqrt(r2) / dr;
    return mix(df, dc, w);
}

static inline float mbMap(float3 p, MbBulb B, float lod) { float4 t; return mbDE(p, B, lod, t); }

// Ray / sphere: entry and exit distances, or (-1, -1) for a miss.
static inline float2 mbSphere(float3 ro, float3 rd, float rad) {
    float b = dot(ro, rd);
    float c = dot(ro, ro) - rad * rad;
    float h = b * b - c;
    if (h < 0.0) return float2(-1.0);
    h = sqrt(h);
    return float2(-b - h, -b + h);
}

// --- Materials -------------------------------------------------------------
struct MbMat {
    float3 lo, mid, hi;  // albedo ramp over the orbit trap (display-referred)
    float3 cav;          // what collects in the creases
    float3 glow;         // glow / rim colour
    float metal;         // specular tinted by the albedo
    float gloss;         // Blinn-Phong exponent
    float coat;          // clear-coat / Fresnel rim strength
    float irid;          // thin-film iridescence
    float sss;           // light leaking through thin buds
};

constant MbMat MB_MATS[4] = {
    // Oxidised bronze
    { float3(0.22, 0.10, 0.045), float3(0.62, 0.38, 0.18), float3(0.95, 0.74, 0.44),
      float3(0.10, 0.40, 0.33), float3(1.00, 0.42, 0.10), 0.85, 36.0, 0.20, 0.0, 0.0 },
    // Celadon glaze
    { float3(0.10, 0.24, 0.21), float3(0.47, 0.68, 0.57), float3(0.80, 0.93, 0.83),
      float3(0.04, 0.21, 0.18), float3(0.25, 0.80, 0.70), 0.0, 160.0, 1.00, 0.0, 0.15 },
    // Iridescent shell
    { float3(0.36, 0.32, 0.42), float3(0.78, 0.74, 0.80), float3(0.98, 0.95, 0.94),
      float3(0.12, 0.08, 0.24), float3(0.55, 0.40, 1.00), 0.15, 80.0, 0.85, 1.0, 0.10 },
    // Coral
    { float3(0.40, 0.08, 0.06), float3(0.86, 0.44, 0.30), float3(0.98, 0.86, 0.72),
      float3(0.24, 0.02, 0.04), float3(1.00, 0.28, 0.22), 0.0, 18.0, 0.30, 0.0, 0.55 },
};

static inline MbMat mbMaterial(float sel) {
    float x = clamp(sel, 0.0, 1.0) * 3.0;
    int i = min(int(x), 2);
    float w = x - float(i);
    MbMat a = MB_MATS[i], b = MB_MATS[i + 1], m;
    m.lo = mix(a.lo, b.lo, w);       m.mid = mix(a.mid, b.mid, w);
    m.hi = mix(a.hi, b.hi, w);       m.cav = mix(a.cav, b.cav, w);
    m.glow = mix(a.glow, b.glow, w); m.metal = mix(a.metal, b.metal, w);
    m.gloss = mix(a.gloss, b.gloss, w); m.coat = mix(a.coat, b.coat, w);
    m.irid = mix(a.irid, b.irid, w); m.sss = mix(a.sss, b.sss, w);
    return m;
}

static inline float3 mbRamp(MbMat M, float k) {
    k = clamp(k, 0.0, 1.0);
    return k < 0.5 ? mix(M.lo, M.mid, smoothstep(0.0, 0.5, k)) : mix(M.mid, M.hi, smoothstep(0.5, 1.0, k));
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float2 uv = lerpUV(pos, u.resolution);
    float T = u.speed * u.time + u.seed * 400.0;

    // --- The bulb. The power breathes slowly about its set value.
    MbBulb B;
    B.n = max(u.power + u.breathe * sin(0.021 * T + u.seed * 6.2831), 1.5);
    B.m = clamp(int(u.power + 0.5), 2, 15);
    B.jul = u.julia;
    B.whole = u.breathe == 0.0 && fract(u.power) == 0.0;
    if (B.whole) B.n = float(B.m);
    B.lodK = 1.0 / log2(max(B.n, 1.5));
    B.lodAdd = MB_LOD_ADD + 1.0 * B.jul;
    // The Julia constant wanders slowly through the shell |c| = 0.72-0.86,
    // within ~22 degrees of the equator: the porous, ridged band (header).
    float ca = 0.011 * T + u.seed * 17.0;
    float cb = 0.38 * sin(0.0077 * T + u.seed * 23.0);
    B.c = (0.79 + 0.07 * sin(0.013 * T + u.seed * 5.0)) * float3(cos(ca) * cos(cb), sin(cb), sin(ca) * cos(cb));
    // Bounding sphere: measured extents of the set (1.10 at power 8, 1.24
    // at 4, 1.54 at 2.5) plus a margin for the glow.
    float bound = mix(1.0 + 1.5 / max(u.power - u.breathe, 1.5), 1.5, B.jul);

    // --- Camera: a slow orbit that drifts in and out. Close in, it turns to
    // skim the surface along its path, with the bulb's limb as a horizon.
    float az = 0.035 * T + u.seed * TWO_PI;
    float el = 0.45 * sin(0.019 * T + u.seed * 11.0);
    float dist = mix(bound + 0.26, bound + 2.0, u.distance) * (1.0 + 0.05 * sin(0.027 * T));
    float3 radial = float3(cos(el) * cos(az), sin(el), cos(el) * sin(az));
    float3 tangent = float3(-sin(az), 0.0, cos(az));
    float3 ro = dist * radial;
    float skim = 1.0 - smoothstep(0.0, 0.35, u.distance);
    float3 fwd = normalize(mix(-radial, normalize(tangent - 0.9 * radial), skim));
    float3 upHint = normalize(mix(float3(0.0, 1.0, 0.0), radial, skim));
    float3 right = normalize(cross(upHint, fwd));
    lerpOrbit(u.yaw, u.pitch, u.magnify, float3(0.0), upHint, ro, right, fwd);   // drag to turn
    float3 up = cross(fwd, right);
    float3 rd = normalize(uv.x * right + uv.y * up + MB_FOCAL * fwd);

    MbMat M = mbMaterial(u.palette);
    float3 glowCol = M.glow;
    float3 bg = mix(float3(0.003, 0.004, 0.008), float3(0.012, 0.012, 0.024), 0.5 + 0.5 * uv.y);
    bg += glowCol * 0.012 * exp(-2.0 * dot(uv, uv));   // faint light behind the bulb
    float3 col = bg;

    // One pixel's angular size, from the real drawable down to MB_REF_PX.
    float pa = 2.0 / (MB_FOCAL * min(min(u.resolution.x, u.resolution.y), MB_REF_PX));
    float2 bs = mbSphere(ro, rd, bound);
    if (bs.y > 0.0) {
        float t = max(bs.x, 0.0);
        float tEnd = bs.y;
        bool hit = false;
        float glowAcc = 0.0;
        float d = 1.0;
        float4 trap = float4(1.0);
        float lod = MB_LOD_MIN;
        float w = 1.3, stepLen = 0.0, prevD = 0.0;
        for (int i = 0; i < MB_STEPS; i++) {
            float foot = pa * t;
            lod = mbLod(B, foot);
            d = mbDE(ro + rd * t, B, lod, trap);
            if (w > 1.0 && d + prevD < stepLen) {
                // The relaxed step overshot: back up to the plain step.
                t += prevD - stepLen;
                stepLen = prevD;
                w = 1.0;
                continue;
            }
            glowAcc += 1.0 / (1.0 + 4000.0 * d * d);
            // The tolerance widens a little with every step, so rays that
            // graze a silhouette give up instead of crawling along it.
            if (d < MB_TOL * foot * (1.0 + 0.06 * float(i))) { hit = true; break; }
            stepLen = d * w;
            prevD = d;
            t += stepLen;
            if (t > tEnd) break;
        }
        if (hit) {
            float3 p = ro + rd * t;
            float foot = pa * t;
            // Forward differences at about one pixel, off the hit sample's
            // own distance (same point, same iteration count).
            float e = max(0.7 * foot, 1e-5);
            float3 grad = float3(mbMap(p + float3(e, 0.0, 0.0), B, lod),
                                 mbMap(p + float3(0.0, e, 0.0), B, lod),
                                 mbMap(p + float3(0.0, 0.0, e), B, lod)) - d;
            float3 nor = normalize(grad);
            // The estimate runs below true distance by a factor that varies
            // over the set; its local slope calibrates the probes below.
            float slope = clamp(length(grad) / e, 0.05, 1.0);

            // Two-scale occlusion: probes along the normal at 3 and 30
            // pixel-ish radii (with a world-space floor). The near one sees
            // the creases between buds, the far one the big folds.
            float h0 = max(3.0 * foot, 0.0012);
            float cav = 0.0, ao = 0.0;
            float h = h0;
            for (int j = 0; j < 2; j++) {
                float dj = mbMap(p + nor * h, B, mbLod(B, max(foot, h * 0.25)));
                float o = clamp(1.0 - (dj - d) / (slope * h), 0.0, 1.0);
                cav = j == 0 ? o : cav;
                ao += o * (j == 0 ? 0.3 : 0.65);
                h *= 10.0;
            }
            ao = clamp(1.0 - ao, 0.0, 1.0);
            cav = smoothstep(0.1, 0.8, cav);

            // Orbit-trap colouring: how close the orbit came to the origin
            // picks the base tone (buds whose orbits stay out read lighter),
            // and the planar traps lay fine bands across it.
            float tr = clamp(trap.w, 0.0, 1.0);
            float kTone = 0.12 + 0.75 * sqrt(tr) + 0.20 * trap.x;
            float band = 0.5 + 0.5 * cos(TWO_PI * (2.2 * sqrt(trap.y) + 1.4 * trap.z));
            float3 base = mbRamp(M, kTone + 0.14 * (band - 0.5));
            base *= base;                                           // to linear
            float3 cavCol = M.cav * M.cav;
            float3 alb = mix(base, cavCol, cav * 0.9);
            // What fills the creases is matte: patina, pooled glaze, pigment.
            float metal = M.metal * (1.0 - cav);

            float3 L = normalize(right * -0.55 + up * 0.75 - fwd * 0.45);
            float dif = max(dot(nor, L), 0.0);
            // Soft shadow from two taps toward the light: how much of each
            // tap's free radius the surface leaves open.
            float sh = 1.0;
            if (dif > 0.0) {
                float3 q = p + nor * h0;
                float ls = max(lod - 2.5, MB_LOD_MIN);
                sh = min(sh, mbMap(q + L * 0.04, B, ls) / 0.04);
                sh = min(sh, mbMap(q + L * 0.16, B, ls) / 0.16);
                sh = smoothstep(0.0, 1.0, clamp(sh * 1.3, 0.0, 1.0));
            }
            float nv = clamp(-dot(rd, nor), 0.0, 1.0);
            float fre = pow(1.0 - nv, 5.0);
            float3 H = normalize(L - rd);
            float nh = clamp(dot(nor, H), 0.0, 1.0);
            float sky = 0.5 + 0.5 * dot(nor, up);
            float3 R = reflect(rd, nor);

            // Thin film: the path difference grows with the trap, so each
            // bud has its own colour cycle as the view angle sweeps.
            float film = 0.8 + 1.1 * sqrt(tr);
            float3 irc = 0.5 + 0.5 * cos(TWO_PI * (film * (0.35 + 0.65 * nv) + float3(0.0, 0.33, 0.67)));

            alb = mix(alb, alb * (0.4 + 1.2 * irc), 0.45 * M.irid * (1.0 - cav));

            // Diffuse: key light, cool sky, a bounce in the glow colour.
            float3 lin = float3(1.00, 0.87, 0.72) * 2.6 * dif * sh
                       + float3(0.14, 0.18, 0.30) * 0.55 * sky * ao
                       + glowCol * 0.22 * clamp(dot(nor, -L), 0.0, 1.0) * ao;
            col = alb * (1.0 - 0.75 * metal) * lin * mix(1.0, ao, 0.4);
            // Light through thin buds: back-lit grazing edges glow in the
            // albedo's own colour.
            col += M.sss * sqrt(alb) * glowCol * pow(clamp(dot(rd, L) * 0.5 + 0.5, 0.0, 1.0), 2.0)
                 * (1.0 - nv) * ao * 0.4;

            // Specular. A metal reflects in its own colour at every angle; a
            // glaze or shell reflects white, mostly at grazing angles (the
            // Fresnel rim); the shell's reflection is coloured by the film.
            float3 f0 = mix(float3(0.04), sqrt(base) * 0.9, metal);
            float3 F = f0 + (1.0 - f0) * fre;
            F *= mix(float3(1.0), 0.35 + 1.4 * irc, M.irid);
            float reflAmt = max(metal, M.coat);
            // The environment: a dim cool dome, dark below, a soft warm
            // window where the key light is.
            float up_ = dot(R, up);
            float3 env = mix(float3(0.010, 0.010, 0.016), float3(0.22, 0.27, 0.38), smoothstep(-0.2, 0.9, up_));
            env += float3(1.0, 0.86, 0.66) * 2.0 * pow(clamp(dot(R, L), 0.0, 1.0), 6.0) * sh;
            env += glowCol * 0.10 * smoothstep(0.3, -0.7, up_);
            col += env * F * reflAmt * ao;
            float gl = M.gloss;
            float spe = pow(nh, gl) * (gl + 8.0) / 25.0 * dif * sh;
            col += F * float3(1.0, 0.92, 0.80) * spe * (0.5 + reflAmt) * (1.0 - 0.8 * cav);

            // Subsurface-ish glow: light seems to well up from inside the
            // folds and leak through grazing edges.
            col += glowCol * u.glow * (0.20 * pow(1.0 - ao, 2.0) + 0.12 * pow(1.0 - nv, 3.0) * ao);
            // Depth fog from the near side of the bulb backwards.
            float fogA = 1.0 - exp(-0.55 * max(t - (length(ro) - 1.0), 0.0));
            col = mix(col, bg, fogA);
        }
        col += glowCol * glowAcc * 0.0012 * u.glow;
    }

    col = 1.0 - exp(-1.2 * col);
    col = sqrt(max(col, 0.0));
    col = lerpDither(col, pos);
    return half4(half3(col), 1.0h);
}
